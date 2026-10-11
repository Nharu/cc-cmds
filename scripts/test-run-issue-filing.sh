#!/usr/bin/env bash
# lint-bash-portability: self-skip
# 계측 필링 — 게이트가 수집기 회차의 트리거를 이슈로 옮기는 경로.
#
# 트리거 자체는 수집기의 출력이고 그 정확성은 test-collect-run-metrics.sh 가 잰다. 이
# 스위트는 수집기를 스텁으로 바꿔 회차 줄을 고정하고, 게이트가 그 줄을 받아 무엇을 부르고
# 무엇을 원장에 남기는지만 잰다 — 케이던스·잠금·좌석·설정·자격·상한·담기·닫기와 행 모양.
# gh 는 스텁이 argv 를 적고 정해진 출력을 내며, 게이트는 그것을 포크로 부른다. 스텁은
# PATH 가 아니라 `CC_METRICS_GH` 로 끼운다 — 드라이버가 시스템 접두사를 PATH 맨 앞에
# 두므로, gh 가 /usr/bin/gh 인 호스트(우분투 CI 러너)에서는 PATH 앞의 스텁이 진짜 gh
# 에 가려 한 번도 불리지 않는다.
#
# 같은 스텁으로 중단 리포트 회차(10번)도 잰다 — 분류기는 `CC_HALT_STOPS` 스텁으로 사건
# 줄을 고정하고, 게이트가 그 사건을 등록·코멘트·담기·건너뜀으로 옮기는 것만 본다.
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

mkdir -p "$WORK/bin" "$WORK/gh-bin" "$WORK/gh-script" "$WORK/gh-fail" "$WORK/gh-sleep"
export GH_LOG="$WORK/gh.log"
export GH_STUB_DIR="$WORK"
# gh 스텁. argv 한 줄과 어느 자격으로 불렸는지(쓰기·읽기·주변)를 적는다 — 토큰 값은
# 적지 않는다. 키마다 $WORK/gh-sleep/<키> 가 있으면 그 초만큼 먼저 멈추고(멈춘 GitHub
# 호출), $WORK/gh-fail/<키> 가 있으면 rc 1, $WORK/gh-script/<키> 가 있으면 그 내용을 낸다.
# 없으면 기본 출력. 멈춤의 `sleep` 은 출력을 /dev/null 로 둔다 — 스텁이 타임아웃으로 죽어도
# 남은 `sleep` 이 게이트의 명령 치환 파이프를 쥐고 있지 않게.
cat > "$WORK/gh-bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "${GH_TOKEN:-}" in
  rw-stub) tok=쓰기 ;;
  ro-stub) tok=읽기 ;;
  *)       tok=주변 ;;
esac
printf '%s | %s\n' "$tok" "$*" >> "$GH_LOG"
printf 'GH_REPO=%s GH_HOST=%s GH_ENTERPRISE_TOKEN=%s\n' "${GH_REPO:-}" "${GH_HOST:-}" "${GH_ENTERPRISE_TOKEN:-}" \
  >> "$GH_STUB_DIR/gh-env.log"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    cat "$a" > "$GH_STUB_DIR/gh-body" 2>/dev/null
    cat "$a" >> "$GH_STUB_DIR/gh-bodies.all" 2>/dev/null
  fi
  prev="$a"
done
key="$1-${2:-}"
[ "$1" = "api" ] && key="api-user"
if [ -e "$GH_STUB_DIR/gh-sleep/$key" ]; then sleep "$(cat "$GH_STUB_DIR/gh-sleep/$key")" >/dev/null 2>&1; fi
if [ -e "$GH_STUB_DIR/gh-fail/$key" ]; then exit 1; fi
if [ -e "$GH_STUB_DIR/gh-script/$key" ]; then cat "$GH_STUB_DIR/gh-script/$key"; exit 0; fi
case "$key" in
  api-user)     printf 'tester\n' ;;
  issue-list)   printf '[]\n' ;;
  issue-create) printf 'https://github.com/t/t/issues/42\n' ;;
esac
exit 0
GHEOF
chmod +x "$WORK/gh-bin/gh"
export CC_METRICS_GH="$WORK/gh-bin/gh"
# PATH 앞에는 미끼 gh 를 둔다. 게이트가 이음매 대신 PATH 로 gh 를 찾으면 이 미끼가
# 불리고, 9번이 그것을 잡는다 — gh 가 /usr/bin 에 없는 호스트에서도 같은 회귀가 보인다.
export GH_DECOY_LOG="$WORK/gh-decoy.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GH_DECOY_LOG"\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
# 알림 도구는 절대 닿지 않게 PATH 에서 가린다.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/terminal-notifier"; chmod +x "$WORK/bin/terminal-notifier"
export PATH="$WORK/bin:$PATH"
# 목적지를 옮기는 환경 변수를 물려 둔다. 게이트가 그것을 지우지 않으면 스텁의 환경
# 기록에 남고, 9번이 그것을 잡는다.
export GH_REPO=decoy/decoy GH_HOST=decoy.invalid GH_ENTERPRISE_TOKEN=decoy-token

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
# 중단 리포트 분류기 스텁 — 원장 파일 이름마다 $WORK/halt-ev/<이름> 이 있으면 그 줄을
# 내고, 없으면 사건 0 이다. 계측 케이스는 모두 사건 0 으로 돌아 그 행 수 단언이 흔들리지
# 않고, 중단 리포트 케이스만 줄을 둔다. 플릿 백로그 경로는 빈 값으로 끄고 백로그
# 케이스에서만 연다.
mkdir -p "$WORK/halt-ev"
cat > "$WORK/halt-stops" <<HSEOF
#!/usr/bin/env bash
f="$WORK/halt-ev/\$(basename "\$1")"
if [ -f "\$f" ]; then cat "\$f"; fi
exit 0
HSEOF
chmod +x "$WORK/halt-stops"
export CC_HALT_STOPS="$WORK/halt-stops"
export CC_HALT_BACKLOG=

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

# 체크아웃 이름은 알아볼 수 있는 이름으로 둔다 — 공개 트래커로 가는 본문에 그 이름이
# 실리지 않는다는 단언(2번)이 무언가를 배제하도록.
REPO="$WORK/acme-private-checkout"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@example.invalid && git config user.name T \
  && mkdir -p docs/pipeline-run docs/pipeline-grant && echo one > a.txt && git add -A \
  && git commit -qm one && git branch -M main ) >/dev/null 2>&1
WT=$(cd "$REPO" && git rev-parse --show-toplevel)
CG=$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir)
# 레포 표지 — 게이트와 같은 규칙(베이스의 repo-key 를 sha256 한 앞 12자리). 이 레포의
# 이슈 제목은 모두 "$PRE <서명>" 이다.
TAG=$(printf '%s' "$WT" | tr / - | shasum -a 256 | cut -c1-12)
PRE="[cc-metrics $TAG]"
OTHER_PRE="[cc-metrics 000000000000]"
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
# 회차는 게이트 동사가 띄운 분리 자식에서 돈다 — 동사는 스탬프·잠금·발사만 치르고 돌아온다.
# 회차 결과를 단언하는 곳은 자식이 잠금을 풀 때까지 기다린 뒤에 단언한다. 잠금은 동사가
# 돌아오기 전에 잡히므로, 동사 뒤에 잠금이 없으면 회차가 없었거나 이미 끝난 것이다.
ROUND_LOG="$STATE_ROOT/run/$RUN/log/metrics-round.log"
wait_round() {
  local i=0
  while [ -d "$STATE_ROOT/.metrics.lock" ]; do
    [ "$i" -lt 300 ] || { bad "회차 대기" "잠금이 30초 안에 풀리지 않았다"; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
snap_nowait() { g snapshot --manifest "$MANIFEST"; }
snap() { snap_nowait; wait_round; }
calls() { if [ -f "$WORK/calls" ]; then grep -c '' "$WORK/calls"; else printf 0; fi; }
LEDGER_MARK=0
fresh() {
  # 한 케이스의 시작 — 스탬프를 지우고 gh 로그·스크립트를 비우고 원장 위치를 표시한다.
  rm -f "$STATE_ROOT/metrics.stamp"
  rm -rf "$WORK/gh-script" "$WORK/gh-fail" "$WORK/gh-sleep" "$REPO/docs/pipeline-run/metrics.unfiled" "$WORK/gh-body"
  mkdir -p "$WORK/gh-script" "$WORK/gh-fail" "$WORK/gh-sleep"
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
check "2: 제목은 [cc-metrics <레포 표지>] 와 서명이다" "$(grep -c -F -- "--title $PRE T3/review" "$GH_LOG")" "1"
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
check "2: 필링 행의 되돌리는 법은 그 이슈를 닫는 명령이다" "$(field "$fr" '되돌리는 법')" "gh issue close 42 --repo Nharu/cc-cmds"
check "2: 필링 행에 행위자 필드가 없다" "$(printf '%s' "$fr" | grep -c -F '| 행위자=')" "0"
check "2: 필링 행에 판단 부류 필드가 없다" "$(printf '%s' "$fr" | grep -c -F '| 판단 부류=')" "0"
check "2: 등록된 회차에는 건너뜀 행이 없다" "$(nrows "$(skip_rows)")" "0"
# 라벨은 있다고 가정하지 않는다 — gh 는 이슈를 만들기 전에 라벨을 id 로 해소하고, 없으면
# 생성 전체가 실패한다. 그래서 등록 직전에 쓰기 자격으로 멱등 생성한다.
check "2: 등록 전에 라벨을 한 번 만든다" "$(ghcount '| label create cc-metrics ')" "1"
check "2: 라벨 생성은 --force 로 멱등이다" "$(grep -F '| label create ' "$GH_LOG" | grep -c -F -- '--force')" "1"
check "2: 라벨 생성은 쓰기 자격으로 한다" "$(grep -F '| label create ' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
ln_label=$(grep -n -F '| label create ' "$GH_LOG" | cut -d: -f1)
ln_create=$(grep -n -F '| issue create ' "$GH_LOG" | cut -d: -f1)
check "2: 라벨 생성이 이슈 생성보다 먼저다" "$([ "${ln_label:-0}" -gt 0 ] && [ "${ln_label:-0}" -lt "${ln_create:-0}" ] && printf 예 || printf 아니오)" "예"
check "2: 이슈·라벨 호출은 모두 목적지 레포를 명시한다" \
  "$(grep -E '\| (issue|label) ' "$GH_LOG" | grep -v -c -F -- '--repo Nharu/cc-cmds')" "0"
check "2: (선행) 등록 본문이 기록됐다" "$(grep -c -F '요약 파일은' "$WORK/gh-body" 2>/dev/null)" "1"
check "2: 본문은 로컬 절대 경로를 싣지 않는다" "$(grep -c -F -e "$WORK" -e "$WT" "$WORK/gh-body" 2>/dev/null)" "0"
check "2: 본문은 체크아웃 디렉터리 이름을 싣지 않는다" "$(grep -c -F 'acme-private-checkout' "$WORK/gh-body" 2>/dev/null)" "0"
check "2: 본문은 레포를 표지로 나타낸다" "$(grep -c -F -- "- 레포 표지: \`$TAG\`" "$WORK/gh-body" 2>/dev/null)" "1"

# 라벨 생성이 실패하면 이슈를 만들지 않고 기존 사유 `조회 실패` 로 건너뛴다.
fresh; round T3/review
: > "$WORK/gh-fail/label-create"
snap
check "2: 라벨 생성이 실패하면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "2: 라벨 생성이 실패하면 조회 실패 건너뜀 행이 남는다" "$(field "$(skip_rows)" '사유')" "조회 실패"
check "2: 라벨 생성이 실패하면 필링 행이 없다" "$(nrows "$(file_rows)")" "0"

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
printf '[{"number":5,"title":"%s T3/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
snap
check "4: 같은 서명이 열려 있으면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "4: 같은 서명이 열려 있으면 상한 도달이다" "$(field "$(skip_rows)" '사유')" "상한 도달"
fresh; round T2/review
printf '[{"number":5,"title":"%s T3/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
snap
check "4: 다른 서명이 열려 있어도 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "4: 다른 서명이 열려 있으면 상한 도달이다" "$(field "$(skip_rows)" '사유')" "상한 도달"
fresh; round T2/review
printf '[{"number":9,"title":"%s T6/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
snap
check "4: T6 이 열려 있는 중 다른 트리거는 그 이슈에 코멘트한다" "$(ghcount '| issue comment 9 ')" "1"
check "4: 코멘트는 쓰기 자격으로 한다" "$(grep -F '| issue comment ' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
check "4: 코멘트할 때는 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "4: 코멘트 회차의 이슈 호출도 모두 목적지 레포를 명시한다" \
  "$(grep -E '\| (issue|label) ' "$GH_LOG" | grep -v -c -F -- '--repo Nharu/cc-cmds')" "0"
fr=$(file_rows)
check "4: 코멘트는 결정=코멘트 필링 행을 남긴다" "$(field "$fr" '결정')" "코멘트"
check "4: 코멘트 회차에는 건너뜀 행이 없다" "$(nrows "$(skip_rows)")" "0"

# 모든 레포의 회차가 한 공개 트래커로 등록하므로, 다른 레포 표지의 이슈와 표지 없는 옛
# 제목은 이 레포의 이슈가 아니다 — 상한을 채우지도, 코멘트를 받지도 않는다.
fresh; round T2/review
printf '[{"number":5,"title":"%s T3/review"},{"number":9,"title":"%s T6/review"},{"number":13,"title":"[cc-metrics] T3/review"}]\n' \
  "$OTHER_PRE" "$OTHER_PRE" > "$WORK/gh-script/issue-list"
snap
check "4: 다른 레포·표지 없는 이슈만 열려 있으면 등록한다" "$(ghcount '| issue create ')" "1"
check "4: 다른 레포의 열린 이슈는 상한 도달을 만들지 않는다" "$(nrows "$(skip_rows)")" "0"
check "4: 다른 레포의 열린 T6 에는 코멘트하지 않는다" "$(ghcount '| issue comment ')" "0"
check "4: 그 회차의 등록 제목도 이 레포의 표지를 단다" "$(grep -c -F -- "--title $PRE T2/review" "$GH_LOG")" "1"

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
printf '[{"number":9,"title":"%s T6/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
snap
check "7: close 서명과 같은 열린 이슈를 닫는다" "$(ghcount '| issue close 9')" "1"
check "7: 닫기 회차의 이슈 호출도 모두 목적지 레포를 명시한다" \
  "$(grep -E '\| (issue|label) ' "$GH_LOG" | grep -v -c -F -- '--repo Nharu/cc-cmds')" "0"
fr=$(file_rows)
check "7: 닫기는 결정=닫힘 필링 행을 남긴다" "$(field "$fr" '결정')" "닫힘"
check "7: 닫힘 행의 되돌리는 법은 다시 여는 명령(기록만, 실행 안 함)이다" "$(field "$fr" '되돌리는 법')" "gh issue reopen 9 --repo Nharu/cc-cmds"
check "7: 닫기만 있는 회차는 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "7: T6 닫힘 행의 근거는 두 항 술어를 말한다" "$(field "$fr" '근거')" \
  "같은 층의 두 항이 선행 회차 중앙값 대비 좋은 쪽인 회차가 연속 3회다"

# 결함 부류(T6 이외)도 닫히며, 그 근거는 T6 의 두 항 술어가 아니라 「다시 관측되지
# 않았다」다 — 근거를 한 문장으로 묶으면 닫은 이유가 아닌 술어를 원장에 적게 된다.
fresh; round - T2/review
printf '[{"number":11,"title":"%s T2/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
snap
check "7: 결함 부류 서명도 같은 열린 이슈를 닫는다" "$(ghcount '| issue close 11')" "1"
fr=$(file_rows)
check "7: 결함 부류 닫기도 결정=닫힘 행을 남긴다" "$(field "$fr" '결정')" "닫힘"
check "7: 결함 부류 닫힘 행의 되돌리는 법도 다시 여는 명령이다" "$(field "$fr" '되돌리는 법')" "gh issue reopen 11 --repo Nharu/cc-cmds"
check "7: 결함 부류 닫힘 행의 근거는 재관측 없음이다" "$(field "$fr" '근거')" \
  "그 조건이 평가된 회차 연속 3회 동안 다시 관측되지 않았다"

# 닫기 판정은 회차를 띄운 레포의 저널에서 나온다 — 같은 서명이라도 다른 레포 표지의
# 이슈나 표지 없는 옛 제목은 그 판정의 대상이 아니므로 닫지 않는다.
fresh; round - T6/review
printf '[{"number":9,"title":"%s T6/review"},{"number":13,"title":"[cc-metrics] T6/review"}]\n' "$OTHER_PRE" \
  > "$WORK/gh-script/issue-list"
snap
check "7: 다른 레포·표지 없는 같은 서명 이슈는 닫지 않는다" "$(ghcount '| issue close ')" "0"
check "7: 그 회차는 닫힘 행을 남기지 않는다" "$(nrows "$(file_rows)")" "0"

# 게이트가 닫기를 처리하지 못하는 회차. 수집기에는 게이트의 성패가 돌아올 입력이 없고,
# 조건이 사라진 뒤에는 그 서명이 다시 발화하지도 않는다 — 그래서 흘린 닫기를 다시 내지
# 않으면 그 레포의 열림 상한 한 자리가 영구히 막힌다. 닫기가 매 회차 다시 오는 상태 진술이라야
# 회복되며, 같은 닫기가 두 번 와도 제목 조회가 없는 것을 무동작으로 흘린다.
fresh; round - T2/review
printf '[{"number":11,"title":"%s T2/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
: > "$WORK/gh-fail/issue-close"
snap
check "7: 닫기 호출이 실패하면 닫힘 행을 남기지 않는다" "$(nrows "$(file_rows)")" "0"
check "7: 닫기 호출이 실패해도 건너뜀 행으로 오분류하지 않는다" "$(nrows "$(skip_rows)")" "0"
rm -f "$WORK/gh-fail/issue-close" "$STATE_ROOT/metrics.stamp"
snap
check "7: 다시 온 같은 닫기가 다음 회차에 이슈를 닫는다" "$(ghcount '| issue close 11')" "2"
check "7: 그 회차는 닫힘 필링 행을 남긴다" "$(field "$(file_rows)" '결정')" "닫힘"
# 이미 닫힌 이슈에 대한 중복 제안은 무해하다 — 열린 목록에 제목이 없으면 아무것도 안 한다.
printf '[]\n' > "$WORK/gh-script/issue-list"
rm -f "$STATE_ROOT/metrics.stamp"; : > "$GH_LOG"
snap
check "7: 열린 목록에 없는 서명의 닫기 제안은 무동작이다" "$(ghcount '| issue close ')" "0"

# 조기 반환 경로는 닫기 루프에 이르지도 못한다 — 그 회차의 닫기는 통째로 흘러간다. 그러나
# 건너뜀 행은 남기지 않는다: 그 행의 뜻은 「등록하지 못했다」인데 닫기만 있는 회차에는
# 등록할 것이 없고, 닫기가 매 회차 다시 오는 상태 진술이라 이 행을 남기면 Project 번호가
# 없는 동안 6시간마다 영구히 쌓여 진짜 미등록 신호와 구별되지 않는다.
fresh; round - T2/review
printf '[{"number":11,"title":"%s T2/review"}]\n' "$PRE" > "$WORK/gh-script/issue-list"
printf 'account\ttester\n' > "$WORK/metrics-filing"
snap
check "7: Project 번호가 없으면 닫기도 부르지 않는다" "$(ghcount '| issue close ')" "0"
check "7: 닫기만 있는 회차는 번호 없음 건너뜀 행을 남기지 않는다" "$(nrows "$(skip_rows)")" "0"
check "7: 닫기만 있는 회차는 필링 행도 남기지 않는다" "$(nrows "$(file_rows)")" "0"
fresh; round - T2/review
( export CC_GATE_TOKEN_RW="" CC_GATE_KEYCHAIN="cc-cmds-no-such-keychain-$$"; snap )
check "7: 닫기만 있는 회차는 자격 없음 건너뜀 행도 남기지 않는다" "$(nrows "$(skip_rows)")" "0"
fresh; round - T2/review
: > "$WORK/gh-fail/issue-list"
snap
check "7: 닫기만 있는 회차는 조회 실패 건너뜀 행도 남기지 않는다" "$(nrows "$(skip_rows)")" "0"
# 발화와 닫기가 한 회차에 함께 오면 건너뜀 행은 남되, 트리거 필드는 발화한 서명만 나른다 —
# 닫기 목록은 수집기가 사라졌다고 판정한 것이지 발화한 것이 아니다.
fresh; round T3/review T2/review
printf 'account\ttester\n' > "$WORK/metrics-filing"
snap
sr=$(skip_rows)
check "7: 발화가 함께 있는 회차는 번호 없음 건너뜀 행을 남긴다" "$(field "$sr" '사유')" "번호 없음"
check "7: 그 행의 트리거는 발화한 서명만 나르고 닫기 서명은 싣지 않는다" "$(field "$sr" '트리거')" "T3/review"

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
snap_nowait & p1=$!
snap_nowait & p2=$!
wait "$p1"; wait "$p2"
wait_round
unset CC_STUB_SLEEP
check "8: 스탬프 만료 뒤 동시 진입 둘에 수집기는 한 번만 돈다" "$(( $(calls) - before ))" "1"
check "8: 동시 진입 둘에 등록 시도는 한 번이다" "$(ghcount '| issue create ')" "1"

# --- 8b. 멈춘 gh 호출 --------------------------------------------------------------------
# 회차는 게이트 동사가 띄운 분리 자식에서 돈다. 멈춘 GitHub 호출은 호출당 타임아웃으로 끊기고,
# 그 호출이 실패한 것과 같은 분기를 탄다 — 새 사유를 만들지 않는다. 동사 자체의 경과와 회차가
# 끝나기까지의 경과를 따로 잰다: 동사는 회차를 기다리지 않고, 회차는 타임아웃 덕에 멈춤보다
# 먼저 끝난다. 멈춤(6초)을 타임아웃(1초)과 게이트 자신의 기동 시간을 더한 것보다 넉넉히 길게
# 두어, 회차 경과가 멈춤보다 짧다는 단언이 타임아웃 말고는 설명되지 않게 한다.
fresh; round T3/review
printf '6\n' > "$WORK/gh-sleep/issue-list"
t0=$SECONDS
( export CC_METRICS_GH_TIMEOUT_S=1; snap_nowait )
el_call=$((SECONDS - t0))
wait_round
el=$((SECONDS - t0))
check "8b: (선행) 멈춘 조회가 실제로 불렸다" "$(ghcount '| issue list ')" "1"
check "8b: 멈춘 조회가 있어도 게이트 동사는 멈춤보다 먼저 돌아온다" "$([ "$el_call" -lt 6 ] && printf 예 || printf "아니오(${el_call}초)")" "예"
check "8b: 멈춘 조회는 끊겨 회차가 멈춤보다 먼저 끝난다" "$([ "$el" -lt 6 ] && printf 예 || printf "아니오(${el}초)")" "예"
check "8b: 끊긴 조회는 조회 실패 건너뜀 행을 남긴다" "$(field "$(skip_rows)" '사유')" "조회 실패"
check "8b: 끊긴 조회 뒤에는 등록하지 않는다" "$(ghcount '| issue create ')" "0"
fresh; round T3/review
printf '6\n' > "$WORK/gh-sleep/issue-create"
t0=$SECONDS
( export CC_METRICS_GH_TIMEOUT_S=1; snap_nowait )
el_call=$((SECONDS - t0))
wait_round
el=$((SECONDS - t0))
check "8b: (선행) 멈춘 등록이 실제로 불렸다" "$(ghcount '| issue create ')" "1"
check "8b: 멈춘 등록이 있어도 게이트 동사는 멈춤보다 먼저 돌아온다" "$([ "$el_call" -lt 6 ] && printf 예 || printf "아니오(${el_call}초)")" "예"
check "8b: 멈춘 등록은 끊겨 회차가 멈춤보다 먼저 끝난다" "$([ "$el" -lt 6 ] && printf 예 || printf "아니오(${el}초)")" "예"
check "8b: 끊긴 등록은 조회 실패 건너뜀 행을 남긴다" "$(field "$(skip_rows)" '사유')" "조회 실패"
check "8b: 끊긴 등록은 필링 행을 남기지 않는다" "$(nrows "$(file_rows)")" "0"

# --- 8c. 분리 회차 · 기한 · 난스 ------------------------------------------------------------
# 동사는 회차를 기다리지 않는다. 수집기가 5초 걸려도 동사는 곧바로 돌아오고, 그때 잠금은
# 아직 회차가 쥐고 있으며, 회차가 끝나면 필링은 동기로 돌던 때와 같다.
fresh; round T3/review
before=$(calls)
export CC_STUB_SLEEP=5
t0=$SECONDS
snap_nowait
el_call=$((SECONDS - t0))
lock_after=$([ -d "$STATE_ROOT/.metrics.lock" ] && printf 있음 || printf 없음)
wait_round
unset CC_STUB_SLEEP
check "8c: 수집기가 오래 걸려도 게이트 동사는 곧바로 돌아온다" "$([ "$el_call" -lt 3 ] && printf 예 || printf "아니오(${el_call}초)")" "예"
check "8c: 동사가 돌아왔을 때 잠금은 아직 회차가 쥐고 있다" "$lock_after" "있음"
check "8c: 분리 회차가 수집기를 한 번 부른다" "$(( $(calls) - before ))" "1"
check "8c: 분리 회차가 끝나면 잠금이 풀린다" "$([ -d "$STATE_ROOT/.metrics.lock" ] && printf 있음 || printf 없음)" "없음"
check "8c: 분리 회차의 등록은 issue create 한 번이다" "$(ghcount '| issue create ')" "1"
check "8c: 분리 회차도 등록 필링 행을 남긴다" "$(field "$(file_rows)" '결정')" "등록"

# 기한이 수집기를 끊는다. 끊긴 수집기는 실패한 수집기와 같은 갈래를 타고(rc 143), 잠금은
# 풀리며, 필링은 없다. 수집기의 남은 자식이 출력을 쥐고 있어도 회차는 기다리지 않는다 —
# 회차 경과가 멈춤(5초)보다 짧다는 단언이 그것을 잰다.
fresh; round T3/review
before=$(calls)
lb=$(grep -c -F '계측 회차 실패 — 수집기 rc=143' "$ROUND_LOG" 2>/dev/null || true)
t0=$SECONDS
( export CC_METRICS_ROUND_TIMEOUT_S=1 CC_STUB_SLEEP=5; snap )
el=$((SECONDS - t0))
la=$(grep -c -F '계측 회차 실패 — 수집기 rc=143' "$ROUND_LOG" 2>/dev/null || true)
check "8c: (선행) 기한 사례의 수집기가 실제로 불렸다" "$(( $(calls) - before ))" "1"
check "8c: 기한을 넘긴 수집기는 rc=143 실패로 회차 로그에 남는다" "$(( ${la:-0} - ${lb:-0} ))" "1"
check "8c: 기한에 끊긴 회차는 멈춤보다 먼저 끝난다" "$([ "$el" -lt 5 ] && printf 예 || printf "아니오(${el}초)")" "예"
check "8c: 기한에 끊긴 회차는 잠금을 푼다" "$([ -d "$STATE_ROOT/.metrics.lock" ] && printf 있음 || printf 없음)" "없음"
check "8c: 기한에 끊긴 회차는 gh 를 부르지 않는다" "$(grep -c '' "$GH_LOG")" "0"
check "8c: 기한에 끊긴 회차는 필링 행도 건너뜀 행도 남기지 않는다" "$(( $(nrows "$(file_rows)") + $(nrows "$(skip_rows)") ))" "0"

# 내부 동사를 직접 부르면 잠금의 난스와 맞지 않는 한 아무것도 하지 않는다 — 잠그지 않은
# 회차를 돌리지도, 남의 잠금을 풀지도 않는다.
fresh; round T3/review
before=$(calls)
mkdir -p "$STATE_ROOT/.metrics.lock"
printf '1 %s\n' "$(date -u +%s)" > "$STATE_ROOT/.metrics.lock/owner"
printf 'the-real-nonce\n' > "$STATE_ROOT/.metrics.lock/nonce"
rc_n=0; g metrics-round --manifest "$MANIFEST" --nonce not-the-nonce || rc_n=$?
check "8c: 난스가 다른 metrics-round 직접 호출은 exit 3" "$rc_n" "3"
rc_n=0; g metrics-round --manifest "$MANIFEST" || rc_n=$?
check "8c: 난스 없는 metrics-round 직접 호출은 exit 2" "$rc_n" "2"
check "8c: 거부된 직접 호출은 수집기를 부르지 않는다" "$(( $(calls) - before ))" "0"
check "8c: 거부된 직접 호출은 남의 잠금과 난스를 그대로 둔다" "$(cat "$STATE_ROOT/.metrics.lock/nonce" 2>/dev/null)" "the-real-nonce"
check "8c: 거부된 직접 호출은 필링 행을 남기지 않는다" "$(nrows "$(file_rows)")" "0"
rm -rf "$STATE_ROOT/.metrics.lock"

# --- 10. 중단 리포트 ---------------------------------------------------------------------
# 회차는 호스트의 열린 런별 기록을 모두 걷는다. 케이스마다 정착한 기록과 그 원장을 손으로
# 두고, 분류기 스텁이 그 원장에 대해 낼 사건 줄을 정한다. 계측 회차가 끼지 않게 계측
# 스탬프는 늘 새것으로 둔다. 회차의 결과 행은 회차를 띄운 런의 원장에 남는다.
HALT_ROOT="$STATE_ROOT/halt-report"
HALT_RUNS="$HALT_ROOT/runs"
HALT_PIN=0123456789abcdef0123456789abcdef01234567
HALT_UNFILED="$REPO/docs/pipeline-run/halt-report.unfiled"
wait_halt() {
  local i=0
  while [ -d "$STATE_ROOT/.halt.lock" ]; do
    [ "$i" -lt 300 ] || { bad "중단 리포트 회차 대기" "잠금이 30초 안에 풀리지 않았다"; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
hpath() { bash -c 'CC_GATE_SOURCE_ONLY=1 . "$1" </dev/null; gate_halt_record_path "$2"' _ "$GATE" "$1"; }
hfresh() {
  # 한 중단 리포트 케이스의 시작 — 기록·사건·gh 로그·스크립트를 비운다. 신원 조회 스텁은
  # 응답 머리와 본문을 함께 내는 꼴로 바꾼다(회차는 `api -i user` 로 스코프 머리를 읽는다).
  cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true
  : > "$GH_LOG"
  rm -rf "$WORK/gh-script" "$WORK/gh-fail" "$WORK/gh-sleep" "$WORK/gh-body" "$HALT_RUNS" \
         "$WORK/halt-ev" "$HALT_UNFILED"
  mkdir -p "$WORK/gh-script" "$WORK/gh-fail" "$WORK/gh-sleep" "$WORK/halt-ev"
  printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: repo, project, read:org\r\n\r\n{"login":"tester"}\n' \
    > "$WORK/gh-script/api-user"
  printf '%s\n' "$(date -u +%s)" > "$STATE_ROOT/metrics.stamp"
  LEDGER_MARK=$(grep -c '' "$LEDGER" 2>/dev/null || printf 0)
}
hrec() {
  # hrec <런 id> — 정착한 런 하나: `run` 행 하나를 든 원장과 그 런의 기록.
  local id="$1" l="$WORK/halt-ledgers/$1.md"
  mkdir -p "$WORK/halt-ledgers" "$HALT_RUNS"
  printf -- '- `run` | run-id=%s | 시작=2026-01-01T00:00:00Z | 판본=%s\n' "$id" "$HALT_PIN" > "$l"
  jq -n --arg id "$id" --arg l "$l" \
    '{schema: "cc-halt-report-run v1", run: $id, "원장": $l, "매니페스트": "", RUN_DIR: "",
      "상태": "정착", "열림 시각": "2026-01-01T00:00:00Z", "정착 시각": "2026-01-01T01:00:00Z",
      "종결 시각": null, "정착 토큰": "종단", "사건": {}, "최종 건너뜀": null, "런 처분": "정착 대기"}' \
    > "$(hpath "$id")"
}
hev() {
  # hev <런 id> <줄…> — 그 런의 원장에 대해 분류기 스텁이 낼 사건 줄.
  local id="$1"; shift
  : > "$WORK/halt-ev/$id.md"
  local x; for x in "$@"; do printf '%s\n' "$x" >> "$WORK/halt-ev/$id.md"; done
}
U() { printf '%s\t비의도\t-\t-' "$1"; }
hround() { rm -f "$STATE_ROOT/halt.stamp"; snap_nowait; wait_halt; }
hget() { jq -r "$2" "$(hpath "$1")" 2>/dev/null; }
halt_rows() { new_rows | grep -F -e 'kind=halt-report' || true; }
hskip_rows() { new_rows | grep -F -e '- `중단 리포트 건너뜀` |' || true; }
ghlines() { grep -c '' "$GH_LOG" 2>/dev/null || true; }
cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true; : > "$GH_LOG"
HALT_ALL_MARK=$(grep -c '' "$WORK/gh.all" 2>/dev/null || printf 0)
HR1=20260202-bbbbbbbb
SIG1='stage/크래시/implement'

# 10a. 새 서명 → 등록과 autopilot Project 담기.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
hround
check "10a: 새 서명은 issue create 한 번이다" "$(ghcount '| issue create ')" "1"
check "10a: 제목은 [cc-halt] 와 서명이다" "$(grep -c -F -- "--title [cc-halt] $SIG1 " "$GH_LOG")" "1"
check "10a: 라벨 cc-halt 가 붙는다" "$(grep -F '| issue create ' "$GH_LOG" | grep -c -F -- '--label cc-halt')" "1"
check "10a: autopilot Project 에 담는다" \
  "$(grep -c -F -- '| project item-add 1 --owner Nharu --url https://github.com/Nharu/cc-cmds/issues/42' "$GH_LOG")" "1"
check "10a: 열린 이슈 조회는 --limit 1000 으로 연 것만 본다" \
  "$(grep -F '| issue list ' "$GH_LOG" | grep -F -- '--label cc-halt' | grep -F -- '--state open' | grep -c -F -- '--limit 1000')" "1"
check "10a: 열린 이슈 조회는 읽기 자격으로 한다" "$(grep -F '| issue list ' "$GH_LOG" | cut -d' ' -f1)" "읽기"
check "10a: 등록은 쓰기 자격으로 한다" "$(grep -F '| issue create ' "$GH_LOG" | cut -d' ' -f1)" "쓰기"
check "10a: 신원·스코프 조회는 응답 머리를 받는다" "$(ghcount '| api -i user')" "1"
ln_label=$(grep -n -F '| label create cc-halt ' "$GH_LOG" | cut -d: -f1 | sed -n '1p')
ln_create=$(grep -n -F '| issue create ' "$GH_LOG" | cut -d: -f1 | sed -n '1p')
check "10a: 라벨 보장이 첫 생성보다 먼저다" \
  "$([ "${ln_label:-0}" -gt 0 ] && [ "${ln_label:-0}" -lt "${ln_create:-0}" ] && printf 예 || printf 아니오)" "예"
hr=$(halt_rows)
check "10a: 리포트 행이 하나 남는다" "$(nrows "$hr")" "1"
check "10a: 리포트 행의 결정은 등록이다" "$(field "$hr" '결정')" "등록"
check "10a: 리포트 행의 담기는 성공이다" "$(field "$hr" '담기')" "성공"
check "10a: 리포트 행은 멈춘 런과 서명과 이슈를 싣는다" \
  "$(field "$hr" '런')|$(field "$hr" '서명')|$(field "$hr" '이슈')" "$HR1|$SIG1|42"
check "10a: 리포트 행의 되돌리는 법은 그 이슈를 닫는 명령이다" "$(field "$hr" '되돌리는 법')" "gh issue close 42 --repo Nharu/cc-cmds"
check "10a: 기록은 종결되고 런 처분은 등록 #42 다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "종결/등록 #42"
check "10a: 본문은 서명·런·판본을 싣는다" \
  "$(grep -c -F -e "- 서명: \`$SIG1\`" -e "- 런: \`$HR1\`" -e "- 판본: \`$HALT_PIN\`" "$WORK/gh-body" 2>/dev/null)" "3"
check "10a: 본문은 로컬 절대 경로를 싣지 않는다" "$(grep -c -F -e "$WORK" -e "$WT" "$WORK/gh-body" 2>/dev/null)" "0"
check "10a: 본문은 체크아웃 디렉터리 이름을 싣지 않는다" "$(grep -c -F 'acme-private-checkout' "$WORK/gh-body" 2>/dev/null)" "0"
n_gh=$(ghlines)
hround
check "10a: 종결된 기록은 다음 회차에 gh 를 부르지 않는다" "$(ghlines)" "$n_gh"

# 10b. 같은 제목의 열린 이슈가 있으면 가장 작은 번호에 코멘트한다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
printf '[{"number":9,"title":"[cc-halt] %s"},{"number":5,"title":"[cc-halt] %s"},{"number":3,"title":"[cc-halt] 다른/서명"}]\n' \
  "$SIG1" "$SIG1" > "$WORK/gh-script/issue-list"
hround
check "10b: 열린 같은 제목에는 가장 작은 번호로 코멘트한다" "$(ghcount '| issue comment 5 ')" "1"
check "10b: 코멘트할 때는 등록하지 않는다" "$(ghcount '| issue create ')" "0"
check "10b: 코멘트도 그 이슈를 Project 에 담는다" "$(ghcount '| project item-add 1 --owner Nharu --url https://github.com/Nharu/cc-cmds/issues/5')" "1"
hr=$(halt_rows)
check "10b: 리포트 행의 결정은 코멘트다" "$(field "$hr" '결정')" "코멘트"
check "10b: 코멘트 행의 되돌리는 법은 마지막 코멘트를 지우는 명령이다" "$(field "$hr" '되돌리는 법')" "gh issue comment 5 --repo Nharu/cc-cmds --delete-last"
check "10b: 런 처분은 코멘트 #5 다" "$(hget "$HR1" '.["런 처분"]')" "코멘트 #5"

# 10c. 조회는 열린 이슈만 본다 — 같은 제목이 닫힌 이슈뿐이면 목록이 비고, 빈 목록은
# 조회 실패가 아니라 새 등록으로 간다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
printf '[]\n' > "$WORK/gh-script/issue-list"
hround
check "10c: 빈 열린 목록이면 새 이슈를 만든다" "$(ghcount '| issue create ')" "1"
check "10c: 빈 목록은 조회 실패 건너뜀 행을 남기지 않는다" "$(nrows "$(hskip_rows)")" "0"

# 10d. 의도된 대기만 열린 런 → gh 0회, 대상 아님 행.
hfresh; hrec "$HR1"; hev "$HR1" "$(printf 'approval/판단\t의도\t설계 판단\t-')"
hround
check "10d: 의도된 대기만 있으면 gh 를 부르지 않는다" "$(ghlines)" "0"
sr=$(hskip_rows)
check "10d: 대상 아님 건너뜀 행이 하나 남는다" "$(nrows "$sr")|$(field "$sr" '사유')" "1|대상 아님"
check "10d: 그 행은 런과 서명을 싣고 세그먼트는 - 다" \
  "$(field "$sr" '런')|$(field "$sr" '서명')|$(field "$sr" '세그먼트')" "$HR1|approval/판단|-"
check "10d: 런 처분은 대상 아님과 그 제외 사유다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "종결/대상 아님:설계 판단"

# 10e. B4 종료 행으로 끝난 런 — 결정이지 대기가 아니므로 건너뜀 행도 없다.
hfresh; hrec "$HR1"; hev "$HR1" "$(printf 'approval/경계/B4\t의도\t비용 천장\t열린 대기 아님')"
hround
check "10e: B4 종료로 끝난 런은 gh 를 부르지 않는다" "$(ghlines)" "0"
check "10e: B4 종료로 끝난 런은 건너뜀 행을 남기지 않는다" "$(nrows "$(hskip_rows)")" "0"

# 10f. 사건 0건 · 열린 대기 0건.
hfresh; hrec "$HR1"
hround
check "10f: 사건이 없는 런은 gh 를 부르지 않는다" "$(ghlines)" "0"
check "10f: 사건이 없는 런은 원장 행을 남기지 않는다" "$(nrows "$(new_rows | grep -F -e 'kind=halt-report' -e '`중단 리포트 건너뜀`' || true)")" "0"
check "10f: 사건이 없는 런은 대상 없음으로 종결된다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "종결/대상 없음"

# 10g. 쓰기 자격이 없다 → gh 0회, 자격 없음 최종 처분, 다음 회차에 다시 보지 않는다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
( export CC_GATE_TOKEN_RW="" CC_GATE_KEYCHAIN="cc-cmds-no-such-keychain-$$"; hround )
check "10g: 쓰기 자격이 없으면 gh 를 부르지 않는다" "$(ghlines)" "0"
check "10g: 자격 없음 건너뜀 행이 남는다" "$(field "$(hskip_rows)" '사유')" "자격 없음"
check "10g: 기록은 종결되고 최종 건너뜀이 자격 없음이다" "$(hget "$HR1" '.["상태"] + "/" + .["최종 건너뜀"]')" "종결/자격 없음"
hround
check "10g: 다음 회차는 같은 런을 다시 시도하지 않는다" "$(ghlines)|$(nrows "$(hskip_rows)")" "0|1"

# 10h. 스코프 머리에 project 가 없다 → 스코프 부족, 생성 0회. 머리가 없으면(세분 토큰)
# 미리 거절하지 않고 시도한다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
printf 'HTTP/2.0 200 OK\r\nx-oauth-scopes: repo\r\n\r\n{"login":"tester"}\n' > "$WORK/gh-script/api-user"
hround
check "10h: project 스코프가 없으면 스코프 부족이다" "$(field "$(hskip_rows)" '사유')" "스코프 부족"
check "10h: 스코프 부족이면 등록하지 않는다" "$(ghcount '| issue create ')" "0"
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
printf 'HTTP/2.0 200 OK\r\n\r\n{"login":"tester"}\n' > "$WORK/gh-script/api-user"
hround
check "10h: 스코프 머리가 없으면 생성을 시도한다" "$(ghcount '| issue create ')" "1"

# 10i. 신원 조회 실패 → 회차마다 조회 실패 행 하나, 세 번 뒤에는 시도하지 않는다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
: > "$WORK/gh-fail/api-user"
hround; hround; hround
check "10i: 세 회차가 조회 실패 행 셋을 남긴다" \
  "$(hskip_rows | grep -c -F '| 사유=조회 실패 |')" "3"
check "10i: 세 번 실패한 사건은 종결된다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "종결/건너뜀:조회 실패"
n_gh=$(ghlines)
hround
check "10i: 넷째 회차는 시도하지 않는다" "$(ghlines)|$(hskip_rows | grep -c -F '| 사유=조회 실패 |')" "$n_gh|3"

# 10j. 담기 실패 → 실패 행과 미담기 산출물, 다음 회차는 행 없이 담기만 다시 하고, 세 번
# 실패하면 포기한다.
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
: > "$WORK/gh-fail/project-item-add"
hround
hr=$(halt_rows)
check "10j: 담기만 실패해도 등록 행은 남고 담기=실패다" "$(field "$hr" '결정')|$(field "$hr" '담기')" "등록|실패"
check "10j: 미담기 산출물에 담는 명령이 적힌다" \
  "$(grep -c -F 'gh project item-add 1 --owner Nharu --url https://github.com/Nharu/cc-cmds/issues/42' "$HALT_UNFILED/42.md" 2>/dev/null || printf 0)" "1"
check "10j: 기록의 담기는 실패:1 이다" "$(hget "$HR1" ".[\"사건\"][\"$SIG1\"][\"담기\"]")" "실패:1"
hround
check "10j: 담기 재시도는 새 원장 행을 쓰지 않는다" "$(nrows "$(halt_rows)")" "1"
check "10j: 담기 재시도는 이슈를 다시 만들지 않는다" "$(ghcount '| issue create ')" "1"
check "10j: 두 번째 실패는 실패:2 다" "$(hget "$HR1" ".[\"사건\"][\"$SIG1\"][\"담기\"]")" "실패:2"
hround
check "10j: 세 번째 실패는 포기다" "$(hget "$HR1" ".[\"사건\"][\"$SIG1\"][\"담기\"]")" "포기"
check "10j: 포기한 런 처분은 담기=포기 #42 다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "종결/담기=포기 #42"
n_add=$(ghcount '| project item-add ')
hround
check "10j: 포기 뒤에는 담기를 다시 시도하지 않는다" "$(ghcount '| project item-add ')" "$n_add"
hfresh; hrec "$HR1"; hev "$HR1" "$(U "$SIG1")"
: > "$WORK/gh-fail/project-item-add"
hround
rm -f "$WORK/gh-fail/project-item-add"
hround
check "10j: 다음 회차에 담기가 되면 기록의 담기만 성공으로 바뀐다" \
  "$(hget "$HR1" ".[\"사건\"][\"$SIG1\"][\"담기\"]")|$(nrows "$(halt_rows)")" "성공|1"

# 10k. 회차당 쓰기 8건 — 사건 하나가 생성·담기 두 건이므로 다섯째 사건은 미룸이 되고 다음
# 회차에 처리된다.
hfresh; hrec "$HR1"
hev "$HR1" "$(U 'stage/크래시/implement')" "$(U 'stage/크래시/review')" "$(U 'stage/외부 종료/design')" \
  "$(U 'halt/gate-unanswerable/implement')" "$(U 'run-blocked/라이브니스 침묵')"
hround
check "10k: 한 회차의 등록은 넷에서 멈춘다" "$(ghcount '| issue create ')" "4"
check "10k: 다섯째 사건은 미룸이다" "$(hget "$HR1" '.["사건"]["run-blocked/라이브니스 침묵"]["처분"]')" "미룸"
check "10k: 미룸이 남은 런 처분은 미룸 1건이다" "$(hget "$HR1" '.["상태"] + "/" + .["런 처분"]')" "정착/미룸 1건"
hround
check "10k: 미룬 사건은 다음 회차에 등록된다" "$(ghcount '| issue create ')" "5"
check "10k: 다섯이 다 처리되면 기록이 종결된다" "$(hget "$HR1" '.["상태"]')" "종결"

# 10l. 공개 본문은 허용 목록만 — 형식 밖 런 id 는 본문에 실리지 않는다. 파일 이름으로
# 쓸 수 없는 런 id 의 기록은 안전한 이름으로 둔다.
hfresh; hrec R1; hev R1 "$(U "$SIG1")"
hround
check "10l: 형식 밖 런 id 는 본문에 (형식 외) 로 실린다" "$(grep -c -F -- '- 런: `(형식 외)`' "$WORK/gh-body" 2>/dev/null)" "1"
check "10l: 형식 밖 런 id 원문은 본문에 없다" "$(grep -c -F -- '`R1`' "$WORK/gh-body" 2>/dev/null)" "0"
check "10l: 파일 이름으로 안전한 런 id 는 그 이름으로 둔다" "$(basename "$(hpath R1)")" "R1.json"
check "10l: 파일 이름으로 쓸 수 없는 런 id 는 해시 앞 16자로 둔다" \
  "$(basename "$(hpath 'a/b c')" | grep -c -E '^[0-9a-f]{16}\.json$')" "1"

# 10m. 플릿 백로그 park — 기준선 회차는 등록하지 않고, 그 뒤 새로 park 된 id 는 다섯
# 사유 각각 한 번씩 등록되고 담긴다. 쓰기 상한 때문에 두 회차에 걸친다.
hfresh
rm -f "$HALT_ROOT/fleet.seen" "$HALT_ROOT/fleet.pending"
BL="$WORK/backlog.jsonl"
printf '{"schema":"cc-pace-backlog v1","id":"p0","status":"parked","park_reason":"doc-changed"}\n' > "$BL"
( export CC_HALT_BACKLOG="$BL"; hround )
check "10m: 기준선 회차는 gh 를 부르지 않는다" "$(ghlines)" "0"
check "10m: 기준선은 그때 park 된 id 를 적는다" "$(cat "$HALT_ROOT/fleet.seen" 2>/dev/null)" "p0"
n=1
for r in manifest-missing clock-incoherent deadline-passed doc-changed base-moved; do
  printf '{"schema":"cc-pace-backlog v1","id":"p%s","status":"parked","park_reason":"%s"}\n' "$n" "$r" >> "$BL"
  n=$((n + 1))
done
( export CC_HALT_BACKLOG="$BL"; hround; hround )
for r in manifest-missing clock-incoherent deadline-passed doc-changed base-moved; do
  check "10m: 백로그 park $r 는 한 번 등록된다" "$(grep -c -F -- "--title [cc-halt] backlog-park/$r " "$GH_LOG")" "1"
done
check "10m: 백로그 park 다섯이 모두 담긴다" "$(ghcount '| project item-add 1 --owner Nharu ')" "5"
check "10m: 처리된 id 는 모두 seen 에 오른다" "$(sort "$HALT_ROOT/fleet.seen" | tr '\n' ' ')" "p0 p1 p2 p3 p4 p5 "
check "10m: 백로그 리포트 행의 런은 - 다" "$(halt_rows | grep -v -c -F '| 런=- |')" "0"
check "10m: 백로그 본문의 런은 (형식 외) 다" "$(grep -c -F -- '- 런: `(형식 외)`' "$WORK/gh-body" 2>/dev/null)" "1"

# 10n. 중단 리포트 케이스 전체를 가로지르는 불변.
cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true; : > "$GH_LOG"
halt_all=$(sed -n "$((HALT_ALL_MARK + 1)),\$p" "$WORK/gh.all")
check "10n: (선행) 중단 리포트 케이스의 gh 호출이 모였다" "$([ -n "$halt_all" ] && printf 있음 || printf 없음)" "있음"
check "10n: 중단 리포트는 이슈를 닫지도 다시 열지도 않는다" \
  "$(printf '%s\n' "$halt_all" | grep -c -F -e '| issue close' -e '| issue reopen')" "0"
check "10n: 이슈·라벨 호출은 모두 목적지 레포를 명시한다" \
  "$(printf '%s\n' "$halt_all" | grep -E '\| (issue|label) ' | grep -v -c -F -- '--repo Nharu/cc-cmds')" "0"
check "10n: 체크아웃 이름은 어느 argv 에도 없다" "$(printf '%s\n' "$halt_all" | grep -c -F 'acme-private-checkout')" "0"
check "10n: 체크아웃 이름과 로컬 경로는 어느 본문에도 없다" \
  "$(grep -c -F -e 'acme-private-checkout' -e "$WORK" "$WORK/gh-bodies.all" 2>/dev/null)" "0"
bad_reason=$(grep -F -e '- `중단 리포트 건너뜀` |' "$LEDGER" | sed -n 's/.*| 사유=\([^|]*\) |.*/\1/p' | sed 's/ *$//' \
  | grep -v -x -e '대상 아님' -e '자격 없음' -e '스코프 부족' -e '조회 실패' || true)
check "10n: 건너뜀 행의 사유는 닫힌 넷 안에만 있다" "$bad_reason" ""
check "10n: 리포트 행과 건너뜀 행 어디에도 판단 부류가 없다" \
  "$(grep -e '- `중단 리포트 건너뜀` |' -e 'kind=halt-report' "$LEDGER" | grep -c -F '판단 부류=')" "0"
check "10n: 리포트 행과 건너뜀 행 어디에도 행위자가 없다" \
  "$(grep -e '- `중단 리포트 건너뜀` |' -e 'kind=halt-report' "$LEDGER" | grep -c -F '| 행위자=')" "0"
check "10n: 아침 보고서 렌더링 열거에 중단 리포트 항목이 한 번 있다" \
  "$(grep -c -F -- '- **중단 리포트** —' "$SKILL")" "1"

# --- 9. 전 케이스를 가로지르는 불변 ---------------------------------------------------
cat "$GH_LOG" >> "$WORK/gh.all" 2>/dev/null || true
check "9: (선행) 케이스 전체의 gh 호출이 모였다" "$([ -s "$WORK/gh.all" ] && printf 있음 || printf 없음)" "있음"
check "9: gh issue reopen 은 어디서도 부르지 않았다" "$(grep -c -F '| issue reopen' "$WORK/gh.all")" "0"
check "9: gh auth 는 어디서도 부르지 않았다" "$(grep -c -F '| auth ' "$WORK/gh.all")" "0"
check "9: (선행) gh 호출마다 환경이 기록됐다" "$([ -s "$WORK/gh-env.log" ] && printf 있음 || printf 없음)" "있음"
check "9: 목적지를 옮기는 환경 변수는 어느 gh 호출에도 새지 않았다" \
  "$(grep -v -c -x 'GH_REPO= GH_HOST= GH_ENTERPRISE_TOKEN=' "$WORK/gh-env.log")" "0"
check "9: PATH 앞의 미끼 gh 는 어디서도 불리지 않았다(게이트는 이음매로 gh 를 찾는다)" \
  "$([ -s "$GH_DECOY_LOG" ] && printf 불림 || printf 안불림)" "안불림"
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
