#!/usr/bin/env bash
# Test scripts/lint-interview-verification.sh against
# tests/fixtures/lint-interview-verification/.
#
# Each fixture holds a `skills/` root and an `orchestrator/` beside it, the
# lint's default checker location. The directory name encodes the expectation:
#   OK-*       → exit 0, output `OK:`
#   FAIL-<n>-* → exit 1, and the output names `[단언 <n>]`
#
# The real tree is run as well, and the lint and this test must be registered
# in `make lint` and LINT_TESTS.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-interview-verification.sh"
fixtures="$repo_root/tests/fixtures/lint-interview-verification"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

run_case() {
  # run_case <name> <want-exit> <skills-root|""> <needle>
  local name="$1" want="$2" root="$3" needle="$4" out ec ok=1
  if [[ -z "$root" ]]; then
    out=$(SKILLS_ROOT= ORCH_ROOT= bash "$LINT" 2>&1)
  else
    out=$(SKILLS_ROOT="$root" ORCH_ROOT= bash "$LINT" 2>&1)
  fi
  ec=$?
  [[ "$ec" == "$want" ]] || ok=0
  if ! grep -qF -- "$needle" <<EOF
$out
EOF
  then
    ok=0
    echo "  missing in output: $needle" >&2
  fi
  if [[ "$ok" == "1" ]]; then
    passed=$((passed + 1))
    echo "PASS: $name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (exit=$ec, expected=$want)" >&2
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
  fi
}

run_case "OK-real-tree" 0 "" "OK:"

for fixture in "$fixtures"/*/; do
  name=$(basename "$fixture")
  case "$name" in
    OK-*)
      run_case "$name" 0 "${fixture%/}/skills" "OK:"
      ;;
    FAIL-*)
      n=${name#FAIL-}
      n=${n%%-*}
      run_case "$name" 1 "${fixture%/}/skills" "[단언 $n]"
      ;;
    *)
      echo "test-lint-interview-verification: fixture '$name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      ;;
  esac
done

# Registration — asked of make itself, the same way the sibling lint tests do.
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//')
if grep -qxF 'bash scripts/lint-interview-verification.sh' <<EOF
$lint_recipe
EOF
then
  passed=$((passed + 1))
  echo "PASS: registered-in-make-lint"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-make-lint — make lint 레시피에 bash scripts/lint-interview-verification.sh 가 없다" >&2
fi
lint_test_words=$(printf '%s\n' "$lint_tests" | tr ' \t' '\n\n')
if grep -qxF 'scripts/test-lint-interview-verification.sh' <<EOF
$lint_test_words
EOF
then
  passed=$((passed + 1))
  echo "PASS: registered-in-LINT_TESTS"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-LINT_TESTS — LINT_TESTS 에 scripts/test-lint-interview-verification.sh 가 없다" >&2
fi

echo "test-lint-interview-verification: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
