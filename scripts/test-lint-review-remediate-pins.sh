#!/usr/bin/env bash
# Test scripts/lint-review-remediate-pins.sh against
# tests/fixtures/lint-review-remediate-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory containing a review-remediate/
# tree. Convention: fixture directory name encodes the expected exit code.
#   T-RR-OK-*   → expected exit 0
#   T-RR-FAIL-* → expected exit 1
#
# The FAIL fixtures each break exactly one pin, so a pin that silently stops
# checking shows up as a fixture that turns green rather than as a lint that
# still exits 0 for the wrong reason.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-review-remediate-pins"

if [[ ! -d "$fixtures" ]]; then
  echo "test-lint-review-remediate-pins: fixtures directory missing: $fixtures" >&2
  exit 1
fi

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-RR-OK-*)   want=0 ;;
    T-RR-FAIL-*) want=1 ;;
    *)
      echo "test-lint-review-remediate-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-review-remediate-pins.sh" >/dev/null 2>&1
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

# A suite that ran zero fixtures is a green that proves nothing.
if (( passed + failures == 0 )); then
  echo "test-lint-review-remediate-pins: no fixtures found under $fixtures" >&2
  exit 1
fi

echo "test-lint-review-remediate-pins: $passed passed, $failures failed"
exit $(( failures > 0 ? 1 : 0 ))
