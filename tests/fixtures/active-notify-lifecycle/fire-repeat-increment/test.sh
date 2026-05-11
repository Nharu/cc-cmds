#!/usr/bin/env bash
# ARM(repeat) + FIRE → fire_count=1, last_fire_at set (integer), flag preserved,
# no -group flag in notifier invocation.
set -euo pipefail

bash "$NOTIFY_SH" arm "iter" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" fire "iter" "step 완료"

[[ -f "$FLAG_FILE" ]] || { echo "FIRE: flag must be preserved in repeat mode" >&2; exit 1; }
grep -q '"fire_count":1' "$FLAG_FILE" || { echo "FIRE: fire_count not incremented to 1" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -qE '"last_fire_at":[0-9]+' "$FLAG_FILE" || { echo "FIRE: last_fire_at not set to integer" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "FIRE: mode mutated" >&2; exit 1; }

[[ -f "$NOTIFIER_LOG" ]] || { echo "FIRE: notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "FIRE: expected 1 notifier call, got $lines" >&2; exit 1; }
if grep -q -- '-group' "$NOTIFIER_LOG"; then
  echo "FIRE: repeat-mode must NOT use -group (pile-up intentional)" >&2
  exit 1
fi
grep -q -- '-title \[cc-cmds\] iter' "$NOTIFIER_LOG" || { echo "FIRE: title missing" >&2; exit 1; }
