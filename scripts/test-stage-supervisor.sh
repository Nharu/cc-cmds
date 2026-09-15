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
# Fixture — a repository outside this checkout, one target, one run.
# ---------------------------------------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@example.invalid && git config user.name T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant && echo one > a.txt && git add -A \
  && git commit -qm one && git branch -M main ) >/dev/null 2>&1
WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
RUN=SUP1
MANIFEST="$WT/plan.md"
LEDGER="$WT/docs/pipeline-run/$RUN.md"
row="- \`target\` | 별칭=repo | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/t | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n' "$row" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'; PD0=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)
{
  printf '# 파이프라인 런 매니페스트 — %s\n' "$RUN"
  printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$RUN"
  printf '     anchor-kind=repo; anchor-key=t/t;\n'
  printf '     owner-doc=(없음); origin-worktree=%s;\n' "$WT"
  printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
  printf '## 런 정체\n**킥오프 일시**: 2026-01-01T00:00:00Z\n**런 id**: %s\n' "$RUN"
  printf '**앵커 종류**: repo\n**앵커 키**: t/t\n**사용자 확인 문면**: 테스트 픽스처\n\n'
  printf '## 의도\n```text\n테스트\n```\n\n'
  printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$TD" "$row"
  printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
  printf '## 실행 계획\n**계획 다이제스트**: %s\n**승인 문면**: 테스트\n```json\n%s\n```\n\n' "$PD0" "$PLAN"
  printf '## 인가\n**런 최대 절단점**: 배포\n**종료 지점**: 픽스처가 끝나면\n'
  printf '**벽시계 마감**: 2030-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
  printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
} > "$MANIFEST"
cat > "$WT/docs/pipeline-grant/$RUN.md" <<GRANTEOF
# 파이프라인 인가 기록 — $RUN
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=(없음); origin-worktree=$WT; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 $RUN
**인가 일시**: 2026-01-01T00:00:00Z
**종료 지점**: 픽스처가 끝나면
**권한 절단점**: 배포
**말단 행위 상한**: 없음
**직렬 웨이브 고지**: 해당 없음
**시각 정합 마커**: 없음
**사용자 확인 문면**: 테스트 픽스처
**설계 문서 전체 sha256**: (해당 없음)
**보고서**: $WT/docs/pipeline-run/$RUN.md
GRANTEOF
: > "$LEDGER"

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

g snapshot --manifest "$MANIFEST" >/dev/null
RD="$XDG_STATE_HOME/cc-cmds/run/$RUN"
if [ ! -d "$RD" ]; then
  printf 'fixture: 런 디렉터리가 만들어지지 않았습니다 — %s\n' "$RD" >&2
  exit 1
fi

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

printf '\ntest-stage-supervisor: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
