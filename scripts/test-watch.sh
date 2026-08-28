#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the liveness watcher's three arms.
#
# The watcher exists for one failure the rest of the system cannot see: the
# router quietly stopping. Nothing crashes, no rule refuses, and a terminal that
# was going to be quiet stays quiet — so the only evidence would be a person
# noticing hours later. Everything asserted here is about making that visible
# WITHOUT making it a decision: the watcher resumes nothing.
#
# The three arms are not variations of one condition:
#   stalled          — nothing happening and nothing waiting
#   finished-for-now — every segment waiting or terminal; the run is done until
#                      a person touches it, which is different from stuck
#   heartbeat        — alive. Without it, silence from a dead watcher and
#                      silence from a healthy run are the same observation.
#
# Usage: bash scripts/test-watch.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
WATCH="$repo_root/plugins/cc-cmds/orchestrator/watch.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-watch-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# `grep -q` on the right of a pipe exits as soon as it matches, which kills the
# writer with SIGPIPE — and under `pipefail` the whole pipeline then reports
# failure even though the match was found. GNU sed makes it loud ("couldn't
# flush stdout: Broken pipe") and BSD sed usually does not, so this failed only
# on the Linux leg and only once a scanned function grew long enough for the
# race to be real.
#
# `grep -c` has the same truth value and consumes its input to the end, so the
# writer never sees a closed pipe. The count goes to /dev/null; only the exit
# status is wanted.
grep_all_q() {
  # The count is CAPTURED, not redirected to /dev/null: BSD grep short-circuits
  # when its output is being discarded, which reintroduces the very SIGPIPE this
  # helper exists to avoid. Measured — `sed … | grep -c … >/dev/null` returns
  # 141 while `n=$(grep -c …)` returns 0.
  local n
  n=$(grep -c "$@" || true)
  [ "${n:-0}" != "0" ]
}

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

n=0
fresh() {
  # A new run directory and ledger per case — the watcher keeps state on disk on
  # purpose (that is what makes `--once` meaningful across invocations), so
  # sharing one directory would leak a case into the next.
  n=$((n + 1))
  RD="$WORK/run$n"; LG="$WORK/ledger$n.md"
  mkdir -p "$RD"; : > "$LG"
}
run() { bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" 2>&1; }

# ---------------------------------------------------------------------------
# 1. Heartbeat
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
out=$(run)
case "$out" in
  *"[watch] 살아 있음"*) ok "긍정 하트비트를 낸다 (침묵이 진단 가치를 갖는다)" ;;
  *) bad "하트비트" "'$out'" ;;
esac
case "$out" in
  *"비종단 세그먼트 1개"*) ok "하트비트가 관측값을 함께 싣는다" ;;
  *) bad "하트비트 내용" "'$out'" ;;
esac

# ---------------------------------------------------------------------------
# 2. Stalled — nothing happening and nothing waiting
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
run --stall 0 >/dev/null
out=$(run --stall 0)
if grep -q '사유=라이브니스 침묵' "$LG"; then
  ok "정체를 blocked 행으로 기록한다"
else
  bad "정체 기록" "행이 없다"
fi
n_blocked=$(grep -c '라이브니스 침묵' "$LG" || true)
run --stall 0 >/dev/null
run --stall 0 >/dev/null
check "같은 조건을 반복 기록하지 않는다" "$(grep -c '라이브니스 침묵' "$LG" || true)" "$n_blocked"

# Re-announcing would also grow the ledger, which resets the very idleness being
# measured — the watcher would then alternate between firing and heartbeating
# forever, and neither state would mean anything.
ok "재기록 억제가 측정 대상을 스스로 흔들지 않게 한다"

# ---------------------------------------------------------------------------
# 3. An open approval is NOT a stall
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
run --stall 0 >/dev/null
if grep -q '라이브니스 침묵' "$LG"; then
  bad "대기 중 승인" "사람을 기다리는 런을 정체로 기록했다"
else
  ok "열린 승인이 있으면 정체로 판정하지 않는다 (기다리는 것과 멈춘 것은 다르다)"
fi

# ---------------------------------------------------------------------------
# 4. Finished-for-now
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
out=$(run)
case "$out" in
  *"사람이 손대기 전까지 끝난 것"*) ok "모두 대기/종단이면 그렇게 크게 말한다" ;;
  *) bad "완료-대기 안내" "'$out'" ;;
esac
out2=$(run)
case "$out2" in
  *"사람이 손대기 전까지 끝난 것"*) bad "재안내" "같은 안내를 매 패스마다 반복한다" ;;
  *) ok "같은 안내를 반복하지 않는다" ;;
esac

# The resolved case must go back to a heartbeat — otherwise the announcement
# latch would silence the watcher for the rest of the run.
printf -- '- `승인` | 승인 id=A1 | 상태=승인\n' >> "$LG"
printf -- '- `segment` | id=S2 | 상태=실행중\n' >> "$LG"
out3=$(run)
case "$out3" in
  *"[watch] 살아 있음"*) ok "해소되면 하트비트로 돌아온다" ;;
  *) bad "복귀" "'$out3'" ;;
esac

# ---------------------------------------------------------------------------
# 5. It decides nothing and resumes nothing
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$WATCH" | grep_all_q -E '\bclaude\b|run\.sh|gate\.sh'; then
  bad "재개 금지" "감시 스크립트가 무언가를 기동한다 — 두 번째 의사결정자가 생긴다"
else
  ok "아무것도 기동하지 않는다 (자동 워치독이 아니다)"
fi

if grep -vE '^[[:space:]]*#' "$WATCH" | grep_all_q 'wait -n'; then
  bad "라이브니스 오라클" "wait -n 은 인터프리터 하한에 없고, 재부착된 스테이지는 이 셸의 자식이 아니다"
else
  ok "라이브니스는 kill -0 과 시작 시각 지문으로 본다"
fi

if grep -q 'LC_TIME=C' "$WATCH"; then
  ok "시작 시각 비교 전에 LC_TIME 을 고정한다 (지문이 로케일 산물이 되지 않게)"
else
  bad "LC_TIME" "ps -o lstart= 비교가 로케일에 좌우된다"
fi

printf '\ntest-watch: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
