#!/usr/bin/env bash
# ARM(request, ctx, "continuous") → flag JSON written with mode="single"
# (silent normalize-to-single regression guard). ARM-vs-fire policy asymmetry lock.
set -euo pipefail

bash "$NOTIFY_SH" arm "req" "ctx" "continuous"

[[ -f "$FLAG_FILE" ]] || { echo "ARM should still write the flag" >&2; exit 1; }
grep -q '"mode":"single"' "$FLAG_FILE" || { echo "invalid mode should normalize to single" >&2; cat "$FLAG_FILE" >&2; exit 1; }
grep -qv '"mode":"continuous"' "$FLAG_FILE" || { echo "raw invalid mode leaked into flag" >&2; exit 1; }
# Other fields written normally.
grep -q '"schema":2' "$FLAG_FILE" || { echo "schema not 2" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "fire_count not 0" >&2; exit 1; }
grep -q '"request_text":"req"' "$FLAG_FILE" || { echo "request_text missing" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "ARM should not call notifier" >&2; exit 1; }
