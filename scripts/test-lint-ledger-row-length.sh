#!/usr/bin/env bash
# Test scripts/lint-ledger-row-length.sh against
# tests/fixtures/lint-ledger-row-length/.
#
# Each fixture is a self-contained triple of roots — `orchestrator/gate.sh` (the
# cap SOT), `skills/_common/pipeline-sidecar.md` (the consumer contract), and an
# optional `ledger/` of run ledgers — so the lint can be exercised against a
# whole cap regime without touching the real tree. The directory name encodes
# the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#   ERR-*  → expected exit 2 (invalid invocation: the SOT itself is unusable)
#
# `OK-2-ledger-at-cap` and `FAIL-2-row-over-cap` are the pair that earns its
# keep: 1024 and 1025 bytes, the exact boundary two independent measurements put
# the corruption threshold at. An off-by-one in the byte accounting — forgetting
# that the newline occupies a byte on disk — flips exactly one of the two.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-ledger-row-length"

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
    ERR-*)  want=2 ;;
    *)
      echo "test-lint-ledger-row-length: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    LEDGER_ROOT="$fixture/ledger" \
    bash "$script_dir/lint-ledger-row-length.sh" >/dev/null 2>&1
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

echo "test-lint-ledger-row-length: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
