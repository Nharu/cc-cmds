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

# check <case_name> <expect_body> <want> <ec> <output> <verdict> [problem_substring]
#   verdict: pass — judge_fixture must count it as a PASS
#            fail — judge_fixture must count it as a FAILURE
check() {
  local case_name="$1" expect_body="$2" want="$3" ec="$4" output="$5" verdict="$6" needle="${7:-}"
  local expect_file="$tmp/EXPECT"
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

OK_LINE='OK:   thing — 3 pins all intact'
FAIL_LINE='FAIL: thing (region) — pinned literal missing: x'

# The shape a healthy fixture has.
check 'OK fixture, whole-line declaration' \
      "$OK_LINE" 0 0 "$OK_LINE" pass

check 'FAIL fixture, labelled declaration' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE" pass

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

# The count clause: an extra unexpected diagnostic must not pass.
check 'count clause — a second, undeclared FAIL line' \
      "$FAIL_LINE" 1 1 "$FAIL_LINE
FAIL: other (region) — something else broke" fail \
      'FAIL-line count'

echo "test-expect-contract: $cases_passed passed, $cases_failed failed"
if (( cases_failed > 0 )); then
  exit 1
fi
exit 0
