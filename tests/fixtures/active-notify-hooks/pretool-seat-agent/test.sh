#!/usr/bin/env bash
# Verify: a fire-now call carrying an agent_id (a spawned agent) gets an empty
# seat prefix and no ticket, and is still allowed.
set -euo pipefail

fire_cmd='bash /abs/active-notify/scripts/notify.sh fire-now "build" "done"'
sid="test-seat-agent"

stdin_json=$(jq -nc --arg c "$fire_cmd" --arg sid "$sid" \
  '{tool_input:{command:$c}, session_id:$sid, agent_id:"agent-7"}')
printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

[[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
  || { echo "FAIL: decision is not allow" >&2; exit 1; }
if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
  echo "FAIL: applyPermissionRules present" >&2; exit 1
fi

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
if [[ "${CC_CMDS_NOTIFY_INJECT_SID:-0}" == "1" ]]; then
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET= CLAUDE_CODE_SESSION_ID=${sid} ${fire_cmd}"
else
  want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET= ${fire_cmd}"
fi
[[ "$updated" == "$want" ]] || { echo "FAIL: command" >&2; echo "  want: $want" >&2; echo "  got:  $updated" >&2; exit 1; }

if [[ -d "$PRETOOL_SEAT_DIR" ]] && [[ -n "$(ls -A "$PRETOOL_SEAT_DIR")" ]]; then
  echo "FAIL: a ticket was issued for an agent call" >&2; ls -A "$PRETOOL_SEAT_DIR" >&2; exit 1
fi

exit 0
