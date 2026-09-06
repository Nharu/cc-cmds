#!/usr/bin/env bash
# Test scripts/lint-watch-threshold-pins.sh against
# tests/fixtures/lint-watch-threshold-pins/.
#
# Each fixture is a self-contained pair of roots — `orchestrator/watch.sh` (the
# defaults' SOT) and `skills/autopilot/SKILL.md` (the document that pins them) —
# so the lint can be driven over a whole disagreement without touching the real
# tree. The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `FAIL-1-value-drift` is the fixture that earns its keep: it reproduces the
# failure the lint exists for, which is a default moving underneath a document
# that goes on stating the old number. That divergence is invisible until a
# night run behaves unlike its own contract, and every other check in the repo
# stays green through it.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-watch-threshold-pins"

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
      echo "test-lint-watch-threshold-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-watch-threshold-pins.sh" >/dev/null 2>&1
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

echo "test-lint-watch-threshold-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
