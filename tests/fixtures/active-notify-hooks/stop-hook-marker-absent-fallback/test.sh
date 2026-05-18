#!/usr/bin/env bash
# Marker absent → v1.4.2 binary fallback (backward compat regression anchor).
# workflow = first non-cd token of last Bash ("npm"); summary = "성공" via is_error.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-marker-absent-fallback.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-marker-absent-fallback","request_text":"빌드 끝나면 알려줘","context_hint":"build","mode":"single","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ -s "$NOTIFIER_LOG" ]] || { echo "FAIL: notifier not invoked"; cat "$HOOK_STDERR" >&2; exit 1; }
grep -q -- '-title \[cc-cmds\] npm' "$NOTIFIER_LOG" || { echo "FAIL: workflow should be binary fallback 'npm'"; cat "$NOTIFIER_LOG" >&2; exit 1; }
grep -q -- '-message 성공' "$NOTIFIER_LOG" || { echo "FAIL: summary should be binary fallback '성공'"; cat "$NOTIFIER_LOG" >&2; exit 1; }

exit 0
