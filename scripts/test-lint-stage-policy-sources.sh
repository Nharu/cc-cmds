#!/usr/bin/env bash
# Test the two halves of the stage-policy drift contract against
# tests/fixtures/lint-stage-policy-sources/.
#
# Repository half — `scripts/lint-stage-policy-sources.sh`. Each fixture is a
# POLICY_ROOT-shaped directory (a `stage-policy.md` beside a
# `stage-policy.sources.tsv`); the directory name encodes the expected exit.
#   T-POLICY-OK-*   → expected exit 0
#   T-POLICY-FAIL-* → expected exit 1
# Every FAIL fixture is the OK pair with exactly one defect: a non-ASCII line,
# a volatile token, an oversize policy, a pin sentence absent or doubled, a
# policy heading no row names, a `policy:` row naming a heading that does not
# exist, a disposition outside the closed vocabulary, a duplicated user-scope
# anchor, a four-column row, a memory row carrying a hash.
#
# Source half — `plugins/cc-cmds/orchestrator/stage-policy-drift.sh`. Each
# case under `drift/` carries the manifest and the fake sources it is compared
# with. The checker's contract says the manifest sits NEXT TO the script and
# the user-scope source is `${CLAUDE_CONFIG_DIR}/CLAUDE.md`, so the test copies
# the checker into a scratch directory beside the case's manifest and points
# `CLAUDE_CONFIG_DIR` at the case's `cfg/`. The workspace source is reached
# only through a host map, which must hold an ABSOLUTE path; the map is
# therefore written at run time into the scratch directory, naming the case's
# `ws/CLAUDE.md` when the case has one. A case carrying `map.malformed` gets
# that file as its map instead. A case with neither gets a map path that does
# not exist. The person's real global files are never read.
#
# Expected per case: the exit code, the verdict on the last line, and — where
# a finding is the point — the finding line itself, asserted verbatim.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-stage-policy-sources"
checker="$repo_root/plugins/cc-cmds/orchestrator/stage-policy-drift.sh"

failures=0
passed=0

# ---------- repository half --------------------------------------------------

for fixture in "$fixtures"/T-POLICY-*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-POLICY-OK-*)   want=0 ;;
    T-POLICY-FAIL-*) want=1 ;;
    *)
      echo "test-lint-stage-policy-sources: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  POLICY_ROOT="$fixture" bash "$script_dir/lint-stage-policy-sources.sh" >/dev/null 2>&1
  ec=$?
  set -e

  if [[ "$ec" == "$want" ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi
done

# ---------- source half ------------------------------------------------------

# run_drift <case> — runs the checker for one case; sets DRIFT_OUT and DRIFT_EC.
run_drift() {
  local case_dir="$fixtures/drift/$1" scratch map
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/cc-policy-drift.XXXXXX")
  cp "$checker" "$scratch/stage-policy-drift.sh"
  cp "$case_dir/stage-policy.sources.tsv" "$scratch/stage-policy.sources.tsv"
  if [[ -f "$case_dir/map.malformed" ]]; then
    map="$case_dir/map.malformed"
  elif [[ -f "$case_dir/ws/CLAUDE.md" ]]; then
    map="$scratch/map"
    printf 'workspace\t%s\n' "$case_dir/ws/CLAUDE.md" > "$map"
  else
    map="$scratch/no-such-map"
  fi
  set +e
  DRIFT_OUT=$(CLAUDE_CONFIG_DIR="$case_dir/cfg" bash "$scratch/stage-policy-drift.sh" --sources-map "$map" 2>/dev/null)
  DRIFT_EC=$?
  set -e
  rm -rf "$scratch"
}

# expect_drift <case> <exit> <last-line> [<finding line>...]
# With no finding line given, the output must consist of the last line alone
# (plus SKIP lines, which are allowed anywhere) — that is how "memory rows
# print nothing" is asserted.
expect_drift() {
  local name="$1" want_ec="$2" want_last="$3" ok=1 last line
  shift 3
  run_drift "$name"
  last=$(printf '%s\n' "$DRIFT_OUT" | tail -n 1)
  if [[ "$DRIFT_EC" != "$want_ec" ]]; then
    echo "FAIL: drift/$name — exit=$DRIFT_EC, expected=$want_ec" >&2; ok=0
  fi
  if [[ "$last" != "$want_last" ]]; then
    echo "FAIL: drift/$name — last line '$last', expected '$want_last'" >&2; ok=0
  fi
  for line in "$@"; do
    hits=$(printf '%s\n' "$DRIFT_OUT" | grep -Fxc -- "$line" || true)
    if [[ "${hits:-0}" != "1" ]]; then
      echo "FAIL: drift/$name — expected exactly one line '$line', found ${hits:-0}" >&2; ok=0
    fi
  done
  if (( $# == 0 )); then
    stray=$(printf '%s\n' "$DRIFT_OUT" | grep -vE '^(SKIP |match$|skipped$)' || true)
    if [[ -n "$stray" ]]; then
      echo "FAIL: drift/$name — unexpected output line(s): $stray" >&2; ok=0
    fi
  fi
  if (( ok == 1 )); then
    passed=$((passed + 1)); echo "PASS: drift/$name"
  else
    failures=$((failures + 1)); echo "     output was: $DRIFT_OUT" >&2
  fi
}

expect_drift match 0 match
expect_drift added 1 'mismatch 1' 'added user-scope delta rule four'
expect_drift removed 1 'mismatch 1' 'removed user-scope gamma'
expect_drift changed 1 'mismatch 1' 'changed user-scope alpha'
expect_drift non-unique 1 'mismatch 1' 'non-unique user-scope alpha'
expect_drift skipped 0 skipped
expect_drift one-compared 0 match
expect_drift memory-silent 0 match
expect_drift workspace-changed 1 'mismatch 1' 'changed workspace ## Two'
expect_drift workspace-match 0 match
expect_drift malformed-manifest 2 ''
expect_drift malformed-map 2 ''

# `non-unique` must not be folded into `removed`, and a SKIP source must be
# named as such in the one-compared case.
run_drift non-unique
hits=$(printf '%s\n' "$DRIFT_OUT" | grep -c '^removed ' || true)
if [[ "${hits:-0}" == "0" ]]; then
  passed=$((passed + 1)); echo "PASS: drift/non-unique (not folded into removed)"
else
  failures=$((failures + 1)); echo "FAIL: drift/non-unique — a non-unique anchor was reported as removed" >&2
fi
run_drift one-compared
hits=$(printf '%s\n' "$DRIFT_OUT" | grep -c '^SKIP workspace ' || true)
if [[ "${hits:-0}" == "1" ]]; then
  passed=$((passed + 1)); echo "PASS: drift/one-compared (workspace SKIP line present)"
else
  failures=$((failures + 1)); echo "FAIL: drift/one-compared — expected one 'SKIP workspace' line, found ${hits:-0}" >&2
fi

echo "test-lint-stage-policy-sources: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
