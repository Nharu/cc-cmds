#!/usr/bin/env bash
#
# stage-policy-edit-drift.sh — the edit-time seat of the stage-policy drift check.
#
# WHAT IT IS FOR. `orchestrator/stage-policy.md` is an English distillation of
# the user-scope CLAUDE.md and the workspace instruction file, and a person edits
# those two by hand. The session that just edited one of them knows best what the
# edit meant, so this `PostToolUse` hook runs the drift checker right after an
# `Edit`, `Write` or `MultiEdit` of either file and, when the verdict is
# `mismatch`, hands the findings back to that session as `additionalContext`.
# The session then asks the person whether the distillation still holds and
# records the answer with the checker's `--ack` or `--ack-added`. What the hook
# misses, the autopilot kickoff shows again.
#
# THE CONTRACT THIS FILE IMPLEMENTS IS WRITTEN DOWN NEXT DOOR, in README.md.
#
# WHY `set -uo pipefail` AND NOT `-e`. The checker answers `mismatch` with exit 1,
# which is the one case this hook exists for; under `-e` the capture of that
# output would kill the hook exactly when it has something to say.
#
# STDOUT IS THE CONTEXT CHANNEL HERE, AND ONLY FOR THE ONE JSON OBJECT. Unlike the
# banner seats, this hook writes to stdout on purpose: a `PostToolUse` hook's
# `hookSpecificOutput.additionalContext` is how text reaches the model. Every
# other path writes nothing to stdout, nothing to stderr, and every path exits 0 —
# the checker's own stderr goes to /dev/null, because a line there would land in
# the person's transcript after an ordinary edit.
#
# THE CONTEXT IS CAPPED AT 6000 BYTES, AND A CUT SAYS SO. The instructions are
# never cut; they carry the checker's finding count and tell the session to run
# `--explain` itself before any `--ack`. When the findings do not fit, they are
# cut at a line boundary and end in a `[truncated: ...]` marker with the same
# count, so a session cannot mistake a partial list for the whole of it.
#
# AN UNATTENDED STAGE IS LEFT ALONE. With `CC_PIPELINE_RUN_ID` set there is nobody
# to confirm an acknowledgement, and the checker refuses one there anyway.
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
watched=0
[ "$edited" = "$(canon "$cfgdir/CLAUDE.md")" ] && watched=1
map="${HOME:-}/.config/cc-cmds/stage-policy-sources"
if [ "$watched" = 0 ] && [ -f "$map" ]; then
  ws=$(awk -F'\t' '$1 == "workspace" { print $2; exit }' "$map" 2>/dev/null)
  [ -n "$ws" ] && [ "$edited" = "$(canon "$ws")" ] && watched=1
fi
[ "$watched" = 1 ] || exit 0

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
checker="$plugin_root/orchestrator/stage-policy-drift.sh"
[ -f "$checker" ] || exit 0

report=$(bash "$checker" --explain 2>/dev/null)
verdict=$(printf '%s\n' "$report" | tail -n 1)
case "$verdict" in
  mismatch*) : ;;
  *) exit 0 ;;
esac
total="${verdict#mismatch }"

# The instructions come before the findings, so the byte cap cuts findings and
# never the rule that an acknowledgement needs the person's confirmation. The
# instructions also carry the checker's own finding count and the command that
# prints the whole list, because `--ack` records every pending finding and the
# list below may not show them all.
context="The file just edited ($edited) is a source of the cc-cmds stage policy ($plugin_root/orchestrator/stage-policy.md), an English distillation injected into unattended stages, and the edit moved an item the policy tracks.
The checker reported $total finding(s). The list below may be cut short by the context size cap, so before any --ack run bash \"$checker\" --explain yourself and read its full output.
For each 'changed' item, compare the edited item with the policy section its disposition names (policy:<Section> is the '## <Section>' heading of stage-policy.md; skill:<name> is that skill's SKILL.md) and judge whether the distillation still says what the item now says, then ask the user to confirm your judgment; ask the same for a 'removed' item on an excluded row. --ack has no per-row form: one run records every such pending finding at once. So ask about all of them first, and only when the user has confirmed every one run once: bash \"$checker\" --ack. If they reject any, do not run --ack at all; tell them the rejected item needs the policy text changed in the repository.
For an 'added' item, recommend a disposition and ask the user. If it is excluded:<reason> or skill:<name>, record it after their confirmation with: bash \"$checker\" --ack-added '<anchor prefix>' <disposition>. If it belongs in the policy, tell the user it needs a repository change to stage-policy.md and stage-policy.sources.tsv; do not record it.
Do not run --ack or --ack-added without the user's explicit confirmation: an acknowledgement is the user's claim that the policy still holds, not yours.
Findings and diffs (stage-policy-drift.sh --explain):
"

# Past the cap, the findings are cut at a line boundary — which also keeps a
# multibyte character whole — and a marker naming the total takes the place of
# what was cut. Byte counts need LC_ALL=C.
cap=6000
LC_ALL=C
if [ $(( ${#context} + ${#report} )) -le "$cap" ]; then
  context="$context$report"
else
  marker="
[truncated: the checker reported $total finding(s); run bash \"$checker\" --explain for the full list]"
  budget=$(( cap - ${#context} - ${#marker} ))
  cut=""
  if [ "$budget" -gt 0 ]; then
    cut=$(printf '%s' "$report" | head -c "$budget")
    case "$cut" in
      *$'\n'*) cut="${cut%$'\n'*}" ;;
      *) cut="" ;;
    esac
  fi
  context="$context$cut$marker"
fi
context=$(printf '%s' "$context" | head -c "$cap")

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null
exit 0
