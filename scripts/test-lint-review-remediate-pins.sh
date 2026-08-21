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
#
# An exit code alone cannot tell the three apart: the pin fired, the lint aborted
# before reaching it, and some other pin fired instead. All three exit 1. So this
# runner reads the lint's output as well as its status, and pairs the two — see
# the attribution predicates in the fixture loop. Restoring a redirection that
# throws either half away removes the guard entirely, not just half of it.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-review-remediate-pins"
skill_dir="$repo_root/plugins/cc-cmds/skills/review-remediate"

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
# suite's output, and an assertion placed lint-side would reproduce exactly the
# silence it exists to break. A reader who gets a bare failure line without this
# diagnosis concludes "the pin I just narrowed is wrong" and reverts a correct
# narrowing.
#
# Scoped to the baseline alone. The FAIL fixtures are supposed to differ from the
# skill — asserting identity across all of them would break every one.
#
# The file list is DERIVED from the shipped skill rather than written out here.
# An enumeration goes stale the day a reference file is added, and goes stale
# silently: the new file is simply never compared. An empty derivation is treated
# as a failure — an empty set here means the walk stopped working, which is
# "unknown", not "the skill has no files".

baseline="$fixtures/T-RR-OK-baseline/review-remediate"
baseline_drift=0

skill_files=()
while IFS= read -r f; do
  skill_files+=("${f#"$skill_dir/"}")
done < <(find "$skill_dir" -type f -name '*.md' | LC_ALL=C sort)

if (( ${#skill_files[@]} == 0 )); then
  echo "BASELINE: 출하 스킬에서 비교 대상 파일을 하나도 파생하지 못했습니다 — 빈 집합은 「없음」이 아니라 「모름」입니다" >&2
  echo "          파생 대상: $skill_dir" >&2
  baseline_drift=1
else
  for rel in "${skill_files[@]}"; do
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
    echo "BASELINE: 픽스처가 출하 스킬과 바이트 동일합니다 (${#skill_files[@]}개 파일 대조)"
  fi
fi

# ---- guard self-checks ------------------------------------------------------
#
# Red paths for the two guards whose subject is the lint's OWN source rather than
# a skill tree. A fixture is a `review-remediate/` directory, so nothing a fixture
# contains can reach the lint's literal pin arrays or its control flow — for these
# two the only possible red path is a mutated copy of the lint itself.
#
# This is not optional decoration. The one real subsumption this repo ever had was
# removed by the enum narrowing in this same change, so without these the
# subsumption guard would ship green with nothing to catch **and nothing that
# could ever catch it** — the blind-guard shape this whole harness exists to
# refuse.
#
# The copy lands beside the original so the lint's `repo_root` still resolves;
# a trap removes it even if the runner is interrupted.

selfcheck_copy="$script_dir/.tmp-guard-selfcheck.sh"
trap 'rm -f "$selfcheck_copy"' EXIT

guard_selfcheck() {
  local label="$1" anchor="$2" injected="$3" expect="$4"
  ANCHOR="$anchor" INJECTED="$injected" LC_ALL=C awk '
    { print }
    index($0, ENVIRON["ANCHOR"]) == 1 && !done { print ENVIRON["INJECTED"]; done = 1 }
  ' "$script_dir/lint-review-remediate-pins.sh" > "$selfcheck_copy"

  if ! grep -Fq -- "$injected" "$selfcheck_copy"; then
    echo "FAIL: 가드 자가 검사 '$label' — 주입 앵커가 더 이상 맞지 않는다: $anchor" >&2
    failures=$((failures + 1))
    return
  fi

  set +e
  local out ec
  out=$(bash "$selfcheck_copy" 2>&1 </dev/null)
  ec=$?
  set -e

  if [[ "$ec" == "0" ]]; then
    echo "FAIL: 가드 자가 검사 '$label' — 주입했는데 종료 0이다; 가드가 발화하지 않았다" >&2
    failures=$((failures + 1))
  elif ! printf '%s\n' "$out" | grep -Eq -- "$expect"; then
    echo "FAIL: 가드 자가 검사 '$label' — 기대한 진단이 출력에 없다: $expect" >&2
    failures=$((failures + 1))
  else
    passed=$((passed + 1))
    echo "PASS: 가드 자가 검사 '$label'"
  fi
}

# Subsumption: a shorter reason token that every longer one contains. The
# diagnostic must name BOTH literals and the list they belong to — a bare
# "subsumption found" would leave the reader to re-derive which pair in which of
# the eight lists.
guard_selfcheck 'subsumption' 'REASONS=(' "  '보류 불가'" \
  "^FAIL: pin list REASONS — '보류 불가' is a substring of '보류 불가\(.*\)'"

# Abort: an unchecked non-zero exit must name the line that ended the run. It
# exits 1 exactly like a pin failure, so the marker string is the whole of the
# distinction.
guard_selfcheck 'abort marker' 'fail=0' 'grep -q ZZZ-GUARD-SELFCHECK /dev/null' \
  '^ABORT: .* ended at line [0-9]+ with exit [0-9]+'

rm -f "$selfcheck_copy"

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
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-review-remediate-pins.sh" 2>&1 </dev/null)
  ec=$?
  set -e

  reasons=()

  # 1 — abort marker. An abort exits 1 exactly like a pin failure, so without
  #     this predicate a lint that died before reaching the pin is indistinguish-
  #     able from the pin firing, and every FAIL fixture stays green through it.
  if printf '%s\n' "$out" | grep -q '^ABORT:'; then
    reasons+=("중단 표지 출현 — 핀이 걸린 것이 아니라 검사되지 않은 비영 종료로 끝났다")
  fi

  # 2 — exit code.
  if [[ "$ec" != "$want" ]]; then
    reasons+=("종료 코드 $ec, 기대 $want")
  fi

  n_fail=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)

  if [[ "$want" == "1" ]]; then
    # 3 — a diagnostic exists at all.
    if (( n_fail == 0 )); then
      reasons+=("진단 없음 — 종료 코드만 1이고 어느 핀이 걸렸는지 말하지 않는다")
    # 4 — exactly one. A fixture that trips several pins stops being evidence
    #     about the pin it names.
    elif (( n_fail != 1 )); then
      reasons+=("발화 ${n_fail}건 — 픽스처 하나는 핀 하나만 깨뜨려야 한다")
    fi

    # 5 — attribution. The exit code says something failed; only this says the
    #     thing that failed is the thing this fixture breaks.
    exp_file="${fixture%/}/expected-fail.txt"
    if [[ ! -f "$exp_file" ]]; then
      reasons+=("기대 문자열 파일 없음: ${exp_file#"$repo_root/"}")
    else
      exp=$(head -1 "$exp_file")
      if [[ -z "$exp" ]]; then
        reasons+=("기대 문자열이 비어 있다: ${exp_file#"$repo_root/"}")
      elif ! printf '%s\n' "$out" | grep -Fq -- "$exp"; then
        reasons+=("귀속 불일치 — 기대한 진단이 출력에 없다: $exp")
      fi
    fi
  else
    # 6 — the pass summary. A green run that prints nothing cannot be told from
    #     a green run that checked nothing.
    if ! printf '%s\n' "$out" | grep -q '^OK: '; then
      reasons+=("통과 요약 줄 없음 — 무엇을 검사하고 지나갔는지 말하지 않는다")
    fi
  fi

  if (( ${#reasons[@]} == 0 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name" >&2
    for r in "${reasons[@]}"; do
      echo "      - $r" >&2
    done
  fi
done

# A suite that ran zero fixtures is a green that proves nothing.
if (( passed + failures == 0 )); then
  echo "test-lint-review-remediate-pins: no fixtures found under $fixtures" >&2
  exit 1
fi

# The summary must agree with the exit code. Baseline drift fails the suite
# without failing any fixture, so a bare "N passed, 0 failed" would be the last
# line of a run that exits 1 — and the last line is what a CI log tail shows.
if (( baseline_drift > 0 )); then
  echo "test-lint-review-remediate-pins: $passed passed, $failures failed — 베이스라인 대조가 실패해 스위트는 실패입니다" >&2
  exit 1
fi

echo "test-lint-review-remediate-pins: $passed passed, $failures failed"
exit $(( failures > 0 ? 1 : 0 ))
