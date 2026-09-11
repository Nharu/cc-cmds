#!/usr/bin/env bash
#
# session-turn-notify.sh — seat 2 of the general-session banner.
#
# WHAT IT IS FOR. A turn can end in plain prose and still need the user to do
# something — confirm, choose, operate an external system, type a credential —
# and no tool call marks that. So the model marks it, with one line, and this
# hook fires on it at turn end.
#
# THE MARKER IS NOT INFERRED, IT IS DECLARED, and if it is absent nothing fires
# and that is correct behaviour rather than a miss to be recovered from. There is
# deliberately NO fallback that opens the transcript and walks backwards: that
# path re-fires a marker already fired, because a turn whose last message carries
# no text block makes the walk pick up the message before it. The one property
# this seat rests on is that the banner text comes only from what the harness
# handed over — `.last_assistant_message` here, `.tool_input.questions[]` in the
# sibling seat — and the only change that can break it is adding that fallback.
#
# THE MARKER'S CANONICAL COPY IS README.md NEXT DOOR. The anchor string below is
# a copy of it. One character of drift and this seat goes permanently silent, and
# that silence cannot be told apart from nobody having marked a turn.
#
# WHY `set -uo pipefail` AND NOT `-e`, and why the gate reads `agent_id` rather
# than `agent_type`: both reasons are the sibling seat's, spelled out in the
# header of `session-ask-notify.sh`. The `-e` one bites harder here — an exit 2
# from a `Stop` hook stops the turn from ending at all, so this file cannot
# afford a non-zero path on any branch, including the one a user takes by
# switching the banners off.
set -uo pipefail

# Same prepend and same seam as the sibling seat; see its header for why the
# emitter's own prepend does not cover the `jq` calls in a hook.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
emitter="$plugin_root/orchestrator/notify-run.sh"
[ -f "$emitter" ] || exit 0
# shellcheck source=/dev/null
. "$emitter" >/dev/null 2>&1 || exit 0

if ! cc_notify_session_enabled; then exit 0; fi
if ! cc_caller_is_router; then exit 0; fi

agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
[ -z "$agent_id" ] || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

# THE FIELD IS OPTIONAL IN THE PAYLOAD SCHEMA, so its absence is a normal path.
# It is treated as "no marker" and NOT as a reason to go looking elsewhere —
# that is the same refusal the header states, arriving at its second occasion.
msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null)
[ -n "$msg" ] || exit 0

# THE ANCHOR IS THE START OF THE LAST NON-EMPTY LINE. Six false-positive shapes
# fall out of that definition rather than needing rules of their own: no marker
# at all, a marker inside a `> ` quote, a marker on a `- ` bullet, a marker
# indented, a marker inside a fenced block (the closing fence is then the last
# non-empty line), and a marker spliced into the middle of a line.
#
# A MARKER FOLLOWED BY BLANK LINES STILL FIRES, and that also falls out of the
# definition. Implementing the opposite — anchoring on the literal last line —
# loses a large share of the true positives, and loses them silently.
last=$(printf '%s\n' "$msg" | grep -v '^[[:space:]]*$' | tail -n1)
[ -n "$last" ] || exit 0

marker='**cc-cmds 차례 넘김**: '
case "$last" in
  "$marker"*) reason="${last#"$marker"}" ;;
  *) exit 0 ;;
esac
if [ -z "$reason" ]; then reason='차례가 넘어왔습니다'; fi

CC_NOTIFY_SESSION_ID="$sid"
export CC_NOTIFY_SESSION_ID
cc_notify_fire session-turn "$reason" >/dev/null 2>&1
exit 0
