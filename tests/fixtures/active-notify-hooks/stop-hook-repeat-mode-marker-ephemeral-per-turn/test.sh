#!/usr/bin/env bash
# Per-turn marker freshness — repeat-mode flag persists across turns but
# marker scrape is per-invocation (no caching). Turn 1 with marker → rich
# copy; turn 2 with no marker → binary fallback.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-repeat-marker-ephemeral.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-repeat-marker-ephemeral","request_text":"매 단계마다 알려줘","context_hint":"work","mode":"repeat","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

transcript_path=$(jq -r '.transcript_path' "$HOOK_INPUT")

# === Turn 1 — marker present ===
"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
line1=$(sed -n '1p' "$NOTIFIER_LOG")
[[ -n "$line1" ]] || { echo "FAIL: Turn 1 should fire"; cat "$HOOK_STDERR" >&2; exit 1; }
echo "$line1" | grep -q -- '-title \[cc-cmds\] 테스트' || { echo "FAIL: Turn 1 workflow should be marker '테스트', got: $line1"; exit 1; }
echo "$line1" | grep -q -- '-message 12 specs 모두 통과' || { echo "FAIL: Turn 1 summary should be marker copy, got: $line1"; exit 1; }

# === Turn 2 — append work without marker ===
cat >> "$transcript_path" <<'EOF'
{"type":"user","sessionId":"test-repeat-marker-ephemeral","message":{"role":"user","content":[{"type":"text","text":"다음"}]}}
{"type":"assistant","sessionId":"test-repeat-marker-ephemeral","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"npm run lint","description":"Lint"}}]}}
{"type":"user","sessionId":"test-repeat-marker-ephemeral","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b1","content":"0 issues","is_error":false}]}}
{"type":"assistant","sessionId":"test-repeat-marker-ephemeral","message":{"role":"assistant","content":[{"type":"text","text":"Lint passed (no marker)."}]}}
EOF

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
line2=$(sed -n '2p' "$NOTIFIER_LOG")
[[ -n "$line2" ]] || { echo "FAIL: Turn 2 should fire"; cat "$HOOK_STDERR" >&2; exit 1; }
echo "$line2" | grep -q -- '-title \[cc-cmds\] npm' || { echo "FAIL: Turn 2 workflow should be Bash fallback 'npm', got: $line2"; exit 1; }
echo "$line2" | grep -q -- '-message 성공' || { echo "FAIL: Turn 2 summary should be binary fallback '성공', got: $line2"; exit 1; }

exit 0
