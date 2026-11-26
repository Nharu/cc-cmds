#!/usr/bin/env bash
# Fixture: polling loops that give up after a number of rounds, in each header
# form the rule reads, and one nested inside a loop of its own.
i=0
while [ "$i" -lt 100 ] && [ ! -f "$WORK/ready" ]; do sleep 0.1; i=$((i + 1)); done
for _ in $(seq 1 50); do
  [ -f "$WORK/ready" ] && break
  sleep 0.1
done
for n in {1..50}; do [ -s "$WORK/out.$n" ] && break; sleep 0.2; done
k=0
until (( k >= 30 )) || [ -f "$WORK/ready" ]; do
  sleep 1; k=$((k + 1))
done
for f in a b; do
  j=0
  while [ 20 -gt "$j" ]; do
    [ -f "$WORK/$f" ] && break
    sleep 0.1; j=$((j + 1))
  done
done
