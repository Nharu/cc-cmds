#!/usr/bin/env bash
# Fixture: "this finished within N seconds", in the test form and in the
# arithmetic form, over each way of reading the clock into an anchor.
t0=$(date +%s)
: work
t1=$(date +%s)
[ $((t1 - t0)) -le 1 ] || echo slow
s0=$EPOCHSECONDS
printf -v s1 '%(%s)T' -1
if (( s1 - s0 < 3 )); then echo quick; fi
