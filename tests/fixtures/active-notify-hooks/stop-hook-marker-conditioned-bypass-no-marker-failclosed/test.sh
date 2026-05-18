#!/usr/bin/env bash
# milestone non-empty + marker absent + AskUserQuestion terminal → fail-
# closed: Stop hook silent-exits (wrong banner not produced). Audit log
# records "Rule 3 bypass skipped" for forensic anchor (§3.5 PROP-R4-1).
# Trust-direction: silent miss recoverable, wrong banner non-recoverable.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-bypass-no-marker-failclosed.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-bypass-no-marker-failclosed","request_text":"빌드 끝나면 알림","context_hint":"build","mode":"single","milestone":"빌드","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: fail-closed violation — banner fired despite marker absent"
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# audit.log MUST contain "Rule 3 bypass skipped" entry
audit_log="$FLAG_DIR/audit.log"
[[ -f "$audit_log" ]] || { echo "FAIL: audit.log not written"; exit 1; }
grep -q 'Rule 3 bypass skipped: milestone=빌드' "$audit_log" || {
  echo "FAIL: audit entry missing or wrong milestone"
  cat "$audit_log" >&2
  exit 1
}

exit 0
