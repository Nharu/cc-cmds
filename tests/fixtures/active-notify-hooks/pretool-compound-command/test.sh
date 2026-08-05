#!/usr/bin/env bash
# Verify: a compound command still matches, and the γ-path env prefix binds to
# the FIRST command only.
#
# This pins a real limitation rather than a desired behavior. `A && B` matches
# notify_re on A, and the rewrite puts the assignment in front of the whole
# line — so B runs WITHOUT the injected session id and would compute a
# different flag path. That is why the skill requires each notify.sh call to be
# its own Bash invocation instead of being chained onto a neighbour.
set -euo pipefail

first='bash /abs/active-notify/scripts/notify.sh fire-now "build" "성공"'
compound="${first} && echo done"
session_id="test-pretool-compound"

stdin_json=$(jq -nc \
  --arg c "$compound" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: compound command containing a notify.sh call must still match" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" != "1" ]]; then
  exit 0
fi

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
quoted_sid=$(jq -rn --arg s "$session_id" '$s | @sh')
expected="CLAUDE_CODE_SESSION_ID=${quoted_sid} ${compound}"

if [[ "$updated" != "$expected" ]]; then
  echo "FAIL (γ): unexpected rewrite of a compound command" >&2
  echo "  expected: $expected" >&2
  echo "  got:      $updated" >&2
  exit 1
fi

# The assignment sits before the first command only — everything after `&&`
# runs without it. Asserted explicitly so the limitation cannot be "fixed" by
# accident without updating the contract that depends on it.
if [[ "$updated" != "CLAUDE_CODE_SESSION_ID="*" bash "*" && echo done" ]]; then
  echo "FAIL (γ): prefix placement changed; the second command's binding is part of the contract" >&2
  echo "  got: $updated" >&2
  exit 1
fi

exit 0
