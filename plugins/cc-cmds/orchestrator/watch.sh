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
LC_TIME=C
export LC_TIME

RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1200; ONCE=0; NOTIFY=0; AFTER_STAGE=120
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --after-stage) AFTER_STAGE="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    --notify)   NOTIFY=1; shift ;;
    *) printf 'watch: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ] || { printf 'watch: --run-dir 는 필수입니다\n' >&2; exit 2; }
[ -n "$LEDGER" ]  || { printf 'watch: --ledger 는 필수입니다\n' >&2; exit 2; }

now_epoch() { date +%s; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

ledger_size() { wc -c < "$1" 2>/dev/null | tr -d ' ' || printf '0'; }

ledger_idle_seconds() {
  # SIZE, not mtime. `stat` takes a different flag on each platform, and the
  # portable alternative is better here anyway: the ledger is append-only, so
  # its size strictly increases when it grows — while an mtime can move without
  # a byte changing, and a restored file can carry an old one.
  #
  # The watcher owns the clock rather than the filesystem: it remembers the last
  # size it saw and when it first saw it, which also makes `--once` work across
  # invocations instead of always reporting zero.
  local size prev_size prev_at now
  size=$(ledger_size "$LEDGER")
  now=$(now_epoch)
  prev_size=$(sed -n '1p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  prev_at=$(sed -n '2p' "$RUN_DIR/watch.state" 2>/dev/null || true)
  if [ -z "$prev_size" ] || [ "$size" != "$prev_size" ]; then
    printf '%s\n%s\n' "$size" "$now" > "$RUN_DIR/watch.state"
    printf '0'
    return 0
  fi
  printf '%s' $(( now - prev_at ))
}

proc_fingerprint() {
  # pid + start time. The pair, not the pid — see the header.
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//'
}

live_stages() {
  local f pid rec now n=0
  for f in "$RUN_DIR"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    rec=$(cat "${f%.pid}.start" 2>/dev/null || true)
    if [ -n "$rec" ]; then
      now=$(proc_fingerprint "$pid")
      # A recorded start time that no longer matches means the pid was reused.
      # Counting it would report a stage that is not there.
      [ "$rec" = "$now" ] || continue
    fi
    n=$((n + 1))
  done
  printf '%s' "$n"
}

open_approvals() {
  local id st n=0
  for id in $( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null || true; } \
               | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { grep -E '^- `승인`' "$LEDGER" 2>/dev/null | grep -F "승인 id=$id " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "대기" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

nonterminal_segments() {
  local sid st n=0
  for sid in $( { grep -E '^- `segment`' "$LEDGER" 2>/dev/null || true; } \
                | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    st=$( { grep -E '^- `segment`' "$LEDGER" 2>/dev/null | grep -F "id=$sid " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    case "$st" in 머지됨|park) ;; *) n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

banner() {
  # Best-effort, and every failure is swallowed on purpose: a watcher that dies
  # because a notifier is missing removes the only signal the user had left.
  [ "$NOTIFY" = "1" ] || return 0
  [ "$(uname -s)" = "Darwin" ] || return 0
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  command -v terminal-notifier >/dev/null 2>&1 || return 0
  { terminal-notifier -title "[cc-cmds] 자율 런" -message "$1" \
      -group 'cc-cmds-autopilot-watch' -execute ':' 2>/dev/null || true; }
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
  local age live pend nonterm
  age=$(ledger_idle_seconds)
  live=$(live_stages)
  pend=$(open_approvals)
  nonterm=$(nonterminal_segments)

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
  if [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$AFTER_STAGE" ] \
     && [ -z "$(cat "$RUN_DIR/done" 2>/dev/null || true)" ] \
     && [ "$( { grep -E '^- `' "$LEDGER" 2>/dev/null || true; } | tail -1 \
             | grep -cE '^- `(stage-result|cost)`' || true)" != "0" ] \
     && ! grep -q '스테이지 종단 후 라우터 무응답' "$RUN_DIR/stall" 2>/dev/null; then
    announce "스테이지가 끝났는데 라우터가 ${age}초 동안 아무것도 하지 않았습니다" \
             "그 스테이지를 깨울 통지가 없는 형태로 띄웠을 수 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    banner "스테이지가 끝났는데 런이 이어지지 않습니다 (${age}초)"
    record_blocked "스테이지 종단 후 라우터 무응답" "메인 세션에서 이어서 진행하도록 지시"
    return 0
  fi

  # Announce a condition ONCE. Re-announcing on every pass turns the loud line
  # into noise, and the row it writes would itself grow the ledger — which resets
  # the very idleness being measured, so the watcher would alternate between
  # firing and heartbeating forever.
  if [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$STALL" ] \
     && ! grep -q '라이브니스 침묵' "$RUN_DIR/stall" 2>/dev/null \
     && ! grep -q '사유=라이브니스 침묵' "$LEDGER" 2>/dev/null; then
    announce "런이 ${age}초 동안 아무것도 쓰지 않았습니다 (살아 있는 스테이지 0, 대기 승인 0)" \
             "라우터가 턴을 잡지 않고 있을 수 있습니다 — 이 스크립트는 아무것도 재개하지 않습니다"
    banner "라우터가 ${age}초 동안 멈춰 있습니다 — 세션을 resume 하고 재개를 지시하세요"
    record_blocked "라이브니스 침묵" "메인 세션에서 이어서 진행하도록 지시"
    return 0
  fi

  if [ "$live" = "0" ] && [ "$nonterm" = "0" ] && [ "$pend" -gt 0 ] \
     && [ ! -f "$RUN_DIR/watch.announced-waiting" ]; then
    : > "$RUN_DIR/watch.announced-waiting"
    announce "모든 세그먼트가 승인 대기이거나 종단입니다 (대기 승인 ${pend}건)" \
             "런은 막힌 것이 아니라 사람이 손대기 전까지 끝난 것입니다"
    banner "런이 사람을 기다립니다 — 대기 중 승인 ${pend}건"
    return 0
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
  printf '%s 원장 %s초 전 갱신 · 스테이지 %s개 · 대기 승인 %s건 · 비종단 세그먼트 %s개\n' \
    "$(now_iso)" "$age" "$live" "$pend" "$nonterm" > "$RUN_DIR/watch.heartbeat"
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
  [ -d "$RUN_DIR" ] || return 0
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
