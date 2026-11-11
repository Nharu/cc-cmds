#!/usr/bin/env bash
# Test scripts/measure-test-slots.sh.
#
# The verdict is what sets the unattended default of scripts/test-slots.sh, so
# a report that reads the wrong rows turns slots on (or leaves them off) for
# every unattended run of the host. What is pinned:
#   - `report` on crafted results.tsv files: on with auto, on with the 1.5×
#     number, off, a tie within 2% going to auto, too few valid repetitions and
#     a six-hour cap line both being `판정: 판정불가`, and invalid trials and
#     warm-ups left out of the medians;
#   - a small `run` with the mock run, the load reading and the CPU count
#     swapped for doubles: the TSV's head and line shape, the warm-ups and the
#     form order of each repetition, a second `run` adding nothing, a trial
#     that fails once being run again, one that fails twice ending `run` with
#     1, the cap stopping `run` before a trial, and an uncommitted change being
#     refused.
#
# Nothing here runs the real gate suite or check-push: the mock run is a
# double, and the measured repository is a throwaway one under the work
# directory.
#
# Usage: bash scripts/test-measure-test-slots.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
measure="$script_dir/measure-test-slots.sh"

for v in $(compgen -e | grep -E '^(CC_PIPELINE_|CC_TEST_SLOT|CHECK_PUSH_|MTS_)' || true); do unset "$v"; done

failures=0
passed=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-test-slots.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

[ -f "$measure" ] || { echo "FAIL: measure-test-slots.sh not found" >&2; exit 2; }

# ---- report ----------------------------------------------------------------------

T=$(printf '\t')
# head <dir>: the head lines of a results file for CPU 18, levels 8,24.
head_of() {
  mkdir -p "$1"
  {
    printf '# measure-test-slots v1\n# commit=abc123\n# cpus=18\n# levels=8,24\n# reps=3\n'
    printf '# forms=off:0 auto:auto x15:27\n# work=direct=0a sections=- goals=-\n# config=x\n# limit=head 모드\n'
  } > "$1/results.tsv"
}
# row <dir> <form> <level> <rep> <valid> <makespan>: start load 100, peak
# 110, the load wait at its cap, 200 processes outside, no failed run, no slot
# wait, 50 seconds spent.
row() {
  printf 'trial\t%s\t%s\t%s\t%s\t%s\t-\t-\t100\t110\t1\t200\t0\t0\t50\n' "$2" "$3" "$4" "$5" "$6" >> "$1/results.tsv"
}
# rows <dir> <form> <level> <m1> <m2> <m3>: three valid repetitions
rows() { row "$1" "$2" "$3" 1 1 "$4"; row "$1" "$2" "$3" 2 1 "$5"; row "$1" "$2" "$3" 3 1 "$6"; }
verdict() { bash "$measure" report --work "$1" 2>/dev/null | tail -n 1; }

D="$WORK/r-on-auto"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 104 105 106
rows "$D" off 24 300 310 305; rows "$D" auto 24 260 270 280; rows "$D" x15 24 290 295 300
check "auto 가 끔보다 5% 넘게 짧으면 켬 auto" "$(verdict "$D")" "판정: 켬 auto"

D="$WORK/r-on-x15"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 100 101 102
rows "$D" off 24 300 310 305; rows "$D" auto 24 280 285 290; rows "$D" x15 24 250 255 260
check "1.5배가 auto 보다 2% 넘게 짧으면 켬 27" "$(verdict "$D")" "판정: 켬 27"

D="$WORK/r-tie"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 100 101 102
rows "$D" off 24 300 310 305; rows "$D" auto 24 260 262 264; rows "$D" x15 24 255 258 260
check "두 켠 꼴이 2% 안이면 auto 를 고른다" "$(verdict "$D")" "판정: 켬 auto"

D="$WORK/r-off-hi"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 100 101 102
rows "$D" off 24 300 310 305; rows "$D" auto 24 295 296 297; rows "$D" x15 24 298 299 300
check "높은 수준에서 5% 안이면 끔" "$(verdict "$D")" "판정: 끔"

D="$WORK/r-off-lo"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 110 112 111; rows "$D" x15 8 120 121 122
rows "$D" off 24 300 310 305; rows "$D" auto 24 260 270 280; rows "$D" x15 24 290 295 300
check "낮은 수준에서 5% 넘게 길면 끔" "$(verdict "$D")" "판정: 끔"

D="$WORK/r-off-c3"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 104 105 106
rows "$D" off 24 300 310 305; rows "$D" x15 24 400 400 400
row "$D" auto 24 1 1 100; row "$D" auto 24 2 1 470; row "$D" auto 24 3 0 100
check "조건 1·2 는 서고 조건 3 만 무너지는 결과다" "$(bash "$measure" report --work "$D" 2>/dev/null | grep -c '조건 1 성립 · 조건 2 성립 · 조건 3 불성립')" "1"
check "높은 수준에서 끔보다 짧은 반복이 둘 미만이면 끔" "$(verdict "$D")" "판정: 끔"

D="$WORK/r-few"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 104 105 106
rows "$D" off 24 300 310 305; rows "$D" auto 24 260 270 280
row "$D" x15 24 1 1 250; row "$D" x15 24 2 0 240; row "$D" x15 24 3 0 230
check "유효 반복이 2회 미만인 꼴이 있으면 판정불가" "$(verdict "$D")" "판정: 판정불가"

D="$WORK/r-cap"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 104 105 106
rows "$D" off 24 300 310 305; rows "$D" auto 24 260 270 280; rows "$D" x15 24 290 295 300
printf 'cap%s21650\n' "$T" >> "$D/results.tsv"
check "상한 기록이 있으면 반복 수와 상관없이 판정불가" "$(verdict "$D")" "판정: 판정불가"

D="$WORK/r-excl"; head_of "$D"
rows "$D" off 8 100 102 101; rows "$D" auto 8 100 103 99; rows "$D" x15 8 104 105 106
rows "$D" off 24 300 310 305; rows "$D" auto 24 295 296 297; rows "$D" x15 24 298 299 300
row "$D" auto 24 4 0 10; row "$D" auto 24 5 0 10; row "$D" auto 8 w 1 10; row "$D" auto 24 w 1 10
check "무효 시도와 예열은 중앙값에 들지 않는다" "$(verdict "$D")" "판정: 끔"
out=$(bash "$measure" report --work "$D" 2>/dev/null)
case "$out" in
  *"auto(auto)${T}24${T}3${T}296${T}295${T}297"*) pass "표는 꼴·수준마다 유효 반복 수·M·최소·최대를 싣는다" ;;
  *) fail "표의 auto/24 줄이 다르다: $out" ;;
esac
case "$out" in
  *"잰 커밋: abc123"*"한계: head 모드"*) pass "표 머리에 잰 커밋과 한계를 싣는다" ;;
  *) fail "표 머리가 다르다: $out" ;;
esac
case "$out" in
  *"auto${T}수준 24${T}반복 4${T}시작 부하 100${T}부하 대기 상한 도달${T}makespan 10초${T}무효"*) pass "시도마다 시작 부하와 대기 상한 도달 여부를 싣는다" ;;
  *) fail "시도 줄이 다르다: $out" ;;
esac

# ---- run ---------------------------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO"
(
  cd "$REPO" && git init -q && git config user.email t@example.invalid && git config user.name t \
    && printf 'x\n' > f && git add f && git commit -q -m init
) || { echo "FAIL: fixture repository" >&2; exit 2; }
sha=$(cd "$REPO" && git rev-parse HEAD)

TASK="$WORK/task.sh"
cat > "$TASK" <<'TASK_EOF'
# The mock run double: records what it was given and passes, unless the file
# named by MTS_TEST_FAIL exists, which it consumes once per line.
printf '%s %s %s %s\n' "$CC_TEST_SLOTS" "${CC_PIPELINE_RUN_ID:-none}" "$MTS_DIRECT" "${CC_TEST_SLOTS_DIR##*/}" >> "$MTS_TEST_LOG"
if [ -n "${MTS_TEST_FAIL:-}" ] && [ -s "$MTS_TEST_FAIL" ]; then
  sed -n '2,$p' "$MTS_TEST_FAIL" > "$MTS_TEST_FAIL.n"; mv "$MTS_TEST_FAIL.n" "$MTS_TEST_FAIL"
  exit 1
fi
exit 0
TASK_EOF

mrun() {
  env MTS_REPO="$REPO" MTS_TASK="$TASK" MTS_LOAD_CMD='echo 0.5' MTS_CPUS=4 \
    MTS_GAP_SECS=0 MTS_SAMPLE_SECS=1 MTS_LOAD_WAIT_MAX=0 CC_PIPELINE_RUN_ID=outer \
    MTS_TEST_LOG="$WORK/task.log" "$@"
}
trials() { grep -c '^trial' "$1/results.tsv"; }

W="$WORK/w1"
mrun bash "$measure" run --work "$W" --levels 1,2 --reps 3 --direct 0a > /dev/null 2>&1
rc=$?
check "작은 run 은 0 으로 끝난다" "$rc" "0"
check "results.tsv 머리에 잰 커밋을 적는다" "$(sed -n 's/^# commit=//p' "$W/results.tsv")" "$sha"
check "1.5배 꼴은 CPU 4 의 1.5배 올림 6 이다" "$(sed -n 's/^# forms=//p' "$W/results.tsv")" "off:0 auto:auto x15:6"
case "$(sed -n 's/^# limit=//p' "$W/results.tsv")" in
  *"head 모드"*) pass "머리에 head 모드 한계를 적는다" ;;
  *) fail "머리에 한계가 없다" ;;
esac
check "예열 2 + 수준 2 × 꼴 3 × 반복 3 = 20 시도" "$(trials "$W")" "20"
check "시도 줄은 15 칸이다" "$(awk -F'\t' '$1 == "trial" && NF != 15 { n++ } END { print n + 0 }' "$W/results.tsv")" "0"
check "예열은 낮은 수준의 켠 두 꼴이 먼저 돈다" \
  "$(awk -F'\t' '$1 == "trial" { printf "%s/%s/%s ", $2, $3, $4 }' "$W/results.tsv" | cut -d' ' -f1-5)" \
  "auto/1/w x15/1/w off/1/1 auto/1/1 x15/1/1"
check "반복마다 꼴의 순서를 돌린다" \
  "$(awk -F'\t' '$1 == "trial" && $3 == 2 { printf "%s ", $2 }' "$W/results.tsv")" \
  "off auto x15 auto x15 off x15 off auto "
check "수준 2 시도는 모의 런을 둘 띄운다" "$(wc -l < "$WORK/task.log" | tr -d ' ')" "$((2 + 3 * 3 * 1 + 3 * 3 * 2))"
check "모의 런은 꼴의 값·비운 무인 판별·direct 절·꼴마다의 저장소로 돈다" \
  "$(LC_ALL=C sort -u "$WORK/task.log" | tr '\n' ',')" "0 none 0a store-off,6 none 0a store-x15,auto none 0a store-auto,"

: > "$WORK/task.log"
mrun bash "$measure" run --work "$W" --levels 1,2 --reps 3 --direct 0a > /dev/null 2>&1
check "다시 돌리면 기록된 시도를 건너뛴다" "$(trials "$W") $(wc -l < "$WORK/task.log" | tr -d ' ')" "20 0"

mrun bash "$measure" run --work "$W" --levels 1,2 --reps 2 --direct 0a > /dev/null 2>&1
check "다른 설정으로 같은 작업 디렉터리를 이으면 2" "$?" "2"

W="$WORK/w2"
printf 'a\n' > "$WORK/fail1"
mrun MTS_TEST_FAIL="$WORK/fail1" bash "$measure" run --work "$W" --levels 1 --reps 1 > /dev/null 2>&1
check "한 번 실패한 시도는 다시 돌고 run 은 0" "$? $(awk -F'\t' '$1 == "trial" && $2 == "auto" && $4 == "w" { printf "%s", $5 }' "$W/results.tsv")" "0 01"
check "실패한 런의 기록을 남긴다" "$(ls "$W/failed" | wc -l | tr -d ' ')" "1"

W="$WORK/w3"
printf 'a\nb\n' > "$WORK/fail2"
mrun MTS_TEST_FAIL="$WORK/fail2" bash "$measure" run --work "$W" --levels 1 --reps 1 > /dev/null 2>&1
check "두 번 실패하면 run 은 1 이고 다음 시도를 돌리지 않는다" "$? $(trials "$W")" "1 2"

W="$WORK/w4"
mrun MTS_CAP_SECS=0 bash "$measure" run --work "$W" --levels 1 --reps 1 > /dev/null 2>&1
check "상한에 닿으면 시도 없이 0 으로 멈추고 상한을 적는다" "$? $(trials "$W") $(grep -c '^cap' "$W/results.tsv")" "0 0 1"
check "상한에서 멈춘 결과는 판정불가" "$(verdict "$W")" "판정: 판정불가"

printf 'y\n' > "$REPO/f"
mrun bash "$measure" run --work "$WORK/w5" --levels 1 --reps 1 > /dev/null 2> "$WORK/err5"
rc=$?
check "커밋하지 않은 변경이 있으면 2" "$rc" "2"
case "$(cat "$WORK/err5")" in
  *"커밋하지 않은 변경"*) pass "거절이 커밋하지 않은 변경을 말한다" ;;
  *) fail "거절 문면이 다르다: $(cat "$WORK/err5")" ;;
esac
check "거절은 결과를 만들지 않는다" "$([ -e "$WORK/w5/results.tsv" ] && echo 있음 || echo 없음)" "없음"

# A floor on the pass count, so a case that silently stops running fails here.
if (( failures == 0 && passed < 30 )); then
  fail "통과 수 $passed 가 하한 30 보다 적다 — 경우가 조용히 빠졌다"
fi

echo "test-measure-test-slots: $passed passed, $failures failed"
(( failures == 0 ))
