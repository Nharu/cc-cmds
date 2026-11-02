#!/usr/bin/env bash
# Verify: PreToolUse hook matches notify.sh ARM/CANCEL Bash commands and
# emits the appropriate JSON for α and γ paths.
#
# Both paths: permissionDecision=allow on every call, applyPermissionRules ABSENT.
# α-path (CC_CMDS_NOTIFY_INJECT_SID=0, default): no updatedInput (ARM takes no
#   seat prefix).
# γ-path (CC_CMDS_NOTIFY_INJECT_SID=1): updatedInput.command rewrite with the
#   sid prefix only — no seat prefix on ARM.
#
# Driver invokes this fixture once per env value (inject_sid loop).
set -euo pipefail

# request_text variant includes literal '"' to verify shell-safe handling
arm_cmd='bash /abs/active-notify/scripts/notify.sh arm "\"끝나면\" 알려줘" "build" single'
session_id="test-pretool-notify"

stdin_json=$(jq -nc \
  --arg c "$arm_cmd" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

# Both paths emit permissionDecision="allow"
decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: expected permissionDecision=allow, got: $decision" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" == "1" ]]; then
  # γ-path: updatedInput.command must start with CLAUDE_CODE_SESSION_ID prefix
  updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
  expected_prefix="CLAUDE_CODE_SESSION_ID=${session_id} "
  if [[ "$updated" != "${expected_prefix}${arm_cmd}" ]]; then
    echo "FAIL (γ): updatedInput.command does not match expected prefix" >&2
    echo "  expected: ${expected_prefix}${arm_cmd}" >&2
    echo "  got:      $updated" >&2
    exit 1
  fi
  # Reason must distinguish γ from α
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$HOOK_STDOUT")
  if [[ "$reason" != *"session-id injection"* ]]; then
    echo "FAIL (γ): permissionDecisionReason missing 'session-id injection'" >&2
    echo "  got: $reason" >&2
    exit 1
  fi
else
  # α-path: updatedInput must be ABSENT
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): updatedInput present (ARM takes no seat prefix)" >&2
    exit 1
  fi
fi

# Both paths: applyPermissionRules MUST be absent — the dispatcher branch
# allows per call, so the hook keeps running before every call.
if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
  echo "FAIL: applyPermissionRules present on the dispatcher branch" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

# ARM never issues a seat ticket.
if [[ -d "$PRETOOL_SEAT_DIR" ]] && [[ -n "$(ls -A "$PRETOOL_SEAT_DIR")" ]]; then
  echo "FAIL: ARM left a seat ticket" >&2
  ls -A "$PRETOOL_SEAT_DIR" >&2
  exit 1
fi

exit 0
