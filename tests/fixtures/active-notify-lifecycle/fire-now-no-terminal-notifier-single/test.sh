#!/usr/bin/env bash
# ARM(single, count=1) + fire-now with terminal-notifier absent → stderr
# hint once, flag consumed (single armCount=1 final-fire 1-shot intent),
# notifier stub NOT called.
set -euo pipefail

if command -v terminal-notifier >/dev/null 2>&1; then
  echo "fixture setup error: terminal-notifier still on PATH ($(command -v terminal-notifier))" >&2
  exit 1
fi

bash "$NOTIFY_SH" arm "build" "build"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

# First fire — emits missing-binary hint + creates sentinel + consumes flag.
err=$(bash "$NOTIFY_SH" fire-now "build" "summary" 2>&1 1>/dev/null)
echo "$err" | grep -q 'install terminal-notifier' || { echo "first fire: missing-notifier hint not emitted" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ -f "$NOTIFIER_HINT" ]] || { echo "first fire: sentinel hint file not created" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "first fire: single armCount=1 final-fire flag must be consumed even when notifier missing" >&2; exit 1; }

[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier stub should not have been called" >&2; exit 1; }

# Re-ARM and fire again — sentinel must suppress the hint (dedup).
bash "$NOTIFY_SH" arm "build2" "build2"
err2=$(bash "$NOTIFY_SH" fire-now "build2" "summary2" 2>&1 1>/dev/null)
if echo "$err2" | grep -q 'install terminal-notifier'; then
  echo "second fire: hint should be suppressed by sentinel" >&2
  exit 1
fi
[[ ! -f "$FLAG_FILE" ]] || { echo "second fire: flag must still be consumed" >&2; exit 1; }
