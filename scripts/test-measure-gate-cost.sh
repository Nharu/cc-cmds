#!/usr/bin/env bash
# Test scripts/measure-gate-cost.sh.
#
# The measurement harness is itself a claim — "this is what the verification
# costs" — and a broken one is worse than none, because a slice that changed
# nothing would report an improvement and land on it.
#
# WHAT IS DELIBERATELY NOT ASSERTED: the actual number. The row-at-a-time loop
# costs 3n+2 processes today, and pinning that here would make this suite fail on
# exactly the commit that succeeds at making it cheaper. What is asserted instead
# are the properties that have to hold for ANY implementation for the number to
# be worth reading:
#
#   - it counts at all (a counter stuck at zero reports a free verification)
#   - it is reproducible (V1's claim is zero variance across runs; a metric that
#     moves on its own cannot show a slice's effect)
#   - it is read-only against the ledger it measures
#
# Usage: bash scripts/test-measure-gate-cost.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
MEASURE="$script_dir/measure-gate-cost.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

field() { sed -n "s/^$2=//p" "$1" | sed -n 1p; }

[ -f "$MEASURE" ] || { printf 'FAIL: measure-gate-cost.sh not found\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. It runs and reports the shape a caller can parse.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 10 > "$WORK/run1.txt" 2>"$WORK/run1.err"
rc=$?
check "10행 원장에서 측정이 성공한다" "$rc" "0"

check "센 행수가 요청한 행수와 같다" "$(field "$WORK/run1.txt" rows)" "10"

total1=$(field "$WORK/run1.txt" processes_total)
if [ -n "$total1" ] && [ "$total1" -gt 0 ] 2>/dev/null; then
  ok "프로세스를 실제로 센다 (0 이 아니다)"
else
  bad "프로세스 계수" "processes_total 이 '$total1' 이다 — 0 이거나 비어 있으면 검증이 공짜라고 보고하는 것이다"
fi

# The verdict must still be reachable through the stubbed PATH. A measurement
# that breaks the thing it measures is measuring something else.
check "측정 중에도 체인 판정이 무결로 나온다" "$(field "$WORK/run1.txt" verdict_rc)" "0"

# ---------------------------------------------------------------------------
# 2. Reproducibility. V1's claim is that this metric has zero variance across
#    runs; if it drifts, a slice's effect cannot be read off it.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 10 > "$WORK/run2.txt" 2>&1
total2=$(field "$WORK/run2.txt" processes_total)
check "같은 입력의 두 측정이 같은 값을 낸다 (분산 0)" "$total1" "$total2"

# ---------------------------------------------------------------------------
# 3. It scales with the input. A counter wired to a constant would pass every
#    assertion above.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 20 > "$WORK/run3.txt" 2>&1
total3=$(field "$WORK/run3.txt" processes_total)
if [ -n "$total3" ] && [ "$total3" -gt "$total1" ] 2>/dev/null; then
  ok "행수가 늘면 프로세스 수도 는다 (상수에 묶인 계수기가 아니다)"
else
  bad "입력에 대한 반응" "10행 $total1, 20행 $total3 — 늘지 않았다"
fi

# ---------------------------------------------------------------------------
# 4. Read-only against the ledger it measures. This is the property that keeps
#    a measurement from changing its own corpus, which is how the design session
#    put twenty rows into six historical ledgers.
# ---------------------------------------------------------------------------
LG="$WORK/fixed.md"
hdr='## 실행 MEASURE'
prev=$(printf '%s' "$hdr" | shasum -a 256 | cut -d' ' -f1)
{
  printf '%s\n' "$hdr"
  i=1
  while [ "$i" -le 5 ]; do
    row='- `act` | 순번='"$i"' | prev='"$prev"
    printf '%s\n' "$row"
    prev=$(printf '%s' "$row" | shasum -a 256 | cut -d' ' -f1)
    i=$((i + 1))
  done
} > "$LG"
digest_before=$(shasum -a 256 < "$LG" | cut -d' ' -f1)
size_before=$(wc -c < "$LG" | tr -d ' ')

bash "$MEASURE" --ledger "$LG" > "$WORK/run4.txt" 2>&1
rc4=$?
check "주어진 원장에 대한 측정이 성공한다" "$rc4" "0"
check "측정이 원장 바이트를 바꾸지 않는다" "$(shasum -a 256 < "$LG" | cut -d' ' -f1)" "$digest_before"
check "측정이 원장에 행을 붙이지 않는다" "$(wc -c < "$LG" | tr -d ' ')" "$size_before"
check "주어진 원장의 행수를 그대로 센다" "$(field "$WORK/run4.txt" rows)" "5"

# ---------------------------------------------------------------------------
# 5. A ledger that does not exist is a refusal, not a zero.
# ---------------------------------------------------------------------------
bash "$MEASURE" --ledger "$WORK/nope.md" >/dev/null 2>&1
check "없는 원장은 0 이 아니라 거부다" "$?" "2"

printf 'test-measure-gate-cost: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
