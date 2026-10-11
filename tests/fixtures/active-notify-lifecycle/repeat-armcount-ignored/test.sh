#!/usr/bin/env bash
# ARM(repeat, --count=3) + fire-now × 4 → 4 notifier lines, flag survives,
# arm_count:3 stored verbatim but dispatcher ignores the cap at runtime
# (storage shape mode-uniform, runtime semantics mode-asymmetric).
set -euo pipefail

bash "$NOTIFY_SH" arm "iter" "iter" "repeat" --count=3
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
grep -q '"schema":3' "$FLAG_FILE" || { echo "schema not 3" >&2; exit 1; }
grep -q '"mode":"repeat"' "$FLAG_FILE" || { echo "mode not repeat" >&2; exit 1; }
grep -q '"arm_count":3' "$FLAG_FILE" || { echo "arm_count:3 not stored verbatim" >&2; cat "$FLAG_FILE" >&2; exit 1; }
safe_sid="${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9_.-]/_}"
armed_at=$(grep -oE '"armed_at":[0-9]+' "$FLAG_FILE" | sed 's/.*://')

# Fire 4 times — exceeds arm_count=3 but repeat ignores the cap.
for i in 1 2 3 4; do
  bash "$NOTIFY_SH" fire-now "iter-$i" "step $i"
  [[ -f "$FLAG_FILE" ]] || { echo "FIRE $i: flag must survive in repeat mode" >&2; exit 1; }
  grep -q "\"fire_count\":$i" "$FLAG_FILE" || { echo "FIRE $i: fire_count != $i" >&2; cat "$FLAG_FILE" >&2; exit 1; }
done

# arm_count:3 unchanged in the flag (storage verbatim).
grep -q '"arm_count":3' "$FLAG_FILE" || { echo "arm_count was mutated" >&2; exit 1; }
grep -q '"fire_count":4' "$FLAG_FILE" || { echo "fire_count not 4 (cap should be ignored)" >&2; exit 1; }

lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "4" ]] || { echo "expected 4 notifier lines, got $lines" >&2; exit 1; }

# Repeat gives every fire its own group (intentional pile-up), numbered by the
# repeat fire_count — past the stored arm_count as well.
for n in 1 2 3 4; do
  want="-group cc-cmds-active-notify-${safe_sid}@${armed_at}.${n}"
  got=$(sed -n "${n}p" "$NOTIFIER_LOG")
  [[ "$got" == *"$want" || "$got" == *"$want "* ]] || {
    echo "fire $n: expected '$want'" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
done
