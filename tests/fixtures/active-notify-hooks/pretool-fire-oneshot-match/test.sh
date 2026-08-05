#!/usr/bin/env bash
# Verify: PreToolUse hook matches notify.sh fire-oneshot Bash commands on both
# the α (applyPermissionRules) and γ (updatedInput rewrite) paths.
#
# Without the notify_re token this subcommand falls through to the Bash
# permission dialog, which strands every scheduler-delegated banner behind a
# prompt no one is present to answer — the exact silent failure the delegation
# exists to remove.
set -euo pipefail

oneshot_cmd='bash /abs/active-notify/scripts/notify.sh fire-oneshot "scheduled" "30분 경과"'
session_id="test-pretool-fire-oneshot"

stdin_json=$(jq -nc \
  --arg c "$oneshot_cmd" \
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
  if [[ "$updated" != "${expected_prefix}${oneshot_cmd}" ]]; then
    echo "FAIL (γ): updatedInput.command does not match expected prefix" >&2
    echo "  expected: ${expected_prefix}${oneshot_cmd}" >&2
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
