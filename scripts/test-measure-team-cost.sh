#!/usr/bin/env bash
# Test scripts/measure-team-cost.sh against
# tests/fixtures/measure-team-cost/.
#
# The fixtures are SYNTHETIC transcripts committed to this repo. That is the
# whole point: this is the first script here that reads outside the repo at
# runtime, and pointing a test at real session history would fail on a machine
# with no history and pass non-deterministically on one that has it — the
# second outcome being the worse, since it certifies nothing while looking
# green.
#
# Three sessions in the fixture set differ ONLY in their witness bodies
# (s1/s2/s3), so a run that skipped the transcript witness reconstruction and
# compared the rest of the columns would not match the golden file. That is
# deliberate: the reconstruction is half of what the script exists to do, and
# a golden diff that could pass without exercising it would leave that half
# unverified.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/measure-team-cost"
golden="$fixtures/golden/expected.tsv"
measure="$script_dir/measure-team-cost.sh"

failures=0
passed=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# ---- golden render ----------------------------------------------------------

tmp=$(mktemp)
if bash "$measure" --transcripts "$fixtures/input" --project -fixture-project > "$tmp" 2>/dev/null; then
  if diff -u "$golden" "$tmp" >/dev/null; then
    pass "golden match (10 synthetic sessions)"
  else
    fail "golden diff"
    diff -u "$golden" "$tmp" >&2 || true
  fi
else
  fail "measure-team-cost exited non-zero on the fixture set"
fi
rm -f "$tmp"

# ---- scope_source labels are a closed set -----------------------------------
#
# The label is what a reader trusts when deciding whether a row reflects a
# narrowed scope. A typo or an unlisted value would be read as a real source,
# so the set is asserted rather than left to the golden diff alone.
LABELS=$(cut -f11 "$golden" | tail -n +2 | sort -u | tr '\n' ' ')
EXPECTED_LABELS='NA READ-ERROR numstat numstat-unreadable per-file pr-summary '
observed_subset=1
for l in $LABELS; do
  case " $EXPECTED_LABELS " in *" $l "*) ;; *) observed_subset=0 ;; esac
done
if (( observed_subset == 1 )); then
  pass "scope_source labels are all in the declared set"
else
  fail "scope_source has an undeclared label: $LABELS"
fi

# ---- an unreadable transcript is stamped, never measured as empty -----------
#
# Built at test time rather than committed: git does not carry a 0000 mode, and
# a fixture that is readable after checkout would assert nothing.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-test.XXXXXX")
cp -R "$fixtures/input" "$tmpdir/input"
printf '{"type":"assistant"}\n' > "$tmpdir/input/-fixture-project/s99-unreadable.jsonl"
chmod 000 "$tmpdir/input/-fixture-project/s99-unreadable.jsonl"
if [[ -r "$tmpdir/input/-fixture-project/s99-unreadable.jsonl" ]]; then
  # Running as root (or on a filesystem ignoring the mode): the premise of the
  # case does not hold, so say so instead of asserting something else.
  echo "SKIP: unreadable-transcript case (the file is still readable here)"
else
  row=$(bash "$measure" --transcripts "$tmpdir/input" --project -fixture-project 2>/dev/null \
    | grep '^s99-unreadable' || true)
  if [[ "$row" == *"READ-ERROR"* ]] && [[ "$row" != *"	0	"* ]]; then
    pass "unreadable transcript is stamped READ-ERROR, not measured as zero"
  else
    fail "unreadable transcript row was not stamped: ${row:-<no row>}"
  fi
fi
chmod 644 "$tmpdir/input/-fixture-project/s99-unreadable.jsonl" 2>/dev/null || true
rm -rf "$tmpdir"

# ---- no transcript root → usage error, never a silent real-home default -----

set +e
TRANSCRIPT_ROOT= bash "$measure" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" == "2" ]]; then
  pass "missing --transcripts exits 2 (no default pointing at a real home)"
else
  fail "missing --transcripts should exit 2, got $ec"
fi

# ---- unknown project scope → usage error, never a global scan ---------------

set +e
bash "$measure" --transcripts "$fixtures/input" --project -no-such-project >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" == "2" ]]; then
  pass "unknown --project exits 2 (no fallback to scanning every project)"
else
  fail "unknown --project should exit 2, got $ec"
fi

echo "test-measure-team-cost: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
