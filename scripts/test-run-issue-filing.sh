#!/usr/bin/env bash
# lint-bash-portability: self-skip
# 계측 필링 — 게이트가 수집기 회차의 트리거를 이슈로 옮기는 경로.
#
# 트리거 자체는 수집기의 출력이고 그 정확성은 test-collect-run-metrics.sh 가 잰다. 이
# 스위트는 수집기를 스텁으로 바꿔 회차 줄을 고정하고, 게이트가 그 줄을 받아 무엇을 부르고
# 무엇을 원장에 남기는지만 잰다 — 케이던스·잠금·좌석·설정·자격·상한·담기·닫기와 행 모양.
# gh 는 PATH 앞의 스텁이 argv 를 적고 정해진 출력을 내며, 게이트는 포크로 부른다(스텁이
# PATH 로만 끼어들 수 있으므로).
#
# Usage: bash scripts/test-run-issue-filing.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_SESSION_NOTIFY=0
export CC_CMDS_SESSION_NOTIFY
# 스테이지 안에서 돌리면 좌석 표지가 환경으로 물려온다 — 그러면 모든 픽스처 호출이
# 스테이지의 호출이 되어 필링 경로가 통째로 꺼진다.
unset CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST CC_PIPELINE_LEDGER \
      CC_PIPELINE_GRANT CC_PIPELINE_GATE CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT \
      CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_PARENT_SESSION
export CC_GATE_PIN_DISABLE=1

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"
SKILL="$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-issue-filing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"
STATE_ROOT="$XDG_STATE_HOME/cc-cmds"

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- 스텁 ------------------------------------------------------------------------

mkdir -p "$WORK/bin" "$WORK/gh-script" "$WORK/gh-fail"
export GH_LOG="$WORK/gh.log"
export GH_STUB_DIR="$WORK"
# gh 스텁. argv 한 줄과 어느 자격으로 불렸는지(쓰기·읽기·주변)를 적는다 — 토큰 값은
# 적지 않는다. 키마다 $WORK/gh-fail/<키> 가 있으면 rc 1, $WORK/gh-script/<키> 가 있으면
# 그 내용을 낸다. 없으면 기본 출력.
cat > "$WORK/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "${GH_TOKEN:-}" in
  rw-stub) tok=쓰기 ;;
  ro-stub) tok=읽기 ;;
  *)       tok=주변 ;;
esac
printf '%s | %s\n' "$tok" "$*" >> "$GH_LOG"
key="$1-${2:-}"
[ "$1" = "api" ] && key="api-user"
if [ -e "$GH_STUB_DIR/gh-fail/$key" ]; then exit 1; fi
if [ -e "$GH_STUB_DIR/gh-script/$key" ]; then cat "$GH_STUB_DIR/gh-script/$key"; exit 0; fi
case "$key" in
  api-user)     printf 'tester\n' ;;
  issue-list)   printf '[]\n' ;;
  issue-create) printf 'https://github.com/t/t/issues/42\n' ;;
esac
exit 0
GHEOF
chmod +x "$WORK/bin/gh"
# 알림 도구는 절대 닿지 않게 PATH 에서 가린다.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/terminal-notifier"; chmod +x "$WORK/bin/terminal-notifier"
export PATH="$WORK/bin:$PATH"

# 수집기 스텁 — 호출 수를 세고 $WORK/round.json 을 그대로 낸다.
cat > "$WORK/collector-stub" <<STUBEOF
#!/usr/bin/env bash
printf '1\n' >> "$WORK/calls"
[ -n "\${CC_STUB_SLEEP:-}" ] && sleep "\$CC_STUB_SLEEP"
cat "$WORK/round.json"
STUBEOF
chmod +x "$WORK/collector-stub"
export CC_METRICS_COLLECTOR="$WORK/collector-stub"
export CC_METRICS_FILING_FILE="$WORK/metrics-filing"
export CC_GATE_TOKEN_RW=rw-stub CC_GATE_TOKEN_RO=ro-stub
export CC_CLAUDE_BIN=/usr/bin/true

round() {
  # round <fired 서명들(쉼표) | -> [close 서명들(쉼표)] — 회차 줄 하나.
  jq -cn --arg f "$1" --arg c "${2:-}" '
    {round: 4, at: "2026-01-01T00:00:00Z", repo: "-x", counts: {"수집됨": 2, "미수집": 0, "사라짐": 0, "미종단": 0},
     new_runs: ["20260101-aaaaaaaa"], probe: "ok", mixed_window: false, strata: {},
     fired: (if $f == "-" or $f == "" then [] else ($f | split(",") | map({id: split("/")[0], kind: split("/")[1], signature: ., body: ("술어 " + .)})) end),
     close: (if $c == "" then [] else ($c | split(",")) end),
     excluded: {}}' > "$WORK/round.json"
}
round -
printf 'project\t7\naccount\ttester\n' > "$WORK/metrics-filing"

# --- 픽스처 레포와 런 -------------------------------------------------------------

REPO="$WORK/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@example.invalid && git config user.name T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant && echo one > a.txt && git add -A \
  && git commit -qm one && git branch -M main ) >/dev/null 2>&1
WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
row="- \`target\` | 별칭=repo | 메인 워크트리=$WT | 공통 git 디렉터리=$CG | 베이스 브랜치=main | 홈=예 | 원격 슬러그=t/t | 절단점=배포 | 말단 행위 상한=없음"
TD=$(printf '%s\n' "$row" | sed 's/[[:space:]]\{1,\}/ /g' | sort | shasum -a 256 | cut -d' ' -f1)
PLAN='{ "steps": [] }'; PD0=$(printf '%s\n' "$PLAN" | shasum -a 256 | cut -d' ' -f1)
RUN=20260101-aaaaaaaa
MANIFEST="$WT/plan-$RUN.md"
LEDGER="$WT/docs/pipeline-run/$RUN.md"
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
  printf '## 요소\n**설계 문서**: (없음)\n'
  printf '**적용 주체**: (해당 없음)\n\n'
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

g() { ( cd "$WT" && bash "$GATE" "$@" >/dev/null 2>&1 ); }
snap() { g snapshot --manifest "$MANIFEST"; }
calls() { if [ -f "$WORK/calls" ]; then grep -c '' "$WORK/calls"; else printf 0; fi; }
LEDGER_MARK=0
fresh() {
  # 한 케이스의 시작 — 스탬프를 지우고 gh 로그·스크립트를 비우고 원장 위치를 표시한다.
  rm -f "$STATE_ROOT/metrics.stamp"
  rm -rf "$WORK/gh-script" "$WORK/gh-fail" "$REPO/docs/pipeline-run/metrics.unfiled"
  mkdir -p "$WORK/gh-script" "$WORK/gh-fail"
  cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true
  : > "$GH_LOG"
  printf 'project\t7\naccount\ttester\n' > "$WORK/metrics-filing"
  LEDGER_MARK=$(grep -c '' "$LEDGER" 2>/dev/null || printf 0)
}
new_rows() { sed -n "$((LEDGER_MARK + 1)),\$p" "$LEDGER"; }
skip_rows() { new_rows | grep -F -e '- `계측 필링 건너뜀` |' || true; }
file_rows() { new_rows | grep -F -e '- `자율 승인` |' | grep -F -e '| 절단점=필링 |' || true; }
nrows() { if [ -z "$1" ]; then printf 0; else printf '%s\n' "$1" | grep -c ''; fi; }
field() { printf '%s\n' "$1" | sed -n "s/.*| $2=\([^|]*\) |.*/\1/p" | sed 's/ *$//' | sed -n '1p'; }
ghcount() { grep -c -- "$1" "$GH_LOG" 2>/dev/null || true; }

# 런 디렉터리를 만드는 첫 스냅숏. 이것이 첫 회차이기도 하다(발화 없음).
snap
if [ ! -d "$STATE_ROOT/run/$RUN" ]; then
  printf 'fixture: 런 디렉터리가 만들어지지 않았습니다\n' >&2; exit 1
fi

# --- 1. 조건 없음 · 케이던스 ---------------------------------------------------------
check "1: 첫 진입은 수집기를 한 번 부른다" "$(calls)" "1"
check "1: 스탬프가 쓰인다" "$([ -f "$STATE_ROOT/metrics.stamp" ] && printf 있음 || printf 없음)" "있음"
check "1: 조건이 없으면 gh 를 부르지 않는다" "$(grep -c '' "$GH_LOG" 2>/dev/null || printf 0)" "0"
check "1: 조건이 없으면 필링 행도 건너뜀 행도 없다" "$(grep -c -F -e '`계측 필링 건너뜀`' -e '절단점=필링' "$LEDGER")" "0"
round T3/review
snap
check "1: 스탬프 안의 두 번째 진입은 수집기를 부르지 않는다(케이던스)" "$(calls)" "1"
check "1: 케이던스로 건너뛴 진입은 아무 행도 남기지 않는다" "$(grep -c -F '`계측 필링 건너뜀`' "$LEDGER")" "0"

# --- 2. 등록 · Project 담기 -----------------------------------------------------------
fresh; round T3/review
snap
check "2: 스탬프가 만료되면 수집기를 다시 부른다" "$(calls)" "2"
check "2: 등록은 issue create 한 번이다" "$(ghcount '| issue create ')" "1"
check "2: 제목은 [cc-metrics] 와 서명이다" "$(grep -c -F -- "--title [cc-metrics] T3/review" "$GH_LOG")" "1"
check "2: 라벨 cc-metrics 가 붙는다" "$(grep -F '| issue create ' "$GH_LOG" | grep -c -F -- '--label cc-metrics')" "1"
check "2: 등록은 쓰기 자격으로 한다" "$(grep -F '| issue create ' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
check "2: 열린 이슈 조회는 읽기 자격으로 한다" "$(grep -F '| issue list ' "$GH_LOG" | cut -d' ' -f1)" "읽기"
check "2: 신원 조회는 쓰기 자격으로 한다" "$(grep -F '| api user' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
check "2: 관측 Project(설정 번호·owner)에 담긴다" \
  "$(grep -c -F -- '| project item-add 7 --owner tester --url https://github.com/t/t/issues/42' "$GH_LOG")" "1"
check "2: 다른 번호의 Project(작업 큐)에는 담지 않는다" \
  "$(grep -F '| project item-add ' "$GH_LOG" | grep -v -c -F '| project item-add 7 ')" "0"
fr=$(file_rows)
check "2: 필링 행이 하나 남는다" "$(nrows "$fr")" "1"
check "2: 필링 행의 결정은 등록이다" "$(field "$fr" '결정')" "등록"
check "2: 필링 행의 kind 는 metrics-filing 이다" "$(field "$fr" 'kind')" "metrics-filing"
check "2: 필링 행의 세그먼트는 - 다" "$(field "$fr" '세그먼트')" "-"
check "2: 필링 행의 되돌리는 법은 그 이슈를 닫는 명령이다" "$(field "$fr" '되돌리는 법')" "gh issue close 42"
check "2: 필링 행에 행위자 필드가 없다" "$(printf '%s' "$fr" | grep -c -F '| 행위자=')" "0"
check "2: 필링 행에 판단 부류 필드가 없다" "$(printf '%s' "$fr" | grep -c -F '| 판단 부류=')" "0"
check "2: 등록된 회차에는 건너뜀 행이 없다" "$(nrows "$(skip_rows)")" "0"

# --- 3. 번호 없음 ---------------------------------------------------------------------
fresh; round T3/review
printf 'account\ttester\n' > "$WORK/metrics-filing"
snap
check "3: Project 번호가 없으면 issue create 를 부르지 않는다" "$(ghcount '| issue create ')" "0"
check "3: Project 번호가 없으면 gh 를 전혀 부르지 않는다" "$(grep -c '' "$GH_LOG")" "0"
sr=$(skip_rows)
check "3: 번호 없음 건너뜀 행이 남는다" "$(field "$sr" '사유')" "번호 없음"
check "3: 건너뜀 행이 서명을 나른다" "$(field "$sr" '트리거')" "T3/review"
check "3: 건너뜀 행의 세그먼트는 - 다" "$(field "$sr" '세그먼트')" "-"
fresh; round T3/review
printf 'project\tabc\naccount\ttester\n' > "$WORK/metrics-filing"
snap
check "3: 숫자가 아닌 번호는 없는 것으로 읽는다" "$(field "$(skip_rows)" '사유')" "번호 없음"
fresh; round T3/review
rm -f "$WORK/metrics-filing"
snap
check "3: 설정 파일이 없으면 번호 없음이다" "$(field "$(skip_rows)" '사유')" "번호 없음"

# --- 4. 상한 · 코멘트 -----------------------------------------------------------------
fresh; round T3/review
printf '[{"number":5,"title":"[cc-metrics] T3/review"}]\n' > "$WORK/gh-script/issue-list"
snap
check "4: 같은 서명이 열려 있으면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "4: 같은 서명이 열려 있으면 상한 도달이다" "$(field "$(skip_rows)" '사유')" "상한 도달"
fresh; round T2/review
printf '[{"number":5,"title":"[cc-metrics] T3/review"}]\n' > "$WORK/gh-script/issue-list"
snap
check "4: 다른 서명이 열려 있어도 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "4: 다른 서명이 열려 있으면 상한 도달이다" "$(field "$(skip_rows)" '사유')" "상한 도달"
fresh; round T2/review
printf '[{"number":9,"title":"[cc-metrics] T6/review"}]\n' > "$WORK/gh-script/issue-list"
snap
check "4: T6 이 열려 있는 중 다른 트리거는 그 이슈에 코멘트한다" "$(ghcount '| issue comment 9 ')" "1"
check "4: 코멘트는 쓰기 자격으로 한다" "$(grep -F '| issue comment ' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
check "4: 코멘트할 때는 등록하지 않는다" "$(ghcount '| issue create ')" "0"
fr=$(file_rows)
check "4: 코멘트는 결정=코멘트 필링 행을 남긴다" "$(field "$fr" '결정')" "코멘트"
check "4: 코멘트 회차에는 건너뜀 행이 없다" "$(nrows "$(skip_rows)")" "0"

# --- 5. 담기 실패 ---------------------------------------------------------------------
fresh; round T3/review
: > "$WORK/gh-fail/project-item-add"
snap
check "5: 담기만 실패해도 이슈는 남는다" "$(ghcount '| issue create ')" "1"
check "5: 미담기 산출물에 담는 명령이 적힌다" \
  "$(grep -c -F 'gh project item-add 7 --owner tester --url https://github.com/t/t/issues/42' "$REPO/docs/pipeline-run/metrics.unfiled/42.md" 2>/dev/null || printf 0)" "1"
check "5: 담기 실패는 건너뜀 행을 남기지 않는다" "$(nrows "$(skip_rows)")" "0"
check "5: 담기 실패여도 등록 필링 행은 남는다" "$(field "$(file_rows)" '결정')" "등록"

# --- 6. 신원·조회·자격 ---------------------------------------------------------------
fresh; round T3/review
printf 'someone-else\n' > "$WORK/gh-script/api-user"
snap
check "6: 쓰기 자격의 신원이 설정 계정과 다르면 조회 실패다" "$(field "$(skip_rows)" '사유')" "조회 실패"
check "6: 신원이 다르면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
fresh; round T3/review
: > "$WORK/gh-fail/api-user"
snap
check "6: 신원 조회가 실패하면 조회 실패다" "$(field "$(skip_rows)" '사유')" "조회 실패"
fresh; round T3/review
: > "$WORK/gh-fail/issue-list"
snap
check "6: 열린 이슈 조회가 실패하면 조회 실패다" "$(field "$(skip_rows)" '사유')" "조회 실패"
check "6: 조회가 실패하면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
fresh; round T3/review
( export CC_GATE_TOKEN_RW="" CC_GATE_KEYCHAIN="cc-cmds-no-such-keychain-$$"; snap )
check "6: 쓰기 자격이 없으면 자격 없음이다" "$(field "$(skip_rows)" '사유')" "자격 없음"
check "6: 쓰기 자격이 없으면 gh 를 부르지 않는다" "$(grep -c '' "$GH_LOG")" "0"

# --- 7. 닫기 --------------------------------------------------------------------------
fresh; round - T6/review
printf '[{"number":9,"title":"[cc-metrics] T6/review"}]\n' > "$WORK/gh-script/issue-list"
snap
check "7: close 서명과 같은 열린 이슈를 닫는다" "$(ghcount '| issue close 9')" "1"
fr=$(file_rows)
check "7: 닫기는 결정=닫힘 필링 행을 남긴다" "$(field "$fr" '결정')" "닫힘"
check "7: 닫힘 행의 되돌리는 법은 다시 여는 명령(기록만, 실행 안 함)이다" "$(field "$fr" '되돌리는 법')" "gh issue reopen 9"
check "7: 닫기만 있는 회차는 등록하지 않는다" "$(ghcount '| issue create ')" "0"

# 수집기가 rc 0 으로 끝났는데 회차 줄이 비었거나 JSON 이 아니면 회차가 없는 것이다 —
# 번호 없음 설정에서도 건너뜀 행이 남으면 발화하지 않은 트리거를 적은 셈이 된다.
fresh; : > "$WORK/round.json"
printf 'account\ttester\n' > "$WORK/metrics-filing"
snap
check "7: 빈 회차 줄은 건너뜀 행을 남기지 않는다" "$(nrows "$(skip_rows)")" "0"
check "7: 빈 회차 줄은 gh 를 부르지 않는다" "$(grep -c '' "$GH_LOG")" "0"
fresh; printf 'not json\n' > "$WORK/round.json"
printf 'account\ttester\n' > "$WORK/metrics-filing"
snap
check "7: JSON 이 아닌 회차 줄도 건너뜀 행을 남기지 않는다" "$(nrows "$(skip_rows)")" "0"

# --- 8. 좌석 · plan · 동시 진입 --------------------------------------------------------
fresh; round T3/review
before=$(calls)
( export CC_PIPELINE_STAGE_ID='SX#1' CC_PIPELINE_SEGMENT=SX; snap )
check "8: 스테이지 좌석은 수집기를 부르지 않는다" "$(calls)" "$before"
check "8: 스테이지 좌석은 스탬프를 쓰지 않는다" "$([ -f "$STATE_ROOT/metrics.stamp" ] && printf 있음 || printf 없음)" "없음"
g plan --manifest "$MANIFEST" --kind x --target repo --cutpoint 커밋 -- git status
check "8: plan 동사는 수집기를 부르지 않는다" "$(calls)" "$before"
check "8: plan 동사는 스탬프를 쓰지 않는다" "$([ -f "$STATE_ROOT/metrics.stamp" ] && printf 있음 || printf 없음)" "없음"
fresh; round T3/review
before=$(calls)
export CC_STUB_SLEEP=2
snap & p1=$!
snap & p2=$!
wait "$p1"; wait "$p2"
unset CC_STUB_SLEEP
check "8: 스탬프 만료 뒤 동시 진입 둘에 수집기는 한 번만 돈다" "$(( $(calls) - before ))" "1"
check "8: 동시 진입 둘에 등록 시도는 한 번이다" "$(ghcount '| issue create ')" "1"

# --- 9. 전 케이스를 가로지르는 불변 ---------------------------------------------------
cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true
check "9: (선행) 케이스 전체의 gh 호출이 모였다" "$([ -s "$WORK/gh.all" ] && printf 있음 || printf 없음)" "있음"
check "9: gh issue reopen 은 어디서도 부르지 않았다" "$(grep -c -F '| issue reopen' "$WORK/gh.all")" "0"
check "9: gh auth 는 어디서도 부르지 않았다" "$(grep -c -F '| auth ' "$WORK/gh.all")" "0"
check "9: (선행) 원장에 건너뜀 행이 여럿 모였다" "$([ "$(grep -c -F -e '- `계측 필링 건너뜀` |' "$LEDGER")" -ge 8 ] && printf 예 || printf 아니오)" "예"
bad_reason=$(grep -F -e '- `계측 필링 건너뜀` |' "$LEDGER" | sed -n 's/.*| 사유=\([^|]*\) |.*/\1/p' | sed 's/ *$//' \
  | grep -v -x -e '자격 없음' -e '상한 도달' -e '번호 없음' -e '조회 실패' || true)
check "9: 건너뜀 행의 사유는 닫힌 넷 안에만 있다" "$bad_reason" ""
check "9: 두 행 어디에도 판단 부류가 없다" \
  "$(grep -e '- `계측 필링 건너뜀` |' -e '절단점=필링' "$LEDGER" | grep -c -F '판단 부류=')" "0"
check "9: 두 행 어디에도 행위자가 없다" \
  "$(grep -e '- `계측 필링 건너뜀` |' -e '절단점=필링' "$LEDGER" | grep -c -F '| 행위자=')" "0"

# 아침 보고서 — 렌더링은 모델이 하므로, 이 트리에서 잴 수 있는 것은 렌더링 열거에 항목이
# 있다는 사실까지다. 보고서가 실제로 그 행들을 옮겨 적는지는 여기서 재지 못한다.
check "9: 아침 보고서 렌더링 열거에 계측 필링 건너뜀 항목이 있다" \
  "$(grep -c -F -- '- **계측 필링 건너뜀** —' "$SKILL")" "1"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
