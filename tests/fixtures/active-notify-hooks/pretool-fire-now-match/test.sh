#!/usr/bin/env bash
# Verify: PreToolUse hook matches notify.sh fire-now Bash commands, allows the
# call without applyPermissionRules, and rewrites the command with the seat
# prefix (α-path) or the seat prefix followed by the session-id prefix
# (γ-path). Positive regression for v2 fire-now subcommand.
set -euo pipefail

fire_now_cmd='bash /abs/active-notify/scripts/notify.sh fire-now "build" "성공"'
session_id="test-pretool-fire-now"

stdin_json=$(jq -nc \
  --arg c "$fire_now_cmd" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: expected permissionDecision=allow, got: $decision" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
  echo "FAIL: applyPermissionRules present on the dispatcher branch" >&2
  exit 1
fi

# Exactly one ticket was issued; its name is the seat prefix's value.
tickets=$(ls -A "$PRETOOL_SEAT_DIR" 2>/dev/null || true)
if [[ $(printf '%s\n' "$tickets" | grep -c .) -ne 1 ]] || [[ ! "$tickets" =~ ^[0-9a-f]{32}$ ]]; then
  echo "FAIL: expected exactly one seat ticket, got: $tickets" >&2
  exit 1
fi
seat_prefix="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${tickets} "

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" == "1" ]]; then
  expected="${seat_prefix}CLAUDE_CODE_SESSION_ID=${session_id} ${fire_now_cmd}"
else
  expected="${seat_prefix}${fire_now_cmd}"
fi
if [[ "$updated" != "$expected" ]]; then
  echo "FAIL: updatedInput.command does not match" >&2
  echo "  expected: $expected" >&2
  echo "  got:      $updated" >&2
  exit 1
fi

exit 0
