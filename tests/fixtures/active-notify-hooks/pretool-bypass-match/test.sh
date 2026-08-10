#!/usr/bin/env bash
# Verify: PreToolUse hook matches `terminal-notifier ... -group
# 'cc-cmds-active-notify'` bypass argv and emits α-path JSON regardless
# of CC_CMDS_NOTIFY_INJECT_SID (γ branch is gated on is_notify=1).
set -euo pipefail

bypass_cmd="terminal-notifier -message 'cc-cmds permission test' -title '[cc-cmds] test' -group 'cc-cmds-active-notify'"
session_id="test-pretool-bypass"

stdin_json=$(jq -nc \
  --arg c "$bypass_cmd" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: expected permissionDecision=allow, got: $decision" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

# Bypass match must take α-path emit regardless of inject_sid value.
# Verify applyPermissionRules contains the bypass pattern (not the notify.sh one).
#
# The notify leg stopped emitting a rule; this leg keeps one, and asserting it
# here is what makes the difference between the two legs observable. Deleting the
# bypass leg's rule too would otherwise be a change no fixture in the suite
# notices — this file is the only thing that reddens for it.
rules=$(jq -r '.hookSpecificOutput.applyPermissionRules // empty | if type == "array" then join("|") else . end' "$HOOK_STDOUT")
if [[ "$rules" != *"terminal-notifier"* ]]; then
  echo "FAIL: applyPermissionRules missing terminal-notifier pattern" >&2
  echo "  got: $rules" >&2
  exit 1
fi
if [[ "$rules" != *"cc-cmds-active-notify"* ]]; then
  echo "FAIL: applyPermissionRules missing cc-cmds-active-notify token" >&2
  echo "  got: $rules" >&2
  exit 1
fi

# Bypass match must NEVER produce updatedInput, even under inject_sid=1
if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
  echo "FAIL: bypass match emitted updatedInput (γ branch should be inactive for bypass)" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

# The matcher is unanchored on purpose, so its '.*' must not be allowed to cross
# a newline. bash's ERE lets '.' match one, so `[[ =~ ]]` pairs a terminal-notifier
# on one line with a -group on another and approves a command line that never
# contained the documented form at all. grep is line-based and does not.
cross_line_cmd="terminal-notifier -message 'cc-cmds permission test'
some-other-command -group 'cc-cmds-active-notify'"

jq -nc --arg c "$cross_line_cmd" --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}' \
  | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL: terminal-notifier and -group on separate lines were paired into a match" >&2
  echo "  command: $cross_line_cmd" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
