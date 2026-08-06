#!/usr/bin/env bash
# Test scripts/lint-design-audit-pins.sh against
# tests/fixtures/lint-design-audit-pins/.
#
# Each fixture is a SKILLS_ROOT-shaped directory. The directory name encodes the
# expected exit code:
#   T-AUDIT-OK-*   → expected exit 0
#   T-AUDIT-FAIL-* → expected exit 1
#
# EXPECT — the diagnostic contract (declaration format, fixed here and shared by
# every driver that adopts it).
#
#   Every fixture directory MUST contain a file named `EXPECT`. It declares what
#   the lint is supposed to SAY, not merely that it said something:
#     * blank lines and lines whose first non-space character is `#` are ignored;
#     * every other line must appear as a SUBSTRING of the lint's combined
#       stdout+stderr;
#     * additionally, the number of output lines beginning with `FAIL:` must
#       equal the number of EXPECT lines beginning with `FAIL:`.
#
#   The count clause is what makes an expectation exact rather than a floor. A
#   substring list alone answers "did the intended diagnostic fire"; the count
#   also answers "and nothing else did", which is the half that catches a
#   fixture going red for a second, unintended reason and thereby masking the
#   regression it was built to detect.
#
#   `EXPECT` is mandatory, not optional. Exit-code-only checking is how a FAIL
#   fixture passes for the wrong cause — a fixture that fails because its file
#   is missing looks identical to one that fails because the pinned literal was
#   dropped. Making the file mandatory means a fixture cannot be added without
#   stating what it proves.
#
#   The OK fixture's EXPECT carries the lint's one-line arity summary. That line
#   names the size of every pinned array, so removing any single literal changes
#   a number in it and turns the OK fixture red — which is what gives each
#   pinned literal independent coverage instead of leaving it to whichever FAIL
#   fixture happens to name it.
#
# The test invokes the lint with `SKILLS_ROOT=<fixture-dir>` so the real plugin
# skills are untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-design-audit-pins"

failures=0
passed=0

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

  expect_file="$fixture/EXPECT"
  if [[ ! -f "$expect_file" ]]; then
    echo "FAIL: $fixture_name — no EXPECT file; a fixture must declare the diagnostic it proves" >&2
    failures=$((failures + 1))
    continue
  fi

  set +e
  output=$(SKILLS_ROOT="$fixture" bash "$script_dir/lint-design-audit-pins.sh" 2>&1)
  ec=$?
  set -e

  problems=()

  if [[ "$ec" != "$want" ]]; then
    problems+=("exit=$ec, expected=$want")
  fi

  # Every EXPECT line must appear in the output.
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

  # ...and nothing else may have failed.
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

echo "test-lint-design-audit-pins: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
