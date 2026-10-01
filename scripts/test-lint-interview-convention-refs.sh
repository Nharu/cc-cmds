#!/usr/bin/env bash
# Test scripts/lint-interview-convention-refs.sh against
# tests/fixtures/lint-interview-convention-refs/.
#
# Each fixture is a `skills/` root. The directory name encodes the expectation:
#   OK-*       → exit 0, output `OK:`
#   SKIP-*     → exit 0, output `SKIP:` (neither the convention nor a reader)
#   FAIL-<n>-* → exit 1, and the output names `[단언 <n>]`
#
# The OK tree's autopilot places a `**5b (second tail)` paragraph right after
# 5j, and splits 5j's text over two paragraphs with the read sentence in the
# second. `FAIL-3-read-outside-zone` moves that sentence below the second-tail
# label. The pair pins the zone end: a blank line must not end a zone, and a
# label followed by a parenthesis must — a zone-end pattern that only knew
# `**5b — ` would read the moved sentence as 5j's and pass the FAIL tree.
#
# The real tree is run as well, and the lint and this test must be registered
# in `make lint` and LINT_TESTS.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
LINT="$script_dir/lint-interview-convention-refs.sh"
fixtures="$repo_root/tests/fixtures/lint-interview-convention-refs"

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
    out=$(SKILLS_ROOT= bash "$LINT" 2>&1)
  else
    out=$(SKILLS_ROOT="$root" bash "$LINT" 2>&1)
  fi
  ec=$?
  [[ "$ec" == "$want" ]] || ok=0
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
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
    SKIP-*)
      run_case "$name" 0 "$fixture/skills" "SKIP:"
      ;;
    FAIL-*)
      n=${name#FAIL-}
      n=${n%%-*}
      run_case "$name" 1 "$fixture/skills" "[단언 $n]"
      ;;
    *)
      echo "test-lint-interview-convention-refs: fixture '$name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      ;;
  esac
done

# Registration — asked of make itself, the same way the sibling lint tests do.
lint_recipe=$(MAKEFLAGS= MAKELEVEL= make -n -C "$repo_root" --no-print-directory lint 2>/dev/null)
lint_tests=$(awk '/^LINT_TESTS :=/ { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$repo_root/Makefile" \
  | sed -e 's/^LINT_TESTS :=//' -e 's/\\$//')
if printf '%s\n' "$lint_recipe" | grep -qxF 'bash scripts/lint-interview-convention-refs.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-make-lint"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-make-lint — make lint 레시피에 bash scripts/lint-interview-convention-refs.sh 가 없다" >&2
fi
if printf '%s\n' "$lint_tests" | tr ' \t' '\n\n' | grep -qxF 'scripts/test-lint-interview-convention-refs.sh'; then
  passed=$((passed + 1))
  echo "PASS: registered-in-LINT_TESTS"
else
  failures=$((failures + 1))
  echo "FAIL: registered-in-LINT_TESTS — LINT_TESTS 에 scripts/test-lint-interview-convention-refs.sh 가 없다" >&2
fi

echo "test-lint-interview-convention-refs: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
