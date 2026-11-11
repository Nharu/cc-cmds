#!/usr/bin/env bash
#
# feed.sh — the run's progress channel. Reads the ledger on a fixed interval and
# prints ONE LINE per boundary event and per state transition, to stdout. The
# lead session arms it with `Monitor(persistent: true, description: "autopilot
# <run-id>")`, and each printed line becomes a conversation message there.
#
# WHY A NEW SCRIPT AND NOT AN ARM OF THE WATCHER. Piping the watcher's own stdout
# into the monitor produces roughly one notification per minute — its heartbeat
# is per-pass — which is the flood the channel exists to avoid. That is not the
# decisive reason though. Extending the watcher forces TWO watcher instances onto
# one run directory, and they contend over `watch.state`, `watch.pid`, the
# `announced-*` once-markers and `stall`. Duplicate run-scope `blocked` rows are
# an input to the termination condition, so the contention can stop a run from
# ever finishing. Merging them into one and letting the monitor raise the banners
# instead moves the banner seat inside a session, which is the arrangement the
# router's own invariants exist to prevent.
#
# THE BOUNDARY: THE WATCHER JUDGES AND THIS RELAYS. Nothing here is written for
# another reader to consume, and no stall threshold is re-implemented. The
# channel is a pure projection of the ledger, so it can say nothing the ledger
# does not — which is also why the morning report is not replaced by it.
#
# THE FENCE, AND IT CARRIES WEIGHT RATHER THAN BEING TIDY. This file does NOT
# source `notify-run.sh`, and it names neither of that file's two emitter
# functions anywhere — not even inside a comment, so the check holding this
# fence can be an exact count of zero rather than a judgement about context.
# Both the gate and the watcher do source it; this one structurally cannot raise
# a banner, which is what makes "the channel never decides what reaches the
# user" a property of the file rather than a promise in its header.
# `liveness.sh` IS sourced — it holds process and ledger predicates and no
# notification path at all, and re-deriving `cc_proc_fingerprint` here would be
# a second spelling of an identity two processes have to agree on.
#
# The banner-site lint counts occurrences of the notifier BINARY's name, so it
# cannot see a sourcing path at all; the assertions in `test-run.sh` are what
# actually hold this fence, and they are load-bearing rather than supplementary.
#
# NO NEW THRESHOLDS. The poll interval is the watcher's pinned `--interval 60`
# and the silence floor is its pinned `--stall`, used as-is. A fifth threshold
# would be structurally invisible to the lint that pins the other four, which is
# the defect that check's own header says it exists to prevent.
#
# Usage:
#   feed.sh --run-dir <dir> --ledger <path> [--interval <sec>] [--stall <sec>]
#           [--once]
#
# Exit codes:
#   0 — ran, or another live feed already holds the lock (see `feed.lock.d`), or
#       reclaimed a lock whose holder is gone
#   2 — bad arguments
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -uo pipefail

feed_src=$0
case "$feed_src" in
  */*) feed_src=${feed_src%/*}; [ -n "$feed_src" ] || feed_src=/ ;;
  *) feed_src=. ;;
esac
FEED_DIR=$(cd "$feed_src" && pwd)
# shellcheck source=/dev/null
. "$FEED_DIR/liveness.sh"
# The run's version pin, for the same hop the gate and the watcher take.
# shellcheck source=/dev/null
. "$FEED_DIR/pin.sh"
# The display zone every line's clock is drawn in (`CC_CMDS_AUTOPILOT_TZ`).
# shellcheck source=/dev/null
. "$FEED_DIR/display-tz.sh"
cc_display_tz_load

FEED_ARGV=("$@")

RUN_DIR=""; LEDGER=""; INTERVAL=60; STALL=1200; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stall)    STALL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    *) printf 'feed: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ] || { printf 'feed: --run-dir 는 필수입니다\n' >&2; exit 2; }
[ -n "$LEDGER" ]  || { printf 'feed: --ledger 는 필수입니다\n' >&2; exit 2; }

# THE HOP, ahead of the cursor, the state file, the heartbeat and the lock — the
# same ordering rule the watcher and the gate follow, and for the same reason:
# `exec` keeps the pid and the fingerprint but drops EXIT traps, so a lock taken
# before it would be held by a record nothing can release.
feed_hop_t=""; feed_hop_rc=0
feed_hop_t=$(pin_hop_target "$RUN_DIR" "$FEED_DIR") || feed_hop_rc=$?
case "$feed_hop_rc" in
  0) exec "${BASH:-/bin/bash}" "$feed_hop_t/feed.sh" ${FEED_ARGV[@]+"${FEED_ARGV[@]}"} ;;
  2) printf 'feed: plugin-pin 은 있는데 사본이 없습니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
  3) printf 'feed: plugin-pin 이 이 런의 사본이 아닌 곳을 가리킵니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
esac

CURSOR="$RUN_DIR/feed.cursor"
STATEF="$RUN_DIR/feed.state"
HEARTBEAT="$RUN_DIR/feed.heartbeat"
# THE LOCK IS ONE ARTIFACT, AND THAT IS THE PROPERTY IT RESTS ON. The acquisition
# token is a DIRECTORY — `mkdir` either creates or fails, in one syscall, with no
# window between the test and the write, which is the idiom this repository's own
# helper convention already names for exactly this job — and the record of WHO
# holds it lives INSIDE that directory.
#
# It used to live beside it, in a `feed.lock` file written by a second syscall
# after the `mkdir` had already succeeded, and `lock_holder_alive` opened with
# `[ -f "$LOCKF" ] || return 1`. Between those two syscalls the lock therefore
# answered "nobody holds this" — the `mkdir` had bought atomicity and the second
# write gave it straight back. The window is not theoretical: the value written
# is `$(cc_proc_fingerprint "$$")`, word expansion happens before the
# redirection, and that substitution forks `ps`, so an entire process spawn sat
# inside it. A second instance arriving in that window reclaims a lock whose
# owner is alive and running, which is precisely the duplicate-feed state this
# lock exists to prevent.
LOCKD="$RUN_DIR/feed.lock.d"
LOCK_OWNED=0

# THE MEMORY CLOCK. One `date` at startup and the shell's `SECONDS` after it, so
# a cycle reads the time without forking; `cc_clock_start` says why that is the
# same wall clock `date` reads.
cc_clock_start
now_epoch() { local now; cc_clock_now_into now; printf '%s\n' "$now"; }
now_stamp() {
  local now
  cc_clock_now_into now
  printf '%s %s' "$(cc_display_hhmm "$now")" "$CC_DTZ_LABEL"
}

# The separator in `feed.state`, spelled once. A literal tab inside a `sed` or
# `grep` expression is invisible in a diff and survives being turned into spaces
# by an editor, which makes the state file silently stop matching itself.
TAB=$'\t'

# The epoch of this channel's last beat, kept in memory once this process has
# written or read one, so the keepalive's age needs no `stat` of its own file.
FEED_HB_AT=""
# The ledger's row count at the last read, for the cycles that skip the read.
FEED_ROWS=0
# This process's start fingerprint, taken once: the lock record carries it, and
# the pid it describes does not change.
FEED_FP=""
cc__proc_fingerprint_into FEED_FP "$$"

file_mtime() {
  # file_mtime <path> — epoch seconds, or empty. `stat` takes a different flag on
  # each platform; `date -r` is on both and takes the file directly.
  [ -f "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

clip() {
  # clip <text> <chars> — CHARACTERS, not bytes. `cut -c` counts bytes on the
  # BSD side, and every value here is Korean, so a byte cut lands mid-codepoint
  # and prints a replacement glyph into the one line a person actually reads.
  printf '%s' "$1" \
    | awk -v n="$2" '{ if (length($0) > n) printf "%s…", substr($0, 1, n); else printf "%s", $0 }'
}

row_series_into() {
  # row_series_into <var> <row> — the series name between the row's leading
  # "- `" and the next backtick, or empty when the row has no such pair.
  local __r="$2"
  printf -v "$1" '%s' ""
  case "$__r" in '- `'*) __r=${__r#'- `'} ;; *) return 0 ;; esac
  case "$__r" in *'`'*) printf -v "$1" '%s' "${__r%%'`'*}" ;; esac
}

row_field_into() {
  # row_field_into <var> <row> <key> — the row grammar guarantees no field value
  # contains a `|` or a newline, so splitting on `|` and taking the first match
  # is exact. The first `|`-separated piece that, past its leading spaces, starts
  # with `<key>=` gives the value, its trailing whitespace taken off; <var> is
  # set empty when no piece does. Builtins only, so a row read field by field
  # forks for none of them.
  local __rest="$2" __p __v
  printf -v "$1" '%s' ""
  while :; do
    __p=${__rest%%|*}
    __p=${__p#"${__p%%[! ]*}"}
    case "$__p" in
      "$3="*)
        __v=${__p#"$3="}
        __v=${__v%"${__v##*[![:space:]]}"}
        printf -v "$1" '%s' "$__v"
        return 0 ;;
    esac
    case "$__rest" in *'|'*) __rest=${__rest#*|} ;; *) return 0 ;; esac
  done
}

# ---------------------------------------------------------------------------
# The lock. `feed.cursor` is what makes re-arming free.
#
# THE RE-ARM PATH IS A HEALTHY NIGHT'S NORMAL RESULT, so it must not exit
# non-zero. The lead re-arms on every shift return — up to three times a night —
# because whether a `persistent` monitor survives a compaction or a resume is
# unmeasured, and re-arming binds the risk either way: alive, the lock finds the
# existing instance and nothing is duplicated; dead, the cursor resumes exactly
# where the last line left off. A non-zero exit is reported to the lead as a
# failure, so the healthy night would file up to three false failures.
#
# A LOCK WHOSE HOLDER IS GONE IS RECLAIMED, not reported. It used to exit 3 with
# an instruction to delete the file by hand, and there is no hand on this path: the
# feed is armed by a sleeping user's session, so one unclean death — SIGKILL, an
# OOM kill, a crash, a reboot — turned every re-arm for the rest of the night into
# a failure. The same comment below names "the re-arm does nothing for the rest of
# the night" as the most expensive failure direction, and exit 3 produced it by
# another road. Worse, the watcher's sixth arm exists to DETECT that death and then
# tells the lead to re-arm, so detection and recovery sat on two sides of one
# defect. Overwriting a dead pid's stale record creates no new risk; the
# fingerprint below is what makes "dead" mean dead rather than "recycled".
#
# AND THE PID ALONE IS NOT THE HOLDER'S IDENTITY. `RUN_DIR` survives a reboot by
# design, so a recycled pid reads as "a feed is already running" and the re-arm
# then does nothing for the rest of the night — the failure direction that costs
# the most. The start-time fingerprint is recorded beside the pid for the same
# reason the watcher already records one.
#
# THE LOCK EARNS ITS KEEP RATHER THAN BEING A PRECAUTION: a stop acknowledged as
# successful has been observed not to have stopped the task, so stopping and
# re-arming can leave two feeds on one run — one of them the instance the lead
# believes it already removed. The observed coexistence lasted 30 seconds only
# because a timeout deadline cut it short, and this channel is armed with no
# deadline at all.
# ---------------------------------------------------------------------------
lock_holder_alive() {
  local pid fp rec holder="$LOCKD/holder"
  [ -d "$LOCKD" ] || return 1
  # NO RECORD YET MEANS ACQUISITION IN PROGRESS, AND THAT READS AS ALIVE. The
  # directory exists, so some process won the `mkdir` and is on its way to
  # writing the record. Answering "dead" here is the reclaiming failure this lock
  # exists to prevent, and the two errors are not symmetric: backing off from a
  # holder that turns out to be dead costs one re-arm cycle, while reclaiming
  # from a holder that is alive puts two feeds on one run.
  [ -f "$holder" ] || return 0
  pid=""; rec=""
  { IFS= read -r pid; IFS= read -r rec; } 2>/dev/null < "$holder" || :
  pid=${pid//[!0123456789]/}
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A record written before fingerprints existed has nothing to compare, and the
  # `kill -0` above is then all there is. That is weaker, not absent.
  [ -n "$rec" ] || return 0
  cc__proc_fingerprint_into fp "$pid"
  [ -n "$fp" ] || return 1
  [ "$rec" = "$fp" ]
}

take_lock() {
  # RECLAIMING IS ONE ATOMIC STEP, AND THE STEP IS THE RENAME.
  #
  # The path here used to be "judge the holder gone → overwrite the record →
  # declare ownership", and not one of those three is atomic. Two re-arms
  # reaching one settled orphan both judged it gone, both overwrote, and both
  # continued as owner — so the branch that exists to recover from a duplicate
  # feed could create one. Renaming the directory elects a single winner instead:
  # the loser's `mv` fails with ENOENT because the name it names is already gone.
  #
  # OWNERSHIP COMES FROM THE `mkdir` AND FROM NOTHING ELSE. `LOCK_OWNED=1` sits in
  # that one branch, so it is equivalent to "this process created the directory"
  # — which is the only claim any of this can actually make atomically. A
  # reclaimer re-enters the loop and must win the `mkdir` like anyone else rather
  # than inheriting ownership from having done the cleanup.
  #
  # BOUNDED, BECAUSE THIS PATH RUNS WITH NOBODY AWAKE. Each turn either acquires,
  # backs off, or loses one race to a process that is the holder from then on, so
  # three turns is already generous; exhausting them backs off the same way a
  # live holder does. A re-arm on a healthy night must not report failure, so the
  # exhausted path exits 0 like the others.
  local tries=0 dead
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if mkdir "$LOCKD" 2>/dev/null; then
      printf '%s\n%s\n' "$$" "$FEED_FP" > "$LOCKD/holder"
      LOCK_OWNED=1
      return 0
    fi
    if lock_holder_alive; then
      printf '%s 진행 채널이 이미 돌고 있습니다 (pid %s) — 이 호출은 아무것도 중복하지 않습니다\n' \
        "$(now_stamp)" "$(sed -n '1p' "$LOCKD/holder" 2>/dev/null | tr -dc '0-9')"
      exit 0
    fi
    dead="$LOCKD.dead.$$"
    if mv "$LOCKD" "$dead" 2>/dev/null; then
      rm -rf "$dead"
      # ONE LINE, THEN CARRY ON. The morning needs to know the last channel did
      # not shut down cleanly; the night needs the channel running either way.
      # Only the winner of the rename prints it, so one unclean death leaves one
      # line however many instances arrived to find it.
      printf 'feed: 주인이 사라진 락을 회수합니다 (%s) — 앞선 진행 채널이 깨끗하지 않게 죽었습니다\n' \
        "$LOCKD" >&2
    fi
    # Reclaimed or beaten to it, the state has moved. Go round and judge it
    # again rather than assuming what the move left behind.
  done
  printf '%s 진행 채널의 락을 얻지 못했습니다 — 다른 인스턴스가 방금 가져갔습니다\n' "$(now_stamp)"
  exit 0
}

release_lock() {
  # ONLY THE HOLDER RELEASES. The trap is installed before the lock is taken, so
  # the instance that finds a live holder and exits 0 runs this too — and without
  # the flag it would delete the running instance's lock on its way out, which is
  # the duplicate-feed state the lock exists to prevent.
  #
  # AND IT IS ONE STEP, because there is one artifact. Releasing used to remove
  # the record and then the directory, which leaves a state — directory present,
  # record gone — that a concurrent arrival reads as its own acquisition window.
  [ "$LOCK_OWNED" = "1" ] || return 0
  rm -rf "$LOCKD"
  # A second call does nothing. The EXIT trap is the only caller today, and the
  # flag keeps that true of any caller added later.
  LOCK_OWNED=0
}

# ---------------------------------------------------------------------------
# Emission.
#
# EVERY LINE CARRIES TIME, SUBJECT AND STATE — POSITIVELY, not by avoiding a
# list of forbidden things. A rule made only of prohibitions passes a line like
# `[06:22 KST] 스테이지 종단`, and the lead that receives it has to read the
# snapshot to learn what ended — which is the one act the router's channel
# invariant forbids outright. The clock is in the display zone and the label
# beside it names that zone, because a line falls into the conversation with no
# heading to say it. Ledger rows stay UTC, so to find a line's row subtract the
# label's offset first.
#
# THE RUN ID IS NOT IN THE LINE BODY. The monitor's `description` carries it into
# every event's summary, and that string is the only thing separating two runs
# emitting at once — putting it in the body as well would cost a token on every
# line to say what the envelope already says.
# ---------------------------------------------------------------------------
emit() {
  local now iso
  cc_clock_now_into now
  cc_epoch_to_iso_into iso "$now"
  printf '[%s %s] %s\n' "$(cc_display_hhmm "$now")" "$CC_DTZ_LABEL" "$1"
  printf '%s\n' "$iso" > "$HEARTBEAT" && FEED_HB_AT=$now
}

# ---------------------------------------------------------------------------
# The projector.
#
# TWO CLOSED LISTS, AND BOTH ARE NEEDED. The first is which ROW KINDS become
# lines; the second is which FIELDS of those rows may be interpolated.
#
# WHY THE ROW KINDS ARE A CLOSED LIST. `자율 승인` is 67%..92% of a real ledger —
# one measured run held 1,093 of them in 1,186 rows — so relaying that kind would
# multiply the lead's turns by hundreds. The cost is not an automatic cutoff:
# the transport degrades loudly and announces its own losses, and 200ms batching
# caps production at about five events per second. The cost is WAKING, which is
# the quantity this whole design exists to reduce. An open list would let a new
# row kind make the channel noisy with nobody deciding that it should.
#
# AND ONE EXCEPTION, WHICH THE EXCLUSION WOULD OTHERWISE SWALLOW. The sidecar's
# row table has no `judgment` series — `judgment` is a VALUE of `자율 승인.kind` —
# so excluding `자율 승인` by the letter also excludes every grade-2 escalation,
# which is exactly the class that needs a person. That one shape is relayed.
#
# WHY THE FIELDS ARE A WHITELIST. "Do not write imperatives" cannot be enforced;
# a fixed list of interpolable fields can. Six fields are excluded by name and
# each for its own reason: `blocked.재개 명령` is a direct instruction to the
# lead, `blocked.근거` and `자율 승인.근거` are the router narrating its own next
# move, `handoff.다음 후보` is an instruction aimed at the successor shift, the
# approval's `질문 문면`/`답변 문면` are addressed to the human decider and travel
# to them by banner instead, and `종료 절.근거` is free narration. A relayed
# imperative is a second router, and two routers disagree in the dark.
#
# A REVIEW LINE CARRIES NO LANE DECISION, which is why the cycle projector stops
# at the P0/P1 counts. Whether those counts mean re-convergence is the router's
# call, and a projected verdict is an invitation for the woken lead to make it
# again.
# ---------------------------------------------------------------------------
project_into() {
  # project_into <var> <row> — sets <var> to a line body, or to nothing at all.
  # Run in the caller's shell, so a projected row forks only where a value is
  # clipped.
  local row="$2" series a b c d
  printf -v "$1" '%s' ""
  row_series_into series "$row"
  case "$series" in
    run)
      row_field_into a "$row" '설계 문서'
      b="런 시작 · 설계 문서 $a"
      # Only when it is there. The field arrives with the audit layer and a run
      # opened before that has no such value, so interpolating it unconditionally
      # would print a dangling label on every line this projector writes.
      row_field_into c "$row" '강제 코드'
      case "$c" in ''|-|없음) : ;; *) b="$b · 강제 코드 $(clip "$c" 12)" ;; esac
      printf -v "$1" '%s' "$b"
      ;;
    segment)
      # State transitions only, and the previous state is on the line. `계획됨 →
      # 실행중` says what a bare `실행중` does not: whether anything moved.
      local sid st prev="" keep="" l
      row_field_into sid "$row" 'id'
      row_field_into st "$row" '상태'
      [ -n "$sid" ] && [ -n "$st" ] || return 0
      # The last line for this segment is its previous state; every other line is
      # kept as it was.
      while IFS= read -r l; do
        case "$l" in
          "$sid$TAB"*) prev=${l#"$sid$TAB"} ;;
          *) keep="$keep$l
" ;;
        esac
      done 2>/dev/null < "$STATEF"
      [ "$prev" = "$st" ] && return 0
      { printf '%s%s\t%s\n' "$keep" "$sid" "$st"; } > "$STATEF.tmp" && mv "$STATEF.tmp" "$STATEF"
      b="세그먼트 $sid ${prev:-없음} → $st"
      row_field_into a "$row" 'PR'; row_field_into c "$row" '커밋'
      case "$a" in ''|-|없음) : ;; *) b="$b · PR $a" ;; esac
      case "$c" in ''|-|없음) : ;; *) b="$b · 커밋 $(clip "$c" 7)" ;; esac
      printf -v "$1" '%s' "$b"
      ;;
    cycle)
      row_field_into a "$row" '세그먼트'; row_field_into b "$row" '사이클'
      row_field_into c "$row" 'P0'; row_field_into d "$row" 'P1'
      printf -v "$1" '리뷰 %s %s회차 · P0 %s · P1 %s' "$a" "$b" "$c" "$d"
      ;;
    stage-result)
      row_field_into a "$row" '스테이지'; row_field_into b "$row" '종류'
      row_field_into c "$row" '종료 코드'; row_field_into d "$row" '종단 부류'
      printf -v "$1" '스테이지 %s 종단 · 종류 %s · 종료 코드 %s · 부류 %s' "$a" "$b" "$c" "$d"
      ;;
    blocked)
      row_field_into a "$row" '스코프'; row_field_into b "$row" '사유'
      row_field_into c "$row" '원인'
      printf -v "$1" '막힘 관측 · 스코프 %s · 사유 %s · 원인 %s' "$a" "$b" "$c"
      ;;
    승인)
      row_field_into a "$row" '승인 id'; a=$(clip "$a" 12)
      row_field_into b "$row" '상태'
      row_field_into c "$row" '절단점'; row_field_into d "$row" '막는 세그먼트'
      printf -v "$1" '승인 %s %s · 절단점 %s · 막는 세그먼트 %s' "$a" "$b" "$c" "$d"
      ;;
    handoff)
      row_field_into a "$row" '교대'; row_field_into b "$row" '사유'
      row_field_into c "$row" '막힌 지점'; c=$(clip "$c" 80)
      printf -v "$1" '교대 %s 종료 · 사유 %s · 막힌 지점 %s' "$a" "$b" "$c"
      ;;
    '종료 절')
      row_field_into a "$row" 'id'; row_field_into b "$row" '상태'
      row_field_into c "$row" '자체 근거'
      # A clause the run settled on its own execution says so on the feed.
      if [ "$c" = "예" ]; then
        printf -v "$1" '종료 절 %s %s · 자체 근거' "$a" "$b"
      else
        printf -v "$1" '종료 절 %s %s' "$a" "$b"
      fi
      ;;
    problem)
      row_field_into a "$row" '동일성'; a=$(clip "$a" 60)
      row_field_into b "$row" '현재 단'
      printf -v "$1" '문제 %s · 현재 단 %s' "$a" "$b"
      ;;
    '대상 추가')
      row_field_into a "$row" '별칭'; row_field_into b "$row" '원격 슬러그'
      row_field_into c "$row" '층'
      printf -v "$1" '대상 추가 %s · 슬러그 %s · 층 %s' "$a" "$b" "$c"
      ;;
    '자율 승인')
      row_field_into a "$row" 'kind'
      [ "$a" = "judgment" ] || return 0
      row_field_into a "$row" '등급'
      [ "$a" = "2" ] || return 0
      row_field_into a "$row" '판단 부류'; row_field_into b "$row" '세그먼트'
      row_field_into c "$row" '대상'
      printf -v "$1" '판단 등급 2 · 부류 %s · 세그먼트 %s · 대상 %s' "$a" "$b" "$c"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# The chain runs BOTH WAYS.
#
# The watcher counts this channel's absence, and that is only half of it: if the
# process that dies is the WATCHER, its arm dies with it and this channel goes on
# calmly narrating a run nobody is guarding. So this reads the watcher's
# heartbeat too and says so in its own line. Each layer reports the one above,
# and the harness's own termination notice catches the top.
#
# The floor is the watcher's `--stall`, used as-is. This channel beats once per
# floor even when nothing happens, so the watcher's own staleness test is exactly
# two missed beats — a whole number, which is what keeps one late beat from
# reading as a death.
# ---------------------------------------------------------------------------
watcher_silence_check() {
  local mt age now
  [ -f "$RUN_DIR/feed.announced-watch-silence" ] && return 0
  mt=$(file_mtime "$RUN_DIR/watch.heartbeat")
  [ -n "$mt" ] || return 0
  cc_clock_now_into now
  age=$(( now - mt ))
  [ "$age" -ge "$STALL" ] || return 0
  [ -f "$RUN_DIR/feed.announced-watch-silence" ] && return 0
  : > "$RUN_DIR/feed.announced-watch-silence"
  emit "감시자 침묵 ${age}초 · watch.sh 하트비트가 멎었습니다 · 관측자 feed.sh"
}

pass() {
  # pass <read> <silence> — <read> 1 reads the ledger whatever its age, 0 reads
  # it only when it may have changed since the last read; <silence> 1 runs the
  # watcher-silence check this cycle.
  local n_rows cursor="" row body emitted=0 rows now nl=$'\n'
  # A LEDGER STRICTLY OLDER THAN THE LAST READ HAS NOTHING NEW. The mark is
  # touched before the rows are counted, so a row appended after the count —
  # in the same second or later — leaves the ledger no older than the mark and
  # the next cycle reads it. The cursor file's own time is not consulted.
  if [ "$1" = "0" ] && [ -f "$LEDGER" ] && [ "$LEDGER" -ot "$RUN_DIR/.feed.readmark" ]; then
    n_rows=$FEED_ROWS
  else
    { : > "$RUN_DIR/.feed.readmark"; } 2>/dev/null
    { IFS= read -r cursor; } 2>/dev/null < "$CURSOR" || :
    cursor=${cursor//[!0123456789]/}
    cursor=${cursor:-0}
    # ONE READ OF THE LEDGER: the count of its rows first, then the rows past the
    # cursor.
    rows=$( { awk -v c="$cursor" '
      index($0, "- `") == 1 { n++; if (n > c) r[n] = $0 }
      END { print n + 0; for (i = c + 1; i <= n; i++) print r[i] }
    ' "$LEDGER" 2>/dev/null || printf '0\n'; } )
    n_rows=${rows%%"$nl"*}
    case "$rows" in *"$nl"*) rows=${rows#*"$nl"} ;; *) rows="" ;; esac
    case "$n_rows" in ''|*[!0-9]*) n_rows=0 ;; esac
    FEED_ROWS=$n_rows
    # A ledger that shrank is a ledger that was replaced. Restarting from zero
    # would replay a whole night into the lead's conversation, so the cursor is
    # clamped instead and the discrepancy is left to the morning's damage count.
    [ "$cursor" -gt "$n_rows" ] && cursor="$n_rows"

    if [ "$n_rows" -gt "$cursor" ]; then
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        project_into body "$row"
        [ -n "$body" ] || continue
        emit "$body"
        emitted=1
      done <<EOF
$rows
EOF
      printf '%s\n' "$n_rows" > "$CURSOR"
    fi
  fi

  [ "$2" = "1" ] && watcher_silence_check

  # THE KEEPALIVE IS THE BEAT THE WATCHER COUNTS, and it is also the only line a
  # quiet hour produces. Without it the channel and a dead channel look the same
  # from outside, which is the property the sixth watcher arm needs in order to
  # mean anything. Its age is this process's memory of its last beat; a beat
  # left by an earlier channel is read from the file once.
  if [ "$emitted" = "0" ]; then
    if [ -f "$HEARTBEAT" ] && [ -z "$FEED_HB_AT" ]; then
      FEED_HB_AT=$(file_mtime "$HEARTBEAT")
    fi
    cc_clock_now_into now
    if [ ! -f "$HEARTBEAT" ] || [ -z "$FEED_HB_AT" ]; then
      emit "채널 시작 · 원장 ${n_rows}행부터 잇습니다"
    elif [ "$(( now - FEED_HB_AT ))" -ge "$STALL" ]; then
      emit "변화 없음 · 원장 ${n_rows}행 · 채널 살아 있음"
    fi
  fi
}

run_is_over() {
  [ -f "$RUN_DIR/done" ] && return 0
  [ -d "$RUN_DIR" ] || return 0
  return 1
}

[ -d "$RUN_DIR" ] || { printf 'feed: 런 디렉터리가 없습니다: %s\n' "$RUN_DIR" >&2; exit 2; }
# THE TRAP GOES UP BEFORE THE LOCK DOES, and `HUP` is on it. Installed after
# `take_lock`, a signal arriving in between left the lock behind with nothing to
# remove it; `HUP` is on the list because a terminal going away is one of the
# ordinary ways this process ends. Neither closes the SIGKILL window — nothing in
# a shell can — which is why the reclaim above is the load-bearing half and this
# ordering is only the half that is free.
#
# A SIGNAL TRAP ONLY EXITS, AND THE EXIT TRAP ALONE RELEASES. A handler that
# released and returned handed control back to the loop: measured, a feed sent
# TERM kept running with its lock gone, so the next start found no holder and
# two feeds wrote one channel. `exit` from the handler runs the EXIT trap once,
# with the status the signal implies. The sleep runs as a child the shell waits
# on, because bash defers a trap until a foreground child returns — a signal in
# the middle of the interval would otherwise wait the interval out — and the
# EXIT trap kills that child so no `sleep` outlives the feed.
#
# `sp` IS SET BEFORE THE TRAPS. Under `set -u` an EXIT trap that reads an unset
# `sp` fails before `release_lock`, and `--once` never enters the sleep that
# assigns it — so that path left its lock behind.
sp=""
trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; release_lock' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
take_lock

# QUIET RUNS ARE READ ON A MULTIPLE. While the watcher reports the run quiet
# (`cc_watch_mode_quiet`), every `CC_QUIET_PASS_EVERY`-th cycle reads the ledger
# whatever its age and runs the watcher-silence check; the cycles between skip
# a ledger older than the last read and skip the check. Both counts start at
# this process's first cycle, which always reads. A working run checks the
# watcher's silence every cycle.
feed_cycle=0
while :; do
  feed_read=0; feed_silence=1
  if [ $((feed_cycle % ${CC_QUIET_PASS_EVERY:-4})) -eq 0 ]; then
    feed_read=1
  elif cc_watch_mode_quiet "$RUN_DIR" "$INTERVAL"; then
    feed_silence=0
  fi
  feed_cycle=$((feed_cycle + 1))
  pass "$feed_read" "$feed_silence"
  [ "$ONCE" = "1" ] && break
  run_is_over && break
  sleep "$INTERVAL" & sp=$!; wait "$sp"; sp=""
done
exit 0
