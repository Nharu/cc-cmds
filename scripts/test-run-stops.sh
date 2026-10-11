#!/usr/bin/env bash
# lint-bash-portability: self-skip
# The stop classifier and the settlement predicate, on fixture ledgers alone.
#
# WHY NO GATE. `run-stops.sh` reads tokens the gate, the watcher and the driver
# already wrote, so every event class can be pinned with a hand-written ledger.
# Starting a gate for each would test the gate's row writers a second time and
# this table not at all.
#
# Usage: bash scripts/test-run-stops.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
STOPS="$ORCH/run-stops.sh"
LIVENESS="$ORCH/liveness.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-run-stops.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# THE CLASSIFIER HAS NO CREDENTIAL AND NO NETWORK. A decoy `gh` first on PATH
# logs every call; the log must stay empty for the whole suite.
mkdir -p "$WORK/bin"
GH_LOG="$WORK/gh.calls"
: > "$GH_LOG"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
exit 0
STUB
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"
export PATH

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- fixture helpers ----------------------------------------------------------

n_case=0
newcase() {
  # newcase — a fresh run directory and ledger; sets RD and LG.
  n_case=$((n_case + 1))
  RD="$WORK/case$n_case/run"
  LG="$WORK/case$n_case/ledger.md"
  mkdir -p "$RD/halt"
  printf '# 파이프라인 런 원장 — fixture\n\n' > "$LG"
}
# Every real row ends with the chain field, and readers rely on the separator
# after the last named field — so the fixture ends its rows the same way.
row()  { local s="$1"; shift; local IFS='|'; printf -- '- `%s` | %s | prev=0\n' "$s" "$(printf '%s' "$*" | sed 's/|/ | /g')" >> "$LG"; }
halt() { printf '<!-- cc-pipeline-halt v1 -->\n**분류**: %s\n**관측 상세**: 자유 문면 precondition-failed 는 읽히지 않는다\n<!-- /cc-pipeline-halt v1 -->\n' "$2" > "$RD/halt/$1.md"; }
stops(){ bash "$STOPS" "$LG" "$RD" "$@" 2>&1; }
has()  { if printf '%s\n' "$2" | grep -qxF "$3"; then ok "$1"; else bad "$1" "missing '$3' in: $(printf '%s' "$2" | tr '\n' ';')"; fi; }
hasnt(){ if printf '%s\n' "$2" | grep -qF "$3"; then bad "$1" "unexpected '$3' in: $(printf '%s' "$2" | tr '\n' ';')"; else ok "$1"; fi; }
T=$(printf '\t')
ev()   { printf '%s\t%s\t%s\t%s' "$1" "$2" "${3:--}" "${4:--}"; }

# --- settlement predicate -----------------------------------------------------

settled() {
  # settled <run-dir> <ledger> [abandon] — prints 정착 or 미정착.
  CC_RD="$1" CC_LG="$2" CC_AB="${3:-}" bash -c '
    . "$0"
    if cc_run_settled_for_report "$CC_RD" "$CC_LG" $CC_AB; then printf 정착; else printf 미정착; fi' "$LIVENESS"
}
state() {
  CC_RD="$1" CC_LG="$2" CC_AB="${3:-}" bash -c '
    . "$0"; if [ -n "$CC_AB" ]; then cc_run_state "$CC_RD" "$CC_LG" "" "$CC_AB"; else cc_run_state "$CC_RD" "$CC_LG"; fi' "$LIVENESS"
}
grew_ago() { printf '마지막성장=%s\n' "$(( $(date -u +%s) - $1 ))" > "$RD/watch.heartbeat"; }

newcase
row segment 'id=s1' '상태=머지됨'
: > "$RD/done"
grew_ago 595;  check "terminal run 595s quiet is not settled" "$(settled "$RD" "$LG")" "미정착"
grew_ago 600;  check "terminal run 600s quiet is settled" "$(settled "$RD" "$LG")" "정착"

newcase
row segment 'id=s1' '상태=실행중'
row blocked '대상=-' '스코프=run' '원인=불명' '사유=라이브니스 침묵'
: > "$RD/done"
grew_ago 3590; check "done with an open run block is not terminal" "$(state "$RD" "$LG")" "정지경고"
check "done with an open run block, short of abandon, is not settled" "$(settled "$RD" "$LG")" "미정착"
grew_ago 3600; check "done with an open run block settles as abandoned" "$(settled "$RD" "$LG")" "정착"

newcase
row segment 'id=s1' '상태=실행중'
row 승인 '승인 id=J-1' '상태=대기' '절단점=판단'
grew_ago 3590; check "an open approval short of abandon is not settled" "$(settled "$RD" "$LG")" "미정착"
grew_ago 3600; check "an open approval at abandon is settled" "$(settled "$RD" "$LG")" "정착"
grew_ago 95;   check "the abandon argument moves the approval boundary (below)" "$(settled "$RD" "$LG" 100)" "미정착"
grew_ago 105;  check "the abandon argument moves the approval boundary (above)" "$(settled "$RD" "$LG" 100)" "정착"

newcase
row segment 'id=s1' '상태=실행중'
printf '%s' "$$" > "$RD/live.pid"
CC_PID=$$ bash -c '. "$0"; cc_proc_fingerprint "$CC_PID"' "$LIVENESS" > "$RD/live.start"
grew_ago 99999; check "a live stage is never settled" "$(settled "$RD" "$LG")" "미정착"

newcase
rm -f "$LG"
check "no clock at all is settled" "$(settled "$RD" "$LG")" "정착"

# R12 — the idle boundary is the one `cc_run_state` crosses into 버려짐.
newcase
row segment 'id=s1' '상태=실행중'
grew_ago 3590
check "R12: below abandon the state is not 버려짐" "$(state "$RD" "$LG")" "정지경고"
check "R12: below abandon the predicate is unsettled" "$(settled "$RD" "$LG")" "미정착"
grew_ago 3600
check "R12: at abandon the state is 버려짐" "$(state "$RD" "$LG")" "버려짐"
check "R12: at abandon the predicate is settled" "$(settled "$RD" "$LG")" "정착"
grew_ago 190
check "R12: a passed abandon moves the state boundary (below)" "$(state "$RD" "$LG" 200)" "정지경고"
check "R12: a passed abandon moves the predicate boundary (below)" "$(settled "$RD" "$LG" 200)" "미정착"
grew_ago 200
check "R12: a passed abandon moves the state boundary (at)" "$(state "$RD" "$LG" 200)" "버려짐"
check "R12: a passed abandon moves the predicate boundary (at)" "$(settled "$RD" "$LG" 200)" "정착"
# The idle both read is one helper's.
check "R12: cc_run_state reads idle through the shared helper" \
  "$(sed -n '/^cc_run_state() {/,/^}/p' "$LIVENESS" | grep -c 'cc_run_idle_seconds')" "1"
check "R12: the predicate reads idle through the shared helper" \
  "$(sed -n '/^cc_run_settled_for_report() {/,/^}/p' "$LIVENESS" | grep -c 'cc_run_idle_seconds')" "1"
check "R12: no second subtraction of the growth clock remains" \
  "$(grep -c 'now - grew' "$LIVENESS")" "1"

# --- run-blocked --------------------------------------------------------------

newcase
row blocked '대상=-' '스코프=run' '원인=불명' '사유=라이브니스 침묵'
row blocked '대상=-' '스코프=run' '원인=불명' '사유=세그먼트 미개시'
row blocked '대상=-' '스코프=run' '원인=막힘' '사유=강제 표면 이동'
row blocked '대상=-' '스코프=run' '원인=막힘' '사유=인벤토리 스냅숏 손상'
row blocked '대상=-' '스코프=run' '원인=막힘' '사유=어휘 밖 사유'
row blocked '대상=-' '스코프=run' '원인=막힘' '사유=게이트 park'
row blocked '대상=-' '스코프=run' '원인=해소' '사유=게이트 park'
printf '2026-10-02T00:00:00Z\t스테이지 종단 후 라우터 무응답\t명령\n' > "$RD/stall"
out=$(stops)
has "run-blocked: liveness silence" "$out" "$(ev 'run-blocked/라이브니스 침묵' 비의도)"
has "run-blocked: segment never started" "$(stops)" "$(ev 'run-blocked/세그먼트 미개시' 비의도)"
has "run-blocked: enforcement surface moved" "$out" "$(ev 'run-blocked/강제 표면 이동' 비의도)"
has "run-blocked: inventory reason kept distinct" "$out" "$(ev 'run-blocked/인벤토리 스냅숏 손상' 비의도)"
has "run-blocked: out-of-vocabulary reason folds" "$out" "$(ev 'run-blocked/미분류' 비의도)"
has "run-blocked: an untranscribed stall observation counts" "$out" "$(ev 'run-blocked/스테이지 종단 후 라우터 무응답' 비의도)"
hasnt "run-blocked: a resolved block is no event" "$out" "게이트 park"

# --- stage --------------------------------------------------------------------

newcase
row stage-result '세그먼트=a' '스테이지=a' '종류=implement' '실행 버전=1' '종단 부류=크래시'
row stage-result '세그먼트=b' '스테이지=b' '종류=review' '실행 버전=1' '종단 부류=크래시'
row stage-result '세그먼트=b' '스테이지=b' '종류=review' '실행 버전=2' '종단 부류=정상 완료'
row stage-result '세그먼트=c' '스테이지=c' '종류=weird' '실행 버전=1' '종단 부류=한도 종료'
row stage-result '세그먼트=d' '스테이지=d' '종류=audit' '실행 버전=1' '종단 부류=의도된 park'
out=$(stops)
has "stage: last attempt crashed" "$out" "$(ev 'stage/크래시/implement' 비의도)"
hasnt "stage: a later successful attempt resolves" "$out" "/review"
has "stage: unknown kind folds" "$out" "$(ev 'stage/한도 종료/미분류' 비의도)"
hasnt "stage: an intended park is no stage event" "$out" "/audit"

# --- halt ---------------------------------------------------------------------

newcase
row stage-result '세그먼트=impl' '스테이지=impl' '종류=implement' '실행 버전=1' '종단 부류=의도된 park'
row stage-result '세그먼트=rev' '스테이지=rev' '종류=review' '실행 버전=1' '종단 부류=의도된 park'
row stage-result '세그먼트=aud' '스테이지=aud' '종류=audit' '실행 버전=1' '종단 부류=의도된 park'
row stage-result '세그먼트=aud' '스테이지=aud' '종류=audit' '실행 버전=2' '종단 부류=정상 완료'
halt 'impl#1' precondition-failed
halt 'rev#1' crash
halt 'ghost#1' tool-unavailable
halt 'aud#1' freeze-mismatch
out=$(stops)
has "halt: class and kind" "$out" "$(ev 'halt/precondition-failed/implement' 비의도)"
has "halt: an out-of-contract class folds" "$out" "$(ev 'halt/미분류/review' 비의도)"
has "halt: an unmapped stage id folds the kind" "$out" "$(ev 'halt/tool-unavailable/미분류' 비의도)"
hasnt "halt: a later completed attempt resolves the halt" "$out" "freeze-mismatch"
hasnt "halt: the observation body is never read" "$out" "자유 문면"

newcase
row stage-result '세그먼트=impl' '스테이지=impl' '종류=implement' '실행 버전=1' '종단 부류=의도된 park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=신고등급한도' '세그먼트=impl' '스테이지=impl#1'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=prod인가없음' '세그먼트=impl' '스테이지=impl#1'
halt 'impl#1' gate-unanswerable
has "halt: gate-unanswerable bound to a four-cell park is intended" "$(stops)" "$(ev 'halt/gate-unanswerable/implement' 의도 '사전 인가 밖')"

newcase
row stage-result '세그먼트=impl' '스테이지=impl' '종류=implement' '실행 버전=1' '종단 부류=의도된 park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=prod인가없음' '세그먼트=impl' '스테이지=impl#1'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=신고등급한도' '세그먼트=impl' '스테이지=impl#1'
halt 'impl#1' gate-unanswerable
has "halt: the LAST park decides — a later other cell is reported" "$(stops)" "$(ev 'halt/gate-unanswerable/implement' 비의도)"

newcase
row stage-result '세그먼트=impl' '스테이지=impl' '종류=implement' '실행 버전=1' '종단 부류=의도된 park'
halt 'impl#1' gate-unanswerable
has "halt: an unbound gate-unanswerable is reported with its marker" "$(stops)" "$(ev 'halt/gate-unanswerable/implement' 비의도 - '원인 셀 미결합')"

# --- cone ---------------------------------------------------------------------

newcase
row blocked '대상=-' '스코프=cone' '원인=판정 불가' '사유=사이클 예산 소진' '앵커 세그먼트=c1'
has "cone: unexplained undecidable cone" "$(stops)" "$(ev 'cone/판정 불가' 비의도)"
newcase
row stage-result '세그먼트=c1' '스테이지=c1' '종류=implement' '실행 버전=1' '종단 부류=크래시'
row blocked '대상=-' '스코프=cone' '원인=판정 불가' '사유=사이클 예산 소진' '앵커 세그먼트=c1'
out=$(stops)
hasnt "cone: a stage event explains the cone" "$out" "cone/"
has "cone: the explaining stage event stands" "$out" "$(ev 'stage/크래시/implement' 비의도)"

# --- run-end ------------------------------------------------------------------

newcase
row '자율 승인' 'kind=boundary' '결정=종료' '기준=B5'
row '자율 승인' 'kind=' '결정=act' '기준=무효화 종료'
out=$(stops)
has "run-end: B5" "$out" "$(ev 'run-end/B5' 비의도)"
has "run-end: invalidation end" "$out" "$(ev 'run-end/무효화 종료' 비의도)"

# --- shift and stage launch ---------------------------------------------------

newcase
row '자율 승인' 'kind=router-shift' '결정=결과' '근거=rc=127'
out=$(stops); has "shift: rc 127 is a launch precondition failure" "$out" "$(ev 'shift/기동 전제 실패' 비의도)"
newcase
row '자율 승인' 'kind=router-shift' '결정=결과' '근거=rc=1'
out=$(stops); has "shift: rc 1 is a death without handoff" "$out" "$(ev 'shift/handoff 없는 사망' 비의도)"
newcase
row '자율 승인' 'kind=router-shift' '결정=결과' '근거=rc=5'
row 승인 '승인 id=SHIFT-FLOOR-0a1b2c3d' '상태=대기' '절단점=경계'
out=$(stops)
hasnt "shift: rc 5 is no shift event" "$out" "shift/"
has "shift: rc 5 leaves the waiting floor approval to the approval class" "$out" "$(ev 'approval/경계/SHIFT-FLOOR' 비의도)"
newcase
row '자율 승인' 'kind=router-shift' '결정=결과' '근거=rc=1'
row handoff '교대=2' '사유=중단'
row '교대 기동' '서수=2' '사유=중단'
check "shift: a later shift launch resolves the death" "$(stops)" ""
newcase
row handoff '교대=2' '사유=중단'
check "handoff 중단 alone is no event" "$(stops)" ""

newcase
row stage-result '세그먼트=s1' '스테이지=s1' '종류=review' '실행 버전=1' '종단 부류=정상 완료'
row '자율 승인' 'kind=skill' '결정=act' '세그먼트=s1'
row '자율 승인' 'kind=skill' '결정=결과' '세그먼트=s1' '근거=rc=127'
has "stage-launch: rc 127 with no later launch" "$(stops)" "$(ev 'stage-launch/기동 전제 실패/review' 비의도)"
row '자율 승인' 'kind=skill' '결정=act' '세그먼트=s1'
check "stage-launch: a later launch of the segment resolves it" "$(stops)" ""

# --- park ---------------------------------------------------------------------

newcase
row segment 'id=p1' '상태=park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=CI실패' '세그먼트=p1' '스테이지=p1#1'
row segment 'id=p2' '상태=park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=prod인가없음' '세그먼트=p2' '스테이지=p2#1'
row segment 'id=p3' '상태=park'
row segment 'id=p4' '상태=park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=대상 미선언' '세그먼트=p4'
row segment 'id=p5' '상태=park'
row stage-result '세그먼트=p5' '스테이지=p5' '종류=design' '실행 버전=1' '종단 부류=공허한 성공'
row segment 'id=p6' '상태=park'
row blocked '대상=x' '스코프=act' '원인=막힘' '사유=도달 park' '도달 판정=등급회귀' '세그먼트=p6' '스테이지=p6#1'
out=$(stops)
has "park: reportable cell" "$out" "$(ev 'park/CI실패' 비의도)"
has "park: four-cell park is intended" "$out" "$(ev 'park/prod인가없음' 의도 '사전 인가 밖')"
has "park: no explaining row falls back" "$out" "$(ev 'segment/park' 비의도)"
has "park: undeclared target" "$out" "$(ev 'park/대상 미선언' 비의도)"
has "park: a cell outside the table folds" "$out" "$(ev 'park/미분류' 비의도)"
has "park: the stage event stands for its segment" "$out" "$(ev 'stage/공허한 성공/design' 비의도)"
check "park: a segment with a stage event adds no park line" "$(printf '%s\n' "$out" | grep -c '^park/\|^segment/')" "5"

newcase
row segment 'id=s1' '상태=실행중'
row segment 'id=s2' '상태=리뷰중'
row segment 'id=s3' '상태=완료'
row segment 'id=s4' '상태=머지됨'
row '종료 절' 'id=E1' '상태=충족'
check "in-flight, finished and declared-end segments are no event" "$(stops)" ""

# --- intended waits and resolution --------------------------------------------

mkmanifest() { printf '# 파이프라인 런 매니페스트 — fx\n\n## 인가\n**비용 천장**: %s\n\n## 요소\n' "$1" > "$WORK/case$n_case/manifest.md"; }

newcase
row cost '누적 usd=25'
row 승인 '승인 id=B4-0a1b2c3d' '상태=대기' '절단점=경계'
mkmanifest 20
has "B4: a waiting B4 at or past the ceiling is intended" "$(stops --manifest "$WORK/case$n_case/manifest.md")" "$(ev 'approval/경계/B4' 의도 '비용 천장')"
mkmanifest 100
has "B4: a waiting B4 below the ceiling is reported" "$(stops --manifest "$WORK/case$n_case/manifest.md")" "$(ev 'approval/경계/B4' 비의도)"
has "B4: an unreadable manifest reports the wait" "$(stops --manifest "$WORK/case$n_case/none.md")" "$(ev 'approval/경계/B4' 비의도)"

newcase
row '자율 승인' 'kind=boundary' '결정=종료' '기준=B4'
has "B4: an end row is intended and not an open wait" "$(stops)" "$(ev 'run-end/B4' 의도 '비용 천장' '열린 대기 아님')"

newcase
row 승인 '승인 id=A-1' '상태=대기' '절단점=머지'
has "a ladder-cutpoint act approval is intended" "$(stops)" "$(ev 'approval/미분류' 의도 '사전 인가 밖')"

for opener in design implement 라우터 미상; do
  newcase
  row 승인 '승인 id=J-1' '상태=대기' '절단점=판단' "연 자리=$opener"
  if [ "$opener" = design ]; then
    has "judgment opened by design is intended" "$(stops)" "$(ev 'approval/판단' 의도 '설계 판단')"
  else
    has "judgment opened by $opener is reported" "$(stops)" "$(ev 'approval/판단' 비의도)"
  fi
done

for why in '자유 입력' '슬롯 부재'; do
  newcase
  row 승인 '승인 id=J-2' '상태=대기' '절단점=판단' '연 자리=미상'
  row 승인 '승인 id=J-2' '상태=대기' "처분 사유=$why"
  has "an approval answered by $why is intended" "$(stops)" "$(ev 'approval/판단' 의도 '자유 입력')"
done

newcase
row 승인 '승인 id=J-3' '상태=대기' '절단점=판단' '연 자리=미상'
row 승인 '승인 id=J-3' '상태=승인' '처분 사유=자동 해소'
check "a closed approval is no event" "$(stops)" ""

# --- vocabulary pins ----------------------------------------------------------

table=$(bash "$STOPS" --vocab run-blocked)
missing=""
for lit in $( { grep -o 'record_blocked "[^"]*"' "$ORCH/watch.sh" || true; } | sed 's/^record_blocked "//; s/"$//' | tr ' ' '_'); do
  lit=$(printf '%s' "$lit" | tr '_' ' ')
  printf '%s\n' "$table" | grep -qxF "$lit" || missing="$missing[$lit]"
done
n_watch=$(grep -c 'record_blocked "' "$ORCH/watch.sh" || true)
[ "$n_watch" -ge 3 ] && ok "pin: the watcher's record_blocked literals were found ($n_watch)" || bad "pin: watcher literals" "found $n_watch"
check "pin: every watcher record_blocked reason is in the classifier's table" "$missing" ""
missing=""
for lit in $( { grep -o 'rundir_refuse "[^"]*"' "$ORCH/run.sh" || true; } | sed 's/^rundir_refuse "//; s/"$//' | tr ' ' '_' | sort -u); do
  lit=$(printf '%s' "$lit" | tr '_' ' ')
  printf '%s\n' "$table" | grep -qxF "$lit" || missing="$missing[$lit]"
done
n_run=$(grep -c 'rundir_refuse "' "$ORCH/run.sh" || true)
[ "$n_run" -ge 2 ] && ok "pin: the driver's rundir_refuse literals were found ($n_run)" || bad "pin: driver literals" "found $n_run"
check "pin: every driver rundir_refuse reason is in the classifier's table" "$missing" ""
check "pin: the kind table is the gate's STAGE_KINDS" \
  "$(bash "$STOPS" --vocab kinds | tr '\n' ' ' | sed 's/ $//')" \
  "$(sed -n 's/^readonly STAGE_KINDS="\(.*\)"$/\1/p' "$ORCH/gate.sh")"
check "pin: the cutpoint table is the driver's CUTPOINTS" \
  "$(bash "$STOPS" --vocab cutpoints | tr '\n' ' ' | sed 's/ $//')" \
  "$(sed -n 's/^readonly CUTPOINTS="\(.*\)"$/\1/p' "$ORCH/run.sh")"

# --- input boundary -----------------------------------------------------------

newcase
row stage-result '세그먼트=a' '스테이지=a' '종류=implement' '실행 버전=1' '종단 부류=크래시'
halt 'a#1' precondition-failed
printf '2026-10-02T00:00:00Z\t라이브니스 침묵\t명령\n' > "$RD/stall"
before=$(shasum -a 256 "$LG" "$RD/stall" "$RD/halt/a#1.md")
stops >/dev/null
check "boundary: the classifier writes nothing it reads" "$(shasum -a 256 "$LG" "$RD/stall" "$RD/halt/a#1.md")" "$before"
check "boundary: the classifier never calls gh" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
check "boundary: a missing ledger is a usage error" "$(bash "$STOPS" "$WORK/nope.md" "$RD" >/dev/null 2>&1; echo $?)" "2"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
