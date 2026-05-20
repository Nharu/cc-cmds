#!/usr/bin/env bash
# ARM(single, --count=3) + fire-now × 3 → notifier 3 lines (no -group),
# flag consumed after final fire. Subsequent fire-now is silent no-op.
set -euo pipefail

bash "$NOTIFY_SH" arm "multi" "task" "single" --count=3
grep -q '"arm_count":3' "$FLAG_FILE" || { echo "arm_count not 3" >&2; exit 1; }

# First fire — intermediate (fire_count 0 → 1)
bash "$NOTIFY_SH" fire-now "task-1" "step 1"
[[ -f "$FLAG_FILE" ]] || { echo "FIRE1: flag should persist" >&2; exit 1; }
grep -q '"fire_count":1' "$FLAG_FILE" || { echo "FIRE1: fire_count not 1" >&2; cat "$FLAG_FILE" >&2; exit 1; }

# Second fire — intermediate (fire_count 1 → 2)
bash "$NOTIFY_SH" fire-now "task-2" "step 2"
[[ -f "$FLAG_FILE" ]] || { echo "FIRE2: flag should persist" >&2; exit 1; }
grep -q '"fire_count":2' "$FLAG_FILE" || { echo "FIRE2: fire_count not 2" >&2; cat "$FLAG_FILE" >&2; exit 1; }

# Third fire — final (fire_count 2 → 3, equals arm_count → mv -n consume)
bash "$NOTIFY_SH" fire-now "task-3" "step 3 완료"
[[ ! -f "$FLAG_FILE" ]] || { echo "FIRE3: flag should be consumed (final)" >&2; exit 1; }

lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "3" ]] || { echo "expected 3 notifier lines, got $lines" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
if grep -q -- '-group' "$NOTIFIER_LOG"; then
  echo "armCount>1 fires must NEVER use -group (each sub-event must persist)" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# Fourth call — flag absent → silent no-op (count does not grow)
bash "$NOTIFY_SH" fire-now "task-4" "overflow"
lines2=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines2" == "3" ]] || { echo "post-final fire-now should be silent no-op (got $lines2 lines)" >&2; exit 1; }
