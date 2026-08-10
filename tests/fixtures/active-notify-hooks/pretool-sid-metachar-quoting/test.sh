#!/usr/bin/env bash
# Verify: the γ-path shell-quotes the injected session id — asserted by RUNNING
# the rewritten line, not by inspecting it.
#
# This is the one path in the plugin that rewrites a command AND reports it as
# allowed, so an unquoted injection hands the auto-approval meant for notify.sh
# to whatever the session id appended. Comparing the rewritten string against an
# expected string proves only that it matches today's quoting helper; executing
# it proves the shell cannot be made to run a second command. The sentinel lands
# in the driver's per-fixture TMPDIR, so nothing outside this run can be touched
# and no state leaks between the two env legs.
set -euo pipefail

notify_cmd='bash /abs/active-notify/scripts/notify.sh cancel'
sentinel_name='sentinel-should-never-exist'
session_id="sid; touch ${sentinel_name}"

jq -nc --arg c "$notify_cmd" --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}' \
  | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: expected permissionDecision=allow, got: ${decision:-<empty>}" >&2
  exit 1
fi

inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"
if [[ "$inject_sid" != "1" ]]; then
  # α-path performs no rewrite, so there is nothing to execute.
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL (α): updatedInput present (should only appear in γ-path)" >&2
    exit 1
  fi
  exit 0
fi

updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
if [[ -z "$updated" ]]; then
  echo "FAIL (γ): updatedInput.command missing" >&2
  exit 1
fi

# The rewritten line is what the Bash tool would actually run. The notify.sh
# path is a placeholder and will fail to execute; that failure is expected and
# irrelevant — the assertion is about the sentinel.
( cd "$TMPDIR" && bash -c "$updated" ) >/dev/null 2>&1 || true

if [[ -e "$TMPDIR/$sentinel_name" ]]; then
  echo "FAIL (γ): the session id executed a command of its own" >&2
  echo "  rewritten line: $updated" >&2
  exit 1
fi

# The user's call must still be the tail of the line, unsplit.
if [[ "$updated" != *"$notify_cmd" ]]; then
  echo "FAIL (γ): the notify.sh invocation is no longer what runs" >&2
  echo "  rewritten line: $updated" >&2
  exit 1
fi

# A session id that is not a string. `@sh` quotes each element of an array
# separately, so without the `tostring` one assignment becomes an assignment plus
# a stray word, and that word lands in command position. It is quoted, so it ends
# as "command not found" rather than execution — the harm is a lost notification
# carrying an allow, not code execution, and executing the line would therefore
# not discriminate. Nothing below runs anything; the sentinel name is inert.
#
# The assertion derives the expected value the same way the hook must. The obvious
# form — comparing against "CLAUDE_CODE_SESSION_ID="*" ${notify_cmd}" — passes
# with the `tostring` removed, because the glob's `*` spans the stray word and the
# line still ends with the call.
nonstring_json=$(jq -nc --arg c "$notify_cmd" \
  '{tool_input:{command:$c}, session_id:["a","; touch nonstring-sentinel"]}')

printf '%s' "$nonstring_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

updated_ns=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
expected_ns=$(jq -rn '"CLAUDE_CODE_SESSION_ID=" + ((["a","; touch nonstring-sentinel"]) | tostring | @sh)')
if [[ "$updated_ns" != "${expected_ns} ${notify_cmd}" ]]; then
  echo "FAIL (γ): a non-string session id did not reduce to a single shell word" >&2
  echo "  expected: ${expected_ns} ${notify_cmd}" >&2
  echo "  got:      $updated_ns" >&2
  exit 1
fi

exit 0
