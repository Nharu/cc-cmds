#!/usr/bin/env bash
# ARM(repeat) + fire-now × 1 → fire_count=1, last_fire_at integer,
# flag preserved, the fire in its own pile-up group
# `cc-cmds-active-notify-<sid>@<armed_at>.<fire_count>`.
set -euo pipefail

bash "$NOTIFY_SH" arm "iter" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
safe_sid="${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9_.-]/_}"
armed_at=$(grep -oE '"armed_at":[0-9]+' "$FLAG_FILE" | sed 's/.*://')

bash "$NOTIFY_SH" fire-now "iter" "step 완료"

[[ -f "$FLAG_FILE" ]] || { echo "FIRE: flag must be preserved in repeat mode" >&2; exit 1; }
grep -q '"fire_count":1' "$FLAG_FILE" || { echo "FIRE: fire_count not incremented to 1" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -qE '"last_fire_at":[0-9]+' "$FLAG_FILE" || { echo "FIRE: last_fire_at not integer" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "FIRE: mode mutated" >&2; exit 1; }
grep -q '"schema":3' "$FLAG_FILE" || { echo "FIRE: schema corrupted" >&2; exit 1; }

[[ -f "$NOTIFIER_LOG" ]] || { echo "FIRE: notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "FIRE: expected 1 notifier call, got $lines" >&2; exit 1; }
want="-group cc-cmds-active-notify-${safe_sid}@${armed_at}.1"
grep -qF -- "$want" "$NOTIFIER_LOG" || {
  echo "FIRE: repeat-mode fire must use its own pile-up group '$want'" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}
# Unbracketed for the same reason as the single-mode fixture: a leading bracket
# makes terminal-notifier drop the title and show the application name instead.
grep -q -- '-title cc-cmds iter' "$NOTIFIER_LOG" || { echo "FIRE: title missing" >&2; exit 1; }
# Fired outside tmux — the driver clears TMUX and TMUX_PANE — so the click
# value is the `:` fallback, and `-execute` is still there.
grep -q -- '-execute :' "$NOTIFIER_LOG" || { echo "FIRE: -execute ':' no-op missing" >&2; exit 1; }
