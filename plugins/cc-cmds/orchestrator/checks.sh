#!/usr/bin/env bash
#
# checks.sh — the run's CI poller. Asks GitHub what the checks on each segment's
# PR are doing and appends ONE LINE per state TRANSITION to
# `$RUN_DIR/checks.observed`. The gate's `gate_drain_checks()` is what turns
# those lines into `checks` rows.
#
# WHY THIS IS A SEPARATE PROCESS, AND THE REASON IS NOT THE GRADE. The first
# reason used to be grading — `pr checks --watch` was an external-state act, so
# an unattended stage waiting on it sat in an approval queue. The axis-2 table
# has since demoted that family to a read, and THAT REASON ALONE CANNOT ANSWER
# "why not just wait inside the stage". The second reason answers it, and it does
# not go away: A HEADLESS STAGE HAS NO PATH BACK TO WAKEFULNESS. A `claude -p`
# process ends the moment the model yields the turn, so a wait launched in its
# background finishes with no session left to consume the result. The background
# process does not die — THE RESULT REACHES NOBODY. So the waiting has to happen
# outside whatever process holds the turn, which is this one.
#
# THE LEDGER HAS ONE WRITER AND IT IS NOT THIS PROCESS. This is the same
# arrangement `watch.sh` already has for stalls: the observer appends to a file
# in the run directory, and the gate — which holds the lock and the hash chain —
# transcribes. Writing rows from here would break the chain from that row on.
#
# THE GATE'S ENFORCEMENT DOES NOT REACH THIS FILE, AND THAT IS DELIBERATE. That
# enforcement is a `PreToolUse` hook whose matcher is tool calls; a command run
# inside a detached `bash checks.sh &` is not a tool call, so the hook does not
# fire and axis-2 grades are never consulted. This is not a bypass — the grade is
# simply not asked for. It also makes this the FIRST detached run-scope process
# that calls the network at all, and a single `pr merge` added here would merge
# on an unattended night with neither a record nor an approval. So the fence is
# an ALLOWLIST OF SPELLINGS and `test-run.sh` holds it: every call below is
# `gh -R "$slug" pr <verb> …` and the verb set is exactly {list, view, checks}.
# A denylist would let a fourth verb through in silence, which is precisely what
# this fence exists to stop. Keeping the calls in that one shape is what lets the
# assertion extract the verb at all.
#
# THE BANNER FENCE, INHERITED FROM `feed.sh` WORD FOR WORD. This file does NOT
# source `notify-run.sh` and names neither of that file's two emitter functions
# anywhere, so the check holding the fence is an exact count of zero rather than
# a judgement about context. CI results are an input for the router, not news for
# a person; a third banner seat would spend one of eight stacking slots on
# something nobody has to answer. `liveness.sh` IS sourced — it holds the run
# state predicate and no notification path at all.
#
# NO NEW THRESHOLDS. `--interval` is the watcher's pinned `--interval 60`, and
# rule 4 of `scripts/lint-watch-threshold-pins.sh` sweeps the consuming document
# for that spelling and compares it against the watcher's own declaration. THIS
# IS A PERMANENT COUPLING AND IT IS CHOSEN RATHER THAN INCIDENTAL: the expected
# value comes from `watch.sh`, so re-tuning the watcher's interval later breaks
# the kickoff line of this unrelated script until it is moved in step. The
# in-script default below is NOT pinned by anything — rule 1's source of truth is
# hardcoded to the watcher, so a new script is structurally invisible to it, and
# this file does not pretend otherwise.
#
# AND THE POLLER'S BUDGET IS NOT A NUMBER OF SECONDS. It is the run's three
# exits — `done`, the directory going away, and the shared terminal predicate. A
# seconds budget would be a twelfth threshold on a tree that already carries six
# the pinning lint cannot see.
#
# THE REQUIRED-SET RULE IS DUPLICATED FROM THE DRIVER, AND THE REAL REASON IS NOT
# "IT CANNOT BE SOURCED". `run.sh` has a source-only seam and other scripts in
# this repository use it. What forces the copy is that the rule is INLINE inside
# `merge_gate` with no surface to call. The distinction decides the repair: if
# sourcing were impossible there would be no answer, but "there is no surface"
# means lifting the rule into a function is the answer, some day. The copy also
# inherits the trap that comes with it — `grep -c` PRINTS THE COUNT AND THEN
# EXITS NON-ZERO ON ZERO, so it has to be taken with `|| true`; `|| printf '0'`
# is wrong because the count is then printed twice. The `판정 불가` path below
# reaches the zero case more often than the driver does, so the trap fires more
# readily here.
#
# Usage:
#   checks.sh --run-dir <dir> --ledger <path> --manifest <path>
#             [--interval <sec>] [--once]
#
# Exit codes:
#   0 — ran to one of the run's three exits
#   2 — bad arguments
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -uo pipefail

CHECKS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$CHECKS_DIR/liveness.sh"
# The run's version pin, for the same hop the gate, the watcher and the feed take.
# shellcheck source=/dev/null
. "$CHECKS_DIR/pin.sh"

CHECKS_ARGV=("$@")

RUN_DIR=""; LEDGER=""; MANIFEST=""; INTERVAL=60; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)  RUN_DIR="$2"; shift 2 ;;
    --ledger)   LEDGER="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    *) printf 'checks: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ]  || { printf 'checks: --run-dir 는 필수입니다\n' >&2; exit 2; }
[ -n "$LEDGER" ]   || { printf 'checks: --ledger 는 필수입니다\n' >&2; exit 2; }
# REQUIRED, because the slug fallback has nowhere else to go. `$RUN_DIR/plan.tsv`
# is written by the driver alone, so on a router run it does not exist; the
# manifest is the one file both paths have.
[ -n "$MANIFEST" ] || { printf 'checks: --manifest 는 필수입니다\n' >&2; exit 2; }

# THE HOP, ahead of the pid record and every other write — the same ordering rule
# the gate, the watcher and the feed follow, and for the same reason: `exec`
# keeps the pid but drops EXIT traps, so a record written before it would be left
# behind by a process nothing can trap.
checks_hop_t=""; checks_hop_rc=0
checks_hop_t=$(pin_hop_target "$RUN_DIR" "$CHECKS_DIR") || checks_hop_rc=$?
case "$checks_hop_rc" in
  0) exec "${BASH:-/bin/bash}" "$checks_hop_t/checks.sh" ${CHECKS_ARGV[@]+"${CHECKS_ARGV[@]}"} ;;
  2) printf 'checks: plugin-pin 은 있는데 사본이 없습니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
  3) printf 'checks: plugin-pin 이 이 런의 사본이 아닌 곳을 가리킵니다: %s/plugin-pin — 설치본 코드로 계속합니다\n' "$RUN_DIR" >&2 ;;
esac

OBSERVED="$RUN_DIR/checks.observed"
PIDF="$RUN_DIR/checks.pid"

# The clip ceilings, spelled here because the poller is the one that cuts. The
# drain re-applies `gate_row_safe` at the same widths, and that is a second line
# of defence rather than a second clip.
REQ_MAX=200
FAIL_MAX=300

TAB=$(printf '\t')

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

clip_bytes() {
  # clip_bytes <text> <max-bytes> — BYTES, and never mid-character.
  #
  # The same property `gate_clip` has, and for the same measured reason: `cut -c`
  # counts characters on the BSD side, so a byte budget applied with it returned
  # up to three times its own size over Korean; GNU implements `-c` as `-b` and
  # lands inside a UTF-8 sequence instead, writing invalid bytes. The trailing
  # partial sequence is dropped by reading the last lead byte's announced length.
  local s="$1" n="$2" len
  len=$(printf '%s' "$s" | wc -c | tr -d ' ')
  if [ "${len:-0}" -le "$n" ]; then printf '%s' "$s"; return 0; fi
  printf '%s' "$s" | LC_ALL=C awk -v n="$n" '
    BEGIN { marker = "…(잘림)"; keep = n - length(marker); if (keep < 0) keep = 0 }
    {
      t = substr($0, 1, keep); m = length(t)
      for (i = 0; i < 4 && m - i >= 1; i++) {
        c = substr(t, m - i, 1)
        if (c < "\200") break
        if (c >= "\300") {
          k = (c < "\340") ? 2 : ((c < "\360") ? 3 : 4)
          if (i + 1 != k) t = substr(t, 1, m - i - 1)
          break
        }
      }
      printf "%s%s", t, marker
    }
  '
}

field_safe() {
  # field_safe <text> <max-bytes> — one column of `checks.observed`.
  #
  # THE TAB IS REMOVED HERE AND NOWHERE ELSE. `gate_row_safe` handles `|` and
  # newlines only, so a tab inside a check name survives it — and this file is
  # tab-separated, so one tab shifts every column after it and the ledger row's
  # `상태` position ends up holding some other value entirely.
  clip_bytes "$(printf '%s' "$1" | tr '\t' ' ' | tr '|' '/' | tr '\n\r' '  ' | tr -s ' ')" "$2"
}

row_series() {
  printf '%s' "$1" | sed -n 's/^- `\([^`]*\)`.*/\1/p'
}

row_field() {
  # row_field <row> <key> — the row grammar guarantees no field value carries a
  # `|` or a newline, so splitting on `|` and taking the first match is exact.
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | head -1
}

# ---------------------------------------------------------------------------
# The memory table: `<PR>\t<head sha>\t<상태>`, one pair per line, last wins.
#
# WHY TRANSITIONS ARE JUDGED HERE AND NOT IN THE DRAIN. A transition is a
# property of two CONSECUTIVE observations, and the drain does not observe — it
# runs on gate acts, which are rare and irregular. Judging there would mean a
# reverse scan of the whole ledger for the last row of this `(PR, head sha)` on
# every act path. The loop already holds the previous state in memory, so here it
# is O(1). Writing every poll instead would leave forty identical `대기` rows for
# one forty-minute wait, which is the churn the design's exclusion list names.
# ---------------------------------------------------------------------------
STATE_TBL=""
SEEDED=0

tbl_get() {
  # tbl_get <pr> <sha> — the last recorded state for that pair, or empty.
  printf '%s' "$STATE_TBL" | sed -n "s/^$(printf '%s' "$1" | sed 's/[][\.*^$\/&]/\\&/g')$TAB$(printf '%s' "$2" | sed 's/[][\.*^$\/&]/\\&/g')$TAB//p" | tail -1
}

tbl_put() {
  # tbl_put <pr> <sha> <state> — append; `tbl_get` takes the last line, so an
  # append is an update and the table never has to be rewritten.
  STATE_TBL="${STATE_TBL}$1$TAB$2$TAB$3
"
}

seed_table() {
  # ONCE AT STARTUP, NOT ONCE A PASS. A restarted poller that skipped this would
  # re-emit the current state of every pair as if it were a transition, and the
  # ledger would carry a duplicate row per pair per restart.
  #
  # THREE SOURCES, OLDEST FIRST — and the order is the point, not a tidiness.
  # The ledger holds what the gate has already transcribed; a
  # `checks.observed.draining.*` file holds what a drain renamed aside and has
  # not finished reading; and `checks.observed` holds what has not been drained
  # at all, which is the newest of the three. `tbl_get` takes the LAST value put,
  # so reading them out of age order seeds a stale state over a fresh one and the
  # poller then judges its next transition against a state that was already
  # superseded. The loop below used to read `checks.observed` before the
  # temporaries, against what this very comment said.
  #
  # Omitting the last two would make the observations in flight invisible and
  # re-emit them. Seeding from them is NOT what keeps a dead drain's lines from
  # being lost — the gate's own sweep of those files is what does that, and it
  # has to, because seeding here is precisely what stops this poller from
  # re-emitting them.
  local row f line ts seg pr sha st req fail
  [ "$SEEDED" = "0" ] || return 0
  SEEDED=1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(row_series "$row")" = "checks" ] || continue
    pr=$(row_field "$row" 'PR')
    sha=$(row_field "$row" 'head sha')
    st=$(row_field "$row" '상태')
    [ -n "$pr" ] && [ -n "$sha" ] && [ -n "$st" ] || continue
    tbl_put "$pr" "$sha" "$st"
  done <<EOF
$( { grep '^- `checks`' "$LEDGER" 2>/dev/null || true; } )
EOF
  # `ls -tr` orders the temporaries by mtime, which `mv` carried across from the
  # file each was renamed from — so it is the order the lines were observed in.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    while IFS="$TAB" read -r ts seg pr sha st req fail; do
      [ -n "$pr" ] && [ -n "$sha" ] && [ -n "$st" ] || continue
      tbl_put "$pr" "$sha" "$st"
    done < "$f"
  done <<EOF
$( { ls -tr "$RUN_DIR"/checks.observed.draining.* 2>/dev/null || true; } )
$OBSERVED
EOF
}

# ---------------------------------------------------------------------------
# Discovery. The handle is the WORKTREE, and the branch comes from the row when
# the row has one.
#
# `segment.PR` is not the handle and that candidate was refuted: the only writer
# of that field writes it on a `상태=머지됨` row, so it does not exist during the
# very window CI has to be waited on. `브랜치` is written by the driver but is
# absent from a large share of router rows, while `워크트리` is on every segment
# row there is — so the poller reads the row's branch when it is there and
# derives it from the worktree when it is not, and serves both paths.
# ---------------------------------------------------------------------------
segment_ids() {
  { grep '^- `segment`' "$LEDGER" 2>/dev/null || true; } \
    | sed -n 's/^- `segment` .*| *id=\([^|]*\).*/\1/p' \
    | sed 's/[[:space:]]*$//' | awk '!seen[$0]++'
}

segment_last_row() {
  # EVERY GREP IN THE PIPELINE CARRIES `|| true`. This file runs under `pipefail`,
  # so an unmatched filter in the middle makes the whole substitution report
  # failure — and the segment this poller has nothing recorded for is the ordinary
  # case, not the exceptional one.
  { grep '^- `segment`' "$LEDGER" 2>/dev/null || true; } \
    | { grep -F "id=$1 " || true; } | tail -1
}

manifest_home_slug() {
  # The `홈=예` target row of the MANIFEST. `홈=` is a manifest field; the
  # ledger's nearest series is `대상 추가` and it has no such field at all —
  # reading the ledger for it lands on a row that does not exist.
  { grep '^- `target`' "$MANIFEST" 2>/dev/null || true; } \
    | { grep -F '홈=예' || true; } | tail -1 | tr '|' '\n' \
    | sed -n 's/^ *원격 슬러그=//p' | sed 's/[[:space:]]*$//' | head -1
}

branch_of() {
  # branch_of <worktree> — the checked-out branch, or empty.
  #
  # DETACHED HEAD PRINTS THE STRING `HEAD` AND EXITS 0, so a `|| printf '미상'`
  # fallback never fires. That value is not a branch, so it is treated as no
  # handle at all and the segment is skipped; without this a segment is polled
  # for a branch literally named `HEAD`.
  local out
  out=$( { cd "$1" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null; } || true)
  [ "$out" = "HEAD" ] && return 0
  printf '%s' "$out"
}

slug_of() {
  # slug_of <worktree> — `<owner>/<name>`, the form `gh -R` takes and the form a
  # manifest target row declares.
  #
  # THE SUFFIX IS STRIPPED BEFORE THE SPLIT, AND A ONE-PASS SPELLING CANNOT DO IT.
  # The obvious single expression — `s#.*[:/]\([^/]*/[^/]*\)\(\.git\)\{0,1\}$#\1#`
  # — never removes anything: the greedy `[^/]*` eats `.git` itself and the
  # optional group is then satisfied by the empty string. Measured: a remote of
  # `https://github.com/Nharu/cc-cmds.git` came out as `Nharu/cc-cmds.git`, so the
  # PR handle read `Nharu/cc-cmds.git#7` — which matches neither the slug the
  # manifest declares nor anything `gh -R` accepts, and the poller's whole output
  # was addressed to a repository that does not exist.
  local out
  out=$( { cd "$1" 2>/dev/null && git config --get remote.origin.url 2>/dev/null; } || true)
  [ -n "$out" ] || return 0
  out="${out%.git}"
  printf '%s' "$out" | sed 's#.*[:/]\([^/]*/[^/]*\)$#\1#'
}

# ---------------------------------------------------------------------------
# The two questions, and the fifth status value that keeps them honest.
#
# `판정 불가` exists because the dangerous pair recurs one level up. A broken
# call — auth, network, rate limit — would otherwise fall to `미등록`, and
# `미등록` is the value a consumer reads as "this repository has no checks". The
# place where "the question broke" is told apart from "the question was answered
# and there are none" is this token, and it sits on both `상태` and `필수 집합`.
# ---------------------------------------------------------------------------
names_of() {
  # The first column of every non-empty output row, joined with `, `.
  printf '%s' "$1" | awk -F'\t' 'NF > 0 && $1 != "" { printf "%s%s", sep, $1; sep = ", " }'
}

no_checks_reply() {
  # The "there is nothing to report" answer, told apart from a broken call by
  # what the message says rather than by the exit code — this repository answers
  # rc=1 for it, so the code alone cannot carry the distinction.
  case "$1" in *"no checks reported"*|*"no required checks reported"*) return 0 ;; esac
  return 1
}

poll_status() {
  # poll_status <slug> <pr-number> — prints `<상태>\t<실패 체크>`.
  local slug="$1" n="$2" out err rc fails
  err=$(mktemp)
  out=$(gh -R "$slug" pr checks "$n" 2>"$err"); rc=$?
  case "$rc" in
    0) printf '통과\t-'; rm -f "$err"; return 0 ;;
    8) printf '대기\t-'; rm -f "$err"; return 0 ;;
  esac
  if [ "$rc" = "1" ]; then
    fails=$(printf '%s' "$out" | awk -F'\t' '$2 == "fail" { printf "%s%s", sep, $1; sep = ", " }')
    if [ -n "$fails" ]; then
      printf '실패\t%s' "$fails"; rm -f "$err"; return 0
    fi
    if no_checks_reply "$(cat "$err" 2>/dev/null || true)"; then
      printf '미등록\t-'; rm -f "$err"; return 0
    fi
  fi
  printf '판정 불가\t-'
  rm -f "$err"
  return 0
}

poll_required() {
  # poll_required <slug> <pr-number> — prints the `필수 집합` value.
  #
  # The same rule the driver applies inline, projected onto names instead of a
  # row count. What the field buys is that the answer SURVIVES: the driver's
  # count is a local variable that is gone the moment the merge returns, and by
  # morning only the ledger is left to tell "nothing was required" from "a
  # required check broke".
  local slug="$1" n="$2" out err rc names
  err=$(mktemp)
  out=$(gh -R "$slug" pr checks "$n" --required 2>"$err"); rc=$?
  names=$(names_of "$out")
  if [ -n "$names" ]; then
    printf '%s' "$names"; rm -f "$err"; return 0
  fi
  if no_checks_reply "$(cat "$err" 2>/dev/null || true)"; then
    printf '없음'; rm -f "$err"; return 0
  fi
  case "$rc" in
    0|8) printf '없음' ;;
    *)   printf '판정 불가' ;;
  esac
  rm -f "$err"
  return 0
}

pass_once() {
  local seg row st wt branch slug listed n sha status fails req prev line
  # The poller's own pid, so a person can tell a live poller from a finished
  # run's. NO `.start`/`.pgid` SIBLING IS WRITTEN, and that is what exempts this
  # file from the live-stage census structurally — that predicate requires the
  # sibling. The orphan detector cannot be exempted that way because it asks only
  # "is this pid still here", so it carries the name `checks` explicitly.
  [ -d "$RUN_DIR" ] && printf '%s' "$$" > "$PIDF"
  [ -f "$LEDGER" ] || return 0
  seed_table

  for seg in $(segment_ids); do
    row=$(segment_last_row "$seg")
    [ -n "$row" ] || continue
    st=$(row_field "$row" '상태')
    case "$st" in 머지됨|완료|park) continue ;; esac

    branch=$(row_field "$row" '브랜치')
    wt=$(row_field "$row" '워크트리')
    if [ -z "$branch" ] || [ "$branch" = "-" ] || [ "$branch" = "없음" ]; then
      [ -n "$wt" ] && [ -d "$wt" ] || continue
      branch=$(branch_of "$wt")
    fi
    [ -n "$branch" ] || continue

    slug=""
    [ -n "$wt" ] && [ -d "$wt" ] && slug=$(slug_of "$wt")
    [ -n "$slug" ] || slug=$(manifest_home_slug)
    [ -n "$slug" ] || continue

    # ONE CALL FOR BOTH HALVES OF THE IDENTITY. An empty result is NOT an error
    # — at kickoff no segment has a PR yet, and the healthy state then is "zero
    # poll targets and not one line written". `미등록` is only ever written when
    # a PR EXISTS and carries no checks.
    listed=$(gh -R "$slug" pr list --head "$branch" --json number,headRefOid 2>/dev/null) || continue
    n=$(printf '%s' "$listed" | sed -n 's/.*"number":\([0-9]*\).*/\1/p' | head -1)
    [ -n "$n" ] || continue
    sha=$(printf '%s' "$listed" | sed -n 's/.*"headRefOid":"\([0-9a-f]*\)".*/\1/p' | head -1)
    case "$sha" in
      ????????????????????????????????????????) : ;;
      *) sha="미상" ;;
    esac

    line=$(poll_status "$slug" "$n")
    status=${line%%"$TAB"*}
    fails=${line#*"$TAB"}
    req=$(poll_required "$slug" "$n")

    prev=$(tbl_get "$slug#$n" "$sha")
    [ "$prev" = "$status" ] && continue
    # A `실패` IS COMMITTED ONLY WITH A SETTLED `필수 집합`. The two columns come
    # from two different `gh` calls, and the transition key is `상태` alone — so a
    # `실패` whose second call broke once was written as `필수 집합=판정 불가`,
    # every later pass then matched `prev` and skipped, and a restart re-seeded
    # the same `실패` from the ledger. The gate reads that pair as "no answer" and
    # does not refuse, which is right for a question that broke at the moment it
    # was asked and wrong for one that is never asked again: the refusal stayed off
    # for the rest of that head's life, with no row saying so.
    #
    # So the pair is left unrecorded and the next pass asks both questions again.
    # The retry spacing is the pass itself, which is why no count or delay of this
    # script's own appears here. Until it settles the ledger keeps the previous
    # state, and the gate does with that exactly what it did with the broken pair
    # — nothing — so the deferral opens no window the old row had closed. Only
    # `실패` waits: it is the one state whose verdict reads `필수 집합`.
    # A `--required` that never answers defers the pair for good, and that is
    # accepted: the verdict table answers a `실패` with `필수 집합=판정 불가`
    # exactly as it answers the earlier state — no refusal — so writing the pair
    # would change nothing but the morning's reading, while this stderr line
    # repeats every pass and says so.
    if [ "$status" = "실패" ] && [ "$req" = "판정 불가" ]; then
      printf 'checks: %s 의 필수 집합 조회가 깨져 실패 전이를 다음 패스로 미룹니다\n' "$slug#$n" >&2
      continue
    fi
    tbl_put "$slug#$n" "$sha" "$status"
    # ONE LINE, ONE `>>`. The free-text columns go last and the longer of the two
    # goes last of all, because `read -r a b c` piles every remaining tab into
    # the final variable — the same property `stall` relies on.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(now_iso)" "${seg:--}" "$slug#$n" "$sha" "$status" \
      "$(field_safe "$req" "$REQ_MAX")" "$(field_safe "$fails" "$FAIL_MAX")" >> "$OBSERVED"
  done
  return 0
}

release_pid() {
  rm -f "$PIDF" 2>/dev/null || true
}

run_is_over() {
  # THE THREE EXITS, and this script is born with all of them. `feed.sh` has two
  # and gets away with it because `Monitor` owns its lifetime and `feed.lock.d`
  # reclaims duplicates; this process has neither, so it inherits the watcher's
  # exposure and the third exit is not optional.
  [ -f "$RUN_DIR/done" ] && return 0
  # "NOT YET CREATED" IS NOT "WENT AWAY". The kickoff starts this before the
  # router's first gate call, and that call is what creates the run directory —
  # so absence only ends the loop once the directory has been seen at least once.
  # Until then it is a bounded wait, so a poller pointed at a path that never
  # appears does not linger forever.
  if [ -d "$RUN_DIR" ]; then
    RUN_DIR_SEEN=1
  elif [ "${RUN_DIR_SEEN:-0}" = "1" ]; then
    return 0
  else
    STARTUP_WAIT=$(( ${STARTUP_WAIT:-0} + 1 ))
    if [ "$STARTUP_WAIT" -gt "${STARTUP_MAX:-60}" ]; then
      printf 'checks: 런 디렉터리가 끝내 생기지 않았습니다: %s\n' "$RUN_DIR" >&2
      return 0
    fi
    return 1
  fi
  # THE SHARED PREDICATE, called with its own declared default for the stall
  # threshold rather than a value of this script's own — the terminal branch does
  # not read that argument at all, and declaring one here would be the twelfth
  # unpinned threshold in this tree.
  [ "$(cc_run_state "$RUN_DIR" "$LEDGER")" = "종단" ] && return 0
  return 1
}

# The trap goes up before the pid record does, and `HUP` is on it — a terminal
# going away is one of the ordinary ways a detached process ends.
trap 'release_pid' EXIT HUP INT TERM

while :; do
  pass_once
  [ "$ONCE" = "1" ] && break
  run_is_over && break
  sleep "$INTERVAL"
done
exit 0
