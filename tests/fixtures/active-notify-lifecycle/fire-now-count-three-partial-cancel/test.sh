#!/usr/bin/env bash
# ARM(single, --count=3) + fire-now × 2 → CANCEL → 3 subsequent fire-now
# all silent no-op (flag absent). Mid-cycle cancel preserves notifier count.
set -euo pipefail

bash "$NOTIFY_SH" arm "task" "task" "single" --count=3

bash "$NOTIFY_SH" fire-now "task" "step 1"
bash "$NOTIFY_SH" fire-now "task" "step 2"

[[ -f "$FLAG_FILE" ]] || { echo "flag should persist after 2/3" >&2; exit 1; }
grep -q '"fire_count":2' "$FLAG_FILE" || { echo "fire_count not 2" >&2; cat "$FLAG_FILE" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "2" ]] || { echo "expected 2 notifier lines after 2 fires, got $lines" >&2; exit 1; }

# CANCEL mid-cycle
bash "$NOTIFY_SH" cancel
[[ ! -f "$FLAG_FILE" ]] || { echo "CANCEL did not remove flag" >&2; exit 1; }

# Subsequent fire-now calls are silent no-ops (flag absent)
bash "$NOTIFY_SH" fire-now "task" "step 3"
bash "$NOTIFY_SH" fire-now "task" "step 4"
bash "$NOTIFY_SH" fire-now "task" "step 5"

lines2=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines2" == "2" ]] || { echo "post-cancel fires should be silent (got $lines2)" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
