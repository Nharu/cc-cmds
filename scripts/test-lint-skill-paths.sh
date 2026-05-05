#!/usr/bin/env bash
# Test scripts/lint-skill-paths.sh against tests/fixtures/lint-skill-paths/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing skill subdirs
# with SKILL.md, optional `_common/` markdown, optional `<skill>/references/`
# markdown). Convention: fixture directory name encodes the expected exit code.
#   T-PATH-OK-*   → expected exit 0
#   T-PATH-FAIL-* → expected exit 1
#
# Exit-code 2 (no scannable files) is intentionally NOT covered by fixtures —
# the OK-fixture invariant in the design doc requires every fixture to ship
# at least one scannable file, so the empty-collection branch is tested by
# prevention rather than by an explicit empty fixture. Adding such a fixture
# would be rejected by this runner's `case` statement.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-skill-paths"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-PATH-OK-*)   want=0 ;;
    T-PATH-FAIL-*) want=1 ;;
    *)
      echo "test-lint-skill-paths: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-skill-paths.sh" >/dev/null 2>&1
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

echo "test-lint-skill-paths: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
