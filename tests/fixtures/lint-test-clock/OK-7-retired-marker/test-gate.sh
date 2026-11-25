#!/usr/bin/env bash
# Fixture: test-gate.sh with the load marker gone — what it excused is now a
# lower bound, or carries an escape comment with its reason, as in any other
# file.
t0=$(date +%s)
t1=$(date +%s)
check "held" "$([ $((t1 - t0)) -ge 2 ] && echo y)" y
check "fake clock" "$([ $((t1 - t0)) -le 1 ] && echo y)" y # lint-test-clock: disable=elapsed-bound both readings come from the injected clock
