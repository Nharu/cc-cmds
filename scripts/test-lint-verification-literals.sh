#!/usr/bin/env bash
# Test scripts/lint-verification-literals.sh against
# tests/fixtures/lint-verification-literals/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing _common/ and
# implement/ as needed). The directory name encodes the expected exit code:
#   T-VERIF-OK-*   → expected exit 0
#   T-VERIF-FAIL-* → expected exit 1
#
# EXPECT — the declaration format, and the judgment that applies it, live in ONE
# place: `scripts/_expect-contract.sh`, sourced below. Read the contract there.
# It is not restated here, and the restatement is what was removed: five drivers
# carried a copy, one of the copies asserted that "three suites share one
# convention" while five did, and another had imported a neighbouring suite's
# measurements as if they described its own fixtures. A copy is a parity
# obligation; the invariant is that there are no copies.
#
# The OK fixture's EXPECT carries the lint's one-line arity summary, which names
# every pinned group's size; dropping any single pinned literal changes a number
# on that line and turns the fixture red.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./_expect-contract.sh
source "$script_dir/_expect-contract.sh"
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-verification-literals"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-VERIF-OK-*)   want=0 ;;
    T-VERIF-FAIL-*) want=1 ;;
    *)
      echo "test-lint-verification-literals: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  expect_file="$fixture/EXPECT"
  if [[ ! -f "$expect_file" ]]; then
    echo "FAIL: $fixture_name — no EXPECT file; a fixture must declare the diagnostic it proves" >&2
    failures=$((failures + 1))
    continue
  fi

  set +e
  output=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-verification-literals.sh" 2>&1)
  ec=$?
  set -e

  judge_fixture "$fixture_name" "$expect_file" "$want" "$ec" "$output"
done
echo "test-lint-verification-literals: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
