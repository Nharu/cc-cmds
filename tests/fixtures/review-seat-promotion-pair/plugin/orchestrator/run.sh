#!/usr/bin/env bash
# Fixture driver: only the launch flags a review stage gets, read by the paired
# re-review runner when it is sourced with CC_ORCH_SOURCE_ONLY=1.

stage_launch_flags() {
  case "$1" in
    review) printf -- '--effort medium --model opus' ;;
    *) printf -- '--effort high --model opus' ;;
  esac
}

[ "${CC_ORCH_SOURCE_ONLY:-}" = "1" ] && return 0
echo "fixture driver: not runnable" >&2
exit 1
