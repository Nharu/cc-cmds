#!/usr/bin/env bash
# ARM(single) + CANCEL + fire-now → silent no-op (CANCEL removes flag;
# fire-now ARM-existence guard exits 0). Re-validates flag-absent path
# after deliberate cancellation.
set -euo pipefail

bash "$NOTIFY_SH" arm "build" "build" "single"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }

bash "$NOTIFY_SH" cancel
[[ ! -f "$FLAG_FILE" ]] || { echo "CANCEL: flag should be deleted" >&2; exit 1; }

bash "$NOTIFY_SH" fire-now "build" "post-cancel"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-now after cancel should not recreate flag" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called after cancel" >&2; exit 1; }
