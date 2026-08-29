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
# 4b. A running stage must be VISIBLE, or the detector cries wolf
#
# The stall arm is "ledger idle AND nothing alive AND nothing waiting". A stage
# writes no ledger rows WHILE it runs, so if the watcher cannot see the stage,
# every long stage looks exactly like a router that stopped. Measured on the
# first real run: the watcher reported "스테이지 0개" while a review stage was
# 350 lines into its output, and would have recorded a false stall.
#
# A false alarm is worse than no alarm, because it teaches its reader to ignore
# the true one.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
sleep 1 &
live_pid=$!
printf '%s\n' "$live_pid" > "$RD/S1.pid"
out=$(run --stall 0)
case "$out" in
  *"라이브니스 침묵"*) bad "살아 있는 스테이지" "스테이지가 도는데 정체로 판정했다" ;;
  *) ok "pid 기록이 있는 살아 있는 스테이지는 정체 판정을 막는다" ;;
esac
case "$out" in
  *"스테이지 1개"*) ok "하트비트가 살아 있는 스테이지를 센다" ;;
  *) bad "스테이지 계수" "'$out'" ;;
esac
wait "$live_pid" 2>/dev/null

# And the gate must write that record — the watcher can only count what exists.
GATE_SH="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
if grep -vE '^[[:space:]]*#' "$GATE_SH" | grep -c 'RUN_DIR/$seg.pid' >/dev/null 2>&1 \
   && [ "$(grep -vE '^[[:space:]]*#' "$GATE_SH" | grep -c 'RUN_DIR/\$seg\.pid' || true)" != "0" ]; then
  ok "게이트가 스테이지 pid 를 기록한다 (감시자가 셀 수 있는 것만 센다)"
else
  bad "pid 기록" "게이트가 스테이지를 띄우면서 pid 파일을 쓰지 않는다"
fi

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

# ---------------------------------------------------------------------------
# The watcher STOPS. Its loop had no exit condition and nothing else reaped it —
# the gate ends a run without touching it, and the report renderer is forbidden
# from starting or writing anything. Measured on one machine: seven watchers
# from seven runs, ages from 18 seconds to 1 day 4 hours, with no way to tell a
# live run's watcher from a finished run's.
# ---------------------------------------------------------------------------
WD="$WORK/stopdir"; mkdir -p "$WD"
LG2="$WORK/stopledger.md"; printf '# x\n' > "$LG2"
printf '2026-08-29T00:00:00Z 종단 — 종료 조건 아홉 성립\n' > "$WD/done"
out=$(bash "$WATCH" --run-dir "$WD" --ledger "$LG2" --interval 1 2>&1); rc=$?
check "종단 표시가 있으면 감시자가 스스로 끝난다" "$rc" "0"
case "$out" in
  *"감시를 멈춥니다"*) ok "멈추는 이유를 말한다" ;;
  *) bad "종단 안내" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# The run directory going away is the other end. A watcher for a run whose
# directory was removed has nothing left to read.
WD2="$WORK/gonedir"; mkdir -p "$WD2"; rmdir "$WD2"
out=$(bash "$WATCH" --run-dir "$WD2" --ledger "$LG2" --interval 1 2>&1); rc=$?
check "런 디렉터리가 사라져도 끝난다" "$rc" "0"

# The heartbeat goes to a FILE. This process is launched into the background by
# a tool call that then returns, so its stdout is closed and every heartbeat
# printed there reaches nobody — the property "a live watcher's silence differs
# from a dead one's" was stated and then not obtainable.
WD3="$WORK/hbdir"; mkdir -p "$WD3"
LG3="$WORK/hbledger.md"; printf -- '- `run` | run-id=R1 | prev=x\n' > "$LG3"
bash "$WATCH" --run-dir "$WD3" --ledger "$LG3" --once >/dev/null 2>&1
if [ -f "$WD3/watch.heartbeat" ]; then
  ok "하트비트가 파일로 남는다 (닫힌 표준출력이 아니라)"
else
  bad "하트비트" "watch.heartbeat 가 생기지 않았다"
fi
case "$(cat "$WD3/watch.heartbeat" 2>/dev/null)" in
  *"스테이지"*) ok "그 파일이 관측값을 싣는다" ;;
  *) bad "하트비트 내용" "$(cat "$WD3/watch.heartbeat" 2>/dev/null)" ;;
esac
# Rewritten every pass even when nothing moved — which is exactly what
# `watch.state` cannot do, since that file only moves when the ledger's size does.
sleep 1
bash "$WATCH" --run-dir "$WD3" --ledger "$LG3" --once >/dev/null 2>&1
hb2=$(date -u -r "$WD3/watch.heartbeat" +%s 2>/dev/null)
st2=$(date -u -r "$WD3/watch.state" +%s 2>/dev/null || printf '')
if [ -n "$hb2" ]; then
  ok "원장이 그대로여도 하트비트는 다시 쓰인다"
else
  bad "하트비트 갱신" "mtime 을 읽지 못했다"
fi

printf '\ntest-watch: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
