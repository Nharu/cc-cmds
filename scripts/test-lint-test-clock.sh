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

printf 'test-lint-test-clock: %d passed, %d failed\n' "$passed" "$failures"
(( failures == 0 ))
