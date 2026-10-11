#!/usr/bin/env bash
#
# suite-guard.sh — run one test suite, then reap what it left behind.
#
# Usage:
#   bash scripts/suite-guard.sh <suite> [args…]
#   bash scripts/suite-guard.sh --sweep --fd <n> --marker <path> --epoch <s>
#                               [--exclude <pid>]… [--classify]
#
# WHY THIS EXISTS. Under `make -jN` every recipe inherits make's jobserver pipe
# as fds 3–5, and so does every descendant the recipe leaves behind — a
# backgrounded `sleep`, a double-forked detached child, a process whose stdio
# was reopened on /dev/null. make does not return while any of them holds that
# pipe, and it waits with no child of its own, so a suite that printed its
# summary and left one such process stalls the whole target for as long as the
# process lives. This wrapper sits on the recipe line and removes them when the
# suite ends.
#
# WHO IS "OURS" IS DECIDED BY AN INHERITED FD, NOT BY A NAME OR A GROUP. The
# wrapper opens a private marker file on the literal fd 9 before it starts the
# suite, so every process the suite starts carries that file at that number
# unless it closed it. A holder is a process that `lsof` lists as holding the
# marker on exactly fd 9; the same file open on another number does not count.
# A session or process-group test would miss the detached grandchild, which is
# in neither. A literal number because bash 3.2 has no `{fd}>` allocation.
#
# THE KNOWN BLIND SPOT is a descendant that closed the fd: `exec 9>&-`, a
# closefrom, a Python `subprocess` child under the default `close_fds=True`,
# anything `launchctl` or another daemon started. Such a process also closed
# fds 3–5 if it closed everything, and then cannot hold make either. The
# suite's own process group is printed beside the holders, so a member that
# closed fd 9 but stayed in the group is at least seen.
#
# A SIGNAL GOES ONLY TO A PROVEN PROCESS. Right before every signal the pid is
# proven again: same uid, started no earlier than the second the marker was
# made, and still holding the marker on fd 9. pids are reused, and a listing
# taken a second ago proves nothing about the pid now. The one exception is the
# suite's own process group while its leader is still unreaped — a pgid cannot
# be reused while the leader exists, even as a zombie. After the leader is
# reaped the group is walked member by member under the same uid and start
# checks instead of being signalled as a whole.
#
# THE ENUMERATION NEVER LISTS ITSELF. `lsof` does not list its own pid, its
# output goes to a file rather than through a pipe or a command substitution,
# and the wrapper moves its own copy of the marker from fd 9 to fd 7 the
# moment the suite has started, so nothing the wrapper runs afterwards inherits
# fd 9. The copy on fd 7 is kept on purpose: every sweep expects to see the
# wrapper itself on fd 7, which is the positive control that tells "no holder"
# apart from an `lsof` that failed. `lsof -t` exits 1 for both.
#
# THE MARKER MUST STILL BE THE SAME FILE. A deleted marker makes `lsof` list
# nothing at all, so before a sweep the path has to exist with the inode the
# wrapper recorded; otherwise the sweep is a failed judgement, not a clean one.
#
# Strict mode (CC_SUITE_GUARD_STRICT=1, set by the macOS workflow only) turns
# what is found into a failure. Without it the wrapper still reaps and prints,
# and returns the suite's own rc — the recipe is shared with the ubuntu leg and
# with a developer's `make test`, where a new failure would be out of place.
#
# Exit codes:
#   the suite's rc  whenever it is non-zero, and always outside strict mode
#   3               strict, the suite passed and left at least one holder
#   4               strict, the judgement could not be made (no `lsof`, the
#                   positive control failed, the marker was removed or replaced)
#   124             strict, the deadline passed and the suite was reaped
#   128+n           the wrapper itself received signal n (INT, TERM, HUP); it
#                   is passed to the suite's group first, the suite is reaped
#                   and the sweep still runs, but what it finds does not change
#                   this code
#
# Environment:
#   CC_SUITE_GUARD_STRICT    1 = strict (above)
#   CC_SUITE_GUARD_LIMIT_S   the wrapper's own limit in seconds; 0 or unset is none
#   CC_STEP_DEADLINE_EPOCH   the step deadline the CI arming line exports
#   CC_SUITE_GUARD_MARGIN_S  how far before that step deadline the suite is cut
#                            (default 30), so the suite's deadline always falls
#                            first and the step's dump still has time to run
#   CC_SUITE_GUARD_GRACE_S   seconds between the suite's end and the sweep when
#                            something still holds the marker, and between TERM
#                            and KILL (default 2). It has to be longer than one
#                            `lsof` call, which each sweep prints.
#   CC_SUITE_GUARD_LSOF      the lsof to run (default `lsof`)
#
# `--sweep` is the same sweep run against a marker someone else holds — the CI
# arming line (scripts/ci-step-guard.sh) calls it for its fd 8 marker at the
# step's end and at its deadline. It prints, signals proven holders, and exits
# 0 when nothing held the marker, 3 when something did, 4 when it could not
# tell. `--classify` adds the reading of who was waiting for whom (below).
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `wait -n`.

set -u

SG_STRICT=0
[ "${CC_SUITE_GUARD_STRICT:-}" = "1" ] && SG_STRICT=1
SG_LSOF="${CC_SUITE_GUARD_LSOF:-lsof}"
SG_GRACE="${CC_SUITE_GUARD_GRACE_S:-2}"
case "$SG_GRACE" in ''|*[!0-9]*) SG_GRACE=2 ;; esac
SG_MARGIN="${CC_SUITE_GUARD_MARGIN_S:-30}"
case "$SG_MARGIN" in ''|*[!0-9]*) SG_MARGIN=30 ;; esac
SG_UID=$(id -u)
SG_NAME="suite-guard"
SG_TMP=""
SG_MARKER=""
SG_EPOCH=0
SG_INODE=""
SG_FD=9
SG_SELF_FD=""
SG_EXCLUDE=" "
SG_CLASSIFY=0
SG_FOUND=""

sg_log() { printf '%s: %s\n' "$SG_NAME" "$*" >&2; }

sg_now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

sg_secs() { perl -e 'printf "%.2f", $ARGV[1] - $ARGV[0]' "$1" "$2"; }

sg_inode() { perl -e 'my @s = stat $ARGV[0] or exit 1; print $s[1], "\n"' "$1"; }

# `ps -o lstart=` read as an epoch. `date -j`/`date -d` are the two spellings
# the portability lint forbids, so the parse is perl's. The column has
# one-second resolution, which is why the comparison is against the recorded
# epoch's whole second.
sg_start_epoch() {
  local st
  st=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  perl -MPOSIX -e '
    my %m = (Jan=>0, Feb=>1, Mar=>2, Apr=>3, May=>4, Jun=>5,
             Jul=>6, Aug=>7, Sep=>8, Oct=>9, Nov=>10, Dec=>11);
    my $s = join(" ", @ARGV);
    if ($s =~ /^\s*\w+\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d+)/ && exists $m{$1}) {
      print POSIX::mktime($5, $4, $3, $2, $m{$1}, $6 - 1900, 0, 0, -1), "\n";
      exit 0;
    }
    exit 1;' $st
}

# sg_proven <pid> [<fd>] — the proof taken right before a signal. With no fd it
# is the group walk's proof (uid and start time); with one it also requires the
# marker on that fd now.
sg_proven() {
  local pid="$1" fd="${2:-}" u e
  u=$(ps -o uid= -p "$pid" 2>/dev/null) || return 1
  u=${u// /}
  [ "$u" = "$SG_UID" ] || return 1
  e=$(sg_start_epoch "$pid") || return 1
  [ -n "$e" ] && [ "$e" -ge "$SG_EPOCH" ] || return 1
  [ -n "$fd" ] || return 0
  "$SG_LSOF" -w -a -p "$pid" -d "$fd" -F p -- "$SG_MARKER" >"$SG_TMP/proof" 2>/dev/null || return 1
  grep -qx "p$pid" "$SG_TMP/proof"
}

sg_print_file() {
  local l
  while IFS= read -r l; do printf '%s:     %s\n' "$SG_NAME" "$l" >&2; done < "$1"
}

sg_dump() {
  # sg_dump <pid> <label>
  sg_log "  $2 pid=$1"
  {
    ps -o pid,ppid,pgid,etime,stat,command -p "$1"
    "$SG_LSOF" -w -n -P -a -p "$1" -d 0-9,cwd
  } >"$SG_TMP/dump" 2>&1
  sg_print_file "$SG_TMP/dump"
}

# sg_enumerate — writes the pids holding the marker on SG_FD to $SG_TMP/holders
# and returns 0, or returns 4 when the listing cannot be trusted. With
# SG_SELF_FD set the wrapper itself must appear on that fd.
sg_enumerate() {
  local t0 t1 lrc cur
  if [ ! -e "$SG_MARKER" ]; then
    sg_log "판정 실패 — 표지 파일이 없다: $SG_MARKER (지워진 표지는 아무 보유자도 나열하지 않는다)"
    return 4
  fi
  if [ -n "$SG_INODE" ]; then
    cur=$(sg_inode "$SG_MARKER") || cur=""
    if [ "$cur" != "$SG_INODE" ]; then
      sg_log "판정 실패 — 표지 파일이 바뀌었다(inode $SG_INODE → ${cur:-없음})"
      return 4
    fi
  fi
  t0=$(sg_now)
  "$SG_LSOF" -w -F pf -- "$SG_MARKER" >"$SG_TMP/lsof" 2>"$SG_TMP/lsof.err"
  lrc=$?
  t1=$(sg_now)
  sg_log "표지 열거 lsof 소요 $(sg_secs "$t0" "$t1")s (rc=$lrc)"
  if [ "$lrc" != 0 ] && { [ -s "$SG_TMP/lsof" ] || [ -s "$SG_TMP/lsof.err" ] || [ -n "$SG_SELF_FD" ]; }; then
    sg_log "판정 실패 — lsof 가 rc=$lrc 로 끝났다"
    sg_print_file "$SG_TMP/lsof.err"
    return 4
  fi
  awk '/^p/ { p = substr($0, 2) } /^f/ { print p, substr($0, 2) }' "$SG_TMP/lsof" >"$SG_TMP/pairs"
  if [ -n "$SG_SELF_FD" ] && ! grep -qx "$$ $SG_SELF_FD" "$SG_TMP/pairs"; then
    sg_log "판정 실패 — 양성 대조: lsof 가 표지를 쥔 이 래퍼(pid $$, fd $SG_SELF_FD)를 나열하지 않았다"
    return 4
  fi
  awk -v fd="$SG_FD" -v self="$$" -v ex="$SG_EXCLUDE" '
    BEGIN { n = split(ex, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    $2 == fd && $1 != self && !($1 in skip) { print $1 }' "$SG_TMP/pairs" | sort -u >"$SG_TMP/holders"
  return 0
}

# What a step deadline was waiting on. W2': make is alive with no child and a
# holder outside its tree shares its jobserver pipe. W1: a suite bash is still
# alive. W3: the suites are gone and only recipe processes remain under make.
sg_classify() {
  local pid comm mk="" kids dev peer cls="" h
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
    case "${comm##*/}" in make|gmake) mk="$pid" ;; esac
  done < "$SG_TMP/holders"
  ps -A -o pid=,ppid= >"$SG_TMP/tree" 2>/dev/null || : >"$SG_TMP/tree"
  if [ -n "$mk" ]; then
    kids=$(awk -v p="$mk" '$2 == p { printf "%s ", $1 }' "$SG_TMP/tree")
    sg_log "make pid=$mk stat=$(ps -o stat= -p "$mk" 2>/dev/null) 자식=[${kids% }]"
    "$SG_LSOF" -w -n -P -a -p "$mk" -d 3 >"$SG_TMP/mkfd" 2>/dev/null || :
    dev=$(awk '$5 == "PIPE" { print $6; exit }' "$SG_TMP/mkfd")
    peer=$(awk '$5 == "PIPE" { sub(/^->/, "", $NF); print $NF; exit }' "$SG_TMP/mkfd")
    sg_log "make fd 3 PIPE DEVICE=${dev:-?} 맞은편=${peer:-?}"
    : >"$SG_TMP/sharers"
    while IFS= read -r h; do
      [ -n "$h" ] && [ "$h" != "$mk" ] || continue
      "$SG_LSOF" -w -n -P -a -p "$h" -d 3,4,5 >"$SG_TMP/hfd" 2>/dev/null || :
      if [ -n "$dev" ] && awk -v d="$dev" -v q="$peer" '$5 == "PIPE" && ($6 == d || $6 == q) { f = 1 } END { exit !f }' "$SG_TMP/hfd"; then
        printf '%s\n' "$h" >>"$SG_TMP/sharers"
        sg_log "  보유자 pid=$h 의 fd 3·4·5 PIPE 가 make 의 jobserver 파이프와 같다"
      fi
    done < "$SG_TMP/holders"
    if [ -z "$kids" ] && [ -s "$SG_TMP/sharers" ]; then cls="W2'"; fi
  fi
  if [ -z "$cls" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      case "$(ps -o command= -p "$h" 2>/dev/null)" in
        *suite-guard.sh*) ;;
        *bash*test-*.sh*|*bash*test-run.sh*) cls="W1"; break ;;
      esac
    done < "$SG_TMP/holders"
  fi
  if [ -z "$cls" ] && [ -n "$mk" ] && [ -n "${kids:-}" ]; then cls="W3"; fi
  case "$cls" in
    "W2'") sg_log "분류: W2' — make 가 자식 없이 살아 있고 트리 밖 보유자가 jobserver 파이프를 쥐었다" ;;
    W1)    sg_log "분류: W1 — 묶음 bash 가 아직 살아 있다" ;;
    W3)    sg_log "분류: W3 — 묶음은 끝났고 make 아래 레시피 프로세스만 남았다" ;;
    *)     sg_log "분류: 미분류 — 위 덤프로 대기자를 읽는다" ;;
  esac
}

# sg_sweep — enumerate, dump, TERM, grace, KILL. Returns 0 when nothing held
# the marker, 3 when something did, 4 when the judgement failed. A holder
# found on the first look gets the grace to finish on its own before it counts.
sg_sweep() {
  local pid n
  sg_enumerate || return 4
  if [ ! -s "$SG_TMP/holders" ]; then
    sg_log "표지 보유자 0"
    return 0
  fi
  sleep "$SG_GRACE"
  sg_enumerate || return 4
  if [ ! -s "$SG_TMP/holders" ]; then
    sg_log "표지 보유자 0 (유예 ${SG_GRACE}s 안에 끝났다)"
    return 0
  fi
  n=$(grep -c . "$SG_TMP/holders")
  SG_FOUND="$SG_FOUND $(tr '\n' ' ' < "$SG_TMP/holders")"
  sg_log "잔존 — 표지(fd $SG_FD) 보유자 $n"
  [ "$SG_CLASSIFY" = 1 ] && sg_classify
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    sg_dump "$pid" "보유자"
    if sg_proven "$pid" "$SG_FD"; then
      kill -TERM "$pid" 2>/dev/null && sg_log "  TERM → pid=$pid"
    else
      sg_log "  pid=$pid 는 소속이 다시 증명되지 않아 신호하지 않는다"
    fi
  done < "$SG_TMP/holders"
  sleep "$SG_GRACE"
  sg_enumerate || return 4
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if sg_proven "$pid" "$SG_FD"; then
      kill -KILL "$pid" 2>/dev/null && sg_log "  KILL → pid=$pid (TERM 뒤에도 남았다)"
    else
      sg_log "  pid=$pid 는 TERM 뒤에도 남았으나 소속이 다시 증명되지 않아 신호하지 않는다"
    fi
  done < "$SG_TMP/holders"
  return 3
}

sg_setup_tmp() {
  SG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-suite-guard.XXXXXX") || {
    sg_log "임시 디렉터리를 만들지 못했다"
    exit 4
  }
}

# --- sweep mode -------------------------------------------------------------

if [ "${1:-}" = "--sweep" ]; then
  shift
  # The caller's copies of the markers are not this process's to hold.
  exec 8<&- 9<&-
  SG_NAME="step-guard"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fd) SG_FD="${2:-}"; shift 2 ;;
      --marker) SG_MARKER="${2:-}"; shift 2 ;;
      --epoch) SG_EPOCH="${2:-0}"; shift 2 ;;
      --exclude) SG_EXCLUDE="$SG_EXCLUDE${2:-} "; shift 2 ;;
      --classify) SG_CLASSIFY=1; shift ;;
      *) sg_log "모르는 인자: $1"; exit 4 ;;
    esac
  done
  case "$SG_FD" in ''|*[!0-9]*) sg_log "--fd 가 숫자가 아니다"; exit 4 ;; esac
  case "$SG_EPOCH" in ''|*[!0-9]*) SG_EPOCH=0 ;; esac
  [ -n "$SG_MARKER" ] || { sg_log "--marker 가 없다"; exit 4; }
  command -v "$SG_LSOF" >/dev/null 2>&1 || { sg_log "판정 실패 — lsof 가 없다"; exit 4; }
  sg_setup_tmp
  sg_sweep
  src=$?
  rm -rf "$SG_TMP"
  exit "$src"
fi

# --- wrapper mode -----------------------------------------------------------

if [ "$#" -lt 1 ]; then
  sg_log "사용법: bash scripts/suite-guard.sh <suite> [args…]"
  exit 2
fi
SG_NAME="suite-guard[$*]"
sg_setup_tmp

# The epoch first, then the marker: every process that may hold the marker
# started no earlier than this second.
SG_EPOCH=$(date +%s)
SG_MARKER=$(mktemp "${TMPDIR:-/tmp}/cc-suite.XXXXXX") || {
  sg_log "표지 파일을 만들지 못했다"
  rm -rf "$SG_TMP"
  exit 4
}
SG_INODE=$(sg_inode "$SG_MARKER") || SG_INODE=""
exec 9<"$SG_MARKER"

sg_cleanup() {
  exec 7<&- 9<&-
  rm -f "$SG_MARKER"
  rm -rf "$SG_TMP"
}

# Mode: `marker` sweeps fd 9 holders; `group` is the fallback when the positive
# control cannot be had outside strict mode.
SG_MODE=marker
pc_t0=$(sg_now)
if ! command -v "$SG_LSOF" >/dev/null 2>&1; then
  pc_why="lsof 가 없다"
elif ! "$SG_LSOF" -w -t -- "$SG_MARKER" >"$SG_TMP/pc" 2>"$SG_TMP/pc.err" 9<&-; then
  pc_why="lsof 가 0 이 아닌 값으로 끝났다"
elif ! grep -qx "$$" "$SG_TMP/pc"; then
  pc_why="lsof 가 표지를 쥔 이 래퍼(pid $$)를 나열하지 않았다"
else
  pc_why=""
fi
pc_t1=$(sg_now)
if [ -n "$pc_why" ]; then
  if [ "$SG_STRICT" = 1 ]; then
    printf '::error::suite-guard: 양성 대조 실패 — %s. 묶음을 돌리지 않는다: %s\n' "$pc_why" "$*" >&2
    sg_cleanup
    exit 4
  fi
  sg_log "NOTE: 양성 대조 실패($pc_why) — 표지 스윕을 끄고 묶음의 프로세스 그룹 스윕으로 대신한다"
  SG_MODE=group
else
  sg_log "양성 대조 통과 (lsof $(command -v "$SG_LSOF"), $(sg_secs "$pc_t0" "$pc_t1")s)"
fi

case " ${MAKEFLAGS:-} " in
  *--jobserver-fds=*)
    jf=${MAKEFLAGS#*--jobserver-fds=}; jf=${jf%% *}
    sg_log "MAKEFLAGS jobserver-fds=$jf" ;;
  *--jobserver-auth=*)
    jf=${MAKEFLAGS#*--jobserver-auth=}; jf=${jf%% *}
    sg_log "MAKEFLAGS jobserver-auth=$jf" ;;
  *)
    sg_log "MAKEFLAGS 에 jobserver 없음" ;;
esac

# The effective deadline: the wrapper's own limit and the step deadline less
# the margin, whichever comes first. Neither set means no deadline.
SG_DEADLINE=0
lim="${CC_SUITE_GUARD_LIMIT_S:-0}"
case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
[ "$lim" -gt 0 ] && SG_DEADLINE=$((SG_EPOCH + lim))
sd="${CC_STEP_DEADLINE_EPOCH:-0}"
case "$sd" in ''|*[!0-9]*) sd=0 ;; esac
if [ "$sd" -gt 0 ]; then
  sd=$((sd - SG_MARGIN))
  if [ "$SG_DEADLINE" = 0 ] || [ "$sd" -lt "$SG_DEADLINE" ]; then SG_DEADLINE=$sd; fi
fi

sg_sig=""
sg_deadline_hit=0
trap 'sg_sig=2' INT
trap 'sg_sig=15' TERM
trap 'sg_sig=1' HUP
trap 'sg_deadline_hit=1' USR1

# The suite runs as its own process-group leader. Its stdin is /dev/null: a
# group that is not the terminal's foreground group stops on a terminal read.
set -m
bash "$@" </dev/null &
spid=$!
set +m
exec 7<&9 9<&-

SG_TIMER=""
if [ "$SG_DEADLINE" -gt 0 ]; then
  perl -e '
    my ($pp, $dl) = @ARGV;
    while (1) {
      exit 0 if getppid() != $pp;
      if (time >= $dl) { kill "USR1", $pp; exit 0 }
      sleep 1;
    }' "$$" "$SG_DEADLINE" 7<&- &
  SG_TIMER=$!
fi

sg_group_live() {
  ps -A -o pid=,pgid=,stat= 2>/dev/null \
    | awk -v g="$spid" '$2 == g && $3 !~ /^Z/ { printf "%s ", $1 }'
}

# sg_reap_group <signal> — the group signal, allowed only because the leader
# is not reaped yet; then the grace; then KILL to whatever is left; then reap.
sg_reap_group() {
  local i=0 live
  kill -"$1" -- "-$spid" 2>/dev/null
  live=$(sg_group_live)
  while [ -n "$live" ] && [ "$i" -lt $((SG_GRACE * 5)) ]; do
    sleep 0.2
    i=$((i + 1))
    live=$(sg_group_live)
  done
  if [ -n "$live" ]; then
    sg_log "그룹 $spid 에 KILL (남은 구성원: ${live% })"
    kill -KILL -- "-$spid" 2>/dev/null
  fi
  wait "$spid" 2>/dev/null
}

timed_out=0
rc=0

while :; do
  wait "$spid"
  wrc=$?
  if [ -n "$sg_sig" ]; then
    sg_log "신호 $sg_sig 를 받았다 — 묶음 그룹 $spid 에 전달하고 거둔다"
    sg_reap_group "$sg_sig"
    rc=$((128 + sg_sig))
    break
  fi
  if [ "$sg_deadline_hit" = 1 ] && [ "$timed_out" = 0 ]; then
    timed_out=1
    sg_log "마감 초과 — 묶음을 덤프하고 거둔다"
    ps -A -o pid=,pgid= 2>/dev/null | awk -v g="$spid" '$2 == g { print $1 }' >"$SG_TMP/members"
    while IFS= read -r m; do
      [ -n "$m" ] && sg_dump "$m" "그룹 구성원"
    done < "$SG_TMP/members"
    sg_reap_group TERM
    rc=$?
    break
  fi
  rc=$wrc
  break
done
trap '' INT TERM HUP USR1

if [ -n "$SG_TIMER" ]; then
  kill -TERM "$SG_TIMER" 2>/dev/null
  wait "$SG_TIMER" 2>/dev/null
fi

sweep_rc=0
if [ "$SG_MODE" = marker ]; then
  SG_SELF_FD=7
  sg_sweep
  sweep_rc=$?
fi

# The group, after its leader was reaped: printed always, and walked member by
# member when it is the fallback.
ps -A -o pid=,pgid= 2>/dev/null | awk -v g="$spid" '$2 == g { print $1 }' >"$SG_TMP/members"
if [ -s "$SG_TMP/members" ]; then
  sg_log "그룹 교차 확인 — 묶음 그룹 $spid 에 남은 구성원 $(grep -c . "$SG_TMP/members")"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    sg_dump "$m" "그룹 구성원"
    if [ "$SG_MODE" = group ]; then
      if sg_proven "$m"; then
        kill -TERM "$m" 2>/dev/null && sg_log "  TERM → pid=$m"
      fi
    fi
  done < "$SG_TMP/members"
  if [ "$SG_MODE" = group ]; then
    sweep_rc=3
    sleep "$SG_GRACE"
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      if sg_proven "$m"; then
        kill -KILL "$m" 2>/dev/null && sg_log "  KILL → pid=$m (TERM 뒤에도 남았다)"
      fi
    done < "$SG_TMP/members"
  fi
fi

sg_cleanup

if [ -n "$sg_sig" ]; then
  exit "$rc"
fi
if [ "$timed_out" = 1 ] && [ "$SG_STRICT" = 1 ]; then
  printf '::error::suite-guard: 마감을 넘겨 묶음을 거뒀다(위 덤프) — %s\n' "$*" >&2
  exit 124
fi
[ "$rc" != 0 ] && exit "$rc"
if [ "$SG_STRICT" = 1 ]; then
  case "$sweep_rc" in
    4) printf '::error::suite-guard: 잔존 판정 실패 — %s\n' "$*" >&2; exit 4 ;;
    3) printf '::error::suite-guard: 묶음이 끝난 뒤 남은 프로세스가 있었다(위 덤프) — %s\n' "$*" >&2; exit 3 ;;
  esac
fi
exit 0
