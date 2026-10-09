#!/usr/bin/env bash
#
# session-return-dismiss.sh — take a session's cc-cmds banners down when the
# person comes back to it.
#
# WHAT IT IS FOR. A banner is raised so that someone looking at another window
# comes back. Once they have — they submitted a message, or they answered a
# question — the banner has done its job, and leaving it on the screen and in
# Notification Center only buries the next one. This hook takes down the banners
# THIS session raised: the session seat (`cc-cmds-session-<sid>`) and every
# active-notify banner (`cc-cmds-active-notify-<sid>` and its `@` pile-up
# groups). Another session's banners, the autopilot run banners and the
# permission-test bypass banner are never touched.
#
# ONE SCRIPT, THREE hooks.json ENTRIES:
#   Stop                          — records the session's scheduled-task texts;
#                                   never dismisses
#   UserPromptSubmit              — classifies the prompt, dismisses on a return
#   PostToolUse(AskUserQuestion)  — an answer is always a return
# The writer and the reader of the state file live in this one file so that the
# path, the sanitizer and the format move together.
#
# WHY A PROMPT IS CLASSIFIED. `UserPromptSubmit` also fires with nobody there: a
# background agent's report arrives as a `<task-notification>` envelope, and a
# `/loop` iteration or a `ScheduleWakeup` arrives as the bare scheduled text. No
# payload field tells those apart from typing. So, in order:
#   1. the text a previous `Stop` recorded for this session (or the head of a
#      truncated record) — not a return;
#   2. a leading XML-shaped element — not a return, except a leading
#      `<pasted_content …>`, which is the person pasting;
#   3. everything else — a return.
# Accepted misses, all in the cheap direction (the banner stays until the next
# return): an answer closed with Esc and a local-only slash command fire no event
# at all; typing exactly the text of a pending scheduled task, and typing that
# starts with markup, read as machine turns.
#
# NO `agent_id` GATE, unlike the seats. A successful `AskUserQuestion` means a
# person answered, whoever asked, and a subagent's tool events carry the parent's
# `session_id`. `UserPromptSubmit` has no subagent shape to filter.
#
# WHY `set -uo pipefail` AND NOT `-e`, and why every path exits 0 with nothing on
# stdout or stderr: the same reasons as the seats (see session-ask-notify.sh),
# with one more here — a `UserPromptSubmit` hook's stdout is added to the
# model's context, so a stray byte is not just noise but an injected prompt.
# Every `jq` call drops its stderr: a broken payload makes it print a parse error.
set -uo pipefail

# Same PATH prepend and seam as the seats, so `jq` is found whatever PATH the
# harness hands down and a test can shadow the binaries.
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

# Switched off: neither record nor dismiss — a session with nothing to protect
# has no reason to keep the record.
if ! cc_notify_dismiss_enabled; then exit 0; fi
# A pipeline stage session (`claude -p` with `CC_PIPELINE_*`) has nobody to come
# back, and its prompts are not a person returning.
if ! cc_caller_is_router; then exit 0; fi

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

# The state file. The sanitizer is a copy of `an_safe_sid` in
# skills/active-notify/scripts/notify.sh — its twin; change the two together.
# A sibling of the active-notify flag directory, not inside it: this hook never
# reads or writes an ARM flag.
safe_sid="${sid//[^A-Za-z0-9_.-]/_}"
state_dir="${TMPDIR:-/tmp}/cc-cmds-session-return"
state_file="$state_dir/${safe_sid}.crons"

# Stop — snapshot the pending scheduled-task texts as one compact JSON array
# (texts may span lines, so no line format), overwriting the previous snapshot.
# An empty array removes the file. A payload WITHOUT the key leaves the file as
# it is: the key is documented as present when the task registry is reachable,
# so its absence means "could not read", not "nothing pending" — and removing
# the file would make the next scheduled turn over-dismiss.
record_crons() {
  local has crons tmp
  has=$(printf '%s' "$input" | jq -r 'has("session_crons")' 2>/dev/null) || return 0
  [ "$has" = "true" ] || return 0
  crons=$(printf '%s' "$input" | jq -c '[.session_crons[]?.prompt | strings]' 2>/dev/null) || return 0
  [ -n "$crons" ] || return 0
  if [ "$crons" = "[]" ]; then
    rm -f "$state_file" 2>/dev/null
    return 0
  fi
  (
    umask 077
    mkdir -p "$state_dir" 2>/dev/null || exit 0
    tmp=$(mktemp "$state_dir/.${safe_sid}.XXXXXX" 2>/dev/null) || exit 0
    if printf '%s\n' "$crons" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  )
  return 0
}

# The truncation marker a long scheduled text is recorded with, `… [+N chars]`.
# Both the Unicode ellipsis (kept as its three UTF-8 bytes) and three dots are
# accepted, because only the documented form was seen, never the bytes. Held in
# a variable and tested with `[[ =~ ]]`, like the envelope pattern below.
trunc_re='[[:space:]]*(…|\.\.\.) \[\+[0-9]+ chars\]$'

# Stage 1. A prompt is a scheduled machine turn when it equals a recorded text
# byte for byte (compared inside jq, so a trailing newline is not lost to a
# command substitution), or when a recorded text carries the truncation marker
# and the prompt starts with its head. Reads the state file, never writes it.
is_recorded_cron() {
  local line entry head
  [ -f "$state_file" ] || return 1
  if printf '%s' "$input" \
       | jq -e --slurpfile s "$state_file" \
           '.prompt as $p | ($s[0] // []) | any(.[]; . == $p)' >/dev/null 2>&1; then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry=$(printf '%s' "$line" | jq -r '.' 2>/dev/null) || continue
    if [[ $entry =~ $trunc_re ]]; then
      head="${entry%"${BASH_REMATCH[0]}"}"
      [ -n "$head" ] || continue
      if [[ $prompt == "$head"* ]]; then
        return 0
      fi
    fi
  done <<EOF
$(jq -r '.[]? | strings | @json' "$state_file" 2>/dev/null)
EOF
  return 1
}

# Stage 2. A leading XML-shaped element is a harness envelope. bash's `^`
# anchors at the start of the whole string, not of each line — which is why
# this is not a `grep -E` pipe as in active-notify-pretool.sh: line by line,
# `hi\n<task-notification>` would read as an envelope and stay open.
envelope_re='^[[:space:]]*<[A-Za-z][A-Za-z0-9_-]*([[:space:]>/])'
pasted_re='^[[:space:]]*<pasted_content([[:space:]>])'

is_return_prompt() {
  if is_recorded_cron; then return 1; fi
  if [[ $prompt =~ $pasted_re ]]; then return 0; fi
  if [[ $prompt =~ $envelope_re ]]; then return 1; fi
  return 0
}

# The dismissal. The session seat goes first: when an answer to question 1 is
# followed at once by question 2 in the same seat, a late removal could take
# question 2's banner down, and putting the seat first narrows that window by
# the `-list ALL` time. Detached, so the hook returns at once and the turn is
# not held; `CC_CMDS_NOTIFY_DISMISS_SYNC=1` runs it in the foreground for tests.
# This hook never calls terminal-notifier itself.
dismiss() {
  if [ "${CC_CMDS_NOTIFY_DISMISS_SYNC:-}" = "1" ]; then
    { CC_NOTIFY_SESSION_ID="$sid" cc_notify_clear session-ask
      bash "$plugin_root/skills/active-notify/scripts/notify.sh" dismiss "$sid"
    } </dev/null >/dev/null 2>&1
  else
    { CC_NOTIFY_SESSION_ID="$sid" cc_notify_clear session-ask
      bash "$plugin_root/skills/active-notify/scripts/notify.sh" dismiss "$sid"
    } </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
case "$event" in
  Stop)
    record_crons
    ;;
  UserPromptSubmit)
    prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)
    if is_return_prompt; then dismiss; fi
    ;;
  PostToolUse)
    # Checked here as well as by the matcher, so an entry that loses its
    # matcher or lands in the wrong array cannot turn every tool call into a
    # dismissal.
    tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
    if [ "$tool" = "AskUserQuestion" ]; then dismiss; fi
    ;;
esac
exit 0
