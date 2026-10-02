#!/usr/bin/env bash
# Acceptance test: the two orchestrator suites do not write to the ledger of a
# pipeline run they inherit from their environment.
#
# A suite started inside a pipeline stage inherits all eleven `CC_PIPELINE_*`
# names. The pre-tool hook the hook-decision sections drive reads
# `CC_PIPELINE_MANIFEST` from the environment and hands it to
# `gate.sh digest-path --manifest`, and the gate derives the ledger from that
# manifest — so fixture `run` rows landed in the live run's ledger. Both suites
# now clear the eleven names at the top of the file. This test proves the
# channel is closed rather than asserting the `unset` line exists.
#
# THE SHAPE, and why each piece is there:
#
#   - The working tree is copied into a scratch MIRROR that is its own git
#     repository, and the scratch manifest names that mirror as its
#     `origin-worktree`. The hook runs in the suite's cwd, and the gate refuses a
#     manifest whose `origin-worktree` is not the cwd's repository — so a suite
#     run from anywhere else writes nothing whether or not the guard works. The
#     real incident had exactly this alignment: the suite ran inside the checkout
#     the live manifest named. Tracked files are never truncated; the cut copy
#     below lives in the mirror.
#   - A CONTROL call comes first: the real hook, called the way `hook_decide`
#     calls it, with a copy of the scratch manifest exported. Its ledger must
#     appear. Without that, "no ledger appeared" below could mean the channel is
#     closed or merely that this environment never opens it.
#   - The measured runs: `test-run.sh` cut just before its `# --- T17` marker, so
#     every hook-decision section (T13 to T16) and everything before them runs;
#     and `test-gate.sh --sections` over the sections that open a run and launch
#     a stage. `test-gate.sh` never calls the real hook, so what its run guards
#     is the gate's own reading of the pipeline environment on the run-open and
#     stage-launch paths:
#         1b   the run's settings directory is created on the first call
#         14h  a stage launch with a stub CLI goes end to end
#         14o  the first call creates the authorization directory and one
#              `run` row
#   - The assertion is that the scratch ledger FILE does not exist. That covers
#     every row family at once — `run`, `blocked` and whatever is added later.
#
# WHAT THIS CATCHES, measured by mutating a scratch copy: moving `test-run.sh`'s
# `unset` behind T13, or dropping `CC_PIPELINE_MANIFEST` from it, makes the
# `test-run.sh` assertion fail. Dropping `CC_PIPELINE_MANIFEST` from
# `test-gate.sh`'s `unset` does NOT fail anything today, and no choice of
# sections changes that: the only place that reads the variable's value is
# `gate-pretool.sh`, and `test-gate.sh` never runs that hook. Its half of this
# test is the tripwire for the day a section starts calling the hook or a gate
# path starts reading the variable.
#
# Usage: bash scripts/test-suite-isolation.sh

set -uo pipefail

# THE NOTIFIER IS OFF FOR THIS WHOLE PROCESS. This suite runs the real pre-tool
# hook and two suites that call the gate a hundred times over, and every one of
# those paths can raise a real banner on the user's screen. Nothing here asserts
# anything about a banner, so killing the channel at the process level costs
# this file nothing and is what keeps a scratch fixture from reaching a person.
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_SESSION_NOTIFY=0
export CC_CMDS_SESSION_NOTIFY

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-suite-isolation.XXXXXX")" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

passed=0
failures=0
ok()  { passed=$((passed + 1)); echo "PASS: $1"; }
bad() { failures=$((failures + 1)); echo "FAIL: $1 — $2" >&2; }

# --- the mirror: the working tree as its own repository ----------------------
MIRROR="$ROOT/mirror"
mkdir -p "$MIRROR"
for d in plugins scripts tests Makefile; do
  [ -e "$repo_root/$d" ] && cp -R "$repo_root/$d" "$MIRROR/"
done
mkdir -p "$MIRROR/docs/pipeline-run" "$MIRROR/docs/pipeline-grant"
( cd "$MIRROR" && git init -q \
  && git -c user.email=t@example.invalid -c user.name=T add -A \
  && git -c user.email=t@example.invalid -c user.name=T \
       commit -q --no-gpg-sign -m mirror ) \
  || { echo "FAIL: 거울 레포를 만들지 못했다" >&2; exit 1; }
COMMON=$(cd "$MIRROR" && git rev-parse --path-format=absolute --git-common-dir)

# write_manifest <path> <run-id> — the manifest and grant of a run whose
# origin-worktree is the mirror.
write_manifest() {
  local m="$1" rid="$2" trow tdig
  trow="- \`target\` | 별칭=home | 메인 워크트리=$MIRROR | 공통 git 디렉터리=$COMMON | 베이스 브랜치=master | 홈=예 | 원격 슬러그=Nharu/cc-cmds | 절단점=머지 | 말단 행위 상한=없음"
  tdig=$(printf '%s\n' "$trow" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
  {
    printf '# 파이프라인 런 매니페스트 — %s\n' "$rid"
    printf '<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=%s;\n' "$rid"
    printf '     anchor-kind=repo; anchor-key=Nharu/cc-cmds;\n'
    printf '     owner-doc=(없음); origin-worktree=%s;\n' "$MIRROR"
    printf '     NOT a design doc; mechanism-local, never staged by a skill -->\n\n'
    printf '## 런 정체\n**킥오프 일시**: 2026-09-20T00:00:00Z\n**런 id**: %s\n' "$rid"
    printf '**앵커 종류**: repo\n**앵커 키**: Nharu/cc-cmds\n**사용자 확인 문면**: 돌려라\n\n'
    printf '## 대상\n**대상 맵 다이제스트**: %s\n%s\n\n' "$tdig" "$trow"
    printf '## 요소\n**설계 문서**: (없음)\n**적용 주체**: (해당 없음)\n\n'
    printf '## 실행 계획\n**승인 문면**: 진행\n```json\n{ "steps": ["audit"] }\n```\n\n'
    printf '## 인가\n**런 최대 절단점**: 머지\n**종료 지점**: 전부 머지\n'
    printf '**벽시계 마감**: 2099-01-01T00:00:00Z\n**시각 정합 마커**: 없음\n'
    printf '**사다리 가용 단 수**: 2\n**미선언 상황 처분**: park\n'
    printf -- '- `종료 절` | id=C1 | 문면=네 슬라이스가 전부 머지됐다\n'
  } > "$m"
  {
    printf '# 인가 기록\n<!-- cc-pipeline-grant v1; owner-doc=(없음); writer=autopilot -->\n\n'
    printf '## 인가 %s\n' "$rid"
    printf '**인가 일시**: 2026-09-20T00:00:00Z\n**종료 지점**: 전부 머지\n**권한 절단점**: 머지\n'
    printf '**말단 행위 상한**: 없음\n**직렬 웨이브 고지**: 없음\n**시각 정합 마커**: 없음\n'
    printf '**사용자 확인 문면**: 돌려라\n**설계 문서 전체 sha256**: (해당 없음)\n'
    printf '**보고서**: %s/docs/pipeline-run/%s.md\n' "$MIRROR" "$rid"
  } > "$MIRROR/docs/pipeline-grant/$rid.md"
}

RID=20260101-5c7a7c40
CTL_RID=20260101-c0a7201a
write_manifest "$ROOT/manifest.md" "$RID"
write_manifest "$ROOT/control.md" "$CTL_RID"
LEDGER="$MIRROR/docs/pipeline-run/$RID.md"
CTL_LEDGER="$MIRROR/docs/pipeline-run/$CTL_RID.md"
mkdir -p "$ROOT/rundir" "$ROOT/hh"

# --- control: the channel is open in this environment ------------------------
# The shape of `hook_decide` in test-run.sh: prefix assignments only, no
# `env -i`, cwd inside the manifest's repository.
( cd "$MIRROR" \
  && printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$ROOT/rundir/x.md" \
     | CC_PIPELINE_MANIFEST="$ROOT/control.md" HOME="$ROOT/hh" \
       CLAUDE_CONFIG_DIR="$ROOT/hh/.claude-x" XDG_CONFIG_HOME="$ROOT/hh/.config" \
       XDG_STATE_HOME="$ROOT/hh/.local/state" \
       bash "$MIRROR/plugins/cc-cmds/hooks/gate-pretool.sh" \
         --run-dir "$ROOT/rundir" --gate "$MIRROR/plugins/cc-cmds/orchestrator/gate.sh" \
     >/dev/null 2>&1 )
if [ -f "$CTL_LEDGER" ]; then
  ok "대조군: 매니페스트를 물려받은 진짜 훅이 그 원장을 만든다 (채널이 이 환경에서 열려 있다)"
else
  bad "대조군: 매니페스트를 물려받은 진짜 훅이 그 원장을 만든다" \
      "원장이 생기지 않아 아래 「생기지 않음」 단언이 공허하다"
  echo "test-suite-isolation: $passed passed, $failures failed"
  exit 1
fi

# --- the eleven names, pointing at the scratch run ---------------------------
export CC_PIPELINE_MANIFEST="$ROOT/manifest.md"
export CC_PIPELINE_LEDGER="$LEDGER"
export CC_PIPELINE_RUN_ID="$RID"
export CC_PIPELINE_RUN_DIR="$ROOT/rundir"
export CC_PIPELINE_GRANT="$MIRROR/docs/pipeline-grant/$RID.md"
export CC_PIPELINE_GATE="$MIRROR/plugins/cc-cmds/orchestrator/gate.sh"
export CC_PIPELINE_TARGET=home
export CC_PIPELINE_SEGMENT=S1
export CC_PIPELINE_STAGE_ID='S1#1'
export CC_PIPELINE_SHIFT_ID='S1#1'
export CC_PIPELINE_PARENT_SESSION=isolation-parent

# --- test-run.sh through T16 -------------------------------------------------
TR="$MIRROR/plugins/cc-cmds/orchestrator/test-run.sh"
CUT="$MIRROR/plugins/cc-cmds/orchestrator/test-run-cut.sh"
n=$(grep -n '^# --- T17' "$TR" | head -1 | cut -d: -f1)
if [ -z "$n" ]; then
  bad "test-run.sh 에 T17 표지가 있다" "절단점을 찾지 못했다"
else
  head -n "$((n - 1))" "$TR" > "$CUT"
  ( cd "$MIRROR" && bash "$CUT" ) > "$ROOT/run.out" 2>&1
  rc=$?
  echo "INFO: test-run.sh (T16 까지) rc=$rc FAIL=$(grep -c '^FAIL' "$ROOT/run.out")"
  if [ -f "$LEDGER" ]; then
    bad "test-run.sh (T16 까지) 가 물려받은 런의 원장을 만들지 않는다" \
        "$(grep -c '^- `' "$LEDGER") 행이 붙었다"
  else
    ok "test-run.sh (T16 까지) 가 물려받은 런의 원장을 만들지 않는다"
  fi
fi

# --- test-gate.sh, the run-open and stage-launch sections --------------------
# Judged on its own rows: when the run above already failed, the file exists
# and a bare existence check would blame this suite for the other one's rows.
GATE_SECTIONS=1b,14h,14o
before=0
[ -f "$LEDGER" ] && before=$(grep -c '^- `' "$LEDGER")
( cd "$MIRROR" && bash "$MIRROR/scripts/test-gate.sh" --sections "$GATE_SECTIONS" ) \
  > "$ROOT/gate.out" 2>&1
rc=$?
echo "INFO: test-gate.sh --sections $GATE_SECTIONS rc=$rc FAIL=$(grep -c '^FAIL' "$ROOT/gate.out")"
after=0
[ -f "$LEDGER" ] && after=$(grep -c '^- `' "$LEDGER")
if [ "$after" != "$before" ] || { [ "$before" = 0 ] && [ -f "$LEDGER" ]; }; then
  bad "test-gate.sh --sections $GATE_SECTIONS 가 물려받은 런의 원장을 만들지 않는다" \
      "$((after - before)) 행이 붙었다"
else
  ok "test-gate.sh --sections $GATE_SECTIONS 가 물려받은 런의 원장을 만들지 않는다"
fi

echo "test-suite-isolation: $passed passed, $failures failed"
if (( failures > 0 )); then
  exit 1
fi
exit 0
