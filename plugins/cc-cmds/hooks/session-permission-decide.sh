#!/usr/bin/env bash
#
# session-permission-decide.sh — the decision helper: every read and write of
# the attention spool that applies a remote allow or deny to this session's open
# permission dialog.
#
# The remote-reply mod's `classic.PermissionRequest` hook decides when to call
# this helper and who won the race with the dialog; this script does the rest.
# The decision envelope, its acceptance conditions and its apply order are
# fixed in `plugins/cc-cmds/skills/_common/remote-reply.md` (`## 결정 봉투`); the
# spool, events and handled markers in
# `plugins/cc-cmds/skills/_common/attention-event.md`. The seam
# (`remote-reply/seam.sh`) never applies a decision envelope.
#
# SUBCOMMANDS (the mod in `remote-reply/index.tsx` is the caller):
#   wait                       stdin {session_id, tool_name, tool_input, rejected, tmpdir}
#                              checks once a second and prints `<addr> <reply_id>`
#                              for the first candidate envelope, or ends with no
#                              output when the dialog is gone
#   commit <addr> <reply_id>   stdin the same input (`rejected` is not read);
#                              acceptance, pick-up, applied record, handled
#                              marker; prints {"behavior":…,"sender":…}
#   note <reason> [event id]   stdin the same input; one diagnostic line
#   key                        stdin the same input; prints `<fingerprint>
#                              <normalized key> <state dir> <marker fingerprint or ->`,
#                              for the tests
#
# THE GATE, in order, before any subcommand; a false step ends with rc 0 and no
# output: jq present; `cc_caller_is_router`; the spool root exists — the same
# order as the seam.
#
# THE DIALOG IS FOUND THROUGH THE SEAT'S MARKER. The permission seat
# (`session-permission-notify.sh`) keeps `pending.<fp>` / `open.<fp>` in
# `${TMPDIR:-/tmp}/cc-cmds-permission/<session id>`, each holding one line
# `<fp> <normalized key>`. The mod re-serializes the tool input, so the bytes
# this helper hashes can differ from the seat's; the helper computes the
# normalized key (numbers rewritten by jq arithmetic) from its own input, takes
# the marker with the same key and uses the fingerprint that marker names for
# the slot `cc-cmds-permission-<session id>@<fp>`. The state directory comes
# from the input's `tmpdir` (the mod's TMPDIR), else this process's TMPDIR.
#
# THE SEAM'S OWN BYTES. The handled reading, the target cell claim, the pick-up
# marker and the applied record are written the way the seam writes them, so the
# seam's cleanup removes this helper's files as its own.
#
# A REJECTION writes nothing to the spool or the seat state, prints nothing and
# exits 0; it leaves one line in `decide.log` of the seat state directory —
# `<UTC ISO time> <event id or -> <reason>`, never the envelope or the command.
#
# Compatibility: bash 3.2 (macOS stock) — no associative arrays, no `mapfile`.
set -uo pipefail

if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd "$(dirname "$0")/.." && pwd) || exit 0
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

# The reasons a diagnostic line may carry.
REASONS=" 근거없음-agent표지 표지없음-30초 표지사라짐 사건처리됨 부모소멸 발신자불허 만료 호스트불일치 대상불일치 슬롯불일치 늦은사건 이미적용 꼴위반 확정실패 로컬먼저 중단신호 확정뒤로컬먼저 훅실패 "

# --------------------------------------------------------------------------
# The input and the seat state
# --------------------------------------------------------------------------

input=""
sid=""
tool=""
dir=""

# dp_read_input — read stdin once and set sid, tool and dir. False when the
# session id is outside the seat's alphabet (the seat writes nothing for such a
# session, and its safe_sid would then differ from the id).
dp_read_input() {
  local t
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || return 1
  [[ $sid =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  case "$sid" in
    .|..) return 1 ;;
  esac
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || return 1
  [ -n "$tool" ] || return 1
  t=$(printf '%s' "$input" | jq -r '.tmpdir // empty | strings' 2>/dev/null) || t=""
  [ -n "$t" ] || t="${TMPDIR:-/tmp}"
  dir="${t%/}/cc-cmds-permission/$sid"
  return 0
}

# dp_hash16 <jq filter> — the first 16 hex digits of the sha256 of the filter's
# key-sorted compact output on the input, followed by a newline: the seat's
# fingerprint computation.
dp_hash16() {
  local canon sum
  canon=$(printf '%s' "$input" | jq -cS "$1" 2>/dev/null) || return 1
  [ -n "$canon" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$canon" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s\n' "$canon" | sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  sum="${sum%% *}"
  sum="${sum:0:16}"
  case "$sum" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#sum}" -eq 16 ] || return 1
  printf '%s' "$sum"
}

dp_fingerprint() {
  dp_hash16 '{tool_name, tool_input}'
}

dp_normkey() {
  dp_hash16 '{tool_name, tool_input} | walk(if type == "number" then . + 0 else . end)'
}

# dp_marker_fp <normalized key> — print the fingerprint the seat's marker with
# that key names, or nothing when no `pending.*` / `open.*` marker holds it.
dp_marker_fp() {
  local nk="$1" f fp key
  for f in "$dir"/pending.* "$dir"/open.*; do
    [ -f "$f" ] || continue
    fp="" key=""
    read -r fp key < "$f" 2>/dev/null || true
    [ "$key" = "$nk" ] || continue
    printf '%s' "$fp" | grep -Eq '^[0-9a-f]{16}$' || continue
    case "$f" in
      */pending."$fp"|*/open."$fp") ;;
      *) continue ;;
    esac
    printf '%s' "$fp"
    return 0
  done
}

dp_marker_present() {
  [ -e "$dir/pending.$1" ] || [ -e "$dir/open.$1" ]
}

dp_agent_present() {
  local f
  for f in "$dir"/agent.*; do
    if [ -e "$f" ]; then return 0; fi
  done
  return 1
}

# dp_note <reason> [event id] — one diagnostic line, only into an existing seat
# state directory. Never the envelope, never the tool input.
dp_note() {
  local reason="$1" ev="${2:-}"
  case "$REASONS" in *" $reason "*) ;; *) return 0 ;; esac
  if ! printf '%s' "$ev" | grep -Eq '^[a-z0-9-]{1,32}\.[0-9]+\.[0-9a-f]{8}$'; then ev="-"; fi
  [ -d "$dir" ] || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ev" "$reason" >> "$dir/decide.log" 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# The seam's rules, in the seam's bytes
# --------------------------------------------------------------------------

seam_is_rid() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9-]{1,32}\.[0-9]+\.[0-9a-f]{8}$'
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

# --------------------------------------------------------------------------
# Events
# --------------------------------------------------------------------------

# dp_latest_event <slot> — print `<id>\t<created_at_ms>` of the permission event
# of that slot with the largest created_at_ms (the id's byte order breaks a
# tie), or nothing. Every event file goes to one jq through a pipe, the way the
# handled reading does.
dp_latest_event() {
  local slot="$1" ed="$root/events"
  [ -d "$ed" ] || return 0
  find "$ed" -maxdepth 1 -type f -name '*.json' ! -name '.*' \
      -exec awk 'FNR == 1 && NR > 1 { printf "\n" } { printf "%s ", $0 } END { if (NR > 0) printf "\n" }' {} + 2>/dev/null \
    | jq -nrR --arg slot "$slot" '
        [inputs | (try fromjson catch null)
         | select(type == "object" and .schema == 1 and .kind == "permission"
                  and .slot == $slot and (.created_at_ms | type) == "number"
                  and (.id | type) == "string")]
        | sort_by([.created_at_ms, .id]) | last
        | if . == null then empty else "\(.id)\t\(.created_at_ms)" end' 2>/dev/null
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

cmd_wait() {
  local nk fp slot rejected start now seen=0 latest lid lcreated f rid hs parent limit
  dp_read_input || return 0
  nk=$(dp_normkey) || return 0
  # How long a marker that never showed is waited for; the tests shorten it.
  limit="${CC_CMDS_DECIDE_NO_MARKER_MS:-30000}"
  case "$limit" in ''|*[!0123456789]*) limit=30000 ;; esac
  rejected=$(printf '%s' "$input" | jq -r '(.rejected // [])[] | strings' 2>/dev/null) || rejected=""
  parent="$PPID"
  start=$(cc_attention__ms) || return 0
  while :; do
    fp=$(dp_marker_fp "$nk")
    if [ -z "$fp" ]; then
      if [ "$seen" = 1 ]; then dp_note 표지사라짐; return 0; fi
      now=$(cc_attention__ms) || return 0
      if [ $((now - start)) -ge "$limit" ]; then dp_note 표지없음-30초; return 0; fi
    else
      seen=1
    fi
    if dp_agent_present; then dp_note 근거없음-agent표지; return 0; fi
    if ! kill -0 "$parent" 2>/dev/null \
        || [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != "$parent" ]; then
      dp_note 부모소멸
      return 0
    fi
    if [ -n "$fp" ]; then
      slot="cc-cmds-permission-$sid@$fp"
      latest=$(dp_latest_event "$slot")
      lid=${latest%%	*}
      lcreated=${latest#*	}
      if [ -n "$latest" ]; then
        hs=$(seam_handled_state "$slot" "$lcreated")
        if [ "$hs" = handled ]; then dp_note 사건처리됨 "$lid"; return 0; fi
        for f in "$root/inbox/s-$sid"/*.json; do
          [ -f "$f" ] || continue
          rid=${f##*/}
          rid=${rid%.json}
          seam_is_rid "$rid" || continue
          case "$nl$rejected$nl" in *"$nl$rid$nl"*) continue ;; esac
          seam_is_rid "$lid" || continue
          if jq -e --arg rid "$rid" --arg sid "$sid" --arg lid "$lid" '
               .reply_id == $rid and .kind == "permission-decision"
               and (.target | type) == "object" and .target.session_id == $sid
               and .event_id == $lid' "$f" >/dev/null 2>&1; then
            printf 's-%s %s\n' "$sid" "$rid"
            return 0
          fi
        done
      fi
    fi
    sleep 1
  done
}

# dp_accept <addr> <reply_id> <now> — the path shapes and the nine acceptance
# conditions. Prints `<event id>\t<slot>\t<fp>\t<decision>\t<transport>\t<sender>`
# or nothing, after leaving the reason in the diagnostic log.
dp_accept() {
  local addr="$1" rid="$2" now="$3" env host out ev nk fp slot latest lid lcreated rec ok msid h claim line senders
  [ "$addr" = "s-$sid" ] || { dp_note 꼴위반; return 0; }
  seam_is_rid "$rid" || { dp_note 꼴위반; return 0; }
  env="$root/inbox/$addr/$rid.json"
  [ -f "$env" ] || { dp_note 꼴위반; return 0; }
  host=$(cc_attention__host)
  out=$(jq -r --arg rid "$rid" --arg host "$host" --argjson now "$now" '
    def keys_ok: (keys - ["schema","reply_id","event_id","host","kind","target","decision","provenance","expires_at_ms"]) == [];
    if type != "object" then "꼴위반"
    elif .schema != 1 or .reply_id != $rid or (keys_ok | not)
         or .kind != "permission-decision"
         or (.decision != "allow" and .decision != "deny")
         or ((.event_id | type) != "string")
         or ((.event_id | test("\\A[a-z0-9-]{1,32}\\.[0-9]+\\.[0-9a-f]{8}\\z")) | not)
         or ((.host | type) != "string")
         or ((.provenance | type) != "object")
         or ((.provenance.sender | type) != "string")
         or ((.provenance.transport | type) != "string")
         or ((.expires_at_ms | type) != "number")
         or ((.target | type) != "object")
    then "꼴위반"
    else
      (if .host != $host then "호스트불일치"
       elif ($now < .expires_at_ms | not) then "만료"
       else "ok" end) as $v
      | [$v, .event_id, .decision, .provenance.transport, .provenance.sender] | join("\t")
    end' "$env" 2>/dev/null) || { dp_note 꼴위반; return 0; }
  case "$out" in
    ok"	"*) ;;
    *"	"*) dp_note "${out%%	*}" "$(printf '%s' "$out" | cut -f2)"; return 0 ;;
    *) dp_note "${out:-꼴위반}"; return 0 ;;
  esac
  ev=$(printf '%s' "$out" | cut -f2)
  case "$ev" in
    ''|.*|*/*) dp_note 꼴위반; return 0 ;;
  esac
  # The event id starts with the envelope's host.
  case "$ev" in
    "$host".*) ;;
    *) dp_note 호스트불일치 "$ev"; return 0 ;;
  esac

  # 8 and 9 — the seat's marker of this call, and no running subagent.
  nk=$(dp_normkey) || { dp_note 꼴위반 "$ev"; return 0; }
  fp=$(dp_marker_fp "$nk")
  if [ -z "$fp" ]; then dp_note 표지사라짐 "$ev"; return 0; fi
  if dp_agent_present; then dp_note 근거없음-agent표지 "$ev"; return 0; fi
  slot="cc-cmds-permission-$sid@$fp"

  # 2 — the event: schema 1, a permission event that accepts a decision, this
  # call's slot, the latest event of the slot, not handled.
  rec="$root/events/$ev.json"
  [ -f "$rec" ] || { dp_note 슬롯불일치 "$ev"; return 0; }
  ok=$(jq -r --arg slot "$slot" '
    if .schema != 1 or .kind != "permission"
       or (((.accepts // []) | type) != "array")
       or (any(.accepts[]; . == "permission-decision") | not)
    then "꼴위반"
    elif .slot != $slot then "슬롯불일치"
    else "ok" end' "$rec" 2>/dev/null) || ok="꼴위반"
  [ "$ok" = ok ] || { dp_note "$ok" "$ev"; return 0; }
  latest=$(dp_latest_event "$slot")
  lid=${latest%%	*}
  lcreated=${latest#*	}
  [ -n "$latest" ] && [ "$lid" = "$ev" ] || { dp_note 늦은사건 "$ev"; return 0; }
  [ "$(seam_handled_state "$slot" "$lcreated")" = open ] || { dp_note 사건처리됨 "$ev"; return 0; }

  # 3 — the target is the event's reply, this session and this tool.
  ok=$(jq -rn --slurpfile e "$env" --slurpfile r "$rec" --arg sid "$sid" --arg tool "$tool" '
    ($e[0].target) as $t
    | if $t == $r[0].reply
         and ($t | type) == "object" and $t.surface == "permission"
         and $t.session_id == $sid and $t.tool_name == $tool
      then "ok" else "대상불일치" end' 2>/dev/null) || ok="대상불일치"
  [ "$ok" = ok ] || { dp_note 대상불일치 "$ev"; return 0; }

  # 6 — not applied yet; the pick-up marker is this session's; the target cell
  # (the event id) is free or this envelope's.
  [ -e "$root/applied/$rid.json" ] && { dp_note 이미적용 "$ev"; return 0; }
  if [ -e "$root/inbox/$addr/$rid.picked" ]; then
    msid=$(jq -r 'select(.schema == 1) | .session_id // empty' "$root/inbox/$addr/$rid.picked" 2>/dev/null) || msid=""
    [ "$msid" = "$sid" ] || { dp_note 이미적용 "$ev"; return 0; }
  fi
  h=$(printf '%s\037%s' "$root" "$ev" | seam_sha256) || { dp_note 확정실패 "$ev"; return 0; }
  claim="$state/remote-reply/target/$h"
  if [ -e "$claim" ]; then
    line=""
    IFS= read -r line < "$claim" 2>/dev/null || line=""
    [ "$line" = "$rid" ] || { dp_note 이미적용 "$ev"; return 0; }
  fi

  # 7 — the sender is registered for a permission decision.
  senders="${HOME:-}/.config/cc-cmds/remote-senders.json"
  [ -f "$senders" ] || { dp_note 발신자불허 "$ev"; return 0; }
  ok=$(jq -r --arg s "$(printf '%s' "$out" | cut -f5)" '
         select(.schema == 1 and (.senders | type) == "array")
         | [ .senders[] | select(type == "object" and .id == $s
                                 and ((.capabilities // []) | type) == "array"
                                 and any(.capabilities[]; . == "permission-decision")) ]
         | length' "$senders" 2>/dev/null) || ok=""
  case "$ok" in ''|0) dp_note 발신자불허 "$ev"; return 0 ;; esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ev" "$slot" "$fp" \
    "$(printf '%s' "$out" | cut -f3)" "$(printf '%s' "$out" | cut -f4)" "$(printf '%s' "$out" | cut -f5)"
}

cmd_commit() {
  local addr="${1:-}" rid="${2:-}" now acc ev slot fp decision transport sender hash
  dp_read_input || return 0
  now=$(cc_attention__ms) || return 0
  acc=$(dp_accept "$addr" "$rid" "$now")
  [ -n "$acc" ] || return 0
  ev=$(printf '%s' "$acc" | cut -f1)
  slot=$(printf '%s' "$acc" | cut -f2)
  fp=$(printf '%s' "$acc" | cut -f3)
  decision=$(printf '%s' "$acc" | cut -f4)
  transport=$(printf '%s' "$acc" | cut -f5)
  sender=$(printf '%s' "$acc" | cut -f6)
  hash=$(printf '%s' "$decision" | seam_sha256) || { dp_note 확정실패 "$ev"; return 0; }
  seam_pick "$addr" "$rid" "$sid" "$now" || { dp_note 확정실패 "$ev"; return 0; }
  seam_record "$ev" "$sid" "$rid" "$ev" "$hash" "$transport" "$sender" "$now" || { dp_note 확정실패 "$ev"; return 0; }
  cc_attention_handled "$slot" reply-applied
  if [ "$decision" = deny ]; then
    rm -f "$dir/pending.$fp" "$dir/open.$fp" 2>/dev/null
  fi
  jq -cn --arg b "$decision" --arg s "$sender" '{behavior: $b, sender: $s}'
}

cmd_note() {
  local reason="${1:-}" ev="${2:-}"
  dp_read_input || return 0
  dp_note "$reason" "$ev"
}

cmd_key() {
  local fp nk mfp
  dp_read_input || return 0
  fp=$(dp_fingerprint) || return 0
  nk=$(dp_normkey) || return 0
  mfp=$(dp_marker_fp "$nk")
  printf '%s %s %s %s\n' "$fp" "$nk" "$dir" "${mfp:--}"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  wait) cmd_wait "$@" ;;
  commit) cmd_commit "$@" ;;
  note) cmd_note "$@" ;;
  key) cmd_key "$@" ;;
esac 2>/dev/null || true
exit 0
