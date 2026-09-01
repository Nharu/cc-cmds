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
# without the guard below there would be neither output nor fallback. And the
# resolution uses `$BASH_SOURCE` rather than `$0` because the agreement suite
# sources this file to reach its functions, and under that seam `$0` is the
# suite.
#
# NOTHING HERE WRITES. Every predicate comes from `liveness.sh`, which exists so
# that this file, the watcher and the gate answer "is this run still going?"
# with one implementation instead of three that drift.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

set -uo pipefail

# The "no run" line and the fallback line are THE SAME BYTES, deliberately. A
# session with no run of its own must render exactly what was on screen before
# this script was ever installed, so that installing it is invisible until it
# has something to say — and every degraded path lands on the same shape rather
# than on a second, subtly different one that a reader would have to learn.
#
# No trailing newline: the command this replaces ends its format string at `%s`,
# and the apply path asserts byte-identity against that output.
emit_fallback() {
  printf '[cc🎨] %s' "${PWD##*/}"
}

CC_SL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) \
  || { emit_fallback; exit 0; }
# shellcheck source=./liveness.sh
. "$CC_SL_DIR/liveness.sh" 2>/dev/null || { emit_fallback; exit 0; }

# The staleness mark, and why it is not the watcher's.
#
# 180 seconds is a RENDER that clears itself on the next tick. The watcher's
# stall arm sits at 1200 because what it writes is a ledger row that only a
# person's resolving row takes back. Two different costs, two constants; pinning
# them to each other is the one change this file must never accept.
CC_SL_STALL=180

# Twice the watcher's pinned `--interval`. The launch line fixes that value at
# 60 precisely so this threshold can be read off a contract instead of guessed.
CC_SL_HEARTBEAT_STALE=120

# A whole-slot budget, because there is no width to measure against: `$COLUMNS`
# is not exported into a child and `tput cols` answers a wrong number with a
# success code. Overflow drops low-priority slots ENTIRELY — a glyph cut in half
# is worse than a fact omitted.
CC_SL_BUDGET=72

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
  # recorded stage, or nothing.
  #
  # THIS IS A LABEL, NOT A LIVENESS JUDGEMENT, and the distinction is the reason
  # it is allowed to exist here. `cc_live_stages` has already answered whether
  # anything is running; all this picks is which name to show beside the glyph.
  # Re-deriving "which of these pids is alive" would be a second copy of the
  # predicate this design exists to have one of.
  local run_dir="$1" f seg t best_t=-1 best=""
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    # `watch.pid` shares the glob and is not a stage.
    [ "$seg" = "watch" ] && continue
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

stdin_json=$(cat 2>/dev/null || true)

# `sed`, not `jq`. The field is one flat string, this runs every ten seconds,
# and a scenario in which `jq` is absent must still resolve the run rather than
# merely avoid crashing — spending a process on a lookup a substring answers
# would buy nothing and lose that.
sid=$(printf '%s' "$stdin_json" \
      | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$sid" ] || { emit_fallback; exit 0; }

CC_SL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
idx="$CC_SL_STATE/session/$sid"
[ -f "$idx" ] || { emit_fallback; exit 0; }

# The index is a LIST — one run id per line, appended and deduped by the gate.
# A session holds several runs across a night, and the tie-break the design
# fixed is: anything still going beats anything finished, and within a class the
# later one wins. Entries whose directory is gone are skipped rather than
# pruned; pruning would put a write on a path that has none.
best_rd=""; best_rid=""; best_state=""; best_ledger=""; best_t=-1; best_term=1
while IFS= read -r rid; do
  [ -n "$rid" ] || continue
  rd="$CC_SL_STATE/run/$rid"
  # Readability is tested alongside existence. A directory that is there but
  # cannot be opened yields empty reads all the way down, and empty reads look
  # exactly like a quiet run — so without this the line would confidently
  # describe a run it never managed to read.
  [ -d "$rd" ] && [ -r "$rd" ] || continue
  ledger=$(cat "$rd/ledger-path" 2>/dev/null || true)
  st=$(cc_run_state "$rd" "$ledger" "$CC_SL_STALL" 2>/dev/null || true)
  [ -n "$st" ] || continue
  if [ "$st" = "종단" ]; then
    term=1
    # WHERE A TERMINAL TIME COMES FROM, once, for both paths. `done` carries an
    # ISO stamp but only a handful of runs ever reach the verb that writes it,
    # and a derived termination has no stamp at all — so ordering on the stamp
    # would order two populations by two different clocks. The file mtime is one
    # clock: `done`'s when it exists, the ledger's last movement otherwise.
    t=$(cc_mtime "$rd/done"); [ -n "$t" ] || t=$(cc_mtime "$ledger")
  else
    term=0
    t=$(cc_mtime "$ledger")
  fi
  [ -n "$t" ] || t=0
  if [ -z "$best_rd" ] || [ "$term" -lt "$best_term" ] \
     || { [ "$term" -eq "$best_term" ] && [ "$t" -gt "$best_t" ]; }; then
    best_rd=$rd; best_rid=$rid; best_state=$st; best_ledger=$ledger
    best_t=$t; best_term=$term
  fi
done < "$idx"

[ -n "$best_rd" ] || { emit_fallback; exit 0; }

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------

now=$(date -u +%s)

# The ledger's age comes from the watcher's heartbeat, not from an mtime this
# process measures. An elapsed-since-last-growth needs somewhere to remember the
# previous size; the watcher already remembers it, and a status line may not
# write. An absent field means "cannot judge", which is why every use below is
# guarded rather than defaulted to zero.
grew=$(cc_ledger_growth_at "$best_rd")
age_slot=""
if [ -n "$grew" ]; then
  age_slot=" · 원장 $(age_phrase "$((now - grew))")"
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
    # TERMINAL OUTRANKS THE STALL WARNING. A finished run has no live stage and
    # a ledger that stopped growing, which is also the exact shape of a stalled
    # one — judged the other way round, every clean finish would show as a
    # warning from the moment it ended and never stop.
    line="✓ ${best_rid} 종료"
    ;;
  승인대기)
    pend=$(cc_open_approvals "$best_ledger")
    line="⏸ ${best_rid} 승인 대기 ${pend}건${age_slot}"
    ;;
  정지경고)
    line="⚠ ${best_rid} 스테이지 0${age_slot}"
    ;;
  도는중)
    slot=$(newest_stage_pid "$best_rd")
    seg=${slot%% *}; pid=${slot#* }
    if [ -n "$slot" ] && [ -n "$seg" ]; then
      line="⟳ ${best_rid} ${seg}"
      kind=$(stage_kind "$best_ledger" "$seg")
      elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
      # Elapsed comes from `ps`, never from `started-at` or `.start`. The former
      # is rewritten on every gate call and is not the run's start time; the
      # latter is a formatted date string that no portable arithmetic accepts —
      # and reading it would mean branching on the two incompatible date flags.
      [ -n "$kind" ]    && line="$line ${kind}"
      [ -n "$elapsed" ] && line="$line ${elapsed}"
      # Drop whole slots, lowest priority first, until it fits.
      if [ "${#line}" -gt "$CC_SL_BUDGET" ] && [ -n "$kind" ]; then
        line="⟳ ${best_rid} ${seg}"
        [ -n "$elapsed" ] && line="$line ${elapsed}"
      fi
      [ "${#line}" -gt "$CC_SL_BUDGET" ] && line="⟳ ${best_rid} ${seg}"
    else
      line="⟳ ${best_rid}${age_slot}"
    fi
    ;;
  진행중)
    # NOT A SIXTH STATE, and not the running row either. This is the residual:
    # the run is in flight but no stage is up at this instant — between two of
    # them, with the ledger still fresh. It says `스테이지 0` for the same reason
    # the stall row does, because that is the true and load-bearing fact: a pid
    # file whose process died, or whose pid was reused, must never render as a
    # stage that is up. The only thing separating this line from the stall row
    # is the glyph, which is exactly the difference — the same facts, one of
    # them past the mark.
    line="⟳ ${best_rid} 스테이지 0${age_slot}"
    ;;
  *)
    emit_fallback; exit 0
    ;;
esac

printf '%s%s' "$line" "$watch_slot"
exit 0
