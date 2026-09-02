#!/usr/bin/env bash
#
# watch.sh — the liveness detector, and why it is not an auto-resumer.
#
# The most likely way this redesign fails is that the ROUTER quietly stops
# taking turns. Nothing else in the system notices: the ledger simply stops
# growing, no stage crashes, no rule refuses, and a terminal that was going to
# be silent anyway stays silent. An automatic watchdog was rejected — a process
# that restarts the router on a timer is a second decision-maker, and two of
# those disagree in the dark. What replaces it has to make the failure VISIBLE
# without making it anybody's decision.
#
# So this script writes a `blocked` row and prints one loud line. It resumes
# nothing, retries nothing, and decides nothing.
#
# TWO CONDITIONS, and the second is not a special case of the first.
#
#   Stalled  — the ledger has not grown for T, no stage is alive, and no
#              approval is open. Nothing is happening and nothing is waiting.
#   Finished-for-now — EVERY segment is either pending an approval or terminal,
#              and nothing is alive. The run is not stuck; it is **done until a
#              person touches it**, and saying so is better than a quiet
#              terminal.
#
# POSITIVE HEARTBEAT. A watcher that only speaks on failure cannot be
# distinguished from a watcher that died, so silence would carry no
# information. This one says it is alive on a fixed period, and that is what
# makes its silence diagnostic.
#
# The liveness detector does NOT substitute for the heartbeat, and the reason is
# specific: the detector reads the ledger's mtime, so while a stage keeps
# writing it stays quiet — including when the watcher itself is dead.
#
# PID REUSE. `RUN_DIR` deliberately survives a reboot, so a recorded pid can
# name an unrelated live process afterwards. `kill -0` alone would then report a
# stage that does not exist, which breaks liveness in three different directions
# at once (a wrong kill, a detector that never fires, a termination check that
# never completes). The start-time fingerprint is compared alongside the pid,
# and `LC_TIME=C` is pinned so that comparison is not a locale artifact.
#
# Usage:
#   watch.sh --run-dir <dir> --ledger <path> [--interval <sec>] [--stall <sec>]
#                                            [--after-stage <sec>] [--run-open <sec>]
#   watch.sh --run-dir <dir> --ledger <path> --once      # one pass, no loop
#   watch.sh … --notify                                  # also raise a banner
#
# `--notify` exists because THIS PROCESS IS THE ONLY ONE THAT CAN CARRY THE
# NEWS. The condition it reports is "the router stopped", and a router that has
# stopped cannot report it — the loud line above goes to a terminal that may no
# longer exist. The driver left this seat empty for a stated reason: the shared
# operating rules forbid a SPAWNED AGENT from deciding whether a banner reaches
# the user, and a notification-only stage would be one. A shell script is not an
# agent, and this one outlives the session by design (it is orphaned to init).
# So it is the one mechanism that satisfies both constraints at once.
#
# Exit codes:
#   0  a pass completed (or the loop was terminated)
#   2  invalid invocation
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile, no `wait -n`.

set -uo pipefail
# Script-scope `LC_TIME` stays. What the shared predicates require is that THEY
# do not depend on a caller's locale, and they fix it inside themselves; this
# line serves the other time handling in this file and removing it is not
# something the decision asks for.
LC_TIME=C
export LC_TIME

# Sourced ONCE at startup, deliberately not inside the loop: a plugin edit
# landing mid-run must not change the predicate a watcher is already using.
WATCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=/dev/null
. "$WATCH_DIR/liveness.sh"

# `RUN_OPEN` is the run-age arm's threshold, and it sits between the other two on
# purpose: the window it names is bounded below by how long a healthy router
# takes to open its first segment — the contract says the first `segment` row is
# at least two model turns after the run opens — and above by `STALL`, which is
# what used to be the only thing covering it.
RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1200; ONCE=0; NOTIFY=0; AFTER_STAGE=120; RUN_OPEN=300
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --after-stage) AFTER_STAGE="$2"; shift 2 ;;
    --run-open) RUN_OPEN="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    --notify)   NOTIFY=1; shift ;;
    *) printf 'watch: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ] || { printf 'watch: --run-dir 는 필수입니다\n' >&2; exit 2; }
[ -n "$LEDGER" ]  || { printf 'watch: --ledger 는 필수입니다\n' >&2; exit 2; }

# The run id is the run directory's own name — the driver names it that way and
# nothing else has to be read to get it. The banner group below is keyed on it.
RUN_ID=$(basename "$RUN_DIR")

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Delegated for the same reason the three predicates below are: the status line
# has to measure the SAME quantity this watcher does, and two spellings of
# "how big is the ledger" is how they stop agreeing. The `:-0` keeps this
# function's own contract — callers here do arithmetic on the result, and the
# shared function answers empty for a file that is not there.
ledger_size() { local n; n=$(cc_ledger_size "$1"); printf '%s' "${n:-0}"; }

ledger_idle_seconds() {
  # SIZE, not mtime. `stat` takes a different flag on each platform, and the
  # portable alternative is better here anyway: the ledger is append-only, so
  # its size strictly increases when it grows — while an mtime can move without
  # a byte changing, and a restored file can carry an old one.
  #
  # The watcher owns the clock rather than the filesystem: it remembers the last
  # size it saw and when it first saw it, which also makes `--once` work across
  # invocations instead of always reporting zero.
  # THE LEDGER PATH IS PART OF THE STATE, on line 3, because the state file's
  # own path is derived from `--run-dir` alone. Without it a watcher restarted
  # against a DIFFERENT ledger inherits the previous one's accumulated idleness
  # and can fire a stall on its first pass — measured: the first watcher was
  # pointed at a stub that never grew, and the replacement, started with the
  # real ledger, armed immediately even though that ledger had been written 27
  # seconds earlier. The observation it produced becomes an irreversible
  # run-scope row, so the cost of getting this wrong is not a stray warning.
  #
  # Line 3 rather than line 1 so a state file written before this field existed
  # reads as an empty path, mismatches, and resets. A reset reports zero idle
  # seconds, which is the safe direction: it can delay a true stall by one
  # interval, never invent one.
  local size prev_size prev_at prev_ledger now
  size=$(ledger_size "$LEDGER")
  now=$(now_epoch)
  prev_size=$(sed -n '1p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  prev_at=$(sed -n '2p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  prev_ledger=$(sed -n '3p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  if [ -z "$prev_size" ] || [ "$size" != "$prev_size" ] || [ "$prev_ledger" != "$LEDGER" ]; then
    printf '%s\n%s\n%s\n' "$size" "$now" "$LEDGER" > "$RUN_DIR/watch.state"
    printf '0'
    return 0
  fi
  printf '%s' $(( now - prev_at ))
}

# These three were the reference implementations; the predicate moved to
# `liveness.sh` and they became its callers. The behaviour is unchanged — what
# changed is that the gate's render and its termination conditions now compute
# the same numbers this watcher does, instead of three implementations that
# agreed until they did not.

live_stages() { cc_live_stages "$RUN_DIR"; }

open_approvals() { cc_open_approvals "$LEDGER"; }

open_approval_ids() {
  # The SET of open approval ids, one per line — not their count.
  #
  # It is here rather than beside the shared predicates because the shared one
  # is a count-only contract and the set of functions the architecture gathers
  # into that file does not include an enumerator. So this is not a second copy
  # of a shared predicate; it is a different question about the same rows, and
  # it applies that predicate's fold verbatim — the ledger is append-only, so a
  # resolution is a later row and the LAST row per id is the one that counts.
  local id st
  [ -n "$LEDGER" ] || return 0
  for id in $( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null | grep -F "승인 id=$id " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    if [ "$st" = "대기" ]; then printf '%s\n' "$id"; fi
  done
}

nonterminal_segments() { cc_nonterminal_segments "$LEDGER"; }

iso_to_epoch() {
  # `YYYY-MM-DDTHH:MM:SSZ` → epoch seconds, or empty when it does not parse.
  #
  # NEITHER `date -d` NOR `date -j -f` MAY BE USED. The first is GNU, the second
  # BSD, and the portability lint denies both — the same wall the gate's deadline
  # check hit, which it got around by comparing digit strings because it only
  # needed an ordering. This caller needs a DIFFERENCE against a threshold in
  # seconds, and no digit-string compare yields one, so the conversion is done in
  # the shell.
  #
  # The arithmetic is the standard civil-to-days one. Every intermediate stays
  # non-negative for years at or after 1970, which is what lets `$(( ))`'s
  # truncating division stand in for floor. `10#` on every field because `08` and
  # `09` are invalid octal and would abort the expansion.
  local s="$1" digits y m d hh mm ss era yoe doy doe days
  digits=$(printf '%s' "$s" | tr -cd '0-9')
  [ ${#digits} -ge 14 ] || return 0
  y=$((10#$(printf '%s' "$digits" | cut -c1-4)))
  m=$((10#$(printf '%s' "$digits" | cut -c5-6)))
  d=$((10#$(printf '%s' "$digits" | cut -c7-8)))
  hh=$((10#$(printf '%s' "$digits" | cut -c9-10)))
  mm=$((10#$(printf '%s' "$digits" | cut -c11-12)))
  ss=$((10#$(printf '%s' "$digits" | cut -c13-14)))
  [ "$y" -ge 1970 ] || return 0
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 0
  [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 0
  # March-based year: January and February belong to the preceding one, which is
  # what removes the leap day from the middle of the count.
  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then
    doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  printf '%s' $(( days * 86400 + hh * 3600 + mm * 60 + ss ))
}

run_open_seconds() {
  # Seconds since the gate opened this run, read from the `run` row's own
  # `시작=` stamp — or empty when there is no such row or its stamp does not
  # parse.
  #
  # THE ROW'S STAMP, NOT A CLOCK THIS PROCESS KEEPS. A watcher restarted
  # mid-run remembers nothing, and an elapsed count that restarted with it would
  # push the arm below out by the whole restart — which is the window that arm
  # exists to shorten.
  #
  # Empty means "cannot judge", and the caller treats it as such rather than as
  # zero. That direction can only delay a report; the other one invents them.
  local at ep
  [ -n "$LEDGER" ] || return 0
  at=$( { grep -E '^- `run`' "$LEDGER" 2>/dev/null || true; } | tail -1 \
        | tr '|' '\n' | sed -n 's/^ *시작=//p' | sed 's/[[:space:]]*$//' | tail -1)
  [ -n "$at" ] || return 0
  ep=$(iso_to_epoch "$at")
  [ -n "$ep" ] || return 0
  printf '%s' $(( $(now_epoch) - ep ))
}

banner() {
  # Best-effort, and every failure is swallowed on purpose: a watcher that dies
  # because a notifier is missing removes the only signal the user had left.
  [ "$NOTIFY" = "1" ] || return 0
  [ "$(uname -s)" = "Darwin" ] || return 0
  # The prepend is skippable, because it is what makes the banner path
  # UNTESTABLE otherwise: a stub placed first on PATH is shadowed by the real
  # binary in `/opt/homebrew/bin`, so no assertion about what this function
  # passes can stand. The two other notifier call sites already honour this
  # variable; they spell the test with `[[ ]]` and this file is POSIX `[ ]`
  # throughout, so the convention followed here is the file's.
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  fi
  command -v terminal-notifier >/dev/null 2>&1 || return 0
  # THE GROUP IS PER RUN. `terminal-notifier` treats a group as a slot and
  # replaces whatever is in it, so a constant made two concurrent runs erase
  # each other's banners — the second run's notice silently took the first
  # one's place and the first run's condition was never seen.
  { terminal-notifier -title "[cc-cmds] 자율 런" -message "$1" \
      -group "cc-cmds-autopilot-${RUN_ID}" -execute ':' 2>/dev/null || true; }
  return 0
}

announce() {
  # Loud, on the terminal, once per condition. The whole point of this script is
  # that a person looking at the terminal in the morning learns something a
  # quiet prompt would not have told them.
  printf '\n================================================================\n'
  printf '  %s\n' "$1"
  printf '  %s\n' "$2"
  printf '================================================================\n\n'
}

record_blocked() {
  # THE LEDGER HAS ONE WRITER AND IT IS NOT THIS PROCESS. The row this used to
  # append carried no `prev=`, took no lock, and passed no row-length check —
  # and the two sides of the chain then disagreed about it: the verifier skips a
  # row with no `prev=` without advancing its running value, while the writer's
  # tip hashes the ledger's last ROW including that one. So a run whose watcher
  # fired once read as "chain broken" from the next row onward, forever. That is
  # the same permanent-break value #219 already measured: a real splice and a
  # normal run look identical.
  #
  # So the observation is written HERE, as a file, and the gate transcribes it
  # into a properly chained row on its next invocation. If the router never
  # calls the gate again — which is the very condition this detector reports —
  # the file is still on disk for the render and for the morning.
  printf '%s\t%s\t%s\n' "$(now_iso)" "$1" "$2" >> "$RUN_DIR/stall"
}

pass() {
  # NO ARM RETURNS BEFORE THE HEARTBEAT. Every arm below used to `return 0` on
  # firing, so a run in a condition that keeps re-arming stopped rewriting
  # `watch.heartbeat` entirely — and a stale heartbeat is exactly how a dead
  # watcher looks. Each arm carries its own once-marker, so two firing in one
  # pass is harmless and reaching the bottom every time is the point.
  local age live pend nonterm run_age size grew silent id newly
  # The watcher's own pid, so a person (and the status line) can tell a live
  # watcher from a finished run's. The directory is NOT created here: the
  # watcher legitimately runs in the window before the router's first gate call
  # makes it, and `run_is_over()` already owns that window. `cc_live_stages`
  # does not count this file — it has no `.start`/`.pgid` sibling.
  [ -d "$RUN_DIR" ] && printf '%s' "$$" > "$RUN_DIR/watch.pid"
  age=$(ledger_idle_seconds)
  live=$(live_stages)
  pend=$(open_approvals)
  nonterm=$(nonterminal_segments)

  # THE RUN ENDED. Waiting for the `done` file would mean saying so almost
  # never: measured across 39 run directories, 2 had one, because almost no run
  # reaches the propose-done path. The shared state predicate derives the same
  # conclusion from the ledger, and using it here is what keeps this line and
  # the status line from disagreeing about whether a run is over.
  if [ "$(cc_run_state "$RUN_DIR" "$LEDGER" "$STALL")" = "종단" ] \
     && [ ! -f "$RUN_DIR/watch.announced-terminal" ]; then
    : > "$RUN_DIR/watch.announced-terminal"
    announce "런이 종단했습니다 — 더 진행할 것이 없습니다" \
             "아침 보고서를 확인하세요 — 이 스크립트는 아무것도 재개하지 않습니다"
    banner "런이 종단했습니다 — 아침 보고서를 확인하세요"
  fi

  # A STAGE ENDED AND THE ROUTER DID NOT ACT. This is a far sharper condition
  # than generic idleness, and it is the symptom of the one failure the dispatch
  # form causes: a stage launched without a wake path finishes, writes its rows,
  # and nobody is told.
  #
  # It is here because the form ITSELF cannot be checked. Measured: the
  # environment a harness-tracked background command sees and the environment a
  # foreground one sees are byte-identical — zero differing lines — so the gate
  # has nothing to test at dispatch time. The requirement can only be stated in
  # prose, and prose was violated again within four hours of being written.
  #
  # The generic stall arm below cannot cover it either: its threshold is twenty
  # minutes and it only starts counting once the stage is gone, so the run sits
  # silent for that long after an already-long stage. This arm keys on the last
  # ledger ROW being a stage's terminal row, which is true for exactly as long
  # as the router has not acted since — so a properly woken router clears it in
  # seconds and a stranded one is named in two minutes.
  #
  # THE LEDGER GUARD IS PART OF THE CONDITION, not a refinement of it. A run that
  # finished normally ends with a `stage-result` row as its last row and no live
  # stage — the exact shape this arm keys on — so without it every clean finish
  # was told the router had stranded it, and the `blocked` row that produced
  # then blocked the run's own termination condition.
  #
  # THE NON-TERMINAL SEGMENT COUNT IS THE WHOLE TEST HERE, and a disjunct on "no
  # segment row yet" was attached to it and has been taken back out. The
  # last-row guard above already excludes the window that disjunct was for. That
  # window is the one between the run opening and its first segment: the
  # kickoff's report stub carries ZERO ledger rows, the gate appends the `run`
  # row on its first call, and the first `segment` row appears only when the
  # router calls `act --kind segment`, at least two model turns later. A
  # `stage-result` or `cost` row is written only after a STAGE has run, and a
  # stage runs inside a segment — so in that window the last-row guard cannot be
  # satisfied by anything, and the disjunct could not change this arm's verdict
  # on any ledger the gate writes. It read as though taking it out would bring a
  # bug back, and it was unreachable.
  #
  # THAT WINDOW IS COVERED BELOW, NOT HERE. The stall arm keeps the same
  # disjunct and does reach it, at `STALL`; the run-age arm between them names
  # it earlier and on its own key. This arm keys on a stage having ENDED, and in
  # that window no stage ever started.
  #
  # The once-guard is a DEDICATED MARKER rather than a grep of `stall`, because
  # the gate empties `stall` on every act: the guard came back to life, the arm
  # re-fired every pass, and — when it still returned early — the heartbeat
  # stopped for good. `record_blocked` still writes `stall`; that file is the
  # observation, not the guard.
  if [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$AFTER_STAGE" ] \
     && [ "$nonterm" -ge 1 ] \
     && [ -z "$(cat "$RUN_DIR/done" 2>/dev/null || true)" ] \
     && [ "$( { grep -E '^- `' "$LEDGER" 2>/dev/null || true; } | tail -1 \
             | grep -cE '^- `(stage-result|cost)`' || true)" != "0" ] \
     && [ ! -f "$RUN_DIR/watch.announced-after-stage" ]; then
    : > "$RUN_DIR/watch.announced-after-stage"
    announce "스테이지가 끝났는데 라우터가 ${age}초 동안 아무것도 하지 않았습니다" \
             "그 스테이지를 깨울 통지가 없는 형태로 띄웠을 수 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    banner "스테이지가 끝났는데 런이 이어지지 않습니다 (${age}초)"
    record_blocked "스테이지 종단 후 라우터 무응답" "메인 세션에서 이어서 진행하도록 지시"
  fi

  # THE RUN OPENED AND NO SEGMENT EVER DID. Its own arm, keyed on the age of the
  # `run` row, because that window has no other clock: with no segment row there
  # is no stage to be alive, no approval to be open, and no terminal stage row
  # for the arm above to key on. Grafting the case onto that arm is what produced
  # a disjunct its own last-row guard made unreachable, and the window was then
  # left to the stall arm's twenty minutes.
  #
  # THE IDLE CONJUNCT IS PART OF THE CONDITION, not a refinement. The router
  # writes `자율 승인` rows before it opens the first segment, so "no segment
  # yet" on its own accuses a router that is working. Adding "and the ledger has
  # not grown for `AFTER_STAGE`" asks the sharper question: nothing running,
  # nothing waiting, nothing written, and still no segment.
  #
  # IT DOES NOT DISPLACE THE STALL ARM. That arm keeps the zero-segment window
  # under its own reason, so a run parked here records two observations — this
  # one at `RUN_OPEN` and the general one at `STALL`. Both are true and each
  # names a different thing; suppressing the second would be this arm deciding
  # what the more general detector may say.
  #
  # A NORMALLY TERMINATED RUN CANNOT REACH IT: a clean finish has at least one
  # segment row, so the segment count alone excludes it, and the `done` guard
  # excludes it a second time.
  #
  # The once-guard is a dedicated marker for the same reason the arm above's is:
  # the gate empties `stall` on every act, so a guard that read that file would
  # come back to life and this arm would re-fire every pass.
  run_age=$(run_open_seconds)
  if [ "$live" = "0" ] && [ "$pend" = "0" ] \
     && [ "$(cc_segment_count "$LEDGER")" = "0" ] \
     && [ -n "$run_age" ] && [ "$run_age" -ge "$RUN_OPEN" ] \
     && [ "$age" -ge "$AFTER_STAGE" ] \
     && [ -z "$(cat "$RUN_DIR/done" 2>/dev/null || true)" ] \
     && [ ! -f "$RUN_DIR/watch.announced-run-open" ]; then
    : > "$RUN_DIR/watch.announced-run-open"
    announce "런이 열린 지 ${run_age}초인데 세그먼트가 하나도 열리지 않았습니다" \
             "라우터가 첫 세그먼트를 열기 전에 멈췄을 수 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    banner "런이 열린 뒤 ${run_age}초 동안 세그먼트가 열리지 않았습니다"
    record_blocked "세그먼트 미개시" "메인 세션에서 이어서 진행하도록 지시"
  fi

  # Announce a condition ONCE. Re-announcing on every pass turns the loud line
  # into noise, and the row it writes would itself grow the ledger — which resets
  # the very idleness being measured, so the watcher would alternate between
  # firing and heartbeating forever.
  #
  # The ledger guard asks whether the reason is CURRENTLY UNRESOLVED, not
  # whether a row for it was ever written. A ledger row is never deleted, so the
  # old test was a one-way latch: a run that a person unblocked and that then
  # stopped a second time could never say so again. `cc_unresolved_blocked`
  # applies the same last-row-per-사유 fold the gate's termination condition
  # uses. `grep -c` rather than `grep -q` on the right of that pipe — `-q` exits
  # on first match and kills the writer with SIGPIPE, which `pipefail` then
  # reports as a failed pipeline.
  #
  # The `stall` file grep stays: it is not redundant with the ledger test but the
  # other half of it, suppressing a repeat within the same drain window.
  #
  # THE `nonterm`/`n_seg` DISJUNCT LIVES HERE AND ONLY HERE. This is the arm
  # that can reach the zero-segment window: it carries no last-row guard, so a
  # ledger whose only row is `run` still gets judged, and on a bare `nonterm >= 1`
  # it would fall silent — a run that died before opening its first segment
  # would then be reported by no arm at all. The after-stage arm above states
  # the same test in prose and cannot reach it, which is why the copy there came
  # back out.
  #
  # WHAT COVERING IT HERE COSTS IS TIME: this arm's threshold is `STALL`, twenty
  # minutes. The run-age arm above is what makes the same window audible
  # earlier; it does not replace this one, and the two record different reasons
  # on purpose.
  silent=$(cc_unresolved_blocked "$LEDGER" | grep -cF '라이브니스 침묵' || true)
  if [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$STALL" ] \
     && { [ "$nonterm" -ge 1 ] || [ "$(cc_segment_count "$LEDGER")" = "0" ]; } \
     && ! grep -q '라이브니스 침묵' "$RUN_DIR/stall" 2>/dev/null \
     && [ "${silent:-0}" = "0" ]; then
    announce "런이 ${age}초 동안 아무것도 쓰지 않았습니다 (살아 있는 스테이지 0, 대기 승인 0)" \
             "라우터가 턴을 잡지 않고 있을 수 있습니다 — 이 스크립트는 아무것도 재개하지 않습니다"
    banner "라우터가 ${age}초 동안 멈춰 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    record_blocked "라이브니스 침묵" "메인 세션에서 이어서 진행하도록 지시"
  fi

  # AN APPROVAL REACHES THE USER THE MOMENT IT IS ISSUED, whatever else is
  # running. The condition below wants every segment settled first, which is
  # structurally false at the instant an approval is written — the segment that
  # triggered it is by definition still live. So the one event that exists to
  # summon a person produced no signal on any channel, and the run waited all
  # night for someone who had not been told.
  #
  # KEYED BY THE ID SET, NOT BY THE COUNT. A count marker asks "have I announced
  # *this many* approvals", which is not the question: two approvals opening
  # while one closes leaves the count where it was, and the newly opened one
  # then reaches nobody. The ids are appended to one file, so an id already
  # announced stays quiet even after it is resolved and reopened.
  newly=0
  for id in $(open_approval_ids); do
    grep -qxF "$id" "$RUN_DIR/watch.announced-approvals" 2>/dev/null && continue
    printf '%s\n' "$id" >> "$RUN_DIR/watch.announced-approvals"
    newly=$((newly + 1))
  done
  if [ "$newly" -gt 0 ]; then
    announce "승인 대기 ${pend}건 — 런이 답을 기다립니다" \
             "세션으로 돌아가 답하면 그 자리에서 이어집니다"
    banner "승인 대기 ${pend}건 — 답을 기다립니다"
  fi

  if [ "$live" = "0" ] && [ "$nonterm" = "0" ] && [ "$pend" -gt 0 ] \
     && [ ! -f "$RUN_DIR/watch.announced-waiting" ]; then
    : > "$RUN_DIR/watch.announced-waiting"
    announce "모든 세그먼트가 승인 대기이거나 종단입니다 (대기 승인 ${pend}건)" \
             "런은 막힌 것이 아니라 사람이 손대기 전까지 끝난 것입니다"
    banner "런이 사람을 기다립니다 — 대기 중 승인 ${pend}건"
  fi

  # Positive heartbeat. Says the watcher is alive, which is what makes its
  # silence mean something.
  #
  # Written to a FILE as well as to stdout, and the file is what carries the
  # claim. This process is launched into the background by a tool call that then
  # returns, so its stdout is closed and every heartbeat printed there reaches
  # nobody — the property "a live watcher's silence differs from a dead one's"
  # was stated and then not obtainable. The file's own mtime is what makes the
  # watcher's liveness measurable, and it is rewritten every pass even when
  # nothing changed, which is exactly the case `watch.state` cannot cover: that
  # file only moves when the ledger's size moves.
  #
  # THE LAST TWO FIELDS ARE FOR A READER THAT IS NOT THIS PROCESS. The status
  # line has to judge whether the ledger is stale, and it may not write — so it
  # cannot own an elapsed-since-last-growth clock of its own. This file is where
  # that value is published, and it comes from the clock that already exists:
  # `ledger_idle_seconds` records "when I first saw this size" on line 2 of
  # `watch.state`, and for an append-only ledger that IS the last growth. A
  # second clock would be a second answer to one question.
  #
  # The four existing fields keep their positions and their wording verbatim —
  # they are read from this file by name.
  size=$(ledger_size "$LEDGER")
  grew=$(sed -n '2p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  printf '%s 원장 %s초 전 갱신 · 스테이지 %s개 · 대기 승인 %s건 · 비종단 세그먼트 %s개 · 원장크기=%s · 마지막성장=%s\n' \
    "$(now_iso)" "$age" "$live" "$pend" "$nonterm" "$size" "$grew" > "$RUN_DIR/watch.heartbeat"
  printf '%s [watch] 살아 있음 — 원장 %s초 전 갱신, 스테이지 %s개, 대기 승인 %s건, 비종단 세그먼트 %s개\n' \
    "$(now_iso)" "$age" "$live" "$pend" "$nonterm"
  return 0
}

run_is_over() {
  # The two ways this watcher's job ends. Neither is a judgment it makes — one
  # is a fact the gate records, the other is the run's own directory going away.
  #
  # Without them the loop had no exit at all and nothing else reaped it: the
  # gate ends a run without touching the watcher, and the report renderer is
  # forbidden from starting or writing anything. Measured on one machine: seven
  # watchers from seven different runs, ages from 18 seconds to 1 day 4 hours,
  # with no way to tell a live run's watcher from a finished run's.
  [ -f "$RUN_DIR/done" ] && return 0
  # "NOT YET CREATED" IS NOT "WENT AWAY", and treating them alike made the
  # watcher exit at once, quietly, on the very ordering the kickoff prescribes:
  # it says to start the watcher before entering the router loop, and the run
  # directory is created by the router's FIRST gate call. Measured — watcher up
  # at 03:18:0x, directory created at 03:18:36, and the run then ran with no
  # watcher at all while the launching call had reported success.
  #
  # So absence only ends the loop once the directory has been seen at least
  # once. Until then it is a wait, and the wait is bounded so a watcher pointed
  # at a path that never appears does not linger forever.
  if [ -d "$RUN_DIR" ]; then
    RUN_DIR_SEEN=1
    return 1
  fi
  if [ "${RUN_DIR_SEEN:-0}" = "1" ]; then
    return 0
  fi
  STARTUP_WAIT=$(( ${STARTUP_WAIT:-0} + 1 ))
  if [ "$STARTUP_WAIT" -gt "${STARTUP_MAX:-60}" ]; then
    printf '%s [watch] 런 디렉터리가 끝내 생기지 않았습니다: %s\n' "$(now_iso)" "$RUN_DIR" >&2
    return 0
  fi
  return 1
}

if [ "$ONCE" = "1" ]; then
  pass
  exit 0
fi

while :; do
  if run_is_over; then
    if [ -f "$RUN_DIR/done" ]; then
      announce "런이 종단했습니다 — 감시를 멈춥니다" "$(cat "$RUN_DIR/done" 2>/dev/null || printf '종단 표시 있음')"
    fi
    exit 0
  fi
  pass
  sleep "$INTERVAL"
done
