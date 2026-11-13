#!/usr/bin/env bash
# statusline.sh — the one line the harness renders for this session.
#
# TOTALITY IS THE CONTRACT, not a nicety. This runs on every render in whatever
# directory the user happens to be in, so there is no failure it may propagate:
# a missing `jq`, a truncated stdin, an unreadable run directory and an absent
# sibling library all have to come out as a valid line and `exit 0`. `set -e` is
# deliberately absent for the same reason — an unguarded non-zero from any of
# the dozen reads below would otherwise leave the harness with no line at all.
#
# THE SIBLING SOURCE IS THE HOLE THE INSTALLED GUARD CANNOT SEE. The command in
# `settings.json` tests `[ -x statusline.sh ]`, which passes on a partial
# checkout that has this file and not `liveness.sh`; the source then fails and
# without the guard below there would be neither output nor fallback. Every
# caller EXECUTES this file — the agreement suite runs it as `bash "$SL"` — and
# none sources it; one could not, because stdin is read before the sibling
# source. The resolution still uses `$BASH_SOURCE` rather than `$0`, which costs
# nothing and names this file under either seam.
#
# NOTHING HERE WRITES. Every run predicate comes from `liveness.sh`, which
# exists so that this file, the watcher and the gate answer "is this run still
# going?" with one implementation instead of three that drift. The one verdict
# that does not is the borrow segment's: it is a jq-free mirror of
# `rt_borrow_read` in `route.sh`, and the suite's live route equivalence cases
# are what tie the two together.
#
# A FINISHED RUN THAT CANNOT WIN IS NOT JUDGED, AND THAT IS COMPUTED, NOT
# CACHED. The selection below screens out dormant runs — no pid that answers,
# no ledger or heartbeat inside the dormancy window — from the file times and
# the process table on every call, and judges one only when it could still take
# the line. Nothing is kept between calls, so a ledger that grows again puts its
# run back into the judgement on the next render.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.
# No `date -r` or `date -d` either: the two date implementations disagree on
# both, so the one epoch this file formats goes through the shell arithmetic of
# `display-tz.sh`, in the display zone the pane and the feed also use.

set -uo pipefail

# The "no run" line and the fallback line are THE SAME BYTES ON A MACHINE WHERE
# THE APPLY FOUND A COMMAND TO REPLACE, deliberately, and that scope is part of
# the claim rather than a caveat on it. There the replaced command becomes the
# wrapper's `||` fallback, so a session with no run of its own renders exactly
# what was on screen before this script was ever installed — installing it is
# invisible until it has something to say, and every degraded path lands on that
# one shape rather than on a second, subtly different one a reader would have to
# learn.
#
# ON A MACHINE THAT HAD NO STATUS LINE THE TWO ARE NOT THE SAME BYTES, and that
# difference is accepted rather than repaired. The fallback there is `true` and
# emits nothing while this line emits its glyph, so the two branches of the
# installed guard are separable by output alone — which is exactly what lets the
# installer's pre-commit verify run tell a live guard from a dead one, and that
# first install is the only path it still runs on. Matching the bytes would buy
# an invisibility nobody on that machine can observe, since there was no previous
# line to be invisible against, and would pay for it with the one check that
# catches a guard installed permanently false.
#
# THAT PROMISE IS SCOPED TO "NO BORROW TO SHOW". When the borrow verdict below
# is "nothing", every path prints today's bytes exactly. Otherwise the output is
# today's output with exactly the borrow segment appended — with one exception:
# the 도는중 arm may drop more of its run slots so that the borrow mark fits.
#
# THE FORMAT STRING IS COPIED FROM THE COMMAND THIS REPLACES, escapes included.
# The colour is not decoration: for the population above, a version of this line
# without the escapes gives "nothing to say" two different renderings — the
# second shape the first paragraph exists to prevent, reintroduced by the very
# function meant to prevent it. The suite reads the reference out of the install
# target and runs it rather than transcribing the bytes, because a transcription
# is how the escapes went missing here while every case stayed green.
#
# No trailing newline: the command this replaces ends its format string at `%s`,
# and the suite asserts byte-identity against that output. The installer's verify
# run asserts nothing of the kind — its five conditions ask whether a line can be
# rendered at all, not whether it matches a particular one.
emit_fallback() {
  printf '\033[36m[cc🎨]\033[0m %s' "${PWD##*/}"
}

# A whole-slot budget, because there is no width to measure against: `$COLUMNS`
# is not exported into a child and `tput cols` answers a wrong number with a
# success code. Overflow drops low-priority slots ENTIRELY — a glyph cut in half
# is worse than a fact omitted. The order is the borrow detail first (its clock
# or its gloss), then the 도는중 kind, then the elapsed; the borrow MARK is never
# dropped, so a line may run past the budget. Every judgement is the one sum
# `${#line} + ${#SL_BORROW_SEG}`, and the watcher slot is not in it — the
# undercount is at most ` · 워처 미기동`. Defined up here because the fallback
# exits below already measure against it.
CC_SL_BUDGET=72

# ---------------------------------------------------------------------------
# The borrow segment.
# ---------------------------------------------------------------------------
#
# A SUFFIX AND NOTHING ELSE. While cc-lane has lent this lane another account,
# every line this script prints — the fallback, the no-run line, every run arm —
# gets ` · <mark>[<detail>]` after the bytes it prints today; with nothing to
# show the segment is the empty string and the output is today's to the byte.
# It is computed once, before the first exit, because the two exits just below
# fire before the sibling source — and for the same reason nothing here comes
# from `liveness.sh`, so a partial checkout still shows it.
#
# THE READER MIRRORS `rt_borrow_read` IN route.sh, WITHOUT jq. Spawning
# `route.sh borrow-read` costs jq and route.sh every ten seconds and breaks the
# no-jq property the suite pins. The mirror is SOUND on every input: whenever it
# shows a segment, `borrow-read` names the same state and the same donor. It is
# complete only over the grammar cc-lane writes. Outside it — over 64 KiB, raw
# tabs or a CRLF layout, a backslash in one of the five verdict strings,
# surrogate escapes, numbers only jq accepts, nesting past 32 — it shows nothing
# where route may say borrowing, and the suite pins each of those as a one-way
# row. The direction of error is always "show nothing".

SL_BORROW_SCHEMA='"cc-lane-borrow v1"'
# One alternative per JSON token, the last one a single stray byte, so that
# anything outside the grammar becomes a junk token the walker refuses.
SL_BORROW_TOK='"([^"\\]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null|[^[:space:]]'
# Raw C0 bytes other than LF. grep does not decode octal escapes, so the class is
# built by the shell.
SL_BORROW_C0=$'[\001-\011\013-\037]'

sl_borrow_path() {
  # sl_borrow_path — SL_BFILE is the record's absolute path, by the rule of
  # `route__borrow_path`: a non-empty `XDG_STATE_HOME`, else a non-empty `HOME`
  # under `.local/state`, and only when that base is absolute. The `:-` idiom the
  # run index uses below is NOT reused: it accepts a relative XDG and turns an
  # empty `HOME` into `/.local/state`.
  SL_BFILE=
  local base
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    base="$XDG_STATE_HOME"
  elif [ -n "${HOME:-}" ]; then
    base="$HOME"
  else
    return 1
  fi
  case "$base" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -z "${XDG_STATE_HOME:-}" ]; then base="$base/.local/state"; fi
  SL_BFILE="$base/cc-lane/borrow.json"
}

sl_borrow_key() {
  # sl_borrow_key <key token> — SL_BKEY is the key as the walker's paths spell it.
  #
  # jq decodes keys, so a key that spells one of its letters as a unicode escape
  # IS that key to route, and a later duplicate spelled that way would override
  # the verdict behind this reader's back. So a
  # key carrying an escape is decoded just far enough to tell whether it names a
  # field the verdict reads. Every such field is spelled in `[a-z_]`; an escape
  # decoding to anything else becomes `#`, which none of them contains.
  local k="$1" out="" c h i=0 n code
  local lower=abcdefghijklmnopqrstuvwxyz
  case "$k" in
    *\\*) ;;
    *) SL_BKEY="$k"; return 0 ;;
  esac
  k=${k#\"}; k=${k%\"}
  n=${#k}
  while [ "$i" -lt "$n" ]; do
    c=${k:$i:1}
    if [ "$c" != '\' ]; then
      out="$out$c"; i=$((i + 1)); continue
    fi
    if [ "${k:$((i + 1)):1}" = u ]; then
      h=${k:$((i + 2)):4}
      code=$((16#$h))
      if [ "$code" -eq 95 ]; then out="${out}_"
      elif [ "$code" -ge 97 ] && [ "$code" -le 122 ]; then out="$out${lower:$((code - 97)):1}"
      else out="${out}#"; fi
      i=$((i + 6))
    else
      out="${out}#"; i=$((i + 2))
    fi
  done
  SL_BKEY="\"$out\""
}

sl_borrow_walk() {
  # sl_borrow_walk — the grammar, over the caller's `toks`, filling the caller's
  # `s_*` and `donor_obj`. A frame stack of indexed arrays, one top-level object,
  # nothing after it, depth at most 32. Leaves are recorded by key path; a
  # duplicate key's last value wins and a value that starts again clears what was
  # recorded under it, both as jq does. Returns 1 on the first token the grammar
  # refuses.
  #
  # Array elements are always read as `${a[i]-}`: under `set -u` a missing one is
  # an "unbound variable" that ends this script with no line and rc 1, which the
  # totality contract above forbids.
  local tok IFS=$'\n'
  for tok in $toks; do
    case "$exp" in
      DONE) return 1 ;;
      V|VE)
        if [ "$exp" = VE ] && [ "$tok" = ']' ]; then
          d=$((d - 1))
          if [ "$d" -eq 0 ]; then exp=DONE; else exp=CE; fi
          continue
        fi
        if [ "$d" -eq 0 ] && [ "$tok" != '{' ]; then return 1; fi
        case "$vpath" in
          '."schema"') s_schema= ;;
          '."state"') s_state= ;;
          '."lane_config_dir"') s_lane= ;;
          '."donor"') s_did=; s_ddir=; donor_obj=0 ;;
          '."donor"."id"') s_did= ;;
          '."donor"."config_dir"') s_ddir= ;;
          '."trigger_window"') s_tw= ;;
          '."home_windows"') s_r5=; s_r7= ;;
          '."home_windows"."five_hour"'|'."home_windows"."five_hour"."resets_at_epoch"') s_r5= ;;
          '."home_windows"."seven_day"'|'."home_windows"."seven_day"."resets_at_epoch"') s_r7= ;;
        esac
        case "$tok" in
          '{')
            d=$((d + 1)); [ "$d" -le 32 ] || return 1
            ST_T[$d]=o; ST_P[$d]="$vpath"; ST_K[$d]=
            if [ "$vpath" = '."donor"' ] && [ "$d" -eq 2 ]; then donor_obj=1; fi
            exp=KE
            continue
            ;;
          '[')
            d=$((d + 1)); [ "$d" -le 32 ] || return 1
            ST_T[$d]=a; ST_P[$d]="$vpath"; ST_K[$d]=
            vpath="$vpath[]"
            exp=VE
            continue
            ;;
          # A multi-byte token starting with a digit or `-` can only be the
          # number alternative's, so its shape is already the grammar's; a single
          # stray `-` is not.
          '"'*'"'|true|false|null|[0123456789]|[-0123456789]?*) ;;
          *) return 1 ;;
        esac
        case "$vpath" in
          '."schema"') s_schema="$tok" ;;
          '."state"') s_state="$tok" ;;
          '."lane_config_dir"') s_lane="$tok" ;;
          '."donor"."id"') s_did="$tok" ;;
          '."donor"."config_dir"') s_ddir="$tok" ;;
          '."trigger_window"') s_tw="$tok" ;;
          '."home_windows"."five_hour"."resets_at_epoch"') s_r5="$tok" ;;
          '."home_windows"."seven_day"."resets_at_epoch"') s_r7="$tok" ;;
        esac
        if [ "$d" -eq 0 ]; then exp=DONE; else exp=CE; fi
        ;;
      KE|K)
        if [ "$exp" = KE ] && [ "$tok" = '}' ]; then
          d=$((d - 1))
          if [ "$d" -eq 0 ]; then exp=DONE; else exp=CE; fi
          continue
        fi
        case "$tok" in
          '"'*'"') sl_borrow_key "$tok"; ST_K[$d]="$SL_BKEY"; exp=C ;;
          *) return 1 ;;
        esac
        ;;
      C)
        [ "$tok" = ':' ] || return 1
        vpath="${ST_P[$d]-}.${ST_K[$d]-}"
        exp=V
        ;;
      CE)
        case "$tok" in
          ',')
            if [ "${ST_T[$d]-}" = o ]; then exp=K; else exp=V; vpath="${ST_P[$d]-}[]"; fi
            ;;
          '}')
            [ "${ST_T[$d]-}" = o ] || return 1
            d=$((d - 1))
            if [ "$d" -eq 0 ]; then exp=DONE; else exp=CE; fi
            ;;
          ']')
            [ "${ST_T[$d]-}" = a ] || return 1
            d=$((d - 1))
            if [ "$d" -eq 0 ]; then exp=DONE; else exp=CE; fi
            ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done
  [ "$exp" = DONE ] && [ "$d" -eq 0 ]
}

sl_borrow_read() {
  # sl_borrow_read <file> — the verdict on an already-guarded record. Returns 0
  # and sets SL_B_STATE (intent, borrowed or returning), SL_B_LANE, SL_B_DID,
  # SL_B_DDIR and SL_B_RESET (an epoch, or empty) when route would call the
  # record borrowing; returns 1 with all five empty otherwise.
  SL_B_STATE=; SL_B_LANE=; SL_B_DID=; SL_B_DDIR=; SL_B_RESET=
  local f="$1" toks rc exp=V d=0 vpath="" k
  local s_schema="" s_state="" s_lane="" s_did="" s_ddir="" s_tw="" s_r5="" s_r7="" donor_obj=0
  local -a ST_T ST_P ST_K
  ST_T=(); ST_P=(); ST_K=()
  # Byte refusals over the whole file: raw C0 other than LF, and a surrogate
  # escape. jq takes a tab or a CR as whitespace; this reader does not, which is
  # one of the named one-way rows.
  if LC_ALL=C grep -q -e "$SL_BORROW_C0" -e '\\u[dD][89a-fA-F]' "$f" 2>/dev/null; then
    return 1
  fi
  toks=$(LC_ALL=C grep -o -E "$SL_BORROW_TOK" "$f" 2>/dev/null) || return 1
  [ -n "$toks" ] || return 1
  # The walker splits on newlines with globbing off: `*` is a junk token the
  # grammar must see as itself, not as the working directory.
  set -f
  sl_borrow_walk; rc=$?
  set +f
  [ "$rc" -eq 0 ] || return 1
  # The predicate, on raw tokens. The three strings used as values must carry no
  # backslash: decoding them would buy nothing cc-lane writes, and a quote or a
  # backslash could not pass the id check anyway. schema and state are compared
  # with exact literals, so an escape there already fails.
  [ "$s_schema" = "$SL_BORROW_SCHEMA" ] || return 1
  case "$s_state" in
    '"intent"'|'"borrowed"'|'"returning"') ;;
    *) return 1 ;;
  esac
  [ "$donor_obj" = 1 ] || return 1
  for k in "$s_lane" "$s_did" "$s_ddir"; do
    case "$k" in
      *\\*|'""') return 1 ;;
      '"'*'"') ;;
      *) return 1 ;;
    esac
  done
  SL_B_STATE=${s_state//\"/}
  SL_B_LANE=${s_lane#\"}; SL_B_LANE=${SL_B_LANE%\"}
  SL_B_DID=${s_did#\"}; SL_B_DID=${SL_B_DID%\"}
  SL_B_DDIR=${s_ddir#\"}; SL_B_DDIR=${SL_B_DDIR%\"}
  # The reset is the epoch of the window the trigger names, and only a plain
  # integer of at most twelve digits. Any other trigger, or any other value, is
  # "no value": the clock goes and the mark stays.
  case "$s_tw" in
    '"five_hour"') k="$s_r5" ;;
    '"seven_day"') k="$s_r7" ;;
    *) k="" ;;
  esac
  case "$k" in
    ''|*[!0123456789]*) ;;
    *) [ "${#k}" -le 12 ] && SL_B_RESET="$k" ;;
  esac
  return 0
}

sl_borrow_clock() {
  # sl_borrow_clock — SL_BORROW_CLOCK for the lane view of `borrowed`, or empty.
  # The time is in the display zone (`CC_CMDS_AUTOPILOT_TZ`, KST by default) and
  # carries no zone label — the line's width budget is tight. The host `TZ` has
  # no say, so this clock and the pane agree for one setting. Output of any
  # other shape is no clock. With no helper loaded (`SL_DTZ` unset) the clock is
  # empty and the rest of the segment still draws. "Within 24 hours" is strict:
  # exactly 86400 seconds out as `HH:MM` would read as now.
  SL_BORROW_CLOCK=
  local e="$SL_B_RESET" now out
  [ -n "$e" ] || return 0
  [ "${SL_DTZ:-0}" = 1 ] || return 0
  now=$(date -u +%s)
  case "$now" in
    ''|*[!0123456789]*) return 0 ;;
  esac
  if [ "$e" -le "$now" ]; then
    SL_BORROW_CLOCK="홈 리셋 지남"
    return 0
  fi
  out=$(cc_display_mdhm "$e" 2>/dev/null)
  case "$out" in
    [0-9][0-9]/[0-9][0-9]\ [0-9][0-9]:[0-9][0-9])
      if [ $((e - now)) -lt 86400 ]; then
        SL_BORROW_CLOCK="홈 ${out#* }"
      else
        SL_BORROW_CLOCK="홈 $out"
      fi
      ;;
  esac
}

sl_json_str_into() {
  # sl_json_str_into <key> <var> — sets <var> to the string value of "<key>" in
  # `stdin_json`, or to empty. It is the value
  # `sed -n 's/.*"<key>"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1`
  # gives, without its three processes: the first line that matches, and on that
  # line the last occurrence, because the leading `.*` is the longest one and
  # the trailing `.*` makes the whole line the match, as it is for sed. The
  # lines are split on newlines with globbing off, not read from a here-document,
  # which bash 3.2 backs with a temporary file. The pattern sits in a variable
  # and is used unquoted, the one spelling bash 3.2 and later read alike.
  local re line IFS=$'\n'
  re='^.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*$'
  printf -v "$2" '%s' ''
  set -f
  for line in $stdin_json; do
    if [[ $line =~ $re ]]; then
      printf -v "$2" '%s' "${BASH_REMATCH[1]}"
      break
    fi
  done
  set +f
}

sl_borrow_compute() {
  # sl_borrow_compute — SL_BORROW_SEG (the full segment) and SL_BORROW_SHORT (the
  # same with its detail dropped), both empty when there is nothing to show.
  #
  # WHOSE SESSION THIS IS. A non-empty `CLAUDE_CONFIG_DIR` is the session's
  # config directory; otherwise `transcript_path` on stdin names it when it
  # starts with one of the record's two directories plus `/projects/`. Both
  # compares are exact strings — no trailing-slash trim, no realpath — as route's
  # own mark is. The lane view wins when both match. Only `donor.config_dir` is
  # the donor: the record's `donor.group` names accounts that lent nothing.
  #
  # A session with no record pays two tests and no fork; the transcript is read
  # only past the file guard for that reason.
  SL_BORROW_SEG=; SL_BORROW_SHORT=
  local f n cfg="${CLAUDE_CONFIG_DIR-}" tp="" view="" id mark="" detail=""
  sl_borrow_path || return 0
  f="$SL_BFILE"
  # Before opening: a symlink is nothing, and so is anything not a readable
  # regular file — a FIFO is never opened. The size bounds the parse.
  [ -L "$f" ] && return 0
  { [ -f "$f" ] && [ -r "$f" ]; } || return 0
  n=$(( $( { wc -c < "$f"; } 2>/dev/null ) ))
  { [ "$n" -ge 1 ] && [ "$n" -le 65536 ]; } || return 0
  if [ -n "$cfg" ]; then
    # A substring prefilter, deliberately unquoted: it cannot reject a record the
    # exact compare below would accept.
    grep -qF -- "$cfg" "$f" 2>/dev/null || return 0
  else
    sl_json_str_into transcript_path tp
    [ -n "$tp" ] || return 0
  fi
  sl_borrow_read "$f" || return 0
  if [ -n "$cfg" ]; then
    if [ "$cfg" = "$SL_B_LANE" ]; then view=lane
    elif [ "$cfg" = "$SL_B_DDIR" ]; then view=donor
    fi
  else
    case "$tp" in
      "$SL_B_LANE"/projects/*) view=lane ;;
      "$SL_B_DDIR"/projects/*) view=donor ;;
    esac
  fi
  [ -n "$view" ] || return 0
  # The donor id goes on the terminal only in a shape that cannot carry an
  # escape or a control byte. The class is spelled out rather than ranged, since
  # a range in a UTF-8 locale follows collation and can admit other letters.
  id="$SL_B_DID"
  case "$id" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) id='?' ;;
  esac
  [ "${#id}" -le 32 ] || id='?'
  if [ "$view" = lane ]; then
    case "$SL_B_STATE" in
      intent) mark="cc→${id}?"; detail=" (차용 확인 중)" ;;
      borrowed)
        mark="cc→${id}"
        sl_borrow_clock
        if [ -n "$SL_BORROW_CLOCK" ]; then detail=" · ${SL_BORROW_CLOCK}"; fi
        ;;
      returning) mark="cc←${id}"; detail=" (반환 중)" ;;
    esac
  else
    case "$SL_B_STATE" in
      intent) mark="빌려 줌→cc?"; detail=" (차용 확인 중)" ;;
      borrowed) mark="빌려 줌→cc" ;;
      returning) mark="빌려 줌←cc"; detail=" (반환 중)" ;;
    esac
  fi
  [ -n "$mark" ] || return 0
  SL_BORROW_SHORT=" · ${mark}"
  SL_BORROW_SEG="${SL_BORROW_SHORT}${detail}"
}

sl_exit_fallback() {
  # sl_exit_fallback — every early exit, so the fallback carries the segment too.
  # The width judged is the fallback's visible text; its two escapes print
  # nothing.
  local fb="[cc🎨] ${PWD##*/}"
  if [ $(( ${#fb} + ${#SL_BORROW_SEG} )) -gt "$CC_SL_BUDGET" ]; then
    SL_BORROW_SEG="$SL_BORROW_SHORT"
  fi
  emit_fallback; printf '%s' "$SL_BORROW_SEG"; exit 0
}

# Read here, before the sibling source, so that the two exits just below can
# still carry the segment. Every caller hands this script a closed stdin, which
# the render path already depended on at its old place further down.
stdin_json=$(cat 2>/dev/null || true)
sl_borrow_compute

sl_dirname_into() {
  # sl_dirname_into <path> <var> — sets <var> to what `dirname <path>` prints:
  # trailing slashes go, then the last component and the slashes before it; a
  # path with no slash is `.`, and one that leaves nothing is `/`.
  local p="$1"
  while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p=${p%/}; done
  case "$p" in
    */*)
      p=${p%/*}
      while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p=${p%/}; done
      [ -n "$p" ] || p=/
      ;;
    *) p=. ;;
  esac
  printf -v "$2" '%s' "$p"
}

# The outer `$( )` stays: `cd` inside it leaves this shell's `PWD` alone.
sl_dirname_into "${BASH_SOURCE[0]:-$0}" sl_src_dir
CC_SL_DIR=$(cd "$sl_src_dir" 2>/dev/null && pwd) \
  || sl_exit_fallback
# The display zone for the borrow clock, sourced beside `liveness.sh` and ahead
# of it so that its fallback exit still carries the clock. A failed source
# empties that clock and nothing else, so it does not fall back. The segment
# was computed before the directory was known, so a session with a segment
# computes it once more now that the clock can be drawn.
SL_DTZ=0
# shellcheck source=./display-tz.sh
if . "$CC_SL_DIR/display-tz.sh" 2>/dev/null; then
  cc_display_tz_load && SL_DTZ=1
  [ -n "$SL_BORROW_SEG" ] && sl_borrow_compute
fi
# shellcheck source=./liveness.sh
. "$CC_SL_DIR/liveness.sh" 2>/dev/null || sl_exit_fallback

# The staleness mark, and why it is not the watcher's.
#
# 180 seconds is now the ORDER BOUNDARY, and it stopped being free to get wrong.
# It separates rank 3 from rank 4 — a run whose ledger moved inside the mark
# stands above one that did not, and BOTH of them stand above every finished run
# in this session. What getting it wrong costs is therefore no longer the
# screen: it is the order and the glyph among the runs that are still going.
# `CC_SL_ABANDON` is the mark that hands the line to a finished run, and this
# one is not.
#
# The watcher's stall arm still sits at 1200 because what IT writes is a ledger
# row that only a person's resolving row takes back. Two different costs, two
# constants; pinning them to each other is the one change this file must never
# accept, and the boundary above makes that more true rather than less.
CC_SL_STALL=180

# Past this, a quiet run is not stalled but abandoned. It is the render boundary
# AND the order boundary: 정지경고 ranks above 종단 and 버려짐 ranks below it, so
# crossing this mark is precisely what drops a quiet run beneath every finished
# run in the session. Passed explicitly on every call so this consumer and the
# watcher cannot grade one run by two thresholds; the default lives beside
# `cc_run_state` in `liveness.sh` and is the same number.
#
# Not finely tuned, and it must not be read as if it were. Sweeping the
# threshold from 300 to 86400 moved the abandoned count on this host from 73 to
# 71 — under a day's idle tops out at 82804s and over a day's starts at
# 145549s, so the whole range between them is empty. Any value above the 900s
# floor (below it, an existing case that pins a 900s-idle run to 정지경고 goes
# red) gives the same verdicts here.
CC_SL_ABANDON=3600

# Twice the watcher's pinned `--interval`. The launch line fixes that value at
# 60 precisely so this threshold can be read off a contract instead of guessed.
CC_SL_HEARTBEAT_STALE=120

age_phrase() {
  # age_phrase <seconds> — SL_AGE is a short human duration.
  local s="$1"
  if   [ "$s" -lt 60 ];   then printf -v SL_AGE '%s초 전' "$s"
  elif [ "$s" -lt 3600 ]; then printf -v SL_AGE '%s분 전' "$((s / 60))"
  else                         printf -v SL_AGE '%s시간 전' "$((s / 3600))"
  fi
}

sl_read_value_into() {
  # sl_read_value_into <file> <var> — sets <var> to the value `$(cat <file>)`
  # gives, read with the `read` builtin when the file is one line, with or
  # without its final newline. A file with a second line, or one that cannot be
  # opened as a regular readable file, keeps the `cat` value.
  local l1="" l2=""
  if [ -f "$1" ] && [ -r "$1" ]; then
    { if IFS= read -r l1; then
        if IFS= read -r l2 || [ -n "$l2" ]; then l2=more; fi
      fi; } 2>/dev/null < "$1"
  else
    l2=more
  fi
  if [ -n "$l2" ]; then
    l1=$(cat "$1" 2>/dev/null || true)
  fi
  printf -v "$2" '%s' "$l1"
}

newest_stage_pid() {
  # newest_stage_pid <run-dir> — SL_SLOT is "<segment> <pid>" for the most
  # recently recorded stage that is STILL RUNNING, or empty.
  #
  # A LABEL IS STILL A CLAIM. Picking on mtime alone was defended as "only a
  # name, not a judgement", but a name beside a spinning glyph reads as "this
  # one is running" to the person at 3am, and mtime picks the wrong one in the
  # ordinary case: the stage that just ENDED owns the newest pid file. `date -r`
  # also has one-second resolution, so ties are common and the glob order — not
  # the clock — decided them.
  #
  # Filtering here adds no second copy of the predicate. `cc_stage_is_live` is
  # what `cc_live_stages` counts with, asked about one pid instead of all of
  # them, so the name on the line and the count behind it come from one
  # implementation rather than two that agree today.
  local run_dir="$1" f seg t best_t=-1 best="" p
  SL_SLOT=""
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    # `watch.pid` shares the glob and is not a stage.
    [ "$seg" = "watch" ] && continue
    cc_stage_is_live "$run_dir" "$seg" || continue
    t=$(cc_mtime "$f"); [ -n "$t" ] || t=0
    if [ "$t" -gt "$best_t" ]; then best_t=$t; best=$seg; fi
  done
  [ -n "$best" ] || return 0
  sl_read_value_into "$run_dir/$best.pid" p
  SL_SLOT="$best $p"
}

# ---------------------------------------------------------------------------
# Resolve this session's run.
# ---------------------------------------------------------------------------

# A shell match, not `jq`. The field is one flat string, this runs every ten
# seconds, and a scenario in which `jq` is absent must still resolve the run
# rather than merely avoid crashing — spending a process on a lookup a
# substring answers would buy nothing and lose that.
sl_json_str_into session_id sid
[ -n "$sid" ] || sl_exit_fallback

CC_SL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
idx="$CC_SL_STATE/session/$sid"
[ -f "$idx" ] || sl_exit_fallback

# The index is a LIST — one run id per line, appended and deduped by the gate.
# A session holds several runs across a night, and the order is a SIX-RANK
# GRADE rather than the two classes this comment used to describe. It ranked on
# "shows no sign of having finished", which sounds like liveness and is not: a
# run that never opened a segment can never satisfy the derived terminal test
# and has no `done` file either, so it was permanently non-terminal and held its
# session forever. `cc_run_grade` ranks on evidence instead — live stage, then
# waiting approval, then a ledger that moved inside `CC_SL_STALL`, then one that
# passed `CC_SL_STALL` but not `CC_SL_ABANDON`, then finished, then gone quiet
# past `CC_SL_ABANDON`. Recency is the tie-break INSIDE a rank and never
# across two. Entries whose directory is gone are skipped HERE rather than
# pruned, because this file writes nothing by contract; the pruning belongs to
# the gate, which does it on a sparse cycle beside the reclamation that removed
# those directories in the first place.
#
# A DORMANT RUN IS NOT JUDGED UNLESS IT COULD WIN, and nothing about that is
# remembered. Judging a run spawns several processes that read its ledger, so a
# session that had piled up finished runs paid for every one of them on every
# render — measured, a 24-run session under heavy load took the pane helper 40
# seconds against its 8-second limit. A run is DORMANT when all four of these
# hold, and then `cc_run_state` can only give it rank 5 or 6:
#
#   1. no `*.pid` in its directory (any name, `watch.pid` included) names a pid
#      that answers `kill -0` — no fingerprint, so a reused pid only costs a
#      judgement;
#   2. no `*.waiting` marker's last `보유자=` pid answers `kill -0`;
#   3. `shift.live` is absent, or its first-line pid does not answer;
#   4. the ledger and `watch.heartbeat`, whichever exist, are both older than the
#      dormancy window: `CC_SL_ABANDON` rounded up to minutes, plus one.
#
# Every rank-4-or-better arm of `cc_run_state` needs one of those: a live stage
# or a fresh waiter for 도는중, a live shift for a settling `done`, a heartbeat
# inside 120 seconds for rank 2, and a growth time inside `CC_SL_ABANDON` for the
# rest — and the heartbeat's `마지막성장` is written before the heartbeat file, so
# it is never later than that file's mtime. The test is conservative: a run it
# fails to call dormant is judged as before, at a cost and never a wrong line.
# Conditions 1-3 use shell builtins only; condition 4 is one `find` over the
# whole index, so the screening costs a constant number of processes. A file
# dated in the future is inside the window and so not dormant.
#
# THE ORDER THEN KEEPS THE RESULT THAT OF JUDGING EVERY RUN. Non-dormant runs are
# judged first, in index order. If the best of them has rank 4 or better no
# dormant run can beat it and none is judged. Otherwise the dormant runs are
# walked newest clock first (`done`, else the ledger — one `ls -t`), and the walk
# stops at the first whose clock is older than the best so far once that best
# has rank 5 or better: a terminal run there loses on time, and anything else on
# rank. Equal clocks keep walking, because the index order still decides them.
# A `find` or `ls` that fails turns the shortcut off for this render.
#
# Two read-only knobs, read like `CC_SL_PANE_FIELDS`: `CC_SL_SCREEN=0` turns the
# screening off (every run is judged), which is what the suite compares the
# default output against; `CC_SL_TRACE=1` writes `cc-sl-derive <run id>` to
# stderr each time a run is judged, which is what it counts.
sl_screen=1; [ "${CC_SL_SCREEN:-}" = "0" ] && sl_screen=0
sl_trace=0; [ "${CC_SL_TRACE:-}" = "1" ] && sl_trace=1
best_rd=""; best_rid=""; best_state=""; best_ledger=""; best_t=-1; best_rank=9; best_i=-1
now=$(date -u +%s)

# WHAT ONE RENDER ASKS TWICE IT ASKS ONCE. The grade of a token, the mtime of a
# path and the ledger growth of an index position are kept in indexed arrays
# for the rest of this process and nowhere else, so nothing outlives the
# render and the contract above stands. The grade table itself stays in
# `liveness.sh`; these arrays hold its answers, not a copy of it.
sl_gk=(); sl_gv=(); sl_mk=(); sl_mv=(); sl_gw=(); sl_gws=()

sl_grade_into() {
  # sl_grade_into <token> <var> — sets <var> to `cc_run_grade <token>`.
  local j=0 v
  while [ "$j" -lt "${#sl_gk[@]}" ]; do
    if [ "${sl_gk[$j]}" = "$1" ]; then printf -v "$2" '%s' "${sl_gv[$j]}"; return 0; fi
    j=$((j + 1))
  done
  v=$(cc_run_grade "$1" 2>/dev/null || true)
  sl_gk[${#sl_gk[@]}]=$1; sl_gv[${#sl_gv[@]}]=$v
  printf -v "$2" '%s' "$v"
}

sl_mtime_into() {
  # sl_mtime_into <path> <var> — sets <var> to `cc_mtime <path>`. A path that
  # is not a regular file is empty without a fork, as `cc_mtime` answers it.
  local j=0 v=""
  while [ "$j" -lt "${#sl_mk[@]}" ]; do
    if [ "${sl_mk[$j]}" = "$1" ]; then printf -v "$2" '%s' "${sl_mv[$j]}"; return 0; fi
    j=$((j + 1))
  done
  [ -f "$1" ] && v=$(cc_mtime "$1")
  sl_mk[${#sl_mk[@]}]=$1; sl_mv[${#sl_mv[@]}]=$v
  printf -v "$2" '%s' "$v"
}

sl_growth_into() {
  # sl_growth_into <index position> <var> — sets <var> to
  # `cc_ledger_growth_at` of that run, computed once per position.
  local i="$1" v
  if [ "${sl_gws[$i]-}" = 1 ]; then printf -v "$2" '%s' "${sl_gw[$i]-}"; return 0; fi
  v=$(cc_ledger_growth_at "${sl_rd[$i]}" "${sl_led[$i]}")
  sl_gw[$i]=$v; sl_gws[$i]=1
  printf -v "$2" '%s' "$v"
}

sl_judge() {
  # sl_judge <index position> — judges that run and keeps it if it beats the
  # best so far: a lower rank, else a later time, else an earlier index line.
  # The last clause is what lets the dormant walk visit runs out of index order
  # and still pick the run a walk in index order would.
  local i="$1" rd rid ledger st rank hb_t g t
  rid="${sl_rid[$i]}"; rd="${sl_rd[$i]}"; ledger="${sl_led[$i]}"
  [ "$sl_trace" = 1 ] && printf 'cc-sl-derive %s\n' "$rid" >&2
  st=$(cc_run_state "$rd" "$ledger" "$CC_SL_STALL" "$CC_SL_ABANDON" 2>/dev/null || true)
  [ -n "$st" ] || return 0
  sl_grade_into "$st" rank
  [ -n "$rank" ] || rank=9
  # A WAITING APPROVAL HOLDS ITS RANK ONLY WHILE A WATCHER CAN STILL DELIVER IT.
  # `cc_run_state` returns 승인대기 for any open approval however long the ledger
  # has been quiet, and that is right for the token: the watcher's terminal
  # banner keys on it and must not change. But as a RANK it let a run whose
  # watcher died with one approval open hold every later run's session forever —
  # measured, a run past its deadline and taken over by a successor held the
  # line 102 hours after its last row, over the run that replaced it. So with no
  # fresh heartbeat the approval stops counting and the run is ranked on the
  # same idle ladder as a run without one. The token, and so the glyph when it
  # is still the only run, stays 승인대기; only the order changes.
  if [ "$st" = "승인대기" ]; then
    sl_mtime_into "$rd/watch.heartbeat" hb_t
    if [ -z "$hb_t" ] || [ "$((now - hb_t))" -gt "$CC_SL_HEARTBEAT_STALE" ]; then
      sl_growth_into "$i" g
      if [ -z "$g" ] || [ "$((now - g))" -ge "$CC_SL_ABANDON" ]; then
        sl_grade_into 버려짐 rank
      elif [ "$((now - g))" -ge "$CC_SL_STALL" ]; then
        sl_grade_into 정지경고 rank
      fi
    fi
  fi
  if [ "$st" = "종단" ]; then
    # WHERE A TERMINAL TIME COMES FROM, once, for both paths. `done` carries an
    # ISO stamp but only a handful of runs ever reach the verb that writes it,
    # and a derived termination has no stamp at all — so ordering on the stamp
    # would order two populations by two different clocks. The file mtime is one
    # clock: `done`'s when it exists, the ledger's last movement otherwise.
    sl_mtime_into "$rd/done" t; [ -n "$t" ] || sl_mtime_into "$ledger" t
  else
    sl_mtime_into "$ledger" t
  fi
  [ -n "$t" ] || t=0
  if [ -z "$best_rd" ] || [ "$rank" -lt "$best_rank" ] \
     || { [ "$rank" -eq "$best_rank" ] && [ "$t" -gt "$best_t" ]; } \
     || { [ "$rank" -eq "$best_rank" ] && [ "$t" -eq "$best_t" ] && [ "$i" -lt "$best_i" ]; }; then
    best_rd=$rd; best_rid=$rid; best_state=$st; best_ledger=$ledger
    best_t=$t; best_rank=$rank; best_i=$i
  fi
  return 0
}

sl_pid_answers() {
  # sl_pid_answers <file> — succeeds when the file's first line, blanks
  # removed, is a pid some process holds. The existence test is
  # `cc_pid_exists` from `liveness.sh`, so this file keeps no liveness
  # judgement of its own; a reused pid only costs a judgement here.
  local p=""
  IFS= read -r p < "$1" || [ -n "$p" ] || return 1
  p=${p//[[:space:]]/}
  cc_pid_exists "$p"
}

sl_awake_by_pid() {
  # sl_awake_by_pid <run-dir> — succeeds when screening conditions 1-3 find a
  # pid that answers, or a file they could not read (which is not evidence of
  # dormancy).
  local rd="$1" f l h
  for f in "$rd"/*.pid; do
    [ -f "$f" ] || continue
    [ -r "$f" ] || return 0
    sl_pid_answers "$f" && return 0
  done
  for f in "$rd"/*.waiting; do
    [ -f "$f" ] || continue
    [ -r "$f" ] || return 0
    h=""
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in 보유자=*) h=${l#보유자=} ;; esac
      l=""
    done < "$f"
    h=${h//[[:space:]]/}
    cc_pid_exists "$h" && return 0
  done
  if [ -f "$rd/shift.live" ]; then
    [ -r "$rd/shift.live" ] || return 0
    sl_pid_answers "$rd/shift.live" && return 0
  fi
  return 1
}

sl_split_lines() {
  # sl_split_lines <text> — sl_lines holds its non-empty lines. Word splitting
  # on newlines with globbing off, not a here-document: bash 3.2 backs a
  # here-document with a temporary file, and this script writes nothing.
  local IFS=$'\n' x
  sl_lines=()
  set -f
  for x in $1; do sl_lines[${#sl_lines[@]}]=$x; done
  set +f
}

sl_find_arg_ok() {
  # sl_find_arg_ok <path> — a path `find` would read as an operand rather than
  # as part of its expression.
  case "$1" in
    ''|-*|'('*|')'*|'!'*) return 1 ;;
  esac
  return 0
}

# Pass 1: walk the index once. Indexed arrays, never associative ones, and
# every expansion is guarded by its length first: bash 3.2 under `set -u`
# treats an empty "${a[@]}" as unbound.
sl_n=0
sl_rid=(); sl_rd=(); sl_led=(); sl_hb=(); sl_clk=(); sl_dorm=(); sl_paths=()
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  rd="$CC_SL_STATE/run/$rid"
  # Readability is tested alongside existence. A directory that is there but
  # cannot be opened yields empty reads all the way down, and empty reads look
  # exactly like a quiet run — so without this the line would confidently
  # describe a run it never managed to read.
  [ -d "$rd" ] && [ -r "$rd" ] || continue
  # The ledger path is read with the `read` builtin rather than `cat`. For a
  # one-line file, with or without its final newline, that is the value
  # `$(cat …)` gives; a file with a second line keeps the `cat` value and the
  # run is not dormant.
  dorm=$sl_screen; ledger=""
  if [ -e "$rd/ledger-path" ]; then
    l1=""; l2=""
    if [ -f "$rd/ledger-path" ] && [ -r "$rd/ledger-path" ]; then
      { if IFS= read -r l1; then
          if IFS= read -r l2 || [ -n "$l2" ]; then l2=more; fi
        fi; } 2>/dev/null < "$rd/ledger-path"
    else
      l2=more
    fi
    if [ -n "$l2" ]; then
      ledger=$(cat "$rd/ledger-path" 2>/dev/null || true); dorm=0
    else
      ledger=$l1
    fi
  fi
  hbp="$rd/watch.heartbeat"
  if [ "$dorm" = 1 ] && sl_awake_by_pid "$rd"; then dorm=0; fi
  if [ "$dorm" = 1 ]; then
    for p in "$ledger" "$hbp"; do
      [ -n "$p" ] && [ -f "$p" ] || continue
      if sl_find_arg_ok "$p"; then sl_paths[${#sl_paths[@]}]=$p; else dorm=0; fi
    done
  fi
  if [ -f "$rd/done" ]; then clk="$rd/done"
  elif [ -n "$ledger" ] && [ -f "$ledger" ]; then clk=$ledger
  else clk=""
  fi
  sl_rid[$sl_n]=$rid; sl_rd[$sl_n]=$rd; sl_led[$sl_n]=$ledger; sl_hb[$sl_n]=$hbp
  sl_clk[$sl_n]=$clk; sl_dorm[$sl_n]=$dorm
  sl_n=$((sl_n + 1))
done < "$idx"

# Condition 4, for the whole index at once. A path `find` prints is inside the
# window, and every run holding that path as its ledger or heartbeat is awake —
# two runs sharing one ledger (a successor run) both are. `-L` follows a link
# to the file's own time, as `cc_mtime` does.
if [ "$sl_screen" = 1 ] && [ "${#sl_paths[@]}" -gt 0 ]; then
  sl_win=$(( (CC_SL_ABANDON + 59) / 60 + 1 ))
  if sl_fresh=$(find -L "${sl_paths[@]}" -prune -mmin "-$sl_win" -print 2>/dev/null); then
    sl_split_lines "$sl_fresh"
    j=0
    while [ "$j" -lt "${#sl_lines[@]}" ]; do
      p=${sl_lines[$j]}
      i=0
      while [ "$i" -lt "$sl_n" ]; do
        if [ "${sl_led[$i]}" = "$p" ] || [ "${sl_hb[$i]}" = "$p" ]; then sl_dorm[$i]=0; fi
        i=$((i + 1))
      done
      j=$((j + 1))
    done
  else
    i=0
    while [ "$i" -lt "$sl_n" ]; do sl_dorm[$i]=0; i=$((i + 1)); done
  fi
fi

# Pass 2: every run that is not dormant, in index order.
i=0
while [ "$i" -lt "$sl_n" ]; do
  [ "${sl_dorm[$i]}" = 1 ] || sl_judge "$i"
  i=$((i + 1))
done

# Pass 3: the dormant runs, only when the best so far is rank 5 or worse.
if [ "$best_rank" -gt 4 ]; then
  sl_order=(); sl_files=()
  i=0
  while [ "$i" -lt "$sl_n" ]; do
    if [ "${sl_dorm[$i]}" = 1 ] && [ -n "${sl_clk[$i]}" ]; then
      dup=0; j=0
      while [ "$j" -lt "${#sl_files[@]}" ]; do
        [ "${sl_files[$j]}" = "${sl_clk[$i]}" ] && { dup=1; break; }
        j=$((j + 1))
      done
      [ "$dup" = 1 ] || sl_files[${#sl_files[@]}]=${sl_clk[$i]}
    fi
    i=$((i + 1))
  done
  sl_walk_stops=1
  if [ "${#sl_files[@]}" -gt 0 ]; then
    if sl_sorted=$(ls -1tL -- "${sl_files[@]}" 2>/dev/null); then
      sl_split_lines "$sl_sorted"
      j=0
      while [ "$j" -lt "${#sl_lines[@]}" ]; do
        p=${sl_lines[$j]}
        i=0
        while [ "$i" -lt "$sl_n" ]; do
          if [ "${sl_dorm[$i]}" = 1 ] && [ "${sl_clk[$i]}" = "$p" ]; then
            sl_order[${#sl_order[@]}]=$i
          fi
          i=$((i + 1))
        done
        j=$((j + 1))
      done
    else
      sl_walk_stops=0
    fi
  fi
  if [ "$sl_walk_stops" = 1 ]; then
    # The runs with no clock file go last, in index order.
    i=0
    while [ "$i" -lt "$sl_n" ]; do
      if [ "${sl_dorm[$i]}" = 1 ] && [ -z "${sl_clk[$i]}" ]; then sl_order[${#sl_order[@]}]=$i; fi
      i=$((i + 1))
    done
  else
    sl_order=()
    i=0
    while [ "$i" -lt "$sl_n" ]; do
      [ "${sl_dorm[$i]}" = 1 ] && sl_order[${#sl_order[@]}]=$i
      i=$((i + 1))
    done
  fi
  k=0
  while [ "$k" -lt "${#sl_order[@]}" ]; do
    i=${sl_order[$k]}
    if [ "$sl_walk_stops" = 1 ] && [ -n "$best_rd" ] && [ "$best_rank" -le 5 ]; then
      c=""
      [ -n "${sl_clk[$i]}" ] && sl_mtime_into "${sl_clk[$i]}" c
      [ -n "$c" ] || c=0
      [ "$c" -lt "$best_t" ] && break
    fi
    sl_judge "$i"
    k=$((k + 1))
  done
fi

[ -n "$best_rd" ] || sl_exit_fallback

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------

# `now` was read once before the selection loop, so the rank and the slots
# below are judged against one clock.

# The ledger's age comes from the watcher's heartbeat when there is one, and
# from the ledger's own mtime when there is not. Measured 2026-09-07: 61 of 62
# runs in flight published no `마지막성장`, so on the heartbeat alone this slot
# was empty for almost every run that needed it — and an age-less line reads as
# "just started" on a run that has been quiet for a day. Reading an mtime is
# still not a write, so the property this file rests on is untouched. An absent
# value on BOTH means nothing has been recorded at all, which is why every use
# below is guarded rather than defaulted to zero.
sl_growth_into "$best_i" grew
age_slot=""
if [ -n "$grew" ]; then
  # CLAMPED, AND CLAMPED HERE RATHER THAN AT THE SOURCE. A ledger mtime in the
  # future is not hypothetical — one run on this host measured 28 seconds ahead
  # — and the mtime fallback above put a `grew` on far more runs than the
  # heartbeat field ever did, so the exposure grew with it. Without this the
  # line says `원장 -72초 전` while `cc_run_state`, which clamps the very same
  # value, calls the run 진행중: two axes disagreeing about one run's sign. The
  # slot is shared, so this one place covers 승인대기, 정지경고, 버려짐, 진행중
  # and the 도는중 else branch. Clamping inside `cc_ledger_growth_at` would let
  # both consumers inherit it, but that function has no `now` and would spend a
  # `date` fork per call — once per indexed run per ten-second tick, twelve of
  # them on a twelve-run session. Measure that before moving it.
  a=$((now - grew))
  [ "$a" -lt 0 ] && a=0
  age_phrase "$a"
  age_slot=" · 원장 $SL_AGE"
fi

# `watch.pid` is what keeps "has not come up yet" from collapsing into "died".
# Without it both render as silence, and silence from a watcher that was never
# started means something different to the person reading this at 3am.
#
# `watch_v` is the same verdict as a word for the pane's field row, set beside
# each slot so the two cannot be judged twice.
watch_slot=""; watch_v=ok
sl_mtime_into "$best_rd/watch.heartbeat" hb
if [ -z "$hb" ]; then
  if [ -f "$best_rd/watch.pid" ]; then watch_slot=" · 워처 없음"; watch_v=stale
  else                                 watch_slot=" · 워처 미기동"; watch_v=unstarted; fi
elif [ "$((now - hb))" -gt "$CC_SL_HEARTBEAT_STALE" ]; then
  watch_slot=" · 워처 없음"; watch_v=stale
fi

case "$best_state" in
  종단)
    # TERMINAL IS JUDGED BEFORE THE STALL WARNING — a test order, not a rank. A
    # finished run has no live stage and a ledger that stopped growing, which is
    # also the exact shape of a stalled one; judged the other way round, every
    # clean finish would show as a warning from the moment it ended and never
    # stop. In the GRADE the direction is the opposite: 정지경고 outranks 종단,
    # because a run between two stages is still a run.
    line="✓ ${best_rid} 종료"
    # The watcher exits when the run ends, so a stale heartbeat here is the
    # normal shape of a finish, not a missing watcher.
    watch_slot=""; watch_v=none
    arm=종료
    ;;
  승인대기)
    pend=$(cc_open_approvals "$best_ledger")
    line="⏸ ${best_rid} 승인 대기 ${pend}건${age_slot}"
    arm=승인대기
    ;;
  정지경고)
    # The glyph and the wording stay. `CC_SL_ABANDON` is what separates this arm
    # from the one below, and it is now a SELECTION boundary too: this arm ranks
    # above 종단 and the one below ranks beneath it, so which side of the mark a
    # quiet run falls on decides whether it holds the line at all.
    line="⚠ ${best_rid} 스테이지 0${age_slot}"
    arm=정지경고
    ;;
  버려짐)
    # THREE THINGS MADE THE OLD LINE READ AS ACTIVE, and all three are fixed
    # here rather than in the ordering. `⟳` was the same glyph a genuinely
    # running stage gets; the age slot was empty because the heartbeat field was
    # usually missing; and `· 워처 미기동` reads as "has not started yet" on a
    # run that has been quiet for a day. So: a glyph that does not read as
    # motion and is distinct from the other four, an age that now falls back to
    # the ledger mtime, and no watcher slot at all.
    #
    # SUPPRESSING THE WATCHER SLOT IS ALLOWED, NOT REQUIRED ELSEWHERE. The
    # contract permits a heartbeat to show in the wording; it does not oblige
    # it. On an abandoned run the slot answers a question nobody is asking and
    # is the specific phrase that misled a reader, so it goes.
    #
    # NEVER `emit_fallback` FROM HERE, and never `sl_exit_fallback` either —
    # going through the wrapper does not change what its bytes say. They are the
    # "this session has no run" line, so routing an abandoned run there would be
    # silently legal — every assertion in the suite stays green and only the
    # meaning is wrong.
    #
    # NO NEW SLOT AFTER THE AGE. Three cases in the suite compare by stripping a
    # trailing digit run off the end of the line; anything appended past the age
    # breaks them one time in seven, which is worse than breaking them cleanly.
    # The one exception is the borrow segment, which follows every line. Those
    # cases run with no borrow record, and none may run with one: a `홈 HH:MM`
    # clock at the end is exactly what the strip removes.
    #
    # NO BUDGET TRIM ON THIS ARM, and that asymmetry is deliberate but not free.
    # Trimming of the run's slots lives only on the 도는중 arm. The longest run
    # id on this host is 24 characters, which puts this line inside 30, so the
    # cap is unreachable today — "unreachable" and "the width is managed" are
    # different claims, and a longer id would expose this arm first. Dropping
    # the borrow detail is not a run slot and applies to every arm, this one
    # included.
    # Any non-empty line of the reader's output is a standing block, which is
    # what counting them used to decide; the command substitution drops the
    # trailing empty lines, so a non-empty value holds at least one.
    blocked_out=$(cc_unresolved_blocked "$best_ledger" 2>/dev/null || true)
    if [ -n "$blocked_out" ]; then w=차단; else w=방치; fi
    line="⊘ ${best_rid} ${w}${age_slot}"
    watch_slot=""; watch_v=none
    arm=$w
    ;;
  도는중)
    newest_stage_pid "$best_rd"; slot=$SL_SLOT
    seg=${slot%% *}; pid=${slot#* }
    if [ -n "$slot" ] && [ -n "$seg" ]; then
      line="⟳ ${best_rid} ${seg}"
      # The kind comes from `liveness.sh`, the source the pane reads too. A
      # segment on its first driver attempt has none and the slot is dropped.
      kind=$(cc_stage_kind "$best_rd" "$best_ledger" "$seg")
      elapsed=$(ps -o etime= -p "$pid" 2>/dev/null); elapsed=${elapsed// /}
      # THE PID IS ALREADY IDENTITY-CHECKED by the time it reaches here, and
      # that is what makes this number meaningful: measured on an unfiltered
      # pid, `ps` answers empty for a dead one and — after a reuse — the elapsed
      # time of an unrelated process, which is worse than no slot at all.
      #
      # Elapsed comes from `ps`, never from `started-at` or `.start`. The former
      # is rewritten on every gate call and is not the run's start time; the
      # latter is a formatted date string that no portable arithmetic accepts —
      # and reading it would mean branching on the two incompatible date flags.
      [ -n "$kind" ]    && line="$line ${kind}"
      [ -n "$elapsed" ] && line="$line ${elapsed}"
      # Drop whole slots, lowest priority first, until it fits — the borrow
      # detail before anything of the run's own, so that it goes first here as
      # it does on every other arm. With no segment each sum below is the
      # `${#line}` this arm always compared.
      if [ $(( ${#line} + ${#SL_BORROW_SEG} )) -gt "$CC_SL_BUDGET" ]; then
        SL_BORROW_SEG="$SL_BORROW_SHORT"
      fi
      if [ $(( ${#line} + ${#SL_BORROW_SEG} )) -gt "$CC_SL_BUDGET" ] && [ -n "$kind" ]; then
        line="⟳ ${best_rid} ${seg}"
        [ -n "$elapsed" ] && line="$line ${elapsed}"
      fi
      [ $(( ${#line} + ${#SL_BORROW_SEG} )) -gt "$CC_SL_BUDGET" ] && line="⟳ ${best_rid} ${seg}"
    else
      line="⟳ ${best_rid}${age_slot}"
    fi
    arm=도는중
    ;;
  진행중)
    # NOT A STATE OF ITS OWN, and not the running row either. This is the
    # residual: the run is in flight but no stage is up at this instant —
    # between two of them, with the ledger still fresh. It outranks a finished
    # run, and so does the stall row below — beating a finished run is no longer
    # what `CC_SL_STALL` decides. What the mark still decides is the order
    # between THIS row and that one, and the glyph.
    # It says `스테이지 0` for the same reason
    # the stall row does, because that is the true and load-bearing fact: a pid
    # file whose process died, or whose pid was reused, must never render as a
    # stage that is up. The only thing separating this line from the stall row
    # is the glyph, which is exactly the difference — the same facts, one of
    # them past the mark.
    line="⟳ ${best_rid} 스테이지 0${age_slot}"
    arm=진행중
    ;;
  정산중)
    # EVERY SEGMENT HAS ENDED BUT THE RUN HAS NOT. A run carrying the
    # `ends-on-done` marker settles its exit clauses after the last segment and
    # ends on `done`; until then it is in flight, so it keeps the running glyph
    # and the watcher slot as 진행중 does. A quiet settlement leaves this arm
    # through the same 정지경고 and 버려짐 ladder, so no second threshold lives here.
    line="⟳ ${best_rid} 정산 중${age_slot}"
    arm=정산중
    ;;
  *)
    sl_exit_fallback
    ;;
esac

# The borrow detail goes here on every arm that is still too wide, once; an
# already-short segment is left as it is.
if [ $(( ${#line} + ${#SL_BORROW_SEG} )) -gt "$CC_SL_BUDGET" ]; then
  SL_BORROW_SEG="$SL_BORROW_SHORT"
fi
printf '%s%s%s' "$line" "$watch_slot" "$SL_BORROW_SEG"

# THE PANE'S FIELD ROW, and only when it asks. `run-pane.sh` sets
# `CC_SL_PANE_FIELDS=1` and splits at the first newline; the engine's call does
# not set it, so the line above stays the whole output, byte for byte. The row
# carries the values this one evaluation judged with — the token, the arm's
# word, the clock, the ledger growth the `원장` slot used, the heartbeat mtime
# the watcher verdict read and that verdict — so the pane shows no word the
# status line did not judge and copies no threshold. Only a run line gets one;
# the no-run paths above exit before reaching here.
if [ "${CC_SL_PANE_FIELDS:-}" = "1" ]; then
  printf '\ncc-sl\t1\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$best_rid" "$best_state" "$arm" \
    "$now" "${grew:--}" "${hb:--}" "$watch_v"
fi
exit 0
