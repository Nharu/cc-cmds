#!/usr/bin/env bash
# Verify: PreToolUse hook matches `terminal-notifier ... -group
# 'cc-cmds-active-notify'` bypass argv and emits α-path JSON regardless
# of CC_CMDS_NOTIFY_INJECT_SID (γ branch is gated on is_notify=1).
#
# The command is read from the required-form block of SKILL.md §7 rather
# than written here, so the document's command and the one this fixture
# feeds the hook cannot drift apart: the line must carry `-sound 'default'`
# and still be auto-approved.
set -euo pipefail

skill_md="$(dirname "$PRETOOL_HOOK_SH")/../skills/active-notify/SKILL.md"
[[ -f "$skill_md" ]] || { echo "FAIL: SKILL.md not found at $skill_md" >&2; exit 1; }
# The `bash` block that follows the §7 heading, and in it the one notifier line.
bypass_lines=$(awk '
  /^## 7\. Permission test bypass/ { sec = 1; next }
  sec && /^## / { exit }
  sec && /^```bash$/ { blk = 1; next }
  blk && /^```$/ { exit }
  blk && index($0, "terminal-notifier -message '\''cc-cmds permission test'\''") { print }
' "$skill_md")
n=$(printf '%s' "$bypass_lines" | grep -c 'terminal-notifier' || true)
[[ "$n" == "1" ]] || { echo "FAIL: expected 1 bypass line in SKILL.md §7 block, got $n" >&2; exit 1; }
bypass_cmd=$(printf '%s\n' "$bypass_lines" | sed -E 's/^.*(terminal-notifier .*-execute '\'':'\'').*$/\1/')
[[ "$bypass_cmd" == terminal-notifier* ]] || { echo "FAIL: could not cut the notifier command from: $bypass_lines" >&2; exit 1; }
[[ "$bypass_cmd" == *"-group 'cc-cmds-active-notify' -sound 'default' -execute ':'"* ]] || {
  echo "FAIL: bypass command lacks -sound 'default' between -group and -execute" >&2
  echo "  got: $bypass_cmd" >&2
  exit 1
}
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

exit 0
