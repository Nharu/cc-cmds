#!/usr/bin/env bash
# Test scripts/lint-sidecar-schema.sh against
# tests/fixtures/lint-sidecar-schema/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing _common/ as
# needed). Convention: fixture directory name encodes the expected exit code.
#   T-SIDECAR-OK-*   → expected exit 0
#   T-SIDECAR-FAIL-* → expected exit 1
#
# The FAIL fixtures are the ways this pin is known to be defeatable: an
# undeclared terminator (the pre-fix state), a crosswired one, one that is only
# shown inside a fence, a schema with no machine header, one whose header
# survives only as prose about a header, and a §1.3 whose truncation check has
# been hoisted ahead of the version guard. The pin's discriminating power is
# exactly the set of fixtures here.
#
# EXPECT — the declaration format, and the judgment that applies it, live in ONE
# place: `scripts/_expect-contract.sh`, sourced below. Read the contract there.
# It is not restated here, and the restatement is what was removed: five drivers
# carried a copy, one of the copies asserted that "three suites share one
# convention" while five did, and another had imported a neighbouring suite's
# measurements as if they described its own fixtures. A copy is a parity
# obligation; the invariant is that there are no copies.
#
# This driver had none of the above until it was measured: it discarded the
# lint's output entirely and checked only the exit code, so four of six
# assertion-deleting mutants survived with the whole suite green.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./_expect-contract.sh
source "$script_dir/_expect-contract.sh"
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

  expect_file="$fixture/EXPECT"
  if [[ ! -f "$expect_file" ]]; then
    echo "FAIL: $fixture_name — no EXPECT file; a fixture must declare the diagnostic it proves" >&2
    failures=$((failures + 1))
    continue
  fi

  set +e
  output=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-sidecar-schema.sh" 2>&1)
  ec=$?
  set -e

  judge_fixture "$fixture_name" "$expect_file" "$want" "$ec" "$output"
done
echo "test-lint-sidecar-schema: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
