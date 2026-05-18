#!/usr/bin/env bash
# BashOutput-only turn — BashOutput is NOT in the 11-tool whitelist, so
# work_calls=0 (ARM Bash call is excluded by helper regex). milestone non-
# empty + marker emitted + non-repeat → Rule 2 + Rule 3 BOTH bypass and
# fire with marker copy. Verifies §3.5 PROP-R2-3 parallel bypass.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-rule2-bypass-bashoutput-only.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-rule2-bypass-bashoutput-only","request_text":"빌드 끝나면 알림","context_hint":"build","mode":"single","milestone":"빌드","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ -s "$NOTIFIER_LOG" ]] || {
  echo "FAIL: Rule 2 + Rule 3 parallel bypass should fire (work_calls=0 but marker present)"
  cat "$HOOK_STDERR" >&2
  exit 1
}

grep -q -- '-title \[cc-cmds\] 빌드' "$NOTIFIER_LOG" || { echo "FAIL: workflow should be marker '빌드'"; cat "$NOTIFIER_LOG" >&2; exit 1; }
grep -q -- '-message 빌드 실패: E0308 type mismatch' "$NOTIFIER_LOG" || { echo "FAIL: summary should be marker copy"; cat "$NOTIFIER_LOG" >&2; exit 1; }

# Marker present → no bypass-skip audit entry
if [[ -f "$FLAG_DIR/audit.log" ]] && grep -q 'bypass skipped' "$FLAG_DIR/audit.log"; then
  echo "FAIL: audit.log should be clean when bypass triggers"
  cat "$FLAG_DIR/audit.log" >&2
  exit 1
fi

exit 0
