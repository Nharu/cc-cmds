#!/usr/bin/env bash
# wait-fixture.sh — the one way a test waits for something to happen.
#
# WHY A SHARED FILE. A test that picks its own number of seconds — a `for i in
# $(seq 1 50)` poll, a window `[ $((t1 - t0)) -le 10 ]`, a `sleep 600 &` stub
# that must outlive the assertions — passes on a quiet host and fails on a busy
# one, and every such failure is then "fixed" by raising that number. Here the
# only number is the shared ceiling `CC_TEST_WAIT_CEILING` (default 120
# seconds): a wait ends as soon as its condition holds, and the ceiling is paid
# only by a regression. A negative control lowers it with the one variable.
#
#   wait_until <command> [args...]
#       Calls the command every 0.1 s; returns 0 as soon as it returns 0.
#       When the ceiling passes first, writes one line to standard error,
#       `wait_until: 상한 <N>초 안에 조건이 서지 않았다 — <command>`, and
#       returns 1. There is no per-call seconds argument.
#   wait_pid_gone <pid>
#       Waits with `wait_until` until <pid> no longer exists, then reaps it with
#       `wait` when it is this shell's child. Returns 1 at the ceiling.
#   wait_holder
#       The body of a background holder, used as `wait_holder & pid=$!`. It
#       lives while `WAIT_FIXTURE_OWNER` is alive, checking once a second, and
#       ends by itself when that shell is gone; a `kill` ends it at once. It
#       keeps the standard streams it was started with, so a holder started
#       inside a command substitution holds that pipe open until it ends —
#       redirect it there (`wait_holder >/dev/null 2>&1 &`). Register the pid
#       in the suite's own cleanup list (`FX_PIDS`, `TR_PIDS`, ...) as well.
#
# WAIT_FIXTURE_OWNER is the `$$` of the first shell that sources this file,
# exported, so a child bash that sources it again inherits the top test shell
# as the owner rather than itself.
#
# This file is sourced, not executed. It defines functions and changes no shell
# option.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

if [ -z "${WAIT_FIXTURE_LOADED:-}" ]; then
WAIT_FIXTURE_LOADED=1

: "${WAIT_FIXTURE_OWNER:=$$}"
export WAIT_FIXTURE_OWNER

wait_until() {
  local ceil="${CC_TEST_WAIT_CEILING:-120}" start
  start=$(date +%s)
  while :; do
    if "$@"; then
      return 0
    fi
    # The one wall-clock comparison of the suites: it judges nothing, it only
    # ends a wait that would otherwise never end.
    if [ "$(date +%s)" -ge $(( start + ceil )) ]; then
      printf 'wait_until: 상한 %s초 안에 조건이 서지 않았다 — %s\n' "$ceil" "$*" >&2
      return 1
    fi
    sleep 0.1
  done
}

_wait_fixture_gone() {
  ! kill -0 "$1" 2>/dev/null
}

wait_pid_gone() {
  wait_until _wait_fixture_gone "$1" || return 1
  wait "$1" 2>/dev/null || true
  return 0
}

wait_holder() {
  while kill -0 "$WAIT_FIXTURE_OWNER" 2>/dev/null; do
    sleep 1
  done
}

fi
