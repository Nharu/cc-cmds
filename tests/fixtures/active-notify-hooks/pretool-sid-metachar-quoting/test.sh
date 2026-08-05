#!/usr/bin/env bash
# Verify: the γ-path shell-quotes the injected session id, so metacharacters in
# it cannot append a command to the rewritten line.
#
# This is the one path in the plugin that rewrites a command AND reports it as
# allowed, so an unquoted injection would hand the auto-approval meant for
# notify.sh to whatever the session id appended — while also dropping the
# notify.sh call the user was actually making.
set -euo pipefail

notify_cmd='bash /abs/active-notify/scripts/notify.sh cancel'
session_id='sid; touch /tmp/cc-cmds-should-never-exist'

stdin_json=$(jq -nc \
  --arg c "$notify_cmd" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: expected permissionDecision=allow, got: $decision" >&2
  exit 1
fi

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" != "1" ]]; then
  # α-path performs no rewrite, so there is nothing to quote.
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): updatedInput present (should only appear in γ-path)" >&2
    exit 1
  fi
  exit 0
fi

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
quoted_sid=$(jq -rn --arg s "$session_id" '$s | @sh')
expected="CLAUDE_CODE_SESSION_ID=${quoted_sid} ${notify_cmd}"

if [[ "$updated" != "$expected" ]]; then
  echo "FAIL (γ): session id was not shell-quoted" >&2
  echo "  expected: $expected" >&2
  echo "  got:      $updated" >&2
  exit 1
fi

# The user's command must still be the tail of the line, unsplit.
if [[ "$updated" != *"$notify_cmd" ]]; then
  echo "FAIL (γ): the notify.sh invocation is no longer the command being run" >&2
  echo "  got: $updated" >&2
  exit 1
fi

exit 0
