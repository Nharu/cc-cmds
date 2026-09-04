#!/usr/bin/env bash
# Test scripts/measure-gate-cost.sh.
#
# The measurement harness is itself a claim — "this is what the verification
# costs" — and a broken one is worse than none, because a slice that changed
# nothing would report an improvement and land on it.
#
# WHAT IS DELIBERATELY NOT ASSERTED: an arbitrary process count as a number.
# Pinning "3n+2" here would make this suite fail on exactly the commit that
# succeeds at making it cheaper. What is asserted instead are the properties that
# have to hold for ANY implementation for the number to be worth reading:
#
#   - the counting apparatus counts at all — established against the FROZEN
#     REFERENCE, which still forks per row
#   - it is reproducible (V1's claim is zero variance across runs; a metric that
#     moves on its own cannot show a slice's effect)
#   - it is read-only against the ledger it measures
#
# WHY THE APPARATUS IS PROVED ON THE REFERENCE AND NOT ON THE LIVE FUNCTION.
# The live verifier now walks the whole ledger in one `perl` process, and `perl`
# is not one of the four tools the stubs shadow, so its true count is zero. A
# guard reading "processes_total > 0" therefore fired on success, and — worse —
# it could no longer tell a DEAD COUNTER from a FORK-FREE VERIFIER, which are the
# two states it existed to separate. Both produce zero.
#
# The separation is recovered by running the same apparatus a second time against
# a workload whose fork count is a known positive number. The vendored reference
# is that workload: it is committed, pinned by sha256 in the equivalence suite,
# and forbidden to be modernized, so it keeps issuing 3n+2 and can serve as a
# fixed yardstick. Zero there means the stubs are not on PATH, the counter file
# is not being written, or the names no longer match — a broken harness, with no
# other reading available. Zero from the live function, with the yardstick
# reading positive in the same run, means the forks are genuinely gone.
#
# Usage: bash scripts/test-measure-gate-cost.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
MEASURE="$script_dir/measure-gate-cost.sh"
REFERENCE="$repo_root/tests/fixtures/gate-chain-equiv/reference-v1.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

field() { sed -n "s/^$2=//p" "$1" | sed -n 1p; }

[ -f "$MEASURE" ] || { printf 'FAIL: measure-gate-cost.sh not found\n' >&2; exit 2; }
# A missing yardstick is a harness defect, not a zero. Reporting "0 forks" from a
# measurement whose reference could not be loaded is precisely the free-lunch
# claim this file exists to refuse.
[ -f "$REFERENCE" ] || { printf 'FAIL: reference-v1.sh not found: %s\n' "$REFERENCE" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. The counting apparatus is alive. Measured against the frozen reference,
#    which is still the row-at-a-time loop and therefore forks a known positive
#    number of times.
#
#    The shim below hands measure-gate-cost.sh a file to source in place of
#    gate.sh through its EXISTING `GATE_SH` seam — no contract of that script is
#    widened for this. All the shim owes is a `gate_chain_verify` reading the
#    same two globals the real one reads.
# ---------------------------------------------------------------------------
SHIM="$WORK/gate-reference-shim.sh"
cat > "$SHIM" <<SHIM_EOF
gate_chain_verify() { bash "$REFERENCE" "\$LEDGER" "\$RUN_ID"; }
SHIM_EOF

GATE_SH="$SHIM" bash "$MEASURE" --rows 10 > "$WORK/ref1.txt" 2>"$WORK/ref1.err"
check "참조 구현에 대한 측정이 성공한다" "$?" "0"

ref1=$(field "$WORK/ref1.txt" processes_total)
if [ -n "$ref1" ] && [ "$ref1" -gt 0 ] 2>/dev/null; then
  ok "계수 장치가 실제로 센다 (행마다 fork 하는 참조에서 0 이 아니다)"
else
  bad "계수 장치 생존" "참조에 대한 processes_total 이 '$ref1' 이다 — 행마다 fork 하는 구현이 0 으로 나오면 스텁이 PATH 에 없거나 계수 파일이 안 쓰이는 것이다"
fi

GATE_SH="$SHIM" bash "$MEASURE" --rows 10 > "$WORK/ref2.txt" 2>&1
check "참조에 대한 두 측정이 같은 값을 낸다 (분산 0)" "$ref1" "$(field "$WORK/ref2.txt" processes_total)"

GATE_SH="$SHIM" bash "$MEASURE" --rows 20 > "$WORK/ref3.txt" 2>&1
ref3=$(field "$WORK/ref3.txt" processes_total)
if [ -n "$ref3" ] && [ "$ref3" -gt "$ref1" ] 2>/dev/null; then
  ok "참조의 계수가 행수를 따라 는다 (상수에 묶인 계수기가 아니다)"
else
  bad "계수 장치의 입력 반응" "참조가 10행 $ref1, 20행 $ref3 — 행마다 fork 하는 구현에서 늘지 않으면 계수기가 상수에 묶인 것이다"
fi

# ---------------------------------------------------------------------------
# 2. It runs against the live verifier and reports the shape a caller can parse.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 10 > "$WORK/run1.txt" 2>"$WORK/run1.err"
rc=$?
check "10행 원장에서 측정이 성공한다" "$rc" "0"

check "센 행수가 요청한 행수와 같다" "$(field "$WORK/run1.txt" rows)" "10"

# THE LIVE VERIFIER SPAWNS NONE OF THE FOUR, and that is pinned as an achievement
# rather than tolerated as a threshold. The row loop folded into one `perl`
# process, which the stubs do not shadow; section 1 has just shown on the same
# apparatus, in the same run, that a positive count is still reachable, so this
# zero is the measured absence of forks and not a silent counting failure.
#
# PINNING ZERO IS NOT THE THING THE PREAMBLE WARNS AGAINST. That warning is about
# a number a cheaper commit would have to break. Zero is the floor: no
# improvement can break it, and every revert does — a row-at-a-time loop is 3n+2,
# which fails here and at the second size below.
total1=$(field "$WORK/run1.txt" processes_total)
if [ "$total1" = "0" ]; then
  ok "현행 검증기는 계수 대상 도구를 하나도 띄우지 않는다 (행 단위 fork 가 제거됐다)"
else
  bad "행 단위 fork 제거" "10행에서 processes_total 이 '$total1' 이다 — 0 이어야 한다. 행 단위 루프가 돌아오면 3n+2 가 된다"
fi

# The verdict must still be reachable through the stubbed PATH. A measurement
# that breaks the thing it measures is measuring something else.
check "측정 중에도 체인 판정이 무결로 나온다" "$(field "$WORK/run1.txt" verdict_rc)" "0"

# ---------------------------------------------------------------------------
# 3. Reproducibility. V1's claim is that this metric has zero variance across
#    runs; if it drifts, a slice's effect cannot be read off it.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 10 > "$WORK/run2.txt" 2>&1
total2=$(field "$WORK/run2.txt" processes_total)
check "같은 입력의 두 측정이 같은 값을 낸다 (분산 0)" "$total1" "$total2"

# ---------------------------------------------------------------------------
# 4. The pin holds at a second size. One sample of zero is also what a small n
#    would give a loop that still forks, so two sizes is what turns "does not
#    grow with the input" into a statement instead of a coincidence.
#
#    The guard that used to sit here asserted the OPPOSITE — that the count grows
#    with the row count. That was true of the row-at-a-time loop and became a
#    fire-on-success the moment the loop was removed, since a fork-free walk
#    cannot grow. The property worth holding was never "it grows"; it was "the
#    apparatus responds to its input", and section 1 now carries that on the
#    reference, where growth is still the correct expectation.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 20 > "$WORK/run3.txt" 2>&1
total3=$(field "$WORK/run3.txt" processes_total)
if [ "$total3" = "0" ]; then
  ok "행수를 두 배로 해도 계수가 0 그대로다 (행수에 대해 평평하다)"
else
  bad "행 단위 fork 제거 (두 번째 크기)" "20행에서 processes_total 이 '$total3' 이다 — 0 이어야 한다. 행수를 따라 자랐다면 행 단위 루프가 돌아온 것이다"
fi

# ---------------------------------------------------------------------------
# 5. Read-only against the ledger it measures. This is the property that keeps
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
# 6. A ledger that does not exist is a refusal, not a zero.
# ---------------------------------------------------------------------------
bash "$MEASURE" --ledger "$WORK/nope.md" >/dev/null 2>&1
check "없는 원장은 0 이 아니라 거부다" "$?" "2"

printf 'test-measure-gate-cost: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
