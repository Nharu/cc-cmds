#!/usr/bin/env bash
# Verify: PreToolUse hook matches notify.sh fire-now Bash commands and
# emits permissionDecision=allow + applyPermissionRules (α-path) or
# updatedInput rewrite (γ-path). Positive regression for v2 fire-now subcommand.
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

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" == "1" ]]; then
  updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
  expected_prefix="CLAUDE_CODE_SESSION_ID=${session_id} "
  if [[ "$updated" != "${expected_prefix}${fire_now_cmd}" ]]; then
    echo "FAIL (γ): updatedInput.command does not match expected prefix" >&2
    echo "  expected: ${expected_prefix}${fire_now_cmd}" >&2
    echo "  got:      $updated" >&2
    exit 1
  fi
  if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (γ): applyPermissionRules present (would defeat session-id injection)" >&2
    exit 1
  fi
else
  rules=$(jq -r '.hookSpecificOutput.applyPermissionRules // empty | if type == "array" then join("|") else . end' "$HOOK_STDOUT")
  if [[ "$rules" != *"notify.sh"* ]]; then
    echo "FAIL (α): applyPermissionRules missing notify.sh pattern" >&2
    echo "  got: $rules" >&2
    exit 1
  fi
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): updatedInput present (should only appear in γ-path)" >&2
    exit 1
  fi
fi

exit 0
