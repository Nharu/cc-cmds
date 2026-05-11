#!/usr/bin/env bash
# ARM(single) + FIRE → notifier stub fired (1 line in log), flag deleted.
set -euo pipefail

bash "$NOTIFY_SH" arm "build done" "build"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" fire "build" "성공 (exit 0)"

[[ ! -f "$FLAG_FILE" ]] || { echo "FIRE: flag should be consumed" >&2; exit 1; }
[[ -f "$NOTIFIER_LOG" ]] || { echo "FIRE: notifier was not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "FIRE: expected 1 notifier call, got $lines" >&2; exit 1; }
grep -q -- '-group cc-cmds-active-notify' "$NOTIFIER_LOG" || { echo "FIRE: single-mode should use -group" >&2; exit 1; }
grep -q -- '-title \[cc-cmds\] build' "$NOTIFIER_LOG" || { echo "FIRE: title missing" >&2; exit 1; }
grep -q -- '-message 성공 (exit 0)' "$NOTIFIER_LOG" || { echo "FIRE: summary missing" >&2; exit 1; }
