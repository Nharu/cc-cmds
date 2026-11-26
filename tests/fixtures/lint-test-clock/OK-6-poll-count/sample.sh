#!/usr/bin/env bash
# Fixture: loops and waits the poll-count rule leaves alone — a wait on the
# shared ceiling, a condition poll with no count, a counted loop that does not
# sleep, a count whose bound is not a literal, and a lower bound on an elapsed
# value.
. "$repo_root/scripts/wait-fixture.sh"
ready() { [ -f "$WORK/ready" ]; }
wait_until ready
wait_pid_gone "$pid"
while [ ! -f "$WORK/ready" ]; do sleep 0.1; done
for i in $(seq 1 5); do echo "$i" >> "$WORK/list"; done
n=0
while [ "$n" -lt "$max" ]; do sleep 0.1; n=$((n + 1)); done
t0=$(date +%s)
wait_until ready
t1=$(date +%s)
[ $((t1 - t0)) -ge 2 ] || echo "returned before the hold"
