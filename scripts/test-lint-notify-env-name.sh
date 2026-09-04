#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-notify-env-name.sh against
# tests/fixtures/lint-notify-env-name/.
#
# Each fixture is a self-contained pair of roots — `orchestrator/notify-run.sh`
# (the code that reads the kill switch) and `skills/autopilot/SKILL.md` (the
# prose that tells a user what to type) — so the lint can be driven against a
# whole name pairing without touching the real tree. The directory name encodes
# the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# `FAIL-name-drift` is the fixture that earns its keep: the emitter reads one
# name and the kickoff sentence tells the user another. That drift is invisible
# at runtime — the user sets a variable nothing reads, the banners keep arriving,
# and the value can only be chosen before the run starts, so there is no later
# moment at which anyone could notice.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-notify-env-name"

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
      echo "test-lint-notify-env-name: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  ORCH_ROOT="$fixture/orchestrator" SKILLS_ROOT="$fixture/skills" \
    bash "$script_dir/lint-notify-env-name.sh" >/dev/null 2>&1
  ec=$?

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

echo "test-lint-notify-env-name: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
