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
    # A pid file is a STAGE only if it carries a sibling one of the two spawners
    # leaves beside it: both write `<name>.start`, and the driver writes
    # `<stage>.pgid` on top of that. The glob itself has no namespace, and this
    # directory holds pids that are not stages — the watcher's `watch.pid` is
    # one — so without this the count answers a different question than its
    # name, and the run's termination condition, which has no resolving verb,
    # would never come true while a watcher ran. `.start` alone is NOT the test,
    # and the reason is no longer that the driver declines to write one: a run
    # directory laid down before the driver started recording fingerprints
    # carries only `.pgid`, so requiring `.start` would silently undercount
    # every stage in it.
    [ -f "${f%.pid}.start" ] || [ -f "${f%.pid}.pgid" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    # IDENTITY IS VERIFIED, NEVER ASSUMED. The two spawners leave the SAME
    # handle — a start-time fingerprint — so this asks for it first, and its
    # absence now means an older run directory rather than a different spawner.
    # Skipping the check whenever that handle was missing is what left the
    # driver's stages on a bare `kill -0`, which is the pid-reuse hole this
    # file exists to close.
    rec=$(cat "${f%.pid}.start" 2>/dev/null || true)
    if [ -n "$rec" ]; then
      now=$(cc_proc_fingerprint "$pid")
      [ "$rec" = "$now" ] || continue
    else
      # NOTHING TO COMPARE AGAINST — its own case, not a pass. That is what
      # this branch originally meant, and it means it again now that both
      # spawners record a fingerprint. An empty `.start` is reachable: either
      # spawner's redirection creates the file before `ps` writes into it. A
      # missing one means a run directory a driver laid down before it recorded
      # fingerprints at all, and the `.pgid` compare below is the FALLBACK for
      # exactly those directories — not the driver's regular path. An empty or
      # unreadable `.pgid` is reachable the same way. Not counting is the safe
      # direction: the run's termination condition has no resolving verb, so an
      # over-count ends the run's ability to finish permanently, while an
      # under-count costs one render.
      rec=$( { cat "${f%.pid}.pgid" 2>/dev/null || true; } | tr -d '[:space:]')
      [ -n "$rec" ] || continue
      now=$(cc_proc_pgid "$pid")
      [ -n "$now" ] || continue
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

cc_proc_pgid() {
  # cc_proc_pgid <pid> — the pid's process group id, or empty.
  # THIS IS A FALLBACK, NOT AN IDENTITY. The driver now records a start-time
  # fingerprint beside the pid as well, so the only records that reach here are
  # the ones written before it did. What the compare still filters out is a
  # stale record with no live group leader behind it; what it cannot filter out
  # is pid reuse, because the driver spawns under job control and the child then
  # leads its own group — the recorded value IS the pid, so anything that holds
  # that pid next matches as long as it leads a group of its own.
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
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

# `완료` is the third terminal state, and its absence forced every honest
# router into a false statement. A stage that produced its output and had
# nothing to merge — an audit, a review, a census — could only be recorded as
# `머지됨` (claiming a merge that did not happen) or `park` (recording a success
# as a blockage, which the morning report then cannot tell from a real one). And
# the termination condition demands every segment reach a terminal state, so
# declining to choose left the run unable to end at all.
#
# THE ENUMERATION LIVES HERE, once. It used to be declared beside the gate's
# termination check while this file carried a two-element copy in a `case`, so
# the same segment was terminal to one reader and in flight to the other.
#
# `readonly` under a guard, because this file is sourced by more than one
# consumer and a second `source` in one shell would otherwise abort with
# "readonly variable". The guard admits the canonical value and overwrites any
# other, so a caller cannot pre-seed a different terminal set.
case " ${TERMINAL_SEGMENT_STATES:-} " in
  " 머지됨 완료 park ") ;;
  *) readonly TERMINAL_SEGMENT_STATES="머지됨 완료 park" ;;
esac

cc_nonterminal_segments() {
  # cc_nonterminal_segments <ledger> — count of segments not in a terminal state.
  # `TERMINAL_SEGMENT_STATES` above is the enumeration; everything else is in
  # flight. The membership test is the gate's, verbatim, because a second
  # spelling of it is how the two readers diverged in the first place.
  local ledger="$1" sid st n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for sid in $( { grep -E '^- `segment`' "$ledger" 2>/dev/null || true; } \
                | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    st=$( { grep -E '^- `segment`' "$ledger" 2>/dev/null | grep -F "id=$sid " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    case " $TERMINAL_SEGMENT_STATES " in
      *" $st "*) ;;
      *) n=$((n + 1)) ;;
    esac
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
  # EVERY grep in this pipeline needs its own guard, not just the first. A middle
  # `grep` that matches nothing exits 1, `pipefail` promotes that to the whole
  # pipeline, and the caller runs this as a BARE statement under `set -e` — so a
  # ledger with no run-scope block at all, which is the ordinary case, killed the
  # gate's verb with status 1 and NO message. Every other refusal in this file
  # carries a sentence naming the repair; this path was the one that said nothing,
  # and a silent failure is the only kind a router cannot recover from.
  { grep -E '^- `blocked`' "$ledger" 2>/dev/null || true; } \
    | { grep -F '스코프=run' || true; } | tr '|' '\n' \
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
