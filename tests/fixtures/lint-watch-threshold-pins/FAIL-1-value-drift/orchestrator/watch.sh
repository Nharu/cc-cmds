#!/usr/bin/env bash
# Fixture watcher whose stall default has moved. The document below still states
# the old number, and nothing about the disagreement is visible at a glance.
RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1800; ONCE=0; AFTER_STAGE=120; RUN_OPEN=300
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --after-stage) AFTER_STAGE="$2"; shift 2 ;;
    --run-open) RUN_OPEN="$2"; shift 2 ;;
    *) shift ;;
  esac
done
