#!/usr/bin/env bash
# FIRE without ARM → silent no-op (notifier stub NOT called).
set -euo pipefail

bash "$NOTIFY_SH" fire "build" "should not fire"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-without-flag: flag should not exist" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "fire-without-flag: notifier should NOT have been called" >&2; exit 1; }
