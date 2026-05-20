#!/usr/bin/env bash
# ARM(repeat) + fire-now × 3 → fire_count progresses 0→1→2→3, last_fire_at
# integer after first fire, flag preserved at every step.
set -euo pipefail

bash "$NOTIFY_SH" arm "iter" "iter" "repeat"

for i in 1 2 3; do
  bash "$NOTIFY_SH" fire-now "iter-$i" "step $i 완료"
  [[ -f "$FLAG_FILE" ]] || { echo "FIRE $i: flag must be preserved" >&2; exit 1; }
  grep -q "\"fire_count\":$i" "$FLAG_FILE" || { echo "FIRE $i: fire_count expected $i" >&2; cat "$FLAG_FILE" >&2; exit 1; }
  grep -qE '"last_fire_at":[0-9]+' "$FLAG_FILE" || { echo "FIRE $i: last_fire_at not integer" >&2; cat "$FLAG_FILE" >&2; exit 1; }
  grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "FIRE $i: mode corrupted" >&2; exit 1; }
  grep -q '"schema":3' "$FLAG_FILE" || { echo "FIRE $i: schema corrupted" >&2; exit 1; }
  grep -q '"request_text":"iter"' "$FLAG_FILE" || { echo "FIRE $i: request_text corrupted" >&2; exit 1; }
done

lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "3" ]] || { echo "expected 3 notifier calls, got $lines" >&2; exit 1; }
