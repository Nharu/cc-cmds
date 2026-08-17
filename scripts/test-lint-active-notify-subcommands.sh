#!/usr/bin/env bash
# Test scripts/lint-active-notify-subcommands.sh against
# tests/fixtures/lint-active-notify-subcommands/.
#
# Each fixture is a PLUGIN_ROOT-shaped tree carrying a small three-subcommand
# dispatcher and the four surfaces the lint scans. Convention: the directory
# name encodes the expected exit code.
#   T-SUBCMD-OK-*   → expected exit 0
#   T-SUBCMD-FAIL-* → expected exit 1
#   T-SUBCMD-ERR-*  → expected exit 2
#
# FAIL-2 is the one worth naming: its alternation lists exactly the right set of
# subcommands in the wrong order. A rule that compared sets rather than
# sequences would pass it, and the ordering is what makes the alternation a
# faithful mirror of the dispatcher rather than a coincidence of membership.
#
# Exit 2 has two halves and they are not fixtured the same way. The MISSING-FILE
# half is deliberately left uncovered: a fixture that omits the dispatcher or a
# surface would test the guard by removing the thing every other assertion in
# the tree depends on. The UNREADABLE-CASE-BLOCK half needs no such removal —
# every T-SUBCMD-ERR-* fixture ships a readable file and all four surfaces, and
# breaks only the SHAPE the extractor reads. That half is where the silent-green
# escapes were, so that is the half carrying regression pressure.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-active-notify-subcommands"

# Which lint to exercise. An INPUT, so a mutation harness can point the suite
# at a scratch copy instead of writing the tracked file.
lint_sh="${CC_CMDS_SUBCMD_LINT_UNDER_TEST:-$script_dir/lint-active-notify-subcommands.sh}"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-SUBCMD-OK-*)   want=0 ;;
    T-SUBCMD-FAIL-*) want=1 ;;
    T-SUBCMD-ERR-*)  want=2 ;;
    *)
      echo "test-lint-active-notify-subcommands: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  PLUGIN_ROOT="${fixture}plugins/cc-cmds" \
    bash "$lint_sh" >/dev/null 2>&1
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

echo "test-lint-active-notify-subcommands: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
