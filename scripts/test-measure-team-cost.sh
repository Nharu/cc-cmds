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
    pass "golden match (6 synthetic sessions)"
  else
    fail "golden diff"
    diff -u "$golden" "$tmp" >&2 || true
  fi
else
  fail "measure-team-cost exited non-zero on the fixture set"
fi
rm -f "$tmp"

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
