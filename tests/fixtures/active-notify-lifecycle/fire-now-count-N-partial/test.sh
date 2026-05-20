#!/usr/bin/env bash
# ARM(single, --count=2) + fire-now × 1 → notifier 1 line, flag preserved
# with fire_count=1, no -group on intermediate fire.
set -euo pipefail

bash "$NOTIFY_SH" arm "two-step" "task" "single" --count=2
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
grep -q '"arm_count":2' "$FLAG_FILE" || { echo "arm_count not 2" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "fire_count not 0" >&2; exit 1; }

bash "$NOTIFY_SH" fire-now "task" "step 1 시작"

[[ -f "$FLAG_FILE" ]] || { echo "fire-now: flag should be preserved (intermediate)" >&2; exit 1; }
grep -q '"fire_count":1' "$FLAG_FILE" || { echo "fire_count not 1" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -qE '"last_fire_at":[0-9]+' "$FLAG_FILE" || { echo "last_fire_at not integer" >&2; exit 1; }
grep -q '"arm_count":2' "$FLAG_FILE" || { echo "arm_count corrupted" >&2; exit 1; }
grep -q '"mode":"single"' "$FLAG_FILE" || { echo "mode corrupted" >&2; exit 1; }

[[ -f "$NOTIFIER_LOG" ]] || { echo "notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "expected 1 notifier call, got $lines" >&2; exit 1; }
if grep -q -- '-group' "$NOTIFIER_LOG"; then
  echo "intermediate fire (armCount>1) must NOT use -group" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi
