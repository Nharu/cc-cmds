#!/usr/bin/env bash
# ARM(repeat) → flag with mode=repeat, fire_count=0, last_fire_at=null.
set -euo pipefail

bash "$NOTIFY_SH" arm "repeat me" "iter" "repeat"
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
grep -q '"schema":2' "$FLAG_FILE" || { echo "schema not 2" >&2; exit 1; }
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "mode not repeat" >&2; exit 1; }
grep -q '"fire_count":0' "$FLAG_FILE" || { echo "fire_count not 0" >&2; exit 1; }
grep -q '"last_fire_at":null' "$FLAG_FILE" || { echo "last_fire_at not null" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "ARM should not call notifier" >&2; exit 1; }
