#!/usr/bin/env bash
# Fixture: background processes the stub-lifetime rule leaves alone — a holder
# tied to the test shell, a dead pid made without a sleep, a writer that sleeps
# in the foreground inside a background subshell the test kills, a foreground
# sleep, a duration that is not a literal, and the words inside a string.
. "$repo_root/scripts/wait-fixture.sh"
wait_holder & pid=$!
FX_PIDS="$FX_PIDS $pid"
true & dead=$!
wait "$dead"
( echo a >> "$WORK/log"; sleep 1; echo b >> "$WORK/log" ) & writer=$!
kill "$writer"
sleep 0.1
sleep 1 && echo after
sleep "$delay" &
echo "sleep 5 &"
