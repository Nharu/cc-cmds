#!/usr/bin/env bash
# fire-now without prior ARM → silent no-op (notifier stub NOT called,
# no flag created). ARM-existence guard regression.
set -euo pipefail

bash "$NOTIFY_SH" fire-now "build" "should not fire"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-now without flag should not create one" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should NOT have been called" >&2; exit 1; }
[[ ! -d "${FLAG_FILE}.lockdir" ]] || { echo "lockdir leak" >&2; exit 1; }
