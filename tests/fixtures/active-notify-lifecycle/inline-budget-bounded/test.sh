#!/usr/bin/env bash
# The inline budget is separate from, and far smaller than, the fire budget.
#
# `cancel` runs inside the model's turn, so its worst case has to stay near a
# second while the fire branch's worst case is tens of seconds. Unifying the two
# has exactly one other symptom — a suite that runs a minute longer — and
# nothing else in the repo reads the clock, so this fixture is what makes that
# collapse visible.
#
# It deliberately does NOT shim the inline budget: there is no env override for
# it, and that absence is the point. A shimmable inline budget would let this
# fixture pass while measuring nothing, which is the failure mode the seam on
# the fire budget exists to avoid rather than to spread.
set -euo pipefail

# Shim the FIRE budget only. If the two budgets were ever unified, this shim
# would also shrink the inline path and the assertion below would stop meaning
# anything — so the fixture asserts the shim did not reach it.
export CC_CMDS_NOTIFY_LOCK_BUDGET_FIRE=100000

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

start=$(date +%s)
bash "$NOTIFY_SH" cancel
end=$(date +%s)
elapsed=$(( end - start ))

if (( elapsed >= 10 )); then
  echo "cancel took ${elapsed}s — the inline budget is not bounded separately from the fire budget" >&2
  exit 1
fi

# Fail-open: the user asked to stop, so the flag goes even though the lock was
# never acquired.
[[ ! -f "$FLAG_FILE" ]] || { echo "fail-open cancel left the flag in place" >&2; exit 1; }
[[ -d "$lockdir" ]] || { echo "cancel stole the lock it never acquired" >&2; exit 1; }

rmdir "$lockdir"
