#!/usr/bin/env bash
# Test scripts/lint-active-notify-subcommands.sh against
# tests/fixtures/lint-active-notify-subcommands/.
#
# Each fixture is a PLUGIN_ROOT-shaped tree carrying a small three-subcommand
# dispatcher and the four surfaces the lint scans. Convention: the directory
# name encodes the expected exit code.
#   T-SUBCMD-OK-*   → expected exit 0
#   T-SUBCMD-FAIL-* → expected exit 1
#
# FAIL-2 is the one worth naming: its alternation lists exactly the right set of
# subcommands in the wrong order. A rule that compared sets rather than
# sequences would pass it, and the ordering is what makes the alternation a
# faithful mirror of the dispatcher rather than a coincidence of membership.
#
# Exit code 2 (dispatcher or declared surface missing, or the case block no
# longer readable) is not covered by a fixture: every fixture ships a readable
# dispatcher and all four surfaces on purpose, since a fixture missing one would
# test the guard by removing the thing every other assertion depends on.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-active-notify-subcommands"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-SUBCMD-OK-*)   want=0 ;;
    T-SUBCMD-FAIL-*) want=1 ;;
    *)
      echo "test-lint-active-notify-subcommands: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  PLUGIN_ROOT="${fixture}plugins/cc-cmds" \
    bash "$script_dir/lint-active-notify-subcommands.sh" >/dev/null 2>&1
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
