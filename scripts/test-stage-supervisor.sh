#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The detached stage supervisor — survival, ordering and the launch token.
#
# WHY THIS SUITE EXISTS SEPARATELY. The gate suite drives verbs against fixture
# ledgers and never needs a process to outlive anything. What this file asserts
# is exactly that: a dispatched stage surviving the death of the process tree
# that dispatched it. That needs a stub CLI that runs for seconds, real pids,
# and an enemy that kills the way the harness does — none of which belongs in a
# fixture suite.
#
# THE ENEMY WALKS `ppid`. The harness reaps a tracked background job by
# collecting its descendants through the parent-pid relation and signalling
# them — not by process group, not by SIGHUP. Measured: a `setsid` grandchild
# with its own session and its own group died because its parent was alive when
# the walk ran, and a double-forked grandchild reparented to init survived. The
# short `treekill` below reproduces that discrimination without a nested
# session.
#
# THE CONTROL IS NOT OPTIONAL. A "survived" assertion passes vacuously the
# moment the enemy silently finds nothing — measured during the design work,
# both arms once reported survival because the walk had matched no descendant.
# So the same enemy is also pointed at a child that keeps its lineage, and that
# child must die.
#
# Usage: bash scripts/test-stage-supervisor.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_SESSION_NOTIFY=0
export CC_CMDS_SESSION_NOTIFY
# THIS SUITE IS OFTEN RUN FROM INSIDE A PIPELINE STAGE, and the gate reads the
# seat markers from the environment: an inherited stage id would make every
# fixture call below a stage's call.
unset CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST CC_PIPELINE_LEDGER \
      CC_PIPELINE_GRANT CC_PIPELINE_GATE CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT \
      CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_PARENT_SESSION
# The compaction-window kill switch would turn the `(argv)` assertions below
# into a property of the caller's shell rather than of the gate, and the effort
# and model switches would do the same to every launch argv.
unset CC_ORCH_STAGE_AUTOCOMPACT CC_ORCH_STAGE_EFFORT CC_ORCH_STAGE_MODEL

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-stage-supervisor.XXXXXX")
export XDG_STATE_HOME="$WORK/state"
# A run opened where an account inventory exists is routed, so the config root
# the inventory is read under is moved off the host's: every run below is
# unrouted until (12) plants an inventory of its own.
export XDG_CONFIG_HOME="$WORK/config"
KILL_LIST=""
cleanup() {
  local p f
  for p in $KILL_LIST; do kill -TERM "$p" 2>/dev/null || true; done
  # The supervisors and stubs this suite detached are not its children, so they
  # are found through the run directory rather than through the shell's jobs.
  for f in "$XDG_STATE_HOME"/cc-cmds/run/*/*.sup "$XDG_STATE_HOME"/cc-cmds/run/*/*.pid; do
    [ -f "$f" ] || continue
    kill -TERM "$(tr -d '[:space:]' < "$f")" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && printf 'alive' || printf 'dead'; }

# ---------------------------------------------------------------------------
# Fixture — a repository outside this checkout, one target, one run at a time.
# ---------------------------------------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@example.invalid && git config user.name T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant && echo one > a.txt && git add -A \
  && git commit -qm one && git branch -M main ) >/dev/null 2>&1
WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
row="- \`target\` | 별칭=repo | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/t | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n' "$row" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'; PD0=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)

# mk_run <run-id> <document key> — one manifest, one grant, one empty ledger and
# one run directory, all keyed by the run id, and the globals every helper below
# reads (`RUN`, `MANIFEST`, `LEDGER`, `RD`) pointed at them. The document key is
# the manifest's `설계 문서` value: `(없음)`, a repo-relative path, or an absolute
# path with the leading `/` removed — the three shapes the shared contract
# defines. The header's `owner-doc=` must equal the body's value or the
# manifest is refused, so one argument fills both. The grant's frozen digest is
# the real one when the document exists, because the gate reads that field for
# presence and the recorder copies it into the `문서 해시` row.
mk_run() {
  local run="$1" key="$2" dl="${3:-2030-01-01T00:00:00Z}" docfile="" dsha='(해당 없음)'
  RUN="$run"
  MANIFEST="$WT/plan-$RUN.md"
  LEDGER="$WT/docs/pipeline-run/$RUN.md"
  RD="$XDG_STATE_HOME/cc-cmds/run/$RUN"
  case "$key" in
    '(없음)') : ;;
    *) if [ -f "$WT/$key" ]; then docfile="$WT/$key"; elif [ -f "/$key" ]; then docfile="/$key"; fi ;;
  esac
  [ -z "$docfile" ] || dsha=$(shasum -a 256 "$docfile" | cut -d' ' -f1)
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$RUN"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$RUN"
    printf '     anchor-kind=repo; anchor-key=t/t;\n'
    printf '     owner-doc=%s; origin-worktree=%s;\n' "$key" "$WT"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: %s\n' "$RUN"
    printf '**앵커 종류**: repo\n**앵커 키**: t/t\n**사용자 확인 문면**: 테스트 픽스처\n\n'
    printf '## 의도\n```text\n테스트\n```\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$TD" "$row"
    printf '## 요소\n**설계 문서**: %s\n' "$key"
    [ -z "$docfile" ] || printf '**설계 문서 전체 sha256**: %s\n' "$dsha"
    printf '**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 테스트\n```json\n%s\n```\n\n' "$PD0" "$PLAN"
    printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 픽스처가 끝나면\n'
    printf '**벽시계 마감**: %s\n**시각 정합 마커**: 없음\n' "$dl"
    printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
  } > "$MANIFEST"
  cat > "$WT/docs/pipeline-grant/$RUN.md" <<GRANTEOF
# 파이프라인 인가 기록 — $RUN
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=$key; origin-worktree=$WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 $RUN
**인가 일시**: 2026-01-01T00:00:00Z
**종료 지점**: 픽스처가 끝나면
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 테스트 픽스처
**설계 문서 전체 sha256**: $dsha
**보고서**: $WT/docs/pipeline-run/$RUN.md
GRANTEOF
  : > "$LEDGER"
  g snapshot --manifest "$MANIFEST" >/dev/null
  if [ ! -d "$RD" ]; then
    printf 'fixture: 런 디렉터리가 만들어지지 않았습니다 — %s\n' "$RD" >&2
    exit 1
  fi
}

# The stub CLI. Runs for CC_STUB_SLEEP seconds and reports a normal result; a
# TERM ends it at once with 143 and no result line — the shape of a stage
# stopped from outside. The `sleep` runs in the background so the trap is taken
# immediately rather than after the sleep.
STUB="$WORK/claude-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
sleep "${CC_STUB_SLEEP:-3}" &
sp=$!
trap 'kill "$sp" 2>/dev/null; exit 143' TERM
wait "$sp"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"num_turns":1,"session_id":"stub-session"}'
exit 0
STUBEOF
chmod +x "$STUB"
export CC_CLAUDE_BIN="$STUB"

HH() { ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null | jq -r .H ); }
g()  { ( cd "$WT" && bash "$GATE" "$@" 2>&1 ); }
seg() {
  g act --manifest "$MANIFEST" --kind segment --target repo --segment "$1" --cutpoint 커밋 \
    --surface 읽기 --snapshot-digest "$(HH)" --rationale "픽스처 세그먼트" \
    -- 워크트리="$WT" 상태=실행중 선행=없음 >/dev/null
}
dispatch() {
  g act --manifest "$MANIFEST" --kind skill --target repo --segment "$1" --cutpoint 커밋 \
    --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale "픽스처 파견" \
    -- review -p "/cc-cmds:review-unattended x"
}
rows_of() { { grep -F '`stage-result`' "$LEDGER" || true; } | { grep -cF "세그먼트=$1 " || true; }; }
wait_file() {  # wait_file <path> <tenths> — poll until the file exists
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$1" ]
}

# THE ENEMY. Every descendant of <root> found by walking `ppid` transitively,
# then TERM to all of them — the shape of the harness's reap, measured.
treekill() {
  local all="$1" changed=1 p
  while [ "$changed" = 1 ]; do
    changed=0
    for p in $(ps -o pid=,ppid= -A | awk -v s=" $all " 'index(s, " " $2 " ") && !index(s, " " $1 " ") { print $1 }'); do
      all="$all $p"; changed=1
    done
  done
  for p in $all; do kill -TERM "$p" 2>/dev/null || true; done
}

mk_run SUP1 '(없음)'

# ---------------------------------------------------------------------------
# (1)–(3), (5), (8) — one dispatch, issued from a launcher the enemy then kills.
# ---------------------------------------------------------------------------
seg A
LAUNCH="$WORK/launcher.sh"
cat > "$LAUNCH" <<'LEOF'
#!/usr/bin/env bash
# launcher.sh <worktree> <gate> <manifest> <segment> <digest> <out>
cd "$1" || exit 1
t0=$(date +%s)
bash "$2" act --manifest "$3" --kind skill --target repo --segment "$4" --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$5" --rationale "픽스처 파견" \
  -- review -p "/cc-cmds:review-unattended x" > "$6" 2>&1
rc=$?
t1=$(date +%s)
printf '%s %s\n' "$rc" "$((t1 - t0))" > "$6.done"
sleep 120
LEOF
CC_STUB_SLEEP=10 bash "$LAUNCH" "$WT" "$GATE" "$MANIFEST" A "$(HH)" "$WORK/launch-A.out" &
LA=$!; KILL_LIST="$KILL_LIST $LA"
if ! wait_file "$WORK/launch-A.out.done" 200; then
  bad "(1) 파견 반환" "20초 안에 파견 act 가 돌아오지 않았다: $(cat "$WORK/launch-A.out" 2>/dev/null)"
fi
a_rc=""; a_el=""
read -r a_rc a_el < "$WORK/launch-A.out.done" 2>/dev/null || true
check "(1) 파견 act 가 성공으로 반환한다" "${a_rc:-none}" "0"
if [ -n "$a_el" ] && [ "$a_el" -lt 10 ]; then
  ok "(1) 파견이 스테이지 종단 전에 반환한다 (${a_el}초 < 스텁 10초)"
else
  bad "(1) 파견이 스테이지 종단 전에 반환한다" "경과 ${a_el:-없음}초 — 파견이 스테이지를 막고 있다"
fi

SUP_A=$( { cat "$RD/A.sup" 2>/dev/null || true; } | tr -d '[:space:]')
check "(2) 반환 직후 감독자가 살아 있다" "$(alive "$SUP_A")" "alive"
check "(2) 감독자의 부모는 init 이다 (혈통이 끊겼다)" \
  "$(ps -o ppid= -p "${SUP_A:-0}" 2>/dev/null | tr -d '[:space:]')" "1"
for f in pid start kind window; do
  check "(2) 반환 직후 A.$f 가 있다" "$( [ -f "$RD/A.$f" ] && printf 'yes' || printf 'no')" "yes"
done
# The window record is the recorder's fallback: two lines, the effective window
# and the lane, written before the CLI is launched.
check "(2) A.window 의 첫 줄이 argv 출처의 창이다" \
  "$(sed -n '1p' "$RD/A.window" 2>/dev/null)" "300000(argv)"
check "(2) A.window 는 두 줄이다 (가드 0)" "$(wc -l < "$RD/A.window" 2>/dev/null | tr -d '[:space:]')" "2"
# The row's lane is read from this record, never re-resolved by the process
# that writes the row. The supervisor inherits the launch's environment, so a
# re-resolving recorder would print the same lane by coincidence; replacing the
# recorded lane with one no environment resolves to is what tells them apart.
# Line 1 is kept as written; the swap is a rename so the recorder never reads a
# half-written file.
A_WIN=$(sed -n '1p' "$RD/A.window" 2>/dev/null)
printf '%s\n%s\n' "$A_WIN" '~/lane-recorded' > "$RD/A.window.tmp" && mv -f "$RD/A.window.tmp" "$RD/A.window"
PID_A=$( { cat "$RD/A.pid" 2>/dev/null || true; } | tr -d '[:space:]')

# (3) THE ENEMY, pointed at the process that issued the dispatch.
treekill "$LA"
wait "$LA" 2>/dev/null || true
sleep 1
check "(3) 적이 파견 셸을 실제로 죽였다" "$(alive "$LA")" "dead"
check "(3) 트리 워크 적 뒤에도 감독자가 살아 있다" "$(alive "$SUP_A")" "alive"
check "(3) 트리 워크 적 뒤에도 CLI 가 살아 있다" "$(alive "$PID_A")" "alive"

# (4) THE CONTROL — a child that keeps its lineage dies to the same enemy.
CTRL="$WORK/control.sh"
cat > "$CTRL" <<'CEOF'
#!/usr/bin/env bash
sleep 120 &
printf '%s\n' "$!" > "$1"
sleep 120
CEOF
bash "$CTRL" "$WORK/control.pid" &
LC=$!; KILL_LIST="$KILL_LIST $LC"
wait_file "$WORK/control.pid" 50 || true
CPID=$( { cat "$WORK/control.pid" 2>/dev/null || true; } | tr -d '[:space:]')
KILL_LIST="$KILL_LIST $CPID"
check "(4) 대조군 자식이 적 앞에서 살아 있었다" "$(alive "$CPID")" "alive"
treekill "$LC"
wait "$LC" 2>/dev/null || true
sleep 1
check "(4) 대조군 — 혈통을 남긴 자식은 같은 적에 죽는다" "$(alive "$CPID")" "dead"

# (8) RECORD FIRST, REMOVE AFTER. Sampled until the row lands: once `A.pid` has
# been seen, its absence must never coincide with the row's absence. The row is
# re-read after the pid is seen gone, because the append can land between the
# two reads of one sample.
seen_pid=0; order_bad=""; n=0
while [ "$n" -lt 400 ]; do
  r=$(rows_of A)
  if [ -f "$RD/A.pid" ]; then
    seen_pid=1
  elif [ "$seen_pid" = "1" ] && [ "$r" = "0" ]; then
    r=$(rows_of A)
    if [ "$r" = "0" ]; then order_bad="A.pid 가 사라졌는데 stage-result 행이 없다"; break; fi
  fi
  [ "$r" != "0" ] && break
  sleep 0.05; n=$((n + 1))
done
check "(8) 기록-후-삭제 — pid 기록이 행보다 먼저 사라지지 않는다" "${order_bad:-ok}" "ok"
check "(8) 그 관측이 실제로 pid 기록을 본 뒤의 것이다" "$seen_pid" "1"

# (5) + (3) — the re-attachment verb, after the dispatcher is gone.
g wait --manifest "$MANIFEST" --segment A --interval 1 --timeout 60 >/dev/null; wait_rc=$?
check "(3) 적 뒤에도 wait 이 스테이지 rc 0 으로 끝난다" "$wait_rc" "0"
check "(3) stage-result 행이 정확히 하나" "$(rows_of A)" "1"
# The row names its writer and carries the window the launch actually got. This
# is the only suite in which the supervisor writes that row across a process
# boundary, so the field must be read off the real row rather than an in-process
# recorder call.
row_a=$( { grep -F '`stage-result`' "$LEDGER" || true; } | { grep -F '세그먼트=A ' || true; } | sed -n '1p')
case "$row_a" in
  *"기록자=게이트 "*|*"기록자=게이트") ok "(3) 감독자가 쓴 행은 기록자=게이트 다" ;;
  *) bad "(3) 감독자가 쓴 행은 기록자=게이트 다" "$row_a" ;;
esac
case "$row_a" in
  *"압축 창=300000(argv) "*) ok "(3) 감독자가 쓴 행은 기동에 실린 창을 적는다" ;;
  *) bad "(3) 감독자가 쓴 행은 기동에 실린 창을 적는다" "$row_a" ;;
esac
case "$row_a" in
  *"레인=~/lane-recorded "*) ok "(3) 감독자가 쓴 행의 레인은 A.window 2행이다" ;;
  *) bad "(3) 감독자가 쓴 행의 레인은 A.window 2행이다" "$row_a" ;;
esac
left=""
for f in pid start kind sup sup.start launch launch.taken window; do
  [ -e "$RD/A.$f" ] && left="$left A.$f"
done
check "(3) 종단 뒤 세그먼트별 파일이 남지 않는다" "$left" ""

# ---------------------------------------------------------------------------
# (6) The launch token is one-shot.
# ---------------------------------------------------------------------------
seg B
printf 'stale-nonce\n\n' > "$RD/B.launch.taken"
CC_STUB_SLEEP=1 dispatch B >/dev/null; rc_b=$?
check "(6) 옛 .launch.taken 이 있어도 재파견이 통과한다 (가드 0)" "$rc_b" "0"
g wait --manifest "$MANIFEST" --segment B --interval 1 --timeout 60 >/dev/null; rc_bw=$?
check "(6) 그 파견의 스테이지가 실제로 끝까지 돈다" "$rc_bw" "0"
check "(6) 그 파견이 행을 남긴다" "$(rows_of B)" "1"

seg C
printf '1\n' > "$RD/C.attempt"
printf 'the-real-nonce\n\n' > "$RD/C.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C --nonce not-the-nonce \
  -- review -p x >/dev/null; rc_c=$?
check "(6) 난스가 다른 supervise-stage 직접 호출은 exit 3 (가드 0, 세 줄 토큰)" "$rc_c" "3"
check "(6) 그 거부는 행을 쓰지 않는다" "$(rows_of C)" "0"
check "(6) 그 거부는 아무것도 띄우지 않는다" "$( [ -e "$RD/C.pid" ] && printf 'yes' || printf 'no')" "no"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C --nonce the-real-nonce \
  -- review -p x >/dev/null; rc_c2=$?
check "(6) 이미 소비된 토큰은 올바른 난스로도 다시 가져갈 수 없다" "$rc_c2" "3"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C2 --nonce any \
  -- review -p x >/dev/null; rc_c3=$?
check "(6) 토큰이 없으면 exit 3" "$rc_c3" "3"
check "(6) 토큰 없는 호출도 행을 쓰지 않는다" "$(rows_of C2)" "0"

# ---------------------------------------------------------------------------
# (7) A TERM that reaches the supervisor is forwarded, and the outcome is still
# recorded — an intended stop leaves a row.
# ---------------------------------------------------------------------------
seg D
CC_STUB_SLEEP=30 dispatch D >/dev/null
wait_file "$RD/D.pid" 50 || true
SUP_D=$( { cat "$RD/D.sup" 2>/dev/null || true; } | tr -d '[:space:]')
PID_D=$( { cat "$RD/D.pid" 2>/dev/null || true; } | tr -d '[:space:]')
check "(7) TERM 전에 D 의 CLI 가 살아 있다" "$(alive "$PID_D")" "alive"
# (5) THE HEARTBEAT, measured on a stage that is certainly still running. A
# `wait` bounded by a two-second timeout must print at least one liveness line
# and then end with 13 — which ends the wait, not the stage.
hb_out=$(g wait --manifest "$MANIFEST" --segment D --interval 1 --timeout 2); hb_rc=$?
case "$hb_out" in
  *"살아 있음"*) ok "(5) wait 이 하트비트를 한 줄 이상 찍는다" ;;
  *) bad "(5) wait 하트비트" "$hb_out" ;;
esac
check "(5) 살아 있는 스테이지에서 timeout 은 13" "$hb_rc" "13"
check "(5) timeout 은 기다림만 끝내고 스테이지는 끝내지 않는다" "$(alive "$PID_D")" "alive"
kill -TERM "${SUP_D:-0}" 2>/dev/null || true
g wait --manifest "$MANIFEST" --segment D --interval 1 --timeout 60 >/dev/null; rc_d=$?
check "(7) 감독자에 보낸 TERM 이 CLI 에 전달된다 (CLI 가 사라졌다)" "$(alive "$PID_D")" "dead"
check "(7) 중단된 스테이지도 stage-result 행을 남긴다" "$(rows_of D)" "1"
check "(7) wait 은 CLI 의 TERM 종료 코드를 돌려준다" "$rc_d" "143"
check "(7) 중단 뒤에도 세그먼트별 파일이 남지 않는다" \
  "$( { ls "$RD"/D.pid "$RD"/D.sup "$RD"/D.kind 2>/dev/null || true; } | grep -c . || true)" "0"

# ---------------------------------------------------------------------------
# (9) A STAGE THAT IS ALREADY GONE WHEN THE SUPERVISOR RECORDS IT.
#
# Every stub above lives for a second or more, so the supervisor always captured
# the fingerprint of a running process and this shape was never driven — which
# is why a supervisor that died on that capture shipped green. It is also the
# most common real failure: a wrong argument, a failed auth or a missing plugin
# directory makes the wrapper exit before it execs, and a missing CLI makes it
# exit 127. Measured on a Linux runner — the capture raised `ps`'s non-zero
# status through `pipefail`, `errexit` ended the supervisor between `.pid` and
# `.kind`, and the attempt left no row, no cleanup, and a record the settlement
# candidate predicate skips forever while the lost-dispatch alarm keeps firing.
# ---------------------------------------------------------------------------

# (9a) THE CAPTURE ITSELF, under the shell options the supervisor inherits. A
# pid that is gone is an answer — the empty string — not a failure of the
# caller. The pid is one no system assigns, so the probe needs no live process.
fp_probe=$(
  . "$repo_root/plugins/cc-cmds/orchestrator/liveness.sh"
  set -euo pipefail
  fp=$(cc_proc_fingerprint 2147483646)
  printf 'survived:[%s]' "$fp"
)
check "(9) 사라진 pid 의 지문 캡처가 errexit 아래에서 호출자를 죽이지 않는다" \
  "$fp_probe" "survived:[]"

# The record is removed at termination, so "`.kind` exists" is a sampled
# invariant rather than an end-state one: from before the dispatch until the row
# lands, `.pid` must never be present without `.kind` beside it. The sampler
# also reports whether it saw the record at all — an invariant nothing observed
# is the vacuous pass this suite exists to refuse.
sample_kind() {  # sample_kind <segment> <outfile>
  local s="$1" out="$2" n=0 seen=0 broke=""
  while [ "$n" -lt 3000 ]; do
    if [ -f "$RD/$s.pid" ]; then
      seen=1
      if [ ! -f "$RD/$s.kind" ]; then broke=".pid 는 있는데 .kind 가 없다"; break; fi
    fi
    [ "$(rows_of "$s")" != "0" ] && break
    sleep 0.01; n=$((n + 1))
  done
  printf '%s|%s\n' "$seen" "${broke:-ok}" > "$out"
}

assert_immediate() {  # assert_immediate <segment> <expected-rc> <label>
  local s="$1" want="$2" label="$3" rc left f seen broke
  sample_kind "$s" "$WORK/sample-$s" &
  local sampler=$!
  dispatch "$s" >/dev/null
  g wait --manifest "$MANIFEST" --segment "$s" --interval 1 --timeout 60 >/dev/null; rc=$?
  wait "$sampler" 2>/dev/null || true
  check "(9) $label — wait 이 스테이지 rc 를 통과시킨다" "$rc" "$want"
  check "(9) $label — stage-result 행이 정확히 하나" "$(rows_of "$s")" "1"
  left=""
  for f in pid start kind sup sup.start launch launch.taken window; do
    [ -e "$RD/$s.$f" ] && left="$left $s.$f"
  done
  check "(9) $label — 잔여 파일이 없다" "$left" ""
  seen=""; broke=""
  IFS='|' read -r seen broke < "$WORK/sample-$s" 2>/dev/null || true
  check "(9) $label — .pid 가 있는 동안 .kind 도 있다" "${broke:-관측 없음}" "ok"
  check "(9) $label — 그 관측이 실제로 파견 기록을 봤다" "${seen:-0}" "1"
}

# (9b) The CLI reports a normal result and exits at once.
seg E
CC_STUB_SLEEP=0
export CC_STUB_SLEEP
assert_immediate E 0 "즉시 정상 종료"
unset CC_STUB_SLEEP

# (9c) The wrapper's own refusal — exit 2 with no result envelope at all, the
# shape a bad argument or a missing plugin directory produces.
STUB_REFUSE="$WORK/claude-stub-refuse"
cat > "$STUB_REFUSE" <<'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
chmod +x "$STUB_REFUSE"
seg F
export CC_CLAUDE_BIN="$STUB_REFUSE"
assert_immediate F 2 "즉시 거부 종료"
export CC_CLAUDE_BIN="$STUB"

# (9d) A STAGE THAT DIED OF THE USAGE LIMIT BY ITSELF. One successful turn, then
# a refused turn whose stream ends on a 429 envelope and a `rejected` frame with
# a numeric reset time, and exit 1. The supervisor hands the recorder the pinned
# attempt's own stream, so the row is `한도 종료` and not `크래시`. Two pairs
# around it: prose on the envelope is never read, and a last frame that is not
# `rejected` stays `크래시` with one shape warning in that attempt's supervisor
# log and none in the ledger.
STUB_LIMIT="$WORK/claude-stub-limit"
cat > "$STUB_LIMIT" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' \
  '{"type":"system","subtype":"init","session_id":"stub-limit"}' \
  '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790390000}}' \
  '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"num_turns":1,"session_id":"stub-limit","result":"done"}' \
  '{"type":"system","subtype":"init","session_id":"stub-limit"}' \
  "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"${CC_STUB_LAST_STATUS:-rejected}\",\"resetsAt\":1790390000}}" \
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"total_cost_usd\":0,\"session_id\":\"stub-limit\",\"result\":\"${CC_STUB_PROSE:-You have hit your session limit}\"}"
exit 1
STUBEOF
chmod +x "$STUB_LIMIT"
limit_rows() {  # limit_rows <segment> <class> — rows of that segment with that class, written by the gate
  { grep -F '`stage-result`' "$LEDGER" || true; } | { grep -F "세그먼트=$1 " || true; } \
    | { grep -F "종단 부류=$2 " || true; } | { grep -cF '기록자=게이트' || true; }
}
limit_suplog() { cat "$RD"/log/"$1"#*.sup.log 2>/dev/null || true; }
export CC_CLAUDE_BIN="$STUB_LIMIT"
seg G
dispatch G >/dev/null
g wait --manifest "$MANIFEST" --segment G --interval 1 --timeout 60 >/dev/null; rc_g=$?
check "(9d) 한도로 스스로 끝난 스테이지는 한도 종료 · 기록자=게이트 행이 정확히 하나" "$(limit_rows G '한도 종료')" "1"
check "(9d) 그 세그먼트의 stage-result 행은 하나뿐이다" "$(rows_of G)" "1"
check "(9d) 감독자 로그가 한도 종료 rc=1 을 찍는다" \
  "$(limit_suplog G | { grep -cF ' 한도 종료 rc=1' || true; })" "1"
check "(9d) wait 은 스테이지의 종료 코드 1 을 돌려준다" "$rc_g" "1"
seg H
CC_STUB_PROSE='Usage cap reached. Try again tomorrow.' dispatch H >/dev/null
g wait --manifest "$MANIFEST" --segment H --interval 1 --timeout 60 >/dev/null
check "(9d) 봉투 산문을 바꿔도 같은 부류다" "$(limit_rows H '한도 종료')" "1"
seg I
CC_STUB_LAST_STATUS=allowed dispatch I >/dev/null
g wait --manifest "$MANIFEST" --segment I --interval 1 --timeout 60 >/dev/null
check "(9d) 마지막 프레임이 allowed 면 크래시다" "$(limit_rows I '크래시')" "1"
check "(9d) 그 시도의 감독자 로그에 형상 경고가 정확히 한 줄" \
  "$(limit_suplog I | { grep -c '한도 형상 불완전 (' || true; })" "1"
check "(9d) 형상 경고는 원장에 없다" "$( { grep -c '한도 형상 불완전 (' "$LEDGER" || true; } )" "0"
export CC_CLAUDE_BIN="$STUB"

# ---------------------------------------------------------------------------
# (10) A RUN THAT DECLARES A DESIGN DOCUMENT, in each shape the key can take.
#
# Every manifest above says `(없음)`, so the recorder's document-hash branch
# had never run in any process context. It is reached only when the run names
# a document, and what it did there depended on the caller: inside the old
# blocking dispatch the recorder sat on the left of `|| rc=$?`, where bash
# ignores errexit for the whole function body; the detached supervisor calls
# it plainly under `set -euo pipefail`, so a bare assignment whose substitution
# failed under `pipefail` ended the supervisor before the `stage-result` row,
# the `cost` row and the cleanup. An absolute-path key — the contract's normal
# shape for a document outside the repository — made that deterministic at
# every termination, and a re-dispatch died at the same line.
#
# Only this suite drives the recorder across a process boundary; the gate suite
# calls it in-process, where the failure never surfaces. One run per shape,
# because the run id keys the ledger, the grant and the run directory.
# ---------------------------------------------------------------------------
assert_doc_run() {  # assert_doc_run <run-id> <document key> <want 문서 해시 rows> <label>
  local run="$1" key="$2" want_hash="$3" label="$4" rc klass left f
  mk_run "$run" "$key"
  seg G
  CC_STUB_SLEEP=0 dispatch G >/dev/null
  g wait --manifest "$MANIFEST" --segment G --interval 1 --timeout 60 >/dev/null; rc=$?
  check "(10) $label — wait 이 스테이지 rc 0 으로 끝난다" "$rc" "0"
  check "(10) $label — stage-result 행이 정확히 하나" "$(rows_of G)" "1"
  klass=$( { grep -F '`stage-result`' "$LEDGER" || true; } | { grep -F '세그먼트=G ' || true; } \
           | sed -n 's/.*종단 부류=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sed -n '1p')
  if [ -n "$klass" ] && [ "$klass" != "외부 종료" ]; then
    ok "(10) $label — 그 행은 감독자가 썼다 (종단 부류=$klass)"
  else
    bad "(10) $label — 그 행은 감독자가 썼다" "종단 부류='${klass:-없음}' — 정산이 쓴 행이거나 행이 없다"
  fi
  check "(10) $label — cost 행이 정확히 하나" \
    "$( { grep -cF '`cost`' "$LEDGER" || true; } )" "1"
  check "(10) $label — 문서 해시 행 수" \
    "$( { grep -cF '`문서 해시`' "$LEDGER" || true; } )" "$want_hash"
  check "(10) $label — 감독자 로그에 종단 줄이 있다" \
    "$( grep -q '스테이지 종단' "$RD/log/G#1.sup.log" 2>/dev/null && printf 'yes' || printf 'no')" "yes"
  left=""
  for f in pid start kind sup sup.start launch launch.taken window; do
    [ -e "$RD/G.$f" ] && left="$left G.$f"
  done
  check "(10) $label — 종단 뒤 세그먼트별 파일이 남지 않는다" "$left" ""
}

# (10a) Repo-relative key, document present.
printf '# design\n' > "$WT/docs/design.md"
assert_doc_run SUP2 'docs/design.md' 1 "저장소 상대 키"

# (10b) Absolute-path key, document present outside the repository — the
# shape that fired deterministically.
mkdir -p "$WORK/outside"
printf '# design\n' > "$WORK/outside/design.md"
assert_doc_run SUP3 "${WORK#/}/outside/design.md" 1 "절대 경로 키"

# (10c) Declared, but the file is not there — a document moved or removed
# during the run.
assert_doc_run SUP4 'docs/gone.md' 0 "선언됐으나 없는 문서"

# ---------------------------------------------------------------------------
# (11) THE WRAPPER OWNS THE COMPACTION WINDOW ONLY WHEN IT OWNS THE PROMPT.
#
# The gate hands the window to the wrapper as an option before `--`, and the
# wrapper puts it on the CLI argv itself. A caller that also puts `--autocompact`
# after `--` would let the CLI's last-wins rule replace the gate's value without
# a trace, so under `--instructions` the wrapper refuses it like the other
# reserved flags. Without `--instructions` the argv is the caller's own — the
# old driver path — and the flag must pass through untouched. Both arms are
# driven against a stub that records its argv, which no stub above does.
# ---------------------------------------------------------------------------
WRAP="$repo_root/plugins/cc-cmds/orchestrator/stage-wrapper.sh"
STUB_ARGV="$WORK/claude-stub-argv"
cat > "$STUB_ARGV" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CC_STUB_ARGV_OUT"
exit 0
STUBEOF
chmod +x "$STUB_ARGV"
printf '{}\n' > "$WORK/wrap-settings.json"
printf 'policy\n' > "$WORK/wrap-instructions.md"
mkdir -p "$WORK/wrap-plugin"

: > "$WORK/wrap-argv.out"
wrap_err=$(CC_CLAUDE_BIN="$STUB_ARGV" CC_STUB_ARGV_OUT="$WORK/wrap-argv.out" \
  bash "$WRAP" --settings "$WORK/wrap-settings.json" --plugin-dir "$WORK/wrap-plugin" \
    --session-id x --instructions "$WORK/wrap-instructions.md" \
    -- --autocompact 300000 -p x 2>&1 >/dev/null); wrap_rc=$?
check "(11) --instructions 아래에서 -- 뒤의 --autocompact 는 exit 2" "$wrap_rc" "2"
case "$wrap_err" in
  *"reserved flag after --: --autocompact"*) ok "(11) 그 거부는 예약 플래그 문면을 낸다" ;;
  *) bad "(11) 그 거부는 예약 플래그 문면을 낸다" "$wrap_err" ;;
esac
check "(11) 거부된 기동은 CLI 에 닿지 않는다" \
  "$(wc -c < "$WORK/wrap-argv.out" | tr -d '[:space:]')" "0"

: > "$WORK/wrap-argv.out"
CC_CLAUDE_BIN="$STUB_ARGV" CC_STUB_ARGV_OUT="$WORK/wrap-argv.out" \
  bash "$WRAP" --settings "$WORK/wrap-settings.json" --plugin-dir "$WORK/wrap-plugin" \
    --session-id x -- --autocompact 300000 -p x >/dev/null 2>&1; wrap_rc2=$?
check "(11) --instructions 없이는 같은 argv 가 exit 0" "$wrap_rc2" "0"
check "(11) 그 기동의 CLI argv 에 호출자의 --autocompact 가 남는다" \
  "$( { grep -cx -- '--autocompact' "$WORK/wrap-argv.out" || true; } )" "1"

# The gate's own form — the option before `--` — lands on the CLI argv once,
# directly after `--strict-mcp-config`, under `--instructions` too.
: > "$WORK/wrap-argv.out"
CC_CLAUDE_BIN="$STUB_ARGV" CC_STUB_ARGV_OUT="$WORK/wrap-argv.out" \
  bash "$WRAP" --settings "$WORK/wrap-settings.json" --plugin-dir "$WORK/wrap-plugin" \
    --session-id x --instructions "$WORK/wrap-instructions.md" --autocompact 300000 \
    -- -p x >/dev/null 2>&1; wrap_rc3=$?
check "(11) -- 앞의 --autocompact 옵션은 --instructions 아래에서도 exit 0" "$wrap_rc3" "0"
check "(11) 그 옵션은 CLI argv 에 --strict-mcp-config 바로 뒤에 한 번 실린다" \
  "$(tr '\n' ' ' < "$WORK/wrap-argv.out" | { grep -o -- '--strict-mcp-config --autocompact 300000 ' || true; } | { grep -c . || true; })" "1"

# The effort and model options land right after the window, in that order, and
# do not displace it.
: > "$WORK/wrap-argv.out"
CC_CLAUDE_BIN="$STUB_ARGV" CC_STUB_ARGV_OUT="$WORK/wrap-argv.out" \
  bash "$WRAP" --settings "$WORK/wrap-settings.json" --plugin-dir "$WORK/wrap-plugin" \
    --session-id x --instructions "$WORK/wrap-instructions.md" --autocompact 300000 \
    --effort high --model opus -- -p x >/dev/null 2>&1; wrap_rc4=$?
check "(11) --effort·--model 옵션도 --instructions 아래에서 exit 0" "$wrap_rc4" "0"
check "(11) 그 둘은 --autocompact 바로 뒤에 순서대로 한 번 실린다" \
  "$(tr '\n' ' ' < "$WORK/wrap-argv.out" | { grep -o -- '--strict-mcp-config --autocompact 300000 --effort high --model opus ' || true; } | { grep -c . || true; })" "1"

# ---------------------------------------------------------------------------
# (12) ROUTING ON — the same dispatch, in a run opened where an inventory exists.
#
# Everything above runs unrouted: no inventory was there when those runs opened,
# so they hold no routing record. This section plants an inventory before it
# opens a run, so that run's record says `1` and every dispatch below is routed.
# HOME, the inventory root and the lease table are all moved under the scratch
# directory: an inventory's account directories must sit under `$HOME/.claude-`,
# and a real one must not be routed to by a test. Each assertion names a file
# or row only a routed launch writes, so a run that silently stayed unrouted
# fails here instead of passing on the unrouted path.
# ---------------------------------------------------------------------------

# The unrouted refusal first: a token carrying routing lines was written by a
# dispatch half that disagrees with this run's record.
seg C3
printf '1\n' > "$RD/C3.attempt"
printf 'n0\n\n\nB:C3#1\n-\n-\n/x\n' > "$RD/C3.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C3 --nonce n0 \
  -- review -p x >/dev/null; rc_c3r=$?
check "(12) 라우팅되지 않은 런의 감독자는 라우팅 줄을 실은 토큰을 exit 3 으로 거부한다" "$rc_c3r" "3"
check "(12) 그 거부는 행을 쓰지 않고 아무것도 띄우지 않는다" \
  "$(rows_of C3)/$( [ -e "$RD/C3.pid" ] && printf 'yes' || printf 'no')" "0/no"
seg C4
printf '1\n' > "$RD/C4.attempt"
printf 'n4\n\n\nwait\nB:C4#1\nfirst\n-\n' > "$RD/C4.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C4 --nonce n4 \
  -- review -p x >/dev/null; rc_c4r=$?
check "(12) 라우팅되지 않은 런의 감독자는 대기 토큰도 exit 3 으로 거부한다" "$rc_c4r" "3"
check "(12) 그 거부도 행을 쓰지 않고 아무것도 띄우지 않는다" \
  "$(rows_of C4)/$( [ -e "$RD/C4.pid" ] && printf 'yes' || printf 'no')" "0/no"

ORCH="$repo_root/plugins/cc-cmds/orchestrator"
R12_HOME_SAVE="$HOME"
export HOME="$WORK/home12"
unset XDG_CONFIG_HOME CLAUDE_CONFIG_DIR
export RUN_PACE_ROOT="$WORK/pace12"
R12_CFG="$HOME/.claude-r12"
mkdir -p "$R12_CFG" "$HOME/.config/cc-lane" "$RUN_PACE_ROOT"
r12_inv() {  # r12_inv <enabled|disabled> <file>
  jq -cn --arg d "$R12_CFG" --arg u "$1" \
    '{schema: "cc-lane-accounts v1", accounts: [{id: "r12a", config_dir: $d, label: "r12a",
      interactive_reserved: false, unattended: $u, added_at: 0}]}' > "$2"
  chmod 600 "$2"
}
r12_inv enabled "$HOME/.config/cc-lane/accounts.json"

# A stub that also records the directory it was launched under.
STUB_CFG="$WORK/claude-stub-cfg"
cat > "$STUB_CFG" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CONFIG_DIR-unset}" > "${CC_STUB_CFG_OUT:-/dev/null}"
sleep "${CC_STUB_SLEEP:-3}" &
sp=$!
trap 'kill "$sp" 2>/dev/null; exit 143' TERM
wait "$sp"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"num_turns":1,"session_id":"stub-session"}'
exit 0
STUBEOF
chmod +x "$STUB_CFG"

mk_run SUPR '(없음)'
check "(12) 인벤토리가 있을 때 연 런은 라우팅 기록 1 을 남긴다" "$(cat "$RD/routing-guard" 2>/dev/null)" "1"
check "(12) 런의 인벤토리 스냅숏이 픽스처 인벤토리다" \
  "$(jq -r '.accounts[0].id' "$RD/inventory.json" 2>/dev/null)" "r12a"

r12_lease() {  # r12_lease <lineage> — the live lease's account, or nothing
  ( . "$ORCH/liveness.sh"; . "$ORCH/route.sh"
    route_lease_of "$RUN_PACE_ROOT/leases" SUPR "$1" 2>/dev/null ) | { jq -r '.account // empty' 2>/dev/null || true; }
}

# A GRANT on an account: the token carries seven lines, the supervisor writes a
# four-line window and hands the grant's directory to the wrapper, the lease is
# live while the stage runs and gone once its row is down, and the row's
# account is the token's.
seg E
CC_CLAUDE_BIN="$STUB_CFG" CC_STUB_CFG_OUT="$WORK/r12-cfg-E" CC_STUB_SLEEP=4 dispatch E >/dev/null; rc_e=$?
check "(12) 계정 부여 파견이 성공으로 반환한다" "$rc_e" "0"
wait_file "$RD/E.pid" 50 || true
check "(12) 토큰이 일곱 줄이다" "$(wc -l < "$RD/E.launch.taken" 2>/dev/null | tr -d '[:space:]')" "7"
check "(12) 토큰 넷째·여섯째·일곱째 줄이 계보·계정·디렉터리다" \
  "$(sed -n '4p' "$RD/E.launch.taken" 2>/dev/null)|$(sed -n '6p' "$RD/E.launch.taken" 2>/dev/null)|$(sed -n '7p' "$RD/E.launch.taken" 2>/dev/null)" \
  "B:E#1|r12a|$R12_CFG"
check "(12) 토큰 다섯째 줄은 임대 난스다 (- 가 아니다)" \
  "$( [ -n "$(sed -n '5p' "$RD/E.launch.taken" 2>/dev/null)" ] && [ "$(sed -n '5p' "$RD/E.launch.taken")" != "-" ] && printf yes || printf no)" "yes"
check "(12) 감독자가 발사 전에 네 줄 창 기록을 쓰고 넷째 줄이 계정이다" \
  "$(wc -l < "$RD/E.window" 2>/dev/null | tr -d '[:space:]')/$(sed -n '4p' "$RD/E.window" 2>/dev/null)" "4/r12a"
check "(12) 스테이지가 도는 동안 계보의 임대가 살아 있다" "$(r12_lease 'B:E#1')" "r12a"
g wait --manifest "$MANIFEST" --segment E --interval 1 --timeout 60 >/dev/null; rc_ew=$?
check "(12) 그 스테이지가 끝까지 돈다" "$rc_ew" "0"
check "(12) 래퍼가 부여된 디렉터리 아래에서 CLI 를 띄웠다" "$(cat "$WORK/r12-cfg-E" 2>/dev/null)" "$R12_CFG"
row_e=$( { grep -F '`stage-result`' "$LEDGER" || true; } | { grep -F '세그먼트=E ' || true; } | tail -1)
case "$row_e" in
  *"| 계정=r12a |"*|*"| 계정=r12a") ok "(12) 종단 행의 계정= 이 토큰 여섯째 줄이다" ;;
  *) bad "(12) 종단 행의 계정= 이 토큰 여섯째 줄이다" "$row_e" ;;
esac
lease_e=$( { grep -F '`stage-lease`' "$LEDGER" || true; } | tail -1)
case "$lease_e" in
  *"| 파견 id=B:E#1 | 계보=B:E#1 | 계정=r12a | 레인=~/.claude-r12 | "*"| 근거=first | "*) ok "(12) 파견 반쪽이 계보를 파견 id 로 한 stage-lease 행을 쓴다" ;;
  *) bad "(12) stage-lease 행" "$lease_e" ;;
esac
check "(12) 행이 쓰인 뒤 임대가 반납된다" "$(r12_lease 'B:E#1')" ""
case "$row_e" in
  *"| 실행 버전=1 |"*) ok "(12) 계보·파견 id 의 시도 번호와 종단 행의 실행 버전이 같다" ;;
  *) bad "(12) 종단 행의 실행 버전" "$row_e" ;;
esac

# The routing record is compared with the baseline before anything else: a
# record that is neither absent nor `1` beside a regular baseline is a pair no
# entry writes, and the dispatch stops with the routing exit code and an
# act-scope row, before the pin. The record is replaced rather than removed —
# with no record the run is simply unrouted, which is a launch, not a stop.
rm -f "$RD/routing-guard"; printf '0\n' > "$RD/routing-guard"
seg F
dispatch F >/dev/null; rc_f=$?
check "(12) 라우팅 기록이 스냅숏과 어긋나면 exit 16 이다" "$rc_f" "16"
row_f=$( { grep -F '`blocked`' "$LEDGER" || true; } | { grep -F '세그먼트=F ' || true; } | tail -1)
case "$row_f" in
  *"스코프=act"*"사유=라우터 판정"*"라우팅 가드 어긋남 — 런 기록 0, 스냅숏 정규 파일"*) ok "(12) 그 정지가 가드 어긋남을 실은 blocked 행을 남긴다" ;;
  *) bad "(12) 가드 어긋남 행" "$row_f" ;;
esac
check "(12) 가드 어긋남은 시도 핀도 토큰도 남기지 않는다" \
  "$( [ -e "$RD/F.attempt" ] && printf pin || printf -- -)$( [ -e "$RD/F.launch" ] && printf tok || printf -- -)" "--"
printf '1\n' > "$RD/routing-guard"

# A PARK — no enabled account — is the same stop with the router's reason.
rm -f "$RD/inventory.json"
r12_inv disabled "$RD/inventory.json"
seg G
dispatch G >/dev/null; rc_g=$?
check "(12) 라우터 PARK 는 exit 16 이다" "$rc_g" "16"
row_g=$( { grep -F '`blocked`' "$LEDGER" || true; } | { grep -F '세그먼트=G ' || true; } | tail -1)
case "$row_g" in
  *"사유=라우터 판정"*"PARK no-enabled-account"*) ok "(12) PARK 정지가 라우터의 사유를 실은 blocked 행을 남긴다" ;;
  *) bad "(12) PARK 행" "$row_g" ;;
esac
check "(12) PARK 는 시도 핀도 토큰도 남기지 않는다" \
  "$( [ -e "$RD/G.attempt" ] && printf pin || printf -- -)$( [ -e "$RD/G.launch" ] && printf tok || printf -- -)" "--"
rm -f "$RD/inventory.json"
r12_inv enabled "$RD/inventory.json"

# The supervisor holds the lease itself before it launches anything, and a
# lease it cannot hold is no launch.
seg H
printf '1\n' > "$RD/H.attempt"
printf 'nh\n\n\nB:H#1\nno-such-nonce\nr12a\n%s\n' "$R12_CFG" > "$RD/H.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment H --nonce nh \
  -- review -p x >/dev/null; rc_h=$?
check "(12) 잡을 수 없는 임대 난스의 토큰은 exit 3 이다" "$rc_h" "3"
check "(12) 그 거부는 행을 쓰지 않고 아무것도 띄우지 않는다" \
  "$(rows_of H)/$( [ -e "$RD/H.pid" ] && printf 'yes' || printf 'no')" "0/no"
seg H2
printf '1\n' > "$RD/H2.attempt"
printf 'nh2\n\n\n' > "$RD/H2.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment H2 --nonce nh2 \
  -- review -p x >/dev/null; rc_h2=$?
check "(12) 라우팅된 런의 감독자는 라우팅 줄이 없는 토큰을 exit 3 으로 거부한다" "$rc_h2" "3"
check "(12) 그 거부도 행을 쓰지 않는다" "$(rows_of H2)" "0"

# No inventory on the host when the run opens: the run holds no routing record,
# so it is unrouted — the token has its three lines, no router is asked and no
# `stage-lease` row is written. A fresh run, because the inventory baseline and
# the record are taken once when a run opens.
rm -f "$HOME/.config/cc-lane/accounts.json"
mk_run SUPN '(없음)'
check "(12) 인벤토리 없이 연 런의 기준은 부재 표지다" "$( [ -L "$RD/inventory.json" ] && printf absent || printf other)" "absent"
check "(12) 인벤토리 없이 연 런에는 라우팅 기록이 없다" "$( [ -e "$RD/routing-guard" ] && printf yes || printf no)" "no"
seg I
CC_CLAUDE_BIN="$STUB_CFG" CC_STUB_SLEEP=1 dispatch I >/dev/null; rc_i=$?
check "(12) 인벤토리 없이 연 런의 파견이 성공으로 반환한다" "$rc_i" "0"
wait_file "$RD/I.pid" 50 || true
check "(12) 그 토큰은 라우팅 줄 없는 세 줄이다" "$(wc -l < "$RD/I.launch.taken" 2>/dev/null | tr -d '[:space:]')" "3"
g wait --manifest "$MANIFEST" --segment I --interval 1 --timeout 60 >/dev/null; rc_iw=$?
check "(12) 라우팅 없이 뜬 스테이지가 끝까지 돈다" "$rc_iw" "0"
check "(12) 라우팅되지 않은 파견은 임대 표에 아무것도 남기지 않는다" \
  "$(find "$RUN_PACE_ROOT/leases" -type f -path '*SUPN*' 2>/dev/null | wc -l | tr -d '[:space:]')" "0"
check "(12) 라우팅되지 않은 파견은 stage-lease 행을 쓰지 않는다" \
  "$( { grep -cF '`stage-lease`' "$LEDGER" || true; } )" "0"

# ---------------------------------------------------------------------------
# (13) WAIT — the dispatch half returns at once and a supervisor waits.
#
# The router is the real one. Usage is absent, so the account's group is held to
# one stage at a time, and a wait entry of another run whose holder this suite
# keeps alive fills that place: the dispatch is answered WAIT with no release
# time. The watcher's threshold record is planted with a live writer so a chunk
# is one second. Ending the blocker's holder frees the place.
# ---------------------------------------------------------------------------
r12_inv enabled "$HOME/.config/cc-lane/accounts.json"
w13_stall() {  # w13_stall — a live threshold record of 2 seconds in this run
  local fp
  fp=$( . "$ORCH/liveness.sh"; cc_proc_fingerprint "$W13_WRITER" )
  printf '2\n%s\n%s\n' "$W13_WRITER" "$fp" > "$RD/watch.stall"
}
w13_block() {  # w13_block <holder pid> — another run's wait entry on the account
  bash "$ORCH/route.sh" lease-wait-put --table "$RUN_PACE_ROOT/leases" --now "$(date +%s)" \
    --run-id OTHER --lineage B:X#1 --account r12a --config-dir "$R12_CFG" --holder "$1" >/dev/null
}
waits_of() { { grep -F '`stage-wait`' "$LEDGER" || true; } | { grep -cF "계보=$1 " || true; }; }
sleep 600 & W13_WRITER=$!; KILL_LIST="$KILL_LIST $W13_WRITER"
sleep 600 & W13_BLOCK=$!; KILL_LIST="$KILL_LIST $W13_BLOCK"

mk_run SUPW '(없음)'
w13_stall
w13_block "$W13_BLOCK"
seg W
CC_CLAUDE_BIN="$STUB_CFG" CC_STUB_CFG_OUT="$WORK/r13-cfg-W" CC_STUB_SLEEP=1 dispatch W >/dev/null; rc_w=$?
check "(13) WAIT 파견은 정지가 아니라 0 으로 반환한다" "$rc_w" "0"
check "(13) 반환 시점에 첫 stage-wait 행이 이미 있다" "$(waits_of 'B:W#1')" "1"
check "(13) 반환 시점에 대기 표지가 있고 기록자는 게이트다" "$(sed -n 's/^기록자=//p' "$RD/W.waiting" 2>/dev/null)" "게이트"
check "(13) 표지의 보유자가 감독자다" \
  "$(sed -n 's/^보유자=//p' "$RD/W.waiting" 2>/dev/null)" "$( { cat "$RD/W.sup" 2>/dev/null || true; } | tr -d '[:space:]')"
check "(13) 대기 토큰의 넷째 줄은 wait 다" "$(sed -n '4p' "$RD/W.launch" "$RD/W.launch.taken" 2>/dev/null)" "wait"
check "(13) 시도 핀이 파견 시점에 쓰였다" "$( { cat "$RD/W.attempt" 2>/dev/null || true; } | tr -d '[:space:]')" "1"
n=0
while [ "$(waits_of 'B:W#1')" -lt 2 ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
check "(13) 감독자가 다음 덩어리에서 심장박동 행을 하나 더 쓴다" "$(waits_of 'B:W#1')" "2"
check "(13) 대기 중에는 스테이지가 뜨지 않았다" "$( [ -e "$RD/W.pid" ] && printf yes || printf no)" "no"
kill -TERM "$W13_BLOCK" 2>/dev/null; wait "$W13_BLOCK" 2>/dev/null || true
wait_file "$RD/W.pid" 100 || true
check "(13) 막던 대기자가 사라지면 감독자가 부여를 받아 스폰한다" "$( [ -e "$RD/W.pid" ] && printf yes || printf no)" "yes"
# The marker goes only after `.pid`, `.kind` and `.start` all exist.
n=0
while [ -e "$RD/W.waiting" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
check "(13) 부여 뒤 대기 표지가 지워진다" "$( [ -e "$RD/W.waiting" ] && printf yes || printf no)" "no"
g wait --manifest "$MANIFEST" --segment W --interval 1 --timeout 60 >/dev/null; rc_ww=$?
check "(13) 대기 뒤 뜬 스테이지가 끝까지 돈다" "$rc_ww" "0"
check "(13) 심장박동 행은 둘뿐이다 (부여 뒤에는 쓰지 않는다)" "$(waits_of 'B:W#1')" "2"
check "(13) 래퍼가 부여된 디렉터리 아래에서 CLI 를 띄웠다" "$(cat "$WORK/r13-cfg-W" 2>/dev/null)" "$R12_CFG"
lease_w=$( { grep -F '`stage-lease`' "$LEDGER" || true; } | tail -1)
case "$lease_w" in
  *"| 계보=B:W#1 | 계정=r12a | "*) ok "(13) 부여 뒤 감독자가 stage-lease 행을 쓴다" ;;
  *) bad "(13) 대기 뒤 stage-lease 행" "$lease_w" ;;
esac
check "(13) 대기 항목이 표에 남지 않는다" \
  "$(find "$RUN_PACE_ROOT/leases" -type f -name 'SUPW*' 2>/dev/null | wc -l | tr -d '[:space:]')" "0"

# WAIT, then the deadline: a run whose deadline leaves a few seconds beyond the
# review class's expected duration. The first answer is WAIT with no release
# time, which the router never parks; the supervisor's own turn parks it once a
# release now could no longer finish in time.
sleep 600 & W13_BLOCK=$!; KILL_LIST="$KILL_LIST $W13_BLOCK"
W13_DL=$(( $(date +%s) + $(CC_ORCH_SOURCE_ONLY=1; . "$ORCH/run.sh"; printf '%s' "$EXPECTED_DURATION_REVIEW_S") + 4 ))
mk_run SUPD '(없음)' "$(jq -rn --argjson e "$W13_DL" '$e | todate')"
w13_stall
w13_block "$W13_BLOCK"
seg D
dispatch D >/dev/null; rc_d=$?
check "(13) 마감 전의 WAIT 파견도 0 으로 반환한다" "$rc_d" "0"
SUP_D=$( { cat "$RD/D.sup" 2>/dev/null || true; } | tr -d '[:space:]')
n=0
while [ "$(alive "$SUP_D")" = "alive" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
check "(13) 마감에 걸린 감독자는 스스로 끝난다" "$(alive "$SUP_D")" "dead"
row_d=$( { grep -F '`blocked`' "$LEDGER" || true; } | { grep -F '사유=마감 초과 — D ' || true; } )
check "(13) 마감 파킹은 cone 행 하나다" "$(printf '%s' "$row_d" | { grep -c . || true; })" "1"
case "$row_d" in
  *"스코프=cone"*"앵커 세그먼트=D "*"근거=계보=B:D#1 "*"재개 명령="*"gate.sh act --kind skill --target repo --segment D "*) ok "(13) 그 행이 앵커·계보와 표지의 재파견 줄을 싣는다" ;;
  *) bad "(13) 마감 cone 행" "$row_d" ;;
esac
check "(13) 마감 파킹은 스테이지를 띄우지 않는다" "$( [ -e "$RD/D.pid" ] && printf yes || printf no)" "no"
check "(13) 마감 파킹 뒤 대기 표지가 없다" "$( [ -e "$RD/D.waiting" ] && printf yes || printf no)" "no"
g wait --manifest "$MANIFEST" --segment D --interval 1 --timeout 5 >/dev/null; rc_dw=$?
check "(13) 마감 파킹된 시도의 wait 은 16 이다" "$rc_dw" "16"
kill -TERM "$W13_BLOCK" 2>/dev/null || true

# THE SAME DEADLINE ON A RUN-SCOPE DESIGN STEP. Its key is the plan's step id,
# but `act` takes the step only as `--segment -` with `design` as the first
# stage argument; the step id in `--segment` is refused there as a segment with
# no `segment` row. So the resume command the park records must carry `-`, and
# the line is run back through `plan` beside a control that puts the step id in
# its place — the control is what shows the assertion tells the two apart.
sleep 600 & W13_BLOCK=$!; KILL_LIST="$KILL_LIST $W13_BLOCK"
W13_PLAN_SAVE=$PLAN; W13_PD0_SAVE=$PD0
PLAN='{ "design_required": true, "steps": [ { "id": "DS1", "skill": "design", "summary": "설계", "depends_on": [] } ] }'
PD0=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)
W13_DL=$(( $(date +%s) + $(CC_ORCH_SOURCE_ONLY=1; . "$ORCH/run.sh"; printf '%s' "$EXPECTED_DURATION_DESIGN_S") + 4 ))
mk_run SUPDS 'docs/design-ds.md' "$(jq -rn --argjson e "$W13_DL" '$e | todate')"
PLAN=$W13_PLAN_SAVE; PD0=$W13_PD0_SAVE
w13_stall
w13_block "$W13_BLOCK"
ds_prompt="/cc-cmds:design-discuss-unattended $( ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" 2>/dev/null ) | jq -r .design_doc ) \"테스트\""
g act --manifest "$MANIFEST" --kind skill --target repo --segment - --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale "픽스처 설계 파견" \
  -- design -p "$ds_prompt" >/dev/null; rc_ds=$?
check "(13) 설계 스텝의 WAIT 파견도 0 으로 반환한다" "$rc_ds" "0"
SUP_DS=$( { cat "$RD/DS1.sup" 2>/dev/null || true; } | tr -d '[:space:]')
n=0
while [ "$(alive "$SUP_DS")" = "alive" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
check "(13) 마감에 걸린 설계 스텝의 감독자는 스스로 끝난다" "$(alive "$SUP_DS")" "dead"
row_ds=$( { grep -F '`blocked`' "$LEDGER" || true; } | { grep -F '사유=마감 초과 — DS1 ' || true; } )
if [ "$(printf '%s' "$row_ds" | { grep -c . || true; })" = "1" ]; then
  ok "(13) 설계 스텝의 마감 파킹은 cone 행 하나다"
else
  bad "(13) 설계 스텝의 마감 파킹은 cone 행 하나다" \
    "blocked 행: $( { grep -F '`blocked`' "$LEDGER" || true; } | tail -3) / 감독자 로그: $(tail -5 "$RD"/log/DS1#*.sup.log 2>/dev/null)"
fi
case "$row_ds" in
  *"스코프=cone"*"앵커 세그먼트=DS1 "*"근거=계보=B:DS1#1 "*) ok "(13) 그 행의 앵커와 계보는 스텝 id 다" ;;
  *) bad "(13) 설계 스텝 마감 cone 행" "$row_ds" ;;
esac
case "$row_ds" in
  *"| 세그먼트=- |"*) ok "(13) 그 행의 세그먼트는 - 다" ;;
  *) bad "(13) 설계 스텝 마감 행의 세그먼트" "$row_ds" ;;
esac
ds_redo=$(printf '%s' "$row_ds" | sed -n 's/.*gate\.sh act \(--kind skill [^|]*\) -- <같은 스테이지 인자>.*/\1/p')
case "$ds_redo" in
  *"--segment - "*) ok "(13) 설계 스텝의 재개 명령은 --segment - 로 다시 파견한다" ;;
  *) bad "(13) 설계 스텝의 재개 명령" "${ds_redo:-$row_ds}" ;;
esac
# The recorded line itself, its placeholders filled the way a router fills them.
ds_redo=${ds_redo//<절단점>/커밋}
ds_redo=${ds_redo//<새 H>/$(HH)}
ds_argv=()
read -r -a ds_argv <<< "$ds_redo"
ds_msg=$(g plan --manifest "$MANIFEST" ${ds_argv[@]+"${ds_argv[@]}"} --surface 워크트리쓰기 -- design -p "$ds_prompt"); rc_dp=$?
if [ -n "$ds_redo" ] && [ "$rc_dp" != "3" ]; then
  ok "(13) 기록된 재개 명령은 게이트에서 exit 3 으로 거부되지 않는다 (rc=$rc_dp)"
else
  bad "(13) 기록된 재개 명령은 게이트에서 exit 3 으로 거부되지 않는다" "rc=$rc_dp — $ds_msg"
fi
ds_ctl=$(g plan --manifest "$MANIFEST" --kind skill --target repo --segment DS1 --cutpoint 커밋 \
  --snapshot-digest "$(HH)" --surface 워크트리쓰기 -- design -p "$ds_prompt"); rc_dc=$?
check "(13) 대조: 스텝 id 를 --segment 에 넣은 같은 명령은 exit 3 이다" "$rc_dc" "3"
case "$ds_ctl" in
  *"segment 행이 없습니다"*) ok "(13) 대조의 거부는 segment 행 없음 갈래다" ;;
  *) bad "(13) 대조의 거부 문면" "$ds_ctl" ;;
esac
kill -TERM "$W13_BLOCK" 2>/dev/null || true

# ---------------------------------------------------------------------------
# (14) One dispatch per key on a routed run.
#
# The same blocker makes the router answer WAIT. A key whose first dispatch is
# waiting is refused with 17 before any row about the second act, and so is a
# key whose dispatch lock a live act holds. A lock whose holder is dead is
# cleared, and of two acts that meet the same dead lock only one passes it.
# ---------------------------------------------------------------------------
sleep 600 & W14_BLOCK=$!; KILL_LIST="$KILL_LIST $W14_BLOCK"
mk_run SUPK '(없음)'
w13_stall
w13_block "$W14_BLOCK"
auto_rows() {  # auto_rows <key> — the key's dispatch authorization rows
  { grep -F '`자율 승인`' "$LEDGER" || true; } | { grep -F '| kind=skill | 결정=act |' || true; } \
    | { grep -cF "세그먼트=$1 " || true; }
}
w14_fp() { ( . "$ORCH/liveness.sh"; cc_proc_fingerprint "$1" ); }
sups_live() {  # sups_live <key> — 1 when the key's supervisor record names a live process
  local p
  p=$( { cat "$RD/$1.sup" 2>/dev/null || true; } | tr -d '[:space:]')
  [ "$(alive "$p")" = "alive" ] && printf 1 || printf 0
}
seg K
dispatch K >/dev/null; rc_k1=$?
dispatch K >/dev/null; rc_k2=$?
check "(14) 대기 중인 키의 둘째 파견은 17 이다" "$rc_k1/$rc_k2" "0/17"
check "(14) 자율 승인 행은 첫째 파견의 하나뿐이다" "$(auto_rows K)" "1"
# K's supervisor keeps writing heartbeat rows meanwhile, so those are left out.
no_wait_rows() { { grep -vF '`stage-wait`' "$LEDGER" || true; } | shasum -a 256; }
k_sha=$(no_wait_rows)
g plan --manifest "$MANIFEST" --kind skill --target repo --segment K --cutpoint 커밋 \
  --surface 워크트리쓰기 --snapshot-digest "$(HH)" --rationale "픽스처 예상" \
  -- review -p "/cc-cmds:review-unattended x" >/dev/null; rc_kp=$?
check "(14) plan 도 그 키의 파견을 17 로 예상한다" "$rc_kp" "17"
check "(14) 그 plan 은 원장에 쓰지 않는다" "$(no_wait_rows)" "$k_sha"
check "(14) 스냅숏의 waiting_stages 에 그 키 하나가 있다" \
  "$( ( cd "$WT" && bash "$GATE" snapshot --manifest "$MANIFEST" --fields waiting_stages 2>/dev/null ) | jq -rs '[.[] | if type == "object" then .waiting_stages else . end | arrays | .[].segment] | join(",")')" "K"

sleep 600 & W14_HOLD=$!; KILL_LIST="$KILL_LIST $W14_HOLD"
seg L
printf '%s\n%s\n' "$W14_HOLD" "$(w14_fp "$W14_HOLD")" > "$RD/L.dispatching"
dispatch L >/dev/null; rc_l=$?
check "(14) 살아 있는 행위가 쥔 잠금 아래의 파견은 17 이다" "$rc_l" "17"
check "(14) 그 거부는 자율 승인 행을 쓰지 않는다" "$(auto_rows L)" "0"
check "(14) 거부된 행위는 남의 잠금을 지우지 않는다" "$(sed -n '1p' "$RD/L.dispatching" 2>/dev/null)" "$W14_HOLD"
kill -TERM "$W14_HOLD" 2>/dev/null; wait "$W14_HOLD" 2>/dev/null || true

seg M
printf '999999\nMon Jan 1 00:00:00 2001\n' > "$RD/M.dispatching"
dispatch M >/dev/null; rc_m=$?
check "(14) 보유자가 죽은 잠금은 치워지고 파견이 진행한다" "$rc_m" "0"
check "(14) 행위가 끝나면 잠금이 남지 않는다" "$( [ -e "$RD/M.dispatching" ] && printf yes || printf no)" "no"

seg N
printf '999999\nMon Jan 1 00:00:00 2001\n' > "$RD/N.dispatching"
dispatch N >/dev/null & w14_a=$!
dispatch N >/dev/null & w14_b=$!
wait "$w14_a"; rc_na=$?
wait "$w14_b"; rc_nb=$?
# The loser is refused either at the lock (17) or, when the winner's row landed
# before its digest comparison, as stale (4); both leave the key one dispatch.
case "$(printf '%s\n%s\n' "$rc_na" "$rc_nb" | sort -n | tr '\n' ' ')" in
  "0 4 "|"0 17 ") ok "(14) 죽은 잠금을 함께 본 두 행위는 하나만 지난다" ;;
  *) bad "(14) 동시 파견" "rc $rc_na / $rc_nb" ;;
esac
check "(14) 그 키의 자율 승인 행은 하나다" "$(auto_rows N)" "1"
check "(14) 감독자는 하나다" "$(sups_live N)" "1"

kill -TERM "$W14_BLOCK" 2>/dev/null; wait "$W14_BLOCK" 2>/dev/null || true
for k in K M N; do
  g wait --manifest "$MANIFEST" --segment "$k" --interval 1 --timeout 60 >/dev/null
done
kill -TERM "$W13_WRITER" 2>/dev/null || true

export HOME="$R12_HOME_SAVE" XDG_CONFIG_HOME="$WORK/config"; unset RUN_PACE_ROOT

printf '\ntest-stage-supervisor: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
