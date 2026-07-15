#!/usr/bin/env bash
# Test scripts/lint-review-prompt-parity.sh against
# tests/fixtures/lint-review-prompt-parity/.
#
# Each fixture is a SKILLS_ROOT-shaped directory (containing design-review/ and
# design-review-lite/ as needed). Convention: fixture directory name encodes the
# expected exit code.
#   T-PARITY-OK-*   → expected exit 0
#   T-PARITY-FAIL-* → expected exit 1
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-review-prompt-parity"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-PARITY-OK-*)   want=0 ;;
    T-PARITY-FAIL-*) want=1 ;;
    *)
      echo "test-lint-review-prompt-parity: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-review-prompt-parity.sh" 2>&1)
  ec=$?
  set -e

  ok=1
  if [[ "$ec" != "$want" ]]; then
    ok=0
    echo "FAIL: $fixture_name (exit=$ec, expected=$want)" >&2
  fi

  # Intent check: every FAIL fixture must name the assertion it exists to guard.
  # An exit-code-only pass lets a fixture 'exit 1 for the wrong reason' and
  # silently stop guarding its target. EXPECT lines are substrings that MUST all
  # appear in the lint's stderr.
  if [[ "$want" == 1 ]]; then
    expect_file="$fixture/EXPECT"
    if [[ ! -f "$expect_file" ]]; then
      echo "FAIL: $fixture_name — FAIL fixture missing EXPECT file (intent unpinned)" >&2
      ok=0
    else
      while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        if [[ "$out" != *"$sub"* ]]; then
          echo "FAIL: $fixture_name — lint stderr missing expected assertion: $sub" >&2
          ok=0
        fi
      done < "$expect_file"
    fi
  fi

  if (( ok )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec, expected=$want)"
  else
    failures=$((failures + 1))
  fi
done

echo "test-lint-review-prompt-parity: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
