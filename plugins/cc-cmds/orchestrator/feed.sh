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

FEED_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$FEED_DIR/liveness.sh"

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

now_epoch() { date +%s; }
now_stamp() { date -u +%H:%MZ; }

# The separator in `feed.state`, spelled once. A literal tab inside a `sed` or
# `grep` expression is invisible in a diff and survives being turned into spaces
# by an editor, which makes the state file silently stop matching itself.
TAB=$(printf '\t')

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

row_series() {
  printf '%s' "$1" | sed -n 's/^- `\([^`]*\)`.*/\1/p'
}

row_field() {
  # row_field <row> <key> — the row grammar guarantees no field value contains a
  # `|` or a newline, so splitting on `|` and taking the first match is exact.
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | head -1
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
  pid=$(sed -n '1p' "$holder" 2>/dev/null | tr -dc '0-9')
  rec=$(sed -n '2p' "$holder" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A record written before fingerprints existed has nothing to compare, and the
  # `kill -0` above is then all there is. That is weaker, not absent.
  [ -n "$rec" ] || return 0
  fp=$(cc_proc_fingerprint "$pid")
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
      printf '%s\n%s\n' "$$" "$(cc_proc_fingerprint "$$")" > "$LOCKD/holder"
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
}

# ---------------------------------------------------------------------------
# Emission.
#
# EVERY LINE CARRIES TIME, SUBJECT AND STATE — POSITIVELY, not by avoiding a
# list of forbidden things. A rule made only of prohibitions passes a line like
# `[06:22Z] 스테이지 종단`, and the lead that receives it has to read the snapshot
# to learn what ended — which is the one act the router's channel invariant
# forbids outright. The clock is the same UTC `Z` the ledger and the morning
# report use, so any line can be grepped back to its row.
#
# THE RUN ID IS NOT IN THE LINE BODY. The monitor's `description` carries it into
# every event's summary, and that string is the only thing separating two runs
# emitting at once — putting it in the body as well would cost a token on every
# line to say what the envelope already says.
# ---------------------------------------------------------------------------
emit() {
  printf '[%s] %s\n' "$(now_stamp)" "$1"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HEARTBEAT"
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
project() {
  # project <row> — prints a line body, or nothing at all.
  local row="$1" series
  series=$(row_series "$row")
  case "$series" in
    run)
      printf '런 시작 · 설계 문서 %s' "$(row_field "$row" '설계 문서')"
      # Only when it is there. The field arrives with the audit layer and a run
      # opened before that has no such value, so interpolating it unconditionally
      # would print a dangling label on every line this projector writes.
      local code
      code=$(row_field "$row" '강제 코드')
      case "$code" in ''|-|없음) : ;; *) printf ' · 강제 코드 %s' "$(clip "$code" 12)" ;; esac
      ;;
    segment)
      # State transitions only, and the previous state is on the line. `계획됨 →
      # 실행중` says what a bare `실행중` does not: whether anything moved.
      local sid st prev
      sid=$(row_field "$row" 'id')
      st=$(row_field "$row" '상태')
      [ -n "$sid" ] && [ -n "$st" ] || return 0
      prev=$(sed -n "s/^$sid$TAB//p" "$STATEF" 2>/dev/null | tail -1)
      [ "$prev" = "$st" ] && return 0
      { grep -v "^$sid$TAB" "$STATEF" 2>/dev/null || true; printf '%s\t%s\n' "$sid" "$st"; } \
        > "$STATEF.tmp" && mv "$STATEF.tmp" "$STATEF"
      printf '세그먼트 %s %s → %s' "$sid" "${prev:-없음}" "$st"
      local pr cm
      pr=$(row_field "$row" 'PR'); cm=$(row_field "$row" '커밋')
      case "$pr" in ''|-|없음) : ;; *) printf ' · PR %s' "$pr" ;; esac
      case "$cm" in ''|-|없음) : ;; *) printf ' · 커밋 %s' "$(clip "$cm" 7)" ;; esac
      ;;
    cycle)
      printf '리뷰 %s %s회차 · P0 %s · P1 %s' \
        "$(row_field "$row" '세그먼트')" "$(row_field "$row" '사이클')" \
        "$(row_field "$row" 'P0')" "$(row_field "$row" 'P1')"
      ;;
    stage-result)
      printf '스테이지 %s 종단 · 종류 %s · 종료 코드 %s · 부류 %s' \
        "$(row_field "$row" '스테이지')" "$(row_field "$row" '종류')" \
        "$(row_field "$row" '종료 코드')" "$(row_field "$row" '종단 부류')"
      ;;
    blocked)
      printf '막힘 관측 · 스코프 %s · 사유 %s · 원인 %s' \
        "$(row_field "$row" '스코프')" "$(row_field "$row" '사유')" \
        "$(row_field "$row" '원인')"
      ;;
    승인)
      printf '승인 %s %s · 절단점 %s · 막는 세그먼트 %s' \
        "$(clip "$(row_field "$row" '승인 id')" 12)" "$(row_field "$row" '상태')" \
        "$(row_field "$row" '절단점')" "$(row_field "$row" '막는 세그먼트')"
      ;;
    handoff)
      printf '교대 %s 종료 · 사유 %s · 막힌 지점 %s' \
        "$(row_field "$row" '교대')" "$(row_field "$row" '사유')" \
        "$(clip "$(row_field "$row" '막힌 지점')" 80)"
      ;;
    '종료 절')
      printf '종료 절 %s %s' "$(row_field "$row" 'id')" "$(row_field "$row" '상태')"
      ;;
    problem)
      printf '문제 %s · 현재 단 %s' \
        "$(clip "$(row_field "$row" '동일성')" 60)" "$(row_field "$row" '현재 단')"
      ;;
    '대상 추가')
      printf '대상 추가 %s · 슬러그 %s · 층 %s' \
        "$(row_field "$row" '별칭')" "$(row_field "$row" '원격 슬러그')" \
        "$(row_field "$row" '층')"
      ;;
    '자율 승인')
      [ "$(row_field "$row" 'kind')" = "judgment" ] || return 0
      [ "$(row_field "$row" '등급')" = "2" ] || return 0
      printf '판단 등급 2 · 부류 %s · 세그먼트 %s · 대상 %s' \
        "$(row_field "$row" '판단 부류')" "$(row_field "$row" '세그먼트')" \
        "$(row_field "$row" '대상')"
      ;;
  esac
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
  local mt age
  mt=$(file_mtime "$RUN_DIR/watch.heartbeat")
  [ -n "$mt" ] || return 0
  age=$(( $(now_epoch) - mt ))
  [ "$age" -ge "$STALL" ] || return 0
  [ -f "$RUN_DIR/feed.announced-watch-silence" ] && return 0
  : > "$RUN_DIR/feed.announced-watch-silence"
  emit "감시자 침묵 ${age}초 · watch.sh 하트비트가 멎었습니다 · 관측자 feed.sh"
}

pass() {
  local n_rows cursor row body i=0 emitted=0 hb_age
  n_rows=$( { grep -c '^- `' "$LEDGER" 2>/dev/null || true; } )
  n_rows=${n_rows:-0}
  cursor=$(sed -n '1p' "$CURSOR" 2>/dev/null | tr -dc '0-9')
  cursor=${cursor:-0}
  # A ledger that shrank is a ledger that was replaced. Restarting from zero
  # would replay a whole night into the lead's conversation, so the cursor is
  # clamped instead and the discrepancy is left to the morning's damage count.
  [ "$cursor" -gt "$n_rows" ] && cursor="$n_rows"

  if [ "$n_rows" -gt "$cursor" ]; then
    while IFS= read -r row; do
      i=$((i + 1))
      [ -n "$row" ] || continue
      body=$(project "$row")
      [ -n "$body" ] || continue
      emit "$body"
      emitted=1
    done <<EOF
$( { grep '^- `' "$LEDGER" 2>/dev/null || true; } | tail -n "$(( n_rows - cursor ))")
EOF
    printf '%s\n' "$n_rows" > "$CURSOR"
  fi

  watcher_silence_check

  # THE KEEPALIVE IS THE BEAT THE WATCHER COUNTS, and it is also the only line a
  # quiet hour produces. Without it the channel and a dead channel look the same
  # from outside, which is the property the sixth watcher arm needs in order to
  # mean anything.
  if [ "$emitted" = "0" ]; then
    hb_age=$(file_mtime "$HEARTBEAT")
    if [ -z "$hb_age" ]; then
      emit "채널 시작 · 원장 ${n_rows}행부터 잇습니다"
    elif [ "$(( $(now_epoch) - hb_age ))" -ge "$STALL" ]; then
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
trap 'release_lock' EXIT HUP INT TERM
take_lock

while :; do
  pass
  [ "$ONCE" = "1" ] && break
  run_is_over && break
  sleep "$INTERVAL"
done
exit 0
