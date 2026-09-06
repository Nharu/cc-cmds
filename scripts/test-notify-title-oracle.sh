#!/usr/bin/env bash
# The third layer: measure the swallowing set against the REAL binary.
#
# The other two layers read our own source. The static lint checks the literals
# we write and the suites assert the argv we build, so if a tool upgrade changed
# WHICH characters are swallowed, both would stay green and both would be wrong
# — the set they encode is an assumption about somebody else's parser. This is
# the only thing in the tree that would notice.
#
# NO BANNER IS RAISED, HERE OR IN THE LIVENESS PROBE. The discriminator is the
# EXIT CODE of `terminal-notifier -list "<value>"`, which hands the value to the
# same argument parser the fire path uses and then prints a listing instead of
# posting a notice. A test that proved the rendering by rendering something would
# be putting notices on a person's screen every time the suite ran.
#
# THE STATUS IS READ DIRECTLY, NOT THROUGH A PIPE. Behind a pipe `$?` is the
# reader's status rather than the notifier's, which is how this measurement was
# first got wrong. Both streams are discarded because the usage text goes to
# stdout and stderr alike, so matching on prose depends on which one you happen
# to look at — the code does not.
#
# ---------------------------------------------------------------------------
# WHICH BINARY. This resolves the notifier THE WAY THE EMITTER DOES — Homebrew
# directories prepended — and then calls it by absolute path.
#
# That is a correctness requirement, not a convenience. The emitter prepends
# `/opt/homebrew/bin:/usr/local/bin` before it fires, so the program that renders
# our banners is the one in those directories. An oracle that resolved the bare
# name off the ambient PATH would be measuring whatever else happens to answer to
# that name — and on the GitHub `macos-26-arm64` image something else does.
# Measured 2026-09-05 on run 33957470368, where Homebrew itself printed the
# warning during install:
#
#   The following terminal-notifier executables are shadowed by other commands
#   earlier in your PATH:
#     terminal-notifier (shadowed by .../lib/ruby/gems/3.4.0/bin/terminal-notifier)
#
# Every one of the 25 probes then returned non-zero, so the eleven values that
# must be swallowed "passed" and the fourteen that must survive "failed" — the
# 11/14 split is the signature of a discriminator that stopped discriminating
# rather than of any claim about characters.
#
# ---------------------------------------------------------------------------
# WHY A LIVENESS PROBE, AND WHY IT IS TWO-SIDED. Resolving the right binary is
# not enough on its own: the binary can be present and still be unable to answer
# (no GUI session, a permissions prompt nobody can accept, a future rewrite that
# drops `-list`). So before any claim is measured, the discriminator is measured
# against two controls whose answers are already known:
#
#   `x`   must be ACCEPTED (exit 0)      — proves it can say yes
#   `[x`  must be REFUSED  (exit non-0)  — proves it can say no
#
# One control would not do. A probe that only checked the accepting side stays
# green when everything is refused, which is exactly the failure above; a probe
# that only checked the refusing side stays green when everything is accepted.
# The pair is what makes "it answered" different from "it discriminates".
#
# `uname` and "is the file there" are deliberately NOT used for this. Both were
# true on the runner that produced the false result.
#
# ---------------------------------------------------------------------------
# WHERE THIS TEST ACTUALLY RUNS, recorded because a skip that nobody can locate
# becomes permanent:
#
#   RUNS  — a macOS desktop with a logged-in GUI session and the Homebrew build
#           on PATH. Measured 2026-09-05: terminal-notifier 3.1.0 at
#           /opt/homebrew/bin/terminal-notifier, 25 passed / 0 failed.
#   SKIPS — a host with no notifier at all (the ubuntu leg, any Linux).
#   UNKNOWN UNTIL IT RUNS — the GitHub macOS runner. Naming the binary by its
#           Homebrew path removes the shadowing that broke it; whether a headless
#           runner can answer `-list` at all is not settled here, and the
#           liveness block below is what reports the answer either way. If it
#           skips there, the skip line names which control failed and with what
#           status, so the next reader does not have to re-derive this.
#
# A SKIP IS LOUD AND COUNTED. It prints the resolved path, both control statuses
# and the notifier's own stderr, and the summary line carries the skipped count
# beside passed and failed — a suite that reports `0 passed, 0 failed` with no
# third number is indistinguishable from one that had nothing to say.
#
# Usage: bash scripts/test-notify-title-oracle.sh

set -uo pipefail

# The emitter's own prepend, spelled the same way and honouring the same seam.
#
# THE SEAM IS HONOURED SO THIS FILE'S OWN SKIP PATH CAN BE EXERCISED. Without it
# the prepend puts the real binary ahead of any stub, so the liveness block below
# could never be driven — and a skip path that nothing ever runs is the same
# defect as a test that nothing ever runs, one level down.
#
# Honouring it is safe here for a reason that did not exist before: the two-sided
# liveness probe refuses a stub that cannot discriminate, so a stub reaches the
# claims only by reproducing the parser's answers on both controls. The seam is
# per-process — each suite is its own `bash script.sh` — so no sibling suite can
# leak it into this one.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

# The two case sets. Declared before EVERY skip path so each one can report how
# many claims went unmeasured, rather than a hardcoded number that drifts — or a
# zero, which reads as "there was nothing to do" and is the quiet shape this
# whole block exists to refuse.
SWALLOWED=( '[x' '(x' '{x' '<x' '"x' '-x' ' [x' ' (x' ' {x' ' <x' ' "x' )
PASSING=( ' -x' ')x' ']x' '}x' '>x' "'x" '.x' '#x' '~x' '가x' '1x' '답 필요' '손 필요' '자율 런' )
n_cases=$(( ${#SWALLOWED[@]} + ${#PASSING[@]} ))

NOTIFIER=$(command -v terminal-notifier 2>/dev/null || true)
if [ -z "$NOTIFIER" ]; then
  echo "SKIP: terminal-notifier not installed — nothing to measure the parser against"
  echo "      이 시험이 실제로 도는 자리는 파일 상단 주석의 「WHERE THIS TEST ACTUALLY RUNS」 에 적혀 있다."
  echo "test-notify-title-oracle: 0 passed, 0 failed, ${n_cases} skipped"
  exit 0
fi

# --- Liveness: can the discriminator still discriminate? --------------------
errfile=$(mktemp "${TMPDIR:-/tmp}/cc-oracle-err.XXXXXX")
trap 'rm -f "$errfile"' EXIT

"$NOTIFIER" -list "x" >/dev/null 2>"$errfile"
rc_accept=$?
"$NOTIFIER" -list "[x" >/dev/null 2>&1
rc_refuse=$?

if [ "$rc_accept" != "0" ] || [ "$rc_refuse" = "0" ]; then
  echo "SKIP: 판별기가 판별하지 못한다 — 이 호스트에서 삼킴 문자 집합을 잴 수 없다"
  echo "      resolved   : $NOTIFIER"
  echo "      control 「x」  (통과해야 함): exit=$rc_accept"
  echo "      control 「[x」 (삼켜져야 함): exit=$rc_refuse"
  echo "      notifier stderr:"
  sed -n '1,5p' "$errfile" 2>/dev/null || true
  echo "      두 control 이 갈리지 않으면 개별 값의 종료 코드는 문자에 대한 관측이 아니다."
  echo "      이 시험이 실제로 도는 자리는 파일 상단 주석의 「WHERE THIS TEST ACTUALLY RUNS」 에 적혀 있다."
  echo "test-notify-title-oracle: 0 passed, 0 failed, ${n_cases} skipped"
  exit 0
fi

echo "OK:   판별기 생존 확인 — $NOTIFIER (「x」 accept, 「[x」 refuse)"

passed=0
failures=0

swallowed() {
  "$NOTIFIER" -list "$1" >/dev/null 2>&1
  [ "$?" != "0" ]
}

expect_swallowed() {
  if swallowed "$1"; then
    passed=$((passed + 1))
    echo "PASS: 「$1」 는 삼켜진다 (기대대로)"
  else
    failures=$((failures + 1))
    echo "FAIL: 「$1」 가 통과했다 — 삼킴 문자 집합이 여섯이 아니게 됐다" >&2
  fi
}

expect_passes() {
  if swallowed "$1"; then
    failures=$((failures + 1))
    echo "FAIL: 「$1」 가 삼켜졌다 — 통과해야 하는 값이다" >&2
  else
    passed=$((passed + 1))
    echo "PASS: 「$1」 는 통과한다 (기대대로)"
  fi
}

# The six, and the five of them a leading space does not save.
#
# TWO MECHANISMS, NOT ONE, and a leading space tells them apart. Five are
# swallowed by the value parser, which strips whitespace before judging — so a
# leading space is no shield there. `-` is swallowed for the other reason: the
# word looks like an option, and a space in front stops it being a word at all.
#
# Measured rather than assumed: the emitter strips leading whitespace before it
# decides anything, so the distinction never reaches the fire path — but the
# static lint judges source literals that have NOT been stripped, and there the
# difference is the line between a real violation and a false positive.
for t in "${SWALLOWED[@]}"; do
  expect_swallowed "$t"
done

# Closing brackets and ordinary punctuation pass, a space saves the dash, and the
# strings this system actually ships must survive. A rule that held for synthetic
# probes and failed for the real titles would be a green suite and a blank screen.
for t in "${PASSING[@]}"; do
  expect_passes "$t"
done

echo "test-notify-title-oracle: $passed passed, $failures failed, 0 skipped"

if [ "$failures" != "0" ]; then
  exit 1
fi
exit 0
