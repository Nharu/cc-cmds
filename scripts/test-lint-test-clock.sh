#!/usr/bin/env bash
# Test scripts/lint-test-clock.sh against tests/fixtures/lint-test-clock/.
#
# Each fixture is a directory with one or more `*.sh` files and, optionally, a
# `baseline` the lint compares with (a fixture without one runs against an
# empty baseline). The directory name encodes the expected exit code:
#   OK-*   → expected exit 0
#   FAIL-* → expected exit 1
#
# A FAIL fixture ships an `expected.txt` listing every violation it should
# produce, one per line, compared as a set:
#
#   <file basename>:<line number>:<rule>      a hit or a reasonless disable
#   stale:<file basename>:<rule>              a baseline entry that no longer hits
#
# The exit code alone cannot see a violation reported for the wrong rule or the
# wrong line, so the reported set is what is held in place.
#
# Beyond the fixtures: `--write-baseline` over a FAIL fixture writes a baseline
# that the next run passes with, a reasonless disable cannot be written away,
# and a scan root with nothing to scan exits 2.
#
# The `elapsed-compare` rule and the load marker are held by cases this script
# writes into a scratch scan root, one file each: a hit and a pass per detected
# form, the three ways a hit connects to a judgement line, the marker's own four
# checks, the marker above a backslash-ended judgement line (taken) and above a
# one-line one (refused), and a test-gate.sh entry in the baseline (refused).
# The case text is assembled from pieces — the marker, the clock reads and the
# elapsed reads never appear whole in this file — so the lint passes over this
# script with no disable comment and no baseline entry.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-test-clock"
lint="$script_dir/lint-test-clock.sh"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-test-clock.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failures=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# reported <stderr file> — the violations as expected.txt spells them.
reported() {
  {
    sed -n 's/^FAIL: \([^ ]*\):\([0-9][0-9]*\) — \([a-z-]*\):.*/\1:\2:\3/p' "$1"
    sed -n 's/^FAIL: baseline entry no longer hits — \([^|]*\)|\([^|]*\)|.*/stale:\1:\2/p' "$1"
  } | LC_ALL=C sort
}

for fixture in "$fixtures"/*/; do
  fixture=${fixture%/}
  name=$(basename "$fixture")
  case "$name" in
    OK-*)   want=0 ;;
    FAIL-*) want=1 ;;
    *) fail "$name: unrecognized prefix"; continue ;;
  esac

  ec=0
  SCAN_ROOT="$fixture" BASELINE="$fixture/baseline" bash "$lint" >/dev/null 2>"$work/err" || ec=$?
  ok=1
  if [[ "$ec" != "$want" ]]; then
    ok=0
    echo "  $name: exit=$ec, expected=$want" >&2
    sed 's/^/    /' "$work/err" >&2
  fi
  if [[ -f "$fixture/expected.txt" ]]; then
    actual=$(reported "$work/err")
    expected=$(LC_ALL=C sort "$fixture/expected.txt")
    if [[ "$actual" != "$expected" ]]; then
      ok=0
      echo "  $name: violations differ from expected.txt" >&2
      echo "  expected:" >&2; printf '%s\n' "$expected" | sed 's/^/    /' >&2
      echo "  actual:" >&2; printf '%s\n' "$actual" | sed 's/^/    /' >&2
    fi
  elif [[ "$want" == 1 ]]; then
    ok=0
    echo "  $name: a FAIL fixture needs an expected.txt" >&2
  fi
  if (( ok )); then pass "$name (exit=$ec)"; else fail "$name"; fi
done

# --write-baseline takes the hits it finds, and the next run passes with them.
for name in FAIL-1-small-margin FAIL-2-elapsed-bound; do
  b="$work/$name.baseline"
  ec=0
  SCAN_ROOT="$fixtures/$name" BASELINE="$b" bash "$lint" --write-baseline >/dev/null 2>&1 || ec=$?
  entries=$(grep -cv '^#' "$b" 2>/dev/null || true)
  want_entries=$(grep -c . "$fixtures/$name/expected.txt")
  ec2=0
  SCAN_ROOT="$fixtures/$name" BASELINE="$b" bash "$lint" >/dev/null 2>&1 || ec2=$?
  if [[ "$ec/$entries/$ec2" == "0/$want_entries/0" ]]; then
    pass "--write-baseline: $name 의 적중 ${entries}개를 받고 다시 돌리면 통과한다"
  else
    fail "--write-baseline: $name 쓰기 exit=$ec, 항목 ${entries}개(기대 $want_entries), 다시 돌린 exit=$ec2"
  fi
done

# A reasonless disable is not a hit, so writing the baseline does not clear it.
b="$work/reasonless.baseline"
ec=0
SCAN_ROOT="$fixtures/FAIL-3-disable-no-reason" BASELINE="$b" bash "$lint" --write-baseline >/dev/null 2>"$work/err" || ec=$?
if [[ "$ec" == 1 ]] && grep -q 'disable-no-reason' "$work/err"; then
  pass "--write-baseline: 사유 없는 해제 주석은 기준선으로 덮이지 않는다"
else
  fail "--write-baseline: 사유 없는 해제 주석 픽스처에서 exit=$ec"
fi

# Nothing to scan is not a verdict.
mkdir -p "$work/empty"
ec=0
SCAN_ROOT="$work/empty" BASELINE="$work/none" bash "$lint" >/dev/null 2>&1 || ec=$?
if [[ "$ec" == 2 ]]; then
  pass "검사할 파일이 없으면 exit 2"
else
  fail "검사할 파일이 없는데 exit=$ec (기대 2)"
fi

cases="$work/cases"

# mkcase <name> <file name> <line>... — a scan root holding one case file.
mkcase() {
  local d="$cases/$1" f="$2"
  shift 2
  rm -rf "$d"; mkdir -p "$d"
  printf '%s\n' "$@" > "$d/$f"
}

# expect_case <label> <name> <exit> [<violation>...] — the exit code and the
# violation set, spelt as expected.txt spells them.
expect_case() {
  local label="$1" name="$2" want="$3" ec=0 got want_set
  shift 3
  SCAN_ROOT="$cases/$name" BASELINE="${CASE_BASELINE:-$work/none}" bash "$lint" >/dev/null 2>"$work/err" || ec=$?
  got=$(reported "$work/err" | paste -s -d ' ' -)
  want_set=$(printf '%s\n' "$@" | LC_ALL=C sort | paste -s -d ' ' -)
  if [[ "$ec" == "$want" && "$got" == "$want_set" ]]; then
    pass "$label"
  else
    fail "$label — exit=$ec(기대 $want), 위반 「${got}」(기대 「${want_set}」)"
    sed 's/^/    /' "$work/err" >&2
  fi
}

S='SEC''ONDS'
EL="el=\$$S"
NOW='$(da''te +%s)'
MK="# gate"'-load:'
GI="# gate"'-isolation: 변동'
DIS="# lint-test-clock"': disable=elapsed-compare'
CMP_LT='[ "$el" -''lt 5 ]'

# One hit and one pass per detected form. A pass is the lower-bound twin, which
# the rule leaves alone, or a value that is not elapsed.
form() {
  local tag="$1" hit="$2" miss="$3" pre="${4:-$EL}"
  mkcase "form-$tag-hit" other.sh "$pre" "$hit && echo y"
  expect_case "elapsed-compare: $tag 꼴을 잡는다" "form-$tag-hit" 1 "other.sh:2:elapsed-compare"
  mkcase "form-$tag-miss" other.sh "$pre" "$miss && echo y"
  expect_case "elapsed-compare: $tag 의 짝은 잡지 않는다" "form-$tag-miss" 0
}
form lt "$CMP_LT" '[ "$el" -''gt 5 ]'
form le '[ "$el" -''le 5 ]' '[ "$el" -''ge 5 ]'
form gt-mirror '[ 5 -''gt "$el" ]' '[ 5 -''lt "$el" ]'
form ge-mirror '[ 5 -''ge "$el" ]' '[ 5 -''le "$el" ]'
form arith-lt '(( el ''< 5 ))' '(( el ''> 5 ))'
form arith-le '(( el ''<= 5 ))' '(( el ''>= 5 ))'
form eq '[ "$el" -''eq 0 ]' '[ "$n" -''eq 0 ]'
form arith-eq '(( el ''== 0 ))' '(( n ''== 0 ))'
form inline '[ $(( '"$NOW"' - m )) -''lt 60 ]' '[ $(( '"$NOW"' - 60 )) -''lt "$m" ]' 'm=$(stat -f %m f)'
form seconds '[ $'"$S"' -''lt 5 ]' '[ $'"$S"' -''gt 5 ]' ':'
mkcase clock-minus-const other.sh 'n=$(( '"$NOW"' - 30 ))' '[ "$n" -''lt 5 ] && echo y'
expect_case "elapsed-compare: 시각에서 상수를 뺀 값은 경과가 아니다" clock-minus-const 0
mkcase derived other.sh "$EL" 'd=$el' '[ "$d" -''lt 5 ] && echo y'
expect_case "elapsed-compare: 경과 변수로 받은 변수도 경과다" derived 1 "other.sh:3:elapsed-compare"
mkcase scope other.sh 'f() {' "  $EL" '}' "$CMP_LT && echo y"
expect_case "elapsed-compare: 다른 함수의 같은 이름은 경과가 아니다" scope 0
mkcase logical other.sh "$EL" 'r=$( echo \' "  \"\$($CMP_LT && echo y)\" )"
expect_case "elapsed-compare: 백슬래시로 이은 논리 줄을 첫 물리 줄로 낸다" logical 1 "other.sh:2:elapsed-compare"

# The three ways a hit in test-gate.sh connects to its judgement line.
mkcase conn-check test-gate.sh "$EL" "check \"c\" \"\$($CMP_LT && echo y)\" y $MK 경과 상한"
expect_case "연결 — 같은 논리 줄의 check 에 표지가 있으면 받는다" conn-check 0
mkcase conn-check-bare test-gate.sh "$EL" "check \"c\" \"\$($CMP_LT && echo y)\" y"
expect_case "연결 — 표지 없는 check 는 거절한다" conn-check-bare 1 "test-gate.sh:2:elapsed-compare"
mkcase conn-above test-gate.sh "$EL" "$MK 경과 상한" 'check "c" \' "  \"\$($CMP_LT && echo y)\" y"
expect_case "윗줄 꼴 — 백슬래시로 끝나는 여러 줄 check 위의 표지는 받는다" conn-above 0
mkcase conn-above-one test-gate.sh "$EL" "$MK 경과 상한" "check \"c\" \"\$($CMP_LT && echo y)\" y"
expect_case "윗줄 꼴 — 줄 끝에 달 수 있는 판정 줄 위의 표지는 거절한다" conn-above-one 1 \
  "test-gate.sh:2:gate-load-orphan" "test-gate.sh:3:elapsed-compare"
mkcase conn-if test-gate.sh "$EL" "if $CMP_LT; then ok \"c\"" "else bad \"c\" \"\${el}s\"; fi $MK 경과 상한"
expect_case "연결 — if 조건이면 블록 안 bad 줄의 표지를 본다" conn-if 0
mkcase conn-if-bare test-gate.sh "$EL" "if $CMP_LT; then ok \"c\"" "else bad \"c\" \"\${el}s\"; fi"
expect_case "연결 — if 블록의 bad 줄에 표지가 없으면 거절한다" conn-if-bare 1 "test-gate.sh:2:elapsed-compare"
mkcase conn-other test-gate.sh "$EL" "r=\$($CMP_LT && echo y)" 'check "c" "$r" y'
expect_case "연결 — 판정 줄이 없는 비교는 거절한다" conn-other 1 "test-gate.sh:2:elapsed-compare"
mkcase conn-other-dis test-gate.sh "$EL" "r=\$($CMP_LT && echo y) $DIS check c 가 판정" 'check "c" "$r" y'
expect_case "연결 — 판정 줄이 없는 비교는 탈출 주석으로 받는다" conn-other-dis 0
mkcase bound-marked test-gate.sh "t0=$NOW" "t1=$NOW" "check \"c\" \"\$([ \$((t1 - t0)) -''le 1 ] && echo y)\" y $MK 경과 상한"
expect_case "표지는 test-gate.sh 의 elapsed-bound 도 받는다" bound-marked 0
mkcase margin-marked test-gate.sh "t0=$NOW" "check \"c\" \"\$((t0 ''+ 5))\" 1 $MK 여유"
expect_case "표지는 clock-margin 을 받지 않는다" margin-marked 1 "test-gate.sh:2:clock-margin"

# The marker's own four checks.
mkcase mk-reason test-gate.sh "check \"c\" a a $MK"
expect_case "표지 검사 — 빈 사유" mk-reason 1 "test-gate.sh:1:gate-load-reason"
mkcase mk-dash test-gate.sh "check \"c\" a a $MK 가 — 나"
expect_case "표지 검사 — 사유의 ' — '" mk-dash 1 "test-gate.sh:1:gate-load-reason"
mkcase mk-orphan test-gate.sh "x=1 $MK 경과 상한"
expect_case "표지 검사 — check/bad 가 없는 줄" mk-orphan 1 "test-gate.sh:1:gate-load-orphan"
mkcase mk-outside other.sh "check \"c\" a a $MK 경과 상한"
expect_case "표지 검사 — test-gate.sh 밖" mk-outside 1 "other.sh:1:gate-load-outside"
mkcase mk-order test-gate.sh "check \"c\" a a $GI $MK 경과 상한"
expect_case "표지 검사 — gate-isolation 뒤의 표지" mk-order 1 "test-gate.sh:1:gate-load-order"

# A test-gate.sh hit is never answered by the baseline, and is never written.
mkcase tg-baseline test-gate.sh "$EL" "check \"c\" \"\$($CMP_LT && echo y)\" y"
printf '%s\n' "test-gate.sh|elapsed-compare|check \"c\" \"\$($CMP_LT && echo y)\" y" > "$work/tg.baseline"
CASE_BASELINE="$work/tg.baseline" expect_case "test-gate.sh 의 경과 적중은 기준선이 받지 않는다" tg-baseline 1 "test-gate.sh:2:elapsed-compare"
ec=0
SCAN_ROOT="$cases/tg-baseline" BASELINE="$work/tg.baseline" bash "$lint" >/dev/null 2>"$work/err" || ec=$?
if [[ "$ec" == 1 ]] && grep -q '^FAIL: baseline entry refused — test-gate.sh|elapsed-compare|' "$work/err"; then
  pass "test-gate.sh 의 경과 적중 기준선 항목은 그 자체로 실패한다"
else
  fail "test-gate.sh 기준선 항목 — exit=$ec, 거절 줄 없음"
fi
ec=0
SCAN_ROOT="$cases/tg-baseline" BASELINE="$work/tg-w.baseline" bash "$lint" --write-baseline >/dev/null 2>&1 || ec=$?
if [[ "$ec" == 1 ]] && ! grep -q '^test-gate.sh|' "$work/tg-w.baseline"; then
  pass "--write-baseline 은 test-gate.sh 의 경과 적중을 쓰지 않고 실패로 남긴다"
else
  fail "--write-baseline 이 test-gate.sh 적중을 다뤘다 — exit=$ec"
fi

printf 'test-lint-test-clock: %d passed, %d failed\n' "$passed" "$failures"
(( failures == 0 ))
