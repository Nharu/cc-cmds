#!/usr/bin/env bash
# ARM(repeat) + CANCEL → flag deleted regardless of mode (mode-agnostic).
set -euo pipefail

bash "$NOTIFY_SH" arm "repeat me" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" cancel
[[ ! -f "$FLAG_FILE" ]] || { echo "CANCEL: flag should be deleted" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "CANCEL: notifier should not be called" >&2; exit 1; }
