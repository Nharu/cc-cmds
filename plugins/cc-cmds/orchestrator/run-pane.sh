#!/usr/bin/env bash
# run-pane.sh <session-id> [--cols N] [--rows N] — the lines the autopilot
# status pane draws.
#
# THE PANE DRAWS, THIS FILE JUDGES. The mod in `hooks/autopilot-status.tsx`
# knows three classes — `live`, `ended`, `none` — a closed set of bundle names
# and a tone per fragment; which run to show, whether it is alive, what to say
# about it, in what order and colour, what to drop when the dock is short, and
# how often to ask again are all decided here. A TypeScript copy of any of that
# would sit where `scripts/lint-statusline-token-arms.sh` cannot read, and the
# plugin test harness cannot run this process, so the wording has to live where
# the bash suite covers it.
#
# THE RUN IS THE STATUS LINE'S, BY CONSTRUCTION. This calls the unchanged
# selection in `statusline.sh` with the session id and `CC_SL_PANE_FIELDS=1`,
# and takes the run id, the state token, the arm word, the clock, the ledger
# growth time, the heartbeat time and the watcher verdict from the fields row
# it prints after its human line. The selection loop, its thresholds and the
# demotion of a waiting approval with a stale heartbeat are NOT copied here,
# and neither is the token → glyph table: the glyph is the first token of the
# human line. The run id is accepted only when it is a whole line of this
# session's index (`grep -qxF`); a run id format regex is not used, because the
# older `YYYY-MM-DD-xxxxxxxx` ids are still live.
#
# OUTPUT CONTRACT. One head row, then body rows; fields are TAB-separated:
#
#   cc-pane<TAB>2<TAB><live|ended|none><TAB><rid|-><TAB><index path|-><TAB><refresh_ms>
#   <bundle><TAB><cut|wrap><TAB><tone><TAB><text>[<TAB><tone><TAB><text>]...
#
# The schema field is the string `2` and the mod compares it exactly. The index
# path is printed even when the file does not exist yet — the mod stats it for
# its mtime — and is `-` for a session id that fails the shape check. A tone is
# `normal`, `dim`, `ok`, `warn`, `error` or `accent`, optionally with `.b` for
# bold. `cut` is drawn truncated at the end and `wrap` wrapped; only
# `block-reason` wraps. The bundles are a closed set: `none`, `title`,
# `session-title`, `head`, `head-detail`, `gap`, `seg-heading`, `seg`,
# `seg-detail`, `seg-folded`, `gate-none`, `approval`, `block-heading`,
# `block-reason`, `cone-unresolved`, `orphan`, `event-heading`, `event`. Text
# never holds a TAB.
#
# THE CAP is `min(24, --rows)`, and this file meets it by dropping rows in a
# fixed order (see the reduction below). Some rows are protected and stay past
# the cap: what is waiting for a person must not scroll away behind history.
#
# NOTHING HERE TICKS EVERY SECOND. Times are a stage's start as `HH:MM` and
# ages in whole minutes or hours, all computed from the one clock the fields
# row carries, so two refreshes ten seconds apart draw the same bytes unless
# the run moved. Clock times are in the display zone `display-tz.sh` reads
# from `CC_CMDS_AUTOPILOT_TZ` (KST by default), and the event heading names
# it; without that sibling they stay UTC and the heading says `UTC`.
#
# TOTAL, AND NOTHING HERE WRITES. Every path exits 0 with a valid head row — a
# missing sibling, an unreadable run directory, a missing `ledger-path` and a
# PATH without `jq` included; nothing here calls `jq`. `set -e` is absent for
# the same reason it is absent from `statusline.sh`. No file or directory is
# created.
#
# `--glyphs` prints the glyph table, one `<glyph><TAB><class>` per line, and
# nothing else. It is the read-only path the suite uses to hold this table
# against the render arms of `statusline.sh` without keeping a copy of it.
# `--estimate <cols>` prints the line count this file estimates for the text on
# stdin, so the suite measures a wrapped row with the function the cap uses.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

set -uo pipefail

PANE_SCHEMA=2
PANE_CAP_MAX=24
PANE_COLS_DEFAULT=44
PANE_ROWS_DEFAULT=24
PANE_EVENTS_MAX=6
PANE_REFRESH_LIVE=10000
PANE_REFRESH_OTHER=60000

# THE GLYPH TABLE LIVES HERE AND ONLY HERE. A class is read off the glyph the
# status line already chose, which carries its whole judgement — the demotion
# included — so nothing here re-derives a run state. A waiting approval whose
# heartbeat went stale is still `⏸`, so it is still `live`: the open approval
# waits for a person whatever the watcher is doing. A glyph that is in neither
# list is `ended`.
PANE_LIVE_GLYPHS="⟳ ⏸ ⚠"
PANE_ENDED_GLYPHS="✓ ⊘"

pane_glyph_class() {
  # pane_glyph_class <glyph> — PANE_CLASS is `live` or `ended`.
  case " $PANE_LIVE_GLYPHS " in
    *" $1 "*) PANE_CLASS=live ;;
    *)        PANE_CLASS=ended ;;
  esac
}

pane_glyph_tone() {
  # pane_glyph_tone <glyph> — PANE_TONE is the tone the title and the head word
  # take.
  case "$1" in
    "⟳"|"⏸") PANE_TONE=accent ;;
    "⚠")     PANE_TONE=warn ;;
    "✓")     PANE_TONE=ok ;;
    *)       PANE_TONE=dim ;;
  esac
}

pane_est_lines() {
  # pane_est_lines <cols> <text> — the lines a wrapped row takes.
  #
  # Cells ≈ ASCII bytes + ceil(2 × non-ASCII bytes / 3), counted under
  # `LC_ALL=C` so the count is bytes on every bash and every tr. A three-byte
  # Hangul syllable is two cells and is counted as two, so the estimate does
  # not fall short on Korean prose; a narrow non-ASCII mark such as `·` is
  # over-counted. The engine wraps on words, which can take a line more than
  # this at a narrow width — the cost is an old event scrolling below the fold,
  # and the protected rows sit above it.
  local cols="$1" all asc cells n
  all=$(printf '%s' "$2" | LC_ALL=C wc -c | tr -d ' ')
  asc=$(printf '%s' "$2" | LC_ALL=C tr -d '\200-\377' | LC_ALL=C wc -c | tr -d ' ')
  cells=$(( asc + (2 * (all - asc) + 2) / 3 ))
  n=$(( (cells + cols - 1) / cols ))
  [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

pane_posint() {
  # pane_posint <value> <default> — the value when it is a positive integer.
  case "$1" in
    ""|*[!0-9]*) printf '%s' "$2"; return 0 ;;
  esac
  if [ "${#1}" -gt 6 ] || [ $((10#$1)) -le 0 ]; then printf '%s' "$2"; else printf '%s' $((10#$1)); fi
}

if [ "${1:-}" = "--glyphs" ]; then
  for g in $PANE_LIVE_GLYPHS $PANE_ENDED_GLYPHS; do
    pane_glyph_class "$g"
    printf '%s\t%s\n' "$g" "$PANE_CLASS"
  done
  exit 0
fi
if [ "${1:-}" = "--estimate" ]; then
  pane_est_lines "$(pane_posint "${2:-}" "$PANE_COLS_DEFAULT")" "$(cat)"
  printf '\n'
  exit 0
fi

sid="${1:-}"
[ "$#" -gt 0 ] && shift
cols=$PANE_COLS_DEFAULT; rows=$PANE_ROWS_DEFAULT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cols) cols=$(pane_posint "${2:-}" "$PANE_COLS_DEFAULT"); [ "$#" -ge 2 ] && shift ;;
    --rows) rows=$(pane_posint "${2:-}" "$PANE_ROWS_DEFAULT"); [ "$#" -ge 2 ] && shift ;;
  esac
  shift
done
cap=$PANE_CAP_MAX
[ "$rows" -lt "$cap" ] && cap=$rows

pane_dirname_into() {
  # pane_dirname_into <path> <var> — sets <var> to what `dirname <path>` prints:
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

PANE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
# The outer `$( )` stays: `cd` inside it leaves this shell's `PWD` alone.
pane_dirname_into "${BASH_SOURCE[0]:-$0}" pane_src_dir
PANE_DIR=$(cd "$pane_src_dir" 2>/dev/null && pwd) || PANE_DIR=""
TAB=$'\t'
NL='
'

pane_id_shape_ok() {
  # pane_id_shape_ok <value> <letters> — succeeds when some line of the value
  # is non-empty and made only of the given letters: the answer
  # `printf '%s' <value> | LC_ALL=C grep -qE '^[<class>]+$'` gives, without
  # its two processes. The letters are spelled out rather than ranged, since a
  # range in a UTF-8 locale follows collation and can admit other letters, and
  # any byte outside ASCII is outside them as it is under `LC_ALL=C`.
  local line IFS=$'\n'
  set -f
  for line in $1; do
    case "$line" in
      *[!"$2"]*) ;;
      *) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}
PANE_ID_SID='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-'
PANE_ID_TITLE='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'

pane_session_title() {
  # pane_session_title <session-id> — PANE_TITLE is the session's current
  # title, or empty.
  #
  # The file is the one `hooks/session-title.sh` keeps at
  # `session-title-now/<id>`: a schema line `cc-session-title-now v1`, then the
  # title. Its writer makes that path only for an id of `^[A-Za-z0-9-]+$`, which
  # is narrower than the shape check below, so the id is checked again here. A
  # missing or unreadable file, another schema line or an empty title is no
  # title. Lines are read with the shell's `read`, untrimmed; a title line
  # without its newline still counts, and lines past the second are ignored. A
  # TAB in the title becomes a space, because text never holds a TAB.
  local f l1="" l2=""
  PANE_TITLE=""
  pane_id_shape_ok "$1" "$PANE_ID_TITLE" || return 0
  f="$PANE_STATE/session-title-now/$1"
  [ -f "$f" ] && [ -r "$f" ] || return 0
  { IFS= read -r l1; IFS= read -r l2; } < "$f" 2>/dev/null
  [ "$l1" = "cc-session-title-now v1" ] && [ -n "$l2" ] || return 0
  PANE_TITLE=${l2//$TAB/ }
}

pane_none() {
  # pane_none <index-path|-> — the head row and the one body row of a session
  # with no run to show, then exit. A session whose id passed the shape check
  # also gets its title row under it when it has a current title.
  local st=""
  printf 'cc-pane\t%s\tnone\t-\t%s\t%s\n' "$PANE_SCHEMA" "$1" "$PANE_REFRESH_OTHER"
  printf 'none\tcut\tdim\t연결된 런 없음\n'
  [ "$1" = "-" ] || { pane_session_title "$sid"; st=$PANE_TITLE; }
  [ -z "$st" ] || printf 'session-title\tcut\tdim\t세션 \tnormal\t%s\n' "$st"
  exit 0
}

# THE SESSION ID IS A PATH SEGMENT AND A JSON STRING, so its shape is checked
# before it becomes either. A value made only of dots passes the character
# class and names the index directory itself or its parent. The check is on the
# session id alone; run ids are taken as the index lists them.
if [ -z "$sid" ] || ! pane_id_shape_ok "$sid" "$PANE_ID_SID"; then
  pane_none -
fi
case "$sid" in *[!.]*) ;; *) pane_none - ;; esac

idx="$PANE_STATE/session/$sid"

[ -n "$PANE_DIR" ] && [ -f "$PANE_DIR/statusline.sh" ] || pane_none "$idx"
sl_out=$(printf '{"session_id":"%s"}' "$sid" \
           | CC_SL_PANE_FIELDS=1 bash "$PANE_DIR/statusline.sh" 2>/dev/null) || true

# The first line is the human line, the second the fields row. The status
# line's no-run output starts with an ESC byte and carries no fields row; the
# index check below would reject it on its own, and the ESC test says why in
# one comparison.
human=${sl_out%%"$NL"*}
human=${human//$TAB/ }
fields=""
case "$sl_out" in
  *"$NL"*) fields=${sl_out#*"$NL"}; fields=${fields%%"$NL"*} ;;
esac
esc=$'\033'
case "$human" in
  ""|"$esc"*) pane_none "$idx" ;;
esac

f_rid=""; f_state=""; f_arm=""; f_now=""; f_grew="-"; f_hb="-"; f_watch=""
case "$fields" in
  "cc-sl${TAB}1${TAB}"*)
    IFS="$TAB" read -r _ _ f_rid f_state f_arm f_now f_grew f_hb f_watch <<EOF
$fields
EOF
    ;;
esac
# A fields row whose clock is not a number is no fields row: every age and the
# start time are differences against it, and no other clock stands in.
case "$f_now" in
  ""|*[!0-9]*) fields="" ;;
esac
case "$f_grew" in ""|*[!0-9]*) f_grew="-" ;; esac
case "$f_hb"   in ""|*[!0-9]*) f_hb="-" ;; esac
[ -n "$f_rid" ] || fields=""

glyph=${human%% *}
if [ -n "$fields" ]; then
  rid=$f_rid
else
  rest=${human#* }
  rid=${rest%% *}
  [ "$rid" != "$human" ] || rid=""
fi
[ -n "$rid" ] || pane_none "$idx"
grep -qxF -- "$rid" "$idx" 2>/dev/null || pane_none "$idx"

pane_glyph_class "$glyph"; kind=$PANE_CLASS
pane_glyph_tone "$glyph"; gtone=$PANE_TONE
refresh=$PANE_REFRESH_OTHER
[ "$kind" = "live" ] && refresh=$PANE_REFRESH_LIVE

rd="$PANE_STATE/run/$rid"
ledger=""
rd_ok=0
if [ -d "$rd" ] && [ -r "$rd" ] && [ -x "$rd" ]; then
  rd_ok=1
  # Read with the `read` builtin, as the status line's first pass reads it:
  # for a one-line file, with or without its final newline, that is the value
  # `$(cat …)` gives, and a file with a second line keeps the `cat` value.
  l1=""; l2=""
  if [ -f "$rd/ledger-path" ] && [ -r "$rd/ledger-path" ]; then
    { if IFS= read -r l1; then
        if IFS= read -r l2 || [ -n "$l2" ]; then l2=more; fi
      fi; } 2>/dev/null < "$rd/ledger-path"
  else
    l2=more
  fi
  if [ -n "$l2" ]; then
    ledger=$(cat "$rd/ledger-path" 2>/dev/null || true)
  else
    ledger=$l1
  fi
fi
[ -n "$ledger" ] && [ -f "$ledger" ] && [ -r "$ledger" ] || ledger=""

# Sourced relative to this file, never through an environment variable, so a
# checkout carries its own pair. Without it, or without a ledger, the body is
# the title and the head and nothing more.
have_liveness=0
if [ -f "$PANE_DIR/liveness.sh" ]; then
  # shellcheck source=./liveness.sh
  . "$PANE_DIR/liveness.sh" 2>/dev/null && have_liveness=1
fi
# The display zone. Without the sibling the pane keeps UTC and its heading says
# so, so the label always matches the times beside it.
have_dtz=0; CC_DTZ_OFF=0; CC_DTZ_LABEL=UTC
if [ -f "$PANE_DIR/display-tz.sh" ]; then
  # shellcheck source=./display-tz.sh
  . "$PANE_DIR/display-tz.sh" 2>/dev/null && cc_display_tz_load && have_dtz=1
fi
full=0
[ "$have_liveness" = 1 ] && [ -n "$ledger" ] && full=1

# ---------------------------------------------------------------------------
# Rows. Each row is kept in parallel arrays — bundle, mode, the tone/text
# fragments as one TAB-joined string, the estimated line count, a class used
# by the reduction, and whether it is protected and currently shown.
# ---------------------------------------------------------------------------

NROWS=0; TOTAL=0
add_row() {
  # add_row <bundle> <mode> <class> <protected 0|1> <on 0|1> <tone> <text> [<tone> <text>]...
  #
  # Adjacent fragments of the same tone are merged, so a row is never more
  # pieces than it has colours.
  local b="$1" m="$2" c="$3" p="$4" on="$5" frag="" lt="" lx="" plain=""
  shift 5
  while [ "$#" -ge 2 ]; do
    if [ -n "$lt" ] && [ "$1" = "$lt" ]; then
      lx="$lx$2"
    else
      [ -n "$lt" ] && frag="$frag${frag:+$TAB}$lt$TAB$lx"
      lt="$1"; lx="$2"
    fi
    plain="$plain$2"
    shift 2
  done
  [ -n "$lt" ] && frag="$frag${frag:+$TAB}$lt$TAB$lx"
  RB[$NROWS]=$b; RM[$NROWS]=$m; RF[$NROWS]=$frag; RC[$NROWS]=$c; RP[$NROWS]=$p
  if [ "$m" = "wrap" ]; then RN[$NROWS]=$(pane_est_lines "$cols" "$plain"); else RN[$NROWS]=1; fi
  RON[$NROWS]=$on
  [ "$on" = 1 ] && TOTAL=$((TOTAL + RN[NROWS]))
  NROWS=$((NROWS + 1))
}
row_off() { [ "${RON[$1]}" = 1 ] && { RON[$1]=0; TOTAL=$((TOTAL - RN[$1])); }; return 0; }
row_on()  { [ "${RON[$1]}" = 1 ] || { RON[$1]=1; TOTAL=$((TOTAL + RN[$1])); }; return 0; }

pane_age() {
  # pane_age <seconds> — PANE_AGE in minutes, never seconds; a negative
  # difference is 0.
  local a="$1"
  [ "$a" -lt 0 ] && a=0
  if [ "$a" -lt 60 ]; then PANE_AGE='1분 안'
  elif [ "$a" -lt 3600 ]; then printf -v PANE_AGE '%s분 전' $((a / 60))
  else printf -v PANE_AGE '%s시간 전' $((a / 3600)); fi
}

pane_etime_secs() {
  # pane_etime_secs <etime> — PANE_SECS is `MM:SS`, `HH:MM:SS` or
  # `D-HH:MM:SS` as seconds, or empty. Every field is forced decimal with
  # `10#`, so `08` and `09` are numbers and not invalid octal.
  local e="$1" d=0 rest a b c v
  PANE_SECS=""
  case "$e" in
    *-*) d=${e%%-*}; rest=${e#*-} ;;
    *)   rest=$e ;;
  esac
  IFS=: read -r a b c <<EOF
$rest
EOF
  if [ -z "${c:-}" ]; then c=$b; b=$a; a=0; fi
  for v in "$d" "$a" "$b" "$c"; do
    case "$v" in ""|*[!0-9]*) return 0 ;; esac
  done
  PANE_SECS=$(( 10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c ))
}

pane_hhmm() {
  # pane_hhmm <epoch> — PANE_HM is `HH:MM` in the display zone by arithmetic,
  # so neither date dialect is needed; UTC when the helper did not load. The
  # helper prints, so it costs the one command substitution and no second.
  if [ "$have_dtz" = 1 ]; then
    PANE_HM=$(cc_display_hhmm "$1")
  else
    printf -v PANE_HM '%02d:%02d' $(( ($1 % 86400) / 3600 )) $(( ($1 % 3600) / 60 ))
  fi
}

# ---------------------------------------------------------------------------
# One pass over the ledger: the facts the head and the segment rows read, and
# the recent events.
#
# EVENT TIME RULES — a display rule, applied in this order:
#   1. The row's own time field, when it holds a UTC ISO time
#      (`YYYY-MM-DDTHH:MM`, optional `:SS`, then `Z`): `관측 시각`, `관측`,
#      `기록 시각`, or the `정산 시각` inside the `관측` of a lost dispatch
#      settlement. Its `HH:MM` is shifted into the display zone and wrapped at
#      midnight; the pane shows no date, so the day change is not drawn. A time
#      with another zone or none counts as no time and falls to rule 2: adding
#      an offset to a time of unknown zone draws a wrong time that looks right.
#      A time quoted in prose such as `사유` is not read.
#   2. Otherwise the k-th `stage-result` (k counted from the top of the file)
#      takes the time of the first later `cost` row with `스테이지 수=k`. That
#      count is the number of `stage-result` rows when the cost was written, so
#      two stages ending together leave the earlier one unpaired, and it falls
#      to rule 3 — a few seconds off at minute resolution.
#   3. Otherwise the time of the nearest earlier row of any kind that has one.
#   4. Otherwise `--:--`.
# Rules 2 and 3 take a time rule 1 already shifted, so they shift nothing.
# Kinds are `stage-result`, `cycle`, `checks`, `blocked`, `승인` and the
# newest `cost` only; `자율 승인` is never an event. Newest first, at most six.
# ---------------------------------------------------------------------------

facts=""
if [ "$full" = 1 ]; then
  facts=$(LC_ALL=C awk -F'|' -v maxev="$PANE_EVENTS_MAX" -v tzoff="$CC_DTZ_OFF" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # The LAST occurrence wins: a row may repeat a field (`id=A | id=A`).
    function field(name,   i, f, n, v) {
      n = length(name); v = ""
      for (i = 2; i <= NF; i++) {
        f = trim($i)
        if (substr(f, 1, n) == name) v = substr(f, n + 1)
      }
      return v
    }
    function isiso(v) { return v ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9](:[0-9][0-9])?Z/ }
    # The HH:MM of a UTC ISO time in the display zone. awk `%` keeps the sign
    # of the dividend, so a negative remainder is lifted by one more 1440.
    function hm(v,   x) {
      x = substr(v, 12, 2) * 60 + substr(v, 15, 2) + int(tzoff / 60)
      x = ((x % 1440) + 1440) % 1440
      return sprintf("%02d:%02d", int(x / 60), x % 60)
    }
    function owntime(   v, p) {
      v = field("관측 시각="); if (isiso(v)) return hm(v)
      v = field("관측=");      if (isiso(v)) return hm(v)
      p = index(v, "정산 시각 ")
      if (p > 0) { v = substr(v, p + length("정산 시각 ")); if (isiso(v)) return hm(v) }
      v = field("기록 시각="); if (isiso(v)) return hm(v)
      return ""
    }
    function ev(text, k) {
      ne++; evText[ne] = text; evOwn[ne] = t; evPrev[ne] = prevT; evK[ne] = k
    }
    /^- `/ {
      s = $1; sub(/^- `/, "", s); sub(/`.*$/, "", s)
      prevT = lastT
      t = owntime()
      if (s == "stage-result") {
        nsr++
        seg = field("세그먼트="); kd = field("종류="); ver = field("실행 버전=")
        code = field("종료 코드="); cls = field("종단 부류=")
        txt = seg
        if (kd != "") txt = txt " " kd
        if (ver != "") txt = txt " " ver "회차"
        if (code != "" && code != "-") txt = txt " · rc " code
        if (cls == "의도된 park") txt = txt " · park"
        else if (cls != "" && cls != "정상 완료") txt = txt " · " cls
        ev(txt, nsr)
        if (seg != "") { srKind[seg] = kd; srVer[seg] = ver; srCls[seg] = cls; srSeen[seg] = 1 }
      } else if (s == "cycle") {
        seg = field("세그먼트="); c = field("사이클="); p0 = field("P0="); p1 = field("P1=")
        ev(seg " 리뷰 " c "회차 · P0 " p0 " · P1 " p1, 0)
        if (seg != "") { cyC[seg] = c; cyP0[seg] = p0; cyP1[seg] = p1; cySeen[seg] = 1 }
      } else if (s == "checks") {
        seg = field("세그먼트="); pr = field("PR="); st = field("상태=")
        if (pr != "") { sub(/^.*#/, "", pr); txt = "체크 PR #" pr " " st } else txt = "체크 " st
        ev(txt, 0)
        if (seg != "") { ckPr[seg] = pr; ckSt[seg] = st; ckSeen[seg] = 1 }
      } else if (s == "cost") {
        usd = field("누적 usd="); n = field("스테이지 수=")
        lastUsd = sprintf("%.2f", usd + 0); lastN = n
        txt = "비용 누적 $" lastUsd
        if (n != "") txt = txt " · 스테이지 " n
        ev(txt, 0); lastCost = ne; isCost[ne] = 1
        if (n ~ /^[0-9]+$/ && (n + 0) >= 1 && (n + 0) <= nsr && !((n + 0) in paired) && t != "")
          paired[n + 0] = t
      } else if (s == "blocked") {
        cause = field("원인="); scope = field("스코프=")
        if (cause == "해소") txt = "막힘 해소"
        else if (scope == "cone") {
          subj = field("앵커 세그먼트="); if (subj == "") subj = field("대상=")
          txt = "막힘 cone " subj " 기록"
        } else txt = "막힘 run 기록"
        ev(txt, 0)
      } else if (s == "승인") {
        id = field("승인 id="); st = field("상태=")
        if (st == "대기") ev("승인 대기 " id, 0); else ev("승인 " id " " st, 0)
      } else if (s == "교대 기동") {
        shiftN = field("서수=")
      } else if (s == "segment") {
        id = field("id=")
        if (id != "") pre[id] = field("선행=")
      }
      if (t != "") lastT = t
    }
    END {
      if (shiftN != "") printf "shift\t%s\n", shiftN
      if (lastCost) printf "cost\t%s\t%s\n", lastUsd, lastN
      for (k in pre) printf "pre\t%s\t%s\n", k, pre[k]
      for (k in srSeen) printf "sr\t%s\t%s\t%s\t%s\n", k, srKind[k], srVer[k], srCls[k]
      for (k in cySeen) printf "cyc\t%s\t%s\t%s\t%s\n", k, cyC[k], cyP0[k], cyP1[k]
      for (k in ckSeen) printf "chk\t%s\t%s\t%s\n", k, ckPr[k], ckSt[k]
      shown = 0
      for (i = ne; i >= 1 && shown < maxev; i--) {
        if ((i in isCost) && i != lastCost) continue
        tm = evOwn[i]
        if (tm == "" && evK[i] > 0 && (evK[i] in paired)) tm = paired[evK[i]]
        if (tm == "") tm = evPrev[i]
        if (tm == "") tm = "--:--"
        printf "ev\t%s\t%s\n", tm, evText[i]
        shown++
      }
    }
  ' "$ledger" 2>/dev/null || true)
fi

# THE FACTS ARE INDEXED ONCE, and every reader below takes them from three
# arrays instead of running the facts back through `awk` or `cut`: FK is a
# line's kind (its first TAB field), FS its second field, FR the line after
# its kind. The `ev` lines, in order and without their kind, are `events`.
FK=(); FS=(); FR=(); events=""
pane_index_facts() {
  local line rest IFS=$'\n'
  set -f
  for line in $facts; do
    case "$line" in
      *"$TAB"*) rest=${line#*"$TAB"} ;;
      *)        rest=$line ;;
    esac
    FK[${#FK[@]}]=${line%%"$TAB"*}
    case "$line" in
      *"$TAB"*) FS[${#FS[@]}]=${rest%%"$TAB"*} ;;
      *)        FS[${#FS[@]}]="" ;;
    esac
    FR[${#FR[@]}]=$rest
    [ "${line%%"$TAB"*}" = ev ] && events="$events${events:+$NL}$rest"
  done
  set +f
}
pane_index_facts

fact() {
  # fact <kind> [<key>] — PANE_FACT is the first facts line of that kind (and
  # key), fields after the kind; empty when there is none.
  local j=0
  PANE_FACT=""
  while [ "$j" -lt "${#FK[@]}" ]; do
    if [ "${FK[$j]}" = "$1" ] && { [ -z "${2:-}" ] || [ "${FS[$j]}" = "$2" ]; }; then
      PANE_FACT=${FR[$j]}
      return 0
    fi
    j=$((j + 1))
  done
}
fact_col() {
  # fact_col <line> <n> — PANE_COL is the n-th TAB field of the line, as
  # `cut -f<n>` prints it: a line with no TAB is printed whole, and a field
  # past the last one is empty.
  local v="$1" i=1
  case "$v" in
    *"$TAB"*) ;;
    *) PANE_COL=$v; return 0 ;;
  esac
  while [ "$i" -lt "$2" ]; do
    case "$v" in
      *"$TAB"*) v=${v#*"$TAB"} ;;
      *) PANE_COL=""; return 0 ;;
    esac
    i=$((i + 1))
  done
  PANE_COL=${v%%"$TAB"*}
}

# ---------------------------------------------------------------------------
# title and head
# ---------------------------------------------------------------------------

add_row title cut - 1 1 "$gtone.b" "autopilot $rid"
pane_session_title "$sid"; session_title=$PANE_TITLE
[ -z "$session_title" ] || add_row session-title cut - 1 1 dim "세션 " normal "$session_title"

if [ -n "$fields" ]; then
  tail_parts=""
  if [ "$full" = 1 ]; then
    fact shift; fact_col "$PANE_FACT" 1; shift_n=$PANE_COL
    [ -n "$shift_n" ] && tail_parts="교대 $shift_n"
    pane_dirname_into "$ledger" ledger_dir
    manifest="$ledger_dir/$rid.plan.md"
    if [ -f "$manifest" ] && [ -r "$manifest" ]; then
      target_part=$(LC_ALL=C awk -F'|' '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        /^- `target`/ {
          n++
          for (i = 2; i <= NF; i++) {
            f = trim($i)
            if (substr(f, 1, 7) == "별칭=") alias = substr(f, 8)
            else if (substr(f, 1, 10) == "절단점=") cut = substr(f, 11)
          }
        }
        /^\*\*런 최대 절단점\*\*:/ { m = $0; sub(/^\*\*런 최대 절단점\*\*:[ \t]*/, "", m); runmax = trim(m) }
        END {
          if (n == 1) { o = alias; if (cut != "") o = o (o != "" ? " · " : "") "절단점 " cut }
          else if (n > 1) { o = "대상 " n "개"; if (runmax != "") o = o " · 절단점 " runmax }
          printf "%s", o
        }' "$manifest" 2>/dev/null || true)
      [ -n "$target_part" ] && tail_parts="$tail_parts${tail_parts:+ · }$target_part"
    fi
  fi
  if [ -n "$tail_parts" ]; then
    add_row head cut - 1 1 "$gtone.b" "$glyph $f_arm" normal "  $tail_parts"
  else
    add_row head cut - 1 1 "$gtone.b" "$glyph $f_arm"
  fi
else
  # Without a fields row the head is the status line's human line as it is.
  add_row head cut - 1 1 normal "$human"
fi

[ "$full" = 1 ] || {
  printf 'cc-pane\t%s\t%s\t%s\t%s\t%s\n' "$PANE_SCHEMA" "$kind" "$rid" "$idx" "$refresh"
  i=0
  while [ "$i" -lt "$NROWS" ]; do
    printf '%s\t%s\t%s\n' "${RB[$i]}" "${RM[$i]}" "${RF[$i]}"
    i=$((i + 1))
  done
  exit 0
}

# head-detail: ledger age, watcher, cumulative cost. The ledger age and the
# heartbeat age come from the fields row alone — the same evaluation that chose
# the status line's words — so the two screens cannot disagree, and without a
# fields row both slots are dropped rather than filled from another clock.
hd=()
fact cost; fact_col "$PANE_FACT" 1; cost_usd=$PANE_COL
if [ -n "$fields" ]; then
  if [ "$f_grew" != "-" ]; then
    pane_age $((f_now - f_grew))
    hd[${#hd[@]}]=dim; hd[${#hd[@]}]="원장 $PANE_AGE"
  fi
  hb_age=""
  [ "$f_hb" != "-" ] && { pane_age $((f_now - f_hb)); hb_age=$PANE_AGE; }
  case "$f_watch" in
    ok)        hd[${#hd[@]}]=dim;  hd[${#hd[@]}]="워처 ♥${hb_age:+ $hb_age}" ;;
    stale)     hd[${#hd[@]}]=warn; hd[${#hd[@]}]="워처 없음${hb_age:+ $hb_age}" ;;
    unstarted) hd[${#hd[@]}]=dim;  hd[${#hd[@]}]="워처 미기동" ;;
  esac
fi
[ -n "$cost_usd" ] && { hd[${#hd[@]}]=dim; hd[${#hd[@]}]="\$$cost_usd"; }
if [ "${#hd[@]}" -gt 0 ]; then
  args=(); j=0
  while [ "$j" -lt "${#hd[@]}" ]; do
    if [ "$j" -gt 0 ]; then args[${#args[@]}]=dim; args[${#args[@]}]=" · "; fi
    args[${#args[@]}]=${hd[$j]}; args[${#args[@]}]=${hd[$((j + 1))]}
    j=$((j + 2))
  done
  add_row head-detail cut - 1 1 "${args[@]}"
fi

# ---------------------------------------------------------------------------
# Segments
# ---------------------------------------------------------------------------

seg_states=$(cc_segment_states "$ledger" 2>/dev/null || true)
cone=$(cc_cone_blocked "$ledger" 2>/dev/null || true)
pane_lines_into() {
  # pane_lines_into <text> — PANE_LINES holds the text's non-empty lines, split
  # on newlines with globbing off rather than read from a here-document, which
  # bash 3.2 backs with a temporary file.
  local x IFS=$'\n'
  PANE_LINES=()
  set -f
  for x in $1; do PANE_LINES[${#PANE_LINES[@]}]=$x; done
  set +f
}

# The second field of every `held` line of the cone reader, and the live stage
# records, each kept as lines in an array for the segment loop below.
held_subjects=()
pane_lines_into "$cone"
j=0
while [ "$j" -lt "${#PANE_LINES[@]}" ]; do
  x=${PANE_LINES[$j]}
  if [ "${x%%"$TAB"*}" = held ]; then
    case "$x" in
      *"$TAB"*) x=${x#*"$TAB"}; held_subjects[${#held_subjects[@]}]=${x%%"$TAB"*} ;;
      *)        held_subjects[${#held_subjects[@]}]="" ;;
    esac
  fi
  j=$((j + 1))
done
live_recs=""
[ "$rd_ok" = 1 ] && live_recs=$(cc_live_stage_records "$rd" 2>/dev/null || true)
pane_lines_into "$live_recs"
live_rec_lines=()
[ "${#PANE_LINES[@]}" -gt 0 ] && live_rec_lines=("${PANE_LINES[@]}")
PANE_DISPATCH_RE='^S[0123456789]+:[^:]+:'

pane_is_held() {
  # pane_is_held <segment> — succeeds when it is one of the held subjects,
  # compared as whole lines.
  local j=0
  while [ "$j" -lt "${#held_subjects[@]}" ]; do
    [ "${held_subjects[$j]}" = "$1" ] && return 0
    j=$((j + 1))
  done
  return 1
}

live_rec_for() {
  # live_rec_for <segment> — PANE_REC is the first live stage record of that
  # segment, or empty. A gate-launched stage's pid file is named after the
  # segment; a driver's is its dispatch id `S<n>:<seg>:<cycle>`, whose second
  # field is the segment.
  local j=0 n
  PANE_REC=""
  while [ "$j" -lt "${#live_rec_lines[@]}" ]; do
    n=${live_rec_lines[$j]%%"$TAB"*}
    if [[ $n =~ $PANE_DISPATCH_RE ]]; then n=${n#*:}; n=${n%%:*}; fi
    if [ "$n" = "$1" ]; then PANE_REC=${live_rec_lines[$j]}; return 0; fi
    j=$((j + 1))
  done
}

sr_text() {
  # sr_text <segment> — PANE_SR is `<kind> <version>회차 · <terminal class>` of
  # its last stage-result, missing parts dropped.
  local r k v c out=""
  PANE_SR=""
  fact sr "$1"; r=$PANE_FACT; [ -n "$r" ] || return 0
  fact_col "$r" 2; k=$PANE_COL
  fact_col "$r" 3; v=$PANE_COL
  fact_col "$r" 4; c=$PANE_COL
  [ -n "$k" ] && out=$k
  [ -n "$v" ] && out="$out${out:+ }${v}회차"
  [ -n "$c" ] && out="$out${out:+ · }$c"
  PANE_SR=$out
}

n_segs=0
if [ -n "$seg_states" ]; then
  add_row gap cut - 0 1 normal ""
  add_row seg-heading cut - 0 1 normal.b "세그먼트"
  while IFS="$TAB" read -r s_id s_st s_v; do
    [ -n "$s_id" ] || continue
    n_segs=$((n_segs + 1))
    held=0
    pane_is_held "$s_id" && held=1
    live_rec_for "$s_id"; rec=$PANE_REC
    fact pre "$s_id"; fact_col "$PANE_FACT" 2; pre_v=$PANE_COL
    detail=""
    if [ -n "$rec" ]; then
      cls=run; g="⟳"; gt=accent; word="실행중"
      fact_col "$rec" 1; r_file=$PANE_COL
      fact_col "$rec" 2; r_stage=$PANE_COL
      fact_col "$rec" 3; r_pid=$PANE_COL
      r_kind=$(cc_stage_kind "$rd" "$ledger" "$r_file" 2>/dev/null || true)
      r_att=""
      case "$r_stage" in *"#"*) r_att=${r_stage##*#} ;; esac
      part=$r_kind
      [ -n "$r_att" ] && part="$part${part:+ }${r_att}회차"
      detail=$part
      if [ -n "$fields" ] && [ -n "$r_pid" ]; then
        et=$(ps -o etime= -p "$r_pid" 2>/dev/null); et=${et// /}
        pane_etime_secs "$et"; secs=$PANE_SECS
        if [ -n "$secs" ]; then
          pane_hhmm $((f_now - secs))
          detail="$detail${detail:+ · }$PANE_HM 시작"
        fi
      fi
      [ -n "$pre_v" ] && [ "$pre_v" != "없음" ] && detail="$detail${detail:+ · }선행 $pre_v"
    elif [ "$held" = 1 ]; then
      cls=held; g="▲"; gt=error; word=$s_st
      sr_text "$s_id"; detail=$PANE_SR
    elif [ "$s_v" = "done" ] && [ "$s_st" != "park" ]; then
      cls=done; g="✓"; gt=ok; word=$s_st
      fact cyc "$s_id"; cy=$PANE_FACT
      fact chk "$s_id"; ck=$PANE_FACT
      if [ -n "$cy" ]; then
        fact_col "$cy" 2; cy_c=$PANE_COL
        fact_col "$cy" 3; cy_p0=$PANE_COL
        fact_col "$cy" 4; cy_p1=$PANE_COL
        detail="리뷰 ${cy_c}회차 P0 ${cy_p0} · P1 ${cy_p1}"
      fi
      if [ -n "$ck" ]; then
        fact_col "$ck" 2; ck_pr=$PANE_COL
        fact_col "$ck" 3; ck_st=$PANE_COL
        if [ -n "$ck_pr" ]; then ck_t="PR #$ck_pr${ck_st:+ $ck_st}"; else ck_t="체크 $ck_st"; fi
        detail="$detail${detail:+ · }$ck_t"
      fi
    elif [ "$s_v" = "done" ]; then
      cls=park; g="⊘"; gt=dim; word=park
      sr_text "$s_id"; detail=$PANE_SR
    else
      cls=open; g="·"; gt=dim; word=$s_st
      sr_text "$s_id"; detail=$PANE_SR
      if [ -z "$detail" ] && [ -n "$pre_v" ] && [ "$pre_v" != "없음" ]; then
        detail="선행 $pre_v"
      fi
    fi
    add_row seg cut "$cls" "$held" 1 "$gt" "$g" normal " $s_id $word"
    [ -n "$detail" ] && add_row seg-detail cut "$cls" 0 1 dim "   $detail"
  done <<EOF
$seg_states
EOF
  FOLD_DONE=$NROWS; add_row seg-folded cut - 0 0 dim "끝난 세그먼트"
  FOLD_OPEN=$NROWS; add_row seg-folded cut - 0 0 normal "끝나지 않은 세그먼트"
fi

# ---------------------------------------------------------------------------
# Gate: what is waiting for a person. Every row here is protected.
# ---------------------------------------------------------------------------

cause_word() {
  # cause_word <cause> — PANE_CAUSE is the word the block heading shows.
  if [ "$1" = "막힘" ]; then PANE_CAUSE='사람 결정 필요'; else PANE_CAUSE=$1; fi
}

add_row gap cut - 0 1 normal ""
gate_start=$NROWS
while IFS="$TAB" read -r a_id a_cp; do
  [ -n "$a_id" ] || continue
  add_row approval cut - 1 1 accent "승인 대기 $a_id · 절단점 $a_cp"
done <<EOF
$(cc_open_approval_rows "$ledger" 2>/dev/null || true)
EOF
while IFS="$TAB" read -r b_cause b_reason; do
  [ -n "$b_reason" ] || continue
  cause_word "$b_cause"
  add_row block-heading cut - 1 1 error.b "▲ 막힘 · run · $PANE_CAUSE"
  add_row block-reason wrap - 1 1 normal "$b_reason"
done <<EOF
$(cc_unresolved_blocked "$ledger" 2>/dev/null || true)
EOF
n_unres=0
while IFS="$TAB" read -r c_kind c_subj c_cause c_reason c_obs; do
  [ -n "$c_kind" ] || continue
  if [ "$c_kind" = "held" ]; then
    t=$c_reason
    [ -n "$c_obs" ] && [ "$c_obs" != "-" ] && t="$t · $c_obs"
    cause_word "$c_cause"
    add_row block-heading cut - 1 1 error.b "▲ 막힘 · cone $c_subj · $PANE_CAUSE"
    add_row block-reason wrap - 1 1 normal "$t"
  else
    n_unres=$((n_unres + 1))
  fi
done <<EOF
$cone
EOF
[ "$n_unres" -gt 0 ] && add_row cone-unresolved cut - 1 1 dim "주체 미상 cone 막힘 ${n_unres}건"
if [ "$rd_ok" = 1 ]; then
  while IFS= read -r o_seg; do
    [ -n "$o_seg" ] || continue
    add_row orphan cut - 1 1 warn "고아 스테이지 $o_seg"
  done <<EOF
$(cc_orphan_stages "$rd" 2>/dev/null || true)
EOF
fi
# The summary only when nothing at all stands: beside a standing block it
# would say "no block".
[ "$NROWS" -eq "$gate_start" ] && add_row gate-none cut - 0 1 dim "승인 대기 없음 · 막힘 없음"

# ---------------------------------------------------------------------------
# Recent events
# ---------------------------------------------------------------------------

EV_GAP=-1; EV_HEAD=-1
if [ -n "$events" ]; then
  EV_GAP=$NROWS; add_row gap cut - 0 1 normal ""
  EV_HEAD=$NROWS; add_row event-heading cut - 0 1 normal.b "최근 이벤트 $CC_DTZ_LABEL"
  while IFS="$TAB" read -r e_t e_x; do
    [ -n "$e_x" ] || continue
    add_row event cut - 0 1 dim "$e_t" normal " $e_x"
  done <<EOF
$events
EOF
fi

# ---------------------------------------------------------------------------
# The reduction. Until the estimated total is at most the cap, in order:
#   1. events, oldest first; with none left, the event heading and its gap;
#   2. the detail rows of finished segments;
#   3. finished segments, folded into `끝난 세그먼트 N개`;
#   4. the remaining detail rows, a running segment's last;
#   5. gaps;
#   6. open segments without a held block (park included), folded into
#      `끝나지 않은 세그먼트 N개`.
# Protected rows — title, session title, head, head-detail, approvals, block
# headings and reasons, the unresolved cone count, orphans, a segment with a
# held block — are never touched, so the result is at most max(cap, floor).
# ---------------------------------------------------------------------------

over() { [ "$TOTAL" -gt "$cap" ]; }

drop_bottom_up() {
  # drop_bottom_up <bundle> [<class>...] — switch rows of that bundle off from
  # the bottom, one at a time, while over the cap. With classes, only those.
  local b="$1" i want
  shift
  want=" $* "
  i=$((NROWS - 1))
  while [ "$i" -ge 0 ] && over; do
    if [ "${RON[$i]}" = 1 ] && [ "${RB[$i]}" = "$b" ] && [ "${RP[$i]}" = 0 ]; then
      if [ "$want" = "  " ] || case "$want" in *" ${RC[$i]} "*) true ;; *) false ;; esac; then
        row_off "$i"
      fi
    fi
    i=$((i - 1))
  done
}

fold_segments() {
  # fold_segments <fold-row> <label> <class>... — fold every unprotected
  # segment of those classes, with its detail row, into one counted row.
  local fr="$1" label="$2" i n=0 want
  shift 2
  want=" $* "
  i=0
  while [ "$i" -lt "$NROWS" ]; do
    if [ "${RP[$i]}" = 0 ] && case "$want" in *" ${RC[$i]} "*) true ;; *) false ;; esac; then
      case "${RB[$i]}" in
        seg)        [ "${RON[$i]}" = 1 ] && n=$((n + 1)); row_off "$i" ;;
        seg-detail) row_off "$i" ;;
      esac
    fi
    i=$((i + 1))
  done
  if [ "$n" -gt 0 ]; then
    RF[$fr]="${RF[$fr]%%$TAB*}$TAB$label ${n}개"
    row_on "$fr"
  fi
}

if over; then
  drop_bottom_up event
  if [ "$EV_HEAD" -ge 0 ]; then
    left=0; i=$((EV_HEAD + 1))
    while [ "$i" -lt "$NROWS" ]; do
      [ "${RB[$i]}" = event ] && [ "${RON[$i]}" = 1 ] && left=$((left + 1))
      i=$((i + 1))
    done
    [ "$left" -eq 0 ] && { row_off "$EV_HEAD"; row_off "$EV_GAP"; }
  fi
fi
over && drop_bottom_up seg-detail done
over && [ "$n_segs" -gt 0 ] && fold_segments "$FOLD_DONE" "끝난 세그먼트" done
over && drop_bottom_up seg-detail open park held
over && drop_bottom_up seg-detail run
over && drop_bottom_up gap
over && [ "$n_segs" -gt 0 ] && fold_segments "$FOLD_OPEN" "끝나지 않은 세그먼트" open park run

printf 'cc-pane\t%s\t%s\t%s\t%s\t%s\n' "$PANE_SCHEMA" "$kind" "$rid" "$idx" "$refresh"
i=0
while [ "$i" -lt "$NROWS" ]; do
  [ "${RON[$i]}" = 1 ] && printf '%s\t%s\t%s\n' "${RB[$i]}" "${RM[$i]}" "${RF[$i]}"
  i=$((i + 1))
done
exit 0
