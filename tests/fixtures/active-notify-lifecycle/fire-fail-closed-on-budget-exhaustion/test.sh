#!/usr/bin/env bash
# The fire branch fails CLOSED when it cannot take the lock.
#
# `arm` and `cancel` fail OPEN on budget exhaustion — they run inline in the
# model's turn and a stall there is worse than the narrow race. `fire-now` is
# the opposite: it can afford to wait, and a fire that proceeds without the lock
# would race the read-modify-write it is supposed to serialize. This fixture is
# the only thing asserting that asymmetry; flipping the fire branch to fail-open
# leaves every other fixture green.
#
# The wall-clock assertion is load-bearing, not decoration. Without the budget
# shim this scenario costs ~42 s, and with the shim ~0.05 s — but a run that
# ignored the shim would still be GREEN and merely 800× slower, so nothing would
# notice the seam being removed. Asserting the clock is what makes the seam
# visible to CI.
set -euo pipefail

export CC_CMDS_NOTIFY_LOCK_BUDGET_FIRE=5

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

before="${TMPDIR}/flag.before"
cp "$FLAG_FILE" "$before"

start=$(date +%s)
bash "$NOTIFY_SH" fire-now "build" "성공"
rc=$?
end=$(date +%s)

[[ "$rc" == "0" ]] || { echo "fire-now must exit 0 even when it skips" >&2; exit 1; }

# Fail-closed: no banner, and the flag is untouched.
if [[ -s "${NOTIFIER_LOG:-/dev/null}" ]]; then
  echo "fire-now dispatched a banner without holding the lock" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi
cmp -s "$before" "$FLAG_FILE" || {
  echo "fire-now mutated the flag without holding the lock" >&2
  exit 1
}

# The holder's lock must survive — the gated EXIT trap must not remove a lock
# this call never acquired.
[[ -d "$lockdir" ]] || { echo "fire-now stole the lock it never acquired" >&2; exit 1; }

elapsed=$(( end - start ))
if (( elapsed > 10 )); then
  echo "fire-now took ${elapsed}s — the CC_CMDS_NOTIFY_LOCK_BUDGET_FIRE seam was not honored" >&2
  exit 1
fi

rmdir "$lockdir"
