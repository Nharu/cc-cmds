#!/usr/bin/env bash
# Test scripts/lint-team-budget-pins.sh against
# tests/fixtures/lint-team-budget-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory. Convention: the directory
# name encodes the expected exit code.
#   T-BUDGET-OK-*   → expected exit 0
#   T-BUDGET-FAIL-* → expected exit 1
#
# **The exit code alone is not the assertion.** A lint can exit 1 for a reason
# unrelated to what the fixture mutates, and it can exit 0 while reaching none
# of the pins the fixture was built to exercise — both read as coverage. So
# every fixture also carries an `expect.txt`: each of its lines must be a
# PREFIX of some line the lint printed. Prefix rather than substring, because
# the interesting text (`FAIL: <path>:<line>`, `OK: … N pin(s) checked`) starts
# a line, and a mid-line substring match would accept a message about a
# different file.
#
# The runner CAPTURES stdout and stderr and matches against both. The previous
# version discarded them, which is why the real-tree total could not fail: a
# check whose output nobody reads cannot be observed to have run.
#
# An empty `expect.txt`, or one containing only blank lines, is a FAILURE, not
# a pass — a vacuous expectation is the same silent coverage this file exists
# to prevent. A missing `expect.txt` is likewise an error.
#
# The two revert fixtures (OK-2, OK-3) are load-bearing: they assert that
# removing a lever's section leaves the lint green **and announces the skip**,
# so `git revert` of a single lever cannot turn `make check` red on its way
# back nor pass off a skipped lever as a checked one.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-team-budget-pins"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-BUDGET-OK-*)   want=0 ;;
    T-BUDGET-FAIL-*) want=1 ;;
    *)
      echo "test-lint-team-budget-pins: fixture '$fixture_name' has unrecognized prefix" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  set +e
  out=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-team-budget-pins.sh" 2>&1)
  ec=$?
  set -e

  ok=1
  reason=""

  if [[ "$ec" != "$want" ]]; then
    ok=0
    reason="exit=$ec expected=$want"
  fi

  expect_file="$fixture/expect.txt"
  if [[ ! -f "$expect_file" ]]; then
    ok=0
    reason="${reason:+$reason; }no expect.txt (exit code alone is not an assertion)"
  else
    # Non-blank expectation lines only; a file of blank lines asserts nothing.
    expect_lines=$(grep -v '^[[:space:]]*$' "$expect_file" || true)
    if [[ -z "$expect_lines" ]]; then
      ok=0
      reason="${reason:+$reason; }expect.txt is vacuous"
    else
      while IFS= read -r want_line; do
        [[ -n "$want_line" ]] || continue
        if [[ "$want_line" == '^'* ]]; then
          # Prefix anchor. Used to key a fence expectation on the FILE PATH
          # without keying it on the line number the fence reports — line
          # numbers shift with any edit above them, and one fixture exists
          # precisely to exercise a path whose numbering is unstable.
          if ! printf '%s\n' "$out" \
            | awk -v p="${want_line#^}" 'index($0, p) == 1 { found = 1 } END { exit(found ? 0 : 1) }'; then
            ok=0
            reason="${reason:+$reason; }no output line begins with: ${want_line#^}"
          fi
        else
          # Substring anywhere. Used for the message text that follows a
          # variable-width prefix, so a fixture can assert WHY it failed and
          # not merely that something failed.
          if ! printf '%s\n' "$out" | grep -qF -- "$want_line"; then
            ok=0
            reason="${reason:+$reason; }missing expected text: $want_line"
          fi
        fi
      done <<EOF
$expect_lines
EOF
    fi
  fi

  if (( ok == 1 )); then
    passed=$((passed + 1))
    echo "PASS: $fixture_name (exit=$ec)"
  else
    failures=$((failures + 1))
    echo "FAIL: $fixture_name — $reason" >&2
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  fi
done

echo "test-lint-team-budget-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
