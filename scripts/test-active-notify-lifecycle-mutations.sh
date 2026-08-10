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
# Four clauses, in the order that matters:
#
#   (a) unique anchor. Enforced, not assumed — a stale recipe fails loudly here
#       rather than mutating the wrong site or nothing.
#   (b) `bash -n`, unconditionally and never as the malformed-mutant check. It
#       is free and it catches mutants that break the parse, but a quote shifted
#       one character leaves the file syntactically valid while destroying
#       tokenization, so it is a cheap pre-filter and nothing more.
#   (c) complete application. The replacement is verified to have changed the
#       file.
#   (d) the declared per-fixture vector. This is the mutant-validity check, and
#       it has to be per-fixture rather than a count: two mutations that share a
#       line here produce one red each and DIFFERENT reds, so a count accepts
#       either as the other and reports a pin that was never exercised.
#
# (d) only has force when the vector is pre-registered from the property the
# mutation was meant to exercise. A vector written from the observed result
# always matches and certifies whatever happened. If a run disagrees with its
# vector, the mutation is what gets investigated — not the vector.
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

self_check=0
[[ "${1:-}" == "--self-check" ]] && self_check=1

for p in "$manifest_root" "$lifecycle_root" "$notify_sh" "$driver"; do
  [[ -e "$p" ]] || { echo "FAIL: missing $p" >&2; exit 2; }
done

work=$(mktemp -d)
pristine="$work/notify.pristine.sh"
cp "$notify_sh" "$pristine"
restore() { cp "$pristine" "$notify_sh"; }
trap 'restore; rm -rf "$work"' EXIT

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
  anchor=$(cat "$dir/anchor")
  replacement=$(cat "$dir/replacement" 2>/dev/null || true)
  expected=$(grep -v '^#' "$expected_file" | grep -v '^$' | sort -u)

  if [[ -z "$expected" ]]; then
    echo "FAIL: $id — expected-red is empty; every mutation must declare a required red" >&2
    return 1
  fi

  restore
  # (a) unique anchor + (c) complete application, both enforced by the helper.
  if ! ANCHOR="$anchor" REPLACEMENT="$replacement" python3 - "$notify_sh" <<'PY'
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
  bash -n "$notify_sh" 2>/dev/null || syntax=BROKEN

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
for d in "${mutations[@]}"; do
  if run_mutation "$d" "$d/expected-red"; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
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

echo "test-active-notify-lifecycle-mutations: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
