#!/usr/bin/env bash
# The EXPECT contract, in one definition.
#
# WHAT THE CONTRACT IS. Each fixture directory declares, in a file named `EXPECT`,
# what the lint is supposed to SAY — not merely that it said something:
#   * blank lines and lines whose first non-space character is `#` are ignored;
#   * every other line must appear as a SUBSTRING of the lint's combined
#     stdout+stderr;
#   * the number of output lines beginning with `FAIL:` must EQUAL the number of
#     EXPECT lines beginning with `FAIL:`.
#
# The count clause is what makes an expectation exact rather than a floor. A
# substring list alone answers "did the intended diagnostic fire"; the count also
# answers "and nothing else did", which is the half that catches a fixture going
# red for a second, unintended reason and thereby masking the regression it was
# built to detect.
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
#        declaration, and the comparison is keyed on the line kind:
#          * `OK:`   — the declaration must equal the emitted line WHOLE.
#          * `SKIP:` — substring, deliberately.
#        The count equality bounds the FAIL side only, so without (P3) an EXPECT
#        can be WEAKENED rather than emptied into passing. The whole-line half is
#        what makes that weakening unreachable: under a substring rule a
#        declaration could be shortened to a prefix — in the limit to the bare
#        literal `OK:` — and the arity summary would still be "covered" while
#        pinning nothing, after which a pinned literal can be dropped from its
#        array and a shipped section deleted with it, whole suite green.
#        The `SKIP:` exception is not a convenience: a skip summary names the
#        absolute path it searched, which varies with the run, so no EXPECT can
#        state it whole.
#   (P4) A `FAIL:` declaration must carry a label and a message, written as
#        `FAIL: <label> — <message>`. (P3) closed the weakening hole on the two
#        summary kinds and left it open on the kind where the diagnostic content
#        actually lives: replacing every `FAIL:` declaration in a suite with the
#        bare literal `FAIL:` was measured to leave that suite fully green, so a
#        fixture could go on claiming to prove something while asserting only
#        that the lint failed somehow. The em dash is what makes the requirement
#        more than "non-empty" — it forces the declaration to name WHICH check
#        fired, which is the half a substring match cannot supply on its own.
#        This hole predates the delta that added (P3); what that delta did was
#        close the `OK:` half of a two-sided opening, and this closes the other.
#
# WHY ONE DEFINITION. This block existed five times. Asserting that the five
# copies agree is the pattern this repository has already recorded as failed —
# two same-named copies of the region extractor were re-synchronized by hand
# under a comment claiming they were byte-identical, which they were not, by
# three lines and two prefixes. The invariant is therefore not "the copies match"
# but "there are no copies": what does not exist cannot drift. The unit matters
# too — the span the five drivers share is 78 lines (77 contiguous plus one),
# not the 82 of the extracted function body and not the 18 of the
# weakening-prevention arm alone, and extracting only the arm would satisfy the
# words "fix it once" while leaving the fix five deep.
#
# WHAT (P4) REQUIRES OF THE LINTS THEMSELVES, stated because it is an obligation
# and was not written down anywhere. (P4) constrains the EXPECT *declaration*,
# and a declaration has to be a substring of the emitted line — so in practice
# every lint that this contract judges must emit its failures as
# `FAIL: <label> — <message>` with an em dash and non-space text on both sides.
# All five do today; the rule is recorded here so the sixth is not written
# against a format nobody stated.
#
# Usage:
#   source scripts/_expect-contract.sh
#   judge_fixture <fixture_name> <expect_file> <want_exit> <actual_exit> <output>
#
# The caller owns `passed` and `failures`; this function increments one of them.
# It is called in the caller's shell, never in a subshell, which is what makes
# that possible.

# judge_fixture <fixture_name> <expect_file> <want> <ec> <output>
judge_fixture() {
  local fixture_name="$1" expect_file="$2" want="$3" ec="$4" output="$5"
  local line trimmed out_line decl match_kind covered
  local declared_lines expected_fail_lines actual_fail_lines label lhs rhs
  local -a problems declarations

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

    # (P4) a FAIL declaration must say WHICH check fired, not merely that one did.
    for decl in ${declarations+"${declarations[@]}"}; do
      case "$decl" in
        FAIL:*) ;;
        *) continue ;;
      esac
      label="${decl#FAIL:}"
      # `-z` is the wrong test here and was measured wrong: the prefix strip
      # removes `FAIL:` and leaves whatever spacing followed it, so
      # `FAIL:  — msg` (two spaces) hands this clause a one-space left side,
      # which is non-empty and passes. The right question is whether the side
      # holds any non-space character at all.
      lhs="${label%% — *}"
      rhs="${label##* — }"
      if [[ "$label" != *' — '* ]] \
         || [[ ! "$lhs" =~ [^[:space:]] ]] \
         || [[ ! "$rhs" =~ [^[:space:]] ]]; then
        problems+=("FAIL declaration is weaker than the contract allows; write it as 'FAIL: <label> — <message>' so it names which check fired: $decl")
      fi
    done

    # (P3) no summary line may go undeclared, matched per line kind.
    #
    # The match is an `if`, never `[[ … ]] && { … }`: under `set -euo pipefail` an
    # AND-list whose test fails is the loop body's last command, and its non-zero
    # status aborts the driver mid-sweep — silently turning "no fixture failed"
    # into "the sweep stopped early". The `if` form has no such status to leak.
    while IFS= read -r out_line; do
      # The EXPECT side is trimmed before it is compared, and the output side
      # was not. That asymmetry let three shapes through: an indented `OK:` and
      # an indented `SKIP:` fell to the `*)` arm and escaped this clause
      # entirely, and an indented `FAIL:` escaped the count clause below, whose
      # `grep` is line-anchored. Normalising here makes the two sides symmetric
      # rather than adding a second rule to remember.
      out_line="${out_line#"${out_line%%[![:space:]]*}"}"
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
    # Counted over the SAME normalisation the clause above applies, for the same
    # reason: a line-anchored `grep` cannot see an indented diagnostic, and a
    # lint that indents one would have it counted as absent while the reader
    # sees it.
    actual_fail_lines=$(printf '%s\n' "$output" \
      | sed -E 's/^[[:space:]]+//' | grep -c '^FAIL:' || true)
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
}
