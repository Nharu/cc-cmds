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
  # The hook shell-quotes the injected value with @sh; derive the expected
  # form the same way rather than hardcoding it.
  quoted_sid=$(jq -rn --arg s "$session_id" '$s | @sh')
  expected_prefix="CLAUDE_CODE_SESSION_ID=${quoted_sid} "
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
  # α-path: the notify leg emits no applyPermissionRules — the allow covers this
  # call only (see pretool-notify-match for the full reason).
  if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): the notify leg must emit no applyPermissionRules" >&2
    cat "$HOOK_STDOUT" >&2
    exit 1
  fi
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): updatedInput present (should only appear in γ-path)" >&2
    exit 1
  fi
fi

exit 0
