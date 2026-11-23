#!/usr/bin/env bash
# Test scripts/wait-fixture.sh — the shared wait helpers the suites build on.
#
# Five assertions, one per promise:
#   (1) `wait_until` returns 0 at once when the condition already holds.
#   (2) Under `CC_TEST_WAIT_CEILING=2`, `wait_until false` returns 1 and writes
#       the one diagnostic line naming the ceiling.
#   (3) A holder started by a child shell that sourced the file with
#       `WAIT_FIXTURE_OWNER` unset ends by itself once that shell is gone, so no
#       holder is left behind as an orphan.
#   (4) `wait_pid_gone` on a pid that has already exited returns 0 at once.
#   (5) A holder sent `kill` is gone within `wait_pid_gone`.
#
# Nothing here measures how long a step took: every wait goes through the
# helpers under test, and a helper that hangs fails at the ceiling.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=wait-fixture.sh
. "$repo_root/scripts/wait-fixture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-wait-fixture.XXXXXX")
KILL_LIST=""
cleanup() {
  local p
  for p in $KILL_LIST; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

passed=0
failures=0

pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

# --- (1) a condition that already holds -----------------------------------
rc=0
wait_until true 2>"$WORK/1.err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$WORK/1.err" ]; then
  pass "(1) 이미 선 조건에 wait_until 은 0 이다"
else
  fail "(1) 이미 선 조건에 wait_until 은 0 이다 — rc=$rc, 오류=$(cat "$WORK/1.err")"
fi

# --- (2) the ceiling ------------------------------------------------------
rc=0
CC_TEST_WAIT_CEILING=2 wait_until false 2>"$WORK/2.err" || rc=$?
first=$(head -n 1 "$WORK/2.err")
lines=$(wc -l < "$WORK/2.err" | tr -d ' ')
case "$first" in
  "wait_until: 상한 2초"*) diag=yes ;;
  *) diag=no ;;
esac
if [ "$rc" -eq 1 ] && [ "$diag" = yes ] && [ "$lines" = 1 ]; then
  pass "(2) 상한을 넘긴 wait_until 은 1 과 진단 한 줄이다"
else
  fail "(2) 상한을 넘긴 wait_until 은 1 과 진단 한 줄이다 — rc=$rc, 줄 수=$lines, 첫 줄=$first"
fi

# --- (3) a holder outlives no owner ---------------------------------------
# The child shell is the owner: the variable is unset in its environment, so
# its own `$$` is what the holder watches. The holder's streams go to /dev/null
# so the command substitution returns when the child shell ends, not when the
# holder does.
orphan=$(env -u WAIT_FIXTURE_OWNER -u WAIT_FIXTURE_LOADED bash -c \
  '. "$1/scripts/wait-fixture.sh"; wait_holder </dev/null >/dev/null 2>&1 & echo $!' _ "$repo_root")
case "$orphan" in
  ''|*[!0-9]*)
    fail "(3) 소유자 셸이 끝나면 보유자도 끝난다 — 보유자 pid 를 받지 못했다: '$orphan'" ;;
  *)
    KILL_LIST="$KILL_LIST $orphan"
    if wait_pid_gone "$orphan"; then
      pass "(3) 소유자 셸이 끝나면 보유자도 끝난다"
    else
      fail "(3) 소유자 셸이 끝나면 보유자도 끝난다 — pid $orphan 이 남았다"
    fi ;;
esac

# --- (4) a pid that has already exited ------------------------------------
true &
dead=$!
wait "$dead" 2>/dev/null || true
rc=0
wait_pid_gone "$dead" 2>"$WORK/4.err" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$WORK/4.err" ]; then
  pass "(4) 이미 죽은 pid 의 wait_pid_gone 은 0 이다"
else
  fail "(4) 이미 죽은 pid 의 wait_pid_gone 은 0 이다 — rc=$rc, 오류=$(cat "$WORK/4.err")"
fi

# --- (5) a killed holder --------------------------------------------------
wait_holder &
holder=$!
KILL_LIST="$KILL_LIST $holder"
if ! kill -0 "$holder" 2>/dev/null; then
  fail "(5) kill 을 받은 보유자는 사라진다 — 보유자가 kill 전에 이미 없다"
else
  kill "$holder" 2>/dev/null || true
  if wait_pid_gone "$holder"; then
    pass "(5) kill 을 받은 보유자는 사라진다"
  else
    fail "(5) kill 을 받은 보유자는 사라진다 — pid $holder 이 남았다"
  fi
fi

echo
echo "test-wait-fixture: $passed passed, $failures failed"
[ "$failures" -eq 0 ]
