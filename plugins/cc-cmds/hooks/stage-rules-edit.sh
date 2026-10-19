#!/usr/bin/env bash
#
# stage-rules-edit.sh — show the stage rules status after an edit of the
# user-scope CLAUDE.md.
#
# WHAT IT IS FOR. The bullets of the user-scope CLAUDE.md tagged `[무인]` are
# copied, at each run's open, into the `# Personal rules` block every
# unattended stage reads; untagged bullets and `[대화형]` bullets stay out. The
# session that just edited that file is the one that can tell the person what
# the edit did to the block, so this `PostToolUse` hook runs
# `orchestrator/stage-rules.sh status` right after an `Edit`, `Write` or
# `MultiEdit` of it and hands the output back as `additionalContext`: counts
# and bytes per tag, the untagged and malformed bullets, and the next steps.
# Nothing is recorded and nothing needs confirming — the file itself is the
# record.
#
# THE CONTRACT THIS FILE IMPLEMENTS IS WRITTEN DOWN NEXT DOOR, in README.md.
#
# ONLY THE USER-SCOPE FILE. Any other CLAUDE.md — a repository's, the
# workspace file — is quiet: the stages read those through the instruction
# chain, not through the tags.
#
# STDOUT IS THE CONTEXT CHANNEL HERE, AND ONLY FOR THE ONE JSON OBJECT. Unlike
# the banner seats, this hook writes to stdout on purpose: a `PostToolUse`
# hook's `hookSpecificOutput.additionalContext` is how text reaches the model.
# Every other path writes nothing to stdout, nothing to stderr, and every path
# exits 0 — the helper's own stderr goes to /dev/null, because a line there
# would land in the person's transcript after an ordinary edit.
#
# THE CONTEXT IS CAPPED AT 6000 BYTES, AND A CUT SAYS SO. Past the cap the
# status is cut at a line boundary and ends in a `[truncated: ...]` marker
# naming the command that prints all of it.
#
# AN UNATTENDED STAGE IS LEFT ALONE. With `CC_PIPELINE_RUN_ID` set there is
# nobody to read the status, and a run's block was fixed when it opened.
set -uo pipefail

[ -z "${CC_PIPELINE_RUN_ID:-}" ] || exit 0

# Prepend the Homebrew paths so `jq` is discoverable whatever PATH the harness
# hands down, spelled as the sibling hooks spell it so a test can shadow it.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file_path" ] || exit 0

# canon <file> — the file's directory resolved with `pwd -P`, joined to its
# base name, so a path that came in through a linked settings directory is
# recognised as the same file. Prints nothing when the directory does not exist.
canon() {
  local d
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 0
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

edited=$(canon "$file_path")
[ -n "$edited" ] || exit 0

cfgdir="${CLAUDE_CONFIG_DIR:-}"
[ -n "$cfgdir" ] || cfgdir="${HOME:-}/.claude"
[ "$edited" = "$(canon "$cfgdir/CLAUDE.md")" ] || exit 0

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
helper="$plugin_root/orchestrator/stage-rules.sh"
[ -f "$helper" ] || exit 0

report=$(bash "$helper" status --source "$edited" 2>/dev/null)
[ -n "$report" ] || exit 0
cmd="bash \"$helper\" status"

context="The file just edited ($edited) is the source of the # Personal rules block that cc-cmds unattended stages read: its bullets tagged [무인] are copied into the block when a run opens, and the next run picks up this edit. Show the person the status below; tagging is theirs to decide, so do not change tags on your own judgment.
Status ($cmd):
"

# Past the cap, the status is cut at a line boundary — which also keeps a
# multibyte character whole — and a marker naming the command takes the place
# of what was cut. Byte counts and byte slices need LC_ALL=C. The cut is a
# parameter slice, not a pipe into `head -c`: with SIGPIPE ignored, as a CI
# runner can hand it down, the writer of a report larger than the pipe buffer
# hits the closed pipe and bash prints a write error on stderr.
cap=6000
LC_ALL=C
if [ $(( ${#context} + ${#report} )) -le "$cap" ]; then
  context="$context$report"
else
  marker="
[truncated: run $cmd for the full status]"
  budget=$(( cap - ${#context} - ${#marker} ))
  cut=""
  if [ "$budget" -gt 0 ]; then
    cut="${report:0:budget}"
    case "$cut" in
      *$'\n'*) cut="${cut%$'\n'*}" ;;
      *) cut="" ;;
    esac
  fi
  context="$context$cut$marker"
fi
context="${context:0:cap}"

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null
exit 0
