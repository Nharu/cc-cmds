#!/usr/bin/env bash
# run-fixture.sh — shared fixture primitives for the run-state test suites.
#
# WHY A SHARED FILE. Four suites need the same three things: a run directory
# under an isolated `XDG_STATE_HOME`, stage pid files in each of the states the
# liveness predicate distinguishes, and ledger rows whose `prev=` chain
# actually verifies. Written per-suite, the third one is where they drift — a
# fixture with a broken chain fails `gate_chain_verify` and the test then fails
# for a reason that has nothing to do with what it was asserting.
#
# This file is sourced, not executed. It defines functions and touches nothing
# until one is called.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# --------------------------------------------------------------------------
# Run directory and ledger
# --------------------------------------------------------------------------

fx_mkrun() {
  # fx_mkrun <run-id> — create an isolated run directory and an empty ledger.
  #
  # Sets FX_RUN_ID, FX_RUN_DIR, FX_LEDGER and seeds FX_PREV with the chain
  # anchor. `XDG_STATE_HOME` must already point somewhere disposable; every
  # suite here sets it to a `mktemp -d` and traps its removal.
  FX_RUN_ID="$1"
  FX_RUN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/$FX_RUN_ID"
  mkdir -p "$FX_RUN_DIR"
  FX_LEDGER="$FX_RUN_DIR/fixture-ledger.md"
  : > "$FX_LEDGER"
  # The chain's first anchor is the block heading, not a row — the same value
  # `gate_chain_verify` seeds itself with.
  FX_PREV=$(printf '%s' "## 실행 $FX_RUN_ID" | shasum -a 256 | cut -d' ' -f1)
  export FX_RUN_ID FX_RUN_DIR FX_LEDGER FX_PREV
}

fx_row() {
  # fx_row <계열> <field=value> ... — append one chained ledger row.
  #
  # The digest is taken over the line as written, which is what the verifier
  # re-walks. Callers never compute `prev=` themselves; that is the whole point
  # of this helper existing.
  local series="$1"; shift
  local line f
  line="- \`$series\`"
  for f in "$@"; do line="$line | $f"; done
  line="$line | prev=$FX_PREV"
  printf '%s\n' "$line" >> "$FX_LEDGER"
  FX_PREV=$(printf '%s' "$line" | shasum -a 256 | cut -d' ' -f1)
}

fx_approval() {
  # fx_approval <id> <상태> — an approval row. Append a second row with the same
  # id to resolve it; the fold reads the last row per id.
  fx_row '승인' "승인 id=$1" "상태=$2" "대상=-" "절단점=경계" \
    "질문 문면=픽스처" "답변 문면=-" "해소 시각=-"
}

fx_segment() {
  # fx_segment <id> <상태> — a segment row. The terminal states are 머지됨, 완료
  # and park; `TERMINAL_SEGMENT_STATES` in liveness.sh is the authority for that
  # enumeration and this comment is not a second copy of it.
  fx_row 'segment' "id=$1" "상태=$2" "워크트리=$FX_RUN_DIR"
}

fx_blocked() {
  # fx_blocked <사유> <원인> — a run-scope block. `원인=해소` on a later row with
  # the same 사유 is what resolves it.
  fx_row 'blocked' "대상=-" "스코프=run" "원인=$2" "사유=$1"
}

# --------------------------------------------------------------------------
# Stage pid files — the three states the liveness predicate separates
# --------------------------------------------------------------------------
#
# HOW A REUSED PID IS FAKED. The fingerprint comes from `ps -o lstart=`, so a
# mismatch cannot be produced by manipulating a process — it is produced by
# writing a different string into the `.start` file beside the pid. That is the
# only handle a test has, and it is faithful: what the predicate actually does
# is compare a recorded string against a freshly read one.

fx_stage_live() {
  # fx_stage_live <segment> — a stage that is running, with a matching
  # fingerprint. Records the pid in FX_LAST_PID so the caller can reap it.
  local seg="$1" pid
  sleep 120 &
  pid=$!
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  LC_TIME=C ps -o lstart= -p "$pid" 2>/dev/null \
    | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//' > "$FX_RUN_DIR/$seg.start"
  FX_LAST_PID="$pid"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_LAST_PID FX_PIDS
}

fx_stage_dead() {
  # fx_stage_dead <segment> — a pid file whose process has exited.
  #
  # The pid is taken from a process this shell reaped, so it is guaranteed to
  # have existed and guaranteed not to be running. That is stricter than
  # inventing a large number, which could collide with something real.
  local seg="$1" pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  printf '%s' "픽스처 — 죽은 스테이지" > "$FX_RUN_DIR/$seg.start"
}

fx_stage_reused() {
  # fx_stage_reused <segment> — a LIVE pid whose recorded fingerprint does not
  # match. This is the case `kill -0` alone gets wrong, and the one that made a
  # run unable to terminate: condition 7 has no resolving verb.
  local seg="$1" pid
  sleep 120 &
  pid=$!
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  printf '%s' "Mon Jan  1 00:00:00 2001" > "$FX_RUN_DIR/$seg.start"
  FX_LAST_PID="$pid"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_LAST_PID FX_PIDS
}

# HOW THE DRIVER'S SHAPE DIFFERS. The gate's spawn writes `<seg>.start`; the
# driver's writes `<stage>.pgid` and never a start time. A fixture that knows
# only the gate's shape therefore cannot produce the driver path's pid-reuse
# case at all — which is exactly the case a bare `kill -0` gets wrong.

fx_stage_driver_live() {
  # fx_stage_driver_live <segment> — a running stage in the DRIVER's shape: a
  # `.pgid` holding the pid's real process group, and no `.start`.
  #
  # The group is read back from the process rather than assumed, for the same
  # reason the driver reads it back: a background job's group is the caller's
  # unless job control gave it its own, so a written-in assumption would make
  # this fixture pass against a predicate that compares nothing.
  local seg="$1" pid
  sleep 120 &
  pid=$!
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' > "$FX_RUN_DIR/$seg.pgid"
  FX_LAST_PID="$pid"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_LAST_PID FX_PIDS
}

fx_stage_driver_reused() {
  # fx_stage_driver_reused <segment> — a LIVE pid in the driver's shape whose
  # recorded process group does not match. Group 1 is init's, and nothing this
  # fixture starts can be in it, so the mismatch is guaranteed rather than
  # merely likely.
  local seg="$1" pid
  sleep 120 &
  pid=$!
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  printf '%s\n' "1" > "$FX_RUN_DIR/$seg.pgid"
  FX_LAST_PID="$pid"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_LAST_PID FX_PIDS
}

fx_stage_unverifiable() {
  # fx_stage_unverifiable <segment> — a LIVE pid whose sibling carries no
  # identity: a zero-byte `.start`, and no `.pgid` at all.
  #
  # Reachable, not contrived. The gate creates the file by redirection before
  # `ps` writes into it, so a stage observed inside that window has the sibling
  # the glob filter demands and nothing to compare against.
  local seg="$1" pid
  sleep 120 &
  pid=$!
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  : > "$FX_RUN_DIR/$seg.start"
  FX_LAST_PID="$pid"
  FX_PIDS="${FX_PIDS:-}$pid "
  export FX_LAST_PID FX_PIDS
}

fx_reap() {
  # fx_reap — kill every process a fixture started. Call from the suite's trap;
  # a `sleep 120` left behind outlives the test run by two minutes.
  local pid
  for pid in ${FX_PIDS:-}; do
    kill "$pid" 2>/dev/null || true
  done
  FX_PIDS=""
}
