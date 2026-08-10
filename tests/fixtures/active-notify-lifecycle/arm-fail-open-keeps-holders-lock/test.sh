#!/usr/bin/env bash
# `arm` fails OPEN, writes its flag, and does not take the holder's lock with it.
#
# The mirror of `cancel-fail-open-keeps-holders-lock`. Both inline callers give
# up on the lock after the same small budget and proceed anyway, and both must
# leave a lock they never acquired exactly where they found it — an
# unconditional `rmdir` in the EXIT trap would hand a wedged holder's lock to
# whoever asks next.
#
# The write itself is staged and renamed, so a reader that catches this moment
# sees the old flag or the new one and never a zero-length file. Asserted here
# by requiring the flag to be complete after the call and no staging file to
# survive it.
set -euo pipefail

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "ARM: initial mode not repeat" >&2; exit 1; }

lockdir="${FLAG_FILE}.lockdir"
mkdir "$lockdir" || { echo "fixture could not take the lock" >&2; exit 1; }

# Held for the whole call, so arm exhausts its budget and takes the fail-open path.
bash "$NOTIFY_SH" arm "빌드 끝나면 알림" "build" "single" --count=1

grep -q '"mode":"single"' "$FLAG_FILE" || { echo "fail-open arm did not write the new cycle" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "fail-open arm lost --count=1" >&2; exit 1; }
grep -q '"schema":3' "$FLAG_FILE" || { echo "flag is not a complete schema:3 record" >&2; exit 1; }

[[ -d "$lockdir" ]] || { echo "arm stole the lock it never acquired" >&2; exit 1; }

leftover=$(find "$FLAG_DIR" -name '*.tmp-*' 2>/dev/null | head -1)
[[ -z "$leftover" ]] || { echo "arm left a staging file behind: $leftover" >&2; exit 1; }

rmdir "$lockdir"
