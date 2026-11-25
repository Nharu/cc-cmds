#!/usr/bin/env bash
# Fixture: the retired load marker, at the end of a judgement line and alone on
# the comment line above a backslash-ended one; the elapsed-time hit it used to
# excuse in test-gate.sh fails as it does in any other file.
t0=$(date +%s)
t1=$(date +%s)
check "quick" "$([ $((t1 - t0)) -le 1 ] && echo y)" y # gate-load: 부하 아래에서 늦어진다
# gate-load: 부하 아래에서 늦어진다
check "slow" \
  "$(echo y)" y
