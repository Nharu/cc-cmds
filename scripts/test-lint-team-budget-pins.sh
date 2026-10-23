#!/usr/bin/env bash
# Test scripts/lint-team-budget-pins.sh against
# tests/fixtures/lint-team-budget-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory. Convention: the fixture
# directory name encodes the expected exit code.
#   T-BUDGET-OK-*   → expected exit 0
#   T-BUDGET-FAIL-* → expected exit 1
#
# The two revert fixtures (OK-2, OK-3) are the load-bearing ones: they assert
# that removing a lever's section leaves the lint green, so `git revert` of a
# single lever cannot turn `make check` red on its way back.
#
# OK-4 and FAIL-7 are the design small-work gate's pair, and they are a pair on
# purpose. Every other fixture omits `design/SKILL.md` entirely, so the design
# lever is skipped for file absence and its two states were never exercised.
# FAIL-7 carries the gate heading with the floor sentence deleted (the lever
# fires, the pin is gone → red); OK-4 carries a `design/SKILL.md` that has no
# gate heading at all (the lever is skipped → green). Only the second one
# distinguishes "heading reverted" from "file absent", which is the distinction
# the lever's skip-if-absent posture rests on.
#
# OK-5, FAIL-8, FAIL-9 and FAIL-10 cover the by-path relay and the dispatch
# ordering. OK-5 carries the protocol's `### Dispatch latency` and
# `### Dispatch kinds and witness keys` sections with all ten pinned literals,
# the two relay sentences, and consumer lines that hand peer witnesses over by
# path (→ green). FAIL-8, FAIL-9 and FAIL-10 are OK-5 with one change each, so
# they fail only on the defect they target: FAIL-8 puts a verbatim-quote line
# inside review-lite's `#### Round structure` section, the range the budget
# fence exempts and the relay fence must not; FAIL-9 drops the
# no-boundary-batching literal from `### Dispatch latency`; FAIL-10 drops the
# no-send-in-the-nonce-response literal from `### Dispatch kinds and witness
# keys`. Every older fixture carries the two relay sentences too, because those
# checks run whenever the protocol file exists — without them each FAIL case
# would go red for a reason unrelated to its own defect and rule nothing out.
#
# OK-6 and FAIL-11 cover the re-entry notes parameter. OK-6 adds the protocol's
# `### Parameter — re-entry notes (opt-in)` section with its fenced clause, and
# each opted-in skill the fixture carries (design-lite, review, review-lite)
# attaches that clause once (→ green). FAIL-11 is OK-6 with review-lite's
# attachment removed, so the per-skill count reads 0 (→ red).
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-team-budget-pins"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-BUDGET-OK-*)   want=0 ;;
    T-BUDGET-FAIL-*) want=1 ;;
    *)
      echo "test-lint-team-budget-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-team-budget-pins.sh" >/dev/null 2>&1
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

echo "test-lint-team-budget-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
