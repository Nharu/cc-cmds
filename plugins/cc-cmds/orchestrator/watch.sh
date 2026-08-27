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
#
# Exit codes:
#   0  a pass completed (or the loop was terminated)
#   2  invalid invocation
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile, no `wait -n`.

set -uo pipefail
LC_TIME=C
export LC_TIME

RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1200; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
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
  # watch.sh is not the ledger's writer in the general case — the gate is. This
  # one row is the exception the design names, and it is scoped `run` because
  # what it reports is a property of the run rather than of any act.
  printf -- '- `blocked` | 대상=- | 스코프=run | 원인=불명 | 사유=%s | 관측=%s | 재개 명령=%s\n' \
    "$1" "$(now_iso)" "$2" >> "$LEDGER"
}

pass() {
  local age live pend nonterm
  age=$(ledger_idle_seconds)
  live=$(live_stages)
  pend=$(open_approvals)
  nonterm=$(nonterminal_segments)

  # Announce a condition ONCE. Re-announcing on every pass turns the loud line
  # into noise, and the row it writes would itself grow the ledger — which resets
  # the very idleness being measured, so the watcher would alternate between
  # firing and heartbeating forever.
  if [ "$live" = "0" ] && [ "$pend" = "0" ] && [ "$age" -ge "$STALL" ] \
     && ! grep -q '사유=라이브니스 침묵' "$LEDGER" 2>/dev/null; then
    announce "런이 ${age}초 동안 아무것도 쓰지 않았습니다 (살아 있는 스테이지 0, 대기 승인 0)" \
             "라우터가 턴을 잡지 않고 있을 수 있습니다 — 이 스크립트는 아무것도 재개하지 않습니다"
    record_blocked "라이브니스 침묵" "메인 세션에서 이어서 진행하도록 지시"
    return 0
  fi

  if [ "$live" = "0" ] && [ "$nonterm" = "0" ] && [ "$pend" -gt 0 ] \
     && [ ! -f "$RUN_DIR/watch.announced-waiting" ]; then
    : > "$RUN_DIR/watch.announced-waiting"
    announce "모든 세그먼트가 승인 대기이거나 종단입니다 (대기 승인 ${pend}건)" \
             "런은 막힌 것이 아니라 사람이 손대기 전까지 끝난 것입니다"
    return 0
  fi

  # Positive heartbeat. Says the watcher is alive, which is what makes its
  # silence mean something.
  printf '%s [watch] 살아 있음 — 원장 %s초 전 갱신, 스테이지 %s개, 대기 승인 %s건, 비종단 세그먼트 %s개\n' \
    "$(now_iso)" "$age" "$live" "$pend" "$nonterm"
  return 0
}

if [ "$ONCE" = "1" ]; then
  pass
  exit 0
fi

while :; do
  pass
  sleep "$INTERVAL"
done
