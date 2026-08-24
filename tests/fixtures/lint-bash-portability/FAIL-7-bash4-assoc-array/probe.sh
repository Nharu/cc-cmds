#!/usr/bin/env bash
# Fixture: associative arrays are bash 4+. bash 3.2 exits rc=2 on both the
# `declare -A` and the `local -A` spelling, so both are denylisted.
set -euo pipefail

declare -A stage_state
stage_state[S4]=running
echo "${stage_state[S4]}"
