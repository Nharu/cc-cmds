#!/usr/bin/env bash
# Mutation harness for the drift lint. Applies each declared mutation singly and
# requires the observed red set to EQUAL the declared one.
#
# Manifest contract (tests/fixtures/lint-active-notify-drift-mutations/<id>/):
#   anchor       — required. Exact text to replace; must occur exactly once.
#   replacement  — required. Text to put in its place; may be empty.
#   description  — required. One line: which property the mutation reverts.
#   expected-red — required, non-empty. One fixture name per line.
#
# The four clauses, the reading rules, what is deliberately not caught, and the
# row schema all live in tests/mutation-harness/ — the canonical home. This file
# calls that schema check and cites that prose; it does not restate either.
#
# The red set is read as the complement of the driver's own per-fixture PASS
# lines and reconciled against its `N failed` tally. A `FAIL:`-prefix grep does
# not work — fixtures print their own diagnostics with that prefix, and a
# harness that reads the wrong stream reports "nothing pins this" with full
# confidence, which is the conclusion this lint exists to make.
#
# Not wired into `make lint` or `make test`: a full pass re-runs the fixture
# suite once per mutation. Run it when the lint changes.
#
# Usage: test-lint-active-notify-drift-mutations.sh [--self-check]
#   --self-check  additionally runs one mutation against a deliberately wrong
#                 vector and requires the harness to report the mismatch.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest_root="$repo_root/tests/fixtures/lint-active-notify-drift-mutations"
fixtures_root="$repo_root/tests/fixtures/lint-active-notify-drift"
lint="$script_dir/lint-active-notify-drift.sh"
driver="$script_dir/test-lint-active-notify-drift.sh"
harness_home="$repo_root/tests/mutation-harness"

# shellcheck source=../tests/mutation-harness/schema-check.sh
. "$harness_home/schema-check.sh"

self_check=0
[[ "${1:-}" == "--self-check" ]] && self_check=1

for p in "$manifest_root" "$fixtures_root" "$lint" "$driver"; do
  [[ -e "$p" ]] || { echo "FAIL: missing $p" >&2; exit 2; }
done

# The tracked lint is never written. Earlier revisions of this harness mutated
# it in place and restored it from a snapshot taken at startup, which is
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

pristine="$work/lint.pristine.sh"
cp "$lint" "$pristine"
chmod a-w "$pristine"

target="$work/lint.under-test.sh"          # the mutated copy the driver runs
export CC_CMDS_DRIFT_LINT_UNDER_TEST="$target"
restore() { cp "$pristine" "$target"; chmod u+w "$target"; }

# Hash the tracked file at both ends. This is the assertion that the isolation
# actually held — a harness that silently reverted to in-place mutation would
# still pass every vector while destroying a concurrent edit, and only this
# check separates the two.
hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
tracked_hash_before=$(hash_of "$lint")

all_fixtures=$(find "$fixtures_root" -mindepth 1 -maxdepth 1 -type d -name 'T-ANDRIFT-*' \
  -exec basename {} \; | sort)

observe_red() {
  local out="$work/driver.out" passed red summary want_failed got_failed
  set +e
  bash "$driver" > "$out" 2>"$work/driver.err"
  set -e
  summary=$(grep -E '^test-lint-active-notify-drift: [0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)
  [[ -n "$summary" ]] || { echo "HARNESS: driver printed no summary line" >&2; return 2; }
  want_failed=$(printf '%s' "$summary" | sed -E 's/.*, ([0-9]+) failed$/\1/')
  passed=$(sed -n 's/^PASS: \([^ ]*\) (exit=.*$/\1/p' "$out" | sort -u \
    | comm -12 - <(printf '%s\n' "$all_fixtures"))
  red=$(comm -23 <(printf '%s\n' "$all_fixtures") <(printf '%s\n' "$passed"))
  got_failed=$(printf '%s' "$red" | grep -c . || true)
  if [[ "$got_failed" != "$want_failed" ]]; then
    echo "HARNESS: extracted $got_failed red fixture(s) but the driver reported $want_failed failed" >&2
    return 2
  fi
  printf '%s\n' "$red"
}

run_mutation() {   # $1 = mutation dir, $2 = expected-red file
  local dir="$1" expected_file="$2" id anchor replacement expected observed syntax
  id=$(basename "$dir")
  # Command substitution strips trailing newlines, and several anchors are whole
  # lines whose newline is part of what the mutation removes. Dropping it turns
  # a line deletion into a blank line inside a `\` continuation chain — a syntax
  # error the mutation never intended, which `bash -n` then reports as a broken
  # mutant. The sentinel byte is what keeps the newline; it has to be stripped
  # at the assignment, because wrapping it in a helper reintroduces the problem.
  anchor=$(cat "$dir/anchor"; printf 'x'); anchor="${anchor%x}"
  replacement=$(cat "$dir/replacement"; printf 'x'); replacement="${replacement%x}"
  # One parse, shared with the counter below via the same helper. `$2` lets the
  # self-check controls feed a vector that is not the row's own file.
  if [[ "$expected_file" == "$dir/expected-red" ]]; then
    expected=$(mutation_row_declared_vector "$dir" | sort -u)
  else
    expected=$(grep -v '^#' "$expected_file" | grep -v '^$' | sort -u)
  fi

  restore
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

  syntax=OK
  bash -n "$target" 2>/dev/null || syntax=BROKEN

  observed=$(observe_red) || { echo "FAIL: $id — harness aborted" >&2; return 1; }
  observed=$(printf '%s\n' "$observed" | grep -v '^$' | sort -u || true)
  restore

  if [[ "$observed" == "$expected" ]]; then
    printf 'PASS: %-46s bash -n=%-6s red=%s\n' "$id" "$syntax" \
      "$(printf '%s' "$observed" | tr '\n' ',' | sed -e 's/,$//' -e 's/T-ANDRIFT-//g')"
    return 0
  fi
  {
    echo "FAIL: $id — observed red set does not equal the declared one"
    echo "  declared: $(printf '%s' "$expected" | tr '\n' ',' | sed 's/,$//')"
    echo "  observed: $(printf '%s' "$observed" | tr '\n' ',' | sed 's/,$//')"
    echo "  bash -n:  $syntax"
  } >&2
  # 3 = rejected BY THE VECTOR COMPARISON. Distinct from 1 (anchor, application,
  # harness abort) so a self-check control can assert the rejection came from the
  # comparison it is testing. A control that only asserts "non-zero" passes when
  # the row was rejected for an unrelated reason, which is how a control ends up
  # certifying a comparison it never exercised.
  return 3
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
declare -a sole_hits=()
# Before the first row: the vectors were derived against a specific fixture set,
# so a changed set invalidates all of them at once. Stopping here is the point —
# a maintainer who reaches the rows reaches a table that no longer describes them.
mutation_pre_measurement_check "$manifest_root" "$fixtures_root" "T-ANDRIFT-" || exit 2

for d in "${mutations[@]}"; do
  # Schema before pins: a malformed corpus is a configuration error, and running
  # it anyway would report pin verdicts about rows that are not rows.
  mutation_row_schema_check "$d" || exit 2
  if run_mutation "$d" "$d/expected-red"; then
    passed=$((passed + 1))
    # Count off the SAME parse the comparator used. Reading the file again with
    # a different line rule is how this number moves without anything else
    # moving — and it is silent, because both the row and the run still pass.
    row_vector=$(mutation_row_declared_vector "$d")
    if [[ "$(mutation_row_declared_vector "$d" | grep -c . || true)" == "1" ]]; then
      sole_hits+=("$row_vector")
    fi
  else
    failures=$((failures + 1))
    failed_rows+=("$(basename "$d")")
  fi
done

if (( self_check == 1 )); then
  # Two controls, and both are EXPRESSIBLE — they name fixtures that exist. The
  # control this replaces named a fixture that does not, so the observed red set
  # was by construction a subset of the real ones and equality rejected it
  # without ever comparing anything the corpus can actually get wrong. That is
  # one bit of discriminating power, and it covers none of the corpus's real
  # failure modes.
  #
  # Rows are picked BY RED-SET SIZE, not by position: under-declaring is not
  # expressible on a singleton row, and a corpus whose first row is a singleton
  # would silently lose that half of the control.
  #
  # Both assert the rejection came from the VECTOR COMPARISON (rc 3), not merely
  # that something exited non-zero.
  ctl_multi=""; ctl_any="${mutations[0]}"
  for d in "${mutations[@]}"; do
    n=$(mutation_row_declared_vector "$d" | grep -c . || true)
    [[ -z "$ctl_multi" && "$n" -ge 2 ]] && ctl_multi="$d"
  done

  real_fixture=$(printf '%s\n' "$all_fixtures" | head -1)

  # (a) over-declaring: the row's own vector plus a real fixture it does not redden.
  {
    mutation_row_declared_vector "$ctl_any"
    printf '%s\n' "$all_fixtures" | grep -vxF -f <(mutation_row_declared_vector "$ctl_any") | head -1
  } > "$work/over-declared"
  set +e
  run_mutation "$ctl_any" "$work/over-declared" >/dev/null 2>&1; rc_over=$?
  set -e
  if [[ "$rc_over" == "3" ]]; then
    echo "PASS: self-check (a) — an over-declared vector is rejected by the comparison"
    passed=$((passed + 1))
  else
    echo "FAIL: self-check (a) — over-declared vector gave rc=$rc_over, wanted 3 (vector comparison)" >&2
    failures=$((failures + 1)); failed_rows+=("self-check(a)")
  fi

  # (b) under-declaring: a multi-fixture row with one member removed.
  if [[ -n "$ctl_multi" ]]; then
    mutation_row_declared_vector "$ctl_multi" | tail -n +2 > "$work/under-declared"
    set +e
    run_mutation "$ctl_multi" "$work/under-declared" >/dev/null 2>&1; rc_under=$?
    set -e
    if [[ "$rc_under" == "3" ]]; then
      echo "PASS: self-check (b) — an under-declared vector is rejected by the comparison"
      passed=$((passed + 1))
    else
      echo "FAIL: self-check (b) — under-declared vector gave rc=$rc_under, wanted 3 (vector comparison)" >&2
      failures=$((failures + 1)); failed_rows+=("self-check(b)")
    fi
  else
    # Stated, not skipped: a corpus with no multi-fixture row cannot express this
    # control, and silence would read as a control that ran.
    echo "NOTE: self-check (b) not expressible — no row declares two or more fixtures"
  fi
  : "$real_fixture"
fi

tracked_hash_after=$(hash_of "$lint")
if [[ "$tracked_hash_before" != "$tracked_hash_after" ]]; then
  echo "FAIL: the tracked lint changed while the harness ran — isolation did not hold" >&2
  echo "  before: $tracked_hash_before" >&2
  echo "  after:  $tracked_hash_after" >&2
  exit 2
fi

fixture_count=$(printf '%s\n' "$all_fixtures" | grep -c .)
sole_count=$(printf '%s\n' "${sole_hits[@]:-}" | sort -u | grep -c . || true)
echo "test-lint-active-notify-drift-mutations: $passed passed, $failures failed"
(( failures > 0 )) && echo "  failing row(s): ${failed_rows[*]:-<self-check>}"
echo "  ${#mutations[@]} mutation(s) over $fixture_count fixture(s); $sole_count fixture(s) are the sole killer of at least one"
echo "  tracked lint unchanged (sha256 ${tracked_hash_before:0:12})"

if (( failures > 0 )); then
  exit 1
fi
exit 0
