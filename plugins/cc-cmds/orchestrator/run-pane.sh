#!/usr/bin/env bash
# run-pane.sh <session-id> — the lines the autopilot status pane draws.
#
# THE PANE DRAWS, THIS FILE JUDGES. The mod in `hooks/autopilot-status.tsx`
# knows three words — `live`, `ended`, `none` — and a tone per line; which run
# to show, whether it is alive, what to say about it, in what order and colour,
# and how often to ask again are all decided here. A TypeScript copy of any of
# that would sit where `scripts/lint-statusline-token-arms.sh` cannot read, and
# the plugin test harness cannot run this process, so the wording has to live
# where the bash suite covers it.
#
# THE RUN IS THE STATUS LINE'S, BY CONSTRUCTION. This calls the unchanged
# `statusline.sh` with the session id and takes the run id from the second
# token of the line it prints, so the pane and the status line cannot point at
# two runs. The selection loop, its three thresholds and the demotion of a
# waiting approval with a stale heartbeat are NOT copied here, not one line of
# them: a second copy of that loop is what drifts. The second token is accepted
# only when it is a whole line of this session's index (`grep -qxF`); a run id
# format regex is not used, because the older `YYYY-MM-DD-xxxxxxxx` ids are
# still live.
#
# THE HEAD LINE IS NOT CLAIMED TO BE THE STATUS LINE'S BYTES. Without a
# `transcript_path` on stdin the borrow segment may be missing from the end of
# it. It sits after the glyph and the run id, so the class and the run are the
# same either way.
#
# OUTPUT CONTRACT. One head row, then body rows; fields are TAB-separated:
#
#   cc-pane<TAB>1<TAB><live|ended|none><TAB><rid|-><TAB><index path|-><TAB><refresh_ms>
#   <tone><TAB><text>
#
# The schema field is the string `1` and the mod compares it exactly. The index
# path is printed even when the file does not exist yet — the mod stats it for
# its mtime — and is `-` for a session id that fails the shape check. Tones are
# `normal`, `dim`, `ok`, `warn`, `error`, `accent`. The body is at most
# PANE_MAX_LINES lines: segment lines collapse first, then the tail is cut and
# the last line says how many lines went.
#
# TOTAL, AND NOTHING HERE WRITES. Every path exits 0 with a valid head row — a
# missing sibling, an unreadable run directory, a missing `ledger-path` and a
# PATH without `jq` included. `set -e` is absent for the same reason it is
# absent from `statusline.sh`. No file or directory is created.
#
# `--glyphs` prints the glyph table, one `<glyph><TAB><class>` per line, and
# nothing else. It is the read-only path the suite uses to hold this table
# against the render arms of `statusline.sh` without keeping a copy of it.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

set -uo pipefail

PANE_SCHEMA=1
PANE_MAX_LINES=15
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
  # pane_glyph_class <glyph> — `live` or `ended`.
  case " $PANE_LIVE_GLYPHS " in
    *" $1 "*) printf 'live' ;;
    *)        printf 'ended' ;;
  esac
}

if [ "${1:-}" = "--glyphs" ]; then
  for g in $PANE_LIVE_GLYPHS $PANE_ENDED_GLYPHS; do
    printf '%s\t%s\n' "$g" "$(pane_glyph_class "$g")"
  done
  exit 0
fi

sid="${1:-}"
PANE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
PANE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || PANE_DIR=""

pane_none() {
  # pane_none <index-path|-> — the head row and the one body line of a session
  # with no run to show, then exit.
  printf 'cc-pane\t%s\tnone\t-\t%s\t%s\n' "$PANE_SCHEMA" "$1" "$PANE_REFRESH_OTHER"
  printf 'dim\t연결된 런 없음\n'
  exit 0
}

# THE SESSION ID IS A PATH SEGMENT AND A JSON STRING, so its shape is checked
# before it becomes either. A value made only of dots passes the character
# class and names the index directory itself or its parent. The check is on the
# session id alone; run ids are taken as the index lists them.
if [ -z "$sid" ] || ! printf '%s' "$sid" | LC_ALL=C grep -qE '^[A-Za-z0-9._-]+$'; then
  pane_none -
fi
case "$sid" in *[!.]*) ;; *) pane_none - ;; esac

idx="$PANE_STATE/session/$sid"

[ -n "$PANE_DIR" ] && [ -f "$PANE_DIR/statusline.sh" ] || pane_none "$idx"
head_line=$(printf '{"session_id":"%s"}' "$sid" | bash "$PANE_DIR/statusline.sh" 2>/dev/null) || true

# The status line's no-run output starts with an ESC byte, and its second token
# is a directory name rather than a run id; the index check below rejects it on
# its own, and the ESC test says why in one comparison.
esc=$(printf '\033')
case "$head_line" in
  ""|"$esc"*) pane_none "$idx" ;;
esac
glyph=${head_line%% *}
rest=${head_line#* }
rid=${rest%% *}
[ -n "$rid" ] && [ "$rid" != "$head_line" ] || pane_none "$idx"
grep -qxF -- "$rid" "$idx" 2>/dev/null || pane_none "$idx"

kind=$(pane_glyph_class "$glyph")
refresh=$PANE_REFRESH_OTHER
[ "$kind" = "live" ] && refresh=$PANE_REFRESH_LIVE

rd="$PANE_STATE/run/$rid"
ledger=""
if [ -d "$rd" ] && [ -r "$rd" ]; then
  ledger=$(cat "$rd/ledger-path" 2>/dev/null || true)
fi
[ -n "$ledger" ] && [ -r "$ledger" ] || ledger=""

# Sourced relative to this file, never through an environment variable, so a
# checkout carries its own pair. A failed source still leaves the head row and
# the head line; the detail groups below are then simply empty.
have_liveness=0
if [ -f "$PANE_DIR/liveness.sh" ]; then
  # shellcheck source=./liveness.sh
  . "$PANE_DIR/liveness.sh" 2>/dev/null && have_liveness=1
fi

TAB=$(printf '\t')
NL='
'

# ---------------------------------------------------------------------------
# The groups, in drawing order. Each is a newline-joined list of body lines.
# ---------------------------------------------------------------------------

seg_open=""; n_open=0; n_done=0
approvals=""; run_blocks=""; cone_held=""; n_cone_unresolved=0; orphans=""

if [ "$have_liveness" = 1 ] && [ -n "$ledger" ]; then
  # Done or not is the third field and nothing else: the 상태 field cannot tell
  # a `머지됨` that still owes its apply from one that does not.
  while IFS="$TAB" read -r s_id s_st s_v; do
    [ -n "$s_id" ] || continue
    if [ "$s_v" = "open" ]; then
      seg_open="$seg_open${seg_open:+$NL}normal${TAB}세그먼트 $s_id $s_st"
      n_open=$((n_open + 1))
    else
      n_done=$((n_done + 1))
    fi
  done <<EOF
$(cc_segment_states "$ledger" 2>/dev/null || true)
EOF

  while IFS="$TAB" read -r a_id a_cp; do
    [ -n "$a_id" ] || continue
    approvals="$approvals${approvals:+$NL}accent${TAB}승인 대기 $a_id · 절단점 $a_cp"
  done <<EOF
$(cc_open_approval_rows "$ledger" 2>/dev/null || true)
EOF

  while IFS="$TAB" read -r b_cause b_reason; do
    [ -n "$b_reason" ] || continue
    run_blocks="$run_blocks${run_blocks:+$NL}error${TAB}run 막힘 · $b_cause · $b_reason"
  done <<EOF
$(cc_unresolved_blocked "$ledger" 2>/dev/null || true)
EOF

  while IFS="$TAB" read -r c_kind c_subj c_cause c_reason c_obs; do
    [ -n "$c_kind" ] || continue
    if [ "$c_kind" = "held" ]; then
      t="cone 막힘 $c_subj · $c_cause · $c_reason"
      [ -n "$c_obs" ] && [ "$c_obs" != "-" ] && t="$t · $c_obs"
      cone_held="$cone_held${cone_held:+$NL}warn${TAB}$t"
    else
      n_cone_unresolved=$((n_cone_unresolved + 1))
    fi
  done <<EOF
$(cc_cone_blocked "$ledger" 2>/dev/null || true)
EOF
fi

if [ "$have_liveness" = 1 ] && [ -d "$rd" ] && [ -r "$rd" ]; then
  while IFS= read -r o_seg; do
    [ -n "$o_seg" ] || continue
    orphans="$orphans${orphans:+$NL}warn${TAB}고아 스테이지 $o_seg"
  done <<EOF
$(cc_orphan_stages "$rd" 2>/dev/null || true)
EOF
fi

seg_done=""
[ "$n_done" -gt 0 ] && seg_done="dim${TAB}끝난 세그먼트 ${n_done}개"
cone_unresolved=""
[ "$n_cone_unresolved" -gt 0 ] && cone_unresolved="dim${TAB}주체 미상 cone 막힘 ${n_cone_unresolved}건"

count_lines() {
  # count_lines <text> — the number of non-empty lines.
  [ -n "$1" ] || { printf '0'; return 0; }
  printf '%s\n' "$1" | grep -c . || true
}

# ---------------------------------------------------------------------------
# The cap. Segment lines go first because they are the group a person acts on
# least; a run with many segments would otherwise push its block lines — the
# ones that say what is waiting for a person — past the cut.
# ---------------------------------------------------------------------------

tail_text=""
for part in "$approvals" "$run_blocks" "$cone_held" "$cone_unresolved" "$orphans"; do
  [ -n "$part" ] && tail_text="$tail_text${tail_text:+$NL}$part"
done
n_tail=$(count_lines "$tail_text")
n_seg_done=0; [ -n "$seg_done" ] && n_seg_done=1

if [ $((1 + n_open + n_seg_done + n_tail)) -gt "$PANE_MAX_LINES" ] && [ "$n_open" -gt 0 ]; then
  seg_open="normal${TAB}끝나지 않은 세그먼트 ${n_open}개"
fi

body="normal${TAB}${head_line}"
for part in "$seg_open" "$seg_done" "$tail_text"; do
  [ -n "$part" ] && body="$body$NL$part"
done

n_body=$(count_lines "$body")
if [ "$n_body" -gt "$PANE_MAX_LINES" ]; then
  keep=$((PANE_MAX_LINES - 1))
  body="$(printf '%s\n' "$body" | head -n "$keep")$NL"
  body="${body}dim${TAB}+$((n_body - keep))개 더"
fi

printf 'cc-pane\t%s\t%s\t%s\t%s\t%s\n' "$PANE_SCHEMA" "$kind" "$rid" "$idx" "$refresh"
printf '%s\n' "$body"
exit 0
