#!/usr/bin/env bash
# Verify: when the model already wrote a seat assignment in front of the
# command (empty agent_id), the hook's own prefix comes first, exactly one
# ticket is issued, and its name is the hook prefix's value — the model's value
# names no live ticket.
set -euo pipefail

forged='CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=0123456789abcdef0123456789abcdef'
fire_cmd="${forged} bash /abs/active-notify/scripts/notify.sh fire-now \"build\" \"done\""
sid="test-seat-model"

stdin_json=$(jq -nc --arg c "$fire_cmd" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
  || { echo "FAIL: decision is not allow" >&2; exit 1; }

listing=$(ls -A "$PRETOOL_SEAT_DIR")
[[ "$listing" =~ ^[0-9a-f]{32}$ ]] || { echo "FAIL: expected exactly one ticket, got: $listing" >&2; exit 1; }
[[ "$listing" != "0123456789abcdef0123456789abcdef" ]] || { echo "FAIL: the model's value became a ticket" >&2; exit 1; }

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
if [[ "${CC_CMDS_NOTIFY_INJECT_SID:-0}" == "1" ]]; then
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${listing} CLAUDE_CODE_SESSION_ID=${sid} ${fire_cmd}"
else
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${listing} ${fire_cmd}"
fi
[[ "$updated" == "$want" ]] || { echo "FAIL: command" >&2; echo "  want: $want" >&2; echo "  got:  $updated" >&2; exit 1; }

exit 0
