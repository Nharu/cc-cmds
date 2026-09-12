#!/usr/bin/env bash
# lint-approval-answer-provenance: self-skip
# Test scripts/lint-approval-answer-provenance.sh against
# tests/fixtures/lint-approval-answer-provenance/cases/.
#
# Each case is a fixture root of its own — `ledgers/*.md` (the authoritative
# input), an optional `exempt-at-landing.txt`, and an optional `scan/` tree
# whose `docs/pipeline-run/` stands in for the local corpus. The directory name
# encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `OK-2` is the false-positive guard: a closing row whose answer QUOTES an
# envelope is not a row that recorded one, and a substring count reports it.
# `OK-3` and `FAIL-2` are the secondary diagnostic's two halves — a landing-time
# file carrying envelopes is exempt, a later file carrying one is not.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-approval-answer-provenance/cases"

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
      echo "test-lint-approval-answer-provenance: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  FIXTURE_ROOT="$fixture" SCAN_ROOT="$fixture/scan" \
    bash "$script_dir/lint-approval-answer-provenance.sh" >/dev/null 2>&1
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

echo "test-lint-approval-answer-provenance: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
