#!/usr/bin/env bash
# Test scripts/lint-kickoff-recommendations.sh against
# tests/fixtures/lint-kickoff-recommendations/.
#
# Each fixture is a miniature skills root — `autopilot/SKILL.md` and
# `autopilot/references/boundaries.md` — with its own `entry-plan.schema.json`,
# so every rule can be exercised without touching the real tree. The directory
# name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `OK-1-sourced-lines` is the fixture that earns its keep. It holds the lines a
# careless detector gets wrong: a marker named in prose behind a backquote
# (not a marker), two markers of one key on one line with two judgment tokens,
# a judgment and a default marker on one line, and a judgment token on a line
# with no marker. Each FAIL fixture keeps its other file clean, so it fails for
# the one violation its name gives.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-kickoff-recommendations"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *)
      echo "test-lint-kickoff-recommendations: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" ENTRY_PLAN_SCHEMA="$fixture/entry-plan.schema.json" \
    bash "$script_dir/lint-kickoff-recommendations.sh" >/dev/null 2>&1
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

echo "test-lint-kickoff-recommendations: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
