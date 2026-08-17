#!/usr/bin/env bash
# cancel participates in the fire branch's lock.
#
# Ordering is forced by the lock itself, not by sleep timing: the fixture takes
# ${FLAG_FILE}.lockdir and holds it, so cancel cannot proceed until it is
# released. A cancel that ignores the lock deletes the flag at once and is
# caught at the first observation; a cancel that takes it leaves the flag in
# place while it waits. That is the whole difference this test exists to pin.
#
# Before the fix, cancel's `rm -f` could land between the fire branch's read of
# the flag and its trailing `mv`, so the `mv` wrote the flag back and the next
# fire-now dispatched a banner the user had already cancelled.
set -euo pipefail

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

bash "$NOTIFY_SH" cancel &
cancel_pid=$!

# Well inside cancel's inline budget, well past the ~5ms an unlocked cancel
# needs to finish.
sleep 0.2

if [[ ! -f "$FLAG_FILE" ]]; then
  echo "cancel deleted the flag while the lock was held by someone else" >&2
  kill "$cancel_pid" 2>/dev/null || true
  exit 1
fi

rmdir "$lockdir"
wait "$cancel_pid"

[[ ! -f "$FLAG_FILE" ]] || { echo "cancel did not delete the flag after the lock was released" >&2; exit 1; }
[[ ! -d "$lockdir" ]] || { echo "cancel leaked the lockdir it acquired" >&2; exit 1; }
