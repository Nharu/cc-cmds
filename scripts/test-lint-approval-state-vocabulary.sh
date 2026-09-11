#!/usr/bin/env bash
# lint-approval-state-vocabulary: self-skip
# Test scripts/lint-approval-state-vocabulary.sh against
# tests/fixtures/lint-approval-state-vocabulary/.
#
# Each fixture is a self-contained triple of roots — `orchestrator/` (gate.sh,
# the vocabulary SOT), `scan/` (the tree whose `상태=` literals are compared)
# and `skills/` (the contract whose vocabulary row is compared) — so the lint
# is exercised against a whole vocabulary without touching the real one. The
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The three rules fail in three different places, and one fixture per rule is
# what keeps a broken extraction from leaving all of them green: `FAIL-1` and
# `FAIL-2` are the count (five and seven), `FAIL-3` is the count right and the
# token wrong, `FAIL-4` is the contract row drifting from the SOT, `FAIL-5` is a
# literal in an approval-row context. `OK-2` is the false-positive guard — the
# metasyntactic shapes a real tree contains must not be read as value claims.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-approval-state-vocabulary"

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
      echo "test-lint-approval-state-vocabulary: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SCAN_ROOT="$fixture/scan" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-approval-state-vocabulary.sh" >/dev/null 2>&1
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

echo "test-lint-approval-state-vocabulary: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
