#!/usr/bin/env bash
# Test scripts/lint-verification-literals.sh against
# tests/fixtures/lint-verification-literals/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing _common/ and
# implement/ as needed). The directory name encodes the expected exit code:
#   T-VERIF-OK-*   → expected exit 0
#   T-VERIF-FAIL-* → expected exit 1
#
# EXPECT — the same declaration format `test-lint-design-audit-pins.sh` fixes,
# adopted here so the two suites share one convention rather than two:
#   * every fixture directory MUST contain an `EXPECT` file;
#   * blank lines and `#` lines are ignored;
#   * every other line must appear as a substring of the combined output;
#   * the number of output lines beginning with `FAIL:` must equal the number of
#     EXPECT lines beginning with `FAIL:` — so the declaration is an equality,
#     not a floor, and a fixture cannot pass by failing for a second reason.
#
# The OK fixture's EXPECT carries the lint's one-line arity summary, which names
# every pinned group's size; dropping any single pinned literal changes a number
# on that line and turns the fixture red.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-verification-literals"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-VERIF-OK-*)   want=0 ;;
    T-VERIF-FAIL-*) want=1 ;;
    *)
      echo "test-lint-verification-literals: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  expect_file="$fixture/EXPECT"
  if [[ ! -f "$expect_file" ]]; then
    echo "FAIL: $fixture_name — no EXPECT file; a fixture must declare the diagnostic it proves" >&2
    failures=$((failures + 1))
    continue
  fi

  set +e
  output=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-verification-literals.sh" 2>&1)
  ec=$?
  set -e

  problems=()

  if [[ "$ec" != "$want" ]]; then
    problems+=("exit=$ec, expected=$want")
  fi

  expected_fail_lines=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    if [[ "$trimmed" == '#'* ]]; then
      continue
    fi
    if [[ "$trimmed" == FAIL:* ]]; then
      expected_fail_lines=$((expected_fail_lines + 1))
    fi
    if [[ "$output" != *"$trimmed"* ]]; then
      problems+=("missing expected diagnostic: $trimmed")
    fi
  done < "$expect_file"

  actual_fail_lines=$(printf '%s\n' "$output" | grep -c '^FAIL:' || true)
  if [[ "$actual_fail_lines" != "$expected_fail_lines" ]]; then
    problems+=("FAIL-line count $actual_fail_lines, expected $expected_fail_lines")
  fi

  if (( ${#problems[@]} == 0 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, ${expected_fail_lines} declared diagnostic(s))"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name" >&2
    printf '        %s\n' "${problems[@]}" >&2
  fi
done

echo "test-lint-verification-literals: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
