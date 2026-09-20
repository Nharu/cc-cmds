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
# The nine FAIL fixtures are one per failure mode the lint claims to catch —
# a duplicated class row, a missing class row, a class bound to the wrong
# model, a skill that stopped pointing at the tier file, each of the three
# retired model-choice sentences coming back, and the report template
# carrying the record block zero or two times. Without one fixture each, a
# check that silently stopped firing would look identical to a tree with
# nothing wrong in it.
#
# FAIL-4, FAIL-8 and FAIL-9 plant one retired sentence each, so every phrase
# in the lint's array has a fixture that turns red only through it. Between
# them FAIL-4 and FAIL-8 also cover the fence's two `find` branches (a skill's
# own `*.md` at depth 2, a `references/*.md` at depth 3), which keeps either
# branch from being deleted unnoticed. Planting a second sentence in FAIL-4
# instead would have traded one blind spot for the other — that fixture
# already fails at depth 2, so a further hit would change nothing about its
# exit code.
#
# The exit code alone cannot see a check that stopped running: every fixture
# keeps its expected code when a class row, a bound skill or a fence branch
# is dropped from the lint. The banner's check COUNT is what notices, so
# T-TIER-OK-1 asserts it. The count sees a phrase deleted from the array but
# not a phrase left in place with its wording broken; the per-phrase fixtures
# are what catch that.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real
# plugin skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-team-model-tier-pins"

# What a whole tree costs the lint: 13 class ids × (row + model) + 4 bound
# skills + 3 fence phrases + 1 template block. Update this deliberately when a
# check is added; a drop means one stopped running.
OK1_EXPECTED_CHECKS=34

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
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-team-model-tier-pins.sh" 2>&1)
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi

  # The intact tree is the only fixture that reaches every check, so it is the
  # only one whose count is meaningful.
  if [[ "$fixture_name" == "T-TIER-OK-1" ]]; then
    if printf '%s\n' "$out" | grep -qF -- "$OK1_EXPECTED_CHECKS check(s) intact"; then
      passed=$((passed + 1))
      echo "PASS: $fixture_name banner (checks=$OK1_EXPECTED_CHECKS)"
    else
      failures=$((failures + 1))
      echo "FAIL: $fixture_name banner — expected '$OK1_EXPECTED_CHECKS check(s) intact', got: $out" >&2
    fi
  fi
done

echo "test-lint-team-model-tier-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
