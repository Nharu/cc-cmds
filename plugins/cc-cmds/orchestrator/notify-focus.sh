#!/usr/bin/env bash
#
# notify-focus.sh — what a banner click runs, the two helpers that build the
# value a banner carries, and the background work that makes a click fast.
#
#   exec-arg [--seat-file <file>]    print the `-execute` value for one banner
#   record <RUN_DIR>                 write <RUN_DIR>/notify.seat, once
#   focus <socket> <pid> <%pane>     bring that tmux pane forward in iTerm2,
#                                    across Spaces
#   prime <socket> <pid> <%pane>     resolve that pane ahead of the click and
#                                    build the helper; selects nothing
#   build                            build the helper only (started by a click
#                                    that found none)
#
# THE VALUE IS ALWAYS ONE OF TWO SHAPES: `:` or
# `/bin/bash '<this file>' focus '<socket>' '<pid>' '<%pane>'`. Every line that
# raises a banner carries `-execute` with one of them, and when a value cannot be
# built it falls back to `:` — there is no path that drops `-execute`, because a
# banner without it hands the click to the notifier's own default, which moves
# focus to an application nobody asked for.
#
# WHY ONE FILE FOR ALL OF IT. The click process inherits nothing from whoever
# raised the banner — not TMUX, not PATH, not the working directory — so the
# location and this file's absolute path have to be baked into the value. The
# three banner families share this one file so that the rule deciding where a
# click lands exists once.
#
# EVERY PATH EXITS 0. `exec-arg` reports failure only by printing `:`, `record`
# by writing nothing, and `focus` by changing nothing. A banner sits on the
# critical path of the caller, and a click has nobody to report to.
#
# THE CLICK DETACHES ITSELF. `focus` checks its arguments, sends 0, 1 and 2 to
# /dev/null and runs its body as a separate process, so the notifier gets its
# command back at once. `prime` does the same. `exec-arg` and `record` start a
# prime that way when the value they produced points at a pane.
#
# NOTHING IN TMUX IS CHANGED UNTIL THE TARGET IS DECIDED. `focus` runs every
# check that can say "no" — the pane is alive on the same server, a client is
# attached to its session, iTerm2 shows that client — before it selects anything
# in tmux. iTerm2 is touched only after tmux is. Raising the window moves the
# screen to its Space before the tab and session are selected, so a session that
# moved in between can fail that selection after the screen moved; the click
# then resolves again and selects the right session (the slow path).
#
# THE CACHE. Under one root —
# `${CC_CMDS_NOTIFY_FOCUS_CACHE:-$(getconf DARWIN_USER_CACHE_DIR)cc-cmds/notify-focus}`,
# mode 700, and none at all when `getconf` fails or does not print an absolute
# path — sit the pane entries a prime resolved, the window → AX element table per
# iTerm2 pid, the compiled helper `notify-focus-ax` (built from the sibling
# `notify-focus-ax.swift`), the current click's token and the guide stamps. Every
# write goes to a temporary file in the same directory and is renamed into place.
# Every lock is an mkdir directory holding its owner's pid.
#
# THE GUIDE. A click that finds the helper refused by accessibility, or no Swift
# compiler on the host, sources the sibling `notify-run.sh` and raises its
# `focus-guide` banner, at most once a day. Only `focus` does this.
#
# CONTRACT WITH THE EMITTER: CC_CMDS_NOTIFY_FOCUS_PRIME=off stops `exec-arg` and
# `record` from starting a prime. The emitter passes it when the banners of that
# run are switched off; it is not a test seam, although the tests use it too.
#
# Seams: CC_CMDS_NOTIFY_FOCUS_TMUX names the tmux binary.
# CC_CMDS_NOTIFY_FOCUS_ITERM names a program taking `find <N> [<control tty>…]`
# (the whole resolver; prints the seven-field rows) and `show <wid> <sid> [w]`
# in place of the AppleScript calls; when it is set, `pgrep` is skipped and the
# iTerm2 pid is CC_CMDS_NOTIFY_FOCUS_ITERM_PID (a fixed stub pid when unset, no
# pid when empty). CC_CMDS_NOTIFY_FOCUS_ITERM_Q names a program taking the
# resolver's single reads — `ttys`, `var <wid> <tab> <session> <name>`, `wins`,
# `wpane <wid>`, `narrow <N>` — and CC_CMDS_NOTIFY_FOCUS_RESOLVER=narrow forces
# the narrow walk. CC_CMDS_NOTIFY_FOCUS_AX names a program used in place of the
# helper (no build then), CC_CMDS_NOTIFY_FOCUS_OPEN one used in place of
# /usr/bin/open, CC_CMDS_NOTIFY_FOCUS_SWIFTC the compiler (`none`: no compiler),
# CC_CMDS_NOTIFY_FOCUS_OSBUILD the OS build in the helper key.
# CC_CMDS_NOTIFY_FOCUS_CACHE sets the cache root, CC_CMDS_NOTIFY_FOCUS_GUIDE=off
# suppresses the guide, CC_CMDS_NOTIFY_FOCUS_FOREGROUND=1 runs `focus` and
# `prime` in place, CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE multiplies every wait and
# time limit, and CC_CMDS_NOTIFY_FOCUS_TRACE=<file> appends timed lines there.
# CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND skips the Homebrew PATH prepend, the same
# rule the emitter follows.
#
# Compatibility: bash 3.2 (macOS stock) — no associative arrays, no `mapfile`.

TAB=$(printf '\t')
NF_ITERM_ID=com.googlecode.iterm2
# The pid a stubbed iTerm2 answers with when the test does not name one.
NF_STUB_PID=1

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

# --- clock, waits, trace ------------------------------------------------------

# Milliseconds. bash 3.2 has no sub-second clock of its own and BSD `date` has
# no `%N`, so the stock perl answers; without it the clock falls back to whole
# seconds.
nf_now_ms() {
  local t
  if [ -x /usr/bin/perl ]; then
    t=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' 2>/dev/null)
    if nf_is_num "$t"; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  printf '%s000\n' "$(date +%s)"
}

nf_scale() {
  case "${CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE:-}" in
    ''|*[!0-9.]*|.|*.*.*) printf '1' ;;
    *) printf '%s' "$CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE" ;;
  esac
}

# A time limit in milliseconds, scaled by the wait seam.
nf_scaled_ms() {
  awk -v a="$1" -v b="$(nf_scale)" 'BEGIN { printf "%d\n", a * b }'
}

# Every wait passes through here, so one seam shortens all of them.
nf_sleep() {
  local s
  s=$(awk -v a="$1" -v b="$(nf_scale)" 'BEGIN { printf "%.3f\n", a * b }')
  sleep "$s" 2>/dev/null || sleep 1
}

nf_trace() {
  [ -n "${CC_CMDS_NOTIFY_FOCUS_TRACE:-}" ] || return 0
  printf '%s %s\n' "$(nf_now_ms)" "$*" >> "$CC_CMDS_NOTIFY_FOCUS_TRACE" 2>/dev/null || true
}

nf_errsink() {
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_TRACE:-}" ]; then
    printf '%s' "$CC_CMDS_NOTIFY_FOCUS_TRACE"
  else
    printf '/dev/null'
  fi
}

# The same prepend the emitter uses, so a click and a prime find the binaries a
# banner was raised with.
nf_path_prepend() {
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
  PATH="$PATH:/usr/bin:/bin"
  export PATH
}

# --- cache root, atomic writes, locks ----------------------------------------

# Print the cache root, creating it mode 700. A `getconf` that fails or prints
# something other than an absolute path means no root at all: a relative one
# would land wherever the click happened to run.
nf_root() {
  local r d
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_CACHE:-}" ]; then
    r=$CC_CMDS_NOTIFY_FOCUS_CACHE
  else
    d=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null) || return 1
    r="${d%/}/cc-cmds/notify-focus"
  fi
  case "$r" in
    /*) : ;;
    *) return 1 ;;
  esac
  ( umask 077 && mkdir -p "$r/panes" "$r/ax" "$r/helper" ) 2>/dev/null || return 1
  chmod 700 "$r" 2>/dev/null || true
  printf '%s\n' "$r"
}

# nf_put <file> <content> — write through a temporary file and rename.
nf_put() {
  local t="$1.tmp.$$"
  printf '%s' "$2" > "$t" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
  mv -f "$t" "$1" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
}

# nf_lock_take <dir> — the mkdir itself, under umask 077, with this pid in it.
# A lock whose pid could not be written is removed again: nobody could release
# it, and it would look alive for as long as its age allows.
nf_lock_take() {
  ( umask 077 && mkdir "$1" ) 2>/dev/null || return 1
  if ! ( umask 077 && printf '%s\n' "$$" > "$1/pid" ) 2>/dev/null; then
    rm -rf "$1" 2>/dev/null
    return 1
  fi
  return 0
}

# nf_lock <dir> <minutes> — take an mkdir lock. One held by a pid that is gone,
# or older than the given minutes, is stale and is taken over.
#
# TAKING OVER IS ITSELF UNDER A LOCK, `<dir>.break`. Two callers can both judge
# the same lock stale; the first then takes the freed name, and the second,
# acting on its earlier judgment, would move that fresh lock aside while its
# owner is still filling it — the owner's work directory goes with it and
# nobody builds. Whoever does not get `<dir>.break` gives up, and whoever gets
# it judges the lock again from a fresh reading. It holds `<dir>.break` until
# it has taken the lock, so the next breaker meets a live lock. A `<dir>.break`
# left by a caller that died in those few steps is removed after a minute.
#
# A STALE LOCK IS MOVED ASIDE, NOT REMOVED, and only the move that caught the
# very lock it judged — same pid inside — goes on to take it. An owner can
# still release its lock and another take the name between the reading and the
# move, since taking needs no `<dir>.break`.
#
# A RENAME THAT CAUGHT A LOCK SOMEONE HAD JUST TAKEN IS NOT RENAMED BACK. The
# name may have been taken again meanwhile, and renaming a directory onto an
# existing one moves it inside, leaving two holders. The lock is re-created
# with mkdir instead, which fails on an existing name, carrying its owner's
# pid so that owner can still release it.
nf_lock() {
  local seen aside rc=1
  nf_lock_take "$1" && return 0
  nf_lock_live "$1" "$2" && return 1
  if ! nf_lock_take "$1.break"; then
    [ -n "$(find "$1.break" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$1.break" 2>/dev/null
    return 1
  fi
  # The pid is read once: that one reading is both what is judged dead and what
  # the moved lock is compared with.
  seen=$(cat "$1/pid" 2>/dev/null)
  if [ ! -d "$1" ]; then
    nf_lock_take "$1" && rc=0
  elif ! nf_lock_live "$1" "$2" "$seen"; then
    aside="$1.stale.$$"
    if mv "$1" "$aside" 2>/dev/null; then
      if [ "$(cat "$aside/pid" 2>/dev/null)" = "$seen" ]; then
        rm -rf "$aside" 2>/dev/null
        nf_lock_take "$1" && rc=0
      else
        if ( umask 077 && mkdir "$1" ) 2>/dev/null; then
          cp "$aside/pid" "$1/pid" 2>/dev/null || true
        fi
        rm -rf "$aside" 2>/dev/null
      fi
    fi
  fi
  nf_unlock "$1.break"
  return "$rc"
}

# nf_lock_live <dir> <minutes> [<pid as already read>]
nf_lock_live() {
  local p
  [ -d "$1" ] || return 1
  if [ $# -ge 3 ]; then p=$3; else p=$(cat "$1/pid" 2>/dev/null); fi
  if nf_is_num "$p" && ! ps -p "$p" >/dev/null 2>&1; then
    return 1
  fi
  [ -z "$(find "$1" -maxdepth 0 -mmin +"$2" 2>/dev/null)" ]
}

# Only the owner releases: a lock that was judged stale and taken over belongs
# to its new holder, and removing it would let a third caller in beside it.
nf_unlock() {
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$1" 2>/dev/null || true
}

nf_key() {
  set -- $(printf '%s\t%s\t%s' "$NF_SOCK" "$NF_PID" "$NF_PANE" | cksum)
  printf '%s\n' "$1"
}

# True while this click is still the latest one. With no cache root there is no
# token, and every check passes.
nf_mine() {
  [ -n "${NF_ROOT:-}" ] || return 0
  [ "$(cat "$NF_ROOT/click.current" 2>/dev/null)" = "$NF_TOKEN" ]
}

# nf_log <text> — one line per click that gave up the switch, bounded at 64 KiB.
nf_log() {
  local f old=""
  [ -n "${NF_ROOT:-}" ] || return 0
  f="$NF_ROOT/focus.log"
  if [ -f "$f" ] && [ "$(wc -c < "$f" | tr -d ' ')" -le 65536 ]; then
    old=$(cat "$f" 2>/dev/null)
    [ -n "$old" ] && old="$old
"
  fi
  nf_put "$f" "$old$(date -u +%Y-%m-%dT%H:%M:%SZ) $*
" || true
}

# --- spawning -----------------------------------------------------------------

# nf_spawn <verb> <args…> — run this file again, detached: its own process
# group, every stream on /dev/null, so neither a `$(…)` nor the notifier waits
# for it. A separate process rather than a backgrounded function, because the
# locks record `$$` and bash 3.2 has no other way to name a subshell's pid.
nf_spawn() {
  local self
  self=$(nf_self) || return 0
  (
    set -m
    CC_CMDS_NOTIFY_FOCUS_FOREGROUND=1 /bin/bash "$self" "$@" </dev/null >/dev/null 2>&1 &
  ) </dev/null >/dev/null 2>&1
  return 0
}

# Whether a banner-time prime may start. The notifier is looked up on the PATH
# the emitter fires with, because `cc_notify_fire` computes the click value and
# `cc_notify_seat_state` calls `record` before that prepend.
nf_prime_ok() {
  [ "${CC_CMDS_NOTIFY_FOCUS_PRIME:-}" = off ] && return 1
  if [ ! -x /usr/bin/osascript ] && [ -z "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ] \
    && [ -z "${CC_CMDS_NOTIFY_FOCUS_ITERM_Q:-}" ]; then
    return 1
  fi
  (
    if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
      PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    fi
    command -v terminal-notifier >/dev/null 2>&1
  )
}

nf_prime_spawn() {
  nf_prime_ok || return 0
  nf_trace "prime 띄움 $NF_SOCK $NF_PID $NF_PANE"
  nf_spawn prime "$NF_SOCK" "$NF_PID" "$NF_PANE"
}

# --- exec-arg and record -------------------------------------------------------

nf_exec_arg() {
  local self seat=0
  if [ "${1:-}" = "--seat-file" ]; then
    seat=1
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
  # The seat-file form is the one place a launchd-lineage process can reach, so
  # it never starts a prime.
  [ "$seat" = 1 ] || nf_prime_spawn
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
  # A hard link publishes without replacing and fails when the name exists, so
  # exactly one of two racing callers sees it succeed. Only that one starts the
  # seat pane's prime; each removes its own temporary file.
  if ln "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp" || true
    nf_prime_spawn
    return 0
  fi
  rm -f "$tmp" || true
  return 0
}

# --- tmux ------------------------------------------------------------------------

nf_tmux() {
  NF_TM="${CC_CMDS_NOTIFY_FOCUS_TMUX:-}"
  [ -n "$NF_TM" ] || NF_TM=$(command -v tmux) || return 1
  [ -n "$NF_TM" ] && [ -x "$NF_TM" ]
}

# The pane is alive, on the server that was recorded. A pane that does not exist
# still answers with exit 0 and the server pid filled in, so existence is the
# pane id coming back verbatim, not the exit code. Sets P_SID, P_WID, P_SNAME.
nf_pane_check() {
  local out p pid2
  out=$("$NF_TM" -S "$NF_SOCK" display-message -p -t "$NF_PANE" \
    '#{pid}|#{session_id}|#{window_id}|#{pane_id}|#{session_name}') || return 1
  case "$out" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  IFS='|' read -r p P_SID P_WID pid2 P_SNAME <<EOF
$out
EOF
  [ "$pid2" = "$NF_PANE" ] || return 1
  nf_is_id '$' "$P_SID" || return 1
  nf_is_id '@' "$P_WID" || return 1
  [ "$p" = "$NF_PID" ] || return 1
  [ -n "$P_SNAME" ] || return 1
  return 0
}

# Clients attached to that session — and only those. A client watching another
# session is never pulled over: that would change what a person is looking at.
# Control-mode clients are counted and their ttys kept for the resolver; the tty
# of a normal client is kept with its activity so the most recent one is tried
# first. Sets NC, CMAX, TMAX, TTYS (normal, newest first, without /dev/) and
# CTTYS (control).
nf_clients() {
  local clients line mode r csid act tty tlist="" re_ctty
  NC=0; CMAX=-1; TMAX=-1; TTYS=""; CTTYS=""
  clients=$("$NF_TM" -S "$NF_SOCK" list-clients \
    -F '#{client_control_mode}|#{session_id}|#{client_activity}|#{client_tty}') || return 1
  re_ctty='^/dev/[A-Za-z0-9]+(/[0-9]+)?$'
  while IFS= read -r line; do
    case "$line" in
      *'|'*'|'*'|'*) : ;;
      *) continue ;;
    esac
    mode=${line%%|*}; r=${line#*|}
    csid=${r%%|*};    r=${r#*|}
    act=${r%%|*};     tty=${r#*|}
    [ "$csid" = "$P_SID" ] || continue
    nf_is_num "$act" || continue
    case "$mode" in
      1)
        NC=$((NC + 1))
        [ "$act" -gt "$CMAX" ] && CMAX=$act
        if [[ "$tty" =~ $re_ctty ]]; then
          CTTYS="$CTTYS $tty"
        fi
        ;;
      0)
        [[ "$tty" =~ $re_ctty ]] || continue
        tlist="$tlist$act $tty
"
        [ "$act" -gt "$TMAX" ] && TMAX=$act
        ;;
    esac
  done <<EOF
$clients
EOF
  [ "$NC" -gt 0 ] || [ -n "$tlist" ] || return 1
  TTYS=$(printf '%s' "$tlist" | sort -k1,1nr | while read -r _ tt; do printf '%s\n' "${tt#/dev/}"; done)
  return 0
}

# --- iTerm2 -------------------------------------------------------------------------

nf_iterm_pid() {
  local p
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    if [ "${CC_CMDS_NOTIFY_FOCUS_ITERM_PID+set}" = set ]; then
      p=$CC_CMDS_NOTIFY_FOCUS_ITERM_PID
    else
      p=$NF_STUB_PID
    fi
  else
    p=$(pgrep -x iTerm2 2>/dev/null | awk 'NR==1')
  fi
  nf_is_num "$p" || return 1
  printf '%s\n' "$p"
}

# nf_capped <ms> <command…> — run a command, killed when the limit passes. The
# command is started directly rather than through a function, so the kill
# reaches the process doing the work.
nf_capped() {
  local ms=$1 cpid wpid rc
  shift
  [ "$ms" -gt 0 ] 2>/dev/null || return 1
  "$@" &
  cpid=$!
  # The limit is already scaled, so it is slept as it stands. The watcher's own
  # `sleep` is a child of its own; the trap takes it down with the watcher, so
  # a command that finished early leaves no sleeper behind.
  ( s=$(awk -v m="$ms" 'BEGIN { printf "%.3f\n", m / 1000 }')
    sleep "$s" &
    sp=$!
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    wait "$sp"
    kill "$cpid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  wpid=$!
  wait "$cpid"
  rc=$?
  kill "$wpid" 2>/dev/null
  return "$rc"
}

# What is left of the resolver's 30-second limit, in milliseconds.
nf_left_ms() {
  printf '%s\n' $(( NF_RES_END - $(nf_now_ms) ))
}

# The resolver's single reads. Each is one AppleScript event batch, or one call
# of the seam program. No pane number, tty or name is spliced into the script
# text: whatever varies arrives as argv.
nf_q() {
  local left
  left=$(nf_left_ms)
  [ "$left" -gt 0 ] || return 1
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM_Q:-}" ]; then
    nf_capped "$left" "$CC_CMDS_NOTIFY_FOCUS_ITERM_Q" "$@"
    return
  fi
  case "$1" in
    ttys)
      # Window id, window index, session id and tty of every session, in four
      # reads however many sessions there are.
      nf_capped "$left" /usr/bin/osascript \
        -e 'set sepTab to (character id 9)' \
        -e 'tell application id "com.googlecode.iterm2"' \
        -e 'set wids to id of windows' \
        -e 'set wixs to index of windows' \
        -e 'set sids to id of sessions of tabs of windows' \
        -e 'set ys to tty of sessions of tabs of windows' \
        -e 'end tell' \
        -e 'set o to ""' \
        -e 'repeat with i from 1 to count of wids' \
        -e 'set ws to item i of sids' \
        -e 'set wy to item i of ys' \
        -e 'repeat with ti from 1 to count of ws' \
        -e 'set ts to item ti of ws' \
        -e 'set ty to item ti of wy' \
        -e 'repeat with si from 1 to count of ts' \
        -e 'set y to item si of ty' \
        -e 'if y is missing value then set y to ""' \
        -e 'set o to o & (item i of wids) & sepTab & (item i of wixs) & sepTab & (item si of ts) & sepTab & y & sepTab & ti & sepTab & si & linefeed' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'return o'
      ;;
    var)
      shift
      nf_capped "$left" /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set wid to (item 1 of argv) as integer' \
        -e 'set ti to (item 2 of argv) as integer' \
        -e 'set si to (item 3 of argv) as integer' \
        -e 'set nm to item 4 of argv' \
        -e 'set v to ""' \
        -e 'tell application id "com.googlecode.iterm2"' \
        -e 'tell session si of tab ti of window id wid to set v to (variable named nm)' \
        -e 'end tell' \
        -e 'if v is missing value then set v to ""' \
        -e 'return v' \
        -e 'end run' \
        "$@"
      ;;
    wins)
      nf_capped "$left" /usr/bin/osascript \
        -e 'set sepTab to (character id 9)' \
        -e 'tell application id "com.googlecode.iterm2"' \
        -e 'set wids to id of windows' \
        -e 'set wixs to index of windows' \
        -e 'set wns to name of windows' \
        -e 'end tell' \
        -e 'set o to ""' \
        -e 'repeat with i from 1 to count of wids' \
        -e 'set o to o & (item i of wids) & sepTab & (item i of wixs) & sepTab & (item i of wns) & linefeed' \
        -e 'end repeat' \
        -e 'return o'
      ;;
    wpane)
      shift
      nf_capped "$left" /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set wid to (item 1 of argv) as integer' \
        -e 'set sepTab to (character id 9)' \
        -e 'set p to ""' \
        -e 'tell application id "com.googlecode.iterm2"' \
        -e 'set s to current session of window id wid' \
        -e 'set i to id of s' \
        -e 'tell s to set p to (variable named "tmuxWindowPane")' \
        -e 'end tell' \
        -e 'if p is missing value then set p to ""' \
        -e 'return i & sepTab & p' \
        -e 'end run' \
        "$@"
      ;;
    narrow)
      # The walk: every session, but the tmux variables only of a session with
      # no tty (an integration session), and role and client name only where
      # the pane number matched. A window that errors is skipped, not fatal.
      shift
      nf_capped "$left" /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set nwant to item 1 of argv' \
        -e 'set sepTab to (character id 9)' \
        -e 'set o to ""' \
        -e 'tell application id "com.googlecode.iterm2"' \
        -e 'set wl to windows' \
        -e 'repeat with w in wl' \
        -e 'try' \
        -e 'set wid to id of w' \
        -e 'set wix to index of w' \
        -e 'repeat with t in tabs of w' \
        -e 'repeat with s in sessions of t' \
        -e 'set y to ""' \
        -e 'set r to ""' \
        -e 'set p to ""' \
        -e 'set c to ""' \
        -e 'try' \
        -e 'set y to (tty of s)' \
        -e 'end try' \
        -e 'if y is missing value then set y to ""' \
        -e 'if y is "" then' \
        -e 'try' \
        -e 'tell s to set p to (variable named "tmuxWindowPane")' \
        -e 'end try' \
        -e 'if p is missing value then set p to ""' \
        -e 'if (p as text) is nwant then' \
        -e 'try' \
        -e 'tell s to set r to (variable named "tmuxRole")' \
        -e 'end try' \
        -e 'try' \
        -e 'tell s to set c to (variable named "tmuxClientName")' \
        -e 'end try' \
        -e 'if r is missing value then set r to ""' \
        -e 'if c is missing value then set c to ""' \
        -e 'else' \
        -e 'set p to ""' \
        -e 'end if' \
        -e 'end if' \
        -e 'if y is not "" or p is not "" then' \
        -e 'set o to o & wid & sepTab & wix & sepTab & (id of s) & sepTab & y & sepTab & r & sepTab & p & sepTab & c & linefeed' \
        -e 'end if' \
        -e 'end repeat' \
        -e 'end repeat' \
        -e 'end try' \
        -e 'end repeat' \
        -e 'end tell' \
        -e 'return o' \
        -e 'end run' \
        "$@"
      ;;
    *) return 1 ;;
  esac
}

# The connection-label path for tmux -CC panes. For each control client: the
# gateway session is the one whose tty is that client's tty, its
# `tmuxClientName` is the label, the windows whose name ends in exactly
# `[<label>]` are the candidates, and a candidate counts once its current
# session reports this pane number. Any step that comes up empty fails the
# whole path, and the caller falls back to the narrow walk.
nf_resolve_label() {
  local N=$1 trows ct grow lab wins w cand cwid cidx cname wp csid cpn rows="" r
  trows=$(nf_q ttys) || return 1
  [ -n "$trows" ] || return 1
  for ct in $CTTYS; do
    grow=""
    while IFS= read -r r; do
      case "$r" in
        *"$TAB$ct$TAB"*) grow=$r; break ;;
      esac
    done <<EOF
$trows
EOF
    [ -n "$grow" ] || return 1
    set -- $(printf '%s' "$grow" | awk -F "$TAB" '{ print $1, $5, $6 }')
    lab=$(nf_q var "$1" "$2" "$3" tmuxClientName) || return 1
    case "$lab" in
      ''|*[[:cntrl:]]*) return 1 ;;
    esac
    if [ -z "${wins:-}" ]; then
      wins=$(nf_q wins) || return 1
      [ -n "$wins" ] || return 1
    fi
    cand=0
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      cname=${w#*"$TAB"}; cname=${cname#*"$TAB"}
      case "$cname" in
        *"[$lab]") : ;;
        *) continue ;;
      esac
      cwid=${w%%"$TAB"*}
      cidx=${w#*"$TAB"}; cidx=${cidx%%"$TAB"*}
      wp=$(nf_q wpane "$cwid") || continue
      csid=${wp%%"$TAB"*}
      cpn=${wp#*"$TAB"}
      [ "$cpn" = "$N" ] || continue
      rows="$rows$cwid$TAB$cidx$TAB$csid$TAB$TAB""client$TAB$N$TAB
"
      cand=1
    done <<EOF
$wins
EOF
    [ "$cand" = 1 ] || return 1
  done
  # Normal-mode rows: every session that has a tty.
  printf '%s\n' "$trows" | awk -F "$TAB" -v OFS="$TAB" '$4 != "" { print $1, $2, $3, $4, "", "", "" }'
  printf '%s' "$rows"
}

# nf_resolve <N> — print the seven-field rows the decision rules read:
# window id, window index, session id, tty, tmuxRole, tmuxWindowPane,
# tmuxClientName. Bounded at 30 seconds; past that nothing is printed.
nf_resolve() {
  local N=$1 out
  NF_RES_END=$(( $(nf_now_ms) + $(nf_scaled_ms 30000) ))
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    # shellcheck disable=SC2086
    nf_capped "$(nf_left_ms)" "$CC_CMDS_NOTIFY_FOCUS_ITERM" find "$N" $CTTYS
    return
  fi
  if [ "${CC_CMDS_NOTIFY_FOCUS_RESOLVER:-}" != narrow ]; then
    out=$(nf_resolve_label "$N") && { printf '%s\n' "$out"; return 0; }
  fi
  nf_q narrow "$N"
}

# nf_digest <rows> <N> <session name> — reduce the rows to what the decision
# needs, into E_NB/E_BWID/E_BSID (rule (b)) and E_CLIST (rule (c): `tty:wid:sid`
# in row order). Returns 1 when no row is a candidate for either rule.
nf_digest() {
  local row x f_wid f_idx f_sid f_tty f_role f_wp f_cn r b_idx="" re_dtty
  E_NB=0; E_BWID=""; E_BSID=""; E_CLIST=""
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
    if [ "$f_role" = "client" ] && [ "$f_wp" = "$2" ]; then
      if [ -z "$f_cn" ] || [ "$f_cn" = "$3" ]; then
        E_NB=$((E_NB + 1))
        if [ -z "$b_idx" ] || [ "$f_idx" -lt "$b_idx" ]; then
          b_idx=$f_idx; E_BWID=$f_wid; E_BSID=$f_sid
        fi
      fi
    fi

    # (c) normal mode: kept per tty in row order; the click matches them
    # against the clients in activity order.
    if [ -z "$f_role" ] && [ -n "$f_tty" ]; then
      E_CLIST="$E_CLIST ${f_tty#/dev/}:$f_wid:$f_sid"
    fi
  done <<EOF
$1
EOF
  [ "$E_NB" -gt 0 ] || [ -n "$E_CLIST" ]
}

# The pane entry: one versioned line, so a click can check it was resolved for
# this very pane, session and name before trusting the candidates in it.
nf_entry_write() {
  [ -n "${NF_ROOT:-}" ] || return 0
  nf_put "$NF_ROOT/panes/$NF_KEY" "v1$TAB$NF_SOCK$TAB$NF_PID$TAB$NF_PANE$TAB$P_SID$TAB$P_SNAME$TAB$(date +%s)$TAB$E_NB$TAB$E_BWID$TAB$E_BSID$TAB$E_CLIST
" || true
}

nf_entry_read() {
  local line="" f r i v
  [ -n "${NF_ROOT:-}" ] || return 1
  f="$NF_ROOT/panes/$NF_KEY"
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" 2>/dev/null || [ -n "$line" ] || return 1
  r=$line
  set --
  i=0
  while [ "$i" -lt 10 ]; do
    case "$r" in
      *"$TAB"*) : ;;
      *) return 1 ;;
    esac
    v=${r%%"$TAB"*}
    set -- "$@" "$v"
    r=${r#*"$TAB"}
    i=$((i + 1))
  done
  [ "$1" = v1 ] || return 1
  [ "$2" = "$NF_SOCK" ] && [ "$3" = "$NF_PID" ] && [ "$4" = "$NF_PANE" ] || return 1
  [ "$5" = "$P_SID" ] && [ "$6" = "$P_SNAME" ] || return 1
  nf_is_num "$8" || return 1
  # The candidates pass the same checks they passed when written: a file in
  # the cache is trusted no further than a row from iTerm2 was.
  if [ -n "$9" ]; then nf_is_num "$9" || return 1; fi
  case "${10}" in
    *[!A-Za-z0-9-]*) return 1 ;;
  esac
  nf_clist_ok "$r" || return 1
  E_NB=$8; E_BWID=$9; E_BSID=${10}; E_CLIST=$r
  return 0
}

# Every item of a rule (c) list is `tty:wid:sid` with the characters a row may
# carry in those fields.
nf_clist_ok() {
  local it ok=0 re_item
  re_item='^[A-Za-z0-9]+(/[0-9]+)?:[0-9]+:[A-Za-z0-9-]+$'
  set -f
  for it in $1; do
    [[ "$it" =~ $re_item ]] || { ok=1; break; }
  done
  set +f
  return "$ok"
}

# The decision, re-run on every click against fresh client data. Sets WID_X and
# SID_X, or returns 1.
nf_decide() {
  local c_wid="" c_sid="" t_wid="" t_sid="" tt it order m rest
  WID_X=""; SID_X=""
  # (d) A tie among control rows is broken by the frontmost window only while
  # the rows fit inside the number of control clients — each such client draws
  # the pane once, so more rows than clients means another server's session of
  # the same name is mixed in, and the rows cannot tell which.
  if [ "$NC" -gt 0 ] && [ "$E_NB" -ge 1 ] && [ "$E_NB" -le "$NC" ]; then
    c_wid=$E_BWID; c_sid=$E_BSID
  fi
  if [ -n "$TTYS" ] && [ -n "$E_CLIST" ]; then
    set -f
    while IFS= read -r tt; do
      [ -n "$tt" ] || continue
      for it in $E_CLIST; do
        if [ "${it%%:*}" = "$tt" ]; then
          rest=${it#*:}
          t_wid=${rest%%:*}; t_sid=${rest#*:}
          break 2
        fi
      done
    done <<EOF
$TTYS
EOF
    set +f
  fi
  # (a) The mode with the more recent activity is asked first; a tie goes to
  # control mode. The other mode answers only when the first has nothing.
  if [ "$CMAX" -ge "$TMAX" ]; then order="c t"; else order="t c"; fi
  for m in $order; do
    if [ "$m" = c ] && [ -n "$c_wid" ]; then WID_X=$c_wid; SID_X=$c_sid; break; fi
    if [ "$m" = t ] && [ -n "$t_wid" ]; then WID_X=$t_wid; SID_X=$t_sid; break; fi
  done
  [ -n "$WID_X" ]
}

# Resolve now and decide. Writes the entry when the rows held a candidate. A
# resolution that read iTerm2 and found no candidate removes the pane's old
# entry — the pane is no longer where it said — while one that failed or ran
# out of time leaves the cache as it was.
nf_slow() {
  local rows
  rows=$(nf_resolve "${NF_PANE#%}") || return 1
  [ -n "$rows" ] || return 1
  if ! nf_digest "$rows" "${NF_PANE#%}" "$P_SNAME"; then
    [ -n "${NF_ROOT:-}" ] && rm -f "$NF_ROOT/panes/$NF_KEY" 2>/dev/null
    return 1
  fi
  nf_entry_write
  return 0
}

# Select tab and session of a window found by id — and, with a third argument,
# the window itself. The values arrive as argv and are compared, never spliced
# into the script. Prints the error text on failure.
nf_show() {
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_ITERM:-}" ]; then
    "$CC_CMDS_NOTIFY_FOCUS_ITERM" show "$@" 2>&1
    return
  fi
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set wid to (item 1 of argv) as integer' \
    -e 'set sid to item 2 of argv' \
    -e 'set sw to ((count of argv) > 2)' \
    -e 'tell application id "com.googlecode.iterm2"' \
    -e 'try' \
    -e 'set w to window id wid' \
    -e 'set ids to id of sessions of tabs of w' \
    -e 'on error' \
    -e 'error "window not found"' \
    -e 'end try' \
    -e 'repeat with ti from 1 to count of ids' \
    -e 'set ts to item ti of ids' \
    -e 'repeat with si from 1 to count of ts' \
    -e 'if (item si of ts) is sid then' \
    -e 'if sw then select w' \
    -e 'select tab ti of w' \
    -e 'select session si of tab ti of w' \
    -e 'return "ok"' \
    -e 'end if' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'end tell' \
    -e 'error "session not found"' \
    -e 'end run' \
    "$@" 2>&1
}

# 0 shown, 10 the target is gone — the session is no longer in that window, or
# the window id no longer names a window (iTerm2 restarted, a tmux -CC client
# reattached) — and has to be resolved again, 1 anything else.
nf_show_rc() {
  local out rc
  out=$(nf_show "$@")
  rc=$?
  nf_trace "show $rc"
  [ "$rc" = 0 ] && return 0
  case "$out" in
    *'session not found'*|*'window not found'*) return 10 ;;
  esac
  return 1
}

nf_open() {
  "${CC_CMDS_NOTIFY_FOCUS_OPEN:-/usr/bin/open}" -b "$NF_ITERM_ID" </dev/null >/dev/null 2>&1
  nf_trace "open -b 반환"
}

# --- the helper ----------------------------------------------------------------------

nf_helper_key() {
  local src cks arch osb
  src="$NF_DIR/notify-focus-ax.swift"
  [ -f "$src" ] || return 1
  cks=$(cksum < "$src")
  arch=$(uname -m 2>/dev/null)
  osb=${CC_CMDS_NOTIFY_FOCUS_OSBUILD:-$(sw_vers -buildVersion 2>/dev/null)}
  set -- $(printf '%s|%s|%s' "$cks" "$arch" "${osb:-unknown}" | cksum)
  printf '%s\n' "$1"
}

# Print the helper to run, or return 1 when there is none yet.
nf_helper() {
  local key
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_AX:-}" ]; then
    printf '%s\n' "$CC_CMDS_NOTIFY_FOCUS_AX"
    return 0
  fi
  [ -n "${NF_ROOT:-}" ] || return 1
  key=$(nf_helper_key) || return 1
  [ -x "$NF_ROOT/helper/$key/notify-focus-ax" ] || return 1
  printf '%s\n' "$NF_ROOT/helper/$key/notify-focus-ax"
}

# Pick the compiler by file existence alone — the shims (`/usr/bin/swiftc`,
# `xcrun`) are never called, because on a host without the Command Line Tools a
# shim opens an install dialog. Sets SC and SDK.
nf_compiler() {
  local clt=/Library/Developer/CommandLineTools
  local xc=/Applications/Xcode.app/Contents/Developer
  if [ -n "${CC_CMDS_NOTIFY_FOCUS_SWIFTC:-}" ]; then
    [ "$CC_CMDS_NOTIFY_FOCUS_SWIFTC" = none ] && return 1
    SC=$CC_CMDS_NOTIFY_FOCUS_SWIFTC
    SDK="$clt/SDKs/MacOSX.sdk"
    return 0
  fi
  if [ -x "$clt/usr/bin/swiftc" ]; then
    SC="$clt/usr/bin/swiftc"
    SDK="$clt/SDKs/MacOSX.sdk"
    return 0
  fi
  if [ -x "$xc/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SC="$xc/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    SDK="$xc/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    return 0
  fi
  return 1
}

# Whether a build failure stamp still holds: younger than a day. An expired one
# is removed so the next build may try.
nf_build_failed() {
  [ -f "$1" ] || return 1
  [ -n "$(find "$1" -mmin +1440 2>/dev/null)" ] || return 0
  rm -f "$1"
  return 1
}

# Build the helper under the build lock. A failure is stamped, and the same key
# is not tried again for a day; a new OS build changes the key.
#
# EACH BUILDER WRITES ITS OWN OUTPUT, inside the lock, under a name carrying its
# pid, and installs it only after running it once: a binary that does not
# answer `trusted` with 0 or 3 is not put in place. A builder that finds the
# lock no longer its own when the compiler returns — it was judged stale and
# taken over — installs nothing and stamps nothing, because its failure says
# nothing about the source.
nf_build() {
  local key src dir lock failed work rc
  [ -n "${NF_ROOT:-}" ] || return 1
  [ -z "${CC_CMDS_NOTIFY_FOCUS_AX:-}" ] || return 0
  nf_compiler || return 1
  key=$(nf_helper_key) || return 1
  src="$NF_DIR/notify-focus-ax.swift"
  dir="$NF_ROOT/helper/$key"
  lock="$NF_ROOT/helper/$key.lock"
  failed="$NF_ROOT/helper/$key.failed"
  [ -x "$dir/notify-focus-ax" ] && return 0
  nf_build_failed "$failed" && return 1
  nf_lock "$lock" 15 || return 1
  # Another builder may have finished, or failed, while this one waited.
  if [ -x "$dir/notify-focus-ax" ]; then nf_unlock "$lock"; return 0; fi
  if nf_build_failed "$failed"; then nf_unlock "$lock"; return 1; fi
  nf_trace "build $key"
  work="$lock/w.$$"
  ( umask 077 && mkdir "$work" ) 2>/dev/null || { nf_unlock "$lock"; return 1; }
  rc=1
  if TMPDIR="$work" "$SC" -O -sdk "$SDK" -module-cache-path "$NF_ROOT/helper/mc" \
       -o "$work/out" "$src" </dev/null >/dev/null 2>>"$(nf_errsink)" \
     && [ -x "$work/out" ]; then
    "$work/out" trusted </dev/null >/dev/null 2>&1
    case "$?" in
      0|3) rc=0 ;;
    esac
  fi
  if [ "$(cat "$lock/pid" 2>/dev/null)" != "$$" ]; then
    nf_trace "build 잠금 잃음"
    rm -rf "$work" 2>/dev/null
    return 1
  fi
  if [ "$rc" = 0 ] \
     && ( umask 077 && mkdir -p "$dir" ) 2>/dev/null \
     && mv -f "$work/out" "$dir/notify-focus-ax" 2>/dev/null; then
    find "$NF_ROOT/helper" -mindepth 1 -maxdepth 1 -type d ! -name "$key" ! -name mc \
      ! -name '*.lock' -mtime +30 -exec rm -rf {} + 2>/dev/null
    nf_unlock "$lock"
    return 0
  fi
  nf_put "$failed" "$(date +%s)
" || true
  nf_unlock "$lock"
  return 1
}

# nf_ax <verb> <args…> — run the helper; its output on stdout, its status back.
nf_ax() {
  "$NF_HX" "$@" </dev/null 2>>"$(nf_errsink)"
}

# --- the window → element table -------------------------------------------------

nf_table() {
  printf '%s/ax/%s\n' "$NF_ROOT" "$NF_IPID"
}

nf_table_eid() {
  [ -n "${NF_ROOT:-}" ] || return 0
  awk -F "$TAB" -v w="$1" '$1 == w { print $2; exit }' "$(nf_table)" 2>/dev/null
}

nf_table_max() {
  [ -n "${NF_ROOT:-}" ] || return 0
  awk '$1 == "max" { print $2; exit }' "$(nf_table)" 2>/dev/null
}

# The scan ceiling: two thousand past the largest element id seen, and never
# under four thousand.
nf_ceiling() {
  local m
  m=$(nf_table_max)
  if nf_is_num "$m" && [ $((m + 2000)) -gt 4000 ]; then
    printf '%s\n' $((m + 2000))
  else
    printf '4000\n'
  fi
}

# nf_table_set <wid> <eid> / nf_table_del <wid> — rewrite the whole table.
nf_table_set() {
  local t body
  [ -n "${NF_ROOT:-}" ] || return 0
  t=$(nf_table)
  body=$(awk -F "$TAB" -v OFS="$TAB" -v w="$1" -v e="$2" '
    /^max / { split($0, a, " "); if (a[2] + 0 > m) m = a[2] + 0; next }
    $1 == w { next }
    NF == 2 { print }
    END { print w, e; if (e + 0 > m) m = e + 0; print "max " m }
  ' "$t" 2>/dev/null)
  [ -n "$body" ] || body="$1$TAB$2
max $2"
  nf_put "$t" "$body
" || true
}

nf_table_del() {
  local t body
  [ -n "${NF_ROOT:-}" ] || return 0
  t=$(nf_table)
  [ -f "$t" ] || return 0
  body=$(awk -F "$TAB" -v w="$1" '$1 != w { print }' "$t" 2>/dev/null)
  nf_put "$t" "${body:+$body
}" || true
}

# --- the guide --------------------------------------------------------------------

# The application a person grants accessibility to: the bundle beside the
# notifier's `bin`, found by following its link. When that cannot be settled,
# the path the PATH lookup gave.
nf_notifier_app() {
  local n l t d set_n
  n=$(command -v terminal-notifier 2>/dev/null) || return 1
  l=$(readlink "$n" 2>/dev/null)
  if [ -n "$l" ]; then
    case "$l" in
      /*) t=$l ;;
      *) t="$(dirname "$n")/$l" ;;
    esac
    d=$(cd -P "$(dirname "$t")" 2>/dev/null && pwd -P)
    if [ -n "$d" ]; then
      set -- "$(dirname "$d")"/*.app
      set_n=$#
      if [ "$set_n" -eq 1 ] && [ -d "$1" ]; then
        (cd -P "$1" 2>/dev/null && pwd -P) && return 0
      fi
    fi
  fi
  printf '%s\n' "$n"
}

# nf_guide ax|clt — raise the setup banner, once a day, and again at once when
# the application path changed (a new version of the notifier is a new app to
# grant).
#
# THE STAMP IS WRITTEN ONLY AFTER THE BANNER WENT OUT. The emitter returns 0
# whether or not it raised anything, so the conditions it raises under — the
# file sourced, a Darwin host, the notifier on the PATH — are asked here after
# the call; a click that could not raise the guide leaves the next click free
# to try.
nf_guide() {
  local app="" body stamp mark
  [ "${CC_CMDS_NOTIFY_FOCUS_GUIDE:-}" = off ] && return 0
  [ -n "${NF_ROOT:-}" ] || return 0
  stamp="$NF_ROOT/guide.$1"
  case "$1" in
    ax)
      app=$(nf_notifier_app) || app=""
      if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$app" ] \
        && [ -z "$(find "$stamp" -mmin +1440 2>/dev/null)" ]; then
        return 0
      fi
      mark=$app
      body="$app — 손쉬운 사용에 추가하면 배너 클릭이 다른 Space 로 넘어갑니다(이 앱의 모든 배너에 적용)."
      ;;
    clt)
      if [ -f "$stamp" ] && [ -z "$(find "$stamp" -mmin +1440 2>/dev/null)" ]; then
        return 0
      fi
      mark=$(date +%s)
      body="xcode-select --install 로 Command Line Tools 를 설치하세요. 배너 클릭이 다른 Space 의 창으로 넘어가게 됩니다."
      ;;
    *) return 0 ;;
  esac
  nf_trace "guide $1"
  if (
    . "$NF_DIR/notify-run.sh" || exit 1
    cc_notify_fire focus-guide "$body"
    [ "$(cc_notify_host_os)" = Darwin ] || exit 1
    command -v terminal-notifier >/dev/null 2>&1
  ) </dev/null >/dev/null 2>&1; then
    nf_put "$stamp" "$mark" || true
  fi
  return 0
}

# --- the click --------------------------------------------------------------------------

# Wait for another process resolving this pane — a prime — instead of
# starting a second resolution beside it.
nf_wait_prime() {
  local lock="$NF_ROOT/panes/$NF_KEY.lock"
  nf_lock_live "$lock" 1 || return 0
  while nf_lock_live "$lock" 1; do
    nf_mine || return 1
    [ $(( $(nf_now_ms) - NF_START )) -lt "$NF_DL" ] || return 0
    nf_sleep 0.1
  done
  nf_mine
}

# Find the target: the entry when it is this pane's and decides something,
# otherwise the slow path. With $1 = 1 the entry is not trusted.
nf_target() {
  if [ "$1" != 1 ] && nf_entry_read && nf_decide; then
    return 0
  fi
  if [ "$1" != 1 ] && [ -n "${NF_ROOT:-}" ]; then
    nf_wait_prime || return 1
    if nf_entry_read && nf_decide; then
      return 0
    fi
  fi
  nf_slow || return 1
  nf_mine || return 1
  nf_decide
}

# The raise-and-follow loop: every 0.1 s ask whether the window's Space is a
# current one; while not, ask again 0.4 s after the last request, twice at most,
# and stop at 1.5 s. A raise that fails now ends the retries.
nf_follow() {
  local i=0 n=0 rc out now lim gap
  lim=$(nf_scaled_ms 1500)
  gap=$(nf_scaled_ms 400)
  # The iteration cap only backs up the clock.
  while [ "$i" -lt 30 ]; do
    nf_mine || return 0
    nf_ax onspace "$WID_X" >/dev/null
    rc=$?
    nf_trace "onspace $rc"
    [ "$rc" = 6 ] || return 0
    now=$(nf_now_ms)
    [ $((now - NF_T0)) -lt "$lim" ] || return 0
    if [ $((now - NF_TREQ)) -ge "$gap" ] && [ "$n" -lt 2 ]; then
      out=$(nf_ax raise "$NF_IPID" "$WID_X" ${NF_EID:+--eid "$NF_EID"} \
        --budget-ms 1000 --ceiling "$(nf_ceiling)")
      rc=$?
      nf_trace "raise $rc"
      nf_mine || return 0
      case "$rc" in
        0)
          nf_open
          NF_TREQ=$(nf_now_ms)
          nf_take_eid "$out"
          ;;
        4) nf_table_del "$WID_X"; return 0 ;;
        *) nf_log "raise $rc wid=$WID_X"; return 0 ;;
      esac
      n=$((n + 1))
    fi
    nf_sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Record the element id a raise printed, when it differs from the table.
nf_take_eid() {
  nf_is_num "$1" || return 0
  NF_EID=$1
  [ "$(nf_table_eid "$WID_X")" = "$1" ] && return 0
  nf_table_set "$WID_X" "$1"
}

# The switch, after tmux has been selected. Returns 10 when the target has to
# be resolved again.
#
# A NEWER CLICK WINS AT EVERY STEP THAT CAN BLOCK. The helper, the AppleScript
# selection and the resolver can each take a while, and a click that came in
# meanwhile has already moved the screen; so before each `open -b`, selection
# and guide that follows one of them, this click checks it is still the latest
# and stops when it is not.
nf_switch() {
  local out rc
  if ! NF_HX=$(nf_helper); then
    # No helper yet: tab and session only. A compiler builds one in the
    # background; without one the person is told how to get it.
    nf_show_rc "$WID_X" "$SID_X"
    rc=$?
    if nf_compiler; then
      if [ -n "${NF_ROOT:-}" ]; then
        nf_trace "build 띄움"
        nf_spawn build
      fi
    else
      nf_mine || return 0
      nf_guide clt
    fi
    return "$rc"
  fi
  NF_EID=$(nf_table_eid "$WID_X")
  nf_is_num "$NF_EID" || NF_EID=""
  out=$(nf_ax raise "$NF_IPID" "$WID_X" ${NF_EID:+--eid "$NF_EID"} \
    --budget-ms 1000 --ceiling "$(nf_ceiling)")
  rc=$?
  nf_trace "raise $rc"
  nf_mine || return 0
  case "$rc" in
    0)
      nf_open
      NF_TREQ=$(nf_now_ms)
      NF_T0=$NF_TREQ
      nf_show_rc "$WID_X" "$SID_X" || return $?
      nf_take_eid "$out"
      nf_follow
      return 0
      ;;
    3)
      # Not trusted: select the window too, and bring iTerm2 forward only when
      # that window is already on a current Space — `open -b` alone would go to
      # whichever Space iTerm2 last used. The guide is raised whatever the
      # selection did: a target that has to be resolved again is still a click
      # the missing permission stopped from switching.
      nf_show_rc "$WID_X" "$SID_X" w
      rc=$?
      nf_mine || return 0
      if [ "$rc" = 0 ]; then
        nf_ax onspace "$WID_X" >/dev/null
        out=$?
        nf_trace "onspace $out"
        [ "$out" = 0 ] && nf_open
      fi
      nf_guide ax
      return "$rc"
      ;;
    4)
      # The window is gone: forget it and resolve again, once.
      nf_table_del "$WID_X"
      [ "$NF_TRY" -lt 2 ] && return 10
      nf_show_rc "$WID_X" "$SID_X"
      return $?
      ;;
    5)
      return 0
      ;;
    8)
      nf_show_rc "$WID_X" "$SID_X"
      return $?
      ;;
    *)
      # 7 (AX cannot complete), 1, 2: nothing cached is touched.
      nf_show_rc "$WID_X" "$SID_X"
      rc=$?
      nf_log "raise $rc wid=$WID_X"
      return "$rc"
      ;;
  esac
}

nf_focus_body() {
  local force=0 rc
  NF_START=$(nf_now_ms)
  nf_trace "시작"
  nf_path_prepend
  NF_DL=$(nf_scaled_ms 10000)
  NF_ROOT=$(nf_root) || NF_ROOT=""
  NF_TOKEN="$$.$NF_START"
  if [ -n "$NF_ROOT" ]; then
    nf_put "$NF_ROOT/click.current" "$NF_TOKEN" || NF_ROOT=""
  fi
  NF_KEY=$(nf_key)
  NF_DIR=$(dirname "$(nf_self)")

  nf_tmux || return 0
  nf_pane_check || return 0
  nf_clients || return 0
  NF_IPID=$(nf_iterm_pid) || NF_IPID=""

  # iTerm2 is not running — a click must not launch it. tmux alone is moved.
  if [ -z "$NF_IPID" ]; then
    nf_mine || return 0
    "$NF_TM" -S "$NF_SOCK" select-window -t "$P_SID:$P_WID" || return 0
    "$NF_TM" -S "$NF_SOCK" select-pane -t "$NF_PANE" || return 0
    return 0
  fi

  NF_TRY=0
  while [ "$NF_TRY" -lt 2 ]; do
    NF_TRY=$((NF_TRY + 1))
    nf_target "$force" || return 0
    nf_mine || return 0
    # tmux first, then iTerm2. If the pane vanished in between, the click ends
    # here and iTerm2 is left alone.
    "$NF_TM" -S "$NF_SOCK" select-window -t "$P_SID:$P_WID" || return 0
    "$NF_TM" -S "$NF_SOCK" select-pane -t "$NF_PANE" || return 0
    nf_mine || return 0
    # Past the deadline only the selection is made; no Space moves.
    if [ $(( $(nf_now_ms) - NF_START )) -ge "$NF_DL" ]; then
      nf_show_rc "$WID_X" "$SID_X"
      return 0
    fi
    nf_switch
    rc=$?
    [ "$rc" = 10 ] || return 0
    force=1
  done
  return 0
}

nf_focus() {
  NF_SOCK="${1:-}"; NF_PID="${2:-}"; NF_PANE="${3:-}"
  exec </dev/null >/dev/null 2>&1
  nf_valid || exit 0
  if [ "${CC_CMDS_NOTIFY_FOCUS_FOREGROUND:-}" != 1 ]; then
    nf_spawn focus "$NF_SOCK" "$NF_PID" "$NF_PANE"
    exit 0
  fi
  nf_focus_body
  exit 0
}

# --- prime and build ------------------------------------------------------------------

nf_housekeep() {
  local f p
  find "$NF_ROOT/panes" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
  find "$NF_ROOT/panes" -mindepth 1 -maxdepth 1 -type d -name '*.lock' -mtime +0 \
    -exec rm -rf {} + 2>/dev/null
  # The table of an iTerm2 that is gone, with its attempt stamp and its lock.
  for f in "$NF_ROOT"/ax/*; do
    [ -e "$f" ] || continue
    p=${f##*/}
    p=${p%%.*}
    nf_is_num "$p" || continue
    ps -p "$p" >/dev/null 2>&1 || rm -rf "$f"
  done
}

nf_prime() {
  local lock out rc t
  NF_SOCK="${1:-}"; NF_PID="${2:-}"; NF_PANE="${3:-}"
  exec </dev/null >/dev/null 2>&1
  nf_valid || exit 0
  if [ "${CC_CMDS_NOTIFY_FOCUS_FOREGROUND:-}" != 1 ]; then
    nf_spawn prime "$NF_SOCK" "$NF_PID" "$NF_PANE"
    exit 0
  fi
  nf_path_prepend
  NF_DIR=$(dirname "$(nf_self)")
  # 1. A dead pane leaves nothing behind, not even the cache root.
  nf_tmux || exit 0
  nf_pane_check || exit 0
  NF_ROOT=$(nf_root) || exit 0
  NF_KEY=$(nf_key)
  nf_housekeep
  # 2. The helper, built here when missing. A prime raises no banner.
  if ! NF_HX=$(nf_helper); then
    nf_build || exit 0
    NF_HX=$(nf_helper) || exit 0
  fi
  # 3. One prime per pane, and none within a minute of the last resolution.
  lock="$NF_ROOT/panes/$NF_KEY.lock"
  nf_lock "$lock" 1 || exit 0
  if [ -n "$(find "$NF_ROOT/panes/$NF_KEY" -mmin -1 2>/dev/null)" ]; then
    nf_unlock "$lock"
    exit 0
  fi
  # 4. iTerm2 is asked nothing unless Apple events to it are already allowed:
  # a lineage without that permission would get a prompt at night.
  nf_ax aecheck >/dev/null
  if [ $? -ne 0 ]; then
    nf_unlock "$lock"
    exit 0
  fi
  # 5. Resolve and write the entry.
  if nf_clients; then
    nf_slow || true
  fi
  nf_unlock "$lock"
  # 6. The element table, when the helper is trusted and the table is not
  # fresh. Only a complete scan replaces it.
  nf_ax trusted >/dev/null
  [ $? -eq 0 ] || exit 0
  NF_IPID=$(nf_iterm_pid) || exit 0
  t=$(nf_table)
  nf_map_fresh "$t" && exit 0
  # ONE SCAN PER iTerm2 AT A TIME, AND NONE WITHIN A MINUTE OF THE LAST TRY.
  # The table is shared by every pane, so primes of different panes would each
  # scan it; and a scan that ran out of budget writes no table, so without a
  # record of the attempt every later banner would scan again.
  nf_lock "$t.lock" 1 || exit 0
  if nf_map_fresh "$t"; then
    nf_unlock "$t.lock"
    exit 0
  fi
  nf_put "$t.tried" "$(date +%s)
" || true
  out=$(nf_ax map "$NF_IPID" --budget-ms 5000 --ceiling "$(nf_ceiling)")
  rc=$?
  nf_trace "map $rc"
  if [ "$rc" -eq 0 ]; then
    out=$(printf '%s\n' "$out" | awk -F "$TAB" -v OFS="$TAB" '
      NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print; if ($2 + 0 > m) m = $2 + 0 }
      END { print "max " m + 0 }')
    nf_put "$t" "$out
" || true
  fi
  nf_unlock "$t.lock"
  exit 0
}

# The table was written, or a scan of it was tried, within the last minute.
nf_map_fresh() {
  [ -n "$(find "$1" -mmin -1 2>/dev/null)" ] && return 0
  [ -n "$(find "$1.tried" -mmin -1 2>/dev/null)" ]
}

nf_build_verb() {
  exec </dev/null >/dev/null 2>&1
  nf_path_prepend
  NF_DIR=$(dirname "$(nf_self)")
  NF_ROOT=$(nf_root) || exit 0
  nf_build || true
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
  prime)
    shift
    nf_prime "$@"
    ;;
  build)
    nf_build_verb
    ;;
esac
exit 0
