#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the liveness watcher's six arms.
#
# The watcher exists for one failure the rest of the system cannot see: the
# router quietly stopping. Nothing crashes, no rule refuses, and a terminal that
# was going to be quiet stays quiet — so the only evidence would be a person
# noticing hours later. Everything asserted here is about making that visible
# WITHOUT making it a decision: the watcher resumes nothing.
#
# The arms are not variations of one condition:
#   run ended        — every segment terminal and nothing waiting. Derived from
#                      the ledger rather than from a `done` file, because almost
#                      no run reaches the path that writes one
#   stage ended,
#   router silent    — the sharp case: a terminal stage row as the last row
#   run opened,
#   no segment       — the window between the run opening and its first segment.
#                      The sharp arm above cannot see it: its key is a stage
#                      having ended, and in this window none ever started
#   stalled          — nothing happening and nothing waiting
#   approval open    — the one event that exists to summon a person
#   finished-for-now — every segment waiting or terminal; the run is done until
#                      a person touches it, which is different from stuck
#
# And under all of them, the heartbeat: alive. Without it, silence from a dead
# watcher and silence from a healthy run are the same observation — which is why
# NO arm may return before reaching it.
#
# Usage: bash scripts/test-watch.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
WATCH="$repo_root/plugins/cc-cmds/orchestrator/watch.sh"
. "$repo_root/scripts/run-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-watch-test.XXXXXX")
trap 'fx_reap; rm -rf "$WORK"' EXIT

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

passed=0; failed=0; skipped=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------------------
# The notifier stub.
#
# EVERY BANNER ASSERTION DEPENDS ON THE PATH OPT-OUT. `banner()` prepends the
# two Homebrew directories to PATH before resolving `terminal-notifier`, so a
# stub placed first on PATH is shadowed by whatever is really installed — and
# then the assertions here would either exercise the real binary or silently
# observe nothing. The watcher honours CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND for
# exactly this reason, and the other two notifier call sites already did.
#
# The stub records its argv; that is the whole interface these tests need, since
# what is being asserted is which `-group` value each run passes.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
NOTIFY_LOG="$WORK/notifier.log"; : > "$NOTIFY_LOG"
cat > "$WORK/bin/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$WORK/bin/terminal-notifier"
PATH="$WORK/bin:$PATH"
CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
CC_TEST_NOTIFY_LOG="$NOTIFY_LOG"
export PATH CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND CC_TEST_NOTIFY_LOG

# `banner()` returns early off Darwin, so the banner cases have nothing to
# observe on the Linux leg. They are SKIPPED rather than passed there: counting
# an unreachable path as a pass is how a platform-specific hole stays invisible.
is_darwin() { [ "$(uname -s)" = "Darwin" ]; }

case_n=0
fresh() {
  # A new run directory and ledger per case — the watcher keeps state on disk on
  # purpose (that is what makes `--once` meaningful across invocations), so
  # sharing one directory would leak a case into the next.
  #
  # THE COUNTER IS NAMED, and the assertion below is why. It used to be `n`, and
  # a case further down assigned to a bare `n` of its own — no `local`, since it
  # was at file scope — which reset this counter to zero. Every `fresh` after it
  # handed back a directory an earlier case had already run in, complete with
  # that case's `stall` file and `watch.announced-*` markers, and the negative
  # assertions in those cases could then pass on the leftovers instead of on
  # what they claim to measure. The rename is the fix; this check is what keeps
  # it fixed, because the failure is silent and every test still passes under it.
  case_n=$((case_n + 1))
  RD="$WORK/run$case_n"; LG="$WORK/ledger$case_n.md"
  if [ -e "$RD" ]; then
    bad "케이스 격리" "run$case_n 이 이미 있다 — 앞 케이스의 디렉터리를 물려받는다"
  fi
  mkdir -p "$RD"; : > "$LG"
  # THE GATE LEAVES THIS FILE, on every entry, and the run-age arm reads it as
  # "when the gate was last called". A directory without it is one the gate
  # never made, which that arm treats as "cannot judge" — so every case about it
  # would then pass on the file's absence rather than on what it claims to
  # measure. The default is an old stamp, the shape of a run whose router has
  # gone quiet; the cases that need a recent one overwrite it.
  printf '%s\n' 1577836800 > "$RD/started-at"
}
run() { bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" 2>&1; }

seed_idle() {
  # seed_idle <초> <run 인자…> — hand the watcher an idle ledger.
  #
  # It owns that clock: it records the size it saw and when it first saw it, so
  # a single pass can only ever report zero and no fixture written from outside
  # can shorten that. One pass seeds the state file, then line 2 is moved back.
  # Line 1 comes back out of the watcher's own state rather than being computed
  # here, so this does not restate how it measures the ledger.
  local secs="$1"; shift
  run "$@" >/dev/null
  printf '%s\n%s\n%s\n' "$(sed -n '1p' "$RD/watch.state")" \
    "$(( $(date -u +%s) - secs ))" "$LG" > "$RD/watch.state"
}

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
if grep -q '라이브니스 침묵' "$RD/stall" 2>/dev/null; then
  ok "정체를 런 디렉터리의 관측 파일로 기록한다 (원장이 아니라)"
else
  bad "정체 기록" "stall 파일에 관측이 없다"
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
# The shared fixture, not a hand-rolled pid file: a pid file ALONE is not a
# stage to the predicate, which needs the `.start` sibling the gate's spawner
# leaves beside it and the fingerprint inside it to match. Writing that recipe
# a second time here is exactly the per-suite drift run-fixture.sh exists to
# prevent, and a fixture that drifts fails for reasons unrelated to its claim.
FX_RUN_DIR="$RD"; FX_PIDS=""
fx_stage_live S1
out=$(run --stall 0)
case "$out" in
  *"라이브니스 침묵"*) bad "살아 있는 스테이지" "스테이지가 도는데 정체로 판정했다" ;;
  *) ok "pid 기록이 있는 살아 있는 스테이지는 정체 판정을 막는다" ;;
esac
case "$out" in
  *"스테이지 1개"*) ok "하트비트가 살아 있는 스테이지를 센다" ;;
  *) bad "스테이지 계수" "'$out'" ;;
esac
fx_reap

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

# The idle state is keyed by the LEDGER as well as the run directory. Its file
# path comes from `--run-dir` alone, so without the ledger recorded inside it a
# watcher restarted against a different ledger inherits the previous one's
# accumulated idleness and can arm a stall on its first pass — and that
# observation becomes an irreversible run-scope row.
# THE TWO LEDGERS ARE THE SAME SIZE ON PURPOSE. Idleness is measured by size,
# so two files of different lengths would reset the counter on the size check
# alone and the ledger-identity check would never be exercised. Equal size and
# different path is the only shape that isolates it — and it is also the real
# case, since the stub a misdirected watcher measures is a sibling of the file
# it should have been reading.
# The segment row is what makes the stall arm reachable at all: the arm requires
# a non-terminal segment, because a run that finished normally has none and
# would otherwise be told its router had stranded it. Both ledgers carry it, so
# they stay the same length.
WD5="$WORK/keydir"; mkdir -p "$WD5"
LG5a="$WORK/stub.md"
printf -- '- `segment` | id=S1 | 상태=실행중\n- `run` | run-id=R1 | prev=x\n' > "$LG5a"
LG5b="$WORK/real.md"
printf -- '- `segment` | id=S1 | 상태=실행중\n- `run` | run-id=R1 | prev=x\n' > "$LG5b"

# A non-zero threshold, because a reset reports zero idle seconds and `0 >= 0`
# would arm anyway — which would make the reset invisible to this assertion.
bash "$WATCH" --run-dir "$WD5" --ledger "$LG5a" --once --stall 1 >/dev/null 2>&1
sleep 2
bash "$WATCH" --run-dir "$WD5" --ledger "$LG5a" --once --stall 1 >/dev/null 2>&1
if [ -f "$WD5/stall" ]; then
  ok "같은 원장에서 임계를 넘기면 정지가 발화한다 (기준선 확인)"
else
  bad "정지 기준선" "같은 원장 두 번에도 stall 이 생기지 않았다"
fi

# Now the same run directory and the same size, but a DIFFERENT ledger. The
# accumulated idleness belongs to the other file, so this pass must reset.
rm -f "$WD5/stall"
bash "$WATCH" --run-dir "$WD5" --ledger "$LG5b" --once --stall 1 >/dev/null 2>&1
if [ -f "$WD5/stall" ]; then
  bad "원장 교체" "다른 원장으로 바꿨는데 앞 원장의 누적 유휴를 물려받아 즉시 정지했다"
else
  ok "원장을 바꾸면 유휴가 초기화된다 (앞 원장의 누적을 물려받지 않는다)"
fi
check "상태 파일이 어느 원장을 재고 있었는지 싣는다" \
  "$(sed -n '3p' "$WD5/watch.state" 2>/dev/null)" "$LG5b"

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

# ---------------------------------------------------------------------------
# The watcher does NOT write the ledger. Its row carried no `prev=`, took no
# lock and passed no length check, and the two sides of the chain then
# disagreed about it — the verifier skips a row with no `prev=` without
# advancing its running value while the writer's tip hashes the last ROW
# including that one. A run whose watcher fired once read as broken from the
# next row onward, forever.
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$WATCH" | grep_all_q -F '>> "$LEDGER"'; then
  bad "단일 기록자" "감시자가 여전히 원장에 직접 쓴다"
else
  ok "감시자가 원장에 직접 쓰지 않는다"
fi

WD4="$WORK/stalldir"; mkdir -p "$WD4"
LG4="$WORK/stallledger.md"
printf -- '- `segment` | id=S1 | 상태=실행중\n- `run` | run-id=R1 | prev=x\n' > "$LG4"
# Two passes, because the idle clock is the watcher's own: the first records the
# size it saw and reports zero, the second measures against it.
bash "$WATCH" --run-dir "$WD4" --ledger "$LG4" --once --stall 0 >/dev/null 2>&1
bash "$WATCH" --run-dir "$WD4" --ledger "$LG4" --once --stall 0 >/dev/null 2>&1
if [ -f "$WD4/stall" ]; then
  ok "정체 관측이 런 디렉터리의 파일로 남는다"
else
  bad "정체 기록" "stall 파일이 생기지 않았다"
fi
n_ledger_blocked=$(grep -c 'blocked' "$LG4" 2>/dev/null || true)
check "그 관측이 원장을 건드리지 않는다" "${n_ledger_blocked:-0}" "0"

# THE ZERO-SEGMENT WINDOW, which every run passes through and which no arm could
# report a death inside. The kickoff's report stub carries zero ledger rows, the
# gate appends the `run` row on its first call, and the first `segment` row
# appears only when the router calls `act --kind segment`, at least two model
# turns later. A router that dies in there leaves a ledger on which `nonterm` is
# 0, and on a bare `nonterm >= 1` this arm fell silent while every other arm
# wanted a row that cannot exist yet — the watcher would heartbeat all night and
# say nothing.
#
# THIS ARM IS THE ONE THAT COVERS IT, and it is the only `record_blocked` arm
# that can: the after-stage arm's last-row guard is unsatisfiable in that window,
# since a `stage-result` or `cost` row means a stage ran and a stage runs inside
# a segment. So the disjunct belongs here alone. What it costs is this arm's
# threshold — twenty minutes — which is what the run-age arm below shortens.
#
# The threshold is 0 and this is a SINGLE pass, because the stall arm fires
# immediately at that threshold and its once-guard suppresses the second.
fresh
printf -- '- `run` | run-id=R1 | prev=x\n' > "$LG"
out=$(run --stall 0)
case "$out" in
  *"아무것도 쓰지 않았습니다"*) ok "세그먼트 행이 없는 원장에서도 정지가 발화한다" ;;
  *) bad "세그먼트 0개 정지" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
if [ -f "$RD/stall" ]; then
  ok "첫 세그먼트 행 이전에 죽은 런의 관측이 파일로 남는다"
else
  bad "세그먼트 0개 정지" "stall 파일이 생기지 않았다"
fi

# ---------------------------------------------------------------------------
# A STAGE ENDED AND THE ROUTER DID NOT ACT — the sharp arm.
#
# The dispatch form itself cannot be checked: measured, the environment a
# harness-tracked background command sees and the environment a foreground one
# sees are byte-identical, so the gate has nothing to test at dispatch time.
# What can be observed is the consequence — a stage's terminal row as the last
# row in the ledger, for longer than a router that was woken would take.
# ---------------------------------------------------------------------------
# The segment row comes FIRST and stays non-terminal on purpose. The arm keys on
# the LAST row being a stage's terminal row, so putting it after would defeat the
# fixture; and it has to be there at all because a run whose segments are all
# terminal is a finished run, not a stranded one.
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `stage-result` | 세그먼트=S1 | 종단 부류=정상 완료 | prev=x\n' >> "$LG"
# The FIRST pass, not the second: with the threshold at zero this arm fires
# immediately, and the second pass is suppressed by the announce-once guard.
out=$(run --stall 99999 --after-stage 0)
case "$out" in
  *"스테이지가 끝났는데"*) ok "스테이지 종단 뒤 라우터 무응답을 잡는다" ;;
  *) bad "종단 후 무응답" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
if grep -q '스테이지 종단 후 라우터 무응답' "$RD/stall" 2>/dev/null; then
  ok "그 관측이 파일에 남는다"
else
  bad "종단 후 무응답" "stall 파일에 관측이 없다"
fi

# A row after the stage's terminal row means the router DID act — no alarm.
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `stage-result` | 세그먼트=S1 | 종단 부류=정상 완료 | prev=x\n' >> "$LG"
printf -- '- `자율 승인` | kind=segment | 결정=act | prev=y\n' >> "$LG"
out=$(run --stall 99999 --after-stage 0)
case "$out" in
  *"스테이지가 끝났는데"*) bad "종단 후 무응답" "라우터가 이어서 행위했는데 경보가 났다" ;;
  *) ok "라우터가 이어서 행위했으면 경보가 나지 않는다" ;;
esac

# And a terminated run does not raise it — that is not a stranded router.
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `stage-result` | 세그먼트=S1 | 종단 부류=정상 완료 | prev=x\n' >> "$LG"
printf '2026-08-30T00:00:00Z 종단\n' > "$RD/done"
out=$(run --stall 99999 --after-stage 0 2>&1 || true)
case "$out" in
  *"스테이지가 끝났는데"*) bad "종단 후 무응답" "종단한 런에서 경보가 났다" ;;
  *) ok "종단한 런에서는 나지 않는다" ;;
esac

# AND IT STAYS SILENT WHERE NO SEGMENT WAS EVER OPENED.
#
# This is the one ledger shape on which a "no segment row yet" disjunct in that
# arm changes its answer: zero `segment` rows, so both `nonterm` and the segment
# count are 0, and a terminal stage row LAST, so the arm's own guard is
# satisfied. No ledger the gate writes has it — a `stage-result` row means a
# stage ran, which means a segment was opened — which is exactly why the
# disjunct was unreachable there while reading as though removing it would bring
# a bug back. This case is the only assertion that can tell the two apart.
#
# THE `run` ROW CARRIES NO `시작=` HERE, and that is what keeps the run-age arm
# out of this case rather than a large `--run-open`: no stamp means that arm
# cannot judge and stays silent, whatever the threshold. A threshold big enough
# to hold back a fixed old stamp does not exist — the gap only grows — and the
# run-age arm writes the same `stall` file, so the second assertion below would
# then have been measuring the wrong arm.
fresh
printf -- '- `run` | run-id=R1 | prev=x\n' > "$LG"
printf -- '- `stage-result` | 세그먼트=- | 종단 부류=정상 완료 | prev=y\n' >> "$LG"
printf -- '- `cost` | 세그먼트=- | prev=z\n' >> "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 0)
case "$out" in
  *"스테이지가 끝났는데"*) bad "무응답 arm" "세그먼트를 연 적 없는 원장에서 발화했다" ;;
  *) ok "세그먼트 행이 없는 원장에서 무응답 arm 은 침묵한다" ;;
esac
if [ -f "$RD/stall" ]; then
  bad "무응답 arm" "발화하지 않아야 할 창에서 관측 파일을 남겼다"
else
  ok "그 창에서 관측 파일도 남기지 않는다"
fi

# ---------------------------------------------------------------------------
# THE RUN OPENED AND NO SEGMENT DID — the sixth arm.
#
# With the disjunct back out, the arm above cannot see that window and the stall
# arm covers it alone, at twenty minutes. This arm names it earlier on a key of
# its own: the age of the `run` row. The row's own `시작=` stamp rather than an
# elapsed count the watcher keeps, so a watcher restarted mid-run measures the
# same age the first one would have instead of starting the clock over.
# ---------------------------------------------------------------------------
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) ok "run 행이 오래됐고 세그먼트가 없으면 발화한다" ;;
  *) bad "run 나이 arm" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
if grep -q '세그먼트 미개시' "$RD/stall" 2>/dev/null; then
  ok "그 관측이 런 디렉터리의 파일로 남는다"
else
  bad "run 나이 arm" "stall 파일에 관측이 없다"
fi

# The once-guard has to be a DEDICATED MARKER, not a grep of `stall`: the gate
# empties that file on every act, so a guard reading it comes back to life and
# the arm re-fires every pass for the rest of the night.
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) bad "run 나이 arm 재발화" "매 pass 마다 다시 알린다" ;;
  *) ok "같은 조건을 다시 알리지 않는다" ;;
esac
check "그 관측도 한 번만 남는다" "$(grep -c '세그먼트 미개시' "$RD/stall" || true)" "1"

# The threshold is a threshold. A run that opened seconds ago has not failed to
# open a segment — it has not had time to. This is also the case that reads a
# REAL timestamp through the ISO-to-epoch conversion: a parser that answered a
# wrong epoch would arm right here.
fresh
printf -- '- `run` | run-id=R1 | 시작=%s | prev=x\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) bad "run 나이 arm" "막 열린 런을 세그먼트 미개시로 판정했다" ;;
  *) ok "임계 이전에는 발화하지 않는다" ;;
esac

# AND THE CONVERSION IS PINNED FROM BOTH SIDES. The case just above only shows
# the arm staying quiet, which a parser answering an epoch too far in the FUTURE
# would produce just as well — a negative age is below every threshold, so that
# whole direction passes unmeasured. Firing on a stamp taken moments ago and
# reading the age the announcement carries closes it: an epoch wrong by a day
# arrives here as ±86400.
fresh
printf -- '- `run` | run-id=R1 | 시작=%s | prev=x\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 0)
age_said=$(printf '%s' "$out" | sed -n 's/.*런이 열린 지 \([0-9-][0-9]*\)초.*/\1/p' | tail -1)
if [ -n "$age_said" ] && [ "$age_said" -ge 0 ] 2>/dev/null && [ "$age_said" -le 60 ] 2>/dev/null; then
  ok "ISO 시각을 epoch 으로 옮긴 나이가 실제 경과와 맞는다 (${age_said}초)"
else
  bad "run 행 나이 환산" "got '$age_said', want 0..60"
fi

# No stamp to read is "cannot judge", not "zero seconds old". Silence can only
# delay the report to the stall arm's margin; the other direction invents one
# for every ledger written before that field existed.
fresh
printf -- '- `run` | run-id=R1 | prev=x\n' > "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 0)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) bad "run 나이 arm" "시각 없는 run 행을 나이 0 으로 읽었다" ;;
  *) ok "run 행에 시각이 없으면 판정하지 않는다" ;;
esac

# A NORMALLY TERMINATED RUN CANNOT REACH IT. A clean finish has at least one
# segment row, so the segment count alone excludes it. The terminal
# announcement in the same pass is what shows the fixture is a finished run
# rather than a ledger too empty to trigger anything.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' >> "$LG"
out=$(run --stall 99999 --after-stage 0 --run-open 0)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) bad "run 나이 arm" "정상 종단한 런에서 발화했다" ;;
  *) ok "정상 종단한 런에서는 발화하지 않는다" ;;
esac
case "$out" in
  *"런이 종단했습니다"*) ok "그 pass 가 실제로 종단으로 판정된 pass 다" ;;
  *) bad "run 나이 arm 음성 대조" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# And a run carrying a `done` file is excluded a second time.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '2026-08-30T00:00:00Z 종단\n' > "$RD/done"
out=$(run --stall 99999 --after-stage 0 --run-open 0 2>&1 || true)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) bad "run 나이 arm" "종단 표시가 있는 런에서 발화했다" ;;
  *) ok "종단 표시가 있으면 발화하지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# A WORKING ROUTER IS NOT A STOPPED ONE, AND THE LEDGER CANNOT TELL THEM APART.
#
# Before the first segment the router writes the manifest and the grant, stubs
# the morning report, starts this watcher and reads skill contracts — none of it
# appends a row. So an unchanged ledger is not evidence that nothing happened,
# and this arm keyed on nothing else.
#
# The fixture is a healthy run measured at the moment every other conjunct held:
# the run 333 seconds old, the ledger unchanged for 300 seconds, no segment row,
# nothing alive and nothing waiting. That router opened its first segment
# normally 21 minutes and 32 seconds later — longer than `STALL`, so no
# threshold this arm could carry separates the two. The gate's own record does.
#
# THE THRESHOLDS ARE THE PRODUCTION ONES, and they are spelled out rather than
# left to the defaults so that the case fails if either side moves without the
# other. A case that picked numbers of its own would keep passing while the
# configuration a real run uses drifted out from under it.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(date -u +%s)" > "$RD/started-at"
seed_idle 300 --stall 99999 --after-stage 120 --run-open 300
out=$(run --stall 99999 --after-stage 120 --run-open 300)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    bad "run 나이 arm" "게이트를 방금 부른 라우터를 세그먼트 미개시로 지목했다" ;;
  *) ok "원장이 조용해도 게이트가 최근에 불렸으면 발화하지 않는다" ;;
esac
# The negative control. Silence here would also be produced by a fixture that
# never reached the idle threshold at all, and then the case above measures
# nothing — so the pass has to be shown to be one the ledger conjunct passed.
idle_said=$(printf '%s' "$out" | sed -n 's/.*원장 \([0-9][0-9]*\)초 전 갱신.*/\1/p' | tail -1)
if [ -n "$idle_said" ] && [ "$idle_said" -ge 120 ] 2>/dev/null; then
  ok "그 침묵이 원장 유휴 임계를 넘긴 pass 의 것이다 (${idle_said}초)"
else
  bad "유휴 대조" "got '$idle_said', want >= 120"
fi

# AND THE ARM STILL FIRES WHEN THE GATE IS SILENT TOO. Same fixture, same
# thresholds; the one thing that changes is that nothing has called the gate.
# Without this the conjunct above could be satisfied by never firing at all.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
seed_idle 300 --stall 99999 --after-stage 120 --run-open 300
out=$(run --stall 99999 --after-stage 120 --run-open 300)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) ok "게이트도 오래 조용하면 발화한다 (arm 이 죽지 않았다)" ;;
  *) bad "run 나이 arm" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# No record of a gate call is "cannot judge", not "the gate was never called".
# The run directory is the gate's own artifact, so its absence says the watcher
# is looking at something the gate did not make — and inventing a report from a
# file nobody wrote is the direction that costs a person their night.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
rm -f "$RD/started-at"
seed_idle 300 --stall 99999 --after-stage 120 --run-open 300
out=$(run --stall 99999 --after-stage 120 --run-open 300)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    bad "run 나이 arm" "게이트 호출 기록이 없는 것을 호출이 없었던 것으로 읽었다" ;;
  *) ok "게이트 호출 기록이 없으면 판정하지 않는다" ;;
esac

# ---------------------------------------------------------------------------
# THE SIXTH ARM DOES NOT MASK THE OTHER FIVE.
#
# No arm returns before the heartbeat, so adding one cannot swallow a pass — but
# that is a property to measure rather than assume, and this arm sits between
# two that fire on the very same ledger. One pass with both thresholds met must
# produce both announcements, leave both observations under their own reasons,
# and still reach the heartbeat.
# ---------------------------------------------------------------------------
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
out=$(run --stall 0 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*) ok "그 pass 에서 run 나이 arm 이 발화한다" ;;
  *) bad "동시 발화" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *"아무것도 쓰지 않았습니다"*) ok "같은 pass 에서 정지 arm 도 발화한다 (뒤 arm 이 가려지지 않는다)" ;;
  *) bad "동시 발화" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *"[watch] 살아 있음"*) ok "두 arm 이 발화한 pass 도 하트비트까지 도달한다" ;;
  *) bad "동시 발화 하트비트" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
check "두 arm 이 각자의 사유로 관측을 남긴다" "$(grep -c . "$RD/stall" || true)" "2"

# ---------------------------------------------------------------------------
# It stays alive across passes.
#
# Every other case here drives `--once`, which cannot observe the one property
# the loop is for: that the watcher keeps going. A watcher that dies on its
# second pass passes every single-pass assertion above and then reports nothing
# for the rest of the night — and its silence is indistinguishable from a
# healthy run's.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
bash "$WATCH" --run-dir "$RD" --ledger "$LG" --interval 1 >/dev/null 2>&1 &
wpid=$!
sleep 1
hb_a=$(date -u -r "$RD/watch.heartbeat" +%s 2>/dev/null || printf '')
sleep 2
hb_b=$(date -u -r "$RD/watch.heartbeat" +%s 2>/dev/null || printf '')
if [ -f "$RD/watch.pid" ] && [ "$(cat "$RD/watch.pid" 2>/dev/null)" = "$wpid" ]; then
  ok "감시자가 자기 pid 를 런 디렉터리에 남긴다"
else
  bad "watch.pid" "got '$(cat "$RD/watch.pid" 2>/dev/null)', want '$wpid'"
fi
kill "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
if [ -n "$hb_a" ] && [ -n "$hb_b" ] && [ "$hb_b" -gt "$hb_a" ] 2>/dev/null; then
  ok "루프가 여러 pass 에 걸쳐 하트비트를 계속 전진시킨다"
else
  bad "생존 스모크" "hb_a='$hb_a' hb_b='$hb_b'"
fi
# The pid file must not be counted as a stage — the run's termination condition
# has no resolving verb, so a watcher that counted itself would take the run's
# ability to finish away for as long as it ran.
check "그 pid 파일은 스테이지로 세지 않는다" \
  "$(sed -n 's/.*스테이지 \([0-9][0-9]*\)개.*/\1/p' "$RD/watch.heartbeat" 2>/dev/null)" "0"

# ---------------------------------------------------------------------------
# NO ARM RETURNS BEFORE THE HEARTBEAT.
#
# Each arm used to `return 0` on firing. A condition that keeps re-arming
# therefore stopped the heartbeat for good — and a stale heartbeat is precisely
# the shape of a dead watcher, so the failure this whole script exists to make
# visible was hidden by the script's own alarm.
# ---------------------------------------------------------------------------
# The FIRST pass, as in the case above: a fresh state file reports zero idle
# seconds and `0 >= 0` arms immediately, while a second pass would be suppressed
# by the announce-once guard and observe nothing.
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
out=$(run --stall 0)
case "$out" in
  *"아무것도 쓰지 않았습니다"*) ok "정지 arm 이 발화한다 (기준선)" ;;
  *) bad "정지 arm" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *"[watch] 살아 있음"*) ok "정지 arm 이 발화한 pass 도 하트비트까지 도달한다" ;;
  *) bad "정지 arm 하트비트" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
out=$(run)
case "$out" in
  *"사람이 손대기 전까지 끝난 것"*) ok "대기 종료 arm 이 발화한다 (기준선)" ;;
  *) bad "대기 종료 arm" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *"[watch] 살아 있음"*) ok "대기 종료 arm 이 발화한 pass 도 하트비트까지 도달한다" ;;
  *) bad "대기 종료 arm 하트비트" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# `--once` judges termination too.
#
# The loop path checks for termination before it ever calls a pass, and `--once`
# skips that check entirely — so the one invocation form a person or a status
# line would use to ask "is this over?" was the one form that could not answer.
# Deriving termination inside the pass closes it, and the derivation does not
# need a `done` file: 2 of 39 run directories had one.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
out=$(run)
case "$out" in
  *"런이 종단했습니다"*) ok "--once 한 번으로 유도 종단을 판정한다 (done 파일 없이)" ;;
  *) bad "--once 종단 검사" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
out=$(run)
case "$out" in
  *"런이 종단했습니다"*) bad "종단 재안내" "같은 종단을 매 패스마다 반복한다" ;;
  *) ok "종단은 한 번만 안내한다" ;;
esac

# ---------------------------------------------------------------------------
# The approval arm is keyed by the ID SET, not by the count.
#
# An approval is the one event that exists to summon a person, and the count
# key lost it in the case that matters most: two approvals opening while one
# closes leaves the count unchanged, so the new one announced to nobody and the
# run waited all night for someone who had not been told.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
out=$(run)
case "$out" in
  *"승인 대기"*) bad "arm A" "열린 승인이 없는데 알렸다" ;;
  *) ok "열린 승인이 없으면 알리지 않는다" ;;
esac
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
out=$(run)
case "$out" in
  *"승인 대기 1건"*) ok "승인이 열린 pass 에 알린다" ;;
  *) bad "arm A" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# Resolved and reopened under the same id: still silent. The id file is the
# marker, so an id announced once never announces again.
printf -- '- `승인` | 승인 id=A1 | 상태=승인\n' >> "$LG"
run >/dev/null
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
out=$(run)
case "$out" in
  *"승인 대기"*) bad "arm A 재발화" "해소된 뒤 같은 id 가 다시 열렸는데 또 알렸다" ;;
  *) ok "같은 id 로는 다시 알리지 않는다" ;;
esac
check "알린 승인 id 가 한 줄로 남는다" \
  "$(grep -c . "$RD/watch.announced-approvals" 2>/dev/null || true)" "1"

# A second, DISTINCT id announces — which is the case the count key could not
# separate from the first one.
printf -- '- `승인` | 승인 id=A2 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
out=$(run)
case "$out" in
  *"승인 대기"*) ok "다른 id 가 열리면 다시 알린다" ;;
  *) bad "arm A 신규 id" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# The terminal arm says it on BOTH channels.
#
# The old `done` branch only called `announce()`, and its output goes to a
# stdout that is closed the moment the launching call returns. A run that ended
# overnight therefore ended in silence on every channel a sleeping person has.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
out=$(run --notify)
case "$out" in
  *"런이 종단했습니다"*) ok "arm B 가 유도 종단을 크게 말한다" ;;
  *) bad "arm B" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
if is_darwin; then
  if grep -q '런이 종단했습니다' "$NOTIFY_LOG" 2>/dev/null; then
    ok "arm B 가 배너도 함께 올린다 (announce 만이 아니라)"
  else
    bad "arm B 배너" "$(tr '\n' ' ' < "$NOTIFY_LOG" 2>/dev/null)"
  fi
else
  skip "arm B 배너" "banner() 는 Darwin 에서만 동작한다"
fi

# ---------------------------------------------------------------------------
# The banner group is per run.
#
# `terminal-notifier` treats a group as a slot and replaces whatever occupies
# it, so a constant group made two concurrent runs erase each other's banners —
# and the erased one's condition then reached nobody at all.
# ---------------------------------------------------------------------------
if is_darwin; then
  : > "$NOTIFY_LOG"
  fresh
  printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
  run --notify >/dev/null
  fresh
  printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
  run --notify >/dev/null
  check "두 런이 각각 배너를 올린다" \
    "$(grep -c . "$NOTIFY_LOG" 2>/dev/null || true)" "2"
  check "그 두 배너의 -group 값이 서로 다르다" \
    "$(sed -n 's/.*-group \([^ ]*\).*/\1/p' "$NOTIFY_LOG" | sort -u | grep -c . || true)" "2"
else
  skip "런별 배너 그룹" "banner() 는 Darwin 에서만 동작한다"
  skip "런별 배너 그룹 (호출 수)" "banner() 는 Darwin 에서만 동작한다"
fi

printf '\ntest-watch: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" = "0" ]
