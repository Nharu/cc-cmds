#!/usr/bin/env bash
# active-notify PreToolUse hook — self-approves dispatcher invocations
# (active-notify/scripts/notify.sh) and the permission-test bypass
# (terminal-notifier -group cc-cmds-active-notify), suppressing the
# Bash tool permission dialog.
#
# Branches on CC_CMDS_NOTIFY_INJECT_SID env (default 0 = α path):
#   0 → applyPermissionRules emit (session-persistent silent allow)
#   1 → updatedInput.command rewrite with CLAUDE_CODE_SESSION_ID prepend
#       (γ fallback for env-var renames; applyPermissionRules MUST NOT
#       be set so the hook fires every call to perform the injection).
set -euo pipefail
# Prepend brew install paths so jq is discoverable regardless of caller PATH.
# Tests can set CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 to skip the prepend.
if [[ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0   # jq missing → silent fail-open, defer to default gate

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0   # non-Bash matcher slip → noop

notify_re='active-notify/scripts/notify\.sh[[:space:]]+(arm|fire|cancel)\b'
bypass_re="terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]"

is_notify=0; is_bypass=0
printf '%s' "$cmd" | grep -qE "$notify_re" && is_notify=1
printf '%s' "$cmd" | grep -qE "$bypass_re" && is_bypass=1
[[ $is_notify -eq 1 || $is_bypass -eq 1 ]] || exit 0   # not ours → default gate

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"

if [[ "$inject_sid" == "1" && $is_notify -eq 1 ]]; then
  # γ-path: inject CLAUDE_CODE_SESSION_ID via updatedInput.command rewrite.
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  new_cmd="CLAUDE_CODE_SESSION_ID=${session_id} ${cmd}"
  jq -nc --arg c "$new_cmd" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "active-notify self-approve + session-id injection",
      updatedInput: { command: $c }
    }
  }'
  exit 0
fi

# α-path (or bypass match): session-persistent allow via applyPermissionRules.
if [[ $is_notify -eq 1 ]]; then
  rule='Bash(bash *active-notify/scripts/notify.sh:*)'
else
  rule="Bash(terminal-notifier *-group *cc-cmds-active-notify*)"
fi

jq -nc --arg r "$rule" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "active-notify self-approve",
    applyPermissionRules: [$r]
  }
}'
exit 0
