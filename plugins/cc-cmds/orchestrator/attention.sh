#!/usr/bin/env bash
#
# attention.sh — the attention tap: the two functions a seat calls to leave a
# record of a banner it has already decided to raise, and of a banner slot it
# has cleared, in the machine-wide attention spool.
#
#   cc_attention_emit <token> <slot> <title> <body> [<detail-json-file>]
#   cc_attention_handled <slot> <cause> [prefix]
#
# The record shapes, the token and kind table, the cause table and the reader
# rules live in `plugins/cc-cmds/skills/_common/attention-event.md`; that file
# is the one source of the tables, and the schema lint and the test suite read
# them from it.
#
# THIS FILE IS SOURCED. Its top level holds function definitions only: sourcing
# it changes no shell option, trap, umask, working directory or variable, and
# runs no command that can fail. Bash 3.2 syntax only.
#
# NEITHER FUNCTION CAN CHANGE ITS CALLER. Each body runs in one subshell wrapped
# in `</dev/null >/dev/null 2>&1 || true`, and the function then returns 0. A
# failing command or an unset variable inside ends the subshell only, and the
# caller's exit status, stdout, stderr and ERR trap are untouched even under
# `set -euo pipefail` and `set -E`. Inside the subshell the `||` context turns
# errexit off, so every step whose failure would poison the next one carries
# its own `|| exit 0`, and every variable is read as `${name:-}`.
#
# A FAILURE WRITES NOTHING. A missing spool root, a missing tool (`jq`, perl's
# Time::HiRes, /dev/urandom), malformed input or a refused attachment ends the
# call without a file. The functions never wait on the relay, never read the
# seat state, the presence state or a router verdict, and there is no switch
# that turns the remote copy off: the caller's seat decision is inherited as is.
#
# THE SPOOL ROOT is `$CC_CMDS_ATTENTION_ROOT` when it is non-empty — a test
# seat, set by the test suites only — and `$HOME/.local/state/cc-cmds/attention`
# otherwise. The configuration directory and the XDG values play no part, so a
# lane session and a borrowed session land in the same spool. The root is never
# created: when it is not a directory, nothing is written. The subdirectory a
# call writes into (`events/` or `handled/`) is created on first use with
# `umask 077` and `mkdir -m 700`, and a lost race to create it is not a failure.
#
# A FILE IS CREATED ONCE. The record goes to the dot file `.<id>.<pid>.tmp` in
# the same directory and is moved to `<id>.json` with `mv -n`, whose exit status
# is not read (macOS returns 0 when the target exists and the move did not
# happen); the temporary file is then removed on every path. A second creation
# of the same id leaves the first file as it was.

# --------------------------------------------------------------------------
# Internal helpers. Each is called from inside a function's subshell only.
# --------------------------------------------------------------------------

cc_attention__root() {
  # Print the spool root, or return 1 when there is none to write into.
  local root="${CC_CMDS_ATTENTION_ROOT:-}"
  if [ -z "$root" ]; then
    [ -n "${HOME:-}" ] || return 1
    root="$HOME/.local/state/cc-cmds/attention"
  fi
  [ -d "$root" ] || return 1
  printf '%s' "$root"
}

cc_attention__host() {
  # Print the host id: the first line of `$HOME/.config/cc-cmds/host-id` when it
  # is 1 to 32 characters of lowercase letters, digits and `-`, and `local`
  # otherwise — a missing, empty, unreadable or malformed file alike. A line
  # without a trailing newline is still the first line; a trailing carriage
  # return is outside the alphabet. Never fails, so no record is dropped here.
  local f line=""
  if [ -n "${HOME:-}" ]; then
    f="$HOME/.config/cc-cmds/host-id"
    if [ -f "$f" ] && [ -r "$f" ]; then
      IFS= read -r line < "$f" || true
    fi
  fi
  # The class is spelled out letter by letter: a range such as `a-z` follows
  # the collation order in some locales and would admit uppercase letters.
  case "$line" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) line=local ;;
  esac
  [ "${#line}" -le 32 ] || line=local
  printf '%s' "$line"
}

cc_attention__ms() {
  # Print the current time in epoch milliseconds.
  local ms
  ms=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000') || return 1
  case "$ms" in
    ''|*[!0123456789]*) return 1 ;;
  esac
  printf '%s' "$ms"
}

cc_attention__hex() {
  # Print 8 random lowercase hex digits.
  local hex
  hex=$(od -An -N4 -tx1 /dev/urandom) || return 1
  hex=$(printf '%s' "$hex" | tr -d ' \n') || return 1
  case "$hex" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#hex}" -eq 8 ] || return 1
  printf '%s' "$hex"
}

cc_attention__write() {
  # cc_attention__write <root> <subdir> <id> <json> — create <root>/<subdir>/<id>.json
  # once, through a dot file in the same directory and `mv -n`.
  local d="$1/$2" id="$3" json="$4" tmp
  umask 077
  if [ ! -d "$d" ]; then
    mkdir -m 700 "$d" || [ -d "$d" ] || return 1
  fi
  tmp="$d/.$id.$$.tmp"
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -n "$tmp" "$d/$id.json" || true
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# Public functions
# --------------------------------------------------------------------------

cc_attention_emit() {
  # cc_attention_emit <token> <slot> <title> <body> [<detail-json-file>]
  #
  # Leave one event record in `events/`. The optional fifth argument is the
  # funnel attachment `{kind, actionable, reply, body?}`: a regular file owned
  # by the current user, not a symbolic link, whose name begins with
  # `cc-attention-detail.`. It is read and removed before anything else, so it
  # is gone even when the spool root is missing; a non-empty argument that
  # fails that check is neither read nor removed and the call ends there.
  (
    token="${1:-}"
    slot="${2:-}"
    title="${3:-}"
    body_arg="${4:-}"
    f="${5:-}"
    detail=""
    has_detail=0

    # 1. The attachment, before the root check.
    if [ -n "$f" ]; then
      case "${f##*/}" in
        cc-attention-detail.*) ;;
        *) exit 0 ;;
      esac
      if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then
        :
      else
        exit 0
      fi
      detail=$(cat "$f")
      read_rc=$?
      rm -f "$f"
      [ "$read_rc" -eq 0 ] || exit 0
      has_detail=1
    fi

    # 2. The spool root.
    root=$(cc_attention__root) || exit 0

    # 3. The token, mapped to the kinds it can raise. A token outside this
    #    list raises no event.
    case "$token" in
      session-ask) kinds="auq question-form" ;;
      session-turn) kinds="turn" ;;
      answer) kinds="approval" ;;
      ended) kinds="run-end" ;;
      rekick|resume) kinds="run-stop" ;;
      hands) kinds="run-blocked" ;;
      active-notify) kinds="active-notify" ;;
      permission) kinds="permission" ;;
      *) exit 0 ;;
    esac

    # 4. The slot.
    [ -n "$slot" ] || exit 0

    # 5. The host id, and the two values every new id needs.
    host=$(cc_attention__host)
    command -v jq >/dev/null 2>&1 || exit 0
    ms=$(cc_attention__ms) || exit 0
    hex=$(cc_attention__hex) || exit 0

    # 6-10. Kind, reply, actionable and accepts, id, body and origin, in one
    #    jq call. The program prints the id and the record on two lines, or
    #    nothing when the call must not leave an event.
    prog='
      def nestr: type == "string" and length > 0;
      def has_str($k): has($k) and (.[$k] | type == "string");
      def has_nestr($k): has($k) and (.[$k] | nestr);
      def labels_ok: type == "array" and all(.[]; type == "object" and has_str("label"));
      def reply_ok($kind):
        type == "object" and .surface == $kind and
        (if $kind == "auq" then
           has_nestr("session_id") and has_nestr("tool_use_id")
           and (.questions | type == "array")
           and all(.questions[]; type == "object" and has_str("question") and has_str("header")
                   and (.multi_select | type == "boolean") and (.options | labels_ok))
         elif $kind == "question-form" then
           has_nestr("session_id") and has_nestr("form_id")
           and (.questions | type == "array")
           and all(.questions[]; type == "object" and has_nestr("id") and has_str("question")
                   and (.options | labels_ok))
         elif $kind == "approval" then
           has_str("run_id") and has_str("approval_id") and has_str("question")
           and (.options | type == "array") and all(.options[]; type == "string")
         elif $kind == "permission" then
           has_nestr("session_id") and has_nestr("tool_name") and has_str("input_summary")
         else false end);
      def nn: if . == "" then null else . end;

      (if $has == "1" then (try ($detail | fromjson) catch null) else null end) as $d
      | if $has == "1" and ($d | type) != "object" then empty else . end
      | ($kinds | split(" ")) as $ks
      | (if $has == "1" then $d.kind else $ks[0] end) as $kind
      | if ($kind | type) != "string" or (any($ks[]; . == $kind) | not) then empty else . end
      | (if $d != null and ($d.reply | reply_ok($kind)) then $d.reply else null end) as $reply
      | (if (($d // {}) | .actionable) == true and $reply != null then
           (if $kind == "auq" then
              ($reply.questions | length) >= 1
              and all($reply.questions[]; (.options | length) >= 1)
            elif $kind == "question-form" then
              all($reply.questions[]; (.id | nestr) and (.options | length) >= 1)
            elif $kind == "approval" then
              ($reply.options | length) >= 1
            else false end)
         else false end) as $act
      | (if $d != null and ($d.body | nestr) then $d.body else $body end) as $b
      | (if $kind == "approval" then
           if $d == null or (($d.body | nestr) | not) then empty
           elif $reply != null and $reply.question != $d.body then empty
           else
             (if $reply != null then {r: $reply.run_id, a: $reply.approval_id}
              else ("cc-cmds-autopilot-" + $run + "-") as $p
                   | {r: $run, a: (if ($slot | startswith($p)) then $slot[($p | length):] else "" end)}
              end) as $ids
             | if ($ids.r | test("\\A[A-Za-z0-9-]{1,64}\\z"))
                  and ($ids.a | test("\\A[A-Za-z0-9_-]{1,55}-[0-9a-f]{8}\\z"))
                  and $slot == ("cc-cmds-autopilot-" + $ids.r + "-" + $ids.a)
               then $host + ".appr." + $ids.r + "." + $ids.a
               else empty end
           end
         else $host + "." + $ms + "." + $hex end) as $id
      | (if ($repo | test("\\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\\z"))
            and (($repo | split("/") | .[1]) as $n | $n != "." and $n != "..")
         then $repo else null end) as $origin_repo
      | $id,
        ({schema: 1, id: $id, host: $host, created_at_ms: ($ms | tonumber),
          kind: $kind, token: $token, slot: $slot, title: $title, body: $b,
          actionable: $act, accepts: (if $act then ["option"] else [] end),
          origin: {
            session_id: ((if $reply != null and ($reply.session_id | nestr) then $reply.session_id else $sid end) | nn),
            run_id: ((if $reply != null and ($reply.run_id | nestr) then $reply.run_id else $run end) | nn),
            config_dir: $cfg,
            cwd: ($cwd | nn),
            repo: $origin_repo,
            tmux_pane: ($pane | nn)
          },
          reply: $reply} | tojson)
    '
    out=$(jq -rn \
      --arg has "$has_detail" \
      --arg detail "$detail" \
      --arg kinds "$kinds" \
      --arg token "$token" \
      --arg slot "$slot" \
      --arg title "$title" \
      --arg body "$body_arg" \
      --arg host "$host" \
      --arg ms "$ms" \
      --arg hex "$hex" \
      --arg sid "${CC_NOTIFY_SESSION_ID:-}" \
      --arg run "${RUN_ID:-}" \
      --arg cfg "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}" \
      --arg cwd "${PWD:-}" \
      --arg repo "${CC_NOTIFY_REPO:-}" \
      --arg pane "${TMUX_PANE:-}" \
      "$prog") || exit 0
    nl='
'
    case "$out" in
      *"$nl"*) ;;
      *) exit 0 ;;
    esac
    id=${out%%"$nl"*}
    json=${out#*"$nl"}
    case "$id" in
      ''|.*|*/*) exit 0 ;;
    esac
    [ -n "$json" ] || exit 0

    # 11. Create the file.
    cc_attention__write "$root" events "$id" "$json" || exit 0
  ) </dev/null >/dev/null 2>&1 || true
  return 0
}

cc_attention_handled() {
  # cc_attention_handled <slot> <cause> [prefix]
  #
  # Leave one handled marker in `handled/`. The cause is chosen by the caller
  # and must be one of the six; there is no default. The third argument is
  # empty (an exact marker) or the word `prefix` (a prefix marker, whose slot
  # must end with `@`); anything else writes nothing.
  (
    slot="${1:-}"
    cause="${2:-}"
    p="${3:-}"
    [ -n "$slot" ] || exit 0
    case "$cause" in
      clear|return|approval-closed|dismiss|reply-applied|permission-settled) ;;
      *) exit 0 ;;
    esac
    case "$p" in
      '') prefix=false ;;
      prefix) prefix=true ;;
      *) exit 0 ;;
    esac
    if [ "$prefix" = true ]; then
      case "$slot" in
        *@) ;;
        *) exit 0 ;;
      esac
    fi

    root=$(cc_attention__root) || exit 0
    host=$(cc_attention__host)
    command -v jq >/dev/null 2>&1 || exit 0
    ms=$(cc_attention__ms) || exit 0
    hex=$(cc_attention__hex) || exit 0
    id="$host.$ms.$hex"
    json=$(jq -cn \
      --arg id "$id" \
      --arg host "$host" \
      --arg ms "$ms" \
      --arg slot "$slot" \
      --arg prefix "$prefix" \
      --arg cause "$cause" \
      '{schema: 1, id: $id, host: $host, at_ms: ($ms | tonumber), slot: $slot,
        prefix: ($prefix == "true"), cause: $cause}') || exit 0
    [ -n "$json" ] || exit 0
    cc_attention__write "$root" handled "$id" "$json" || exit 0
  ) </dev/null >/dev/null 2>&1 || true
  return 0
}
