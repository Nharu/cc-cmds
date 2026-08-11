#!/usr/bin/env bash
# Test scripts/lint-extractor-call-contract.sh against
# tests/fixtures/lint-extractor-call-contract/.
#
# Each fixture is a SCRIPTS_ROOT-shaped directory holding a consumer script and
# a copy of the helper. Convention: fixture directory name encodes the exit code.
#   T-EXTR-OK-*   → expected exit 0
#   T-EXTR-FAIL-* → expected exit 1
#
# The lint checks ONE property — that every `extract_between` call site is
# guarded by `if` on its own line — so the fixture set is one OK and one bare
# assignment. Breadth lives in the lint, which reads every call site in the
# tree uniformly; fixtures here only prove the reader works.
#
# EXPECT — the same declaration format `test-lint-design-audit-pins.sh` fixes,
# adopted here so the three suites share one convention rather than three:
#   * every fixture directory MUST contain an `EXPECT` file;
#   * blank lines and `#` lines are ignored;
#   * every other line must appear as a substring of the combined output;
#   * the number of output lines beginning with `FAIL:` must equal the number of
#     EXPECT lines beginning with `FAIL:` — so the declaration is an equality,
#     not a floor, and a fixture cannot pass by failing for a second reason.
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
#        declaration, and **the comparison is keyed on the line kind**:
#          * `OK:`   — the declaration must equal the emitted line WHOLE.
#          * `SKIP:` — substring, deliberately.
#        The count equality bounds the FAIL side only, so without (P3) an EXPECT
#        can be WEAKENED rather than emptied into passing. The whole-line half is
#        what makes that weakening unreachable: under a substring rule a
#        declaration could be shortened to a prefix — in the limit to the bare
#        literal `OK:` — and the arity summary would still be "covered" while
#        pinning nothing, after which a pinned literal can be dropped from its
#        array and a shipped section deleted with it, whole suite green.
#        **The `SKIP:` exception is not a convenience.** A skip summary names the
#        absolute path it searched, which varies with the run, so no EXPECT can
#        reproduce it as a whole line; a blanket whole-line rule turns exactly
#        the two skip fixtures red and nothing else (measured 12/1 and 10/1).
#        Both halves are required: whole-line alone breaks the skips, substring
#        alone is the hole.
#
# The test invokes the lint with `SCRIPTS_ROOT=<fixture-dir>` so the real scripts
# directory is untouched.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
fixtures="$repo_root/tests/fixtures/lint-extractor-call-contract"

failures=0
passed=0

for fixture in "$fixtures"/*/; do
  fixture_name=$(basename "$fixture")
  case "$fixture_name" in
    T-EXTR-OK-*)   want=0 ;;
    T-EXTR-FAIL-*) want=1 ;;
    *)
      echo "test-lint-extractor-call-contract: fixture '$fixture_name' has unrecognized prefix" >&2
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
  output=$(SCRIPTS_ROOT="$fixture" bash "$script_dir/lint-extractor-call-contract.sh" 2>&1)
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

  # (P3) no summary line may go undeclared, matched per line kind.
  #
  # The match is an `if`, never `[[ … ]] && { … }`: under `set -euo pipefail` an
  # AND-list whose test fails is the loop body's last command, and its non-zero
  # status aborts the driver mid-sweep — silently turning "no fixture failed"
  # into "the sweep stopped early". The `if` form has no such status to leak.
  while IFS= read -r out_line; do
    case "$out_line" in
      OK:*)   match_kind=whole ;;
      SKIP:*) match_kind=substring ;;
      *)      continue ;;
    esac
    covered=0
    for decl in ${declarations+"${declarations[@]}"}; do
      if [[ "$match_kind" == whole && "$out_line" == "$decl" ]] \
         || [[ "$match_kind" == substring && "$out_line" == *"$decl"* ]]; then
        covered=1
        break
      fi
    done
    if (( covered == 0 )); then
      problems+=("undeclared summary line ($match_kind match): $out_line")
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

echo "test-lint-extractor-call-contract: $passed passed, $failures failed"

if (( failures > 0 )); then
  exit 1
fi
exit 0
