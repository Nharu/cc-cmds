#!/usr/bin/env bash
# Pre-baked schema:3 repeat flag with fire_count present-but-non-numeric →
# fire-now → stderr 'corrupt flag (fire_count/last_fire_at missing or
# malformed)' + flag rm + notifier NOT called. Repeat-mode field-shape
# guard regression.
set -euo pipefail

mkdir -p "$FLAG_DIR"
cat > "$FLAG_FILE" <<'EOF'
{"schema":3,"armed_at":1700000000,"session_id":"t","request_text":"x","context_hint":"x","mode":"repeat","arm_count":1,"fire_count":"abc","last_fire_at":null}
EOF

err=$(bash "$NOTIFY_SH" fire-now "build" "ignored" 2>&1 1>/dev/null)
echo "$err" | grep -q 'corrupt flag (fire_count/last_fire_at' || { echo "stderr hint missing 'corrupt flag (fire_count/last_fire_at ...'" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "corrupt flag should be removed" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called for corrupt flag" >&2; exit 1; }
