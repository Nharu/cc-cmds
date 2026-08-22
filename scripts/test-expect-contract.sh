#!/usr/bin/env bash
# Test scripts/_expect-contract.sh — the judgment the five lint suites share.
#
# WHY THIS EXISTS SEPARATELY. The fixture suites cannot test their own contract.
# A fixture that violates a precondition turns its suite red, which is the
# correct behaviour and therefore indistinguishable from a broken suite, so
# "does P4 fire" has no expression in that layer. This driver calls
# `judge_fixture` directly with synthetic inputs and asserts on the verdict,
# which is the only place the preconditions themselves can be demonstrated.
#
# Each case declares the fixture name it simulates, the EXPECT body, the wanted
# and actual exit codes, the lint output, and whether `judge_fixture` should
# report a problem — plus, when it should, a substring of the problem text, so a
# case cannot pass because something else went wrong.
#
# Exit codes:
#   0 — every case behaved as declared
#   1 — at least one case did not

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./_expect-contract.sh
source "$script_dir/_expect-contract.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/expect-contract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cases_passed=0
cases_failed=0

# The case roster, written out by hand.
#
# WHY A LITERAL LIST AND NOT A DERIVED ONE. Deleting a case used to lower the
# pass count and change nothing else — the driver still exited 0 and the suite
# above it reads only that status, so a case could be removed in silence. The
# roster closes that. It is hand-written on purpose: generating it from this
# file with the same matcher the driver runs would re-create the forbidden
# dependence at authoring time, and a roster that moves with its subject cannot
# see the subject move.
#
# Adding or removing a case is therefore a two-place edit, deliberately.
EXPECTED_CASES=(
  'OK fixture, whole-line declaration'
  'FAIL fixture, labelled declaration'
  'exit-code clause — want and actual disagree, nothing else does'
  'blank-line skip — an all-blank EXPECT declares nothing'
  'substring assertion — a declared diagnostic the output never carries'
  'P1 — EXPECT is all comments'
  'P2 — FAIL fixture declares no FAIL line'
  'P3 — OK declaration shortened to a prefix'
  'P3 — SKIP declaration matches as a substring'
  'P3 — a SKIP line no declaration covers'
  'output normalisation — an indented OK line escapes P3'
  'output normalisation — an indented SKIP line escapes P3'
  'output normalisation — an indented FAIL line escapes the count clause'
  'P4 — FAIL declaration is the bare literal'
  'P4 — FAIL declaration carries no label separator'
  'P4 — FAIL declaration has an empty message'
  'P4 — FAIL declaration has a whitespace-only label'
  'P4 — FAIL declaration has a whitespace-only message'
  'count clause — a second, undeclared FAIL line'
)
ran_cases=()

# check <case_name> <expect_body> <want> <ec> <output> <verdict> [problem_substring]
#   verdict: pass — judge_fixture must count it as a PASS
#            fail — judge_fixture must count it as a FAILURE
check() {
  local case_name="$1" expect_body="$2" want="$3" ec="$4" output="$5" verdict="$6" needle="${7:-}"
  local expect_file="$tmp/EXPECT"
  ran "$case_name"
  printf '%s\n' "$expect_body" > "$expect_file"

  # judge_fixture reports through `passed` / `failures` and prints its problem
  # list to stderr, so both are captured here rather than inferred. The call is
  # NOT wrapped in a command substitution: that is a subshell, and the two
  # counters would be incremented in it and lost — the verdict would then read
  # `pass` for every case while the problem text said otherwise. Redirection to
  # files keeps the call in this shell.
  local passed=0 failures=0 out
  judge_fixture "$case_name" "$expect_file" "$want" "$ec" "$output" \
    > "$tmp/stdout" 2> "$tmp/stderr"
  out=$(cat "$tmp/stdout" "$tmp/stderr")

  local got
  if (( failures > 0 )); then got=fail; else got=pass; fi

  if [[ "$got" != "$verdict" ]]; then
    echo "FAIL: $case_name — verdict $got, expected $verdict" >&2
    printf '        %s\n' "$out" >&2
    cases_failed=$((cases_failed + 1))
    return
  fi
  if [[ -n "$needle" && "$out" != *"$needle"* ]]; then
    echo "FAIL: $case_name — verdict was $got but the reason was not the declared one; expected to see: $needle" >&2
    printf '        %s\n' "$out" >&2
    cases_failed=$((cases_failed + 1))
    return
  fi
  cases_passed=$((cases_passed + 1))
  echo "PASS: $case_name"
}

# ran <case_name> — record that a case executed, for the roster gate below.
ran() { ran_cases+=("$1"); }

OK_LINE='OK:   thing — 3 pins all intact'
FAIL_LINE='FAIL: thing (region) — pinned literal missing: x'

# The shape a healthy fixture has.
check 'OK fixture, whole-line declaration' \
      "$OK_LINE" 0 0 "$OK_LINE" pass

check 'FAIL fixture, labelled declaration' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE" pass

# The exit-code clause, isolated. want and actual disagree and NOTHING else
# does: the declaration is present in the output, the FAIL counts agree, and no
# summary line goes undeclared. Deleting that clause used to leave both this
# driver and the whole suite green.
check 'exit-code clause — want and actual disagree, nothing else does' \
      "$FAIL_LINE" 1 0 "$FAIL_LINE" fail \
      'exit=0, expected=1'

# The blank-line skip, isolated. An EXPECT of nothing but blank lines declares
# nothing; without the skip those lines become declarations that every output
# vacuously satisfies, and the fixture passes while asserting nothing.
check 'blank-line skip — an all-blank EXPECT declares nothing' \
      '' 0 0 '' fail \
      'EXPECT declares no lines'

# The substring assertion, isolated. It is what makes 69 fixtures and 136
# declarations mean anything, and it had no case of its own: here the counts
# agree and the exit codes agree, so nothing but this clause can fire.
check 'substring assertion — a declared diagnostic the output never carries' \
      'FAIL: thing (region) — pinned literal missing: x' 1 1 \
      'FAIL: other (region) — something entirely different' fail \
      'missing expected diagnostic'

# (P1) an EXPECT that declares nothing asserts nothing.
check 'P1 — EXPECT is all comments' \
      '# nothing declared here' 1 1 "$FAIL_LINE" fail \
      'EXPECT declares no lines'

# (P2) a FAIL fixture must name at least one diagnostic.
check 'P2 — FAIL fixture declares no FAIL line' \
      'some substring' 1 0 'some substring' fail \
      'declares no FAIL: line'

# (P3) an OK declaration weakened to a prefix must not count as coverage.
check 'P3 — OK declaration shortened to a prefix' \
      'OK:' 0 0 "$OK_LINE" fail \
      'undeclared summary line'

# (P3) SKIP is substring on purpose, because it names a run-varying path.
check 'P3 — SKIP declaration matches as a substring' \
      'SKIP: no call sites under' 0 0 'SKIP: no call sites under /tmp/whatever' pass

# (P3) the SKIP arm's rejecting side. Every existing case exercised SKIP only
# where a declaration covered it; nothing showed the arm firing.
check 'P3 — a SKIP line no declaration covers' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
SKIP: nothing to check under /tmp/whatever" fail \
      'undeclared summary line (substring match)'

# Output-side normalisation, three shapes. The EXPECT side is trimmed before it
# is compared and the output side was not, so an indented summary line fell to
# the ignore arm and an indented diagnostic slipped past a line-anchored count.
# Each of the three is a line the reader plainly sees and the judgment did not.
check 'output normalisation — an indented OK line escapes P3' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
   OK:   summary — 3 pins all intact" fail \
      'undeclared summary line (whole match)'

check 'output normalisation — an indented SKIP line escapes P3' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
   SKIP: nothing to check here" fail \
      'undeclared summary line (substring match)'

check 'output normalisation — an indented FAIL line escapes the count clause' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
   FAIL: other (region) — a second problem" fail \
      'FAIL-line count'

# (P4) a FAIL declaration weakened to the bare prefix.
check 'P4 — FAIL declaration is the bare literal' \
      'FAIL:' 1 1 "$FAIL_LINE" fail \
      'FAIL declaration is weaker than the contract allows'

# (P4) content but no label separator: still weaker than the contract allows.
check 'P4 — FAIL declaration carries no label separator' \
      'FAIL: something went wrong' 1 1 'FAIL: something went wrong' fail \
      'FAIL declaration is weaker than the contract allows'

# (P4) an empty message after the separator is not a message.
check 'P4 — FAIL declaration has an empty message' \
      'FAIL: thing — ' 1 1 'FAIL: thing — ' fail \
      'FAIL declaration is weaker than the contract allows'

# (P4) whitespace-only sides. `FAIL:  — msg` — two spaces after the colon —
# used to PASS: the prefix strip leaves one space on the left side and a
# non-empty test calls that a label. The right side is symmetric.
check 'P4 — FAIL declaration has a whitespace-only label' \
      'FAIL:  — a message' 1 1 'FAIL:  — a message' fail \
      'FAIL declaration is weaker than the contract allows'

check 'P4 — FAIL declaration has a whitespace-only message' \
      'FAIL: a label —  ' 1 1 'FAIL: a label —  ' fail \
      'FAIL declaration is weaker than the contract allows'

# The count clause: an extra unexpected diagnostic must not pass.
check 'count clause — a second, undeclared FAIL line' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
FAIL: other (region) — something else broke" fail \
      'FAIL-line count'

# The roster gate. Compared as SETS in both directions, so a case that is
# deleted and a case that is added without being declared both fail here.
declared=$(printf '%s\n' "${EXPECTED_CASES[@]}" | sort)
actual=$(printf '%s\n' ${ran_cases+"${ran_cases[@]}"} | sort)
if [[ "$declared" != "$actual" ]]; then
  echo "FAIL: case roster — the cases that ran are not the cases this file declares" >&2
  echo "  declared but did not run:" >&2
  comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$actual") | sed 's/^/    /' >&2
  echo "  ran but not declared:" >&2
  comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$actual") | sed 's/^/    /' >&2
  cases_failed=$((cases_failed + 1))
fi

echo "test-expect-contract: $cases_passed passed, $cases_failed failed, ${#EXPECTED_CASES[@]} declared"
if (( cases_failed > 0 )); then
  exit 1
fi
exit 0
