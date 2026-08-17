#!/usr/bin/env bash
# A concurrent reader never observes a partially written `arm` flag.
#
# This is the property `arm-fail-open-keeps-holders-lock` used to claim and could
# not measure: atomicity is a claim about the INTERVAL, and every assertion that
# runs after the call has returned is satisfied identically by an in-place
# rewrite. The only way to see it is to sample the file while the write is in
# flight, which is what this fixture does.
#
# The sampler is fork-free on purpose. `read -r line < file` is a builtin with a
# redirect, so the whole loop stays in one process; a `$(cat)`/`grep` sample
# costs 40-80x the width of the window and detects nothing at all. It takes no
# lock — it is racing the write, not serialising against it.
#
# Honest shape: this is a ONE-SIDED detector. A torn read proves non-atomicity;
# zero torn reads is evidence, not proof. The residual risk is therefore a false
# green on broken code and never a false red on correct code, which is the right
# asymmetry for regression detection — but it is also why this fixture must not
# be described as proving atomicity. Measured margin on the development host,
# 13 runs per side: broken code 3-15 torn reads per run, shipped code 0 every
# run, no overlap. Sample counts ran 11.5k-22k, so the floor asserted below is
# far under the observed rate and exists to catch a sampler that never ran
# rather than to bound the detection rate.
set -euo pipefail

ARM_CALLS=20

bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

stop_file="${TMPDIR}/sampler.stop"
torn_file="${TMPDIR}/sampler.out"

(
  torn=0; samples=0
  while [[ ! -f "$stop_file" ]]; do
    line=""
    read -r line < "$FLAG_FILE" || true
    samples=$(( samples + 1 ))
    case "$line" in
      *'"last_fire_at"'*) ;;
      *) torn=$(( torn + 1 )) ;;
    esac
  done
  printf '%s %s\n' "$torn" "$samples" > "$torn_file"
) 2>/dev/null &
sampler_pid=$!

for (( i = 0; i < ARM_CALLS; i++ )); do
  bash "$NOTIFY_SH" arm "커밋마다 알림" "refactor" "repeat"
done

touch "$stop_file"
wait "$sampler_pid" || true

[[ -f "$torn_file" ]] || { echo "sampler produced no result" >&2; exit 1; }
read -r torn samples < "$torn_file"

if (( samples < 500 )); then
  echo "sampler took only $samples samples across $ARM_CALLS arm calls — it is not sampling the write window" >&2
  exit 1
fi

if (( torn > 0 )); then
  echo "a concurrent reader saw $torn partial flag(s) in $samples samples — the arm write is not staged and renamed" >&2
  exit 1
fi
