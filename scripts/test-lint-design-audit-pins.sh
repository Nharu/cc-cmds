#!/usr/bin/env bash
# Test scripts/lint-design-audit-pins.sh against
# tests/fixtures/lint-design-audit-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory containing a design-audit/
# tree. Convention: fixture directory name encodes the expected exit code.
#   T-AUDIT-OK-*   → expected exit 0
#   T-AUDIT-FAIL-* → expected exit 1
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-design-audit-pins"

failures=0
passed=0

# expected_fail_line <fixture name> — the fixed part of the `FAIL:` line the
# lint prints for the one defect the fixture carries. Every FAIL fixture is
# judged on this line besides its exit code: a later pin can make an older
# fixture fail for an unrelated reason, and the exit code alone would then
# stay green while the fixture no longer tests its own pin. A FAIL fixture
# missing from this table is a test failure, so no new fixture turns green on
# its exit code alone.
expected_fail_line() {
  case "$1" in
    T-AUDIT-FAIL-1-constant-changed)
      printf '%s' "FAIL: design-audit/SKILL.md (constants) — 'READER_COUNT = 3' must appear on exactly 1 line, found 0" ;;
    T-AUDIT-FAIL-2-round-token-dropped)
      printf '%s' 'FAIL: design-audit/references/01-reader-prompt.md — pinned literal missing: This review is Round {round} of pass {pass}.' ;;
    T-AUDIT-FAIL-3-measurement-dropped)
      printf '%s' 'FAIL: design-audit/references/01-reader-prompt.md — pinned literal missing: REPO GROUND-TRUTH MEASUREMENT (MANDATORY' ;;
    T-AUDIT-FAIL-4-slot-dropped)
      printf '%s' 'FAIL: design-audit/references/04-disclosure-block.md — pinned literal missing: **라우팅 — 미해결 이슈**' ;;
    T-AUDIT-FAIL-5-loop-token-leaked)
      printf '%s' 'FAIL: design-audit/references/01-reader-prompt.md — loop-machinery token present: outer_log.md' ;;
    T-AUDIT-FAIL-6-constants-outside-cfi)
      printf '%s' "FAIL: design-audit/SKILL.md (constants) — pinned literal missing from the '## Control-Flow Invariants' body: ROUNDS_PER_READER = 1" ;;
    T-AUDIT-FAIL-7-unattended-token-twice)
      printf '%s' "FAIL: design-audit-unattended/SKILL.md (denylist) — 'consecutive_no_major' must appear on exactly 1 line (its denylist entry), found 2" ;;
    T-AUDIT-FAIL-8-custody-one-arm)
      printf '%s' "FAIL: design-audit-unattended/SKILL.md (custody) — 'baseline.status' absent" ;;
    T-AUDIT-FAIL-9-custody-duty-3-only)
      printf '%s' "FAIL: design-audit-unattended/SKILL.md (custody) — 'report the skip' absent" ;;
    T-AUDIT-FAIL-10-skeletal-fence-dropped)
      printf '%s' 'FAIL: design-audit-unattended/SKILL.md (skeletal fence) — pinned literal missing: <!-- cc-design-audit-skeletal v1 begin -->' ;;
    T-AUDIT-FAIL-11-downstream-fence-dropped)
      printf '%s' 'FAIL: design-audit/references/04-disclosure-block.md — pinned literal missing: <!-- cc-design-audit-downstream v1 begin -->' ;;
    T-AUDIT-FAIL-12-decision-exclusion-dropped)
      printf '%s' 'FAIL: design-audit/references/03-adjustment-pass.md — pinned literal missing: A decision-shaped defect never takes the light path, whatever its downstream class.' ;;
    *) return 1 ;;
  esac
}

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-AUDIT-OK-*)   want=0 ;;
    T-AUDIT-FAIL-*) want=1 ;;
    *)
      echo "test-lint-design-audit-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-design-audit-pins.sh" 2>&1)
  ec=$?
  set -e

  # An OK fixture must also reach the lint's success banner, so a run that
  # exits 0 without checking anything (e.g. the skill-absent skip) does not
  # count. A FAIL fixture must also print the `FAIL:` line of the pin it
  # targets (`expected_fail_line`). A string match, not a pipe into `grep -q`,
  # so an early exit cannot SIGPIPE the writer and invert the result under
  # `pipefail`.
  has_banner=1
  if [[ "$want" == 0 && $'\n'"$out" != *$'\n''OK:   design-audit pins'* ]]; then
    has_banner=0
  fi
  has_line=1
  expected=""
  if [[ "$want" == 1 ]]; then
    if ! expected=$(expected_fail_line "$fixture_name"); then
      failures=$((failures + 1))
      echo "FAIL: $fixture_name (no expected FAIL line in this test's table)" >&2
      continue
    fi
    if [[ $'\n'"$out" != *$'\n'"$expected"* ]]; then
      has_line=0
    fi
  fi

  if [[ "$ec" == "$want" && "$has_banner" == 1 && "$has_line" == 1 ]]; then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  elif [[ "$ec" != "$want" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  elif [[ "$has_line" == 0 ]]; then
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec as expected, but the targeted line is missing: $expected)" >&2
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name (exit=$ec as expected, but the 'OK:   design-audit pins' banner is missing)" >&2
  fi
done

echo "test-lint-design-audit-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
