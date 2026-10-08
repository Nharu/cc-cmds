#!/usr/bin/env bash
# Test plugins/cc-cmds/orchestrator/notify-focus.sh — the banner click handler,
# the two helpers that build the value a banner carries, and the background
# resolution (prime) that makes a click fast.
#
# TWO SUITES. The stub suite replaces tmux, the iTerm2 calls, the AX helper and
# `open` through the handler's own seams and runs anywhere: every stub appends
# what it was asked to ONE ordered log, so an assertion reads the order of the
# calls as well as their presence. The real-server suite starts a private tmux
# server under /tmp and drives the handler against it; everything else stays a
# stub there too.
#
# WHAT THE REAL-SERVER SUITE DOES NOT PROVE. Its normal-mode leg attaches
# ordinary clients from another private server, and its control-mode leg feeds a
# control client from a pipe. Neither is iTerm2's tmux integration, so a pass
# here says nothing about the variables iTerm2 exposes in a user's control-mode
# environment — only that tmux selects what the handler asks it to.
#
# EVERY CLICK RUNS THE WAY A BANNER RUNS IT: the value under `/bin/sh -c` with
# an emptied environment, because the click process inherits nothing from
# whoever raised the banner. Each leg asserts exit status 0 and zero bytes on
# both streams before anything else. The clicks run in the foreground
# (`CC_CMDS_NOTIFY_FOCUS_FOREGROUND=1`) so the order of the log is the order of
# the click; L12 is the one leg that lets the handler detach.
#
# NOTHING HERE REACHES THE MACHINE. The cache root is under the work directory,
# primes are off unless a leg turns them on, and every seam a click needs is in
# the emptied environment `click()` builds — the top-level exports reach only
# the paths that inherit this shell's environment.
#
# When tmux is absent or a private server cannot be started, the real-server
# suite fails under CI and otherwise prints one `SKIP: <reason>` line.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
# Called through a spelling with `..` in it, so the canonical form the value
# carries is something the handler computed rather than what it was given.
H_CALL="$ORCH/../orchestrator/notify-focus.sh"

passed=0
failed=0
# The failures again at the end, where a long run's output is still on screen.
FAILS=""
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  {
  failed=$((failed + 1))
  printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2
  FAILS="$FAILS  $1 — ${2:-}
"
}
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if [ ! -f "$ORCH/notify-focus.sh" ]; then
  bad "처리기 스크립트" "$ORCH/notify-focus.sh 가 없다"
  printf 'test-notify-focus: %s passed, %s failed\n' "$passed" "$failed"
  exit 1
fi
H="$(cd "$ORCH" && pwd -P)/notify-focus.sh"

# Resolved once from the PATH this suite was started with, before anything
# below can put a stub in front of it.
REAL_TMUX=$(command -v tmux 2>/dev/null || true)

unset TMUX TMUX_PANE
unset CC_CMDS_NOTIFY_FOCUS_TRACE CC_CMDS_NOTIFY_FOCUS_ITERM CC_CMDS_NOTIFY_FOCUS_ITERM_Q \
  CC_CMDS_NOTIFY_FOCUS_AX CC_CMDS_NOTIFY_FOCUS_FOREGROUND CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-notify-focus.XXXXXX")
# Every path that inherits this shell — `value()`, `exec_arg`, `record` — starts
# no prime and writes no cache outside the work directory.
export CC_CMDS_NOTIFY_FOCUS_PRIME=off
export CC_CMDS_NOTIFY_FOCUS_CACHE="$WORK/cache"
S=""
TAIL_PID_FILE=""
cleanup() {
  if [ -n "$S" ] && [ -n "$REAL_TMUX" ]; then
    "$REAL_TMUX" -S "$S/o" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -S "$S/s" kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "$TAIL_PID_FILE" ] && [ -f "$TAIL_PID_FILE" ]; then
    kill "$(cat "$TAIL_PID_FILE")" >/dev/null 2>&1 || true
  fi
  if [ -n "$S" ]; then
    rm -f "$S/s" "$S/o"
    rm -rf "$S"
  fi
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin"
LOG="$WORK/calls.log"

# tmux stub. `-S <socket>` is dropped; the two queries are logged by name and
# the two selections with their arguments, which is what the order assertions
# read. STUB_RC_<COMMAND> sets the exit status per subcommand.
cat > "$WORK/bin/tmux" <<'STUB'
#!/bin/bash
[ "${1:-}" = "-S" ] && shift 2
cmd=${1:-}
case "$cmd" in
  display-message|list-clients) printf '%s\n' "$cmd" >> "$STUB_LOG" ;;
  *) printf '%s\n' "$*" >> "$STUB_LOG" ;;
esac
v=STUB_RC_$(printf '%s' "$cmd" | tr 'a-z-' 'A-Z_')
eval "rc=\${$v:-0}"
case "$cmd" in
  display-message) [ "$rc" = 0 ] && printf '%s\n' "${STUB_DISPLAY:-}" ;;
  list-clients) [ "$rc" = 0 ] && [ -n "${STUB_CLIENTS:-}" ] && printf '%s\n' "$STUB_CLIENTS" ;;
esac
exit "$rc"
STUB

# A per-verb sequence: STUB_SEQ_<VERB>="4 0" answers 4 on the first call and 0
# on the second; past its end, and without one, STUB_RC_<VERB> answers.
cat > "$WORK/bin/seq.sh" <<'STUB'
seq_rc() {
  local verb=$1 up seq n f w
  up=$(printf '%s' "$verb" | tr 'a-z-' 'A-Z_')
  eval "seq=\${STUB_SEQ_$up:-}"
  eval "rc=\${STUB_RC_$up:-0}"
  [ -n "$seq" ] || return 0
  f="$STUB_LOG.seq.$verb"
  n=$(cat "$f" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$f"
  set -- $seq
  if [ "$n" -le $# ]; then
    eval "w=\${$n}"
    rc=$w
  fi
}
STUB

# iTerm2 stub: `find` prints the dump, `show <wid> <sid> [w]` is logged and
# answers; STUB_SEQ_SHOW / STUB_RC_SHOW make it fail as a moved session does,
# STUB_SHOW_ERR replaces the error text it fails with, and STUB_SLEEP_SHOW
# holds the answer back as a slow AppleScript selection does.
cat > "$WORK/bin/iterm" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/seq.sh"
case "${1:-}" in
  find)
    printf 'find\n' >> "$STUB_LOG"
    [ -n "${STUB_SLEEP_FIND:-}" ] && sleep "$STUB_SLEEP_FIND"
    [ -n "${STUB_DUMP:-}" ] && printf '%s\n' "$STUB_DUMP"
    exit "${STUB_RC_FIND:-0}"
    ;;
  show)
    shift
    printf 'show %s\n' "$*" >> "$STUB_LOG"
    [ -n "${STUB_SLEEP_SHOW:-}" ] && sleep "$STUB_SLEEP_SHOW"
    seq_rc show
    if [ "$rc" != 0 ]; then
      printf '%s\n' "${STUB_SHOW_ERR:-execution error: session not found (-2700)}" >&2
      exit "$rc"
    fi
    printf 'ok\n'
    ;;
esac
exit 0
STUB

# AX helper stub: every verb is logged with its arguments. `raise` prints
# STUB_RAISE_OUT on success, `map` prints STUB_MAP_OUT. The compiler stub
# copies it into the cache, so it finds the sequence helper beside the log.
cat > "$WORK/bin/ax" <<'STUB'
#!/bin/bash
. "$(dirname "$STUB_LOG")/bin/seq.sh"
printf '%s\n' "$*" >> "$STUB_LOG"
v=${1:-}
seq_rc "$v"
case "$v" in
  raise)
    [ -n "${STUB_SLEEP_RAISE:-}" ] && sleep "$STUB_SLEEP_RAISE"
    [ "$rc" = 0 ] && [ -n "${STUB_RAISE_OUT:-}" ] && printf '%s\n' "$STUB_RAISE_OUT"
    ;;
  map)
    [ -n "${STUB_MAP_OUT:-}" ] && printf '%b\n' "$STUB_MAP_OUT"
    ;;
esac
exit "$rc"
STUB

cat > "$WORK/bin/open" <<'STUB'
#!/bin/bash
printf 'open %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB

# Compiler stub: logs one line, optionally sleeps or fails, and otherwise
# leaves an executable copy of the AX stub at its `-o` path.
cat > "$WORK/bin/swiftc" <<'STUB'
#!/bin/bash
printf 'swiftc\n' >> "$STUB_LOG"
[ -n "${STUB_SLEEP_SWIFTC:-}" ] && sleep "$STUB_SLEEP_SWIFTC"
[ -n "${STUB_SWIFTC_FAIL:-}" ] && exit 1
o=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && o=$2
  shift
done
cp "$(dirname "$0")/ax" "$o" && chmod +x "$o"
STUB

# iTerm2 single-read stub for the resolver.
cat > "$WORK/bin/q" <<'STUB'
#!/bin/bash
printf 'q %s\n' "$*" >> "$STUB_LOG"
[ -n "${STUB_Q_SLEEP:-}" ] && sleep "$STUB_Q_SLEEP"
case "${1:-}" in
  ttys)   printf '%b\n' "${STUB_Q_TTYS:-}" ;;
  var)    printf '%s\n' "${STUB_Q_LABEL:-}" ;;
  wins)   printf '%b\n' "${STUB_Q_WINS:-}" ;;
  wpane)  eval "printf '%b\n' \"\${STUB_Q_WPANE_$2:-}\"" ;;
  narrow) printf '%b\n' "${STUB_Q_NARROW:-}" ;;
esac
exit 0
STUB

# The notifier, installed the way Homebrew installs it: a link in `bin` to the
# binary inside a versioned directory whose sibling is the application bundle.
mk_notifier() {
  local ver=$1 cel="$WORK/brew/Cellar/terminal-notifier/$1"
  mkdir -p "$cel/bin" "$cel/terminal-notifier.app" "$WORK/brew/bin"
  cat > "$cel/bin/terminal-notifier" <<'STUB'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a"; done >> "$NOTIFIER_LOG"
printf -- '--\n' >> "$NOTIFIER_LOG"
STUB
  chmod +x "$cel/bin/terminal-notifier"
  rm -f "$WORK/brew/bin/terminal-notifier"
  ln -s "../Cellar/terminal-notifier/$ver/bin/terminal-notifier" "$WORK/brew/bin/terminal-notifier"
}
mk_notifier 3.1.0
NLOG="$WORK/notifier.log"

chmod +x "$WORK/bin/tmux" "$WORK/bin/iterm" "$WORK/bin/ax" "$WORK/bin/open" \
  "$WORK/bin/swiftc" "$WORK/bin/q"

T=$(printf '\t')
SOCK="/tmp/tmux-fx/default"
D_OK='4242|$31|@31|%48|cc-cmds-notify'
CACHE="$WORK/cache"

# row <wid> <index> <session id> <tty> <role> <window pane> <client name>
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$@"; }
rows() {
  local out="" r
  for r in "$@"; do
    out="$out$r
"
  done
  printf '%s' "${out%?}"
}

# value <socket> <pid> <pane> — the value exec-arg prints for that environment.
value() {
  env -u TMUX -u TMUX_PANE TMUX="$1,$2,0" TMUX_PANE="$3" bash "$H_CALL" exec-arg
}

# The seams every click needs. They go through `env -i`, so they are listed
# here rather than exported at the top.
CLICK_ENV=(
  CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1
  CC_CMDS_NOTIFY_FOCUS_ITERM="$WORK/bin/iterm"
  CC_CMDS_NOTIFY_FOCUS_FOREGROUND=1
  CC_CMDS_NOTIFY_FOCUS_CACHE="$CACHE"
  CC_CMDS_NOTIFY_FOCUS_PRIME=off
  CC_CMDS_NOTIFY_FOCUS_AX="$WORK/bin/ax"
  CC_CMDS_NOTIFY_FOCUS_OPEN="$WORK/bin/open"
  CC_CMDS_NOTIFY_FOCUS_SWIFTC=none
  CC_CMDS_NOTIFY_FOCUS_GUIDE=off
  STUB_LOG="$LOG"
)

# Each click starts from an empty cache unless KEEP=1 — a leg that wants the
# entry an earlier click wrote says so.
KEEP=0
fresh() {
  : > "$LOG"
  rm -f "$LOG".seq.*
  if [ "$KEEP" != 1 ]; then
    rm -rf "$CACHE"
  fi
}

# click <label> <tmux binary> <value> [VAR=value ...] — runs the value the way
# a banner click does and asserts the silent, successful exit every click owes.
click() {
  local label=$1 tm=$2 v=$3 rc
  shift 3
  fresh
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
    "${CLICK_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_TMUX="$tm" "$@" \
    /bin/sh -c "$v" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 표준 출력 0 바이트" "$(wc -c < "$WORK/out" | tr -d ' ')" "0"
  check "$label: 표준 오류 0 바이트" "$(wc -c < "$WORK/err" | tr -d ' ')" "0"
}
# The same, with the handler's argv given directly — for arguments exec-arg
# would never have produced.
click_argv() {
  local label=$1 rc
  shift
  fresh
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
    "${CLICK_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" STUB_DISPLAY="$D_OK" \
    /bin/bash "$H" focus "$@" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 표준 출력 0 바이트" "$(wc -c < "$WORK/out" | tr -d ' ')" "0"
  check "$label: 표준 오류 0 바이트" "$(wc -c < "$WORK/err" | tr -d ' ')" "0"
}
logn() { grep -c -- "^$1" "$LOG" 2>/dev/null || true; }
showline() { grep '^show ' "$LOG" 2>/dev/null || true; }
# wait_for <file> <pattern> — a detached process writes later.
wait_for() {
  local i=0
  while [ "$i" -lt 50 ]; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

V=$(value "$SOCK" 4242 %48)
check "기본 값이 focus 명령 꼴이다" "$V" "/bin/bash '$H' focus '$SOCK' '4242' '%48'"

# --- T1. control mode alone (a miss: no entry yet) ---------------------------
DUMP=$(rows "$(row 7 2 GW-1 /dev/ttys045 gateway '' '')" \
            "$(row 9 1 CL-1 /dev/ttys050 client 48 cc-cmds-notify)")
DUMP_T1=$DUMP
CL_T1='1|$31|100|/dev/ttys045'
click "T1 control mode" "$WORK/bin/tmux" "$V" \
  STUB_DISPLAY="$D_OK" STUB_CLIENTS="$CL_T1" STUB_DUMP="$DUMP"
check "T1 호출 순서가 축자로 맞다" "$(cat "$LOG")" "display-message
list-clients
find
select-window -t \$31:@31
select-pane -t %48
raise 1 9 --budget-ms 1000 --ceiling 4000
open -b com.googlecode.iterm2
show 9 CL-1
onspace 9"

# --- T2. normal mode alone ----------------------------------------------------
DUMP=$(rows "$(row 5 1 NM-1 /dev/ttys045 '' '' '')")
click "T2 일반 모드" "$WORK/bin/tmux" "$V" \
  STUB_DISPLAY="$D_OK" STUB_CLIENTS='0|$31|100|/dev/ttys045' STUB_DUMP="$DUMP"
check "T2 호출 순서가 축자로 맞다" "$(cat "$LOG")" "display-message
list-clients
find
select-window -t \$31:@31
select-pane -t %48
raise 1 5 --budget-ms 1000 --ceiling 4000
open -b com.googlecode.iterm2
show 5 NM-1
onspace 5"

# --- T3. both modes: the more recent activity is asked first ------------------
DUMP=$(rows "$(row 9 1 CL-1 /dev/ttys050 client 48 cc-cmds-notify)" \
            "$(row 5 2 NM-1 /dev/ttys045 '' '' '')")
click "T3 control 활동이 크다" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$31|200|/dev/ttys050' '0|$31|100|/dev/ttys045')" STUB_DUMP="$DUMP"
check "T3 control 활동이 크면 control 행이다" "$(showline)" "show 9 CL-1"
click "T3 일반 활동이 크다" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$31|100|/dev/ttys050' '0|$31|200|/dev/ttys045')" STUB_DUMP="$DUMP"
check "T3 일반 활동이 크면 일반 행이다" "$(showline)" "show 5 NM-1"
click "T3 활동이 같다" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$31|100|/dev/ttys050' '0|$31|100|/dev/ttys045')" STUB_DUMP="$DUMP"
check "T3 활동이 같으면 control 행이다" "$(showline)" "show 9 CL-1"

# --- T4. a tie inside the client count goes to the frontmost window -----------
DUMP=$(rows "$(row 11 3 CL-A '' client 48 cc-cmds-notify)" \
            "$(row 12 1 CL-B '' client 48 cc-cmds-notify)")
click "T4 동률 한도 안" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$31|100|/dev/ttys050' '1|$31|90|/dev/ttys051')" STUB_DUMP="$DUMP"
check "T4 index 1 의 창이다" "$(showline)" "show 12 CL-B"

# --- T5. the client name narrows the candidates -------------------------------
DUMP=$(rows "$(row 21 0 CL-X '' client 48 other)" \
            "$(row 22 3 CL-S '' client 48 cc-cmds-notify)" \
            "$(row 23 1 CL-E '' client 48 '')")
click "T5 다리 1" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$31|100|/dev/ttys050' '1|$31|90|/dev/ttys051')" STUB_DUMP="$DUMP"
check "T5 다리 1 은 index 1 의 창이다" "$(showline)" "show 23 CL-E"
DUMP=$(rows "$(row 31 1 CL-E '' client 48 '')" \
            "$(row 32 0 CL-X '' client 48 other)")
click "T5 다리 2" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS='1|$31|100|/dev/ttys050' STUB_DUMP="$DUMP"
check "T5 다리 2 는 빈 이름 행의 창이다" "$(showline)" "show 31 CL-E"

# --- T6. a session name carrying the field separator --------------------------
DUMP=$(rows "$(row 9 1 CL-1 '' client 48 'a|b')")
click "T6 이름에 구분자" "$WORK/bin/tmux" "$V" STUB_DISPLAY='4242|$31|@31|%48|a|b' \
  STUB_CLIENTS='1|$31|100|/dev/ttys050' STUB_DUMP="$DUMP"
check "T6 이름이 일치해 SHOW 가 있다" "$(showline)" "show 9 CL-1"

# --- T7. negatives: nothing is selected and nothing is shown ------------------
DUMP_C=$(rows "$(row 9 1 CL-1 /dev/ttys050 client 48 cc-cmds-notify)")
C_ONE='1|$31|100|/dev/ttys045'
nothing() {
  check "$1: select-pane 0줄" "$(logn select-pane)" "0"
  check "$1: show 0줄" "$(logn show)" "0"
  check "$1: raise 0줄" "$(logn raise)" "0"
}

click_argv "N1 소켓에 따옴표" "/tmp/a'b/default" 4242 %48
check "N1 소켓에 따옴표: 로그 0줄" "$(wc -l < "$LOG" | tr -d ' ')" "0"
click_argv "N1 pane 에 % 없음" "$SOCK" 4242 48
check "N1 pane 에 % 없음: 로그 0줄" "$(wc -l < "$LOG" | tr -d ' ')" "0"
click_argv "N1 pid 가 숫자 아님" "$SOCK" x %48
check "N1 pid 가 숫자 아님: 로그 0줄" "$(wc -l < "$LOG" | tr -d ' ')" "0"

click "N2" "$WORK/bin/no-such-tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP_C"
check "N2 없는 tmux: 로그 0줄" "$(wc -l < "$LOG" | tr -d ' ')" "0"

click "N3" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_RC_DISPLAY_MESSAGE=1 \
  STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP_C"
check "N3 display-message 는 불렸다" "$(logn display-message)" "1"
check "N3 list-clients 0줄" "$(logn list-clients)" "0"
nothing "N3"

click "N4" "$WORK/bin/tmux" "$V" STUB_DISPLAY='31235||||' STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP_C"
check "N4 display-message 는 불렸다" "$(logn display-message)" "1"
check "N4 죽은 pane: list-clients 0줄" "$(logn list-clients)" "0"
check "N4 죽은 pane: find 0줄" "$(logn find)" "0"
nothing "N4"

click "N5" "$WORK/bin/tmux" "$V" STUB_DISPLAY='4242|$31|@31|%49|cc-cmds-notify' \
  STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP_C"
check "N5 display-message 는 불렸다" "$(logn display-message)" "1"
check "N5 pane_id 불일치: list-clients 0줄" "$(logn list-clients)" "0"
nothing "N5"

click "N6" "$WORK/bin/tmux" "$V" STUB_DISPLAY='4243|$31|@31|%48|cc-cmds-notify' \
  STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP_C"
check "N6 display-message 는 불렸다" "$(logn display-message)" "1"
check "N6 pid 불일치: list-clients 0줄" "$(logn list-clients)" "0"
nothing "N6"

click "N7" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS='' STUB_DUMP="$DUMP_C"
check "N7 list-clients 는 불렸다" "$(logn list-clients)" "1"
check "N7 클라이언트 0개: find 0줄" "$(logn find)" "0"
nothing "N7"

click "N8" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS="$(rows '1|$32|100|/dev/ttys045' '0|$32|100|/dev/ttys046')" STUB_DUMP="$DUMP_C"
check "N8 list-clients 는 불렸다" "$(logn list-clients)" "1"
check "N8 다른 세션 클라이언트만: find 0줄" "$(logn find)" "0"
nothing "N8"

click "N9" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" \
  STUB_DUMP="$DUMP_C" STUB_RC_FIND=1
check "N9 find 는 불렸다" "$(logn find)" "1"
check "N9 find 실패: select-window 0줄" "$(logn select-window)" "0"
nothing "N9"

click "N10" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" STUB_DUMP=''
check "N10 find 는 불렸다" "$(logn find)" "1"
check "N10 빈 덤프: select-window 0줄" "$(logn select-window)" "0"
nothing "N10"

DUMP=$(rows "$(printf '9\t1\tCL-1\t\tclient\t48')" "$(row x9 1 CL-2 '' client 48 cc-cmds-notify)")
click "N11" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP"
check "N11 find 는 불렸다" "$(logn find)" "1"
check "N11 깨진 행: select-window 0줄" "$(logn select-window)" "0"
nothing "N11"

DUMP=$(rows "$(row 7 1 GW-1 /dev/ttys045 gateway '' '')")
click "N12" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP"
check "N12 find 는 불렸다" "$(logn find)" "1"
check "N12 gateway 행만: select-window 0줄" "$(logn select-window)" "0"
nothing "N12"

DUMP=$(rows "$(row 5 1 NM-1 /dev/ttys045 client 48 cc-cmds-notify)")
click "N13" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" \
  STUB_CLIENTS='0|$31|100|/dev/ttys045' STUB_DUMP="$DUMP"
check "N13 find 는 불렸다" "$(logn find)" "1"
check "N13 역할이 client 인 tty 행: select-window 0줄" "$(logn select-window)" "0"
nothing "N13"

click "N14" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" \
  STUB_DUMP="$DUMP_C" STUB_RC_SELECT_WINDOW=1
check "N14 select-window 는 불렸다" "$(logn select-window)" "1"
nothing "N14"

DUMP=$(rows "$(row 11 3 CL-A '' client 48 cc-cmds-notify)" \
            "$(row 12 1 CL-B '' client 48 cc-cmds-notify)")
click "N15" "$WORK/bin/tmux" "$V" STUB_DISPLAY="$D_OK" STUB_CLIENTS="$C_ONE" STUB_DUMP="$DUMP"
check "N15 find 는 불렸다" "$(logn find)" "1"
check "N15 클라이언트 수보다 많은 행: select-window 0줄" "$(logn select-window)" "0"
nothing "N15"

# --- L1–L28. the cache, the helper and the fallbacks ---------------------------
# Every leg below starts from T1's environment: a control-mode pane whose
# candidate is window 9, session CL-1, iTerm2 at the stub pid 1.
T1ENV=(STUB_DISPLAY="$D_OK" STUB_CLIENTS="$CL_T1" STUB_DUMP="$DUMP_T1")
TABLE="$CACHE/ax/1"
seed() {
  # A first click that leaves the pane entry behind.
  KEEP=0
  click "$1 (항목 만들기)" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
  KEEP=1
}
put_table() { mkdir -p "$CACHE/ax"; printf '%b' "$1" > "$TABLE"; }

# L1. A cache hit: no resolution at all, and the element id goes to the helper.
seed L1
put_table '9\t77\nmax 3000\n'
click "L1 캐시 적중" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
check "L1 호출 순서가 축자로 맞다" "$(cat "$LOG")" "display-message
list-clients
select-window -t \$31:@31
select-pane -t %48
raise 1 9 --eid 77 --budget-ms 1000 --ceiling 5000
open -b com.googlecode.iterm2
show 9 CL-1
onspace 9"
KEEP=0

# L2. A miss writes the entry; a raise that found the window by scanning writes
# its element id, and the next click is a hit carrying it.
click "L2 미스" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_RAISE_OUT=88
check "L2 미스: find 한 번" "$(logn find)" "1"
check "L2 표에 요소 id 가 써졌다" "$(grep "^9$T" "$TABLE" 2>/dev/null)" "9${T}88"
KEEP=1
click "L2 다음 클릭" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
check "L2 다음 클릭: find 0" "$(logn find)" "0"
check "L2 다음 클릭: --eid 88" "$(grep -c -- '^raise 1 9 --eid 88 ' "$LOG")" "1"
KEEP=0

# L3. The window is gone (raise 4): no `open`, the row goes, the click resolves
# again and raises once more.
seed L3
put_table '9\t77\nmax 77\n'
click "L3 창 닫힘" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_RAISE="4 0"
check "L3 raise 두 번" "$(logn raise)" "2"
check "L3 다시 해석: find 한 번" "$(logn find)" "1"
check "L3 open 은 둘째 raise 뒤 한 번" "$(logn open)" "1"
check "L3 첫 raise 와 open 사이에 find" "$(grep -E '^(raise|open|find)' "$LOG" | tr '\n' '|')" \
  "raise 1 9 --eid 77 --budget-ms 1000 --ceiling 4000|find|raise 1 9 --budget-ms 1000 --ceiling 4000|open -b com.googlecode.iterm2|"
check "L3 표의 그 줄이 지워졌다" "$(grep -c "^9$T" "$TABLE" 2>/dev/null || true)" "0"
KEEP=0

# L4. The session moved: `show` answers "session not found" and the click
# resolves again.
seed L4
click "L4 세션 옮김" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_SHOW="1 0"
check "L4 다시 해석: find 한 번" "$(logn find)" "1"
check "L4 show 두 번" "$(logn show)" "2"
KEEP=0

# L4b. The window id no longer names a window (iTerm2 restarted, the -CC
# client reattached): the same as a moved session, the click resolves again.
# Any other error text is not a moved target and resolves nothing.
seed L4b
click "L4b 창 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_SHOW="1 0" \
  STUB_SHOW_ERR='execution error: window not found (-2700)'
check "L4b 창 없음: find 한 번" "$(logn find)" "1"
check "L4b 창 없음: show 두 번" "$(logn show)" "2"
KEEP=0
seed L4b
click "L4b 다른 오류" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_SHOW="1 0" \
  STUB_SHOW_ERR="execution error: iTerm got an error: AppleEvent timed out. (-1712)"
check "L4b 다른 오류: find 없음" "$(logn find)" "0"
check "L4b 다른 오류: show 한 번" "$(logn show)" "1"
KEEP=0

# L4c. A resolution that read iTerm2 and found no candidate removes the old
# entry; one that failed leaves it.
entries() { find "$CACHE/panes" -type f ! -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
seed L4c
click "L4c 후보 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_SHOW="1" \
  STUB_DUMP="$(rows "$(row 7 2 GW-1 /dev/ttys045 gateway '' '')")"
check "L4c 후보 없음: 다시 해석" "$(logn find)" "1"
check "L4c 후보 없음: 옛 항목이 지워졌다" "$(entries)" "0"
KEEP=0
seed L4c
click "L4c 해석 실패" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SEQ_SHOW="1" STUB_RC_FIND=1
check "L4c 해석 실패: 다시 해석했다" "$(logn find)" "1"
check "L4c 해석 실패: 옛 항목이 남는다" "$(entries)" "1"
KEEP=0

# L5. An entry written for another session name is a miss.
seed L5
click "L5 신원 어긋남" "$WORK/bin/tmux" "$V" STUB_DISPLAY='4242|$31|@31|%48|other' \
  STUB_CLIENTS="$CL_T1" STUB_DUMP="$(rows "$(row 9 1 CL-1 '' client 48 '')")"
check "L5 미스로 find" "$(logn find)" "1"
KEEP=0

# L6. Not trusted (raise 3): the window is selected too, `open` only when it is
# already on a current Space, and one guide for two clicks.
# The notifier runs behind the emitter, so a banner that is NOT raised cannot
# be waited for. The handler's own trace says, by the time the click returns,
# whether it went for the guide or the build at all; a negative reads that.
GTR="$WORK/gtrace"
GUIDE_ENV=(CC_CMDS_NOTIFY_FOCUS_GUIDE= CC_CMDS_NOTIFY_HOST_OS=Darwin NOTIFIER_LOG="$NLOG"
  PATH="$WORK/brew/bin:$WORK/bin:/usr/bin:/bin"
  CC_CMDS_SESSION_NOTIFY=off CC_CMDS_AUTOPILOT_NOTIFY=0 CC_CMDS_NOTIFY_FOCUS_TRACE="$GTR")
traced() {
  [ -f "$GTR" ] || { printf '0\n'; return 0; }
  grep -cE -- "^[0-9]+ $1\$" "$GTR" || true
}
# wait_count <file> <pattern> <n> — until the pattern has matched n lines.
wait_count() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" = "$3" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# wait_helper — until a built helper is in place and no build lock is left.
wait_helper() {
  local i=0 h l
  while [ "$i" -lt 50 ]; do
    h=$(find "$CACHE/helper" -name notify-focus-ax -type f 2>/dev/null | wc -l | tr -d ' ')
    l=$(find "$CACHE/helper" -maxdepth 1 -name '*.lock' 2>/dev/null | wc -l | tr -d ' ')
    [ "$h" = 1 ] && [ "$l" = 0 ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
rm -f "$NLOG" "$GTR"
click "L6 신뢰 없음, 다른 Space" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_ONSPACE=6
check "L6 select w 를 포함한 선택" "$(showline)" "show 9 CL-1 w"
check "L6 다른 Space 면 open 없음" "$(logn open)" "0"
check "L6 순서" "$(grep -E '^(raise|show|onspace|open)' "$LOG" | tr '\n' '|')" \
  "raise 1 9 --budget-ms 1000 --ceiling 4000|show 9 CL-1 w|onspace 9|"
wait_for "$NLOG" '^--$' || true
KEEP=1
rm -f "$GTR"
click "L6 신뢰 없음, 지금 Space" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_ONSPACE=0
check "L6 지금 Space 면 open 있음" "$(logn open)" "1"
check "L6 둘째 클릭은 안내로 가지 않았다" "$(traced 'guide ax')" "0"
check "L6 두 클릭에 안내 한 번" "$(grep -c '^--$' "$NLOG" 2>/dev/null || true)" "1"
check "L6 안내 제목" "$(grep -c '^cc-cmds · 배너 클릭 설정이 필요합니다$' "$NLOG")" "1"
check "L6 안내 group" "$(grep -c '^cc-cmds-notify-focus-guide$' "$NLOG")" "1"
check "L6 안내 -execute :" "$(awk 'p { print; exit } $0 == "-execute" { p = 1 }' "$NLOG")" ":"
MSG=$(awk 'p { print; exit } $0 == "-message" { p = 1 }' "$NLOG")
check "L6 본문이 200 바이트 이하" "$([ "$(printf '%s' "$MSG" | LC_ALL=C wc -c | tr -d ' ')" -le 200 ] && echo 예 || echo "아니오 ($MSG)")" "예"
APP=$(cd -P "$WORK/brew/Cellar/terminal-notifier/3.1.0/terminal-notifier.app" && pwd -P)
case "$MSG" in
  "$APP"*) ok "L6 본문이 앱 번들 경로로 시작한다" ;;
  *) bad "L6 본문이 앱 번들 경로로 시작한다" "$MSG" ;;
esac
mk_notifier 3.2.0
click "L6 앱 경로 바뀜" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_ONSPACE=6
wait_for "$NLOG" '3\.2\.0/terminal-notifier\.app' || true
check "L6 앱 경로가 바뀌면 다시 한 번" "$(grep -c '^--$' "$NLOG" 2>/dev/null || true)" "2"
# A stamp older than a day lets the guide out again.
touch -t 202001010000 "$CACHE/guide.ax"
click "L6 스탬프 늙음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_ONSPACE=6
if wait_count "$NLOG" '^--$' 3; then ok "L6 하루 지난 스탬프면 다시 안내"; else bad "L6 하루 지난 스탬프면 다시 안내" "안내 $(grep -c '^--$' "$NLOG" 2>/dev/null || true)번"; fi
KEEP=0

# L6b. Not trusted, and the session moved: the selection answers "session not
# found" and the second resolution fails — the guide is still raised.
seed L6b
rm -f "$NLOG" "$GTR"
click "L6b 신뢰 없음, 세션 옮김" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_SHOW=1 STUB_RC_FIND=1
check "L6b 다시 해석하러 갔다" "$(logn find)" "1"
check "L6b onspace 없음" "$(logn onspace)" "0"
check "L6b open 없음" "$(logn open)" "0"
check "L6b 안내로 갔다" "$(traced 'guide ax')" "1"
if wait_for "$NLOG" '^--$'; then ok "L6b 안내가 떴다"; else bad "L6b 안내가 떴다" "알림기 줄이 없다"; fi
KEEP=0

# L7. AX cannot complete (7) and a spent budget (1): no `open`, the cache
# bytes stay, one line in focus.log, no guide.
for rc7 in 7 1; do
  seed "L7-$rc7"
  put_table '9\t77\nmax 77\n'
  before=$(cat "$CACHE"/panes/* "$TABLE" | cksum)
  rm -f "$NLOG" "$GTR"
  click "L7 raise $rc7" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" STUB_RC_RAISE=$rc7
  check "L7 raise $rc7: open 없음" "$(logn open)" "0"
  check "L7 raise $rc7: 탭·세션 선택" "$(showline)" "show 9 CL-1"
  check "L7 raise $rc7: 캐시 바이트 불변" "$(cat "$CACHE"/panes/* "$TABLE" | cksum)" "$before"
  check "L7 raise $rc7: focus.log 한 줄" "$(wc -l < "$CACHE/focus.log" | tr -d ' ')" "1"
  check "L7 raise $rc7: raise 를 지나갔다" "$(traced "raise $rc7")" "1"
  check "L7 raise $rc7: 안내 없음" "$(traced 'guide (ax|clt)')$([ -s "$NLOG" ] && echo 있음 || echo 없음)" "0없음"
  KEEP=0
done

# L8. A missing symbol (8): selection only, no `open`, no build, no guide.
rm -f "$NLOG" "$GTR"
click "L8 심볼 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=8 CC_CMDS_NOTIFY_FOCUS_SWIFTC="$WORK/bin/swiftc"
check "L8 탭·세션 선택" "$(showline)" "show 9 CL-1"
check "L8 open 없음" "$(logn open)" "0"
check "L8 raise 를 지나갔다" "$(traced 'raise 8')" "1"
check "L8 빌드 띄움 없음" "$(traced 'build 띄움')" "0"
check "L8 빌드 없음" "$(logn swiftc)" "0"
check "L8 안내 없음" "$(traced 'guide (ax|clt)')$([ -s "$NLOG" ] && echo 있음 || echo 없음)" "0없음"

# L9. No helper yet, a compiler present: selection only and a build behind it.
rm -f "$NLOG" "$GTR"
click "L9 도우미 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_AX= CC_CMDS_NOTIFY_FOCUS_SWIFTC="$WORK/bin/swiftc"
check "L9 탭·세션 선택" "$(showline)" "show 9 CL-1"
check "L9 raise 없음" "$(logn raise)" "0"
check "L9 open 없음" "$(logn open)" "0"
check "L9 빌드를 띄웠다" "$(traced 'build 띄움')" "1"
check "L9 안내로 가지 않았다" "$(traced 'guide (ax|clt)')" "0"
# The build runs on behind the click; the next leg empties the cache, so this
# one waits until the helper is in place and the build lock is gone.
if wait_helper; then ok "L9 뒤의 빌드가 도우미를 놓았다"; else bad "L9 뒤의 빌드가 도우미를 놓았다" "도우미가 없거나 잠금이 남았다"; fi
check "L9 설치 전에 한 번 돌려 봤다" "$(logn trusted)" "1"
check "L9 안내 없음" "$([ -s "$NLOG" ] && echo 있음 || echo 없음)" "없음"

# L10. No compiler: the click raises the CLT guide once; a prime does not.
rm -f "$NLOG"
click "L10 컴파일러 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_AX= CC_CMDS_NOTIFY_FOCUS_SWIFTC=none
wait_for "$NLOG" '^--$' || true
check "L10 CLT 안내 한 번" "$(grep -c 'Command Line Tools' "$NLOG" 2>/dev/null || true)" "1"
check "L10 guide.clt 스탬프" "$([ -f "$CACHE/guide.clt" ] && echo 있음 || echo 없음)" "있음"

# prime_run <label> [VAR=value ...] — a prime in the foreground.
prime_run() {
  local label=$1 rc
  shift
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
    "${CLICK_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" "$@" \
    /bin/bash "$H" prime "$SOCK" 4242 %48 >"$WORK/pout" 2>"$WORK/perr"
  rc=$?
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 출력 0 바이트" "$(cat "$WORK/pout" "$WORK/perr" | wc -c | tr -d ' ')" "0"
}

rm -rf "$CACHE"; : > "$LOG"; rm -f "$NLOG" "$GTR"
prime_run "L10 prime" "${T1ENV[@]}" "${GUIDE_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_AX= CC_CMDS_NOTIFY_FOCUS_SWIFTC=none
check "L10 prime 은 안내로 가지 않는다" "$(traced 'guide (ax|clt)')" "0"
check "L10 prime 은 안내하지 않는다" "$([ -s "$NLOG" ] && echo 있음 || echo 없음)" "없음"
check "L10 prime 은 find 하지 않는다" "$(logn find)" "0"

# L11. Builds: two primes at once compile once; a failure stamp holds for a
# day; a new OS build changes the key.
BUILD_ENV=(CC_CMDS_NOTIFY_FOCUS_AX= CC_CMDS_NOTIFY_FOCUS_SWIFTC="$WORK/bin/swiftc"
  CC_CMDS_NOTIFY_FOCUS_OSBUILD=24A1 STUB_RC_TRUSTED=3)
rm -rf "$CACHE"; : > "$LOG"
prime_run "L11 prime 1" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SLEEP_SWIFTC=1 &
p1=$!
sleep 0.2
prime_run "L11 prime 2" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SLEEP_SWIFTC=1
wait "$p1"
check "L11 동시 prime 둘에 컴파일 한 번" "$(logn swiftc)" "1"
check "L11 빌드한 prime 이 이어서 해석했다" "$(logn find)" "1"
rm -rf "$CACHE"; : > "$LOG"
prime_run "L11 실패" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SWIFTC_FAIL=1
prime_run "L11 실패 뒤" "${T1ENV[@]}" "${BUILD_ENV[@]}"
check "L11 실패 스탬프가 다시 시도를 막는다" "$(logn swiftc)" "1"
prime_run "L11 새 OS 빌드" "${T1ENV[@]}" "${BUILD_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_OSBUILD=24B2
check "L11 OS 빌드가 바뀌면 다시 빌드" "$(logn swiftc)" "2"
# A failure stamp older than a day lets the build try again.
touch -t 202001010000 "$CACHE"/helper/*.failed
prime_run "L11 실패 스탬프 늙음" "${T1ENV[@]}" "${BUILD_ENV[@]}"
check "L11 하루 지난 실패 스탬프면 다시 빌드" "$(logn swiftc)" "3"
helpers() { find "$CACHE/helper" -name notify-focus-ax -type f 2>/dev/null | wc -l | tr -d ' '; }
failures() { find "$CACHE/helper" -maxdepth 1 -name '*.failed' 2>/dev/null | wc -l | tr -d ' '; }
leftovers() { find "$CACHE/helper" -maxdepth 1 \( -name '*.lock' -o -name '*.stale.*' -o -name '*.break' \) 2>/dev/null | wc -l | tr -d ' '; }

# A built binary that does not answer `trusted` with 0 or 3 is not put in place.
rm -rf "$CACHE"; : > "$LOG"
prime_run "L11 설치 전 확인 실패" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_RC_TRUSTED=1
check "L11 설치 전 확인: 컴파일 한 번" "$(logn swiftc)" "1"
check "L11 설치 전 확인: 한 번 돌려 봤다" "$(logn trusted)" "1"
check "L11 설치 전 확인: 도우미가 놓이지 않았다" "$(helpers)" "0"
check "L11 설치 전 확인: 실패 스탬프" "$(failures)" "1"
check "L11 설치 전 확인: 잠금·작업 디렉터리가 남지 않는다" "$(leftovers)" "0"

# A stale build lock — its holder is gone — judged by two primes at once: one
# compile, the helper in place, no failure stamp, nothing left aside.
KEY=$(find "$CACHE/helper" -maxdepth 1 -name '*.failed' | sed 's|.*/||; s|\.failed$||')
dead_pid() { /bin/sh -c 'exit 0' & local p=$!; wait "$p"; printf '%s\n' "$p"; }
rm -rf "$CACHE"; : > "$LOG"
mkdir -p "$CACHE/helper/$KEY.lock"
dead_pid > "$CACHE/helper/$KEY.lock/pid"
prime_run "L11 낡은 잠금 prime 1" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SLEEP_SWIFTC=0.5 &
p1=$!
prime_run "L11 낡은 잠금 prime 2" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SLEEP_SWIFTC=0.5 &
p2=$!
wait "$p1"; wait "$p2"
check "L11 낡은 잠금: 컴파일 한 번" "$(logn swiftc)" "1"
check "L11 낡은 잠금: 도우미가 놓였다" "$(helpers)" "1"
check "L11 낡은 잠금: 실패 스탬프 없음" "$(failures)" "0"
check "L11 낡은 잠금: 남은 잠금·옆으로 옮긴 것 없음" "$(leftovers)" "0"

# A takeover lock left by a breaker that died: while it is young the stale lock
# is not broken; past a minute it is cleared, and the next prime builds.
rm -rf "$CACHE"; : > "$LOG"
mkdir -p "$CACHE/helper/$KEY.lock" "$CACHE/helper/$KEY.lock.break"
dead_pid > "$CACHE/helper/$KEY.lock/pid"
dead_pid > "$CACHE/helper/$KEY.lock.break/pid"
prime_run "L11 탈취 잠금 젊음" "${T1ENV[@]}" "${BUILD_ENV[@]}"
check "L11 탈취 잠금 젊음: 컴파일 없음" "$(logn swiftc)" "0"
check "L11 탈취 잠금 젊음: 탈취 잠금이 남는다" "$([ -d "$CACHE/helper/$KEY.lock.break" ] && echo 있음 || echo 없음)" "있음"
touch -t 202001010000 "$CACHE/helper/$KEY.lock.break"
prime_run "L11 탈취 잠금 늙음" "${T1ENV[@]}" "${BUILD_ENV[@]}"
check "L11 탈취 잠금 늙음: 치우고 이번에는 물러난다" "$(logn swiftc)" "0"
prime_run "L11 탈취 잠금 뒤" "${T1ENV[@]}" "${BUILD_ENV[@]}"
check "L11 탈취 잠금 뒤: 컴파일 한 번" "$(logn swiftc)" "1"
check "L11 탈취 잠금 뒤: 도우미가 놓였다" "$(helpers)" "1"
check "L11 탈취 잠금 뒤: 남은 잠금 없음" "$(leftovers)" "0"

# A lock past its age whose holder is still compiling is taken over. The first
# builder, finding the lock no longer its own, installs and stamps nothing.
rm -rf "$CACHE"; : > "$LOG"
prime_run "L11 넘겨진 잠금 prime 1" "${T1ENV[@]}" "${BUILD_ENV[@]}" STUB_SLEEP_SWIFTC=2 &
p1=$!
wait_for "$LOG" '^swiftc$' || true
touch -t 202001010000 "$CACHE/helper/$KEY.lock"
prime_run "L11 넘겨진 잠금 prime 2" "${T1ENV[@]}" "${BUILD_ENV[@]}"
wait "$p1"
check "L11 넘겨진 잠금: 넘겨받은 쪽이 다시 컴파일" "$(logn swiftc)" "2"
check "L11 넘겨진 잠금: 도우미가 놓였다" "$(helpers)" "1"
check "L11 넘겨진 잠금: 잃은 쪽은 실패 스탬프를 남기지 않는다" "$(failures)" "0"
check "L11 넘겨진 잠금: 남은 잠금·옆으로 옮긴 것 없음" "$(leftovers)" "0"

# L12. Detached: the click returns at once and the work lands afterwards.
fresh
t0=$(date +%s)
env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" "${CLICK_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" CC_CMDS_NOTIFY_FOCUS_FOREGROUND= \
  "${T1ENV[@]}" STUB_SLEEP_RAISE=2 /bin/sh -c "$V" >"$WORK/out" 2>"$WORK/err"
rc=$?
t1=$(date +%s)
check "L12 분리: 종료 코드 0" "$rc" "0"
check "L12 분리: 1초 안에 돌아온다" "$([ $((t1 - t0)) -le 1 ] && echo 예 || echo "아니오 $((t1 - t0))초")" "예"
check "L12 분리: 돌아온 순간 open 은 아직 없다" "$(logn open)" "0"
if wait_for "$LOG" '^open '; then ok "L12 분리: 본문이 뒤에서 끝났다"; else bad "L12 분리: 본문이 뒤에서 끝났다" "open 줄이 없다"; fi

# exec_arg <label> <want> [VAR=value ...] -- [exec-arg args...]
exec_arg() {
  local label=$1 want=$2 rc out lines
  shift 2
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u TMUX -u TMUX_PANE ${envs[@]+"${envs[@]}"} \
    bash "$H_CALL" exec-arg "$@" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  out=$(cat "$WORK/out")
  lines=$(wc -l < "$WORK/out" | tr -d ' ')
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 값" "$out" "$want"
  check "$label: 한 줄" "$lines" "1"
  check "$label: 표준 오류 0 바이트" "$(wc -c < "$WORK/err" | tr -d ' ')" "0"
  case "$out" in
    *'-group '*) bad "$label: -group 없음" "$out" ;;
    *) ok "$label: -group 없음" ;;
  esac
}

# L13 / L15 / L27. Whether exec-arg starts a prime is read from the trace line
# the starting side writes, not from anything the prime leaves behind — a prime
# against a dead socket leaves nothing either way.
TR="$WORK/trace"
PRIME_ON=(CC_CMDS_NOTIFY_FOCUS_PRIME= CC_CMDS_NOTIFY_FOCUS_TRACE="$TR"
  CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 PATH="$WORK/brew/bin:/usr/bin:/bin"
  CC_CMDS_NOTIFY_FOCUS_ITERM="$WORK/bin/iterm" CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/no-such-tmux")
primes() { cat "$TR" 2>/dev/null | grep -c '^[0-9]* prime 띄움 ' || true; }
rm -f "$TR"
exec_arg "L13 prime 켬" "$V" "${PRIME_ON[@]}" TMUX="$SOCK,4242,0" TMUX_PANE=%48 --
check "L13 prime 켬: 정확히 하나 띄움" "$(primes)" "1"
check "L13 prime 켬: 띄운 대상" "$(sed 's/^[0-9]* //' "$TR")" "prime 띄움 $SOCK 4242 %48"
rm -f "$TR"
exec_arg "L13 prime 끔" "$V" "${PRIME_ON[@]}" CC_CMDS_NOTIFY_FOCUS_PRIME=off TMUX="$SOCK,4242,0" TMUX_PANE=%48 --
check "L13 prime 끔: 띄우지 않음" "$(primes)" "0"
printf '%s\t%s\t%s\n' "$SOCK" 4242 %7 > "$WORK/good.seat.l15"
rm -f "$TR"
exec_arg "L15 좌석 파일" "/bin/bash '$H' focus '$SOCK' '4242' '%7'" "${PRIME_ON[@]}" -- --seat-file "$WORK/good.seat.l15"
check "L15 --seat-file 은 prime 을 띄우지 않는다" "$(primes)" "0"
rm -f "$TR"
exec_arg "L27 알림기 없음" "$V" "${PRIME_ON[@]}" PATH="/usr/bin:/bin" TMUX="$SOCK,4242,0" TMUX_PANE=%48 --
check "L27 PATH 에 알림기가 없으면 띄우지 않는다" "$(primes)" "0"
PREP='PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"'
check "L27 발사기의 앞붙이기 문면이 있다" "$(grep -cF "$PREP" "$ORCH/notify-run.sh" | awk '{ print ($1 > 0) }')" "1"
check "L27 처리기의 앞붙이기가 발사기와 같은 문면이다" \
  "$(grep -F 'PATH="' "$ORCH/notify-focus.sh" | grep -v ':/usr/bin:/bin' | sed 's/^ *//' | sort -u)" "$PREP"

# L14. A dead socket: the prime creates nothing at all, not even the root.
rm -rf "$WORK/cache14"
prime_run "L14 죽은 소켓" STUB_DISPLAY='31235||||' CC_CMDS_NOTIFY_FOCUS_CACHE="$WORK/cache14"
check "L14 캐시 뿌리가 생기지 않는다" "$([ -e "$WORK/cache14" ] && echo 있음 || echo 없음)" "없음"

# L16. A newer click supersedes an older one: the older, still in its slow
# path, comes back and changes nothing.
rm -rf "$CACHE"; : > "$LOG"
env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" "${CLICK_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" "${T1ENV[@]}" STUB_SLEEP_FIND=1.5 \
  /bin/sh -c "$V" >/dev/null 2>&1 &
old=$!
sleep 0.5
KEEP=1
click "L16 새 클릭" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
: > "$LOG.after"
wait "$old"
cat "$LOG" > "$LOG.after"
check "L16 앞 클릭은 선택하지 않았다: select-pane 한 번" "$(grep -c '^select-pane' "$LOG.after")" "1"
check "L16 앞 클릭은 올리지 않았다: raise 한 번" "$(grep -c '^raise' "$LOG.after")" "1"
check "L16 show 한 번" "$(grep -c '^show' "$LOG.after")" "1"
KEEP=0

# L16, the other wait: the older click is held inside its AppleScript selection
# on the not-trusted path, which would go on to `onspace`, `open -b` and the
# guide. A newer click finishes meanwhile; the older one, once the selection
# answers, does none of the three. L6 is the same older click left alone, and
# there it does all three.
rm -rf "$CACHE"; : > "$LOG"; rm -f "$NLOG" "$GTR"
env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" "${CLICK_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" "${T1ENV[@]}" "${GUIDE_ENV[@]}" \
  STUB_RC_RAISE=3 STUB_RC_ONSPACE=0 STUB_SLEEP_SHOW=1.5 \
  /bin/sh -c "$V" >/dev/null 2>&1 &
old=$!
wait_for "$LOG" '^show 9 CL-1 w$' || true
KEEP=1
click "L16 선택 중에 새 클릭" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
wait "$old"
check "L16 선택 중: 새 클릭만 onspace 를 물었다" "$(logn onspace)" "1"
check "L16 선택 중: 새 클릭만 open 했다" "$(logn open)" "1"
check "L16 선택 중: 앞 클릭은 안내로 가지 않았다" "$(traced 'guide ax')" "0"
check "L16 선택 중: 안내 배너 없음" "$([ -s "$NLOG" ] && echo 있음 || echo 없음)" "없음"
KEEP=0

# L17. The retries: `onspace` stays 6 → raise + open exactly three times within
# 1.5 s; a re-raise answering 7 stops them; `onspace` 8 never retries.
t0=$(date +%s)
click "L17 늘 6" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_RC_ONSPACE=6
t1=$(date +%s)
check "L17 raise 세 번" "$(logn raise)" "3"
check "L17 open 세 번" "$(logn open)" "3"
check "L17 3초 안에 끝난다" "$([ $((t1 - t0)) -le 3 ] && echo 예 || echo "아니오 $((t1 - t0))초")" "예"
click "L17 다시 올리기가 7" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_RC_ONSPACE=6 STUB_SEQ_RAISE="0 7"
check "L17 7 뒤 raise 두 번" "$(logn raise)" "2"
check "L17 7 뒤 open 한 번" "$(logn open)" "1"
click "L17 onspace 8" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_RC_ONSPACE=8
check "L17 8 이면 raise 한 번" "$(logn raise)" "1"
check "L17 8 이면 onspace 한 번" "$(logn onspace)" "1"

# L18. The 10-second deadline (scaled to 1 s): a slow resolution ends in
# selection only.
click "L18 마감" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_SLEEP_FIND=1.5 \
  CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE=0.1
check "L18 선택은 했다" "$(showline)" "show 9 CL-1"
check "L18 raise 없음" "$(logn raise)" "0"
check "L18 open 없음" "$(logn open)" "0"

# L19. Concurrent table writers leave a table that always reads.
seed L19
put_table '9\t77\nmax 77\n'
for i in 1 2 3 4 5 6 7 8; do
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" "${CLICK_ENV[@]}" \
    CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" "${T1ENV[@]}" STUB_RAISE_OUT=$((100 + i)) \
    /bin/sh -c "$V" >/dev/null 2>&1 &
done
wait
check "L19 표의 모든 줄이 읽힌다" \
  "$(grep -cvE "^([0-9]+$T[0-9]+|max [0-9]+)$" "$TABLE" || true)" "0"
check "L19 창 9 의 줄은 하나다" "$(grep -c "^9$T" "$TABLE")" "1"
KEEP=0

# L20. No Apple-event permission: the prime asks iTerm2 nothing.
rm -rf "$CACHE"; : > "$LOG"
prime_run "L20 자동화 권한 없음" "${T1ENV[@]}" STUB_RC_AECHECK=1
check "L20 find 0" "$(logn find)" "0"
check "L20 항목 없음" "$(find "$CACHE/panes" -type f | wc -l | tr -d ' ')" "0"

# L21. One resolution per pane: two primes at once resolve once, and a missed
# click arriving meanwhile waits for the entry instead of resolving again.
rm -rf "$CACHE"; : > "$LOG"
prime_run "L21 prime 1" "${T1ENV[@]}" STUB_SLEEP_FIND=1 STUB_RC_TRUSTED=3 &
p1=$!
sleep 0.3
prime_run "L21 prime 2" "${T1ENV[@]}" STUB_RC_TRUSTED=3
KEEP=1
click "L21 합류한 클릭" "$WORK/bin/tmux" "$V" "${T1ENV[@]}"
wait "$p1"
check "L21 합류한 클릭은 해석하지 않았다" "$(logn find)" "0"
check "L21 합류한 클릭은 써진 항목으로 선택했다" "$(showline)" "show 9 CL-1"
KEEP=0

# L22. record starts the seat pane's prime, once, and only when it wrote.
mkdir -p "$WORK/rd22"
rm -f "$TR"
env -u TMUX -u TMUX_PANE "${PRIME_ON[@]}" TMUX="$SOCK,4242,0" TMUX_PANE=%48 \
  bash "$H_CALL" record "$WORK/rd22" >/dev/null 2>&1
check "L22 record 가 좌석 pane 의 prime 을 하나 띄운다" "$(primes)" "1"
check "L22 띄운 대상" "$(sed 's/^[0-9]* //' "$TR")" "prime 띄움 $SOCK 4242 %48"
rm -f "$TR"
env -u TMUX -u TMUX_PANE "${PRIME_ON[@]}" TMUX="$SOCK,4242,0" TMUX_PANE=%48 \
  bash "$H_CALL" record "$WORK/rd22" >/dev/null 2>&1
check "L22 기록이 이미 있으면 띄우지 않는다" "$(primes)" "0"
mkdir -p "$WORK/rd22b"
env -u TMUX -u TMUX_PANE "${PRIME_ON[@]}" CC_CMDS_NOTIFY_FOCUS_PRIME=off TMUX="$SOCK,4242,0" TMUX_PANE=%48 \
  bash "$H_CALL" record "$WORK/rd22b" >/dev/null 2>&1
check "L22 PRIME=off 면 띄우지 않는다" "$(primes)" "0"
check "L22 PRIME=off 여도 기록은 쓴다" "$([ -f "$WORK/rd22b/notify.seat" ] && echo 있음 || echo 없음)" "있음"

# L23. The prime's map: called once with the derived ceiling, the table
# replaced only on 0, and not at all without trust.
rm -rf "$CACHE"; : > "$LOG"
put_table '9\t77\nmax 3000\n'
touch -t 202001010000 "$TABLE"
prime_run "L23 map 0" "${T1ENV[@]}" STUB_RC_TRUSTED=0 STUB_MAP_OUT='9\t70\n12\t300'
check "L23 map 축자" "$(grep '^map' "$LOG")" "map 1 --budget-ms 5000 --ceiling 5000"
check "L23 표가 map 출력으로 바뀌었다" "$(cat "$TABLE")" "9${T}70
12${T}300
max 300"
for rcm in 7 1; do
  rm -rf "$CACHE"; : > "$LOG"
  put_table '9\t77\nmax 77\n'
  touch -t 202001010000 "$TABLE"
  before=$(cksum < "$TABLE")
  prime_run "L23 map $rcm" "${T1ENV[@]}" STUB_RC_TRUSTED=0 STUB_RC_MAP=$rcm STUB_MAP_OUT='9\t70'
  check "L23 map $rcm: 표 바이트 불변" "$(cksum < "$TABLE")" "$before"
done
rm -rf "$CACHE"; : > "$LOG"
prime_run "L23 신뢰 없음" "${T1ENV[@]}" STUB_RC_TRUSTED=3
check "L23 신뢰 없으면 map 없음" "$(logn map)" "0"

# L23b. One scan per iTerm2 at a time, and none within a minute of the last
# try — a scan that ran out of budget writes no table but still counts. Each
# prime below drops the pane entry first, so it is the table rule that stops it.
rm -rf "$CACHE"; : > "$LOG"
prime_run "L23b 첫 시도" "${T1ENV[@]}" STUB_RC_TRUSTED=0 STUB_RC_MAP=1
check "L23b 첫 시도: map 한 번" "$(logn map)" "1"
check "L23b 첫 시도: 표는 없다" "$([ -e "$TABLE" ] && echo 있음 || echo 없음)" "없음"
check "L23b 첫 시도: 시도 시각이 남았다" "$([ -f "$TABLE.tried" ] && echo 있음 || echo 없음)" "있음"
drop_entries() { find "$CACHE/panes" -type f -exec rm -f {} + 2>/dev/null; }
drop_entries
prime_run "L23b 1분 안" "${T1ENV[@]}" STUB_RC_TRUSTED=0 STUB_RC_MAP=1
check "L23b 1분 안: 다시 해석은 했다" "$(logn find)" "2"
check "L23b 1분 안: map 은 다시 없다" "$(logn map)" "1"
touch -t 202001010000 "$TABLE.tried"
drop_entries
prime_run "L23b 1분 뒤" "${T1ENV[@]}" STUB_RC_TRUSTED=0 STUB_MAP_OUT='9\t70'
check "L23b 1분 뒤: map 다시" "$(logn map)" "2"
check "L23b 1분 뒤: 표가 써졌다" "$(grep -c "^9${T}70\$" "$TABLE" 2>/dev/null || true)" "1"
rm -f "$TABLE" "$TABLE.tried"
drop_entries
mkdir -p "$TABLE.lock"
printf '%s\n' "$$" > "$TABLE.lock/pid"
prime_run "L23b 잠금 중" "${T1ENV[@]}" STUB_RC_TRUSTED=0
check "L23b 다른 prime 이 표를 잡고 있으면 map 없음" "$(logn map)" "2"
check "L23b 남의 잠금은 그대로다" "$(cat "$TABLE.lock/pid" 2>/dev/null)" "$$"
rm -rf "$TABLE.lock"

# L24. iTerm2 not running: tmux only.
click "L24 pid 없음" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" CC_CMDS_NOTIFY_FOCUS_ITERM_PID=
check "L24 pid 없음: tmux 선택" "$(logn select-pane)" "1"
check "L24 pid 없음: find 없음" "$(logn find)" "0"
check "L24 pid 없음: show 없음" "$(logn show)" "0"
check "L24 pid 없음: raise 없음" "$(logn raise)" "0"
click "L24 raise 5" "$WORK/bin/tmux" "$V" "${T1ENV[@]}" STUB_RC_RAISE=5
check "L24 raise 5: show 없음" "$(logn show)" "0"
check "L24 raise 5: open 없음" "$(logn open)" "0"

# L25. The AppleScript the handler ships.
AS=$(grep -E "^[[:space:]]*-e '" "$ORCH/notify-focus.sh")
check "L25 & tab & 없음" "$(printf '%s\n' "$AS" | grep -c '& tab &' || true)" "0"
check "L25 activate 없음" "$(printf '%s\n' "$AS" | grep -ci 'activate' || true)" "0"
check "L25 구분자는 character id 9" "$(printf '%s\n' "$AS" | grep -c "set sepTab to (character id 9)" | awk '{ print ($1 > 0) }')" "1"
check "L25 구분자는 tell 블록 밖에서 만든다" \
  "$(printf '%s\n' "$AS" | awk '/tell application id/ { t = 1 } /end tell/ { t = 0 } /set sepTab/ && t { print "안" }' | sort -u)" ""
check "L25 set wl to windows 다음 줄들에 창마다 try" \
  "$(printf '%s\n' "$AS" | awk '/set wl to windows/ { w = NR } w && NR == w + 2 { print }' | sed "s/^ *-e //")" "'try' \\"
check "L25 pane 번호는 on run argv 로" "$(printf '%s\n' "$AS" | grep -c "set nwant to item 1 of argv")" "1"
check "L25 선택은 창 id 가 없을 때 window not found 로 실패한다" \
  "$(printf '%s\n' "$AS" | grep -c "error \"window not found\"")" "1"

# L26. getconf fails: no root, nothing in the working directory, and the click
# still selects through the slow path.
mkdir -p "$WORK/gbin" "$WORK/cwd26"
printf '#!/bin/sh\nexit 1\n' > "$WORK/gbin/getconf"
chmod +x "$WORK/gbin/getconf"
fresh
(cd "$WORK/cwd26" && env -i HOME="$WORK" PATH="$WORK/gbin:$WORK/bin:/usr/bin:/bin" "${CLICK_ENV[@]}" \
  CC_CMDS_NOTIFY_FOCUS_CACHE= CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" "${T1ENV[@]}" \
  /bin/sh -c "$V" >/dev/null 2>&1)
check "L26 작업 디렉터리에 cc-cmds/ 가 없다" "$(ls -A "$WORK/cwd26" | wc -l | tr -d ' ')" "0"
check "L26 느린 경로로 선택했다" "$(showline)" "show 9 CL-1"
check "L26 느린 경로: find 한 번" "$(logn find)" "1"

# L28. With the emitter: a run whose banners are off writes the seat record and
# starts no prime; a session seat switched off starts none either.
L28_ENV=("${PRIME_ON[@]}" CC_CMDS_NOTIFY_HOST_OS=Darwin NOTIFIER_LOG="$NLOG"
  TMUX="$SOCK,4242,0" TMUX_PANE=%48 CC_NOTIFY_SESSION_ID=s28
  CC_PIPELINE_SEGMENT= CC_PIPELINE_STAGE_ID= CC_PIPELINE_SHIFT_ID=)
seat28() {
  mkdir -p "$1"
  env "${L28_ENV[@]}" RUN_DIR="$1" "${@:2}" bash -c \
    '. "$0" && cc_notify_seat_state' "$ORCH/notify-run.sh" >/dev/null 2>&1
}
rm -f "$TR"
seat28 "$WORK/rd28a" CC_CMDS_AUTOPILOT_NOTIFY=0
check "L28 (가) 꺼진 런: notify.seat 은 쓴다" "$([ -f "$WORK/rd28a/notify.seat" ] && echo 있음 || echo 없음)" "있음"
check "L28 (가) 꺼진 런: prime 없음" "$(primes)" "0"
rm -f "$TR"
seat28 "$WORK/rd28b" CC_CMDS_AUTOPILOT_NOTIFY=
check "L28 (가) 켜진 런: prime 정확히 하나" "$(primes)" "1"
fire28() {
  env "${L28_ENV[@]}" "$@" bash -c \
    '. "$0" && cc_notify_fire session-turn "본문"' "$ORCH/notify-run.sh" >/dev/null 2>&1
}
rm -f "$TR"
fire28 CC_CMDS_SESSION_NOTIFY=off
check "L28 (나) 꺼진 세션: prime 없음" "$(primes)" "0"
rm -f "$TR"
fire28 CC_CMDS_SESSION_NOTIFY=
check "L28 (나) 켜진 세션: prime 정확히 하나" "$(primes)" "1"

# --- Q. the connection-label resolver, read by read ----------------------------
# The prime runs the real resolver with each AppleScript read replaced by the
# single-read seam; the pane entry it writes says which candidate it settled on.
Q_ENV=(CC_CMDS_NOTIFY_FOCUS_ITERM= CC_CMDS_NOTIFY_FOCUS_ITERM_Q="$WORK/bin/q"
  STUB_DISPLAY="$D_OK" STUB_CLIENTS="$CL_T1" STUB_RC_TRUSTED=3
  STUB_Q_TTYS='7\t2\tGW-1\t/dev/ttys045\t1\t1\n5\t1\tNM-1\t/dev/ttys050\t1\t1\n9\t1\tCL-1\t\t1\t1'
  STUB_Q_LABEL='@host (2)')
entry() { cat "$CACHE"/panes/[0-9]* 2>/dev/null | awk -F "$T" '{ print $8, $9, $10 }'; }
rm -rf "$CACHE"; : > "$LOG"
prime_run "Q1 연결 라벨" "${Q_ENV[@]}" \
  STUB_Q_WINS='11\t3\tbar [@host (22)]\n9\t1\tfoo [@host (2)]' STUB_Q_WPANE_9='CL-1\t48'
check "Q1 후보 창 9 가 항목에 들었다" "$(entry)" "1 9 CL-1"
check "Q1 게이트웨이의 라벨을 읽었다" "$(grep -c '^q var 7 1 1 tmuxClientName$' "$LOG")" "1"
check "Q1 (22) 는 (2) 의 후보가 아니다" "$(grep -c '^q wpane 11' "$LOG" || true)" "0"
check "Q1 좁힌 순회 없음" "$(grep -c '^q narrow' "$LOG" || true)" "0"
rm -rf "$CACHE"; : > "$LOG"
prime_run "Q2 후보 없음" "${Q_ENV[@]}" STUB_Q_WINS='11\t3\tbar [@host (22)]' \
  STUB_Q_NARROW='9\t1\tCL-1\t\tclient\t48\tcc-cmds-notify'
check "Q2 후보가 없으면 좁힌 순회" "$(grep -c '^q narrow 48$' "$LOG")" "1"
check "Q2 좁힌 순회의 답이 항목에 들었다" "$(entry)" "1 9 CL-1"
rm -rf "$CACHE"; : > "$LOG"
prime_run "Q3 확인 어긋남" "${Q_ENV[@]}" STUB_Q_WINS='9\t1\tfoo [@host (2)]' STUB_Q_WPANE_9='CL-1\t47' \
  STUB_Q_NARROW='9\t1\tCL-1\t\tclient\t48\tcc-cmds-notify'
check "Q3 확인이 어긋나면 좁힌 순회" "$(grep -c '^q narrow 48$' "$LOG")" "1"
rm -rf "$CACHE"; : > "$LOG"
prime_run "Q4 상한" "${Q_ENV[@]}" STUB_Q_SLEEP=1 CC_CMDS_NOTIFY_FOCUS_WAIT_SCALE=0.01 \
  STUB_Q_WINS='9\t1\tfoo [@host (2)]' STUB_Q_WPANE_9='CL-1\t48'
check "Q4 상한을 넘기면 항목을 쓰지 않는다" "$(ls "$CACHE/panes" 2>/dev/null | grep -vc '\.lock$' || true)" "0"
rm -rf "$CACHE"; : > "$LOG"
prime_run "Q5 좁힌 순회 강제" "${Q_ENV[@]}" CC_CMDS_NOTIFY_FOCUS_RESOLVER=narrow \
  STUB_Q_NARROW='9\t1\tCL-1\t\tclient\t48\tcc-cmds-notify'
check "Q5 강제면 ttys 를 읽지 않는다" "$(grep -c '^q ttys' "$LOG" || true)" "0"
check "Q5 강제면 좁힌 순회" "$(grep -c '^q narrow 48$' "$LOG")" "1"

# --- T20. exec-arg ------------------------------------------------------------
exec_arg "T20 TMUX 없음" ":" TMUX_PANE=%48 --
exec_arg "T20 pane 에 % 없음" ":" TMUX="$SOCK,4242,0" TMUX_PANE=48 --
exec_arg "T20 소켓에 따옴표" ":" TMUX="/tmp/a'b/default,4242,0" TMUX_PANE=%48 --
exec_arg "T20 소켓에 -group" ":" TMUX="/tmp/x -group y/default,4242,0" TMUX_PANE=%48 --
exec_arg "T20 소켓에 쉼표" "/bin/bash '$H' focus '/tmp/tmux-fx,a/default' '4242' '%48'" \
  TMUX="/tmp/tmux-fx,a/default,4242,7" TMUX_PANE=%48 --
exec_arg "T20 좌석 파일 없음" ":" TMUX="$SOCK,4242,0" TMUX_PANE=%48 -- --seat-file "$WORK/none.seat"
printf '%s\t%s\n' "$SOCK" 4242 > "$WORK/broken.seat"
exec_arg "T20 좌석 파일 깨진 줄" ":" -- --seat-file "$WORK/broken.seat"
printf '%s\t%s\t%s\n' "$SOCK" 4242 %7 > "$WORK/good.seat"
exec_arg "T20 좌석 파일이 환경보다 앞선다" "/bin/bash '$H' focus '$SOCK' '4242' '%7'" \
  TMUX="$SOCK,4242,0" TMUX_PANE=%48 -- --seat-file "$WORK/good.seat"

# --- T21. record --------------------------------------------------------------
# record <label> <dir> [VAR=value ...]
record() {
  local label=$1 dir=$2 rc
  shift 2
  env -u TMUX -u TMUX_PANE "$@" bash "$H_CALL" record "$dir" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 표준 출력 0 바이트" "$(wc -c < "$WORK/out" | tr -d ' ')" "0"
}
mkdir -p "$WORK/rd"
record "T21 첫 기록" "$WORK/rd" TMUX="/tmp/tmux-fx,a/default,4242,7" TMUX_PANE=%48
check "T21 첫 기록은 탭 구분 한 줄이다" "$(cat "$WORK/rd/notify.seat" 2>/dev/null || true)" \
  "$(printf '%s\t%s\t%s' '/tmp/tmux-fx,a/default' 4242 %48)"
check "T21 첫 기록은 한 줄이다" "$(wc -l < "$WORK/rd/notify.seat" | tr -d ' ')" "1"
record "T21 이미 있음" "$WORK/rd" TMUX="$SOCK,9999,1" TMUX_PANE=%3
check "T21 이미 있는 기록은 바뀌지 않는다" "$(cat "$WORK/rd/notify.seat" 2>/dev/null || true)" \
  "$(printf '%s\t%s\t%s' '/tmp/tmux-fx,a/default' 4242 %48)"
mkdir -p "$WORK/ro"
chmod 555 "$WORK/ro"
record "T21 쓸 수 없는 디렉터리" "$WORK/ro" TMUX="$SOCK,4242,0" TMUX_PANE=%48
chmod 755 "$WORK/ro"
mkdir -p "$WORK/rd2"
record "T21 TMUX 없음" "$WORK/rd2" TMUX_PANE=%48
check "T21 TMUX 없음: 기록이 생기지 않는다" "$([ -e "$WORK/rd2/notify.seat" ] && echo 있음 || echo 없음)" "없음"
record "T21 TMUX 꼴이 깨짐" "$WORK/rd2" TMUX="$SOCK" TMUX_PANE=%48
check "T21 TMUX 꼴이 깨짐: 기록이 생기지 않는다" "$([ -e "$WORK/rd2/notify.seat" ] && echo 있음 || echo 없음)" "없음"

# --- T8–T11. a private tmux server ---------------------------------------------
real_unavailable() {
  if [ -n "${CI:-}" ]; then
    bad "실서버 묶음" "$1"
  else
    printf 'SKIP: %s\n' "$1"
  fi
}
# wait_clients <count> — the clients attach in the background.
wait_clients() {
  local i=0 n
  while [ "$i" -lt 50 ]; do
    n=$("$REAL_TMUX" -S "$S/s" list-clients -F x 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
real_suite() {
  local tm=$REAL_TMUX out rc spid sid wid pane before after v ttys t
  S=$(mktemp -d /tmp/ccnf.XXXXXX) || { real_unavailable "임시 디렉터리를 만들지 못했다"; return; }
  if ! env -u TMUX -u TMUX_PANE "$tm" -S "$S/s" -f /dev/null \
       new-session -d -s one -x 80 -y 24 >/dev/null 2>&1; then
    real_unavailable "사설 tmux 서버를 띄우지 못했다"
    return
  fi
  printf 'tmux -V: %s\n' "$("$tm" -V 2>&1)"

  # T8 (i). A pane that does not exist answers with exit 0 and empty ids — the
  # fixed point the dead-pane stub output stands on.
  out=$("$tm" -S "$S/s" display-message -p -t %99999 '#{pane_id}|#{session_id}' 2>/dev/null)
  rc=$?
  check "T8 없는 pane: 종료 코드 0" "$rc" "0"
  check "T8 없는 pane: id 가 빈다" "$out" "|"

  spid=$("$tm" -S "$S/s" display-message -p -t one '#{pid}')
  sid=$("$tm" -S "$S/s" display-message -p -t one '#{session_id}')

  # T9 (ii). No client is attached: nothing changes and iTerm2 is not asked.
  wid=$("$tm" -S "$S/s" new-window -d -t one -P -F '#{window_id}')
  pane=$("$tm" -S "$S/s" split-window -d -t "$wid" -P -F '#{pane_id}')
  before=$("$tm" -S "$S/s" display-message -p -t "$sid" '#{window_id} #{pane_id}')
  v=$(value "$S/s" "$spid" "$pane")
  click "T9 클라이언트 없음" "$tm" "$v" STUB_DUMP="$(rows "$(row 9 1 CL-1 '' client "${pane#%}" one)")"
  after=$("$tm" -S "$S/s" display-message -p -t "$sid" '#{window_id} #{pane_id}')
  check "T9 현재 window·pane 이 그대로다" "$after" "$before"
  check "T9 find 0줄" "$(logn find)" "0"

  # T10 (iii). A control-mode client, fed from a pipe that stays open. The
  # target is an inactive pane of an inactive window.
  TAIL_PID_FILE="$S/tail.pid"
  # The group's own stderr is closed: its `wait` reports the feeder's end.
  { tail -f /dev/null & printf '%s\n' "$!" > "$TAIL_PID_FILE"; wait; } 2>/dev/null \
    | env -u TMUX -u TMUX_PANE "$tm" -S "$S/s" -C attach -t one >/dev/null 2>&1 &
  if ! wait_clients 1; then
    bad "T10 control mode 클라이언트" "붙지 않았다"
  else
    click "T10 control mode" "$tm" "$v" \
      STUB_DUMP="$(rows "$(row 9 1 CL-1 '' client "${pane#%}" one)")"
    after=$("$tm" -S "$S/s" display-message -p -t "$sid" '#{window_id} #{pane_id}')
    check "T10 세션의 현재가 대상 window·pane 이다" "$after" "$wid $pane"
    check "T10 show 가 있다" "$(showline)" "show 9 CL-1"
  fi
  kill "$(cat "$TAIL_PID_FILE" 2>/dev/null)" >/dev/null 2>&1 || true
  wait_clients 0 || true

  # T11 (iv). Two ordinary clients, each running in a pane of an outer private
  # server, attached to the same inner session.
  wid=$("$tm" -S "$S/s" new-window -d -t one -P -F '#{window_id}')
  pane=$("$tm" -S "$S/s" split-window -d -t "$wid" -P -F '#{pane_id}')
  env -u TMUX -u TMUX_PANE "$tm" -S "$S/o" -f /dev/null new-session -d -s out -x 80 -y 24 \
    "env -u TMUX '$tm' -S '$S/s' attach -t one" >/dev/null 2>&1
  env -u TMUX -u TMUX_PANE "$tm" -S "$S/o" split-window -d -t out \
    "env -u TMUX '$tm' -S '$S/s' attach -t one" >/dev/null 2>&1
  if ! wait_clients 2; then
    bad "T11 일반 모드 클라이언트 둘" "붙지 않았다"
    return
  fi
  ttys=$("$tm" -S "$S/s" list-clients -F '#{client_tty}')
  printf 'client_tty: %s\n' "$(printf '%s' "$ttys" | tr '\n' ' ')"
  t=${ttys%%
*}
  v=$(value "$S/s" "$spid" "$pane")
  click "T11 일반 모드 둘" "$tm" "$v" STUB_DUMP="$(rows "$(row 5 1 NM-1 "$t" '' '' '')")"
  check "T11 show 가 있다" "$(showline)" "show 5 NM-1"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    check "T11 클라이언트 $t 의 pane 이 대상이다" \
      "$("$tm" -S "$S/s" display-message -c "$t" -p '#{pane_id}' 2>/dev/null)" "$pane"
  done <<EOF
$ttys
EOF
}

if [ -z "$REAL_TMUX" ]; then
  real_unavailable "tmux 가 설치되어 있지 않다"
else
  real_suite
fi

[ -n "$FAILS" ] && printf '실패 목록:\n%s' "$FAILS" >&2
printf 'test-notify-focus: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
