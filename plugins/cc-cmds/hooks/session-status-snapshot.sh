#!/usr/bin/env bash
#
# session-status-snapshot.sh — leave a session's state and recent output in the
# attention spool, as `status/<safe_sid>.json`, for a read-only session view.
#
# WHAT IT IS FOR. An app outside this machine shows what each session is doing
# — working, waiting on a question, waiting on a permission, idle — and the last
# thing it said. Nothing else records that, so this hook rewrites one small file
# per session at each of those moments. It raises no banner, calls no notifier
# and no attention tap, and never changes what the session does.
#
# ONE SCRIPT, SEVEN hooks.json ENTRIES (it branches on `hook_event_name`):
#   PreToolUse(AskUserQuestion)   — waiting-question; the questions and labels
#   PostToolUse(AskUserQuestion)  — working; the previous excerpt
#   PostToolBatch                 — waiting-question and the one-shot marker when
#                                   the batch opened the question form
#   Stop                          — the marker alone is consumed when present;
#                                   otherwise idle with the last assistant text
#   UserPromptSubmit              — working; the previous excerpt
#   PermissionRequest             — waiting-permission; tool name and input
#   SessionEnd                    — the snapshot and the marker are removed
#
# THE WRITE GATE, in order; any false step writes and removes nothing:
#   jq present; a PostToolBatch whose raw input does not name the question form
#   ends before anything is sourced (the event fires after every tool batch);
#   `cc_caller_is_router`; no `agent_id`; a non-empty `session_id`; the spool
#   root exists. The banner switch (`cc_notify_session_enabled`) is NOT read:
#   the snapshot is data, not a banner. The test seat of the spool root is read
#   only inside attention.sh, whose helpers give the root, the host id and the
#   time; that file is sourced, never edited.
#
# THE QUESTION FORM'S TURN. The form opens and its turn ends at once with the
# form still up, so that turn's Stop would overwrite the question with idle. The
# PostToolBatch that saw the form open leaves a marker under TMPDIR, and the Stop
# that finds it removes the marker and leaves the snapshot as it is. Every other
# write removes the marker, so the next turn's end writes idle as usual.
#
# THE EXCERPT comes only from what the harness handed over — the transcript is
# never opened — and is cut to 4096 UTF-8 bytes on line boundaries: the tail is
# kept for a turn's end, the head for a question or a permission. When the one
# line on the kept side alone is over the limit, it is cut on a character
# boundary instead, so the excerpt is never empty for want of a newline.
#
# WHY `set -uo pipefail` AND NOT `-e`, and why every path exits 0 with nothing on
# stdout or stderr: the stdout of UserPromptSubmit reaches the model, the stdout
# of PreToolUse, PermissionRequest and PostToolBatch is a decision channel, and
# an exit 2 from PostToolBatch or Stop stops the agent loop. Every `jq` and `git`
# call drops its stderr, and every write runs with its output discarded.
set -uo pipefail

# Same PATH prepend and seam as the seats, so `jq` is found whatever PATH the
# harness hands down and a test can shadow the binaries.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# PostToolBatch fires after every tool batch of every turn; the only batch this
# hook acts on carries the question form's tool name, so every other one ends
# here on a shell `case`, before anything is sourced or parsed. The event key is
# matched in its unescaped form, so the same words inside a string value do not
# match; a spelling not listed here falls through to the full parse, which does
# the same thing more slowly.
case "$input" in
  *'"hook_event_name":"PostToolBatch"'*|*'"hook_event_name": "PostToolBatch"'*)
    case "$input" in
      *mcp__cc-cmds__question_form*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
fi
emitter="$plugin_root/orchestrator/notify-run.sh"
[ -f "$emitter" ] || exit 0
# shellcheck source=/dev/null
. "$emitter" >/dev/null 2>&1 || exit 0

# A pipeline stage, a routing shift or a re-entry has no person to show.
if ! cc_caller_is_router; then exit 0; fi

# `agent_id` and not `agent_type`: the same reason as the seats (see the header
# of session-ask-notify.sh).
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
[ -z "$agent_id" ] || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

tap="$plugin_root/orchestrator/attention.sh"
[ -f "$tap" ] || exit 0
# shellcheck source=/dev/null
. "$tap" >/dev/null 2>&1 || exit 0
# The helper runs in this command substitution's subshell and never creates the
# root: no root, no snapshot.
root=$(cc_attention__root 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

# The sanitizer is a copy of `an_safe_sid` in skills/active-notify/scripts/
# notify.sh — its twin; change the two together.
safe_sid="${sid//[^A-Za-z0-9_.-]/_}"
status_dir="$root/status"
snap="$status_dir/${safe_sid}.json"
mark_dir="${TMPDIR:-/tmp}/cc-cmds-session-status"
mark="$mark_dir/${safe_sid}.form"

# The excerpt rules, shared by every event that writes one.
# `QUESTION_FORM_OPEN` is a copy of the question form's result token
# (`TOKEN_PREFIX` + `OPEN` in hooks/question-form/spec.ts); change them together.
JQ_DEFS='
def cpbytes: if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end;
def cpcut($keep):
  explode
  | (if $keep == "tail" then reverse else . end) as $o
  | (reduce $o[] as $c ({n: 0, k: 0, stop: false};
      if .stop then .
      else (.n + ($c | cpbytes)) as $m
        | if $m <= 4096 then .n = $m | .k += 1 else .stop = true end
      end)) as $r
  | $o | .[0:$r.k]
  | (if $keep == "tail" then reverse else . end)
  | implode;
def cut($keep):
  if utf8bytelength <= 4096 then .
  else
    split("\n")
    | (if $keep == "tail" then reverse else . end) as $o
    | (reduce $o[] as $x ({n: -1, k: 0, stop: false};
        if .stop then .
        else (.n + 1 + ($x | utf8bytelength)) as $m
          | if $m <= 4096 then .n = $m | .k += 1 else .stop = true end
        end)) as $r
    | if $r.k == 0 then ($o[0] | cpcut($keep))
      else $o | .[0:$r.k] | (if $keep == "tail" then reverse else . end) | join("\n")
      end
  end;
def str: if type == "string" then . elif . == null then "" else tostring end;
def qlines:
  [ .questions[]?
    | ((.header | if type == "string" and . != "" then . else "질문" end)
        + " — " + (.question | str)),
      (.options[]? | "- " + (.label | str)) ];
def form_open:
  [ .tool_calls[]?
    | select(.tool_name == "mcp__cc-cmds__question_form")
    | select((.tool_response | if type == "string" then . else tojson end)
             | contains("QUESTION_FORM_OPEN ")) ]
  | last;
'

# The previous snapshot's excerpt as a JSON string, `""` when the file is
# missing, unreadable or holds no string there.
prev_excerpt() {
  local v
  v=$(jq -cn 'first(inputs) | (if type == "object" then .excerpt else null end)
              | if type == "string" then . else "" end' "$snap" 2>/dev/null)
  [ -n "$v" ] || v='""'
  printf '%s' "$v"
}

# The `<owner>/<name>` of the working directory's origin remote, or empty; the
# check that makes it a value is the one the attention tap applies to
# `origin.repo`, inside the record builder below.
repo_of() {
  local dir="$1" url
  [ -n "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  url=$( (cd "$dir" 2>/dev/null && git config --get remote.origin.url) 2>/dev/null) || return 0
  printf '%s' "$url"
}

drop_mark() { rm -f "$mark" >/dev/null 2>&1; return 0; }

# write_snap <state> <excerpt as a JSON string> — the one record, moved over the
# old one from a dot file in the same directory. The marker is removed after
# every write; the PostToolBatch branch makes it again after its own write.
write_snap() {
  local state="$1" ex="$2" host ms cwd url cfg
  [ -n "$ex" ] || return 0
  host=$(cc_attention__host 2>/dev/null)
  [ -n "$host" ] || host=local
  ms=$(cc_attention__ms 2>/dev/null) || return 0
  [ -n "$ms" ] || return 0
  cwd=$(printf '%s' "$input" | jq -r '.cwd | strings' 2>/dev/null)
  [ -n "$cwd" ] || cwd="${PWD:-}"
  url=$(repo_of "$cwd")
  cfg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  (
    umask 077
    if [ ! -d "$status_dir" ]; then
      mkdir -m 700 "$status_dir" || [ -d "$status_dir" ] || exit 0
    fi
    rec=$(jq -cn \
      --arg host "$host" --arg sid "$sid" --arg cfg "$cfg" --arg cwd "$cwd" \
      --arg url "$url" --arg state "$state" --argjson ms "$ms" --argjson ex "$ex" \
      '($url | sub("\\.git$"; "") | [splits("[:/]")] | .[-2:] | join("/")) as $r
       | {schema: 1, host: $host, session_id: $sid, config_dir: $cfg,
          cwd: (if $cwd == "" then null else $cwd end),
          repo: (if $url != ""
                    and ($r | test("\\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\\z"))
                    and (($r | split("/") | .[1]) as $n | $n != "." and $n != "..")
                 then $r else null end),
          state: $state, last_activity_ms: $ms, excerpt: $ex}') || exit 0
    [ -n "$rec" ] || exit 0
    tmp="$status_dir/.${safe_sid}.$$.tmp"
    if printf '%s\n' "$rec" > "$tmp"; then
      mv -f "$tmp" "$snap"
    fi
    rm -f "$tmp"
  ) >/dev/null 2>&1
  drop_mark
  return 0
}

excerpt() {
  printf '%s' "$input" | jq -c "$JQ_DEFS $1" 2>/dev/null
}

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
case "$event" in
  PreToolUse)
    # Checked here as well as by the matcher, so an entry that loses its matcher
    # cannot turn every tool call into a question.
    if [ "$tool" = "AskUserQuestion" ]; then
      write_snap waiting-question "$(excerpt '.tool_input | qlines | join("\n") | cut("head")')"
    fi
    ;;
  PostToolUse)
    if [ "$tool" = "AskUserQuestion" ]; then
      write_snap working "$(prev_excerpt)"
    fi
    ;;
  PostToolBatch)
    ex=$(excerpt 'form_open | if . == null then empty else
           .tool_input
           | ([(.title | if type == "string" and . != "" then . else empty end)] + qlines)
           | join("\n") | cut("head") end')
    if [ -n "$ex" ]; then
      write_snap waiting-question "$ex"
      ( umask 077; mkdir -p "$mark_dir" && : > "$mark" ) >/dev/null 2>&1
    fi
    ;;
  Stop)
    if [ -e "$mark" ]; then
      drop_mark
    else
      write_snap idle "$(excerpt '.last_assistant_message | str | cut("tail")')"
    fi
    ;;
  UserPromptSubmit)
    write_snap working "$(prev_excerpt)"
    ;;
  PermissionRequest)
    # The question paths own these two tools.
    case "$tool" in
      AskUserQuestion|mcp__cc-cmds__question_form) ;;
      *)
        write_snap waiting-permission "$(excerpt '
          (.tool_name | str) + "\n"
          + (.tool_input as $i
             | if ($i | type) == "object" and ($i.command | type) == "string" then $i.command
               elif ($i | type) == "object" and ($i.file_path | type) == "string" then $i.file_path
               else ($i | tojson) end)
          | cut("head")')"
        ;;
    esac
    ;;
  SessionEnd)
    rm -f "$snap" >/dev/null 2>&1
    drop_mark
    ;;
esac
exit 0
