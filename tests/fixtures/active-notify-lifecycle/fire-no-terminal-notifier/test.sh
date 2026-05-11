#!/usr/bin/env bash
# ARM(single) + FIRE with terminal-notifier absent → stderr hint once, flag
# consumed (single-mode 1-shot intent), notifier stub NOT called.
set -euo pipefail

# Confirm test setup: terminal-notifier truly unavailable.
if command -v terminal-notifier >/dev/null 2>&1; then
  echo "fixture setup error: terminal-notifier still on PATH ($(command -v terminal-notifier))" >&2
  exit 1
fi

bash "$NOTIFY_SH" arm "build" "build"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

# First fire emits the missing-binary hint to stderr and creates the sentinel.
err=$(bash "$NOTIFY_SH" fire "build" "summary" 2>&1 1>/dev/null)
echo "$err" | grep -q 'install terminal-notifier' || { echo "first fire: missing-notifier hint not emitted" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ -f "$NOTIFIER_HINT" ]] || { echo "first fire: sentinel hint file not created" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "first fire: single-mode flag must be consumed even when notifier missing" >&2; exit 1; }

# Driver stub was prepended but env.sh overrides PATH so the stub directory is
# no longer on PATH; the notifier log must not exist.
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier stub should not have been called" >&2; exit 1; }

# Re-ARM and FIRE again — sentinel must suppress the hint (dedup).
bash "$NOTIFY_SH" arm "build2" "build2"
err2=$(bash "$NOTIFY_SH" fire "build2" "summary2" 2>&1 1>/dev/null)
if echo "$err2" | grep -q 'install terminal-notifier'; then
  echo "second fire: hint should be suppressed by sentinel" >&2
  exit 1
fi
[[ ! -f "$FLAG_FILE" ]] || { echo "second fire: flag must still be consumed" >&2; exit 1; }
