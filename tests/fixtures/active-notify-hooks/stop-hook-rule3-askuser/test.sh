#!/usr/bin/env bash
# Verify: flag alive + user-task Bash in turn + turn-terminal tool = AskUserQuestion →
# Rule 3 fails → no fire.
set -euo pipefail

flag_file="$FLAG_DIR/pending-test-askuser.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-askuser","request_text":"빌드 후 알려줘","context_hint":"build","mode":"single","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was invoked despite AskUserQuestion turn-terminal" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

if [[ ! -f "$flag_file" ]]; then
  echo "FAIL: flag was consumed without fire" >&2
  exit 1
fi

exit 0
