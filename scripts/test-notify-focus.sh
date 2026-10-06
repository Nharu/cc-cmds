#!/usr/bin/env bash
# Test plugins/cc-cmds/orchestrator/notify-focus.sh — the banner click handler
# and the two helpers that build the value a banner carries.
#
# TWO SUITES. The stub suite replaces tmux and the two iTerm2 calls through the
# handler's own seams and runs anywhere: both stubs append what they were asked
# to ONE ordered log, so an assertion reads the order of the calls as well as
# their presence. The real-server suite starts a private tmux server under
# /tmp and drives the handler against it; iTerm2 stays a stub there too.
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
# both streams before anything else.
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
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-notify-focus.XXXXXX")
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

# iTerm2 stub: `find` prints the dump, `show <wid> <sid>` is logged and answers.
cat > "$WORK/bin/iterm" <<'STUB'
#!/bin/bash
case "${1:-}" in
  find)
    printf 'find\n' >> "$STUB_LOG"
    [ -n "${STUB_DUMP:-}" ] && printf '%s\n' "$STUB_DUMP"
    exit "${STUB_RC_FIND:-0}"
    ;;
  show)
    printf 'show %s %s\n' "${2:-}" "${3:-}" >> "$STUB_LOG"
    printf 'ok\n'
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/tmux" "$WORK/bin/iterm"

T=$(printf '\t')
SOCK="/tmp/tmux-fx/default"
D_OK='4242|$31|@31|%48|cc-cmds-notify'

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

# click <label> <tmux binary> <value> [VAR=value ...] — runs the value the way
# a banner click does and asserts the silent, successful exit every click owes.
click() {
  local label=$1 tm=$2 v=$3 rc
  shift 3
  : > "$LOG"
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
    CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
    CC_CMDS_NOTIFY_FOCUS_TMUX="$tm" \
    CC_CMDS_NOTIFY_FOCUS_ITERM="$WORK/bin/iterm" \
    STUB_LOG="$LOG" "$@" \
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
  : > "$LOG"
  env -i HOME="$WORK" PATH="$WORK/bin:/usr/bin:/bin" \
    CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
    CC_CMDS_NOTIFY_FOCUS_TMUX="$WORK/bin/tmux" \
    CC_CMDS_NOTIFY_FOCUS_ITERM="$WORK/bin/iterm" \
    STUB_LOG="$LOG" STUB_DISPLAY="$D_OK" \
    /bin/bash "$H" focus "$@" >"$WORK/out" 2>"$WORK/err"
  rc=$?
  check "$label: 종료 코드 0" "$rc" "0"
  check "$label: 표준 출력 0 바이트" "$(wc -c < "$WORK/out" | tr -d ' ')" "0"
  check "$label: 표준 오류 0 바이트" "$(wc -c < "$WORK/err" | tr -d ' ')" "0"
}
logn() { grep -c -- "^$1" "$LOG" 2>/dev/null || true; }
showline() { grep '^show ' "$LOG" 2>/dev/null || true; }

V=$(value "$SOCK" 4242 %48)
check "기본 값이 focus 명령 꼴이다" "$V" "/bin/bash '$H' focus '$SOCK' '4242' '%48'"

# --- T1. control mode alone ---------------------------------------------------
DUMP=$(rows "$(row 7 2 GW-1 /dev/ttys045 gateway '' '')" \
            "$(row 9 1 CL-1 /dev/ttys050 client 48 cc-cmds-notify)")
click "T1 control mode" "$WORK/bin/tmux" "$V" \
  STUB_DISPLAY="$D_OK" STUB_CLIENTS='1|$31|100|/dev/ttys045' STUB_DUMP="$DUMP"
check "T1 호출 순서가 축자로 맞다" "$(cat "$LOG")" "display-message
list-clients
find
select-window -t \$31:@31
select-pane -t %48
show 9 CL-1"

# --- T2. normal mode alone ----------------------------------------------------
DUMP=$(rows "$(row 5 1 NM-1 /dev/ttys045 '' '' '')")
click "T2 일반 모드" "$WORK/bin/tmux" "$V" \
  STUB_DISPLAY="$D_OK" STUB_CLIENTS='0|$31|100|/dev/ttys045' STUB_DUMP="$DUMP"
check "T2 호출 순서가 축자로 맞다" "$(cat "$LOG")" "display-message
list-clients
find
select-window -t \$31:@31
select-pane -t %48
show 5 NM-1"

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

# --- T20. exec-arg ------------------------------------------------------------
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

printf 'test-notify-focus: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
