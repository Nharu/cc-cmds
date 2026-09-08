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
  # The count is CAPTURED rather than redirected to /dev/null — but NOT because
  # discarding the output makes grep exit early. It does not. Re-measured on this
  # host over 200,000 lines behind a `sed`: `sed … | grep -c … >/dev/null`
  # produced a non-zero pipeline 0 times out of 10 and the captured form 0 out of
  # 10, while the control `grep -q` produced one 10 out of 10. What
  # short-circuits is the `-q` flag itself.
  #
  # What capturing actually buys is that the verdict is a VALUE rather than an
  # exit status. `grep -c` exits 1 when the count is zero, so the redirected form
  # hands its truth value to `pipefail` — fine while this stays an `if` condition
  # and a trap for whoever copies the idiom into a pipeline whose failure means
  # something else.
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

# The host check is SEAMED, so every leg can drive the Darwin branch. Skipping
# these on the other leg counted an unreachable path as a pass, which is how a
# platform-specific hole stays invisible; the seam is what makes the assertions
# reachable everywhere instead.
#
# The variable is attached at each call site rather than exported for the file.
# A file-wide export is inherited by every case that follows it, silently, which
# is the shape a later reader cannot see — and for a shell function a prefix
# assignment does NOT scope to the call, so it has to prefix the real command.

# The emitter launches the notifier DETACHED and never asks its exit status — a
# banner sits on the critical path of an act and may not be able to block one. So
# a stub's write can land after the watcher process has already exited, and every
# assertion about the log has to wait for it rather than read once.
#
# Bounded, and the assertion itself stays a boolean: this waits for a COUNT to be
# reached and never compares elapsed seconds against anything.
notify_settle() {
  # notify_settle <expected-line-count>
  local want="$1" i=0 n
  while [ "$i" -lt 60 ]; do
    n=$(grep -c . "$NOTIFY_LOG" 2>/dev/null || true)
    if [ "${n:-0}" -ge "$want" ]; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

notify_lines() { grep -c . "$NOTIFY_LOG" 2>/dev/null || true; }

# The stub logs `$*`, so argv arrives space-joined and a title carrying a space
# cannot be pulled out with a `[^ ]*` capture — the fixed-string form asks the
# question directly instead.
has_title()   { grep -cF -- "-title $1 -message" "$NOTIFY_LOG" 2>/dev/null || true; }
has_group()   { grep -cF -- "-group $1 " "$NOTIFY_LOG" 2>/dev/null || true; }
n_sound()     { grep -cF -- '-sound default' "$NOTIFY_LOG" 2>/dev/null || true; }
groups_uniq() { sed -n 's/.*-group \([^ ]*\).*/\1/p' "$NOTIFY_LOG" | sort -u | grep -c . || true; }

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
# The same pass with the host seam pinned, for the cases that assert on banner
# arguments. `--notify` is gone: the run-level kill switch is the only toggle,
# and a second parsing site is what let a user believe they had switched the
# banners off while every one of them kept arriving.
runb() { CC_CMDS_NOTIFY_HOST_OS=Darwin bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" 2>&1; }

# The watcher's own time conversion, taken as source text and run on its own.
# It is lifted out HERE, above its first user, because two things need it: the
# valid/invalid tables far below, which are what it was extracted for, and the
# seeding helper right under this, which has to know how old a fixture's run row
# claims to be before it can say whether a threshold is out of that fixture's
# reach.
iso_fn=$(sed -n '/^iso_to_epoch() {/,/^}/p' "$WATCH")
iso_epoch() { CC_ISO_FN="$iso_fn" bash -c 'eval "$CC_ISO_FN"; iso_to_epoch "$1"' _ "$1"; }

out_of_reach() {
  # out_of_reach <이름> <효력 임계> <측정값> — the override has to STRICTLY
  # exceed what the seeding pass measured, or it is not what is holding its arm
  # off. Silent on success: this is the helper's own bookkeeping, not a case, and
  # a passing line per call would put it into every caller's total.
  case "${2:-}" in
    ''|*[!0-9]*)
      bad "시딩 헬퍼" "$1 임계를 인자 목록에서 읽지 못했다 ('${2:-}')"; return ;;
  esac
  [ "$2" -gt "$3" ] || bad "시딩 헬퍼" \
    "$1 임계 $2 가 시딩 pass 의 측정값 $3 을 넘지 못한다 — 이 override 는 arm 을 막고 있지 않다"
}

seed_idle() {
  # seed_idle <초> <run 인자…> — hand the watcher an idle ledger.
  #
  # It owns that clock: it records the size it saw and when it first saw it, so
  # a single pass can only ever report zero and no fixture written from outside
  # can shorten that. One pass seeds the state file, then line 2 is moved back.
  # Line 1 comes back out of the watcher's own state rather than being computed
  # here, so this does not restate how it measures the ledger.
  #
  # THE SEEDING PASS IS A FULL PASS. It writes `watch.state`, and it also
  # evaluates every arm — so an arm that fires HERE leaves its once-marker, the
  # pass the case actually measures is then held back by that marker, and the
  # case reads it as "the arm did not fire". The diagnosis points at the exact
  # opposite of the defect. The thresholds are therefore put out of reach for
  # this pass alone; they are appended after the caller's, so the last value
  # wins and each case still spells its own for the pass it measures.
  #
  # ONE ARGUMENT VECTOR, NOT TWO. The pass below and the check under it read the
  # same list, so a threshold dropped from here is dropped from both — a check
  # carrying its own copy of these numbers would go on asserting about a
  # threshold the pass no longer ran with.
  local secs="$1"; shift
  set -- "$@" --stall 99999999999 --after-stage 99999999999 --run-open 99999999999
  run "$@" >/dev/null
  # And the assumption is checked rather than trusted, because it is the kind
  # that stops holding quietly: an arm carrying no threshold, or one whose
  # threshold this list stops naming, would leave its marker here and nothing
  # else in the suite would say so.
  if [ -e "$RD/stall" ] || [ -n "$(ls "$RD"/watch.announced-* 2>/dev/null || true)" ]; then
    bad "시딩 헬퍼" "시딩 pass 가 arm 을 발화시켰다 — 뒤따르는 측정 pass 가 once 가드에 막혀 침묵을 결함으로 보고한다"
  fi
  # AND "OUT OF REACH" IS MEASURED, NOT DECLARED. Two of the three overrides
  # carried no load at all. The run-age one was about 3.17 years while every
  # fixture that reaches that arm opens its run in 2020, so the number this
  # comment called unreachable was already exceeded twice over; and the stall one
  # was held off by the caller's own number rather than by this one. Both could
  # be deleted with the whole suite staying green. So each threshold IN EFFECT —
  # last spelling wins, the rule the watcher's own parser applies — is compared
  # against the quantity its arm reads on this pass.
  local _a _prev="" _eff_stall="" _eff_after="" _eff_open=""
  for _a in "$@"; do
    case "$_prev" in
      --stall)       _eff_stall="$_a" ;;
      --after-stage) _eff_after="$_a" ;;
      --run-open)    _eff_open="$_a" ;;
    esac
    _prev="$_a"
  done
  local _now _seen _idle _gate_at _run_at _run_ep
  _now=$(date -u +%s)
  # The ledger idleness this pass saw, out of the watcher's own state rather than
  # recomputed here — line 2 is when it first saw the size it still sees.
  _seen=$(sed -n '2p' "$RD/watch.state" 2>/dev/null || true)
  case "${_seen:-}" in
    ''|*[!0-9]*)
      bad "시딩 헬퍼" "시딩 pass 뒤에 watch.state 의 관측 시각을 읽지 못했다 ('${_seen:-}') — 아래 대조가 잴 것이 없다" ;;
    *)
      _idle=$(( _now - _seen ))
      out_of_reach --stall "$_eff_stall" "$_idle"
      out_of_reach --after-stage "$_eff_after" "$_idle" ;;
  esac
  # The gate-idle reading the after-stage threshold is also compared against. A
  # fixture that removed the file is one where that arm cannot judge at all, so
  # there is nothing for the threshold to hold off.
  _gate_at=$(sed -n '1p' "$RD/started-at" 2>/dev/null || true)
  case "${_gate_at:-}" in
    ''|*[!0-9]*) : ;;
    *) out_of_reach --after-stage "$_eff_after" "$(( _now - _gate_at ))" ;;
  esac
  # And the run age, read the way the watcher reads it. No `run` row, or a stamp
  # that does not parse, is again a fixture that arm cannot judge.
  _run_at=$( { grep -E '^- `run`' "$LG" 2>/dev/null || true; } | tail -1 \
             | tr '|' '\n' | sed -n 's/^ *시작=//p' | sed 's/[[:space:]]*$//' | tail -1)
  if [ -n "$_run_at" ]; then
    _run_ep=$(iso_epoch "$_run_at")
    [ -z "$_run_ep" ] || out_of_reach --run-open "$_eff_open" "$(( _now - _run_ep ))"
  fi
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
# The emitter is SOURCED, not launched, and its filename ends in `run.sh` — so
# the substring test below reads that source line as the driver. The claim being
# made is "this process starts nothing", so the scan drops that exact line and
# keeps every other one, rather than loosening the pattern until it also stops
# catching the file it exists to catch. The exclusion is a WHOLE-LINE match:
# `bash "$WATCH_DIR/notify-run.sh"` would still be scanned and still fail.
if grep -vE '^[[:space:]]*#' "$WATCH" \
   | grep -vxF '. "$WATCH_DIR/notify-run.sh"' \
   | grep_all_q -E '\bclaude\b|run\.sh|gate\.sh'; then
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
# lock and passed no length check, and the chain could not account for it. That
# used to surface one row late: the verifier stepped over a row it could not
# read a `prev=` from without advancing its running value, while the writer's
# tip hashed the last ROW including that one, so a run whose watcher fired once
# read as broken from the NEXT row onward, forever. It now surfaces on the row
# itself — an unreadable `prev=` is a break where it occurs — which is a better
# report of the same defect and no reason to keep the writer.
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

# ---------------------------------------------------------------------------
# THE CONVERSION ITSELF, FED DIRECTLY.
#
# The two cases above reach `iso_to_epoch` through the arm, and between them
# they feed it exactly two stamps: one fixed old one and one taken now. Its four
# validation guards — the digit count, the 1970 floor, the month range and the
# day range — are reached by neither, so all four could be deleted and this
# suite would stay green.
#
# The arithmetic being right is not what is at risk; it is that a stamp the
# function cannot parse comes back as a number instead of as nothing. A wrong
# epoch becomes a negative age, a negative age is below every threshold, and the
# arm then falls SILENT — which is indistinguishable from the healthy case and
# is also the exact failure this watcher exists to break. So the guards fail in
# the one direction nothing else in this suite can see.
#
# Taken as source text and run on its own, the way the shared predicate's
# consumers are read elsewhere in this tree: driving it through the arm would
# need a ledger and a run directory per row, and neither is what these rows are
# about. The extraction itself is at the top of this file, because the seeding
# helper needs the same conversion; what stays here is the assertion that it
# found something to run.
# ---------------------------------------------------------------------------
if [ -n "$iso_fn" ]; then
  ok "watch.sh 에서 시각 환산 함수를 떼어냈다"
else
  bad "시각 환산 추출" "iso_to_epoch 를 찾지 못했다 — 아래 행들은 잴 것이 없다"
fi

# The valid side. The rows are the boundaries hand-rolled civil-date arithmetic
# gets wrong: the epoch itself, a 400-year leap year, a 100-year NON-leap year,
# the leap day the March-based rebase moves, and the two signed-integer cliffs.
for iso_row in \
  '1970-01-01T00:00:00Z|0' \
  '2020-01-01T00:00:00Z|1577836800' \
  '2000-02-29T00:00:00Z|951782400' \
  '2100-03-01T00:00:00Z|4107542400' \
  '2024-02-29T12:34:56Z|1709210096' \
  '2038-01-19T03:14:08Z|2147483648' \
  ; do
  check "시각 환산 ${iso_row%%|*}" "$(iso_epoch "${iso_row%%|*}")" "${iso_row##*|}"
done

# THE INVALID SIDE IS NOT OPTIONAL. A table of valid inputs alone stays green
# with every guard deleted — that is measured, not supposed. One row per guard:
# a stamp one digit short of a full field, the year floor, the month range and
# the day range. The empty string is here for the contract rather than for a
# guard: with the digit count gone it still answers empty, because the
# arithmetic aborts on a field that is not there.
#
# AND A RANGE IS TWO COMPARISONS, NOT ONE. The month and day guards each carry a
# floor as well as a ceiling, and a table that only overshoots reaches neither
# floor: measured, `[ "$m" -ge 1 ] &&` and `[ "$d" -ge 1 ] &&` could each be
# deleted with this suite staying green. What comes back through that hole is not
# a wrong month, it is a NUMBER where the contract says empty — `2026-00-01`
# answered 1764547200 and `2026-01-00` answered 1767139200 — and a number here
# becomes a negative age, a negative age is under every threshold, and the arm
# falls silent, which is the one failure this watcher exists to break.
for iso_bad in '' '2026-01-01T00:00:0Z' '1969-12-31T23:59:59Z' \
               '2026-00-01T00:00:00Z' '2026-13-01T00:00:00Z' \
               '2026-01-00T00:00:00Z' '2026-01-32T00:00:00Z'; do
  check "파싱되지 않는 시각은 빈 값이다 ('$iso_bad')" "$(iso_epoch "$iso_bad")" ""
done

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
# The negative control the sibling case above carries and this one did not. The
# silence asserted here is also what a fixture that never crossed the ledger
# idle threshold produces, and the two are the same green — so the pass has to
# be shown to be one that reached the threshold before its silence means the
# missing gate record.
idle_said=$(printf '%s' "$out" | sed -n 's/.*원장 \([0-9][0-9]*\)초 전 갱신.*/\1/p' | tail -1)
if [ -n "$idle_said" ] && [ "$idle_said" -ge 120 ] 2>/dev/null; then
  ok "그 침묵도 원장 유휴 임계를 넘긴 pass 의 것이다 (${idle_said}초)"
else
  bad "유휴 대조" "got '$idle_said', want >= 120"
fi

# ---------------------------------------------------------------------------
# THE THREE CONJUNCTS THAT WERE NEVER DRIVEN FROM THEIR FALSE SIDE.
#
# Every case above hands this arm a ledger already idle past the threshold, no
# live stage and no open approval, so those three conjuncts were true in all of
# them — and deleting any one of the three lines changed no verdict anywhere in
# this suite. They are not refinements and they are not dead: each one names a
# router that IS working, and without them this arm accuses it.
#
# The fixtures below differ from the firing one by a single fact each, and the
# firing case is repeated underneath the first so the silence cannot be blamed
# on some other conjunct having quietly failed.
# ---------------------------------------------------------------------------
# The ledger conjunct. The idle count comes from the watcher's own clock, and a
# first pass against a fresh run directory records the size it sees and reports
# zero — so this fixture is silent for exactly one reason.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
out=$(run --stall 99999 --after-stage 120 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    bad "run 나이 arm" "원장이 방금 갱신된 런을 세그먼트 미개시로 지목했다" ;;
  *) ok "원장이 아직 조용하지 않으면 발화하지 않는다" ;;
esac
idle_said=$(printf '%s' "$out" | sed -n 's/.*원장 \([0-9][0-9]*\)초 전 갱신.*/\1/p' | tail -1)
if [ -n "$idle_said" ] && [ "$idle_said" -lt 120 ] 2>/dev/null; then
  ok "그 침묵이 원장 유휴 임계에 못 미친 pass 의 것이다 (${idle_said}초)"
else
  bad "유휴 대조" "got '$idle_said', want < 120"
fi

# The same fixture with only the idle threshold moved. Without this the case
# above would read the same whether the ledger conjunct held it back or some
# other conjunct never became true at all.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    ok "임계만 내리면 같은 픽스처가 발화한다 (나머지 연언지는 전부 참이었다)" ;;
  *) bad "유휴 연언지 대조" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# The approval conjunct. A run waiting on a person has not failed to open a
# segment; it is doing the one thing that legitimately takes an unbounded time.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf -- '- `승인` | 승인 id=A1 | 상태=대기 | 막는 세그먼트=S1\n' >> "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    bad "run 나이 arm" "사람을 기다리는 런을 세그먼트 미개시로 지목했다" ;;
  *) ok "대기 승인이 있으면 발화하지 않는다" ;;
esac

# The live-stage conjunct. The shared fixture rather than a hand-rolled pid
# file, for the reason the stall arm's case states: a pid file alone is not a
# stage to the predicate.
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
FX_RUN_DIR="$RD"; FX_PIDS=""
fx_stage_live S1
out=$(run --stall 99999 --after-stage 0 --run-open 60)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    bad "run 나이 arm" "스테이지가 도는 런을 세그먼트 미개시로 지목했다" ;;
  *) ok "살아 있는 스테이지가 있으면 발화하지 않는다" ;;
esac
fx_reap

# ---------------------------------------------------------------------------
# THE SEEDING HELPER, DRIVEN FROM THE SIDE IT EXISTS TO PROTECT.
#
# Every case above hands `seed_idle` thresholds that no arm can reach on the
# seeding pass, so the guard inside it never has anything to say and the
# override it protects can be deleted with this whole suite staying green. The
# helper is held up by its callers rather than by itself, and the next case
# somebody writes is the one that stops holding it up.
#
# The thresholds here ARE reachable on that pass, which is what a case written
# without thinking about the helper looks like. Two things then have to hold at
# once: the seeding pass leaves no once-marker, and the measuring pass still
# fires. Without the override the seeding pass takes the marker and the
# measuring pass falls silent — reported as "the arm did not fire", which is the
# opposite of what happened.
# ---------------------------------------------------------------------------
#
# TWO ARMS, NOT ONE, because the helper names a threshold per arm and a case that
# only puts the run-age one within reach leaves the other overrides unmeasured —
# which is how two of the three came to carry no load at all. The stall
# threshold is spelled `0` here for exactly that reason: its arm then fires on
# the seeding pass the moment the override stops holding it off.
# ---------------------------------------------------------------------------
fresh
printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
seed_idle 300 --stall 0 --after-stage 0 --run-open 0
out=$(run --stall 0 --after-stage 0 --run-open 0)
case "$out" in
  *"세그먼트가 하나도 열리지 않았습니다"*)
    ok "시딩 pass 가 once 마커를 가져가지 않아 측정 pass 가 발화한다" ;;
  *) bad "시딩 헬퍼" "임계가 닿는 픽스처에서 측정 pass 가 침묵했다 — 시딩 pass 가 arm 을 먼저 발화시켰다" ;;
esac
case "$out" in
  *"아무것도 쓰지 않았습니다"*)
    ok "같은 pass 에서 정지 arm 도 발화한다 (그 임계의 override 도 잴 것이 생긴다)" ;;
  *) bad "시딩 헬퍼" "정지 임계가 닿는 픽스처에서 측정 pass 가 침묵했다 — 시딩 pass 가 정지 arm 을 먼저 발화시켰다" ;;
esac

# ---------------------------------------------------------------------------
# AND THE ARM NO FIXTURE ABOVE CAN REACH.
#
# Every ledger above carries a `run` row and no segment row, and that is the one
# shape the stage-ended arm is structurally excluded from: it needs a
# non-terminal segment AND a terminal stage row as the last row. So the override
# that holds THAT arm off on the seeding pass was being measured by nothing, and
# what stood in for it was the run-age arm reading the same threshold. A ledger
# of the other shape separates them.
# ---------------------------------------------------------------------------
fresh
{ printf -- '- `segment` | id=S1 | 상태=실행중\n'
  printf -- '- `stage-result` | 세그먼트=S1 | 스테이지=S1 | 종료 코드=0 | 종단 부류=정상 완료\n'
} > "$LG"
printf '%s\n' "$(( $(date -u +%s) - 3600 ))" > "$RD/started-at"
seed_idle 300 --stall 99999 --after-stage 0 --run-open 99999
out=$(run --stall 99999 --after-stage 0 --run-open 99999)
case "$out" in
  *"스테이지가 끝났는데 라우터가"*)
    ok "시딩 pass 가 스테이지 종단 arm 의 마커를 가져가지 않아 측정 pass 가 발화한다" ;;
  *) bad "시딩 헬퍼" "임계가 닿는 픽스처에서 스테이지 종단 arm 이 침묵했다 — $(printf '%s' "$out" | tr '\n' ' ')" ;;
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
out=$(runb)
case "$out" in
  *"런이 종단했습니다"*) ok "arm B 가 유도 종단을 크게 말한다" ;;
  *) bad "arm B" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
notify_settle 1
if grep -q '런이 종단했습니다' "$NOTIFY_LOG" 2>/dev/null; then
  ok "arm B 가 배너도 함께 올린다 (announce 만이 아니라)"
else
  bad "arm B 배너" "$(tr '\n' ' ' < "$NOTIFY_LOG" 2>/dev/null)"
fi
check "종단 배너 제목이 할 일을 말한다" "$(has_title 'cc-cmds · 결과를 확인하세요')" "1"

# ---------------------------------------------------------------------------
# The banner group is per run.
#
# `terminal-notifier` treats a group as a slot and replaces whatever occupies
# it, so a constant group made two concurrent runs erase each other's banners —
# and the erased one's condition then reached nobody at all.
# ---------------------------------------------------------------------------
: > "$NOTIFY_LOG"
fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
runb >/dev/null
fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
runb >/dev/null
notify_settle 2
check "두 런이 각각 배너를 올린다" "$(notify_lines)" "2"
check "그 두 배너의 -group 값이 서로 다르다" \
  "$(sed -n 's/.*-group \([^ ]*\).*/\1/p' "$NOTIFY_LOG" | sort -u | grep -c . || true)" "2"

# ---------------------------------------------------------------------------
# Fixtures for the arms below.
#
# `cc_unresolved_blocked` matches `사유=<reason> ` WITH a trailing space, so the
# reason may never be the row's last field — the trailing `관측=`/`prev=` fields
# are load-bearing here rather than decorative.
# ---------------------------------------------------------------------------
blocked_row() {
  # blocked_row <원인> <사유>
  printf -- '- `blocked` | 대상=- | 스코프=run | 원인=%s | 사유=%s | 관측=2026-09-03T00:00:00Z | prev=x\n' \
    "$1" "$2" >> "$LG"
}
approval_row() {
  printf -- '- `승인` | 승인 id=%s | 상태=대기 | 막는 세그먼트=S1\n' "$1" >> "$LG"
}
# The kill switch is attached to the REAL command, never to the function and
# never file-wide. A prefix assignment on a bash function call outlives the call,
# so every case after it would inherit the value with nothing on screen to say so.
runk() {
  # runk <killswitch-value> [args...]
  local v="$1"; shift
  CC_CMDS_AUTOPILOT_NOTIFY="$v" CC_CMDS_NOTIFY_HOST_OS=Darwin \
    bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" 2>&1
}

# ---------------------------------------------------------------------------
# The kill switch turns off BANNERS and leaves everything else alone.
#
# Its scope reaches the five call sites this file already had, not only the arms
# added with it. The local `--notify` flag and its guard came down at the same
# time, so the switch is the single gate — and without this assertion an
# implementation that routed only the NEW banners through the emitter, leaving
# the old five on their own path, would pass every other case here.
#
# The off tokens are driven ONE BY ONE rather than sampled. A wide off set that
# is only asserted in prose is a set nobody has actually tested.
# ---------------------------------------------------------------------------
for offv in 0 off OFF oFf false FALSE fAlSe no NO; do
  fresh
  : > "$NOTIFY_LOG"
  printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
  out=$(runk "$offv")
  sleep 0.2
  check "킬스위치 '$offv' 이 배너를 끈다" "$(notify_lines)" "0"
  case "$out" in
    *"런이 종단했습니다"*) ok "킬스위치 '$offv' 에서도 터미널의 큰 소리 줄은 그대로다" ;;
    *) bad "킬스위치 '$offv' 큰 소리 줄" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
  if [ -f "$RD/watch.heartbeat" ]; then
    ok "킬스위치 '$offv' 에서도 하트비트 파일은 그대로다"
  else
    bad "킬스위치 '$offv' 하트비트" "watch.heartbeat 가 없다"
  fi
done

# Two negative controls: a value that must read as ON, and a value that looks
# like an attempt to switch off but is not in the set. The second must still be
# ON — and must say so, because a silent acceptance is how a person ends up
# believing the banners are off while every one of them keeps arriving.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
runk 1 >/dev/null
notify_settle 1
check "'1' 은 켬으로 읽는다" "$(notify_lines)" "1"

fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
out=$(runk disabled)
notify_settle 1
check "목록에 없는 값은 켬으로 읽는다" "$(notify_lines)" "1"
case "$out" in
  *"알아보지 못했습니다"*) ok "끄려는 시도로 보이는 미인식 값에 경고한다" ;;
  *) bad "근미스 경고" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# THE SCOPE OF THE SWITCH IS EVERY FIRING POINT IN THIS PROCESS, and the
# denominator is measured rather than remembered.
#
# The loop above drives ONE arm. That was enough while the design said the switch
# had to reach "the five call sites this file already had" — but the census says
# nine, and the four the old number left out are the arms this work added. An
# implementation that routed some of them through the emitter and left the rest
# on a path of their own would pass every assertion above.
#
# EACH ARM IS DRIVEN TWICE AND THE ON PASS IS NOT DECORATION. A negative
# assertion on its own passes when the fixture never reached the arm at all, so
# each arm first has to be shown firing; only then does its silence mean
# something. The loop-exit arm is the ninth and lives below, because it needs the
# real loop rather than a single `--once` pass.
# ---------------------------------------------------------------------------
ks_seed() {
  # ks_seed <arm> — the minimal ledger that reaches one watcher firing point.
  case "$1" in
    ended)       printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG" ;;
    answer)      printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
                 approval_row A1 ;;
    answer-run)  printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
                 approval_row A1 ;;
    rekick)      printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
                 blocked_row 무효화 "강제 표면 이동" ;;
    hands)       printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
                 blocked_row 사람대기 "적용 판정 불가" ;;
    after-stage) printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
                 printf -- '- `stage-result` | 세그먼트=S1 | 종료 코드=0\n' >> "$LG" ;;
    run-open)    printf -- '- `run` | id=R1 | 시작=2026-09-03T00:00:00Z\n' > "$LG" ;;
    silence)     printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG" ;;
  esac
}
ks_run() {
  # ks_run <killswitch-value> <arm> — thresholds lowered per arm, never globally.
  case "$2" in
    after-stage) runk "$1" --after-stage 0 ;;
    run-open)    runk "$1" --run-open 0 --after-stage 0 ;;
    silence)     runk "$1" --stall 0 ;;
    *)           runk "$1" ;;
  esac
}

for arm in ended answer answer-run rekick hands after-stage run-open silence; do
  fresh
  : > "$NOTIFY_LOG"
  ks_seed "$arm"
  ks_run 1 "$arm" >/dev/null
  notify_settle 1
  if [ "$(notify_lines)" -ge 1 ]; then
    ok "대조군 — '$arm' arm 이 켬에서 실제로 발화한다"
  else
    bad "킬스위치 대조군 '$arm'" "켬인데도 배너가 0이라 아래 끔 단언이 공허하다"
  fi

  fresh
  : > "$NOTIFY_LOG"
  ks_seed "$arm"
  ks_run 0 "$arm" >/dev/null
  sleep 0.2
  check "킬스위치가 '$arm' arm 도 끈다" "$(notify_lines)" "0"
done

# ---------------------------------------------------------------------------
# One token chooses TITLE AND GROUP, and the assertion reads both from the same
# log line. The sound is now a CONSTANT rather than an axis, so it is asserted as
# one — every banner carries it, and a single silent one is a failure.
#
# Splitting title and group is what opens a combination per call site — a
# "직접 손대세요" notice landing in the replace slot arrives with well-formed
# arguments and silently erases another summons. Driving each token and reading
# both from one line is what makes that combination unreachable.
# ---------------------------------------------------------------------------
# `answer` — an open approval. One banner PER ID, into its own group, with sound.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
approval_row A1
runb >/dev/null
notify_settle 1
check "answer — 제목" "$(has_title 'cc-cmds · 답하세요')" "1"
check "answer — 그룹이 승인 id 별이다" "$(has_group "cc-cmds-autopilot-$(basename "$RD")-A1")" "1"
check "answer — 소리가 있다" "$(n_sound)" "1"

# `hands` — a resolvable run-scope anchor, keyed by its reason.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 사람대기 "적용 판정 불가"
runb >/dev/null
notify_settle 1
check "hands — 제목" "$(has_title 'cc-cmds · 직접 손대세요')" "1"
check "hands — 그룹이 항목 키를 싣는다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")-run-적용-판정-불가")" "1"
check "hands — 소리가 있다" "$(n_sound)" "1"

# `rekick` — an invalidated run. The gate refuses to resolve this cause, so it is
# NOT something anyone can put their hands on: it takes the per-run replace slot,
# and the title names the only action actually available, which is to open a new
# run. This is the case the older three-token shape could not express, and the
# combination it names is title-says-a-person-is-needed with a replace group.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 무효화 "강제 표면 이동"
runb >/dev/null
notify_settle 1
check "rekick — 제목이 새 런을 열라고 말한다" "$(has_title 'cc-cmds · 새 런을 여세요')" "1"
check "rekick — 그룹은 런 단위 대체 슬롯" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")")" "1"
check "rekick — 대체 버킷이어도 소리가 있다" "$(n_sound)" "1"

# `answer-run` — the whole run is waiting. It shares no slot with the lifecycle
# three, because a run can hold open approvals while it is also stalled or
# finished, and a shared slot would let one of those erase this one.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
approval_row A1
runb >/dev/null
notify_settle 2
check "answer-run — 제목은 답하세요" "$(has_title 'cc-cmds · 답하세요')" "2"
check "answer-run — 자기 슬롯을 갖는다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")-답")" "1"
check "answer-run — 생애주기 슬롯을 쓰지 않는다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")")" "0"

# The address must be UNIQUE per waiting item, or the morning cannot tell what is
# still waiting from what was answered hours ago. N distinct approvals, N
# distinct groups.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
approval_row A1; approval_row A2; approval_row A3
runb >/dev/null
notify_settle 3
check "서로 다른 승인 셋이 서로를 지우지 않는다" "$(groups_uniq)" "3"

# THE RUN ID COMES FIRST IN EVERY GROUP KEY. Two runs parking the same segment id
# is the case that revives the measured regression — an id that is not run-unique
# makes two runs write one key and erase each other's summons.
: > "$NOTIFY_LOG"
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 사람대기 "세그먼트 S1 보류"
runb >/dev/null
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 사람대기 "세그먼트 S1 보류"
runb >/dev/null
notify_settle 2
check "같은 세그먼트를 세운 두 런이 서로의 손 필요 배너를 지우지 않는다" "$(groups_uniq)" "2"

# ---------------------------------------------------------------------------
# The stacking cap — exactly 8, exactly 9, and above.
#
# The ninth and everything after it collapse into ONE slot carrying a count, and
# that slot must not be the status slot: sharing it would make the overflow
# notice and the router-silence notice erase each other.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
for i in 1 2 3 4 5 6 7 8; do approval_row "A$i"; done
runb >/dev/null
notify_settle 8
check "정확히 8건까지는 개별로 남는다" "$(groups_uniq)" "8"
check "8건에서는 넘침 자리가 열리지 않는다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")-대기")" "0"

approval_row A9
runb >/dev/null
notify_settle 9
check "아홉째는 넘침 자리로 모인다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")-대기")" "1"
check "그 자리는 상태 슬롯과 다른 자리다" \
  "$(has_group "cc-cmds-autopilot-$(basename "$RD")")" "0"
# The overflow notice has a title OF ITS OWN, and that is new. While every
# answer-shaped token shared one string, "the ninth arrived" and "answer this
# one" were indistinguishable on screen; now the eight individual notices say
# 답하세요 and the collapsed one says there is more waiting.
check "개별 여덟은 답하세요 제목을 쓴다" "$(has_title 'cc-cmds · 답하세요')" "8"
check "넘침 자리는 자기 제목을 쓴다" "$(has_title 'cc-cmds · 답할 것이 더 있습니다')" "1"

approval_row A10
approval_row A11
runb >/dev/null
notify_settle 11
check "그 위로는 자리를 늘리지 않고 같은 자리에 모인다" "$(groups_uniq)" "9"

# ---------------------------------------------------------------------------
# The anchored arm must not react to conditions this process itself authored.
#
# Both the after-stage arm and the silence arm write their observation one line
# after raising a banner, and the gate transcribes those with the cause `불명` —
# the only place it writes that value. Keying on the cause is what excludes them
# structurally; a list of reason strings would go stale, silently, on the next
# arm added here.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 불명 "라이브니스 침묵"
runb >/dev/null
sleep 0.2
check "감시자가 저작한 조건(원인=불명)에는 정박 배너가 나가지 않는다" "$(notify_lines)" "0"

# 「해소 가능」과 「해소됨」은 다르다 — the first raises a banner and the second does
# not. This is the negative case the obvious implementation fails and every other
# scenario passes.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 사람대기 "적용 판정 불가"
blocked_row 해소 "적용 판정 불가"
runb >/dev/null
sleep 0.2
check "이미 해소된 막힘에는 정박 배너가 나가지 않는다" "$(notify_lines)" "0"

# Once per condition, and the neighbour's marker is not touched. The second half
# is what the existing once-guard assertions in this file never check, and it is
# the likelier defect: an arm that reuses a neighbour's marker dies quietly in
# every run where the neighbour fired first.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 사람대기 "적용 판정 불가"
runb >/dev/null
runb >/dev/null
notify_settle 1
check "정박 arm 은 같은 조건에 한 번만 발화한다" "$(notify_lines)" "1"
if [ -f "$RD/watch.announced-stall-적용-판정-불가" ]; then
  ok "정박 arm 이 자기 마커를 남긴다"
else
  bad "정박 마커" "$(ls "$RD" | tr '\n' ' ')"
fi
if [ -f "$RD/watch.announced-terminal" ] || [ -f "$RD/watch.announced-loop-exit" ]; then
  bad "이웃 마커" "정박 arm 이 이웃 arm 의 마커를 건드렸다"
else
  ok "이웃 arm 의 마커는 건드려지지 않았다"
fi

# ---------------------------------------------------------------------------
# The loop-exit banner and the pass-side terminal arm are one PAIR, driven in
# both directions.
#
# The pass-side arm keys on the shared run-state predicate, which requires zero
# unresolved run-scope blocks — so an invalidated run never returns `종단` and
# that arm is silent for it forever. The loop-exit arm is that run's only
# channel, and it must stay quiet on a run that ended cleanly.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
printf '2026-09-03T00:00:00Z 종단 — 종료 조건 아홉 성립\n' > "$RD/done"
CC_CMDS_NOTIFY_HOST_OS=Darwin bash "$WATCH" --run-dir "$RD" --ledger "$LG" --interval 1 >/dev/null 2>&1
sleep 0.3
if [ -f "$RD/watch.announced-loop-exit" ]; then
  bad "루프 종료 배너" "정상 종료한 런에서 새 배너가 발화했다"
else
  ok "정상 종료한 런에서는 루프 종료 배너가 침묵한다"
fi

fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 무효화 "강제 표면 이동"
printf '2026-09-03T00:00:00Z 종단 — 무효화\n' > "$RD/done"
CC_CMDS_NOTIFY_HOST_OS=Darwin bash "$WATCH" --run-dir "$RD" --ledger "$LG" --interval 1 >/dev/null 2>&1
notify_settle 1
if [ -f "$RD/watch.announced-loop-exit" ]; then
  ok "미해소 막힘이 있는 채 종단 표시가 찍힌 런에서는 새 배너가 발화한다"
else
  bad "루프 종료 배너" "무효화로 끝난 런에서 발화하지 않았다"
fi
check "두 마커의 이름이 실제로 다르다" \
  "$( { [ -f "$RD/watch.announced-terminal" ] && printf 'shared'; } || printf 'distinct')" "distinct"

# The ninth firing point under the kill switch. It sits here rather than in the
# table above because it needs the real loop: the marker is written on the way
# out, which a single `--once` pass never reaches.
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
blocked_row 무효화 "강제 표면 이동"
printf '2026-09-03T00:00:00Z 종단 — 무효화\n' > "$RD/done"
CC_CMDS_AUTOPILOT_NOTIFY=0 CC_CMDS_NOTIFY_HOST_OS=Darwin \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --interval 1 >/dev/null 2>&1
sleep 0.3
check "킬스위치가 루프 종료 arm 도 끈다" "$(notify_lines)" "0"

# ---------------------------------------------------------------------------
# The emitter records its own state ONCE, into this process's own file — never
# by appending to the report. This seat holds no lock and the gate does, so two
# unlocked appends to one file interleave and what breaks is the ledger row
# beside the prose.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
runb >/dev/null
runb >/dev/null
check "감시자가 자기 파일에 배너 상태를 한 번만 남긴다" \
  "$(grep -c . "$RD/notify.state" 2>/dev/null || true)" "1"
check "그 기록이 원장을 건드리지 않는다" \
  "$(grep -c '배너 좌석' "$LG" 2>/dev/null || true)" "0"

# ---------------------------------------------------------------------------
# The marker handshake works ACROSS processes, which is a different property
# from "an arm does not touch its neighbour's marker inside one pass". The
# double-firing failure this design describes rests on this direction.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
approval_row A1
printf 'A1\n' > "$RD/watch.announced-approvals"
runb >/dev/null
sleep 0.2
check "게이트가 이미 알린 승인 id 를 감시자가 존중한다" "$(notify_lines)" "0"

# ---------------------------------------------------------------------------
# A STAGE WEDGED WHILE THE ROUTER KEEPS WORKING — the seventh arm.
#
# Every arm above times the ROUTER's silence. This one times how long a single
# STAGE has been alive, and the commercial failure mode — a stage hung while the
# router goes on writing rows normally — is invisible to all of them and to every
# boundary in the gate, because a hung stage produces no acts and those
# boundaries count acts.
#
# THE CLOCK IS THE STAGE'S START FINGERPRINT. It is written once when the stage
# spawns and never touched again, so its mtime IS the age. The stream log's mtime
# was the other candidate and it measures "how long since it last spoke", which
# loses the stage that is wedged while its log keeps growing.
# ---------------------------------------------------------------------------
fresh
: > "$NOTIFY_LOG"
FX_RUN_DIR="$RD"; FX_PIDS=""
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
# THE ROUTER IS WORKING IN THIS FIXTURE, and the three thresholds below are the
# PRODUCTION ones rather than large numbers. The ledger was just written and the
# gate was just called, so the sibling arms are silent because their conditions
# genuinely do not hold — not because a test put them out of reach. That is what
# makes this case say "fires even while the router is fine" instead of merely
# "fires".
printf '%s\n' "$(date -u +%s)" > "$RD/started-at"
fx_stage_live S1
fx_age_file "$RD/S1.start" 7300
out=$(run --stall 1200 --after-stage 120 --run-open 300 --stage-age 7200)
case "$out" in
  *"스테이지 S1 이"*"살아 있습니다"*) ok "스테이지가 임계를 넘게 살아 있으면 발화한다" ;;
  *) bad "스테이지 연령 arm" "$(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *"라이브니스 침묵"*) bad "형제 arm" "라우터가 정상인 픽스처에서 정체 arm 이 함께 발화했다" ;;
  *) ok "라우터가 계속 행을 쓰고 있어도 이 팔만 발화한다 (형제 arm 은 침묵한다)" ;;
esac
# NOTIFY ONLY; NO BLOCK ROW. An unresolved run-scope block stands up a
# termination condition, so one long legitimate stage would stop the run from
# ending all night and would need a person to write the resolving row — which
# spends the very tolerance for false positives this arm's threshold rests on.
if [ -f "$RD/stall" ]; then
  bad "스테이지 연령 arm" "막힘 관측 파일을 남겼다 — 정당한 긴 스테이지 하나가 밤새 런의 종료를 막는다"
else
  ok "이 팔은 막힘 관측을 남기지 않는다 (통지만 한다)"
fi

# The once-guard is a DEDICATED PER-STAGE MARKER for the same reason the arms
# above use one: the gate empties `stall` on every act, so a guard reading that
# file would come back to life and this arm would re-fire every pass.
out=$(run --stall 1200 --after-stage 120 --run-open 300 --stage-age 7200)
case "$out" in
  *"스테이지 S1 이"*"살아 있습니다"*) bad "재발화" "매 pass 마다 같은 스테이지를 다시 알린다" ;;
  *) ok "같은 스테이지를 다시 알리지 않는다" ;;
esac
if [ -f "$RD/watch.announced-stage-age-S1" ]; then
  ok "그 억제가 스테이지별 전용 마커 파일이다"
else
  bad "once 가드" "$(ls "$RD" | tr '\n' ' ')"
fi
fx_reap

# The threshold is a threshold. A stage that started moments ago has not hung.
fresh
FX_RUN_DIR="$RD"; FX_PIDS=""
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf '%s\n' "$(date -u +%s)" > "$RD/started-at"
fx_stage_live S2
out=$(run --stall 1200 --after-stage 120 --run-open 300 --stage-age 7200)
case "$out" in
  *"살아 있습니다"*) bad "스테이지 연령 arm" "막 시작한 스테이지를 걸린 것으로 지목했다" ;;
  *) ok "임계 이전에는 발화하지 않는다" ;;
esac
fx_reap

# AND A DEAD STAGE IS NOT AN OLD ONE. The pid file outlives a stage that crashed
# without cleaning up, and its fingerprint file keeps ageing forever — so without
# the liveness conjunct this arm would report every crashed stage of the night,
# repeatedly, as a hang.
fresh
FX_RUN_DIR="$RD"; FX_PIDS=""
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf '%s\n' "$(date -u +%s)" > "$RD/started-at"
fx_stage_dead S3
fx_age_file "$RD/S3.start" 7300
out=$(run --stall 1200 --after-stage 120 --run-open 300 --stage-age 7200)
case "$out" in
  *"살아 있습니다"*) bad "스테이지 연령 arm" "죽은 스테이지의 낡은 지문을 걸린 스테이지로 읽었다" ;;
  *) ok "죽은 스테이지에는 발화하지 않는다 (연령만이 아니라 생존도 본다)" ;;
esac

# ---------------------------------------------------------------------------
# The fifth threshold is PINNED, here rather than in the lint that pins the other
# four — that script is outside this change's declared file set. The property is
# the same one: the launch line a run actually consumes has to spell the script's
# own default, or the sentence beside it saying these are the defaults becomes
# false and nothing says so.
# ---------------------------------------------------------------------------
SKILL_MD="$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md"
sa_decl=$( { grep -oE '(^|[;[:space:]])STAGE_AGE=[0-9]+' "$WATCH" || true; } \
           | sed -E 's/.*STAGE_AGE=//')
check "watch.sh 가 STAGE_AGE 기본값을 정확히 하나 선언한다" \
  "$(printf '%s\n' "$sa_decl" | grep -c . || true)" "1"
sa_launch=$( { grep -E 'watch\.sh .*--run-dir' "$SKILL_MD" || true; } \
             | { grep -oE -- '--stage-age [0-9]+' || true; } | sed -E 's/^--stage-age //')
check "기동 줄이 --stage-age 를 정확히 하나 싣는다" \
  "$(printf '%s\n' "$sa_launch" | grep -c . || true)" "1"
check "기동 줄의 값이 watch.sh 의 기본값과 축자로 같다" "$sa_launch" "$sa_decl"
# The launch line is not the only place the document writes this number — the
# paragraph under it restates it, and that paragraph is where the claim about
# defaults lives. A scan anchored on the launch line never reaches it.
sa_stale=$( { grep -oE -- '--stage-age [0-9]+' "$SKILL_MD" || true; } \
            | sed -E 's/^--stage-age //' | { grep -vxF "$sa_decl" || true; } )
check "문서 안의 다른 기재도 같은 값을 못 박는다" \
  "$(printf '%s' "$sa_stale" | grep -c . || true)" "0"

# ---------------------------------------------------------------------------
# `cc_mtime` — the helper the arm above names, ON BOTH PLATFORMS.
#
# The claim is that BSD and GNU answer the same epoch for the same file, and no
# single leg can compare two hosts. What makes the comparison possible is that
# the expected values are LITERALS: both CI legs already run this file, so both
# assert against the same numbers, and a divergence arrives as a red leg rather
# than as a difference nobody is in a position to observe. Asserting "the two
# hosts agree" by hand instead would close once and re-open on the next change.
#
# TWO HELPERS CARRY THIS BODY — one in `liveness.sh` and one in the gate — so the
# one under test is NAMED rather than found. An assertion measuring the other
# copy would stay green while the arm's own reading diverged.
#
# Taken as source text and run on its own, the way `iso_to_epoch` is read above:
# driving it through the arm would need a run directory and a live process per
# row, and neither is what these rows are about.
# ---------------------------------------------------------------------------
LIVENESS="$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
mtime_fn=$(sed -n '/^cc_mtime() {/,/^}/p' "$LIVENESS")
if [ -n "$mtime_fn" ]; then
  ok "liveness.sh 에서 cc_mtime 을 떼어냈다"
else
  bad "cc_mtime 추출" "함수를 찾지 못했다 — 아래 행들은 잴 것이 없다"
fi
# The zone is attached to `bash` and not to the function name: for a shell
# function a prefix assignment does NOT scope to the call, which this file
# already had to learn once for the host seam.
cc_mtime_of() {
  # cc_mtime_of <path> [TZ]
  CC_MTIME_FN="$mtime_fn" TZ="${2:-UTC}" \
    bash -c 'eval "$CC_MTIME_FN"; cc_mtime "$1"' _ "$1"
}

# `perl`, and not `touch -t`, for the reason the shared fixture already gives:
# computing the stamp `touch` wants means formatting an epoch, and that is the
# one operation where the two date implementations take incompatible flags.
# `utime` takes the number directly. The rows are the epoch itself, a round
# stamp, a 400-year leap day and the signed-32-bit cliff.
MT="$WORK/mtime-probe"
for mt_row in 0 1577836800 951782400 2147483648; do
  : > "$MT"
  perl -e 'my ($f, $t) = @ARGV; utime $t, $t, $f or die "utime: $!";' "$MT" "$mt_row"
  check "cc_mtime 이 epoch $mt_row 을 그대로 낸다 (두 레그가 같은 리터럴을 단언한다)" \
    "$(cc_mtime_of "$MT")" "$mt_row"
done

# AND THE ANSWER MUST NOT DEPEND ON THE HOST'S ZONE. `date -r` without `-u`
# answers a local calendar time, and the two legs do not share a zone — so a
# dropped `-u` would show up as a platform divergence when it is nothing of the
# kind. Two zones, one file, one expected number.
: > "$MT"
perl -e 'my ($f, $t) = @ARGV; utime $t, $t, $f or die "utime: $!";' "$MT" 1577836800
check "시간대가 달라도 같은 값을 낸다 (Asia/Seoul)" \
  "$(cc_mtime_of "$MT" Asia/Seoul)" "1577836800"
check "시간대가 달라도 같은 값을 낸다 (UTC)" \
  "$(cc_mtime_of "$MT" UTC)" "1577836800"

# No file is "cannot judge", not "epoch zero" — the arm above skips a stage whose
# fingerprint it cannot read, and a number here would make it judge one.
check "없는 파일에는 빈 값을 낸다" "$(cc_mtime_of "$WORK/없는파일")" ""

# And the arm really does read THIS helper. Without this line the rows above
# measure a function the watcher might not be calling.
if grep -vE '^[[:space:]]*#' "$WATCH" | grep_all_q -F 'cc_mtime "$RUN_DIR/$sseg.start"'; then
  ok "스테이지 연령 팔이 지목된 헬퍼 cc_mtime 으로 기점을 읽는다"
else
  bad "헬퍼 지목" "워처 팔이 cc_mtime 을 읽지 않는다 — 위 단언이 다른 사본을 재고 있다"
fi

printf '\ntest-watch: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" = "0" ]
