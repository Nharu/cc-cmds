#!/usr/bin/env bash
# ARM(repeat) + fire-now with terminal-notifier absent → stderr hint once +
# flag PRESERVED (asymmetric with single — repeat preserves for next-turn
# retry once the binary is installed).
set -euo pipefail

if command -v terminal-notifier >/dev/null 2>&1; then
  echo "fixture setup error: terminal-notifier still on PATH" >&2
  exit 1
fi

bash "$NOTIFY_SH" arm "iter" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
flag_before=$(cat "$FLAG_FILE")

err=$(bash "$NOTIFY_SH" fire-now "iter" "ping" 2>&1 1>/dev/null)
echo "$err" | grep -q 'install terminal-notifier' || { echo "missing-notifier hint not emitted" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ -f "$NOTIFIER_HINT" ]] || { echo "sentinel hint file not created" >&2; exit 1; }
[[ -f "$FLAG_FILE" ]] || { echo "repeat-mode flag must be preserved when notifier missing" >&2; exit 1; }

# Flag content unchanged (no fire_count increment because notifier never ran).
flag_after=$(cat "$FLAG_FILE")
[[ "$flag_before" == "$flag_after" ]] || { echo "repeat-mode flag content changed during failed fire" >&2; diff <(echo "$flag_before") <(echo "$flag_after") >&2; exit 1; }

[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not have been called" >&2; exit 1; }
