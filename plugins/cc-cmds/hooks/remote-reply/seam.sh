#!/usr/bin/env bash
#
# seam.sh — the session seam's shell side: every read and write of the attention
# spool that applies a remote answer to this session's open question.
#
# The formats are fixed in `plugins/cc-cmds/skills/_common/remote-reply.md`
# (envelope, mailbox, pick-up marker, acceptance conditions, apply order, answer
# strings, wake literal, applied record) and in
# `plugins/cc-cmds/skills/_common/attention-event.md` (spool, events, handled
# markers, file creation). This script moves them; it does not restate them.
#
# SUBCOMMANDS (the mode in `index.tsx` and `pretool.sh` are the callers):
#   wait                       stdin {session_id, tool_use_id, questions, rejected}
#                              polls once a second for a candidate envelope of the
#                              open call and prints `<addr> <reply_id>`
#   commit <addr> <reply_id>   stdin {session_id, tool_use_id, questions}
#                              acceptance, pick-up, applied record, handled
#                              marker; prints the answer map
#   sat                        stdin the PreToolUse hook input; applies a picked
#                              run-address approval envelope and prints the hook
#                              decision
#   scan                       stdin {session_id, form}; prints
#                              {form: {reply_id, picks} | null, wake: [...]}
#                              after picking up run-address envelopes
#   form-pick <reply_id>       stdin {session_id, form}; prints the reply id when
#                              the pick-up marker is this session's
#   form-unpick <reply_id>     stdin {session_id}; removes this session's marker
#   form-record <session_id> <reply_id>
#                              stdin the submitted text; applied record and
#                              handled marker
#   wake-mark <run_id> <reply_id>
#                              stdin {session_id}; marks the envelope woken and
#                              prints the wake literal once
#   cleanup                    stdin {session_id}; removes this role's files
#                              whose envelope is gone
#
# THE GATE, in order, before any subcommand; a false step ends with rc 0 and no
# output: jq present; `cc_caller_is_router`; the spool root exists. The root
# comes from the tap library's public `cc_attention_root`, the host id and the
# time from its helpers, so the test seat of the root is read only there.
#
# A REJECTION writes nothing, prints nothing and exits 0. Nothing here prints to
# stderr or shows anything on a screen.
#
# Compatibility: bash 3.2 (macOS stock) — no associative arrays, no `mapfile`.
set -uo pipefail

if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/../.." && pwd) || exit 0
fi
. "$plugin_root/orchestrator/notify-run.sh" >/dev/null 2>&1 || exit 0
if ! cc_caller_is_router; then exit 0; fi
. "$plugin_root/orchestrator/attention.sh" >/dev/null 2>&1 || exit 0
root=$(cc_attention_root 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
state="${XDG_STATE_HOME:-${HOME:-}/.local/state}/cc-cmds"
umask 077

nl='
'

# --------------------------------------------------------------------------
# Small checks
# --------------------------------------------------------------------------

seam_safe_sid() {
  local s="$1"
  printf '%s' "${s//[^A-Za-z0-9_.-]/_}"
}

seam_is_rid() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9-]{1,32}\.[0-9]+\.[0-9a-f]{8}$'
}

seam_is_run() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9-]{1,64}$'
}

seam_is_sid() {
  case "$1" in
    ''|.*|*/*) return 1 ;;
  esac
  return 0
}

seam_is_addr() {
  case "$1" in
    s-*) printf '%s' "${1#s-}" | grep -Eq '^[A-Za-z0-9_.-]+$' ;;
    r-*) seam_is_run "${1#r-}" ;;
    *) return 1 ;;
  esac
}

# The run ids of this session's forward index whose run directory exists, one
# per line.
seam_runs() {
  local sid="$1" idx line
  idx="$state/session/$sid"
  [ -f "$idx" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    seam_is_run "$line" || continue
    [ -d "$state/run/$line" ] || continue
    printf '%s\n' "$line"
  done < "$idx"
}

# True when the session id is a line of the run's lineage file.
seam_in_lineage() {
  local run="$1" sid="$2" f
  f="$state/run/$run/session-lineage"
  [ -f "$f" ] || return 1
  grep -Fxq -- "$sid" "$f" 2>/dev/null
}

seam_sha256() {
  local h
  h=$(shasum -a 256 2>/dev/null) || return 1
  h=${h%% *}
  printf '%s' "$h" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s' "$h"
}

seam_mkdir() {
  [ -d "$1" ] && return 0
  mkdir -p -m 700 "$1" 2>/dev/null || [ -d "$1" ]
}

# seam_create <dir> <name> <content> — create <dir>/<name> once through a dot
# file in the same directory and `mv -n`, whose exit status is not read.
seam_create() {
  local d="$1" name="$2" content="$3" tmp
  seam_mkdir "$d" || return 1
  tmp="$d/.$name.$$.tmp"
  if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -n "$tmp" "$d/$name" 2>/dev/null || true
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# Events and handled markers
# --------------------------------------------------------------------------

# seam_event_record <event_id> — print the event's slot and created_at_ms on one
# line separated by a tab when the record is schema 1 and accepts `option`;
# print nothing otherwise. Handled markers are not read here.
seam_event_record() {
  local ev="$1" f
  case "$ev" in
    ''|.*|*/*) return 0 ;;
  esac
  f="$root/events/$ev.json"
  [ -f "$f" ] || return 0
  jq -r 'select(.schema == 1 and ((.accepts // []) | type) == "array"
                and any(.accepts[]; . == "option")
                and (.slot | type) == "string" and (.slot | length) > 0
                and (.created_at_ms | type) == "number")
         | "\(.slot)\t\(.created_at_ms)"' "$f" 2>/dev/null || return 0
}

# seam_handled_state <slot> <created_at_ms> — print `handled` when a handled
# marker closes the event by the reader rules, `open` when none does, and
# nothing when the markers could not be read. Every marker file goes to one jq
# through a pipe as one line of its own, never as an argument, so the number of
# markers is not bounded by the argument limit, and a file that does not parse
# as one JSON object is skipped instead of stopping the read. A file's own
# newlines are joined with spaces, which no JSON string can hold raw.
seam_handled_state() {
  local slot="$1" created="$2" hd="$root/handled"
  if [ ! -d "$hd" ]; then
    printf 'open\n'
    return 0
  fi
  find "$hd" -maxdepth 1 -type f -name '*.json' ! -name '.*' \
      -exec awk 'FNR == 1 && NR > 1 { printf "\n" } { printf "%s ", $0 } END { if (NR > 0) printf "\n" }' {} + 2>/dev/null \
    | jq -nrR --arg slot "$slot" --argjson c "$created" '
        if any(inputs | (try fromjson catch null)
                      | select(type == "object" and .schema == 1
                               and (.slot | type) == "string"
                               and (.at_ms | type) == "number");
               .slot as $m
               | .at_ms > $c
                 and ($m == $slot or (.prefix == true and ($slot | startswith($m)))))
        then "handled" else "open" end' 2>/dev/null
}

# seam_event <event_id> — print the event's slot and created_at_ms on one line
# separated by a tab when the record is schema 1, accepts `option` and is not
# handled by the reader rules; print nothing otherwise. Markers that could not
# be read reject the envelope: an unread marker may be the one that closed the
# event, and applying an answer to a closed question is the worse outcome.
seam_event() {
  local info slot created state
  info=$(seam_event_record "$1")
  [ -n "$info" ] || return 0
  slot=${info%%	*}
  created=${info#*	}
  state=$(seam_handled_state "$slot" "$created") || return 0
  [ "$state" = open ] || return 0
  printf '%s\t%s\n' "$slot" "$created"
}

# --------------------------------------------------------------------------
# Acceptance
# --------------------------------------------------------------------------

# The envelope checks that need no file other than the envelope: schema, kind,
# host (1), the address rule, the target against the open call or form (3), the
# answer rules (4) and expiry (5). Prints one JSON object with what the apply
# needs, or nothing.
ACCEPT_JQ='
def ctl: test("[\u001e\u001f]");
def dupes: length != (unique | length);
def norm: split(" ← ")[0];
def strs: type == "array" and all(.[]; type == "string");
. as $e
| $e.target as $t
| select($e.schema == 1 and $e.kind == "option" and $e.reply_id == $rid)
| select($e.host == $host)
| select(($e.expires_at_ms | type) == "number" and $now < $e.expires_at_ms)
| select(($e.event_id | type) == "string" and ($e.event_id | startswith($host + ".")))
| select(($e.provenance | type) == "object"
         and ($e.provenance.transport | type) == "string"
         and ($e.provenance.sender | type) == "string")
| select(($t | type) == "object")
| ($t.surface) as $s
| select(if $s == "approval" then $addr == ("r-" + ($t.run_id | tostring))
         elif $s == "auq" or $s == "question-form" then $addr == ("s-" + $safe) and $t.session_id == $sid
         else false end)
| (if $s == "auq" then
     [ $t.questions[]? | {q: .question, h: .header, m: (.multi_select == true),
                          labels: [ .options[]?.label ]} ]
   elif $s == "question-form" then
     [ $t.questions[]? | {id: .id, q: .question, m: false, labels: [ .options[]?.label ]} ]
   else
     [ {q: $t.question, m: false, labels: ($t.options // [])} ]
   end) as $tq
| select(($tq | length) >= 1)
| select(all($tq[]; (.q | type) == "string" and (.labels | strs) and (.labels | length) >= 1))
| select(all($tq[]; (.q | ctl | not) and all(.labels[]; ctl | not)))
| select(all($tq[]; .labels | dupes | not))
| select(all($tq[]; (.m | not) or all(.labels[]; contains(", ") | not)))
| select($s != "auq" or ([ $tq[].q ] | dupes | not))
| ($e.answers) as $a
| select(($a | type) == "array" and ($a | length) == ($tq | length))
| select([ range(0; $a | length) as $i
           | $a[$i] as $x
           | $tq[$i] as $q
           | ($x | type) == "object" and $x.question_index == $i
             and ($x.labels | strs)
             and (if $q.m then ($x.labels | length) >= 1 and ($x.labels | dupes | not)
                  else ($x.labels | length) == 1 end)
             and all($x.labels[]; . as $l | $q.labels | index([$l]) != null) ]
         | all)
| (if $mode == "call" then
     ($call.questions // []) as $cq
     | if $s == "auq" then
         select($call.tool_use_id == $t.tool_use_id and ($cq | length) == ($tq | length))
         | select([ range(0; $cq | length) as $i
                    | $cq[$i] as $c | $tq[$i] as $q
                    | $c.question == $q.q and $c.header == $t.questions[$i].header
                      and (($c.multiSelect // false) == $q.m)
                      and ([ $c.options[]?.label ] == $q.labels) ] | all)
         | {cell: $call.tool_use_id,
            answers: (reduce range(0; $cq | length) as $i ({};
              $cq[$i] as $c | $a[$i].labels as $ls
              | . + {($c.question):
                     (if $tq[$i].m then [ $c.options[].label | select(. as $l | $ls | index([$l]) != null) ] | join(", ")
                      else $ls[0] end)}))}
       elif $s == "approval" then
         select(($cq | length) == 1 and $cq[0].question == $t.question)
         | [ $cq[0].options[]?.label ] as $cl
         | select(($cl | strs) and ($cl | length) >= 1 and ($cl | dupes | not))
         | select(all($cl[]; ctl | not))
         | select(([ $cl[] | norm ] | dupes | not))
         | select(([ $cl[] | norm ] | unique) == ($t.options | unique))
         | {cell: $call.tool_use_id,
            answers: {($t.question): ([ $cl[] | select(norm == $a[0].labels[0]) ][0])}}
       else empty end
   elif $mode == "form" then
     select($s == "question-form" and ($form | type) == "object" and $form.form_id == $t.form_id)
     | ($form.questions // []) as $fq
     | select(($fq | length) == ($tq | length))
     | select([ range(0; $fq | length) as $i
                | $fq[$i] as $f | $tq[$i] as $q
                | $f.id == $q.id and $f.question == $q.q
                  and ([ $f.options[]?.label ] == $q.labels) ] | all)
     | {cell: $t.form_id,
        picks: [ range(0; $tq | length) as $i | {id: $tq[$i].id, label: $a[$i].labels[0]} ]}
   elif $mode == "pickup" then
     select($s == "approval") | {cell: null}
   else empty end)
| . + {surface: $s, event_id: $e.event_id,
       transport: $e.provenance.transport, sender: $e.provenance.sender,
       approval_id: (if $s == "approval" then $t.approval_id else null end)}
'

# seam_accept <mode> <addr> <reply_id> <sid> <now> <input-json>
#   mode call   — the open AskUserQuestion call {tool_use_id, questions}
#   mode form   — {form: <open form target>}
#   mode pickup — run-address pick-up (conditions 1, 2, 4, 5, lineage, no marker)
# Prints the accepted JSON (with `slot`) or nothing.
seam_accept() {
  local mode="$1" addr="$2" rid="$3" sid="$4" now="$5" input="$6"
  local env host out ev slotinfo slot marker msid run cell h claim
  seam_is_addr "$addr" || return 0
  seam_is_rid "$rid" || return 0
  seam_is_sid "$sid" || return 0
  env="$root/inbox/$addr/$rid.json"
  [ -f "$env" ] || return 0
  host=$(cc_attention__host)
  out=$(jq -c \
    --arg mode "$mode" --arg addr "$addr" --arg rid "$rid" --arg sid "$sid" \
    --arg safe "$(seam_safe_sid "$sid")" --arg host "$host" --argjson now "$now" \
    --argjson call "$(if [ "$mode" = call ]; then printf '%s' "$input"; else printf 'null'; fi)" \
    --argjson form "$(if [ "$mode" = form ]; then printf '%s' "$input" | jq -c '.form // null'; else printf 'null'; fi)" \
    "$ACCEPT_JQ" "$env" 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  case "$out" in *"$nl"*) return 0 ;; esac

  # 2 — the event exists, accepts `option` and is not handled.
  ev=$(printf '%s' "$out" | jq -r '.event_id' 2>/dev/null) || return 0
  slotinfo=$(seam_event "$ev")
  [ -n "$slotinfo" ] || return 0
  slot=${slotinfo%%	*}

  # 6 — not applied yet; the marker is this session's or inheritable; the
  # target cell's claim is free or this envelope's.
  [ -e "$root/applied/$rid.json" ] && return 0
  run=""
  case "$addr" in r-*) run=${addr#r-} ;; esac
  marker="$root/inbox/$addr/$rid.picked"
  if [ -e "$marker" ]; then
    [ "$mode" = pickup ] && return 0
    msid=$(jq -r 'select(.schema == 1) | .session_id // empty' "$marker" 2>/dev/null) || return 0
    if [ "$msid" != "$sid" ]; then
      [ -n "$run" ] || return 0
      [ -n "$msid" ] || return 0
      seam_in_lineage "$run" "$msid" || return 0
      seam_in_lineage "$run" "$sid" || return 0
    fi
  elif [ -n "$run" ]; then
    seam_in_lineage "$run" "$sid" || return 0
  fi
  cell=$(printf '%s' "$out" | jq -r '.cell // empty' 2>/dev/null) || return 0
  if [ -n "$cell" ]; then
    h=$(printf '%s\037%s' "$root" "$cell" | seam_sha256) || return 0
    claim="$state/remote-reply/target/$h"
    if [ -e "$claim" ]; then
      IFS= read -r line < "$claim" 2>/dev/null || line=""
      [ "$line" = "$rid" ] || return 0
    fi
  fi

  # 7 — session-address envelopes only: the sender is registered for the kind.
  if [ -z "$run" ]; then
    local senders="${HOME:-}/.config/cc-cmds/remote-senders.json" ok
    [ -f "$senders" ] || return 0
    ok=$(jq -r --arg s "$(printf '%s' "$out" | jq -r '.sender')" '
           select(.schema == 1 and (.senders | type) == "array")
           | [ .senders[] | select(type == "object" and .id == $s
                                   and ((.capabilities // []) | type) == "array"
                                   and any(.capabilities[]; . == "option")) ]
           | length' "$senders" 2>/dev/null) || return 0
    case "$ok" in ''|0) return 0 ;; esac
  fi

  printf '%s' "$out" | jq -c --arg slot "$slot" '. + {slot: $slot}' 2>/dev/null
}

# --------------------------------------------------------------------------
# Apply steps
# --------------------------------------------------------------------------

# (가) seam_pick <addr> <reply_id> <sid> <now> — create the pick-up marker when
# it is missing, then read it back. True when it is this session's (or, for a
# marker that was already there, one the acceptance found inheritable).
seam_pick() {
  local addr="$1" rid="$2" sid="$3" now="$4" d marker json msid
  d="$root/inbox/$addr"
  marker="$d/$rid.picked"
  if [ -e "$marker" ]; then
    return 0
  fi
  json=$(jq -cn --arg rid "$rid" --arg sid "$sid" --argjson now "$now" \
    '{schema: 1, reply_id: $rid, session_id: $sid, picked_at_ms: $now, apply_by_ms: ($now + 120000)}') || return 1
  seam_create "$d" "$rid.picked" "$json" || return 1
  msid=$(jq -r '.session_id // empty' "$marker" 2>/dev/null) || return 1
  [ "$msid" = "$sid" ]
}

# (나) seam_record <cell> <sid> <rid> <event_id> <hash> <transport> <sender> <now>
# — claim the target cell, refuse an envelope already applied, write the nine-key
# record and read every key back.
seam_record() {
  local cell="$1" sid="$2" rid="$3" ev="$4" hash="$5" transport="$6" sender="$7" now="$8"
  local h tdir line json f want got
  h=$(printf '%s\037%s' "$root" "$cell" | seam_sha256) || return 1
  tdir="$state/remote-reply/target"
  seam_create "$tdir" "$h" "$rid" || return 1
  line=""
  IFS= read -r line < "$tdir/$h" 2>/dev/null || true
  [ "$line" = "$rid" ] || return 1
  f="$root/applied/$rid.json"
  [ -e "$f" ] && return 1
  json=$(jq -cn --arg tu "$cell" --arg sid "$sid" --arg rid "$rid" --arg ev "$ev" \
    --arg h "$hash" --arg tr "$transport" --arg se "$sender" --argjson at "$now" \
    '{schema: 1, tool_use_id: $tu, session_id: $sid, reply_id: $rid, event_id: $ev,
      answers_sha256: $h, transport: $tr, sender: $se, applied_at_ms: $at}') || return 1
  seam_create "$root/applied" "$rid.json" "$json" || return 1
  want=$(printf '%s' "$json" | jq -cS . 2>/dev/null) || return 1
  got=$(jq -cS . "$f" 2>/dev/null) || return 1
  [ -n "$want" ] && [ "$want" = "$got" ]
}

# seam_commit_call <addr> <reply_id> <call-json> [need-marker] — the whole commit
# for an open AskUserQuestion call; prints the answer map on success.
seam_commit_call() {
  local addr="$1" rid="$2" call="$3" need="${4:-}" sid now acc answers hash cell ev slot transport sender
  sid=$(printf '%s' "$call" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  now=$(cc_attention__ms) || return 0
  acc=$(seam_accept call "$addr" "$rid" "$sid" "$now" "$call")
  [ -n "$acc" ] || return 0
  if [ -n "$need" ] && [ ! -e "$root/inbox/$addr/$rid.picked" ]; then return 0; fi
  answers=$(printf '%s' "$acc" | jq -c '.answers' 2>/dev/null) || return 0
  hash=$(printf '%s' "$call" | jq -j --argjson a "$answers" \
    '.questions[] | .question, "\u001f", $a[.question], "\u001e"' 2>/dev/null | seam_sha256) || return 0
  cell=$(printf '%s' "$acc" | jq -r '.cell') || return 0
  ev=$(printf '%s' "$acc" | jq -r '.event_id') || return 0
  slot=$(printf '%s' "$acc" | jq -r '.slot') || return 0
  transport=$(printf '%s' "$acc" | jq -r '.transport') || return 0
  sender=$(printf '%s' "$acc" | jq -r '.sender') || return 0
  seam_pick "$addr" "$rid" "$sid" "$now" || return 0
  seam_record "$cell" "$sid" "$rid" "$ev" "$hash" "$transport" "$sender" "$now" || return 0
  cc_attention_handled "$slot" reply-applied
  printf '%s\n' "$answers"
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

cmd_wait() {
  local input sid tu safe aid rejected f rid runs run
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  tu=$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  [ -n "$tu" ] || return 0
  safe=$(seam_safe_sid "$sid")
  aid=$(printf '%s' "$input" | jq -r '
        (.questions // []) | if length == 1 then
          (try (.[0].question | capture("^승인 (?<id>[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}) — ").id) catch empty)
        else empty end' 2>/dev/null) || aid=""
  rejected=$(printf '%s' "$input" | jq -r '(.rejected // [])[] | strings' 2>/dev/null) || rejected=""
  while :; do
    for f in "$root/inbox/s-$safe"/*.json; do
      [ -f "$f" ] || continue
      rid=${f##*/}
      rid=${rid%.json}
      case "$nl$rejected$nl" in *"$nl$rid$nl"*) continue ;; esac
      if jq -e --arg rid "$rid" --arg tu "$tu" '.reply_id == $rid and .target.tool_use_id == $tu' "$f" >/dev/null 2>&1; then
        printf 's-%s %s\n' "$safe" "$rid"
        return 0
      fi
    done
    if [ -n "$aid" ]; then
      runs=$(seam_runs "$sid")
      for run in $runs; do
        for f in "$root/inbox/r-$run"/*.json; do
          [ -f "$f" ] || continue
          rid=${f##*/}
          rid=${rid%.json}
          case "$nl$rejected$nl" in *"$nl$rid$nl"*) continue ;; esac
          if jq -e --arg rid "$rid" --arg aid "$aid" '.reply_id == $rid and .target.approval_id == $aid' "$f" >/dev/null 2>&1; then
            printf 'r-%s %s\n' "$run" "$rid"
            return 0
          fi
        done
      done
    fi
    sleep 1
  done
}

cmd_commit() {
  local addr="${1:-}" rid="${2:-}" call
  call=$(cat)
  seam_commit_call "$addr" "$rid" "$call"
}

cmd_sat() {
  local input sid tu call aid runs run f rid answers
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  tu=$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  [ -n "$tu" ] || return 0
  aid=$(printf '%s' "$input" | jq -r '
        (.tool_input.questions // []) | if length == 1 then
          (try (.[0].question | capture("^승인 (?<id>[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}) — ").id) catch empty)
        else empty end' 2>/dev/null) || return 0
  [ -n "$aid" ] || return 0
  call=$(printf '%s' "$input" | jq -c '{session_id, tool_use_id, questions: .tool_input.questions}' 2>/dev/null) || return 0
  runs=$(seam_runs "$sid")
  for run in $runs; do
    for f in "$root/inbox/r-$run"/*.json; do
      [ -f "$f" ] || continue
      rid=${f##*/}
      rid=${rid%.json}
      [ -e "$root/inbox/r-$run/$rid.picked" ] || continue
      jq -e --arg aid "$aid" '.target.approval_id == $aid' "$f" >/dev/null 2>&1 || continue
      answers=$(seam_commit_call "r-$run" "$rid" "$call" need-marker)
      if [ -n "$answers" ]; then
        jq -cn --argjson a "$answers" \
          '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {answers: $a}}}'
        return 0
      fi
    done
  done
}

cmd_scan() {
  local input sid safe now form fout f rid acc runs run marker msid wake info
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  safe=$(seam_safe_sid "$sid")
  now=$(cc_attention__ms) || return 0
  form=$(printf '%s' "$input" | jq -c '.form // null' 2>/dev/null) || return 0
  fout=null
  if [ "$form" != null ]; then
    for f in "$root/inbox/s-$safe"/*.json; do
      [ -f "$f" ] || continue
      rid=${f##*/}
      rid=${rid%.json}
      acc=$(seam_accept form "s-$safe" "$rid" "$sid" "$now" "$input")
      [ -n "$acc" ] || continue
      fout=$(printf '%s' "$acc" | jq -c --arg rid "$rid" '{reply_id: $rid, picks}' 2>/dev/null) || fout=null
      break
    done
  fi
  wake=""
  runs=$(seam_runs "$sid")
  for run in $runs; do
    seam_in_lineage "$run" "$sid" || continue
    for f in "$root/inbox/r-$run"/*.json; do
      [ -f "$f" ] || continue
      rid=${f##*/}
      rid=${rid%.json}
      seam_is_rid "$rid" || continue
      marker="$root/inbox/r-$run/$rid.picked"
      if [ ! -e "$marker" ]; then
        acc=$(seam_accept pickup "r-$run" "$rid" "$sid" "$now" "{}")
        [ -n "$acc" ] || continue
        seam_pick "r-$run" "$rid" "$sid" "$now" || continue
      fi
      info=$(seam_wake_candidate "$run" "$rid" "$sid" "$now")
      [ -n "$info" ] || continue
      wake="$wake$info$nl"
    done
  done
  printf '%s' "$wake" | jq -cs --argjson form "$fout" '{form: $form, wake: .}' 2>/dev/null
}

# seam_wake_candidate <run> <reply_id> <sid> <now> — print
# {run_id, approval_id, reply_id} when the picked envelope is this session's or
# inheritable, not expired, not handled, not applied and not yet woken.
seam_wake_candidate() {
  local run="$1" rid="$2" sid="$3" now="$4" f marker msid aid ev
  f="$root/inbox/r-$run/$rid.json"
  marker="$root/inbox/r-$run/$rid.picked"
  [ -f "$f" ] && [ -f "$marker" ] || return 0
  [ -e "$root/applied/$rid.json" ] && return 0
  msid=$(jq -r 'select(.schema == 1 and (has("woken_at_ms") | not)) | .session_id // empty' "$marker" 2>/dev/null) || return 0
  [ -n "$msid" ] || return 0
  if [ "$msid" != "$sid" ]; then
    seam_in_lineage "$run" "$msid" || return 0
    seam_in_lineage "$run" "$sid" || return 0
  fi
  aid=$(jq -r --arg rid "$rid" --arg run "$run" --argjson now "$now" --arg host "$(cc_attention__host)" '
        select(.schema == 1 and .reply_id == $rid and .host == $host
               and .target.surface == "approval" and .target.run_id == $run
               and (.expires_at_ms | type) == "number" and $now < .expires_at_ms)
        | .target.approval_id // empty' "$f" 2>/dev/null) || return 0
  printf '%s' "$aid" | grep -Eq '^[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}$' || return 0
  ev=$(jq -r '.event_id // empty' "$f" 2>/dev/null) || return 0
  [ -n "$(seam_event "$ev")" ] || return 0
  jq -cn --arg run "$run" --arg aid "$aid" --arg rid "$rid" '{run_id: $run, approval_id: $aid, reply_id: $rid}'
}

cmd_form_pick() {
  local rid="${1:-}" input sid safe now acc
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  safe=$(seam_safe_sid "$sid")
  now=$(cc_attention__ms) || return 0
  acc=$(seam_accept form "s-$safe" "$rid" "$sid" "$now" "$input")
  [ -n "$acc" ] || return 0
  seam_pick "s-$safe" "$rid" "$sid" "$now" || return 0
  printf '%s\n' "$rid"
}

cmd_form_unpick() {
  local rid="${1:-}" input sid safe marker msid
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  seam_is_rid "$rid" || return 0
  safe=$(seam_safe_sid "$sid")
  marker="$root/inbox/s-$safe/$rid.picked"
  [ -f "$marker" ] || return 0
  msid=$(jq -r '.session_id // empty' "$marker" 2>/dev/null) || return 0
  [ "$msid" = "$sid" ] || return 0
  rm -f "$marker"
}

cmd_form_record() {
  local sid="${1:-}" rid="${2:-}" safe f marker msid now hash info cell ev transport sender slotinfo slot
  seam_is_sid "$sid" || return 0
  seam_is_rid "$rid" || return 0
  safe=$(seam_safe_sid "$sid")
  f="$root/inbox/s-$safe/$rid.json"
  marker="$root/inbox/s-$safe/$rid.picked"
  [ -f "$f" ] && [ -f "$marker" ] || return 0
  msid=$(jq -r '.session_id // empty' "$marker" 2>/dev/null) || return 0
  [ "$msid" = "$sid" ] || return 0
  hash=$(seam_sha256) || return 0
  now=$(cc_attention__ms) || return 0
  info=$(jq -r --arg rid "$rid" --arg sid "$sid" --arg host "$(cc_attention__host)" '
         select(.schema == 1 and .reply_id == $rid and .host == $host
                and .target.surface == "question-form" and .target.session_id == $sid
                and (.target.form_id | type) == "string"
                and (.event_id | type) == "string"
                and (.provenance.transport | type) == "string"
                and (.provenance.sender | type) == "string")
         | [.target.form_id, .event_id, .provenance.transport, .provenance.sender] | @tsv' "$f" 2>/dev/null) || return 0
  [ -n "$info" ] || return 0
  IFS='	' read -r cell ev transport sender <<EOF
$info
EOF
  # The submit has already run its prompt hooks, and the return hook marks a
  # submitted bundle handled, so the event is read without the handled filter:
  # for a form envelope the applied record, not the marker, decides the result.
  slotinfo=$(seam_event_record "$ev")
  [ -n "$slotinfo" ] || return 0
  slot=${slotinfo%%	*}
  seam_record "$cell" "$sid" "$rid" "$ev" "$hash" "$transport" "$sender" "$now" || return 0
  cc_attention_handled "$slot" reply-applied
}

cmd_wake_mark() {
  local run="${1:-}" rid="${2:-}" input sid now info d marker json literal
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  seam_is_run "$run" || return 0
  seam_is_rid "$rid" || return 0
  seam_in_lineage "$run" "$sid" || return 0
  now=$(cc_attention__ms) || return 0
  info=$(seam_wake_candidate "$run" "$rid" "$sid" "$now")
  [ -n "$info" ] || return 0
  d="$root/inbox/r-$run"
  marker="$d/$rid.picked"
  json=$(jq -c --argjson now "$now" '. + {woken_at_ms: $now}' "$marker" 2>/dev/null) || return 0
  [ -n "$json" ] || return 0
  if ! printf '%s\n' "$json" > "$d/.$rid.picked.$$.tmp" 2>/dev/null; then
    rm -f "$d/.$rid.picked.$$.tmp"
    return 0
  fi
  mv "$d/.$rid.picked.$$.tmp" "$marker" 2>/dev/null || true
  rm -f "$d/.$rid.picked.$$.tmp"
  [ "$(jq -r '.woken_at_ms // empty' "$marker" 2>/dev/null)" = "$now" ] || return 0
  literal=$(printf '%s' "$info" | jq -r '"<cc-remote-approval run=\(.run_id) id=\(.approval_id)/>"' 2>/dev/null) || return 0
  printf '%s' "$literal" | grep -Eq '^<cc-remote-approval run=[A-Za-z0-9-]{1,64} id=[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}/>$' || return 0
  printf '%s\n' "$literal"
}

# seam_envelope_gone <reply_id> — true when no mailbox holds the envelope.
seam_envelope_gone() {
  local f
  for f in "$root"/inbox/*/"$1".json; do
    [ -e "$f" ] && return 1
  done
  return 0
}

cmd_cleanup() {
  local input sid safe runs run d f rid line
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  seam_is_sid "$sid" || return 0
  safe=$(seam_safe_sid "$sid")
  runs=$(seam_runs "$sid")
  for d in "s-$safe" $(for run in $runs; do printf 'r-%s\n' "$run"; done); do
    for f in "$root/inbox/$d"/*.picked; do
      [ -f "$f" ] || continue
      rid=${f##*/}
      rid=${rid%.picked}
      seam_is_rid "$rid" || continue
      [ -e "$root/inbox/$d/$rid.json" ] || rm -f "$f"
    done
  done
  for f in "$root/applied"/*.json; do
    [ -f "$f" ] || continue
    rid=${f##*/}
    rid=${rid%.json}
    seam_is_rid "$rid" || continue
    seam_envelope_gone "$rid" && rm -f "$f"
  done
  for f in "$state/remote-reply/target"/*; do
    [ -f "$f" ] || continue
    line=""
    IFS= read -r line < "$f" 2>/dev/null || true
    seam_is_rid "$line" || continue
    [ -e "$root/applied/$line.json" ] && continue
    seam_envelope_gone "$line" && rm -f "$f"
  done
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  wait) cmd_wait "$@" ;;
  commit) cmd_commit "$@" ;;
  sat) cmd_sat "$@" ;;
  scan) cmd_scan "$@" ;;
  form-pick) cmd_form_pick "$@" ;;
  form-unpick) cmd_form_unpick "$@" ;;
  form-record) cmd_form_record "$@" ;;
  wake-mark) cmd_wake_mark "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
esac 2>/dev/null || true
exit 0
