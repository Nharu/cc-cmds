#!/usr/bin/env bash
#
# session-title.sh — name a session after the slash command it is running.
#
# WHAT IT IS FOR. A slash-command prompt such as `/cc-cmds:review 1085` gives the
# session the title `review·#1085` — `<skill>·<argument summary>`, at most 38
# display cells — through `hookSpecificOutput.sessionTitle`. The harness stores it where `/rename` stores
# a name, so it shows in the `cc -r` picker, the prompt box and the terminal
# title. It is registered as a sibling entry of the existing `UserPromptSubmit`
# array; `SessionStart` is not used, because a session is not named when it
# starts.
#
# IT NEVER OVERWRITES A NAME A PERSON GAVE. The harness does not protect a
# `/rename` name from a hook title, and the payload carries no field saying who
# set the current title. So the hook remembers the titles it emitted, per
# session, in `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session-title/<sid>`,
# and acts only when the current title is empty or one of its own. Once a title
# it did not emit is seen, the file is marked `!released` and the hook never
# titles that session again. After `/clear` (a new session id carrying the old
# title) the title is adopted when it is the last title another session's file
# recorded.
#
# THE CURRENT TITLE FILE. Every prompt that gets past the session id check also
# keeps `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session-title-now/<sid>`
# in step with the session's user-defined title: two lines, the schema line
# `cc-session-title-now v1` and the title. The run-status pane and the two
# banner seats read that file and nothing else. It lives in its own directory
# because the `/clear` lookup and the 30-day sweep walk the ownership directory,
# which must hold one format only, and it is written on plain prompts too —
# recording a `/rename` name does not touch the ownership state.
#
# WHY stdout IS USED. Unlike the banner seats, this hook answers through stdout:
# exactly one JSON object, on the path that emits a title, and nothing on any
# other path. A `UserPromptSubmit` hook's plain stdout is added to the model's
# context, so no diagnostic is ever written there.
#
# WHY `set -uo pipefail` AND NOT `-e`. The switch parsing and the file checks
# answer a normal "no" with status 1 inside the flow; under `-e` the hook would
# die on exactly those answers. Every path exits 0 — exit 2 on this event blocks
# the prompt — and nothing is written to stderr; every external command drops
# its stderr.
#
# THE GATE READS `agent_id`, NOT `agent_type`. `agent_type` is also present on a
# main thread started with `--agent`. This event's payload carries no `agent_id`
# at all today, so the branch is a defence, not a path that fires.
#
# THERE IS NO PIPELINE-MARKER CHECK, ON PURPOSE. Unattended stage sessions get
# their titles by the same rules. Copying a sibling hook's stage check here would
# make stage titles disappear without a sound.
#
# Self-contained: it does not source `notify-run.sh`, does not read
# `CC_PIPELINE_*`, `.transcript_path` or `.agent_type`, and raises no banner.
set -uo pipefail

# Same PATH prepend and test seam as the banner seats, so `jq` is found whatever
# PATH the harness hands down and a test can shadow the binaries.
if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

# The switch. Off values exit before stdin is read, so neither state file is
# written or removed — a current title file written before the switch was set
# stays as it is.
case "${CC_CMDS_SESSION_TITLE:-}" in
  0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) exit 0 ;;
esac

input=$(cat)

# Prompt parsing, title assembly, width and cutting all happen in this one jq
# program; bash never measures or cuts a string. The fields come out one per
# line, and none of them can hold a newline: a current title with a newline or a
# NUL can never equal a title this hook emitted, so it is passed as `odd`.
#
# `cw` and `cut` stay one line each starting at column 0: the banner emitter
# carries the same two definitions and a test compares the copies byte for byte.
prog='
def cw: if (. >= 4352 and . <= 4447) or (. >= 11904 and . <= 42191 and . != 12351) or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255) or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135) or (. >= 65280 and . <= 65376) or (. >= 65504 and . <= 65510) or (. >= 127744 and . <= 129791) or (. >= 131072 and . <= 262141) then 2 else 1 end;
def cut($n): reduce explode[] as $c ({o: [], w: 0, stop: false}; if .stop then . elif .w + ($c|cw) <= $n then .o += [$c] | .w += ($c|cw) else .stop = true end) | .o | implode | sub("[\\s·]+$"; "");
# The harness normalisation set, compared by code point so no regex engine is
# involved: C0/C1 controls, the line and paragraph separators, every Unicode 17.0
# Cf code point, and the spaces JS trim removes.
def isn:
  (. <= 32) or (. >= 127 and . <= 160) or . == 173
  or (. >= 1536 and . <= 1541) or . == 1564 or . == 1757 or . == 1807
  or (. >= 2192 and . <= 2193) or . == 2274 or . == 5760 or . == 6158
  or (. >= 8192 and . <= 8207) or (. >= 8232 and . <= 8239)
  or (. >= 8287 and . <= 8292) or (. >= 8294 and . <= 8303)
  or . == 12288 or . == 65279 or (. >= 65529 and . <= 65531)
  or . == 69821 or . == 69837 or (. >= 78896 and . <= 78911)
  or (. >= 113824 and . <= 113827) or (. >= 119155 and . <= 119162)
  or . == 917505 or (. >= 917536 and . <= 917631);
def norm:
  [explode[] | if isn then 32 else . end]
  | reduce .[] as $c ([]; if $c == 32 and length > 0 and .[-1] == 32 then . else . + [$c] end)
  | (if length > 0 and .[0] == 32 then .[1:] else . end)
  | (if length > 0 and .[-1] == 32 then .[:-1] else . end)
  | implode;
# The current title file value: each run of control characters becomes one space.
def oneline:
  reduce explode[] as $c ({o: [], p: false};
    if ($c <= 31) or ($c >= 127 and $c <= 159)
    then (if .p then . else .o += [32] | .p = true end)
    else .o += [$c] | .p = false end)
  | .o | implode;
# The single quote is built from its code point: this program sits inside a
# single-quoted shell string.
def sq: [39] | implode;
def unq:
  if length >= 2 and ((startswith("\"") and endswith("\"")) or (startswith(sq) and endswith(sq)))
  then .[1:-1] else . end;
def dropflags:
  . as $t
  | reduce range(0; length) as $i ({o: [], skip: false};
      if .skip then .skip = false
      elif ($t[$i] | startswith("--")) then
        (if ($t[$i] | contains("=") | not) and $i + 1 < ($t | length) and ($t[$i + 1] | startswith("-") | not)
         then .skip = true else . end)
      else .o += [$t[$i]] end)
  | .o;
def word:
  if test("/(pull|issues)/[0-9]+$") then "#" + capture("/(pull|issues)/(?<n>[0-9]+)$").n
  else
    (if contains("/") or endswith(".md")
     then (split("/") | last // "") | (if endswith(".md") then .[:-3] else . end)
     else . end)
    | gsub("[0-9]{8}-(?<h>[0-9a-f]{8})"; "\(.h)")
  end;
def summary:
  norm
  | [scan("\"[^\"]*\"|" + sq + "[^" + sq + "]*" + sq + "|[^ ]+")]
  | dropflags
  | map(unq | [splits(" +")] | map(select(length > 0) | word))
  | (if length > 0 and (.[0] | length) > 0 and (.[0][0] | test("^[0-9]+$"))
     then .[0][0] = "#" + .[0][0] else . end)
  | [.[][] | select(length > 0)]
  | join(" ")
  | norm;
def str: if type == "string" then . else "" end;
def hasnl: explode | any(. == 10 or . == 0);

(.session_id | str | if test("^[A-Za-z0-9-]+$") then . else "" end) as $sid
| ((.agent_id // "") | tostring | if length > 0 then "1" else "0" end) as $agent
| (.prompt | str | split("\n")[0] // "") as $first
| (.session_title // "" | str) as $t
| (if $t == "" then "empty" elif ($t | hasnl) then "odd" else "plain" end) as $tkind
| (if $tkind == "plain" then $t else "" end) as $tv
| ($tv | sub("-[a-z]+-[a-z]+(-[0-9]{1,4})?$"; "") | if . == "" then $tv else . end) as $base
| ($t | oneline) as $now
| (.cwd | str | if hasnl then "" elif startswith("/") then . else "" end) as $cwd
| "^/(?<ns>[A-Za-z0-9][A-Za-z0-9_.-]*:)?(?<name>[A-Za-z0-9][A-Za-z0-9_-]*)(?=\\s|$)(?<args>.*)$" as $re
| (if ($first | test($re)) then ($first | capture($re)) else null end) as $m
| (if $m == null then {v: "skip", name: "", title: ""}
   else
     ($m.name) as $label
     | ($m.args | summary) as $s
     | {v: (if $m.ns == null then "bare" else "ns" end),
        name: $label,
        title: (if ([$label | explode[] | cw] | add) > 38 then $label | cut(38)
                elif $s == "" then $label
                else ($label + "·" + $s) | cut(38) end)}
   end) as $r
| $sid, $agent, $r.v, $r.name, $r.title, $tkind, $tv, $base, $now, $cwd, "end"
'

out=$(printf '%s' "$input" | jq -r "$prog" 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0
{
  IFS= read -r sid
  IFS= read -r agent
  IFS= read -r verdict
  IFS= read -r name
  IFS= read -r title
  IFS= read -r tkind
  IFS= read -r T
  IFS= read -r base
  IFS= read -r now_value
  IFS= read -r cwd
  IFS= read -r sentinel
} <<EOF
$out
EOF
[ "${sentinel:-}" = "end" ] || exit 0

# A subagent is not titled; the gate reads `agent_id` only.
[ "$agent" = "0" ] || exit 0
# The id becomes a file name, so its shape is checked before any path is built.
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || exit 0

state_root="${XDG_STATE_HOME:-}"
if [ -z "$state_root" ]; then
  [ -n "${HOME:-}" ] || exit 0
  state_root="$HOME/.local/state"
fi
own_dir="$state_root/cc-cmds/session-title"
own_file="$own_dir/$sid"
now_dir="$state_root/cc-cmds/session-title-now"
now_file="$now_dir/$sid"
own_schema='cc-session-title v1'
now_schema='cc-session-title-now v1'

# Set when this call wrote or removed a file in either directory; only then does
# the 30-day sweep run.
touched=0

# write_atomic <dir> <target> <line>... — a `mktemp` sibling, then `mv -f`.
write_atomic() {
  local dir="$1" target="$2" tmp
  shift 2
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.$sid.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$@" 2>/dev/null >"$tmp" && mv -f "$tmp" "$target" 2>/dev/null; then
    touched=1
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Keep the current title file in step with <value>. Written when the value is
# not empty and differs from line 2 or the file does not read as the format;
# removed when the value is empty; left alone, mtime and all, when it is equal.
# A failure here changes neither the output nor the ownership state.
sync_now() {
  local v="$1" l1="" l2="" valid=0
  if [ -f "$now_file" ]; then
    { IFS= read -r l1; IFS= read -r l2; } 2>/dev/null <"$now_file"
    if [ "$l1" = "$now_schema" ] && [ -n "$l2" ]; then valid=1; fi
  fi
  if [ -z "$v" ]; then
    if [ -e "$now_file" ] && rm -f "$now_file" 2>/dev/null; then touched=1; fi
    return 0
  fi
  if [ "$valid" = "1" ] && [ "$l2" = "$v" ]; then return 0; fi
  write_atomic "$now_dir" "$now_file" "$now_schema" "$v" || true
  return 0
}

sweep() {
  [ "$touched" = "1" ] || return 0
  local d
  for d in "$own_dir" "$now_dir"; do
    [ -d "$d" ] || continue
    find "$d" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
  done
  return 0
}

# Every end after the id check goes through here: the current title file is set
# to <value> before the one stdout line, then the sweep, then the line.
finish() {
  sync_now "$1"
  sweep
  if [ -n "${2:-}" ]; then
    jq -cn --arg t "$2" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",sessionTitle:$t}}' 2>/dev/null
  fi
  exit 0
}

release() {
  write_atomic "$own_dir" "$own_file" "$own_schema" '!released' || true
  finish "$now_value"
}

# Not a target: a plain prompt, a pasted path, a built-in command, or a bare
# name that resolves in none of the five places. Nothing about ownership moves.
[ "$verdict" = "skip" ] && finish "$now_value"
if [ "$verdict" = "bare" ]; then
  cfg="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$cfg" ] && [ -n "${HOME:-}" ]; then cfg="$HOME/.claude"; fi
  found=0
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/$name/SKILL.md" ]; then found=1; fi
  if [ -n "$cfg" ]; then
    if [ -f "$cfg/skills/$name/SKILL.md" ] || [ -f "$cfg/commands/$name.md" ]; then found=1; fi
  fi
  if [ -n "$cwd" ]; then
    if [ -f "$cwd/.claude/skills/$name/SKILL.md" ] || [ -f "$cwd/.claude/commands/$name.md" ]; then found=1; fi
  fi
  [ "$found" = "1" ] || finish "$now_value"
fi

# Ownership. `titles` holds this session's remembered titles, oldest first.
titles=()
file_state=none
if [ -f "$own_file" ]; then
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = "1" ]; then
      first=0
      [ "$line" = "$own_schema" ] || { file_state=none; break; }
      file_state=list
      continue
    fi
    if [ "$line" = "!released" ]; then file_state=released; break; fi
    [ -n "$line" ] && titles+=("$line")
  done 2>/dev/null <"$own_file"
fi

[ "$file_state" = "released" ] && finish "$now_value"

# Own when the current title equals a remembered title, or is one with the
# harness's uniqueness suffix `-<adjective>-<noun>[-N]` (lowercase only). jq
# took the suffix off as `base`, so this is byte comparison alone.
is_own_title() {
  local l
  for l in ${titles[@]+"${titles[@]}"}; do
    [ "$T" = "$l" ] && return 0
    if [ "$base" != "$T" ] && [ "$base" = "$l" ]; then return 0; fi
  done
  return 1
}

if [ "$tkind" != "empty" ]; then
  if [ "$file_state" = "list" ]; then
    if [ "$tkind" = "odd" ] || ! is_own_title; then release; fi
  else
    # No usable file but a title: adopt it when it is the last line of another
    # session's live file (the `/clear` carry), otherwise release.
    [ "$tkind" = "odd" ] && release
    adopted=""
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      c_first="" c_last="" c_rel=0
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$c_first" ] && c_first="$line"
        [ "$line" = "!released" ] && c_rel=1
        c_last="$line"
      done 2>/dev/null <"$cand"
      [ "$c_first" = "$own_schema" ] || continue
      [ "$c_rel" = "0" ] || continue
      if [ "$c_last" = "$T" ] || [ "$c_last" = "$base" ]; then
        adopted="$c_last"
        break
      fi
    done <<EOF
$(grep -lFx -e "$T" -e "$base" -- "$own_dir"/* 2>/dev/null)
EOF
    [ -n "$adopted" ] || release
    titles=("$adopted")
  fi
fi

# A repeat: the same title, or the same title with a uniqueness suffix. The
# harness skips the first itself, and the second may be re-applied without the
# suffix after a resume, so the hook emits neither.
if [ "$tkind" = "plain" ]; then
  if [ "$title" = "$T" ] || { [ "$base" != "$T" ] && [ "$base" = "$title" ]; }; then
    finish "$now_value"
  fi
fi

# Remember the title before emitting it, keeping the newest four. A title that
# could not be remembered is not emitted: it would read as a person's name next
# time and stop this session's titling for good.
titles+=("$title")
while [ "${#titles[@]}" -gt 4 ]; do
  titles=("${titles[@]:1}")
done
write_atomic "$own_dir" "$own_file" "$own_schema" "${titles[@]}" || finish "$now_value"
finish "$title" "$title"
