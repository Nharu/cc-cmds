#!/usr/bin/env bash
# Test scripts/measure-spawn-count.sh against its committed baseline.
#
# The tool is a claim — "this is how many processes a unit of resident work
# costs" — and the slices that follow it land on what it reports, so a broken
# count is worse than none: a slice that changed nothing would read as cheaper.
#
# TWO KINDS OF ASSERTION, because only one of them is host independent.
#
#   - The STATIC count reads source, not a run, so it holds on every host: for
#     each of the eight target scripts, the exec sites by absolute path (which no
#     PATH stub can see) are no more than the baseline's, and every name a target
#     runs through PATH is on the stub list. A name off the list would be a
#     process the run count cannot see.
#   - The RUN count depends on the host. It is asserted only when the six
#     measuring conditions the baseline records (`uname -s`, the bash version,
#     the digests of the stub list, the unit specs and the fixtures, and the U8
#     caller) all equal the present ones. Then: the calibration target counts 6,
#     every unit counts the same twice, no command the trap saw run by name went
#     around its stub, and a unit with a target file meets it. When any condition
#     differs nothing is measured and one line per differing condition goes to
#     stderr, so a run on another host is never read as a pass of these.
#
# A TARGET THAT REWRITES PATH is the case the stub-bypass assertion is for: a
# rewrite that puts the system directories first would hide every command after
# it from the stubs. Each target the static count reports with a `pathrewrite`
# line must be run by a unit named in `REWRITE_UNITS` below, and that unit must
# show stub lines and no bypass — so a rewrite is measured, not assumed away. A
# rewriting target no unit runs fails the suite.
#
# WHAT IS DELIBERATELY NOT ASSERTED: that the counts equal the baseline. That is
# `measure-spawn-count.sh --reproduce`, which is not part of this suite — a slice
# that makes a unit cheaper must not fail here for having done so.
#
# A TARGET FILE is `tests/fixtures/measure-spawn-count/targets/<unit>` holding
# the unit's cap as a whole percentage of its baseline (`60` for 60%). The unit
# meets it when its count is at most floor(cap × baseline / 100) and below the
# baseline. The slices that make a unit cheaper add the file with the change.
#
# Usage: bash scripts/test-measure-spawn-count.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
MEASURE="$script_dir/measure-spawn-count.sh"
BASELINE="$repo_root/tests/fixtures/measure-spawn-count/baseline.tsv"
TARGETS_DIR="$repo_root/tests/fixtures/measure-spawn-count/targets"
UNITS="U1 U2 U3 U4 U5 U6 U7 U8"
# The unit that runs each target which rewrites PATH: `<target> <unit>` lines.
REWRITE_UNITS="plugins/cc-cmds/orchestrator/gate.sh U8
plugins/cc-cmds/hooks/gate-pretool.sh U7"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-spawn-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

field() { sed -n "s/^$2=//p" "$1" | sed -n 1p; }
# base <kind> <key> — the baseline's value for that row.
base() { awk -F '\t' -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }' "$BASELINE"; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

finish() {
  printf 'test-measure-spawn-count: %d passed, %d failed\n' "$passed" "$failed"
  [ "$failed" = 0 ] || exit 1
  exit 0
}

[ -f "$MEASURE" ] || { printf 'FAIL: measure-spawn-count.sh not found\n' >&2; exit 2; }
# A missing baseline is a harness defect, not a pass with nothing to compare.
[ -f "$BASELINE" ] || { printf 'FAIL: baseline not found: %s\n' "$BASELINE" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. The static count, on every host.
# ---------------------------------------------------------------------------
bash "$MEASURE" --static > "$WORK/static.txt" 2>"$WORK/static.err"
check "정적 셈이 성공한다" "$?" "0"

rows=$(awk -F '\t' '$1 == "abspath"' "$BASELINE" | wc -l | tr -d ' ')
check "기준선에 절대 경로 실행 행이 여덟 있다" "$rows" "8"
while IFS="$(printf '\t')" read -r kind key want; do
  [ "$kind" = abspath ] || continue
  got=$(field "$WORK/static.txt" "abspath.$key")
  if is_int "$got" && is_int "$want" && [ "$got" -le "$want" ]; then
    ok "절대 경로 실행 자리 수가 기준선 이하다 ($key: $got ≤ $want)"
  else
    bad "절대 경로 실행 자리 수 ($key)" "지금 '$got', 기준선 '$want' — 스텁이 보지 못하는 실행이 늘면 실행 셈이 그만큼 덜 센다"
  fi
  got=$(field "$WORK/static.txt" "outside.$key")
  if [ "$got" = 0 ]; then
    ok "PATH 로 부르는 이름이 모두 스텁 목록에 있다 ($key)"
  else
    bad "스텁 목록 밖 이름 ($key)" "${got:-없음}개 — $(field "$WORK/static.txt" "outside-names.$key"). 목록 밖 이름의 프로세스는 셈에 잡히지 않는다"
  fi
done < "$BASELINE"

# ---------------------------------------------------------------------------
# 2. The measuring conditions. Any difference skips every run assertion.
# ---------------------------------------------------------------------------
bash "$MEASURE" --cond > "$WORK/cond.now" 2>"$WORK/cond.err"
check "측정 조건을 읽는다" "$?" "0"
awk -F '\t' '$1 == "cond"' "$BASELINE" > "$WORK/cond.base"
check "기준선에 측정 조건 행이 여섯 있다" "$(wc -l < "$WORK/cond.base" | tr -d ' ')" "6"

differ=""
while IFS="$(printf '\t')" read -r kind key want; do
  now=$(awk -F '\t' -v n="$key" '$2 == n { print $3; exit }' "$WORK/cond.now")
  [ "$now" = "$want" ] || differ="${differ}  ${key}: 기준선 '${want}', 지금 '${now}'
"
done < "$WORK/cond.base"
if [ -n "$differ" ]; then
  printf '측정 조건이 기준선과 다름 — 실행 셈 단언 건너뜀\n%s' "$differ" >&2
  finish
fi

# ---------------------------------------------------------------------------
# 3. The run count, on the host the baseline was measured on.
# ---------------------------------------------------------------------------
bash "$MEASURE" --calibrate > "$WORK/cal.txt" 2>"$WORK/cal.err"
check "교정 대상의 셈이 6 이다" "$(field "$WORK/cal.txt" calibrate)" "6"
check "교정 대상의 제자리 exec 표시가 하나다 (sed)" "$(field "$WORK/cal.txt" calibrate.self)" "1"
check "교정 대상의 스텁 줄이 모두 귀속된다" "$(field "$WORK/cal.txt" calibrate.unattributed)" "0"

for u in $UNITS; do
  bash "$MEASURE" --unit "$u" > "$WORK/$u.1" 2>"$WORK/$u.1.err"
  rc1=$?
  bash "$MEASURE" --unit "$u" > "$WORK/$u.2" 2>"$WORK/$u.2.err"
  rc2=$?
  if [ "$rc1" != 0 ] || [ "$rc2" != 0 ]; then
    bad "$u 측정" "종료 코드 $rc1, $rc2 — $(tail -n 3 "$WORK/$u.1.err" "$WORK/$u.2.err" | tr '\n' ' ')"
    continue
  fi
  n1=$(field "$WORK/$u.1" "$u"); n2=$(field "$WORK/$u.2" "$u")
  check "$u 의 두 측정이 같은 셈을 낸다" "$n1" "$n2"
  check "$u 에서 스텁을 거치지 않은 명령이 없다" "$(field "$WORK/$u.1" "$u.bypass")" "0"
  tf="$TARGETS_DIR/$u"
  [ -f "$tf" ] || continue
  cap=$(sed -n 1p "$tf" | tr -d ' ')
  bl=$(base unit "$u")
  if ! is_int "$cap" || ! is_int "$bl" || ! is_int "$n1"; then
    bad "$u 목표" "목표 '$cap', 기준선 '$bl', 셈 '$n1' 가 정수가 아니다"
    continue
  fi
  limit=$((bl * cap / 100))
  if [ "$n1" -le "$limit" ] && [ "$n1" -lt "$bl" ]; then
    ok "$u 가 목표를 지킨다 ($n1 ≤ $limit = ${cap}% × $bl)"
  else
    bad "$u 목표" "셈 $n1, 상한 $limit (${cap}% × 기준선 $bl)"
  fi
done

# ---------------------------------------------------------------------------
# 4. Every target that rewrites PATH is still counted through the stubs.
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  t=${line#pathrewrite.}; t=${t%%=*}; v=${line#*=}
  [ "$v" = none ] && continue
  u=$(printf '%s\n' "$REWRITE_UNITS" | awk -v t="$t" '$1 == t { print $2; exit }')
  if [ -z "$u" ]; then
    bad "PATH 를 다시 쓰는 대상의 단위 ($t)" "줄 $v 에서 PATH 를 다시 쓰는데 그 대상을 띄우는 단위가 REWRITE_UNITS 에 없다"
    continue
  fi
  ex=$(field "$WORK/$u.1" "$u.exec"); by=$(field "$WORK/$u.1" "$u.bypass")
  if is_int "$ex" && [ "$ex" -gt 0 ] && [ "$by" = 0 ]; then
    ok "PATH 를 다시 쓰는 $t 의 단위 $u 가 스텁을 거쳐 센다 (스텁 줄 $ex, 우회 0)"
  else
    bad "PATH 를 다시 쓰는 $t 의 단위 $u" "스텁 줄 '${ex}', 우회 '${by}' — 다시 쓰기 뒤의 명령이 스텁을 비켜 셈에서 빠진다"
  fi
done <<EOF
$(grep '^pathrewrite\.' "$WORK/static.txt")
EOF

finish
