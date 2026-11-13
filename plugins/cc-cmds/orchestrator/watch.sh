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
#                                            [--silence <sec>]
#   watch.sh --run-dir <dir> --ledger <path> --once      # one pass, no loop
#
# THIS PROCESS IS ONE OF THE TWO SEATS THAT CAN CARRY THE NEWS; the other is the
# adjudication gate. The condition this one reports is "the router stopped", and
# a router that has stopped cannot report it — the loud line above goes to a
# terminal that may no longer exist. The shared operating rules forbid a SPAWNED
# AGENT from deciding whether a banner reaches the user, and neither seat is an
# agent: a shell script is not one, and this script outlives the session by
# design (it is orphaned to init).
#
# THERE IS NO `--notify` FLAG ANY MORE, and dropping it was not tidying. A second
# parsing site meant the run-level kill switch could not reach these banners: a
# person who set the variable went on receiving every notice this file raises
# while believing they had stopped them. The switch is
# `CC_CMDS_AUTOPILOT_NOTIFY`, it is parsed in `notify-run.sh` and nowhere else,
# and it is a start-of-run choice — this loop inherits its environment once and
# never re-reads it.
#
# Exit codes:
#   0  a pass completed (or the loop was terminated)
#   2  invalid invocation
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile, no `wait -n`.

set -uo pipefail
# Script-scope `LC_TIME` stays, but it is NOT what makes the liveness compare
# work. This file never clears `LC_ALL` — it does not source the driver — so an
# `LC_ALL` inherited from whoever launched the watcher overrides this line
# entirely, and for a while that meant a watcher started from a Korean-locale
# shell read every stage as dead while reporting "0 live". The fingerprint is
# pinned at its own capture with `LC_ALL` instead, which nothing outranks. What
# remains here serves this file's other time handling, whose formats are numeric
# and would survive the override anyway.
LC_TIME=C
export LC_TIME

# Sourced ONCE at startup, deliberately not inside the loop: a plugin edit
# landing mid-run must not change the predicate a watcher is already using.
watch_src=${BASH_SOURCE[0]:-$0}
case "$watch_src" in
  */*) watch_src=${watch_src%/*}; [ -n "$watch_src" ] || watch_src=/ ;;
  *) watch_src=. ;;
esac
WATCH_DIR=$(cd "$watch_src" && pwd)
# shellcheck source=/dev/null
. "$WATCH_DIR/liveness.sh"
# The banner emitter, sourced here for the same reason and on the same terms.
# Every notice this file raises takes its title, group and sound from that file,
# which is what stops this process and the gate from spelling one group two ways
# — and a group is a slot, so two spellings mean two runs erasing each other.
# shellcheck source=/dev/null
. "$WATCH_DIR/notify-run.sh"
# The run's version pin. The watcher hops into the pinned copy for the same
# reason the gate does — and the hop needs the original argument vector, which
# the parse loop below consumes.
# shellcheck source=/dev/null
. "$WATCH_DIR/pin.sh"

WATCH_ARGV=("$@")

# `RUN_OPEN` is the run-age arm's threshold, and it sits between the other two on
# purpose: the window it names is bounded below by how long a healthy router
# takes to open its first segment — the contract says the first `segment` row is
# at least two model turns after the run opens — and above by `STALL`, which is
# what used to be the only thing covering it.
#
# There is no `NOTIFY` variable beside them: the banners this file raises are
# governed by the kill switch `notify-run.sh` parses, and a flag here would be a
# second parsing site the switch could not reach.
#
# `STAGE_AGE` is the stage-age arm's threshold and it measures a DIFFERENT
# subject from every other number here: the three above time the ROUTER's
# silence, this one times how long a single stage has been alive. Two hours,
# calibrated on 27 real runs where the longest stage ran 70.6 minutes and the
# false-positive count was 0.
#
# THAT CALIBRATION IS IN TENSION WITH ANOTHER MEASUREMENT IN THE SAME BODY OF
# WORK, and the tension is left visible rather than resolved. Stage duration
# across a wider sample has a 39-minute median with 165 minutes at the 90th
# percentile and 285 at the 95th, and under that distribution 28 of 217 intervals
# (12.9%) exceed two hours. The two can coexist — the wider sample's interval
# lengths come from a proxy that overestimates — but reading "0 false positives
# in 27" alone says this arm will be quiet, and that is a stronger claim than the
# evidence supports.
#
# The tension is acceptable because of what firing COSTS here: this arm notifies
# and writes no block, so a long legitimate stage costs one line in the morning,
# while a genuinely hung stage costs the whole night. That is also why this
# threshold is not judged by the same statistics as the act budget's rejected
# wall-clock cap — that boundary's firing opens an approval only a person can
# close and stops the run, and different consequences do not share a test.
#
# THE CALIBRATION DOES NOT TRANSFER TO ANOTHER CLOCK. It was obtained from log
# file mtimes as a proxy for stage end; the arm below reads the stage's start
# fingerprint instead, so if that reading is ever swapped the threshold has to be
# re-measured rather than carried over.
#
# `SILENCE` IS THE GENERAL AND SETTLE-STALL ARMS' OWN THRESHOLD, and only theirs:
# they fire at `min(STALL, SILENCE)` when the run is quiet on every signal — the
# ledger, the gate's own entry, a relay's hand-back and a live shift's stream —
# and at `STALL` while a seat turn follows a handoff, a halt record waits for a
# person or a fixed-graph run's dispatch marker is alive. Every other reader of
# `STALL` (the waiter refresh and its freshness, `watch.stall`, the run state,
# the feed-silence arm, the `done` tail) keeps reading `STALL`. It is a literal on this line rather than a value derived from
# another, so the pin lint can read it.
RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1200; ONCE=0; AFTER_STAGE=120; RUN_OPEN=300; SILENCE=300
STAGE_AGE=7200
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --after-stage) AFTER_STAGE="$2"; shift 2 ;;
    --run-open) RUN_OPEN="$2"; shift 2 ;;
    --silence)  SILENCE="$2"; shift 2 ;;
    --stage-age) STAGE_AGE="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    *) printf 'watch: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ] || { printf 'watch: --run-dir 는 필수입니다\n' >&2; exit 2; }
[ -n "$LEDGER" ]  || { printf 'watch: --ledger 는 필수입니다\n' >&2; exit 2; }

# THE HOP, AND IT IS AHEAD OF EVERY WRITE. `watch.pid`, `watch.state`,
# `watch.heartbeat` and the single-holder record all land below this line: `exec`
# preserves the pid and the start-time fingerprint but drops EXIT traps, so a
# marker written before the hop would outlive the process that could clean it up
# while still passing its own identity check.
#
# A pin that names a missing copy is a WARNING here and not a stop. The gate
# refuses outright in that state, which is what actually halts the run; a watcher
# that killed itself as well would take the reporting surface down with it at the
# exact moment somebody needs to read why.
watch_hop_t=""; watch_hop_rc=0
watch_hop_t=$(pin_hop_target "$RUN_DIR" "$WATCH_DIR") || watch_hop_rc=$?
case "$watch_hop_rc" in
  0) exec "${BASH:-/bin/bash}" "$watch_hop_t/watch.sh" ${WATCH_ARGV[@]+"${WATCH_ARGV[@]}"} ;;
  2) printf 'watch: plugin-pin 은 있는데 사본이 없습니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
  3) printf 'watch: plugin-pin 이 이 런의 사본이 아닌 곳을 가리킵니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
esac

# The run id is the run directory's own name — the driver names it that way and
# nothing else has to be read to get it. The banner group below is keyed on it.
#
# WHAT DOES NOT CHANGE FOR THE LIFE OF THIS PROCESS IS READ ONCE, HERE: the run
# id, the run root that holds every run's directory (the host-load sample counts
# its siblings), the host's OS name, and this watcher's own start fingerprint.
# The id and the root are taken apart with expansions, the way `basename` and
# `dirname` would, so no cycle forks for them.
#
# The OS name is read twice over. `WATCH_OS` honours the `CC_WATCH_HOST_OS`
# seam, which lets a test on any host drive the Darwin branch whose commands a
# PATH stub can make fail. `WATCH_HOST_UNAME` is the host's own answer and picks
# the `ls` time format, because that flag is the `ls` binary's and a seamed name
# would hand a BSD flag to a GNU `ls`.
watch_rd=$RUN_DIR
while :; do case "$watch_rd" in ?*/) watch_rd=${watch_rd%/} ;; *) break ;; esac; done
case "$watch_rd" in
  */*) WATCH_RUN_ROOT=${watch_rd%/*}; [ -n "$WATCH_RUN_ROOT" ] || WATCH_RUN_ROOT=/ ;;
  *) WATCH_RUN_ROOT=. ;;
esac
RUN_ID=${watch_rd##*/}
WATCH_HOST_UNAME=$(uname -s 2>/dev/null || true)
WATCH_OS=${CC_WATCH_HOST_OS:-$WATCH_HOST_UNAME}
WATCH_FP=""
cc__proc_fingerprint_into WATCH_FP "$$"

# THE MEMORY CLOCK. One `date` here and the shell's own `SECONDS` after it
# (`cc_clock_start`): every reading of the time below comes from it, so a cycle
# forks for none. `SECONDS` counts wall-clock seconds, so a host sleep moves it
# as it moves `date`. `now_epoch` falls back to `date` when the clock was never
# anchored — a test that lifts this function on its own source text has not run
# the line below.
cc_clock_start

now_epoch() {
  if [ -n "${CC_CLOCK_EPOCH0:-}" ]; then
    printf '%s\n' $((CC_CLOCK_EPOCH0 + SECONDS - ${CC_CLOCK_SECONDS0:-0}))
  else
    date +%s
  fi
}

now_iso() {
  local s
  watch_iso_into s
  printf '%s\n' "$s"
}

watch_now_into() {
  # watch_now_into <var> — now, in epoch seconds, from the memory clock.
  cc_clock_now_into "$1"
}

watch_iso_into() {
  # watch_iso_into <var> — now as `YYYY-MM-DDTHH:MM:SSZ`, from the memory clock.
  local __w_now
  cc_clock_now_into __w_now
  cc_epoch_to_iso_into "$1" "$__w_now"
}

# When this watcher started watching. The idle exit counts from no earlier than
# this: a watcher the seat starts again on a run that has been quiet for a day
# reads the day-old `마지막성장` its predecessor left, and without this it would
# leave on its first iteration, before writing a heartbeat of its own.
WATCH_STARTED=$CC_CLOCK_EPOCH0

# Delegated for the same reason the three predicates below are: the status line
# has to measure the SAME quantity this watcher does, and two spellings of
# "how big is the ledger" is how they stop agreeing. The `:-0` keeps this
# function's own contract — callers here do arithmetic on the result, and the
# shared function answers empty for a file that is not there.
ledger_size() { local n; n=$(cc_ledger_size "$1"); printf '%s' "${n:-0}"; }

ledger_idle_read() {
  # ledger_idle_read — sets the caller's `size` (the ledger's size in bytes, 0
  # when it cannot be read), `age` (seconds since that size was first seen) and
  # `grew` (the epoch it was first seen, or empty when `watch.state` could not be
  # written). Set rather than printed, so the full pass reads all three with one
  # `wc` and no subshell of its own; `size` is the value `ledger_size` gives.
  #
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
  local n="" prev_size="" prev_at="" prev_ledger="" now
  if [ -f "$LEDGER" ]; then
    n=$(wc -c < "$LEDGER" 2>/dev/null) || n=""
    n=${n// /}
  fi
  size=${n:-0}
  watch_now_into now
  { IFS= read -r prev_size; IFS= read -r prev_at; IFS= read -r prev_ledger; } 2>/dev/null < "$RUN_DIR/watch.state" || :
  if [ -z "$prev_size" ] || [ "$size" != "$prev_size" ] || [ "$prev_ledger" != "$LEDGER" ]; then
    age=0
    if printf '%s\n%s\n%s\n' "$size" "$now" "$LEDGER" > "$RUN_DIR/watch.state"; then
      grew=$now
    else
      grew=""
    fi
    return 0
  fi
  age=$(( now - prev_at ))
  grew=$prev_at
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
  #
  # The approval table of `liveness.sh` gives the same set in one pass; where
  # that table declines (`cc__table_into` fails) the per-id pipeline below runs.
  local id st cp tbl open="" nl=$'\n'
  [ -n "$LEDGER" ] || return 0
  if declare -F cc__table_into >/dev/null && cc__table_into tbl cc__approval_table "$LEDGER"; then
    while IFS=$'\037' read -r id st cp; do
      [ -n "$id" ] && [ "$st" = "대기" ] || continue
      open="${open:+$open$nl}$id"
    done <<EOF
$tbl
EOF
    [ -n "$open" ] || return 0
    sort -u <<EOF
$open
EOF
    return 0
  fi
  for id in $( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null | grep -F "| 승인 id=$id |" || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    if [ "$st" = "대기" ]; then printf '%s\n' "$id"; fi
  done
}

watch_approval_canon_question() {
  # watch_approval_canon_question <승인 id> — the gate's canonical question for
  # one approval, `승인 <id> — <question>`, or nothing.
  watch_gate_approval_read gate_approval_canon_question "$1"
}

watch_approval_attach_json() {
  # watch_approval_attach_json <승인 id> — the gate's attention attachment for
  # one approval, the JSON line `gate_approval_attach_json` prints, or nothing.
  # The gate's own approval site sends the same attachment, so whichever site
  # leaves the event first, its reply target is the one the router asks with.
  watch_gate_approval_read gate_approval_attach_json "$1"
}

watch_gate_approval_read() {
  # watch_gate_approval_read <gate function> <승인 id> — what one of the gate's
  # approval readers prints for that approval, or nothing.
  #
  # THE GATE IS SOURCED, NOT CALLED. Every gate verb writes the run directory's
  # entry records before it reaches its own branch, so calling even a read verb
  # once a pass would leave the watcher's footprints in the gate's records. The
  # re-kick script reads gate functions the same way: in a child shell, with the
  # gate sourced only and the run's paths put in by hand.
  #
  # The base is the ledger path with its `/docs/pipeline-run/<file>` tail taken
  # off, and the authorization record sits under it the way the run script
  # derives it. A ledger path without that tail has no base, so nothing is
  # asked. A judgment approval's row carries only an excerpt and its full text
  # is in the sidecar, so the gate's own reader, with its proof pair, is what
  # gives the bytes the router asks with. Stdin is closed and stderr dropped.
  local g="$WATCH_DIR/gate.sh" base
  case "$LEDGER" in
    */docs/pipeline-run/*) base=${LEDGER%/docs/pipeline-run/*} ;;
    *) return 0 ;;
  esac
  case "${LEDGER#"$base"/docs/pipeline-run/}" in
    ''|*/*) return 0 ;;
  esac
  [ -n "$base" ] && [ -r "$g" ] || return 0
  case "$1" in
    gate_approval_canon_question|gate_approval_attach_json) ;;
    *) return 0 ;;
  esac
  CC_GATE_SOURCE_ONLY=1 bash -c '
    g=$1; base=$2; rid=$3; rd=$4; led=$5; fn=$6; id=$7
    set --
    . "$g" >/dev/null 2>&1 || exit 0
    set +e
    unset CC_GATE_SOURCE_ONLY CC_ORCH_SOURCE_ONLY
    BASE=$base; RUN_ID=$rid; RUN_DIR=$rd; LEDGER=$led
    GRANT="$base/docs/pipeline-grant/$rid.md"
    "$fn" "$id"
  ' watch-canon "$g" "$base" "$RUN_ID" "$RUN_DIR" "$LEDGER" "$1" "$2" </dev/null 2>/dev/null || true
  return 0
}

nonterminal_segments() { cc_nonterminal_segments "$LEDGER"; }

# `YYYY-MM-DDTHH:MM:SSZ` → epoch seconds, or empty. The conversion moved to
# `liveness.sh` when the relay's CI wake clock needed it there too: one parser
# for the run-open arm and the relay's `관측` clock, so the two cannot read one
# timestamp as two times.
iso_to_epoch() { cc_iso_to_epoch "$1"; }

run_open_into() {
  # run_open_into <var> — sets <var> to the seconds since the gate opened this
  # run, read from the `run` row's own `시작=` stamp — or empty when there is no
  # such row or its stamp does not parse. The last `run` row's last `시작=` field
  # is found by one awk, and the stamp is converted in the shell.
  #
  # THE ROW'S STAMP, NOT A CLOCK THIS PROCESS KEEPS. A watcher restarted
  # mid-run remembers nothing, and an elapsed count that restarted with it would
  # push the arm below out by the whole restart — which is the window that arm
  # exists to shorten.
  #
  # Empty means "cannot judge", and the caller treats it as such rather than as
  # zero. That direction can only delay a report; the other one invents them.
  local at="" ep="" now
  printf -v "$1" '%s' ""
  [ -n "$LEDGER" ] || return 0
  at=$(LC_ALL=C awk '
    index($0, "- `run`") == 1 { last = $0; seen = 1 }
    END {
      if (!seen) exit
      n = split(last, f, "|"); got = 0
      for (i = 1; i <= n; i++) {
        s = f[i]; sub(/^ */, "", s)
        if (index(s, "시작=") == 1) { v = substr(s, length("시작=") + 1); got = 1 }
      }
      if (got) { sub(/[[:space:]]+$/, "", v); print v }
    }' "$LEDGER" 2>/dev/null) || at=""
  [ -n "$at" ] || return 0
  cc_iso_to_epoch_into ep "$at"
  [ -n "$ep" ] || return 0
  watch_now_into now
  printf -v "$1" '%s' $(( now - ep ))
}

gate_idle_into() {
  # gate_idle_into <var> — sets <var> to the seconds since the gate was last
  # entered, or empty when there is no such record or it does not hold an epoch.
  #
  # WHY THE GATE AND NOT THE LEDGER. A ledger that has not grown is not a router
  # that has not worked, and the gap between those two is wide precisely where
  # the arm below looks: before the first segment the router writes the
  # manifest, records the grant, stubs the morning report, spawns this watcher
  # and reads skill contracts, and none of that appends a row.
  #
  # `started-at` is rewritten by `rundir_init` on EVERY gate entry, before the
  # verb is dispatched, so it moves for a `snapshot` and a `--render` too — the
  # calls that leave the ledger's size exactly where it was. That makes it a
  # strictly finer activity signal than the size this file already measures, not
  # a second spelling of it.
  #
  # Empty means "cannot judge", the same direction `run_open_into` takes. A
  # run directory the gate never made carries no such file, and reading its
  # absence as "nobody has called the gate" would accuse a router on the
  # strength of a file nobody wrote.
  local at="" now
  printf -v "$1" '%s' ""
  [ -n "$RUN_DIR" ] || return 0
  { IFS= read -r at; } 2>/dev/null < "$RUN_DIR/started-at" || :
  case "${at:-}" in ''|*[!0-9]*) return 0 ;; esac
  watch_now_into now
  printf -v "$1" '%s' $(( now - at ))
}

# There is no local `banner()` any more. The whole of what it did — the fixed
# title, the per-run group, the PATH opt-out, the swallowed failure — is what the
# emitter's `status` token now produces, so the five status-class call sites
# below are unchanged in behaviour. The approval one deliberately is not: it used
# to raise ONE aggregate notice into the run-level replace slot, and open
# approvals are precisely the class that must not share a slot.
#
# Every call swallows, because the emitter promising to return 0 is only half of
# responsibility 1 and a watcher that died on a missing notifier would take away
# the last signal the user had.

announce() {
  # Loud, on the terminal, once per condition. The whole point of this script is
  # that a person looking at the terminal in the morning learns something a
  # quiet prompt would not have told them.
  printf '\n================================================================\n'
  printf '  %s\n' "$1"
  printf '  %s\n' "$2"
  printf '================================================================\n\n'
}

file_mtime() {
  # file_mtime <path> — epoch seconds, or empty. `stat` diverges between BSD and
  # GNU on exactly the flag this needs, and `date -r` is on both and takes the
  # file directly. The same idiom the gate already uses, spelled the same way so
  # the two agree about what a timestamp is.
  [ -f "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

done_empty() {
  # done_empty — succeeds when `done` holds nothing but newlines or cannot be
  # read: what `[ -z "$(cat done)" ]` answers, read with a builtin. Each arm
  # asks at its own moment, so a `done` the gate writes during a pass still
  # silences the arms after it.
  local d
  cc__file_bytes d "$RUN_DIR/done"
  [ -z "$d" ]
}

host_load_num_into() {
  # host_load_num_into <var> <value> — sets <var> to the value itself when it is
  # a JSON number (an integer or a decimal with no leading zero), else to `null`.
  # Every field of the host-load sample goes through this, so a command that
  # printed nothing, an error text or a locale's decimal comma lands as `null`
  # rather than as a line no JSON reader can parse.
  local __hl_re='^(0|[1-9][0-9]*)(\.[0-9]+)?$'
  if [[ "${2:-}" =~ $__hl_re ]]; then printf -v "$1" '%s' "$2"; else printf -v "$1" '%s' null; fi
}

host_load_sample() {
  # host_load_sample <stages> — append one line to `$RUN_DIR/host-load.jsonl`:
  #
  #   {"schema":1,"at":…,"load1":…,"load5":…,"load15":…,"ncpu":…,"claude_procs":…,"runs":…,"stages":…}
  #
  # The keys and their order are fixed. A reader running while the run is still
  # going takes the last complete line and treats the load as unknown when its
  # `at` is older than three intervals.
  #
  # `load*` and `ncpu` come from one `sysctl` naming both keys on Darwin and from
  # `/proc/loadavg` and `getconf` elsewhere. `claude_procs` counts `pgrep -x
  # claude` across the host: no match is 0, and a missing or failing `pgrep` is
  # `null`. `runs` counts the sibling run directories whose `watch.heartbeat` was
  # rewritten within three intervals, this one included — measured in seconds,
  # since `find -mmin` rounds to minutes and `stat` flags differ by platform.
  # `stages` is the count this pass's heartbeat line carries.
  #
  # THE SAMPLE NEVER DECIDES ANYTHING ABOUT THE WATCHER. A value it cannot read is
  # `null`, a write that fails is ignored, and the heartbeat, the stall arms and
  # the exit status are the same with or without this file. Nothing rotates or
  # deletes it: one line is about 150 bytes, a day of them about 0.2MB.
  #
  # The host check is SEAMED (`WATCH_OS`, from `CC_WATCH_HOST_OS`) so a test on
  # any host can drive the Darwin branch, the one whose commands a PATH stub can
  # make fail.
  local out="" line la="" l1="" l5="" l15="" _rest nc="" procs rc runs=0 now pre mt fmt at
  local j1 j5 j15 jn jp jr js
  if [ "$WATCH_OS" = Darwin ]; then
    # One `sysctl` for both keys: the load line first, in braces, then the CPU
    # count. A line in braces or with more than one word is the load; the first
    # other line is the count.
    out=$(sysctl -n vm.loadavg hw.ncpu 2>/dev/null || true)
    while IFS= read -r line; do
      case "$line" in
        '{'*|*' '*) [ -n "$la" ] || la=${line//[\{\}]/} ;;
        ?*) [ -n "$nc" ] || nc=$line ;;
      esac
    done <<EOF
$out
EOF
  else
    { IFS= read -r la < /proc/loadavg; } 2>/dev/null || la=""
    nc=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  fi
  read -r l1 l5 l15 _rest <<EOF
$la
EOF
  procs=null
  if command -v pgrep >/dev/null 2>&1; then
    out=$(pgrep -x claude 2>/dev/null); rc=$?
    case "$rc" in
      0) procs=0
         while IFS= read -r line; do
           if [ -n "$line" ]; then procs=$((procs + 1)); fi
         done <<EOF
$out
EOF
         ;;
      1) procs=0 ;;
    esac
  fi
  # The run root keeps every finished run's directory and its last heartbeat.
  # ONE `ls` LISTS THEM NEWEST FIRST AND PRINTS EACH ONE'S MTIME IN EPOCH
  # SECONDS, so the walk forks for none of them and stops at the first one
  # outside the window. The time format is a flag of the `ls` binary, picked by
  # the host's own name: BSD spells it `-D %s`, GNU `--time-style=+%s`. `-d`
  # keeps a directory that happens to carry the name from being listed by its
  # contents, and a line whose mode is not a regular file's is passed over the
  # way the per-file reading passed it over. The path is taken off the end of
  # each line by the run root it starts with, so an owner or group name with a
  # space in it cannot shift the time field.
  case "$WATCH_HOST_UNAME" in
    Darwin|*BSD|DragonFly) fmt=-D ;;
    *) fmt=--time-style=+%s ;;
  esac
  if [ "$fmt" = -D ]; then
    out=$(ls -l -d -t -D %s "$WATCH_RUN_ROOT"/*/watch.heartbeat 2>/dev/null)
  else
    out=$(ls -l -d -t "$fmt" "$WATCH_RUN_ROOT"/*/watch.heartbeat 2>/dev/null)
  fi
  watch_now_into now
  while IFS= read -r line; do
    case "$line" in -*) ;; *) continue ;; esac
    pre=${line% "$WATCH_RUN_ROOT"/*}
    [ "$pre" != "$line" ] || continue
    mt=${pre##* }
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    [ $(( now - mt )) -le $(( 3 * INTERVAL )) ] || break
    runs=$((runs + 1))
  done <<EOF
$out
EOF
  watch_iso_into at
  host_load_num_into j1 "$l1"; host_load_num_into j5 "$l5"; host_load_num_into j15 "$l15"
  host_load_num_into jn "$nc"; host_load_num_into jp "$procs"; host_load_num_into jr "$runs"
  host_load_num_into js "${1:-}"
  { printf '{"schema":1,"at":"%s","load1":%s,"load5":%s,"load15":%s,"ncpu":%s,"claude_procs":%s,"runs":%s,"stages":%s}\n' \
      "$at" "$j1" "$j5" "$j15" "$jn" "$jp" "$jr" "$js" >> "$RUN_DIR/host-load.jsonl"; } 2>/dev/null || true
}

shift_active() {
  # Is a routing shift being launched right now?
  #
  # AN EXPIRY TIMESTAMP, AND `[ ! -f ]` IS FORBIDDEN HERE. The marker exists so
  # the after-stage arm does not read a shift changeover as "a stage ended and
  # the router went silent" — a misreading that writes a run-scope `blocked` row
  # with cause `불명`, and an unresolved run-scope block is an input to the
  # termination condition, so the run can no longer finish.
  #
  # But `RUN_DIR` is never pruned. Tested for mere existence, a shift that dies
  # immediately after its handoff leaves the file behind for the rest of the
  # night, and this arm is disarmed for good — the safety device becomes the
  # silent hole. Reading the timestamp is what makes the marker expire on its
  # own, with no writer needed to clean up after a process that is gone.
  #
  # OR THE SHIFT IS DEMONSTRABLY ALIVE. The expiry above is a 300-second
  # cold-start budget that is never renewed, and it was enough while a stage
  # ended inside the shift's own blocking dispatch call. With the supervisor
  # detached a stage can end at ANY point of a shift's life — six minutes in,
  # two hours in — and on the expired marker alone the after-stage arm fires
  # mid-shift and writes the run-scope `blocked` row this function exists to
  # prevent. `shift.live` (pid + fingerprint, written by the gate's launcher
  # beside the marker and removed with it) answers the question the timestamp
  # cannot; the fingerprint is what keeps a reused pid from disarming the arm
  # for good. Lengthening the expiry instead would reopen a hole of that length,
  # and a shift's real length is unbounded so no number is right.
  local f="$RUN_DIR/shift.in-progress" exp=""
  if [ -f "$f" ]; then
    { IFS= read -r exp; } 2>/dev/null < "$f" || :
    exp=${exp//[!0123456789]/}
    if [ -n "$exp" ] && [ "$(now_epoch)" -lt "$exp" ]; then return 0; fi
  fi
  cc_shift_is_live "$RUN_DIR"
}

seat_turn_open() {
  # Is the seat's turn open after a handoff? The ledger's latest `handoff` row
  # comes after its latest `교대 기동` row, and no relay is alive to hold the
  # wait. The ROW ORDER decides, not a clock: the launcher writes nothing after a
  # shift but the `무기록` handoff, and other writers during the seat turn do not
  # move the order. A live relay gets no grace — the `! relay_effective`
  # conjunct is what speaks for it, so a hung relay cannot hide in this window.
  [ -n "$LEDGER" ] && [ -f "$LEDGER" ] || return 1
  cc_relay_is_live "$RUN_DIR" && return 1
  LC_ALL=C awk '
    /^- `handoff` / { h = NR }
    /^- `교대 기동` / { l = NR }
    END { exit((h > 0 && h > l) ? 0 : 1) }
  ' "$LEDGER" 2>/dev/null
}

fleet_run_marker_live() {
  # Is a fixed-graph run's dispatch job alive for THIS run? rc 0 when a fleet
  # run marker under `busy/` carries this watcher's run id on its third line and
  # its pid is still the process that wrote it (first line pid, second line the
  # start fingerprint taken in UTC, the way the writer took it). rc 1 when the
  # directory is absent, no marker names this run, or every one that does is
  # dead.
  #
  # Only the pid half of fleet's own liveness test: the probe half is the run's
  # live stages, and a stage that is alive already keeps the arms quiet on its
  # own. The gate's `gate_fleet_busy_state` reads the same marker the same way.
  # Read only — removing a dead marker is the dispatcher's job under its lock.
  local d f pid fp run
  d="${FLEET_PACE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace}/busy"
  [ -d "$d" ] || return 1
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    run=$(sed -n '3p' "$f" 2>/dev/null | tr -d '[:space:]')
    [ "$run" = "$RUN_ID" ] || continue
    pid=$(sed -n '1p' "$f" 2>/dev/null | tr -d '[:space:]')
    fp=$(sed -n '2p' "$f" 2>/dev/null || true)
    if TZ=UTC0 cc_holder_is_live "$pid" "$fp"; then return 0; fi
  done
  return 1
}

failover_clock_note() {
  # Called once per cycle. Keeps `watch.failover-clock`: this cycle's epoch, the
  # current account-failover wait's resume time (`-` with none), and the seconds
  # of clock jump this watcher saw after that resume time.
  #
  # A JUMP IS THE GAP BETWEEN TWO PASSES PAST THREE INTERVALS: the host slept,
  # or something held this process. The slack `failover_waiting` gives covers a
  # host that stays awake and a tick that runs on time; a sleep over the whole
  # slack would otherwise have the first pass after it read a run the next tick
  # will resume as silent, and write a `blocked` row a resolving row has to take
  # back, a shift's or a person's. No
  # ordering holds between that pass and the tick, so the part of the jump past
  # the resume time is taken off the clock the slack is measured on: the tick
  # gets its own awake slack, and with no jump nothing is taken off. A new
  # resume time starts from zero.
  #
  # `failover_clock_note probe` is the probe cycle's call, and it reads no file:
  # the resume time is the one the last full pass read from the ledger, and the
  # previous pass's epoch and the jump so far are the ones this process wrote
  # last. The file is written with a plain redirect, not a rename: a reader can
  # catch it empty between the truncation and the one short write, and an empty
  # file reads as no jump, which is the direction a host that stayed awake has.
  local f="$RUN_DIR/watch.failover-clock" now at last="" prev_at="" held="" iv from
  watch_now_into now
  if [ "${1:-}" = probe ]; then
    at=$W_FO_AT; last=$W_FO_LAST; prev_at=$W_FO_PREV; held=$W_FO_HELD
  else
    at=$(cc_failover_wait_resume "$LEDGER" 2>/dev/null || true)
    { IFS= read -r last; IFS= read -r prev_at; IFS= read -r held; } 2>/dev/null < "$f" || :
  fi
  case "$last" in ''|*[!0-9]*) last=$now ;; esac
  case "$held" in ''|*[!0-9]*) held=0 ;; esac
  [ "$prev_at" = "${at:--}" ] || held=0
  if [ -n "$at" ]; then
    iv=${INTERVAL%.*}
    case "$iv" in ''|*[!0-9]*) iv=1 ;; esac
    if [ $((now - last)) -gt $((iv * 3)) ]; then
      from=$last
      [ "$from" -ge "$at" ] || from=$at
      [ "$now" -le "$from" ] || held=$((held + now - from))
    fi
  fi
  { printf '%s\n%s\n%s\n' "$now" "${at:--}" "$held" > "$f"; } 2>/dev/null || :
  W_FO_AT=$at; W_FO_LAST=$now; W_FO_PREV=${at:--}; W_FO_HELD=$held
  return 0
}

failover_waiting() {
  # The run is inside an account-failover wait: the latest `계정 이전` row
  # after the latest `handoff` is `결과=대기` and its `재개 시각`, plus the
  # slack in which the relay or the fleet tick makes the next call
  # (`CC_FAILOVER_WATCH_SLACK_SECONDS`), has not come. Read by the shared
  # helper the gate and the fleet tick use, on this watcher's clock less the
  # jump `failover_clock_note` kept, which is none on a host that stayed awake.
  #
  # ONCE PER PASS. `pass` declares `fo_wait` empty and the first call fills it,
  # so the several arms that ask in one pass read one answer and one ledger
  # read; a caller without that variable asks afresh every time.
  local held="" _l1 _l2 now rc
  case "${fo_wait-}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  { IFS= read -r _l1; IFS= read -r _l2; IFS= read -r held; } 2>/dev/null < "$RUN_DIR/watch.failover-clock" || :
  case "$held" in ''|*[!0-9]*) held=0 ;; esac
  watch_now_into now
  rc=0
  cc_failover_waiting_now "$LEDGER" "$(( now - held ))" "$CC_FAILOVER_WATCH_SLACK_SECONDS" || rc=$?
  if [ "${fo_wait-unset}" != unset ]; then
    if [ "$rc" = 0 ]; then fo_wait=1; else fo_wait=0; fi
  fi
  return "$rc"
}

stall_threshold_into() {
  # The threshold T of the general and settle-stall arms. `STALL` while a seat
  # turn is open or a halt record waits for a person's answer — neither is a
  # router that stopped, and both are as long as the measured seat-turn gaps or
  # longer — and `min(STALL, SILENCE)` otherwise, so a fixture passing a small
  # `--stall` keeps its meaning.
  #
  # `STALL` too while a fixed-graph run's marker is alive. That run has no
  # router, no shift and no handoff row, and its driver polls CI inline outside
  # the gate for up to an hour — no gate entry, no ledger row, no stage — so
  # `SILENCE` would call a healthy merge wait a stall and leave a run-scope
  # `blocked` row that stays until a resolving row takes it back, which that run
  # has no shift to write.
  #
  # `STALL` too while the run waits for an account-failover resume time
  # (`failover_waiting`): the gate wrote that wait and launches nothing until
  # then, so the quiet is the wait itself. The silence, after-stage, run-open
  # and settle arms also read the same judgment as a conjunct and raise nothing
  # before that time; past it they judge as before.
  #
  # `stall_threshold_into <var>` sets <var> rather than printing, so the pass
  # forks no subshell for it; the unanswered-halt count it read, when it read
  # one, is left in the caller's `halts` for the quiet judgment.
  local h
  if seat_turn_open; then printf -v "$1" '%s' "$STALL"; return 0; fi
  if failover_waiting; then printf -v "$1" '%s' "$STALL"; return 0; fi
  h=$(cc_unanswered_halts "$RUN_DIR" "$LEDGER" 2>/dev/null || printf 0)
  halts=$h
  if [ "${h:-0}" -ge 1 ] 2>/dev/null; then printf -v "$1" '%s' "$STALL"; return 0; fi
  if fleet_run_marker_live; then printf -v "$1" '%s' "$STALL"; return 0; fi
  if [ "$SILENCE" -lt "$STALL" ]; then printf -v "$1" '%s' "$SILENCE"; else printf -v "$1" '%s' "$STALL"; fi
}

quiet_seconds() {
  # Seconds since the run last showed activity on any signal, or empty when it
  # cannot be judged. The base is the LATEST of: the ledger's last growth, the
  # gate's last entry (`started-at`, left out when unreadable), a relay's
  # `handback`, and a live shift's newest stream log. `refreshed` is not one of
  # them: a relay that refreshes and never wakes would hide behind it, and a
  # relay doing its job is already held off by `! relay_effective`.
  #
  # A LIVE SHIFT WITH NO STREAM LOG IS NOT JUDGED. The log is created by the
  # redirection before `shift.live` exists, so this is not a normal state, and
  # without the shift's own signal its silence would be measured on the two that
  # a working shift may well leave quiet.
  local now base b lg
  watch_now_into now
  base=$((now - ${age:-0}))
  if [ -n "${gate_idle:-}" ]; then
    b=$((now - gate_idle)); [ "$b" -le "$base" ] || base=$b
  fi
  b=$(cc_relay_field "$RUN_DIR" handback)
  case "$b" in ''|*[!0-9]*) : ;; *) [ "$b" -le "$base" ] || base=$b ;; esac
  if cc_shift_is_live "$RUN_DIR"; then
    lg=$( { ls -t "$RUN_DIR"/log/shift-*.json 2>/dev/null || true; } | sed -n '1p')
    [ -n "$lg" ] || return 0
    b=$(file_mtime "$lg")
    [ -n "$b" ] || return 0
    [ "$b" -le "$base" ] || base=$b
  fi
  [ "$base" -le "$now" ] || base=$now
  printf '%s' $((now - base))
}

relay_seen_note() {
  # Record, per relay and per key, the pass that first saw a wake condition
  # whose evidence carries no clock of its own — a `stage-result` after the
  # reference row, or a waited key no longer live. Kept in `watch.relay-seen`,
  # the way `watch.state` keeps the ledger's size, so the clock survives `--once`
  # and a restarted watcher. A CI wake carries its verdict's `관측` and is not
  # recorded here.
  local started k c now tab
  [ -d "$RUN_DIR" ] && [ -f "$RUN_DIR/relay.live" ] || return 0
  started=$(cc_relay_field "$RUN_DIR" started)
  [ -n "$started" ] || return 0
  watch_now_into now
  tab=$'\t'
  while IFS="$tab" read -r k c; do
    [ -n "$k" ] && [ -z "$c" ] || continue
    [ -z "$(cc_relay_seen_at "$RUN_DIR" "$started" "$k")" ] || continue
    printf '%s\t%s\t%s\n' "$started" "$k" "$now" >> "$RUN_DIR/watch.relay-seen"
  done <<EOF
$(cc_relay_wake_keys "$RUN_DIR" "$LEDGER")
EOF
  return 0
}

relay_effective() {
  # A relay that is alive, refreshing within `SILENCE` and not sitting on a wake
  # condition for longer than `AFTER_STAGE`. A separate conjunct of the general
  # and settle-stall arms only: folded into `live_w` or `shift_active` it would
  # also switch off the after-stage arm, the one cross-check that names a relay
  # which saw its stage end and launched nothing.
  relay_seen_note
  cc_relay_is_effective "$RUN_DIR" "$LEDGER" "$SILENCE" "$AFTER_STAGE"
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
  local at
  watch_iso_into at
  printf '%s\t%s\t%s\n' "$at" "$1" "$2" >> "$RUN_DIR/stall"
}

beat() {
  # beat — the watcher's own liveness, apart from every arm: the reads the arms
  # judge on and the heartbeat that publishes them.
  #
  # SPLIT OUT OF `pass` FOR THE `done` TAIL. While `done` is on disk and a shift
  # is still settling, the loop runs no arm at all, but the watcher is alive and
  # has to look it — the status line reads a heartbeat older than two minutes as
  # "no watcher", and the gate's report and the ledger-growth clock read their
  # age fields from this file. So the tail calls this alone, and `pass` calls it
  # first and then judges.
  #
  # The variables are the caller's: `pass` declares them local and the arms read
  # what this assigned. Called from the loop they are plain globals nothing else
  # reads.
  #
  # The judgment reads are also kept in `W_*`, the memory the probe cycle
  # publishes from (`probe_beat`).
  watch_self_marks
  ledger_idle_read
  live=$(live_stages)
  # A STAGE WAITING FOR AN ACCOUNT HAS NO PROCESS YET, so `live` does not see
  # it, and a run whose only work is that wait is not silent: its supervisor or
  # driver rewrites its marker and a `stage-wait` row on half of `STALL`.
  # `live_w` counts the fresh ones beside the live stages, and the arms that ask
  # "is anything running" read it. A waiter whose refresh has stopped is no
  # longer fresh, so it stops quieting them — that is how a hung waiter is
  # still heard. The after-stage arm reads it too: a wait's own first row
  # moves the last ledger row only when nothing else ends after it, and a
  # different stage's terminal rows can land below that wait while the router
  # sits in `gate.sh wait` for the waiter.
  live_w=$(( ${live:-0} + $(cc_waiting_fresh_count "$RUN_DIR" "$LEDGER" "$STALL") ))
  pend=$(open_approvals)
  nonterm=$(nonterminal_segments)

  # Positive heartbeat. Says the watcher is alive, which is what makes its
  # silence mean something.
  #
  # Written to a FILE as well as to stdout, and the file is what carries the
  # claim. This process is launched into the background with its STDIN closed and
  # its STDOUT REDIRECTED to a log file in the run directory — not closed, which
  # is what this comment used to say and what the design inherited from it. The
  # older wording described the launch form that preceded the redirection. The
  # consequence is the same either way and it is the reason the file exists:
  # nobody opens that log overnight, so a heartbeat printed there reaches no one
  # and the property "a live watcher's silence differs from a dead one's" was
  # stated and then not obtainable. The file's own mtime is what makes the
  # watcher's liveness measurable, and it is rewritten every cycle even when
  # nothing changed, which is exactly the case `watch.state` cannot cover: that
  # file only moves when the ledger's size moves.
  #
  # THE LAST TWO FIELDS ARE FOR A READER THAT IS NOT THIS PROCESS. The status
  # line has to judge whether the ledger is stale, and it may not write — so it
  # cannot own an elapsed-since-last-growth clock of its own. This file is where
  # that value is published, and it comes from the clock that already exists:
  # `ledger_idle_read` records "when I first saw this size" on line 2 of
  # `watch.state`, and for an append-only ledger that IS the last growth. A
  # second clock would be a second answer to one question.
  #
  # The four existing fields keep their positions and their wording verbatim —
  # they are read from this file by name.
  W_AGE=$age; W_LIVE=$live; W_PEND=$pend; W_NONTERM=$nonterm; W_SIZE=$size; W_GREW=$grew
  watch_publish
}

watch_self_marks() {
  # The watcher's own pid, so a person (and the status line) can tell a live
  # watcher from a finished run's. The directory is NOT created here: the
  # watcher legitimately runs in the window before the router's first gate call
  # makes it, and `run_is_over()` already owns that window. `cc_live_stages`
  # does not count this file — it has no `.start`/`.pgid` sibling.
  [ -d "$RUN_DIR" ] && printf '%s' "$$" > "$RUN_DIR/watch.pid"
  # THE THRESHOLD THIS PROCESS IS USING, for a stage that waits for an account:
  # it paces its heartbeat rows on half of it. Three lines — the threshold in
  # seconds, this pid, this pid's fingerprint — written to a temporary name first
  # so a reader never sees half a record, and renamed into place. The name does
  # not end in `.pid`, so no census reads it as a stage.
  #
  # NOT REWRITTEN WHEN NOTHING IN IT CHANGED. The content is the same for the
  # life of this process, so it is written on the first pass, and again only if
  # the file is gone; a restarted watcher's first pass replaces the old one's.
  local body
  [ -d "$RUN_DIR" ] || return 0
  body="$STALL"$'\n'"$$"$'\n'"$WATCH_FP"$'\n'
  if [ "$body" = "${WATCH_STALL_LAST:-}" ] && [ -f "$RUN_DIR/watch.stall" ]; then
    return 0
  fi
  if { printf '%s' "$body" > "$RUN_DIR/.watch.stall.$$"; } 2>/dev/null \
     && mv -f "$RUN_DIR/.watch.stall.$$" "$RUN_DIR/watch.stall" 2>/dev/null; then
    WATCH_STALL_LAST=$body
  else
    rm -f "$RUN_DIR/.watch.stall.$$"
  fi
  return 0
}

watch_publish() {
  # Writes the heartbeat line, the host-load sample and the alive line from the
  # caller's `age`, `live`, `pend`, `nonterm`, `size` and `grew`, stamped by the
  # memory clock. The full pass and the probe cycle both end their beat here, so
  # the two lines keep one field order whichever cycle wrote them.
  local at
  watch_iso_into at
  printf '%s 원장 %s초 전 갱신 · 스테이지 %s개 · 대기 승인 %s건 · 비종단 세그먼트 %s개 · 원장크기=%s · 마지막성장=%s\n' \
    "$at" "$age" "$live" "$pend" "$nonterm" "$size" "$grew" > "$RUN_DIR/watch.heartbeat"
  # The host-load sample rides the same cadence, after the heartbeat so its own
  # file already counts toward `runs`. `beat` also runs in the `done` tail, so the
  # last heartbeat leaves a sample too.
  [ -d "$RUN_DIR" ] && host_load_sample "$live"
  printf '%s [watch] 살아 있음 — 원장 %s초 전 갱신, 스테이지 %s개, 대기 승인 %s건, 비종단 세그먼트 %s개\n' \
    "$at" "$age" "$live" "$pend" "$nonterm"
}

probe_beat() {
  # The probe cycle's beat: the watcher's own marks, then the heartbeat and the
  # alive line from the values the last full pass read (`W_*`), with the ledger
  # age carried forward on the memory clock. Nothing the arms judge on is read
  # here — a probe cycle runs only when the probe saw nothing new.
  local age live pend nonterm size grew now
  watch_self_marks
  watch_now_into now
  live=$W_LIVE; pend=$W_PEND; nonterm=$W_NONTERM; size=$W_SIZE; grew=$W_GREW
  case "$grew" in
    ''|*[!0-9]*) age=$W_AGE ;;
    *) age=$((now - grew)) ;;
  esac
  watch_publish
  failover_clock_note probe
}

settle_stall_arm() {
  # A SETTLEMENT THAT STOPPED. A run carrying `ends-on-done` does not end when
  # its last segment does: the seat still settles the exit clauses and writes
  # `done`. The stall arm in `pass` cannot see this window — its condition is a
  # non-terminal segment or no segment at all, and here every segment is
  # terminal — so a seat that stopped after the last merge would be silent all
  # night.
  #
  # It reads `age`, `live`, `pend`, `nonterm` and `size` as `beat` left them in
  # the calling `pass`. A function of its own, rather than inline, so the window
  # between its condition and its fire can be driven on its own.
  #
  # ONCE PER LEDGER SIZE. The marker carries the size the stop was observed at,
  # so the same stop says nothing twice and a settlement that grew the ledger
  # and stopped again is a new episode.
  #
  # NO BLOCK ROW. An unresolved run-scope block is an input to the termination
  # condition, so writing one here could refuse the very `propose-done` the
  # banner asks the seat to make. A live shift is not excluded: one that has
  # been quiet for T, its stream quiet too, may be hung, and that is a person's
  # to look at. T, the quiet base and the `! relay_effective` conjunct are the
  # general arm's, read from the calling `pass`.
  #
  # THE TWO FILES ARE TESTED AGAIN JUST BEFORE THE FIRE. `resume` shares the
  # run's slot with `ended`, and the later banner replaces the earlier — so a
  # gate that wrote `done` and raised `ended` during this pass must not be
  # covered by a stall banner raised after it. What remains is the window
  # between this test and the notifier's own start.
  local mk
  cc_run_ends_on_done "$RUN_DIR" || return 0
  [ ! -f "$RUN_DIR/done" ] || return 0
  [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$nonterm" = "0" ] || return 0
  [ "$(cc_segment_count "$LEDGER")" -ge 1 ] 2>/dev/null || return 0
  [ "$(cc_unresolved_blocked "$LEDGER" | grep -c . || true)" = "0" ] || return 0
  [ -n "${quiet:-}" ] && [ "$quiet" -ge "$thr" ] || return 0
  [ "${relay_eff:-0}" = "0" ] || return 0
  ! failover_waiting || return 0
  mk="$RUN_DIR/watch.announced-settle-stall-$size"
  [ ! -f "$mk" ] || return 0
  : > "$mk"
  announce "세그먼트는 모두 끝났는데 런이 ${age}초째 끝맺지 못했습니다" \
           "좌석이 정산(종료 조항·done)을 마치지 못하고 멈췄을 수 있습니다 — 세션에서 정산을 이어가세요"
  if [ ! -f "$RUN_DIR/done" ] && [ ! -d "$RUN_DIR/notify.ended" ]; then
    cc_notify_fire resume "세그먼트는 끝났는데 런이 ${age}초째 끝맺지 못하고 멈췄습니다 — 세션에서 정산을 이어가세요" || true
  fi
  return 0
}

pass() {
  # NO ARM RETURNS BEFORE THE HEARTBEAT. Every arm below used to `return 0` on
  # firing, so a run in a condition that keeps re-arming stopped rewriting
  # `watch.heartbeat` entirely — and a stale heartbeat is exactly how a dead
  # watcher looks. The heartbeat is now written by `beat`, ahead of every arm,
  # so no arm can skip it; each arm still carries its own once-marker, so two
  # firing in one pass is harmless.
  local age live live_w pend nonterm run_age gate_idle size grew silent id newly stale
  local cause reason slug mk thr quiet relay_eff halts="" fo_wait="" ub line expiry="" now
  beat
  failover_clock_note
  # THE GATE'S IDLE TIME SITS BESIDE `age` because two arms read it: the
  # run-open arm, and the quiet base of the general and settle-stall arms.
  gate_idle_into gate_idle
  stall_threshold_into thr
  quiet=$(quiet_seconds)
  relay_eff=0
  if relay_effective; then relay_eff=1; fi
  # The emitter's own state, once per run, into this process's file. The gate
  # transcribes it into the report on its next call; this seat never appends
  # there itself, because it holds no lock and the ledger rows beside the prose
  # are what an interleaved write corrupts.
  cc_notify_seat_state || true

  # THE RUN ENDED, AS THE LEDGER DERIVES IT. The `done` file is a SHORTCUT for
  # that and not its definition on a run without the `ends-on-done` marker:
  # measured 2026-09-07, 99 of 202 run directories had one, so waiting for it
  # would stay silent about the half of all runs that never reach the
  # propose-done path. The shared state predicate derives the same conclusion
  # from the ledger, and using it here is what keeps this line and the status
  # line from disagreeing about whether a run is over. A run WITH the marker
  # never reads 종단 without `done`, and while `done` is on disk the loop runs
  # no pass — so in practice this arm speaks for a markerless run's derived end,
  # and for a `--once` call on a run that already has `done`.
  #
  # THE RUN'S ONE `ended` IS CLAIMED, NOT MARKED. The gate raises it too, and
  # it publishes `done` before it reaches its own fire line — so a pass landing
  # in between reads 종단 and wins the claim. The sentence is read from `done`
  # for that reason: a fixed clean-finish sentence here would take a boundary's
  # or an invalidation's only `ended` and say something else.
  if [ "$(cc_run_state "$RUN_DIR" "$LEDGER" "$STALL")" = "종단" ] && cc_notify_claim_ended; then
    announce "런이 종단했습니다 — 더 진행할 것이 없습니다" \
             "아침 보고서를 확인하세요 — 이 스크립트는 아무것도 재개하지 않습니다"
    cc_notify_fire ended "$(cc_notify_ended_text "$RUN_DIR")" || true
    cc_notify_mark_ended_fired
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
  # AND NOT WHILE A SHIFT IS CHANGING OVER. Under the headless routing shape a
  # stage ending is followed by the routing session itself ending and a
  # successor starting, and for those seconds the ledger's last row IS a
  # terminal stage row with no live stage and no router acting — which is this
  # arm's condition exactly. The marker distinguishes a changeover from a
  # stranding, and it is read as an EXPIRY rather than as a flag; see
  # `shift_active`.
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$AFTER_STAGE" ] \
     && [ "$nonterm" -ge 1 ] && ! shift_active && ! failover_waiting \
     && done_empty \
     && [ "$( { grep -E '^- `' "$LEDGER" 2>/dev/null || true; } | tail -1 \
             | grep -cE '^- `(stage-result|cost)`' || true)" != "0" ] \
     && [ ! -f "$RUN_DIR/watch.announced-after-stage" ]; then
    : > "$RUN_DIR/watch.announced-after-stage"
    announce "스테이지가 끝났는데 라우터가 ${age}초 동안 아무것도 하지 않았습니다" \
             "그 스테이지를 깨울 통지가 없는 형태로 띄웠을 수 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    cc_notify_fire resume "스테이지가 끝났는데 런이 이어지지 않습니다 (${age}초)" || true
    record_blocked "스테이지 종단 후 라우터 무응답" "메인 세션에서 이어서 진행하도록 지시"
  fi

  # A STAGE THAT IS ALIVE AND HAS BEEN FOR TOO LONG. Nothing in this file aimed
  # at that pathology before, and no boundary in the gate did either: a hung stage
  # produces no acts, and the act budget counts acts, so it was never a hang
  # detector to begin with. Every arm above times the ROUTER; this one times a
  # STAGE, and the commercial failure mode — a stage wedged while the router keeps
  # working normally — is invisible to all of them.
  #
  # THREE CANDIDATE ANTECEDENTS WERE MEASURED AND THIS IS THE ONLY ONE THAT
  # COVERS THE CASE. "The ledger is completely silent" covers 0.7% of real live
  # intervals — a median of 20 rows are written while a stage lives and 51.6% of
  # them grade `읽기`, so keeping the ledger noisy is free for the router. "The
  # ledger has been idle for N" is a different predicate and its own numbers are
  # decent (4/136 false positives, stable across 20/30/60-minute thresholds), but
  # it fails on BEHAVIOUR rather than on error rate: a router that keeps writing
  # never lets the gap open, so it misses "hung stage, working router" too.
  # "The progress digest has not moved" covers 15.6%; it fires when the router
  # shoots only reads and stays silent when reads and worktree writes are mixed,
  # and the observed grade mix is 51.6% read against 37.7% worktree write, so
  # mixed is the shape that actually occurs. Stage age fires on the first
  # evaluation in all three shapes.
  #
  # THE CLOCK IS THE STAGE'S START FINGERPRINT, `<seg>.start`. It is written once
  # when the stage spawns and never touched again, so its mtime IS the age — which
  # is exactly what the word means. The stream log's mtime was the other
  # candidate and it measures "how long since it last spoke", which loses the
  # stage that is wedged while its log keeps growing — the very case this arm
  # exists for. The liveness predicate already uses this file as its fingerprint,
  # so no new path is introduced.
  #
  # `cc_mtime` NAMED EXPLICITLY. Two helpers with this body exist — one here in
  # `liveness.sh` and one in the gate — and the cross-platform assertion has to
  # measure the same one this arm reads.
  #
  # NOTIFY ONLY; NO BLOCK ROW. Every sibling stall arm calls `record_blocked`, and
  # copying that here would be wrong in a way that undoes this arm's own
  # justification: an unresolved run-scope block stands up a termination condition
  # and the shared state predicate then refuses terminal forever, so one long
  # legitimate stage would stop the run from ending all night and would need a
  # person or a shift to write the resolving row. The tolerance for false positives
  # above is bought entirely by "firing leaves a line, it does not kill" — a block
  # row spends that. And the two differ in kind: the sibling arms measure the
  # ROUTER's silence, which takes a person or a shift to break, while this one
  # measures a STAGE's, which resolves by itself when the stage ends.
  #
  # The once-guard is a dedicated per-stage marker for the same reason the arms
  # above use one: the gate empties `stall` on every act, so a guard reading that
  # file would come back to life and this arm would re-fire every pass.
  local sf sseg sstart snow sage smk
  watch_now_into snow
  for sf in "$RUN_DIR"/*.pid; do
    [ -f "$sf" ] || continue
    sseg=${sf##*/}; sseg=${sseg%.pid}
    cc_stage_is_live "$RUN_DIR" "$sseg" || continue
    sstart=$(cc_mtime "$RUN_DIR/$sseg.start")
    [ -n "$sstart" ] || continue
    sage=$((snow - sstart))
    # THE MARKER IS KEYED TO THE STAGE INSTANCE, NOT THE SEGMENT, because the
    # clock it guards is per-instance: the gate writes `<seg>.start` on every
    # launch and deletes it on exit, so the age resets while a segment-keyed
    # marker would not — and nothing anywhere clears these markers. One false
    # positive would then consume this segment's detector for the whole run.
    # That matters because the acceptance argument for this arm's false
    # positives is "a firing costs one line in the morning, it kills nothing";
    # if the firing also spends the detector, the cost side gains every later
    # miss and the comparison stops holding. The ordering it takes is inside
    # this design's own distribution — a long legitimate stage followed by a
    # genuinely stuck one on the same segment.
    #
    # The start mtime is the instance discriminator because it is the only one
    # on disk: the gate's own stage identity (`<seg>#<attempt>`) lives in the
    # child's environment, which the watcher cannot read.
    smk="$RUN_DIR/watch.announced-stage-age-$sseg-$sstart"
    if [ "$sage" -ge "$STAGE_AGE" ] && [ ! -f "$smk" ]; then
      : > "$smk"
      announce "스테이지 ${sseg} 이 ${sage}초째 살아 있습니다 (임계 ${STAGE_AGE}초)" \
               "걸렸을 수 있습니다 — 스트림 로그를 보고 판단하세요. 이 팔은 막힘 행을 쓰지 않으므로 런의 종료를 막지 않습니다"
      cc_notify_fire hands "스테이지 ${sseg} 이 ${sage}초째 살아 있습니다 — 걸렸는지 확인하세요" || true
    fi
    if [ ! -f "$smk" ]; then watch_expiry_offer $((sstart + STAGE_AGE)); fi
  done

  # THE RUN OPENED AND NO SEGMENT EVER DID. Its own arm, keyed on the age of the
  # `run` row, because that window has no other clock: with no segment row there
  # is no stage to be alive, no approval to be open, and no terminal stage row
  # for the arm above to key on. Grafting the case onto that arm is what produced
  # a disjunct its own last-row guard made unreachable, and the window was then
  # left to the stall arm's twenty minutes.
  #
  # THE TWO IDLE CONJUNCTS ARE PART OF THE CONDITION, not refinements. The
  # router writes `자율 승인` rows before it opens the first segment, so "no
  # segment yet" on its own accuses a router that is working. Adding "and the
  # ledger has not grown for `AFTER_STAGE`" asks the sharper question: nothing
  # running, nothing waiting, nothing written, and still no segment.
  #
  # AND THAT IS STILL NOT SHARP ENOUGH, which is what the gate conjunct is for.
  # Measured on a healthy run: the run 333 seconds old, the ledger unchanged for
  # 300, no segment row, no live stage and no open approval — every other
  # conjunct here satisfied — and that router opened its first segment normally
  # 21 minutes and 32 seconds later. It was not idle in that window; it was
  # writing the manifest and the grant, stubbing the report, starting this
  # watcher and reading skill contracts, none of which appends a row.
  #
  # RAISING `RUN_OPEN` PAST IT IS NOT THE ANSWER. The observed healthy silence
  # is longer than `STALL`, so a threshold above it would take this arm's reason
  # for existing — saying it sooner than the general stall arm does — away.
  # Asking the gate instead separates "the ledger did not grow" from "nobody
  # called the gate", and only the second is the failure this arm reports.
  #
  # Both idle tests keep `AFTER_STAGE`: they are two readings of one quantity —
  # how long the run has been silent — and giving them separate thresholds would
  # make "silent" mean two things in one condition.
  #
  # THE STALL ARM YIELDS TO IT IN THE ZERO-SEGMENT WINDOW. The two once fired at
  # `RUN_OPEN` and `STALL`, two different moments, and recording both was
  # intended. With the general arm now firing at `min(STALL, SILENCE)` the two
  # reach the same silence in the same pass, so once this arm has recorded
  # (`watch.announced-run-open`) the general arm says nothing for a run with no
  # segment. A run that never entered the gate is not recorded here — the gate
  # idle conjunct needs `started-at` — so the general arm still records that one.
  #
  # A NORMALLY TERMINATED RUN CANNOT REACH IT: a clean finish has at least one
  # segment row, so the segment count alone excludes it, and the `done` guard
  # excludes it a second time.
  #
  # A RUN WAITING ON AN ACCOUNT-FAILOVER RESUME TIME STAYS OUT TOO: a first shift
  # can hit the limit before any segment opens, and then no segment and no gate
  # entry is the wait the gate wrote, which the next call ends.
  #
  # The once-guard is a dedicated marker for the same reason the arm above's is:
  # the gate empties `stall` on every act, so a guard that read that file would
  # come back to life and this arm would re-fire every pass.
  run_open_into run_age
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] \
     && [ "$(cc_segment_count "$LEDGER")" = "0" ] \
     && [ -n "$run_age" ] && [ "$run_age" -ge "$RUN_OPEN" ] \
     && [ "$age" -ge "$AFTER_STAGE" ] \
     && [ -n "$gate_idle" ] && [ "$gate_idle" -ge "$AFTER_STAGE" ] \
     && ! failover_waiting \
     && done_empty \
     && [ ! -f "$RUN_DIR/watch.announced-run-open" ]; then
    : > "$RUN_DIR/watch.announced-run-open"
    announce "런이 열린 지 ${run_age}초인데 세그먼트가 하나도 열리지 않았습니다" \
             "라우터가 첫 세그먼트를 열기 전에 멈췄을 수 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    cc_notify_fire resume "런이 열린 뒤 ${run_age}초 동안 세그먼트가 열리지 않았습니다" || true
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
  # THE THRESHOLD IS T AND THE CLOCK IS THE QUIET BASE (`stall_threshold_into`,
  # `quiet_seconds`): `min(STALL, SILENCE)` measured from the latest activity on
  # any signal, `STALL` while a seat turn is open or a halt record is unanswered.
  # An empty quiet reading — a live shift with no stream log — does not fire. An
  # effective relay holds the arm off as its own conjunct. In the zero-segment
  # window the arm yields once the run-age arm above has recorded.
  #
  # AND NOT AFTER `done`, as the run-open and feed-silence arms already hold.
  # The loop runs no pass while `done` is on disk, but a `done` written during
  # this pass would otherwise be followed by a `라이브니스 침묵` block row on a
  # run that has ended.
  #
  # The unresolved set is read once here, and the anchored arm below walks the
  # same copy; the count is of its lines that carry the reason, as `grep -cF`
  # counted them.
  ub=$(cc_unresolved_blocked "$LEDGER")
  silent=0
  while IFS= read -r line; do
    case "$line" in *'라이브니스 침묵'*) silent=$((silent + 1)) ;; esac
  done <<EOF
$ub
EOF
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] \
     && [ -n "$quiet" ] && [ "$quiet" -ge "$thr" ] \
     && [ "$relay_eff" = "0" ] && ! failover_waiting \
     && { [ "$nonterm" -ge 1 ] \
          || { [ "$(cc_segment_count "$LEDGER")" = "0" ] \
               && [ ! -f "$RUN_DIR/watch.announced-run-open" ]; }; } \
     && done_empty \
     && ! grep -q '라이브니스 침묵' "$RUN_DIR/stall" 2>/dev/null \
     && [ "${silent:-0}" = "0" ]; then
    # A waiter whose refresh stopped while its holder lives is never dispatched
    # again — the key is still a member — so the only recovery is to end that
    # holder, after which settlement closes the attempt. Say so by pid, or the
    # person resumes a router that will refuse to dispatch the key.
    stale=$(cc_waiting_records "$RUN_DIR" "$LEDGER" "$STALL" \
            | awk -F'\t' '$8 == "false" { printf "%s%s(보유자 %s)", (n++ ? ", " : ""), $1, $6 }')
    if [ -n "$stale" ]; then
      announce "런이 ${age}초 동안 아무것도 쓰지 않았습니다 (살아 있는 스테이지 0, 갱신이 멈춘 대기자: ${stale})" \
               "갱신이 멈춘 대기자의 보유자 pid 를 끝내면 정산이 그 시도를 닫고 다시 파견할 수 있습니다 — 이 스크립트는 아무것도 재개하지 않습니다"
    else
      announce "런이 ${age}초 동안 아무것도 쓰지 않았습니다 (살아 있는 스테이지 0, 대기 승인 0)" \
               "라우터가 턴을 잡지 않고 있을 수 있습니다 — 이 스크립트는 아무것도 재개하지 않습니다"
    fi
    cc_notify_fire resume "라우터가 ${age}초 동안 멈춰 있습니다 — 세션을 resume 하고 재개를 지시하세요" || true
    record_blocked "라이브니스 침묵" "메인 세션에서 이어서 진행하도록 지시"
  fi

  settle_stall_arm

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
  # ONE BANNER PER APPROVAL ID, and this used to be one aggregate notice for the
  # whole set, raised into the run-level replace slot. Open approvals are the
  # class with the longest delay by construction — a boundary approval is
  # evaluated on every act, so one opened by a long stage waits out that whole
  # stage, and one of the boundaries carries a dollar figure. Sharing a slot,
  # they went on erasing each other, which is the measured regression this
  # channel exists to end. This site is also the ONLY route a stage-opened
  # approval has: the gate raises those as rows only.
  #
  # The loud terminal line stays aggregate. It is one screen a person reads top
  # to bottom, not a set of slots that overwrite one another.
  #
  # THE REMOTE COPY CARRIES THE GATE'S CANONICAL QUESTION, not this banner's
  # text, which names the id only. Whichever of this site and the gate's own
  # site leaves the approval's event first, the event's body is then the
  # question the router asks. The attachment is made after the id is listed, so
  # an id this pass skips never leaves one behind; a question that could not be
  # read sends none, and the banner goes up as before without an event.
  newly=0
  for id in $(open_approval_ids); do
    grep -qxF "$id" "$RUN_DIR/watch.announced-approvals" 2>/dev/null && continue
    printf '%s\n' "$id" >> "$RUN_DIR/watch.announced-approvals"
    newly=$((newly + 1))
    w_detail=
    w_attach=$(watch_approval_attach_json "$id")
    w_canon=$(printf '%s' "$w_attach" | jq -r '.body // empty' 2>/dev/null || true)
    case "$w_canon" in
      "승인 $id — "*)
        w_detail=$(cc_attention_detail_make "$w_attach") || w_detail=
        ;;
    esac
    CC_NOTIFY_ATTENTION_DETAIL="$w_detail" cc_notify_fire answer "승인 $id 이 답을 기다립니다" "$id" || true
  done
  if [ "$newly" -gt 0 ]; then
    announce "승인 대기 ${pend}건 — 런이 답을 기다립니다" \
             "세션으로 돌아가 답하면 그 자리에서 이어집니다"
  fi

  if [ "$live_w" = "0" ] && [ "$nonterm" = "0" ] && [ "$pend" -gt 0 ] \
     && [ ! -f "$RUN_DIR/watch.announced-waiting" ]; then
    : > "$RUN_DIR/watch.announced-waiting"
    announce "모든 세그먼트가 승인 대기이거나 종단입니다 (대기 승인 ${pend}건)" \
             "런은 막힌 것이 아니라 사람이 손대기 전까지 끝난 것입니다"
    # `answer-run` and not `status`: this is the one banner that asserts the WHOLE
    # run is stopped waiting for a person, and what that person does is answer. It
    # needs a per-run slot rather than a per-approval one, and it needs a slot of
    # its own rather than the lifecycle three's — a run can hold open approvals
    # while it is also stalled or finished, so sharing would let one of those
    # erase this one and leave an instruction that no longer matches the state.
    cc_notify_fire answer-run "런이 사람을 기다립니다 — 대기 중 승인 ${pend}건" || true
  fi

  # A RUN THAT ANCHORED. Without this arm a stall a stage caused reaches a person
  # only through the twenty-minute silence arm above — whose wording tells them
  # to resume the session and instruct the router, while the gate itself refuses
  # to clear the very block that caused it. That is the wrong-instruction defect
  # this channel was built to remove, arriving through the channel that replaced
  # it.
  #
  # THE PREDICATE IS THE CAUSE, NOT A LIST OF REASONS. Two of the conditions that
  # put an unresolved run-scope block in the ledger are conditions this watcher
  # announced itself one line earlier — the after-stage arm and the silence arm
  # each write their observation immediately after raising a banner, and the gate
  # transcribes those with the cause `불명`, which is the only place it writes
  # that value. Keying on the cause therefore excludes "authored by this process"
  # structurally. Enumerating reason strings instead would leave this predicate
  # quietly stale every time an arm is added here, and nothing would show it.
  #
  # `cc_unresolved_blocked` has already dropped anything whose last row resolves
  # it, so "resolvable" and "resolved" stay different things: the first raises a
  # banner and the second does not.
  while IFS=$'\t' read -r cause reason; do
    [ -n "$reason" ] || continue
    [ "$cause" = "불명" ] && continue
    slug=${reason// /-}; slug=${slug//\//-}
    mk="$RUN_DIR/watch.announced-stall-$slug"
    [ -f "$mk" ] && continue
    : > "$mk"
    if [ "$cause" = "무효화" ]; then
      # The gate refuses to resolve this one, so it is not a thing a person can
      # put their hands on — it takes the per-run replace slot, and the title
      # names the only action that is actually available, which is to open a new
      # run rather than to touch this one.
      cc_notify_fire rekick \
        "이 런은 여기서 끝났습니다 — 기준선은 다시 잡히지 않으니 새 런으로 다시 킥오프하세요" || true
    else
      cc_notify_fire hands \
        "런이 정박했습니다 — 아침 보고서의 보류 큐를 보세요 ($reason)" "run-$slug" || true
    fi
  done <<EOF
$ub
EOF

  # THE SIXTH ARM — THE PROGRESS CHANNEL HAS GONE QUIET.
  #
  # The channel reports its own death in-band on four of the five paths it can
  # die on — the harness announces a normal exit, a non-zero exit, a SIGKILL and
  # a timeout, and the router's invariant re-arms on each. `TaskStop` is the
  # fifth and it leaves no signal at all, so that one path needs an observer
  # OUTSIDE the channel. While the lead is idle the only reader awake is this
  # watcher, which is why the count lives here.
  #
  # IT DOES NOT CALL `record_blocked`, AND THAT IS THE POINT. An unresolved
  # run-scope block is an input to the termination condition, so writing one here
  # would make losing the night's COMMENTARY stop the night's WORK from
  # finishing. The channel is a projection of the ledger; the ledger is the run.
  # Confusing the two layers costs more than the outage it reports.
  #
  # DERIVED FROM `--stall`, WITH NO NEW PIN. The lint that keeps the thresholds
  # honest hardcodes exactly four (flag, value) pairs, so a fifth constant would
  # be structurally invisible to it — the one defect that check's own header says
  # it exists to prevent. The channel beats once per `STALL`, and this waits for
  # `2 x STALL`, which is exactly two missed beats. At any other cadence the
  # ratio stops being a whole number of beats and one late beat banners a healthy
  # channel as dead.
  #
  # A RUN WITH NO CHANNEL IS NOT ACCUSED. The heartbeat file exists only once the
  # feed has run, so a night nobody armed one for never reaches this test.
  local feed_hb feed_mt feed_age
  feed_hb="$RUN_DIR/feed.heartbeat"
  feed_age=""
  feed_mt=""
  watch_now_into now
  if [ -f "$feed_hb" ]; then feed_mt=$(file_mtime "$feed_hb"); fi
  [ -n "$feed_mt" ] && feed_age=$(( now - feed_mt ))
  if [ -n "$feed_age" ] && [ "$feed_age" -ge "$(( STALL * 2 ))" ] \
     && done_empty \
     && [ ! -f "$RUN_DIR/watch.announced-feed-silence" ]; then
    : > "$RUN_DIR/watch.announced-feed-silence"
    announce "진행 채널이 ${feed_age}초 동안 아무 박동도 내지 않았습니다" \
             "채널이 죽었을 수 있습니다 — 런은 계속 돕니다. 리드 세션에서 채널을 다시 거세요"
    cc_notify_fire hands \
      "진행 채널이 ${feed_age}초째 조용합니다 — 밤의 해설만 끊긴 것이고 런은 계속 돕니다" "feed" || true
  fi

  # A SEPARATE LINE, NOT A FIFTH HEARTBEAT FIELD. The four above are read out of
  # this file by name and their positions are part of that contract; this alarm
  # is also not a periodic measurement but a condition that is either there or
  # not. It is emitted only when it holds, so a night with none of these is a
  # night with none of these lines — which is what makes the one night that has
  # it legible.
  #
  # What it names is a dispatch whose record outlived its process: the stage's
  # outcome was never written, and no other surface says so. The dispatching
  # shift ends normally and its own stream carries a terminal line, so without
  # this the run's account of itself is a shift that finished and a stage that
  # never existed.
  #
  # THE WORDING SAYS ONLY WHAT THE PREDICATE KNOWS. The earlier tail — "look at
  # the dispatch mode, not the stage" — named one cause, and it was wrong on a
  # measured case (a stage killed by an account limit under a perfectly normal
  # dispatch). With the supervisor detached from the routing session the
  # dispatch mode can no longer produce an orphan at all, so that sentence
  # would point at a removed cause. What remains true: the record outlived the
  # process, no result was recorded, and a surviving orphan means the SUPERVISOR
  # died too — a machine-level event, listed without choosing among its
  # branches. The settlement token `외부 종료` is spelled out so a person who
  # saw the banner at 3am has the string to grep the ledger for at 9.
  local orphans at
  orphans=$( { cc_orphan_stages "$RUN_DIR" || true; } )
  orphans=${orphans//$'\n'/ }
  if [ -n "$orphans" ]; then
    watch_iso_into at
    printf '%s [watch] 잃어버린 파견 — %s · 파견 기록이 남았는데 그 프로세스가 없습니다. 스테이지 결과가 기록되지 않았습니다 — 원인은 이 술어의 입력에 없습니다. 감독자까지 사라졌다는 뜻이므로 기계 재부팅·절전·OOM, 사람이 보낸 종료가 감독자에 닿은 것, 또는 정산이 도중에 멈춘 것일 수 있습니다. 다음 게이트 호출이 이를 `외부 종료` 로 정산합니다\n' \
      "$at" "$orphans"
  fi

  # THE NEXT MOMENT A TIME-BASED ARM CAN FIRE, for the probe cycles of a quiet
  # run (the main loop runs a full pass once the memory clock reaches it). Each
  # arm offers the time its clock conditions would all hold — the latest of its
  # thresholds — when the conditions that are not about time hold now; a time
  # already past offers nothing, so an arm that fired or cannot fire does not
  # keep forcing full passes. The offers err early, never late: an early full
  # pass costs one pass, a late one delays a banner.
  local t sx=""
  watch_now_into now
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] && [ "$nonterm" -ge 1 ] 2>/dev/null \
     && [ ! -f "$RUN_DIR/watch.announced-after-stage" ] && done_empty; then
    case "$grew" in ''|*[!0-9]*) t=$((now - age + AFTER_STAGE)) ;; *) t=$((grew + AFTER_STAGE)) ;; esac
    if [ -f "$RUN_DIR/shift.in-progress" ]; then
      { IFS= read -r sx; } 2>/dev/null < "$RUN_DIR/shift.in-progress" || :
      sx=${sx//[!0123456789]/}
      if [ -n "$sx" ] && [ "$sx" -gt "$t" ] 2>/dev/null; then t=$sx; fi
    fi
    watch_expiry_offer "$t"
  fi
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] && [ -n "$run_age" ] && [ -n "$gate_idle" ] \
     && [ ! -f "$RUN_DIR/watch.announced-run-open" ]; then
    t=$((now - age + AFTER_STAGE))
    [ $((now - run_age + RUN_OPEN)) -le "$t" ] || t=$((now - run_age + RUN_OPEN))
    [ $((now - gate_idle + AFTER_STAGE)) -le "$t" ] || t=$((now - gate_idle + AFTER_STAGE))
    watch_expiry_offer "$t"
  fi
  if [ "$live_w" = "0" ] && [ "$pend" = "0" ] && [ -n "$quiet" ] && [ "$relay_eff" = "0" ]; then
    watch_expiry_offer $((now - quiet + thr))
  fi
  if [ -n "$feed_mt" ] && [ ! -f "$RUN_DIR/watch.announced-feed-silence" ]; then
    watch_expiry_offer $((feed_mt + STALL * 2))
  fi

  # QUIET OR WORKING, decided once per full pass by the shared predicate on the
  # counts this pass already read, and kept for the main loop and `watch.mode`.
  W_QUIET=0
  if cc_run_quiet "$RUN_DIR" "$LEDGER" "$live_w" "$pend" "$halts" "$age" "$STALL"; then
    W_QUIET=1
  fi
  WATCH_EXPIRY=$expiry
  # The probe's reference, touched after this pass's last write to the run
  # directory, so nothing this pass wrote reads as new on the next cycle.
  if [ -d "$RUN_DIR" ]; then : > "$RUN_DIR/.watch.fullpass"; fi
  return 0
}

watch_expiry_offer() {
  # watch_expiry_offer <epoch> — lowers the calling pass's `expiry` to <epoch>
  # when <epoch> is still ahead of the memory clock.
  local t="${1:-}" n
  case "$t" in ''|*[!0-9]*) return 0 ;; esac
  watch_now_into n
  [ "$t" -gt "$n" ] || return 0
  if [ -z "${expiry:-}" ] || [ "$t" -lt "$expiry" ]; then expiry=$t; fi
  return 0
}

# THE PROBE SET: every run-directory name a full pass judges on that is not one
# of the three resident scripts' own writes, plus the ledger (`LEDGER`). On a
# quiet run a cycle between two full passes compares each member against
# `.watch.fullpass` with `-nt` and runs a full pass when any is newer — builtins
# and globs, no fork. A trailing `/` names a directory, whose mtime moves when a
# record is added to it or renamed into it. The run directory's own mtime is
# not a member: the watcher's own writes move it every cycle. `watch.pid` and
# `checks.pid` match `*.pid` and are passed over by name, because the watcher and
# `checks.sh` rewrite them every cycle. `routing-guard` and `checks.observed`
# are not members: only a relay path reads them, and a live relay already makes
# the run a working one.
WATCH_PROBES='LEDGER halt/ halt/shift/ started-at done ends-on-done shift.live relay.live *.pid *.sup *.waiting *.sup.start *.pid.settling* apply/*.launch apply/*.sup apply/*.sup.start apply/*.sup.self apply/*.sup.self.start'
read -r -a WATCH_PROBE_LIST <<< "$WATCH_PROBES"

watch_probe_changed() {
  # rc 0 when some member of the probe set is newer than `.watch.fullpass`, or
  # when there is no such reference yet; rc 1 when nothing is.
  local mark="$RUN_DIR/.watch.fullpass" p f
  [ -f "$mark" ] || return 0
  for p in "${WATCH_PROBE_LIST[@]}"; do
    case "$p" in
      LEDGER)
        if [ "$LEDGER" -nt "$mark" ]; then return 0; fi ;;
      *'*'*)
        for f in "$RUN_DIR"/$p; do
          case "${f##*/}" in watch.pid|checks.pid) continue ;; esac
          if [ "$f" -nt "$mark" ]; then return 0; fi
        done ;;
      *)
        if [ "$RUN_DIR/$p" -nt "$mark" ]; then return 0; fi ;;
    esac
  done
  return 1
}

watch_mode_write() {
  # One line, `quiet <epoch>` or `work <epoch>`, rewritten every cycle: the full
  # pass's verdict, or on a probe cycle the last one, stamped with this cycle's
  # memory clock. `checks.sh` and `feed.sh` read it, and read a missing, unreadable
  # or stale line as a working run.
  local now m=work
  [ -d "$RUN_DIR" ] || return 0
  [ "$W_QUIET" = 1 ] && m=quiet
  watch_now_into now
  { printf '%s %s\n' "$m" "$now" > "$RUN_DIR/watch.mode"; } 2>/dev/null || :
}

run_is_over() {
  # The ways this watcher's job ends. None is a judgment of its own — one is a
  # fact the gate records, one is the run's own directory going away, and the
  # third is the shared idle predicate in `liveness.sh`.
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
    # THE THIRD EXIT: A RUN THAT WAITS FOR NOBODY. Nothing alive, no approval,
    # no unanswered halt record, and a ledger that has not grown for the shared
    # threshold. It is the shared predicate with the shared threshold — this
    # file declares no value of its own — and it writes no `done`: the run stays
    # open, and the seat starts a watcher again when it next launches a shift.
    if cc_run_idle_exit "$RUN_DIR" "" "$LEDGER" "${WATCH_STARTED:-}"; then
      printf '%s [watch] 유휴 %s초 — 살아 있는 교대·스테이지도, 열린 승인도, 답 없는 정지 기록도 없고 원장이 그동안 자라지 않아 감시를 멈춥니다. 런은 열린 채 남습니다 — 닫으려면 게이트의 end-abandoned 동사를 씁니다\n' \
        "$(now_iso)" "$CC_RUN_IDLE_EXIT_SECONDS"
      return 0
    fi
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

# The memory a probe cycle publishes from and the main loop decides on, filled
# by each full pass. The first cycle is always a full pass, so none of these is
# read before a pass has written it.
W_AGE=0; W_LIVE=0; W_PEND=0; W_NONTERM=0; W_SIZE=0; W_GREW=""
W_FO_AT=""; W_FO_LAST=""; W_FO_PREV=""; W_FO_HELD=""
W_QUIET=0; WATCH_EXPIRY=""; WATCH_STALL_LAST=""

if [ "$ONCE" = "1" ]; then
  pass
  watch_mode_write
  exit 0
fi

wait_ended_fired() {
  # wait_ended_fired — when some process holds the run's `ended` claim, wait up
  # to `INTERVAL` seconds for its `fired` mark. `rekick` shares the run's slot
  # with `ended` and the later banner replaces the earlier, so a `rekick` raised
  # while the claimant is still raising would be covered by the `ended` it was
  # meant to follow. Bounded, because a claimant that died before firing must
  # not hold this watcher open.
  local i=0
  [ -d "$RUN_DIR/notify.ended" ] || return 0
  while [ ! -f "$RUN_DIR/notify.ended/fired" ] && [ "$i" -lt "${INTERVAL%.*}" ]; do
    sleep 1
    i=$((i + 1))
  done
  return 0
}

# WORKING AND QUIET CYCLES. A working run gets a full pass every cycle, as it
# always did. A quiet one (`cc_run_quiet`, decided by each full pass) gets one
# every `CC_QUIET_PASS_EVERY` cycles, and between them a probe cycle — the
# watcher's own marks, the heartbeat from the last full pass's values, the
# host-load sample and the failover clock — unless the probe set shows
# something newer than the last full pass, or the memory clock has reached the
# next moment a time-based arm can fire, or the run directory is not there;
# any of those makes the cycle a full one. The first cycle is always full.
# `run_is_over` runs on full cycles only: its exits are a `done` the loop
# already reads every cycle, a directory that went away, and an idle threshold
# of a day.
watch_cycle=0
watch_since_full=0
while :; do
  # `done` IS JUDGED FIRST, AND WHILE IT IS ON DISK NO PASS RUNS. On a run that
  # ends on `done`, a shift can still be settling after `done` is written, and
  # several arms of `pass` carry no `done` condition — a boundary's `done` can
  # leave a live stage, an open approval or a non-terminal segment behind, and
  # those arms would speak over a run that has ended. The tail's silence is a
  # property of this branch rather than of a guard on every arm.
  #
  # THE TAIL ENDS WHEN THE SETTLEMENT IS OVER, OR WHEN `done` IS `STALL` OLD.
  # The first is the gate's own moment, and its shift-return site raises `ended`
  # there; this branch then raises nothing, because the claim is taken. The
  # second is for a shift that never returns: a person who never gets the
  # banner is worse off than one who gets it while a hung shift is still alive.
  # On a run without the marker the settlement is over the moment `done`
  # exists, so this exits when it always did.
  if [ -f "$RUN_DIR/done" ]; then
    # The directory has been seen, so a later disappearance ends the loop at
    # once rather than waiting out the startup bound.
    RUN_DIR_SEEN=1
    done_mt=$(file_mtime "$RUN_DIR/done")
    watch_now_into watch_now
    if cc_run_end_settled "$RUN_DIR" \
       || { [ -n "$done_mt" ] && [ $(( watch_now - done_mt )) -ge "$STALL" ]; }; then
      announce "런이 종단했습니다 — 감시를 멈춥니다" "$(cat "$RUN_DIR/done" 2>/dev/null || printf '종단 표시 있음')"
      # A BACKSTOP, NOT THE OWNER. The gate's sites take the claim first in the
      # ordinary case and this raises nothing then; it speaks when no gate site
      # reached the run — a stage's boundary, or a shift still alive at `STALL`.
      # The sentence comes from `done` as the gate's does.
      cc_notify_ended_once "$(cc_notify_ended_text "$RUN_DIR")" || true
      # NARROWED TO THE CASE THE PASS-SIDE ARM CANNOT REACH, which is what earns
      # this arm its place rather than duplicating one that already exists.
      #
      # The pass-side terminal arm keys on the shared run-state predicate, and
      # that predicate requires zero unresolved run-scope blocks — so a run
      # invalidated by a forced surface move never returns `종단` and that arm is
      # silent for it forever. This path reads only the marker file the gate
      # writes, so for such a run it is the only channel there is. A run that
      # ended with no unresolved block has had its `ended` already, from the gate
      # or from the line above, and gets nothing more here.
      #
      # ITS OWN MARKER, never the terminal claim. Sharing would let whichever
      # fired first silence the other, and a silenced arm cannot be told apart in
      # the log from one that fired exactly once.
      if [ "$(cc_unresolved_blocked "$LEDGER" | grep -c . || true)" != "0" ] \
         && [ ! -f "$RUN_DIR/watch.announced-loop-exit" ]; then
        : > "$RUN_DIR/watch.announced-loop-exit"
        wait_ended_fired
        cc_notify_fire rekick \
          "이 런은 여기서 끝났습니다 — 기준선은 다시 잡히지 않으니 새 런으로 다시 킥오프하세요" || true
      fi
      exit 0
    fi
    beat
    watch_mode_write
    sleep "$INTERVAL"
    continue
  fi
  watch_full=1
  if [ "$watch_cycle" -gt 0 ] && [ "$W_QUIET" = 1 ] && [ -d "$RUN_DIR" ] \
     && [ "$watch_since_full" -lt $((CC_QUIET_PASS_EVERY - 1)) ]; then
    watch_full=0
    watch_now_into watch_now
    if [ -n "$WATCH_EXPIRY" ] && [ "$watch_now" -ge "$WATCH_EXPIRY" ]; then
      watch_full=1
    elif watch_probe_changed; then
      watch_full=1
    fi
  fi
  watch_cycle=$((watch_cycle + 1))
  if [ "$watch_full" = 1 ]; then
    # The directory went away, or never appeared.
    if run_is_over; then
      exit 0
    fi
    pass
    watch_since_full=0
  else
    probe_beat
    watch_since_full=$((watch_since_full + 1))
  fi
  watch_mode_write
  sleep "$INTERVAL"
done
