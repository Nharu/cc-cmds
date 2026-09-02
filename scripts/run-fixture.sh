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

# HOW THE DRIVER'S SHAPE DIFFERS. The driver writes a `<stage>.pgid` on top of
# the `<name>.start` both spawns leave, and job control makes that group equal
# to the pid. So the difference is not "no start time" but "one more handle,
# and it is derived from the pid". The two fixtures below omit the start time
# on purpose: that is the shape of a run directory a driver laid down before it
# recorded fingerprints, which is what the `.pgid` compare is a fallback for.
# Neither reproduces production's relationship — one inherits this suite's group
# and the other pins 1, both INDEPENDENT of the pid — so for that shape see
# `fx_stage_driver_reused_leader`.

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

fx_stage_driver_reused_leader() {
  # fx_stage_driver_reused_leader <segment> — the shape the driver actually
  # writes, for a REUSED pid: a live pid that leads its own process group, so
  # the recorded group matches on a pure string compare, beside a start-time
  # fingerprint that does not.
  #
  # Job control is scoped to the single spawn because that is what makes
  # `pgid == pid`, and `pgid == pid` is the whole point: the other driver-shaped
  # fixtures keep the group INDEPENDENT of the pid — one inherits this suite's
  # group, the other pins 1 — and independent data proves only that a comparison
  # happens. Production's value is derived from the pid, so only this shape can
  # show the comparison losing its discriminating power.
  #
  # It must be restored immediately: a section-wide setting would give every
  # later fixture its own group and take it out of the driver's group reclaim,
  # and the suite itself normally runs AS a driver-spawned stage. The child's
  # group is fixed at fork, so restoring does not move it. `FX_PIDS` still
  # carries the pid — a group of its own is exactly what a group kill misses.
  local seg="$1" pid
  set -m
  sleep 120 &
  pid=$!
  set +m
  printf '%s' "$pid" > "$FX_RUN_DIR/$seg.pid"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' > "$FX_RUN_DIR/$seg.pgid"
  printf '%s' "Mon Jan  1 00:00:00 2001" > "$FX_RUN_DIR/$seg.start"
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

# --------------------------------------------------------------------------
# Clocks, handles and the session index — what a status line reads
# --------------------------------------------------------------------------

fx_age_file() {
  # fx_age_file <path> <seconds-ago> — move a file's mtime into the past.
  #
  # `perl`, and not `touch -t`, because computing the stamp `touch` wants means
  # formatting an epoch — and that is the one operation where the two date
  # implementations take incompatible flags. `utime` takes the number directly.
  perl -e 'my ($f, $s) = @ARGV; my $t = time() - $s; utime $t, $t, $f or die "utime: $!";' \
    "$1" "$2"
}

fx_ledger_path() {
  # fx_ledger_path — the pointer the gate leaves so a reader outside the driver
  # can find the ledger. Its location is derived from the manifest, which
  # nothing but the gate knows, so without this file the status line can reach
  # the run directory and still not read a single row.
  printf '%s\n' "$FX_LEDGER" > "$FX_RUN_DIR/ledger-path"
}

fx_session_index() {
  # fx_session_index <session-id> <run-id>... — the forward index, in the
  # gate's own shape: one run id per line, appended, deduped. It is a LIST
  # because one session holds several runs across a night, and the tie-break the
  # status line applies only means anything over a list.
  local sid="$1"; shift
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session"
  mkdir -p "$dir"
  local rid
  for rid in "$@"; do
    grep -qxF "$rid" "$dir/$sid" 2>/dev/null || printf '%s\n' "$rid" >> "$dir/$sid"
  done
}

fx_heartbeat() {
  # fx_heartbeat <heartbeat-age-sec> <growth-age-sec> — the watcher's heartbeat,
  # in slice B's field order.
  #
  # THE TWO AGES ARE INDEPENDENT ON PURPOSE. The file's own mtime says whether
  # the WATCHER is alive; the `마지막성장` field says when the LEDGER last moved.
  # A healthy watcher beating every minute over a ledger that has not grown in
  # an hour is the exact shape the stall mark exists to catch, and a fixture
  # that tied the two together could not produce it.
  local hb_age="$1" grew_age="$2" grew
  grew=$(( $(date -u +%s) - grew_age ))
  printf '%s 원장 %s초 전 갱신 · 스테이지 0개 · 대기 승인 0건 · 비종단 세그먼트 1개 · 원장크기=1 · 마지막성장=%s\n' \
    "픽스처" "$grew_age" "$grew" > "$FX_RUN_DIR/watch.heartbeat"
  [ "$hb_age" -eq 0 ] || fx_age_file "$FX_RUN_DIR/watch.heartbeat" "$hb_age"
}

fx_watch_pid() {
  # fx_watch_pid <live|dead> — the watcher's own pid handle. Without it "has not
  # come up yet" and "died" are the same observation.
  local kind="$1" pid
  if [ "$kind" = "live" ]; then
    sleep 120 &
    pid=$!
    FX_PIDS="${FX_PIDS:-}$pid "
    export FX_PIDS
  else
    sleep 0 &
    pid=$!
    wait "$pid" 2>/dev/null || true
  fi
  printf '%s\n' "$pid" > "$FX_RUN_DIR/watch.pid"
}

fx_done() {
  # fx_done — the `done` file, with the ISO stamp the propose-done path writes.
  # It is a SHORTCUT for the terminal predicate, not its definition: 2 of 39
  # observed run directories had one.
  printf '%s\n' "종단 — 픽스처" > "$FX_RUN_DIR/done"
}

fx_statusline_stdin() {
  # fx_statusline_stdin <session-id> [cwd] — the one-line JSON the harness feeds
  # a status line command, carrying the five fields it documents.
  local sid="$1" cwd="${2:-$PWD}"
  printf '{"session_id":"%s","transcript_path":"/dev/null","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"},"model":{"id":"fixture","display_name":"fixture"}}' \
    "$sid" "$cwd" "$cwd" "$cwd"
}
