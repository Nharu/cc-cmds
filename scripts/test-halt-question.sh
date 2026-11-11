#!/usr/bin/env bash
# 좌석 질문 렌더 도우미(halt-question.sh) — 긴 중단 기록이 질문 칸에 들고, 원문은 본문에 그대로 남는가.
#
# 이 스위트가 있는 이유. 좌석은 중단 기록의 질문을 질문 다이얼로그에 넣는데, 질문 칸은 한 줄에
# 정해진 분량만 보인다. 도우미는 질문 칸에 상한 안의 문장을, 본문에 원문 전체를 문단으로 나눠
# 낸다. 단언은 합성 기록마다 「질문이 상한 안의 한 줄인가」, 「어느 갈래(원문·요지·대체)를
# 탔는가」, 「선택지가 기록과 바이트 동일한가」, 「본문의 원문 부분이 공백만 다른가」를 본다.
# 도우미가 접는 규칙이 게이트의 질문 판독과 같은지는 게이트 정의를 들여오는
# test-waiting-decisions.sh 가 본다. 이 스위트는 게이트 계열을 부르지 않는다.
#
# 픽스처는 모두 이 스크립트 안에서 만드는 합성 기록이다(일반 문구와 example.invalid 주소만).
#
# Usage: bash scripts/test-halt-question.sh
#        bash scripts/test-halt-question.sh --record <기록 경로>   — 주어진 기록을 렌더해 출력하고
#                                                               분량·갈래·선택지 단언만 돌린다

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HQ="$repo_root/plugins/cc-cmds/orchestrator/halt-question.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-halt-question-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# 도우미는 기록의 절대 경로를 디렉터리에서 다시 구한다 — TMPDIR 끝의 / 가 겹친 꼴을 맞춰 둔다.
WORK=$(cd "$WORK" && pwd)

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
truthy() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

MAX=200
MORE='…(본문에 이어짐)'

cpn() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }
nows() { printf '%s' "$1" | tr -d ' \t\r\n'; }
has() { case "$2" in *"$1"*) printf 1 ;; *) printf 0 ;; esac; }

OUT=''; rc=0
render() { OUT=$(bash "$HQ" render --record "$1" 2>"$WORK/err"); rc=$?; }
jqv() { printf '%s' "$OUT" | jq -r "$1"; }

qpart() {
  # 본문의 질문 원문 부분 — `**질문 원문**` 줄 다음부터 다음 부분의 머리 앞까지, 빈 줄 뺀 문단들.
  printf '%s\n' "$(jqv .body)" | awk '
    $0 == "**질문 원문**" { on = 1; next }
    on && (index($0, "**선택지 리스크**") == 1 || $0 == "**질문 뒤 인용 줄**" || index($0, "기록: ") == 1) { exit }
    on && $0 != "" { print }'
}

record_option_lines() {
  # 기록의 선택지 블록 줄 — `**선택지**:` 줄부터 다음 `**` 줄 또는 닫는 울타리 앞까지.
  LC_ALL=C awk '
    $0 == "<!-- /cc-pipeline-halt v1 -->" { exit }
    inb && /^\*\*/ { inb = 0 }
    /^\*\*선택지\*\*:[ \t]*$/ { inb = 1; next }
    inb && /^- `[^`]+`/ { print }' "$1"
}

json_option_lines() {
  # 출력의 선택지를 기록의 줄 꼴로 되돌린 것.
  jqv '.options[] | if .description == "" then "- `" + .label + "`" else "- `" + .label + "` — " + .description end'
}

assert_shape() {
  # assert_shape <제목> <기록> — 분량, 갈래, 선택지 바이트 동일 (실측 기록 재연에도 쓴다).
  local t="$1" f="$2" q name
  q=$(jqv .question)
  name=$(basename "$f"); name=${name%.md}
  check "$t: exit 0" "$rc" "0"
  truthy "$t: question 이 ${MAX} 코드포인트 이하" "$([ "$(cpn "$q")" -le "$MAX" ] && echo 1)" "$(cpn "$q") 코드포인트"
  check "$t: question 에 줄바꿈이 없다" "$(printf '%s' "$q" | wc -l | tr -d ' ')" "0"
  case "$(jqv .source)" in
    원문) ok "$t: 원문 갈래" ;;
    요지|대체) check "$t: question 이 [$name] 으로 시작한다" "$(has "[$name] " "${q:0:$((${#name} + 3))}")" "1" ;;
    *) bad "$t: source 가 셋 중 하나" "$(jqv .source)" ;;
  esac
  check "$t: 선택지 라벨과 설명이 기록과 바이트 동일하고 차례도 같다" "$(json_option_lines)" "$(record_option_lines "$f")"
}

if [ "${1:-}" = "--record" ]; then
  [ -n "${2:-}" ] && [ -f "$2" ] || { printf 'usage: test-halt-question.sh --record <기록 경로>\n' >&2; exit 2; }
  render "$2"
  printf '%s\n' "$OUT"
  assert_shape "기록 재연" "$2"
  printf '\n%d passed, %d failed\n' "$passed" "$failed"
  [ "$failed" = "0" ]
  exit
fi

# --- 픽스처 -----------------------------------------------------------------------
mk() {
  # mk <파일> <스킬> <스텝> <요지|-> <질문 문면> <선택지 줄|''> <리스크|-> [질문 뒤 줄] [fence|nofence]
  local f="$WORK/$1"
  {
    printf '<!-- cc-pipeline-halt v1; writer=stage; reader=orchestrator; stage=%s; run=20990101-hq000001 -->\n' "${1%.md}"
    printf '**중단 시각**: 2099-01-01T00:00:00Z\n**스킬**: %s\n**스텝**: %s\n**분류**: gate-unanswerable\n' "$2" "$3"
    [ "$4" = "-" ] || printf '**판정 요지**: %s\n' "$4"
    printf '**질문 문면**: %s\n' "$5"
    [ -z "${8:-}" ] || printf '%s\n' "$8"
    if [ -n "$6" ]; then
      printf '**선택지**:\n%s\n' "$6"
      printf '**추천**: (없음) — 화면이 맞는지는 화면을 본 사람만 판정한다\n**추천 근거**: (없음)\n'
    fi
    [ "$7" = "-" ] || printf '**선택지 리스크**: %s\n' "$7"
    printf '**하네스 오류**: (없음)\n**관측 상세**: (없음)\n**재호출 명령**: (없음)\n**후속**: 보류 큐\n'
    [ "${9:-fence}" = "nofence" ] || printf '<!-- /cc-pipeline-halt v1 -->\n'
  } > "$f"
  printf '%s' "$f"
}

URL1='https://example.invalid/canvas/p1'
LONGQ="캔버스 $URL1 과 https://example.invalid/canvas/p2 를 확인합니다. $(for i in $(seq 1 80); do printf '화면 %d 에서 규칙 token-block 발견이 남았고 사소 발견도 함께 확인했습니다. ' "$i"; done)"
LONGQ=${LONGQ% }
VOPTS='- `승인` — 기계 검사 발견을 그대로 받아들이고 구현 승인을 씁니다
- `수정 요청` — 댓글을 입력으로 다시 만들어 같은 주소에 새 판을 발행합니다
- `거부` — 아무것도 쓰지 않고 화면 슬라이스를 묶어 둡니다
- `디자인 시스템 다시 열기` — 디자인 시스템 수정 요청으로 돌아갑니다'
VRISK='`승인` — 남은 발견이 그대로 구현에 들어갑니다 / `수정 요청` — 한 판을 더 만들어 시간이 듭니다 / `거부` — 화면 슬라이스가 이 런에서 착지하지 않습니다 / `디자인 시스템 다시 열기` — 다른 문서의 구현 승인이 무효가 됩니다'

# --- 1. 옛 형식 긴 기록 -----------------------------------------------------------
check "1: 픽스처 질문 문면이 2,085 코드포인트 이상" "$([ "$(cpn "$LONGQ")" -ge 2085 ] && echo 1)" "1"
mkdir -p "$WORK/c1"
F1=$(mk 'c1/S2P#5.md' visual-publish-unattended '시각-판정 — 판 5' - "$LONGQ" "$VOPTS" "$VRISK")
render "$F1"
assert_shape "1" "$F1"
Q1=$(jqv .question)
check "1: source 가 대체" "$(jqv .source)" "대체"
check "1: [S2P#5] 로 시작한다" "${Q1:0:8}" "[S2P#5] "
check "1: 시각-판정 대체 문장을 담는다" "$(has '캔버스의 화면을 구현 기준으로 승인할지 판정합니다' "$Q1")" "1"
check "1: 첫 주소를 담는다" "$(has "— 주소: $URL1 " "$Q1")" "1"
check "1: 둘째 주소는 담지 않는다" "$(has 'canvas/p2' "$Q1")" "0"
check "1: header 는 기록 이름" "$(jqv .header)" "S2P#5"
want_pv=$(printf '%s\n' '남은 발견이 그대로 구현에 들어갑니다' '한 판을 더 만들어 시간이 듭니다' '화면 슬라이스가 이 런에서 착지하지 않습니다' '다른 문서의 구현 승인이 무효가 됩니다')
check "1: 각 preview 가 그 라벨의 리스크 조각과 같다" "$(jqv '.options[].preview')" "$want_pv"
B1=$(jqv .body)
check "1: 본문에 추천 근거 줄이 있다" "$(printf '%s\n' "$B1" | grep -cxF '**추천 근거**: (없음)')" "1"
check "1: 본문에 추천 줄이 있다" "$(printf '%s\n' "$B1" | grep -cxF '**추천**: (없음) — 화면이 맞는지는 화면을 본 사람만 판정한다')" "1"
check "1: 본문 첫 줄은 도우미가 만든 판정 요지" "$(printf '%s\n' "$B1" | sed -n '1p')" "**판정 요지**(기록에 없어 좌석 도우미가 만든 문장): 캔버스의 화면을 구현 기준으로 승인할지 판정합니다 — 주소: $URL1"
P1=$(qpart)
truthy "1: 본문의 질문 원문 부분이 두 문단 이상" "$([ "$(printf '%s\n' "$P1" | grep -c .)" -ge 2 ] && echo 1)" "$(printf '%s\n' "$P1" | grep -c .) 문단"
check "1: 공백을 지운 원문 부분이 공백을 지운 질문 문면과 같다" "$(nows "$P1")" "$(nows "$LONGQ")"
check "1: 본문의 리스크는 라벨마다 한 줄" "$(printf '%s\n' "$B1" | grep -c '^- `[^`]*` — ')" "4"
check "1: 본문 끝은 기록의 절대 경로" "$(printf '%s\n' "$B1" | tail -1)" "기록: $F1"

# --- 2. 새 형식 긴 기록 -----------------------------------------------------------
GIST150=$(printf '판정 요지 문장%.0s' $(seq 1 18))
GIST150="${GIST150}가나다라마바"
check "2: 픽스처 요지는 150 코드포인트" "$(cpn "$GIST150")" "150"
mkdir -p "$WORK/c2"
F2=$(mk 'c2/S2P#5.md' visual-publish-unattended '시각-판정' "$GIST150" "$LONGQ" "$VOPTS" "$VRISK")
render "$F2"
assert_shape "2" "$F2"
check "2: question 이 [S2P#5] <요지> 와 바이트 동일" "$(jqv .question)" "[S2P#5] $GIST150"
check "2: source 가 요지" "$(jqv .source)" "요지"
check "2: 본문 첫 줄은 기록의 요지 줄" "$(jqv .body | sed -n '1p')" "**판정 요지**: $GIST150"

# --- 3. 너무 긴 요지 --------------------------------------------------------------
GIST250=$(printf '가나다라마바사아자차%.0s' $(seq 1 25))
mkdir -p "$WORK/c3"
F3=$(mk 'c3/S2P#5.md' visual-publish-unattended '시각-판정' "$GIST250" "$LONGQ" "$VOPTS" "$VRISK")
render "$F3"
Q3=$(jqv .question)
truthy "3: question 이 상한 이하" "$([ "$(cpn "$Q3")" -le "$MAX" ] && echo 1)" "$(cpn "$Q3")"
check "3: 끝이 $MORE" "$(has "$MORE" "${Q3: -${#MORE}}")" "1"
check "3: 본문 첫 부분에 요지 전체가 있다" "$(jqv .body | sed -n '1p')" "**판정 요지**: $GIST250"

# --- 4. 짧은 한 줄 기록 -----------------------------------------------------------
SHORTQ='짧은 질문입니다 — 계속할까요?'
F4=$(mk 'S4#1.md' implement-unattended 'Step 3 검사' - "$SHORTQ" '- `계속` — 다음 단계로 갑니다
- `중단` — 세그먼트를 park 합니다' '`계속` — 시간이 듭니다 / `중단` — 일이 빠집니다')
render "$F4"
assert_shape "4" "$F4"
check "4: question 이 질문 문면과 바이트 동일" "$(jqv .question)" "$SHORTQ"
check "4: source 가 원문" "$(jqv .source)" "원문"
check "4: 본문에 질문 원문 부분이 없다" "$(has '**질문 원문**' "$(jqv .body)")" "0"
check "4: 본문에 판정 요지 줄이 없다" "$(has '판정 요지' "$(jqv .body)")" "0"

# --- 5. 짧은 여러 줄 기록 (결정 수거 꼴) -------------------------------------------
F5=$(mk 'S5#1.md' implement-unattended 'Step 3 검사' - '두 항목을 닫습니다.
- 「갑」 — 추천 답: 하나
- 「을」 —   추천 답: 둘

답은 첨부에 적습니다.' '- `계속` — 다음 단계로 갑니다
- `중단` — 세그먼트를 park 합니다' -)
render "$F5"
check "5: question 이 접은 질문 문면" "$(jqv .question)" "두 항목을 닫습니다. - 「갑」 — 추천 답: 하나 - 「을」 — 추천 답: 둘 답은 첨부에 적습니다."
check "5: source 가 원문" "$(jqv .source)" "원문"
check "5: 본문의 질문 원문 부분이 줄마다 문단이다" "$(qpart)" "두 항목을 닫습니다.
- 「갑」 — 추천 답: 하나
- 「을」 — 추천 답: 둘
답은 첨부에 적습니다."
check "5: 문단 사이는 빈 줄" "$(has "추천 답: 하나"$'\n\n'"- 「을」" "$(jqv .body)")" "1"

# --- 6. 다른 스킬의 긴 기록 -------------------------------------------------------
F6=$(mk 'S6#2.md' implement-unattended 'Step 3 게이트 도달' - "$LONGQ" '- `계속` — 다음 단계로 갑니다
- `중단` — 세그먼트를 park 합니다' -)
render "$F6"
assert_shape "6" "$F6"
check "6: 일반 대체 문장이 스킬과 스텝을 담는다" "$(has '[S6#2] implement-unattended 의 Step 3 게이트 도달 정지에 답합니다' "$(jqv .question)")" "1"

# --- 7. 선택지 없는 기록 ----------------------------------------------------------
F7=$(mk 'S7#1.md' implement-unattended 'Step 3 검사' - "$LONGQ" '' -)
render "$F7"
check "7: 종료 코드 0" "$rc" "0"
check "7: options 가 빈 목록" "$(jqv '.options | length')" "0"

# --- 8. 닫는 울타리 없는 기록 ------------------------------------------------------
F8=$(mk 'S8#1.md' implement-unattended 'Step 3 검사' - "$SHORTQ" '- `계속` — 갑니다' - '' nofence)
render "$F8"
check "8: 닫는 울타리가 없으면 종료 코드 3" "$rc" "3"
F8b="$WORK/S8#2.md"
printf '**스킬**: x\n**선택지**:\n- `계속` — 갑니다\n<!-- /cc-pipeline-halt v1 -->\n' > "$F8b"
render "$F8b"
check "8: 질문 문면이 없으면 종료 코드 3" "$rc" "3"
OUT=$(bash "$HQ" render 2>/dev/null); rc=$?
check "8: 인자 오류는 종료 코드 2" "$rc" "2"
render "$WORK/없는기록.md"
check "8: 없는 기록은 종료 코드 2" "$rc" "2"

# --- 9. --record 모드 -------------------------------------------------------------
OUT9=$(bash "$0" --record "$F1" 2>&1); rc=$?
check "9: --record 모드가 1 의 기록에서 통과한다" "$rc" "0"
check "9: --record 모드가 렌더 결과를 낸다" "$(printf '%s\n' "$OUT9" | grep -c '"source": "대체"')" "1"

# --- 10. 결정 수거 긴 기록 --------------------------------------------------------
DQ="구현 전 결정 항목 세 개가 열려 있습니다.$(printf '\n- 「항목 %s 의 표제」 — 추천 답: 이 항목은 기존 규약대로 닫습니다. 근거가 되는 문장이 설계 문서에 이미 있습니다 · 추천 근거: 설계 문서 · 닿는 슬라이스: A' 1 2 3)
답은 첨부 decision-collect-0123456789ab.answer.md 에 적습니다 — 표제마다 한 줄로 옮기고 그 아래에 결정을 적습니다."
F10=$(mk 'decision-collect-0123456789ab.md' autopilot-router-shift '결정 수거 — 구현 전 결정' - "$DQ" '- `추천대로 확정` — 추천 답으로 닫습니다
- `항목별로 답함` — 첨부의 결정으로 닫습니다' - '**미결 결정 항목**: 「### 항목 1 의 표제」, 「### 항목 2 의 표제」, 「### 항목 3 의 표제」')
render "$F10"
assert_shape "10" "$F10"
Q10=$(jqv .question)
check "10: 결정 수거 대체 문장" "$(has '구현 전 결정 항목 3개를 어떻게 닫을지 판정합니다' "$Q10")" "1"
check "10: header 는 앞 12 코드포인트" "$(jqv .header)" "decision-col"
P10=$(qpart)
truthy "10: 원문 문단 수가 질문 블록 줄 수 이상" "$([ "$(printf '%s\n' "$P10" | grep -c .)" -ge 5 ] && echo 1)" "$(printf '%s\n' "$P10" | grep -c .)"
check "10: 공백을 지운 원문 부분이 공백을 지운 질문 문면과 같다" "$(nows "$P10")" "$(nows "$DQ")"

# --- 11. 교대 정지 긴 기록 --------------------------------------------------------
mkdir -p "$WORK/shift"
F11=$(mk 'shift/S13#1.md' autopilot-router-shift '교대 정지 — 병합 거절' - "$LONGQ" '- `계속` — 다음 단계로 갑니다
- `중단` — 세그먼트를 park 합니다' -)
render "$F11"
assert_shape "11" "$F11"
check "11: 대체 문장이 스텝의 자리를 담는다" "$(has '[S13#1] 병합 거절 교대 정지를 어떻게 처리할지 판정합니다' "$(jqv .question)")" "1"

# --- 12. **확인**: 줄이 있는 기록 --------------------------------------------------
CONF='**확인**: 확인 대기 — 문서 docs/a.md
**확인**: 사람 승인 — 문서 docs/b.md'
F12=$(mk 'S2P#9.md' visual-publish-unattended '디자인-시스템-판정 — 수정 2회' - "$LONGQ 확인 형식 오류입니다." '- `승인` — 이 디자인 시스템을 씁니다
- `거부` — 멈춥니다' - "$CONF")
render "$F12"
B12=$(jqv .body)
check "12: 디자인 시스템 대체 문장(수정 회차 포함 스텝)" "$(has '디자인 시스템(팔레트와 토큰)을 승인할지 판정합니다' "$(jqv .question)")" "1"
check "12: 질문 뒤 인용 줄 머리가 있다" "$(printf '%s\n' "$B12" | grep -cxF '**질문 뒤 인용 줄**')" "1"
check "12: 확인 줄이 바이트 그대로 있다" "$(printf '%s\n' "$B12" | grep -F '**확인**: ')" "$CONF"
check "12: 공백을 지운 원문 부분은 여전히 질문 문면과 같다" "$(nows "$(qpart)")" "$(nows "$LONGQ 확인 형식 오류입니다.")"

# --- 13. 주소 끝 규칙 --------------------------------------------------------------
n=0
for tail in ')' '」' '.' '로' ',)' '`'; do
  n=$((n + 1))
  F13=$(mk "S13#$n.md" implement-unattended 'Step 3 검사' - "주소 「https://example.invalid/x$n$tail 를 봅니다. $LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' -)
  render "$F13"
  check "13: 주소 뒤 '$tail' 앞에서 주소가 끝난다" "$(has "— 주소: https://example.invalid/x$n (원문은 위 본문)" "$(jqv .question)")" "1"
done

# --- 14. 라벨이 아닌 조각이 있는 리스크 줄 ----------------------------------------
BADRISK='맨 부분 / `계속` — 시간이 듭니다 / `중단` — 일이 빠집니다'
F14=$(mk 'S14#1.md' implement-unattended 'Step 3 검사' - "$LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' "$BADRISK")
render "$F14"
check "14: preview 가 하나도 없다" "$(jqv '[.options[] | select(has("preview"))] | length')" "0"
check "14: 본문에 기록의 리스크 줄이 그대로 있다" "$(jqv .body | grep -cxF "**선택지 리스크**: $BADRISK")" "1"
F14b=$(mk 'S14#2.md' implement-unattended 'Step 3 검사' - "$LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' '`계속` — 시간이 듭니다 / `없는 라벨` — 일이 빠집니다')
render "$F14b"
check "14: 선택지에 없는 라벨 조각도 나눌 수 없는 줄이다" "$(jqv '[.options[] | select(has("preview"))] | length')" "0"
F14c=$(mk 'S14#3.md' implement-unattended 'Step 3 검사' - "$LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' '`계속` — 시간이 듭니다')
render "$F14c"
check "14: 조각이 없는 선택지에는 preview 가 없다" "$(jqv '[.options[] | has("preview")] | map(tostring) | join(" ")')" "true false"

# --- 15. 빈 요지와 중복 요지 -------------------------------------------------------
F15=$(mk 'S15#1.md' implement-unattended 'Step 3 검사' '   ' "$LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' -)
render "$F15"
check "15: 빈 요지면 source 가 대체" "$(jqv .source)" "대체"
F15b=$(mk 'S15#2.md' implement-unattended 'Step 3 검사' '첫 요지입니다
**판정 요지**: 둘째 요지입니다' "$LONGQ" '- `계속` — 갑니다
- `중단` — 멈춥니다' -)
render "$F15b"
check "15: 요지 줄이 둘이면 첫 줄이 쓰인다" "$(jqv .question)" "[S15#2] 첫 요지입니다"

# --- 16. 대체 문장 자름 ------------------------------------------------------------
BAN=$(printf 'ban-candidate-%.0s' $(seq 1 20))
F16=$(mk 'S2P#7.md' visual-publish-unattended '금지-후보' - "$LONGQ" '- `승인` — 넣습니다
- `거절` — 뺍니다
- `나중에` — 남깁니다' - "**금지 후보**: $BAN")
render "$F16"
Q16=$(jqv .question)
truthy "16: 긴 금지 후보 id 로도 question 이 상한 이하" "$([ "$(cpn "$Q16")" -le "$MAX" ] && echo 1)" "$(cpn "$Q16")"
check "16: 끝이 $MORE" "$(has "$MORE" "${Q16: -${#MORE}}")" "1"
check "16: 금지 후보 대체 문장의 머리" "$(has '[S2P#7] 금지 후보 ban-candidate-' "$Q16")" "1"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
