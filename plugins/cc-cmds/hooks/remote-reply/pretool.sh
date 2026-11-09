#!/usr/bin/env bash
#
# pretool.sh — the PreToolUse(AskUserQuestion) seat that answers an autopilot
# approval question at once from a run-address envelope this session (or a
# session it inherits from through the run's lineage) has already picked up.
#
# It never waits and never looks again: when there is no such envelope, or the
# call is anything other than one question opening with `승인 <approval_id> — `,
# it exits 0 with nothing on stdout. On success it prints one PreToolUse
# decision, `allow` with `updatedInput.answers` only. The acceptance and the
# apply are `seam.sh sat`, the same functions the mode's commit uses.
#
# THE GATE, in order, like the session snapshot seat: jq present;
# `cc_caller_is_router`; no `agent_id`. `seam.sh` then checks the spool root.
set -uo pipefail

if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/../.." && pwd) || exit 0
fi
. "$plugin_root/orchestrator/notify-run.sh" >/dev/null 2>&1 || exit 0
if ! cc_caller_is_router; then exit 0; fi
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null) || exit 0
[ -z "$agent_id" ] || exit 0

printf '%s' "$input" | bash "$plugin_root/hooks/remote-reply/seam.sh" sat 2>/dev/null
exit 0
