#!/usr/bin/env bash
#
# posttool.sh — the PostToolUse(AskUserQuestion) seat that leaves the
# remote-input line `[cc-cmds 원격 입력] 발신=<sender>` in the transcript when a
# remote text envelope answered the call.
#
# The line cannot go inside the tool result, so the seam leaves a mark file when
# it commits a text envelope, and this hook turns that file into additional
# context and removes it (`seam.sh mark-take`). With no mark file it prints
# nothing. An option envelope leaves no mark file.
#
# THE GATE, in order, like pretool.sh: jq present; `cc_caller_is_router`; no
# `agent_id`. `seam.sh` then checks the spool root. Every path exits 0 with
# nothing on stderr.
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

printf '%s' "$input" | bash "$plugin_root/hooks/remote-reply/seam.sh" mark-take 2>/dev/null
exit 0
