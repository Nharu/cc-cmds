#!/usr/bin/env bash
# Host-wide test slots for the job pool of scripts/test-tree.sh, the serial
# bundle of scripts/check-push.sh, and the direct entry points (`make run/…`
# and a narrowed scripts/test-gate.sh) that run through `--run` below.
#
# A SLOT IS ONE CPU'S SHARE. Every run of every checkout of this repository on
# this host sees the same store under the host state root, so the runs that
# share this host take turns through it instead of piling their jobs onto the
# CPUs at once. A job takes as many slots as the CPU share it used the last time it ran
# (its weight), all at once, and gives them back when it ends. The pools queue
# in first-come order: a pool keeps the first two cells of its ticket name for
# its whole life, so its next ticket always stands before a later pool's. Slots
# only schedule; they never change a verdict.
#
# Sourced by scripts/test-tree.sh and scripts/test-gate.sh. Run, it wraps one
# command in a slot, or runs its self-test:
#   bash scripts/test-slots.sh --run <weight key> <name> -- <command...>
#   bash scripts/test-slots.sh --self-test
#
# Variables:
#   CC_TEST_SLOTS           how many slots: a positive whole number is that
#                           many, auto is max(4, CPUs), 0 is off. Unset or
#                           empty, an unattended run (CC_PIPELINE_RUN_ID not
#                           empty) reads TS_UNATTENDED_SLOTS below in the same
#                           grammar and any other run is off. Off means
#                           nothing waits, nothing is measured and a job runs
#                           as it did before slots. Anything else is warned
#                           about and read as off
#   CC_TEST_SLOTS_DIR       the store; without it the private store the caller
#                           names (a self-test whose doubles stand), else
#                           ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/test-slots
#   CC_TEST_SLOTS_WAIT_MAX  seconds a job waits, counted from its ticket,
#                           before it starts without a slot (default 3600 for
#                           the pool and the serial bundle, 300 for --run)
#   CC_TEST_SLOT_HELD       1 in the environment of a job started under slots,
#                           held or started without one at the cap; an entry
#                           point that sees it takes none, so a run nested in
#                           a slot does not wait for a slot again
#
# The store: slot-<k>/owner (the pool, the job and every process of it with
# its start time), queue/<first-ticket epoch, 10 digits>-<pool pid, 10
# digits>-<seq, 6 digits> (the pid and its start time), weights/<job key>
# with `/` spelled `%2F` (the weight, one whole number). Every file is written
# under a temporary name and moved into place; every removal renames first.
# An entry whose processes are all gone, or whose pid now belongs to a process
# started at another time, is anybody's to remove; a slot that has no owner
# file yet is left alone for 30 seconds after it was first seen.

# The unattended default: what an unattended run reads when CC_TEST_SLOTS is
# unset or empty, in its grammar. Not measured yet, so off.
TS_UNATTENDED_SLOTS=0
# The host CPU count the default was measured on, set only when the default is
# a whole number; on a host with another count that number is read as auto.
TS_UNATTENDED_CPUS=""

TS_DIR=""
TS_N=0
TS_ON=0
TS_BROKEN=0
TS_INIT_KEY=""
TS_POOL_PID=""
TS_POOL_FP=""
TS_POOL_EPOCH=""
TS_SEQ=0
TS_TICKET=""
TS_TICKET_T0=0
TS_LASTP=0
TS_GOT=""
TS_MODE="exec"
TS_WAIT_TOTAL=0
TS_SEEN=""
TS_JS_SIG=0
TS_JS_CPID=""
# The wait cap when CC_TEST_SLOTS_WAIT_MAX does not set one: 3600 for the pool
# and the serial bundle, 300 for --run.
TS_WAIT_DEFAULT=3600
# A file holding the epoch the self-tests read instead of the clock; empty in
# every real run.
TS_CLOCK=""

ts_msg() {
  printf '%s: %s\n' "${TT_PREFIX:-test-slots}" "$1" >&2
}

ts_now() {
  if [ -n "$TS_CLOCK" ]; then cat "$TS_CLOCK"; else date +%s; fi
}

# Sets TS_ME to the pid of the shell that calls it, subshells included (bash
# 3.2 has no BASHPID): the command substitution's own process becomes sh, so
# sh's parent is the caller.
TS_ME=""
ts_self_pid() {
  TS_ME=$(exec sh -c 'echo "$PPID"')
}

# The start time of pid $1 as one line, in the C locale so every reader spells
# it the same; nothing when the pid is gone.
ts_fp() {
  local out
  out=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 0
  # shellcheck disable=SC2086
  set -- $out
  printf '%s' "$*"
}

# Every process of the host as "<pid> <start time>" lines, in the C locale;
# nothing while TS_PS_OFF is set, which only the self-test sets, to take the
# path a failed ps takes.
TS_PS_OFF=""
ts_ps_all() {
  [ -z "$TS_PS_OFF" ] || return 0
  LC_ALL=C ps -A -o pid=,lstart= 2>/dev/null
}

# The entry files among $1 whose processes are all gone, one per line, judged
# against ONE ps of the whole host rather than a ps per process. $1 holds the
# entries as "<file><TAB><pid><TAB><start time>" lines, plus one
# "<file><TAB><TAB>" line per file so a file naming no process reads as gone.
# The entries are read before the ps, so a process an entry names that is
# still alive is in it. The lookup is awk's: matching the pids against the ps
# output with bash's own pattern operators costs the square of its length,
# which on a busy host is seconds per pid. 1 with nothing printed when the ps
# came back empty.
ts_dead_entries() {
  local snap
  snap=$(ts_ps_all)
  [ -n "$snap" ] || return 1
  printf '%s\n--\n%s' "$snap" "$1" | awk -F '\t' '
    function words(s,    a, n, i, v) {
      n = split(s, a, " ")
      v = ""
      for (i = 1; i <= n; i++) v = v (i > 1 ? " " : "") a[i]
      return v
    }
    !sep {
      if ($0 == "--") { sep = 1; next }
      p = $0
      sub(/^ +/, "", p)
      q = p
      sub(/ .*$/, "", p)
      sub(/^[^ ]+/, "", q)
      fp[p] = words(q)
      next
    }
    $1 != "" {
      if (!($1 in st)) { st[$1] = 0; ord[++k] = $1 }
      v = words($3)
      if ($2 != "" && v != "" && ($2 in fp) && fp[$2] == v) st[$1] = 1
    }
    END { for (i = 1; i <= k; i++) if (!st[ord[i]]) print ord[i] }
  '
}

ts_cpus() {
  local c
  c=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  case "$c" in ''|*[!0-9]*) c=4 ;; esac
  [ "${#c}" -le 6 ] && [ "$((10#$c))" -ge 1 ] || c=4
  printf '%s' "$((10#$c))"
}

# The wait cap in seconds: CC_TEST_SLOTS_WAIT_MAX when it is a whole number,
# else $1 (3600 when not given).
ts_wait_max() {
  local v="${CC_TEST_SLOTS_WAIT_MAX:-}" d="${1:-3600}"
  case "$v" in ''|*[!0-9]*) v="$d" ;; esac
  [ "${#v}" -le 7 ] || v="$d"
  printf '%s' "$((10#$v))"
}

# Sets TS_N from CC_TEST_SLOTS, or, when it is unset or empty in an
# unattended run (CC_PIPELINE_RUN_ID not empty), from TS_UNATTENDED_SLOTS: 0
# (slots off) when the value read is empty or 0, max(4, CPUs) for auto, the
# number itself for a positive whole number, and 0 with a warning naming the
# variable read for anything else. A whole-number default measured on a host
# with another CPU count is read as auto.
ts_set_count() {
  local v="${CC_TEST_SLOTS:-}" name=CC_TEST_SLOTS c
  TS_N=0
  if [ -z "$v" ] && [ -n "${CC_PIPELINE_RUN_ID:-}" ]; then
    v="$TS_UNATTENDED_SLOTS"
    name=TS_UNATTENDED_SLOTS
    case "$v" in
      ''|*[!0-9]*) ;;
      *)
        if [ -n "$TS_UNATTENDED_CPUS" ] && [ "$TS_UNATTENDED_CPUS" != "$(ts_cpus)" ]; then v=auto; fi
        ;;
    esac
  fi
  case "$v" in
    '') return 0 ;;
    auto)
      c=$(ts_cpus)
      [ "$c" -ge 4 ] || c=4
      TS_N="$c"
      return 0
      ;;
    *[!0-9]*) ;;
    *)
      if [ "${#v}" -le 6 ]; then
        TS_N=$((10#$v))
        return 0
      fi
      ;;
  esac
  ts_msg "경고 — $name=$(printf %q "$v") 는 양의 정수·auto·0 이 아니다, 없는 것(꺼짐)으로 본다"
}

# Decides the store and the slot count for this process. $1 is the private
# store the caller uses when a self-test double stands (empty: none). A
# process keeps its ticket cells, its wait total and its ticket across calls.
ts_init() {
  local priv="${1:-}" me key unatt=0
  ts_self_pid
  me="$TS_ME"
  if [ "$TS_POOL_PID" != "$me" ]; then
    TS_POOL_PID="$me"
    TS_POOL_FP=$(ts_fp "$me")
    TS_POOL_EPOCH=""
    TS_SEQ=0
    TS_TICKET=""
    TS_WAIT_TOTAL=0
    TS_SEEN=""
    TS_INIT_KEY=""
  fi
  [ -z "${CC_PIPELINE_RUN_ID:-}" ] || unatt=1
  key="$priv|${CC_TEST_SLOTS:-}|${CC_TEST_SLOTS_DIR:-}|${CC_TEST_SLOT_HELD:-}|$unatt|${XDG_STATE_HOME:-}"
  [ "$key" != "$TS_INIT_KEY" ] || return 0
  TS_INIT_KEY="$key"
  TS_ON=0
  TS_BROKEN=0
  TS_DIR=""
  [ "${CC_TEST_SLOT_HELD:-}" != 1 ] || return 0
  ts_set_count
  [ "$TS_N" -gt 0 ] || return 0
  TS_ON=1
  if [ -n "${CC_TEST_SLOTS_DIR:-}" ]; then
    TS_DIR="$CC_TEST_SLOTS_DIR"
  elif [ -n "$priv" ]; then
    TS_DIR="$priv"
  elif [ -n "${XDG_STATE_HOME:-}" ] || [ -n "${HOME:-}" ]; then
    TS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/test-slots"
  fi
  if [ -z "$TS_DIR" ] || ! mkdir -p "$TS_DIR/queue" "$TS_DIR/weights" 2>/dev/null || [ -z "$TS_POOL_FP" ]; then
    TS_BROKEN=1
    ts_msg "경고 — 시험 자리 저장소($(ts_or_none "$TS_DIR"))를 쓸 수 없다, 자리 없이 띄운다"
  fi
  return 0
}

ts_or_none() {
  if [ -n "$1" ]; then printf '%s' "$1"; else printf '없음'; fi
}

# --- weights -------------------------------------------------------------------

ts_key_file() {
  printf '%s/weights/%s' "$TS_DIR" "${1//\//%2F}"
}

# The weight of job key $1: the file's whole number cut to 1..N, else 1.
ts_weight_read() {
  local f v=""
  if [ -z "$1" ]; then printf '1'; return 0; fi
  f=$(ts_key_file "$1")
  if [ -r "$f" ]; then IFS= read -r v < "$f"; fi
  case "$v" in ''|*[!0-9]*) v=1 ;; esac
  if [ "${#v}" -gt 6 ]; then v="$TS_N"; fi
  v=$((10#$v))
  [ "$v" -ge 1 ] || v=1
  [ "$v" -le "$TS_N" ] || v="$TS_N"
  printf '%s' "$v"
}

ts_weight_write() {
  local f tmp
  f=$(ts_key_file "$1")
  tmp=$(mktemp "$TS_DIR/weights/.w.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# The milliseconds of one `times` line (`0m1.250s 0m0.375s`); 1 when a field
# is not of that shape.
ts_times_ms() {
  local tok m s whole frac total=0
  for tok in $1; do
    case "$tok" in *m*s) ;; *) return 1 ;; esac
    m="${tok%%m*}"
    s="${tok#*m}"
    s="${s%s}"
    s="${s/,/.}"
    whole="${s%%.*}"
    frac=""
    case "$s" in *.*) frac="${s#*.}" ;; esac
    frac="${frac}000"
    frac="${frac:0:3}"
    case "$m$whole$frac" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$m" ] && [ -n "$whole" ] || return 1
    total=$((total + 10#$m * 60000 + 10#$whole * 1000 + 10#$frac))
  done
  printf '%s' "$total"
}

# The weight of a job whose children used the CPU of `times` line $1 over $2
# wall seconds: max(1, ceil(CPU / wall - 0.25)), in whole-number arithmetic.
# Nothing when the wall time is under 10 seconds or the line does not parse.
ts_weight_calc() {
  local cpu x d w
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  [ "$2" -ge 10 ] || return 0
  cpu=$(ts_times_ms "$1") || return 0
  x=$((4 * cpu - 1000 * $2))
  d=$((4000 * $2))
  if [ "$x" -le 0 ]; then
    w=1
  else
    w=$(((x + d - 1) / d))
    [ "$w" -ge 1 ] || w=1
  fi
  printf '%s' "$w"
}

# --- the store -------------------------------------------------------------------

# Removes a slot or a ticket by renaming it out of the way first, so no reader
# sees half of it. 1 when someone else took it first.
ts_rm() {
  local g
  g="${1%/*}/.gone.${1##*/}.$$.$RANDOM"
  mv "$1" "$g" 2>/dev/null || return 1
  rm -rf "$g"
}

# 0 when a pool or proc line of owner file $1 names a live process started at
# the time it records.
ts_owner_alive() {
  local kind pid fp
  while read -r kind pid fp; do
    case "$kind" in
      pool|proc)
        if [ -n "$pid" ] && [ -n "$fp" ] && [ "$(ts_fp "$pid")" = "$fp" ]; then return 0; fi
        ;;
    esac
  done < "$1"
  return 1
}

ts_ticket_alive() {
  local pid fp
  read -r pid fp < "$1" 2>/dev/null || [ -n "${pid:-}" ] || return 1
  [ -n "$pid" ] && [ -n "$fp" ] && [ "$(ts_fp "$pid")" = "$fp" ]
}

ts_seen_at() {
  local line
  while IFS= read -r line; do
    case "$line" in "$1="*) printf '%s' "${line#"$1="}"; return 0 ;; esac
  done <<EOF
$TS_SEEN
EOF
}

# Removes the slots and tickets of processes that are gone. The owner files
# and tickets are read here and judged together by ts_dead_entries; when its ps
# comes back empty each one is asked of ps per process, so a failed ps never
# makes every owner look gone. An empty owner file or ticket names nobody.
ts_reap() {
  local d f now ino id t seen="" ents="" files="" nents=0 kind pid fp dead tab='	' nl='
'
  now=$(ts_now)
  for d in "$TS_DIR"/slot-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/owner" ]; then
      f="$d/owner"
      # A file that went away between the listing and the read is skipped:
      # its slot was given back, and may already be someone else's again.
      if while read -r kind pid fp; do
        case "$kind" in pool|proc) ents="$ents$f$tab$pid$tab$fp$nl" ;; esac
      done 2>/dev/null < "$f"; then
        ents="$ents$f$tab$tab$nl"
        files="$files$f$nl"
        nents=$((nents + 1))
      fi
      continue
    fi
    # shellcheck disable=SC2046
    set -- $(ls -di "$d" 2>/dev/null)
    ino="${1:-0}"
    id="${d##*/}:$ino"
    t=$(ts_seen_at "$id")
    [ -n "$t" ] || t="$now"
    if [ $((now - t)) -ge 30 ]; then
      ts_rm "$d"
    else
      seen="$seen$id=$t
"
    fi
  done
  TS_SEEN="$seen"
  for f in "$TS_DIR"/queue/[0-9]*; do
    [ -f "$f" ] || continue
    pid=""
    fp=""
    { read -r pid fp; } 2>/dev/null < "$f"
    if [ -n "$pid" ]; then
      ents="$ents$f$tab$pid$tab$fp$nl"
    elif [ ! -f "$f" ]; then
      continue
    fi
    ents="$ents$f$tab$tab$nl"
    files="$files$f$nl"
    nents=$((nents + 1))
  done
  [ "$nents" -gt 0 ] || return 0
  if dead=$(ts_dead_entries "$ents"); then
    while IFS= read -r f; do
      case "$f" in
        '') ;;
        */owner) ts_rm "${f%/owner}" ;;
        *) ts_rm "$f" ;;
      esac
    done <<EOF
$dead
EOF
    return 0
  fi
  while IFS= read -r f; do
    case "$f" in
      '') ;;
      */owner) ts_owner_alive "$f" || ts_rm "${f%/owner}" ;;
      *) ts_ticket_alive "$f" || ts_rm "$f" ;;
    esac
  done <<EOF
$files
EOF
  return 0
}

# How many slots are taken (CPU shares).
ts_used() {
  local d n=0
  for d in "$TS_DIR"/slot-*; do
    [ -d "$d" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# How many live tickets stand before this pool's.
ts_ahead() {
  local f b mine="${TS_TICKET##*/}" n=0
  for f in "$TS_DIR"/queue/[0-9]*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    if [[ "$b" < "$mine" ]]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

ts_ticket_put() {
  local now tmp name
  now=$(ts_now)
  [ -n "$TS_POOL_EPOCH" ] || TS_POOL_EPOCH="$now"
  TS_SEQ=$((TS_SEQ + 1))
  name=$(printf '%010d-%010d-%06d' "$TS_POOL_EPOCH" "$TS_POOL_PID" "$TS_SEQ")
  tmp=$(mktemp "$TS_DIR/queue/.t.XXXXXX" 2>/dev/null) || return 1
  if printf '%s %s\n' "$TS_POOL_PID" "$TS_POOL_FP" > "$tmp" && mv -f "$tmp" "$TS_DIR/queue/$name"; then
    TS_TICKET="$TS_DIR/queue/$name"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

ts_release() {
  local n
  for n in $1; do
    ts_rm "$TS_DIR/$n"
  done
  return 0
}

# Takes $1 free slots for job $2, all or none; TS_GOT names them.
ts_grab() {
  local w="$1" job="$2" k=1 got=0 lim d now tmp fp
  TS_GOT=""
  now=$(ts_now)
  fp="$TS_POOL_FP"
  lim=$((TS_N + $(ts_used) + w))
  while [ "$got" -lt "$w" ] && [ "$k" -le "$lim" ]; do
    d="$TS_DIR/slot-$k"
    k=$((k + 1))
    mkdir "$d" 2>/dev/null || continue
    TS_GOT="${TS_GOT:+$TS_GOT }slot-$((k - 1))"
    got=$((got + 1))
    tmp="$d/.owner.$TS_POOL_PID"
    if ! { printf 'pool %s %s\n' "$TS_POOL_PID" "$fp"; printf 'job %s\n' "$job"; printf 'worktree %s\n' "$PWD"; printf 'at %s\n' "$now"; } > "$tmp" \
      || ! mv -f "$tmp" "$d/owner"; then
      ts_release "$TS_GOT"
      TS_GOT=""
      return 1
    fi
  done
  if [ "$got" -lt "$w" ]; then
    ts_release "$TS_GOT"
    TS_GOT=""
    return 1
  fi
  return 0
}

# Adds the processes $2... to the owner files of slots $1.
ts_owner_add() {
  local names="$1" n d tmp p salt
  shift
  salt="${1:-0}"
  for n in $names; do
    d="$TS_DIR/$n"
    [ -f "$d/owner" ] || continue
    tmp="$d/.owner.$salt"
    if { cat "$d/owner"; for p in "$@"; do printf 'proc %s %s\n' "$p" "$(ts_fp "$p")"; done; } > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$d/owner" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  done
  return 0
}

# One try for job $1 with weight key $2 (empty: weight 1). 0 when the job may
# start, with TS_MODE saying how: `exec` (slots off or nested: start it as
# before), `held` (TS_GOT names its slots; measure it and pass
# CC_TEST_SLOT_HELD=1 on), `free` (start it without a slot, measure nothing).
# 1 when it waits: call again after a while.
ts_slot_take() {
  local job="$1" key="$2" w now ahead used waited max
  TS_GOT=""
  TS_MODE="exec"
  [ "$TS_ON" = 1 ] || return 0
  TS_MODE="free"
  [ "$TS_BROKEN" != 1 ] || return 0
  w=$(ts_weight_read "$key")
  now=$(ts_now)
  if [ -z "$TS_TICKET" ]; then
    TS_TICKET_T0="$now"
    TS_LASTP="$now"
  fi
  if [ -z "$TS_TICKET" ] || [ ! -f "$TS_TICKET" ]; then
    if ! ts_ticket_put; then
      TS_TICKET=""
      ts_msg "경고 — 시험 자리 저장소 $TS_DIR 에 표를 둘 수 없다, 자리 없이 띄운다 — $job"
      return 0
    fi
  fi
  ts_reap
  if [ ! -f "$TS_TICKET" ] && ! ts_ticket_put; then
    TS_TICKET=""
    ts_msg "경고 — 시험 자리 저장소 $TS_DIR 에 표를 둘 수 없다, 자리 없이 띄운다 — $job"
    return 0
  fi
  ahead=$(ts_ahead)
  used=$(ts_used)
  waited=$((now - TS_TICKET_T0))
  if [ "$ahead" = 0 ] && [ $((TS_N - used)) -ge "$w" ] && ts_grab "$w" "$job"; then
    ts_rm "$TS_TICKET"
    TS_TICKET=""
    TS_WAIT_TOTAL=$((TS_WAIT_TOTAL + waited))
    TS_MODE="held"
    ts_msg "자리 잡음 $job (${waited}초 대기)"
    return 0
  fi
  max=$(ts_wait_max "$TS_WAIT_DEFAULT")
  if [ "$waited" -ge "$max" ]; then
    ts_rm "$TS_TICKET"
    TS_TICKET=""
    TS_WAIT_TOTAL=$((TS_WAIT_TOTAL + waited))
    ts_msg "경고 — 자리 대기 ${waited}초가 상한 ${max}초에 닿았다, 자리 없이 띄운다 — $job"
    return 0
  fi
  if [ $((now - TS_LASTP)) -ge "${TT_PROGRESS_SECS:-60}" ]; then
    ts_msg "자리 대기 $job — 사용 중 $used/$TS_N, 앞선 표 $ahead, 무게 $w"
    TS_LASTP="$now"
  fi
  TS_MODE=""
  return 1
}

# Waits, a second at a time, until job $1 may start.
ts_slot_wait() {
  while ! ts_slot_take "$1" "$2"; do
    sleep 1
  done
  return 0
}

# The weight key a job started in the current mode measures under: $1 when it
# holds slots, nothing otherwise.
ts_job_key() {
  if [ "$TS_MODE" = held ]; then printf '%s' "$1"; fi
}

# Removes this process's slots and tickets.
ts_release_mine() {
  local d f kind pid rest
  [ -n "$TS_DIR" ] && [ -d "$TS_DIR" ] || return 0
  ts_self_pid
  [ -n "$TS_POOL_PID" ] && [ "$TS_POOL_PID" = "$TS_ME" ] || return 0
  for d in "$TS_DIR"/slot-*; do
    [ -f "$d/owner" ] || continue
    kind=""
    pid=""
    read -r kind pid rest < "$d/owner" 2>/dev/null
    if [ "$kind" = pool ] && [ "$pid" = "$TS_POOL_PID" ]; then ts_rm "$d"; fi
  done
  for f in "$TS_DIR"/queue/[0-9]*-"$(printf '%010d' "$TS_POOL_PID")"-*; do
    [ -f "$f" ] && ts_rm "$f"
  done
  TS_TICKET=""
  TS_GOT=""
  return 0
}

# --- the job shell -----------------------------------------------------------------
#
# Runs "$@" as its child and ends with the child's exit status. bash holds a
# trap until a foreground child ends, so the child runs in the background and
# the shell waits for it; on TERM it sends the child TERM and waits again,
# which is how cleanup's TERM still reaches the job. With $1 `fg` (a job shell
# run in the foreground, as check-push's serial steps are) an INT is sent on as
# TERM the same way; a job shell started with `&` begins with INT ignored and
# can set no INT trap, so `bg` sets none. With a weight key in $2, the shell
# reads the children's CPU from `times` after the last wait — a file, because
# `times` inside a command substitution reports a fresh process — and records
# the job's weight. The job's processes are added to the owners of the slots
# TS_GOT names, so a slot outlives a pool that dies while its job runs.
ts_job_shell() {
  local how="$1" key="$2" rc t0 t1 tf l1="" l2="" w me
  shift 2
  TS_JS_SIG=0
  TS_JS_CPID=""
  trap 'TS_JS_SIG=1; [ -z "$TS_JS_CPID" ] || kill -TERM "$TS_JS_CPID" 2>/dev/null' TERM
  if [ "$how" = fg ]; then
    trap 'TS_JS_SIG=1; [ -z "$TS_JS_CPID" ] || kill -TERM "$TS_JS_CPID" 2>/dev/null' INT
  fi
  t0=$(ts_now)
  "$@" &
  TS_JS_CPID=$!
  [ "$TS_JS_SIG" = 0 ] || kill -TERM "$TS_JS_CPID" 2>/dev/null
  if [ -n "$TS_GOT" ]; then
    ts_self_pid
    me="$TS_ME"
    ts_owner_add "$TS_GOT" "$me" "$TS_JS_CPID"
  fi
  wait "$TS_JS_CPID"
  rc=$?
  while [ "$TS_JS_SIG" = 1 ]; do
    TS_JS_SIG=0
    if kill -0 "$TS_JS_CPID" 2>/dev/null; then
      wait "$TS_JS_CPID"
      rc=$?
    fi
  done
  if [ -n "$key" ] && tf=$(mktemp "${TMPDIR:-/tmp}/cc-test-slots-times.XXXXXX" 2>/dev/null); then
    times > "$tf"
    { IFS= read -r l1; IFS= read -r l2; } < "$tf"
    rm -f "$tf"
    t1=$(ts_now)
    w=$(ts_weight_calc "$l2" $((t1 - t0)))
    [ -z "$w" ] || ts_weight_write "$key" "$w"
  fi
  : "$l1"
  trap - TERM
  [ "$how" != fg ] || trap - INT
  return "$rc"
}

# --- the wrapper ---------------------------------------------------------------------
#
# Runs "$@" after $1 (weight key) and $2 (name) under a slot: as it is when an
# outer entry point already decided (CC_TEST_SLOT_HELD=1) or slots are off,
# else after waiting for a slot (capped at 300 seconds unless
# CC_TEST_SLOTS_WAIT_MAX says otherwise) with CC_TEST_SLOT_HELD=1 passed on.
# A held command runs in the job shell, which measures its weight and runs it
# with its standard input on /dev/null; a command started without a slot at the
# cap runs in the foreground, unmeasured. Ends with the command's exit status.
ts_run_wrap() {
  local key="$1" name="$2" rc
  shift 2
  [ "${1:-}" = "--" ] && shift
  if [ "$#" -eq 0 ]; then
    printf 'test-slots: 사용법 — --run <무게 키> <이름> -- <명령…>\n' >&2
    return 2
  fi
  if [ "${CC_TEST_SLOT_HELD:-}" = 1 ]; then exec "$@"; fi
  ts_init ""
  if [ "$TS_ON" != 1 ]; then exec "$@"; fi
  trap 'ts_release_mine' EXIT
  trap 'ts_release_mine; trap - EXIT; exit 130' INT
  trap 'ts_release_mine; trap - EXIT; exit 143' TERM
  TS_WAIT_DEFAULT=300
  ts_slot_wait "$name" "$key"
  CC_TEST_SLOT_HELD=1
  export CC_TEST_SLOT_HELD
  if [ "$TS_MODE" = held ]; then
    ts_job_shell fg "$key" "$@"
    rc=$?
    ts_release_mine
    trap - EXIT INT TERM
    return "$rc"
  fi
  trap - EXIT INT TERM
  ts_release_mine
  exec "$@"
}

# --- self-test ---------------------------------------------------------------------

ts_self_test() {
  local mode="${1:-}" passed=0 failed=0 T self out rc v pa pb pc dp cpus err f fpa w
  ok()  { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
  bad() { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
  check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got「$2」 want「$3」"; fi; }
  has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "「$3」 없음: $2" ;; esac; }
  hasnt() { case "$2" in *"$3"*) bad "$1" "「$3」 있음: $2" ;; *) ok "$1" ;; esac; }
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  for v in $(compgen -e); do
    case "$v" in CC_TEST_SLOT*) unset "$v" ;; esac
  done
  unset CC_PIPELINE_RUN_ID XDG_STATE_HOME
  T=$(mktemp -d "${TMPDIR:-/tmp}/test-slots-selftest.XXXXXX") || return 1
  T=$(cd "$T" && pwd)
  TMPDIR="$T/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
  TT_PREFIX="test-slots"
  TT_PROGRESS_SECS=60
  TS_CLOCK="$T/clock"
  printf '1000\n' > "$TS_CLOCK"
  clock() { printf '%s\n' "$1" > "$TS_CLOCK"; }
  # Live stand-ins for pools and jobs, and one pid that is gone.
  sleep 600 & pa=$!
  sleep 600 & pb=$!
  sleep 600 & pc=$!
  (exit 0) & dp=$!
  wait "$dp"
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  case "$cpus" in ''|*[!0-9]*) cpus=4 ;; esac
  [ "$cpus" -ge 4 ] || cpus=4

  # A fresh store with N slots, with this process as the pool.
  fresh() {
    rm -rf "$T/s"
    CC_TEST_SLOTS_DIR="$T/s"
    CC_TEST_SLOTS="$1"
    export CC_TEST_SLOTS_DIR CC_TEST_SLOTS
    TS_POOL_PID=""
    ts_init ""
  }
  # Stand-in pools: their ticket state, swapped in and out of the globals.
  pool_new() { eval "st_$1=\"\$2|\$3|0||0|0\""; }
  pool_in() {
    local s
    eval "s=\$st_$1"
    IFS='|' read -r TS_POOL_PID TS_POOL_EPOCH TS_SEQ TS_TICKET TS_TICKET_T0 TS_LASTP <<EOF
$s
EOF
    TS_POOL_FP=$(ts_fp "$TS_POOL_PID")
  }
  pool_out() { eval "st_$1=\"\$TS_POOL_PID|\$TS_POOL_EPOCH|\$TS_SEQ|\$TS_TICKET|\$TS_TICKET_T0|\$TS_LASTP\""; }
  # One try as pool $1 for job $2 with key $3. It runs in this shell, so the
  # pool's ticket state stays: TR is `<rc> <mode> <slots>`, and the slots it
  # took are kept in got_<pool>.
  try_as() {
    local r n
    pool_in "$1"
    ts_slot_take "$2" "${3:-}" 2>> "$T/err"
    r=$?
    pool_out "$1"
    eval "got_$1=\"\$TS_GOT\""
    n=0
    for v in $TS_GOT; do n=$((n + 1)); done
    TR="$r ${TS_MODE:--} $n"
  }
  queue_n() { find "$T/s/queue" -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' '; }

  # --- the store and the count ---------------------------------------------------
  mkdir -p "$T/repo"
  (cd "$T/repo" && git init -q) > /dev/null 2>&1
  out=$(cd "$T/repo" && unset CC_TEST_SLOTS_DIR && XDG_STATE_HOME="$T/xdg" && CC_TEST_SLOTS=auto && export XDG_STATE_HOME CC_TEST_SLOTS && ts_init "" && printf '%s' "$TS_DIR")
  check "저장소: 아무것도 없으면 XDG 상태 루트 아래 cc-cmds/test-slots" "$out" "$T/xdg/cc-cmds/test-slots"
  out=$(cd "$T/repo" && unset CC_TEST_SLOTS_DIR XDG_STATE_HOME && HOME="$T/home" && CC_TEST_SLOTS=auto && export HOME CC_TEST_SLOTS && ts_init "" && printf '%s' "$TS_DIR")
  check "저장소: XDG_STATE_HOME 이 없으면 ~/.local/state/cc-cmds/test-slots" "$out" "$T/home/.local/state/cc-cmds/test-slots"
  check "저장소: 공통 git 디렉터리 아래에는 만들지 않는다" "$([ -e "$T/repo/.git/cc-cmds-test-slots" ] && echo 있음 || echo 없음)" "없음"
  out=$(cd "$T/repo" && unset CC_TEST_SLOTS_DIR && CC_TEST_SLOTS=auto && export CC_TEST_SLOTS && ts_init "$T/priv" && printf '%s' "$TS_DIR")
  check "저장소: 대역이 서면 사적 저장소" "$out" "$T/priv"
  out=$(cd "$T/repo" && CC_TEST_SLOTS_DIR="$T/named" && CC_TEST_SLOTS=auto && export CC_TEST_SLOTS_DIR CC_TEST_SLOTS && ts_init "$T/priv" && printf '%s' "$TS_DIR")
  check "저장소: CC_TEST_SLOTS_DIR 이 사적 저장소보다 앞선다" "$out" "$T/named"

  # --- the unattended default ---------------------------------------------------------
  # What the constant above gives an unattended run, derived from it so the
  # assertions hold whatever the measurement set it to.
  case "$TS_UNATTENDED_SLOTS" in
    ''|0) v="0 0" ;;
    auto) v="1 $cpus" ;;
    *[!0-9]*) v="0 0" ;;
    *)
      if [ -n "$TS_UNATTENDED_CPUS" ] && [ "$TS_UNATTENDED_CPUS" != "$(ts_cpus)" ]; then v="1 $cpus"; else v="1 $((10#$TS_UNATTENDED_SLOTS))"; fi
      ;;
  esac
  out=$(unset CC_TEST_SLOTS && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: CC_TEST_SLOTS 가 없으면 TS_UNATTENDED_SLOTS 를 따른다" "$out" "|$v"
  out=$(TS_UNATTENDED_SLOTS=auto && unset CC_TEST_SLOTS && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: 기본값 auto 면 max(4, CPU 수)" "$out" "|1 $cpus"
  out=$(TS_UNATTENDED_SLOTS=auto && CC_TEST_SLOTS= && export CC_TEST_SLOTS && unset CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "대화형: 기본값이 켜져 있어도 CC_TEST_SLOTS 가 없으면 꺼짐" "$out" "|0 0"
  out=$(TS_UNATTENDED_SLOTS=auto && CC_TEST_SLOTS=0 && CC_PIPELINE_RUN_ID=r && export CC_TEST_SLOTS CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: 명시한 CC_TEST_SLOTS=0 이 기본값보다 앞서 끈다" "$out" "|0 0"
  out=$(TS_UNATTENDED_SLOTS=auto && CC_TEST_SLOTS=3 && CC_PIPELINE_RUN_ID=r && export CC_TEST_SLOTS CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: 명시한 CC_TEST_SLOTS=3 이 기본값보다 앞선다" "$out" "|1 3"
  out=$(TS_UNATTENDED_SLOTS=auto && unset CC_TEST_SLOTS CC_PIPELINE_RUN_ID && TS_POOL_PID="" && ts_init "$T/priv" && a="$TS_ON" \
    && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" && b="$TS_ON" \
    && unset CC_PIPELINE_RUN_ID && ts_init "$T/priv" && printf '%s %s %s' "$a" "$b" "$TS_ON")
  check "무인: 한 프로세스 안에서 무인 판별이 바뀌면 ts_init 이 다시 정한다" "$out" "0 1 0"
  out=$(TS_UNATTENDED_SLOTS=7 && TS_UNATTENDED_CPUS=$(($(ts_cpus) + 1)) && unset CC_TEST_SLOTS && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: 정수 기본값은 잰 CPU 수와 다른 호스트에서 auto 로 읽힌다" "$out" "|1 $cpus"
  out=$(TS_UNATTENDED_SLOTS=7 && TS_UNATTENDED_CPUS=$(ts_cpus) && unset CC_TEST_SLOTS && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "무인: 정수 기본값은 잰 CPU 수와 같은 호스트에서 그 정수" "$out" "|1 7"
  out=$(TS_UNATTENDED_SLOTS=abc && unset CC_TEST_SLOTS && CC_PIPELINE_RUN_ID=r && export CC_PIPELINE_RUN_ID && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  has "무인: 문법 밖 기본값은 TS_UNATTENDED_SLOTS 를 말해 경고한다" "$out" "TS_UNATTENDED_SLOTS=abc 는 양의 정수·auto·0 이 아니다"
  has "무인: 문법 밖 기본값은 꺼짐" "$out" "|0 0"
  out=$(unset CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "자리 수: 없으면 경고 없이 꺼짐" "$out" "|0 0"
  out=$(CC_TEST_SLOTS= && export CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "자리 수: 빈 값이면 경고 없이 꺼짐" "$out" "|0 0"
  out=$(CC_TEST_SLOTS=auto && export CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  check "자리 수: auto 면 max(4, CPU 수)" "$out" "|1 $cpus"
  out=$(CC_TEST_SLOTS=3 && export CC_TEST_SLOTS && ts_init "$T/priv" && printf '%s %s' "$TS_ON" "$TS_N")
  check "자리 수: CC_TEST_SLOTS=3" "$out" "1 3"
  out=$(CC_TEST_SLOTS=abc && export CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  has "자리 수: 정수가 아닌 값은 경고한다" "$out" "CC_TEST_SLOTS=abc 는 양의 정수·auto·0 이 아니다, 없는 것(꺼짐)으로 본다"
  has "자리 수: 정수가 아닌 값은 없는 것(꺼짐)으로 본다" "$out" "|0 0"
  out=$(CC_TEST_SLOTS=-2 && export CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  has "자리 수: 음수는 경고한다" "$out" "CC_TEST_SLOTS=-2 는 양의 정수·auto·0 이 아니다"
  has "자리 수: 음수도 없는 것(꺼짐)으로 본다" "$out" "|0 0"
  out=$(CC_TEST_SLOTS=AUTO && export CC_TEST_SLOTS && ts_init "$T/priv" 2>&1 && printf '|%s %s' "$TS_ON" "$TS_N")
  has "자리 수: 대문자 AUTO 는 auto 가 아니라 경고한다" "$out" "CC_TEST_SLOTS=AUTO 는 양의 정수·auto·0 이 아니다"
  has "자리 수: 대문자 AUTO 는 꺼짐" "$out" "|0 0"
  out=$(unset CC_TEST_SLOTS && rm -rf "$T/dflt" && ts_init "$T/dflt" && ts_slot_take "목표 x" "" 2>&1; printf '|%s %s %s %s' "$?" "$TS_ON" "$TS_MODE" "$(ls -A "$T/dflt" 2>/dev/null | wc -l | tr -d ' ')")
  check "기본: CC_TEST_SLOTS 가 없으면 기다리지 않고 exec 로 띄우며 저장소를 만들지 않는다" "$out" "|0 0 exec 0"
  out=$(CC_TEST_SLOTS=0 && export CC_TEST_SLOTS && rm -rf "$T/off" && ts_init "$T/off" && ts_slot_take "목표 x" "" 2>&1; printf '|%s %s %s %s' "$?" "$TS_ON" "$TS_MODE" "$(ls -A "$T/off" 2>/dev/null | wc -l | tr -d ' ')")
  check "끔: CC_TEST_SLOTS=0 이면 기다리지 않고 exec 로 띄우며 저장소를 만들지 않는다" "$out" "|0 0 exec 0"
  out=$(CC_TEST_SLOT_HELD=1 && CC_TEST_SLOTS=auto && export CC_TEST_SLOT_HELD CC_TEST_SLOTS && rm -rf "$T/held" && ts_init "$T/held" && ts_slot_take "목표 x" "" 2>&1; printf '|%s %s %s %s' "$?" "$TS_ON" "$TS_MODE" "$(ls -A "$T/held" 2>/dev/null | wc -l | tr -d ' ')")
  check "중첩: CC_TEST_SLOT_HELD=1 이면 자리를 잡지 않는다" "$out" "|0 0 exec 0"
  out=$(CC_TEST_SLOTS_DIR=/dev/null/x && CC_TEST_SLOTS=auto && export CC_TEST_SLOTS_DIR CC_TEST_SLOTS && ts_init "" 2>&1 && ts_slot_take "목표 x" "" 2>&1; printf '|%s %s' "$?" "$TS_MODE")
  has "고장: 쓸 수 없는 저장소는 경고하고" "$out" "를 쓸 수 없다, 자리 없이 띄운다"
  has "고장: 자리 없이 띄운다" "$out" "|0 free"

  # --- the start-time fingerprint ----------------------------------------------------
  v=$(ts_fp "$pa")
  out=$(LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 LC_TIME=fr_FR.UTF-8 ts_fp "$pa")
  if [ -n "$v" ] && [ "$out" = "$v" ]; then ok "지문: 비 C 로케일에서도 같은 시작 시각 지문"; else bad "지문: 비 C 로케일에서도 같은 시작 시각 지문" "「${out}」 「${v}」"; fi
  check "지문: 없는 pid 는 빈 지문" "$(ts_fp "$dp")" ""
  tb='	'
  out=$(ts_dead_entries "fa${tb}${tb}
fa${tb}$pa${tb}$v
fb${tb}${tb}
fb${tb}$dp${tb}$v
fc${tb}${tb}
fc${tb}$pa${tb}Mon Jan 1 00:00:00 2001
fd${tb}${tb}
fe${tb}${tb}
fe${tb}$dp${tb}$v
fe${tb}$pb${tb}$(ts_fp "$pb")
ff${tb}${tb}
ff${tb}$pa${tb}$(printf '%s' "$v" | sed 's/ /  /g')
" | tr '\n' ' ')
  check "판정: ps 한 번으로 죽은 pid·재사용된 pid·프로세스 없는 항목만 고른다" "$out" "fb fc fd "
  TS_PS_OFF=1
  ts_dead_entries "fa${tb}$pa${tb}$v
" > /dev/null
  check "판정: 프로세스 표가 비면 1 로 끝나 호출자가 pid 마다 묻는다" "$?" "1"
  TS_PS_OFF=""

  # --- weights --------------------------------------------------------------------------
  fresh 3
  ts_weight_write "make:run/scripts/x.sh" 2
  check "무게: 키의 / 를 %2F 로 바꾼 한 칸 이름" "$(ls "$T/s/weights")" "make:run%2Fscripts%2Fx.sh"
  check "무게: 쓴 값을 읽는다" "$(ts_weight_read "make:run/scripts/x.sh")" "2"
  check "무게: 없는 파일은 1" "$(ts_weight_read "make:none")" "1"
  printf 'x\n' > "$T/s/weights/make:bad"
  check "무게: 깨진 파일은 1" "$(ts_weight_read "make:bad")" "1"
  printf '0\n' > "$T/s/weights/make:zero"
  check "무게: 0 은 1" "$(ts_weight_read "make:zero")" "1"
  printf '99\n' > "$T/s/weights/make:big"
  check "무게: N 을 넘으면 N" "$(ts_weight_read "make:big")" "3"
  check "무게: 키 없음은 1" "$(ts_weight_read "")" "1"
  check "무게 계산: CPU 12.6초 / 10초 → 2" "$(ts_weight_calc "0m10.000s 0m2.600s" 10)" "2"
  check "무게 계산: 1.25 경계는 1" "$(ts_weight_calc "0m12.500s 0m0.000s" 10)" "1"
  check "무게 계산: 10초 미만은 갱신하지 않는다" "$(ts_weight_calc "1m0.000s 0m0.000s" 9)" ""
  check "무게 계산: 분 자리와 쉼표 소수" "$(ts_weight_calc "1m0,000s 0m0.000s" 20)" "3"

  # --- first come, pool by pool ----------------------------------------------------------
  fresh 1
  : > "$T/err"
  pool_new A "$pa" 100
  pool_new B "$pb" 101
  try_as A "목표 a1" ""
  check "FIFO: A 의 첫 잡이 자리를 잡는다" "$TR" "0 held 1"
  st_A_got="$got_A"
  clock 1001
  try_as B "목표 b1" ""
  check "FIFO: B 는 기다린다" "$TR" "1 - 0"
  try_as A "목표 a2" ""
  check "FIFO: A 의 둘째 잡도 자리가 없어 기다린다" "$TR" "1 - 0"
  pool_in B
  check "FIFO: A 의 다음 표가 먼저 온 풀의 표라 B 의 표 앞에 선다" "$(ts_ahead)" "1"
  ts_release "$st_A_got"
  try_as B "목표 b1" ""
  check "FIFO: A 의 자리를 놓으면 B 는 여전히 기다린다" "$TR" "1 - 0"
  try_as A "목표 a2" ""
  check "FIFO: A 의 둘째 잡이 잡는다" "$TR" "0 held 1"
  has "출력: 잡으면 자리 잡음 줄" "$(cat "$T/err")" "test-slots: 자리 잡음 목표 a1 (0초 대기)"
  clock 1000

  # --- the front ticket waits whole, and the tickets behind it wait too -----------------
  fresh 3
  : > "$T/err"
  pool_new C "$pc" 90
  pool_new A "$pa" 100
  pool_new B "$pb" 101
  ts_weight_write "make:heavy" 3
  try_as C "목표 c" ""
  check "무게: C 가 무게 1 로 하나 잡는다" "$TR" "0 held 1"
  st_C_got="$got_C"
  try_as A "목표 heavy" "make:heavy"
  check "앞 표: 빈 자리 2 < 무게 3 이면 A 는 하나도 잡지 않는다" "$TR" "1 - 0"
  try_as B "목표 light" ""
  check "앞 표: 뒤 표 B 는 무게 1 이어도 앞지르지 않는다" "$TR" "1 - 0"
  check "앞 표: 잡힌 자리는 그대로 1" "$(ts_used)" "1"
  ts_release "$st_C_got"
  try_as A "목표 heavy" "make:heavy"
  check "무게 w: A 가 셋을 한꺼번에 잡는다" "$TR" "0 held 3"
  st_A_got="$got_A"
  try_as B "목표 light" ""
  check "무게 w: B 는 아직 기다린다" "$TR" "1 - 0"
  ts_release "$st_A_got"
  check "무게 w: 놓으면 셋을 모두 놓는다" "$(ts_used)" "0"
  try_as B "목표 light" ""
  check "무게 w: 그 뒤 B 가 잡는다" "$TR" "0 held 1"

  # --- reaping ------------------------------------------------------------------------------
  fresh 4
  owner() { mkdir -p "$T/s/$1"; printf '%s' "$2" > "$T/s/$1/owner"; }
  fpa=$(ts_fp "$pa")
  owner slot-1 "pool $dp $fpa
"
  owner slot-2 "pool $pa Mon Jan  1 00:00:00 2001
"
  owner slot-3 "pool $dp $fpa
job 목표 x
proc $pb $(ts_fp "$pb")
"
  owner slot-4 "pool $pa $fpa
"
  printf '%s %s\n' "$dp" "$fpa" > "$T/s/queue/0000000001-$(printf '%010d' "$dp")-000001"
  printf '%s Mon Jan 1 00:00:00 2001\n' "$pa" > "$T/s/queue/0000000001-$(printf '%010d' "$pa")-000001"
  printf '%s %s\n' "$pb" "$(ts_fp "$pb")" > "$T/s/queue/0000000002-$(printf '%010d' "$pb")-000001"
  ts_reap
  check "회수: 죽은 소유자와 pid 재사용은 지우고, 풀이 죽어도 잡이 살아 있으면 남긴다" "$(cd "$T/s" && ls -d slot-* | tr '\n' ' ')" "slot-3 slot-4 "
  check "회수: 죽은 pid 와 재사용된 pid 의 표는 지우고 산 표는 남긴다" "$(cd "$T/s/queue" && ls | tr '\n' ' ')" "0000000002-$(printf '%010d' "$pb")-000001 "
  fresh 4
  owner slot-1 "pool $dp $fpa
"
  owner slot-2 "pool $pa $fpa
"
  owner slot-3 "job 목표 x
"
  printf '%s %s\n' "$dp" "$fpa" > "$T/s/queue/0000000001-$(printf '%010d' "$dp")-000001"
  : > "$T/s/queue/0000000001-0000000001-000001"
  printf '%s %s\n' "$pb" "$(ts_fp "$pb")" > "$T/s/queue/0000000002-$(printf '%010d' "$pb")-000001"
  TS_PS_OFF=1
  ts_reap
  TS_PS_OFF=""
  check "회수: 프로세스 표가 비면 pid 마다 물어 죽은 자리와 프로세스 없는 자리를 지운다" "$(cd "$T/s" && ls -d slot-* | tr '\n' ' ')" "slot-2 "
  check "회수: 프로세스 표가 비면 pid 마다 물어 죽은 표와 빈 표를 지운다" "$(cd "$T/s/queue" && ls | tr '\n' ' ')" "0000000002-$(printf '%010d' "$pb")-000001 "
  fresh 4
  owner slot-1 "job 목표 x
"
  : > "$T/s/queue/0000000001-0000000001-000001"
  printf '%s %s\n' "$pb" "$(ts_fp "$pb")" > "$T/s/queue/0000000002-$(printf '%010d' "$pb")-000001"
  ts_reap
  check "회수: 프로세스를 적지 않은 owner 의 자리는 지운다" "$(cd "$T/s" && ls -d slot-* 2>/dev/null | tr '\n' ' ')" ""
  check "회수: 빈 표는 지운다" "$(cd "$T/s/queue" && ls | tr '\n' ' ')" "0000000002-$(printf '%010d' "$pb")-000001 "
  clock 2000
  mkdir "$T/s/slot-9"
  ts_reap
  clock 2029
  ts_reap
  check "회수: owner 없는 자리는 29초째에 남는다" "$([ -d "$T/s/slot-9" ] && echo 남음 || echo 없음)" "남음"
  clock 2030
  ts_reap
  check "회수: owner 없는 자리는 30초에 지운다" "$([ -d "$T/s/slot-9" ] && echo 남음 || echo 없음)" "없음"
  clock 1000

  # --- the wait cap and the progress line ---------------------------------------------------
  fresh 1
  : > "$T/err"
  CC_TEST_SLOTS_WAIT_MAX=50
  export CC_TEST_SLOTS_WAIT_MAX
  TT_PROGRESS_SECS=5
  pool_new C "$pc" 90
  pool_new A "$pa" 100
  try_as C "목표 c" ""
  try_as A "목표 w" "make:w"
  check "상한: 자리가 차면 기다린다" "$TR" "1 - 0"
  hasnt "출력: 주기 전에는 대기 줄이 없다" "$(cat "$T/err")" "자리 대기 목표 w"
  clock 1005
  try_as A "목표 w" "make:w"
  has "출력: 대기 줄" "$(cat "$T/err")" "test-slots: 자리 대기 목표 w — 사용 중 1/1, 앞선 표 0, 무게 1"
  clock 1049
  try_as A "목표 w" "make:w"
  check "상한: 49초째는 아직 기다린다" "$TR" "1 - 0"
  clock 1050
  try_as A "목표 w" "make:w"
  check "상한: 50초에 자리 없이 띄운다" "$TR" "0 free 0"
  has "상한: 경고 줄" "$(cat "$T/err")" "test-slots: 경고 — 자리 대기 50초가 상한 50초에 닿았다, 자리 없이 띄운다 — 목표 w"
  check "상한: 자기 표를 지운다" "$(find "$T/s/queue" -name "*-$(printf '%010d' "$pa")-*" | wc -l | tr -d ' ')" "0"
  pool_in A
  check "상한: 자리 없이 띄운 잡은 무게를 재지 않는다" "$(ts_job_key "make:w")" ""
  (ts_job_shell bg "$(ts_job_key "make:w")" sh -c "printf '1080\n' > '$TS_CLOCK'")
  check "상한: 무게 파일이 생기지 않는다" "$([ -f "$T/s/weights/make:w" ] && echo 있음 || echo 없음)" "없음"
  unset CC_TEST_SLOTS_WAIT_MAX
  TT_PROGRESS_SECS=60
  clock 1000

  # --- the job shell --------------------------------------------------------------------------
  fresh 2
  (ts_job_shell bg "" sh -c 'exit 5')
  check "잡 셸: 자식의 종료 코드로 끝난다" "$?" "5"
  (ts_job_shell bg "make:j" sh -c "printf '1020\n' > '$TS_CLOCK'")
  check "잡 셸: 벽시계 20초면 무게를 쓴다" "$(cat "$T/s/weights/make:j" 2>/dev/null)" "1"
  clock 1000
  (ts_job_shell bg "make:k" sh -c "printf '1005\n' > '$TS_CLOCK'")
  check "잡 셸: 10초 미만이면 무게를 쓰지 않는다" "$([ -f "$T/s/weights/make:k" ] && echo 있음 || echo 없음)" "없음"
  clock 1000
  (ts_job_shell bg "" sh -c "echo \$\$ > '$T/child.pid'; trap 'echo got-term >> \"$T/js.log\"; kill \$sp 2>/dev/null; exit 9' TERM; sleep 60 & sp=\$!; wait \$sp") &
  w=$!
  for f in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$T/child.pid" ] && break
    sleep 1
  done
  sleep 1
  kill -TERM "$w" 2>/dev/null
  wait "$w"
  rc=$?
  check "잡 셸: TERM 을 자식에게 넘기고 자식의 종료 코드로 끝난다" "$rc $(cat "$T/js.log" 2>/dev/null)" "9 got-term"
  ts_slot_take "목표 o" "" 2>/dev/null
  (ts_job_shell bg "" sh -c 'exit 0')
  has "잡 셸: 잡의 프로세스를 자리 owner 에 더한다" "$(cat "$T/s/$TS_GOT/owner")" "proc "
  ts_release "$TS_GOT"

  # --- cleanup gives back this process's slots and tickets -----------------------------------
  fresh 4
  ts_weight_write "make:two" 2
  ts_slot_take "목표 two" "make:two" 2>/dev/null
  ts_ticket_put
  printf '%s %s\n' "$pb" "$(ts_fp "$pb")" > "$T/s/queue/0000000002-$(printf '%010d' "$pb")-000001"
  check "정리 전: 자리 둘과 표 둘" "$(ts_used) $(queue_n)" "2 2"
  ts_release_mine
  check "정리: 자기 자리와 표를 모두 지우고 남의 표는 남긴다" "$(ts_used) $(queue_n)" "0 1"

  # --- the wrapper ------------------------------------------------------------------------
  # Each branch runs in a subshell of this one, so the clock file still stands
  # in for the clock; the command prints what it saw of CC_TEST_SLOT_HELD and of
  # its standard input. slots_n counts the slots and tickets left in a store.
  slots_n() { find "$1" \( -name 'slot-*' -o -path '*/queue/[0-9]*' \) 2>/dev/null | wc -l | tr -d ' '; }
  probe="echo \"held=\${CC_TEST_SLOT_HELD:-unset}\"; read -r l || l=none; echo \"in=\$l\""
  unset CC_TEST_SLOTS CC_TEST_SLOTS_DIR
  rm -rf "$T/w"
  out=$(printf 'line\n' | (CC_TEST_SLOTS=0 CC_TEST_SLOTS_DIR="$T/w" && export CC_TEST_SLOTS CC_TEST_SLOTS_DIR && ts_run_wrap "make:w" "목표 w" -- sh -c "$probe; exit 3") 2>&1; printf '|%s' "$?")
  check "감싸기 끔: 환경과 표준 입력을 바꾸지 않고 명령의 종료 코드로 끝난다" "$(printf '%s' "$out" | tr '\n' ' ')" "held=unset in=line |3"
  check "감싸기 끔: 저장소를 만들지 않는다" "$([ -e "$T/w" ] && echo 있음 || echo 없음)" "없음"
  out=$(printf 'line\n' | (CC_TEST_SLOT_HELD=1 CC_TEST_SLOTS=2 CC_TEST_SLOTS_DIR="$T/w" && export CC_TEST_SLOT_HELD CC_TEST_SLOTS CC_TEST_SLOTS_DIR && ts_run_wrap "make:w" "목표 w" -- sh -c "$probe; exit 4") 2>&1; printf '|%s' "$?")
  check "감싸기 중첩: 바깥이 정했으면 묻지 않고 그대로 띄운다" "$(printf '%s' "$out" | tr '\n' ' ')" "held=1 in=line |4"
  check "감싸기 중첩: 저장소를 만들지 않는다" "$([ -e "$T/w" ] && echo 있음 || echo 없음)" "없음"
  clock 1000
  out=$(printf 'line\n' | (CC_TEST_SLOTS=2 CC_TEST_SLOTS_DIR="$T/w" && export CC_TEST_SLOTS CC_TEST_SLOTS_DIR && ts_run_wrap "make:held" "목표 held" -- sh -c "$probe; printf '1020\n' > '$TS_CLOCK'; exit 5") 2>&1; printf '|%s' "$?")
  has "감싸기 held: 자리를 잡는다" "$out" "test-slots: 자리 잡음 목표 held (0초 대기)"
  has "감싸기 held: CC_TEST_SLOT_HELD=1 을 넘기고 표준 입력은 /dev/null" "$(printf '%s' "$out" | tr '\n' ' ')" "held=1 in=none "
  has "감싸기 held: 명령의 종료 코드로 끝난다" "$out" "|5"
  check "감싸기 held: 무게를 잰다" "$(cat "$T/w/weights/make:held" 2>/dev/null)" "1"
  check "감싸기 held: 자리와 표를 돌려준다" "$(slots_n "$T/w")" "0"
  clock 1000
  rm -rf "$T/w"
  mkdir -p "$T/w/slot-1"
  printf 'pool %s %s\n' "$pa" "$(ts_fp "$pa")" > "$T/w/slot-1/owner"
  out=$(printf 'line\n' | (CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/w" CC_TEST_SLOTS_WAIT_MAX=0 && export CC_TEST_SLOTS CC_TEST_SLOTS_DIR CC_TEST_SLOTS_WAIT_MAX && ts_run_wrap "make:free" "목표 free" -- sh -c "$probe; printf '1020\n' > '$TS_CLOCK'; exit 6") 2>&1; printf '|%s' "$?")
  has "감싸기 free: 상한 경고를 남긴다" "$out" "자리 대기 0초가 상한 0초에 닿았다, 자리 없이 띄운다 — 목표 free"
  has "감싸기 free: CC_TEST_SLOT_HELD=1 을 넘기고 표준 입력은 그대로" "$(printf '%s' "$out" | tr '\n' ' ')" "held=1 in=line "
  has "감싸기 free: 명령의 종료 코드로 끝난다" "$out" "|6"
  check "감싸기 free: 무게를 재지 않는다" "$([ -f "$T/w/weights/make:free" ] && echo 있음 || echo 없음)" "없음"
  check "감싸기 free: 자기 표를 남기지 않는다" "$(slots_n "$T/w")" "1"
  clock 1000
  check "감싸기: 대기 상한 기본은 300초" "$(TS_WAIT_DEFAULT=300 && ts_wait_max "$TS_WAIT_DEFAULT")" "300"
  check "감싸기: 풀과 직렬 단계의 대기 상한 기본은 3600초 그대로" "$(ts_wait_max "$TS_WAIT_DEFAULT")" "3600"
  # A TERM while waiting gives the ticket back; the only slot stays someone
  # else's, so the wrapper waits until the signal comes.
  : > "$T/err"
  (CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/w" && export CC_TEST_SLOTS CC_TEST_SLOTS_DIR && ts_run_wrap "make:wt" "목표 wt" -- sh -c 'exit 0' 2>> "$T/err") &
  w=$!
  for f in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(slots_n "$T/w")" -ge 2 ] && break
    sleep 1
  done
  kill -TERM "$w" 2>/dev/null
  wait "$w"
  rc=$?
  check "감싸기: 기다리는 중에 받은 TERM 은 표를 돌려주고 143 으로 끝난다" "$rc $(slots_n "$T/w")" "143 1"
  # A TERM while the command runs reaches the command, and the slot comes back.
  rm -rf "$T/w" "$T/child.pid" "$T/js.log"
  (CC_TEST_SLOTS=2 CC_TEST_SLOTS_DIR="$T/w" && export CC_TEST_SLOTS CC_TEST_SLOTS_DIR && ts_run_wrap "make:rt" "목표 rt" -- sh -c "echo \$\$ > '$T/child.pid'; trap 'echo got-term >> \"$T/js.log\"; kill \$sp 2>/dev/null; exit 9' TERM; sleep 60 & sp=\$!; wait \$sp" 2>/dev/null) &
  w=$!
  for f in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$T/child.pid" ] && break
    sleep 1
  done
  sleep 1
  kill -TERM "$w" 2>/dev/null
  wait "$w"
  rc=$?
  check "감싸기: 명령이 도는 중에 받은 TERM 을 명령에 넘기고 그 종료 코드로 끝난다" "$rc $(cat "$T/js.log" 2>/dev/null)" "9 got-term"
  check "감싸기: 명령이 도는 중에 받은 TERM 뒤에도 자리를 돌려준다" "$(slots_n "$T/w")" "0"
  rm -rf "$T/w"
  out=$(env -u CC_TEST_SLOTS -u CC_PIPELINE_RUN_ID bash "$self" --run "make:x" "목표 x" -- sh -c 'echo "held=${CC_TEST_SLOT_HELD:-unset}"; exit 7' 2>&1; printf '|%s' "$?")
  check "감싸기: 스크립트로 부른 꺼진 감싸기는 명령을 그대로 띄운다" "$(printf '%s' "$out" | tr '\n' ' ')" "held=unset |7"
  out=$(bash "$self" --run "make:x" 2>&1; printf '|%s' "$?")
  has "감싸기: 명령이 없으면 사용법을 말하고 2 로 끝난다" "$out" "|2"

  # --- the test-gate entry point -----------------------------------------------------------
  # The suite next to this file asks for a slot once when it runs sections and
  # never when it runs none, from its own path or from a copy kept elsewhere.
  f="$(cd "$(dirname "$self")/.." && pwd)"
  if [ -f "$f/scripts/test-gate.sh" ] && [ "$mode" != inner ]; then
    rm -rf "$T/g"
    mkdir -p "$T/g"
    env -u CC_TEST_SLOT_HELD CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/g/store" bash "$f/scripts/test-gate.sh" --list > /dev/null 2>&1
    env -u CC_TEST_SLOT_HELD CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/g/store" bash "$f/scripts/test-gate.sh" --sections 0a --cut-digest > /dev/null 2>&1
    check "test-gate 진입: --list·--cut-digest 는 저장소를 건드리지 않는다" "$(ls -A "$T/g" | wc -l | tr -d ' ')" "0"
    (cd "$f" && env -u CC_TEST_SLOT_HELD CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/g/store" bash scripts/test-gate.sh --sections 0a > /dev/null 2> "$T/g/err")
    rc=$?
    check "test-gate 진입: --sections 실행은 통과하고 자리를 한 번만 잡는다" "$rc $(grep -c '자리 잡음' "$T/g/err")" "0 1"
    mkdir "$T/g/copy" && cp "$f/scripts/test-gate.sh" "$T/g/copy/test-gate.sh"
    (cd "$f" && env -u CC_TEST_SLOT_HELD CC_TEST_SLOTS=1 CC_TEST_SLOTS_DIR="$T/g/store" CC_TEST_GATE_REPO_ROOT="$f" bash "$T/g/copy/test-gate.sh" --sections 0a > /dev/null 2> "$T/g/err2")
    rc=$?
    check "test-gate 진입: 저장소 밖 사본도 통과하고 자리를 한 번만 잡는다" "$rc $(grep -c '자리 잡음' "$T/g/err2")" "0 1"
    check "test-gate 진입: 끝나면 자리와 표가 남지 않는다" "$(slots_n "$T/g/store")" "0"
    rm -rf "$T/g"
  fi

  # --- inherited variables do not change the results -----------------------------------------
  if [ "$mode" != inner ]; then
    out=$(env CC_TEST_SLOT_HELD=1 CC_TEST_SLOTS_DIR="$T/inherited" CC_TEST_SLOTS=abc CC_PIPELINE_RUN_ID=inherited XDG_STATE_HOME="$T/inherited-state" bash "$self" --self-test-inner 2>&1)
    rc=$?
    has "물려받음: CC_TEST_SLOT_HELD=1·CC_TEST_SLOTS_DIR·CC_PIPELINE_RUN_ID 를 물려받고 띄워도 같은 결과" "$rc $out" "0 "
    has "물려받음: 실패 0" "$out" " passed, 0 failed"
    hasnt "물려받음: FAIL 줄이 없다" "$out" "FAIL:"
    check "물려받음: 물려받은 저장소를 건드리지 않는다" "$([ -e "$T/inherited" ] || [ -e "$T/inherited-state" ] && echo 있음 || echo 없음)" "없음"
  fi

  kill "$pa" "$pb" "$pc" 2>/dev/null
  wait "$pa" "$pb" "$pc" 2>/dev/null
  rm -rf "$T"
  printf 'test-slots self-test: %d passed, %d failed\n' "$passed" "$failed"
  # A floor on the count, so a refactor that silently skips cases cannot pass.
  if [ "$mode" = inner ]; then w=105; else w=113; fi
  if [ "$passed" -lt "$w" ]; then
    printf 'test-slots self-test: 통과 수 %d 가 하한 %d 에 못 미칩니다\n' "$passed" "$w" >&2
    return 1
  fi
  [ "$failed" = "0" ]
}

# --- main ----------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    --self-test) ts_self_test; exit $? ;;
    --self-test-inner) ts_self_test inner; exit $? ;;
    --run)
      if [ "$#" -lt 3 ]; then
        printf 'test-slots: 사용법 — --run <무게 키> <이름> -- <명령…>\n' >&2
        exit 2
      fi
      shift
      ts_run_wrap "$@"
      exit $?
      ;;
    *) printf 'test-slots: 사용법 — --self-test | --run <무게 키> <이름> -- <명령…>\n' >&2; exit 2 ;;
  esac
fi
