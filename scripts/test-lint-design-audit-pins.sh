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
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-design-audit-pins.sh" 2>&1)
  ec=$?
  set -e

  # An OK fixture must also reach the lint's success banner, so a run that
  # exits 0 without checking anything (e.g. the skill-absent skip) does not
  # count. The lint prints no failure banner, so FAIL fixtures are judged on
  # the exit code alone. A string match, not a pipe into `grep -q`, so an early
  # exit cannot SIGPIPE the writer and invert the result under `pipefail`.
  has_banner=1
  if [[ "$want" == 0 && $'\n'"$out" != *$'\n''OK:   design-audit pins'* ]]; then
    has_banner=0
  fi

  if [[ "$ec" == "$want" && "$has_banner" == 1 ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  elif [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec as expected, but the 'OK:   design-audit pins' banner is missing)" >&2
  fi
done

echo "test-lint-design-audit-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
