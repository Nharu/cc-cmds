#!/usr/bin/env bash
# Mutation harness for the lifecycle suite. Applies each declared mutation to
# notify.sh singly and requires the observed red set to EQUAL the declared one.
#
# Manifest contract (tests/fixtures/active-notify-mutations/<id>/):
#   anchor       — required. Exact text to replace; must occur exactly once.
#   replacement  — required. Text to put in its place; may be empty.
#   expected-red — required. One fixture name per line; `#` lines are comments.
#                  Must be non-empty: a mutation nothing kills is not a pin, and
#                  recording it as one is how a suite certifies coverage it does
#                  not have.
#
# The four clauses, the reading rules, what is deliberately not caught, and the
# row schema all live in tests/mutation-harness/ — the canonical home. This file
# calls that schema check and cites that prose; it does not restate either.
#
# The red set is read as the complement of the driver's own per-fixture PASS
# lines and is then reconciled against the driver's `N failed` tally. Grepping
# the output for a `FAIL:` prefix does not work: fixtures in this suite print
# their own diagnostics with that same prefix, so a prefix-based extractor
# silently mixes fixture stderr into the set and the harness disagrees with
# itself while looking precise.
#
# Not wired into `make test` — a full pass re-runs the lifecycle suite once per
# mutation and costs minutes. Run it when notify.sh changes.
#
# Usage: test-active-notify-lifecycle-mutations.sh [--self-check]
#   --self-check  additionally runs one mutation against a deliberately wrong
#                 vector and requires the harness to report the mismatch. A
#                 harness that has never rejected anything is indistinguishable
#                 from one that cannot.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest_root="$repo_root/tests/fixtures/active-notify-mutations"
lifecycle_root="$repo_root/tests/fixtures/active-notify-lifecycle"
notify_sh="$repo_root/plugins/cc-cmds/skills/active-notify/scripts/notify.sh"
driver="$script_dir/test-active-notify-lifecycle.sh"
harness_home="$repo_root/tests/mutation-harness"

# shellcheck source=../tests/mutation-harness/schema-check.sh
. "$harness_home/schema-check.sh"

self_check=0
[[ "${1:-}" == "--self-check" ]] && self_check=1

for p in "$manifest_root" "$lifecycle_root" "$notify_sh" "$driver"; do
  [[ -e "$p" ]] || { echo "FAIL: missing $p" >&2; exit 2; }
done

# The tracked dispatcher is never written. Earlier revisions of this harness
# mutated it in place and restored it from a snapshot taken at startup, which is
# indistinguishable from working correctly right up until someone edits that
# file while the harness runs: the restore silently discards their edit, `git
# status` comes back clean, and the harness reports a full green. Instead the
# tracked file is copied once into an immutable snapshot, every mutation is
# applied to a separate scratch copy, and the driver is pointed at that copy
# through its input seam.
#
# `chmod a-w` on the snapshot is what makes "immutable" more than a comment: a
# future edit that reaches for the nearest path must fail loudly rather than
# corrupt the reference the whole run compares against.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pristine="$work/notify.pristine.sh"
cp "$notify_sh" "$pristine"
chmod a-w "$pristine"

target="$work/notify.under-test.sh"        # the mutated copy the driver runs
export CC_CMDS_DISPATCHER_UNDER_TEST="$target"
restore() { cp "$pristine" "$target"; chmod u+wx "$target"; }

# Hash the tracked file at both ends. This is the assertion that the isolation
# actually held — a harness that silently reverted to in-place mutation would
# still pass every vector while destroying a concurrent edit, and only this
# check separates the two.
hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
tracked_hash_before=$(hash_of "$notify_sh")

# All fixture names, mechanically enumerated. The red set is this minus the
# fixtures the driver reported as passing, so it cannot pick up anything that is
# not a fixture.
all_fixtures=$(find "$lifecycle_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)

# Runs the suite against whatever is currently at notify.sh; prints the red set,
# one name per line. Aborts the harness if the set disagrees with the driver's
# own tally.
observe_red() {
  local out="$work/driver.out" passed red summary want_failed
  set +e
  bash "$driver" > "$out" 2>"$work/driver.err"
  set -e
  summary=$(grep -E '^test-active-notify-lifecycle: [0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)
  [[ -n "$summary" ]] || { echo "HARNESS: driver printed no summary line" >&2; return 2; }
  want_failed=$(printf '%s' "$summary" | sed -E 's/.*, ([0-9]+) failed$/\1/')
  passed=$(sed -n 's/^PASS: \(.*\)$/\1/p' "$out" | sort -u | comm -12 - <(printf '%s\n' "$all_fixtures"))
  red=$(comm -23 <(printf '%s\n' "$all_fixtures") <(printf '%s\n' "$passed"))
  local got_failed
  got_failed=$(printf '%s' "$red" | grep -c . || true)
  if [[ "$got_failed" != "$want_failed" ]]; then
    echo "HARNESS: extracted $got_failed red fixture(s) but the driver reported $want_failed failed" >&2
    return 2
  fi
  printf '%s\n' "$red"
}

run_mutation() {   # $1 = mutation dir, $2 = expected-red file
  local dir="$1" expected_file="$2" id anchor replacement expected observed
  id=$(basename "$dir")
  # Command substitution strips trailing newlines, and several anchors are whole
  # lines whose newline is part of what the mutation removes. Dropping it turns
  # a line deletion into a blank line inside a `\` continuation chain — a syntax
  # error the mutation never intended, which `bash -n` then reports as a broken
  # mutant. The sentinel byte is what keeps the newline; it has to be stripped
  # at the assignment, because wrapping it in a helper reintroduces the problem.
  anchor=$(cat "$dir/anchor"; printf 'x'); anchor="${anchor%x}"
  replacement=$(cat "$dir/replacement"; printf 'x'); replacement="${replacement%x}"
  expected=$(grep -v '^#' "$expected_file" | grep -v '^$' | sort -u)

  restore
  # (a) unique anchor + (c) complete application, both enforced by the helper.
  if ! ANCHOR="$anchor" REPLACEMENT="$replacement" python3 - "$target" <<'PY'
import os, sys
path = sys.argv[1]
anchor, replacement = os.environ["ANCHOR"], os.environ["REPLACEMENT"]
src = open(path).read()
n = src.count(anchor)
if n != 1:
    sys.exit("anchor occurs %d time(s), expected exactly 1" % n)
out = src.replace(anchor, replacement, 1)
if out == src:
    sys.exit("replacement is a no-op")
open(path, "w").write(out)
PY
  then
    echo "FAIL: $id — anchor/application check failed" >&2
    return 1
  fi

  # (b) cheap pre-filter, run and reported unconditionally.
  local syntax=OK
  bash -n "$target" 2>/dev/null || syntax=BROKEN

  observed=$(observe_red) || { echo "FAIL: $id — harness aborted" >&2; return 1; }
  observed=$(printf '%s\n' "$observed" | grep -v '^$' | sort -u || true)
  restore

  if [[ "$observed" == "$expected" ]]; then
    printf 'PASS: %-38s bash -n=%-6s red={%s}\n' "$id" "$syntax" "$(printf '%s' "$observed" | tr '\n' ',' | sed 's/,$//')"
    return 0
  fi
  {
    echo "FAIL: $id — observed red set does not equal the declared one"
    echo "  declared: $(printf '%s' "$expected" | tr '\n' ',' | sed 's/,$//')"
    echo "  observed: $(printf '%s' "$observed" | tr '\n' ',' | sed 's/,$//')"
    echo "  bash -n:  $syntax"
  } >&2
  return 1
}

mutations=()
while IFS= read -r d; do mutations+=("$d"); done \
  < <(find "$manifest_root" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#mutations[@]} -gt 0 ]] || { echo "FAIL: no mutations declared under $manifest_root" >&2; exit 2; }

passed=0
failures=0
# Naming the failing rows in the summary is what makes a one-off
# reproducible-only-sometimes result attributable. A count alone tells a
# later reader that something moved and nothing about what, which is the
# same shape as a negative result whose cause was never established.
declare -a failed_rows=()
for d in "${mutations[@]}"; do
  # Schema before pins: a malformed corpus is a configuration error, and running
  # it anyway would report pin verdicts about rows that are not rows.
  mutation_row_schema_check "$d" || exit 2
  if run_mutation "$d" "$d/expected-red"; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    failed_rows+=("$(basename "$d")")
  fi
done

if (( self_check == 1 )); then
  # Known-positive control: the same mutation against a vector naming a fixture
  # it does not touch. The harness must reject it.
  ctl="${mutations[0]}"
  printf 'this-fixture-does-not-exist\n' > "$work/wrong-vector"
  if run_mutation "$ctl" "$work/wrong-vector" >/dev/null 2>&1; then
    echo "FAIL: self-check — the harness accepted a vector it should have rejected" >&2
    failures=$((failures + 1))
  else
    echo "PASS: self-check — a wrong vector is rejected"
    passed=$((passed + 1))
  fi
fi

tracked_hash_after=$(hash_of "$notify_sh")
if [[ "$tracked_hash_before" != "$tracked_hash_after" ]]; then
  echo "FAIL: the tracked dispatcher changed while the harness ran — isolation did not hold" >&2
  echo "  before: $tracked_hash_before" >&2
  echo "  after:  $tracked_hash_after" >&2
  exit 2
fi

echo "test-active-notify-lifecycle-mutations: $passed passed, $failures failed"
(( failures > 0 )) && echo "  failing row(s): ${failed_rows[*]:-<self-check>}"
echo "  tracked dispatcher unchanged (sha256 ${tracked_hash_before:0:12})"
if (( failures > 0 )); then
  exit 1
fi
exit 0
