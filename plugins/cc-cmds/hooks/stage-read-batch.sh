#!/usr/bin/env bash
#
# stage-read-batch.sh — tell an unattended stage lead, right after a response,
# that its last few responses each carried a single read-only call.
#
# WHAT IT IS FOR. Every model request re-reads the whole conversation, so a
# stage costs what its number of responses costs. The stage policy's
# `## Turn economy` section tells every session to issue independent calls in
# one response; this `PostToolBatch` hook is the reminder that reaches the lead
# at the point it chooses its next response. It blocks nothing: whether two
# reads are independent is the lead's judgement, and a wrong count costs one
# line of context.
#
# THE CONTRACT THIS FILE IMPLEMENTS IS WRITTEN DOWN NEXT DOOR, in README.md.
#
# WHEN IT ACTS. Only in a stage lead: `CC_PIPELINE_STAGE_ID` is not empty (a
# routing shift and a general session have none), the event is `PostToolBatch`
# and the input carries no `agent_id` (a team member or a subagent). Anything
# else reads the input, writes nothing and exits 0.
#
# A SINGLE-READ RESPONSE is a batch whose `tool_calls` holds exactly one call,
# and that call is read-only as `scripts/measure-read-chains.py` defines it:
# `Read`, `Grep` or `Glob`, or a `Bash` call whose first word ends in
# `/orchestrator/gate.sh` and whose second word is `snapshot`, or `exec` with
# `--surface 읽기` (or `--surface=읽기`) before the first `--`. The words are
# split on whitespace with surrounding quotes dropped, a jq approximation of
# the script's `shlex` split: a misjudged edge case adds or drops one hint.
#
# THE COUNT is the number of single-read responses in a row, kept per session
# in `${TMPDIR:-/tmp}/cc-cmds-read-batch/<safe_sid>`; any other response puts
# it back to 0. The hint goes out when the count is 2, 6, 10, … (count mod 4 is
# 2): right after the second, to stop a third, and then once every four so a
# long chain does not pile hints into the context. A state file that cannot be
# read or written ends the hook with nothing printed.
#
# WHY `set -uo pipefail` AND NOT `-e`, and why every path exits 0 with nothing
# on stderr: the stdout of PostToolBatch is the context channel, and an exit 2
# from it stops the agent loop. No ledger row, no notifier, no gate call.
set -uo pipefail

if [ -z "${CC_PIPELINE_STAGE_ID:-}" ]; then
  cat >/dev/null 2>&1
  exit 0
fi

# Same PATH prepend and seam as the sibling hooks, so `jq` is found whatever
# PATH the harness hands down and a test can shadow the binaries.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null 2>&1
  exit 0
fi

input=$(cat 2>/dev/null)

# One parse gives the event, the member marker, the session id and the verdict
# on one line each; input that is not JSON prints nothing and ends here.
JQ_PROG='
def words:
  [splits("[ \t\n]+")] | map(select(. != "") | sub("^[\"'"'"']"; "") | sub("[\"'"'"']$"; ""));
def read_only:
  (.tool_name // "") as $n
  | if $n == "Read" or $n == "Grep" or $n == "Glob" then true
    elif $n == "Bash" then
      ((.tool_input.command? // "") | if type == "string" then . else "" end | words) as $w
      | if ($w | length) < 2 or (($w[0] | endswith("/orchestrator/gate.sh")) | not) then false
        elif $w[1] == "snapshot" then true
        elif $w[1] != "exec" then false
        else
          ($w | index("--")) as $k
          | (if $k == null then $w else $w[:$k] end) as $pre
          | [range(0; $pre | length) as $i
             | $pre[$i] == "--surface=읽기"
               or ($pre[$i] == "--surface" and $pre[$i + 1] == "읽기")]
          | any
        end
    else false end;
if type != "object" then empty else
  (.hook_event_name // "" | tostring),
  (.agent_id // "" | tostring),
  (.session_id // "" | tostring),
  (if (.tool_calls | type) == "array" and (.tool_calls | length) == 1
      and (.tool_calls[0] | type) == "object" and (.tool_calls[0] | read_only)
   then "read" else "other" end)
end'

parsed=$(printf '%s' "$input" | jq -r "$JQ_PROG" 2>/dev/null) || exit 0
event=$(printf '%s\n' "$parsed" | sed -n '1p')
agent_id=$(printf '%s\n' "$parsed" | sed -n '2p')
sid=$(printf '%s\n' "$parsed" | sed -n '3p')
verdict=$(printf '%s\n' "$parsed" | sed -n '4p')

[ "$event" = "PostToolBatch" ] || exit 0
[ -z "$agent_id" ] || exit 0
[ -n "$sid" ] || exit 0

# The sanitizer is the one session-status-snapshot.sh uses (`an_safe_sid` in
# skills/active-notify/scripts/notify.sh is the original).
safe_sid="${sid//[^A-Za-z0-9_.-]/_}"
state_dir="${TMPDIR:-/tmp}"
state_dir="${state_dir%/}/cc-cmds-read-batch"
state="$state_dir/$safe_sid"

prev=0
if [ -e "$state" ]; then
  prev=$(cat "$state" 2>/dev/null) || exit 0
  case "$prev" in
    ''|*[!0-9]*) prev=0 ;;
  esac
fi

if [ "$verdict" = "read" ]; then
  n=$((10#$prev + 1))
else
  n=0
fi

(umask 077; mkdir -p "$state_dir") >/dev/null 2>&1 || exit 0
tmp="$state_dir/.${safe_sid}.$$.tmp"
if ! (umask 077; printf '%s\n' "$n" > "$tmp") >/dev/null 2>&1; then
  rm -f "$tmp" >/dev/null 2>&1
  exit 0
fi
if ! mv -f "$tmp" "$state" >/dev/null 2>&1; then
  rm -f "$tmp" >/dev/null 2>&1
  exit 0
fi

if [ "$((n % 4))" -eq 2 ]; then
  hint="[cc-batch-hint] The last $n responses each carried a single read-only call. If the reads you plan next do not depend on a result you have not seen, issue them together in one response (stage policy, Turn economy)."
  jq -cn --arg c "$hint" \
    '{hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $c}}' 2>/dev/null
fi
exit 0
