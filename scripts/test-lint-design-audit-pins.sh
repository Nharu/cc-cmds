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
# THREE PRECONDITIONS make the declaration binding rather than decorative.
#   (P1) `EXPECT` must declare at least one line. An empty or all-comment EXPECT
#        satisfies every substring test vacuously and silently reduces the
#        fixture to the exit-code check this mechanism exists to replace.
#   (P2) A FAIL fixture must declare at least one `FAIL:` line. The count
#        equality already forces this wherever the lint emits such a line, so on
#        today's lints the precondition is redundant — it is stated anyway,
#        because it is what makes the fixture's claim explicit and it fails
#        loudly against a lint that signals failure by exit code alone.
#   (P3) Every `OK:` or `SKIP:` line the lint emits must be covered by an EXPECT
#        declaration. The count equality bounds the FAIL side only, so without
#        this an EXPECT can be WEAKENED rather than emptied into passing: drop
#        the arity summary from an OK fixture and what remains still holds while
#        every pinned literal quietly loses its independent coverage. `SKIP:` is
#        admitted alongside `OK:` because a skip is a summary line too, and an
#        OK-only rule would falsely reject the skip fixtures.
#
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
  declared_lines=0
  expected_fail_lines=0
  declarations=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    if [[ "$trimmed" == '#'* ]]; then
      continue
    fi
    declared_lines=$((declared_lines + 1))
    declarations+=("$trimmed")
    if [[ "$trimmed" == FAIL:* ]]; then
      expected_fail_lines=$((expected_fail_lines + 1))
    fi
    if [[ "$output" != *"$trimmed"* ]]; then
      problems+=("missing expected diagnostic: $trimmed")
    fi
  done < "$expect_file"

  # (P1) an EXPECT that declares nothing asserts nothing.
  if (( declared_lines == 0 )); then
    problems+=("EXPECT declares no lines; a fixture must state what it proves")
  fi

  # (P2) a FAIL fixture must name at least one diagnostic.
  if [[ "$want" == 1 && "$expected_fail_lines" == 0 ]]; then
    problems+=("EXPECT declares no FAIL: line for a FAIL fixture")
  fi

  # (P3) no summary line may go undeclared.
  while IFS= read -r out_line; do
    case "$out_line" in
      OK:*|SKIP:*) ;;
      *) continue ;;
    esac
    covered=0
    for decl in ${declarations+"${declarations[@]}"}; do
      if [[ "$out_line" == *"$decl"* ]]; then
        covered=1
        break
      fi
    done
    if (( covered == 0 )); then
      problems+=("undeclared summary line: $out_line")
    fi
  done <<< "$output"


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
