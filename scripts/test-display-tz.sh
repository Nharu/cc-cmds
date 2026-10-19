#!/usr/bin/env bash
# Test `display-tz.sh`, the helper every autopilot surface uses to show a UTC
# instant in the display zone.
#
# THE ORACLE IS NOT THE HELPER'S OWN ARITHMETIC. Expected clock strings come
# from jq `strftime` over epoch + offset, so a slip in the civil-from-days
# arithmetic shows here instead of agreeing with itself.
#
# EVERY CASE SETS OR CLEARS `CC_CMDS_AUTOPILOT_TZ` ITSELF, so the suite says the
# same thing whatever the calling shell exports.
#
# Usage: bash scripts/test-display-tz.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
DTZ="$repo_root/plugins/cc-cmds/orchestrator/display-tz.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-display-tz-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
like() {
  if grep -qE -- "$3" <<EOF
$2
EOF
  then ok "$1"; else bad "$1" "'$2' 이 /$3/ 에 맞지 않음"; fi
}

# dtz <value|-> <shell body> — run the body after sourcing the helper and
# loading, with the variable set to <value>, or unset for `-`.
dtz() {
  local v="$1" b="$2"
  if [ "$v" = "-" ]; then
    env -u CC_CMDS_AUTOPILOT_TZ bash -c '. "$1" && cc_display_tz_load && '"$b" _ "$DTZ"
  else
    CC_CMDS_AUTOPILOT_TZ="$v" bash -c '. "$1" && cc_display_tz_load && '"$b" _ "$DTZ"
  fi
}
load() { dtz "$1" 'printf "%s/%s" "$CC_DTZ_OFF" "$CC_DTZ_LABEL"'; }
jq_fmt() { jq -rn --argjson e "$1" --arg f "$2" '$e | strftime($f)'; }

# ---------------------------------------------------------------------------
# 1. The interpretation table.
# ---------------------------------------------------------------------------
check "1 미설정 → KST" "$(load -)" "32400/KST"
check "1 빈 값 → KST" "$(load '')" "32400/KST"
for v in UTC utc Z z; do check "1 '$v' → UTC" "$(load "$v")" "0/UTC"; done
for v in +00:00 -00:00; do check "1 '$v' → UTC" "$(load "$v")" "0/UTC"; done
check "1 '+09:00' → KST" "$(load +09:00)" "32400/KST"
check "1 '-05:00' → UTC-05:00" "$(load -05:00)" "-18000/UTC-05:00"
check "1 '+05:30' → UTC+05:30" "$(load +05:30)" "19800/UTC+05:30"
check "1 '+14:00' 는 받는다" "$(load +14:00)" "50400/UTC+14:00"
check "1 '-12:00' 는 받는다" "$(load -12:00)" "-43200/UTC-12:00"
for v in +14:01 -12:01 +15:00 +9 +0900 Asia/Seoul ' +09:00' +09:60 'UTC ' '+09:00 '; do
  check "1 '$v' → KST (읽을 수 없는 값)" "$(load "$v")" "32400/KST"
done
check "1 읽을 수 없는 값은 경고를 내지 않는다" \
  "$(CC_CMDS_AUTOPILOT_TZ=Asia/Seoul bash -c '. "$1" && cc_display_tz_load' _ "$DTZ" 2>&1)" ""

# ---------------------------------------------------------------------------
# 2. Clock strings across a date boundary, against jq over epoch + offset.
# ---------------------------------------------------------------------------
e1=$(jq -rn '"2026-12-31T20:30:00Z" | fromdateiso8601')
e2=$(jq -rn '"2024-02-28T15:00:00Z" | fromdateiso8601')
check "2 2026-12-31T20:30Z KST hhmm (오라클)" "$(jq_fmt $((e1 + 32400)) '%H:%M')" "05:30"
check "2 2026-12-31T20:30Z KST hhmm" "$(dtz - "cc_display_hhmm $e1")" "$(jq_fmt $((e1 + 32400)) '%H:%M')"
check "2 2026-12-31T20:30Z KST mdhm (오라클)" "$(jq_fmt $((e1 + 32400)) '%m/%d %H:%M')" "01/01 05:30"
check "2 2026-12-31T20:30Z KST mdhm" "$(dtz - "cc_display_mdhm $e1")" "$(jq_fmt $((e1 + 32400)) '%m/%d %H:%M')"
check "2 2024-02-28T15:00Z KST mdhm (윤일, 오라클)" "$(jq_fmt $((e2 + 32400)) '%m/%d %H:%M')" "02/29 00:00"
check "2 2024-02-28T15:00Z KST mdhm (윤일)" "$(dtz - "cc_display_mdhm $e2")" "$(jq_fmt $((e2 + 32400)) '%m/%d %H:%M')"
check "2 UTC 이면 오프셋이 없다" "$(dtz UTC "cc_display_mdhm $e1")" "$(jq_fmt "$e1" '%m/%d %H:%M')"
# Behind UTC, the clock wraps backwards past midnight.
e3=$(jq -rn '"2026-10-12T03:07:00Z" | fromdateiso8601')
check "2 -05:00 은 자정 앞으로 감긴다 (hhmm)" "$(dtz -05:00 "cc_display_hhmm $e3")" "$(jq_fmt $((e3 - 18000)) '%H:%M')"
check "2 -05:00 은 자정 앞으로 감긴다 (mdhm)" "$(dtz -05:00 "cc_display_mdhm $e3")" "$(jq_fmt $((e3 - 18000)) '%m/%d %H:%M')"
check "2 +05:30 의 분" "$(dtz +05:30 "cc_display_hhmm $e3")" "$(jq_fmt $((e3 + 19800)) '%H:%M')"
# A spread of instants, including two in the 2100s and the days around leap days.
for iso in 2000-02-29T23:59:00Z 2024-03-01T00:00:00Z 2100-01-15T10:20:00Z 2100-07-15T10:20:00Z \
           2027-01-01T00:00:00Z 2025-12-31T14:59:00Z 2025-12-31T15:00:00Z; do
  e=$(jq -rn --arg s "$iso" '$s | fromdateiso8601')
  check "2 $iso KST mdhm" "$(dtz - "cc_display_mdhm $e")" "$(jq_fmt $((e + 32400)) '%m/%d %H:%M')"
done
check "2 숫자가 아닌 epoch 는 아무것도 내지 않는다" "$(dtz - 'cc_display_hhmm abc; cc_display_mdhm abc')" ""

# ---------------------------------------------------------------------------
# 3. cc_display_iso.
# ---------------------------------------------------------------------------
check "3 초 있는 ISO" "$(dtz - 'cc_display_iso 2026-10-12T03:07:59Z')" "2026-10-12 12:07 KST"
check "3 초 없는 ISO" "$(dtz - 'cc_display_iso 2026-10-12T03:07Z')" "2026-10-12 12:07 KST"
check "3 날짜를 넘긴다" "$(dtz - 'cc_display_iso 2026-12-31T20:30:00Z')" "2027-01-01 05:30 KST"
check "3 UTC 표기" "$(dtz UTC 'cc_display_iso 2026-10-12T03:07:59Z')" "2026-10-12 03:07 UTC"
check "3 -05:00 표기와 전날" "$(dtz -05:00 'cc_display_iso 2026-10-12T03:07:59Z')" "2026-10-11 22:07 UTC-05:00"
check "3 영역 +09:00 은 아무것도 내지 않는다" "$(dtz - 'cc_display_iso 2026-10-12T03:07:59+09:00')" ""
check "3 공백 꼴은 아무것도 내지 않는다" "$(dtz - 'cc_display_iso "2026-10-12 03:07"')" ""
check "3 빈 값은 아무것도 내지 않는다" "$(dtz - 'cc_display_iso ""')" ""
check "3 범위 밖 월은 아무것도 내지 않는다" "$(dtz - 'cc_display_iso 2026-13-12T03:07:59Z')" ""

# ---------------------------------------------------------------------------
# 4. Direct run and sourcing.
# ---------------------------------------------------------------------------
out=$(env -u CC_CMDS_AUTOPILOT_TZ bash "$DTZ" iso 2026-10-12T03:07:59Z); rc=$?
check "4 직접 실행 — 종료 코드 0" "$rc" "0"
check "4 직접 실행 — 한 줄" "$out" "2026-10-12 12:07 KST"
out=$(CC_CMDS_AUTOPILOT_TZ=UTC bash "$DTZ" iso 2026-10-12T03:07:59Z)
check "4 직접 실행 — 환경변수를 따른다" "$out" "2026-10-12 03:07 UTC"
out=$(env -u CC_CMDS_AUTOPILOT_TZ bash "$DTZ" iso 'not-a-time'); rc=$?
check "4 직접 실행 — 형식이 맞지 않으면 빈 출력" "$out" ""
check "4 직접 실행 — 형식이 맞지 않아도 0" "$rc" "0"
out=$(env -u CC_CMDS_AUTOPILOT_TZ bash -c 'set -u; . "$1"; echo "rc=$?"' _ "$DTZ" 2>&1)
check "4 소싱은 아무것도 출력하지 않는다 (set -u 아래)" "$out" "rc=0"
out=$(env -u CC_CMDS_AUTOPILOT_TZ bash -c 'set -u; . "$1"; cc_display_tz_load; cc_display_hhmm 0' _ "$DTZ" 2>&1)
check "4 set -u 아래에서 적재·변환이 돈다" "$out" "09:00"

# ---------------------------------------------------------------------------
# 5. The progress feed's line clock, on a one-row ledger the way the gate
# suite's feed check drives it: a first pass sets the cursor, then each appended
# `stage-result` row is one line.
# ---------------------------------------------------------------------------
FEED="$repo_root/plugins/cc-cmds/orchestrator/feed.sh"
fd="$WORK/feed"; mkdir -p "$fd"
fl="$fd/ledger.md"
printf '%s\n' '- `segment` | 교대=0 | id=S1 | 상태=실행중 | prev=0' > "$fl"
feed_once() { bash "$FEED" --run-dir "$fd" --ledger "$fl" --once --stall 1200 2>&1; }
sr_row() {
  printf '%s\n' "- \`stage-result\` | 교대=0 | 세그먼트=S1 | 스테이지=S1#$1 | 종류=implement | 종료 코드=0 | 종단 부류=정상 | 기록자=게이트 | prev=0" >> "$fl"
}
env -u CC_CMDS_AUTOPILOT_TZ bash "$FEED" --run-dir "$fd" --ledger "$fl" --once --stall 1200 >/dev/null 2>&1
sr_row 1
line=$(env -u CC_CMDS_AUTOPILOT_TZ bash "$FEED" --run-dir "$fd" --ledger "$fl" --once --stall 1200 2>&1 \
         | grep -F '스테이지 S1#1 종단' || true)
[ -n "$line" ] && ok "5 진행 채널이 stage-result 행에 한 줄을 낸다 (전제)" \
  || bad "5 진행 채널" "stage-result 행에 줄이 없다"
like "5 기본 줄머리는 [HH:MM KST]" "$line" '^\[[0-2][0-9]:[0-5][0-9] KST\] '
sr_row 2
line=$(CC_CMDS_AUTOPILOT_TZ=UTC feed_once | grep -F '스테이지 S1#2 종단' || true)
like "5 UTC 이면 줄머리는 [HH:MM UTC]" "$line" '^\[[0-2][0-9]:[0-5][0-9] UTC\] '
sr_row 3
line=$(CC_CMDS_AUTOPILOT_TZ=-05:00 feed_once | grep -F '스테이지 S1#3 종단' || true)
like "5 -05:00 이면 줄머리는 [HH:MM UTC-05:00]" "$line" '^\[[0-2][0-9]:[0-5][0-9] UTC-05:00\] '
like "5 심장 박동 파일은 UTC ISO 그대로다" "$(cat "$fd/feed.heartbeat" 2>/dev/null)" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
