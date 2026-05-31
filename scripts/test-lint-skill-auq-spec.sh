#!/usr/bin/env bash
# Test scripts/lint-skill-auq-spec.sh against tests/fixtures/lint-skill-auq-spec/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (skill subdirs with SKILL.md,
# optional references/, optional _common/). Convention: fixture directory name
# encodes the expected exit code.
#   T-AUQ-OK-*   → expected exit 0
#   T-AUQ-FAIL-* → expected exit 1
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-skill-auq-spec"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-AUQ-OK-*)   want=0 ;;
    T-AUQ-FAIL-*) want=1 ;;
    *)
      echo "test-lint-skill-auq-spec: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-skill-auq-spec.sh" >/dev/null 2>&1
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

echo "test-lint-skill-auq-spec: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
