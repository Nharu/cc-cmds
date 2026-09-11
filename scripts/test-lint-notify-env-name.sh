#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test scripts/lint-notify-env-name.sh against
# tests/fixtures/lint-notify-env-name/.
#
# Each fixture is a self-contained set of THREE roots — `orchestrator/notify-run.sh`
# (the code that reads the switches), `skills/autopilot/SKILL.md` (the prose that
# tells a user what to type for the unattended banners) and `hooks/README.md`
# (the same for the session banners) — so the lint can be driven against a whole
# name pairing without touching the real tree. The third root is not decoration:
# without it a fixture run resolves the seat contract against the REAL repo, and
# every fixture is then measured partly against the tree it is isolated from.
# The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# The two FAIL fixtures fail on different rules, and neither substitutes for the
# other:
#
# `FAIL-name-drift` — the emitter reads one name and the kickoff sentence tells
# the user another. That drift is invisible at runtime: the user sets a variable
# nothing reads, the banners keep arriving, and the value can only be chosen
# before the run starts, so there is no later moment at which anyone could
# notice. Its seat contract is deliberately correct, so the failure can only have
# come from the document that actually drifted.
#
# `FAIL-unregistered-switch` — the emitter reads a third `CC_CMDS_` name that no
# document announces. Both prose documents are consistent, so rules 2 and 3 pass
# and only the set rule can catch it. This shape was UNEXPRESSIBLE while rule 1
# counted to one, which is the whole reason it counts against a registered set
# now.

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
    HOOKS_ROOT="$fixture/hooks" \
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
