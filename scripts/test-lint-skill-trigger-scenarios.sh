#!/usr/bin/env bash
# Test scripts/lint-skill-trigger-scenarios.sh against
# tests/fixtures/lint-skill-trigger-scenarios/.
#
# `base/` is a passing tree: `skills/` holds two model-invoked skills and one
# with model invocation off, `scenarios/` the two scenario files and a README.
# Every other directory is one failure case, laid over a scratch copy of the
# base: its files replace or add the same relative paths, and a `remove` file
# lists base paths to delete. The table below gives each case the line its
# FAIL output must carry, and that line names the check it was built for:
# a case broken in the wrong place would still exit 1, and only the check
# number and phrase show that the right check fired. No FAIL line of a case
# may name another check.
#
# The real tree is run as well, a missing root must exit 2, and the lint and
# both of its tests must be registered in `make lint` and LINT_TESTS.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-skill-trigger-scenarios.sh"
fixtures="$repo_root/tests/fixtures/lint-skill-trigger-scenarios"

if [[ ! -d "$fixtures/base" ]]; then
  echo "FAIL: fixtures root missing: $fixtures/base" >&2
  exit 2
fi

# case<TAB>check<TAB>phrase
CASES='FAIL-missing-file	2	모델 발동 스킬 beta 의 시나리오 파일이 없다 ; 시나리오 파일 beta.tsv 를 더하고 측정 하네스
FAIL-extra-file	2	모델 발동 스킬이 아닌 이름 gamma 의 시나리오 파일이다
FAIL-missing-key-counted	2	모델 발동 스킬 delta 의 시나리오 파일이 없다
FAIL-version-token	3	첫 줄이 판 토큰
FAIL-header	3	열 머리 줄이 「id<TAB>기대<TAB>발화<TAB>근거」 가 아니다
FAIL-field-count	4	데이터 줄이 탭으로 나뉜 네 칸이 아니다 (칸 3개)
FAIL-empty-field	4	빈 칸이 있다
FAIL-whitespace	4	칸 「알파 발동 넷 」 에 앞뒤 공백이 있다
FAIL-id-grammar	4	id 문법 위반 「T_3」
FAIL-id-duplicate	4	id 가 파일 안에서 겹친다 「t2」
FAIL-utterance-duplicate	5	발화가 집합 안에서 겹친다 「알파 발동 하나」
FAIL-unknown-cc-name	6	알 수 없는 cc-cmds 스킬 「cc-cmds:gamma」
FAIL-external-grammar	6	기대 문법 위반 「docs skill!」
FAIL-trigger-floor	7	발동 발화가 2개다
FAIL-neighbor-floor	7	이웃 발화가 2개다
FAIL-no-external	8	외부 스킬을 기대하는 줄이 없다'

passed=0
failures=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-lint-skill-triggers.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# lint_in <skills root> <scenario root> — the lint's output in $out, its exit
# code in $ec. Not called through $( ): the exit code would stay in a subshell.
out=""
ec=0
lint_in() {
  out=$(SKILLS_ROOT="$1" SCENARIO_ROOT="$2" bash "$LINT" 2>&1)
  ec=$?
}

# --- the real tree ------------------------------------------------------------
out=$(env -u SKILLS_ROOT -u SCENARIO_ROOT bash "$LINT" 2>&1)
ec=$?
if [[ "$ec" == "0" ]] && grep -qF 'OK:' <<< "$out"; then
  pass "OK-real-tree"
else
  fail "OK-real-tree (exit=$ec)"; printf '%s\n' "$out" | sed 's/^/  | /' >&2
fi

# --- the base ------------------------------------------------------------------
lint_in "$fixtures/base/skills" "$fixtures/base/scenarios"
if [[ "$ec" == "0" ]] && grep -qF 'OK:' <<< "$out"; then
  pass "OK-base"
else
  fail "OK-base (exit=$ec)"; printf '%s\n' "$out" | sed 's/^/  | /' >&2
fi

# --- a missing root -------------------------------------------------------------
lint_in "$fixtures/base/skills" "$scratch/no-such-root"
[[ "$ec" == "2" ]] && pass "missing-root exits 2" || fail "missing-root (exit=$ec, expected 2)"
lint_in "$scratch/no-such-skills" "$fixtures/base/scenarios"
[[ "$ec" == "2" ]] && pass "missing-skills-root exits 2" || fail "missing-skills-root (exit=$ec, expected 2)"

# --- the failure cases ------------------------------------------------------------
while IFS="$(printf '\t')" read -r name check phrase; do
  [[ -n "$name" ]] || continue
  dir="$fixtures/$name"
  if [[ ! -d "$dir" ]]; then
    fail "$name — 픽스처 디렉터리가 없다"
    continue
  fi
  tree="$scratch/$name"
  mkdir -p "$tree"
  cp -R "$fixtures/base/." "$tree/"
  cp -R "$dir/." "$tree/"
  if [[ -f "$dir/remove" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && rm -f "$tree/$p"
    done < "$dir/remove"
    rm -f "$tree/remove"
  fi
  lint_in "$tree/skills" "$tree/scenarios"
  ok=1
  [[ "$ec" == "1" ]] || ok=0
  grep -qF -- "[검사 $check] $phrase" <<< "$out" || { ok=0; echo "  missing in output: [검사 $check] $phrase" >&2; }
  others=$(grep '^FAIL: ' <<< "$out" | grep -vF -- "[검사 $check]" || true)
  [[ -z "$others" ]] || { ok=0; echo "  another check fired: $others" >&2; }
  if [[ "$ok" == "1" ]]; then
    pass "$name (exit=$ec, [검사 $check])"
  else
    fail "$name (exit=$ec, expected 1 and [검사 $check])"
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
  fi
done <<< "$CASES"

# Every case directory is in the table, so a new fixture cannot sit unrun.
for d in "$fixtures"/*/; do
  name=$(basename "$d")
  [[ "$name" == "base" ]] && continue
  if ! grep -qxF -- "$name" <<< "$(cut -f1 <<< "$CASES")"; then
    fail "fixture '$name' is not in the case table"
  fi
done

# --- registration ------------------------------------------------------------------
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//' | tr ' \t' '\n\n')
if grep -qxF 'bash scripts/lint-skill-trigger-scenarios.sh' <<< "$lint_recipe"; then
  pass "registered-in-make-lint"
else
  fail "registered-in-make-lint — make lint 레시피에 bash scripts/lint-skill-trigger-scenarios.sh 가 없다"
fi
for t in scripts/test-lint-skill-trigger-scenarios.sh scripts/test-skill-trigger-measure.sh; do
  if grep -qxF "$t" <<< "$lint_tests"; then
    pass "registered-in-LINT_TESTS: $t"
  else
    fail "registered-in-LINT_TESTS — LINT_TESTS 에 $t 가 없다"
  fi
done

echo "test-lint-skill-trigger-scenarios: $passed passed, $failures failed"
(( failures == 0 ))
