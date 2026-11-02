#!/usr/bin/env bash
# Verify: when the hook rewrites the command, updatedInput carries the whole
# tool_input — description and timeout survive, only command changes.
set -euo pipefail

fire_cmd='bash /abs/active-notify/scripts/notify.sh fire-now "build" "done"'
sid="test-input-preserved"

stdin_json=$(jq -nc --arg c "$fire_cmd" --arg sid "$sid" \
  '{tool_input:{command:$c, description:"Send the completion notice", timeout:30000}, session_id:$sid}')
printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

desc=$(jq -r '.hookSpecificOutput.updatedInput.description // empty' "$HOOK_STDOUT")
timeout=$(jq -r '.hookSpecificOutput.updatedInput.timeout // empty' "$HOOK_STDOUT")
keys=$(jq -r '.hookSpecificOutput.updatedInput | keys | join(",")' "$HOOK_STDOUT")
[[ "$desc" == "Send the completion notice" ]] || { echo "FAIL: description lost: '$desc'" >&2; exit 1; }
[[ "$timeout" == "30000" ]] || { echo "FAIL: timeout lost: '$timeout'" >&2; exit 1; }
[[ "$keys" == "command,description,timeout" ]] || { echo "FAIL: updatedInput keys: $keys" >&2; exit 1; }

updated=$(jq -r '.hookSpecificOutput.updatedInput.command' "$HOOK_STDOUT")
[[ "$updated" == CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=*" ${fire_cmd}" ]] \
  || { echo "FAIL: command not rewritten: $updated" >&2; exit 1; }

exit 0
