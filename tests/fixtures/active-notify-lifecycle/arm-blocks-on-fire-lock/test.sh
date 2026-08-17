#!/usr/bin/env bash
# arm participates in the fire branch's lock.
#
# Same lock-forced ordering as the cancel case. The scenario is a re-ARM that
# NARROWS the cycle (repeat → single): before the fix it could land between the
# fire branch's read and its `mv`, and the `mv` then restored the wider mode the
# user had just replaced — the cycle silently went back to firing unbounded.
set -euo pipefail

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "ARM: initial mode not repeat" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

bash "$NOTIFY_SH" arm "빌드 끝나면 알림" "build" "single" --count=1 &
arm_pid=$!

sleep 0.2

if ! grep -q '"mode":"repeat"' "$FLAG_FILE"; then
  echo "re-ARM rewrote the flag while the lock was held by someone else" >&2
  kill "$arm_pid" 2>/dev/null || true
  exit 1
fi

rmdir "$lockdir"
wait "$arm_pid"

grep -q '"mode":"single"' "$FLAG_FILE" || { echo "re-ARM did not land after the lock was released" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "re-ARM lost --count=1" >&2; exit 1; }
[[ ! -d "$lockdir" ]] || { echo "arm leaked the lockdir it acquired" >&2; exit 1; }
