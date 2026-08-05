#!/usr/bin/env bash
# cancel fails OPEN, and its EXIT trap does not steal a lock it never acquired.
#
# Two properties, and the second is why the trap is gated on ownership. An
# unconditional `rmdir "$lockdir"` in the trap would release the FIXTURE's lock
# here — on precisely the path where cancel gave up waiting for it — handing a
# wedged holder's lock to whoever asks next.
#
# Fail-open is the deliberate trade: a flag that survives because a lock was
# busy keeps sending banners after the user asked to stop, which is worse than
# the microsecond-wide window that skipping the lock reopens.
set -euo pipefail

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

# Held for the whole call, so cancel exhausts its budget and takes the
# fail-open path.
bash "$NOTIFY_SH" cancel

[[ ! -f "$FLAG_FILE" ]] || { echo "fail-open cancel left the flag in place" >&2; exit 1; }
[[ -d "$lockdir" ]] || { echo "cancel stole the lock it never acquired" >&2; exit 1; }

rmdir "$lockdir"
