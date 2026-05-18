#!/usr/bin/env bash
# milestone empty (generic ARM) + marker emit + AskUserQuestion terminal.
# marker_bypass guard fails on first clause (milestone empty), so Rule 3
# silent-exit applies. No fire, no audit-log entry (generic ARM normal
# silent-exit is NOT audited per §3.3 unbounded-growth guard).
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-marker-with-askuser-no-milestone.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-marker-with-askuser-no-milestone","request_text":"빌드 끝나면 알려줘","context_hint":"build","mode":"single","milestone":"","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: Rule 3 should silent-exit (milestone empty → bypass not triggered)"
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# audit.log MUST NOT contain "Rule 3 bypass skipped" because milestone is empty
# (generic ARM normal silent-exit, audit-clean per §3.3).
if [[ -f "$FLAG_DIR/audit.log" ]] && grep -q 'Rule 3 bypass skipped' "$FLAG_DIR/audit.log"; then
  echo "FAIL: generic-ARM silent-exit should NOT write bypass-skip audit entry"
  cat "$FLAG_DIR/audit.log" >&2
  exit 1
fi

exit 0
