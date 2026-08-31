#!/usr/bin/env bash
# liveness.sh — the shared read-only predicates about a run's state.
#
# WHY THIS FILE EXISTS. Three consumers asked "is this run still going?" and
# each answered it with its own code: the gate's render counted `*.pid` files
# without testing whether any process was behind them, `gate_live_stages()`
# tested `kill -0` but not pid reuse, and the watcher tested both. Measured: 21
# pid files, 5 live processes, and a render that reported "살아 있는 스테이지:
# 1개 / 런 상태: 진행 중" for a run whose recorded pid was dead. The divergence
# was not a bug in any one of them — it was three implementations of one
# predicate, which is a thing that cannot stay consistent.
#
# NOTHING HERE WRITES. That is the property that lets a status line call these
# on every render. `ledger_idle_seconds` is deliberately absent: computing an
# elapsed-since-last-growth needs somewhere to remember the previous size, the
# watcher remembers it in `watch.state`, and a write is exactly what a status
# line may not do.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# Sibling resolution uses `$BASH_SOURCE` and not `$0`, because under a
# source-only seam `$0` is the SOURCING script.
CC_LIVENESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
export CC_LIVENESS_DIR

cc_live_stages() {
  # cc_live_stages <run-dir> — count of stages actually running.
  #
  # `kill -0` on recorded pids, never `wait -n`: that builtin does not exist on
  # the interpreter floor, and a re-attached stage is not this shell's child so
  # `wait` would report a clean exit for a process it never reaped.
  #
  # The `.start` fingerprint is what separates "still running" from "that pid
  # belongs to something else now". A run directory deliberately survives a
  # reboot, so a recorded pid can come back pointing at an unrelated process.
  local run_dir="$1" f pid rec now n=0
  [ -n "$run_dir" ] || { printf '0'; return 0; }
  # LC_TIME is fixed HERE rather than at script scope. These functions are
  # sourced by four different consumers; if the fingerprint's shape depended on
  # the sourcing script's locale, two of them would compare different strings
  # for the same process and disagree about whether it is alive.
  local LC_TIME=C
  export LC_TIME
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    rec=$(cat "${f%.pid}.start" 2>/dev/null || true)
    if [ -n "$rec" ]; then
      now=$(cc_proc_fingerprint "$pid")
      [ "$rec" = "$now" ] || continue
    fi
    n=$((n + 1))
  done
  printf '%s' "$n"
}

cc_proc_fingerprint() {
  # cc_proc_fingerprint <pid> — the pid's start time, whitespace-normalised.
  # The pair (pid, start time) is the identity; the pid alone is not.
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
}

cc_open_approvals() {
  # cc_open_approvals <ledger> — count of approvals still waiting.
  # Last row per id wins: the ledger is append-only, so a resolution is a later
  # row rather than an edit of the earlier one.
  local ledger="$1" id st n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for id in $( { grep -E '^- `승인`' "$ledger" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$ledger" 2>/dev/null | grep -F "승인 id=$id " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "대기" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

cc_nonterminal_segments() {
  # cc_nonterminal_segments <ledger> — count of segments not in a terminal state.
  # The terminal set is `머지됨` and `park`; everything else is in flight.
  local ledger="$1" sid st n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for sid in $( { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
                | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    st=$( { grep -E '^- `segment`' "$ledger" 2>/dev/null | grep -F "id=$sid " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    case "$st" in 머지됨|park) ;; *) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

cc_segment_count() {
  # cc_segment_count <ledger> — distinct segment ids the run has opened.
  # The terminal predicate needs this as a guard: with no segments at all,
  # "every segment is terminal" is vacuously true and a run that has not begun
  # would render as finished.
  local ledger="$1"
  [ -n "$ledger" ] || { printf '0'; return 0; }
  { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
    | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u \
    | grep -c . || true
}

cc_unresolved_blocked() {
  # cc_unresolved_blocked <ledger> — one line per unresolved run-scope block,
  # as `<원인><TAB><사유>`.
  #
  # THE RULE IS "LAST ROW PER 사유", NOT "ANY ROW". Counting raw rows made the
  # gate's termination condition a one-way latch: a ledger row is never deleted,
  # so a single run-scope block — including one a watcher raised on a false
  # positive — took the run's ability to propose done away permanently.
  #
  # The caller counts (`| wc -l`) and the caller decides what each 원인 means;
  # this function only applies the fold. That is what lets the gate's condition
  # 5 and the status line read the same rule instead of two copies of it.
  local ledger="$1" reason last cause
  [ -n "$ledger" ] || return 0
  { grep -E '^- `blocked`' "$ledger" 2>/dev/null || true; } | grep -F '스코프=run' | tr '|' '\n' \
    | sed -n 's/^ *사유=//p' | sed 's/[[:space:]]*$//' | sort -u \
    | while IFS= read -r reason; do
        [ -n "$reason" ] || continue
        last=$( { grep -E '^- `blocked`' "$ledger" 2>/dev/null | grep -F '스코프=run' \
                  | grep -F "사유=$reason " || true; } | tail -1)
        cause=$(printf '%s' "$last" | tr '|' '\n' | sed -n 's/^ *원인=//p' | sed 's/[[:space:]]*$//' | tail -1)
        [ "$cause" = "해소" ] && continue
        printf '%s\t%s\n' "$cause" "$reason"
      done
}

cc_mtime() {
  # cc_mtime <path> — epoch seconds, or empty.
  # `stat` diverges between BSD and GNU on the very flag this needs, so neither
  # spelling is used. `date -r` is present on both and takes the file directly.
  [ -f "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

cc_ledger_size() {
  # cc_ledger_size <ledger> — the ledger's size in bytes, or empty.
  #
  # SIZE, NOT MTIME. An mtime moves without a byte changing, and a restored file
  # carries an old one. Size is what the watcher already measures, and having
  # the status line measure the same quantity is the point of this function
  # existing at all.
  [ -f "$1" ] || return 0
  wc -c < "$1" 2>/dev/null | tr -d ' ' || true
}

cc_ledger_growth_at() {
  # cc_ledger_growth_at <run-dir> — epoch seconds when the ledger last grew, or
  # empty when the watcher has not published it.
  #
  # THE FIELD IS NOT HERE YET AND ITS ABSENCE IS NORMAL. The watcher carries the
  # value in its heartbeat, and putting it there is slice B's edit; the slice
  # order is C then B then A. So this reads a field that does not exist today
  # and returns empty, which `cc_run_state` treats as "cannot judge staleness"
  # rather than as "not stale". A function that is only total after a later
  # slice lands is a function this slice cannot ship.
  local run_dir="$1" hb
  [ -n "$run_dir" ] || return 0
  hb="$run_dir/watch.heartbeat"
  [ -f "$hb" ] || return 0
  sed -n 's/.*마지막성장=\([0-9][0-9]*\).*/\1/p' "$hb" 2>/dev/null | tail -1 || true
}

cc_run_state() {
  # cc_run_state <run-dir> <ledger> [stall-seconds] — one state token.
  #
  # Tokens: 도는중 · 승인대기 · 종단 · 정지경고 · 진행중
  #
  # TERMINAL IS JUDGED BEFORE THE STALL WARNING. A run that has finished has no
  # live stage and a ledger that stopped growing, which is also exactly the
  # shape of a stalled one; ordering the tests the other way labels every clean
  # finish a stall.
  #
  # `done` is a shortcut, not the definition. Measured 2026-08-30: 2 of 39 run
  # directories had the file, because almost no run reaches the propose-done
  # path — so a predicate that only read `done` would answer "진행 중" forever
  # for runs that had plainly ended.
  local run_dir="$1" ledger="$2" stall="${3:-180}"
  local live pend nonterm n_seg blocked_n grew now

  live=$(cc_live_stages "$run_dir")
  [ "$live" -gt 0 ] 2>/dev/null && { printf '도는중'; return 0; }

  blocked_n=$(cc_unresolved_blocked "$ledger" | grep -c . || true)
  pend=$(cc_open_approvals "$ledger")
  nonterm=$(cc_nonterminal_segments "$ledger")
  n_seg=$(cc_segment_count "$ledger")

  # terminal ⟺ no unresolved run-scope block ∧ ( done exists ∨ ( live = 0 ∧
  # pend = 0 ∧ nonterm = 0 ∧ n_seg ≥ 1 ) )
  if [ "${blocked_n:-0}" -eq 0 ] 2>/dev/null; then
    if [ -f "$run_dir/done" ]; then printf '종단'; return 0; fi
    if [ "${pend:-0}" -eq 0 ] 2>/dev/null \
       && [ "${nonterm:-0}" -eq 0 ] 2>/dev/null \
       && [ "${n_seg:-0}" -ge 1 ] 2>/dev/null; then
      printf '종단'; return 0
    fi
  fi

  [ "${pend:-0}" -gt 0 ] 2>/dev/null && { printf '승인대기'; return 0; }

  grew=$(cc_ledger_growth_at "$run_dir")
  if [ -n "$grew" ]; then
    now=$(date -u +%s)
    [ "$((now - grew))" -ge "$stall" ] 2>/dev/null && { printf '정지경고'; return 0; }
  fi

  printf '진행중'
}
