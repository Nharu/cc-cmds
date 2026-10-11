#!/usr/bin/env bash
# ARM(single, --count=2) + fire-now × 1 → notifier 1 line, flag preserved
# with fire_count=1, intermediate fire in its own pile-up group
# `cc-cmds-active-notify-<sid>@<armed_at>.1`.
set -euo pipefail

bash "$NOTIFY_SH" arm "two-step" "task" "single" --count=2
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
safe_sid="${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9_.-]/_}"
armed_at=$(grep -oE '"armed_at":[0-9]+' "$FLAG_FILE" | sed 's/.*://')
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
want="-group cc-cmds-active-notify-${safe_sid}@${armed_at}.1"
grep -qF -- "$want" "$NOTIFIER_LOG" || {
  echo "intermediate fire (armCount>1) must use its own group '$want'" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}
