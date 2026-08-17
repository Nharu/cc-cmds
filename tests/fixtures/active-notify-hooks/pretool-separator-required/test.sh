#!/usr/bin/env bash
# The separator between the dispatcher path and the subcommand is REQUIRED.
#
# Nothing else in this suite pins it. Loosening it to "zero or more" leaves every
# other fixture green while the hook starts approving other files in the
# dispatcher's directory — any name that begins with the tracked literal and
# continues into what the matcher reads as a subcommand. That is a live
# privilege escalation reached by a one-character edit.
set -euo pipefail

for run_on in "notify.shcancel" "notify.sharm" "notify.shfire-now"; do
  cmd="bash /abs/active-notify/scripts/${run_on}"
  jq -nc --arg c "$cmd" --arg sid "test-separator" \
    '{tool_input:{command:$c}, session_id:$sid}' \
    | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
  if [[ -s "$HOOK_STDOUT" ]]; then
    echo "FAIL: '$cmd' was approved — the separator is not required" >&2
    cat "$HOOK_STDOUT" >&2
    exit 1
  fi
done
