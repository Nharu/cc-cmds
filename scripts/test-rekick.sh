#!/usr/bin/env bash
# lint-autoadopt-vocabulary: self-skip
# Test the autopilot kickoff's reader of a previous run (orchestrator/rekick.sh).
#
# WHAT THIS SUITE IS FOR. A re-kickoff carries a stopped run's answers into a
# new run without asking them again, so every way it can go wrong is silent: a
# run it should not have picked is resumed under answers nobody gave this time,
# a check it skips lets a widened manifest through, and a step it removes on
# weak evidence is never run. So the fixtures here are real run files — a git
# repository, a manifest sealed with the driver's own digests, an authorization
# record the gate's own check reads, a run directory with a session index and
# lineage — and the verdicts are held against the driver and the gate rather
# than against copies of their rules written here.
#
# The gate's own decision whether it ended a run is asked in a separate `bash`
# that sources only the gate, and this suite asks the same function the same way
# and asserts the two agree. Every detection is bracketed by a hash over the
# previous run's files, its run directory and the session index: the helper
# writes nothing, and a gate path that did would show up here.
#
# This file carries forbidden auto-adoption class literals on purpose (they are
# the question case), hence the self-skip line above.
#
# The session id is a fixture value and is never printed.
#
# Usage: bash scripts/test-rekick.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
RK="$ORCH/rekick.sh"
KD="$ORCH/kickoff-defaults.sh"
DRIVER="$ORCH/run.sh"
GATE_SH="$ORCH/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-rekick-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' 가 없다: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "'$3' 가 있다" ;; *) ok "$1" ;; esac; }

TAB=$(printf '\t')

# The pipeline's variables, the host's defaults and the host's session must not
# leak in: the first make every call a refusal, the other two make results
# depend on the machine.
for v in $(compgen -e | grep -E '^(CC_PIPELINE_|CC_CMDS_AUTOPILOT_DEFAULT)' || true); do
  unset "$v"
done
unset CLAUDE_CODE_SESSION_ID
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# The dashboard server is off for the same reason: the gate's run-open branch
# starts one, and nothing in this suite stops it.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
HOME="$WORK/home"; mkdir -p "$HOME"
XDG_STATE_HOME="$WORK/state"; mkdir -p "$XDG_STATE_HOME"
XDG_CONFIG_HOME="$WORK/config"; mkdir -p "$XDG_CONFIG_HOME"
CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$WORK/no-such-defaults"
export HOME XDG_STATE_HOME XDG_CONFIG_HOME CC_CMDS_AUTOPILOT_DEFAULTS_FILE

# The gate calls in the dispatch case launch a stage: the stage CLI, the host's
# stage-policy map and the metrics round are all inert for this process, as in
# the gate suite.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/claude-noop"
cat > "$WORK/bin/metrics-noop" <<'METRICSNOOP'
#!/bin/sh
printf '%s\n' '{"fired":[],"close":[]}'
METRICSNOOP
cat > "$WORK/bin/claude-audit" <<'STUBAUDIT'
#!/usr/bin/env bash
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"srk-audit","num_turns":1,"result":"이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다."}\n'
exit 0
STUBAUDIT
chmod +x "$WORK/bin/claude-noop" "$WORK/bin/metrics-noop" "$WORK/bin/claude-audit"
export CC_CLAUDE_BIN="$WORK/bin/claude-noop"
export CC_GATE_STAGE_POLICY_SOURCES="$WORK/no-such-map"
export CC_METRICS_COLLECTOR="$WORK/bin/metrics-noop"
export CC_METRICS_FILING_FILE="$WORK/no-such-metrics-filing"

# shellcheck source=/dev/null
. "$repo_root/scripts/run-fixture.sh"
FX_PIDS=""
trap 'fx_reap; rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixture repository — `<base>` is its top level, as for a real run.
# ---------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
( cd "$REPO" \
  && git init -q . \
  && git config user.email t@example.invalid \
  && git config user.name T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant \
  && echo one > a.txt && git add -A && git commit -qm one ) >/dev/null 2>&1
( git init -q --bare "$WORK/remote.git" \
  && cd "$REPO" && git remote add origin "$WORK/remote.git" \
  && git branch -M main && git push -q origin main ) >/dev/null 2>&1
WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
BASE="$WT"
if [ -z "$WT" ] || [ -z "$CG" ]; then bad "픽스처" "픽스처 레포를 세우지 못했다"; exit 1; fi

DOC='docs/rk-design.md'
DOC_OPEN='docs/rk-open.md'
printf '# 픽스처 설계\n\n**상태**: 동결됨\n\n## 합의된 아키텍처\n\n본문\n' > "$BASE/$DOC"
printf '# 픽스처 설계\n\n**상태**: 논의 중\n\n본문\n' > "$BASE/$DOC_OPEN"
printf '# 베이스 설계\n\n본문 하나\n' > "$BASE/docs/rk-base.md"
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
DOCSHA=$(sha "$BASE/$DOC")

INTENT='재킥오프 이어받기를 시험한다'
PLAN4='{ "design_required": true, "entry_skill": "design", "steps": [ { "id": "D1", "skill": "design", "summary": "설계", "depends_on": [] }, { "id": "A1", "skill": "design-audit", "summary": "감사", "depends_on": ["D1"] }, { "id": "I1", "skill": "implement", "summary": "구현", "depends_on": ["D1", "A1"] }, { "id": "R1", "skill": "review", "summary": "리뷰", "depends_on": ["D1", "I1"] } ] }'
PLANBASE='{ "design_required": true, "design_scope": "base", "entry_skill": "design", "steps": [ { "id": "D1", "skill": "design", "summary": "설계", "depends_on": [] }, { "id": "A1", "skill": "design-audit", "summary": "감사", "depends_on": ["D1"] }, { "id": "S1", "skill": "split", "summary": "분할", "depends_on": ["A1"] } ] }'
KAT0='2026-10-01T00:00:00Z'
DL0='2030-01-01T09:00:00+09:00'

# drv <manifest> <function> — one driver function over a manifest, through the
# definitions-only seam, from inside the fixture repository.
drv() {
  ( cd "$WT" && CC_ORCH_SOURCE_ONLY=1 bash -c 'd="$1"; m="$2"; f="$3"; set --; . "$d" >/dev/null 2>&1; set +e; MANIFEST="$m"; "$f"' \
      _ "$DRIVER" "$1" "$2" 2>/dev/null )
}
# seal <manifest> — fill both digests from the driver's own serializers.
seal() {
  local td bd
  td=$(drv "$1" canonical_targets | shasum -a 256 | cut -d' ' -f1)
  bd=$(drv "$1" binding_set_bytes | shasum -a 256 | cut -d' ' -f1)
  sed -e "s/@TD@/$td/" -e "s/@BD@/$bd/" "$1" > "$1.t" && mv "$1.t" "$1"
}
# mf_check <manifest> — the driver's `check_manifest`, the second of the two
# steps of the defaults suite's `mf_run` (the digests are already derived).
mf_check() {
  ( cd "$WT" && CC_ORCH_SOURCE_ONLY=1 \
    bash -c 'd="$1"; m="$2"; e="$3"; set --; . "$d" >/dev/null 2>&1; set +e; MANIFEST="$m"; ( check_manifest ) >/dev/null 2>"$e"' \
      _ "$DRIVER" "$1" "$WORK/check.err" )
}

# write_manifest <path> <id> — the previous run's manifest. Knobs (all optional):
#   P_KAT P_DL P_PLAN P_DOC P_CUT P_AXES P_RULES P_EXTRA P_NOIV P_INTENT P_PROBE
#   P_AUTOADOPT (the auto-adoption row's class)
write_manifest() {
  local m="$1" id="$2" doc="${P_DOC:-$DOC}" cut="${P_CUT:-머지}" ivsha
  ivsha=$(sha "$BASE/docs/pipeline-run/$id.interview.md")
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$id"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$id"
    printf '     anchor-kind=repo; anchor-key=t/rk;\n'
    printf '     owner-doc=%s; origin-worktree=%s;\n' "$doc" "$WT"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: %s\n**런 id**: %s\n' "${P_KAT:-$KAT0}" "$id"
    printf '**앵커 종류**: repo\n**앵커 키**: t/rk\n**사용자 확인 문면**: 재킥오프 픽스처\n\n'
    printf '## 의도\n```text\n%s\n```\n\n' "${P_INTENT:-$INTENT}"
    printf '## 대상\n**대상 맵 다이제스트**: @TD@\n'
    printf -- '- `target` | 별칭=rk | 메인 워크트리=%s | 공통 git 디렉터리=%s | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/rk | 절단점=%s | 말단 행위 상한=없음\n\n' "$WT" "$CG" "$cut"
    printf '## 요소\n**설계 문서**: %s\n' "$doc"
    [ -z "${P_PROBE:-}" ] || printf '**적용 프로브**: %s\n' "$P_PROBE"
    printf '**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**승인 문면**: 진행\n```json\n%s\n```\n\n' "${P_PLAN:-$PLAN4}"
    if [ -n "${P_RULES:-}" ]; then printf '## 룰 설정\n%s\n\n' "$P_RULES"; fi
    printf '## 인가\n**구속 다이제스트**: @BD@\n**런 최대 절단점**: %s\n**종료 지점**: 픽스처가 끝나면\n' "$cut"
    printf '**벽시계 마감**: %s\n**시각 정합 마커**: 없음\n' "${P_DL:-$DL0}"
    [ -z "${P_AXES:-}" ] || printf '%s\n' "$P_AXES"
    printf '**사다리 가용 단 수**: 4\n**미선언 상황 처분**: park\n'
    printf -- '- `종료 절` | id=C1 | 문면=픽스처 절\n'
    printf -- '- `사전 인가` | 형태=git worktree | 사유=픽스처\n'
    printf -- '- `자동 채택` | 판단 부류=%s | 상한=없음 | 심각도 상한=minor | 사유=픽스처\n' "${P_AUTOADOPT:-스테이지-재시도}"
    if [ -z "${P_NOIV:-}" ]; then
      printf -- '- `사전 인가` | 인터뷰 기록=docs/pipeline-run/%s.interview.md | sha256=%s\n' "$id" "${ivsha:-0000000000000000000000000000000000000000000000000000000000000000}"
    fi
    printf -- '- `설계 로스터` | 역할=architecture | 범위=구조 | 모델=opus\n'
    [ -z "${P_EXTRA:-}" ] || printf '%s\n' "$P_EXTRA"
  } > "$m"
  seal "$m"
}

# grant_block <id> <cut> [종료 지점] [사용자 확인 문면] [설계 문서 전체 sha256]
grant_block() {
  printf '## 인가 %s\n**인가 일시**: 2026-10-01T00:00:00Z\n**종료 지점**: %s\n' "$1" "${3:-픽스처가 끝나면}"
  printf '**권한 절단점**: %s\n**말단 행위 상한**: 없음\n**직렬 웨이브 고지**: 해당 없음\n' "$2"
  printf '**시각 정합 마커**: 없음\n**사용자 확인 문면**: %s\n' "${4:-재킥오프 픽스처}"
  printf '**설계 문서 전체 sha256**: %s\n**보고서**: %s/docs/pipeline-run/%s.md\n' "${5:-(해당 없음)}" "$BASE" "$1"
}
# write_grant <id> <owner-doc> <block file|-> — the record, header and blocks.
write_grant() {
  {
    printf '# 파이프라인 인가 기록 — %s\n' "$1"
    printf '<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=%s; origin-worktree=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n\n' "$2" "$WT"
    if [ "$3" = "-" ]; then grant_block "$1" "${P_GCUT:-머지}"; else cat "$3"; fi
  } > "$BASE/docs/pipeline-grant/$1.md"
}

# mk_prev <id> — a stopped previous run in full: interview record, manifest,
# authorization record, an empty ledger at `<base>/docs/pipeline-run/<id>.md`,
# its run directory with `ledger-path` and a lineage naming the session `s-<id>`,
# and that session's index naming the run. Leaves FX_* on this run, so the
# fixture row writers append to its ledger.
mk_prev() {
  local id="$1"
  printf '# 파이프라인 런 인터뷰 기록 — %s\n\n픽스처 인터뷰 %s\n' "$id" "$id" > "$BASE/docs/pipeline-run/$id.interview.md"
  write_manifest "$BASE/docs/pipeline-run/$id.plan.md" "$id"
  write_grant "$id" "${P_DOC:-$DOC}" -
  fx_mkrun "$id"
  rm -f "$FX_LEDGER"
  FX_LEDGER="$BASE/docs/pipeline-run/$id.md"
  : > "$FX_LEDGER"
  export FX_LEDGER
  fx_ledger_path
  printf '%s\n' "s-$id" > "$FX_RUN_DIR/session-lineage"
  fx_session_index "s-$id" "$id"
}

# rk_as <sid> <args…> — the helper as a kickoff in that session, from a
# directory outside the fixture repository.
rk_as() {
  local sid="$1"; shift
  ( cd "$WORK" && CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$RK" "$@" 2>"$WORK/rk.err" )
}
rk() { ( cd "$WORK" && "$BASH" "$RK" "$@" 2>"$WORK/rk.err" ); }
# col <output> <key> [n] — column n (default 2) of the first line keyed <key>.
col() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v c="${3:-2}" '$1 == k { print $c; exit }'; }
cnt() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { n++ } END { print n + 0 }'; }

# src_sum <id> — one hash over everything a detection must leave alone.
src_sum() {
  local id="$1" rd="$XDG_STATE_HOME/cc-cmds/run/$1" f
  {
    for f in "$BASE/docs/pipeline-run/$id.plan.md" "$BASE/docs/pipeline-grant/$id.md" \
             "$BASE/docs/pipeline-run/$id.md" "$BASE/docs/pipeline-run/$id.interview.md"; do
      printf '%s %s\n' "$f" "$(sha "$f")"
    done
    find "$rd" "$XDG_STATE_HOME/cc-cmds/session" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(sha "$f")"
    done
  } | shasum -a 256 | cut -d' ' -f1
}

# gate_direct <id> — the gate's own end decision for that run, asked through
# the same definitions-only seam the helper uses.
gate_direct() {
  local id="$1" rd="$XDG_STATE_HOME/cc-cmds/run/$1"
  cp "$BASE/docs/pipeline-run/$id.plan.md" "$WORK/gd.plan.md"
  CC_GATE_SOURCE_ONLY=1 bash -c '
    g=$1; m=$2; rid=$3; rd=$4; led=$5; gr=$6; set --
    . "$g" >/dev/null 2>&1 || { echo 판정불가; exit 0; }
    set +e
    MANIFEST=$m; RUN_ID=$rid; RUN_DIR=$rd; LEDGER=$led; GRANT=$gr
    rc=0; gate_run_ended_ok skill - 2>/dev/null || rc=$?
    if [ "$rc" = 0 ]; then echo 안끝남; elif [ "$rc" = "$GATE_EXIT_RULE" ]; then echo 끝남; else echo 판정불가; fi
  ' _ "$GATE_SH" "$WORK/gd.plan.md" "$id" "$rd" "$BASE/docs/pipeline-run/$id.md" "$BASE/docs/pipeline-grant/$id.md" 2>/dev/null
}

# detect_case <label> <id> [arg] — detect for that run's session, with the hash
# bracket and, when the verdict rests on the gate, the agreement check. Sets OUT.
detect_case() {
  local label="$1" id="$2" before after verdict g
  before=$(src_sum "$id")
  OUT=$(rk_as "s-$id" detect --arg "${3:-}")
  after=$(src_sum "$id")
  check "$label: 판별 앞뒤로 원천 런 파일·런 디렉터리·색인이 같다" "$after" "$before"
  verdict=$(col "$OUT" 판정)
  if [ "$(col "$OUT" 갈래)" = "게이트 종료" ]; then
    g=$(gate_direct "$id")
    check "$label: 게이트를 직접 물은 결과와 같다 (끝남)" "$g" "끝남"
  fi
  if [ "$(col "$OUT" 갈래)" = "대기 이어받기" ]; then
    g=$(gate_direct "$id")
    check "$label: 게이트를 직접 물은 결과와 같다 (안끝남)" "$g" "안끝남"
  fi
  : "$verdict"
}

# ---------------------------------------------------------------------------
# 10. 거절 — 런 안에서는 어느 모드도 읽지 않는다
# ---------------------------------------------------------------------------
for var in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  for mode in 'detect --arg x' 'judge --prev X --base /x' 'verify --prev X --base /x' 'graph --prev X --base /x' \
              'render-manifest --prev X --base /x' 'render-manifest --auto --prev X --base /x' \
              'render-interview --prev X --base /x' \
              'verify-subset a b' 'verify-subset --auto a b'; do
    # shellcheck disable=SC2086
    out=$(cd "$WORK" && env "$var=x" "$BASH" "$RK" $mode 2>"$WORK/rk.err"); rc=$?
    check "10: $var 가 있으면 ${mode%% *} 는 3 으로 거부한다" "$rc" "3"
    check "10: $var 거부의 표준 출력은 비어 있다 (${mode%% *})" "$out" ""
  done
done
check "10: 거부의 표준 오류는 한 줄이다" "$(grep -c . "$WORK/rk.err")" "1"
out=$(rk 2>/dev/null); rc=$?
check "모드가 없으면 2" "$rc" "2"
check "용법 오류의 표준 출력은 비어 있다" "$out" ""
if grep -nE '^[^#]*\. "\$RK_DIR/gate\.sh"' "$RK" >/dev/null; then
  bad "게이트는 도우미 자신의 셸에 들여오지 않는다" "rekick.sh 가 gate.sh 를 직접 들여온다"
else
  ok "게이트는 도우미 자신의 셸에 들여오지 않는다"
fi
# The reason the gate child exists: a shell that already sourced the driver
# dies sourcing the gate, which sources the driver again.
( CC_ORCH_SOURCE_ONLY=1 . "$DRIVER" >/dev/null 2>&1; CC_GATE_SOURCE_ONLY=1 . "$GATE_SH" >/dev/null 2>&1; echo alive ) >"$WORK/twice.out" 2>/dev/null
if [ "$(cat "$WORK/twice.out")" != "alive" ]; then
  ok "run.sh 를 들여온 셸에서 gate.sh 를 들여오면 죽는다 (자식 프로세스가 필요한 이유)"
else
  bad "run.sh 를 들여온 셸에서 gate.sh 를 들여오면 죽는다" "살아남았다 — 따로 띄운 자식의 근거를 다시 볼 것"
fi

# ---------------------------------------------------------------------------
# 1. 판별 — 인자
# ---------------------------------------------------------------------------
mk_prev RKA; fx_done
for a in '' '다시' '다시 해줘' 'Resume.' "$INTENT"; do
  out=$(rk_as s-RKA detect --arg "$a")
  check "1: 인자 '$a' 는 재킥오프다" "$(col "$out" 판정)" "재킥오프"
done
check "1: 출력 머리는 cc-rekick v1 이다" "$(printf '%s\n' "$out" | sed -n '1p')" "cc-rekick v1"
check "1: 재킥오프 판정 행이 원천 id 를 싣는다" "$(col "$out" 판정 3)" "RKA"
out=$(rk_as s-RKA detect --arg '전혀 다른 일을 한다')
check "1: 다른 문장은 새 런이다" "$(col "$out" 판정)" "새 런"
has "1: 새 런 고지 줄이 있다" "$out" "다른 의도로 보고 새 런으로 시작합니다"

# ---------------------------------------------------------------------------
# 2. 찾기
# ---------------------------------------------------------------------------
out=$(rk_as s-RKA detect --arg '')
check "2: 작업 디렉터리가 원천 레포 밖이어도 ledger-path 로 base 를 찾는다" "$(col "$out" 판정 4)" "$BASE"
out=$(rk_as s-nobody detect --arg ''); rc=$?
check "2: 색인 파일이 없으면 없음이다" "$(col "$out" 판정)" "없음"
check "2: 없음도 0 으로 끝난다" "$rc" "0"
has "2: 없음 고지 줄" "$out" "처음 킥오프처럼 묻습니다"
out=$( ( cd "$WORK" && "$BASH" "$RK" detect --arg '' 2>/dev/null ) )
check "2: 세션 id 가 없으면 없음이다" "$(col "$out" 판정)" "없음"

# An older run with lineage, and a newer one in the index without lineage.
P_KAT='2026-09-01T00:00:00Z' mk_prev RKOLD; fx_done
P_KAT='2026-10-05T00:00:00Z' mk_prev RKNOLIN; fx_done
: > "$XDG_STATE_HOME/cc-cmds/run/RKNOLIN/session-lineage"
fx_session_index s-RKOLD RKNOLIN
out=$(rk_as s-RKOLD detect --arg '')
check "2: 색인에 있으나 계보에 없는 런은 고르지 않는다" "$(col "$out" 판정 3)" "RKOLD"

# The newest candidate is live: no fallback to an older one.
P_KAT='2026-10-06T00:00:00Z' mk_prev RKLIVE2; fx_stage_live I1
printf '%s\n' s-RKOLD >> "$FX_RUN_DIR/session-lineage"
fx_session_index s-RKOLD RKLIVE2
out=$(rk_as s-RKOLD detect --arg '')
check "2: 최신 후보가 자격이 없으면 더 오래된 후보로 물러서지 않는다" "$(col "$out" 판정)/$(col "$out" 판정 3)" "진행 중/RKLIVE2"

# The newest candidate's ledger-path is missing or of another shape.
P_KAT='2026-09-01T00:00:00Z' mk_prev RKLP1; fx_done
P_KAT='2026-10-07T00:00:00Z' mk_prev RKLP2; fx_done
printf '%s\n' s-RKLP1 >> "$FX_RUN_DIR/session-lineage"
fx_session_index s-RKLP1 RKLP2
rm -f "$FX_RUN_DIR/ledger-path"
out=$(rk_as s-RKLP1 detect --arg '')
check "2: 최신 후보의 ledger-path 가 없으면 없음이고 물러서지 않는다" "$(col "$out" 판정)" "없음"
printf '%s\n' "$BASE/docs/pipeline-run/other.md" > "$FX_RUN_DIR/ledger-path"
out=$(rk_as s-RKLP1 detect --arg '')
check "2: 최신 후보의 ledger-path 가 그 id 의 꼴이 아니면 없음이다" "$(col "$out" 판정)" "없음"

# ---------------------------------------------------------------------------
# 3. 자격
# ---------------------------------------------------------------------------
mk_prev RKINV
fx_blocked '강제 표면 이동' 무효화
fx_approval AP-1 대기
detect_case "3 강제 표면 이동" RKINV
check "3: 강제 표면 이동 무효화 + 열린 승인은 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
check "3: 그 갈래는 강제 표면 이동 무효화다" "$(col "$OUT" 갈래)" "강제 표면 이동 무효화"
has "3: 무효화 굵은 줄" "$OUT" "집행 표면이 옮겨져 무효화됐습니다"

mk_prev RKINVSUB
fx_blocked '강제 표면 이동 비슷한 것' 무효화
detect_case "3 부분 문자열" RKINVSUB 다시
check "3: 사유가 강제 표면 이동을 부분 문자열로만 가지면 무효화 갈래가 아니고 멈춤 대기다" \
  "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/멈춤"

mk_prev RKDONEPARK; fx_done
fx_blocked '세그먼트 정박' 막힘
detect_case "3 done + 정박" RKDONEPARK
check "3: done + 미해소 정박은 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
check "3: 종료 표시는 done 의 내용이다" "$(col "$OUT" '종료 표시')" "종단 — 픽스처"
has "3: 정박 굵은 줄이 건수와 사유를 싣는다" "$OUT" "남은 정박 1건(세그먼트 정박)"

mk_prev RKROW
fx_row '자율 승인' "결정=종료" "기준=비용 천장" "근거=100% 도달"
detect_case "3 종료 행" RKROW
check "3: done 없이 결정=종료 행만 있어도 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
has "3: 종료 행 갈래의 표시는 원장 종료 행을 든다 (괄호를 품은 표시를 자르지 않는다)" "$(col "$OUT" '종료 표시')" "(원장 종료 행 — 종단 표시는 수거됐습니다)"

P_DL='2026-01-01T00:00:00+09:00' mk_prev RKDL
fx_blocked '세그먼트 정박' 막힘
detect_case "3 마감 경과" RKDL
check "3: 진척 축 미선언 + 지난 ±HH:MM 마감은 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
has "3: 그 표시는 벽시계 마감 경과 (<값>) 이다" "$(col "$OUT" '종료 표시')" "벽시계 마감 경과 (2026-01-01T00:00:00+09:00)"
has "3: 마감 경과 원천의 정박 굵은 줄" "$OUT" "남은 정박 1건"
has "3: 종료 행 없이 마감 경과 표시로 끝난 원천은 끝 토큰이 마감이라 한도 문장을 싣는다" "$OUT" "같은 한도가 다시 바닥날 수 있습니다"

P_DL='2026-01-01T00:00:00+0900' mk_prev RKDLC
detect_case "3 마감 ±HHMM" RKDLC 다시
check "3: 같으나 마감이 ±HHMM 이면 끝나지 않은 멈춤 대기다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/멈춤"
check "3: 게이트도 그 런을 끝내지 않았다" "$(gate_direct RKDLC)" "안끝남"

mk_prev RKQUIET
detect_case "3 조용한 종단" RKQUIET 다시
check "3: done 없는 조용한 종단은 멈춤 대기다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/멈춤"
check "3: 대기 판정 행이 원천 id 와 원천 base 를 싣는다" "$(col "$OUT" 판정 3)/$(col "$OUT" 판정 4)" "RKQUIET/$BASE"
check "3: 대기의 갈래는 대기 이어받기다" "$(col "$OUT" 갈래)" "대기 이어받기"
has "3: 그 문면은 끝나지 않은 채 멈춰 있고 이어받는다고 한다" "$OUT" "이전 런 RKQUIET 은 끝나지 않은 채 멈춰 있습니다(멈춤) — 이 새 런이 이어받고, 원천 런은 이어받음으로 닫습니다"
hasnt "3: 멈춤 원인에는 한도 문장이 없다" "$OUT" "같은 한도"
check "3: 게이트도 그 런을 끝내지 않았다 (조용한 종단)" "$(gate_direct RKQUIET)" "안끝남"
fx_row '종료 절' "id=C1" "상태=충족" "근거=픽스처"
detect_case "3 조용한 종단 + 충족" RKQUIET
check "3: 같으나 모든 절의 마지막 행이 충족이면 완료다" "$(col "$OUT" 판정)" "완료"

mk_prev RKSLICE
fx_row 'blocked' "대상=-" "스코프=run" "원인=무효화" "사유=슬라이스 선언이 레포 밖을 가리킵니다" "관측=-" \
  "재개 명령=설계 문서의 ## 구현 슬라이싱 을 고쳐 새 런으로 다시 킥오프 — 이 런의 동결 문서는 바뀌지 않습니다"
detect_case "3 슬라이싱 거절" RKSLICE 다시
check "3: 슬라이싱 거절 모양의 무효화는 멈춤 대기다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/멈춤"
has "3: 그 문장은 끝나지 않은 채 멈춰 있다고 한다" "$OUT" "끝나지 않은 채 멈춰 있습니다(멈춤)"
has "3: 그 뒤에 재개 명령을 축자로 인용한다" "$OUT" "(이전 런이 남긴 재개 명령: 설계 문서의 ## 구현 슬라이싱 을 고쳐 새 런으로 다시 킥오프 — 이 런의 동결 문서는 바뀌지 않습니다)"
hasnt "3: 슬라이싱 거절은 승인 대기 문형이 아니다" "$OUT" "승인 대기"
check "3: 머리 문장이 인용보다 먼저 나온다" \
  "$(printf '%s\n' "$OUT" | grep -n -e '끝나지 않은 채' -e '재개 명령:' | cut -d: -f1 | tr '\n' ' ')" \
  "$(printf '%s\n' "$OUT" | grep -n -e '끝나지 않은 채' -e '재개 명령:' | cut -d: -f1 | sort -n | tr '\n' ' ')"
check "3: 머리 문장과 인용이 둘 다 있다 (순서 단언이 공허하지 않다)" \
  "$(printf '%s\n' "$OUT" | grep -c -e '끝나지 않은 채' -e '재개 명령:')" "2"

mk_prev RKAPPR
fx_approval AP-7 대기
detect_case "3 승인 대기" RKAPPR 다시
check "3: done 없는 승인 대기 정박은 승인 대기로 이어받는다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/승인 대기"
has "3: 열린 승인 줄이 건수와 질문 문면을 싣고 옮기지 않는다고 한다" "$OUT" "이전 런 RKAPPR 의 열린 승인 1건(픽스처)은 옮기지 않습니다"
hasnt "3: 새 런을 열 이유가 아니라는 거절 문장은 없다" "$OUT" "새 런을 열 이유가 아닙니다"
fx_row 'blocked' "대상=-" "스코프=run" "원인=무효화" "사유=다른 무효화" "관측=-" "재개 명령=새 런으로 다시 킥오프"
detect_case "3 승인 대기 + 재개 명령" RKAPPR 다시
has "3: 승인 대기 이어받기도 남은 재개 명령을 인용한다" "$OUT" "(이전 런이 남긴 재개 명령: 새 런으로 다시 킥오프)"
check "3: 이어받기의 마지막 줄은 처음부터 묻는 길이다" "$(printf '%s\n' "$OUT" | tail -n 1)" \
  "고지${TAB}이어받지 않고 처음부터 묻게 하려면 의도를 적어 다시 부르세요"

mk_prev RKLIVE; fx_stage_live I1; fx_done
detect_case "3 살아 있는 스테이지" RKLIVE
check "3: 살아 있는 스테이지가 있으면 done 이 있어도 진행 중이다" "$(col "$OUT" 판정)" "진행 중"
has "3: 그 문면은 아직 돌고 있다고 한다" "$OUT" "아직 돌고 있습니다"

mk_prev RKSHIFT; fx_done
sleep 120 & spid=$!; FX_PIDS="$FX_PIDS$spid "
printf '%s\n%s\n' "$spid" "$(LC_ALL=C ps -o lstart= -p "$spid" | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')" > "$FX_RUN_DIR/shift.live"
detect_case "3 살아 있는 교대" RKSHIFT
check "3: 살아 있는 교대가 있으면 진행 중이다" "$(col "$OUT" 판정)" "진행 중"

mk_prev RKBROKEN
rm -f "$FX_LEDGER"; mkdir -p "$FX_LEDGER"
detect_case "3 깨진 원장" RKBROKEN
check "3: 원장 경로를 깨 둔 런은 이어받지 않고 진행 중이다" "$(col "$OUT" 판정)" "진행 중"
rmdir "$FX_LEDGER"; : > "$FX_LEDGER"

# A gate whose answer is neither 0 nor its own refusal, a gate that cannot be
# sourced, and a gate stub that does end the run — the last proves the copy is
# what is asked, and that a mark carrying brackets is not cut at one.
STUBORCH="$WORK/orch-stub"
cp -R "$ORCH" "$STUBORCH"
mk_prev RKSTUB; fx_done
rk_stub() { ( cd "$WORK" && CLAUDE_CODE_SESSION_ID=s-RKSTUB "$BASH" "$STUBORCH/rekick.sh" detect --arg '' 2>/dev/null ); }
printf 'GATE_EXIT_RULE=3\ngate_run_ended_ok() { return 5; }\ngate_check_grant() { return 0; }\n' > "$STUBORCH/gate.sh"
out=$(rk_stub)
check "3: 게이트 함수가 GATE_EXIT_RULE 밖의 비영을 내면 진행 중이다" "$(col "$out" 판정)" "진행 중"
has "3: 그 문면은 게이트에서 종료 여부를 판정하지 못했다고 한다" "$out" "게이트에서 종료 여부를 판정하지 못했습니다"
printf 'return 1\n' > "$STUBORCH/gate.sh"
check "3: 게이트 들여오기가 실패하면 진행 중이다" "$(col "$(rk_stub)" 판정)" "진행 중"
cat > "$STUBORCH/gate.sh" <<'GATESTUB'
GATE_EXIT_RULE=3
gate_run_ended_ok() {
  printf '%s\n' "x [run][warn] the run has already terminated (스텁 (괄호) 표시) — no new stage is launched. A stage already running goes to the end" >&2
  return 3
}
GATESTUB
out=$(rk_stub)
check "3: 스텁 게이트가 끝냈다고 하면 재킥오프다 (사본의 게이트를 묻는다)" "$(col "$out" 판정)" "재킥오프"
check "3: 표시는 고정 접두·접미 사이 전체다" "$(col "$out" '종료 표시')" "스텁 (괄호) 표시"

# ---------------------------------------------------------------------------
# 3b. 이어받기 — 끝나지 않았고 살아 있는 것이 없는 런, 원인별 고지, 닫기
# ---------------------------------------------------------------------------
# rekick.sh writes nothing, so the close the re-kickoff makes after it is called
# here directly, the way rekickoff.md item 7.8 calls it: the gate's own verb on
# the source manifest. What a close must leave is read off the source ledger.
end_rows() { { grep -F '`자율 승인`' "$BASE/docs/pipeline-run/$1.md" 2>/dev/null || true; } | { grep -F '| 결정=종료 |' || true; }; }
close_src() {  # close_src <id> <successor> — sets rc
  ( cd "$WT" && bash "$GATE_SH" end-abandoned --manifest "$BASE/docs/pipeline-run/$1.plan.md" \
      --cause 이어받음 --successor "$2" ) >"$WORK/close.out" 2>&1; rc=$?
}
# unanswered <id> — the driver's own count of that run's unanswered halt records.
unanswered() {
  ( cd "$WT" && CC_ORCH_SOURCE_ONLY=1 bash -c 'd="$1"; r="$2"; l="$3"; set --; . "$d" >/dev/null 2>&1; set +e; cc_unanswered_halts "$r" "$l"' \
      _ "$DRIVER" "$XDG_STATE_HOME/cc-cmds/run/$1" "$BASE/docs/pipeline-run/$1.md" 2>/dev/null )
}
# adopt_case <label> <id> <원인> — the source is adopted with that cause, then
# closed `이어받음`, after which detect reads it as gate-ended.
adopt_case() {
  local label="$1" id="$2" cause="$3" ends
  detect_case "$label" "$id" 다시
  check "$label: 판정은 대기이고 원인은 $cause 다" "$(col "$OUT" 판정)/$(col "$OUT" 판정 3)/$(col "$OUT" '대기 원인')" "대기/$id/$cause"
  has "$label: 머리 굵은 줄이 원인을 싣는다" "$OUT" "이전 런 $id 은 끝나지 않은 채 멈춰 있습니다($cause)"
  close_src "$id" "RKSUCC-$id"
  ends=$(end_rows "$id")
  check "$label: 닫기는 0 으로 끝나고 종료 행 하나를 쓴다" "$rc/$(printf '%s' "$ends" | grep -c .)" "0/1"
  case "$ends" in
    *'| 재킥 원인=해당없음 | 종료 부류=이어받음 |'*"후계 런 RKSUCC-$id "*) ok "$label: 종료 행은 이어받음과 후계 런 id 를 싣는다" ;;
    *) bad "$label: 종료 행은 이어받음과 후계 런 id 를 싣는다" "$ends $(tail -2 "$WORK/close.out")" ;;
  esac
  OUT2=$(rk_as "s-$id" detect --arg '')
  check "$label: 닫은 뒤의 판별은 게이트 종료 재킥오프다" "$(col "$OUT2" 판정)/$(col "$OUT2" 갈래)" "재킥오프/게이트 종료"
  hasnt "$label: 이어받음으로 끝난 원천에는 한도 문장이 없다" "$OUT2" "같은 한도"
  check "$label: 원천 원장에 세그먼트 입양 행이 없다" \
    "$(grep -c '세그먼트 입양' "$BASE/docs/pipeline-run/$id.md" 2>/dev/null || true)" "0"
}
# arg_table <label> <id> <원인> — the argument decides adoption of an un-ended
# quiet run: an empty argument, a resume word or the intent verbatim holds it
# `진행 중` with its cause, a re-kickoff word adopts it `대기`. Nothing is closed
# either way, since detect writes nothing and no close follows a hold.
arg_table() {
  local label="$1" id="$2" cause="$3" a
  for a in '' '이어서' '재개' '계속' 'resume' 'Resume.' '재개해줘' "$INTENT"; do
    detect_case "$label 인자 '$a'" "$id" "$a"
    check "$label: 인자 '$a' 는 이어받지 않고 진행 중이며 원인을 싣는다" \
      "$(col "$OUT" 판정)/$(col "$OUT" 판정 3)/$(col "$OUT" '대기 원인')" "진행 중/$id/$cause"
    has "$label: 인자 '$a' 의 고지는 재개로 보고 다시 로 이어받는 길을 든다" "$OUT" \
      "이전 런 $id 은 끝나지 않은 채 멈춰 있습니다($cause) — 이 호출은 재개로 보고 이어받지 않습니다"
    hasnt "$label: 인자 '$a' 에는 이어받는 머리 줄이 없다" "$OUT" "원천 런은 이어받음으로 닫습니다"
    hasnt "$label: 인자 '$a' 에는 한도 문장이 없다" "$OUT" "같은 한도"
  done
  for a in '다시' '재킥오프' '다시 킥오프' 'rekick' 'again' 'retry' 'Retry!' '다시 해줘'; do
    detect_case "$label 인자 '$a'" "$id" "$a"
    check "$label: 인자 '$a' 는 대기로 이어받는다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/$cause"
  done
  check "$label: 인자 표를 다 돈 뒤에도 원천에 종료 행이 없다" "$(end_rows "$id" | grep -c . || true)" "0"
  check "$label: 인자 표를 다 돈 뒤에도 게이트는 원천을 끝내지 않았다" "$(gate_direct "$id")" "안끝남"
}

# The #1281 shape: the shift handed off on a stop and a halt record waits.
mk_prev RKW1281
fx_row 'handoff' "교대=1" "사유=중단" "버린 선택지=-"
mkdir -p "$FX_RUN_DIR/halt/shift"
printf '# 정지\n' > "$FX_RUN_DIR/halt/I1#2.md"
printf '# 답\n' > "$FX_RUN_DIR/halt/I1#2.answer.md"
printf '# 정지\n' > "$FX_RUN_DIR/halt/I1#1.md"
fx_row '중단 답' "중단 기록=$FX_RUN_DIR/halt/I1#1.md" "답=재수렴"
printf '# 정지\n' > "$FX_RUN_DIR/halt/shift/S1.md"
arg_table "3b 사람 대기" RKW1281 '사람 대기'
detect_case "3b 사람 대기 재개" RKW1281
has "3b 사람 대기 재개: 재개 고지가 답 없는 정지 기록을 나열한다" "$OUT" \
  "이전 런 RKW1281 의 답 없는 정지 기록 2건(I1#2.md, shift/S1.md)에 답하면 그 런이 이어집니다"
detect_case "3b 사람 대기" RKW1281 다시
has "3b 사람 대기: 답 없는 정지 기록을 이름으로 나열한다" "$OUT" \
  "이전 런 RKW1281 의 답 없는 정지 기록 2건(I1#2.md, shift/S1.md)은 옮기지 않습니다"
check "3b 사람 대기: 나열한 수가 cc_unanswered_halts 와 같다" \
  "$(printf '%s\n' "$OUT" | sed -n 's/.*답 없는 정지 기록 \([0-9][0-9]*\)건.*/\1/p')" "$(unanswered RKW1281)"
check "3b 사람 대기: 대조하는 수가 비어 있지 않다" "$(unanswered RKW1281)" "2"
hasnt "3b 사람 대기: 사람 대기에는 한도 문장이 없다" "$OUT" "같은 한도"
adopt_case "3b 사람 대기" RKW1281 '사람 대기'

mk_prev RKWAP
fx_row '승인' "승인 id=AP-9" "상태=대기" "대상=-" "절단점=경계" "질문 문면=배포 창을 열까" "답변 문면=-" "해소 시각=-"
fx_row '승인' "승인 id=AP-8" "상태=대기" "대상=-" "절단점=경계" "답변 문면=-" "해소 시각=-"
arg_table "3b 승인 대기" RKWAP '승인 대기'
detect_case "3b 승인 대기 재개" RKWAP 재개
has "3b 승인 대기 재개: 재개 고지가 답하면 이어지는 열린 승인을 나열한다" "$OUT" \
  "이전 런 RKWAP 의 열린 승인 2건(AP-8, 배포 창을 열까)에 답하면 그 런이 이어집니다"
detect_case "3b 승인 대기" RKWAP 다시
has "3b 승인 대기: 열린 승인을 질문 문면으로, 없으면 id 로 나열한다" "$OUT" "열린 승인 2건(AP-8, 배포 창을 열까)은 옮기지 않습니다"
adopt_case "3b 승인 대기" RKWAP '승인 대기'
check "3b 승인 대기: 닫은 뒤에도 승인 행은 대기다" \
  "$( ( cd "$WT" && CC_ORCH_SOURCE_ONLY=1 bash -c 'd="$1"; l="$2"; set --; . "$d" >/dev/null 2>&1; cc_open_approval_rows "$l"' _ "$DRIVER" "$BASE/docs/pipeline-run/RKWAP.md" 2>/dev/null ) | grep -c .)" "2"

# A shift that had nothing left but waiting on a stage or a CI verdict hands off
# `사유=대기`; once that relay is gone the run is idle on nothing a limit holds,
# with or without the stage's result arriving after.
mk_prev RKWCI
fx_row 'handoff' "교대=1" "사유=대기" "버린 선택지=-" "CI 대기=S1"
detect_case "3b 스테이지·CI 대기 인계" RKWCI 다시
check "3b 스테이지·CI 대기 인계: 사유=대기 는 한도 대기가 아니라 멈춤이다" "$(col "$OUT" 판정)/$(col "$OUT" '대기 원인')" "대기/멈춤"
has "3b 스테이지·CI 대기 인계: 스테이지·CI 결과를 기다리며 끝났다고 한다" "$OUT" "마지막 교대는 스테이지·CI 결과를 기다리며 끝났고"
hasnt "3b 스테이지·CI 대기 인계: 한도 문장이 없다" "$OUT" "같은 한도"
hasnt "3b 스테이지·CI 대기 인계: 사용 한도를 기다렸다고 하지 않는다" "$OUT" "사용 한도"
fx_row 'stage-result' "세그먼트=S1" "스테이지=S1" "종류=implement" "종료 코드=0" "실행 버전=1" "종단 부류=정상 완료"
detect_case "3b 스테이지·CI 대기 인계 + 정상 완료" RKWCI 다시
check "3b 스테이지·CI 대기 인계 + 정상 완료: 여전히 멈춤이다" "$(col "$OUT" '대기 원인')" "멈춤"
hasnt "3b 스테이지·CI 대기 인계 + 정상 완료: 한도 문장이 없다" "$OUT" "같은 한도"
adopt_case "3b 스테이지·CI 대기 인계" RKWCI 멈춤

# A usage limit is read off a stage it cut, and released by either row.
mk_prev RKWLIM
fx_row 'stage-result' "세그먼트=I1" "스테이지=I1" "종류=implement" "종료 코드=1" "실행 버전=1" "종단 부류=한도 종료"
detect_case "3b 한도 대기" RKWLIM 다시
has "3b 한도 대기: 한도 원인은 같은 한도 문장을 싣는다" "$OUT" "사용 한도를 기다리며 멈췄습니다 — 같은 한도가 다시 바닥날 수 있습니다"
adopt_case "3b 한도 대기" RKWLIM '한도 대기'

for rel in '한도 해제' '교대 기동'; do
  for kind in '한도 종료' '한도-형상 회수'; do
    id="RKWREL$(printf '%s%s' "$rel" "$kind" | shasum | cut -c1-6)"
    mk_prev "$id"
    fx_row 'stage-result' "세그먼트=I1" "스테이지=I1" "종류=implement" "종료 코드=1" "실행 버전=1" "종단 부류=$kind"
    detect_case "3b $kind" "$id" 다시
    check "3b $kind: 마지막 스테이지 결과가 $kind 이면 한도 대기다" "$(col "$OUT" '대기 원인')" "한도 대기"
    fx_row "$rel" "근거=픽스처" "기록 시각=2026-10-01T01:00:00Z"
    detect_case "3b $kind 뒤 $rel" "$id" 다시
    check "3b $kind 뒤 $rel: 풀린 한도는 멈춤이다" "$(col "$OUT" '대기 원인')" "멈춤"
    hasnt "3b $kind 뒤 $rel: 한도 문장이 없다" "$OUT" "같은 한도"
  done
done

# A limit-cut stage followed by a shift lost without a handoff: still the limit.
mk_prev RKWLNR
fx_row 'stage-result' "세그먼트=I1" "스테이지=I1" "종류=implement" "종료 코드=1" "실행 버전=1" "종단 부류=한도 종료"
fx_row 'handoff' "교대=1" "사유=무기록" "버린 선택지=-"
detect_case "3b 한도 종료 뒤 무기록" RKWLNR 다시
check "3b 한도 종료 뒤 무기록: 한도가 무기록보다 앞선다" "$(col "$OUT" '대기 원인')" "한도 대기"

# An approval and a halt record together: the approval decides the cause, and
# both are listed.
mk_prev RKWBOTH
fx_row '승인' "승인 id=AP-3" "상태=대기" "대상=-" "절단점=경계" "질문 문면=둘 다 있다" "답변 문면=-" "해소 시각=-"
mkdir -p "$FX_RUN_DIR/halt"
printf '# 정지\n' > "$FX_RUN_DIR/halt/I1#1.md"
detect_case "3b 승인 + 정지 기록" RKWBOTH 다시
check "3b 승인 + 정지 기록: 원인은 승인 대기다" "$(col "$OUT" '대기 원인')" "승인 대기"
has "3b 승인 + 정지 기록: 열린 승인을 나열한다" "$OUT" "열린 승인 1건(둘 다 있다)은 옮기지 않습니다"
has "3b 승인 + 정지 기록: 답 없는 정지 기록도 나열한다" "$OUT" "답 없는 정지 기록 1건(I1#1.md)은 옮기지 않습니다"

mk_prev RKWSR2
fx_row 'stage-result' "세그먼트=I1" "스테이지=I1" "종류=implement" "종료 코드=1" "실행 버전=1" "종단 부류=한도 종료 아님"
detect_case "3b 부분 문자열 종단 부류" RKWSR2 다시
check "3b 부분 문자열 종단 부류: 통 필드가 아니면 한도 대기가 아니다" "$(col "$OUT" '대기 원인')" "멈춤"

mk_prev RKWNR
fx_row 'handoff' "교대=1" "사유=무기록" "버린 선택지=-"
detect_case "3b 무기록" RKWNR 다시
has "3b 무기록: 인계 없이 끝났다고 한다" "$OUT" "마지막 교대가 인계 없이 끝났습니다"
hasnt "3b 무기록: 한도 문장이 없다" "$OUT" "같은 한도"
adopt_case "3b 무기록" RKWNR 무기록

mk_prev RKWQ
arg_table "3b 멈춤" RKWQ 멈춤
detect_case "3b 멈춤" RKWQ 다시
has "3b 멈춤: 기다리는 것 없이 멈췄다고 한다" "$OUT" "기다리는 것 없이 멈췄습니다"
adopt_case "3b 멈춤" RKWQ 멈춤

# A stage or CI wait whose relay is still alive is not adopted, even on a
# re-kickoff word, and the close the re-kickoff would make is refused for the
# same reason.
mk_prev RKWRELAY
fx_row 'handoff' "교대=1" "사유=대기" "버린 선택지=-" "CI 대기=S1"
sleep 120 & rpid=$!; FX_PIDS="$FX_PIDS$rpid "
printf '%s\n%s\nrefreshed=%s\n' "$rpid" "$(LC_ALL=C ps -o lstart= -p "$rpid" | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')" "$(date -u +%s)" > "$FX_RUN_DIR/relay.live"
detect_case "3b 산 중계" RKWRELAY 다시
check "3b 산 중계: 살아 있는 중계가 있는 대기는 재킥 낱말에도 진행 중이다" "$(col "$OUT" 판정)" "진행 중"
has "3b 산 중계: 그 문면은 아직 돌고 있다고 한다" "$OUT" "아직 돌고 있습니다"
close_src RKWRELAY RKSUCC-RKWRELAY
check "3b 산 중계: 같은 런의 닫기도 거절되고 종료 행이 없다" "$rc/$(end_rows RKWRELAY | grep -c .)" "3/0"

mk_prev RKWWAIT
sleep 120 & wpid=$!; FX_PIDS="$FX_PIDS$wpid "
printf '보유자=%s\n지문=%s\n기록자=게이트\n계보=B:I1#1\n그룹=-\n까지=-\n갱신=%s\n종류=implement\n시도=1\n' \
  "$wpid" "$(LC_ALL=C ps -o lstart= -p "$wpid" | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')" "$(date -u +%s)" > "$FX_RUN_DIR/I1.waiting"
detect_case "3b 신선한 대기 스테이지" RKWWAIT 다시
check "3b 신선한 대기 스테이지: 진행 중이다" "$(col "$OUT" 판정)" "진행 중"

# An ended source that still holds an open person-decision approval and an
# unlanded segment: the approval is listed and left waiting, and the unlanded
# notice is today's, byte for byte.
mk_prev RKWEND; fx_done
fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=벽시계 마감" "재킥 원인=마감" "근거=마감 도달"
fx_row '승인' "승인 id=AP-H1" "상태=대기" "대상=-" "절단점=경계" "판단 부류=사람-결정" "질문 문면=스키마를 둘로 나눌까" "답변 문면=-" "해소 시각=-"
fx_row 'segment' "id=I1" "상태=리뷰" "워크트리=$FX_RUN_DIR" "PR=12"
detect_case "3b 끝난 원천의 열린 승인" RKWEND
check "3b 끝난 원천의 열린 승인: 게이트 종료 재킥오프다" "$(col "$OUT" 판정)/$(col "$OUT" 갈래)" "재킥오프/게이트 종료"
has "3b 끝난 원천의 열린 승인: 굵은 줄이 승인의 질문 문면을 싣는다" "$OUT" \
  "굵게${TAB}이전 런 RKWEND 의 열린 승인 1건(스키마를 둘로 나눌까)은 닫거나 옮기지 않습니다"
has "3b 끝난 원천의 열린 승인: 마감으로 끝난 원천은 한도 문장을 싣는다" "$OUT" "같은 한도가 다시 바닥날 수 있습니다"
check "3b 끝난 원천의 열린 승인: 머지되지 않은 작업 고지가 지금 문면과 바이트로 같다" \
  "$(printf '%s\n' "$OUT" | grep -c -x -F "고지${TAB}이전 런의 머지되지 않은 작업(I1 PR 12)은 이어받지 않습니다 — 새 런이 그 세그먼트를 다시 합니다")" "1"
check "3b 끝난 원천의 열린 승인: 승인 행은 판별 뒤에도 대기다" \
  "$( { grep -F '| 승인 id=AP-H1 |' "$BASE/docs/pipeline-run/RKWEND.md" || true; } | tail -n 1 | grep -c '| 상태=대기 |')" "1"
check "3b 끝난 원천의 열린 승인: 세그먼트 입양 행이 없다" "$(grep -c '세그먼트 입양' "$BASE/docs/pipeline-run/RKWEND.md" || true)" "0"

# An ended source whose end token is not a budget: the boundary sentence only.
mk_prev RKWDEF; fx_done
fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=결함" "재킥 원인=결함" "근거=픽스처"
detect_case "3b 결함 종료" RKWDEF
has "3b 결함 종료: 경계 문장은 있다" "$OUT" "이전 런 RKWDEF 을 끝낸 경계는 같은 값으로 다시 주어집니다"
hasnt "3b 결함 종료: 예산 토큰이 아닌 끝에는 한도 문장이 없다" "$OUT" "같은 한도"
# The earliest ending row is the token, as the gate reads it: a later row does
# not turn a budget end into another.
fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=마감" "재킥 원인=마감" "근거=나중 행"
detect_case "3b 결함 종료 + 나중 마감 행" RKWDEF
hasnt "3b 결함 종료 + 나중 마감 행: 끝 토큰은 첫 종료 행의 것이다" "$OUT" "같은 한도"

# ---------------------------------------------------------------------------
# 4. 완료와 종료 절
# ---------------------------------------------------------------------------
P_EXTRA='- `종료 절` | id=C2 | 문면=둘째 절' mk_prev RKC2; fx_done
fx_row '종료 절' "id=C1" "상태=충족" "근거=a"
fx_row '종료 절' "id=C2" "상태=충족" "근거=b"
detect_case "4 전부 충족 + done" RKC2
check "4: 모든 절의 마지막 행이 충족이면 게이트 종료가 있어도 완료다" "$(col "$OUT" 판정)" "완료"
check "4: 완료 고지는 두 줄이다" "$(cnt "$OUT" 고지)" "2"

mk_prev RKIMP; fx_done
fx_row '종료 절' "id=C1" "상태=충족" "근거=처음엔 됐다"
fx_row '종료 절' "id=C1" "상태=불가능" "근거=대상 레포에 쓸 수 없다\\n둘째 줄"
detect_case "4 불가능" RKIMP
check "4: 불가능 절이 있는 원천은 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
has "4: 불가능 굵은 줄이 근거의 첫 줄을 축자로 싣는다" "$OUT" "C1 를 불가능으로 끝냈습니다(대상 레포에 쓸 수 없다)"
hasnt "4: 근거의 둘째 줄은 싣지 않는다" "$OUT" "둘째 줄"
mk_prev RKIMP2; fx_done
fx_row '종료 절' "id=C1" "상태=불가능" "근거=처음엔 안 됐다"
fx_row '종료 절' "id=C1" "상태=충족" "근거=됐다"
detect_case "4 불가능 → 충족" RKIMP2
check "4: 불가능 → 충족 순서면 불가능 줄이 없고 완료다" "$(col "$OUT" 판정)" "완료"

mk_prev RKHOLD
printf '%s\n' "질의 잔여 — 픽스처" > "$FX_RUN_DIR/done"
fx_row '종료 절' "id=C1" "상태=보류" "근거=사람의 답을 기다린다"
detect_case "4 보류" RKHOLD
check "4: 질의 잔여 + 보류 절 원천은 재킥오프다" "$(col "$OUT" 판정)" "재킥오프"
has "4: 보류 굵은 줄" "$OUT" "C1 는 보류(사람의 답 대기)로 끝났습니다"

mk_prev RKNOCL; fx_done
grep -v '^- `종료 절`' "$BASE/docs/pipeline-run/RKNOCL.plan.md" > "$WORK/nocl.md"
cp "$WORK/nocl.md" "$BASE/docs/pipeline-run/RKNOCL.plan.md"
detect_case "4 절 없음" RKNOCL
check "4: 종료 절 id 가 하나도 없는 원천은 완료가 아니다" "$(col "$OUT" 판정)" "재킥오프"

# ---------------------------------------------------------------------------
# 5. 무결성
# ---------------------------------------------------------------------------
mk_prev RKV; fx_done
out=$(rk verify --prev RKV --base "$BASE"); rc=$?
check "5: 깨끗한 원천의 verify 는 통과한다" "$rc/$(col "$out" 판정)" "0/통과"
check "5: verify 가 원천 매니페스트의 전체 sha256 을 낸다" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "해시" && $2 == "매니페스트" { print $3 }')" "$(sha "$BASE/docs/pipeline-run/RKV.plan.md")"
check "5: verify 가 원천 인가 기록의 전체 sha256 을 낸다" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "해시" && $2 == "인가 기록" { print $3 }')" "$(sha "$BASE/docs/pipeline-grant/RKV.md")"
check "5: verify 가 인터뷰 기록의 전체 sha256 을 낸다" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "해시" && $2 == "인터뷰" { print $3 }')" "$(sha "$BASE/docs/pipeline-run/RKV.interview.md")"
check "5: 깨끗한 원천에는 질문 행이 없다" "$(cnt "$out" 질문)" "0"

vfail() {  # vfail <label> <want check name>
  local o r
  o=$(rk verify --prev "$VID" --base "$BASE"); r=$?
  check "5: $1 — verify 는 1 로 실패한다" "$r/$(col "$o" 판정)" "1/실패"
  has "5: $1 — 실패한 검사 이름 $2 이 나온다" "$(col "$o" 판정 3)" "$2"
}
VID=RKV1; mk_prev RKV1
sed 's/^\*\*종료 지점\*\*: 픽스처가 끝나면$/**종료 지점**: 픽스처가 끝나몀/' "$BASE/docs/pipeline-run/RKV1.plan.md" > "$WORK/t.md"
cp "$WORK/t.md" "$BASE/docs/pipeline-run/RKV1.plan.md"
vfail "매니페스트 한 바이트 변조" 다이제스트
VID=RKV2; mk_prev RKV2; printf 'x' >> "$BASE/docs/pipeline-run/RKV2.interview.md"
vfail "인터뷰 기록 변조" 인터뷰
VID=RKV3; mk_prev RKV3; rm -f "$BASE/docs/pipeline-run/RKV3.interview.md"
vfail "인터뷰 행만 있고 파일 없음" 인터뷰
VID=RKV3B; P_NOIV=1 mk_prev RKV3B
vfail "인터뷰 파일만 있고 행 없음" 인터뷰
VID=RKV4; mk_prev RKV4
grep -v '^\*\*직렬 웨이브 고지\*\*' "$BASE/docs/pipeline-grant/RKV4.md" > "$WORK/t.md"; cp "$WORK/t.md" "$BASE/docs/pipeline-grant/RKV4.md"
vfail "인가 블록 필드 하나 누락" 인가
VID=RKV5; mk_prev RKV5
{ printf '\n'; grant_block OTHERRUN 머지; } >> "$BASE/docs/pipeline-grant/RKV5.md"
vfail "인가 기록에 다른 런의 블록" 인가
VID=RKV6; P_GCUT=커밋 mk_prev RKV6
vfail "대상 절단점이 권한 절단점을 넘음" 인가
VID=RKV7; mk_prev RKV7
sed 's/^\(<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=\)RKV7;/\1RKV7X;/' "$BASE/docs/pipeline-run/RKV7.plan.md" > "$WORK/t.md"
cp "$WORK/t.md" "$BASE/docs/pipeline-run/RKV7.plan.md"
vfail "머리 run-id 가 본문과 다름" 머리

OLDBASESHA=$(printf 'old' | shasum -a 256 | cut -d' ' -f1)
P_EXTRA="- \`베이스 설계\` | 문서=docs/rk-base.md | sha256=$OLDBASESHA | 티켓=T1" mk_prev RKVB; fx_done
out=$(rk verify --prev RKVB --base "$BASE"); rc=$?
check "5: 베이스 설계 해시가 달라진 원천은 실패가 아니다" "$rc/$(col "$out" 판정)" "0/통과"
check "5: 그 원천은 질문 하나를 낸다" "$(cnt "$out" 질문)/$(col "$out" 질문)" "1/베이스설계"
check "5: 질문이 지금 해시를 싣는다" "$(col "$out" 질문 5)" "$(sha "$BASE/docs/rk-base.md")"

# ---------------------------------------------------------------------------
# 11. 검증 표류 — 지금 금지된 자동 채택 부류
# ---------------------------------------------------------------------------
P_AUTOADOPT='설계-골격' mk_prev RKAA; fx_done
out=$(rk verify --prev RKAA --base "$BASE")
check "11: 금지된 부류의 자동 채택 행은 질문 하나를 낸다" "$(cnt "$out" 질문)/$(col "$out" 질문)" "1/자동채택"
has "11: 질문이 그 행을 축자로 싣는다" "$(col "$out" 질문 3)" "판단 부류=설계-골격"
PMAA=$(sha "$BASE/docs/pipeline-run/RKAA.plan.md"); PGAA=$(sha "$BASE/docs/pipeline-grant/RKAA.md")
out=$(rk render-manifest --prev RKAA --base "$BASE" --run-id RKAA2 --kickoff-at 2026-10-10T00:00:00Z \
        --deadline 2030-01-01T00:00:00Z --expect-sha256 "$PMAA" --expect-grant-sha256 "$PGAA")
check "11: 그 행은 답 없이 빼지도 않는다" "$(printf '%s\n' "$out" | grep -c '판단 부류=설계-골격')" "1"

# ---------------------------------------------------------------------------
# 6. 그래프
# ---------------------------------------------------------------------------
P_KAT='2026-10-01T00:00:00Z' mk_prev RKG; fx_done
fx_row 'stage-result' "세그먼트=-" "스테이지=D1" "종류=design" "종단 부류=정상 완료"
fx_row '문서 해시' "스테이지=A1 이후" "sha256=$DOCSHA" "동결값=-" "관측=-"
fx_row 'stage-result' "세그먼트=-" "스테이지=A1" "종류=audit" "종단 부류=정상 완료"
fx_row 'stage-result' "세그먼트=-" "스테이지=A1" "종류=audit" "종단 부류=크래시"
out=$(rk graph --prev RKG --base "$BASE"); rc=$?
check "6: graph 는 0 으로 끝난다" "$rc" "0"
check "6: 동결 문서 + 감사 정상 완료 + 해시 일치면 D1·A1 이 빠진다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "건너뜀" { print $2 }' | tr '\n' ' ')" "D1 A1 "
check "6: 감사 정상 완료 뒤 크래시 행이 와도 완료로 본다" "$(col "$out" 감사)" "뺌"
GPLAN=$(col "$out" 계획)
check "6: design_required 가 false 다" "$(printf '%s' "$GPLAN" | jq -r .design_required)" "false"
check "6: 구현 단계는 빠지지 않는다" "$(printf '%s' "$GPLAN" | jq -r '[.steps[].id] | join(",")')" "I1,R1"
check "6: 남은 단계의 depends_on 에서 지운 id 가 빠진다" "$(printf '%s' "$GPLAN" | jq -c '[.steps[].depends_on]')" '[[],["I1"]]'
check "6: entry_skill 이 남은 첫 단계다" "$(printf '%s' "$GPLAN" | jq -r .entry_skill)" "implement"
check "6: 문서 해시가 지금 문서다" "$(col "$out" 문서해시)" "$DOCSHA"
check "6: 그 빼기는 순수하다" "$(col "$out" 그래프)" "순수"

# Design and audit both removed: the driver still accepts what is drawn.
vg=$(rk verify --prev RKG --base "$BASE")
G_PM=$(printf '%s\n' "$vg" | awk -F'\t' '$1 == "해시" && $2 == "매니페스트" { print $3 }')
G_PG=$(printf '%s\n' "$vg" | awk -F'\t' '$1 == "해시" && $2 == "인가 기록" { print $3 }')
G_KAT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
G_DL=$("$BASH" "$KD" --carry "$BASE/docs/pipeline-run/RKG.plan.md" --kickoff-at "$G_KAT" --expect-sha256 "$G_PM" 2>/dev/null \
  | awk -F'\t' '$1 == "마감" && $2 == "ok" { print $3 }')
NM0="$BASE/docs/pipeline-run/RKN0.plan.md"
rk render-manifest --prev RKG --base "$BASE" --run-id RKN0 --kickoff-at "$G_KAT" --deadline "$G_DL" \
   --expect-sha256 "$G_PM" --expect-grant-sha256 "$G_PG" > "$NM0"
mf_check "$NM0"; rc=$?
if [ "$rc" = "0" ]; then ok "7: 설계와 감사를 지운 매니페스트가 check_manifest 를 통과한다 (R3)"
else bad "7: 설계와 감사를 지운 매니페스트가 check_manifest 를 통과한다 (R3)" "rc=$rc: $(tail -1 "$WORK/check.err")"; fi
check "7: 설계를 지우면 설계 문서 전체 sha256 줄이 지금 문서 해시로 들어간다" \
  "$(awk -F': ' '$1 == "**설계 문서 전체 sha256**" { print $2 }' "$NM0")" "$DOCSHA"

P_KAT='2026-10-01T00:00:00Z' mk_prev RKGH; fx_done
fx_row '문서 해시' "스테이지=A1 이후" "sha256=$OLDBASESHA" "동결값=-" "관측=-"
fx_row 'stage-result' "세그먼트=-" "스테이지=A1" "종류=audit" "종단 부류=정상 완료"
out=$(rk graph --prev RKGH --base "$BASE")
check "6: 해시가 다르면 A1 이 남는다" "$(col "$out" 감사)" "남음"
check "6: 남은 A1 의 depends_on 은 비어 있다" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "남음" && $2 == "A1" { print $4 }')" "-"
check "6: 판정할 수 없어 남긴 것은 바뀜이 아니다" "$(col "$out" 그래프)" "순수"

P_PLAN="$PLANBASE" mk_prev RKGB; fx_done
fx_row '문서 해시' "스테이지=A1 이후" "sha256=$DOCSHA" "동결값=-" "관측=-"
fx_row 'stage-result' "세그먼트=-" "스테이지=A1" "종류=audit" "종단 부류=정상 완료"
out=$(rk graph --prev RKGB --base "$BASE")
check "6: base 그래프는 빼지 않는다" "$(cnt "$out" 건너뜀)/$(col "$out" 범위)" "0/base"

out=$(rk graph --prev RKG --base "$BASE" --accepted extra)
check "6: 받아들인 대상 추가가 있으면 바뀜이다" "$(col "$out" 그래프)" "바뀜"
mk_prev RKGT; fx_done
fx_row '대상 추가' "별칭=extra" "원격 슬러그=t/extra" "메인 워크트리=/x" "공통 git 디렉터리=/x/.git" "베이스 브랜치=main" "층=1" "발견 경로=/x" "기록 시각=-"
out=$(rk graph --prev RKGT --base "$BASE")
check "6: 원장의 대상 추가 행을 낸다" "$(col "$out" 대상추가)/$(col "$out" 대상추가 3)" "extra/t/extra"
out=$(rk graph --prev RKG --base "$BASE" --expect-sha256 "$OLDBASESHA" 2>/dev/null); rc=$?
check "6: 검증한 해시와 다르면 graph 는 1 이고 출력이 없다" "$rc/$out" "1/"

# ---------------------------------------------------------------------------
# 7·8. 쓰기와 완료 기준 — 변화 없는 원천에서 그리고, 검사하고, 기동한다
# ---------------------------------------------------------------------------
# The source keeps its audit step (its hash row does not match), so the new
# run's first step is a dispatch the gate can be asked about.
SRC=RKGH
PM="$BASE/docs/pipeline-run/$SRC.plan.md"; PG="$BASE/docs/pipeline-grant/$SRC.md"
SUM_BEFORE=$(src_sum "$SRC")
detect_case "8 인자 없이" "$SRC" ""
check "8: 같은 세션의 인자 없는 호출이 그 런을 재킥오프로 고르고 원천 base 를 낸다" \
  "$(col "$OUT" 판정)/$(col "$OUT" 판정 3)/$(col "$OUT" 판정 4)" "재킥오프/$SRC/$BASE"
vout=$(rk verify --prev "$SRC" --base "$BASE")
PMSHA=$(printf '%s\n' "$vout" | awk -F'\t' '$1 == "해시" && $2 == "매니페스트" { print $3 }')
PGSHA=$(printf '%s\n' "$vout" | awk -F'\t' '$1 == "해시" && $2 == "인가 기록" { print $3 }')
gout=$(rk graph --prev "$SRC" --base "$BASE" --expect-sha256 "$PMSHA")
KAT1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cout=$("$BASH" "$KD" --carry "$PM" --kickoff-at "$KAT1" --expect-sha256 "$PMSHA" 2>"$WORK/kd.err")
DL1=$(printf '%s\n' "$cout" | awk -F'\t' '$1 == "마감" && $2 == "ok" { print $3 }')
QROWS=$(( $(cnt "$vout" 질문) + $(cnt "$cout" 빈칸) + $(printf '%s\n' "$gout" | awk -F'\t' '$1 == "그래프" && $2 != "순수"' | grep -c . || true) ))
[ -n "$DL1" ] || QROWS=$((QROWS + 1))
check "8: 아무것도 달라지지 않은 원천에서 질문 행이 0이다" "$QROWS" "0"
NEW1=RKN1
NM1="$BASE/docs/pipeline-run/$NEW1.plan.md"
: > "$WORK/asked-empty"
rk render-manifest --prev "$SRC" --base "$BASE" --run-id "$NEW1" --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-empty" > "$NM1"; rc=$?
check "7: render-manifest 는 0 으로 끝난다" "$rc" "0"
[ "$rc" = "0" ] || { tail -3 "$WORK/rk.err"; tail -3 "$WORK/kd.err"; printf '%s\n' "$vout" | grep -v '^해시'; } >&2
mf_check "$NM1"; rc=$?
if [ "$rc" = "0" ]; then ok "7: 설계를 지운 매니페스트가 check_manifest 를 통과한다 (R3)"
else bad "7: 설계를 지운 매니페스트가 check_manifest 를 통과한다 (R3)" "rc=$rc: $(tail -1 "$WORK/check.err")"; fi
td=$(drv "$NM1" canonical_targets | shasum -a 256 | cut -d' ' -f1)
bd=$(drv "$NM1" binding_set_bytes | shasum -a 256 | cut -d' ' -f1)
check "7: 초안의 두 다이제스트가 다시 유도한 값과 같다" \
  "$(grep -c "^\*\*대상 맵 다이제스트\*\*: $td$" "$NM1")/$(grep -c "^\*\*구속 다이제스트\*\*: $bd$" "$NM1")" "1/1"
hasnt "7: 설계를 지우면 로스터 행이 빠진다" "$(cat "$NM1")" '`설계 로스터`'
hasnt "7: 설계를 지우면 인터뷰 행이 빠진다" "$(cat "$NM1")" '인터뷰 기록='
check "7: 설계 문서 전체 sha256 이 지금 문서 해시다" "$(awk -F': ' '$1 == "**설계 문서 전체 sha256**" { print $2 }' "$NM1")" "$DOCSHA"
check "7: 출처 행이 정확히 하나이고 원천과 두 해시를 가리킨다" \
  "$(grep -c '^- `사전 인가` | 이어받은 런=' "$NM1")/$(grep -cF -- "- \`사전 인가\` | 이어받은 런=$SRC | 매니페스트 sha256=$PMSHA | 인가 기록 sha256=$PGSHA" "$NM1")" "1/1"
check "7: 머리와 본문이 새 run id 를 싣는다" \
  "$(drv "$NM1" manifest_header | sed -n 's/.*run-id=\([^;]*\);.*/\1/p')/$(awk -F': ' '$1 == "**런 id**" { print $2 }' "$NM1")" "$NEW1/$NEW1"
check "7: 사용자 확인 문면은 이번 호출의 말이다" "$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$NM1")" "/cc-cmds:autopilot"
SCOPE_A1=$(cd "$WT" && CC_GATE_SOURCE_ONLY=1 bash -c 'g=$1; m=$2; set --; . "$g" >/dev/null 2>&1 || exit 9; set +e; MANIFEST=$m; gate_run_scope_step audit' _ "$GATE_SH" "$NM1" 2>/dev/null)
check "7: 지운 매니페스트에서 gate_run_scope_step audit 이 A1 을 낸다" "$SCOPE_A1" "A1"

# The interval, measured on the frozen values. The offset is taken off by hand:
# `%z` with `mktime` drops it on glibc and keeps it on macOS.
iv() { jq -rn --arg d "$1" --arg k "$2" '
  def e(s): s | capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")
    | ((.t + "Z") | fromdateiso8601)
      - (if .z == "Z" then 0 else (.z | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")
          | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "-" then -1 else 1 end)) end);
  e($d) - e($k)'; }
IV0=$(iv "$DL0" "$KAT0")
# 2026-10-01T00:00:00Z to 2030-01-01T00:00:00Z is 1188 days; an empty IV0 would
# make both comparisons below pass on nothing.
check "8: 이전 간격을 시각으로 읽었다" "$IV0" "102643200"
check "8: 새 마감 − 새 킥오프 일시 = 이전 간격이다" \
  "$(iv "$(awk -F': ' '$1 == "**벽시계 마감**" { print $2 }' "$NM1")" "$(awk -F': ' '$1 == "**킥오프 일시**" { print $2 }' "$NM1")")" "$IV0"

# The new authorization block, as Step 6 makes it from the draft.
D_CONFIRM=$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$NM1")
grant_block "$NEW1" 머지 '픽스처가 끝나면' "$D_CONFIRM" "$DOCSHA" > "$WORK/g1.block"
out=$(rk verify-subset "$NM1" "$PM" --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-empty" --grant "$WORK/g1.block"); rc=$?
check "7: verify-subset 이 통과한다 (새 인가 블록 포함)" "$rc/$(col "$out" 판정)/$(col "$out" 판정 3)" "0/통과/"
check "7: 새 인가의 권한 절단점이 새 매니페스트의 런 최대 절단점과 같다" \
  "$(awk -F': ' '$1 == "**권한 절단점**" { print $2 }' "$WORK/g1.block")" "$(awk -F': ' '$1 == "**런 최대 절단점**" { print $2 }' "$NM1")"
check "8: 흐름 전후 원천 파일들의 sha256 이 같다" "$(src_sum "$SRC")" "$SUM_BEFORE"

# The real dispatch: plan, act and wait for the audit step of the new run.
write_grant "$NEW1" "$DOC" "$WORK/g1.block"
GSTATE="$WORK/gstate"; mkdir -p "$GSTATE"
AUDIT_P="/cc-cmds:design-audit-unattended $WT/$DOC"
( cd "$WT" && XDG_STATE_HOME="$GSTATE" bash "$GATE_SH" plan --manifest "$NM1" --kind skill --target rk --segment - \
    --cutpoint 커밋 --surface 워크트리쓰기 -- audit -p "$AUDIT_P" ) >"$WORK/plan.out" 2>&1; rc=$?
check "7: 새 런의 감사 파견 plan 이 통과한다 (R3)" "$rc" "0"
[ "$rc" = "0" ] || printf '%s\n' "$(grep -v '\[run\] ' "$WORK/plan.out" | tail -3)" >&2
H1=$(cd "$WT" && XDG_STATE_HOME="$GSTATE" bash "$GATE_SH" snapshot --manifest "$NM1" 2>/dev/null | jq -r .H)
( cd "$WT" && XDG_STATE_HOME="$GSTATE" CC_CLAUDE_BIN="$WORK/bin/claude-audit" bash "$GATE_SH" act --manifest "$NM1" \
    --kind skill --target rk --segment - --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest "$H1" \
    --rationale x -- audit -p "$AUDIT_P" ) >"$WORK/act.out" 2>&1; rc=$?
check "7: 새 런의 감사 act --kind skill 이 허락된다 (R3)" "$rc" "0"
[ "$rc" = "0" ] || printf '%s\n' "$(grep -v '\[run\] ' "$WORK/act.out" | tail -3)" >&2
( cd "$WT" && XDG_STATE_HOME="$GSTATE" bash "$GATE_SH" wait --manifest "$NM1" --segment A1 --interval 1 --timeout 60 ) >/dev/null 2>&1
check "7: 감사 단계의 stage-result 행이 스테이지=A1 · 종류=audit 이다" \
  "$(grep -F '`stage-result`' "$BASE/docs/pipeline-run/$NEW1.md" 2>/dev/null | grep -cF '| 스테이지=A1 | 종류=audit |')" "1"
( cd "$WT" && git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r w; do
    [ "$w" = "$WT" ] || git worktree remove --force "$w" >/dev/null 2>&1
  done; git worktree prune >/dev/null 2>&1 )

# Chained: the new run is itself the source of the next one.
write_grant "$NEW1" "$DOC" "$WORK/g1.block"
PM1SHA=$(sha "$NM1"); PG1SHA=$(sha "$BASE/docs/pipeline-grant/$NEW1.md")
KAT2=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
cout2=$("$BASH" "$KD" --carry "$NM1" --kickoff-at "$KAT2" --expect-sha256 "$PM1SHA" 2>/dev/null)
DL2=$(printf '%s\n' "$cout2" | awk -F'\t' '$1 == "마감" && $2 == "ok" { print $3 }')
NM2="$BASE/docs/pipeline-run/RKN2.plan.md"
rk render-manifest --prev "$NEW1" --base "$BASE" --run-id RKN2 --kickoff-at "$KAT2" --deadline "$DL2" \
   --expect-sha256 "$PM1SHA" --expect-grant-sha256 "$PG1SHA" > "$NM2"
check "8: 두 번 연쇄해도 간격이 같다" \
  "$(iv "$(awk -F': ' '$1 == "**벽시계 마감**" { print $2 }' "$NM2")" "$(awk -F': ' '$1 == "**킥오프 일시**" { print $2 }' "$NM2")")" "$IV0"
check "7: 두 번 연쇄에서도 출처 행은 하나이고 직접 원천을 가리킨다" \
  "$(grep -c '^- `사전 인가` | 이어받은 런=' "$NM2")/$(grep -c "^- \`사전 인가\` | 이어받은 런=$NEW1 |" "$NM2")" "1/1"
mf_check "$NM2"; rc=$?
check "7: 연쇄 초안도 check_manifest 를 통과한다" "$rc" "0"
out=$(rk verify-subset "$NM2" "$NM1" --expect-sha256 "$PM1SHA" --expect-grant-sha256 "$PG1SHA" --asked "$WORK/asked-empty"); rc=$?
check "7: 연쇄 초안도 verify-subset 을 통과한다" "$rc" "0"

# ---------------------------------------------------------------------------
# 9. 대조기 — 출처 행만 가진 매니페스트는 아무것도 인가하지 않는다
# ---------------------------------------------------------------------------
grep -v -e '^- `사전 인가` | 형태=' "$NM1" > "$WORK/prov-only.md"
check "9: 탐침 픽스처에 사전 인가 행은 출처 행 하나뿐이다" "$(grep -c '^- `사전 인가`' "$WORK/prov-only.md")" "1"
for argv in "git push origin main" "이어받은 런=$SRC""매니페스트 sha256=$PMSHA" "rm -rf /"; do
  p=$(GATE_PREAUTH_PROBE=1 GATE_MANIFEST="$WORK/prov-only.md" GATE_ARGV="$argv" GATE_SURFACE=외부상태변경 \
      sh "$ORCH/rules/사전-인가-대조.sh" 2>/dev/null)
  case "$p" in "P=0 "*) ok "9: 출처 행은 '$argv' 를 인가하지 않는다" ;; *) bad "9: 출처 행은 '$argv' 를 인가하지 않는다" "$p" ;; esac
done

# ---------------------------------------------------------------------------
# 7. verify-subset — 넓히지 않음 검사의 통과와 실패
# ---------------------------------------------------------------------------
# vs <label> <want 통과|실패> <draft> <asked> [want check name] [--grant file]
vs() {
  local label="$1" want="$2" d="$3" a="$4" name="${5:-}" o r
  shift 5 2>/dev/null || shift $#
  o=$(rk verify-subset "$d" "$VS_PREV" --expect-sha256 "$VS_PMSHA" --expect-grant-sha256 "$VS_PGSHA" --asked "$a" "$@"); r=$?
  check "7: $label" "$(col "$o" 판정)" "$want"
  [ "$(col "$o" 판정)" = "$want" ] || printf '%s\n' "$o" | grep -E '^(판정|불일치)' >&2
  if [ -n "$name" ]; then has "7: $label — 실패한 검사는 $name 이다" "$(col "$o" 판정 3)" "$name"; fi
}
VS_PREV="$PM"; VS_PMSHA="$PMSHA"; VS_PGSHA="$PGSHA"
E="$WORK/asked-empty"
mod() {  # mod <out> <sed expr> — a draft variant of NM1
  sed "$2" "$NM1" > "$1"
}
mod "$WORK/v-dr.md" 's/"design_required": false/"design_required": true/'
vs "design_required=true 를 남긴 초안은 실패한다" 실패 "$WORK/v-dr.md" "$E" 설계
{ cat "$NM1"; printf -- '- `사전 인가` | 형태=gh pr | 사유=더한 행\n'; } > "$WORK/v-pa.md"
vs "원천에 없는 사전 인가 행을 5p 답 없이 더한 초안은 실패한다" 실패 "$WORK/v-pa.md" "$E" 행
printf '5p\t형태=gh pr | 사유=더한 행\n' > "$WORK/asked-5p"
vs "대상 추가 확인 없이 5p 가 있으면 실패한다" 실패 "$WORK/v-pa.md" "$WORK/asked-5p" 대상추가
vs "사용자 확인 문면에 없는 5p 답은 실패한다" 실패 "$WORK/v-pa.md" "$WORK/asked-5p" 확인문면
mod "$WORK/v-cut.md" 's/| 절단점=머지 |/| 절단점=배포 |/'
vs "덮는 답 없이 권한 필드가 바뀐 대상 행은 실패한다" 실패 "$WORK/v-cut.md" "$E" 대상
mod "$WORK/v-cl.md" 's/| 문면=픽스처 절$/| 문면=바뀐 절/'
vs "종료 절 행이 바뀐 초안은 실패한다" 실패 "$WORK/v-cl.md" "$E" 고정값
mod "$WORK/v-ap.md" 's/^\*\*적용 주체\*\*: (해당 없음)$/**적용 주체**: 사람/'
vs "적용 주체가 바뀐 초안은 실패한다" 실패 "$WORK/v-ap.md" "$E" 고정값
mod "$WORK/v-dep.md" 's/"depends_on": \[\]/"depends_on": ["D1"]/'
vs "지운 id 를 가리키는 depends_on 은 실패한다" 실패 "$WORK/v-dep.md" "$E" 의존
{ cat "$NM1"; printf -- '- `사전 인가` | 이어받은 런=%s | 매니페스트 sha256=%s | 인가 기록 sha256=%s\n' "$SRC" "$PMSHA" "$PGSHA"; } > "$WORK/v-prov2.md"
vs "출처 행이 둘인 초안은 실패한다" 실패 "$WORK/v-prov2.md" "$E" 출처
mod "$WORK/v-provx.md" "s/| 이어받은 런=$SRC |/| 이어받은 런=RKX |/"
vs "이어받은 런= 이 --prev 와 다른 초안은 실패한다" 실패 "$WORK/v-provx.md" "$E" 출처
mod "$WORK/v-dl.md" "s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2031-01-01T00:00:00+09:00/"
vs "마감 간격이 바뀐 초안은 실패한다" 실패 "$WORK/v-dl.md" "$E" 마감
# 5e answered in a relative form: the draft carries the instant it resolved to.
printf '5e\t다음 날 아침 9시\n5e 값\t2031-01-01T00:00:00+09:00\n' > "$WORK/asked-5e"
mod "$WORK/v-dl5e.md" "s|^\*\*사용자 확인 문면\*\*: .*|**사용자 확인 문면**: /cc-cmds:autopilot / 다음 날 아침 9시 / 2031-01-01T00:00:00+09:00|;s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2031-01-01T00:00:00+09:00/"
vs "5e 를 상대 표기로 답했으면 마감은 그 답을 해석한 시각이면 된다" 통과 "$WORK/v-dl5e.md" "$WORK/asked-5e"
mod "$WORK/v-dl5ez.md" "s|^\*\*사용자 확인 문면\*\*: .*|**사용자 확인 문면**: /cc-cmds:autopilot / 다음 날 아침 9시 / 2031-01-01T00:00:00+09:00|;s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2030-12-31T15:00:00Z/"
vs "같은 시각을 다른 표기로 쓴 마감도 통과한다" 통과 "$WORK/v-dl5ez.md" "$WORK/asked-5e"
mod "$WORK/v-dl5ex.md" "s|^\*\*사용자 확인 문면\*\*: .*|**사용자 확인 문면**: /cc-cmds:autopilot / 다음 날 아침 9시 / 2031-01-01T00:00:00+09:00|;s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2031-01-01T01:00:00+09:00/"
vs "해석한 시각과 다른 마감은 실패한다" 실패 "$WORK/v-dl5ex.md" "$WORK/asked-5e" 마감
printf '5e\t다음 날 아침 9시\n' > "$WORK/asked-5e-only"
mod "$WORK/v-dl5eo.md" "s|^\*\*사용자 확인 문면\*\*: .*|**사용자 확인 문면**: /cc-cmds:autopilot / 다음 날 아침 9시|;s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2031-01-01T00:00:00+09:00/"
vs "5e 답만 있고 해석한 시각(5e 값)이 없으면 실패한다" 실패 "$WORK/v-dl5eo.md" "$WORK/asked-5e-only" 마감
printf '5e\t다음 날 아침 9시\n5e 값\t2031-01-02T00:00:00+09:00\n5e\t+8h\n5e 값\t2031-01-01T00:00:00+09:00\n' > "$WORK/asked-5e2"
mod "$WORK/v-dl5e2.md" "s|^\*\*사용자 확인 문면\*\*: .*|**사용자 확인 문면**: /cc-cmds:autopilot / 다음 날 아침 9시 / 2031-01-02T00:00:00+09:00 / +8h / 2031-01-01T00:00:00+09:00|;s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: 2031-01-01T00:00:00+09:00/"
vs "마감 재확인으로 5e 를 다시 물으면 마지막 답의 시각이 마감이다" 통과 "$WORK/v-dl5e2.md" "$WORK/asked-5e2"

# 5o confirmed blanks: the values reach the draft and are compared, not exempted.
printf '5o 런:cost-ceiling\t이대로\n5o rk:deploy-triggers\t이대로\n' > "$WORK/asked-5o"
# blanks <out> <scope<TAB>key<TAB>value>… — a saved 5o output holding `빈칸` rows.
blanks() {
  local out="$1"; shift
  { printf 'cc-kickoff-defaults v1\n'
    for r in "$@"; do printf '빈칸\t%s\t기본값 파일\t0\t효과\n' "$r"; done; } > "$out"
}
# The target is labelled by its remote slug, as the 5o output labels it.
blanks "$WORK/blanks-5o" "런${TAB}cost-ceiling${TAB}12" "t/rk${TAB}deploy-triggers${TAB}branch:release"
B5=(--blank-rows "$WORK/blanks-5o")
# vsr <draft> <asked> <args…> — the reason the 확정값 check gives, or 통과.
vsr() {
  local d="$1" a="$2"; shift 2
  rk verify-subset "$d" "$VS_PREV" --expect-sha256 "$VS_PMSHA" --expect-grant-sha256 "$VS_PGSHA" --asked "$a" "$@" \
    | awk -F '\t' '$1 == "검사" && $2 == "확정값" { print ($3 == "통과") ? "통과" : $4 }'
}
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-5o" \
   --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' > "$WORK/v-5o.md"; rc=$?
check "7: --set 을 준 render-manifest 는 0 으로 끝난다" "$rc" "0"
check "7: --set 이 원천에 없던 비용 천장 줄을 확정값으로 쓴다" "$(grep -c '^\*\*비용 천장\*\*: 12$' "$WORK/v-5o.md")" "1"
check "7: --set 이 원천 대상 행에 없던 배포트리거 식별자를 확정값으로 쓴다" \
  "$(grep -E '^- `target`' "$WORK/v-5o.md" | grep -c '| 배포트리거 식별자=branch:release$')" "1"
has "7: 사용자 확인 문면이 확정값을 적는다" "$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$WORK/v-5o.md")" " / 런:cost-ceiling=12 / rk:deploy-triggers=branch:release"
mf_check "$WORK/v-5o.md"; rc=$?
check "7: 확정값을 실은 초안이 check_manifest 를 통과한다" "$rc" "0"
vs "5o 확정값을 실은 초안은 같은 --set 으로 통과한다 (원격 슬러그 빈칸 행·별칭 --set)" 통과 "$WORK/v-5o.md" "$WORK/asked-5o" "" \
  --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' "${B5[@]}"
vs "--set 없이는 5o 답만으로 빈칸 차이가 면제되지 않는다" 실패 "$WORK/v-5o.md" "$WORK/asked-5o" 고정값
sed 's/^\*\*비용 천장\*\*: 12$/**비용 천장**: 99/' "$WORK/v-5o.md" > "$WORK/v-5ox.md"
vs "확정값과 다른 값을 실은 초안은 실패한다" 실패 "$WORK/v-5ox.md" "$WORK/asked-5o" 확정값 \
  --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' "${B5[@]}"
vs "5o 에서 묻지 않은 --set 은 실패한다" 실패 "$WORK/v-5o.md" "$E" 확정값 \
  --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' "${B5[@]}"
printf '5o cost-ceiling\t이대로\n5o deploy-triggers\t이대로\n' > "$WORK/asked-5o-bare"
vs "범위 없이 키만 적은 5o 줄은 --set 을 덮지 않는다" 실패 "$WORK/v-5o.md" "$WORK/asked-5o-bare" 확정값 \
  --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' "${B5[@]}"
# (i) The confirmation line lost one confirmed value.
sed 's|^\(\*\*사용자 확인 문면\*\*: .*\) / 런:cost-ceiling=12|\1|' "$WORK/v-5o.md" > "$WORK/v-5onc.md"
check "7: 확인 문면에서 런:cost-ceiling=12 를 지운 초안을 만들었다" "$(grep -c ' / 런:cost-ceiling=12' "$WORK/v-5onc.md")" "0"
has "7: 확인 문면에서 확정값 하나가 빠진 초안은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-5onc.md" "$WORK/asked-5o" --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' "${B5[@]}")" \
  "런:cost-ceiling 의 확정값이 사용자 확인 문면에 없습니다"
# (ii) A confirmed 10 is not a confirmed 100, in the row and in the line.
blanks "$WORK/blanks-10" "런${TAB}cost-ceiling${TAB}10"
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-5o" \
   --set '런:cost-ceiling=100' > "$WORK/v-100.md"
has "7: 빈칸 값 10 에 --set 과 초안 값 100 은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-100.md" "$WORK/asked-5o" --set '런:cost-ceiling=100' --blank-rows "$WORK/blanks-10")" \
  "런:cost-ceiling 의 확정값이 5o 에서 확인한 빈칸 행과 다릅니다"
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-5o" \
   --set '런:cost-ceiling=10' > "$WORK/v-10.md"
check "7: 빈칸 값 10 을 그대로 실은 초안은 확정값 검사를 통과한다" \
  "$(vsr "$WORK/v-10.md" "$WORK/asked-5o" --set '런:cost-ceiling=10' --blank-rows "$WORK/blanks-10")" "통과"
sed 's|^\(\*\*사용자 확인 문면\*\*: .*\) / 런:cost-ceiling=10$|\1 / 런:cost-ceiling=100|' "$WORK/v-10.md" > "$WORK/v-10c.md"
check "7: 확인 문면에 =100 만 있는 초안을 만들었다" "$(grep -c ' / 런:cost-ceiling=100$' "$WORK/v-10c.md")/$(grep -c ' / 런:cost-ceiling=10$' "$WORK/v-10c.md")" "1/0"
has "7: 확인 문면의 =100 은 확정값 =10 을 덮지 않는다" \
  "$(vsr "$WORK/v-10c.md" "$WORK/asked-5o" --set '런:cost-ceiling=10' --blank-rows "$WORK/blanks-10")" \
  "런:cost-ceiling 의 확정값이 사용자 확인 문면에 없습니다"
# (iii) A --set that differs from the row, with the draft built from it.
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-5o" \
   --set '런:cost-ceiling=13' --set 'rk:deploy-triggers=branch:release' > "$WORK/v-13.md"
has "7: 빈칸 행과 다른 값의 --set 은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-13.md" "$WORK/asked-5o" --set '런:cost-ceiling=13' --set 'rk:deploy-triggers=branch:release' "${B5[@]}")" \
  "런:cost-ceiling 의 확정값이 5o 에서 확인한 빈칸 행과 다릅니다"
# (v) No saved rows, or a file that is not a 5o output.
has "7: --set 이 있는데 --blank-rows 가 없으면 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-5o.md" "$WORK/asked-5o" --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release')" \
  "--blank-rows"
{ printf 'cc-rekick v1\n'; tail -n +2 "$WORK/blanks-5o"; } > "$WORK/blanks-badhdr"
has "7: 머리가 다른 빈칸 행 파일은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-5o.md" "$WORK/asked-5o" --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' --blank-rows "$WORK/blanks-badhdr")" \
  "머리가"
has "7: 읽을 수 없는 빈칸 행 파일은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-5o.md" "$WORK/asked-5o" --set '런:cost-ceiling=12' --set 'rk:deploy-triggers=branch:release' --blank-rows "$WORK/no-such-blanks")" \
  "읽을 수 없습니다"
# (iv) Two targets: the row and its 5o line are for rk, the value is moved to rk2.
awk '{ print } /^- `target` [|] 별칭=rk [|]/ { r = $0; sub(/별칭=rk [|]/, "별칭=rk2 |", r); sub(/원격 슬러그=t\/rk [|]/, "원격 슬러그=t/rk2 |", r); print r }' \
  "$PM" > "$WORK/pm-two.md"
RK2ROW=$(grep -E '^- `target` \| 별칭=rk2 \|' "$WORK/pm-two.md")
check "7: 대상 둘인 원천을 만들었다" "$(grep -cE '^- `target` \| 별칭=rk2? \|' "$WORK/pm-two.md")" "2"
awk -v r2="$RK2ROW | 배포트리거 식별자=branch:release" '
  /^\*\*사용자 확인 문면\*\*: / { sub(/ \/ rk:deploy-triggers=/, " / rk2:deploy-triggers=") }
  /^- `target` [|] 별칭=rk [|]/ { sub(/ [|] 배포트리거 식별자=branch:release$/, ""); print; print r2; next }
  { print }' "$WORK/v-5o.md" > "$WORK/v-two.md"
printf '5o 런:cost-ceiling\t이대로\n5o rk2:deploy-triggers\t이대로\n' > "$WORK/asked-two"
VS_PREV="$WORK/pm-two.md"; VS_PMSHA=$(sha "$WORK/pm-two.md")
has "7: 한 대상의 빈칸 행을 다른 대상 범위로 옮긴 --set 은 확정값 검사에 실패한다" \
  "$(vsr "$WORK/v-two.md" "$WORK/asked-two" --set '런:cost-ceiling=12' --set 'rk2:deploy-triggers=branch:release' "${B5[@]}")" \
  "rk2:deploy-triggers 의 확정값이 5o 에서 확인한 빈칸 행과 다릅니다"
blanks "$WORK/blanks-two" "런${TAB}cost-ceiling${TAB}12" "t/rk2${TAB}deploy-triggers${TAB}branch:release"
check "7: 같은 초안이 그 대상의 빈칸 행으로는 확정값 검사를 통과한다" \
  "$(vsr "$WORK/v-two.md" "$WORK/asked-two" --set '런:cost-ceiling=12' --set 'rk2:deploy-triggers=branch:release' --blank-rows "$WORK/blanks-two")" "통과"
VS_PREV="$PM"; VS_PMSHA="$PMSHA"
# The blanks as `--carry` prints them: a target is labelled by its remote slug,
# and the row goes to --set verbatim.
printf 'cost-ceiling = 12\n[t/rk]\ndeploy-triggers = branch:release\n' > "$WORK/defaults-5o"
cout5=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$WORK/defaults-5o" "$BASH" "$KD" --carry "$PM" --kickoff-at "$KAT1" \
          --expect-sha256 "$PMSHA" 2>>"$WORK/kd.err")
SETS5=$(printf '%s\n' "$cout5" | awk -F'\t' '$1 == "빈칸" { print $2 ":" $3 "=" $4 }' | sort)
check "7: --carry 가 원천의 빈칸을 기본값 파일 값으로 낸다" "$SETS5" \
  "$(printf '%s\n' 't/rk:deploy-triggers=branch:release' '런:cost-ceiling=12' | sort)"
S5=()
while IFS= read -r e; do [ -z "$e" ] || S5+=(--set "$e"); done <<EOF
$SETS5
EOF
printf '%s\n' "$cout5" > "$WORK/blanks-5c"
printf '5o 런:cost-ceiling\t이대로\n5o t/rk:deploy-triggers\t이대로\n' > "$WORK/asked-5c"
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-5c" "${S5[@]}" > "$WORK/v-5c.md"; rc=$?
check "7: --carry 빈칸 행을 그대로 옮긴 --set 으로 render-manifest 가 0 으로 끝난다" "$rc" "0"
check "7: 원격 슬러그로 적힌 --set 이 그 슬러그를 선언한 대상 행에 확정값을 쓴다" \
  "$(grep -E '^- `target`' "$WORK/v-5c.md" | grep -c '| 배포트리거 식별자=branch:release$')" "1"
mf_check "$WORK/v-5c.md"; rc=$?
check "7: 원격 슬러그 --set 으로 만든 초안이 check_manifest 를 통과한다" "$rc" "0"
vs "--carry 빈칸 행을 그대로 옮긴 --set 으로 만든 초안은 같은 --set 과 저장한 출력으로 통과한다" 통과 "$WORK/v-5c.md" "$WORK/asked-5c" "" \
  "${S5[@]}" --blank-rows "$WORK/blanks-5c"
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" \
        --set 'rk:deploy-triggers=branch:release' --set 't/rk:deploy-triggers=branch:release' 2>/dev/null); rc=$?
check "7: 같은 대상을 별칭과 원격 슬러그로 두 번 준 --set 은 render-manifest 가 1 로 거절한다" "$rc/$out" "1/"
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --set 't/zz:dev-ids=host:a' 2>/dev/null); rc=$?
check "7: 어느 대상도 선언하지 않은 원격 슬러그의 --set 은 render-manifest 가 1 로 거절한다" "$rc/$out" "1/"
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --set '런:ladder-rungs=2' 2>/dev/null); rc=$?
check "7: 원천에 값이 있는 키의 --set 은 render-manifest 가 1 로 거절한다" "$rc/$out" "1/"
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --set 'zz:dev-ids=host:a' 2>/dev/null); rc=$?
check "7: 원천에 없는 대상의 --set 은 render-manifest 가 1 로 거절한다" "$rc/$out" "1/"
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN9 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --set 'cost-ceiling=12' 2>/dev/null); rc=$?
check "7: 범위 없는 --set 은 사용법 오류다" "$rc/$out" "2/"
grant_block "$NEW1" 배포 '픽스처가 끝나면' "$D_CONFIRM" "$DOCSHA" > "$WORK/g-up.block"
vs "권한 절단점을 한 단 올린 인가 블록은 실패한다" 실패 "$NM1" "$E" 인가블록 --grant "$WORK/g-up.block"
grant_block "$NEW1" 머지 '다른 종료 지점' "$D_CONFIRM" "$DOCSHA" > "$WORK/g-goal.block"
vs "종료 지점이 초안과 다른 인가 블록은 실패한다" 실패 "$NM1" "$E" 인가블록 --grant "$WORK/g-goal.block"
grant_block "$NEW1" 머지 '픽스처가 끝나면' '다른 확인' "$DOCSHA" > "$WORK/g-conf.block"
vs "사용자 확인 문면이 초안과 다른 인가 블록은 실패한다" 실패 "$NM1" "$E" 인가블록 --grant "$WORK/g-conf.block"
grant_block RKG 머지 '픽스처가 끝나면' "$D_CONFIRM" "$DOCSHA" > "$WORK/g-id.block"
vs "id 가 새 run id 가 아닌 인가 블록은 실패한다" 실패 "$NM1" "$E" 인가블록 --grant "$WORK/g-id.block"

# The source changed last: the provenance hashes no longer hold.
cp "$PG" "$WORK/pg.save"; printf '\n' >> "$PG"
vs "원천 인가 기록을 마지막에 바꾸면 실패한다" 실패 "$NM1" "$E" 원천해시
cp "$WORK/pg.save" "$PG"
cp "$PM" "$WORK/pm.save"; printf '\n' >> "$PM"
vs "원천 매니페스트를 바꾸면 실패한다" 실패 "$NM1" "$E" 원천해시
cp "$WORK/pm.save" "$PM"

# Passing variants from a source that needs an answer.
# (a) A target re-confirmed at Step 2 whose identity fields changed.
sed 's/| 원격 슬러그=t\/rk |/| 원격 슬러그=t\/rk-moved |/' "$PM" | grep -E '^- `target`' > "$WORK/targets-moved"
printf '대상확인 rk\t원격 슬러그는 t/rk-moved 다\n' > "$WORK/asked-tc"
rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN3 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMSHA" --expect-grant-sha256 "$PGSHA" --asked "$WORK/asked-tc" --targets "$WORK/targets-moved" > "$WORK/v-tc.md"
vs "다시 확인해 신원 필드만 바뀐 대상 행은 통과한다" 통과 "$WORK/v-tc.md" "$WORK/asked-tc"
vs "다시 확인하지 않은 대상의 신원 필드가 바뀌면 실패한다" 실패 "$WORK/v-tc.md" "$E" 대상

# (b) A cutpoint out of today's vocabulary, fixed by a 7.7 answer.
P_CUT=병합 P_GCUT=병합 mk_prev RKCUT; fx_done
PMC=$(sha "$BASE/docs/pipeline-run/RKCUT.plan.md"); PGC=$(sha "$BASE/docs/pipeline-grant/RKCUT.md")
sed 's/| 절단점=병합 |/| 절단점=머지 |/' "$BASE/docs/pipeline-run/RKCUT.plan.md" | grep -E '^- `target`' > "$WORK/targets-cut"
printf '7.7 절단점 rk\t머지\n' > "$WORK/asked-cut"
rk render-manifest --prev RKCUT --base "$BASE" --run-id RKN4 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMC" --expect-grant-sha256 "$PGC" --asked "$WORK/asked-cut" --targets "$WORK/targets-cut" > "$WORK/v-cut2.md"
VS_PREV="$BASE/docs/pipeline-run/RKCUT.plan.md"; VS_PMSHA="$PMC"; VS_PGSHA="$PGC"
vs "어휘 밖 절단점을 7.7 답으로 고친 초안은 통과한다" 통과 "$WORK/v-cut2.md" "$WORK/asked-cut"
check "7: 그 초안의 런 최대 절단점은 새 대상 절단점이다" "$(awk -F': ' '$1 == "**런 최대 절단점**" { print $2 }' "$WORK/v-cut2.md")" "머지"
vs "7.7 답 없이 절단점이 바뀌면 실패한다" 실패 "$WORK/v-cut2.md" "$E" 대상

# (c) A rule key changed by a 7.7 answer.
P_RULES='**사전-인가-대조**: 켬' mk_prev RKRULE; fx_done
PMR=$(sha "$BASE/docs/pipeline-run/RKRULE.plan.md"); PGR=$(sha "$BASE/docs/pipeline-grant/RKRULE.md")
printf '7.7 룰 사전-인가-대조\t끔\n' > "$WORK/asked-rule"
rk render-manifest --prev RKRULE --base "$BASE" --run-id RKN5 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMR" --expect-grant-sha256 "$PGR" --asked "$WORK/asked-rule" --rule 사전-인가-대조=끔 > "$WORK/v-rule.md"
VS_PREV="$BASE/docs/pipeline-run/RKRULE.plan.md"; VS_PMSHA="$PMR"; VS_PGSHA="$PGR"
check "7: --rule 이 룰 설정 줄을 그 답으로 쓴다" "$(grep -c '^\*\*사전-인가-대조\*\*: 끔$' "$WORK/v-rule.md")" "1"
vs "룰 설정 키를 7.7 답으로 고친 초안은 통과한다" 통과 "$WORK/v-rule.md" "$WORK/asked-rule"
vs "덮는 답 없이 룰 설정 줄이 바뀐 초안은 실패한다" 실패 "$WORK/v-rule.md" "$E" 고정값

# (d) The base binding, re-bound by a 7.8 answer.
NOWBASE=$(sha "$BASE/docs/rk-base.md")
PMB=$(sha "$BASE/docs/pipeline-run/RKVB.plan.md"); PGB=$(sha "$BASE/docs/pipeline-grant/RKVB.md")
printf '7.8\t묶는다\n' > "$WORK/asked-bind"
rk render-manifest --prev RKVB --base "$BASE" --run-id RKN6 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMB" --expect-grant-sha256 "$PGB" --asked "$WORK/asked-bind" --bind-base "$NOWBASE" > "$WORK/v-bind.md"
VS_PREV="$BASE/docs/pipeline-run/RKVB.plan.md"; VS_PMSHA="$PMB"; VS_PGSHA="$PGB"
vs "묶는다 답으로 베이스 설계 행을 지금 해시로 쓴 초안은 통과한다" 통과 "$WORK/v-bind.md" "$WORK/asked-bind"
vs "7.8 답 없이 베이스 설계 해시가 바뀌면 실패한다" 실패 "$WORK/v-bind.md" "$E" 베이스설계
sed "s/sha256=$NOWBASE | 티켓=T1/sha256=$(printf 'other' | shasum -a 256 | cut -d' ' -f1) | 티켓=T1/" "$WORK/v-bind.md" > "$WORK/v-bindx.md"
vs "답이 있어도 지금 해시와 다른 값이면 실패한다" 실패 "$WORK/v-bindx.md" "$WORK/asked-bind" 베이스설계

# (e) A source whose design step stays: the interview row is renamed only.
P_DOC="$DOC_OPEN" mk_prev RKIV; fx_done
PMI=$(sha "$BASE/docs/pipeline-run/RKIV.plan.md"); PGI=$(sha "$BASE/docs/pipeline-grant/RKIV.md")
gi=$(rk graph --prev RKIV --base "$BASE")
check "6: 미동결 문서면 설계 단계가 남는다" "$(col "$gi" 설계)" "남음"
rk render-manifest --prev RKIV --base "$BASE" --run-id RKN7 --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMI" --expect-grant-sha256 "$PGI" > "$WORK/v-iv.md"
VS_PREV="$BASE/docs/pipeline-run/RKIV.plan.md"; VS_PMSHA="$PMI"; VS_PGSHA="$PGI"
check "7: 설계가 남으면 인터뷰 행의 경로만 새 run id 로 바뀐다" \
  "$(grep -c "^- \`사전 인가\` | 인터뷰 기록=docs/pipeline-run/RKN7.interview.md | sha256=$(sha "$BASE/docs/pipeline-run/RKIV.interview.md")$" "$WORK/v-iv.md")" "1"
check "7: 설계가 남으면 로스터 행이 남는다" "$(grep -c '^- `설계 로스터`' "$WORK/v-iv.md")" "1"
vs "인터뷰 행의 경로만 바뀐 초안은 통과한다" 통과 "$WORK/v-iv.md" "$E"
sed 's/\(인터뷰 기록=[^|]*| sha256=\)[0-9a-f]*/\1'"$OLDBASESHA"'/' "$WORK/v-iv.md" > "$WORK/v-iv-sha.md"
vs "인터뷰 행의 sha256 이 다르면 실패한다" 실패 "$WORK/v-iv-sha.md" "$E" 인터뷰
sed 's/인터뷰 기록=docs\/pipeline-run\/RKN7\.interview\.md/인터뷰 기록=docs\/pipeline-run\/RKZZ.interview.md/' "$WORK/v-iv.md" > "$WORK/v-iv-id.md"
vs "인터뷰 행의 경로가 새 run id 가 아니면 실패한다" 실패 "$WORK/v-iv-id.md" "$E" 인터뷰
{ cat "$WORK/v-iv.md"; grep '^- `사전 인가` | 인터뷰 기록=' "$WORK/v-iv.md"; } > "$WORK/v-iv-2.md"
vs "인터뷰 행이 둘이면 실패한다" 실패 "$WORK/v-iv-2.md" "$E" 인터뷰
VS_PREV="$PM"; VS_PMSHA="$PMSHA"; VS_PGSHA="$PGSHA"
{ cat "$NM1"; printf -- '- `사전 인가` | 인터뷰 기록=docs/pipeline-run/%s.interview.md | sha256=%s\n' "$NEW1" "$OLDBASESHA"; } > "$WORK/v-iv-left.md"
vs "설계가 빠졌는데 인터뷰 행이 남으면 실패한다" 실패 "$WORK/v-iv-left.md" "$E" 인터뷰

# (f) The apply probe code row is carried byte for byte, and the source run's
# pinned plugin copy and its pin record are left alone by the whole flow.
AC_ROW="- \`적용 프로브 코드\` | 불필요=0 | 필요=21 | 프로브 sha256=$(printf '%s' 'make probe' | shasum -a 256 | cut -d' ' -f1)"
P_PROBE='`make probe`' P_EXTRA="$AC_ROW" mk_prev RKAC; fx_done
AC_RD="$XDG_STATE_HOME/cc-cmds/run/RKAC"
mkdir -p "$AC_RD/plugin/cc-cmds/orchestrator"
printf 'pinned copy\n' > "$AC_RD/plugin/cc-cmds/orchestrator/run.sh"
printf 'digest\t%s\n' "$(printf 'pinned copy\n' | shasum -a 256 | cut -d' ' -f1)" > "$AC_RD/plugin-pin"
pin_sum() {
  { printf '%s\n' "$(sha "$AC_RD/plugin-pin")"
    find "$AC_RD/plugin" -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done
  } | shasum -a 256 | cut -d' ' -f1
}
PIN_BEFORE=$(pin_sum)
mf_check "$BASE/docs/pipeline-run/RKAC.plan.md"; rc=$?
check "7: 적용 프로브 코드 행을 가진 원천이 check_manifest 를 통과한다" "$rc" "0"
detect_case "8 적용 프로브 코드" RKAC ""
vac=$(rk verify --prev RKAC --base "$BASE")
PMA=$(printf '%s\n' "$vac" | awk -F'\t' '$1 == "해시" && $2 == "매니페스트" { print $3 }')
PGA=$(printf '%s\n' "$vac" | awk -F'\t' '$1 == "해시" && $2 == "인가 기록" { print $3 }')
rk graph --prev RKAC --base "$BASE" --expect-sha256 "$PMA" >/dev/null
"$BASH" "$KD" --carry "$BASE/docs/pipeline-run/RKAC.plan.md" --kickoff-at "$KAT1" --expect-sha256 "$PMA" >/dev/null 2>&1
rk render-manifest --prev RKAC --base "$BASE" --run-id RKNA --kickoff-at "$KAT1" --deadline "$DL1" \
   --expect-sha256 "$PMA" --expect-grant-sha256 "$PGA" > "$WORK/v-ac.md"; rc=$?
check "7: 적용 프로브 코드 행을 가진 원천의 render-manifest 는 0 으로 끝난다" "$rc" "0"
check "7: 적용 프로브 코드 행이 초안에 바이트 그대로 하나 옮겨진다" \
  "$(grep -c '^- `적용 프로브 코드`' "$WORK/v-ac.md")/$(grep -cxF -- "$AC_ROW" "$WORK/v-ac.md")" "1/1"
mf_check "$WORK/v-ac.md"; rc=$?
check "7: 그 초안이 check_manifest 를 통과한다" "$rc" "0"
VS_PREV="$BASE/docs/pipeline-run/RKAC.plan.md"; VS_PMSHA="$PMA"; VS_PGSHA="$PGA"
vs "적용 프로브 코드 행이 원천과 같은 초안은 통과한다" 통과 "$WORK/v-ac.md" "$E"
sed 's/| 필요=21 |/| 필요=22 |/' "$WORK/v-ac.md" > "$WORK/v-ac-ch.md"
vs "적용 프로브 코드 행의 값이 바뀐 초안은 실패한다" 실패 "$WORK/v-ac-ch.md" "$E" 고정값
grep -vF -- "$AC_ROW" "$WORK/v-ac.md" > "$WORK/v-ac-drop.md"
vs "적용 프로브 코드 행을 뺀 초안은 실패한다" 실패 "$WORK/v-ac-drop.md" "$E" 고정값
VS_PREV="$PM"; VS_PMSHA="$PMSHA"; VS_PGSHA="$PGSHA"
{ cat "$NM1"; printf '%s\n' "$AC_ROW"; } > "$WORK/v-ac-add.md"
vs "원천에 없는 적용 프로브 코드 행을 더한 초안은 실패한다" 실패 "$WORK/v-ac-add.md" "$E" 고정값
check "7: 재킥오프 흐름 전후 원 런의 plugin-pin 과 plugin/cc-cmds 사본이 같다" "$(pin_sum)" "$PIN_BEFORE"

# The interview copy.
out=$(rk render-interview --prev RKIV --base "$BASE" --expect-sha256 "$PMI"); rc=$?
check "7: render-interview 는 0 으로 끝난다" "$rc" "0"
check "7: 인터뷰 복사본의 sha256 이 원천 행과 같다" "$(printf '%s\n' "$out" | shasum -a 256 | cut -d' ' -f1)" "$(sha "$BASE/docs/pipeline-run/RKIV.interview.md")"
printf 'x' >> "$BASE/docs/pipeline-run/RKIV.interview.md"
out=$(rk render-interview --prev RKIV --base "$BASE" 2>/dev/null); rc=$?
check "7: 원천 인터뷰가 행과 다르면 render-interview 는 1 이고 출력이 없다" "$rc/$out" "1/"

# render-manifest refuses a source that moved after it was verified.
out=$(rk render-manifest --prev "$SRC" --base "$BASE" --run-id RKN8 --kickoff-at "$KAT1" --deadline "$DL1" \
        --expect-sha256 "$OLDBASESHA" --expect-grant-sha256 "$PGSHA" 2>/dev/null); rc=$?
check "7: 검증한 해시와 다른 원천에서 render-manifest 는 1 이고 출력이 없다" "$rc/$out" "1/"
[ "$rc" = "1" ] || tail -2 "$WORK/rk.err" >&2

# ---------------------------------------------------------------------------
# 12. 좌석 — judge 의 금지선과 기다림, --auto 렌더·검증, 연쇄 계수
# ---------------------------------------------------------------------------
# A source the seat may carry on: the consent row, a progress row, an end row
# whose token is in E, `done`. Every case below starts from it and breaks one
# thing, so each prohibition line is shown firing on its own.
SEAT_ROW='- `재킥오프` | 연쇄 상한=3 | 길이=PT48H0M0S | 사유=픽스처'
HEXA=$(printf 'a' | shasum -a 256 | cut -d' ' -f1)
# seat_end <token> [종료 부류] — progress (unless SEAT_NOPROG), the end row, done.
seat_end() {
  [ -n "${SEAT_NOPROG:-}" ] || fx_row 'cycle' "id=1" "상태=완료"
  if [ -n "${2:-}" ]; then
    fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=픽스처" "재킥 원인=$1" "종료 부류=$2" "근거=픽스처"
  else
    fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=픽스처" "재킥 원인=$1" "근거=픽스처"
  fi
  fx_done
}
# mk_seat <id> <token> [종료 부류] — P_EXTRA replaces the consent row when set
# (empty: no row).
mk_seat() {
  P_EXTRA="${P_EXTRA-$SEAT_ROW}" mk_prev "$1"
  seat_end "$2" "${3:-}"
}
# prov7 <src> <k> <root> <cause> — a seven-field provenance row (hashes are fixture values).
prov7() { printf -- '- `사전 인가` | 이어받은 런=%s | 매니페스트 sha256=%s | 인가 기록 sha256=%s | 좌석 연쇄=%s | 뿌리 런=%s | 원인=%s' "$1" "$HEXA" "$HEXA" "$2" "$3" "$4"; }
jdg() { local id="$1"; shift; rk_as "s-$id" judge --prev "$id" --base "$BASE" "$@"; }
fired() { printf '%s\n' "$1" | awk -F'\t' '$1 == "금지선" { printf "%s ", $2 }'; }
fact() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == "사실" && $2 == k { print $3; exit }'; }

n=0
for tok in 마감 천장 무진전; do
  n=$((n + 1))
  mk_seat "RKJ-E$n" "$tok"
  before=$(src_sum "RKJ-E$n")
  out=$(jdg "RKJ-E$n"); rc=$?
  check "12: E 의 $tok 로 끝난 원천은 허용이다" "$rc/$(printf '%s\n' "$out" | head -n 1)/$(col "$out" 판정)/$(fired "$out")" "0/cc-rekick v1/허용/"
  [ "$(col "$out" 판정)" = "허용" ] || { printf '%s\n' "$out"; tail -2 "$WORK/rk.err"; } >&2
  check "12: judge 는 원천 파일·런 디렉터리·색인을 바꾸지 않는다 ($tok)" "$(src_sum "RKJ-E$n")" "$before"
done
check "12: 허용의 사실 줄 — 종료 토큰·연쇄·진전·종료 절" \
  "$(fact "$out" '종료 토큰')/$(fact "$out" 연쇄)/$(fact "$out" 진전)/$(fact "$out" '종료 절')" "무진전/1/3/1/0/1"
check "12: 사람 경로의 원천(출처 행 없음)은 링크 1 부터 센다 — 허용에 대기 줄이 없다" "$(cnt "$out" 대기)" "0"

# Each prohibition line, in the table's order.
mk_seat RKJ-L14 마감
out=$(rk_as s-OTHER judge --prev RKJ-L14 --base "$BASE")
check "12: L14 — 계보에 없는 세션은 금지" "$(col "$out" 판정)/$(fired "$out")" "금지/L14 "

mk_prev RKJ-L1; fx_row 'cycle' "id=1" "상태=완료"
out=$(jdg RKJ-L1)
has "12: L1 — 끝나지 않은 원천은 금지" "$(col "$out" 판정)/$(fired "$out")" "금지/L1 "

mk_seat RKJ-L2 마감; fx_row '종료 절' "id=C1" "상태=충족" "근거=픽스처"
out=$(jdg RKJ-L2)
has "12: L2 — 종료 절을 모두 채운 원천은 금지" "$(fired "$out")" "L2 "
P_EXTRA="$SEAT_ROW" mk_prev RKJ-L2B; fx_row 'cycle' "id=1" "상태=완료"
fx_row '자율 승인' "kind=boundary" "결정=종료" "대상=-" "기준=픽스처" "재킥 원인=해당없음" "종료 부류=완료" "근거=픽스처"; fx_done
out=$(jdg RKJ-L2B)
check "12: L2 — 해당없음 + 종료 부류=완료 는 L2 하나로만 금지 (L11 은 겹치지 않는다)" "$(fired "$out")" "L2 "

n=0
for k in 포기 이어받음; do
  n=$((n + 1))
  mk_seat "RKJ-L3$n" 해당없음 "$k"
  out=$(jdg "RKJ-L3$n")
  has "12: L3 — 종료 부류 $k 는 금지" "$(fired "$out")" "L3 "
done

mk_seat RKJ-L5 마감; fx_approval AP-9 대기
out=$(jdg RKJ-L5)
check "12: L5 — 열린 승인이 있으면 금지" "$(col "$out" 판정)/$(fired "$out")/$(fact "$out" '열린 승인')" "금지/L5 /1"

P_EXTRA="$SEAT_ROW
$(prov7 RKJROOT0 3 RKJROOT 마감)" mk_seat RKJ-L6 마감
out=$(jdg RKJ-L6)
check "12: L6 — 좌석 연쇄 3 인 원천의 후속(k=4)은 상한 3 을 넘어 금지" "$(fact "$out" 연쇄)" "4/3"
has "12: L6 줄이 발화한다" "$(fired "$out")" "L6 "
P_EXTRA="$SEAT_ROW
$(prov7 RKJROOT0 0 RKJROOT 마감)" mk_seat RKJ-L6X 마감
out=$(jdg RKJ-L6X)
has "12: L6 — 출처 행이 어긋나 k 를 낼 수 없어도 금지" "$(fired "$out")" "L6 "

P_EXTRA= mk_seat RKJ-L7 마감
out=$(jdg RKJ-L7)
has "12: L7 — 동의 행이 없으면 금지" "$(fired "$out")" "L7 "

SEAT_NOPROG=1 mk_seat RKJ-L9 천장
out=$(jdg RKJ-L9)
check "12: L9 — E 로 끝났지만 진전 행이 없으면 금지" "$(fired "$out")/$(fact "$out" 진전)" "L9 /0"

P_EXTRA="$SEAT_ROW
$(prov7 RKJROOT0 1 RKJROOT 무진전)" mk_seat RKJ-L15 무진전
out=$(jdg RKJ-L15)
has "12: L15 — 좌석 연쇄 안에서 무진전 두 번 연속은 금지" "$(fired "$out")" "L15 "
P_EXTRA="$SEAT_ROW
$(prov7 RKJROOT0 1 RKJROOT 마감)" mk_seat RKJ-L15X 무진전
out=$(jdg RKJ-L15X)
check "12: L15 — 앞 링크가 마감이면 무진전 한 번은 허용" "$(col "$out" 판정)/$(fired "$out")" "허용/"

mk_seat RKJ-L10 마감; fx_blocked '강제 표면 이동' 무효화
out=$(jdg RKJ-L10)
has "12: L10 — 무효화 갈래는 금지" "$(fired "$out")" "L10 "

# Every end token outside E, read from the gate's own list so a token added
# later is covered too; `표면이동` meets L10 first.
GATE_CAUSES=$(CC_GATE_SOURCE_ONLY=1 bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$GATE_REKICK_CAUSES"' _ "$GATE_SH" 2>/dev/null)
check "12: 게이트의 끝 원인 목록을 읽었다" "$( [ -n "$GATE_CAUSES" ] && echo ok)" "ok"
n=0
for tok in $GATE_CAUSES 죽은토큰; do
  case "$tok" in 마감|천장|무진전) continue ;; esac
  n=$((n + 1))
  mk_seat "RKJ-T$n" "$tok"
  out=$(jdg "RKJ-T$n")
  if [ "$tok" = "표면이동" ]; then
    check "12: L10 — 끝 원인 $tok 는 L10 하나로 금지" "$(fired "$out")" "L10 "
  else
    has "12: L11 — E 밖 끝 원인 $tok 는 금지" "$(col "$out" 판정)/$(fired "$out")" "금지/"
    has "12: L11 줄이 발화한다 ($tok)" "$(fired "$out")" "L11 "
  fi
done

mk_seat RKJ-L12 마감
printf 'x' >> "$BASE/docs/pipeline-run/RKJ-L12.interview.md"
out=$(jdg RKJ-L12)
has "12: L12 — verify 가 실패하는 원천은 금지" "$(fired "$out")" "L12 "

# L13 — a successor manifest under this base that names the source.
mk_seat RKJ-L13S 마감
{ printf '# 후속\n'; prov7 RKJ-L13S 1 RKJ-L13S 마감; printf '\n'; } > "$BASE/docs/pipeline-run/RKJ-L13S-next.plan.md"
out=$(jdg RKJ-L13S)
has "12: L13 — 좌석 경로 후속(일곱 필드)이 있는 원천은 금지" "$(fired "$out")" "L13 "
mk_seat RKJ-L13H 마감
printf -- '- `사전 인가` | 이어받은 런=RKJ-L13H | 매니페스트 sha256=%s | 인가 기록 sha256=%s\n' "$HEXA" "$HEXA" > "$BASE/docs/pipeline-run/RKJ-L13H-next.plan.md"
out=$(jdg RKJ-L13H)
has "12: L13 — 사람 경로 후속(네 필드)이 있는 원천은 금지" "$(fired "$out")" "L13 "
mk_seat RKJ-L13O 마감
mkdir -p "$WORK/other-base/docs/pipeline-run"
printf -- '- `사전 인가` | 이어받은 런=RKJ-L13O | 매니페스트 sha256=%s | 인가 기록 sha256=%s\n' "$HEXA" "$HEXA" > "$WORK/other-base/docs/pipeline-run/RKJ-L13O-next.plan.md"
out=$(jdg RKJ-L13O)
check "12: L13 — 다른 베이스의 후속은 보지 못한다 (밝힌 한계)" "$(col "$out" 판정)/$(fired "$out")" "허용/"
printf -- '- `사전 인가` | 이어받은 런=RKJ-L13OX | 매니페스트 sha256=%s | 인가 기록 sha256=%s\n' "$HEXA" "$HEXA" > "$BASE/docs/pipeline-run/RKJ-L13PFX.plan.md"
out=$(jdg RKJ-L13O)
check "12: L13 — 원천 id 를 접두로만 가진 출처 행은 그 원천이 아니다" "$(fired "$out")" ""

# Waits — only the two question lines of verify, cleared by their keys.
P_EXTRA="$SEAT_ROW
- \`베이스 설계\` | 문서=docs/rk-base.md | sha256=$OLDBASESHA | 티켓=T1" P_AUTOADOPT='설계-골격' mk_seat RKJ-W 마감
out=$(jdg RKJ-W)
check "12: 두 기다림이 함께인 원천은 대기이고 줄이 둘이다" "$(col "$out" 판정)/$(cnt "$out" 대기)" "대기/2"
check "12: 베이스설계 기다림의 키는 7.8 이다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "대기" && $2 == "베이스설계" { print $3 }')" "7.8"
check "12: 어휘 기다림의 키는 7.7 자동채택 이다" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "대기" && $2 == "어휘" { print $3 }')" "7.7 자동채택"
printf '7.8\t묶는다\n' > "$WORK/asked-w1"
out=$(jdg RKJ-W --asked "$WORK/asked-w1")
check "12: 하나만 답하면 대기이고 남은 줄은 어휘다" "$(col "$out" 판정)/$(cnt "$out" 대기)/$(col "$out" 대기)" "대기/1/어휘"
printf '7.8\t묶는다\n7.7 자동채택\t빼고 간다\n' > "$WORK/asked-w2"
out=$(jdg RKJ-W --asked "$WORK/asked-w2")
check "12: 둘 다 답하면 허용이다" "$(col "$out" 판정)/$(cnt "$out" 대기)" "허용/0"
fx_approval AP-W 대기
out=$(jdg RKJ-W --asked "$WORK/asked-w2")
check "12: 금지선이 있으면 답해도 금지다" "$(col "$out" 판정)" "금지"
hasnt "12: 마감에 관한 금지선은 없다" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "금지선"')" "마감을"

# detect and judge agree on whether a run ended, fixture by fixture.
agree() {  # agree <label> <id> — detect's 재킥오프 iff judge fires neither L1 nor L2
  local d j
  d=$(col "$(rk_as "s-$2" detect --arg '')" 판정)
  j=$(fired "$(jdg "$2")")
  case "$j" in *"L1 "*|*"L2 "*) j=막힘 ;; *) j=열림 ;; esac
  case "$d" in 재킥오프) d=열림 ;; *) d=막힘 ;; esac
  check "12: detect 와 judge 가 끝남을 같게 읽는다 ($1)" "$j" "$d"
}
agree "게이트 종료" RKJ-E1
agree "끝나지 않음" RKJ-L1
agree "완료" RKJ-L2
agree "무효화" RKJ-L10
agree "열린 승인" RKJ-L5
mk_prev RKJ-LIVE; fx_stage_live I1; fx_done
agree "살아 있음" RKJ-LIVE
mk_seat RKJ-HALT 마감
mkdir -p "$FX_RUN_DIR/halt"; printf '# 중단\n\n**분류**: gate-unanswerable\n' > "$FX_RUN_DIR/halt/I1#1.md"
agree "답 없는 중단" RKJ-HALT
out=$(jdg RKJ-HALT)
check "12: 답 없는 중단 기록은 L5 로 셈한다" "$(fact "$out" '미답 중단')" "1"

# ---------------------------------------------------------------------------
# 12. render-manifest --auto · verify-subset --auto — 좌석 경로 끝까지
# ---------------------------------------------------------------------------
# seat_link <src> <new> [render args…] — items 2, 5 and 7.1–7.5 of the seat's
# path; SL_AUTO empty takes the person's path instead. Sets SL_RC (render),
# SL_VS (verify-subset verdict), SL_OUT (the draft, written only on 0).
seat_link() {
  local src="$1" new="$2" auto="${SL_AUTO---auto}" v c conf; shift 2
  local pm="$BASE/docs/pipeline-run/$src.plan.md"
  v=$(rk verify --prev "$src" --base "$BASE")
  SL_PMS=$(printf '%s\n' "$v" | awk -F'\t' '$1 == "해시" && $2 == "매니페스트" { print $3 }')
  SL_PGS=$(printf '%s\n' "$v" | awk -F'\t' '$1 == "해시" && $2 == "인가 기록" { print $3 }')
  SL_KAT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # shellcheck disable=SC2086
  c=$("$BASH" "$KD" --carry "$pm" --kickoff-at "$SL_KAT" --expect-sha256 "$SL_PMS" $auto 2>/dev/null)
  SL_DL=$(printf '%s\n' "$c" | awk -F'\t' '$1 == "마감" && $2 == "ok" { print $3 }')
  [ -f "${SL_ASKED:-}" ] || { SL_ASKED="$WORK/asked-seat"; : > "$SL_ASKED"; }
  SL_OUT="$BASE/docs/pipeline-run/$new.plan.md"; SL_VS=""
  # shellcheck disable=SC2086
  rk render-manifest $auto --prev "$src" --base "$BASE" --run-id "$new" --kickoff-at "$SL_KAT" --deadline "$SL_DL" \
     --expect-sha256 "$SL_PMS" --expect-grant-sha256 "$SL_PGS" --asked "$SL_ASKED" "$@" > "$WORK/sl.draft"; SL_RC=$?
  [ "$SL_RC" = 0 ] && [ -s "$WORK/sl.draft" ] || return 0
  cp "$WORK/sl.draft" "$SL_OUT"
  if grep -q '^- `사전 인가` | 인터뷰 기록=' "$SL_OUT"; then
    rk render-interview --prev "$src" --base "$BASE" --expect-sha256 "$SL_PMS" > "$BASE/docs/pipeline-run/$new.interview.md"
  fi
  conf=$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$SL_OUT")
  grant_block "$new" 머지 '픽스처가 끝나면' "$conf" "$DOCSHA" > "$WORK/sl.block"
  # shellcheck disable=SC2086
  SL_VS=$(col "$(rk verify-subset "$SL_OUT" "$pm" --expect-sha256 "$SL_PMS" --expect-grant-sha256 "$SL_PGS" \
            --asked "$SL_ASKED" --grant "$WORK/sl.block" $auto)" 판정)
  write_grant "$new" "$DOC" "$WORK/sl.block"
}
# adopt_run <id> — the run directory, ledger, lineage and index of a run whose
# manifest and grant already exist, so it can be judged as a source.
adopt_run() {
  fx_mkrun "$1"; rm -f "$FX_LEDGER"
  FX_LEDGER="$BASE/docs/pipeline-run/$1.md"; : > "$FX_LEDGER"; export FX_LEDGER
  fx_ledger_path
  printf '%s\n' "s-$1" > "$FX_RUN_DIR/session-lineage"
  fx_session_index "s-$1" "$1"
}
prov_of() { grep -E '^- `사전 인가` \| 이어받은 런=' "$1"; }

# Link 0 (a person's kickoff) → links 1, 2, 3 by the seat; the fourth is refused.
mk_seat RKS0 마감
SL_ASKED=""; seat_link RKS0 RKS1
check "12: 링크 1 — render-manifest --auto 는 0 이고 verify-subset --auto 가 통과한다" "$SL_RC/$SL_VS" "0/통과"
check "12: 링크 1 의 출처 행은 일곱 필드이고 좌석 연쇄=1 · 뿌리 런=원천 · 원인=끝 토큰이다" "$(prov_of "$SL_OUT")" \
  "- \`사전 인가\` | 이어받은 런=RKS0 | 매니페스트 sha256=$SL_PMS | 인가 기록 sha256=$SL_PGS | 좌석 연쇄=1 | 뿌리 런=RKS0 | 원인=마감"
check "12: 승인 문면은 좌석 재킥오프 로 고정된다" "$(awk -F': ' '$1 == "**승인 문면**" { print $2 }' "$SL_OUT")" "좌석 재킥오프"
check "12: 사용자 확인 문면은 좌석 재킥오프 <원천 id> 다" "$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$SL_OUT")" "좌석 재킥오프 RKS0"
check "12: 재킥오프 행을 원천과 바이트로 같게 옮긴다" "$(grep -c '^- `재킥오프` | ' "$SL_OUT")/$(grep -cxF -- "$SEAT_ROW" "$SL_OUT")" "1/1"
mf_check "$SL_OUT"; rc=$?
check "12: 링크 1 초안이 check_manifest 를 통과한다" "$rc" "0"
[ "$rc" = 0 ] || tail -1 "$WORK/check.err" >&2
GPLAN0=$(col "$(rk graph --prev RKS0 --base "$BASE")" 계획)
check "12: 그린 계획의 단계 id 는 원천 계획의 부분집합이다" \
  "$(jq -n --argjson g "$GPLAN0" --argjson p "$(drv "$BASE/docs/pipeline-run/RKS0.plan.md" manifest_plan_json)" '([$g.steps[].id] - [$p.steps[].id]) | length')" "0"
check "12: 초안의 계획이 graph 가 그린 계획이다" "$(drv "$SL_OUT" manifest_plan_json | jq -c .)" "$(printf '%s' "$GPLAN0" | jq -c .)"
L1DRAFT="$WORK/link1.md"; cp "$SL_OUT" "$L1DRAFT"; L1PMS=$SL_PMS; L1PGS=$SL_PGS
# A kickoff default is not applied on the seat's path: `--carry --auto` may
# show `빈칸` rows, but the seat passes no `--set`, so the draft keeps the
# source's empty fields and still passes.
printf 'cost-ceiling = 12\n[t/rk]\ndeploy-triggers = branch:release\n' > "$WORK/defaults-seat"
cout=$(CC_CMDS_AUTOPILOT_DEFAULTS_FILE="$WORK/defaults-seat" "$BASH" "$KD" --carry "$BASE/docs/pipeline-run/RKS0.plan.md" \
         --kickoff-at "$SL_KAT" --expect-sha256 "$L1PMS" --auto 2>/dev/null)
check "12: 기본값 파일이 있으면 --carry --auto 도 빈칸 행을 보인다 (다음 단언이 공허하지 않다)" "$(cnt "$cout" 빈칸)" "2"
check "12: 좌석 초안에는 기본값 파일의 값이 들어가지 않는다" "$(grep -cE 'branch:release|cost-ceiling|비용 천장\*\*: 12' "$L1DRAFT")" "0"
out=$(jdg RKS0)
has "12: 링크 1 이 생긴 뒤 같은 원천의 judge 는 L13 으로 금지" "$(fired "$out")" "L13 "

adopt_run RKS1; seat_end 마감
out=$(jdg RKS1)
check "12: 링크 1 을 원천으로 한 judge 는 허용 · 연쇄 2/3" "$(col "$out" 판정)/$(fact "$out" 연쇄)" "허용/2/3"
[ "$(col "$out" 판정)" = 허용 ] || printf '%s\n' "$out" >&2
seat_link RKS1 RKS2
check "12: 링크 2 의 출처 행은 좌석 연쇄=2 · 뿌리 런=RKS0" "$SL_RC/$SL_VS/$(prov_of "$SL_OUT" | sed 's/.*| 좌석 연쇄=/좌석 연쇄=/')" "0/통과/좌석 연쇄=2 | 뿌리 런=RKS0 | 원인=마감"
mf_check "$SL_OUT"; rc=$?
check "12: 링크 2 초안도 check_manifest 를 통과한다" "$rc" "0"
adopt_run RKS2; seat_end 천장
out=$(jdg RKS2)
check "12: 링크 2 를 원천으로 한 judge 는 허용 · 연쇄 3/3" "$(col "$out" 판정)/$(fact "$out" 연쇄)" "허용/3/3"
[ "$(col "$out" 판정)" = 허용 ] || printf '%s\n' "$out" >&2
seat_link RKS2 RKS3
check "12: 링크 3 의 출처 행은 좌석 연쇄=3 · 원인=천장" "$SL_RC/$SL_VS/$(prov_of "$SL_OUT" | sed 's/.*| 좌석 연쇄=/좌석 연쇄=/')" "0/통과/좌석 연쇄=3 | 뿌리 런=RKS0 | 원인=천장"
mf_check "$SL_OUT"; rc=$?
check "12: 링크 3 초안도 check_manifest 를 통과한다" "$rc" "0"
sed 's/| 좌석 연쇄=3 |/| 좌석 연쇄=1 |/' "$SL_OUT" > "$WORK/rkc3-low.md"
VS_PREV="$BASE/docs/pipeline-run/RKS2.plan.md"; VS_PMSHA="$SL_PMS"; VS_PGSHA="$SL_PGS"
vs "링크 3 초안의 좌석 연쇄를 3 에서 1 로 낮추면 --auto 검사 3 이 실패한다" 실패 "$WORK/rkc3-low.md" "$SL_ASKED" 출처 --auto
mf_check "$WORK/rkc3-low.md"; rc=$?
check "12: 얼린 매니페스트에서 좌석 연쇄를 고치면 check_manifest 가 거부한다" "$( [ "$rc" != 0 ] && echo 거부)" "거부"
adopt_run RKS3; seat_end 마감
out=$(jdg RKS3)
check "12: 링크 3 을 원천으로 한 judge 는 L6 으로 금지 · 연쇄 4/3" "$(fired "$out")/$(fact "$out" 연쇄)" "L6 /4/3"
seat_link RKS3 RKS4
check "12: 링크 3 을 원천으로 render-manifest --auto 는 3 이고 초안이 없다" "$SL_RC/$( [ -s "$WORK/sl.draft" ] && echo 있음 || echo 없음)/$( [ -f "$BASE/docs/pipeline-run/RKS4.plan.md" ] && echo 있음 || echo 없음)" "3/없음/없음"
has "12: 그 거부는 상한을 짚는다" "$(cat "$WORK/rk.err")" "연쇄 상한 3"

# A person's re-kickoff in the middle starts the count again.
SL_AUTO= seat_link RKS1 RKH2
check "12: 사람 경로 링크는 네 필드 출처 행을 쓴다" "$SL_RC/$SL_VS/$(prov_of "$SL_OUT" | awk -F' [|] ' '{ print NF }')" "0/통과/4"
adopt_run RKH2; seat_end 마감
seat_link RKH2 RKH3
check "12: 사람 링크 뒤 --auto 링크의 출처 행은 좌석 연쇄=1 · 뿌리 런=사람 링크" "$SL_RC/$(prov_of "$SL_OUT" | sed 's/.*| 좌석 연쇄=/좌석 연쇄=/')" "0/좌석 연쇄=1 | 뿌리 런=RKH2 | 원인=마감"
adopt_run RKH3; seat_end 마감
out=$(jdg RKH3)
check "12: 그 링크를 원천으로 한 judge 는 L6 없이 허용 · 연쇄 2/3" "$(col "$out" 판정)/$(fact "$out" 연쇄)" "허용/2/3"

# verify-subset --auto check 3 — five drafts against the seat source RKS0.
VS_PREV="$BASE/docs/pipeline-run/RKS0.plan.md"; VS_PMSHA="$L1PMS"; VS_PGSHA="$L1PGS"
: > "$WORK/asked-seat0"
vs "--auto 가 만든 일곱 필드 초안은 --auto 에서 통과한다" 통과 "$L1DRAFT" "$WORK/asked-seat0" "" --auto
vs "같은 일곱 필드 초안은 --auto 없이 실패한다" 실패 "$L1DRAFT" "$WORK/asked-seat0" 출처
sed 's/ | 좌석 연쇄=1 | 뿌리 런=RKS0 | 원인=마감$//' "$L1DRAFT" > "$WORK/v-p4.md"
vs "세 필드를 지운 네 필드 초안은 --auto 에서 실패한다" 실패 "$WORK/v-p4.md" "$WORK/asked-seat0" 출처 --auto
sed 's/| 원인=마감$/| 원인=마감 | 덧=1/' "$L1DRAFT" > "$WORK/v-p8.md"
vs "필드가 하나 더 붙은 출처 행은 --auto 에서 실패한다" 실패 "$WORK/v-p8.md" "$WORK/asked-seat0" 출처 --auto
sed 's/| 원인=마감$/| 원인=결함/' "$L1DRAFT" > "$WORK/v-pc.md"
vs "원인이 원천의 끝 토큰과 다른 출처 행은 --auto 에서 실패한다" 실패 "$WORK/v-pc.md" "$WORK/asked-seat0" 출처 --auto
sed 's/| 좌석 연쇄=1 |/| 좌석 연쇄=2 |/' "$L1DRAFT" > "$WORK/v-pk.md"
vs "좌석 연쇄가 다시 낸 값과 다른 출처 행은 --auto 에서 실패한다" 실패 "$WORK/v-pk.md" "$WORK/asked-seat0" 출처 --auto
# The consent row stays the source's.
sed 's/연쇄 상한=3/연쇄 상한=9/' "$L1DRAFT" > "$WORK/v-cap.md"
vs "연쇄 상한을 넓힌 초안은 --auto 에서 실패한다" 실패 "$WORK/v-cap.md" "$WORK/asked-seat0" 동의 --auto
sed 's/길이=PT48H0M0S/길이=PT96H0M0S/' "$L1DRAFT" > "$WORK/v-len.md"
vs "길이를 늘린 초안은 --auto 에서 실패한다" 실패 "$WORK/v-len.md" "$WORK/asked-seat0" 동의 --auto
# Check 10 — the length fallback, measured from the draft's kickoff.
L1KAT=$(awk -F': ' '$1 == "**킥오프 일시**" { print $2 }' "$L1DRAFT")
L1FB=$(jq -rn --arg k "$L1KAT" '($k | fromdateiso8601) + 172800 | todateiso8601')
sed "s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: $L1FB/" "$L1DRAFT" > "$WORK/v-fb.md"
vs "킥오프 일시 + 원천 길이 의 마감은 --auto 에서 통과한다" 통과 "$WORK/v-fb.md" "$WORK/asked-seat0" "" --auto
sed 's/ | 좌석 연쇄=1 | 뿌리 런=RKS0 | 원인=마감$//' "$WORK/v-fb.md" > "$WORK/v-fb4.md"
vs "같은 마감은 --auto 없이 검사 10 에서 실패한다" 실패 "$WORK/v-fb4.md" "$WORK/asked-seat0" 마감
L1FBX=$(jq -rn --arg k "$L1KAT" '($k | fromdateiso8601) + 172800 + 3600 | todateiso8601')
sed "s/^\*\*벽시계 마감\*\*: .*/**벽시계 마감**: $L1FBX/" "$L1DRAFT" > "$WORK/v-fbx.md"
vs "킥오프 일시가 아닌 다른 순간에 길이를 붙인 마감은 --auto 에서도 실패한다" 실패 "$WORK/v-fbx.md" "$WORK/asked-seat0" 마감 --auto

# A graph `graph` calls changed: no draft on the seat's path.
P_PLAN='{ "design_required": true, "entry_skill": "design", "steps": [ { "id": "D1", "skill": "design", "summary": "설계", "depends_on": [] }, { "id": "I1", "skill": "implement", "summary": "구현", "depends_on": ["D1", "X9"] } ] }' \
  mk_seat RKCG 마감
check "12: 빼고 난 계획의 의존이 끊긴 원천은 graph 가 바뀜 이다" "$(col "$(rk graph --prev RKCG --base "$BASE")" 그래프)" "바뀜"
SL_ASKED=""; seat_link RKCG RKCG1
check "12: 그 원천에서 render-manifest --auto 는 3 이고 초안이 없다" "$SL_RC/$( [ -s "$WORK/sl.draft" ] && echo 있음 || echo 없음)" "3/없음"
L1DL=$(awk -F': ' '$1 == "**벽시계 마감**" { print $2 }' "$L1DRAFT")
out=$(rk render-manifest --auto --accepted extra --prev RKS0 --base "$BASE" --run-id RKSA --kickoff-at "$L1KAT" --deadline "$L1DL" \
        --expect-sha256 "$L1PMS" --expect-grant-sha256 "$L1PGS" --asked "$WORK/asked-seat0" 2>/dev/null); rc=$?
check "12: --auto 에 --accepted 는 용법 오류다" "$rc/$out" "2/"

# An answered base-design wait reaches the draft and verify-subset --auto.
P_EXTRA="$SEAT_ROW
- \`베이스 설계\` | 문서=docs/rk-base.md | sha256=$OLDBASESHA | 티켓=T1" mk_seat RKCB 마감
out=$(jdg RKCB)
check "12: 베이스 설계가 바뀐 원천의 judge 는 대기 · 베이스설계 · 7.8" \
  "$(col "$out" 판정)/$(col "$out" 대기)/$(col "$out" 대기 3)" "대기/베이스설계/7.8"
printf '7.8\t묶는다\n' > "$WORK/asked-cb"
out=$(jdg RKCB --asked "$WORK/asked-cb")
check "12: 7.8 을 답한 judge 는 허용이고 기다림 줄이 없다" "$(col "$out" 판정)/$(cnt "$out" 대기)" "허용/0"
SL_ASKED="$WORK/asked-cb"; seat_link RKCB RKCB1 --bind-base "$NOWBASE"
check "12: 답한 7.8 과 --bind-base 로 그린 초안이 verify-subset --auto 를 통과한다" "$SL_RC/$SL_VS" "0/통과"
check "12: 그 초안의 사용자 확인 문면은 좌석 재킥오프 <원천> / 묶는다" \
  "$(awk -F': ' '$1 == "**사용자 확인 문면**" { print $2 }' "$SL_OUT")" "좌석 재킥오프 RKCB / 묶는다"

# An answered target confirmation, with and without --targets.
mk_seat RKCT 마감
sed 's/| 원격 슬러그=t\/rk |/| 원격 슬러그=t\/rk-moved |/' "$BASE/docs/pipeline-run/RKCT.plan.md" | grep -E '^- `target`' > "$WORK/targets-ct"
printf '대상확인 rk\t원격 슬러그는 t/rk-moved 다\n' > "$WORK/asked-ct"
SL_ASKED="$WORK/asked-ct"; seat_link RKCT RKCT1 --targets "$WORK/targets-ct"
check "12: 답한 대상 확인과 --targets 로 그린 초안이 verify-subset --auto 를 통과한다" "$SL_RC/$SL_VS" "0/통과"
SL_ASKED="$WORK/asked-ct"; seat_link RKCT RKCT2
check "12: --targets 없이 그리면 원천 대상 행이 그대로 옮겨진다" \
  "$(grep -E '^- `target`' "$SL_OUT")" "$(grep -E '^- `target`' "$BASE/docs/pipeline-run/RKCT.plan.md")"
SL_ASKED=""

# The seat's wording that no helper prints: the stub's reason line and the
# notice for a failure on the immediate path.
SEATDOC="$repo_root/plugins/cc-cmds/skills/autopilot/references/act2-seat.md"
has "12: 좌석 문서 — 리포트 스텁에 좌석의 근거 한 줄이 들어간다" "$(cat "$SEATDOC")" "「좌석 재킥오프 근거: <근거>」"
has "12: 좌석 문서 — 즉시 경로 실패 고지는 새 런 id 와 매니페스트 경로를 적는다" "$(cat "$SEATDOC")" "The notice names the new run id and its manifest path"
has "12: 좌석 문서 — 첫 snapshot 전이면 즉시 경로를 다시 수행한다" "$(cat "$SEATDOC")" "before the first \`snapshot\`, perform Step 7's immediate path again for the new run"
has "12: 좌석 문서 — 그 뒤면 빈 인자 진행 중 뒤 재개한다" "$(cat "$SEATDOC")" "shows the run as \`진행 중\` and it continues by 「Resuming after a break」"
has "12: 좌석 문서 — 원천을 다시 재킥오프하지 말라고 적는다" "$(cat "$SEATDOC")" "It also says not to re-kick the source"
has "12: 좌석 문서 — L13 의 다른 베이스 한계를 적는다" "$(cat "$SEATDOC")" "**L13 sees only this base.**"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
