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
# THE SETTLEMENT CANDIDATE PREDICATE AND THE `.settling` RECLAIM live in
# `cc_orphan_stages` below, and they are here rather than in the gate's prelude
# because three readers — the watcher's alarm, the snapshot's `orphan_stages[]`
# and the prelude that settles a lost dispatch as `외부 종료` — must see one
# list. A settler that pre-empts a record by renaming `<seg>.pid` to
# `<seg>.pid.settling.<pid>` and then dies leaves a name no `*.pid` glob walks,
# so a visible orphan would become an invisible one; the reclaim rule (a
# `.settling` marker older than 60 seconds is listed again) sits inside the
# enumeration so every reader inherits it without spelling it a second time.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# Sibling resolution uses `$BASH_SOURCE` and not `$0`, because under a
# source-only seam `$0` is the SOURCING script.
CC_LIVENESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
export CC_LIVENESS_DIR

cc_stage_is_live() {
  # cc_stage_is_live <run-dir> <segment> — succeeds when that segment's recorded
  # pid is still the process the run started.
  #
  # ONE STAGE AT A TIME, so that a consumer needing the answer about a single
  # segment — which name belongs beside a "running" glyph — can have it without
  # growing a judgement of its own. `cc_live_stages` below is this function in a
  # loop, and that is the whole relationship between them: the census and the
  # label cannot disagree because there is nothing for them to disagree about.
  #
  # `kill -0` on recorded pids, never `wait -n`: that builtin does not exist on
  # the interpreter floor, and a re-attached stage is not this shell's child so
  # `wait` would report a clean exit for a process it never reaped.
  #
  # The `.start` fingerprint is what separates "still running" from "that pid
  # belongs to something else now". A run directory deliberately survives a
  # reboot, so a recorded pid can come back pointing at an unrelated process.
  local run_dir="$1" seg="$2" f pid rec now
  [ -n "$run_dir" ] && [ -n "$seg" ] || return 1
  f="$run_dir/$seg.pid"
  [ -f "$f" ] || return 1
  # The fingerprint's shape must not depend on the sourcing script's locale, or
  # two of the four consumers compare different strings for the same process and
  # disagree about whether it is alive. Pinning it here is not enough on its own:
  # `LC_TIME` loses to `LC_ALL`, so a consumer launched from a shell that exports
  # `LC_ALL` kept reading the localised form while the writer — which clears
  # `LC_ALL` before it records — had written the C form. The capture itself
  # therefore pins `LC_ALL`, which nothing outranks; this stays for the callers
  # that read a fingerprint without going through the capture.
  local LC_TIME=C
  export LC_TIME
  # A pid file is a STAGE only if it carries a sibling one of the two spawners
  # leaves beside it: both write `<name>.start`, and the driver writes
  # `<stage>.pgid` on top of that. The glob its callers walk has no namespace,
  # and a run directory holds pids that are not stages — the watcher's
  # `watch.pid` is one — so without this the count answers a different question
  # than its name, and the run's termination condition, which has no resolving
  # verb, would never come true while a watcher ran. `.start` alone is NOT the
  # test, and the reason is no longer that the driver declines to write one: a
  # run directory laid down before the driver started recording fingerprints
  # carries only `.pgid`, so requiring `.start` would silently undercount every
  # stage in it.
  [ -f "$run_dir/$seg.start" ] || [ -f "$run_dir/$seg.pgid" ] || return 1
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # IDENTITY IS VERIFIED, NEVER ASSUMED. The two spawners leave the SAME
  # handle — a start-time fingerprint — so this asks for it first, and its
  # absence now means an older run directory rather than a different spawner.
  # Skipping the check whenever that handle was missing is what left the
  # driver's stages on a bare `kill -0`, which is the pid-reuse hole this
  # file exists to close.
  rec=$(cat "$run_dir/$seg.start" 2>/dev/null || true)
  if [ -n "$rec" ]; then
    now=$(cc_proc_fingerprint "$pid")
    [ "$rec" = "$now" ] || return 1
    return 0
  fi
  # NOTHING TO COMPARE AGAINST — its own case, not a pass. That is what this
  # branch originally meant, and it means it again now that both spawners
  # record a fingerprint. An empty `.start` is reachable: either spawner's
  # redirection creates the file before `ps` writes into it. A missing one means
  # a run directory a driver laid down before it recorded fingerprints at all,
  # and the `.pgid` compare below is the FALLBACK for exactly those directories
  # — not the driver's regular path. An empty or unreadable `.pgid` is reachable
  # the same way. Not counting is the safe direction: the run's termination
  # condition has no resolving verb, so an over-count ends the run's ability to
  # finish permanently, while an under-count costs one render.
  rec=$( { cat "$run_dir/$seg.pgid" 2>/dev/null || true; } | tr -d '[:space:]')
  [ -n "$rec" ] || return 1
  now=$(cc_proc_pgid "$pid")
  [ -n "$now" ] || return 1
  [ "$rec" = "$now" ] || return 1
  return 0
}

cc_live_stages() {
  # cc_live_stages <run-dir> — count of stages actually running.
  #
  # The census, not the judgement: every decision about a single pid lives in
  # `cc_stage_is_live` above. The `if` is not stylistic — a bare `&&` here
  # returns non-zero on the last iteration when that stage is dead, and this
  # file is sourced by consumers running under `set -e`.
  local run_dir="$1" f seg n=0
  [ -n "$run_dir" ] || { printf '0'; return 0; }
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    if cc_stage_is_live "$run_dir" "$seg"; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

cc_orphan_stages() {
  # cc_orphan_stages <run-dir> — the segment ids whose dispatch record outlived
  # the process it names, one per line.
  #
  # THIS IS THE FINGERPRINT OF A LOST DISPATCH, and it exists because that
  # failure was silent at every layer that could have spoken. `gate_launch_stage`
  # writes `<seg>.pid`, blocks on the stage, and then removes the record and
  # writes the `stage-result` row — in that order, in one function. So a record
  # that is still here while its process is gone means the line after the block
  # never ran, which means the outcome was never recorded and the stage's own
  # stream has no terminal line either. Nothing else in the run says so: the
  # dispatching shift ends normally, its stream carries a result line, and the
  # ledger shows a shift that finished and a stage that never was.
  #
  # Measured: three dispatches lost this way in one run, zero rows written, and
  # every layer reporting success. The dispatch had been issued in the
  # foreground, the harness moved it to a background task at the tool timeout
  # and reported that as a non-error, and the moved process died with the
  # shift's session.
  #
  # NARROWER THAN `! cc_stage_is_live`, deliberately. That predicate is also
  # false when a run directory predates fingerprint recording, and calling those
  # orphans would report an alarm on directories where nothing is wrong. What is
  # asked here is only "is the process this record names still here" — a dead
  # pid, or a live pid that is now somebody else. An unverifiable record is left
  # out; under-reporting costs a render, over-reporting teaches its reader to
  # ignore the alarm.
  #
  # NARROWER AGAIN WHERE A SUPERVISOR IS RECORDED. The gate's supervisor writes
  # the `stage-result` row FIRST and removes the record afterwards, so there is a
  # window — the CLI is gone, the row is being written — in which the pid alone
  # reads as an orphan, and a settler acting on that reading would write a false
  # `외부 종료` beside the real row about to land. So where `<seg>.sup` names a
  # supervisor, the record is an orphan only when the supervisor is gone too:
  # its pid dead, or — when `<seg>.sup.start` holds a fingerprint — reused. A
  # `.sup` with an empty or missing fingerprint is judged on `kill -0` alone,
  # the same reading the `.start` compare below applies to a CLI pid. A run
  # directory with no `.sup` at all behaves exactly as before.
  #
  # AND THE `.settling` RECLAIM. A settler pre-empts a record by renaming its
  # pid file to `<seg>.pid.settling.<pid>`; if it dies before appending its row
  # the record survives under a name no `*.pid` glob reaches. Those markers are
  # walked here too and listed once their mtime is older than 60 seconds — the
  # question for them is "is this PRE-EMPTION still alive", not "is the CLI",
  # so neither the pid nor the `.sup` condition applies to a reclaimed entry.
  local run_dir="$1" f seg pid rec now sup sup_rec sup_now mt nowts
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    # THE RUN-SCOPE PROCESSES' OWN RECORDS LIVE HERE TOO AND ARE NOT STAGES.
    # `watch.pid` and `checks.pid` are written by loops the gate never dispatched
    # and never blocks on, so the reasoning above — "the line after the block
    # never ran" — has no counterpart for them. Left in, each normal exit of
    # either loop raises a false orphan alarm on every single run.
    #
    # THIS EXEMPTION IS BY NAME, AND IT IS A DIFFERENT MECHANISM FROM THE ONE
    # THE LIVE CENSUS USES. `cc_live_stages`/`cc_stage_is_live` above exempt the
    # same two files STRUCTURALLY — they require a `.start`/`.pgid` sibling and
    # neither loop writes one — so nothing there needs a name. Here the question
    # is only "is this pid still here", which any pid file answers, so the name
    # is the only handle there is. Reading the two exemptions as one mechanism
    # leads to deleting this line on the grounds that the structural check
    # already covers it, and then the alarm returns.
    case "$seg" in watch|checks) continue ;; esac
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      cc_supervisor_is_live "$run_dir" "$seg" || printf '%s\n' "$seg"
      continue
    fi
    # Alive, so the only remaining orphan is pid reuse — that pid is a different
    # process now. Judged only where a fingerprint was recorded to judge against.
    rec=$(cat "$run_dir/$seg.start" 2>/dev/null || true)
    if [ -n "$rec" ]; then
      now=$(cc_proc_fingerprint "$pid")
      if [ "$rec" != "$now" ]; then
        cc_supervisor_is_live "$run_dir" "$seg" || printf '%s\n' "$seg"
      fi
    fi
  done
  nowts=$(date -u +%s)
  for f in "$run_dir"/*.pid.settling*; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%%.pid.settling*}
    [ -n "$seg" ] || continue
    mt=$(cc_mtime "$f")
    [ -n "$mt" ] || continue
    [ $((nowts - mt)) -gt 60 ] || continue
    printf '%s\n' "$seg"
  done
  return 0
}

cc_supervisor_is_live() {
  # cc_supervisor_is_live <run-dir> <segment> — succeeds when `<seg>.sup` names
  # a supervisor that is still the process the dispatch started.
  #
  # NO `.sup` IS "NO SUPERVISOR", i.e. failure: the caller asks this only after
  # the CLI pid has been judged gone, and a record without a supervisor is then
  # exactly what an orphan is. A `.sup` whose fingerprint file is empty or
  # absent is judged on `kill -0` alone — a supervisor that exited between pid
  # capture and fingerprint capture (a launch token it was refused, say) leaves
  # the file empty, and that is a recorded fact rather than a defect to hide.
  local run_dir="$1" seg="$2" sup rec now
  [ -f "$run_dir/$seg.sup" ] || return 1
  sup=$( { cat "$run_dir/$seg.sup" 2>/dev/null || true; } | tr -d '[:space:]')
  [ -n "$sup" ] || return 1
  kill -0 "$sup" 2>/dev/null || return 1
  rec=$(cat "$run_dir/$seg.sup.start" 2>/dev/null || true)
  [ -n "$rec" ] || return 0
  now=$(cc_proc_fingerprint "$sup")
  [ "$rec" = "$now" ]
}

cc_live_stage_records() {
  # cc_live_stage_records <run-dir> — one line per stage `cc_stage_is_live`
  # accepts: `<segment>\t<stage-id>\t<pid>\t<sup>\t<start>`.
  #
  # THE ONE SOURCE for the snapshot's `live_stages[]` and the render's list of
  # names beside "살아 있는 스테이지: N개". The census (`cc_live_stages`) is a
  # count and could not tell a router WHICH segment to `wait` on; this is the
  # same predicate returning the names, so the two cannot disagree. The stage id
  # is `<seg>#<attempt>` when `<seg>.attempt` exists and the bare segment when
  # it does not (a driver-spawned stage has no pin); `sup` is the supervisor's
  # pid from `<seg>.sup`, or `-` for a record the driver wrote.
  local run_dir="$1" f seg pid att sup start
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.pid; do
    [ -f "$f" ] || continue
    seg=${f##*/}; seg=${seg%.pid}
    cc_stage_is_live "$run_dir" "$seg" || continue
    pid=$( { cat "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    att=$( { cat "$run_dir/$seg.attempt" 2>/dev/null || true; } | tr -d '[:space:]')
    sup=$( { cat "$run_dir/$seg.sup" 2>/dev/null || true; } | tr -d '[:space:]')
    start=$( { cat "$run_dir/$seg.start" 2>/dev/null || true; } | tr -d '\n')
    printf '%s\t%s\t%s\t%s\t%s\n' "$seg" "$seg${att:+#$att}" "$pid" "${sup:--}" "$start"
  done
  return 0
}

cc_shift_is_live() {
  # cc_shift_is_live <run-dir> — succeeds when `shift.live` names a shift child
  # that is still the process the launcher started.
  #
  # `shift.live` holds the pid on line 1 and its fingerprint on line 2. BOTH
  # ARE REQUIRED: without the fingerprint, pid reuse after the shift ends would
  # keep the watcher's `shift_active` true forever and permanently disarm its
  # after-stage arm. The name is outside the `*.pid` glob on purpose, so a live
  # shift is never counted as a live stage.
  local run_dir="$1" pid rec now
  [ -f "$run_dir/shift.live" ] || return 1
  pid=$(sed -n '1p' "$run_dir/shift.live" 2>/dev/null | tr -d '[:space:]')
  rec=$(sed -n '2p' "$run_dir/shift.live" 2>/dev/null || true)
  [ -n "$pid" ] && [ -n "$rec" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  now=$(cc_proc_fingerprint "$pid")
  [ "$rec" = "$now" ]
}

cc_pid_exists() {
  # cc_pid_exists <pid> — succeeds when some process holds that pid, and says
  # nothing about WHICH process that is.
  #
  # A BARE EXISTENCE TEST, and the name says so, because every other predicate
  # here answers "is it still the process that was started" and this one cannot:
  # its caller is the gate's `checks` drain lock, whose owner line records a pid
  # and a time and no start fingerprint. It lives here rather than inline because
  # a `kill -0` written in the gate is a liveness judgement of the gate's own,
  # which is the divergence this file exists to prevent. Pid reuse is bounded by
  # that caller instead: it also takes a lock over on age, so a recycled pid
  # keeps a dead owner's lock for at most the sixty seconds that arm allows.
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null
}

cc_holder_is_live() {
  # cc_holder_is_live <pid> <fingerprint> — succeeds when that pid is still the
  # process whose start fingerprint was recorded beside it. The holder records
  # of a dispatch lock and a waiting marker are judged here, so the gate keeps
  # no liveness test of its own.
  local pid="${1:-}" fp="${2:-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$fp" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(cc_proc_fingerprint "$pid")" = "$fp" ]
}

cc_proc_fingerprint() {
  # cc_proc_fingerprint <pid> — the pid's start time, whitespace-normalised.
  # The pair (pid, start time) is the identity; the pid alone is not.
  #
  # `LC_ALL` rather than `LC_TIME`, because this string is compared across
  # process boundaries and the two sides do not share an environment. `ps -o
  # lstart=` is a localised date — under a Korean locale it reads `2026년 9월 4일
  # 금요일 00시 35분 25초` where the C locale reads `Fri Sep 4 00:35:25 2026` —
  # and `LC_TIME` is overridden by an inherited `LC_ALL`, so a writer that had
  # cleared `LC_ALL` and a reader that had not produced different strings for one
  # live process. The reader then called it dead. `LC_ALL` as a command prefix
  # outranks every other locale variable and does not leak past this line.
  #
  # A DEAD PID IS AN ANSWER, NOT A FAILURE, and the `|| true` is what says so to
  # the caller's shell. `ps` exits 1 when the pid is gone, and under the
  # `set -euo pipefail` this file is sourced into, `pipefail` raises that status
  # out of the pipeline and `errexit` ends the caller on the spot. The callers
  # are supervisors and liveness probes, and asking about a process that has
  # already been reaped is their ordinary case — measured: a stage that exited
  # before its supervisor reached this line took the supervisor down with it,
  # leaving no terminal row, no cleanup and a record nothing could settle. The
  # empty string this returns for a dead pid is what every caller already treats
  # as "no fingerprint"; swallowing the status here covers all of them at once.
  { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true; } \
    | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
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

# ---------------------------------------------------------------------------
# The wake chain — when the machine last woke, and the host seam it rests on.
#
# IT MOVED HERE WHOLE, from the driver. A waiting stage's freshness is measured
# from the later of its own refresh and the machine's wake, and the readers of
# that freshness — the watcher, the status line, the snapshot — source this file
# and not the driver. Moving one function would have cut the chain: the wake
# reading needs its source, the source needs the platform test, the platform
# test needs the host. The driver sources this file, so its callers are the same.
#
# THE HOST IS READ, NEVER ASSIGNED, HERE. The driver assigns `ORCH_HOST_OS` once
# at its top level and other places read that variable directly, and the test
# harness assigns it too. This file is sourced on every status-line render, so a
# top-level assignment would start `uname` per render, and an assignment inside
# the function is lost whenever the function runs in a substitution. A shell
# that sourced only this file reads the injection seam, then `uname`.
# ---------------------------------------------------------------------------
platform_supported() { [ "${ORCH_HOST_OS:-${CC_CMDS_ORCH_HOST_OS:-$(uname -s)}}" = "Darwin" ]; }

# Source selection is seam-driven, so it is exercised under injection on any
# runner. Whether the selected binary EXISTS is a separate question, and it is
# one only the darwin leg can answer.
boot_source() { platform_supported && printf 'kern.boottime' || printf ''; }
wake_source() { platform_supported && printf 'kern.waketime' || printf ''; }

# Sleep discriminator. Closing the lid leaves a stage alive with a stalled
# transcript, which the resume table would otherwise read as the limit-exhaustion
# shape and act on — killing and re-running on false evidence. Wall-clock moves
# across a sleep; the wake timestamp records that it happened.
sysctl_sec() {
  # No key selected (non-darwin) means no reading, not a reading of zero. The
  # pipeline is guarded so a missing key cannot abort a caller running under
  # `set -e`.
  [ -n "$1" ] || return 0
  { sysctl -n "$1" 2>/dev/null || true; } \
    | awk -F'[ ,]+' '{for(i=1;i<=NF;i++) if($i=="sec"){print $(i+2); exit}}'
}
boot_epoch() { sysctl_sec "$(boot_source)"; }
wake_epoch() { sysctl_sec "$(wake_source)"; }

machine_slept_since() {
  local since="$1" w
  w=$(wake_epoch)
  [ -n "$w" ] || return 1
  [ "$w" = "0" ] && return 1
  [ "$w" -gt "$since" ]
}

# ---------------------------------------------------------------------------
# The effective stall threshold, for a stage that waits for an account.
#
# A WAITER PACES ITS HEARTBEAT ON THE WATCHER'S THRESHOLD, so it has to read the
# value the watcher is actually using. The watcher rewrites `watch.stall` every
# pass — line 1 the threshold in seconds, line 2 its own pid, line 3 that pid's
# fingerprint — and the value counts only while that writer is still the same
# live process: a dead watcher's test value must not pull every wait down to it.
#
# WITHOUT A LIVE WRITER, THE SHIPPED DEFAULT IS READ FROM THE WATCHER ITSELF —
# its one default declaration, matched with the same expression the threshold-pin
# lint uses, in the watcher beside this file (the run's pinned copy when the gate
# sourced it). There is no second literal to drift. When that declaration is not
# exactly one, nothing is printed and the status is 1: the caller does not wait.
# ---------------------------------------------------------------------------
cc_effective_stall() {
  # cc_effective_stall <run-dir> — the threshold in seconds, or rc 1.
  local f="${1:-}/watch.stall" v pid rec now decl n
  if [ -n "${1:-}" ] && [ -f "$f" ]; then
    v=$( { sed -n '1p' "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    pid=$( { sed -n '2p' "$f" 2>/dev/null || true; } | tr -d '[:space:]')
    rec=$(sed -n '3p' "$f" 2>/dev/null || true)
    case "$v:$pid" in
      *[!0-9:]*|:*|*:) ;;
      *)
        if [ "$((10#$v))" -gt 0 ] && [ -n "$rec" ] && kill -0 "$pid" 2>/dev/null; then
          now=$(cc_proc_fingerprint "$pid")
          if [ "$rec" = "$now" ]; then printf '%s' "$((10#$v))"; return 0; fi
        fi
        ;;
    esac
  fi
  decl=$(LC_ALL=C grep -oE '(^|[;[:space:]])STALL=[0-9]+' "$CC_LIVENESS_DIR/watch.sh" 2>/dev/null || true)
  [ -n "$decl" ] || return 1
  n=$(printf '%s\n' "$decl" | grep -c '' || true)
  [ "$n" = "1" ] || return 1
  v=${decl##*=}
  [ "$((10#$v))" -gt 0 ] || return 1
  printf '%s' "$((10#$v))"
}

cc_wait_chunk() {
  # cc_wait_chunk <stall> — half the threshold, never below one second. A row
  # every half threshold leaves the other half for the router call that comes
  # between two rows; the floor keeps a test-sized threshold from a busy loop.
  local s="$((10#${1:-0}))"
  s=$((s / 2))
  [ "$s" -ge 1 ] || s=1
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Stages that wait for an account before they spawn.
#
# A WAITING STAGE HAS NO PROCESS OF ITS OWN YET, so none of the predicates above
# can see it: no `<key>.pid`, so it is neither live nor an orphan. What it has is
# a marker, `<key>.waiting`, written by whoever waits — the gate's supervisor or
# the driver — as `key=value` lines: 보유자 (the waiting process), 지문 (its
# fingerprint), 기록자 (게이트 or 드라이버), 계보, 그룹, 까지 (epoch or `-`),
# 갱신 (epoch of the last heartbeat), 종류, 논스, 시도, 재파견.
#
# MEMBERSHIP IS THE HOLDER'S LIFE, NOT A CLOCK. A key is waiting when the holder
# is still the process that wrote the marker, the key has no live stage, and the
# attempt has no terminal row — no `stage-result` and no `blocked` row naming its
# lineage. A refresh time is a wall clock, and a machine that slept two hours
# would otherwise drop a healthy waiter and let the key be dispatched again.
#
# FRESHNESS IS SEPARATE AND ONLY QUIETS ALARMS. A member is fresh while the later
# of its refresh and the machine's wake is younger than the effective stall
# threshold. A waiter whose refresh stopped while its holder lives is still a
# member — it is not dispatched again — but it no longer quiets the watcher;
# killing the holder is the recovery, and settlement then closes the attempt.
#
# None of these counts toward `cc_live_stages`: a waiting stage holds no
# account yet, and that census means running stages.
# ---------------------------------------------------------------------------
cc_waiting_field() {
  # cc_waiting_field <marker> <key> — the value of that key, or empty.
  { sed -n "s/^$2=//p" "$1" 2>/dev/null || true; } | tail -1
}

cc_rows_naming_lineage() {
  # cc_rows_naming_lineage <lineage> — the stdin rows that carry `계보=<lineage>`
  # as a whole value. `B:S1#1` must not match inside `B:S1#10`, so the character
  # after the value has to end it.
  awk -v pat="계보=$1" '{
    s = $0
    while ((i = index(s, pat)) > 0) {
      c = substr(s, i + length(pat), 1)
      if (c !~ /[0-9A-Za-z_.#:-]/) { print; next }
      s = substr(s, i + length(pat))
    }
  }'
}

cc_waiting_is_member() {
  # cc_waiting_is_member <run-dir> <ledger> <key> — succeeds when that key is a
  # waiting stage.
  local run_dir="$1" ledger="$2" key="$3" f pid fp now att lin
  [ -n "$run_dir" ] && [ -n "$key" ] || return 1
  f="$run_dir/$key.waiting"
  [ -f "$f" ] || return 1
  pid=$(cc_waiting_field "$f" '보유자' | tr -d '[:space:]')
  fp=$(cc_waiting_field "$f" '지문')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$fp" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  now=$(cc_proc_fingerprint "$pid")
  [ "$fp" = "$now" ] || return 1
  if cc_stage_is_live "$run_dir" "$key"; then return 1; fi
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  att=$(cc_waiting_field "$f" '시도' | tr -d '[:space:]')
  lin=$(cc_waiting_field "$f" '계보')
  if [ -n "$att" ] \
     && [ -n "$( { grep -E '^- `stage-result`' "$ledger" 2>/dev/null || true; } \
                 | { grep -F -e "세그먼트=$key " -e "스테이지=$key " || true; } \
                 | { grep -F "실행 버전=$att " || true; } )" ]; then
    return 1
  fi
  if [ -n "$lin" ] \
     && [ -n "$( { grep -E '^- `blocked`' "$ledger" 2>/dev/null || true; } | cc_rows_naming_lineage "$lin")" ]; then
    return 1
  fi
  return 0
}

cc_waiting_age_base() {
  # cc_waiting_age_base <refreshed> <wake> — the epoch freshness is measured
  # from: the later of the two, the refresh alone when the wake is empty or 0.
  local r="${1:-0}" w="${2:-}"
  case "$r" in ''|*[!0-9]*) r=0 ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  if [ "$w" -gt "$r" ]; then printf '%s' "$w"; else printf '%s' "$r"; fi
}

cc_waiting_records() {
  # cc_waiting_records <run-dir> <ledger> [stall] — one line per waiting stage:
  # `<key>\t<lineage>\t<group>\t<until>\t<refreshed>\t<holder>\t<writer>\t<fresh>`,
  # `<fresh>` being `true` or `false`. The stall threshold defaults to the
  # effective one; with none, no member is fresh.
  local run_dir="$1" ledger="$2" stall="${3:-}" f key wake now base fresh upd
  [ -n "$run_dir" ] || return 0
  for f in "$run_dir"/*.waiting; do
    [ -f "$f" ] || continue
    key=${f##*/}; key=${key%.waiting}
    cc_waiting_is_member "$run_dir" "$ledger" "$key" || continue
    if [ -z "${now:-}" ]; then
      now=$(date -u +%s)
      wake=$(wake_epoch)
      [ -n "$stall" ] || stall=$(cc_effective_stall "$run_dir" || true)
    fi
    upd=$(cc_waiting_field "$f" '갱신' | tr -d '[:space:]')
    base=$(cc_waiting_age_base "$upd" "$wake")
    fresh=false
    if [ -n "$stall" ] && [ "$base" -gt 0 ] && [ $((now - base)) -lt "$stall" ]; then fresh=true; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$(cc_waiting_field "$f" '계보')" \
      "$(cc_waiting_field "$f" '그룹')" "$(cc_waiting_field "$f" '까지')" "$upd" \
      "$(cc_waiting_field "$f" '보유자' | tr -d '[:space:]')" "$(cc_waiting_field "$f" '기록자')" "$fresh"
  done
  return 0
}

cc_waiting_fresh_count() {
  # cc_waiting_fresh_count <run-dir> <ledger> [stall] — how many waiting stages
  # are fresh. The readers that count a live stage count these beside it.
  local n
  n=$(cc_waiting_records "$@" | awk -F'\t' '$8 == "true"' | grep -c . || true)
  printf '%s' "${n:-0}"
}

cc_open_approvals() {
  # cc_open_approvals <ledger> — count of approvals still waiting.
  # Last row per id wins: the ledger is append-only, so a resolution is a later
  # row rather than an edit of the earlier one.
  #
  # The id is matched as a whole field, `| 승인 id=<id> |`. A later row that
  # quotes a waiting id in its question text belongs to another approval, and
  # read as a substring it became the waiting id's last row and hid it.
  local ledger="$1" id st n=0
  [ -n "$ledger" ] || { printf '0'; return 0; }
  for id in $( { grep -E '^- `승인`' "$ledger" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$ledger" 2>/dev/null | grep -F "| 승인 id=$id |" || true; } | tail -1 \
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

cc__blocked_fold() {
  # cc__blocked_fold <ledger> — one line per unresolved block that holds the
  # whole run, as `<사유><TAB><원인><TAB><스코프><TAB><앵커 세그먼트>`, sorted
  # by 사유. `cc_unresolved_blocked` and `cc_unresolved_blocked_where` below are
  # its only readers.
  #
  # THE RULE IS "LAST ROW PER 사유", NOT "ANY ROW". Counting raw rows made the
  # gate's termination condition a one-way latch: a ledger row is never deleted,
  # so a single run-scope block — including one a watcher raised on a false
  # positive — took the run's ability to propose done away permanently.
  #
  # The caller counts (`| wc -l`) and the caller decides what each 원인 means;
  # this function only applies the fold. That is what lets the gate's condition
  # 5 and the status line read the same rule instead of two copies of it.
  local ledger="$1"
  [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  # EVERY grep in this pipeline needs its own guard, not just the first. A middle
  # `grep` that matches nothing exits 1, `pipefail` promotes that to the whole
  # pipeline, and the caller runs this as a BARE statement under `set -e` — so a
  # ledger with no run-scope block at all, which is the ordinary case, killed the
  # gate's verb with status 1 and NO message. Every other refusal in this file
  # carries a sentence naming the repair; this path was the one that said nothing,
  # and a silent failure is the only kind a router cannot recover from.
  #
  # `LC_ALL=C` on the sort, because `사유` is Korean free text by contract and
  # this sort is a SET operation — it decides how many distinct run-scope blocks
  # the ledger holds, which is what the termination conditions and the status
  # line both read. Under `en_US.UTF-8` the collation gives every Hangul
  # syllable the same weight, so two reasons with the same non-Hangul shape and
  # the same syllable counts compare equal and one is dropped. Measured on this
  # host: `강제 표면 이동` and `자동 채택 미달` are one line under that locale and
  # two under C — and both of those are values this field is written with, so
  # the fold is reachable without anybody adding a word. Losing either is bad;
  # losing the first is worst, because it is
  # the block the gate raises when a file its boundary rests on was edited — and
  # a resolved block surviving in its place makes the run eligible to propose an
  # ending with the strongest block still open, reporting nothing.
  #
  # THE TARGET SET IS RUN-SCOPE ROWS AND STEP-ANCHORED CONE ROWS. A deadline
  # park on a design step has no segment to anchor to, so its cone row names the
  # step id in `앵커 세그먼트` — and a step stands in front of every segment, so
  # that row holds the whole run exactly as a run-scope row would. The anchor is
  # read from that field alone, never from `대상`: the driver's own cone rows
  # carry no such field (the `원인=무효화` row and the `대상=<결함>` row among
  # them), and reading "not a segment id" off `대상` would turn each of them into
  # a run stop that condition 5 then reports as unresolvable. A segment anchor
  # always has its `segment` row before its first dispatch, so "the field is set
  # and names no segment" is decidable from the ledger alone.
  #
  # The fold — last row per `사유` — runs inside that set, so an act-scope row
  # that reuses a run block's `사유` neither hides it nor stands in for it.
  #
  # A STEP CONE IS ALSO RELEASED BY A LATER ATTEMPT OF THE SAME KEY. Its `근거`
  # carries `계보=B:<키>#<N>`; when the resume command re-dispatches that key,
  # the new attempt's `stage-wait` or `stage-lease` row carries `계보=B:<키>#<M>`
  # with M > N, and that row is the evidence the park was acted on. A row whose
  # lineage is not of that shape — every driver lineage — is released by
  # `원인=해소` alone.
  LC_ALL=C awk '
    function fld(line, name,   n, i, a, s, v) {
      n = split(line, a, /\|/); v = ""
      for (i = 2; i <= n; i++) {
        s = a[i]; sub(/^[ \t]+/, "", s)
        if (index(s, name "=") == 1) { v = substr(s, length(name) + 2); sub(/[ \t]+$/, "", v) }
      }
      return v
    }
    function lineages(line,   s, out, p) {
      s = line; out = ""; p = length("계보=B:")
      while (match(s, /계보=B:[^ |#]+#[0-9]+/)) {
        out = out " " substr(s, RSTART + p, RLENGTH - p)
        s = substr(s, RSTART + RLENGTH)
      }
      return out
    }
    { lin[NR] = lineages($0) }
    /^- `segment`/ { id = fld($0, "id"); if (id != "") seg[id] = 1; next }
    /^- `blocked`/ {
      nb++; bnr[nb] = NR; bscope[nb] = fld($0, "스코프"); bwhy[nb] = fld($0, "사유")
      banchor[nb] = fld($0, "앵커 세그먼트"); bcause[nb] = fld($0, "원인")
    }
    END {
      # Segment ids are known only once the whole ledger is read, so the set is
      # filtered here rather than row by row.
      for (b = 1; b <= nb; b++) {
        why = bwhy[b]
        if (why == "") continue
        if (bscope[b] == "run") step = 0
        else if (bscope[b] == "cone" && banchor[b] != "" && !(banchor[b] in seg)) step = 1
        else continue
        last[why] = bnr[b]; lastcause[why] = bcause[b]; laststep[why] = step
        lastscope[why] = bscope[b]; lastanchor[why] = banchor[b]
      }
      for (why in last) {
        if (lastcause[why] == "해소") continue
        if (laststep[why] && split(lin[last[why]], own, " ") > 0) {
          k = own[1]; sub(/#[0-9]+$/, "", k); nn = own[1]; sub(/^.*#/, "", nn)
          released = 0
          for (j = last[why] + 1; j <= NR && !released; j++) {
            m = split(lin[j], later, " ")
            for (x = 1; x <= m; x++) {
              lk = later[x]; sub(/#[0-9]+$/, "", lk); ln = later[x]; sub(/^.*#/, "", ln)
              if (lk == k && ln + 0 > nn + 0) { released = 1; break }
            }
          }
          if (released) continue
        }
        printf "%s\t%s\t%s\t%s\n", why, lastcause[why], lastscope[why], lastanchor[why]
      }
    }
  ' "$ledger" | LC_ALL=C sort
}

cc_unresolved_blocked() {
  # cc_unresolved_blocked <ledger> — one line per unresolved block that holds
  # the whole run — a run-scope row, or a cone row anchored on a design step —
  # as `<원인><TAB><사유>`. The fold is `cc__blocked_fold`'s.
  cc__blocked_fold "$1" | LC_ALL=C awk -F '\t' '{ printf "%s\t%s\n", $2, $1 }'
}

cc_unresolved_blocked_where() {
  # cc_unresolved_blocked_where <ledger> — the same set as
  # `cc_unresolved_blocked`, as `<사유><TAB><스코프><TAB><앵커 세그먼트>` of the
  # row the fold kept. The snapshot projects these two fields; reading them off
  # the row the fold chose — not off "the last row of that 사유" — is what keeps
  # a later act-scope row with the same 사유 from relabelling a run block.
  cc__blocked_fold "$1" | LC_ALL=C awk -F '\t' '{ printf "%s\t%s\t%s\n", $1, $3, $4 }'
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
  # cc_ledger_growth_at <run-dir> [ledger] — epoch seconds when the ledger last
  # grew, or empty when nothing about this run has been recorded at all.
  #
  # THE HEARTBEAT FIELD IS THE RULE NOW, AND ITS ABSENCE IS THE EXCEPTION.
  # Measured 2026-09-07: 113 of 167 heartbeats on this host carry `마지막성장`.
  # The watcher publishes it, so a run with a live or recent watcher has it.
  #
  # THE LEDGER MTIME IS THE FALLBACK, AND IT IS OPTIONAL BY POSITION so that a
  # one-argument call — every caller before this second parameter existed —
  # keeps its old meaning. Reaching for it is not the same claim: the heartbeat
  # says "the watcher saw the ledger grow at T", the mtime says "the file was
  # last written at T". Both are facts about the RUN rather than about the
  # watcher, which is what lets a single value stand behind both.
  #
  # EMPTY IS STILL A VERDICT. When neither exists, nothing has been recorded
  # about this run — and `cc_run_state` reads that as 버려짐 rather than as
  # 진행중, because "no clock to judge by" is not evidence of progress.
  local run_dir="$1" ledger="${2:-}" hb v
  [ -n "$run_dir" ] || return 0
  hb="$run_dir/watch.heartbeat"
  if [ -f "$hb" ]; then
    v=$(sed -n 's/.*마지막성장=\([0-9][0-9]*\).*/\1/p' "$hb" 2>/dev/null | tail -1 || true)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  [ -n "$ledger" ] || return 0
  cc_mtime "$ledger"
}

cc_run_grade() {
  # cc_run_grade <token> — the selection rank of a state token, 1 (best) to 9.
  #
  # PURE, AND THAT IS THE WHOLE POINT. A version of this that took a run
  # directory and re-derived the state would walk the predicates a second time
  # on every render; measured 2026-09-07 that second pass costs 60–120ms per run
  # and a twelve-run session already spends 1.5s on one render. So the caller
  # grades the token it already has, and this function does no I/O.
  #
  # SIX RANKS, NOT TWO CLASSES. The old comparison ranked on "no sign of having
  # finished", which let a run that never opened a segment — permanently
  # non-terminal by construction — hold a session forever. Ranking on evidence
  # instead: a live stage beats a waiting approval, which beats a ledger that
  # moved inside `stall`, which beats a ledger that passed `stall` but not
  # `abandon`, which beats a finished run, which beats one that has gone quiet
  # past `abandon`.
  #
  # 정지경고 OUTRANKS 종단, and that is the rank this table exists to get right.
  # A run between two stages is still a run, and the gap between one stage ending
  # and the next being dispatched routinely passes `stall` — so while 정지경고 sat
  # below 종단, every one of those gaps handed the line to a run that finished
  # yesterday. Quiet is not finished. The still-going run keeps the screen and the
  # glyph is what says it has gone quiet.
  #
  # 버려짐 STAYS BELOW 종단, so `abandon` now separates the ORDER as well as the
  # glyph and the wording. Crossing that mark is exactly what drops a quiet run
  # beneath every finished one, which is the difference between "nobody has
  # written for three minutes" and "nobody has written for an hour".
  #
  # THE DEFAULT ARM IS THE WORST RANK ON PURPOSE — an unknown token must not
  # take the screen. It is also SILENT, so a token added to `cc_run_state`
  # without an arm here would quietly sink instead of failing; that is what
  # `scripts/lint-statusline-token-arms.sh` exists to catch on the render side,
  # and this function has to grow with the vocabulary in the same edit.
  #
  # TODAY THIS GRADE HAS EXACTLY ONE CONSUMER, `statusline.sh`. That is why
  # `scripts/test-liveness-agreement.sh` gained no case for it — an agreement
  # suite with one participant tests a function against itself. When a second
  # consumer appears, this function and this file are what it must be compared
  # against.
  case "$1" in
    도는중)   printf '1' ;;
    승인대기) printf '2' ;;
    진행중)   printf '3' ;;
    정지경고) printf '4' ;;
    종단)     printf '5' ;;
    버려짐)   printf '6' ;;
    *)        printf '9' ;;
  esac
}

cc_run_state() {
  # cc_run_state <run-dir> <ledger> [stall-seconds] [abandon-seconds] — one token.
  #
  # Tokens: 도는중 · 승인대기 · 종단 · 정지경고 · 진행중 · 버려짐
  #
  # TERMINAL IS JUDGED BEFORE THE STALL WARNING. A run that has finished has no
  # live stage and a ledger that stopped growing, which is also exactly the
  # shape of a stalled one; ordering the tests the other way labels every clean
  # finish a stall.
  #
  # THAT IS A TEST ORDER AND NOT A RANK. `cc_run_grade` puts 정지경고 ABOVE 종단,
  # which is the opposite direction, and the two do not conflict: this block
  # decides which token a run gets, the grade decides which of two runs holds the
  # line. Reading one as the other is what the two headings are spelled out to
  # prevent.
  #
  # AND 버려짐 IS JUDGED AFTER BOTH, for a sharper reason than tidiness. The
  # watcher decides whether to announce a finished run by comparing this token
  # against `종단` — the one place in that file that puts a desktop banner in
  # front of a person. An idle arm placed before the terminal block would turn
  # finished runs into 버려짐 and silence that announcement. So the two arms that
  # can return 버려짐 both sit BELOW the terminal block and the 승인대기 test,
  # and the token is only ever carved out of 진행중 and 정지경고. That is what
  # keeps the `종단` set byte-identical without opening `watch.sh` to check.
  #
  # `abandon` is declared here, once, and every consumer passes it explicitly or
  # inherits this default. Two consumers reading one run with two thresholds
  # would grade it differently and nobody would see the disagreement.
  #
  # `done` is a shortcut, not the definition. Measured 2026-09-07: 99 of 202 run
  # directories had the file, because many runs never reach the propose-done
  # path — so a predicate that only read `done` would answer "진행 중" forever
  # for runs that had plainly ended.
  local run_dir="$1" ledger="$2" stall="${3:-180}" abandon="${4:-3600}"
  local live pend nonterm n_seg blocked_n grew now idle

  # A FRESH WAITER IS FOLDED INTO THE LIVE COUNT, never given a token of its
  # own: every token this function can return needs an arm in the status line,
  # and a stage waiting for an account is, to a reader of the run, a run that
  # is still going. Its freshness is judged on the watcher's effective
  # threshold, not on `stall` above, because the waiter paces its refresh on
  # that one.
  live=$(cc_live_stages "$run_dir")
  live=$(( ${live:-0} + $(cc_waiting_fresh_count "$run_dir" "$ledger") ))
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

  grew=$(cc_ledger_growth_at "$run_dir" "$ledger")
  # NO CLOCK AT ALL IS THE STRONGEST IDLE SIGNAL, not the weakest. Neither the
  # watcher's field nor a ledger file means nothing has ever been recorded about
  # this run, and the honest reading of that is 버려짐 rather than 진행중.
  [ -n "$grew" ] || { printf '버려짐'; return 0; }
  now=$(date -u +%s)
  idle=$((now - grew))
  # Clamped, because a ledger mtime in the future is not hypothetical — one run
  # on this host measured 28 seconds ahead. A negative idle would otherwise read
  # as the freshest run on the screen.
  [ "$idle" -lt 0 ] && idle=0
  [ "$idle" -ge "$abandon" ] 2>/dev/null && { printf '버려짐'; return 0; }
  [ "$idle" -ge "$stall" ] 2>/dev/null && { printf '정지경고'; return 0; }

  printf '진행중'
}
