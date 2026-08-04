#!/usr/bin/env bash
# Test scripts/lint-design-audit-pins.sh against
# tests/fixtures/lint-design-audit-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory containing a design-audit/
# tree. Convention: fixture directory name encodes the expected exit code.
#   T-AUDIT-OK-*   → expected exit 0
#   T-AUDIT-FAIL-* → expected exit 1
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-design-audit-pins"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-AUDIT-OK-*)   want=0 ;;
    T-AUDIT-FAIL-*) want=1 ;;
    *)
      echo "test-lint-design-audit-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-design-audit-pins.sh" >/dev/null 2>&1
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

echo "test-lint-design-audit-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
