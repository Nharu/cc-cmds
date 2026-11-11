#!/usr/bin/env bash
# 아침 보고의 「기다리는 결정」 도우미 — 무엇을 목록에 올리고 각 결정에 무엇을 적는가.
#
# 이 스위트가 있는 이유. 도우미의 출력은 아침에 사람이 답을 고르는 유일한 자리다. 결정이 빠지면
# 그 결정은 다음 런까지 묻히고, 칸이 비면 사람이 원장을 다시 읽어야 한다. 그래서 단언은 픽스처
# 런 하나에서 「목록에 오른 결정 집합이 기대 집합과 정확히 같은가」, 「각 결정이 질문·형식·답하는
# 곳·추천·근거·라벨마다 리스크를 갖는가」, 「머리줄 계수가 맞는가」를 본다. 게이트 판정과의 동치는
# 매니페스트와 체인이 검증되는 원장이 필요하므로 test-gate.sh 의 절이 본다.
#
# Usage: bash scripts/test-waiting-decisions.sh

set -uo pipefail

CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
# 게이트의 런 개시 갈래가 대시보드 서버를 띄운다 — 이 스위트에는 그것을 내리는 쪽이 없다.
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD
# 스테이지 안에서 돌리면 스테이지의 원장·매니페스트 변수가 물려온다. 이름 목록이 아니라
# 접두어로 걷으므로 게이트가 나중에 내보내기 시작한 이름도 함께 걷힌다.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
HELPER="$ORCH/waiting-decisions.sh"
GATE="$ORCH/gate.sh"
SKILLS="$repo_root/plugins/cc-cmds/skills"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-waiting-decisions-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

RUN_ID=20990101-wd000001
BASE="$WORK/base"
RD="$WORK/run/$RUN_ID"
LEDGER="$BASE/docs/pipeline-run/$RUN_ID.md"
MANIFEST="$WORK/manifest.md"
mkdir -p "$BASE/docs/pipeline-grant" "$BASE/docs/pipeline-run" "$RD/halt/shift"
: > "$BASE/docs/pipeline-grant/$RUN_ID.md"
printf '# 매니페스트\n<!-- cc-pipeline-manifest v1; run-id=%s;\n     origin-worktree=%s;\n-->\n' "$RUN_ID" "$BASE" > "$MANIFEST"

row() { printf -- '- `%s` | %s | prev=0\n' "$1" "$2" >> "$LEDGER"; }

# --- 픽스처: 승인 사이드카 (게이트의 쓰기 함수로 쓴다) --------------------------------
LONGQ=$(printf '긴 질문 문면 %.0s' $(seq 1 60))
side() {
  # 게이트를 들여오면 RUN_ID·BASE 가 초기화되므로 값을 먼저 옮겨 둔다.
  ( fx_rid=$RUN_ID; fx_base=$BASE
    CC_GATE_SOURCE_ONLY=1 . "$GATE" >/dev/null 2>&1
    set +e
    BASE="$fx_base"; RUN_ID="$fx_rid"; GRANT="$BASE/docs/pipeline-grant/$RUN_ID.md"; DOC_KEY='docs/x.md'
    gate_approval_sidecar_write A-act1 issue '질문' '사전 인가 밖 행위를 수행할까요' "$(gate_act_approval_aid cc 'git push origin seg-x')"
    gate_approval_sidecar_write J-pers issue '질문' 'S2 를 다시 파견할까요 — 대안: park' \
      "$(gate_judgment_approval_aid '`승인` — 상시 지침이 재파견을 정한다' '`승인` — 같은 계획으로 한 번 더 돌아 시간이 듭니다 / `거부` — S2 가 park 됩니다')"
    gate_approval_sidecar_write J-vis issue '질문' '캔버스를 승인할까요' \
      "$(gate_judgment_approval_aid '`승인` — 판정 기준을 통과했다' '`승인` — 승인된 캔버스로 발행됩니다 / `거부` — 발행이 멈춥니다 / `무효` — 질문이 닫힙니다')"
    gate_approval_sidecar_write J-free issue '질문' '자유 입력으로 답한 질문'
    gate_approval_sidecar_write B-b1 issue '질문' '경계 B1 을 넘었습니다 — 계속할까요' "$(gate_boundary_approval_aid B1)"
    gate_approval_sidecar_write J-long issue '질문' "$LONGQ"
  ) >/dev/null 2>&1
}
side

# --- 픽스처: 원장 --------------------------------------------------------------------
: > "$LEDGER"
row run "run-id=$RUN_ID | RUN_DIR=$RD"
for s in S1 S2 S4 S6 S11 S12 S14 S15 S16 S17 V1 V2; do row segment "id=$s | 상태=park"; done
row 승인 "승인 id=A-act1 | 상태=대기 | 대상=cc | 절단점=커밋 | 구속 튜플=cc/master/abcdef012345/G3 | 막는 세그먼트=S1 | 질문 문면=사전 인가 밖 행위를 수행할까요"
row 승인 "승인 id=J-pers | 상태=대기 | 절단점=판단 | 막는 세그먼트=S2 | 판단 부류=사람-결정 | 질문 문면=S2 를 다시 파견할까요 — 대안: park"
row 승인 "승인 id=J-closed | 상태=대기 | 절단점=판단 | 막는 세그먼트=S2 | 판단 부류=사람-결정 | 질문 문면=닫힌 질문"
row 승인 "승인 id=J-closed | 상태=승인 | 질문 문면=닫힌 질문"
row 승인 "승인 id=J-vis | 상태=대기 | 절단점=판단 | 막는 세그먼트=V1 | 판단 부류=시각-승인 | 질문 문면=캔버스를 승인할까요"
row 승인 "승인 id=J-free | 상태=대기 | 절단점=판단 | 막는 세그먼트=S4 | 판단 부류=사람-결정 | 처분 사유=자유 입력 | 질문 문면=자유 입력으로 답한 질문"
row 승인 "승인 id=B-b1 | 상태=대기 | 절단점=경계 | 구속 튜플=B1/7 | 막는 세그먼트=- | 질문 문면=경계 B1 을 넘었습니다 — 계속할까요"
row 승인 "승인 id=J-long | 상태=대기 | 절단점=판단 | 막는 세그먼트=S6 | 판단 부류=사람-결정 | 질문 문면=긴 질문 발췌"

park() { row stage-result "세그먼트=$1 | 스테이지=$1 | 실행 버전=$2 | 종단 부류=${3:-의도된 park}"; }
park S1 1; park S2 1; park S3 1; park S4 1; park S6 1; park S7 1; park S8 1; park S9 1; park S10 1
park V1 1; park V2 1; park S11 3; park S12 1 완료; park S14 1; park S15 1; park S16 1; park S17 1; park S18 1
park L1 1; park L2 1
row stage-result "세그먼트=- | 스테이지=D1 | 종류=design | 실행 버전=1 | 종단 부류=의도된 park"
row '중단 답' "중단 기록=$RD/halt/S3#1.md | 세그먼트=S3 | 선택지=계속"
row '중단 답' "중단 기록=$RD/halt/S4#1.md | 세그먼트=S4 | 선택지=계속"
row blocked "대상=cc | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S4 | 사유=중단 답 라우팅 — S4#1.md — 실행하지 못함 | 막힌 답 줄=$(($(wc -l < "$LEDGER")))"
row blocked "대상=cc | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S11 | 사유=낡은 정지 | 근거=S11#1.md 를 사람이 봐야 한다"
row blocked "대상=cc | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S12 | 사유=덮인 정지 | 근거=S12#1.md 를 사람이 봐야 한다"
row segment "id=S12 | 상태=실행중"
row blocked "대상=cc | 스코프=cone | 원인=막힘 | 앵커 세그먼트=S17 | 사유=외부 선행 | 근거=S17#1.md 를 사람이 봐야 한다"
row handoff "사유=승인 | 막힌 지점=L1#1.md 와 L2#1.md 를 사람이 봐야 한다"

# --- 픽스처: 정지 기록 --------------------------------------------------------------
halt() {
  # halt <file> <stage> <step> <options> <추천> <추천 근거> <리스크|-> [nofence|''] [질문 문면]
  local f="$RD/halt/$1"
  {
    printf '<!-- cc-pipeline-halt v1; writer=stage; reader=orchestrator; stage=%s; run=%s -->\n' "$2" "$RUN_ID"
    printf '**스킬**: implement-unattended\n**스텝**: %s\n**분류**: gate-unanswerable\n' "$3"
    printf '**질문 문면**: %s\n' "${9:-$1 의 질문}"
    printf '**선택지**:\n'
    [ -z "$4" ] || printf '%s\n' "$4"
    [ -z "$5" ] || printf '**추천**: %s\n' "$5"
    [ -z "$6" ] || printf '**추천 근거**: %s\n' "$6"
    [ "$7" = "-" ] || printf '**선택지 리스크**: %s\n' "$7"
    printf '**하네스 오류**: (없음)\n'
    [ "${8:-}" = "nofence" ] || printf '<!-- /cc-pipeline-halt v1 -->\n'
  } > "$f"
}
OPTS2='- `계속` — 다음 단계로 갑니다
- `중단` — 세그먼트를 park 합니다'
halt 'S1#1.md' 'S1#1' 'Step 3 검사' "$OPTS2" '`계속` — 상시 지침' '상시 지침: 계속한다' '`계속` — 시간이 듭니다 / `중단` — 일이 빠집니다'
halt 'S2#1.md' 'S2#1' 'Step 3 검사' "$OPTS2" '(없음) — 사람만 아는 사실' '(없음)' '-'
halt 'S3#1.md' 'S3#1' 'Step 3 검사' "$OPTS2" '`계속` — 상시 지침' '상시 지침: 계속한다' '-'
halt 'S4#1.md' 'S4#1' 'Step 3 검사' "$OPTS2" '`계속` — 상시 지침' '상시 지침: 계속한다' '`계속` — 시간이 듭니다 / `중단` — 일이 빠집니다'
halt 'S6#1.md' 'S6#1' 'Step 3 강제 표면 좌석 적용' '- `좌석 적용` — 게이트가 커밋합니다
- `보류` — 보류 큐로 갑니다' '' '' '`좌석 적용` — 기록 내용이 그대로 커밋됩니다 / `보류` — 진행하지 않습니다'
halt 'S7#1.md' 'S7#1' 'Step 3 검사' '' '' '' '-'
printf '답 첨부\n' > "$RD/halt/S1#1.answer.md"
halt 'S8#1.md' 'S8#1' 'Step 3 검사' "$OPTS2" '' '' '-' nofence
halt 'S9#1.md' 'S9#1' 'Step 3 잔여 검증 좌석 실행' '- `좌석 실행` — 좌석이 돌립니다' '' '' '-'
halt 'S10#1.md' 'S10#1' 'Step 3 게이트 도달 좌석 실행' '- `좌석 실행` — 좌석이 돌립니다' '' '' '-'
halt 'V1#1.md' 'V1#1' '시각-판정 — 캔버스' '- `승인` — 발행합니다
- `수정 요청` — 고칩니다
- `거부` — 멈춥니다' '(없음) — 캔버스를 봐야 한다' '(없음)' '`승인` — 발행됩니다 / `수정 요청` — 한 번 더 돕니다 / `거부` — 멈춥니다'
halt 'V2#1.md' 'V2#1' '디자인-시스템-판정 — 팔레트' '- `승인` — 이 디자인 시스템을 씁니다
- `수정 요청` — 다시 만듭니다
- `거부` — 멈춥니다' '(없음) — 디자인 시스템을 봐야 한다' '(없음)' '`승인` — 화면이 이 팔레트로 만들어집니다 / `수정 요청` — 한 번 더 돕니다 / `거부` — 멈춥니다'
halt 'S11#1.md' 'S11#1' 'Step 3 검사' "$OPTS2" '`계속` — 상시 지침' '상시 지침: 계속한다' '맨 부분 / `계속` — 시간 / `계속` — 중복 / `없음` — 없는 라벨'
halt 'S11#2.md' 'S11#2' 'Step 3 검사' "$OPTS2" '' '' '-'
halt 'S11#3.md' 'S11#3' 'Step 3 검사' "$OPTS2" '`없는라벨` — x' 'y' '`계속` — 알려진 위험 없음 — 되돌릴 수 있다 / `중단` — 일이 빠집니다'
halt 'S12#1.md' 'S12#1' 'Step 3 검사' "$OPTS2" '' '' '-'
halt 'shift/S13#1.md' 'S13#1' '교대 정지 — 병합 거절' "$OPTS2" '' '' '-'
halt 'S14#1.md' 'S14#1' 'Step 3 검사' "$OPTS2" '(없음) — 사람만 안다' '(없음)' '`계속` — a / `중단` — b'
printf '99999999\n' > "$RD/S14.waiting"
halt 'D1#1.md' 'D1#1' 'Step 2 설계' "$OPTS2" '(없음) — 사람만 안다' '(없음)' '`계속` — a / `중단` — b'
halt 'S15#1.md' 'S15#1' 'Step 3 검사' '- `축소` — 범위 축소 후 진행합니다
- `중단` — 멈춥니다' '`축소` — 상시 지침' '상시 지침: 축소한다' '`축소` — 범위가 줄어듭니다 / `중단` — 멈춥니다'
halt 'S16#1.md' 'S16#1' 'Step 1 CFI-U3 BT-STOP — 미결 결정' '- `재수렴` — 첨부한 결정으로 다시 수렴합니다' '(없음) — 항목마다 사람의 결정이 필요하다' '(없음)' '`재수렴` — 표제가 맞지 않으면 같은 정지가 다시 납니다'
# A well-formed record without options, carrying the confirmation fields: a
# decision with the two fixed labels. One whose options sit on the `**선택지**:`
# line itself is not well formed and is counted only.
printf '%s\n' "<!-- cc-pipeline-halt v1; writer=stage; reader=orchestrator; stage=S17#1; run=$RUN_ID -->" \
  '**스킬**: implement-unattended' '**스텝**: Step 1 외부 선행 미충족 — 다른 PR 의 머지' '**분류**: precondition-failed' \
  '**질문 문면**: S17#1.md 의 질문' '**선택지**: (없음) — 원인이 사라지면 잇는다' \
  '**해소 확인 명령**: `gh pr view 12 --json state -q .state`' '**해소 기대 출력**: `MERGED`' \
  '**하네스 오류**: (없음)' '<!-- /cc-pipeline-halt v1 -->' > "$RD/halt/S17#1.md"
printf '%s\n' "<!-- cc-pipeline-halt v1; writer=stage; reader=orchestrator; stage=S18#1; run=$RUN_ID -->" \
  '**스킬**: implement-unattended' '**스텝**: Step 3 검사' '**분류**: gate-unanswerable' \
  '**질문 문면**: S18#1.md 의 질문' '**선택지**: 계속, 중단' '<!-- /cc-pipeline-halt v1 -->' > "$RD/halt/S18#1.md"
# 좌석 질문 렌더 도우미가 질문 칸에 요지를 넣는 긴 한 줄 기록과, 질문 문면이 여러 줄인 짧은 기록.
LQ=$(printf '긴 정지 질문 문장입니다. %.0s' $(seq 1 30))
LQ=${LQ% }
halt 'L1#1.md' 'L1#1' 'Step 3 검사' "$OPTS2" '(없음) — 사람만 안다' '(없음)' '`계속` — 시간이 듭니다 / `중단` — 일이 빠집니다' '' "$LQ"
halt 'L2#1.md' 'L2#1' 'Step 3 검사' "$OPTS2" '(없음) — 사람만 안다' '(없음)' '`계속` — 시간이 듭니다 / `중단` — 일이 빠집니다' '' '첫 줄 질문입니다.
- 「갑」 — 추천 답: 하나
둘째   단락입니다.'

# --- 렌더 전용: 실행 전 파일 목록·sha256·수정 시각 -------------------------------------
fileset() {
  find "$BASE/docs" "$RD" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(date -u -r "$f" +%s)"
  done
}
before=$(fileset)

OUT=""; rc=0
report() { OUT=$(bash "$HELPER" report "$@" 2>"$WORK/err"); rc=$?; }
report "$MANIFEST" "$LEDGER" "$RUN_ID"
check "0: 픽스처 런에서 exit 0 이다" "$rc" "0"
check "렌더 전용: 원장·사이드카·런 디렉터리의 파일 목록·sha256·수정 시각이 실행 전후로 같다" "$(fileset)" "$before"

block() {
  # block <머리 접두> — 그 결정의 머리줄부터 다음 빈 줄 앞까지.
  printf '%s\n' "$OUT" | awk -v h="$1" 'index($0, h) == 1 { on = 1 } on && $0 == "" { exit } on { print }'
}
has() { printf '%s\n' "$2" | grep -cF -- "$1" || true; }

# --- C4: 결정 집합 ------------------------------------------------------------------
got=$(printf '%s\n' "$OUT" | sed -n -E 's/^\[(승인|정지 기록) ([^]]*)\].*/\2/p' | LC_ALL=C sort | tr '\n' ' ')
want=$(printf '%s\n' A-act1 J-pers J-vis J-free B-b1 J-long 'S1#1.md' 'S2#1.md' 'S4#1.md' 'S6#1.md' 'V1#1.md' 'V2#1.md' 'S11#1.md' 'S11#3.md' 'S14#1.md' 'D1#1.md' 'S15#1.md' 'S16#1.md' 'S17#1.md' 'S7#1.md' 'L1#1.md' 'L2#1.md' \
  | sed -E 's/^([SVDL][0-9])/halt\/\1/' | LC_ALL=C sort | tr '\n' ' ')
check "C4: 목록에 오른 결정 집합이 기대 집합과 같다" "$got" "$want"
check "C4: 닫힌 승인은 목록에 없다" "$(has 'J-closed' "$OUT")" "0"
check "C4: 답한 정지 기록은 목록에 없다" "$(has 'halt/S3#1.md' "$OUT")" "0"
check "C4: .answer.md 는 결정이 아니다" "$(has 'answer.md' "$OUT")" "0"

# --- C4: 칸 -------------------------------------------------------------------------
check "C4: 머리줄의 결정 수와 미기재 계수" "$(printf '%s\n' "$OUT" | sed -n '1p')" "기다리는 결정 22건 — 추천 미기재 3건 · 리스크 미기재 5건"
for cell in '질문: ' '형식: ' '답하는 곳: ' '추천: ' '근거: '; do
  check "C4: 결정마다 '${cell}' 줄이 하나" "$(printf '%s\n' "$OUT" | grep -c "^$cell" || true)" "22"
done

# S7#1 is a well-formed record without options and without the confirmation
# fields: the fixed labels, and no confirmation lines.
s7=$(block '[정지 기록 halt/S7#1.md]')
check "선택지 없는 기록: 확인 필드가 없으면 확인 줄이 없다" "$(has '해소 확인 명령: ' "$s7")" "0"
check "선택지 없는 기록: 확인 필드가 없어도 두 고정 라벨" "$(printf '%s\n' "$s7" | grep -c -e '^- `원인 해소 후 재개` — ' -e '^- `세그먼트 park` — ' || true)" "2"

s17=$(block '[정지 기록 halt/S17#1.md]')
check "선택지 없는 기록: 고정 라벨 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행이 이 기록의 질문 문면을 보이고 선택지 없는 기록의 고정 라벨로 묻습니다' "$s17")" "1"
check "선택지 없는 기록: 두 고정 라벨이 설명과 리스크를 싣고 오른다" \
  "$(printf '%s\n' "$s17" | grep -c -e '^- `원인 해소 후 재개` — 원인이 사라졌으면 세그먼트를 같은 계획으로 다시 잇습니다 · 리스크: 원인이 남아 있으면 같은 정지가 다시 납니다$' \
      -e '^- `세그먼트 park` — 원인이 사라질 때까지 세그먼트를 외부 보류로 park 합니다 · 리스크: 원인이 사라져도 사람이 다시 답할 때까지 세그먼트가 멈춰 있습니다$' || true)" "2"
check "선택지 없는 기록: 추천은 고정 (없음) 문장" "$(has '추천: (없음) — 선택지 없는 기록은 원인이 사라졌는지를 사람이나 해소 확인이 가립니다' "$s17")" "1"
check "선택지 없는 기록: 확인 명령과 기대 출력을 보인다" \
  "$(printf '%s\n' "$s17" | grep -c -e '^해소 확인 명령: `gh pr view 12 --json state -q .state`$' -e '^해소 기대 출력: `MERGED`$' || true)" "2"
check "선택지 없는 기록: (없음) 줄 아래 문면은 라벨이 아니다" "$(has '원인이 사라지면 잇는다' "$s17")" "0"

act=$(block '[승인 A-act1]')
check "C4: 행위 승인 머리에 행위 줄과 절단점·등급이 붙는다" "$(has '행위 승인 · git · 대상 cc · 막는 세그먼트 S1 · 절단점 커밋 · 등급 G3' "$act")" "1"
check "C4: 행위 승인의 행위 줄에 인자가 없다" "$(has 'seg-x' "$act")" "0"
check "C4: 행위 승인 형식은 예/아니오 고정 문장" "$(has '형식: 예/아니오 — 예는 `승인`, 아니오는 `거부` 로 닫힙니다. `무효` 는 좌석 질문에 없습니다' "$act")" "1"
check "C4: 행위 승인 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행이 이 질문을 메뉴 없이 예/아니오로 묻습니다' "$act")" "1"
check "C4: 행위 승인 라벨에 좌석 답이 붙는다" "$(printf '%s\n' "$act" | grep -c -e '^- `승인` (예) — ' -e '^- `거부` (아니오) — ' -e '^- `무효` (좌석 질문에 없음) — ' || true)" "3"
check "C4: 행위 승인 추천은 (없음) 문장" "$(has '추천: (없음) — 사전 인가 밖 행위는 사람만 엽니다' "$act")" "1"

jp=$(block '[승인 J-pers]')
check "C4: 판단 승인 형식은 라벨 메뉴" "$(has '형식: 라벨 메뉴' "$jp")" "1"
check "C4: 판단 승인 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행(`/cc-cmds:autopilot`)이 이 질문을 그대로 묻습니다' "$jp")" "1"
check "C4: 판단 승인 추천은 라벨, 근거는 대시 뒤 문장" "$(printf '%s\n' "$jp" | grep -c -e '^추천: `승인`$' -e '^근거: 상시 지침이 재파견을 정한다$' || true)" "2"
check "C4: 판단 승인의 리스크 없는 라벨은 미기재" "$(has '- `무효` — 애초에 물어서는 안 됐던 질문입니다 — 행위 없이 승인만 닫습니다 · 리스크: 미기재' "$jp")" "1"
check "C4: 판단 승인 질문은 게이트 정본" "$(has '질문: 승인 J-pers — S2 를 다시 파견할까요 — 대안: park' "$jp")" "1"

jv=$(block '[승인 J-vis]')
check "C4: 시각-승인 은 시각 계열 답하는 곳" "$(has '답하는 곳: 캔버스를 봐야 답하는 결정입니다' "$jv")" "1"
check "C4: 시각-승인 도 라벨마다 리스크" "$(printf '%s\n' "$jv" | grep -v '리스크: 미기재' | grep -c ' · 리스크: ' || true)" "3"

jf=$(block '[승인 J-free]')
check "C4: 자유 입력 처분 승인에 주석이 붙는다" "$(has '이 승인은 자유 입력 답이 처분되지 못해 다시 묻습니다' "$jf")" "1"
check "C4: 결정 보조 없는 승인은 추천 미기재" "$(has '추천: 미기재' "$jf")" "1"

bb=$(block '[승인 B-b1]')
check "C4: 경계 승인 머리에 경계 이름" "$(has '경계 승인 · B1' "$bb")" "1"
check "C4: 경계 승인 추천 문장" "$(has '추천: (없음) — 자동 해소가 이 승인을 닫지 않은 런이라 계속할지는 사람이 정한다' "$bb")" "1"
check "C4: 경계 승인 무효 리스크에 좌석 질문에 없다는 사실" "$(printf '%s\n' "$bb" | grep -c '^- `무효` (좌석 질문에 없음) .*좌석 질문에 없습니다' || true)" "1"

jl=$(block '[승인 J-long]')
check "C4: 긴 질문은 사이드카 전문이다" "$(has "질문: 승인 J-long — $LONGQ" "$jl")" "1"

s1=$(block '[정지 기록 halt/S1#1.md]')
check "C4: 새 형식 정지 기록 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행이 이 기록의 요지와 원문을 보여 주고 선택지를 그대로 묻습니다 — 아래 라벨 하나로 답합니다' "$s1")" "1"
check "C4: 옛 답하는 곳 문장은 남지 않았다" "$(has '이 기록의 질문 문면과 선택지를 그대로 묻습니다' "$OUT")" "0"
check "요지: 짧은 기록(질문 칸에 원문이 드는 기록)에는 요지 줄이 없다" "$(has '요지: ' "$s1")" "0"

# --- 요지 줄과 원문 전체 질문 줄 ---------------------------------------------------------
HQ="$ORCH/halt-question.sh"
l1=$(block '[정지 기록 halt/L1#1.md]')
hq1=$(bash "$HQ" render --record "$RD/halt/L1#1.md")
check "요지: 긴 한 줄 기록의 요지 줄이 도우미의 question 과 같다" "$(printf '%s\n' "$l1" | sed -n 's/^요지: //p')" "$(printf '%s' "$hq1" | jq -r '.question')"
check "요지: 요지 줄은 질문 줄 바로 앞" "$(printf '%s\n' "$l1" | grep -A1 '^요지: ' | sed -n '2p' | grep -c '^질문: ' || true)" "1"
check "요지: 긴 한 줄 기록의 질문 줄은 원문 전체" "$(printf '%s\n' "$l1" | sed -n 's/^질문: //p')" "$LQ"
l2=$(block '[정지 기록 halt/L2#1.md]')
check "질문: 여러 줄 질문 기록의 질문 줄은 접은 원문 전체" "$(printf '%s\n' "$l2" | sed -n 's/^질문: //p')" "첫 줄 질문입니다. - 「갑」 — 추천 답: 하나 둘째 단락입니다."
check "요지: 여러 줄이어도 질문 칸에 드는 기록에는 요지 줄이 없다" "$(has '요지: ' "$l2")" "0"
# 도우미 본문의 원문 부분을 게이트의 접기 규칙으로 접은 값이 게이트의 질문 판독과 같다.
gq1=$( ( CC_GATE_SOURCE_ONLY=1 . "$GATE" >/dev/null 2>&1; set +e; gate_halt_record_question "$RD/halt/L1#1.md" ) )
hp1=$(printf '%s' "$hq1" | jq -r '.body' | awk '
  $0 == "**질문 원문**" { on = 1; next }
  on && (index($0, "**선택지 리스크**") == 1 || $0 == "**질문 뒤 인용 줄**" || index($0, "기록: ") == 1) { exit }
  on { print }' | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')
check "요지: 도우미 본문의 원문 부분을 접은 값이 gate_halt_record_question 과 같다" "$hp1" "$gq1"
truthy() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
truthy "요지: 그 비교가 빈 값끼리의 비교가 아니다" "$([ -n "$gq1" ] && [ "${#gq1}" -gt 200 ] && echo 1)" "길이 ${#gq1}"
gq2=$( ( CC_GATE_SOURCE_ONLY=1 . "$GATE" >/dev/null 2>&1; set +e; gate_halt_record_question "$RD/halt/L2#1.md" ) )
hp2=$(bash "$HQ" render --record "$RD/halt/L2#1.md" | jq -r '.body' | awk '
  $0 == "**질문 원문**" { on = 1; next }
  on && (index($0, "**선택지 리스크**") == 1 || $0 == "**질문 뒤 인용 줄**" || index($0, "기록: ") == 1) { exit }
  on { print }' | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')
check "요지: 여러 줄 기록에서도 접은 원문 부분이 gate_halt_record_question 과 같다" "$hp2" "$gq2"
check "C4: 새 형식 정지 기록의 라벨마다 리스크" "$(printf '%s\n' "$s1" | grep -c -e '^- `계속` — 다음 단계로 갑니다 · 리스크: 시간이 듭니다$' -e '^- `중단` — 세그먼트를 park 합니다 · 리스크: 일이 빠집니다$' || true)" "2"

s2=$(block '[정지 기록 halt/S2#1.md]')
check "C4: 옛 형식 정지 기록의 리스크는 미기재" "$(printf '%s\n' "$s2" | grep -c ' · 리스크: 미기재$' || true)" "2"
check "C4: (없음) 추천은 그대로" "$(has '추천: (없음) — 사람만 아는 사실' "$s2")" "1"

s4=$(block '[정지 기록 halt/S4#1.md]')
check "C4: 답이 되돌아온 기록 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행이 되돌아온 답과 그 답을 실행하지 못한 이유를 먼저 보이고' "$s4")" "1"
check "C4: 답이 되돌아온 기록에는 자동 답 표지가 없다" "$(has '자동 답 대상' "$s4")" "0"

s6=$(block '[정지 기록 halt/S6#1.md]')
check "C4: 좌석 적용 기록 답하는 곳" "$(has '답하는 곳: 다음 좌석 실행이 적용 미리보기의 차이를 보인 뒤' "$s6")" "1"
check "C4: 좌석 적용 기록 근거 고정 문장" "$(has '근거: 없음 — 이 정지 스텝은 추천을 받지 않습니다' "$s6")" "1"

check "C4: 시각-판정 기록은 시각 계열 답하는 곳" "$(has '답하는 곳: 캔버스를 봐야 답하는 결정입니다' "$(block '[정지 기록 halt/V1#1.md]')")" "1"
check "C4: 디자인-시스템-판정 기록은 시각 계열 답하는 곳" "$(has '답하는 곳: 캔버스를 봐야 답하는 결정입니다' "$(block '[정지 기록 halt/V2#1.md]')")" "1"
check "C4: 미결 결정 기록은 첨부 답하는 곳" "$(has '라벨 하나로 답하되, `재수렴` 은 질문 문면이 말하는 내용을 첨부로 함께 내야 닫힙니다' "$(block '[정지 기록 halt/S16#1.md]')")" "1"

s11=$(block '[정지 기록 halt/S11#1.md]')
check "C4: 같은 라벨 두 부분은 둘 다 버린다" "$(has '- `계속` — 다음 단계로 갑니다 · 리스크: 미기재(형식 어긋남 — 같은 라벨이 두 부분에 나옴)' "$s11")" "1"
check "C4: 버린 리스크 부분 줄" "$(printf '%s\n' "$s11" | grep -c '^버린 리스크 부분: ' || true)" "4"
check "C4: 가리킴으로 오른 낡은 기록에는 자동 답 표지가 없다" "$(has '자동 답 대상' "$s11")" "0"
s113=$(block '[정지 기록 halt/S11#3.md]')
check "C4: 선택지에 없는 추천 라벨은 형식 어긋남" "$(has '추천: 미기재(형식 어긋남 — 선택지에 없는 라벨 없는라벨)' "$s113")" "1"
check "C4: 알려진 위험 없음 은 기재다" "$(has '리스크: 알려진 위험 없음 — 되돌릴 수 있다' "$s113")" "1"

# --- 자동 답 표지 --------------------------------------------------------------------
marked=$(printf '%s\n' "$OUT" | awk '/^\[/ { h = $0 } /^자동 답 대상 — / { print h }' | sed -n 's/^\[정지 기록 \([^]]*\)\].*/\1/p' | tr '\n' ' ')
check "자동 답 표지는 자동 답 2단계와 추천 검사를 모두 통과한 기록에만" "$marked" "halt/S1#1.md "
check "범위 축소 추천 기록에는 표지가 없다" "$(has '자동 답 대상' "$(block '[정지 기록 halt/S15#1.md]')")" "0"

# --- 건수 줄 ------------------------------------------------------------------------
check "건수: 직접 실행할 정지" "$(has '다음 좌석 실행이 직접 실행할 정지 2건' "$OUT")" "1"
check "건수: 가리키지 않은 정지 기록" "$(has '좌석이 이번 런에서 가리키지 않은 정지 기록 3건' "$OUT")" "1"
check "건수: 선택지 없고 형식이 어긋난 기록" "$(has '선택지가 없고 형식이 어긋난 정지 기록 1건' "$OUT")" "1"
check "건수: 닫는 펜스 없는 기록" "$(has '닫는 펜스가 없는 기록 1건' "$OUT")" "1"

# --- 라벨 되읽기 --------------------------------------------------------------------
check "라벨 되읽기: 출력에서 뽑은 S1#1 라벨 집합이 기록의 라벨 집합과 같다" \
  "$(printf '%s\n' "$s1" | sed -n 's/^- `\([^`]*\)`.*/\1/p' | tr '\n' ' ')" "계속 중단 "

# --- 실행 문맥 ----------------------------------------------------------------------
mkdir -p "$WORK/nojq"
ln -s "$(command -v dirname)" "$WORK/nojq/dirname"
OUT=$(PATH="$WORK/nojq" "$BASH" "$HELPER" report "$MANIFEST" "$LEDGER" "$RUN_ID" 2>"$WORK/err"); rc=$?
check "실행 문맥: jq 없는 PATH 에서 exit 2" "$rc" "2"
check "실행 문맥: jq 없는 PATH 에서 한 줄 오류" "$(wc -l < "$WORK/err" | tr -d ' ')" "1"
report "$MANIFEST"
check "사용법 오류는 exit 2" "$rc" "2"
report "$MANIFEST" "$WORK/없는원장.md" "$RUN_ID"
check "원장을 읽지 못하면 exit 2" "$rc" "2"

# 한 결정의 판정 함수가 die 로 끝나도 나머지는 렌더된다 — 게이트 사본에서 gate_prompt 를 덮는다.
mkdir -p "$WORK/stub"
cp "$HELPER" "$WORK/stub/waiting-decisions.sh"
cat > "$WORK/stub/gate.sh" <<EOF
. "$GATE"
eval "wd_orig_\$(declare -f gate_prompt)"
gate_prompt() { if [ "\$1" = "J-pers" ]; then die "강제 실패"; fi; wd_orig_gate_prompt "\$@"; }
EOF
OUT=$(bash "$WORK/stub/waiting-decisions.sh" report "$MANIFEST" "$LEDGER" "$RUN_ID" 2>"$WORK/err"); rc=$?
check "실행 문맥: 한 결정이 실패해도 exit 0" "$rc" "0"
check "실행 문맥: 실패한 결정의 칸은 읽기 실패" "$(has '질문: 미기재(읽기 실패 — 강제 실패)' "$(block '[승인 J-pers]')")" "1"
check "실행 문맥: 나머지 결정은 렌더된다" "$(has '추천: (없음) — 사전 인가 밖 행위는 사람만 엽니다' "$(block '[승인 A-act1]')")" "1"
# 이 사본 디렉터리에는 렌더 도우미가 없다 — 도우미 전에 고정된 런의 사본과 같다.
check "실행 문맥: 도우미 없는 사본에서도 긴 기록이 렌더된다" "$(has '질문: 긴 정지 질문 문장입니다.' "$(block '[정지 기록 halt/L1#1.md]')")" "1"
check "실행 문맥: 도우미 없는 사본에서는 요지 줄이 없다" "$(has '요지: ' "$OUT")" "0"

# 런 디렉터리가 회수되면 그 사실 한 줄.
mv "$RD" "$RD.gone"
report "$MANIFEST" "$LEDGER" "$RUN_ID"
check "런 디렉터리가 없으면 그 줄을 쓴다" "$(has '런 디렉터리가 회수돼 정지 기록을 읽지 못했습니다' "$OUT")" "1"
mv "$RD.gone" "$RD"

# --- 렌더 전용: 소스 ---------------------------------------------------------------
src_code=$(grep -v '^[[:space:]]*#' "$HELPER")
check "렌더 전용: 게이트를 들여오는 자리는 하나" "$(printf '%s\n' "$src_code" | grep -c 'CC_GATE_SOURCE_ONLY=1 \.' || true)" "1"
allowed=$(sed -n "s/^WD_GATE_FUNCTIONS='\(.*\)'$/\1/p" "$HELPER")
stray=''
for t in $(printf '%s\n' "$src_code" | grep -v '^WD_GATE_FUNCTIONS=' | grep -oE '\b(gate|cc)_[a-z_]+' | LC_ALL=C sort -u); do
  case " $allowed " in *" $t "*) ;; *) stray="$stray $t" ;; esac
done
check "렌더 전용: 부르는 게이트 함수가 목록 안" "$stray" ""

# --- C3 규약 전파 ------------------------------------------------------------------
NINE='design-audit-unattended design-reconverge implement-unattended review-unattended design-discuss-unattended design-solo-unattended visual-publish-unattended visual-unattended design-base-unattended'
miss=''
for s in $NINE; do grep -qF '선택지 리스크' "$SKILLS/$s/SKILL.md" || miss="$miss $s"; done
for f in _common/pipeline-sidecar.md _common/judgment-grade.md autopilot-router-shift/SKILL.md autopilot-router-shift/references/refutation-reconverge.md; do
  grep -qF '선택지 리스크' "$SKILLS/$f" || miss="$miss $f"
done
check "C3: 작성 스킬과 규약 문서가 모두 선택지 리스크 를 담는다" "$miss" ""
rl=$(grep -F '**`**선택지 리스크**` names, per option' "$SKILLS/_common/pipeline-sidecar.md" || true)
miss=''
for s in $NINE; do case "$rl" in *"\`$s\`"*) ;; *) miss="$miss $s" ;; esac; done
check "C3: 사이드카 리스크 줄 문장이 아홉 스킬 이름을 담는다" "$miss" ""

# --- 보고 절차 문장 ----------------------------------------------------------------
A3="$SKILLS/autopilot/references/act3-report.md"
for s in '판정 게이트: 이 런의 고정본' '판정 게이트: 설치본 — 이 런의 고정본에는 도우미가 없었습니다' '판정 게이트: 설치본 — 이 런의 고정본을 찾지 못했습니다' \
         '기다리는 결정을 읽지 못했습니다' '이 런은 추적 기록으로만 보고되어 기다리는 결정을 렌더하지 않습니다'; do
  check "보고 절차: '$s' 문장이 있다" "$(grep -cF -- "$s" "$A3" || true)" "1"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
