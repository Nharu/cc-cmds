#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-cutpoint-vocabulary.sh against
# tests/fixtures/lint-cutpoint-vocabulary/.
#
# Each fixture is a self-contained pair of roots — `orchestrator/run.sh` (the
# vocabulary SOT) and `skills/…` (the consumer documents) — so the lint can be
# exercised against a whole vocabulary without touching the real tree. The
# directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `FAIL-2-ladder-drift` is the fixture that earns its keep: it reproduces the
# shipped defect exactly — a consumer document rendering the STORED TOKEN where
# the DISPLAY FORM belongs. That drift denied every act at runtime while every
# check in the repo stayed green.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-cutpoint-vocabulary"

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
      echo "test-lint-cutpoint-vocabulary: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-cutpoint-vocabulary.sh" >/dev/null 2>&1
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

echo "test-lint-cutpoint-vocabulary: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
