#!/usr/bin/env bash
# lint-bash-portability: self-skip
# 리뷰 사이클 원인 측정 도구 — 모집단·사이클 표·계기·수정 경로·발견 성격·리포트 상태·출력·인자.
#
# 측정 도구의 오판은 오류가 아니라 자신 있는 틀린 수로 나타난다. 그래서 단언은 대부분
# 「수가 정확히 이것이다」이고, 판정마다 홀로 발화하는 픽스처와 발화하지 않아야 할
# 대조군을 함께 둔다. 실원장은 읽지 않는다 — 픽스처 레포만 만든다.
#
# Usage: bash scripts/test-measure-cycle-causes.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
TOOL="$repo_root/plugins/cc-cmds/orchestrator/measure-cycle-causes.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-cycle-causes-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- 픽스처 ---------------------------------------------------------------------

seg() { printf -- '- `segment` | 교대=0 | id=%s | 상태=%s%s | prev=x\n' "$1" "$2" "${3:-}"; }
cyc() { printf -- '- `cycle` | 교대=0 | 세그먼트=%s | 사이클=%s | P0=%s | P1=%s%s | prev=x\n' "$1" "$2" "$3" "$4" "${5:-}"; }
evt() { printf -- '- `%s` | 교대=0 | 세그먼트=%s%s | prev=x\n' "$1" "$2" "${3:-}"; }

mk_ledger() {
  # mk_ledger <레포 디렉터리> <파일 이름> — 표준 입력의 행을 헤더 뒤에 둔다.
  mkdir -p "$1/docs/pipeline-run"
  { printf '# 파이프라인 런 보고서\n\n이 줄은 산문이다.\n'; cat; } > "$1/docs/pipeline-run/$2"
}

summary() { printf -- '- **발견 요약**: 🔴 P0 %s건 | 🟠 P1 %s건 | 🟡 P2 %s건 | 🟢 P3 %s건\n' "$1" "$2" "$3" "$4"; }

run_json() {
  # run_json <출력 JSON> <인자…> — 표는 $WORK/out.txt 에.
  local j="$1"; shift
  bash "$TOOL" "$@" --json "$j" > "$WORK/out.txt" 2> "$WORK/err.txt"
}

# --- 1. 모집단 -------------------------------------------------------------------

P="$WORK/p"
for name in 20261004-aaaaaaa1.md 20261005-bbbbbbb2.md 20261017-ccccccc3.md 20261018-ddddddd4.md \
            20261010-eeeeeee5.plan.md 20261010-fffffff6.interview.md 2026101-abcdef12.md 20261010-ABCDEF12.md; do
  { seg A 머지됨; cyc A 1 0 0; } | mk_ledger "$P" "$name"
done
printf '{"cycle":1}\n' > "$P/docs/pipeline-run/metrics.json"
{
  seg A 머지됨; cyc A 1 0 0
  seg Z 계획됨 ' | 상태=머지됨'
  printf '산문 속의 - `cycle` | 세그먼트=Q | 사이클=1 는 행이 아니다.\n'
  printf '  - `cycle` | 세그먼트=Q | 사이클=2 | P0=0 | P1=0\n'
} | mk_ledger "$P" 20261005-bbbbbbb2.md

J="$WORK/p.json"
run_json "$J" --ledger-dir p="$P/docs/pipeline-run" --since 2026-10-05 --until 2026-10-17
check "1 기간 양 끝 포함 — 머지됨 행(중복 키는 마지막 값)" "$(jq '.repos[0].ticket.merged_rows' "$J")" 3
check "1 기간 양 끝 포함 — cycle 행(산문·들여쓴 줄 제외)" "$(jq '.repos[0].ticket.cycle_rows' "$J")" 2
check "1 .plan.md·.interview.md·metrics·틀린 이름은 런이 아니다" "$(jq -r '[.segments[].run] | unique | join(",")' "$J")" "20261005-bbbbbbb2,20261017-ccccccc3"
check "1 산문 줄의 세그먼트는 없다" "$(jq '[.segments[] | select(.id == "Q")] | length' "$J")" 0
run_json "$J" --ledger-dir p="$P/docs/pipeline-run"
check "1 대조군 — 기간 없음은 원장 전체" "$(jq '.repos[0].ticket.cycle_rows' "$J")" 4
run_json "$J" --ledger-dir p="$P/docs/pipeline-run" --since 2026-10-05
check "1 since 만 — 위쪽 경계 없음" "$(jq '.repos[0].ticket.cycle_rows' "$J")" 3
check "1 population since/until" "$(jq -c '.population' "$J")" '{"selector":"<8자리>-<8hex>.md","since":"2026-10-05","until":null}'

# --- 2. 사이클 표 -----------------------------------------------------------------

S="$WORK/s"
{
  seg M1 계획됨; cyc M1 1 0 1; cyc M1 2 0 0; cyc M1 2 0 0; seg M1 머지됨; seg M1 머지됨
  seg M2 머지됨; cyc M2 1 0 1; cyc M2 2 0 1; cyc M2 3 0 1; cyc M2 4 0 0
  seg M3 머지됨; cyc M3 1 0 0
  seg K1 실행중; cyc K1 1 0 1; cyc K1 2 0 1; seg K1 park
  seg O1 계획됨; cyc O1 1 0 0; seg O1 리뷰중
  seg O2 완료
  cyc N1 1 0 0; cyc N1 1 0 0
} | mk_ledger "$S" 20261011-22222222.md
{ seg M3 머지됨; cyc M3 1 0 0; } | mk_ledger "$S" 20261012-33333333.md

J="$WORK/s.json"
run_json "$J" --ledger-dir s="$S/docs/pipeline-run"
R='.repos[0]'
check "2 티켓 정의 — 머지됨 행(중복 포함)" "$(jq "$R.ticket.merged_rows" "$J")" 5
check "2 티켓 정의 — cycle 행" "$(jq "$R.ticket.cycle_rows" "$J")" 14
check "2 티켓 정의 — 비" "$(jq "$R.ticket.per_segment" "$J")" 2.8
check "2 보정 정의 — 머지 세그먼트(런마다 다른 M3)" "$(jq "$R.segments.merged.count" "$J")" 4
check "2 보정 정의 — 사이클" "$(jq "$R.segments.merged.cycles" "$J")" 8
check "2 보정 정의 — 평균" "$(jq "$R.segments.merged.mean" "$J")" 2
check "2 보정 정의 — 중앙값" "$(jq "$R.segments.merged.median" "$J")" 1.5
check "2 보정 정의 — 최대" "$(jq "$R.segments.merged.max" "$J")" 4
check "2 park" "$(jq -c "$R.segments.park" "$J")" '{"count":1,"cycles":2}'
check "2 그 밖(값별)" "$(jq -c "$R.segments.other" "$J")" '{"by_state":{"리뷰중":1,"완료":1},"count":2,"cycles":1}'
check "2 세그먼트 행 없음" "$(jq -c "$R.segments.no_segment_row" "$J")" '{"count":1,"cycles":1}'
check "2 분해 — cycle 행" "$(jq -c "$R.decomposition.cycle_rows" "$J")" '{"duplicate":2,"merged":8,"no_segment_row":1,"other":1,"park":2}'
check "2 분해 — 머지됨 행" "$(jq -c "$R.decomposition.merged_rows" "$J")" '{"duplicate":1,"segments":4}'
check "2 분해 등식 — cycle 행" "$(jq "$R | .decomposition.cycle_rows | .merged + .park + .other + .no_segment_row + .duplicate" "$J")" "$(jq "$R.ticket.cycle_rows" "$J")"
check "2 분해 등식 — 머지됨 행" "$(jq "$R | .decomposition.merged_rows | .segments + .duplicate" "$J")" "$(jq "$R.ticket.merged_rows" "$J")"
check "2 표의 분해 줄" "$(grep -c '14 = 8 + 2 + 1 + 1 + 2' "$WORK/out.txt")" 1

# --- 3. 계기 ----------------------------------------------------------------------

T="$WORK/t"
{
  seg T0 머지됨; cyc T0 1 1 0; cyc T0 2 0 0
  seg T1 머지됨; cyc T1 1 0 2; evt checks T1 ' | 상태=실패'; cyc T1 2 0 0
  seg TC 머지됨; cyc TC 1 0 0; evt checks TC ' | 상태=실패'; cyc TC 2 0 0
  seg TB 머지됨; cyc TB 1 0 0; evt blocked TB ' | 도달 판정=CI실패'; cyc TB 2 0 0
  seg TR 머지됨; cyc TR 1 0 0; cyc TR 2 0 0 ' | 모드=해소'
  seg TH 머지됨; cyc TH 1 0 0; evt '중단 답' TH; cyc TH 2 0 0
  seg TV 머지됨; cyc TV 1 0 0; evt stage-result TV ' | 종류=review | 종단 부류=크래시'; cyc TV 2 0 0
  seg TU 머지됨; cyc TU 1 0 0; evt checks TX ' | 상태=실패'; evt checks TU ' | 상태=통과'
  evt stage-result TU ' | 종류=review | 종단 부류=정상 완료'; evt blocked TU ' | 도달 판정=기타'; cyc TU 2 0 0
  seg TE 머지됨; evt checks TE ' | 상태=실패'; cyc TE 1 0 0; cyc TE 2 0 0
  seg TN 머지됨; cyc TN 2 0 0
  seg TD 머지됨; cyc TD 1 0 0; cyc TD 1 0 0
  seg TP park; cyc TP 1 0 1; cyc TP 2 0 0
} | mk_ledger "$T" 20261013-44444444.md

J="$WORK/t.json"
run_json "$J" --ledger-dir t="$T/docs/pipeline-run"
trig() { jq -r --arg s "$1" --argjson n "$2" '.segments[] | select(.id == $s) | .cycles[] | select(.n == $n) | .trigger' "$J" | tail -n 1; }
flag() { jq -r --arg s "$1" --arg f "$2" '.segments[] | select(.id == $s) | .cycles[] | select(.n == 2) | .flags[$f]' "$J"; }
check "3 리뷰 P0" "$(trig T0 2)" "리뷰 P0"
check "3 우선순위 — 앞 사이클 P1 + CI 실패는 리뷰 P1" "$(trig T1 2)" "리뷰 P1"
check "3 우선순위 — ci_failed 플래그는 남는다" "$(flag T1 ci_failed)" true
check "3 CI 실패 — checks 상태=실패" "$(trig TC 2)" "CI 실패"
check "3 CI 실패 — blocked 도달 판정=CI실패" "$(trig TB 2)" "CI 실패"
check "3 베이스 병합 해소" "$(trig TR 2)" "베이스 병합 해소"
check "3 base_resolve 플래그" "$(flag TR base_resolve)" true
check "3 중단·재시도 — 중단 답" "$(trig TH 2)" "중단·재시도"
check "3 halted 플래그" "$(flag TH halted)" true
check "3 중단·재시도 — review 크래시" "$(trig TV 2)" "중단·재시도"
check "3 review_crash 플래그" "$(flag TV review_crash)" true
check "3 대조군 — 다른 세그먼트의 CI 실패·통과·정상 완료·다른 도달 판정은 미상" "$(trig TU 2)" "미상"
check "3 대조군 — 다른 세그먼트의 CI 실패는 플래그도 세우지 않는다" "$(flag TU ci_failed)" false
check "3 대조군 — 앞 사이클 행보다 앞선 CI 실패는 사이가 아니다" "$(trig TE 2)" "미상"
check "3 첫 사이클" "$(trig T0 1)" "첫 사이클"
check "3 앞 사이클 행 없음" "$(trig TN 2)" "앞 사이클 행 없음"
check "3 중복 행" "$(trig TD 1)" "중복 행"
check "3 머지 기준 계기 표" "$(jq -c '.repos[0].triggers.merged' "$J")" \
  '{"CI 실패":2,"리뷰 P0":1,"리뷰 P1":1,"미상":2,"베이스 병합 해소":1,"앞 사이클 행 없음":1,"중단·재시도":2,"중복 행":1,"첫 사이클":10}'
check "3 모든 세그먼트 기준은 park 를 더한다" "$(jq '.repos[0].triggers.all["리뷰 P1"]' "$J")" 2

# --- 4. 수정 경로 -------------------------------------------------------------------

F="$WORK/f"
{
  seg FL 머지됨; cyc FL 1 0 1; evt stage-result FL ' | 종류=lead-fix'; cyc FL 2 0 0
  seg FC 머지됨; cyc FC 1 0 1 ' | 리뷰 종결=리드 수정'; cyc FC 2 0 0
  seg FR 머지됨; cyc FR 1 0 1; evt stage-result FR ' | 종류=reconverge'; cyc FR 2 0 0
  seg FI 머지됨; cyc FI 1 0 1; evt stage-result FI ' | 종류=implement'; cyc FI 2 0 0
  seg FN 머지됨; cyc FN 1 0 1; evt stage-result FX ' | 종류=lead-fix'; cyc FN 2 0 0
  seg FP 머지됨; cyc FP 1 0 1; evt stage-result FP ' | 종류=implement'; evt stage-result FP ' | 종류=lead-fix'; cyc FP 2 0 0
} | mk_ledger "$F" 20261013-55555555.md

J="$WORK/f.json"
run_json "$J" --ledger-dir f="$F/docs/pipeline-run"
fixp() { jq -r --arg s "$1" '.segments[] | select(.id == $s) | .cycles[] | select(.n == 2) | .fix_path' "$J"; }
check "4 lead-fix 행" "$(fixp FL)" "리드 수정"
check "4 앞 사이클 행 리뷰 종결=리드 수정" "$(fixp FC)" "리드 수정"
check "4 reconverge" "$(fixp FR)" "재수렴"
check "4 implement" "$(fixp FI)" "구현"
check "4 대조군 — 다른 세그먼트의 lead-fix 는 기록 없음" "$(fixp FN)" "기록 없음"
check "4 우선순위 — lead-fix 가 implement 를 이긴다" "$(fixp FP)" "리드 수정"
check "4 계기 × 수정 경로" "$(jq -c '.repos[0].trigger_by_fix_path.merged["리뷰 P1"]' "$J")" '{"구현":1,"기록 없음":1,"리드 수정":3,"재수렴":1}'
check "4 첫 사이클은 교차에 없다" "$(jq '.repos[0].trigger_by_fix_path.merged | has("첫 사이클")' "$J")" false

# --- 5. 발견 성격 -------------------------------------------------------------------

A="$WORK/a"
mkdir -p "$A/src" "$A/lib" "$A/p" "$A/q" "$A/deep" "$A/docs/reviews"
lines() { local k=1; while [ "$k" -le "$1" ]; do printf 'line %d\n' "$k"; k=$((k + 1)); done; }
lines 20 > "$A/src/x.sh"; lines 20 > "$A/src/y.sh"; lines 20 > "$A/lib/z.sh"
lines 5 > "$A/p/u.sh"; lines 5 > "$A/q/u.sh"; lines 5 > "$A/deep/only.sh"
gitq() { (cd "$A" && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@") >/dev/null 2>&1; }
gitq init -q
gitq add src lib p q deep
gitq commit -q -m base
H1=$(cd "$A" && git rev-parse HEAD)
awk 'NR == 5 || NR == 6 { print "changed " NR; next } { print }' "$A/src/x.sh" > "$A/x.tmp" && mv "$A/x.tmp" "$A/src/x.sh"
awk 'NR == 15 { print "changed"; next } { print }' "$A/src/y.sh" > "$A/y.tmp" && mv "$A/y.tmp" "$A/src/y.sh"
gitq add src
gitq commit -q -m fix
H2=$(cd "$A" && git rev-parse HEAD)

{ printf -- '- **리뷰 모드**: 전체\n'; summary 0 1 2 1; printf '\n## 🟠 P1 (머지 전 수정 권장)\n\n'
  printf -- '- **[logic]** **[차단]** `src/x.sh:1` 첫 사이클 발견 — r\n'
  printf '\n## 🟡 P2 (차후 이슈 등록 권장)\n\n- **[testing]** `src/x.sh:2` P2 는 세지 않는다 — r\n'; } > "$A/docs/reviews/f1.md"
{ printf -- '- **리뷰 모드**: 델타 (기준 사이클 1)\n'; summary 1 7 0 0
  printf '\n## 기준 사이클 재판정\n\n- **[logic]** `src/x.sh:1` (사이클 1, P1-1)\n    - **판정**: 해결됨\n'
  printf -- '- **[logic]** `src/x.sh:9` (사이클 1, P1-2)\n    - **판정**: 미해결\n'
  printf '\n## 🔴 P0 (즉시 수정 필수)\n\n- **[security]** `src/x.sh:5` 수정 덩어리 안 — r\n'
  printf '\n## 🟠 P1 (머지 전 수정 권장)\n\n'
  printf -- '- **[logic]** **[차단]** `src/y.sh:2` 닿은 파일의 덩어리 밖 — r\n'
  printf -- '- **[logic]** **[차단]** `src/x.sh:7` 덩어리 바로 뒤 줄 — r\n'
  printf -- '- **[testing]** **[차단]** `lib/z.sh:3` 닿지 않은 파일 — r\n'
  printf -- '- **[logic]** **[차단]** `only.sh:2` basename 유일 해석 — r\n'
  printf -- '- **[api-contract]** **[차단]** `u.sh:1` basename 모호 — r\n'
  printf -- '- **[logic]** **[차단]** `foo` 앵커 없음 — r\n'
  printf -- '- **[data-integrity]** **[차단]** `src/x.sh:9` 기준 발견 (사이클 1에서 상속, 미해결) — r\n'; } > "$A/docs/reviews/f2.md"
{ printf -- '- **리뷰 모드**: 전체\n'; summary 0 2 0 0; printf '\n## 🟠 P1 (머지 전 수정 권장)\n\n'
  printf -- '- **[logic]** **[차단]** `src/x.sh:5` 전체 재리뷰 — r\n'
  printf -- '- **[logic]** **[차단]** `src/x.sh:3` (상한 사이클 1에서 상속, 재확인 미해결) — r\n'; } > "$A/docs/reviews/f3.md"
{ printf -- '- **리뷰 모드**: 델타\n'; summary 0 1 0 0; printf '\n## 🟠 P1 (머지 전 수정 권장)\n\n'
  printf -- '- **[logic]** **[차단]** `src/x.sh:5` 없는 HEAD — r\n'; } > "$A/docs/reviews/f4.md"
{
  seg F 머지됨
  cyc F 1 0 1 " | 모드=전체 | 리뷰 HEAD=$H1 | 리포트 경로=docs/reviews/f1.md"
  cyc F 2 1 7 " | 모드=델타 | 기준 사이클=1 | 리뷰 HEAD=$H2 | 리포트 경로=docs/reviews/f2.md"
  cyc F 3 0 2 " | 모드=전체 | 리뷰 HEAD=$H2 | 리포트 경로=$A/docs/reviews/f3.md"
  cyc F 4 0 1 " | 모드=델타 | 기준 사이클=3 | 리뷰 HEAD=0000000000000000000000000000000000000001 | 리포트=docs/reviews/f4.md"
} | mk_ledger "$A" 20261014-66666666.md

B="$WORK/b"
mkdir -p "$B/docs/reviews"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:1` 첫 사이클 — r\n'; } > "$B/docs/reviews/g1.md"
{ printf -- '- **발견 요약(부분 복구)**: 🔴 P0 미상 | 🟠 P1 미상 | 🟡 P2 미상 | 🟢 P3 미상 — 최저 계층 absent, 최저 라운드 1\n'
  printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:2` 읽지 않는다 — r\n'; } > "$B/docs/reviews/g3.md"
{ summary 0 2 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:3` git 아님 — r\n'
  printf -- '- **[testing]** **[차단]** 앵커 없음 — r\n'; } > "$B/docs/reviews/g4.md"
{ summary 0 2 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** 하나만 적힘 — r\n'; } > "$B/docs/reviews/g5.md"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** 대조군 — r\n'; } > "$B/docs/reviews/g6.md"
{
  seg G 머지됨
  cyc G 1 0 1 ' | 모드=전체 | 리포트 경로=docs/reviews/g1.md'
  cyc G 2 1 1 ' | 모드=전체 | 리포트 경로=docs/reviews/none.md'
  cyc G 3 0 1 ' | 모드=전체 | 리포트 경로=docs/reviews/g3.md'
  cyc G 4 0 3 ' | 모드=전체 | 리포트 경로=docs/reviews/g4.md'
  cyc G 5 0 2 ' | 모드=전체 | 리포트 경로=docs/reviews/g5.md'
  cyc G 6 0 1 ' | 모드=전체 | 리포트 경로=docs/reviews/g6.md'
} | mk_ledger "$B" 20261014-77777777.md

J="$WORK/ab.json"
run_json "$J" --ledger-dir "$A/docs/pipeline-run" --ledger-dir "$B/docs/pipeline-run"
fd() { jq -r --argjson n "$1" --arg a "$2" '.segments[] | select(.id == "F") | .cycles[] | select(.n == $n) | .findings[] | select(.anchor == $a) | "\(.bucket)|\(.reason)|\(.in_diff)"' "$J"; }
check "5 이름은 레포 뿌리의 basename" "$(jq -r '[.repos[].label] | join(",")' "$J")" "a,b"
check "5 수정이 만든 발견 — 덩어리 안" "$(fd 2 src/x.sh:5)" "수정이 만든 발견|null|true"
check "5 델타 처음 — 닿은 파일의 덩어리 밖" "$(fd 2 src/y.sh:2)" "델타에서 처음 나온 발견|null|true"
check "5 대조군 — 덩어리 바로 뒤 줄은 밖" "$(fd 2 src/x.sh:7)" "델타에서 처음 나온 발견|null|true"
check "5 델타 처음 — 닿지 않은 파일" "$(fd 2 lib/z.sh:3)" "델타에서 처음 나온 발견|null|false"
check "5 basename 앵커의 유일 해석" "$(fd 2 only.sh:2)" "델타에서 처음 나온 발견|null|false"
check "5 basename 앵커의 모호 — 판정 불가" "$(fd 2 u.sh:1)" "판정 불가|경로 해석 불가|null"
check "5 앵커 없음 — 판정 불가" "$(jq -r '.segments[] | select(.id == "F") | .cycles[] | select(.n == 2) | .findings[] | select(.anchor == null) | "\(.bucket)|\(.reason)"' "$J")" "판정 불가|앵커 없음"
check "5 상속·미해결 표지 — 기준 미해결" "$(fd 2 src/x.sh:9)" "기준 미해결|null|null"
check "5 재확인 미해결 표지 — 기준 미해결" "$(fd 3 src/x.sh:3)" "기준 미해결|null|null"
check "5 전체 모드 덩어리 밖 — 기존 코드" "$(fd 3 src/x.sh:5)" "전체 재리뷰 — 기존 코드|null|null"
check "5 없는 HEAD — 판정 불가" "$(fd 4 src/x.sh:5)" "판정 불가|HEAD 없음|null"
check "5 git 아닌 레포 b — 판정 불가" "$(jq -r '.segments[] | select(.id == "G") | .cycles[] | select(.n == 4) | .findings[] | select(.anchor == "src/a.sh:3") | "\(.bucket)|\(.reason)"' "$J")" "판정 불가|git 작업 트리 아님"
check "5 레포 a 버킷" "$(jq -c '.repos[0].findings.buckets' "$J")" '{"기준 미해결":2,"델타에서 처음 나온 발견":4,"수정이 만든 발견":1,"전체 재리뷰 — 기존 코드":1,"판정 불가":3}'
check "5 버킷별 부류 태그" "$(jq -c '.repos[0].findings.by_tag["델타에서 처음 나온 발견"]' "$J")" '{"logic":3,"testing":1}'
check "5 첫 사이클 부류 태그(P2 제외)" "$(jq -c '.repos[0].findings.first_cycle_by_tag' "$J")" '{"logic":1}'
check "5 심각도 분포" "$(jq -c '.repos[0].findings.severity' "$J")" '{"first":{"P0":0,"P1":1,"P2":2,"P3":1},"later":{"P0":1,"P1":10,"P2":0,"P3":0}}'
check "5 재판정 해결됨·미해결" "$(jq -c '.repos[0].findings.rejudge' "$J")" '{"미해결":1,"해결됨":1}'

# --- 6. 리포트 상태 -----------------------------------------------------------------

rs() { jq -r --argjson n "$1" '.segments[] | select(.id == "G") | .cycles[] | select(.n == $n) | .report_state' "$J"; }
check "6 리포트 없음" "$(rs 2)" missing
check "6 발견 요약(부분 복구)는 요약 없음" "$(rs 3)" no_summary
check "6 행과 불일치" "$(rs 4)" row_mismatch
check "6 항목 수 불일치" "$(rs 5)" item_mismatch
check "6 대조군 — 맞는 리포트" "$(rs 6)" ok
check "6 리포트 상태 목록" "$(jq -c '.repos[1].reports | map_values(map(.n))' "$J")" '{"format_mismatch_recorded":[],"gate_tool_gap":[],"item_mismatch":[5],"missing":[2],"no_summary":[3],"path_reuse":[],"row_mismatch":[4]}'
check "6 판독 불가" "$(jq '.repos[1].findings.unread' "$J")" 3
check "6 판독 차이" "$(jq '.repos[1].findings.read_gap' "$J")" 2
check "6 레포 b 버킷" "$(jq '.repos[1].findings.buckets["판정 불가"]' "$J")" 4
eq() {
  jq -r --arg l "$1" '(.repos[] | select(.label == $l) | ([.findings.buckets[]] | add) + .findings.unread + .findings.read_gap) as $lhs
    | ([.segments[] | select(.label == $l) | .cycles[] | select(.n > 1 and .trigger != "중복 행") | .p0 + .p1] | add) as $rhs
    | "\($lhs)=\($rhs)"' "$J"
}
check "6 합 등식 — 레포 a" "$(eq a)" "11=11"
check "6 합 등식 — 레포 b" "$(eq b)" "9=9"

# --- 7. 출력 -----------------------------------------------------------------------

J1="$WORK/o1.json"; J2="$WORK/o2.json"
run_json "$J1" --ledger-dir "$A/docs/pipeline-run" --ledger-dir "$B/docs/pipeline-run"
run_json "$J2" --ledger-dir "$A/docs/pipeline-run" --ledger-dir "$B/docs/pipeline-run"
if cmp -s "$J1" "$J2"; then ok "7 같은 입력 두 번의 JSON 바이트 동일"; else bad "7 같은 입력 두 번의 JSON 바이트 동일" "differ"; fi
check "7 schema 는 첫 키" "$(sed -n 2p "$J1")" '  "schema": "cc-cycle-causes v2",'
check "7 표 머리의 선택자" "$(grep -c '<8자리>-<8hex>.md' "$WORK/out.txt")" 1
check "7 --json 이 있으면 알림 줄 없음" "$(grep -c '^# JSON: --json' "$WORK/out.txt")" 0
bash "$TOOL" --ledger-dir "$A/docs/pipeline-run" > "$WORK/out2.txt" 2>&1
check "7 --json 없으면 마지막 줄이 인자를 알린다" "$(tail -n 1 "$WORK/out2.txt")" "# JSON: --json <경로> 를 주면 같은 집계를 그 경로에 JSON 으로 쓴다"
check "7 원장 디렉터리에 아무것도 쓰지 않는다" "$(ls "$A/docs/pipeline-run" | wc -l | tr -d ' ')" 1
E="$WORK/empty/docs/pipeline-run"; mkdir -p "$E"
bash "$TOOL" --ledger-dir "$E" > "$WORK/out3.txt" 2>&1
rc=$?
check "7 모집단 0 이어도 0 으로 끝나고 표 머리를 낸다" "$rc:$(grep -c '^## 1. 사이클 표' "$WORK/out3.txt")" "0:1"

# --- 8. 인자 -----------------------------------------------------------------------

bash "$TOOL" > /dev/null 2>&1; check "8 --ledger-dir 없음 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$WORK/nope/docs/pipeline-run" > /dev/null 2>&1; check "8 없는 디렉터리 → 3" "$?" 3
bash "$TOOL" --ledger-dir "$A/docs/pipeline-run" --ledger-dir "$A/docs/pipeline-run" > /dev/null 2> "$WORK/err8.txt"
check "8 같은 이름 둘 → 2" "$?" 2
check "8 같은 이름 진단은 이름 붙이기를 알린다" "$(grep -c '<이름>=<dir>' "$WORK/err8.txt")" 1
bash "$TOOL" --ledger-dir x="$A/docs/pipeline-run" --ledger-dir y="$A/docs/pipeline-run" > /dev/null 2>&1
check "8 대조군 — 이름을 붙이면 같은 디렉터리도 0" "$?" 0
bash "$TOOL" --ledger-dir "$A/docs/pipeline-run" --since 2026-1-05 > /dev/null 2>&1; check "8 틀린 날짜 → 2" "$?" 2

# --- 9. 새 필드 행 -------------------------------------------------------------------
# 기록값이 추론과 다르게 나오도록 고른다 — NA c2 는 옛 규칙이면 리뷰 P1 · 구현 이다.

N="$WORK/n"
{
  seg NA 머지됨
  cyc NA 1 0 1 ' | 계기=첫 리뷰 | 수정 경로=- | 앞 HEAD=- | 리뷰 HEAD 고정=건너뜀 | 리포트 형식=정합 | 항목=0/1'
  evt stage-result NA ' | 종류=implement'
  cyc NA 2 0 0 ' | 계기=CI 실패 | 수정 경로=리드 수정,구현 | 앞 HEAD=후손 | 리뷰 HEAD 고정=예 | 리포트 형식=불일치'
  seg NB 머지됨
  cyc NB 1 0 0 ' | 계기=첫 리뷰 | 수정 경로=-'
  cyc NB 2 0 0 ' | 모드=해소 | 계기=해소 리뷰 | 수정 경로=기록 밖 커밋 | 앞 HEAD=비조상'
  cyc NB 3 0 0 ' | 모드=해소 | 계기=해소 리뷰 | 수정 경로=없음 | 앞 HEAD=후손'
} | mk_ledger "$N" 20261015-88888888.md

J="$WORK/n.json"
run_json "$J" --ledger-dir n="$N/docs/pipeline-run"
cy() { jq -c --arg s "$1" --argjson n "$2" ".segments[] | select(.id == \$s) | .cycles[] | select(.n == \$n) | $3" "$J"; }
check "9 기록된 계기가 정본" "$(cy NA 2 '[.trigger, .trigger_source]')" '["CI 실패","recorded"]'
check "9 기록된 수정 경로 — 첫 원소와 전체 집합" "$(cy NA 2 '[.fix_path, .fix_paths, .fix_path_source]')" '["리드 수정",["리드 수정","구현"],"recorded"]'
check "9 앞 HEAD·고정·형식" "$(cy NA 2 '[.prev_head, .head_pin, .report_format]')" '["후손","예","불일치"]'
check "9 사이클 1 의 첫 리뷰 · 수정 경로 -" "$(cy NA 1 '[.trigger, .trigger_source, .fix_path, .fix_paths, .fix_path_source]')" '["첫 리뷰","recorded",null,[],"recorded"]'
check "9 기록 토큰은 나올 때만 키가 생긴다" "$(jq -c '.repos[0].triggers.merged | with_entries(select(.value > 0))' "$J")" '{"CI 실패":1,"첫 리뷰":2,"해소 리뷰":2}'
check "9 첫 리뷰는 교차에 없다" "$(jq '.repos[0].trigger_by_fix_path.merged | has("첫 리뷰")' "$J")" false
check "9 교차의 기록 수정 경로" "$(jq -c '.repos[0].trigger_by_fix_path.merged["해소 리뷰"]' "$J")" '{"기록 밖 커밋":1,"없음":1}'
check "9 기록·추론 건수" "$(jq -c '.repos[0].sources' "$J")" '{"fix_path":{"inferred":0,"recorded":5},"trigger":{"inferred":0,"recorded":5}}'
check "9 해소 리뷰를 앞 HEAD 로 나눈다" "$(jq -c '.repos[0].resolve_by_prev_head' "$J")" '{"비조상":1,"후손":1}'
check "9 형식 불일치(기록) 목록" "$(jq -c '.repos[0].reports.format_mismatch_recorded | map([.segment, .n])' "$J")" '[["NA",2]]'
check "9 표 — 기록 토큰 행과 비율" "$(grep -c "$(printf '^해소 리뷰\t2 (66.7%%)$')" "$WORK/out.txt")" 1
check "9 표 — 첫 리뷰는 비율 없이" "$(grep -c "$(printf '^첫 리뷰\t2$')" "$WORK/out.txt")" 1
check "9 표 — 해소 리뷰 × 앞 HEAD" "$(grep -c "$(printf '^해소 리뷰 × 앞 HEAD\t비조상 1, 후손 1$')" "$WORK/out.txt")" 1
check "9 표 — 교차의 기록 수정 경로 행" "$(grep -c "$(printf '^해소 리뷰 × 기록 밖 커밋\t1$')" "$WORK/out.txt")" 1
check "9 표 — 기록 / 추론 줄" "$(grep -c "$(printf '^기록 / 추론 (cycle 행)\t5 / 0$')" "$WORK/out.txt")" 2
check "9 표 — 형식 불일치(기록) 상태 줄" "$(grep -c "$(printf '\t형식 불일치(기록)\t20261015-88888888\tNA\t')" "$WORK/out.txt")" 1

# --- 10. 옛 행 ------------------------------------------------------------------------
# 새 필드 없는 행은 추론이다 — 그 값 자체는 3·4 절이 이미 옛 규칙대로 단언했다.

J="$WORK/t.json"
run_json "$J" --ledger-dir t="$T/docs/pipeline-run"
check "10 옛 행의 계기는 inferred" "$(jq -c '[.segments[].cycles[].trigger_source] | unique' "$J")" '["inferred"]'
check "10 옛 행의 기록 건수는 0" "$(jq -c '.repos[0].sources.trigger.recorded' "$J")" 0
check "10 옛 원장 표에는 기록 토큰 행·해소 리뷰 줄이 없다" "$(grep -c -E '^(첫 리뷰|해소 리뷰)' "$WORK/out.txt")" 0
J="$WORK/f.json"
run_json "$J" --ledger-dir f="$F/docs/pipeline-run"
check "10 옛 행의 수정 경로는 inferred 이고 집합은 그 하나" "$(jq -c '.segments[] | select(.id == "FP") | .cycles[] | select(.n == 2) | [.fix_paths, .fix_path_source]' "$J")" '[["리드 수정"],"inferred"]'
check "10 옛 행 사이클 1 의 수정 경로 집합은 비었다" "$(jq -c '.segments[] | select(.id == "FP") | .cycles[] | select(.n == 1) | .fix_paths' "$J")" '[]'

# --- 11. 머리 셈 ------------------------------------------------------------------------

H="$WORK/h"
mkdir -p "$H/docs/reviews"
{ summary 0 2 0 0; printf '\n## 🟠 P1\n\n### P1-1. [logic] 첫 머리\n\n- **위치**: `src/a.sh:3`\n- **[testing]** 머리 아래 불릿 `src/z.sh:9`\n\n'
  printf '### P1-2. 둘째 머리 (사이클 1에서 상속, 미해결)\n\n- **위치**: `src/b.sh:4`\n'; } > "$H/docs/reviews/h1.md"
{ summary 0 2 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:1` 하나 — r\n- **[logic]** **[차단]** `src/a.sh:2` 둘 — r\n'; } > "$H/docs/reviews/h2.md"
{ summary 0 2 0 0; printf '\n## 🟠 P1\n\n### P1-1. [logic] 머리\n\n- **위치**: `src/a.sh:3`\n\n### F-01. 다른 머리\n\n- **[logic]** **[차단]** `src/a.sh:5` 다른 머리 아래 — r\n'; } > "$H/docs/reviews/h3.md"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n### F-01. 다른 머리만\n\n- **위치**: `src/a.sh:3`\n'; } > "$H/docs/reviews/h4.md"
{ summary 1 1 0 0; printf '\n## 🔴 P0\n\n### P0-1 [security] 머리\n\n- **위치**: `src/c.sh:7`\n\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:1` 불릿 — r\n'; } > "$H/docs/reviews/h5.md"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n### P1-10 열 번째\n\n- **위치**: `src/a.sh:3`\n\n### P1-x 숫자 아닌 id\n\n- **[logic]** **[차단]** `src/a.sh:4` — r\n'; } > "$H/docs/reviews/h6.md"
{
  seg HS 머지됨
  cyc HS 1 0 0 ' | 모드=전체 | 리포트 경로=docs/reviews/h0.md'
  # 행의 P0/P1 은 요약과 같게 둔다 — 상태가 행 불일치가 아니라 항목 셈으로 갈리게.
  k=2
  for r in h1:0:2 h2:0:2 h3:0:2 h4:0:1 h5:1:1 h6:0:1; do
    IFS=: read -r rn r0 r1 <<< "$r"
    cyc HS "$k" "$r0" "$r1" " | 모드=전체 | 리포트 경로=docs/reviews/$rn.md"; k=$((k + 1))
  done
} | mk_ledger "$H" 20261016-99999999.md

J="$WORK/h.json"
run_json "$J" --ledger-dir h="$H/docs/pipeline-run"
hs() { jq -c --argjson n "$1" ".segments[] | select(.id == \"HS\") | .cycles[] | select(.n == \$n) | $2" "$J"; }
check "11 항목 수 — 없음·머리만·불릿만·섞임·다른 머리만·절마다·숫자 id 만" "$(jq -c '[.segments[] | select(.id == "HS") | .cycles[] | .findings | length]' "$J")" '[0,2,2,1,0,2,1]'
check "11 머리 블록의 분류·앵커 — 머리 아래 불릿은 항목이 아니다" "$(hs 2 '[.findings[] | [.tag, .anchor]]')" '[["logic","src/a.sh:3"],[null,"src/b.sh:4"]]'
check "11 머리 블록의 상속 표지" "$(hs 2 '[.findings[].bucket]')" '["판정 불가","기준 미해결"]'
check "11 절마다 따로 — P0 머리와 P1 불릿" "$(hs 6 '[.findings[] | [.severity, .anchor]]')" '[["P0","src/c.sh:7"],["P1","src/a.sh:1"]]'
check "11 대조군 — 다른 머리만 쓴 리포트는 옛 셈(0)이라 항목 수 불일치" "$(hs 5 '.report_state')" '"item_mismatch"'
check "11 머리 셈이 맞는 리포트는 ok — 머리만·불릿만·숫자 id 만" "$(jq -c '[.segments[] | select(.id == "HS") | .cycles[] | select(.n == 2 or .n == 3 or .n == 7) | .report_state]' "$J")" '["ok","ok","ok"]'

# --- 12. 경로 재사용 --------------------------------------------------------------------

U="$WORK/u"
mkdir -p "$U/docs/reviews"
for r in r s n; do { summary 0 1 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:1` 하나 — r\n'; } > "$U/docs/reviews/$r.md"; done
{
  seg RU 머지됨
  cyc RU 1 0 1 ' | 모드=전체 | 리뷰 HEAD=aaaa111 | 리포트 경로=docs/reviews/x.md'
  cyc RU 2 0 1 ' | 모드=해소 | 리뷰 HEAD=bbbb222 | 리포트 경로=docs/reviews/r.md'
  cyc RU 3 0 1 " | 모드=해소 | 리뷰 HEAD=cccc333 | 리포트 경로=$(cd "$U" && pwd)/docs/reviews/r.md"
  seg RS 머지됨
  cyc RS 1 0 1 ' | 모드=전체 | 리뷰 HEAD=dddd444 | 리포트 경로=docs/reviews/s.md'
  cyc RS 2 0 1 ' | 모드=전체 | 리뷰 HEAD=dddd4445555 | 리포트 경로=docs/reviews/s.md'
  seg RN 머지됨
  cyc RN 1 0 1 ' | 모드=전체 | 리뷰 HEAD=eeee666 | 리포트 경로=docs/reviews/n.md | 리포트 형식=정합'
  cyc RN 2 0 1 ' | 모드=전체 | 리뷰 HEAD=ffff777 | 리포트 경로=docs/reviews/n.md | 리포트 형식=정합'
} | mk_ledger "$U" 20261016-aaaaaaaa.md

J="$WORK/u.json"
run_json "$J" --ledger-dir u="$U/docs/pipeline-run"
st() { jq -c --arg s "$1" '[.segments[] | select(.id == $s) | .cycles[] | [.report_state, (.findings | length)]]' "$J"; }
check "12 같은 경로·다른 HEAD — 앞 행은 경로 재사용, 뒤 행이 리포트를 읽는다(상대·절대 경로 같음)" "$(st RU)" '[["missing",0],["path_reuse",0],["ok",1]]'
check "12 대조군 — 같은 HEAD(짧은 sha 접두)는 재사용이 아니다" "$(st RS)" '[["ok",1],["ok",1]]'
check "12 대조군 — 리포트 형식이 있는 새 행은 재사용 판정을 받지 않는다" "$(st RN)" '[["ok",1],["ok",1]]'
check "12 경로 재사용 목록" "$(jq -c '.repos[0].reports.path_reuse | map([.segment, .n])' "$J")" '[["RU",2]]'
check "12 판독 불가에 산입" "$(jq '.repos[0].findings.unread' "$J")" 1
check "12 표 — 경로 재사용 상태 줄" "$(grep -c "$(printf '\t판독 불가(경로 재사용)\t20261016-aaaaaaaa\tRU\t사이클 2\t')" "$WORK/out.txt")" 1

# --- 13. 레포 지도 ·  14. 고정 ref 삭제 ----------------------------------------------------

gitin() { local d="$1"; shift; (cd "$d" && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@") >/dev/null 2>&1; }
ML="$WORK/main"; MO="$WORK/other"
# 두 레포의 커밋이 같은 sha 가 되지 않도록 내용을 다르게 둔다.
for d in "$ML" "$MO"; do
  mkdir -p "$d/src"; lines 10 > "$d/src/f.sh"; basename "$d" > "$d/src/name"
  gitin "$d" init -q; gitin "$d" add src; gitin "$d" commit -q -m base
done
L1=$(cd "$ML" && git rev-parse HEAD); O1=$(cd "$MO" && git rev-parse HEAD)
for d in "$ML" "$MO"; do
  awk 'NR == 8 { print "changed"; next } { print }' "$d/src/f.sh" > "$d/f.tmp" && mv "$d/f.tmp" "$d/src/f.sh"
  gitin "$d" add src; gitin "$d" commit -q -m fix
done
L2=$(cd "$ML" && git rev-parse HEAD); O2=$(cd "$MO" && git rev-parse HEAD)
mkdir -p "$ML/docs/reviews"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/f.sh:2` 기존 코드 — r\n'; } > "$ML/docs/reviews/m.md"
{
  seg SL 머지됨 ' | 레포=Nharu/other'
  cyc SL 1 0 1 " | 모드=전체 | 리뷰 HEAD=$O1 | 리포트 경로=docs/reviews/m.md"
  cyc SL 2 0 1 " | 모드=전체 | 리뷰 HEAD=$O2 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  seg SM 머지됨 ' | 레포=Nharu/main'
  cyc SM 1 0 1 " | 모드=전체 | 리뷰 HEAD=$L1 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  cyc SM 2 0 1 " | 모드=전체 | 리뷰 HEAD=$L2 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  seg SN 머지됨
  cyc SN 1 0 1 " | 모드=전체 | 리뷰 HEAD=$L1 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  cyc SN 2 0 1 " | 모드=전체 | 리뷰 HEAD=$L2 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  seg SX 머지됨 ' | 레포=Nharu/main'
  cyc SX 1 0 1 " | 모드=전체 | 리뷰 HEAD=$L1 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  cyc SX 2 0 1 ' | 모드=전체 | 리뷰 HEAD=0000000000000000000000000000000000000002 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합'
  seg SP 머지됨
  cyc SP 1 0 1 " | 모드=전체 | 리뷰 HEAD=$L1 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  cyc SP 2 0 1 ' | 모드=전체 | 리뷰 HEAD=0000000000000000000000000000000000000003 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합 | 리뷰 HEAD 고정=예'
  seg SQ 머지됨 ' | 레포=Nharu/third'
  cyc SQ 1 0 1 " | 모드=전체 | 리뷰 HEAD=$L1 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
  cyc SQ 2 0 1 " | 모드=전체 | 리뷰 HEAD=$L2 | 리포트 경로=docs/reviews/m.md | 리포트 형식=정합"
} | mk_ledger "$ML" 20261017-bbbbbbbb.md

JM="$WORK/m-map.json"; JN="$WORK/m-nomap.json"
run_json "$JM" --ledger-dir main="$ML/docs/pipeline-run" --repo Nharu/other="$MO"
check "13 지도를 주면 0 으로 끝난다" "$?" 0
run_json "$JN" --ledger-dir main="$ML/docs/pipeline-run"
rsn() { jq -r --arg s "$2" '[.segments[] | select(.id == $s) | .cycles[] | select(.n == 2) | .findings[] | "\(.bucket)|\(.reason)"] | join(",")' "$1"; }
check "13 지도 — 다른 레포 세그먼트의 HEAD 를 그 레포에서 찾는다" "$(rsn "$JM" SL)" "전체 재리뷰 — 기존 코드|null"
check "13 지도 없음 — 다른 레포 세그먼트는 레포 미지정" "$(rsn "$JN" SL)" "판정 불가|레포 미지정"
check "13 대조군 — 지도에 없는 다른 레포라도 원장 레포에서 객체를 찾으면 레포 미지정이 아니다" "$(rsn "$JM" SQ)" "전체 재리뷰 — 기존 코드|null"
check "13 이름 부분이 원장 이름과 같은 세그먼트는 원장 레포에서 찾는다" "$(rsn "$JN" SM)" "전체 재리뷰 — 기존 코드|null"
check "13 레포 없는 세그먼트는 원장 레포에서 찾는다" "$(rsn "$JN" SN)" "전체 재리뷰 — 기존 코드|null"
check "13 원장 레포 세그먼트의 없는 객체는 그대로 HEAD 없음" "$(rsn "$JN" SX)" "판정 불가|HEAD 없음"
check "13 원장 레포 세그먼트의 판정은 지도와 무관하다" \
  "$(jq -c '[.segments[] | select(.id != "SL") | .cycles[].findings[] | [.segment, .bucket, .reason]]' "$JM")" \
  "$(jq -c '[.segments[] | select(.id != "SL") | .cycles[].findings[] | [.segment, .bucket, .reason]]' "$JN")"
check "13 발견 객체가 런·세그먼트·레포를 싣는다" "$(jq -c '[.. | objects | select(.segment? == "SL" and .reason? != null) | [.run, .repo, .reason]] | unique' "$JN")" '[["20261017-bbbbbbbb","Nharu/other","레포 미지정"]]'
check "14 고정했다고 기록된 HEAD 가 없으면 고정 ref 삭제" "$(rsn "$JN" SP)" "판정 불가|고정 ref 삭제"
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo other="$MO" > /dev/null 2>&1; check "13 --repo 키에 / 없음 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo a/b/c="$MO" > /dev/null 2>&1; check "13 --repo 키에 / 둘 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo Nharu/other= > /dev/null 2>&1; check "13 --repo 빈 값 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo Nharu/other > /dev/null 2>&1; check "13 --repo 에 = 없음 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo Nharu/other="$MO" --repo Nharu/other="$ML" > /dev/null 2>&1; check "13 --repo 같은 키 둘 → 2" "$?" 2
bash "$TOOL" --ledger-dir "$ML/docs/pipeline-run" --repo Nharu/other="$WORK/nope" > /dev/null 2>&1; check "13 --repo 없는 경로 → 3" "$?" 3

# --- 15. 라우터 판단 사유 ------------------------------------------------------------------

RT="$WORK/rt"
mkdir -p "$RT/docs/reviews"
RTA=$(cd "$RT" && pwd)
{
  seg RJ 머지됨
  cyc RJ 1 0 0 ' | 리포트 경로=docs/reviews/rj1.md'
  printf -- '- `자율 승인` | 교대=0 | kind=skill | 결정=act | 세그먼트=RJ | 리포트 경로=%s/docs/reviews/rj2.md | 계기=라우터 판단 | 근거=계기 사유: 사람 지시로 재확인; 원래 근거 | prev=x\n' "$RTA"
  cyc RJ 2 0 0 ' | 계기=라우터 판단 | 리포트 경로=docs/reviews/rj2.md'
  seg RK 머지됨
  cyc RK 1 0 1 ' | 리포트 경로=docs/reviews/rk1.md'
  printf -- '- `자율 승인` | 교대=0 | kind=skill | 결정=act | 세그먼트=RK | 리포트 경로=%s/docs/reviews/rk2.md | 계기=리뷰 P1 | 근거=계기 사유: 아니다; 원래 | prev=x\n' "$RTA"
  cyc RK 2 0 1 ' | 계기=리뷰 P1 | 리포트 경로=docs/reviews/rk2.md'
} | mk_ledger "$RT" 20261018-cccccccc.md

J="$WORK/rt.json"
run_json "$J" --ledger-dir rt="$RT/docs/pipeline-run"
check "15 파견 행 근거 머리의 사유가 사이클에 붙는다(상대·절대 경로 같음)" "$(cy RJ 2 '.router_reason')" '"사람 지시로 재확인"'
check "15 대조군 — 라우터 판단이 아닌 파견의 근거 머리는 사유가 아니다" "$(cy RK 2 '.router_reason')" null
check "15 사유 목록" "$(jq -c '.repos[0].router_reasons' "$J")" '[{"n":2,"reason":"사람 지시로 재확인","run":"20261018-cccccccc","segment":"RJ"}]'
check "15 표의 사유 절" "$(grep -c "$(printf '^rt\t20261018-cccccccc\tRJ\t사이클 2\t사람 지시로 재확인$')" "$WORK/out.txt")" 1

# --- 16. 판독 차이 목록 ----------------------------------------------------------------------

G="$WORK/g"
mkdir -p "$G/docs/reviews"
{ summary 0 1 0 0; printf '\n## 🟠 P1\n\n- **[logic]** **[차단]** `src/a.sh:1` 하나 — r\n'; } > "$G/docs/reviews/one.md"
{
  seg GA 머지됨
  cyc GA 1 0 1 ' | 리포트 경로=docs/reviews/one.md | 리포트 형식=정합 | 항목=0/2'
  cyc GA 2 0 1 ' | 리포트 경로=docs/reviews/one.md | 리포트 형식=정합 | 항목=0/1'
  cyc GA 3 0 1 ' | 리포트 경로=docs/reviews/one.md | 리포트 형식=정합 | 항목=2'
  cyc GA 4 0 1 ' | 리포트 경로=docs/reviews/one.md | 리포트 형식=불일치 | 항목=0/3'
} | mk_ledger "$G" 20261018-dddddddd.md

J="$WORK/g.json"
run_json "$J" --ledger-dir g="$G/docs/pipeline-run"
check "16 정합 행과 도구 셈이 다르면 판독 차이(P0/P1 꼴과 한 수 꼴), 불일치 행은 아니다" "$(jq -c '.repos[0].reports.gate_tool_gap | map(.n)' "$J")" '[1,3]'
check "16 표 — 판독 차이 상태 줄" "$(grep -c "$(printf '\tgate·도구 판독 차이\t')" "$WORK/out.txt")" 2
check "16 정상 픽스처의 판독 차이 목록은 비었다" "$(jq '[.repos[].reports.gate_tool_gap | length] | add' "$J1")" 0
check "16 새 필드 픽스처의 판독 차이 목록도 비었다" "$(jq '[.repos[].reports.gate_tool_gap | length] | add' "$JN")" 0

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
