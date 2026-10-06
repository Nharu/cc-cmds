#!/usr/bin/env bash
#
# notify-focus.sh — what a banner click runs, and the two helpers that build the
# value a banner carries.
#
#   exec-arg [--seat-file <file>]    print the `-execute` value for one banner
#   record <RUN_DIR>                 write <RUN_DIR>/notify.seat, once
#   focus <socket> <pid> <%pane>     bring that tmux pane forward in iTerm2
#
# THE VALUE IS ALWAYS ONE OF TWO SHAPES: `:` or
# `/bin/bash '<this file>' focus '<socket>' '<pid>' '<%pane>'`. Every line that
# raises a banner carries `-execute` with one of them, and when a value cannot be
# built it falls back to `:` — there is no path that drops `-execute`, because a
# banner without it hands the click to the notifier's own default, which moves
# focus to an application nobody asked for.
#
# WHY ONE FILE FOR THREE JOBS. The click process inherits nothing from whoever
# raised the banner — not TMUX, not PATH, not the working directory — so the
# location and this file's absolute path have to be baked into the value. The
# three banner families share this one file so that the rule deciding where a
# click lands exists once.
#
# EVERY PATH EXITS 0. `exec-arg` reports failure only by printing `:`, `record`
# by writing nothing, and `focus` by changing nothing. A banner sits on the
# critical path of the caller, and a click has nobody to report to.
#
# NOTHING IS CHANGED UNTIL EVERYTHING IS DECIDED. `focus` runs every check that
# can say "no" — the pane is alive on the same server, a client is attached to
# its session, iTerm2 shows that client — before it selects anything in tmux or
# in iTerm2. A click that cannot be resolved leaves the screen as it was.
#
# Seams: CC_CMDS_NOTIFY_FOCUS_TMUX names the tmux binary, and
# CC_CMDS_NOTIFY_FOCUS_ITERM names a program taking `find` / `show <wid> <sid>`
# in place of the two AppleScript calls. CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND
# skips the Homebrew PATH prepend, the same rule the emitter follows.
#
# Compatibility: bash 3.2 (macOS stock) — no associative arrays, no `mapfile`.

TAB=$(printf '\t')

# A value lands inside single quotes in a string `/bin/sh -c` runs, and the
# notifier reads its arguments through a parser that treats `-group ` as a flag.
# So a path carrying a quote, a backslash, a control character or that token is
# refused rather than escaped: refusing is the one rule that can be checked by
# looking at the value.
nf_bad_text() {
  case "$1" in
    '') return 0 ;;
    *\'*|*\\*|*'-group '*) return 0 ;;
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

nf_is_num() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

nf_is_pane() {
  case "$1" in
    %*) nf_is_num "${1#%}" ;;
    *) return 1 ;;
  esac
}

# `<prefix><digits>` — tmux session and window ids.
nf_is_id() {
  case "$2" in
    "$1"*) nf_is_num "${2#"$1"}" ;;
    *) return 1 ;;
  esac
}

# This file's own path, canonical. BASH_SOURCE carries whatever spelling the
# caller used — relative, or with `..` in it — and the click runs from another
# working directory, so the spelling cannot be baked in as it came.
nf_self() {
  local d
  d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "${BASH_SOURCE[0]##*/}"
}

# Read socket, pid and pane from the environment into NF_SOCK/NF_PID/NF_PANE.
# TMUX is `<socket>,<server pid>,<session>` and is taken apart from the right,
# because a socket path may itself carry a comma.
nf_from_env() {
  local t
  NF_SOCK=""; NF_PID=""; NF_PANE="${TMUX_PANE:-}"
  case "${TMUX:-}" in
    *,*,*) : ;;
    *) return 1 ;;
  esac
  t=${TMUX%,*}
  NF_PID=${t##*,}
  NF_SOCK=${t%,*}
  nf_valid
}

# The same three from a seat record: one line, three tab-separated fields.
nf_from_file() {
  local line="" rest
  NF_SOCK=""; NF_PID=""; NF_PANE=""
  [ -f "$1" ] || return 1
  IFS= read -r line < "$1" 2>/dev/null || [ -n "$line" ] || return 1
  case "$line" in
    *"$TAB"*"$TAB"*) : ;;
    *) return 1 ;;
  esac
  NF_SOCK=${line%%"$TAB"*}
  rest=${line#*"$TAB"}
  NF_PID=${rest%%"$TAB"*}
  NF_PANE=${rest#*"$TAB"}
  case "$NF_PANE" in
    *"$TAB"*) return 1 ;;
  esac
  nf_valid
}

nf_valid() {
  nf_is_num "$NF_PID" || return 1
  nf_is_pane "$NF_PANE" || return 1
  nf_bad_text "$NF_SOCK" && return 1
  return 0
}

nf_exec_arg() {
  local self
  if [ "${1:-}" = "--seat-file" ]; then
    nf_from_file "${2:-}" || { printf ':\n'; return 0; }
  else
    nf_from_env || { printf ':\n'; return 0; }
  fi
  self=$(nf_self) || { printf ':\n'; return 0; }
  case "$self" in
    /*) : ;;
    *) printf ':\n'; return 0 ;;
  esac
  if nf_bad_text "$self"; then printf ':\n'; return 0; fi
  printf "/bin/bash '%s' focus '%s' '%s' '%s'\n" "$self" "$NF_SOCK" "$NF_PID" "$NF_PANE"
  return 0
}

# WRITE ONCE, AND ONLY A LINE THAT PASSED. A broken first line would pin every
# run banner of this run to `:` for good, so a refused environment writes
# nothing and leaves the next caller — the watcher's next pass, the seat's next
# call — free to try again. A record that exists is never replaced: a resumed
# seat or an old watcher must not move the target the run was kicked off from.
nf_record() {
  local dir="${1:-}" f tmp
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  nf_from_env || return 0
  f="$dir/notify.seat"
  [ -e "$f" ] && return 0
  tmp="$f.tmp.$$"
  printf '%s\t%s\t%s\n' "$NF_SOCK" "$NF_PID" "$NF_PANE" > "$tmp" \
    || { rm -f "$tmp"; return 0; }
  # `mv -n` publishes without replacing; the loser of a race removes its own
  # temporary file, which is a no-op for the winner.
  mv -n "$tmp" "$f" || true
  rm -f "$tmp" || true
  return 0
}

# The read-only dump. Three session variables are read each under its own
# `try`, so a session outside tmux integration yields empty fields rather than
# an error that would end the whole dump. No argument reaches this text: the
# pane number, the session name and the tty stay in the shell.
nf_find() {
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    "$CC_CMDS_NOTIFY_FOCUS_ITERM" find
    return
  fi
  /usr/bin/osascript \
    -e 'tell application id "com.googlecode.iterm2"' \
    -e 'set o to ""' \
    -e 'repeat with w in windows' \
    -e 'repeat with t in tabs of w' \
    -e 'repeat with s in sessions of t' \
    -e 'set y to ""' \
    -e 'set r to ""' \
    -e 'set p to ""' \
    -e 'set c to ""' \
    -e 'try' \
    -e 'set y to (tty of s)' \
    -e 'end try' \
    -e 'try' \
    -e 'tell s to set r to (variable named "tmuxRole")' \
    -e 'end try' \
    -e 'try' \
    -e 'tell s to set p to (variable named "tmuxWindowPane")' \
    -e 'end try' \
    -e 'try' \
    -e 'tell s to set c to (variable named "tmuxClientName")' \
    -e 'end try' \
    -e 'if y is missing value then set y to ""' \
    -e 'if r is missing value then set r to ""' \
    -e 'if p is missing value then set p to ""' \
    -e 'if c is missing value then set c to ""' \
    -e 'set o to o & (id of w) & tab & (index of w) & tab & (id of s) & tab & y & tab & r & tab & p & tab & c & linefeed' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'return o' \
    -e 'end tell'
}

# Select window, tab and session, then bring the application forward. The two
# values arrive as argv and are compared, never spliced into the script.
nf_show() {
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    "$CC_CMDS_NOTIFY_FOCUS_ITERM" show "$1" "$2"
    return
  fi
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set wid to (item 1 of argv) as integer' \
    -e 'set sid to item 2 of argv' \
    -e 'tell application id "com.googlecode.iterm2"' \
    -e 'set w to (first window whose id is wid)' \
    -e 'repeat with t in tabs of w' \
    -e 'repeat with s in sessions of t' \
    -e 'if (id of s) is sid then' \
    -e 'select w' \
    -e 'select t' \
    -e 'select s' \
    -e 'activate' \
    -e 'return "ok"' \
    -e 'end if' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'end tell' \
    -e 'error "session not found"' \
    -e 'end run' \
    "$1" "$2"
}

nf_focus() {
  local sock="${1:-}" rpid="${2:-}" pane="${3:-}"
  local N tm out p sid wid pid2 sname
  local clients line mode r csid act tty nc=0 cmax=-1 tmax=-1 tlist=""
  local dump row x f_wid f_idx f_sid f_tty f_role f_wp f_cn
  local nb=0 b_wid="" b_sid="" b_idx="" c_wid="" c_sid="" t_wid="" t_sid=""
  local ttys tt order m re_ctty re_dtty tlist_hit="" wid_x="" sid_x=""

  # 1. Preparation. Nothing this process prints has a reader.
  exec >/dev/null 2>&1
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
  PATH="$PATH:/usr/bin:/bin"
  export PATH
  NF_SOCK="$sock"; NF_PID="$rpid"; NF_PANE="$pane"
  nf_valid || exit 0
  N=${pane#%}

  # 2. tmux.
  tm="${CC_CMDS_NOTIFY_FOCUS_TMUX:-}"
  [ -n "$tm" ] || tm=$(command -v tmux) || exit 0
  [ -n "$tm" ] && [ -x "$tm" ] || exit 0

  # 3. The pane is alive, on the server that was recorded. A pane that does not
  # exist still answers with exit 0 and the server pid filled in, so existence
  # is the pane id coming back verbatim, not the exit code.
  out=$("$tm" -S "$sock" display-message -p -t "$pane" \
    '#{pid}|#{session_id}|#{window_id}|#{pane_id}|#{session_name}') || exit 0
  case "$out" in
    *[[:cntrl:]]*) exit 0 ;;
  esac
  IFS='|' read -r p sid wid pid2 sname <<EOF
$out
EOF
  [ "$pid2" = "$pane" ] || exit 0
  nf_is_id '$' "$sid" || exit 0
  nf_is_id '@' "$wid" || exit 0
  [ "$p" = "$rpid" ] || exit 0
  [ -n "$sname" ] || exit 0

  # 4. Clients attached to that session — and only those. A client watching
  # another session is never pulled over: that would change what a person is
  # looking at. Control-mode clients are counted; the tty of a normal client is
  # kept with its activity so the most recent one is tried first.
  clients=$("$tm" -S "$sock" list-clients \
    -F '#{client_control_mode}|#{session_id}|#{client_activity}|#{client_tty}') || exit 0
  re_ctty='^/dev/[A-Za-z0-9]+(/[0-9]+)?$'
  while IFS= read -r line; do
    case "$line" in
      *'|'*'|'*'|'*) : ;;
      *) continue ;;
    esac
    mode=${line%%|*}; r=${line#*|}
    csid=${r%%|*};    r=${r#*|}
    act=${r%%|*};     tty=${r#*|}
    [ "$csid" = "$sid" ] || continue
    nf_is_num "$act" || continue
    case "$mode" in
      1)
        nc=$((nc + 1))
        [ "$act" -gt "$cmax" ] && cmax=$act
        ;;
      0)
        [[ "$tty" =~ $re_ctty ]] || continue
        tlist="$tlist$act $tty
"
        [ "$act" -gt "$tmax" ] && tmax=$act
        ;;
    esac
  done <<EOF
$clients
EOF
  [ "$nc" -gt 0 ] || [ -n "$tlist" ] || exit 0
  ttys=$(printf '%s' "$tlist" | sort -k1,1nr | while read -r _ tt; do printf '%s\n' "${tt#/dev/}"; done)

  # 5. iTerm2 is already running — a click must not launch it.
  if [ -z "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    pgrep -x iTerm2 || exit 0
  fi

  # 6. FIND. The first click raises the automation prompt here, and a refusal
  # ends the click before tmux is touched.
  dump=$(nf_find) || exit 0
  [ -n "$dump" ] || exit 0
  re_dtty='^(/dev/)?[A-Za-z0-9]+(/[0-9]+)?$'
  while IFS= read -r row; do
    # Tabs are IFS whitespace, so `read` would fold runs of them and drop
    # trailing empty fields — exactly the shape of a row outside tmux
    # integration. The fields are counted and cut by hand instead.
    x=${row//[!$TAB]/}
    [ "${#x}" -eq 6 ] || continue
    case "${row//$TAB/}" in
      *[[:cntrl:]]*) continue ;;
    esac
    f_wid=${row%%"$TAB"*};  r=${row#*"$TAB"}
    f_idx=${r%%"$TAB"*};    r=${r#*"$TAB"}
    f_sid=${r%%"$TAB"*};    r=${r#*"$TAB"}
    f_tty=${r%%"$TAB"*};    r=${r#*"$TAB"}
    f_role=${r%%"$TAB"*};   r=${r#*"$TAB"}
    f_wp=${r%%"$TAB"*};     f_cn=${r#*"$TAB"}
    nf_is_num "$f_wid" || continue
    nf_is_num "$f_idx" || continue
    case "$f_sid" in
      ''|*[!A-Za-z0-9-]*) continue ;;
    esac
    if [ -n "$f_tty" ]; then
      [[ "$f_tty" =~ $re_dtty ]] || continue
    fi

    # (b) control mode: an integration session drawing this pane number for a
    # session of this name. A gateway row is never chosen, whatever its tty.
    if [ "$nc" -gt 0 ] && [ "$f_role" = "client" ] && [ "$f_wp" = "$N" ]; then
      if [ -z "$f_cn" ] || [ "$f_cn" = "$sname" ]; then
        nb=$((nb + 1))
        if [ -z "$b_idx" ] || [ "$f_idx" -lt "$b_idx" ]; then
          b_idx=$f_idx; b_wid=$f_wid; b_sid=$f_sid
        fi
      fi
    fi

    # (c) normal mode: the session owning the most recently active client tty.
    # Rows are kept per tty, and the first match in activity order wins below.
    if [ -n "$ttys" ] && [ -z "$f_role" ] && [ -n "$f_tty" ]; then
      tt=${f_tty#/dev/}
      while IFS= read -r x; do
        if [ "$x" = "$tt" ]; then
          tlist_hit="$tlist_hit$tt$TAB$f_wid$TAB$f_sid
"
          break
        fi
      done <<EOF
$ttys
EOF
    fi
  done <<EOF
$dump
EOF

  # (d) A tie among control rows is broken by the frontmost window only while
  # the rows fit inside the number of control clients — each such client draws
  # the pane once, so more rows than clients means another server's session of
  # the same name is mixed in, and the dump cannot tell which.
  if [ "$nb" -ge 1 ] && [ "$nb" -le "$nc" ]; then
    c_wid=$b_wid; c_sid=$b_sid
  fi
  if [ -n "$tlist_hit" ]; then
    while IFS= read -r tt; do
      [ -n "$tt" ] || continue
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        if [ "${row%%"$TAB"*}" = "$tt" ]; then
          r=${row#*"$TAB"}
          t_wid=${r%%"$TAB"*}; t_sid=${r#*"$TAB"}
          break 2
        fi
      done <<EOF
$tlist_hit
EOF
    done <<EOF
$ttys
EOF
  fi

  # (a) The mode with the more recent activity is asked first; a tie goes to
  # control mode. The other mode answers only when the first has nothing.
  if [ "$cmax" -ge "$tmax" ]; then order="c t"; else order="t c"; fi
  for m in $order; do
    if [ "$m" = c ] && [ -n "$c_wid" ]; then wid_x=$c_wid; sid_x=$c_sid; break; fi
    if [ "$m" = t ] && [ -n "$t_wid" ]; then wid_x=$t_wid; sid_x=$t_sid; break; fi
  done
  [ -n "$wid_x" ] || exit 0

  # 7. tmux first, then iTerm2. If the pane vanished in between, the click
  # ends here and iTerm2 is left alone.
  "$tm" -S "$sock" select-window -t "$sid:$wid" || exit 0
  "$tm" -S "$sock" select-pane -t "$pane" || exit 0

  # 8. SHOW.
  nf_show "$wid_x" "$sid_x" || exit 0
  exit 0
}

case "${1:-}" in
  exec-arg)
    shift
    nf_exec_arg "$@" 2>/dev/null
    ;;
  record)
    shift
    nf_record "$@" >/dev/null 2>&1
    ;;
  focus)
    shift
    nf_focus "$@"
    ;;
esac
exit 0
