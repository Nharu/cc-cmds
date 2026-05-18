#!/usr/bin/env bash
# Malformed marker (unterminated interior quote) → regex `[^"]*` boundary
# breaks parse; marker_summary becomes garbage / marker_workflow truncates
# wrongly. Hook MUST gracefully degrade. Acceptable: binary fallback OR
# marker workflow extracted up to first interior quote (still a non-Bash
# token). The forbidden outcome is the literal `summary="missing close`
# string surviving into the banner.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-marker-malformed-fallback.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-marker-malformed-fallback","request_text":"빌드 끝나면 알려줘","context_hint":"build","mode":"single","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ -s "$NOTIFIER_LOG" ]] || { echo "FAIL: notifier not invoked"; cat "$HOOK_STDERR" >&2; exit 1; }
# Attribute values missing quotes → workflow="[^"]*" regex matches nothing
# → marker_workflow/summary stay empty → binary fallback. Forbidden: any
# fragment of the marker text (unterminated/garbage/attribute keywords)
# surviving into the banner copy.
if grep -qE 'unterminated|garbage|attribute' "$NOTIFIER_LOG"; then
  echo "FAIL: malformed marker fragment leaked into banner copy"
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi
# Positive assertion: binary fallback active (workflow='npm', summary='성공').
grep -q -- '-title \[cc-cmds\] npm' "$NOTIFIER_LOG" || { echo "FAIL: workflow should be Bash fallback 'npm'"; cat "$NOTIFIER_LOG" >&2; exit 1; }
grep -q -- '-message 성공' "$NOTIFIER_LOG" || { echo "FAIL: summary should be binary fallback '성공'"; cat "$NOTIFIER_LOG" >&2; exit 1; }

exit 0
