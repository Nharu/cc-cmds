#!/usr/bin/env bash
# Pre-baked schema:1 flag → FIRE → stderr 'stale flag (schema=1)' + flag rm +
# notifier NOT called (schema strict-equality regression guard).
set -euo pipefail

mkdir -p "$FLAG_DIR"
cat > "$FLAG_FILE" <<'EOF'
{"schema":1,"armed_at":1700000000,"session_id":"legacy","request_text":"old","context_hint":"old"}
EOF

err=$(bash "$NOTIFY_SH" fire "build" "ignored" 2>&1 1>/dev/null)
echo "$err" | grep -q 'stale flag (schema=1)' || { echo "stderr hint missing 'stale flag (schema=1)'" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "stale flag should be removed" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called for stale schema" >&2; exit 1; }
