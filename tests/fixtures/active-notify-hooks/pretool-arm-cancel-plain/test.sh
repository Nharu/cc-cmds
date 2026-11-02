#!/usr/bin/env bash
# Verify: ARM and CANCEL never take a seat prefix or a ticket. α-path: no
# updatedInput and no permission rule. γ-path: the session-id prefix only.
set -euo pipefail

sid="test-arm-cancel"
for c in \
  'bash /abs/active-notify/scripts/notify.sh arm "끝나면 알려줘" "build" single' \
  'bash /abs/active-notify/scripts/notify.sh cancel'; do
  stdin_json=$(jq -nc --arg c "$c" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
  printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
    || { echo "FAIL ($c): decision is not allow" >&2; exit 1; }
  if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL ($c): applyPermissionRules present" >&2; exit 1
  fi
  if [[ "${CC_CMDS_NOTIFY_INJECT_SID:-0}" == "1" ]]; then
    updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
    [[ "$updated" == "CLAUDE_CODE_SESSION_ID=${sid} ${c}" ]] \
      || { echo "FAIL ($c): γ command: $updated" >&2; exit 1; }
  else
    if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
      echo "FAIL ($c): α updatedInput present" >&2; exit 1
    fi
  fi
  if [[ -d "$PRETOOL_SEAT_DIR" ]] && [[ -n "$(ls -A "$PRETOOL_SEAT_DIR")" ]]; then
    echo "FAIL ($c): a ticket was issued" >&2; exit 1
  fi
done

exit 0
