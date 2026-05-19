#!/usr/bin/env bash
# ARM(single) + FIRE on non-Darwin host → silent-skip branch:
#   - terminal-notifier stub NOT invoked (notifier log absent).
#   - Flag IS consumed (single-mode 1-shot intent: mv -n + rm cleanup).
#   - Lockdir does not leak.
set -euo pipefail

bash "$NOTIFY_SH" arm "build done" "build"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" fire "build" "성공"

[[ ! -f "$NOTIFIER_LOG" ]] || {
  echo "FAIL: silent-skip 분기에서 notifier stub 이 호출됨 ($NOTIFIER_LOG 존재)" >&2
  exit 1
}
[[ ! -f "$FLAG_FILE" ]] || {
  echo "FAIL: single-mode silent-skip 도 flag 를 consume 해야 함 (mv -n + rm cleanup)" >&2
  exit 1
}
[[ ! -d "${FLAG_FILE}.lockdir" ]] || {
  echo "FAIL: lockdir leak (${FLAG_FILE}.lockdir 잔존)" >&2
  exit 1
}
