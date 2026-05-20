#!/usr/bin/env bash
# ARM(repeat) + fire-now on non-Darwin host → silent-skip branch:
#   - terminal-notifier stub NOT invoked.
#   - Flag IS preserved (repeat-mode: user may retry from Darwin host later).
#   - fire_count remains 0, last_fire_at remains null (no mutation).
#   - Lockdir does not leak.
set -euo pipefail

bash "$NOTIFY_SH" arm "iter" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
flag_before=$(cat "$FLAG_FILE")

bash "$NOTIFY_SH" fire-now "iter" "ping"

[[ ! -f "$NOTIFIER_LOG" ]] || {
  echo "FAIL: silent-skip 분기에서 notifier stub 이 호출됨" >&2
  exit 1
}
[[ -f "$FLAG_FILE" ]] || {
  echo "FAIL: repeat-mode silent-skip 은 flag 를 보존해야 함" >&2
  exit 1
}
flag_after=$(cat "$FLAG_FILE")
[[ "$flag_before" == "$flag_after" ]] || {
  echo "FAIL: silent-skip 중 flag content 가 mutate 됨" >&2
  diff <(echo "$flag_before") <(echo "$flag_after") >&2
  exit 1
}
grep -q '"fire_count":0' "$FLAG_FILE" || {
  echo "FAIL: fire_count 가 0 에서 변경됨" >&2
  cat "$FLAG_FILE" >&2
  exit 1
}
grep -q '"last_fire_at":null' "$FLAG_FILE" || {
  echo "FAIL: last_fire_at 이 null 에서 변경됨" >&2
  cat "$FLAG_FILE" >&2
  exit 1
}
[[ ! -d "${FLAG_FILE}.lockdir" ]] || {
  echo "FAIL: lockdir leak (${FLAG_FILE}.lockdir 잔존)" >&2
  exit 1
}
