#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the watcher's delegation to the resident observer: the `watch` job
# module, the delegated `--once` pass it calls, and the loop's hand-off.
#
# WHAT IS BEING HELD IN PLACE. A looping watcher on a run that carries the
# protocol mark hands its arguments to `observer.py adopt` and exits; from then
# on the observer calls `watch.sh --once` with `CC_OBSERVER_PID` set, on every
# change of the run directory and on every deadline the last pass announced in
# `watch.next`. The cases below hold the parts of that contract a reader of the
# run directory depends on: the pid and fingerprint the delegated pass leaves
# are the observer's, the run ends with exit 3 exactly where the loop would
# exit, a plain `--once` and the loop are unchanged, and every time-based arm
# fires as early under the observer as under the loop it replaced.
#
# EVERYTHING RUNS AGAINST TEMPORARY TREES. The state root is a fresh
# `XDG_STATE_HOME`, the run that the real observer adopts sits under it with a
# pinned copy of this repository's orchestrator, and every observer started here
# is stopped by the exit trap. Most cases need no observer at all: a sleeping
# process of this suite stands in for it, because a delegated pass only reads
# the observer's pid.
#
# THE STAGE GUARD IS CLEARED. `adopt` refuses inside a stage, and this suite is
# run from one, so the variables that mark a stage are unset.
#
# The two timing recipes (section 12) read this host's ledgers for their
# size: `CC_TEST_LEDGER_DIR` names the directory of run ledgers whose longest
# file sets the synthetic ledger's line count. Without it the count is a fixed
# default. The eight-second bound of the pass-time recipe is a claim about this
# host, so on a CI host the recipe prints its timings and asserts nothing.
#
# Usage: bash scripts/test-observer-watch.sh

set -uo pipefail

R3_ON_CI=${CI:-}
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done
unset CI CC_CMDS_OBSERVER CC_OBSERVER_PID TMUX TMUX_PANE v
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
WATCH="$ORCH/watch.sh"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 가 없다 — 관측기를 띄울 수 없다\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-observer-watch-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
S="$WORK/state"
export XDG_STATE_HOME="$S"
export CC_OBSERVER_PERIOD=0.5 CC_OBSERVER_GRACE=600
mkdir -p "$S/cc-cmds/run" "$S/cc-cmds/session"
# The attention spool and the fleet's pace root point under the work directory,
# so nothing here reaches this host's real ones.
export CC_CMDS_ATTENTION_ROOT="$WORK/attention-root-absent"
export FLEET_PACE_ROOT="$WORK/pace"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
# within <name> <value> <low> <high> — an integer inside [low, high].
within(){
  case "$2" in ''|*[!0-9-]*) bad "$1" "정수가 아니다: '$2'"; return ;; esac
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then ok "$1"; else bad "$1" "got $2, want $3..$4"; fi
}

# The notifier stubs, first on PATH; the banner cases count what they record.
STUB="$WORK/stub"; mkdir -p "$STUB"
NOTIFY_LOG="$WORK/notifier.log"; : > "$NOTIFY_LOG"
cat > "$STUB/terminal-notifier" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
SH
printf '#!/bin/sh\nexit 0\n' > "$STUB/osascript"
chmod +x "$STUB/terminal-notifier" "$STUB/osascript"
export PATH="$STUB:$PATH" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 CC_TEST_NOTIFY_LOG="$NOTIFY_LOG"

# The plugin tree every pinned copy is made from: this repository's
# orchestrator and manifest, nothing else.
PT="$WORK/plugin-tree"
mkdir -p "$PT"
cp -R "$repo_root/plugins/cc-cmds/orchestrator" "$PT/orchestrator"
cp -R "$repo_root/plugins/cc-cmds/.claude-plugin" "$PT/.claude-plugin"

STRAYS=""
cleanup() {
  local p
  p=$(cat "$S/cc-cmds/observer/observer.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
  python3 "$PT/orchestrator/observer.py" stop >/dev/null 2>&1
  for p in $STRAYS; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# A process outside this shell's job table, so killing it prints no job notice.
sleeper() { SLEEPER=$(sleep 900 >/dev/null 2>&1 & printf '%s' "$!"); STRAYS="$STRAYS $SLEEPER"; }
fp_of()  { ( . "$ORCH/liveness.sh"; cc_proc_fingerprint "$1" ); }
now()    { date -u +%s; }
iso()    { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }
age_to() { python3 -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
mtime()  { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null; }
first_line() { sed -n '1p' "$1" 2>/dev/null; }

case_n=0
fresh() {
  # A new run directory and ledger per case, the gate's `started-at` stamp an
  # old one (a router that has gone quiet), as `scripts/test-watch.sh` makes them.
  case_n=$((case_n + 1))
  RD="$WORK/run$case_n"; LG="$WORK/ledger$case_n.md"
  mkdir -p "$RD"; : > "$LG"
  printf '%s\n' 1577836800 > "$RD/started-at"
}

# The observer's stand-in: a live process whose pid the delegated pass writes.
sleeper; OBS=$SLEEPER
deleg() { CC_OBSERVER_PID="$OBS" bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" >/dev/null 2>&1; }
plain() { bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. The module's form, as the observer loads it.
# ---------------------------------------------------------------------------
out=$(python3 - "$ORCH" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import observer
mods = observer.load_modules()
m = mods.get("watch")
print("loaded=%s" % (m is not None))
if m is not None:
    print("pidfile=%s" % m.PID_FILE)
    print("rc=%s" % m.RUN_OVER_RC)
    print("gaps=%s/%s/%s" % (m.MAX_GAP_S, m.STALL_GAP_S, m.TIMEOUT_BACKOFF_S))
PY
)
check "1 관측기가 observer_watch 를 watch 작업으로 적재한다" "$(printf '%s\n' "$out" | sed -n 's/^loaded=//p')" "True"
check "1 pid 파일은 watch.pid" "$(printf '%s\n' "$out" | sed -n 's/^pidfile=//p')" "watch.pid"
check "1 런 종료 코드는 watch.sh 의 위임 종료 코드 3 과 같다" "$(printf '%s\n' "$out" | sed -n 's/^rc=//p')" "3"
check "1 간격 상수" "$(printf '%s\n' "$out" | sed -n 's/^gaps=//p')" "300/10/60"
n=$(grep -c 'exit 3$' "$WATCH" || true)
within "1 watch.sh 의 위임된 판이 종료 코드 3 으로 끝나는 자리가 있다" "$n" 1 99

# ---------------------------------------------------------------------------
# 2. When `tick` calls a pass, with a stand-in context.
# ---------------------------------------------------------------------------
TR="$WORK/tickrun"
mkdir -p "$TR/observer.jobs"
: > "$TR/observer.jobs/watch.args"
age_to "$TR/observer.jobs/watch.args" 1000
: > "$TR/watch.heartbeat"
printf 'quiet 5\n' > "$TR/watch.mode"
out=$(python3 - "$ORCH/observer_watch.py" "$TR" <<'PY'
import importlib.util, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ow", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
run = sys.argv[2]


class Ctx:
    def __init__(s):
        s.calls, s.drops, s.logs, s.rc = [], [], [], 0

    def call(s, run, argv, timeout=10):
        s.calls.append(list(argv))
        return s.rc, ""

    def drop(s, run):
        s.drops.append(run)

    def args(s, run):
        return ["--run-dir", run, "--ledger", "/l"]

    def log(s, msg):
        s.logs.append(msg)


c = Ctx()


def step(name, t, changed=False):
    n = len(c.calls)
    r = m.tick(c, run, changed, float(t))
    print("%s=%s" % (name, "call" if len(c.calls) > n else "skip"))
    return r


def nxt(first):
    with open(os.path.join(run, "watch.next"), "w") as f:
        f.write("%s\nLEDGER\nhalt/\n*.pid\n" % first)


r = step("first", 10000)
print("argv-first=%s" % " ".join(c.calls[-1]).replace(run, "RUN"))
print("ret-first=%s" % r)
step("quiet", 10001)
step("changed", 10002, True)
print("argv-changed=%s" % " ".join(c.calls[-1]).replace(run, "RUN"))
nxt(10010)
print("probes=%s" % ",".join(m.probes(run)))
step("before-deadline", 10005)
step("deadline", 10011)
nxt("")
step("gap", 10030)
early = 0
for t in range(10035, 10330, 5):
    n = len(c.calls)
    m.tick(c, run, False, float(t))
    early += len(c.calls) - n
print("maxgap-early=%d" % early)
step("maxgap", 10330)
c.rc = -9
step("timeout", 10331, True)
c.rc = 0
print("logs=%d" % len(c.logs))
nxt(10335)
step("held", 10336)
step("held-changed", 10337, True)
step("after-hold", 10392)
c.rc = 3
r = step("over", 10393, True)
print("drops=%d" % len(c.drops))
print("ret-over=%s" % r)
c.rc = 0
step("readopt", 10394)
print("argv-readopt=%s" % " ".join(c.calls[-1]).replace(run, "RUN"))
print("hb=%d" % int(os.stat(os.path.join(run, "watch.heartbeat")).st_mtime))
with open(os.path.join(run, "watch.mode")) as f:
    print("mode=%s" % f.read().strip())
PY
)
v() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
check "2 첫 바퀴는 부른다" "$(v first)" "call"
check "2 첫 바퀴의 인자: 채택 시각, --alive-at 없음, 등록 인자" "$(v argv-first)" "watch.sh --once --started 1000 --run-dir RUN --ledger /l"
check "2 바퀴는 지금 + 1초를 돌려준다" "$(v ret-first)" "10001.0"
check "2 변화도 기한도 없는 1초 뒤 바퀴는 부르지 않는다" "$(v quiet)" "skip"
check "2 변화가 있으면 부른다" "$(v changed)" "call"
check "2 둘째 호출은 직전 바퀴 시각을 --alive-at 으로 넘긴다" "$(v argv-changed)" "watch.sh --once --started 1000 --alive-at 10001 --run-dir RUN --ledger /l"
check "2 탐침은 watch.next 의 둘째 줄부터" "$(v probes)" "LEDGER,halt/,*.pid"
check "2 기한 전에는 부르지 않는다" "$(v before-deadline)" "skip"
check "2 공표한 기한이 오면 부른다" "$(v deadline)" "call"
check "2 바퀴 사이가 10초를 넘으면 부른다" "$(v gap)" "call"
check "2 300초 안에는 기한 없이 부르지 않는다" "$(v maxgap-early)" "0"
check "2 300초가 차면 부른다" "$(v maxgap)" "call"
check "2 시한 초과 호출도 부른 것이다" "$(v timeout)" "call"
check "2 시한 초과는 로그 한 줄을 남긴다" "$(v logs)" "1"
check "2 시한 초과 뒤 60초 동안은 지난 기한에도 부르지 않는다" "$(v held)" "skip"
check "2 그 동안에도 변화에는 부른다" "$(v held-changed)" "call"
check "2 미룸이 끝나면 다시 부른다" "$(v after-hold)" "call"
check "2 종료 코드 3 은 작업을 내려놓는다" "$(v drops)" "1"
check "2 내려놓은 바퀴는 기한을 돌려주지 않는다" "$(v ret-over)" "None"
check "2 다시 채택되면 첫 바퀴처럼 --alive-at 없이 부른다" "$(v argv-readopt)" "watch.sh --once --started 1000 --run-dir RUN --ledger /l"
check "2 바퀴마다 heartbeat 의 mtime 을 그 시각으로" "$(v hb)" "10394"
check "2 바퀴마다 watch.mode 의 낱말을 지키고 시각만 새로" "$(v mode)" "quiet 10394"

# ---------------------------------------------------------------------------
# 3. The delegated pass writes the observer's pid and fingerprint.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
deleg --stall 1500; rc=$?
check "3 위임된 판은 0 으로 끝난다" "$rc" "0"
check "3 watch.pid 는 관측기의 pid" "$(cat "$RD/watch.pid" 2>/dev/null)" "$OBS"
check "3 watch.stall 의 임계" "$(sed -n '1p' "$RD/watch.stall")" "1500"
check "3 watch.stall 의 pid 는 관측기의 것" "$(sed -n '2p' "$RD/watch.stall")" "$OBS"
check "3 watch.stall 의 지문은 관측기의 것" "$(sed -n '3p' "$RD/watch.stall")" "$(fp_of "$OBS")"

# ---------------------------------------------------------------------------
# 4. `watch.next`: a deadline line, then the probe set; never a probe itself.
# ---------------------------------------------------------------------------
l1=$(first_line "$RD/watch.next")
case "$l1" in *[!0-9]*) bad "4 첫 줄은 정수 epoch 또는 빈 줄" "'$l1'" ;; *) ok "4 첫 줄은 정수 epoch 또는 빈 줄" ;; esac
want=$(sed -n "s/^WATCH_PROBES='\(.*\)'\$/\1/p" "$WATCH")
check "4 나머지 줄은 WATCH_PROBES 의 글롭 하나씩" "$(sed -n '2,$p' "$RD/watch.next" | tr '\n' ' ' | sed 's/ $//')" "$want"
out=$(python3 - "$ORCH" "$want" <<'PY'
import fnmatch, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import observer
globs = list(observer.BASE_PROBES) + sys.argv[2].split()
print(sum(1 for g in globs if fnmatch.fnmatch("watch.next", g)))
PY
)
check "4 watch.next 는 어느 탐침 글롭에도 들지 않는다" "$out" "0"

# ---------------------------------------------------------------------------
# 5. The `done` tail.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
printf '2026-11-21T00:00:00Z 종단 — 종료 조건 성립\n' > "$RD/done"
deleg; check "5 정산이 끝난 done 은 3" "$?" "3"

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf '2026-11-21T00:00:00Z 종단\n' > "$RD/done"
: > "$RD/ends-on-done"
sleeper
printf '%s\n%s\n' "$SLEEPER" "$(fp_of "$SLEEPER")" > "$RD/shift.live"
deleg --stall 1500; check "5 교대가 정산 중인 done 은 0" "$?" "0"
check "5 그때 watch.next 의 기한은 done 의 mtime + STALL" \
  "$(first_line "$RD/watch.next")" "$(( $(mtime "$RD/done") + 1500 ))"
kill "$SLEEPER" 2>/dev/null

fresh
: > "$NOTIFY_LOG"
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `blocked` | 대상=- | 스코프=run | 원인=무효화 | 사유=강제 표면 이동 | 관측=2026-09-03T00:00:00Z | prev=x\n' >> "$LG"
printf '2026-09-03T00:00:00Z 종단 — 무효화\n' > "$RD/done"
rcs=""
for _i in 1 2 3; do
  env -u CC_CMDS_AUTOPILOT_NOTIFY CC_CMDS_NOTIFY_HOST_OS=Darwin CC_OBSERVER_PID="$OBS" \
    bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once >/dev/null 2>&1
  rcs="$rcs$?"
done
sleep 1
check "5 미해소 막힘으로 끝난 런은 매번 3" "$rcs" "333"
check "5 rekick 은 세 번 불러도 한 번" "$(grep -c '새 런으로 다시 킥오프' "$NOTIFY_LOG" || true)" "1"
check "5 그 표지가 남는다" "$( [ -f "$RD/watch.announced-loop-exit" ] && printf y || printf n)" "y"

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
printf -- '- `blocked` | 대상=- | 스코프=run | 원인=무효화 | 사유=강제 표면 이동 | 관측=2026-09-03T00:00:00Z | prev=x\n' >> "$LG"
printf '2026-09-03T00:00:00Z 종단 — 무효화\n' > "$RD/done"
mkdir "$RD/notify.ended"
t0=$(now)
deleg; check "5 fired 없는 어린 차지 표지만 있으면 0" "$?" "0"
within "5 그때 기한은 지금 + 2" "$(first_line "$RD/watch.next")" $((t0 + 1)) $((t0 + 4))
check "5 rekick 표지는 아직 쓰지 않는다" "$( [ -f "$RD/watch.announced-loop-exit" ] && printf y || printf n)" "n"

# ---------------------------------------------------------------------------
# 6. The idle exit counts from `--started`, not from a day-old heartbeat.
# ---------------------------------------------------------------------------
idle_fixture() {
  fresh
  printf '마지막성장=%s\n' "$(( $(now) - 90000 ))" > "$RD/watch.heartbeat"
  age_to "$LG" $(( $(now) - 90000 ))
  age_to "$RD/started-at" $(( $(now) - 90000 ))
}
idle_fixture
deleg --started "$(now)"; check "6 방금 채택된 작업은 하루 묵은 마지막성장으로 끝나지 않는다" "$?" "0"
idle_fixture
deleg --started $(( $(now) - 90000 )); check "6 하루 전에 채택된 작업은 유휴 종료로 3" "$?" "3"

# ---------------------------------------------------------------------------
# 7. A plain `--once` is unchanged.
# ---------------------------------------------------------------------------
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
plain; check "7 맨 --once 는 0" "$?" "0"
check "7 맨 --once 는 watch.next 를 쓰지 않는다" "$( [ -e "$RD/watch.next" ] && printf y || printf n)" "n"
plain --started 5 --alive-at 6; check "7 두 새 인자를 받아들인다" "$?" "0"
check "7 그래도 watch.next 를 쓰지 않는다" "$( [ -e "$RD/watch.next" ] && printf y || printf n)" "n"
differ_pid=$(cat "$RD/watch.pid" 2>/dev/null)
if [ "$differ_pid" != "$OBS" ]; then ok "7 맨 --once 는 제 pid 를 쓴다"; else bad "7 맨 --once 는 제 pid 를 쓴다" "$differ_pid"; fi
CC_OBSERVER_PID=abc bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once >/dev/null 2>&1
check "7 정수가 아닌 CC_OBSERVER_PID 는 위임된 판이 아니다" "$( [ -e "$RD/watch.next" ] && printf y || printf n)" "n"
plain --started x; check "7 정수가 아닌 --started 는 2" "$?" "2"
plain --alive-at; check "7 값 없는 --alive-at 은 2" "$?" "2"

# ---------------------------------------------------------------------------
# 8. The loop's hand-off, driven with a stand-in `observer.py`.
# ---------------------------------------------------------------------------
FT="$WORK/fake-tree"
cp -R "$PT/orchestrator" "$FT"
FAKE_LOG="$WORK/fake-observer.log"
cat > "$FT/observer.py" <<'PY'
import os, sys
with open(os.environ["FAKE_OBS_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("FAKE_OBS_RC", "1")))
PY
export FAKE_OBS_LOG="$FAKE_LOG"
loop_fake() { bash "$FT/watch.sh" --run-dir "$RD" --ledger "$LG" --interval 1 2>&1; }
ended_fixture() {
  fresh
  printf -- '- `segment` | id=S1 | 상태=머지됨\n' > "$LG"
  printf '2026-11-21T00:00:00Z 종단\n' > "$RD/done"
  : > "$FAKE_LOG"
}

fresh; : > "$FAKE_LOG"
out=$(FAKE_OBS_RC=0 loop_fake); rc=$?
check "8 adopt 가 0 이면 루프는 0 으로 끝난다" "$rc" "0"
case "$out" in *"관측 데몬에 위임했습니다"*) ok "8 위임 한 줄을 남긴다" ;; *) bad "8 위임 한 줄을 남긴다" "$out" ;; esac
check "8 adopt 에 넘긴 인자" "$(cat "$FAKE_LOG")" "adopt --run-dir $RD --job watch -- --run-dir $RD --ledger $LG --interval 1 --run-env CC_CMDS_AUTOPILOT_NOTIFY=0"
check "8 위임한 루프는 런 디렉터리에 아무것도 쓰지 않는다" "$(ls "$RD" | tr '\n' ' ')" "started-at "

ended_fixture
out=$(FAKE_OBS_RC=1 loop_fake); rc=$?
check "8 adopt 가 거절하면 지금의 루프를 돈다" "$rc:$(grep -c . "$FAKE_LOG")" "0:1"
case "$out" in *"위임했습니다"*) bad "8 거절 뒤에는 위임 줄이 없다" "$out" ;; *) ok "8 거절 뒤에는 위임 줄이 없다" ;; esac

ended_fixture
out=$(FAKE_OBS_RC=0 CC_CMDS_OBSERVER=off loop_fake)
check "8 CC_CMDS_OBSERVER=off 면 adopt 를 부르지 않는다" "$(grep -c . "$FAKE_LOG" || true)" "0"

ended_fixture
out=$(FAKE_OBS_RC=0 CI=1 loop_fake)
check "8 CI 에서는 adopt 를 부르지 않는다" "$(grep -c . "$FAKE_LOG" || true)" "0"

ended_fixture
mv "$FT/observer-protocol" "$WORK/observer-protocol.aside"
out=$(FAKE_OBS_RC=0 loop_fake)
check "8 규약 표지가 없는 사본은 adopt 를 부르지 않는다" "$(grep -c . "$FAKE_LOG" || true)" "0"
mv "$WORK/observer-protocol.aside" "$FT/observer-protocol"

ended_fixture
out=$(FAKE_OBS_RC=0 bash "$FT/watch.sh" --run-dir "$RD" --ledger "$LG" --once 2>&1)
check "8 --once 는 adopt 를 부르지 않는다" "$(grep -c . "$FAKE_LOG" || true)" "0"

# ---------------------------------------------------------------------------
# 9. `--alive-at` bounds the failover clock's jump.
# ---------------------------------------------------------------------------
fo_fixture() {
  fresh
  local t at
  t=$(now); at=$((t - 1000))
  printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
  printf -- '- `계정 이전` | 세그먼트=S1 | 결과=대기 | 재개 시각=%s | prev=x\n' "$(iso "$at")" >> "$LG"
  printf '%s\n%s\n0\n' $((t - 300)) "$at" > "$RD/watch.failover-clock"
  FO_T=$t
}
fo_fixture
deleg --alive-at $((FO_T - 2))
check "9 관측기가 2초 전에 런을 보았으면 300초 틈은 잠듦이 아니다" "$(sed -n '3p' "$RD/watch.failover-clock")" "0"
fo_fixture
deleg
within "9 --alive-at 이 없으면 그 틈을 잠듦으로 센다" "$(sed -n '3p' "$RD/watch.failover-clock")" 298 305
fo_fixture
deleg --alive-at $((FO_T - 300))
within "9 관측기도 300초 동안 멈췄으면 그 틈을 센다" "$(sed -n '3p' "$RD/watch.failover-clock")" 298 305
fo_fixture
plain --alive-at $((FO_T - 2))
within "9 맨 --once 는 --alive-at 을 쓰지 않는다" "$(sed -n '3p' "$RD/watch.failover-clock")" 298 305

# ---------------------------------------------------------------------------
# 10. The deadlines the pass now announces.
# ---------------------------------------------------------------------------
far="--after-stage 99999 --run-open 99999"
fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf '갱신=%s\n' $((t - 100)) > "$RD/S1.waiting"
age_to "$RD/S1.waiting" $((t - 100))
deleg --stall 5000 --silence 99999 $far
check "10 대기 파일이 낡는 시각" "$(first_line "$RD/watch.next")" $((t - 100 + 5000))

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf 'refreshed=%s\nstarted=%s\nstages=-\nci=-\n' $((t - 10)) $((t - 10)) > "$RD/relay.live"
deleg --stall 5000 --silence 4000 $far
check "10 중계의 refreshed 가 침묵이 되는 시각" "$(first_line "$RD/watch.next")" $((t - 10 + 4000))

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf 'refreshed=%s\nstarted=%s\nstages=-\nci=S1\n' "$t" "$t" > "$RD/relay.live"
deleg --stall 5000 --silence 4000 $far
within "10 CI 를 기다리는 중계는 지금 + INTERVAL" "$(first_line "$RD/watch.next")" $((t + 59)) $((t + 63))

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf 'refreshed=%s\nstarted=%s\nstages=-\nci=-\n' "$t" $((t - 500)) > "$RD/relay.live"
printf 'reset=RJ1:%s\n' $((t - 50)) >> "$RD/relay.live"
grace=$( ( . "$ORCH/liveness.sh"; cc_reset_grace ) )
deleg --stall 5000 --silence 4000 $far
if [ $((t - 50 + grace)) -gt "$t" ]; then
  check "10 한도 리셋이 깨우는 시각" "$(first_line "$RD/watch.next")" $((t - 50 + grace))
else
  check "10 리셋 깨움이 선 시각 + AFTER_STAGE" "$(first_line "$RD/watch.next")" $((t - 50 + grace + 99999))
fi

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf 'defer=%s\n' $((t + 200)) > "$RD/relay.live"
deleg --stall 5000 --silence 4000 $far
check "10 이월 시계" "$(first_line "$RD/watch.next")" $((t + 200))

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
printf -- '- `계정 이전` | 세그먼트=S1 | 결과=대기 | 재개 시각=%s | prev=x\n' "$(iso $((t + 100)))" >> "$LG"
deleg --stall 5000 --silence 99999 $far
check "10 장애 넘김 대기가 풀리는 시각" "$(first_line "$RD/watch.next")" $((t + 100 + 1620))

fresh
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
t=$(now)
deleg --started "$t" --stall 99999 --silence 99999 $far
within "10 하루 유휴 종료 시각" "$(first_line "$RD/watch.next")" $((t + 86400)) $((t + 86402))

# ---------------------------------------------------------------------------
# 11. The readers of a watcher's marks judge a delegated run as a looping one.
# ---------------------------------------------------------------------------
fresh; RA=$RD; LA=$LG
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LA"
fresh; RB=$RD; LB=$LG
printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LB"
CC_CMDS_OBSERVER=off bash "$WATCH" --run-dir "$RA" --ledger "$LA" --interval 1 --stall 1500 >/dev/null 2>&1 &
LOOPA=$!; STRAYS="$STRAYS $LOOPA"
sleeper; OBS11=$SLEEPER
CC_OBSERVER_PID="$OBS11" bash "$WATCH" --run-dir "$RB" --ledger "$LB" --once --stall 1500 >/dev/null 2>&1
n=0; while [ ! -f "$RA/watch.mode" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
both() { printf '%s|%s' "$( ( . "$ORCH/liveness.sh"; LEDGER=$LA; "$@" "$RA" ) )" "$( ( . "$ORCH/liveness.sh"; LEDGER=$LB; "$@" "$RB" ) )"; }
quiet_of() { ( . "$ORCH/liveness.sh"; cc_watch_mode_quiet "$1" 60 && printf quiet || printf work ); }
check "11 cc_watch_mode_quiet" "$(quiet_of "$RA")" "$(quiet_of "$RB")"
check "11 cc_effective_stall 은 살아 있는 감시자의 임계" "$(both cc_effective_stall)" "1500|1500"
g=$(both cc_ledger_growth_at)
case "$g" in [0-9]*'|'[0-9]*) ok "11 cc_ledger_growth_at 이 두 런에서 heartbeat 를 읽는다" ;; *) bad "11 cc_ledger_growth_at" "$g" ;; esac
dash() {
  python3 - "$ORCH" "$1" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import dashboard_read as d
v, present = d.heartbeat_growth(sys.argv[2])
print("%s/%s/%s" % (d.effective_stall(sys.argv[2], d.ProcTable()), present, v is not None))
PY
}
check "11 dashboard_read 의 정지 임계·heartbeat 판독" "$(dash "$RA")" "$(dash "$RB")"
hb_age() { echo $(( $(now) - $(mtime "$1/watch.heartbeat") )); }
within "11 feed.sh 의 감시자 침묵 점검: 위임된 런의 heartbeat 는 STALL 보다 젊다" "$(hb_age "$RB")" 0 1499
kill "$LOOPA" "$OBS11" 2>/dev/null; wait "$LOOPA" 2>/dev/null
sleep 0.3
check "11 감시자가 사라지면 두 런 모두 기본 임계로 돌아간다" "$(both cc_effective_stall)" "1200|1200"

# ---------------------------------------------------------------------------
# 12. The two timing recipes, under the real observer.
#
# R1: for each time-based arm, the same run state and clock under a looping
# watcher and under the observer; the first observation each leaves (the arm's
# `stall` line or once-marker) differs by no more than one loop interval plus
# five seconds.
# R3: a delegated pass over a synthetic ledger as long as this host's longest
# run ledger, five times; each within eight seconds.
# ---------------------------------------------------------------------------
IV=2
rid_n=0
first_obs() {
  python3 - "$1" <<'PY'
import calendar, glob, os, sys, time
rd = sys.argv[1]
ts = []
try:
    with open(os.path.join(rd, "stall")) as f:
        line = f.readline().split("\t")[0].strip()
    if line:
        ts.append(calendar.timegm(time.strptime(line, "%Y-%m-%dT%H:%M:%SZ")))
except (OSError, ValueError):
    pass
for p in glob.glob(os.path.join(rd, "watch.announced-*")):
    ts.append(int(os.stat(p).st_mtime))
print(min(ts) if ts else "")
PY
}
arm_ledger() {
  case "$1" in
    after-stage)
      printf -- '- `segment` | id=S1 | 상태=실행중\n- `stage-result` | 세그먼트=S1 | 스테이지=S1 | 종료 코드=0 | 종단 부류=정상 완료\n' ;;
    run-open)
      printf -- '- `run` | run-id=R1 | 시작=2020-01-01T00:00:00Z | prev=x\n' ;;
    silence)
      printf -- '- `segment` | id=S1 | 상태=실행중\n' ;;
  esac
}
arm_args() {
  case "$1" in
    after-stage) echo "--stall 99999 --silence 99999 --after-stage 10 --run-open 99999" ;;
    run-open)    echo "--stall 99999 --silence 99999 --after-stage 10 --run-open 1" ;;
    silence)     echo "--stall 99999 --silence 10 --after-stage 99999 --run-open 99999" ;;
  esac
}
ARMS="after-stage run-open silence"
LOOP_PIDS=""
for arm in $ARMS; do
  rid_n=$((rid_n + 1))
  rid=$(printf '20261121-%08x' "$rid_n")
  rdb="$S/cc-cmds/run/$rid"
  mkdir -p "$rdb/plugin"
  cp -R "$PT" "$rdb/plugin/cc-cmds"
  lgb="$WORK/r1-$arm-b.md"; rda="$WORK/r1-$arm-a"; lga="$WORK/r1-$arm-a.md"
  mkdir -p "$rda"
  arm_ledger "$arm" > "$lga"; arm_ledger "$arm" > "$lgb"
  printf '%s\n' "$lgb" > "$rdb/ledger-path"
  for d in "$rda" "$rdb"; do printf '%s\n' "$(( $(now) - 3600 ))" > "$d/started-at"; done
  eval "R1_A_$rid_n=\$rda; R1_B_$rid_n=\$rdb"
  # shellcheck disable=SC2046
  CC_CMDS_OBSERVER=off bash "$PT/orchestrator/watch.sh" --run-dir "$rda" --ledger "$lga" --interval "$IV" $(arm_args "$arm") >/dev/null 2>&1 &
  LOOP_PIDS="$LOOP_PIDS $!"; STRAYS="$STRAYS $!"
  # shellcheck disable=SC2046
  out=$(bash "$rdb/plugin/cc-cmds/orchestrator/watch.sh" --run-dir "$rdb" --ledger "$lgb" --interval "$IV" $(arm_args "$arm") 2>&1)
  case "$out" in
    *"관측 데몬에 위임했습니다"*) ok "12 R1 $arm: 루프가 관측기에 위임된다" ;;
    *) bad "12 R1 $arm: 루프가 관측기에 위임된다" "$out" ;;
  esac
done
OPID=$(tr -d '[:space:]' < "$S/cc-cmds/observer/observer.pid" 2>/dev/null)
check "12 위임된 런의 watch.pid 는 관측기의 pid" "$(cat "$S/cc-cmds/run/$(printf '20261121-%08x' 1)/watch.pid" 2>/dev/null)" "$OPID"
check "12 관측기가 저장한 작업 인자의 끝에 운반된 배너 스위치가 남는다" \
  "$(tail -n 2 "$S/cc-cmds/run/$(printf '20261121-%08x' 1)/observer.jobs/watch.args" 2>/dev/null | tr '\n' ' ')" \
  "--run-env CC_CMDS_AUTOPILOT_NOTIFY=0 "
deadline=$(( $(now) + 60 ))
i=0
for arm in $ARMS; do
  i=$((i + 1))
  eval "rda=\$R1_A_$i; rdb=\$R1_B_$i"
  ta=""; tb=""
  while [ "$(now)" -lt "$deadline" ]; do
    ta=$(first_obs "$rda"); tb=$(first_obs "$rdb")
    [ -n "$ta" ] && [ -n "$tb" ] && break
    sleep 0.5
  done
  if [ -z "$ta" ] || [ -z "$tb" ]; then
    bad "12 R1 $arm: 두 경로 모두 관측을 남긴다" "루프='$ta' 위임='$tb'"
    continue
  fi
  d=$((tb - ta)); [ "$d" -ge 0 ] || d=$(( -d ))
  printf 'R1: 팔=%s 루프=%s 위임=%s 차이=%s초 (한도 %s초)\n' "$arm" "$ta" "$tb" "$d" $((IV + 5))
  within "12 R1 $arm: 첫 관측 시각 차이가 바퀴 간격 + 5초 이내" "$d" 0 $((IV + 5))
done
for p in $LOOP_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
rdb=$(printf '%s/cc-cmds/run/20261121-%08x' "$S" 1)
sleep 3
within "12 패스 사이에도 관측기가 heartbeat 를 새로 한다" "$(hb_age "$rdb")" 0 3
mode_age() { local m="" e=""; read -r m e < "$1/watch.mode"; echo $(( $(now) - ${e:-0} )); }
within "12 패스 사이에도 관측기가 watch.mode 의 epoch 를 새로 한다" "$(mode_age "$rdb")" 0 3
python3 "$PT/orchestrator/observer.py" stop >/dev/null 2>&1

# R3
r3_lines=4400
if [ -n "${CC_TEST_LEDGER_DIR:-}" ] && [ -d "$CC_TEST_LEDGER_DIR" ]; then
  r3_lines=$(for f in "$CC_TEST_LEDGER_DIR"/*.md; do [ -f "$f" ] && wc -l < "$f"; done | sort -n | tail -1 | tr -d ' ')
fi
fresh
awk -v n="$r3_lines" 'BEGIN {
  print "- `run` | run-id=R3 | 시작=2020-01-01T00:00:00Z | prev=x"
  i = 1
  while (i < n) {
    k = (i % 60) + 1
    r[0] = "- `segment` | id=S" k " | 상태=실행중 | prev=x"
    r[1] = "- `stage-result` | 세그먼트=S" k " | 스테이지=S" k " | 종료 코드=0 | 종단 부류=정상 완료 | prev=x"
    r[2] = "- `cost` | 세그먼트=S" k " | 스테이지=S" k " | 토큰=1000 | prev=x"
    r[3] = "- `승인` | 승인 id=A" i " | 상태=대기 | 막는 세그먼트=S" k " | prev=x"
    r[4] = "- `승인` | 승인 id=A" (i - 1) " | 상태=승인 | prev=x"
    r[5] = "- `act` | 세그먼트=S" k " | 표면=읽기 | 명령=git status | prev=x"
    r[6] = "- `segment` | id=S" k " | 상태=머지됨 | prev=x"
    print r[i % 7]
    i++
  }
}' > "$LG"
r3_max=0; r3_all=""
for _i in 1 2 3 4 5; do
  el=$(python3 - "$WATCH" "$RD" "$LG" "$OBS" <<'PY'
import os, subprocess, sys, time
env = dict(os.environ, CC_OBSERVER_PID=sys.argv[4])
t = time.time()
subprocess.run(["bash", sys.argv[1], "--run-dir", sys.argv[2], "--ledger", sys.argv[3], "--once",
                "--started", str(int(t))], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("%.2f" % (time.time() - t))
PY
)
  r3_all="$r3_all $el"
  awk -v a="$el" -v b="$r3_max" 'BEGIN { exit !(a > b) }' && r3_max=$el
done
printf 'R3: 원장 %s행, 위임된 --once 다섯 번의 소요(초):%s, 최대 %s\n' "$(wc -l < "$LG" | tr -d ' ')" "$r3_all" "$r3_max"
if [ -n "$R3_ON_CI" ]; then
  printf 'R3: CI 호스트라 8초 한도를 단언하지 않는다\n'
elif awk -v a="$r3_max" 'BEGIN { exit !(a <= 8) }'; then
  ok "12 R3 위임된 --once 다섯 번이 각각 8초 이하"
else
  bad "12 R3 위임된 --once 다섯 번이 각각 8초 이하" "최대 ${r3_max}초"
fi

# ---------------------------------------------------------------------------
# 13. The run's own banner switch and seat pane reach the delegated pass.
#
# The observer runs every pass in the environment it was started with, which
# belongs to whichever session started it first. The looping watcher therefore
# appends its own non-empty values of the three per-run names as `--run-env`,
# and the delegated pass reads those and nothing else: a name the loop did not
# send reads as unset there, never as the caller's value. The calling
# environment of each delegated case below is set to differ from what is
# carried, so a pass that read the caller would fail the case.
# ---------------------------------------------------------------------------
running_fixture() {
  fresh
  printf -- '- `segment` | id=S1 | 상태=실행중\n' > "$LG"
}
state_of() { cat "$RD/notify.state" 2>/dev/null || true; }
seat_of()  { cat "$RD/notify.seat" 2>/dev/null || true; }
on_line='배너 켬 (CC_CMDS_AUTOPILOT_NOTIFY)'
off_line='배너 끔 (CC_CMDS_AUTOPILOT_NOTIFY)'
TAB=$(printf '\t')

fresh; : > "$FAKE_LOG"
out=$(FAKE_OBS_RC=0 CC_CMDS_AUTOPILOT_NOTIFY=off TMUX="/tmp/tmux-w/default,4242,3" TMUX_PANE=%48 loop_fake)
check "13 루프는 비지 않은 세 이름을 정한 순서로 덧붙인다" "$(cat "$FAKE_LOG")" \
  "adopt --run-dir $RD --job watch -- --run-dir $RD --ledger $LG --interval 1 --run-env CC_CMDS_AUTOPILOT_NOTIFY=off --run-env TMUX=/tmp/tmux-w/default,4242,3 --run-env TMUX_PANE=%48"
fresh; : > "$FAKE_LOG"
out=$(FAKE_OBS_RC=0 CC_CMDS_AUTOPILOT_NOTIFY= TMUX_PANE= TMUX="/tmp/tmux-w/default,4242,3" loop_fake)
check "13 빈 값은 넘기지 않는다" "$(cat "$FAKE_LOG")" \
  "adopt --run-dir $RD --job watch -- --run-dir $RD --ledger $LG --interval 1 --run-env TMUX=/tmp/tmux-w/default,4242,3"
fresh; : > "$FAKE_LOG"
out=$(env -u CC_CMDS_AUTOPILOT_NOTIFY FAKE_OBS_RC=0 bash "$FT/watch.sh" --run-dir "$RD" --ledger "$LG" --interval 1 2>&1)
check "13 없는 값은 넘기지 않는다" "$(cat "$FAKE_LOG")" \
  "adopt --run-dir $RD --job watch -- --run-dir $RD --ledger $LG --interval 1"

running_fixture
env -u CC_CMDS_AUTOPILOT_NOTIFY CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once --run-env CC_CMDS_AUTOPILOT_NOTIFY=0 >/dev/null 2>&1
check "13 부르는 환경에 스위치가 없어도 운반된 0 이면 notify.state 는 꺼짐" "$(state_of)" "$off_line"
running_fixture
CC_CMDS_AUTOPILOT_NOTIFY=0 CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once >/dev/null 2>&1
check "13 부르는 환경에만 스위치 0 이 있으면 위임된 판은 꺼짐으로 읽지 않는다" "$(state_of)" "$on_line"

ended_fixture
: > "$NOTIFY_LOG"
env -u CC_CMDS_AUTOPILOT_NOTIFY CC_CMDS_NOTIFY_HOST_OS=Darwin CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once --run-env CC_CMDS_AUTOPILOT_NOTIFY=0 >/dev/null 2>&1
rc=$?
sleep 1
check "13 운반된 스위치가 꺼짐이면 끝난 런도 종료 코드 3" "$rc" "3"
check "13 운반된 스위치가 꺼짐이면 배너를 부르지 않는다" "$(grep -c . "$NOTIFY_LOG" || true)" "0"
ended_fixture
: > "$NOTIFY_LOG"
CC_CMDS_AUTOPILOT_NOTIFY=0 CC_CMDS_NOTIFY_HOST_OS=Darwin CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once >/dev/null 2>&1
sleep 1
check "13 운반된 스위치가 없으면 부르는 환경의 0 과 무관하게 끝 배너가 나간다" \
  "$(grep -c . "$NOTIFY_LOG" || true)" "1"

running_fixture
TMUX="/tmp/tmux-o/default,1111,1" TMUX_PANE=%11 CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once \
  --run-env TMUX=/tmp/tmux-w/default,4242,3 --run-env TMUX_PANE=%48 >/dev/null 2>&1
check "13 notify.seat 은 부르는 환경이 아니라 운반된 TMUX·TMUX_PANE 으로 쓴다" "$(seat_of)" \
  "/tmp/tmux-w/default${TAB}4242${TAB}%48"
running_fixture
TMUX="/tmp/tmux-o/default,1111,1" TMUX_PANE=%11 CC_OBSERVER_PID="$OBS" \
  bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once >/dev/null 2>&1
check "13 운반되지 않은 pane 은 부르는 환경의 값으로 기록하지 않는다" \
  "$( [ -e "$RD/notify.seat" ] && printf y || printf n)" "n"
running_fixture
CC_OBSERVER_PID="$OBS" bash "$WATCH" --run-dir "$RD" --ledger "$LG" --once \
  --run-env TMUX_PANE=%1 --run-env TMUX=/tmp/tmux-w/default,4242,3 --run-env TMUX_PANE=%48 >/dev/null 2>&1
check "13 같은 이름이 둘이면 뒤의 것" "$(seat_of)" "/tmp/tmux-w/default${TAB}4242${TAB}%48"

running_fixture
deleg --run-env PATH=/tmp; check "13 런 환경 이름 밖의 이름은 2" "$?" "2"
deleg --run-env TMUX_PANE; check "13 = 이 없는 값은 2" "$?" "2"
deleg --run-env; check "13 값이 없는 --run-env 는 2" "$?" "2"

running_fixture
plain --run-env CC_CMDS_AUTOPILOT_NOTIFY=1; check "13 맨 --once 도 --run-env 를 받아들인다" "$?" "0"
check "13 맨 --once 는 --run-env 로 환경을 바꾸지 않는다" "$(state_of)" "$off_line"

printf '\ntest-observer-watch: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
