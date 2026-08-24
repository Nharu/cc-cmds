#!/usr/bin/env bash
# Fixture: the bash 3.2-compatible replacements for the four bash4 rows and
# for setsid. None of these may trip the denylist.
set -euo pipefail

# wait -n → poll recorded child pids with kill -0
child_pids=""
sleep 1 & child_pids="$child_pids $!"
sleep 2 & child_pids="$child_pids $!"
while :; do
  alive=0
  for p in $child_pids; do
    if kill -0 "$p" 2>/dev/null; then alive=1; fi
  done
  [[ "$alive" -eq 0 ]] && break
  sleep 1
done

# declare -A → parallel indexed arrays
state_keys=(S4 S5)
state_vals=(running pending)
echo "${state_keys[0]}=${state_vals[0]}"

# mapfile → while IFS= read -r into an indexed array
lines=()
while IFS= read -r line; do lines+=("$line"); done < /etc/hosts
echo "${#lines[@]}"

# ${var^^} → tr
stage=s4
echo "$stage" | tr '[:lower:]' '[:upper:]'

# setsid → nohup for survival, per-stage `set -m` for tree ownership
set -m
nohup ./driver.sh >/dev/null 2>&1 &
ps -o pgid= -p $! || true
