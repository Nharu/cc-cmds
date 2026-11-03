#!/usr/bin/env bash
# Verify: a fire-now command with leading newlines, spaces and tabs gets its
# prefixes in front of the stripped command, so the assignment reaches the
# dispatcher instead of becoming an assignment-only statement on its own line.
set -euo pipefail

stripped='bash /abs/active-notify/scripts/notify.sh fire-now "build" "done"'
c=$'\n  \t'"$stripped"
sid="test-leading-ws"

stdin_json=$(jq -nc --arg c "$c" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

name=$(ls -A "$PRETOOL_SEAT_DIR")
[[ "$name" =~ ^[0-9a-f]{32}$ ]] || { echo "FAIL: expected one ticket, got: $name" >&2; exit 1; }

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
if [[ "${CC_CMDS_NOTIFY_INJECT_SID:-0}" == "1" ]]; then
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${name} CLAUDE_CODE_SESSION_ID=${sid} ${stripped}"
else
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${name} ${stripped}"
fi
[[ "$updated" == "$want" ]] || { echo "FAIL: command" >&2; echo "  want: $want" >&2; echo "  got:  $updated" >&2; exit 1; }

exit 0
