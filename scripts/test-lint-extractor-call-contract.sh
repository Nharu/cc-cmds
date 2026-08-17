#!/usr/bin/env bash
# Test scripts/lint-extractor-call-contract.sh against
# tests/fixtures/lint-extractor-call-contract/.
#
# Each fixture is a SCRIPTS_ROOT-shaped directory holding a consumer script and
# a copy of the helper. Convention: fixture directory name encodes the exit code.
#   T-EXTR-OK-*   → expected exit 0
#   T-EXTR-FAIL-* → expected exit 1
#
# The lint checks ONE property — that every `extract_between` call site is
# guarded by `if` on its own line — so the fixture set is one OK and one bare
# assignment. Breadth lives in the lint, which reads every call site in the
# tree uniformly; fixtures here only prove the reader works.
#
# EXPECT — the declaration format, and the judgment that applies it, live in ONE
# place: `scripts/_expect-contract.sh`, sourced below. Read the contract there.
# It is not restated here, and the restatement is what was removed: five drivers
# carried a copy, one of the copies asserted that "three suites share one
# convention" while five did, and another had imported a neighbouring suite's
# measurements as if they described its own fixtures. A copy is a parity
# obligation; the invariant is that there are no copies.
#
# The test invokes the lint with `SCRIPTS_ROOT=<fixture-dir>` so the real scripts
# directory is untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./_expect-contract.sh
source "$script_dir/_expect-contract.sh"
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-extractor-call-contract"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-EXTR-OK-*)   want=0 ;;
    T-EXTR-FAIL-*) want=1 ;;
    *)
      echo "test-lint-extractor-call-contract: fixture '$fixture_name' has unrecognized prefix" >&2
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
  output=$(SCRIPTS_ROOT="$fixture" bash "$script_dir/lint-extractor-call-contract.sh" 2>&1)
  ec=$?
  set -e

  judge_fixture "$fixture_name" "$expect_file" "$want" "$ec" "$output"
done
echo "test-lint-extractor-call-contract: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
