#!/usr/bin/env bash
# Pre-baked schema:2 repeat flag with fire_count present-but-non-numeric →
# FIRE → stderr 'corrupt flag' + flag rm + notifier NOT called.
# Field-shape guard (strict [0-9]+ quantifier) regression guard.
set -euo pipefail

mkdir -p "$FLAG_DIR"
# fire_count is the string "abc" instead of a number — must trigger the
# field-shape guard, not silently pass through the numeric sed update.
cat > "$FLAG_FILE" <<'EOF'
{"schema":2,"armed_at":1700000000,"session_id":"t","request_text":"x","context_hint":"x","mode":"repeat","fire_count":"abc","last_fire_at":null}
EOF

err=$(bash "$NOTIFY_SH" fire "build" "ignored" 2>&1 1>/dev/null)
echo "$err" | grep -q 'corrupt flag' || { echo "stderr hint missing 'corrupt flag'" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "corrupt flag should be removed" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called for corrupt flag" >&2; exit 1; }
