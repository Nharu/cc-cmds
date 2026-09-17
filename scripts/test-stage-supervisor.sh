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

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-stage-supervisor.XXXXXX")
export XDG_STATE_HOME="$WORK/state"
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
  local run="$1" key="$2" docfile="" dsha='(해당 없음)'
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
    printf '**벽시계 마감**: 2030-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
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
for f in pid start kind; do
  check "(2) 반환 직후 A.$f 가 있다" "$( [ -f "$RD/A.$f" ] && printf 'yes' || printf 'no')" "yes"
done
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
left=""
for f in pid start kind sup sup.start launch launch.taken; do
  [ -e "$RD/A.$f" ] && left="$left A.$f"
done
check "(3) 종단 뒤 세그먼트별 파일이 남지 않는다" "$left" ""

# ---------------------------------------------------------------------------
# (6) The launch token is one-shot.
# ---------------------------------------------------------------------------
seg B
printf 'stale-nonce\n\n' > "$RD/B.launch.taken"
CC_STUB_SLEEP=1 dispatch B >/dev/null; rc_b=$?
check "(6) 옛 .launch.taken 이 있어도 재파견이 통과한다" "$rc_b" "0"
g wait --manifest "$MANIFEST" --segment B --interval 1 --timeout 60 >/dev/null; rc_bw=$?
check "(6) 그 파견의 스테이지가 실제로 끝까지 돈다" "$rc_bw" "0"
check "(6) 그 파견이 행을 남긴다" "$(rows_of B)" "1"

seg C
printf '1\n' > "$RD/C.attempt"
printf 'the-real-nonce\n\n' > "$RD/C.launch"
g supervise-stage --manifest "$MANIFEST" --target repo --segment C --nonce not-the-nonce \
  -- review -p x >/dev/null; rc_c=$?
check "(6) 난스가 다른 supervise-stage 직접 호출은 exit 3" "$rc_c" "3"
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
  for f in pid start kind sup sup.start launch launch.taken; do
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
  for f in pid start kind sup sup.start launch launch.taken; do
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

printf '\ntest-stage-supervisor: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
