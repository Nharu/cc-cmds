#!/usr/bin/env bash
# Test scripts/lint-team-model-tier-pins.sh against
# tests/fixtures/lint-team-model-tier-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory. Convention: the fixture
# directory name encodes the expected exit code.
#   T-TIER-OK-*   → expected exit 0
#   T-TIER-FAIL-* → expected exit 1
#
# OK-2 is the load-bearing one: it carries no tier file at all and asserts
# that the whole lint skips, so reverting the lever cannot turn `make check`
# red on its way back.
#
# The six FAIL fixtures are one per failure mode the lint claims to catch —
# a duplicated class row, a missing class row, a skill that stopped pointing
# at the tier file, a retired model-choice sentence coming back, and the
# report template carrying the record block zero or two times. Without one
# fixture each, a check that silently stopped firing would look identical to
# a tree with nothing wrong in it.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real
# plugin skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-team-model-tier-pins"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-TIER-OK-*)   want=0 ;;
    T-TIER-FAIL-*) want=1 ;;
    *)
      echo "test-lint-team-model-tier-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-team-model-tier-pins.sh" >/dev/null 2>&1
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

echo "test-lint-team-model-tier-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
