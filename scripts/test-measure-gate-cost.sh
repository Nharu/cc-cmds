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
#   - the progress axis MOVES WITH ITS INPUT: one more distinct segment id costs
#     a fixed number of processes, and taking either of that axis's two inputs
#     away makes the relation unobservable rather than silently flat
#
# WHY THE APPARATUS IS STILL PROVED ON THE REFERENCE. The live verifier walks
# the whole ledger in one `perl` process. `perl` is now one of the tools the
# stubs shadow, so the live count is the exact integer 1 rather than a zero
# that a dead counter would also produce — but a reading of 1 from a counter
# that only ever counted `perl` would still be indistinguishable from a counter
# that stopped counting everything else. The reference closes that: it is
# committed, pinned by sha256 in the equivalence suite, and forbidden to be
# modernized, so it keeps issuing 3n+2 `sed`/`shasum`/`cut` processes and
# serves as a fixed yardstick for the rest of the list. Zero there means the
# stubs are not on PATH, the counter file is not being written, or the names
# no longer match — a broken harness, with no other reading available.
#
# THE CHAIN PIN IS 1, NOT 0, AND IT IS A CERTIFICATE. The single-pass walk is
# one interpreter, so 1 is its floor: no cheaper commit can break the pin, and
# every revert to a row loop does (3n+2 at both sizes below). 0 was the old
# reading, and it was an artefact of the tool list — the walk spawned `perl`,
# the list did not name `perl`, and the apparatus reported the process it could
# not see as absent.
#
# THE PROGRESS AXIS IS ASSERTED AS A RELATION, NOT A VALUE. Its fixed part
# depends on how many targets the manifest names and on which readers the gate
# answers from memory, so an absolute total here would fail on the next change
# to either. What cannot change without the act path regaining a per-entity
# fork is the SLOPE — the cost of one more distinct segment id — so the test
# measures at three sizes and pins the two increments to each other and to the
# measured law. And the negative controls are what make a green reading mean
# something: a ledger with no segment rows must be flat under a doubled row
# count, and a missing manifest must be a refusal, because an instrument that
# reports the same point for every input is green by construction.
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
#    same two globals the real one reads, and a `gate_progress_vector` that the
#    script requires to exist — an inert one here, since this section measures
#    the chain axis only.
# ---------------------------------------------------------------------------
SHIM="$WORK/gate-reference-shim.sh"
cat > "$SHIM" <<SHIM_EOF
gate_chain_verify() { bash "$REFERENCE" "\$LEDGER" "\$RUN_ID"; }
gate_progress_vector() { :; }
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

# THE LIVE VERIFIER SPAWNS EXACTLY ONE PROCESS — the `perl` that walks the whole
# ledger — and that is pinned as an achievement rather than tolerated as a
# threshold. Section 1 has just shown on the same apparatus, in the same run,
# that the counter still sees `sed`/`shasum`/`cut`, so this 1 is the measured
# shape of the walk and not a counter that stopped seeing.
#
# PINNING ONE IS NOT THE THING THE PREAMBLE WARNS AGAINST. That warning is about
# a number a cheaper commit would have to break. One interpreter is the floor of
# a single-pass walk: no improvement can break it, and every revert does — a
# row-at-a-time loop is 3n+2, which fails here and at the second size below.
total1=$(field "$WORK/run1.txt" processes_total)
if [ "$total1" = "1" ]; then
  ok "현행 검증기는 단일 패스다 — 계수 대상 프로세스가 정확히 하나(perl)다"
else
  bad "단일 패스 회귀 가드" "10행에서 processes_total 이 '$total1' 이다 — 1 이어야 한다. 행 단위 루프가 돌아오면 3n+2 가 된다"
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
if [ "$total3" = "1" ]; then
  ok "행수를 두 배로 해도 계수가 1 그대로다 (행수에 대해 평평하다)"
else
  bad "단일 패스 회귀 가드 (두 번째 크기)" "20행에서 processes_total 이 '$total3' 이다 — 1 이어야 한다. 행수를 따라 자랐다면 행 단위 루프가 돌아온 것이다"
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

# ---------------------------------------------------------------------------
# 7. The progress axis moves with its input, and only with its input.
#
#    Three sizes, K = 3, 4, 5 distinct segment ids. The two increments must be
#    equal to each other — a straight line — and equal to the measured law of
#    the act path's entity term: one more distinct id is one more pair of field
#    reads, fourteen processes. The fixed part is deliberately not pinned.
# ---------------------------------------------------------------------------
bash "$MEASURE" --rows 10 --segments 3 > "$WORK/seg3.txt" 2>&1
check "세그먼트 3개 원장에서 측정이 성공한다" "$?" "0"
check "센 세그먼트 수가 요청한 수와 같다" "$(field "$WORK/seg3.txt" segments)" "3"
bash "$MEASURE" --rows 10 --segments 4 > "$WORK/seg4.txt" 2>&1
bash "$MEASURE" --rows 10 --segments 5 > "$WORK/seg5.txt" 2>&1
p3=$(field "$WORK/seg3.txt" progress_processes_total)
p4=$(field "$WORK/seg4.txt" progress_processes_total)
p5=$(field "$WORK/seg5.txt" progress_processes_total)
if [ -n "$p3" ] && [ -n "$p4" ] && [ -n "$p5" ] && [ "$((p4 - p3))" = "$((p5 - p4))" ] 2>/dev/null; then
  ok "구별 세그먼트 id 당 증분이 일정하다 ($p3 → $p4 → $p5)"
else
  bad "기울기 축의 선형성" "3·4·5개에서 '$p3' '$p4' '$p5' — 증분이 서로 다르면 계측기가 id 수 외의 것에 반응하고 있다"
fi
check "구별 세그먼트 id 하나가 정확히 14 프로세스다" "$((p4 - p3))" "14"
# The slope's composition, so a regression is named by tool: four `grep`, four
# `sed`, four `tail`, two `tr` per id — the two field reads of one segment row.
for pair in grep:4 sed:4 tail:4 tr:2; do
  t="${pair%%:*}"; want="${pair##*:}"
  got=$(( $(field "$WORK/seg4.txt" "progress_$t") - $(field "$WORK/seg3.txt" "progress_$t") ))
  check "id 당 증분의 $t 몫이 $want 다" "$got" "$want"
done
# The chain axis is untouched by segment rows: the walk stays one process.
check "세그먼트 행이 있어도 체인 검증은 단일 패스다" "$(field "$WORK/seg5.txt" processes_total)" "1"
check "세그먼트 행이 있어도 체인 판정이 무결이다" "$(field "$WORK/seg5.txt" verdict_rc)" "0"

# Negative control (i): with no segment rows the axis must be FLAT under a
# doubled row count. If it moved here it would be reacting to rows, not ids,
# and the slope above would be measuring the wrong variable.
bash "$MEASURE" --rows 40 > "$WORK/flat40.txt" 2>&1
check "세그먼트 행이 없으면 행수를 두 배로 해도 기울기 축이 평평하다" \
  "$(field "$WORK/flat40.txt" progress_processes_total)" "$(field "$WORK/run3.txt" progress_processes_total)"

# Negative control (ii): without the manifest the axis is a refusal, never a
# flat point. A vector read against no manifest reports the same total for
# every ledger, and a guard built on that reading is green by construction.
bash "$MEASURE" --rows 10 --segments 3 --manifest "$WORK/no-manifest.md" > "$WORK/nomanifest.txt" 2>&1
check "매니페스트가 없으면 기울기 축은 평평한 값이 아니라 거부다" "$?" "2"
check "거부한 실행은 기울기 값을 하나도 내지 않는다" "$(field "$WORK/nomanifest.txt" progress_processes_total)" ""

# And the axis is read-only against BOTH of its inputs.
MF="$WORK/fixed-manifest.md"
printf '%s\n' '## 대상' '- `target` | 별칭=fixed | 원격 슬러그=fixed/fixed | 절단점=PR' '' '## 인가' '**종료 지점**: 고정' > "$MF"
mdigest=$(shasum -a 256 < "$MF" | cut -d' ' -f1)
bash "$MEASURE" --rows 5 --segments 2 --manifest "$MF" > "$WORK/run7.txt" 2>&1
check "주어진 매니페스트로 기울기 축이 측정된다" "$?" "0"
check "측정이 매니페스트 바이트를 바꾸지 않는다" "$(shasum -a 256 < "$MF" | cut -d' ' -f1)" "$mdigest"

printf 'test-measure-gate-cost: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
