#!/usr/bin/env bash
# Pre-baked v1.5 schema:2 flag (with milestone field) → fire-now → stderr
# 'stale flag (schema=2;' + flag rm + notifier NOT called.
# Migration self-heal — existing v1.5 users with live ARM at upgrade time
# experience silent flag loss on first fire-now (documented in CHANGELOG).
set -euo pipefail

mkdir -p "$FLAG_DIR"
cat > "$FLAG_FILE" <<'EOF'
{"schema":2,"armed_at":1700000000,"session_id":"legacy","request_text":"v1 user","context_hint":"build","mode":"single","milestone":"","fire_count":0,"last_fire_at":null}
EOF

err=$(bash "$NOTIFY_SH" fire-now "build" "ignored" 2>&1 1>/dev/null)
echo "$err" | grep -q 'stale flag (schema=2;' || { echo "stderr hint missing 'stale flag (schema=2;'" >&2; printf '%s\n' "$err" >&2; exit 1; }
[[ ! -f "$FLAG_FILE" ]] || { echo "stale schema:2 flag should be removed" >&2; exit 1; }
[[ ! -f "$NOTIFIER_LOG" ]] || { echo "notifier should not be called for stale schema" >&2; exit 1; }
