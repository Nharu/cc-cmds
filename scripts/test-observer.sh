#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the resident observer: its lifecycle, adoption, the wake FIFOs, the
# usage mark on a pinned copy, and what it must never touch.
#
# EVERYTHING RUNS AGAINST TEMPORARY TREES. The state root is a fresh
# `XDG_STATE_HOME`, and the observer is started from plugin trees this suite
# builds: three versions of one tree (to see a replacement go up and not down),
# each carrying a fixture job module, and a run whose pinned copy is one of
# them. The real plugin tree is only copied from, so a running observer of this
# machine is never judged, replaced or stopped. Every observer started here is
# stopped by the exit trap.
#
# THE STAGE GUARD IS CLEARED, AND ONE PIPELINE VARIABLE IS PLANTED. `ensure`
# starts nothing inside a stage, and this suite is run from one, so the two
# variables that mark a stage are unset; `CC_PIPELINE_RUN_ID` is then set to a
# value the fixture job must never see, which is what case 9 asserts.
#
# Usage: bash scripts/test-observer.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
for _v in $(compgen -e); do
  case "$_v" in CC_PIPELINE_*) unset "$_v" ;; esac
done
unset CI CC_CMDS_OBSERVER _v
CC_PIPELINE_RUN_ID=leak-from-caller
export CC_PIPELINE_RUN_ID

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
# shellcheck source=wait-fixture.sh
. "$repo_root/scripts/wait-fixture.sh"
ORCH="$repo_root/plugins/cc-cmds/orchestrator"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: python3 가 없다 — 관측기를 띄울 수 없다\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-observer-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
S="$WORK/state"
export XDG_STATE_HOME="$S"
export CC_OBSERVER_PERIOD=0.3 CC_OBSERVER_GRACE=600
mkdir -p "$S/cc-cmds/run" "$S/cc-cmds/session"

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
differ(){ if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "두 값이 같다: '$2'"; fi; }

# Every state root an observer was started under, so the trap can stop each.
ROOTS="$S"
cleanup() {
  local r p
  for r in $ROOTS; do
    p=$(cat "$r/cc-cmds/observer/observer.pid" 2>/dev/null || true)
    [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
    XDG_STATE_HOME="$r" python3 "$TA/orchestrator/observer.py" stop >/dev/null 2>&1
  done
  for p in $STRAYS; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
STRAYS=""
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The trees
# ---------------------------------------------------------------------------

# The fixture job. It records what the judging call saw — the observer's pid and
# the names of any pipeline variable — through the run's own pinned script, and
# probes one file of its own so case 8 can move it.
make_tree() {
  local d="$1" v="$2"
  mkdir -p "$d/.claude-plugin" "$d/orchestrator"
  cp "$ORCH/observer.py" "$ORCH/observer-protocol" "$d/orchestrator/"
  printf '{"name":"cc-cmds","version":"%s"}\n' "$v" > "$d/.claude-plugin/plugin.json"
  cat > "$d/orchestrator/observer_fixt.py" <<'PY'
import os

JOB = "fixt"
PID_FILE = "fixt.pid"


def probes(run):
    return ["fixt.probe"]


def tick(ctx, run, changed, now):
    rc, out = ctx.call(run, ["fixt.sh"], 5)
    tmp = os.path.join(run, ".fixt.seen.tmp")
    with open(tmp, "w") as f:
        f.write("rc=%d\n%s" % (rc, out))
    os.rename(tmp, os.path.join(run, "fixt.seen"))
    return None
PY
  cat > "$d/orchestrator/fixt.sh" <<'SH'
printf 'observer=%s\n' "${CC_OBSERVER_PID:-}"
for v in $(compgen -e); do
  case "$v" in CC_PIPELINE_*) printf 'leak=%s\n' "$v" ;; esac
done
SH
}

TA="$WORK/tree-a"; make_tree "$TA" 1.0.0
TB="$WORK/tree-b"; make_tree "$TB" 1.1.0
TC="$WORK/tree-c"; make_tree "$TC" 0.9.0
OA="$TA/orchestrator/observer.py"
OB="$TB/orchestrator/observer.py"
OC="$TC/orchestrator/observer.py"

# The run: a pinned copy of tree B, a ledger outside the run directory, and a
# session index naming it.
RID=20261101-0000000a
RD="$S/cc-cmds/run/$RID"
mkdir -p "$RD/plugin" "$WORK/docs"
cp -R "$TB" "$RD/plugin/cc-cmds"
LEDGER="$WORK/docs/$RID.md"
printf '# 원장\n\n- `2026-11-01T00:00:00Z` 시작\n' > "$LEDGER"
printf '%s\n' "$LEDGER" > "$RD/ledger-path"
printf '%s\n' "$RID" > "$S/cc-cmds/session/sess1"
ledger_sum0=$(cksum < "$LEDGER")

# The notifier stubs, first on PATH. Nothing here may reach them.
STUB="$WORK/stub"; mkdir -p "$STUB"
NOTE_LOG="$WORK/notifier.log"
for n in terminal-notifier osascript; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$n" "$NOTE_LOG" > "$STUB/$n"
  chmod +x "$STUB/$n"
done
export PATH="$STUB:$PATH"

st()     { python3 "$1" status 2>/dev/null; }
opid()   { cat "$S/cc-cmds/observer/observer.pid" 2>/dev/null | tr -d '[:space:]'; }
rec_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
             "$S/cc-cmds/observer/record.json" "$1" 2>/dev/null; }
mode_of(){ python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1" 2>/dev/null; }
age_back(){ python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
alive()  { kill -0 "$1" 2>/dev/null; }

is_running(){ [ "$(st "$1")" = running ]; }
file_is()   { [ "$(tr -d '[:space:]' < "$1" 2>/dev/null)" = "$2" ]; }

# ---------------------------------------------------------------------------
# 1. ensure starts it
# ---------------------------------------------------------------------------
python3 "$OA" ensure; check "1 ensure 는 0 으로 끝난다" "$?" 0
wait_until is_running "$OA"
check "1 status 가 running" "$(st "$OA")" running
P1=$(rec_of pid)
check "1 record.json 의 열쇠 여섯" \
  "$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])))))' "$S/cc-cmds/observer/record.json")" \
  "fingerprint,pid,root,schema,started,version"
check "1 record.json 은 0600" "$(mode_of "$S/cc-cmds/observer/record.json")" 0o600
check "1 상태 디렉터리는 0700" "$(mode_of "$S/cc-cmds/observer")" 0o700
check "1 observer.pid 가 그 pid" "$(opid)" "$P1"
check "1 기록의 판본이 기동한 트리의 판본" "$(rec_of version)" 1.0.0

# ---------------------------------------------------------------------------
# 2. versions: same keeps, lower keeps, higher replaces
# ---------------------------------------------------------------------------
python3 "$OA" ensure
check "2 같은 판본의 ensure 는 pid 를 바꾸지 않는다" "$(rec_of pid)" "$P1"
python3 "$OC" ensure
check "2 낮은 판본의 ensure 는 손대지 않는다" "$(rec_of pid)" "$P1"
python3 "$OB" ensure
P2=$(rec_of pid)
differ "2 높은 판본의 ensure 는 교체한다" "$P2" "$P1"
check "2 교체한 기록의 판본" "$(rec_of version)" 1.1.0
if alive "$P1"; then bad "2 옛 데몬이 내려갔다" "pid $P1 가 살아 있다"; else ok "2 옛 데몬이 내려갔다"; fi
wait_until is_running "$OB"

# ---------------------------------------------------------------------------
# 3. a stopped observer is hung, and ensure replaces it
# ---------------------------------------------------------------------------
kill -STOP "$P2"; STRAYS="$STRAYS $P2"
age_back "$S/cc-cmds/observer/heartbeat" 31
check "3 SIGSTOP 과 31초 전 heartbeat 이면 hung" "$(st "$OB")" hung
python3 "$OB" ensure
P3=$(rec_of pid)
differ "3 hung 이면 ensure 가 교체한다" "$P3" "$P2"
if alive "$P2"; then bad "3 멈춘 데몬은 KILL 로 내려갔다" "pid $P2 가 살아 있다"; else ok "3 멈춘 데몬은 KILL 로 내려갔다"; fi
wait_until is_running "$OB"
check "3 새 데몬이 running" "$(st "$OB")" running

# ---------------------------------------------------------------------------
# 4. the off switches and the stage guard
# ---------------------------------------------------------------------------
off_case() {
  local label="$1"; shift
  local r="$WORK/off-$label"
  mkdir -p "$r/cc-cmds/run" "$r/cc-cmds/session"
  env XDG_STATE_HOME="$r" "$@" python3 "$OA" ensure; check "4 $label: ensure 는 0" "$?" 0
  if [ -e "$r/cc-cmds/observer/ensure.at" ] || [ -e "$r/cc-cmds/observer/record.json" ]; then
    bad "4 $label: ensure.at 도 기록도 생기지 않는다" "$(ls "$r/cc-cmds/observer" 2>/dev/null | tr '\n' ' ')"
  else
    ok "4 $label: ensure.at 도 기록도 생기지 않는다"
  fi
}
off_case off CC_CMDS_OBSERVER=off
check "4 off: status 가 off" "$(env CC_CMDS_OBSERVER=off XDG_STATE_HOME="$WORK/off-off" python3 "$OA" status)" off
env CC_CMDS_OBSERVER=off python3 "$OB" adopt --run-dir "$RD" --job fixt -- x 2>/dev/null
differ "4 off: adopt 는 0 이 아니다" "$?" 0
off_case ci CI=1
check "4 CI: status 가 off" "$(env CI=1 XDG_STATE_HOME="$WORK/off-ci" python3 "$OA" status)" off
env CI=1 python3 "$OB" adopt --run-dir "$RD" --job fixt -- x 2>/dev/null
differ "4 CI: adopt 는 0 이 아니다" "$?" 0
off_case stage CC_PIPELINE_STAGE_ID=A#1
off_case segment CC_PIPELINE_SEGMENT=A

# ---------------------------------------------------------------------------
# 5. the grace ends an idle observer
# ---------------------------------------------------------------------------
G="$WORK/grace"; mkdir -p "$G/cc-cmds/run" "$G/cc-cmds/session"; ROOTS="$ROOTS $G"
env XDG_STATE_HOME="$G" CC_OBSERVER_GRACE=1 CC_OBSERVER_PERIOD=0.2 python3 "$OA" ensure
GP=$(cat "$G/cc-cmds/observer/observer.pid" 2>/dev/null | tr -d '[:space:]')
gone() { ! alive "$GP"; }
if [ -n "$GP" ] && wait_until gone; then ok "5 등록도 채택도 없으면 유예 뒤 끝난다"; else bad "5 유예 종료" "pid ${GP:-없음}"; fi
if [ -e "$G/cc-cmds/observer/record.json" ] || [ -e "$G/cc-cmds/observer/observer.pid" ]; then
  bad "5 유예 종료 뒤 기록과 observer.pid 가 없다" "$(ls "$G/cc-cmds/observer" | tr '\n' ' ')"
else
  ok "5 유예 종료 뒤 기록과 observer.pid 가 없다"
fi

# ---------------------------------------------------------------------------
# 6. adopt, and what it refuses
# ---------------------------------------------------------------------------
python3 "$OB" adopt --run-dir "$RD" --job fixt -- --run-dir "$RD" --interval 60
check "6 픽스처 작업의 adopt 는 0" "$?" 0
P3=$(opid)
check "6 pid 파일이 데몬 pid 를 담는다" "$(cat "$RD/fixt.pid" 2>/dev/null)" "$P3"
check "6 args 파일이 인자를 한 줄씩 담는다" "$(cat "$RD/observer.jobs/fixt.args" 2>/dev/null | tr '\n' '|')" \
  "--run-dir|$RD|--interval|60|"
check "6 observer.wake.d 는 0700" "$(mode_of "$RD/observer.wake.d")" 0o700

RN="$S/cc-cmds/run/20261101-0000000b"
mkdir -p "$RN/plugin"; cp -R "$TB" "$RN/plugin/cc-cmds"; rm -f "$RN/plugin/cc-cmds/orchestrator/observer-protocol"
python3 "$OB" adopt --run-dir "$RN" --job fixt -- x 2>/dev/null
differ "6 표지가 없는 런은 0 이 아니다" "$?" 0
python3 "$OB" adopt --run-dir "$RD" --job nope -- x 2>/dev/null
differ "6 모르는 작업은 0 이 아니다" "$?" 0
RO="$WORK/elsewhere/20261101-0000000c"
mkdir -p "$RO/plugin"; cp -R "$TB" "$RO/plugin/cc-cmds"
python3 "$OB" adopt --run-dir "$RO" --job fixt -- x 2>/dev/null
differ "6 런 루트 밖의 런 디렉터리는 0 이 아니다" "$?" 0
ln -s "$RD" "$S/cc-cmds/run/20261101-0000000d"
python3 "$OB" adopt --run-dir "$S/cc-cmds/run/20261101-0000000d" --job fixt -- x 2>/dev/null
differ "6 심볼릭 링크인 런 디렉터리는 0 이 아니다" "$?" 0
RL="$S/cc-cmds/run/20261101-0000000e"
mkdir -p "$RL"; ln -s "$TB" "$RL/plugin"
python3 "$OB" adopt --run-dir "$RL" --job fixt -- x 2>/dev/null
differ "6 고정 사본이 런 밖을 가리키는 런은 0 이 아니다" "$?" 0

# ---------------------------------------------------------------------------
# 9. what the judging call saw
# ---------------------------------------------------------------------------
seen_ok() { grep -q "^observer=$(opid)\$" "$RD/fixt.seen" 2>/dev/null; }
wait_until seen_ok
check "9 판정 호출의 CC_OBSERVER_PID 가 데몬 pid" "$(sed -n 's/^observer=//p' "$RD/fixt.seen" 2>/dev/null)" "$(opid)"
check "9 판정 호출의 환경에 CC_PIPELINE_* 가 없다" "$(grep -c '^leak=' "$RD/fixt.seen" 2>/dev/null)" 0

# ---------------------------------------------------------------------------
# 8. the wake FIFOs
# ---------------------------------------------------------------------------
WD="$RD/observer.wake.d"
FIFO="$WD/test.$$.fifo"
mkfifo -m 600 "$FIFO"
exec 7<>"$FIFO"
drain() { while read -r -t 1 -u 7 _; do :; done; }
# One byte read off the wake FIFO; `wait_until` repeats it until a byte comes.
wake_byte() { read -r -t 1 -u 7 _; }
sleep 1; drain
printf '1\n' > "$RD/fixt.probe"
if wait_until wake_byte; then ok "8 탐침이 바뀌면 FIFO 에 한 바이트가 온다"; else bad "8 탐침 변화의 깨움" "공용 상한 안에 오지 않았다"; fi
# Three changes, a period apart, with nothing read in between; the first byte is
# waited for, and what is left is counted over a quiet window.
printf '2\n' > "$RD/fixt.probe"; sleep 0.8
printf '3\n' > "$RD/fixt.probe"; sleep 0.8
printf '4\n' > "$RD/fixt.probe"; sleep 0.8
got=0
wait_until wake_byte && got=1
while read -r -t 1 -u 7 _; do got=$((got + 1)); done
check "8 읽지 않은 채 세 번 바꿔도 read 는 한 번만 성공한다" "$got" 1

true & DEADP=$!; wait "$DEADP" 2>/dev/null
mkfifo -m 600 "$WD/dead.$DEADP.fifo"
dead_gone() { [ ! -e "$WD/dead.$DEADP.fifo" ]; }
if wait_until dead_gone; then ok "8 주인 pid 가 죽은 FIFO 는 지워진다"; else bad "8 죽은 주인의 FIFO" "남아 있다"; fi

mkfifo -m 600 "$WD/noreader.$$.fifo"
printf '5\n' > "$RD/fixt.probe"
if wait_until wake_byte; then ok "8 읽는 쪽이 없는 FIFO 앞에서 바퀴가 막히지 않는다"; else bad "8 읽는 쪽 없는 FIFO" "다른 FIFO 의 깨움이 오지 않았다"; fi
rm -f "$WD/noreader.$$.fifo"

printf 'pid=1\nrefreshed=100\n' > "$RD/relay.live"
sleep 1; drain
printf 'pid=1\nrefreshed=200\n' > "$RD/relay.live"
if read -r -t 2 -u 7 _; then bad "8 relay.live 의 refreshed= 만 바뀐 것은 깨우지 않는다" "깨움이 왔다"; else ok "8 relay.live 의 refreshed= 만 바뀐 것은 깨우지 않는다"; fi
printf 'pid=2\nrefreshed=300\n' > "$RD/relay.live"
if wait_until wake_byte; then ok "8 relay.live 의 다른 내용이 바뀌면 깨운다"; else bad "8 relay.live 내용 변화" "깨움이 오지 않았다"; fi
exec 7>&-
rm -f "$FIFO"

# ---------------------------------------------------------------------------
# 7. a killed observer is replaced and the new one re-adopts from the index
# ---------------------------------------------------------------------------
P4=$(opid)
kill -KILL "$P4"
gone4() { ! alive "$P4"; }
wait_until gone4
python3 "$OB" ensure
P5=$(opid)
differ "7 KILL 뒤 ensure 는 새 데몬을 띄운다" "$P5" "$P4"
readopted() { file_is "$RD/fixt.pid" "$P5"; }
if wait_until readopted; then ok "7 새 데몬이 세션 색인으로 그 런을 다시 채택해 pid 파일을 다시 쓴다"
else bad "7 재채택" "fixt.pid=$(cat "$RD/fixt.pid" 2>/dev/null), 데몬=$P5"; fi

# ---------------------------------------------------------------------------
# 10. the usage mark of a pinned copy
# ---------------------------------------------------------------------------
python3 "$OB" stop
check "10 stop 뒤 기록이 없다" "$(ls "$S/cc-cmds/observer/record.json" 2>/dev/null)" ""
if [ -e "$RD/fixt.pid" ]; then bad "10 stop 은 작업 pid 파일을 지운다" "남아 있다"; else ok "10 stop 은 작업 pid 파일을 지운다"; fi
if [ -e "$RD/observer.jobs/fixt.args" ]; then ok "10 stop 뒤에도 args 는 남는다(재기동 복원)"; else bad "10 args 보존" "지워졌다"; fi
OP="$RD/plugin/cc-cmds/orchestrator/observer.py"
python3 "$OP" ensure
wait_until is_running "$OP"
P6=$(opid)
check "10 고정 사본으로 뜬 데몬이 사용 표지에 자기 pid 를 쓴다" "$(sed -n 's/^pid=//p' "$RD/observer.code-inuse" 2>/dev/null)" "$P6"
fp_want=$(LC_ALL=C ps -o lstart= -p "$P6" | tr -s ' ' | sed 's/^ //; s/ $//')
check "10 사용 표지의 지문이 ps lstart" "$(sed -n 's/^fingerprint=//p' "$RD/observer.code-inuse" 2>/dev/null)" "$fp_want"
check "10 사용 표지는 0600" "$(mode_of "$RD/observer.code-inuse")" 0o600
python3 "$OP" stop
if [ -e "$RD/observer.code-inuse" ]; then bad "10 stop 뒤 사용 표지가 지워진다" "남아 있다"; else ok "10 stop 뒤 사용 표지가 지워진다"; fi

# ---------------------------------------------------------------------------
# 11. what it never touched
# ---------------------------------------------------------------------------
check "11 픽스처 런의 원장 바이트가 그대로다" "$(cksum < "$LEDGER")" "$ledger_sum0"
if [ -e "$RD/halt" ]; then bad "11 halt/ 가 생기지 않는다" "생겼다"; else ok "11 halt/ 가 생기지 않는다"; fi
if [ -s "$NOTE_LOG" ]; then bad "11 알림 도구 스텁이 불리지 않는다" "$(cat "$NOTE_LOG")"; else ok "11 알림 도구 스텁이 불리지 않는다"; fi

# ---------------------------------------------------------------------------
# 12. a batch job keeps a slot while the ticks are slow
# ---------------------------------------------------------------------------
# Six runs whose tick holds its slot for a second and is due again at once, and
# one run of a batch job, are passed through `observe` and `batch` the way
# `one_pass` orders them. With one shared limit the ticks of the previous pass
# still held every slot whenever `batch` looked, so the batch never ran.
out=$(python3 - "$ORCH" "$WORK/slots" <<'PY'
import os, sys, threading, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import observer

base = sys.argv[2]
mu = threading.Lock()
live = {"n": 0, "max": 0}
calls = []


class Slow:
    PID_FILE = "slow.pid"

    @staticmethod
    def probes(run):
        return []

    @staticmethod
    def tick(ctx, run, changed, now):
        with mu:
            live["n"] += 1
            live["max"] = max(live["max"], live["n"])
        time.sleep(1.0)
        with mu:
            live["n"] -= 1
        return time.time()


class Batched:
    PID_FILE = "batched.pid"

    @staticmethod
    def probes(run):
        return []

    @staticmethod
    def tick(ctx, run, changed, now):
        return None

    @staticmethod
    def batch(ctx, runs, now):
        calls.append(now)


d = observer.Daemon()
d.mods = {"slow": Slow, "batched": Batched}
for i in range(7):
    rd = os.path.join(base, "r%d" % i)
    os.makedirs(rd)
    r = observer.Run(rd)
    r.jobs["batched" if i == 6 else "slow"] = observer.Job([])
    d.runs[rd] = r
end = time.time() + 3.0
while time.time() < end:
    now = time.time()
    for r in list(d.runs.values()):
        d.observe(r, now)
    d.batch(now)
    time.sleep(0.1)
print("batches=%d" % len(calls))
print("maxticks=%d" % live["max"])
print("limit=%d" % observer.CHILD_LIMIT)
PY
)
n=$(printf '%s\n' "$out" | sed -n 's/^batches=//p')
if [ "${n:-0}" -ge 10 ]; then ok "12 틱이 슬롯을 붙잡고 있어도 일괄 질의가 주기마다 돈다"
else bad "12 틱이 슬롯을 붙잡고 있어도 일괄 질의가 주기마다 돈다" "3초 동안 batch ${n:-0}번"; fi
lim=$(printf '%s\n' "$out" | sed -n 's/^limit=//p')
check "12 쉬고 있는 일괄 잡 몫으로 틱은 상한보다 하나 적게 돈다" \
  "$(printf '%s\n' "$out" | sed -n 's/^maxticks=//p')" "$(( ${lim:-4} - 1 ))"

printf '\ntest-observer: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
