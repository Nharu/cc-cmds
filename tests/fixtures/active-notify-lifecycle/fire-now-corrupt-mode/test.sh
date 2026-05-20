#!/usr/bin/env bash
# Pre-baked schema:3 flag with mode field "REPEAT" (uppercase invalid) →
# fire-now → stderr 'cleared flag with invalid mode (REPEAT)' (extraction
# surfaces actual corrupt value) + flag rm + notifier NOT called.
# Mode-validity guard fail-closed regression.
set -euo pipefail

mkdir -p "$FLAG_DIR"
cat > "$FLAG_FILE" <<'EOF'
{"schema":3,"armed_at":1700000000,"session_id":"t","request_text":"x","context_hint":"x","mode":"REPEAT","arm_count":1,"fire_count":0,"last_fire_at":null}
EOF

err=$(bash "$NOTIFY_SH" fire-now "build" "ignored" 2>&1 1>/dev/null)
echo "$err" | grep -q 'invalid mode (REPEAT)' || { echo "stderr should surface corrupt mode value 'REPEAT'" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "invalid-mode flag should be removed" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called for invalid mode" >&2; exit 1; }
