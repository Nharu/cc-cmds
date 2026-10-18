#!/usr/bin/env bash
# Fixture: a fixture that injects the time has no race against the clock, and a
# disable comment with a reason takes the hit — at the end of the line or on
# the comment-only line right above it.
NOW=$(date -u +%s)
run_case --now "$NOW" --boot-epoch "$((NOW - 10))" # lint-test-clock: disable=clock-margin the time is injected
# lint-test-clock: disable=elapsed-bound both readings are injected into the fake clock
[ $((NOW - NOW_START)) -le 1 ] || echo slow
NOW_START=$EPOCHSECONDS
