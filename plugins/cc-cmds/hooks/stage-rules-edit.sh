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
# A NOTICE FOLLOWS THE STATUS WHEN THE EDIT LEFT A RULE UNCOVERED. For an
# `Edit` or `MultiEdit`, the lines the edit brought in — and the lines of a
# marker it deleted — go to `orchestrator/stage-rules.sh enforcement
# --notice-for -`, and the rules it prints (not covered on every needed path
# by a live enforcement means, or carrying a dead one) are listed in a block
# starting `Rule enforcement check:` that asks the session to put the
# higher-layer question to the person. A `Write` replaces the whole file, so
# its block carries only the number of such rules in the file. The block is
# capped at 2000 bytes, head and end marker included; past that it keeps the
# lines that fit whole and ends in `[and <n> more: run ...]`. With no such
# rule the context is byte for byte the status alone. Nothing is blocked.
#
# THE CONTEXT IS CAPPED AT 6000 BYTES, AND A CUT SAYS SO. Past the cap the
# status is cut at a line boundary and ends in a `[truncated: ...]` marker
# naming the command that prints all of it. A notice block is taken out of
# the cap first and appended after the status, so the status is cut before
# the block ever is.
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

# THE NOTICE. For every edit, the lines it brought in: the whole lines its new
# text touches in the file as edited, minus the same lines with the old text
# put back, as a multiset, one edit at a time. A site is found with jq's
# fixed-string `split`, so no byte offset is counted. When the new text sits
# in the file exactly once, or `replace_all` is true, each site is measured
# this way, and sites whose touched lines overlap are measured as one group;
# otherwise the new and old texts alone are split into lines. An edit whose
# old lines lose a marker line (`강제:` or `산문:` after leading blanks) also
# names the lines its sites touch, so the bullet that held the marker is
# found by line number. The first output line is those numbers, the rest the
# lines brought in.
notice_prog='
def nlc: [explode[] | select(. == 10)] | length;
def lines: if . == "" then [] else split("\n") end;
def msub($b): reduce $b[] as $x (.; index($x) as $i | if $i == null then . else del(.[$i]) end);
def marker: sub("^[ \t]+"; "") | startswith("강제:") or startswith("산문:");
def edit_lines($F):
  (if (.new_string | type) == "string" then .new_string else "" end) as $new
  | (if (.old_string | type) == "string" then .old_string else "" end) as $old
  | (if (.replace_all | type) == "boolean" then .replace_all else false end) as $ra
  | if $new == "" then {add: [], nums: []}
    else
      ($F | split($new)) as $p
      | (($p | length) - 1) as $n
      | if $n == 1 or ($ra and $n >= 1) then
          ($new | nlc) as $nn
          | ($p | map(nlc)) as $pn
          | [range(0; $n) | select(. == 0 or $pn[.] > 0)] as $starts
          | [range(0; $starts | length) as $g
              | $starts[$g] as $i
              | (if $g + 1 < ($starts | length) then $starts[$g + 1] - 1 else $n - 1 end) as $j
              | (($p[$i] | split("\n") | last) // "") as $head
              | (($p[$j + 1] | split("\n") | first) // "") as $tail
              | [range($i + 1; $j + 1) | $p[.]] as $mids
              | {newt: ($head + ($mids | reduce .[] as $m ($new; . + $m + $new)) + $tail),
                 oldt: ($head + ($mids | reduce .[] as $m ($old; . + $m + $old)) + $tail),
                 line: ((reduce range(0; $i + 1) as $k (0; . + $pn[$k])) + $i * $nn + 1)}]
            as $groups
          | [$groups[] | .newt | lines[]] as $nl
          | [$groups[] | .oldt | lines[]] as $ol
          | {add: ($nl | msub($ol)),
             nums: (if any(($ol | msub($nl))[]; marker)
                    then [$groups[] | .line as $s | range($s; $s + (.newt | lines | length))]
                    else [] end)}
        else
          {add: (($new | lines) | msub($old | lines)), nums: []}
        end
    end;
(if .tool_name == "MultiEdit" then [.tool_input.edits[]?] else [.tool_input] end)
| map(select(type == "object") | edit_lines($f))
| ((map(.nums[]) | unique | map(tostring) | join(" ")) + "\n" + (map(.add[]) | join("\n")))
'

# notice holds the target lines (`line <n><TAB><first 40><TAB><reason>`) of an
# Edit or MultiEdit, write_count the number of targets a Write leaves in the
# whole file. Every failure leaves both empty, and the context is then the
# status alone.
notice=""
write_count=0
tool=$(jq -r '.tool_name // empty' <<< "$input" 2>/dev/null)
case "$tool" in
  Edit|MultiEdit)
    out=$(jq -r --rawfile f "$edited" "$notice_prog" <<< "$input" 2>/dev/null) || out=""
    nums="${out%%$'\n'*}"
    case "$out" in *$'\n'*) added="${out#*$'\n'}" ;; *) added="" ;; esac
    lines_args=()
    for n in $nums; do lines_args[${#lines_args[@]}]=--notice-line; lines_args[${#lines_args[@]}]="$n"; done
    if [ -n "$added" ] || [ -n "$nums" ]; then
      notice=$(bash "$helper" enforcement --source "$edited" --notice-for - \
        ${lines_args[@]+"${lines_args[@]}"} <<< "$added" 2>/dev/null) || notice=""
    fi ;;
  Write)
    wout=$(jq -r '.tool_input.content | if type == "string" then . else empty end' <<< "$input" 2>/dev/null \
      | bash "$helper" enforcement --source "$edited" --notice-for - 2>/dev/null) || wout=""
    [ -z "$wout" ] || write_count=$(grep -c '' <<< "$wout") ;;
esac

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

# The notice block, built and measured here, under LC_ALL=C: a fixed head,
# then target lines taken whole from the front while the block stays within
# 2000 bytes with room kept for the end marker it would need if every line
# were left out; the marker is added only when a line was left out.
block=""
block_cap=2000
enf_cmd="bash \"$helper\" enforcement"
block_head="Rule enforcement check: the rules below, from this edit, are not covered on every path they need by a live enforcement means, or carry a dead means (the last column says which). For each one, ask the person whether a higher layer could block it (structure > hook > gate rule > lint > test > prose); the marker, a continuation line \`강제: ...\` or \`산문: <reason>\`, is the person's to add, so do not add it on your own. The edit was not blocked."
if [ -n "$notice" ] && [ $(( ${#block_head} + 1 + ${#notice} )) -le "$block_cap" ]; then
  block="$block_head
$notice"
elif [ -n "$notice" ]; then
  total=$(grep -c '' <<< "$notice")
  reserve="
[and $total more: run $enf_cmd]"
  block="$block_head"
  taken=0
  rest="$notice
"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    rest="${rest#*$'\n'}"
    [ $(( ${#block} + 1 + ${#line} + ${#reserve} )) -le "$block_cap" ] || break
    block="$block
$line"
    taken=$((taken + 1))
  done
  block="$block
[and $((total - taken)) more: run $enf_cmd]"
elif [ "$write_count" -gt 0 ]; then
  block="$block_head
This file has $write_count rule(s) that the check above applies to; a Write replaces the whole file, so this hook cannot tell which of them are new. $enf_cmd prints the list."
fi

# With a block, the status gets what the block leaves of the cap, so the
# status is cut first and the block never is.
if [ -n "$block" ]; then
  block="

$block"
  cap=$(( cap - ${#block} ))
fi

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
context="${context:0:cap}$block"

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null
exit 0
