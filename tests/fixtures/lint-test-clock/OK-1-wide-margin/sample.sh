#!/usr/bin/env bash
# Fixture: arithmetic over an anchor that the margin rule must leave alone — a
# margin of 60 or more, a constant that is an operand of `%`, `*` or `/`, a
# positional parameter, and a difference that is compared from below.
w_now=$(date -u +%s)
w_stall=600
t0=$(date +%s)
t1=$(date +%s)
check "깨어남이 그보다 이르면 구성원이고 신선하지 않다" "$(w_fresh "$((w_now - w_stall - 100))")" "[1,false]"
hour=$(( (w_now / 3600) % 24 ))
day=$(( w_now / 86400 * 7 ))
ago=$((t0 - $2))
[ $((t1 - t0)) -ge 0 ] || echo "clock went back"
echo "$hour $day $ago $((w_now + 3600))"
