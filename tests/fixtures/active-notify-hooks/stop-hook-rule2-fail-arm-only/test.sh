#!/usr/bin/env bash
# Verify: flag alive but only `notify.sh arm` Bash call (no other user-task) →
# helper-script exclusion regex makes work_calls=0 → Rule 2 fails → no fire.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-arm-only.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-arm-only","request_text":"끝나면 알림 줘","context_hint":"task","mode":"single","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was invoked despite ARM-only turn (Rule 2 should fail)" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# Flag should still be present (single-mode no-fire preserves flag for next turn)
if [[ ! -f "$flag_file" ]]; then
  echo "FAIL: flag was consumed without fire" >&2
  exit 1
fi

exit 0
