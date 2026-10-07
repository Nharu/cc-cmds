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
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.
# No `date -r` or `date -d` either: the two date implementations disagree on
# both, so the one epoch this file formats goes through `perl`.

set -uo pipefail

# The "no run" line and the fallback line are THE SAME BYTES, deliberately. A
# session with no run of its own must render exactly what was on screen before
# this script was ever installed, so that installing it is invisible until it
# has something to say — and every degraded path lands on the same shape rather
# than on a second, subtly different one that a reader would have to learn.
#
# THAT PROMISE IS SCOPED TO "NO BORROW TO SHOW". When the borrow verdict below
# is "nothing", every path prints today's bytes exactly. Otherwise the output is
# today's output with exactly the borrow segment appended — with one exception:
# the 도는중 arm may drop more of its run slots so that the borrow mark fits.
#
# THE FORMAT STRING IS COPIED FROM THE COMMAND THIS REPLACES, escapes included.
# The colour is not decoration: the wrapper the apply installs keeps that
# original command as its `||` fallback, so a version of this line without the
# escapes gives "nothing to say" two different renderings — the second shape the
# paragraph above exists to prevent, reintroduced by the very function meant to
# prevent it. The suite reads the reference out of the install target and runs
# it rather than transcribing the bytes, because a transcription is how the
# escapes went missing here while every case stayed green.
#
# No trailing newline: the command this replaces ends its format string at `%s`,
# and the apply path asserts byte-identity against that output.
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
  # Local time comes from a perl that loads no module, the epoch passed as an
  # argument; output of any other shape is no clock, which also keeps a doctored
  # `perl` from putting terminal bytes on the line. "Within 24 hours" is strict:
  # exactly 86400 seconds out as `HH:MM` would read as now.
  SL_BORROW_CLOCK=
  local e="$SL_B_RESET" now out
  [ -n "$e" ] || return 0
  now=$(date -u +%s)
  case "$now" in
    ''|*[!0123456789]*) return 0 ;;
  esac
  if [ "$e" -le "$now" ]; then
    SL_BORROW_CLOCK="홈 리셋 지남"
    return 0
  fi
  out=$(perl -e 'my @t = localtime($ARGV[0]); printf("%02d/%02d %02d:%02d", $t[4] + 1, $t[3], $t[2], $t[1]);' "$e" 2>/dev/null)
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
    tp=$(printf '%s' "$stdin_json" \
         | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
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

CC_SL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) \
  || sl_exit_fallback
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
  # age_phrase <seconds> — a short human duration.
  local s="$1"
  if   [ "$s" -lt 60 ];   then printf '%s초 전' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%s분 전' "$((s / 60))"
  else                         printf '%s시간 전' "$((s / 3600))"
  fi
}

newest_stage_pid() {
  # newest_stage_pid <run-dir> — echoes "<segment> <pid>" for the most recently
  # recorded stage that is STILL RUNNING, or nothing.
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
  local run_dir="$1" f seg t best_t=-1 best=""
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
  printf '%s %s' "$best" "$(cat "$run_dir/$best.pid" 2>/dev/null || true)"
}

stage_kind() {
  # stage_kind <ledger> <segment> — the kind recorded for that segment, or empty.
  #
  # The kind lives only in `stage-result`, which is written when a stage ENDS, so
  # a segment on its first attempt has none and the slot is simply dropped. The
  # run directory carries no kind handle to read instead — the driver leaves a
  # pid, a start-time fingerprint and a process group there, and nothing else.
  local ledger="$1" seg="$2"
  [ -n "$ledger" ] || return 0
  { grep -F 'stage-result' "$ledger" 2>/dev/null | grep -F "세그먼트=$seg " || true; } \
    | tail -1 | tr '|' '\n' | sed -n 's/^ *종류=//p' | sed 's/[[:space:]]*$//' | tail -1
}

# ---------------------------------------------------------------------------
# Resolve this session's run.
# ---------------------------------------------------------------------------

# `sed`, not `jq`. The field is one flat string, this runs every ten seconds,
# and a scenario in which `jq` is absent must still resolve the run rather than
# merely avoid crashing — spending a process on a lookup a substring answers
# would buy nothing and lose that.
sid=$(printf '%s' "$stdin_json" \
      | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
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
best_rd=""; best_rid=""; best_state=""; best_ledger=""; best_t=-1; best_rank=9
now=$(date -u +%s)
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  rd="$CC_SL_STATE/run/$rid"
  # Readability is tested alongside existence. A directory that is there but
  # cannot be opened yields empty reads all the way down, and empty reads look
  # exactly like a quiet run — so without this the line would confidently
  # describe a run it never managed to read.
  [ -d "$rd" ] && [ -r "$rd" ] || continue
  ledger=$(cat "$rd/ledger-path" 2>/dev/null || true)
  st=$(cc_run_state "$rd" "$ledger" "$CC_SL_STALL" "$CC_SL_ABANDON" 2>/dev/null || true)
  [ -n "$st" ] || continue
  rank=$(cc_run_grade "$st" 2>/dev/null || true)
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
    hb_t=$(cc_mtime "$rd/watch.heartbeat")
    if [ -z "$hb_t" ] || [ "$((now - hb_t))" -gt "$CC_SL_HEARTBEAT_STALE" ]; then
      g=$(cc_ledger_growth_at "$rd" "$ledger")
      if [ -z "$g" ] || [ "$((now - g))" -ge "$CC_SL_ABANDON" ]; then
        rank=$(cc_run_grade 버려짐)
      elif [ "$((now - g))" -ge "$CC_SL_STALL" ]; then
        rank=$(cc_run_grade 정지경고)
      fi
    fi
  fi
  if [ "$st" = "종단" ]; then
    # WHERE A TERMINAL TIME COMES FROM, once, for both paths. `done` carries an
    # ISO stamp but only a handful of runs ever reach the verb that writes it,
    # and a derived termination has no stamp at all — so ordering on the stamp
    # would order two populations by two different clocks. The file mtime is one
    # clock: `done`'s when it exists, the ledger's last movement otherwise.
    t=$(cc_mtime "$rd/done"); [ -n "$t" ] || t=$(cc_mtime "$ledger")
  else
    t=$(cc_mtime "$ledger")
  fi
  [ -n "$t" ] || t=0
  if [ -z "$best_rd" ] || [ "$rank" -lt "$best_rank" ] \
     || { [ "$rank" -eq "$best_rank" ] && [ "$t" -gt "$best_t" ]; }; then
    best_rd=$rd; best_rid=$rid; best_state=$st; best_ledger=$ledger
    best_t=$t; best_rank=$rank
  fi
done < "$idx"

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
grew=$(cc_ledger_growth_at "$best_rd" "$best_ledger")
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
  age_slot=" · 원장 $(age_phrase "$a")"
fi

# `watch.pid` is what keeps "has not come up yet" from collapsing into "died".
# Without it both render as silence, and silence from a watcher that was never
# started means something different to the person reading this at 3am.
watch_slot=""
hb=$(cc_mtime "$best_rd/watch.heartbeat")
if [ -z "$hb" ]; then
  if [ -f "$best_rd/watch.pid" ]; then watch_slot=" · 워처 없음"
  else                                 watch_slot=" · 워처 미기동"; fi
elif [ "$((now - hb))" -gt "$CC_SL_HEARTBEAT_STALE" ]; then
  watch_slot=" · 워처 없음"
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
    ;;
  승인대기)
    pend=$(cc_open_approvals "$best_ledger")
    line="⏸ ${best_rid} 승인 대기 ${pend}건${age_slot}"
    ;;
  정지경고)
    # The glyph and the wording stay. `CC_SL_ABANDON` is what separates this arm
    # from the one below, and it is now a SELECTION boundary too: this arm ranks
    # above 종단 and the one below ranks beneath it, so which side of the mark a
    # quiet run falls on decides whether it holds the line at all.
    line="⚠ ${best_rid} 스테이지 0${age_slot}"
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
    blocked_n=$(cc_unresolved_blocked "$best_ledger" 2>/dev/null | grep -c . || true)
    if [ "${blocked_n:-0}" -gt 0 ] 2>/dev/null; then w=차단; else w=방치; fi
    line="⊘ ${best_rid} ${w}${age_slot}"
    watch_slot=""
    ;;
  도는중)
    slot=$(newest_stage_pid "$best_rd")
    seg=${slot%% *}; pid=${slot#* }
    if [ -n "$slot" ] && [ -n "$seg" ]; then
      line="⟳ ${best_rid} ${seg}"
      kind=$(stage_kind "$best_ledger" "$seg")
      elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
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
exit 0
