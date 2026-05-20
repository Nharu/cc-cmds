#!/usr/bin/env bash
# ARM(single, --count=2) + fire-now × 2 (consume) + fire-now × 3 (silent no-op).
# Audit.log dormancy regression anchor — fire-now must NEVER write audit entries
# in v2 (milestone gate cascade removal).
set -euo pipefail

bash "$NOTIFY_SH" arm "x" "x" "single" --count=2

bash "$NOTIFY_SH" fire-now "x" "1"
bash "$NOTIFY_SH" fire-now "x" "2"

[[ ! -f "$FLAG_FILE" ]] || { echo "flag should be consumed after 2/2" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "2" ]] || { echo "expected 2 notifier lines, got $lines" >&2; exit 1; }

# Post-overflow fires are silent no-ops
bash "$NOTIFY_SH" fire-now "x" "3"
bash "$NOTIFY_SH" fire-now "x" "4"
bash "$NOTIFY_SH" fire-now "x" "5"

lines2=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines2" == "2" ]] || { echo "post-overflow fires should not increase notifier count (got $lines2)" >&2; exit 1; }

# §3.4 audit.log dormancy regression anchor — fire-now writes nothing.
if [[ -f "$FLAG_DIR/audit.log" ]]; then
  size=$(wc -c < "$FLAG_DIR/audit.log" | tr -d ' ')
  [[ "$size" == "0" ]] || {
    echo "FAIL: audit.log non-empty (fire-now must not write audit entries in v2)" >&2
    cat "$FLAG_DIR/audit.log" >&2
    exit 1
  }
fi
