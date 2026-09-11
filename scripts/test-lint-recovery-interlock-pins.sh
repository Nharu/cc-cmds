#!/usr/bin/env bash
# Test scripts/lint-recovery-interlock-pins.sh against
# tests/fixtures/lint-recovery-interlock-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory. Convention: the fixture
# directory name encodes the expected exit code.
#   T-RECOV-OK-*   → expected exit 0
#   T-RECOV-FAIL-* → expected exit 1
#
# Four fixtures are load-bearing rather than illustrative. OK-2 states the same
# contract with every clause wrapped across several lines: it is green only
# because the lint folds a paragraph before comparing, so it is the control
# that keeps the fold from being deleted as decoration. The other three fix the
# boundary between a revert and a retitle from three sides, and none of them is
# redundant given the other two. OK-3 removes the interlock sections altogether
# — headings and clauses alike — and must stay green, so reverting the feature
# does not have to fight `make check` on its way back. FAIL-5 is OK-1 with one
# anchor heading retitled and nothing else touched, which is what the
# all-or-nothing anchor gate catches. FAIL-6 is OK-1 with all three anchor
# headings retitled and nothing else touched: the partial gate passes on it
# because no anchor is missing relative to the others, so without it a wholesale
# retitle would skip every block and report success for exactly the rewrite
# being guarded against.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-recovery-interlock-pins"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-RECOV-OK-*)   want=0 ;;
    T-RECOV-FAIL-*) want=1 ;;
    *)
      echo "test-lint-recovery-interlock-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-recovery-interlock-pins.sh" >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

echo "test-lint-recovery-interlock-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
