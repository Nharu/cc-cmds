#!/usr/bin/env bash
# Test scripts/lint-sidecar-schema.sh against
# tests/fixtures/lint-sidecar-schema/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing _common/ as
# needed). Convention: fixture directory name encodes the expected exit code.
#   T-SIDECAR-OK-*   → expected exit 0
#   T-SIDECAR-FAIL-* → expected exit 1
#
# The four FAIL fixtures are the four ways this pin is known to be defeatable:
# an undeclared terminator (the pre-fix state), a crosswired one, one that is
# only shown inside a fence, and a schema with no machine header. The pin's
# discriminating power is exactly the set of fixtures here.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-sidecar-schema"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-SIDECAR-OK-*)   want=0 ;;
    T-SIDECAR-FAIL-*) want=1 ;;
    *)
      echo "test-lint-sidecar-schema: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-sidecar-schema.sh" >/dev/null 2>&1
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

echo "test-lint-sidecar-schema: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
