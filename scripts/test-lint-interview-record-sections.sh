#!/usr/bin/env bash
# Test scripts/lint-interview-record-sections.sh against
# tests/fixtures/lint-interview-record-sections/.
#
# Each fixture is a `skills/` root holding the four files the lint compares —
# the sidecar contract, the shared interview convention, autopilot and the
# unattended design stage. The directory name encodes the expectation:
#   OK-*       → exit 0
#   FAIL-<n>-* → exit 1, and the output names `[단언 <n>]`
#
# Naming the assertion is what keeps a FAIL fixture honest: a tree broken in
# the wrong place would still exit 1, and only the number shows that the
# assertion the fixture was built for is the one that fired.
#
# The real tree is run as well, and the lint and this test must be registered
# in `make lint` and LINT_TESTS.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-interview-record-sections.sh"
fixtures="$repo_root/tests/fixtures/lint-interview-record-sections"

if [[ ! -d "$fixtures" ]]; then
  echo "FAIL: fixtures root missing: $fixtures" >&2
  exit 2
fi

passed=0
failures=0

run_case() {
  # run_case <name> <want-exit> <skills-root|""> [<needle>]
  local name="$1" want="$2" root="$3" needle="${4:-}" out ec ok=1
  if [[ -z "$root" ]]; then
    out=$(SKILLS_ROOT= bash "$LINT" 2>&1)
  else
    out=$(SKILLS_ROOT="$root" bash "$LINT" 2>&1)
  fi
  ec=$?
  [[ "$ec" == "$want" ]] || ok=0
  if [[ -n "$needle" ]] && ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
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
      run_case "$name" 0 "$fixture/skills" "OK:"
      ;;
    FAIL-*)
      n=${name#FAIL-}
      n=${n%%-*}
      run_case "$name" 1 "$fixture/skills" "[단언 $n]"
      ;;
    *)
      echo "test-lint-interview-record-sections: fixture '$name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      ;;
  esac
done

# Registration — asked of make itself, the same way the sibling lint tests do.
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//')
if printf '%s\n' "$lint_recipe" | grep -qxF 'bash scripts/lint-interview-record-sections.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-make-lint"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-make-lint — make lint 레시피에 bash scripts/lint-interview-record-sections.sh 가 없다" >&2
fi
if printf '%s\n' "$lint_tests" | tr ' \t' '\n\n' | grep -qxF 'scripts/test-lint-interview-record-sections.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-LINT_TESTS"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-LINT_TESTS — LINT_TESTS 에 scripts/test-lint-interview-record-sections.sh 가 없다" >&2
fi

echo "test-lint-interview-record-sections: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
