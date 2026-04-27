#!/usr/bin/env bash
# Test scripts/lint-skill-invariants.sh against tests/fixtures/lint-skill-invariants/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing skill subdirs with
# SKILL.md). Convention: fixture directory name encodes the expected exit code.
#   T-INV-OK-*   → expected exit 0
#   T-INV-FAIL-* → expected exit 1
#
# The test invokes the lint script with `SKILLS_ROOT=<fixture-dir>` so that
# both the position rule and the phrase-presence pair-resolution use the
# fixture as their skill root, leaving real plugin skills untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-skill-invariants"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-INV-OK-*)   want=0 ;;
    T-INV-FAIL-*) want=1 ;;
    *)
      echo "test-lint-skill-invariants: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-skill-invariants.sh" >/dev/null 2>&1
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

echo "test-lint-skill-invariants: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
