#!/usr/bin/env bash
# ARM(single) + CANCEL → flag absent; second CANCEL idempotent (no error).
set -euo pipefail

bash "$NOTIFY_SH" arm "build done" "build"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" cancel
[[ ! -f "$FLAG_FILE" ]] || { echo "CANCEL: flag should be deleted" >&2; exit 1; }

# Second CANCEL with no flag present must be silent + exit 0.
bash "$NOTIFY_SH" cancel
[[ ! -f "$FLAG_FILE" ]] || { echo "CANCEL (2nd): flag reappeared" >&2; exit 1; }

[[ ! -f "$NOTIFIER_LOG" ]] || { echo "CANCEL: notifier should not have been called" >&2; exit 1; }
