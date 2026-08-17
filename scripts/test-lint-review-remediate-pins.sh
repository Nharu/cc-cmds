#!/usr/bin/env bash
# Test scripts/lint-review-remediate-pins.sh against
# tests/fixtures/lint-review-remediate-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory containing a review-remediate/
# tree. Convention: fixture directory name encodes the expected exit code.
#   T-RR-OK-*   → expected exit 0
#   T-RR-FAIL-* → expected exit 1
#
# The FAIL fixtures each break exactly one pin, so a pin that silently stops
# checking shows up as a fixture that turns green rather than as a lint that
# still exits 0 for the wrong reason.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-review-remediate-pins"

if [[ ! -d "$fixtures" ]]; then
  echo "test-lint-review-remediate-pins: fixtures directory missing: $fixtures" >&2
  exit 1
fi

failures=0
passed=0

# ---- baseline identity assertion (must be the suite's FIRST output) ----------
#
# The baseline fixture is a byte-identical copy of the shipped skill, so every
# edit to the skill silently desynchronises it. Only the narrow slice of those
# edits that touches a pinned line makes the lint fail; the rest drift quietly.
#
# This lands in the runner, NOT in the lint: the runner is what writes the
# suite's output, and it discards the lint's own stdout — so an assertion placed
# lint-side would reproduce exactly the silence it exists to break. A reader who
# gets a bare failure line without this diagnosis concludes "the pin I just
# narrowed is wrong" and reverts a correct narrowing.
#
# Scoped to the baseline alone. The FAIL fixtures are supposed to differ from the
# skill — asserting identity across all of them would break every one.

baseline="$fixtures/T-RR-OK-baseline/review-remediate"
skill_dir="$repo_root/plugins/cc-cmds/skills/review-remediate"
baseline_drift=0

for rel in SKILL.md references/output-template.md; do
  if [[ ! -f "$baseline/$rel" ]]; then
    echo "BASELINE: 픽스처에 $rel 가 없습니다 — 베이스라인이 스킬의 사본이 아닙니다" >&2
    baseline_drift=1
  elif ! cmp -s "$baseline/$rel" "$skill_dir/$rel"; then
    echo "BASELINE: $rel 가 출하 스킬과 어긋납니다 — 아래 실패는 핀이 아니라 픽스처 미동기화가 원인일 수 있습니다" >&2
    echo "          동기화: cp $skill_dir/$rel $baseline/$rel" >&2
    baseline_drift=1
  fi
done

if (( baseline_drift == 0 )); then
  echo "BASELINE: 픽스처가 출하 스킬과 바이트 동일합니다"
fi

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-RR-OK-*)   want=0 ;;
    T-RR-FAIL-*) want=1 ;;
    *)
      echo "test-lint-review-remediate-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  SKILLS_ROOT="$fixture" bash "$script_dir/lint-review-remediate-pins.sh" >/dev/null 2>&1
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

# A suite that ran zero fixtures is a green that proves nothing.
if (( passed + failures == 0 )); then
  echo "test-lint-review-remediate-pins: no fixtures found under $fixtures" >&2
  exit 1
fi

echo "test-lint-review-remediate-pins: $passed passed, $failures failed"
exit $(( failures > 0 || baseline_drift > 0 ? 1 : 0 ))
