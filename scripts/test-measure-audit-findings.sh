#!/usr/bin/env bash
# Test scripts/measure-audit-findings.sh against
# tests/fixtures/measure-audit-findings/.
#
# The fixtures are SYNTHETIC audit reports committed to this repo. The real
# corpus lives under `docs/`, which is not tracked, so a test pointed at it
# would fail on a machine with no reports and pass non-deterministically on
# one that has them — the second outcome being the worse, since it certifies
# nothing while looking green.
#
# The fixture set mirrors the shape of the real corpus on the day the script
# was written: eight reports with the disclosure fence (values 23 24 24 27 28
# 29 30 32 → median 27.5), eight that reached the reconciliation pass and never
# wrote the fence, one per-reader witness file that carries a fence and must be
# excluded, and one file with a reconciliation heading but no audit header.
# Every unfenced fixture carries a prose decoy that LOOKS like a defect count;
# two fenced ones carry a slot-shaped decoy outside the fence. The golden diff
# passes only if none of those decoys is read.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/measure-audit-findings"
golden="$fixtures/golden/expected.txt"
measure="$script_dir/measure-audit-findings.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# ---- golden render ----------------------------------------------------------

tmp=$(mktemp)
if bash "$measure" --reports "$fixtures/reports" > "$tmp" 2>/dev/null; then
  if diff -u "$golden" "$tmp" >/dev/null; then
    pass "golden match (8 fenced, median 27.5, 8 missing-fence)"
  else
    fail "golden diff"
    diff -u "$golden" "$tmp" >&2 || true
  fi
else
  fail "measure-audit-findings exited non-zero on the fixture set"
fi

# ---- mutation: one fence value changed → golden no longer matches -----------
#
# Copies the fixture set out of tree and edits ONE fenced value. If the golden
# still matched, the diff above would be passing without reading the fence.

mut=$(mktemp -d)
cp "$fixtures"/reports/*.md "$mut/"
awk '{
  if ($0 == "**고유 결함 수**: 27") print "**고유 결함 수**: 57"; else print
}' "$fixtures/reports/docs-d-delta.md" > "$mut/docs-d-delta.md"
if bash "$measure" --reports "$mut" > "$tmp" 2>/dev/null; then
  if diff -u "$golden" "$tmp" >/dev/null; then
    fail "mutation (fence value 27 -> 57) still matches the golden — the fence is not being read"
  else
    if grep -q '^docs-d-delta.md	57	54000	1.06$' "$tmp" \
      && grep -q '^# fenced  n=8  median=28.5  range=23~57$' "$tmp"; then
      pass "mutation (fence value 27 -> 57) moves the row, the median and the range"
    else
      fail "mutation changed the output but not as expected"
      cat "$tmp" >&2
    fi
  fi
else
  fail "measure-audit-findings exited non-zero on the mutated set"
fi
rm -rf "$mut"

# ---- prose decoys never reach the fenced output ------------------------------
#
# The decoy values are chosen to be absent from every fence: 101, 999, 888, 38,
# 21, 18, 26, 14, 33, 25, 77, 99. Any of them in the fenced rows means a prose
# fallback exists.

bash "$measure" --reports "$fixtures/reports" > "$tmp" 2>/dev/null || true
fenced_block=$(awk '/^# missing-fence/ { exit } { print }' "$tmp")
decoy_hit=0
for v in 101 999 888 38 21 18 26 14 33 25 77 99; do
  if printf '%s\n' "$fenced_block" | grep -qE "	${v}	"; then
    decoy_hit=1
    echo "  decoy value $v appeared in the fenced rows" >&2
  fi
done
if (( decoy_hit == 0 )); then
  pass "no prose decoy reaches the fenced output"
else
  fail "a prose value was read as a fenced count"
fi

# ---- the reader witness and the headerless file are excluded ----------------

if grep -q 'reader-1' "$tmp"; then
  fail "a *.reader-*.md file entered an output"
else
  pass "per-reader witness files are excluded from both outputs"
fi
if grep -q 'docs-z-noheader' "$tmp"; then
  fail "a file with no audit header entered the missing-fence list"
else
  pass "a reconciliation heading without the audit header is not a missing fence"
fi

# ---- missing reports directory → usage error --------------------------------

set +e
bash "$measure" --reports "$fixtures/no-such-dir" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" == "2" ]]; then
  pass "missing --reports directory exits 2"
else
  fail "missing --reports directory should exit 2, got $ec"
fi

rm -f "$tmp"

echo "test-measure-audit-findings: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
