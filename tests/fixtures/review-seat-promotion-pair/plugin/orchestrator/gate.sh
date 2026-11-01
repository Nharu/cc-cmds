#!/usr/bin/env bash
# Fixture gate: the two values a review stage's launch reads.

gate_autocompact_argv_value() {
  case "$1" in
    review) printf '300000' ;;
    *) printf '200000' ;;
  esac
}

gate_stage_launch() {
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CC_ORCH_BG_WAIT_CEILING_MS:-14400000}"
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
}
