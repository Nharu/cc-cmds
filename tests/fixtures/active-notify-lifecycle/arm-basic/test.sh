#!/usr/bin/env bash
# 3-step composite: ARM(single) → ARM(repeat) mode-switch → ARM(repeat) idempotent.
set -euo pipefail

# Step 1: ARM(single).
bash "$NOTIFY_SH" arm "req-1" "ctx-1"
[[ -f "$FLAG_FILE" ]] || { echo "step1: flag not written" >&2; exit 1; }
grep -q '"schema":2' "$FLAG_FILE" || { echo "step1: schema not 2" >&2; exit 1; }
grep -q '"mode":"single"' "$FLAG_FILE" || { echo "step1: mode not single" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "step1: fire_count not 0" >&2; exit 1; }
grep -q '"last_fire_at":null' "$FLAG_FILE" || { echo "step1: last_fire_at not null" >&2; exit 1; }
grep -q '"request_text":"req-1"' "$FLAG_FILE" || { echo "step1: request_text missing" >&2; exit 1; }

# Step 2: ARM(repeat) — mode switch with new request_text/context.
bash "$NOTIFY_SH" arm "req-2" "ctx-2" "repeat"
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "step2: mode not switched to repeat" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "step2: fire_count not reset" >&2; exit 1; }
grep -q '"last_fire_at":null' "$FLAG_FILE" || { echo "step2: last_fire_at not reset" >&2; exit 1; }
grep -q '"request_text":"req-2"' "$FLAG_FILE" || { echo "step2: request_text not updated" >&2; exit 1; }
grep -qv '"request_text":"req-1"' "$FLAG_FILE" || { echo "step2: old request_text leaked" >&2; exit 1; }

# Step 3: ARM(repeat) again with different text — idempotent overwrite.
bash "$NOTIFY_SH" arm "req-3" "ctx-3" "repeat"
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "step3: mode not repeat" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "step3: fire_count not 0" >&2; exit 1; }
grep -q '"last_fire_at":null' "$FLAG_FILE" || { echo "step3: last_fire_at not null" >&2; exit 1; }
grep -q '"request_text":"req-3"' "$FLAG_FILE" || { echo "step3: request_text not updated" >&2; exit 1; }
grep -q '"context_hint":"ctx-3"' "$FLAG_FILE" || { echo "step3: context_hint not updated" >&2; exit 1; }

# No notifier calls during ARM.
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "arm: notifier should not have been called" >&2; exit 1; }
