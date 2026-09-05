#!/usr/bin/env bash
# The third layer: measure the swallowing set against the REAL binary.
#
# The other two layers read our own source. The static lint checks the literals
# we write and the suites assert the argv we build, so if a tool upgrade changed
# WHICH characters are swallowed, both would stay green and both would be wrong
# — the set they encode is an assumption about somebody else's parser. This is
# the only thing in the tree that would notice.
#
# NO BANNER IS RAISED. The discriminator is the EXIT CODE of
# `terminal-notifier -list "<value>"`, which hands the value to the same argument
# parser the fire path uses and then prints a listing instead of posting a
# notice. A test that proved the rendering by rendering something would be
# putting notices on a person's screen every time the suite ran.
#
# THE STATUS IS READ DIRECTLY, NOT THROUGH A PIPE. Behind a pipe `$?` is the
# reader's status rather than the notifier's, which is how this measurement was
# first got wrong. Both streams are discarded because the usage text goes to
# stdout and stderr alike, so matching on prose depends on which one you happen
# to look at — the code does not.
#
# Skips on a non-Darwin host or with no binary installed, so the ubuntu leg stays
# green. The darwin target is the one place this actually runs, which is why the
# workflow's path filter has to name this file: a test nothing triggers has no
# discriminating power at all, and this tree has already shipped one of those.
#
# Usage: bash scripts/test-notify-title-oracle.sh

set -uo pipefail

if [ "$(uname -s 2>/dev/null || printf unknown)" != "Darwin" ]; then
  echo "SKIP: not a Darwin host — the oracle needs the real terminal-notifier"
  exit 0
fi
if ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "SKIP: terminal-notifier not installed"
  exit 0
fi

passed=0
failures=0

# Exit 0 means the parser accepted the value as its own argument; a non-zero
# status means the value was taken for something else and the argument vanished.
swallowed() {
  terminal-notifier -list "$1" >/dev/null 2>&1
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

# The six. If this set ever changes, the static lint and the argv assertions are
# both encoding the wrong rule and neither of them can tell.
for t in '[x' '(x' '{x' '<x' '"x' '-x'; do
  expect_swallowed "$t"
done

# TWO MECHANISMS, NOT ONE, and a leading space tells them apart. Five of the six
# are swallowed by the value parser, which strips whitespace before judging — so
# a leading space is no shield there. `-` is swallowed for the other reason: the
# word looks like an option. A space in front stops it being a word at all, so
# `- x` survives while ` [x` does not.
#
# Measured here rather than assumed: the emitter strips leading whitespace before
# it decides anything, so the distinction never reaches the fire path — but the
# static lint judges source literals that have NOT been stripped, and there the
# difference is the line between a real violation and a false positive.
for t in ' [x' ' (x' ' {x' ' <x' ' "x'; do
  expect_swallowed "$t"
done
expect_passes ' -x'

# Closing brackets and ordinary punctuation pass. Widening the rule to "no
# punctuation" would refuse text the tool renders perfectly well.
for t in ')x' ']x' '}x' '>x' "'x" '.x' '#x' '~x' '가x' '1x'; do
  expect_passes "$t"
done

# The strings this system actually ships. A rule that held for synthetic probes
# and failed for the real titles would be a green suite and a blank screen.
for t in '답 필요' '손 필요' '자율 런'; do
  expect_passes "$t"
done

echo "test-notify-title-oracle: $passed passed, $failures failed"

if [ "$failures" != "0" ]; then
  exit 1
fi
exit 0
