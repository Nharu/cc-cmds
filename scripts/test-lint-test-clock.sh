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
# The `elapsed-compare` rule and the four rules beside it are held by cases
# this script writes into a scratch scan root, one file each: a hit and a pass
# per detected `elapsed-compare` form; a hit, a pass and an escape for
# `stub-lifetime` and `poll-count` (a nested loop included); the retired marker
# at a line end, alone on a comment line, and beside an elapsed-time hit in
# test-gate.sh that it no longer excuses; and a baseline entry under scripts/,
# which is refused when read and never written. The last runs a copy of the
# lint in a scratch tree, which also holds the shared fixtures the lint scans
# besides the test scripts. The case text sits inside quotes or is assembled
# from pieces — the marker, the disable comments, the clock reads and the
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
for name in FAIL-1-small-margin FAIL-2-elapsed-bound FAIL-5-stub-lifetime FAIL-6-poll-count; do
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
DIS="# lint-test-clock"': disable=elapsed-compare'
DIS_STUB="# lint-test-clock"': disable=stub-lifetime'
DIS_POLL="# lint-test-clock"': disable=poll-count'
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
form inline '[ $(( '"$NOW"' - m )) -''lt 60 ]' '[ $(( '"$NOW"' - 60 )) -''lt "$m" ]' 'm=$(stat'' -f %m f)'
form seconds '[ $'"$S"' -''lt 5 ]' '[ $'"$S"' -''gt 5 ]' ':'
mkcase clock-minus-const other.sh 'n=$(( '"$NOW"' - 30 ))' '[ "$n" -''lt 5 ] && echo y'
expect_case "elapsed-compare: 시각에서 상수를 뺀 값은 경과가 아니다" clock-minus-const 0
mkcase derived other.sh "$EL" 'd=$el' '[ "$d" -''lt 5 ] && echo y'
expect_case "elapsed-compare: 경과 변수로 받은 변수도 경과다" derived 1 "other.sh:3:elapsed-compare"
mkcase scope other.sh 'f() {' "  $EL" '}' "$CMP_LT && echo y"
expect_case "elapsed-compare: 다른 함수의 같은 이름은 경과가 아니다" scope 0
mkcase logical other.sh "$EL" 'r=$( echo \' "  \"\$($CMP_LT && echo y)\" )"
expect_case "elapsed-compare: 백슬래시로 이은 논리 줄을 첫 물리 줄로 낸다" logical 1 "other.sh:2:elapsed-compare"

# stub-lifetime: a background sleep with a literal duration, redirections
# between them included; a foreground sleep, also inside a background subshell,
# and a duration that is not a literal pass.
mkcase stub-hit other.sh 'sleep 30 &'
expect_case "stub-lifetime: 배경 sleep 리터럴을 잡는다" stub-hit 1 "other.sh:1:stub-lifetime"
mkcase stub-redir other.sh 'command sleep 5 >/dev/null 2>&1 & pid=$!'
expect_case "stub-lifetime: command 와 리다이렉션을 건너 잡는다" stub-redir 1 "other.sh:1:stub-lifetime"
mkcase stub-miss other.sh '( echo a; sleep 1; echo b ) & w=$!' 'sleep 1 && echo y' 'sleep "$d" &' 'echo "sleep 5 &"'
expect_case "stub-lifetime: 배경 서브셸 안 전경 sleep·&&·리터럴 아닌 길이·문자열은 잡지 않는다" stub-miss 0
mkcase stub-dis other.sh "$DIS_STUB 수명 자체가 단언의 주제다" 'sleep 30 &'
expect_case "stub-lifetime: 윗줄 탈출 주석으로 받는다" stub-dis 0

# poll-count: a counted loop that sleeps, an outer counted loop whose inner
# loop sleeps; a counted loop with no sleep and an uncounted outer loop around
# a counted inner one with no sleep pass.
mkcase poll-hit other.sh 'i=0' 'while [ "$i" -lt 9 ]; do sleep 1; i=$((i + 1)); done'
expect_case "poll-count: 숫자 리터럴 카운터에 sleep 하는 루프를 잡는다" poll-hit 1 "other.sh:2:poll-count"
mkcase poll-nested other.sh 'for i in $(seq 1 3); do' '  while [ ! -f x ]; do sleep 1; done' 'done'
expect_case "poll-count: 안쪽 루프의 sleep 도 바깥 횟수 루프의 본문이다" poll-nested 1 "other.sh:1:poll-count"
mkcase poll-miss other.sh 'for i in $(seq 1 9); do echo "$i"; done' \
  'while [ ! -f x ]; do' '  for i in {1..3}; do echo "$i"; done' '  sleep 1' 'done'
expect_case "poll-count: sleep 없는 횟수 루프와 횟수 없는 폴링은 잡지 않는다" poll-miss 0
mkcase poll-dis other.sh "$DIS_POLL 횟수 자체가 단언의 주제다" 'for i in {1..3}; do sleep 1; done'
expect_case "poll-count: 윗줄 탈출 주석으로 받는다" poll-dis 0

# retired-marker: the marker fails wherever it is, and no longer answers an
# elapsed-time hit in test-gate.sh, which takes an escape comment instead.
mkcase rm-end other.sh "x=1 $MK 경과 상한"
expect_case "retired-marker: 줄 끝 표지를 잡는다" rm-end 1 "other.sh:1:retired-marker"
mkcase rm-comment other.sh "$MK 경과 상한" 'check "c" \' '  a a'
expect_case "retired-marker: 주석 전용 줄의 표지를 잡는다" rm-comment 1 "other.sh:1:retired-marker"
mkcase rm-tg test-gate.sh "$EL" "check \"c\" \"\$($CMP_LT && echo y)\" y $MK 경과 상한"
expect_case "retired-marker: test-gate.sh 의 경과 적중은 표지가 있어도 실패한다" rm-tg 1 \
  "test-gate.sh:2:elapsed-compare" "test-gate.sh:2:retired-marker"
mkcase tg-dis test-gate.sh "$EL" "r=\$($CMP_LT && echo y) $DIS check c 가 판정" 'check "c" "$r" y'
expect_case "test-gate.sh 의 경과 적중도 탈출 주석으로 받는다" tg-dis 0

# baseline-scope: an entry under scripts/ is refused and answers nothing.
mkcase scope test-gate.sh "$EL" "check \"c\" \"\$($CMP_LT && echo y)\" y"
printf '%s\n' "scripts/test-gate.sh|elapsed-compare|check \"c\" \"\$($CMP_LT && echo y)\" y" > "$work/scope.baseline"
CASE_BASELINE="$work/scope.baseline" expect_case "baseline-scope: scripts/ 경로 항목은 거절되고 적중을 받지 않는다" scope 1 \
  "scope.baseline:1:baseline-scope" "test-gate.sh:2:elapsed-compare"

# In the tree layout the lint scans the test scripts and the shared fixtures,
# and --write-baseline writes no entry under scripts/.
tree="$work/tree"
mkdir -p "$tree/scripts"
cp "$lint" "$tree/scripts/lint-test-clock.sh"
printf '%s\n' '#!/usr/bin/env bash' 'n='"$NOW" 'echo "$((n ''+ 5))"' > "$tree/scripts/test-x.sh"
printf '%s\n' 'sleep 60 &' > "$tree/scripts/run-fixture.sh"
printf '%s\n' 'for i in {1..5}; do sleep 1; done' > "$tree/scripts/wait-fixture.sh"
printf '%s\n' 'sleep 60 &' > "$tree/scripts/other-fixture.sh"
ec=0
BASELINE="$work/tree.baseline" bash "$tree/scripts/lint-test-clock.sh" --write-baseline >/dev/null 2>"$work/err" || ec=$?
got=$(reported "$work/err" | paste -s -d ' ' -)
want_set="scripts/run-fixture.sh:1:stub-lifetime scripts/test-x.sh:3:clock-margin scripts/wait-fixture.sh:1:poll-count"
if [[ "$ec" == 1 && "$got" == "$want_set" ]] && ! grep -q '^scripts/' "$work/tree.baseline"; then
  pass "--write-baseline 은 scripts/ 적중을 쓰지 않고 실패로 남기며, 공용 픽스처 둘을 훑는다"
else
  fail "트리 배치 — exit=$ec, 위반 「${got}」(기대 「${want_set}」)"
  sed 's/^/    /' "$work/err" >&2
fi

printf 'test-lint-test-clock: %d passed, %d failed\n' "$passed" "$failures"
(( failures == 0 ))
