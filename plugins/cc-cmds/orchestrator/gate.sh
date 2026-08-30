#!/usr/bin/env bash
#
# gate.sh — the policy layer's only door.
#
# The router decides WHAT happens next; this decides whether it MAY. Those two
# jobs lived in the same `case` arms of run.sh, so neither could move without
# the other. Splitting them is the whole point of the redesign, and this file is
# the half that does not judge.
#
# THE ARGV IS THE SCHEMA. Under the old shape the driver bought a judgment with
# `claude -p --json-schema` and validated the returned bytes. When the router
# became the main session's own model that artifact disappeared — there is no
# longer a file whose bytes can be checked. So the decision is not an output at
# all: it is a call to this script, and this script's argument parser is what
# the schema check used to be. That is also what makes the router testable
# without a model in the loop — drive the verbs with bad argv against a fixture
# ledger and assert the exit code.
#
# WHY IT SOURCES run.sh RATHER THAN COPYING. `scripts/lint-cutpoint-vocabulary.sh`
# treats run.sh's `readonly CUTPOINTS=` as the single source of truth and does
# not scan siblings, so a second copy here would drift with no detector — which
# is the exact failure that vocabulary lint exists to prevent. Sourcing under
# `CC_ORCH_SOURCE_ONLY=1` (run.sh's own seam, already used by test-run.sh) gets
# the vocabulary, the manifest parsers, the ledger row grammar and the log
# helpers without a second copy of any of them.
#
# Verbs:
#   snapshot   emit the router's whole input as one JSON object
#   grade      dry run — what are this argv's two grades? changes nothing
#   plan       dry run — would this act pass? if not, which rule refuses it
#   act        check, record, perform a pipeline act
#   exec       check, record, perform one bash line (the unit B3 counts)
#   close      resolve a pending approval from the harness-written transcript
#
# Exit codes:
#   0  performed (or, for the dry-run verbs, answered)
#   1  hard stop — malformed invocation, unreadable ledger, failed precondition
#      Past the checks, the ACT's own status passes through, so a non-zero code
#      here can also be the act's. A refusal always carries a `gate:` line on
#      stderr and produces no output from the act; that, not the number, is what
#      separates the two.
#   2  vocabulary error — a token outside a closed set
#   3  rule refusal — a catalog rule said no
#   4  stale snapshot digest — the router judged against state that has moved
#   5  approval issued — the act is outside pre-authorization and irreversible
#   6  grade self-declaration mismatch — the claimed grade is not the graded one
#   7  enforcement surface moved — a file the boundary rests on was edited
#
# Usage:
#   gate.sh snapshot --manifest <path> [--render]
#   gate.sh grade    --manifest <path> -- <argv...>
#   gate.sh plan     --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> -- <argv...>
#   gate.sh act      --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> --snapshot-digest <hex> --rationale <text>
#                    -- <argv...>
#   gate.sh exec     --manifest <path> --target <alias> [--segment <id>]
#                    --cutpoint <token> --surface <token>
#                    --snapshot-digest <hex> --rationale <text> -- <argv...>
#   gate.sh close    --manifest <path> --approval <id> [--void]
#
# `act --kind skill` also takes `--resume <session-id>` to RE-ATTACH a stage that
# was cut mid-flight instead of running it again. The id must appear on a
# `stage-result` row for that segment in this run's ledger.
#
# Two `act` kinds take FIELDS rather than a command after `--`, because what
# they perform is the ledger row itself:
#   gate.sh act --kind segment --target <alias> --segment <id> ... \\
#               -- 상태=<계획됨|실행중|리뷰중|머지됨|적용 준비|park> 워크트리=<path> [브랜치=… PR=…]
#   gate.sh act --kind cycle   --target <alias> --segment <id> ... \\
#               -- 사이클=<n> P0=<n> P1=<n> '리뷰 HEAD=<sha>' [리포트 경로=…]
#
# Compatibility: bash 3.2 (macOS stock under the sanitized PATH) — no
# associative arrays, no mapfile, no `wait -n`, no case-modification expansions.
# `scripts/lint-bash-portability.sh` scans this directory at maxdepth 1, so this
# file is linted on arrival with no registration.

# `$BASH_SOURCE` and not `$0`: under the source-only seam below `$0` is the
# SOURCING script, so the run.sh path and the rule catalog would both resolve
# relative to whoever sourced this file.
GATE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# Source the driver for its definitions only. This must happen before `set -e`
# considerations below: run.sh sets `-euo pipefail` itself and we keep it.
CC_ORCH_SOURCE_ONLY=1
export CC_ORCH_SOURCE_ONLY
# shellcheck source=/dev/null
. "$GATE_DIR/run.sh"
# The capability half of the boundary. Sourced rather than re-implemented: the
# gate is the one process that holds the write-scoped credential, and the code
# that decides which credential a child gets has to be the same code in both
# directions or the separation is decorative.
# shellcheck source=/dev/null
. "$GATE_DIR/credentials.sh"

readonly GATE_EXIT_VOCAB=2
readonly GATE_EXIT_RULE=3
readonly GATE_EXIT_STALE=4
readonly GATE_EXIT_APPROVAL=5
readonly GATE_EXIT_GRADE=6
readonly GATE_EXIT_SURFACE=7

readonly GATE_ROW_MAX=1024

# ---------------------------------------------------------------------------
# Axis 2 — the effect surface.
#
# The cutpoint ladder is a sequence of pipeline milestones, not a lattice of
# harm. Mapping `rm -rf ~/Documents`, a curl to a payments API and an unfamiliar
# `npx` onto `배포` means a run authorized to deploy is authorized to anything —
# the ladder collapses at its top rung. So an act carries a grade on each of two
# independent axes, and both are checked.
#
# Stored tokens carry no spaces, for the same reason the cutpoint vocabulary
# splits stored from display: a value with a space cannot round-trip through the
# `for x in $LIST` word-splitting this file and run.sh both rely on, and the one
# time that distinction was skipped the index lookup answered "unknown" and
# every act was silently denied.
# ---------------------------------------------------------------------------
readonly SURFACES="읽기 워크트리쓰기 트리밖쓰기 외부상태변경"

surface_display() {
  case "$1" in
    읽기)         printf '읽기' ;;
    워크트리쓰기) printf '워크트리 쓰기' ;;
    트리밖쓰기)   printf '워크트리 밖 쓰기' ;;
    외부상태변경) printf '외부 상태 변경' ;;
    *) return 1 ;;
  esac
}

# Same discipline as cutpoint_index: signal by return status, never by `die`.
# This is always called inside `$( )`, where an exit kills only the subshell and
# leaves the caller holding an empty string.
surface_index() {
  local want="$1" i=0 s
  for s in $SURFACES; do
    i=$((i + 1))
    [ "$s" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  warn "미인식 효과면 토큰: '${want}' — 허용 토큰: ${SURFACES}"
  return 1
}

# The grading table. An argv0 with no row gets `등급 미상` and NEVER `읽기` —
# reading an unknown thing as the safest value is the characteristic failure of
# this class of table.
#
# argv0 is reduced to its BASENAME before the lookup. The table lists bare
# names, and a command spelled with a path — `/opt/homebrew/bin/gh pr merge` —
# matched no arm and came back `등급 미상`, which is a refusal. That closed the
# absolute-path spelling at the same time as the sanitized PATH closed the bare
# one, leaving no spelling that reached `gh` at all.
#
# Normalizing does not weaken the grade. What this table measures is EFFECT
# SURFACE, not identity: an unexpected binary named `gh` grades `외부상태변경`,
# which is the stricter side, and a grade that depends on how a caller happened
# to spell the path is not a property of the act.
surface_of_argv0() {
  local cmd="${1##*/}"
  shift
  case "$cmd" in
    cat|ls|find|grep|rg|head|tail|wc|stat|file|diff|which|command)
      printf '읽기' ;;
    # Digest tools. Their absence was a DEADLOCK rather than a gap: the
    # unattended implement arm's process B may enter only after comparing the
    # plan's digest against the one on the ledger row, and computing that digest
    # is the only way to make the comparison. With no row here every spelling
    # was refused, so the one path left was wrapping the command in an
    # interpreter to hide argv0 — which is the exact hole the stage had been
    # dispatched to close. Measured: a stage arrived, found this, and stopped
    # rather than use the hole to land the hole's fix, on the ground that the
    # artifact would then refute itself and the ledger row would state the act's
    # authorization falsely.
    #
    # `openssl` is deliberately NOT here. It computes digests, and it also
    # opens network connections — one name covering both is the kind of
    # imprecision this table exists to refuse.
    # `md5`/`md5sum` are deliberately absent: they are the BSD and GNU spellings
    # of one tool, so naming both trips the portability lint on this very line —
    # and nothing here needs them, since every digest this pipeline compares is
    # sha256.
    shasum|sha256sum|sha1sum|sha512sum|cksum|b2sum)
      printf '읽기' ;;
    git) surface_of_git "$@" ;;
    gh)  surface_of_gh "$@" ;;
    make|npm|npx|yarn|pnpm|pytest|go|cargo|bash|sh|zsh|python3|node)
      printf '워크트리쓰기' ;;
    mkdir|touch|cp|mv|rm|sed|tee|install)
      printf '워크트리쓰기' ;;
    curl|wget|ssh|scp|rsync|terraform|kubectl|aws|gcloud|docker)
      printf '외부상태변경' ;;
    # Database clients. A schema migration is a standard step BEFORE a deploy,
    # not an exotic one, and with no row here every one of them fell to `등급
    # 미상` — which refuses. All three ways out were closed at once: `--surface`
    # is a checked claim and any claim mismatches an unknown grade; the basename
    # normalization makes the absolute-path spelling identical; and wrapping in
    # `bash -c` passes while recording a DDL against a database as a worktree
    # write, which is the laundering this table exists to refuse.
    #
    # Graded `외부상태변경` even though these clients can also read. The grade is
    # taken from argv0 alone, so a read-only `SELECT` cannot be told apart from a
    # migration here — and of the two ways to be wrong, requiring a
    # pre-authorization row for a read costs a line in the manifest, while
    # letting a migration through as a read costs the database.
    mysql|mysqladmin|mysqldump|psql|pg_dump|pg_restore|createdb|dropdb|sqlite3|mongo|mongosh|redis-cli)
      printf '외부상태변경' ;;
    *) printf '등급 미상' ;;
  esac
}

surface_of_git() {
  # git's GLOBAL options come BEFORE the subcommand, so `git -C <path> commit`
  # puts `-C` in the slot the table reads and the whole act graded `등급 미상`.
  #
  # Only the globals git actually defines are skipped, and an UNRECOGNIZED dash
  # option ends the scan as unknown rather than guessing whether it consumes the
  # next word. Guessing wrong would shift the subcommand out of view and grade a
  # `push` by whatever word landed in its place — a wrong grade is worse here
  # than no grade, because `등급 미상` refuses and a wrong grade performs.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        [ $# -ge 2 ] || { printf '등급 미상'; return 0; }
        shift 2 ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
        shift ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects)
        shift ;;
      --literal-pathspecs|--no-optional-locks|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        shift ;;
      -*) printf '등급 미상'; return 0 ;;
      *)  break ;;
    esac
  done
  case "${1:-}" in
    status|log|show|diff|rev-parse|rev-list|merge-base|branch|worktree|config|blame|cat-file|ls-files)
      printf '읽기' ;;
    add|commit|checkout|switch|restore|rebase|merge|cherry-pick|stash|apply|am|reset|tag)
      printf '워크트리쓰기' ;;
    push|fetch|pull|clone|remote)
      printf '외부상태변경' ;;
    *) printf '등급 미상' ;;
  esac
}

surface_of_gh() {
  case "${1:-}" in
    api) surface_of_gh_api "$@" ;;
    pr|issue|release|repo|workflow|run) printf '외부상태변경' ;;
    # `auth` is a DELIBERATE refusal, not a gap in the table. It reads and
    # rewrites the credential the whole separation rests on, so an act that
    # reached it would be editing the thing that limits it.
    auth) printf '등급 미상' ;;
    *) printf '등급 미상' ;;
  esac
}

surface_of_gh_api() {
  # `gh api` is graded by the HTTP METHOD it will send, not by the word `api`.
  # Grading the subcommand made a read of a pull request's review threads
  # indistinguishable from a merge and refused both — which took away the only
  # spelling that submits several inline comments as ONE review
  # (`POST …/pulls/{n}/reviews`; `gh pr review` carries no comments array), and
  # every read of a value `gh pr view --json` does not expose along with it.
  shift
  local m="" body=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method)
        [ $# -ge 2 ] || break
        m="$2"; shift 2 ;;
      --method=*) m="${1#--method=}"; shift ;;
      -X*)        m="${1#-X}"; shift ;;
      -f|-F|--field|--raw-field|--input)
        body=1
        [ $# -ge 2 ] || break
        shift 2 ;;
      -f*|-F*)    body=1; shift ;;
      -H|--header|-q|--jq|-t|--template|--hostname|--cache)
        [ $# -ge 2 ] || break
        shift 2 ;;
      *) shift ;;
    esac
  done
  # An explicit method wins. Otherwise a field or an input body is exactly what
  # makes gh itself switch from GET to POST, so the table reads the same signal
  # the tool does rather than a second, divergent one.
  if [ -z "$m" ]; then
    if [ "$body" = "1" ]; then m=POST; else m=GET; fi
  fi
  case "$m" in
    GET|get|HEAD|head) printf '읽기' ;;
    *) printf '외부상태변경' ;;
  esac
}

# ---------------------------------------------------------------------------
# Ledger append — serialized, capped, chained.
#
# run.sh's comment says the ledger has one writer, and that is true of the
# COMPONENT: one function appends. It is not true of the PROCESSES — every gate
# invocation is its own shell, so two acts in flight are two writers against one
# file. Concurrent appends splice field values above 1024 bytes of total line
# length while the line count stays correct, which no row-grammar check can see.
# Three things together close that: the lock makes interleaving rare, the cap
# keeps a row under the measured threshold, and the chain makes the rare case
# detectable rather than silent.
# ---------------------------------------------------------------------------
# Every read below goes through this. A ledger that does not exist yet is the
# NORMAL state at the first act of a run, and `grep` answers a missing file with
# exit 2 — which `pipefail` promotes to the whole pipeline's status and `set -e`
# turns into a silent exit of the snapshot. The first act of the first run is
# exactly when a router most needs the snapshot to answer, so the tolerance is
# not defensive padding: it is the case that always happens.
gate_rows() {
  # gate_rows <series>
  grep -E "^- \`$1\`" "$LEDGER" 2>/dev/null || true
}

gate_has_row() {
  # gate_has_row <series> <fixed-string>
  #
  # NOT `gate_rows X | grep -qF Y`. Under `pipefail` an early-exiting reader on
  # the right of a pipe kills the writer with SIGPIPE and the pipeline reports
  # failure — so a row that IS present can come back as "absent", and every one
  # of these call sites uses absence to decide whether to append. The result
  # would be duplicate approvals and duplicate obligations, which the
  # termination conditions then count.
  local series="$1" needle="$2" out
  out=$(gate_rows "$series")
  case "$out" in *"$needle"*) return 0 ;; esac
  return 1
}

gate_count() {
  # Count of non-empty lines on stdin. `grep -c` answers 0 with exit 1 on empty
  # input, so the usual `|| printf 0` fallback prints a SECOND zero and the
  # caller ends up interpolating `0\n0` — which produced a syntactically
  # invalid snapshot object rather than a wrong number, so nothing downstream
  # could even read far enough to notice.
  grep -c . || true
}

gate_chain_tip() {
  # The digest of the ledger's last ROW, or of the run block heading when no row
  # has been written yet.
  #
  # Rows and not lines, and the difference was not cosmetic. The ledger file is
  # also the morning report, so prose lands in it between rows — the kickoff's
  # stub alone puts two lines there before any act. Hashing the last LINE made
  # the first row point at the stub's identifying line while the verifier, which
  # walks rows, started from the heading, so an UNTOUCHED ledger read as broken
  # at row 1 on every run.
  #
  # A permanently broken chain is worse than no chain: a real splice then looks
  # exactly like a normal kickoff, and a reader who sees `끊김` every morning
  # learns to skip the one field that would have told them.
  local last
  last=$( { grep '^- `' "$LEDGER" 2>/dev/null || true; } | tail -1)
  [ -n "$last" ] || last="## 실행 $RUN_ID"
  printf '%s' "$last" | shasum -a 256 | cut -d' ' -f1
}

gate_append() {
  # gate_append <계열> <field=value> ...
  #
  # The writer hashes what it INTENDED to write, not a re-read of the file — a
  # chain built from a re-read certifies whatever landed, including a splice.
  local series="$1"; shift
  local prev line f
  prev=$(gate_chain_tip)
  line="- \`$series\`"
  for f in "$@"; do line="$line | $f"; done
  line="$line | prev=$prev"

  local n
  n=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
  if [ "$n" -gt "$GATE_ROW_MAX" ]; then
    die "원장 행이 상한을 넘습니다 (${n} > ${GATE_ROW_MAX} 바이트) — 긴 값은 사이드카로 빼야 합니다: ${series}"
  fi

  local tool rc=0
  tool=$(lock_tool)
  if [ -n "$tool" ] && [ -n "${RUN_DIR:-}" ]; then
    "$tool" -k "$RUN_DIR/ledger.lock" \
      /bin/sh -c 'printf "%s\n" "$1" >> "$2"' _ "$line" "$LEDGER" || rc=$?
  else
    printf '%s\n' "$line" >> "$LEDGER" || rc=$?
  fi
  # A LOST ROW IS NOT A WARNING. The whole design forbids an act with no row, so
  # an append that fails — an unwritable lock path, a full disk, a bad ledger
  # path — has to stop the act rather than let it proceed unrecorded. This
  # failed silently once: with `RUN_DIR` empty the lock path became `/ledger.lock`,
  # every append failed, and the caller went on believing it had written.
  [ "$rc" = "0" ] || die "원장 행을 쓰지 못했습니다 (rc=$rc) — 기록 없는 행위는 수행하지 않습니다: ${series}"
  return 0
}

# ---------------------------------------------------------------------------
# Progress vector and its digest.
#
# This is NOT the snapshot. The snapshot is what the router reads and is
# deliberately rich; P is what stagnation is measured over and is deliberately
# poor. Excluded on purpose: cost (monotone), recurrence counts (monotone),
# the no-progress counter itself (self-referential), timestamps, absolute paths,
# and — the one that is easy to get wrong — pending approvals.
#
# Pending approvals are excluded because every boundary that fires ISSUES one.
# With them inside, the boundary's own remedy mutates the hashed input and
# resets the counter that fired it, so the bound can never be reached. That is
# the same defect one layer up from the counter-inside-its-own-hash bug this
# design was written to remove.
# ---------------------------------------------------------------------------
gate_progress_vector() {
  local a
  printf 'goal=%s\n' "$(manifest_field '인가' '종료 지점' | shasum -a 256 | cut -d' ' -f1)"
  for a in $(target_aliases); do
    printf 'target=%s|%s|%s\n' "$a" \
      "$(target_field "$a" '원격 슬러그')" "$(target_field "$a" '절단점')"
  done | sort
  gate_rows 'segment' \
    | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u \
    | while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        printf 'segment=%s|%s|%s\n' "$sid" \
          "$(gate_segment_field "$sid" '상태')" "$(gate_segment_field "$sid" '커밋')"
      done
  gate_open_obligations | sort
}

gate_progress_digest() {
  gate_progress_vector | shasum -a 256 | cut -d' ' -f1
}

gate_segment_field() {
  # Last row for this segment id wins — the append-only advance of contract 3.4.
  local sid="$1" key="$2"
  gate_rows 'segment' \
    | grep -F "id=$sid " | tail -1 \
    | tr '|' '\n' | sed -n "s/^ *$key=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_open_obligations() {
  # An obligation is closed only by a LATER cycle row for the same segment whose
  # report no longer carries the identity — a `problem` row records an attempt,
  # not a resolution, so reading closure from it would mark every re-try as a fix.
  gate_rows 'problem' \
    | tr '|' '\n' | sed -n 's/^ *동일성=//p' | sed 's/[[:space:]]*$//' \
    | sort -u | while IFS= read -r ident; do
        [ -n "$ident" ] || continue
        printf 'obligation=%s\n' "$ident"
      done
}

gate_ledger_damage() {
  # Rows that do not parse as rows. Never silently zero: a skipped row could be
  # the cycle row carrying the P0 that the merge rule reads, and skipping it
  # makes a live defect look resolved.
  local n total
  n=$(grep -E '^- `[^`]+`( \|.*)?$' "$LEDGER" 2>/dev/null | gate_count)
  total=$(grep -E '^- `' "$LEDGER" 2>/dev/null | gate_count)
  printf '%s' $(( total - n ))
}

# ---------------------------------------------------------------------------
# Per-target cutpoint adjudication.
#
# `authorized()` is deliberately NOT used. It takes one argument, reads the
# grant's run-level maximum, and no call site passes a target — so a run
# declaring `frontend: PR` alongside `infra: 배포` authorizes deploy-grade acts
# against the front end. That is filed as Nharu/cc-cmds#208. The value that
# authorizes an act is the one on that act's target row, and this reads it there.
# ---------------------------------------------------------------------------
# The gate resolves the vocabulary — it holds run.sh's tables — and the catalog
# decides. Keeping the comparison here as well would put the same rule in two
# places, and the one that drifts is the one nobody is looking at.
gate_export_cutpoints() {
  # gate_export_cutpoints <alias> <act-token>
  local alias="$1" act="$2" tgt
  GATE_ACT_INDEX=$(cutpoint_index "$act") || return "$GATE_EXIT_VOCAB"
  tgt=$(target_field "$alias" '절단점')
  [ -n "$tgt" ] || { warn "대상 '$alias' 의 절단점이 매니페스트에 없습니다"; return 1; }
  GATE_TARGET_CUTPOINT="$tgt"
  GATE_TARGET_INDEX=$(cutpoint_index "$tgt") || return "$GATE_EXIT_VOCAB"
  export GATE_ACT_INDEX GATE_TARGET_CUTPOINT GATE_TARGET_INDEX
  return 0
}

# ---------------------------------------------------------------------------
# Rule catalog.
#
# A rule is a `.rule` declaration plus a checker script, and the loader reads
# the pair. A declaration whose checker is missing is not loaded at all, so
# "declared but unenforceable" is not a state this catalog can be in — which is
# the property the design asked for and the reason the catalog is a directory
# rather than a table.
# ---------------------------------------------------------------------------
gate_rules_dir() { printf '%s/rules' "$GATE_DIR"; }

gate_rule_order() {
  # Declaration paths, ascending by `순서:`. A declaration with no `순서:` sorts
  # last rather than being dropped — a rule missing one field is still a rule,
  # and silently unloading it is the "declared but unenforceable" state this
  # catalog is shaped to make impossible.
  local d f n
  d=$(gate_rules_dir)
  for f in "$d"/*.rule; do
    [ -f "$f" ] || continue
    # Quit AFTER a match, not on the first line: `/./q` tests the pattern
    # space, which is never empty, so it ends the script before the address
    # that matters is ever reached.
    n=$(sed -n '/^순서:/{s/^순서: *\([0-9][0-9]*\).*/\1/p;q;}' "$f")
    [ -n "$n" ] || n=999
    printf '%s\t%s\n' "$n" "$f"
  done | sort -n | cut -f2
}

gate_rule_enabled() {
  # A rule is on unless the manifest turns it off. Three ignore the setting:
  # `절단점 준수`, `사전 인가 대조` and `인가 자기확장 금지`. The authorization
  # record means nothing if the first two can be switched off, and a
  # self-widening ban that can be switched off is not a ban at all — after the
  # first time it is turned off, the record does not even say what was turned
  # off.
  local name="$1"
  case "$name" in
    절단점-준수|사전-인가-대조|인가-자기확장-금지) return 0 ;;
  esac
  local setting
  setting=$(manifest_field '룰 설정' "$name")
  [ "$setting" = "끔" ] && return 1
  return 0
}

gate_run_rules() {
  # gate_run_rules <act-token> <alias> <segment> <argv-string>
  # Returns 0 when every loaded rule passes, GATE_EXIT_RULE on the first refusal.
  local act="$1" alias="$2" seg="$3" argv="$4"
  local dir decl name checker
  dir=$(gate_rules_dir)
  [ -d "$dir" ] || return 0
  # Ordered by each declaration's `순서:` field, not by the glob. Glob order
  # over Korean filenames is arbitrary, and the first refusal is the one the
  # run reports — so under the shipped order a cutpoint violation came back as
  # "the ledger is unreadable", which sends a 3am reader to the wrong repair.
  # The cheapest and most fundamental checks go first so the reported reason is
  # the most fundamental one that holds.
  for decl in $(gate_rule_order); do
    [ -f "$decl" ] || continue
    name=$(basename "$decl" .rule)
    checker="$dir/$name.sh"
    if [ ! -f "$checker" ]; then
      warn "룰 '$name' 의 검사기가 없어 로드하지 않습니다 — 선언만으로는 강제되지 않습니다"
      continue
    fi
    gate_rule_enabled "$name" || continue
    local rc=0
    GATE_ACT="$act" GATE_ALIAS="$alias" GATE_SEGMENT="$seg" GATE_ARGV="$argv" \
      GATE_LEDGER="$LEDGER" GATE_MANIFEST="$MANIFEST" GATE_GRANT="$GRANT" \
      /bin/sh "$checker" || rc=$?
    [ "$rc" = "0" ] && continue
    # A checker may ask for an approval instead of refusing. Folding that into a
    # plain refusal is what turns "nobody is awake to ask" into "the answer is
    # no" — the collapse this design exists to undo.
    if [ "$rc" = "$GATE_EXIT_APPROVAL" ]; then
      warn "룰 '$name' 이 승인 대기를 요구합니다"
      return "$GATE_EXIT_APPROVAL"
    fi
    warn "룰 거부: $name"
    return "$GATE_EXIT_RULE"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot — the router's entire declared input.
#
# JSON on stdout rather than a table: a table cannot express arrays, cannot be
# canonically serialized, and cannot be validated. `--render` turns the same
# object into the human form for the terminal.
#
# Two fields are unbounded in run length and are therefore capped, with their
# true totals reported separately. Truncating a list while reporting the real
# total is safe; truncating the total is how a router concludes a P0 is gone.
# ---------------------------------------------------------------------------
readonly GATE_OBLIGATION_CAP=50

gate_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

gate_snapshot() {
  local a total shown
  printf '{\n'
  printf '  "run_id": "%s",\n' "$(gate_json_escape "$RUN_ID")"
  printf '  "goal": "%s",\n' "$(gate_json_escape "$(manifest_field '인가' '종료 지점')")"
  printf '  "goal_digest": "%s",\n' \
    "$(manifest_field '인가' '종료 지점' | shasum -a 256 | cut -d' ' -f1)"

  printf '  "targets": [\n'
  local first=1
  for a in $(target_aliases); do
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"alias": "%s", "slug": "%s", "cutpoint": "%s", "home": "%s"}' \
      "$(gate_json_escape "$a")" \
      "$(gate_json_escape "$(target_field "$a" '원격 슬러그')")" \
      "$(gate_json_escape "$(target_field "$a" '절단점')")" \
      "$(gate_json_escape "$(target_field "$a" '홈')")"
  done
  [ "$first" = "1" ] || printf '\n'
  printf '  ],\n'

  printf '  "obligations": [\n'
  total=$(gate_open_obligations | gate_count)
  shown=0
  first=1
  gate_open_obligations | awk -v cap="$GATE_OBLIGATION_CAP" 'NR<=cap' | while IFS= read -r o; do
    [ -n "$o" ] || continue
    [ "$shown" = "0" ] || printf ',\n'
    shown=1
    printf '    "%s"' "$(gate_json_escape "${o#obligation=}")"
  done
  [ "$first" = "1" ] && [ "$total" = "0" ] || printf '\n'
  printf '  ],\n'
  printf '  "obligations_total": %s,\n' "$total"

  printf '  "pending_approvals": [\n'
  gate_pending_approvals_json
  printf '  ],\n'

  printf '  "ledger_damage": %s,\n' "$(gate_ledger_damage)"
  printf '  "chain_intact": %s,\n' "$(gate_chain_verify >/dev/null 2>&1 && printf 'true' || printf 'false')"
  printf '  "H": "%s"\n' "$(gate_progress_digest)"
  printf '}\n'
}

gate_pending_approvals_json() {
  local ids id state first=1
  ids=$(gate_rows '승인' \
        | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u)
  for id in $ids; do
    state=$( { gate_rows '승인' | grep -F "승인 id=$id " || true; } | tail -1 \
            | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$state" = "대기" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '    {"id": "%s", "blocks": "%s"}' \
      "$(gate_json_escape "$id")" \
      "$(gate_json_escape "$(gate_rows '승인' | grep -F "승인 id=$id " | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *막는 세그먼트=//p' | sed 's/[[:space:]]*$//' | tail -1)")"
  done
  [ "$first" = "1" ] || printf '\n'
}

gate_render_snapshot() {
  local a
  printf '목표      : %s\n' "$(manifest_field '인가' '종료 지점')"
  printf '진전 해시 : %s\n' "$(gate_progress_digest)"
  printf '원장 손상 : %s\n' "$(gate_ledger_damage)"
  # The break's ROW NUMBER reaches the reader. `gate_chain_verify` has always
  # reported it, and every caller threw it away into `2>&1` — so the render said
  # `끊김` and gave the morning nowhere to look.
  local chain_out
  chain_out=$(gate_chain_verify 2>&1 >/dev/null || true)
  if [ -z "$chain_out" ]; then
    printf '해시 체인 : 무결\n'
  else
    printf '해시 체인 : 끊김 — %s\n' "$chain_out"
  fi
  printf '대상      :\n'
  for a in $(target_aliases); do
    printf '  %-12s %-24s 절단점 %s\n' "$a" \
      "$(target_field "$a" '원격 슬러그')" "$(target_field "$a" '절단점')"
  done
  printf '미해결 의무: %s건\n' "$(gate_open_obligations | gate_count)"

  # LIVENESS, because "is this still going?" had no cheap answer. The heartbeat
  # a watcher prints goes to a stdout that its launching tool call already
  # closed, so it reaches nobody; the render did not carry a live-stage count,
  # a ledger age, or the run's own terminal state. Answering it needed the row
  # grammar and a manual pid comparison.
  local n_live now_s led_s hb_s done_line
  n_live=$( { ls "$RUN_DIR"/*.pid 2>/dev/null || true; } | gate_count)
  now_s=$(date -u +%s)
  led_s=$(gate_mtime "$LEDGER")
  hb_s=$(gate_mtime "$RUN_DIR/watch.heartbeat")
  printf '살아 있는 스테이지: %s개\n' "$n_live"
  if [ -n "$led_s" ]; then printf '원장 갱신 : %s초 전\n' "$((now_s - led_s))"
  else                     printf '원장 갱신 : (없음)\n'; fi
  if [ -n "$hb_s" ]; then printf '감시자    : %s초 전 하트비트\n' "$((now_s - hb_s))"
  else                    printf '감시자    : 하트비트 없음 (안 돌거나 옛 판입니다)\n'; fi
  done_line=$(cat "$RUN_DIR/done" 2>/dev/null || true)
  if [ -n "$done_line" ]; then printf '런 상태   : 종단 — %s\n' "$done_line"
  else                         printf '런 상태   : 진행 중\n'; fi
  printf '스테이지 스트림: %s/log/<세그먼트>.json\n' "$RUN_DIR"
}

gate_mtime() {
  # gate_mtime <path> — epoch seconds, or empty. `stat` diverges between BSD and
  # GNU on the very flag this needs, so neither spelling is used: `find -newer`
  # against a probe would need a probe, and `ls` output is locale-shaped. `date
  # -r` is present on both and takes the file directly.
  [ -f "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run settings — one file per stage kind, written by the gate, injected by the
# wrapper.
#
# This file is the premise of three separate decisions and had no producing step
# in any of them; two of those decisions also disagreed about its shape, one
# calling for a single shared file and the other for a `design`-specific variant.
# It is settled here: a DIRECTORY under the run directory with one file per stage
# kind, the common gate hook in every variant, and the network-fetch denial in
# the `design` variant only.
#
# The whole directory is an enforcement surface, not one file inside it — the
# digest set the gate re-derives on every hook consultation takes the directory
# as its element, because adding a variant must not be a way to escape the
# comparison.
# ---------------------------------------------------------------------------
readonly STAGE_KINDS="design implement review audit reconverge generic"

gate_settings_dir() {
  # The override exists for ONE caller: the re-derivation probe, which needs to
  # render the settings somewhere harmless to compare them against what is on
  # disk. Rendering them in place to find out whether they changed would move
  # the very surface it is asking about.
  printf '%s' "${CC_GATE_SETTINGS_OVERRIDE:-$RUN_DIR/settings}"
}

gate_settings_file() {
  # gate_settings_file <stage-kind>
  local k="$1"
  case " $STAGE_KINDS " in
    *" $k "*) : ;;
    *) k="generic" ;;
  esac
  printf '%s/%s.json' "$(gate_settings_dir)" "$k"
}

gate_write_settings() {
  # Writes every variant. Called at run start and idempotent — a re-run after a
  # session cut must find the same bytes, because those bytes are in the
  # enforcement-surface digest set and a regenerated-but-different file would
  # read as tampering.
  local dir hook k f deny_extra plugin_dir extra_dirs doc_ws a wt_all
  dir=$(gate_settings_dir)
  mkdir -p "$dir"
  hook="$(dirname "$GATE_DIR")/hooks/gate-pretool.sh"
  [ -f "$hook" ] || die "게이트 훅 스크립트가 없습니다: $hook"

  # THE STAGE MUST BE ABLE TO READ ITS OWN SKILL'S DOCUMENTS.
  #
  # Every skill here opens by Reading several `_common/*` files, and those live
  # in the plugin cache — outside the working directory, so outside what the
  # ambient configuration permits. Measured: a review stage ran seven turns,
  # collected five `Read` denials under the plugin directory, reported that it
  # had stopped before its first step, and exited 0 with no artifact. It
  # explicitly declined to reach the same bytes with `cat`, on the ground that
  # doing so would defeat a permission decision rather than satisfy it — which
  # is the right call and is exactly why the permission has to be granted here.
  #
  # The run's own files are listed for the same reason: the manifest, ledger and
  # grant live under the HOME worktree, so a stage acting in any other target
  # cannot reach them from its own directory.
  #
  # The DESIGN DOCUMENT's directory is listed separately from the run's base
  # because in a polyrepo workspace it is in neither — the repositories are
  # siblings under one directory and the documents describing work across them
  # belong to none of them. A stage measured against a document it cannot read
  # produces nothing and reports success.
  #
  # Read is deliberately NOT added to the hook matcher below. That matcher is
  # default-deny, so adding Read there would deny every read instead of
  # recording it; what a denied read costs is a ledger row, and the price of
  # buying that row with this hook is the whole read surface.
  #
  # Every path is derived, so the bytes stay identical across a re-run — which
  # they must, since this file is in the enforcement-surface digest set.
  #
  # A DOCUMENT THAT DEFERS TO ANOTHER DOCUMENT. Design documents routinely name
  # a second one as the source of truth for part of their content — a task
  # design and an applied design as separate files is the normal shape — and
  # that second file is a sibling or a parent, not a child. For a document
  # INSIDE a repository the grant already reaches it, because `DOC_BASE` is the
  # repository root. For one outside every repository `DOC_BASE` collapses onto
  # the document's own folder, and the grant was exactly that folder.
  #
  # So the containing WORKSPACE is granted in that case, and only that case: for
  # a document that belongs to no repository, its workspace is its parent
  # directory. This is read-only and it is the same widening the in-repo branch
  # already has. The failure it removes is the quiet one — the stage has
  # something to read, so it does not stop; it produces output measured against
  # half a specification and nothing in the artifact says which half.
  #
  # `$DOC` and not `$DOC_DIR` in the guard: a run with NO document still sets
  # `DOC_DIR` and `DOC_BASE` to the run's base, so testing their equality alone
  # would widen the grant to the base's parent on every documentless run — a
  # directory nothing in the run has any business reading.
  doc_ws=""
  if [ -n "${DOC:-}" ] && [ "${DOC_BASE:-}" = "${DOC_DIR:-}" ]; then
    doc_ws=$(dirname "$DOC_DIR")
  fi
  plugin_dir=$(cd "$(dirname "$GATE_DIR")" && pwd)
  # EVERY TARGET'S WORKTREES, both of them, for every declared target.
  #
  # The list used to carry only the run's own base — the HOME worktree — so a
  # stage acting in any other target could not read that target at all, and a
  # stage woken in an EXECUTION worktree could not read the tree it was standing
  # in. That second one is not an edge case: `실행 워크트리` exists for `pr` and
  # `branch` anchors, and for those the landing surface is always outside the
  # main worktree because git refuses to check one branch out twice. Measured: a
  # stage passed every earlier step and then halted before its first write with
  # "Claude requested permissions to read from <execution worktree>/… but you
  # haven't granted it yet".
  #
  # Physical paths go in beside the spelled ones. `DOC_DIR` and `DOC_BASE` are
  # derived from how the path was WRITTEN, so a design document reached through
  # a symlink grants the link's directory and not the file's real one — and the
  # out-of-repo widening does not fire either, because by spelling the link sits
  # inside the repository. `pwd -P` resolves it; adding both costs one line and
  # covers either spelling.
  wt_all=""
  for a in $(target_aliases); do
    wt_all="$wt_all
$(target_field "$a" '메인 워크트리')
$(target_field "$a" '실행 워크트리')"
  done
  extra_dirs=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$plugin_dir" "$RUN_DIR" "$BASE" \
      "$(dirname "$MANIFEST")" "$(dirname "$LEDGER")" "$(dirname "$GRANT")" \
      "${DOC_DIR:-}" "${DOC_BASE:-}" "$doc_ws" \
      "$( [ -n "${DOC_DIR:-}" ] && cd "$DOC_DIR" 2>/dev/null && pwd -P || true)" \
      "$( [ -n "${DOC_BASE:-}" ] && cd "$DOC_BASE" 2>/dev/null && pwd -P || true)" \
      "$wt_all" \
    | sed '/^$/d' | sed 's/^(없음)$//' | sed '/^$/d' \
    | sort -u | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')

  for k in $STAGE_KINDS; do
    f=$(gate_settings_file "$k")
    # `design` alone loses the network-fetch tools. The per-stage spend cap that
    # motivates it cannot be enforced by the argv0 grading table at all — a
    # `WebFetch` call has no argv0 and never reaches the gate — so the only
    # enforcement point available is the settings file the wrapper injects.
    deny_extra=""
    [ "$k" = "design" ] && deny_extra='"WebFetch", "WebSearch", '
    cat > "$f" <<JSON
{
  "permissions": {
    "deny": [ ${deny_extra}"Bash(sudo:*)" ],
    "additionalDirectories": [ ${extra_dirs} ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash '$hook' --run-dir '$RUN_DIR' --gate '$GATE_DIR/gate.sh' --ledger '$LEDGER' --grant '$GRANT'"
          }
        ]
      }
    ]
  }
}
JSON
  done
  # NOT under the probe. The probe renders these files somewhere harmless to
  # find out whether they changed, and its digest is taken over that other
  # directory — writing it here would replace the real baseline with a value
  # that describes a temporary path, and every act afterwards would read as a
  # moved surface.
  if [ -z "${CC_GATE_SETTINGS_OVERRIDE:-}" ]; then
    printf '%s\n' "$(gate_surface_digest)" > "$RUN_DIR/surface-digest"
    log "런 설정 생성: $dir (강제 표면 기준선 기록)"
  fi
}

gate_resettle_settings() {
  # Re-derive the stage settings and, when they differ, rewrite + re-baseline +
  # record. This is what lets a run reach a directory kickoff could not know
  # about — a segment's own worktree, a repository the run added at layer 1 —
  # without either freezing the run or making the surface comparison hollow.
  #
  # The derivation is a pure function of the manifest and the ledger, so the
  # bytes move only when one of those moved, and both are themselves recorded.
  # An edit by anything that is not this function still lands as exit 7, which
  # is the property the digest exists for.
  local before after tmpdir base
  before=$(gate_surface_digest)

  # ONLY FROM A KNOWN-GOOD BASELINE. If the surface has already moved, this is
  # not the place to decide about it — `gate_surface_check` owns that verdict,
  # and rewriting here would erase the very evidence it reads. Without this
  # guard the re-derivation silently repairs and re-baselines an edit made by
  # anything at all, which is exactly the detection the digest exists for.
  base=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || true)
  [ -n "$base" ] && [ "$before" = "$base" ] || return 0

  tmpdir="$(gate_settings_dir).probe.$$"
  rm -rf "$tmpdir"
  ( CC_GATE_SETTINGS_OVERRIDE="$tmpdir"; export CC_GATE_SETTINGS_OVERRIDE
    gate_write_settings >/dev/null 2>&1 ) || { rm -rf "$tmpdir"; return 0; }
  if diff -r -q "$tmpdir" "$(gate_settings_dir)" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; return 0
  fi
  rm -rf "$tmpdir"

  gate_write_settings >/dev/null 2>&1 || return 0
  after=$(gate_surface_digest)
  printf '%s\n' "$after" > "$RUN_DIR/surface-digest"
  gate_append '대상 추가' "별칭=-" "원격 슬러그=-" \
    "메인 워크트리=-" "공통 git 디렉터리=-" "베이스 브랜치=-" "층=0" \
    "발견 경로=인가 디렉터리 재유도 (${before} → ${after})" "기록 시각=$(now_iso)"
  log "인가 디렉터리를 다시 유도했습니다 — 강제 표면 기준선을 갱신하고 원장에 남겼습니다"
}

gate_chain_verify() {
  # Re-walks the chain: each row's `prev=` must equal the digest of the row
  # before it. This is what covers the ledger, since the whole-file digest
  # cannot (see above). A break is reported with the row number so the morning
  # reader has somewhere to look.
  local prev line n=0 broke=0 want
  prev=$(printf '%s' "## 실행 $RUN_ID" | shasum -a 256 | cut -d' ' -f1)
  while IFS= read -r line; do
    case "$line" in '- `'*) ;; *) continue ;; esac
    n=$((n + 1))
    want=$(printf '%s' "$line" | sed -n 's/.*| prev=\([0-9a-f]*\)$/\1/p')
    [ -n "$want" ] || continue
    if [ "$want" != "$prev" ]; then broke=$n; break; fi
    prev=$(printf '%s' "$line" | shasum -a 256 | cut -d' ' -f1)
  done < "$LEDGER"
  [ "$broke" = "0" ] && return 0
  warn "원장 해시 체인이 ${broke}번째 행에서 끊겼습니다 — 스플라이스·삭제·재배열 중 하나입니다"
  return 1
}

gate_grant_field() {
  # gate_grant_field <필드명> — the CANON rendering inside this run's block.
  #
  # sed and shell string equality, not awk. A Korean key fed to `awk`'s regex
  # engine is the exact construction this repository already had to rewrite once
  # after it failed on the macOS leg of CI and nowhere else.
  sed -n "/^## 인가 ${RUN_ID}\$/,/^## /p" "$GRANT" 2>/dev/null \
    | sed -n "s/^\\*\\*${1}\\*\\*: //p" | sed 's/[[:space:]]*$//' | sed -n '1p'
}

gate_check_grant() {
  # THE ROUTER PATH READ THE AUTHORIZATION RECORD NOWHERE, and this is where it
  # starts. `check_grant` lives on the fixed graph, which the router never
  # enters — the router only ever calls the gate's verbs — so a run could
  # execute with a grant that was absent, corrupt, or belonged to another run,
  # and nothing looked. Measured: a stage declaring cutpoint `배포` was launched
  # and ran 40 minutes while the file did not exist at the path the gate
  # derives; it appeared 9 hours 42 minutes later.
  #
  # The four fields the grant carries were being recorded and never compared,
  # which is precisely the defect class this contract exists to delete. And the
  # protection everyone relied on — "the driver has no write path to the grant,
  # so it cannot widen its own authority" — is true and worthless on its own: a
  # document nobody reads cannot be widened because it does not bind.
  local blocks b found=0 foreign="" gmax gi a tc ti gowner mowner
  if [ ! -f "$GRANT" ]; then
    warn "인가 기록이 없습니다: $GRANT — 킥오프가 먼저 돌아야 합니다"
    return "$GATE_EXIT_RULE"
  fi
  blocks=$(grep -E '^## 인가 ' "$GRANT" 2>/dev/null | sed -E 's/^## 인가 //' | sed 's/[[:space:]]*$//' || true)
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ "$b" = "$RUN_ID" ]; then found=1; else foreign="${foreign}${b} "; fi
  done <<EOF
$blocks
EOF
  if [ -n "$foreign" ]; then
    # One document folds every one of its runs onto one grant path, so run N+1
    # meets a block it did not write. Inheriting an earlier run's merge
    # permission is the failure here that is both invisible and irreversible.
    warn "외래 인가 블록이 있습니다: ${foreign}— 사람이 확인해야 합니다"
    return "$GATE_EXIT_RULE"
  fi
  if [ "$found" != "1" ]; then
    warn "이 런($RUN_ID)의 인가 블록이 인가 기록에 없습니다: $GRANT"
    return "$GATE_EXIT_RULE"
  fi

  # Ownership proof. Where the manifest names a document the grant must name the
  # same one; where it does not, the grant must carry the explicit absence
  # marker rather than omit the field — so "no document" stays distinguishable
  # from "field forgotten", which is what makes absence fail closed.
  mowner=$(manifest_hdr_field 'owner-doc')
  gowner=$(sed -n '2p' "$GRANT" | sed -n 's/.*owner-doc=\([^;]*\).*/\1/p' | sed 's/[[:space:]]*$//')
  if [ -z "$gowner" ]; then
    warn "인가 기록에 owner-doc= 이 없습니다 — fail-closed"
    return "$GATE_EXIT_RULE"
  fi
  if [ "$gowner" != "$mowner" ]; then
    warn "인가 기록의 owner-doc= 이 매니페스트와 다릅니다: '$gowner' vs '$mowner'"
    return "$GATE_EXIT_RULE"
  fi

  # The run maximum, cross-checked against the per-target values that actually
  # authorize acts. The grant's own field is a derived audit value and nothing
  # reads it to authorize anything — so without this comparison the two could
  # disagree for a whole night and the disagreement would be the one thing a
  # person could have caught by looking.
  gmax=$(gate_grant_field '권한 절단점')
  if [ -z "$gmax" ]; then
    warn "인가 기록에 「권한 절단점」이 없습니다"
    return "$GATE_EXIT_RULE"
  fi
  gi=$(cutpoint_index "$gmax")
  if [ -z "$gi" ]; then
    warn "인가 기록의 「권한 절단점」이 어휘 밖입니다: $gmax"
    return "$GATE_EXIT_VOCAB"
  fi
  for a in $(target_aliases); do
    tc=$(target_field "$a" '절단점')
    [ -n "$tc" ] || continue
    ti=$(cutpoint_index "$tc")
    [ -n "$ti" ] || continue
    if [ "$ti" -gt "$gi" ] 2>/dev/null; then
      warn "대상 ${a} 의 절단점($tc)이 인가 기록의 런 최대치($gmax)를 넘습니다"
      return "$GATE_EXIT_RULE"
    fi
  done
  return 0
}

gate_surface_check() {
  # Compared on every act, not only at run start. The four surfaces the hook
  # cannot deny a write to get after-the-fact detection only, and after-the-fact
  # is still before the NEXT act — which is the difference between one act
  # slipping through and the rest of the night doing so.
  local base now
  base=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || true)
  [ -n "$base" ] || return 0
  now=$(gate_surface_digest)
  [ "$now" = "$base" ] && return 0
  warn "강제 표면이 런 개시 이후 바뀌었습니다 (기준선 ${base}, 현재 ${now}) — 설정·룰·훅·프로젝트 설정 중 하나가 편집됐습니다"

  # THE DISPOSITION FOR THIS CODE IS THE ROUTER'S AND ONLY THE ROUTER'S: stop
  # and tell the user. A stage cannot do either half. The cause is outside it by
  # definition — the surfaces are the run's settings, the rule catalog, the hook
  # and the project settings, none of which a stage touched and none of which it
  # can inspect, because looking needs Bash and Bash is what was just refused.
  # Re-baselining would be a stage moving the boundary that binds it.
  #
  # So a stage has retry or give up, and neither is the prescribed disposition.
  # Measured on one run: five stages, four of them retried into the same refusal
  # 3, 9, 12 and 15 times and produced no finding; the fifth stopped, and what
  # separated it from the other four was its own judgment rather than anything
  # the contract said. That is what this branch converts into an instruction.
  #
  # A prose fence and not a structural one, deliberately: the stage READ the old
  # message and retried, so the failure is an interpretable misjudgment on a
  # message that described a condition without prescribing an action. What it
  # gets now is an action, plus a run-scope `blocked` row so the run's state is
  # observable to the router and to the morning instead of living in the count
  # of a stage's wasted turns.
  # THE ROW IS WRITTEN WHOEVER IS CALLING, and it used to be written only for a
  # stage. The router is the one caller whose refusal nobody else can report:
  # when it takes this exit the ledger got no row at all, so the snapshot went
  # on rendering `진행 중` with zero live stages and zero open obligations —
  # byte-identical to a healthy run waiting for its next act, while in fact
  # every further act would take the same refusal. Measured: a run died here at
  # 113 rows and $33.36 and kept rendering as in-flight.
  #
  # The resume line is the only place a person is told what to do next, so
  # dropping it exactly when the router — the one that would have carried it to
  # them — is the caller inverted its purpose.
  gate_has_row 'blocked' '사유=강제 표면 이동' \
    || gate_append 'blocked' "대상=${CC_PIPELINE_TARGET:--}" "스코프=run" "원인=무효화" \
         "사유=강제 표면 이동" "관측=$(now_iso)" \
         "재개 명령=새 런으로 다시 킥오프 — 이 런의 기준선은 다시 잡히지 않습니다"
  if [ -n "${CC_PIPELINE_SEGMENT:-}" ]; then
    warn "이 조건은 이 런에서 해소되지 않습니다 — 재시도하지 마세요. 지금 중단하고, 무엇을 하려다 막혔는지 반환문에 적고 돌아가세요. 남은 호출도 같은 거부를 받습니다."
  else
    warn "이 런은 여기서 끝났습니다 — 기준선은 다시 잡히지 않습니다. 재시도하지 말고, 무엇이 표면을 움직였는지와 함께 사용자에게 알리고 새 런으로 다시 킥오프하세요."
  fi
  return "$GATE_EXIT_SURFACE"
}

# FOUR OF THE SIX SURFACES ARE DELIBERATELY NOT IN THIS DIGEST, for two
# different reasons. Two of them move on their own, which is the same defect the
# progress vector was rebuilt to remove; the other two — the rule catalog and
# the hook — are shared installation paths whose legitimate redeployment is
# indistinguishable here from tampering, and they are covered by layer 1
# instead (see `gate_surface_digest`).
#
# The **ledger** legitimately grows on every act — written by this very function's
# caller. Comparing a digest over it at each act means the gate's own write moves
# the value it is about to check, so every act after the first is refused. Its
# integrity is the hash CHAIN's job instead, and the chain is strictly stronger
# here: it detects a splice, a deletion and a reordering, which a whole-file
# digest cannot distinguish from an ordinary append.
#
# The **transcript directory** is appended to by the harness continuously, for
# the same structural reason and with the same result. Its protection is layer
# 1's Write/Edit denial, and the honest statement is that this surface has ONE
# layer rather than two — layer 2 does not reach it at all, because a local file
# write is not an operation any credential governs.
#
# So this covers the two that neither move on their own nor are shared with the
# installation: the run's own settings directory and each target's project
# settings. A design sentence that counts six surfaces is describing what must
# be protected; this is which mechanism protects each, and for four of the six
# that mechanism is layer 1 alone.
gate_surface_digest() {
  # The extension is re-derived on every call rather than listed once: the
  # second element is "the project-scope settings of every worktree the manifest
  # and the target-addition rows name", and targets are added at RUNTIME. A
  # fixed file list would stop covering a target the moment one was added, and
  # would not report that it had stopped.
  #
  # THE INSTALLED PLUGIN'S OWN FILES ARE NOT IN HERE, and that is the whole
  # reason this digest stopped ending runs for doing nothing wrong. The rule
  # catalog and the hook are shared installation paths, not per-run copies, so
  # a digest over them cannot tell "a stage edited the boundary it stands in"
  # from "the operator deployed a new version" — and the second is ordinary
  # operation. Measured: two runs were executing stages on this machine while a
  # rule file needed fixing; deploying killed both, and not deploying kept every
  # router-driven run's merge refused.
  #
  # What covers them instead is layer 1: the hook denies Write/Edit to
  # `*/orchestrator/rules/*` and to its own directory outright, so a stage
  # cannot reach either through the edit tools at all. Dropping them here takes
  # those two surfaces from two layers to one rather than to zero — the same
  # trade this file already states in as many words for the transcript
  # directory, and stated here for the same reason: so the count is honest.
  local a wt
  {
    find "$(gate_settings_dir)" -type f 2>/dev/null | sort
    for a in $(target_aliases); do
      wt=$(target_field "$a" '메인 워크트리')
      [ -n "$wt" ] || continue
      printf '%s\n' "$wt/.claude/settings.json"
    done
  } | while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
      done | shasum -a 256 | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# Verb dispatch
# ---------------------------------------------------------------------------
gate_usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

gate_main() {
  [ $# -ge 1 ] || { gate_usage >&2; exit 2; }
  local verb="$1"; shift
  local kind="" alias="" segment="-" cutpoint="" surface="" snapdig="" rationale=""
  local approval="" render=0 worktree="" review_policy="" void=0
  GATE_RESUME=""; export GATE_RESUME
  MANIFEST=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --manifest)        MANIFEST="$2"; shift 2 ;;
      --kind)            kind="$2"; shift 2 ;;
      --target)          alias="$2"; shift 2 ;;
      --segment)         segment="$2"; shift 2 ;;
      --cutpoint)        cutpoint="$2"; shift 2 ;;
      --surface)         surface="$2"; shift 2 ;;
      --snapshot-digest) snapdig="$2"; shift 2 ;;
      --rationale)       rationale="$2"; shift 2 ;;
      --approval)        approval="$2"; shift 2 ;;
      --worktree)        worktree="$2"; shift 2 ;;
      --review-policy)   review_policy="$2"; shift 2 ;;
      --render)          render=1; shift ;;
      --void)            void=1; shift ;;
      --resume)          GATE_RESUME="$2"; shift 2 ;;
      --)                shift; break ;;
      *) printf 'gate: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  [ -n "$MANIFEST" ] || { printf 'gate: --manifest 가 필요합니다\n' >&2; exit 2; }
  check_manifest
  derive_paths_from_manifest
  gate_check_grant || exit $?
  rundir_init
  # Run start is "the settings directory does not exist yet".
  #
  # AND the settings are RE-DERIVED afterwards, whenever what they are derived
  # FROM has moved. The earlier form wrote them once and never again, on the
  # ground that a surface which changes because the gate touched it is a surface
  # whose comparison means nothing. That ground is real but the remedy was too
  # wide: it also froze the list of directories a stage may read, and kickoff
  # happens BEFORE segmentation — so a segment's own worktree is, by
  # construction, a directory the authorization list cannot contain. Measured: a
  # run produced its review and then could not remediate, because the only
  # writable tree in its list was the live plugin checkout; it ended with the
  # goal marked unreachable for want of a directory rather than for want of work.
  #
  # What keeps the comparison meaningful is not that the surface never moves —
  # it is that it moves only through THIS writer and leaves a row when it does.
  # An edit by anything else still lands as exit 7. So the derivation is a pure
  # function of the manifest and the ledger's `대상 추가` rows, both of which are
  # themselves recorded; when it yields different bytes the gate rewrites,
  # re-baselines, and appends a row naming what widened.
  #
  # The widening is bounded by construction: every directory it can add is a
  # worktree of a target the run already acts in. Nothing here grants a cutpoint,
  # and the cutpoint is what governs whatever leaves the machine.
  if [ ! -d "$(gate_settings_dir)" ]; then
    gate_write_settings
    # Run open is the one moment this belongs — the comment on `cred_check`
    # already says a run whose cutpoint reaches `머지` should learn at kickoff
    # and not at 3am, and until now nothing called it, so nothing ever did. It
    # warns and does not refuse: no host has provisioned these yet, and a stop
    # here would end every run before its first act. What it removes is the
    # silence, which is what made an unseparated run indistinguishable from a
    # separated one at every surface.
    if ! cred_check >/dev/null 2>&1; then
      warn "파이프라인 자격이 갖춰지지 않았습니다 — 이 런의 행위는 주변 자격으로 돕니다 (원장의 「자격」 필드에 매 행 남습니다)"
      cred_check >&2 || true
    fi
    # The `run` row, written once, here. It had no writer at all, so a ledger
    # opened without one carried no statement of what the run was — the report
    # path, the document and its digest, and the enforcement-surface baseline
    # all lived in memory or in a file beside the ledger rather than in it. This
    # is also the row that makes the chain's first anchor a row rather than the
    # stub's prose.
    gate_append 'run' "run-id=$RUN_ID" "시작=$(now_iso)" \
      "설계 문서=${DOC_KEY:-(없음)}" "전체 sha256=$(whole_digest 2>/dev/null || printf '(해당 없음)')" \
      "구속면 다이제스트=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || printf '(미기록)')" \
      "RUN_DIR=$RUN_DIR" "보고서=$LEDGER"
  else
    gate_resettle_settings
  fi

  case "$verb" in
    snapshot)
      if [ "$render" = "1" ]; then gate_render_snapshot; else gate_snapshot; fi
      ;;
    grade)
      [ $# -ge 1 ] || { printf 'gate: grade 는 -- 뒤에 argv 가 필요합니다\n' >&2; exit 2; }
      local g
      g=$(surface_of_argv0 "$@")
      printf '축2=%s\n' "$g"
      # `[ … ] && exit` as the arm's last command hands the FALSE test's status
      # to the caller — a successful grade then exits 1 and reads as a refusal.
      if [ "$g" = "등급 미상" ]; then exit "$GATE_EXIT_VOCAB"; fi
      ;;
    plan|act|exec)
      gate_verb_act "$verb" "$kind" "$alias" "$segment" "$cutpoint" "$surface" \
                    "$snapdig" "$rationale" "$worktree" "$review_policy" "$@"
      ;;
    close)
      [ -n "$approval" ] || { printf 'gate: close 는 --approval 이 필요합니다\n' >&2; exit 2; }
      gate_close "$approval" "$void"
      ;;
    *)
      printf 'gate: 알 수 없는 동사: %s\n' "$verb" >&2; exit 2 ;;
  esac
}

gate_field_of() {
  # gate_field_of <key> <키=값>... — the value of the LAST field with that key.
  local key="$1"; shift
  local f out=""
  for f in "$@"; do
    case "$f" in
      "$key"=*) out="${f#"$key"=}" ;;
    esac
  done
  printf '%s' "$out"
}

gate_record_row() {
  # gate_record_row <segment|cycle> <segment-id> <키=값>...
  #
  # The router's writer for the two row kinds the fixed graph used to own. This
  # is not bookkeeping polish. With no writer on this path `리뷰-후-머지` refuses
  # EVERY merge — not because a review is missing but because the row it reads
  # can never exist, so no argv, no ordering and no preparatory act satisfies it
  # — and termination condition 1 can never hold, so the run has no ending it is
  # able to propose. Both failures read as the mechanism working, which is why
  # the absence stayed invisible until a run tried to finish.
  local kind="$1" seg="$2"; shift 2
  local f k

  # `blocked` is the exception, and it has to be: the row it resolves is
  # run-scope, so demanding a segment would make the one kind that describes the
  # WHOLE run unwritable without naming a part of it.
  if [ "$kind" != "blocked" ] && { [ -z "$seg" ] || [ "$seg" = "-" ]; }; then
    warn "$kind 행에는 --segment 가 필요합니다"
    return "$GATE_EXIT_VOCAB"
  fi
  [ $# -ge 1 ] || { warn "$kind 행에 필드가 하나도 없습니다"; return "$GATE_EXIT_VOCAB"; }
  for f in "$@"; do
    case "$f" in
      *=*) : ;;
      *) warn "$kind 행의 필드는 「키=값」이어야 합니다: $f"; return "$GATE_EXIT_VOCAB" ;;
    esac
  done

  case "$kind" in
    segment)
      local st wt
      st=$(gate_field_of '상태' "$@")
      wt=$(gate_field_of '워크트리' "$@")
      # `적용 준비` is quoted because it is the one state carrying a space, and
      # an unquoted arm would split it into two patterns that match neither.
      case "$st" in
        계획됨|실행중|리뷰중|머지됨|park|'적용 준비') : ;;
        *) warn "segment 행의 「상태」가 어휘 밖입니다: ${st:-없음} — 계획됨 실행중 리뷰중 머지됨 「적용 준비」 park"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      # `리뷰-후-머지` resolves the branch's current HEAD by entering this value,
      # so a segment row without it turns a merge refusal into one that names a
      # missing worktree instead of the review — the wrong repair at 3am.
      [ -n "$wt" ] || { warn "segment 행에 「워크트리」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      gate_append 'segment' "id=$seg" "$@"
      log "세그먼트 기록 — $seg ($st)"
      ;;
    cycle)
      # The four the merge rule actually reads. A cycle row missing any of them
      # does not fail at write time under the old path either — it fails later,
      # inside the rule, as "the review record has no HEAD", which reads as a
      # broken review rather than as a row this run wrote incompletely.
      for k in '사이클' 'P0' 'P1' '리뷰 HEAD'; do
        if [ -z "$(gate_field_of "$k" "$@")" ]; then
          # `${k}` and not `$k`: the closing bracket that follows is multibyte,
          # and bash reads its first byte as part of the variable NAME — the
          # lookup then fails as an unbound variable under `set -u`, turning a
          # vocabulary refusal into a bare exit 1 with no message a reader can
          # act on. Measured here, not imagined.
          warn "cycle 행에 「${k}」가 필요합니다"
          return "$GATE_EXIT_VOCAB"
        fi
      done
      gate_append 'cycle' "세그먼트=$seg" "$@"
      log "리뷰 사이클 기록 — $seg"
      ;;
    problem)
      # The row every open obligation is derived from. With no writer,
      # `gate_open_obligations` read an empty set and termination condition 3 —
      # "obligations are empty or excused" — held vacuously on every run, while
      # the narrow excuse rule beside it could never be reached at all.
      #
      # `동일성` is the key those readers group by, and `생성 등급` is what the
      # excuse rule reads, so both are required: a row missing either produces an
      # obligation that can never be closed and never be excused.
      for k in '동일성' '현재 단' '생성 등급'; do
        if [ -z "$(gate_field_of "$k" "$@")" ]; then
          warn "problem 행에 「${k}」가 필요합니다"
          return "$GATE_EXIT_VOCAB"
        fi
      done
      gate_append 'problem' "세그먼트=$seg" "$@"
      log "문제 기록 — $seg"
      ;;
    blocked)
      # THE ROUTER MAY RESOLVE A RUN-SCOPE BLOCK, AND MAY NOT CREATE ONE. Blocks
      # are raised by the gate itself — the surface check and the watcher's
      # transcription — so a router that could write an arbitrary one would be
      # inventing the very state that governs whether the run may end. What it
      # gets is the other half, which nothing had: the disposition of a stall
      # observation is the router's job, and until now that job had no verb.
      local why cause prior
      why=$(gate_field_of '사유' "$@")
      cause=$(gate_field_of '원인' "$@")
      [ -n "$why" ] || { warn "blocked 행에 「사유」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      [ -n "$(gate_field_of '근거' "$@")" ] \
        || { warn "blocked 행에 「근거」가 필요합니다 — 무엇을 보고 해소로 판정했는지가 아침에 남는 전부입니다"; return "$GATE_EXIT_VOCAB"; }
      if [ "$cause" != "해소" ]; then
        warn "blocked 행의 「원인」은 「해소」여야 합니다 — 막힘을 만드는 것은 게이트의 몫입니다 (관측: ${cause:-없음})"
        return "$GATE_EXIT_VOCAB"
      fi
      prior=$( { gate_rows 'blocked' | grep -F '스코프=run' | grep -F "사유=$why " || true; } | tail -1)
      if [ -z "$prior" ]; then
        warn "해소할 런 스코프 blocked 행이 없습니다: ${why}"
        return "$GATE_EXIT_VOCAB"
      fi
      case "$(printf '%s' "$prior" | tr '|' '\n' | sed -n 's/^ *원인=//p' | sed 's/[[:space:]]*$//' | tail -1)" in
        무효화)
          # The enforcement-surface block. Its own resume line says this run's
          # baseline is never retaken, so clearing it here would be the run
          # re-authorizing itself past the boundary that refused it.
          warn "이 막힘은 해소할 수 없습니다 (원인=무효화): ${why} — 새 런으로 다시 킥오프하세요"
          return "$GATE_EXIT_RULE" ;;
      esac
      gate_append 'blocked' "대상=-" "스코프=run" "$@"
      log "런 스코프 막힘 해소 — $why"
      ;;
  esac
  return 0
}

gate_drain_stall() {
  # Move each line of the watcher's observation file into the ledger as a row,
  # then truncate. Chained and locked because this is the writer; the watcher's
  # own append was neither, and the chain then read as broken from that row on.
  local f="$RUN_DIR/stall" line ts why cmd
  [ -s "$f" ] || return 0
  while IFS="$(printf '\t')" read -r ts why cmd; do
    [ -n "$why" ] || continue
    gate_has_row 'blocked' "사유=$why" && continue
    gate_append 'blocked' "대상=-" "스코프=run" "원인=불명" "사유=$why" \
      "관측=$ts" "재개 명령=$cmd"
  done < "$f"
  : > "$f"
}

gate_deadline_ok() {
  # gate_deadline_ok <kind> <cutpoint>
  #
  # THE DEADLINE IS A DISPATCH GATE, and until now nothing read it. It is frozen
  # into the binding digest and compared at entry, but `gate.sh` mentioned
  # neither the field nor a comparison, and the only callers of the driver's own
  # helper sit in the fixed-graph loop the router never enters. The value a user
  # answered for at kickoff did not reach execution — the same shape #208
  # recorded for the cutpoint. Measured: a run past its deadline had `plan
  # --kind skill` answer "통과 예상".
  #
  # Checked on every acting call, not only at entry: a deadline that was in the
  # future when the run started is the normal case, so entry alone is half.
  #
  # It gates DISPATCH and MERGE and nothing else, per the contract — a stage in
  # flight runs to completion and is classified normally, and the run may still
  # record rows, close approvals and propose that it is done. A deadline that
  # stopped everything would strand the run instead of ending it.
  local kind="$1" cut="$2" dl stamp off now idx merge_idx
  dl=$(manifest_field '인가' '벽시계 마감')
  case "$dl" in ''|'없음'|'(없음)') return 0 ;; esac

  # `date -d` is GNU and `date -j -f` is BSD, so neither parses this. What both
  # do have is `date +FMT` under a TZ, so the comparison is made in the
  # deadline's OWN zone: render now there, and compare digit strings.
  stamp=$(printf '%s' "$dl" | cut -c1-19 | tr -cd '0-9')
  off=$(printf '%s' "$dl" | cut -c20-)
  case "$off" in
    Z|'')      now=$(date -u +%Y%m%d%H%M%S) ;;
    # POSIX TZ inverts the sign: UTC+9 is written `UTC-9`.
    +*:*)      now=$(TZ="UTC-${off#+}" date +%Y%m%d%H%M%S) ;;
    -*:*)      now=$(TZ="UTC+${off#-}" date +%Y%m%d%H%M%S) ;;
    *)
      # An offset this cannot read must NOT silently block every act — a
      # deadline the gate cannot compare is a reason to say so, not to refuse.
      warn "벽시계 마감의 시간대를 읽지 못했습니다 ($dl) — 마감을 강제하지 않습니다"
      return 0 ;;
  esac
  [ ${#stamp} -eq 14 ] || { warn "벽시계 마감의 형식을 읽지 못했습니다 ($dl) — 마감을 강제하지 않습니다"; return 0; }
  [ "$now" -le "$stamp" ] 2>/dev/null && return 0

  if [ "$kind" = "skill" ]; then
    warn "벽시계 마감이 지났습니다 ($dl) — 새 스테이지를 띄우지 않습니다. 도는 스테이지는 끝까지 갑니다"
    return "$GATE_EXIT_RULE"
  fi
  merge_idx=$(cutpoint_index '머지') || return 0
  idx=$(cutpoint_index "$cut") || return 0
  if [ "$idx" -ge "$merge_idx" ]; then
    warn "벽시계 마감이 지났습니다 ($dl) — 마감 뒤로 머지는 없습니다"
    return "$GATE_EXIT_RULE"
  fi
  return 0
}

gate_verb_act() {
  local verb="$1" kind="$2" alias="$3" segment="$4" cutpoint="$5" surface="$6"
  local snapdig="$7" rationale="$8" worktree="$9"
  shift 9
  local review_policy="$1"; shift
  local argv="$*"

  [ -n "$alias" ]    || { printf 'gate: --target 이 필요합니다\n' >&2; exit 2; }
  [ -n "$cutpoint" ] || { printf 'gate: --cutpoint 이 필요합니다\n' >&2; exit 2; }
  # `propose-done` is the one kind with no act behind it — it asks whether the
  # run may stop, and demanding an argv would force the router to invent a
  # command whose only purpose is to satisfy a parser.
  if [ "$kind" != "propose-done" ]; then
    [ $# -ge 1 ] || { printf 'gate: -- 뒤에 argv 가 필요합니다\n' >&2; exit 2; }
  fi

  # Vocabulary first, and by return status rather than `die` — see surface_index.
  cutpoint_index "$cutpoint" >/dev/null || exit "$GATE_EXIT_VOCAB"
  case " $(target_aliases | tr '\n' ' ') " in
    *" $alias "*) : ;;
    *) gate_undeclared_target "$alias" "$cutpoint" "$worktree" || exit $? ;;
  esac

  # The router's declared surface is a CHECKED CLAIM, not a self-grant. A
  # mismatch is exit 6 — the same idiom the slicing declaration's `슬라이스 수`
  # already uses, where a value the writer supplies is compared against one the
  # reader derives instead of being trusted.
  local graded
  case "$kind" in
    propose-done)
      graded="읽기" ;;
    segment|cycle|problem|blocked)
      # A bookkeeping act: its argv is a list of `키=값` fields, not a command,
      # and what it performs is the ledger row the gate would write anyway. It
      # reaches nothing outside the ledger, so it grades `읽기`.
      graded="읽기" ;;
    skill)
      # A stage dispatch's argv does NOT begin with a command: its first token
      # is the STAGE KIND that selects a settings variant, and the wrapper is
      # what eventually runs a binary. Feeding that token to the argv0 table
      # asked a question the table cannot answer, so every stage dispatch graded
      # `등급 미상` and fell into the pre-authorization rule's external-state
      # arm — which made dispatching any stage impossible.
      #
      # The grade is `워크트리쓰기`, and it is not a guess: the stage runs under
      # the read-scoped credential and inside a settings file that denies what
      # this run does not authorize, so what it can reach on its own is the
      # tree. Anything it does ABOVE that grade goes back through this gate as
      # its own act and is graded there.
      graded="워크트리쓰기" ;;
    *)
      graded=$(surface_of_argv0 "$@") ;;
  esac
  if [ -n "$surface" ]; then
    surface_index "$surface" >/dev/null || exit "$GATE_EXIT_VOCAB"
    if [ "$surface" != "$graded" ]; then
      warn "축2 자기선언 불일치: 선언 '$surface' vs 등급 '$graded'"
      exit "$GATE_EXIT_GRADE"
    fi
  fi
  if [ "$graded" = "등급 미상" ]; then
    # The message names WHICH repair, because two different things arrive here:
    # a tool the table has never listed (widen the table), and a recognized tool
    # in a form the sub-table could not parse (respell the command). Without the
    # distinction the router sees one refusal and has no way to tell which.
    warn "축2 등급 미상 — 등급표에 없는 argv0 는 읽기로 떨어지지 않습니다: $1 (그 도구가 표에 오른 적이 없다면 표를 넓혀야 하고, 표에 있는 도구인데 형태를 못 읽은 것이라면 하위 명령이 보이도록 다시 쓰세요)"
    [ "$verb" = "plan" ] || exit "$GATE_EXIT_VOCAB"
  fi

  # Snapshot binding. Under parallel segments a background stage can land a row
  # between the router reading the snapshot and calling here; the main session
  # also compacts, and a compacted router carrying a remembered digest is a
  # correctness failure that is otherwise invisible. Exit 4 turns both into a
  # loud re-read.
  if [ "$verb" != "plan" ]; then
    [ -n "$snapdig" ] || { printf 'gate: --snapshot-digest 가 필요합니다\n' >&2; exit 2; }
    local now
    now=$(gate_progress_digest)
    if [ "$snapdig" != "$now" ]; then
      warn "낡은 스냅숏 다이제스트: 관측 '$snapdig' vs 현재 '$now'"
      exit "$GATE_EXIT_STALE"
    fi
  fi

  # The watcher's observations, transcribed into properly chained rows. It
  # records them as a file precisely because it is not the ledger's writer; this
  # is the writer, so this is where they become rows.
  gate_drain_stall

  # THE DEADLINE IS A DISPATCH GATE. It is frozen into the binding digest and
  # compared at entry, and then nothing read it — `gate.sh` mentioned neither
  # the field nor a comparison, and the only callers of the driver's own
  # deadline helper sit in the fixed-graph loop the router never enters. So the
  # value a user answered for at kickoff did not reach execution, which is the
  # shape #208 already recorded for the cutpoint. Measured: a run past its
  # deadline had `plan --kind skill` answer "통과 예상".
  #
  # It gates DISPATCH and MERGE and nothing else, per the contract: a stage in
  # flight runs to completion and is classified normally, and the run may still
  # record, close and propose. Checking only at entry would be half — a deadline
  # that was in the future when the run started is the normal case.
  if [ "$verb" != "grade" ]; then
    gate_deadline_ok "$kind" "$cutpoint" || exit $?
  fi

  if [ "${GATE_UNDECLARED:-0}" != "1" ]; then
    gate_export_cutpoints "$alias" "$cutpoint" || exit $?
    # Where the act runs. A declared target names its own worktree and the act
    # belongs there; an undeclared one has no row to read, so the act stays in
    # the caller's directory and is bounded by the layers above instead.
    #
    # `실행 워크트리` FIRST, main worktree as the default. One field could not
    # carry both duties: the sidecar path has to converge on the main worktree
    # so that N linked worktrees of one repository do not split the state a
    # single writer owns, while the act has to run where the branch actually is.
    # For a pr or branch anchor those are never the same directory — git refuses
    # to check a branch out twice — so a stage woke on the main worktree's
    # branch every time, read files that were real and were the wrong version,
    # and nothing mechanical noticed.
    GATE_ACT_CWD=$(target_field "$alias" '실행 워크트리')
    case "$GATE_ACT_CWD" in
      ''|'(없음)') GATE_ACT_CWD=$(target_field "$alias" '메인 워크트리') ;;
    esac
    export GATE_ACT_CWD
  fi
  GATE_SURFACE="$graded"; export GATE_SURFACE

  local rules_rc=0
  gate_run_rules "$cutpoint" "$alias" "$segment" "$argv" || rules_rc=$?
  if [ "$rules_rc" = "$GATE_EXIT_APPROVAL" ] && [ "$verb" = "plan" ]; then
    # A DRY RUN NEVER WRITES. `plan` answers "would this pass, and if not which
    # rule refuses it" — issuing an approval to answer that mutates the run the
    # question was about. Worse than untidy: an open approval suspends B1..B3
    # and blocks termination condition 2, so asking the question would stall the
    # run that asked it. The exit code still carries the answer.
    warn "plan(dry-run): 이 행위는 사전 인가 밖이라 승인 대기가 필요합니다 — 발행하지 않았습니다"
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ "$rules_rc" = "$GATE_EXIT_APPROVAL" ]; then
    # A rule asking for an approval and the gate not WRITING one is the same
    # hole as recording without performing, in the other direction: the run
    # stops, nothing says why, and the termination conditions never see the
    # thing that is blocking them. The row is the approval — issuing it is not
    # bookkeeping after the fact.
    gate_issue_act_approval "$alias" "$segment" "$cutpoint" "$graded" "$argv"
    exit "$GATE_EXIT_APPROVAL"
  fi
  [ "$rules_rc" = "0" ] || exit "$rules_rc"

  if [ "$verb" = "plan" ]; then
    printf '통과 예상: kind=%s target=%s 절단점=%s 축2=%s\n' \
      "$kind" "$alias" "$cutpoint" "$graded"
    return 0
  fi

  gate_surface_check || exit $?

  # A STAGE MAY NOT BE DISPATCHED INTO A SEGMENT THAT HAS NO `segment` ROW.
  #
  # The progress vector is built from the goal digest, the target rows, the
  # `segment` rows and the open obligations — and from nothing a running stage
  # emits. So a run whose segments were never written has a vector that cannot
  # move: the stagnation boundary counts three identical digests and issues an
  # approval while a stage is working normally, and its question text says only
  # that the progress hash has not changed. Reading that line, "the router
  # stopped", "the stage is slow" and "nobody wrote the row" are the same
  # sentence. Measured: an audit stage worked 16 minutes, produced its report
  # and three independent witnesses, terminated as `정상 완료` — and the
  # boundary fired in the middle of it, with 38 `자율 승인` rows in the ledger
  # and not one of them an input to the vector.
  #
  # The kickoff already says to write these rows. That is prose, and prose is
  # what the omission got past; the same omission also silently costs the run
  # termination condition 1, which counts `segment` rows, so a run that skips
  # them cannot merge anything and cannot propose it is done — a debt taken on
  # here and presented much later wearing a different face.
  if [ "$kind" = "skill" ] && [ "$verb" = "act" ]; then
    if [ -z "$(gate_segment_field "$segment" '상태')" ]; then
      warn "세그먼트 ${segment} 의 segment 행이 없습니다 — 스테이지를 띄우기 전에 act --kind segment 로 그 행을 먼저 쓰세요"
      warn "그 행이 없으면 진전 벡터가 움직일 수 없어 정상 스테이지 위에서 정체 경계가 발화하고, 종료 조건 1 도 이 세그먼트를 세지 못합니다"
      exit "$GATE_EXIT_RULE"
    fi
  fi

  # The nine conditions are evaluated on EVERY act, not only on a done proposal.
  # A gate that can refuse a proposal but never cause one leaves the router
  # alone deciding when the night ends — so when every condition holds and the
  # router reaches for something else, it has to name what is left.
  local unmet
  unmet=$(gate_done_conditions)
  if [ "$kind" = "propose-done" ]; then
    if [ -n "$unmet" ]; then
      warn "종료 제안 기각 — 미충족 조건:"
      printf '%s\n' "$unmet" >&2
      gate_append '자율 승인' "kind=$kind" "결정=기각" "대상=$alias" "세그먼트=$segment" \
        "절단점=$cutpoint" "축2=$graded" "등급=0" "기준=종료 조건 아홉" \
        "되돌리는 법=해당 없음(거부)" "근거=$(printf '%s' "$unmet" | tr '\n' ';')"
      exit "$GATE_EXIT_RULE"
    fi
    log "종료 조건 아홉이 전부 성립합니다"
    # The run's END, recorded as a FILE in the run directory. The ledger already
    # carries the row, but a row is not a thing another process can test cheaply
    # — and two processes need to: the liveness watcher, whose loop had no exit
    # condition and therefore outlived every run it watched, and a person asking
    # "is this still going?" without knowing the row grammar.
    printf '%s 종단 — 종료 조건 아홉 성립 · 근거 %s\n' "$(now_iso)" "$rationale" > "$RUN_DIR/done"
  elif [ -z "$unmet" ]; then
    if ! gate_names_next_obligation "$rationale"; then
      warn "종료 조건이 전부 성립하는데 다음 의무를 지목하지 못했습니다 — 런은 충족으로 종료합니다"
      exit "$GATE_EXIT_RULE"
    fi
  fi

  gate_boundaries

  # Which credential the act will actually run under, recorded on every act.
  # With neither pipeline credential provisioned the gate used to fall through
  # to whatever the calling environment already held — on a developer machine a
  # full-scope `gh` login — and say nothing, so the layer the separation exists
  # to provide was absent while every surface reported normal operation. The
  # fallback stays (refusing would stop every host that has not provisioned one
  # yet), but it is no longer silent: it is one field in the morning's report.
  local credmode='분리'
  if ! cred_readonly_env >/dev/null 2>&1; then
    credmode='주변'
    # Loud only above `읽기`. A bookkeeping act reaches nothing a credential
    # could widen, and a warning on every row teaches the reader to skip the
    # line that matters.
    [ "$graded" = "읽기" ] || \
      warn "파이프라인 자격이 없어 주변 자격으로 실행합니다 — 이 행위에는 자격 분리가 걸려 있지 않습니다"
  fi

  gate_append '자율 승인' "kind=$kind" "결정=$verb" "대상=$alias" "세그먼트=$segment" \
    "절단점=$cutpoint" "축2=$graded" "자격=$credmode" "근거=$rationale"
  log "게이트 통과 — $verb $cutpoint ($alias)"

  # ---- and now PERFORM it -------------------------------------------------
  #
  # Recording without performing is what the first cut of this file did, and it
  # makes the whole layer unreachable: layer 1 denies every bash line that is
  # not this script, so if this script does not run the line, nothing runs at
  # all. The row is written BEFORE the act, deliberately — a row with no act is
  # an over-report a person can see in the morning, and an act with no row is
  # the thing this design exists to prevent.
  local rc=0
  gate_issue_review_obligation "$segment" "$cutpoint" "$graded" "$review_policy"

  [ "$kind" = "propose-done" ] && return 0
  case "$kind" in
    segment|cycle|problem|blocked) gate_record_row "$kind" "$segment" "$@"; return $? ;;
  esac
  case "$verb" in
    exec)
      # The stage's own credential set: read-scoped, so a `gh pr merge` spelled
      # here fails at the API rather than at a string match.
      gate_run_readonly "$@" || rc=$?
      ;;
    act)
      case "$kind" in
        skill) gate_launch_stage "$alias" "$segment" "$@" || rc=$? ;;
        *)     gate_run_readonly "$@" || rc=$? ;;
      esac
      ;;
  esac
  # The act's own status passes through, the way `env` and `nice` pass one
  # through. A gate REFUSAL is 2..7 and always arrives with a `gate:` line on
  # stderr and no output from the act, so the two are told apart by what came
  # with the code rather than by the code alone — which is the honest reading,
  # since an act is free to exit 3 for its own reasons and no remapping can
  # both preserve its status and reserve a band.
  #
  # A failure gets a SECOND row. The first is written before the act so that a
  # crash mid-act still leaves a record; adding the outcome to that row would
  # mean holding it until the act returned, which is the property being bought
  # by writing early.
  if [ "$rc" != "0" ]; then
    warn "행위가 실패했습니다 (rc=$rc) — 행은 이미 원장에 있습니다"
    gate_append '자율 승인' "kind=$kind" "결정=결과" "대상=$alias" "세그먼트=$segment" \
      "절단점=$cutpoint" "축2=$graded" "근거=rc=$rc"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# An undeclared repository — three layers, and the gate never grants a cutpoint.
#
# A repository the manifest does not name has no cutpoint, so a row that gave it
# one would move the seat of authorization from the manifest (which this run
# cannot write) to the ledger (which it can). That is the property the split
# writer exists to hold, and it does not rest on whether the row is forgeable:
# even an unforgeable approval would be relocating authorization.
#
# Why an approval can open a MERGE on a declared target but cannot open a PUSH
# here: the declared target already has a cutpoint and the approval opens one
# act inside it, while here there is no cutpoint to open, so the approval would
# be creating a permission SCOPE. The first is an event inside an authorization,
# the second is an extension of one.
# ---------------------------------------------------------------------------
gate_undeclared_target() {
  # gate_undeclared_target <alias> <cutpoint> <worktree>
  local alias="$1" cut="$2" wt="$3" idx branch_idx cg layer
  branch_idx=$(cutpoint_index '브랜치') || return "$GATE_EXIT_VOCAB"
  idx=$(cutpoint_index "$cut") || return "$GATE_EXIT_VOCAB"

  if [ "$idx" -gt "$branch_idx" ]; then
    # Layer 2. The honest default, and its cost is one command in the morning.
    # `인가 한도` would be the wrong cause — that one means an act exceeded a
    # cutpoint the target HAS, and the whole point here is that it has none.
    gate_append 'blocked' "대상=$alias" "스코프=act" "원인=막힘" "사유=대상 미선언" \
      "관측=$(now_iso)" "재개 명령=/cc-cmds:autopilot <목표> — 이 레포를 대상에 포함해 재킥오프"
    warn "대상 '$alias' 은 매니페스트에 선언되지 않았습니다 — '$cut' 등급은 재인가가 필요하며 게이트는 그것을 부여하지 않습니다"
    return "$GATE_EXIT_RULE"
  fi

  # Layers 0 and 1. The same preflight a manifest target gets, and it is not
  # optional: stash attribution is per-REPOSITORY rather than per-worktree, and
  # this very tree already has two working trees sharing one `.git` and one
  # `refs/stash`.
  [ -n "$wt" ] || {
    warn "미선언 대상 '$alias' 에는 --worktree 가 필요합니다 (전처리 대상이 없으면 판정할 수 없습니다)"
    return "$GATE_EXIT_VOCAB"
  }
  [ -d "$wt" ] || { warn "미선언 대상 '$alias' 의 워크트리가 없습니다: $wt"; return "$GATE_EXIT_VOCAB"; }
  cg=$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -n "$cg" ] || { warn "미선언 대상 '$alias' 의 공통 git 디렉터리를 읽지 못했습니다"; return "$GATE_EXIT_VOCAB"; }

  # Layer 0 is read-only; anything at `커밋` or above is a local write.
  layer=0
  [ "$idx" -ge "$(cutpoint_index '커밋')" ] && layer=1

  gate_has_row '대상 추가' "별칭=$alias " || \
    gate_append '대상 추가' "별칭=$alias" \
      "원격 슬러그=$(cd "$wt" && git config --get remote.origin.url 2>/dev/null | sed 's#.*[:/]\([^/]*/[^/]*\)\(\.git\)\{0,1\}$#\1#' || printf '미상')" \
      "메인 워크트리=$wt" "공통 git 디렉터리=$cg" \
      "베이스 브랜치=$(cd "$wt" && git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '미상')" \
      "층=$layer" "발견 경로=$rationale" "기록 시각=$(now_iso)"

  # The effective cutpoint is HARDCODED to `브랜치`. Not inherited from the run
  # maximum, not chosen by the router — nothing above it leaves the machine, and
  # that is the entire reason no approval is needed.
  GATE_TARGET_CUTPOINT='브랜치'
  GATE_TARGET_INDEX="$branch_idx"
  GATE_ACT_INDEX="$idx"
  export GATE_TARGET_CUTPOINT GATE_TARGET_INDEX GATE_ACT_INDEX
  GATE_UNDECLARED=1
  return 0
}

gate_issue_act_approval() {
  # gate_issue_act_approval <alias> <segment> <cutpoint> <grade> <argv>
  #
  # An ACT approval, as against the boundary variant: the binding tuple is
  # act-shaped, so staleness is re-derived against the tree it named. The id is
  # derived from the act rather than random, so the same blocked act asked twice
  # produces one pending approval instead of a queue of duplicates.
  local alias="$1" seg="$2" cut="$3" grade="$4" argv="$5" id ad base head
  ad=$(printf '%s' "$argv" | shasum -a 256 | cut -d' ' -f1)
  id="A-$(printf '%s|%s|%s' "$RUN_ID" "$alias" "$ad" | shasum -a 256 | cut -c1-8)"
  gate_has_row '승인' "승인 id=$id " && return 0
  base=$(target_field "$alias" '베이스 브랜치')
  head=$(cd "$(target_field "$alias" '메인 워크트리')" 2>/dev/null && git rev-parse HEAD 2>/dev/null || true)
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=$cut" \
    "행위 다이제스트=$ad" "구속 튜플=$alias|$base|${head:0:12}|$grade" \
    "막는 세그먼트=$seg" "질문 문면=사전 인가 밖 행위를 수행할까요" \
    "답변 문면=-" "발행 시각=$(now_iso)" "해소 시각=-"
  warn "승인 대기 발행 $id — $alias / $cut / $grade"
}

gate_names_next_obligation() {
  # gate_names_next_obligation <rationale>
  #
  # Admissible: an open obligation's identity, a segment in a non-terminal
  # state, or a termination clause marked unmet. Prose does not count — the
  # named thing has to be findable in the ledger, which is what makes the
  # refusal checkable rather than a matter of tone.
  local why="$1" o sid st
  [ -n "$why" ] || return 1
  # A `while read` inside a pipeline runs in a subshell, so it cannot return
  # from this function — the loop below is a plain `for` over a substitution for
  # exactly that reason.
  for o in $(gate_open_obligations | sed 's/^obligation=//'); do
    case "$why" in *"$o"*) return 0 ;; esac
  done
  for sid in $(gate_rows 'segment' | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    st=$(gate_segment_field "$sid" '상태')
    case " $TERMINAL_SEGMENT_STATES " in *" $st "*) continue ;; esac
    case "$why" in *"$sid"*) return 0 ;; esac
  done
  case "$why" in *미충족*) return 0 ;; esac
  return 1
}

gate_issue_review_obligation() {
  # gate_issue_review_obligation <segment> <cutpoint> <grade> <policy>
  #
  # `선머지후리뷰` does not REMOVE the review, it defers it — and a deferral with
  # no record is a removal that nobody wrote down. The row is what makes the
  # deferral survive the merge: termination condition 9 refuses to let the run
  # end while one is unfulfilled.
  #
  # `생성 등급` is the axis-2 grade of the act that created the obligation,
  # because that is the field the excusal rule reads later: an obligation made
  # by an act at or below `워크트리 쓰기` may be excused when its segment parks,
  # and one made above that may not.
  local seg="$1" cut="$2" grade="$3" policy="$4" id
  [ "$policy" = "선머지후리뷰" ] || return 0
  [ "$cut" = "머지" ] || return 0
  [ -n "$seg" ] && [ "$seg" != "-" ] || return 0
  id="RO-$(printf '%s|%s' "$RUN_ID" "$seg" | shasum -a 256 | cut -c1-8)"
  gate_has_row '리뷰 의무' "의무 id=$id " && return 0
  gate_append '리뷰 의무' "의무 id=$id" "상태=미이행" "세그먼트=$seg" \
    "머지 커밋=-" "생성 등급=$grade" "발행 시각=$(now_iso)" "이행 시각=-"
  log "리뷰 의무 발행 $id — 세그먼트 $seg (선머지후리뷰)"
}

gate_run_readonly() {
  # Runs the act under the READ-scoped credential. A `gh pr merge` spelled here
  # then fails at the GitHub API rather than at a string match, and that failure
  # is unforgeable — which is the property no string matcher can have. Acts that
  # genuinely need the write-scoped credential do not come through this door;
  # they are performed by the gate's own verbs.
  #
  # The act runs in the TARGET's worktree, and the whole body is a subshell so
  # that neither the credential exports nor the `cd` outlive the act. `--target`
  # is a parameter of both acting verbs and every target row carries an absolute
  # `메인 워크트리`, but nothing used to carry that value to the act's working
  # directory — so a manifest could declare nine targets and only the home one
  # could receive an act. The two spellings a router reached for instead were
  # both refused: calling from the target's own directory trips the manifest's
  # origin-worktree pin, and `git -C <path>` was ungradeable.
  local line dir="${GATE_ACT_CWD:-}"
  (
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      export "$line"
    done <<CREDS
$(cred_readonly_env 2>/dev/null || true)
CREDS
    if [ -n "$dir" ]; then
      cd "$dir" || { printf 'gate: 대상 워크트리로 이동하지 못했습니다: %s\n' "$dir" >&2; exit 1; }
    fi
    "$@"
  )
}

gate_launch_stage() {
  # gate_launch_stage <alias> <segment> <stage-kind> <cli args...>
  #
  # The wrapper's only legitimate caller, stated in one place. It is an argv
  # laundering tool for whoever holds an allow-list entry, so the set of callers
  # is a design commitment rather than an accident — and this is it.
  local alias="$1" seg="$2" kind="$3"; shift 3
  local wrapper="$GATE_DIR/stage-wrapper.sh"
  [ -f "$wrapper" ] || { warn "스테이지 래퍼가 없습니다: $wrapper"; return 127; }

  # RE-ATTACH, NOT RE-RUN. The contract already says a stage cut mid-flight is
  # continued rather than restarted, and the wrapper already accepts `--resume`
  # — nothing carried the router's intent to it, so the only recovery available
  # was a full re-run. Measured: a review stage died to a machine sleep after
  # 1h53m and 51.84 USD with all five reviewers' output on disk and only the
  # synthesis missing; re-running would have paid for the whole thing again.
  #
  # The session id is CHECKED against this run's own ledger, not taken on trust.
  # A resume is an instruction to continue somebody's transcript, so an
  # unchecked value would let one segment continue another segment's — or
  # another run's — session. It must appear as the `세션 id` of a `stage-result`
  # row for THIS segment.
  #
  # Validated HERE, before the CLI binary is resolved. Resolving first makes
  # "the binary is missing" mask "the argv is wrong", which is the same defect
  # the wrapper already had and had fixed: a host without the CLI answered 127
  # to a bad resume id and the refusal never named the real fault.
  if [ -n "${GATE_RESUME:-}" ]; then
    local known
    known=$( { gate_rows 'stage-result' | grep -F "세그먼트=$seg " || true; } \
             | { grep -cF "세션 id=$GATE_RESUME " || true; } )
    if [ "${known:-0}" = "0" ]; then
      warn "재개 대상 세션이 이 세그먼트의 원장 기록에 없습니다: $GATE_RESUME"
      return "$GATE_EXIT_VOCAB"
    fi
  fi

  # `bash`, not `/bin/sh`. The wrapper declares `#!/usr/bin/env bash` and uses
  # `set -o pipefail`, and naming an interpreter on the command line OVERRIDES
  # the shebang — so on a distribution whose `/bin/sh` is dash the wrapper died
  # at its second line with "Illegal option -o pipefail", taking every stage
  # launch with it. macOS hid this because its `/bin/sh` is bash.
  #
  # `CC_CLAUDE_BIN` is HANDED DOWN rather than re-resolved. run.sh resolves the
  # binary and only then pins PATH to the sanitized set, so a child that looks
  # it up again searches a PATH the CLI is not on — and the wrapper's hard stop
  # then reports "binary not found" for a run whose binary was found two
  # seconds earlier. Every stage launch failed that way, with the gate's own
  # sanitization as the cause.
  [ -n "${CLI_BIN:-}" ] || { warn "게이트가 CLI 바이너리를 해소하지 못했습니다"; return 127; }

  # The plugin root the wrapper injects, so the stage's slash commands resolve.
  # This assignment was deleted by an edit that moved the block above it and
  # took a line with it; `--plugin-dir "$plugin_dir"` stayed, so under `set -u`
  # every stage dispatch died on an unbound variable. Nothing caught it because
  # no test ran this function past its argument checks — the fixture has no CLI,
  # so the launch path was never entered. The stub below now enters it.
  local plugin_dir
  plugin_dir=$(cd "$(dirname "$GATE_DIR")" && pwd)

  # The pid file is what makes a running stage VISIBLE to the liveness watcher.
  # Without it the watcher counts zero live stages, and its stall arm — "ledger
  # idle AND nothing alive AND nothing waiting" — becomes true during any long
  # stage, because a stage writes no ledger rows WHILE it runs. So the detector
  # built to catch a router that stopped would instead cry wolf on a healthy
  # run, which is worse than not having it: a false alarm teaches its reader to
  # ignore the true one.
  #
  # The start-time fingerprint goes beside it. `RUN_DIR` survives a reboot by
  # design, so a bare pid can name an unrelated live process afterwards.
  # THE STAGE IS HANDED WHAT THE HOOK WILL DEMAND OF IT.
  #
  # Layer 1 routes every Bash line, Write and Edit through the gate, and the
  # gate's argv needs a manifest path, a target, a cutpoint and a snapshot
  # digest. A stage that has none of them cannot comply and cannot even write a
  # halt record — the halt path derives its own location from the run id, and
  # reading the run id needs Bash, which the hook has just refused. Measured:
  # an implementation stage was blocked fourteen times, edited nothing, left the
  # tree byte-identical, and exited 0 with `subtype: success`.
  #
  # The values were never missing. The hook command string written two functions
  # above carries the run directory, the ledger and the grant as literal paths —
  # they were in hand at install time and simply not given to the stage.
  #
  # The digest is deliberately NOT among them: it moves on every ledger write,
  # so a value frozen into the environment would be stale by the stage's first
  # act. The stage reads it with `gate.sh snapshot`, which the hook's allow-list
  # already permits — that is what makes handing down the manifest path enough.
  #
  # THE BACKGROUND WAIT CEILING, because a fan-out stage does not fit under the
  # default one. Measured: a dispatched audit stage was killed at exactly 600s
  # with "Background tasks still running after 600s; terminating", reported
  # `subtype: success` and exit 0, and published nothing — its three readers were
  # alive and each had an open zero-byte temp file, so they were killed in the
  # moment before their atomic publish. The same document with the ceiling raised
  # completed, with readers publishing at 22 and 26 minutes.
  #
  # Raised to an hour rather than removed. `0` waits forever, and forever is the
  # one value that costs the run its only signal: the watcher counts a live pid
  # as a healthy stage, so a hung stage reads as a heartbeat and the run sits
  # until the person comes back. A finite ceiling still kills, and a kill is
  # classified. The environment can raise it for a host that needs more.
  #
  # THE ATTEMPT NUMBER, derived rather than passed. The session id is a function
  # of run, segment and attempt, and the caller was leaving the attempt at its
  # default — so the id was a function of run and segment alone. A stage that
  # died before producing anything had already taken that id, and every retry of
  # the same segment was refused by the CLI with "Session ID ... is already in
  # use". Dying is not an exotic path: the contract itself lists the terminal
  # closing, Ctrl+C, the token limit, the network dropping and a reboot, and all
  # five are written as "retry".
  #
  # The failure was worse than a refusal because it happened AFTER the gate
  # passed and after the row was appended — so the ledger showed the segment
  # attempted twice with nothing to show for either, and the cause lived in one
  # line of the CLI's stdout.
  #
  # Derived from the ledger and NOT taken as argv: the gate has already appended
  # this dispatch's own `자율 승인` row by the time it gets here, so counting the
  # skill dispatches for this segment IS the attempt number. Adding an
  # `--attempt` flag instead would let a router re-type the number it used last
  # time, which reproduces the collision through the one surface that is
  # supposed to prevent it.
  local attempt
  attempt=$( { gate_rows '자율 승인' | grep -F 'kind=skill ' || true; } \
             | { grep -cF "세그먼트=$seg " || true; } )
  [ "${attempt:-0}" -ge 1 ] || attempt=1

  # The stage's stream goes to a FILE rather than through a `tee`. A tee would
  # make `$!` the tee's pid, and the pid is what the watcher uses to tell a
  # working stage from a stopped router — so the visible stream would be bought
  # with the liveness record. The outcome is read back below and reported.
  local id_flag
  if [ -n "${GATE_RESUME:-}" ]; then
    id_flag="--resume $GATE_RESUME"
    log "스테이지 재부착 — $seg ← 세션 $GATE_RESUME"
  else
    id_flag="--session-id $(session_uuid "$seg" "$attempt")"
  fi

  mkdir -p "$RUN_DIR/log"

  local n_rows_before
  n_rows_before=$(gate_rows '자율 승인' | gate_count)

  local rc=0
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CC_ORCH_BG_WAIT_CEILING_MS:-3600000}" \
  CC_CLAUDE_BIN="$CLI_BIN" \
  CC_PIPELINE_RUN_ID="$RUN_ID" \
  CC_PIPELINE_RUN_DIR="$RUN_DIR" \
  CC_PIPELINE_MANIFEST="$MANIFEST" \
  CC_PIPELINE_LEDGER="$LEDGER" \
  CC_PIPELINE_GRANT="$GRANT" \
  CC_PIPELINE_GATE="$GATE_DIR/gate.sh" \
  CC_PIPELINE_TARGET="$alias" \
  CC_PIPELINE_SEGMENT="$seg" \
  CC_PIPELINE_STAGE_ID="$seg" \
  bash "$wrapper" \
    --settings "$(gate_settings_file "$kind")" \
    --plugin-dir "$plugin_dir" \
    $id_flag \
    -- "$@" > "$RUN_DIR/log/$seg.json" 2> "$RUN_DIR/log/$seg.err" < /dev/null &
  local spid=$!
  printf '%s\n' "$spid" > "$RUN_DIR/$seg.pid"
  # `LC_TIME=C` on the WRITE side too. The watcher pins it on the read side, and
  # a fingerprint is only a fingerprint if both sides format it the same way —
  # under a Korean LC_TIME this line yields `2026년 8월 28일 …`, the comparison
  # never matches, and the watcher silently skips every stage while reporting
  # "0 live". That failure is invisible: it does not error, it under-counts.
  LC_TIME=C ps -o lstart= -p "$spid" 2>/dev/null \
    | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//' > "$RUN_DIR/$seg.start"
  wait "$spid" || rc=$?
  # Removed on exit, so "no record implies no process" stays true — a stale
  # record and a stale process must die together or pid reuse makes the watcher
  # report a stage that is not there.
  rm -f "$RUN_DIR/$seg.pid" "$RUN_DIR/$seg.start"
  gate_record_stage_outcome "$alias" "$seg" "$kind" "$attempt" "$rc" "$n_rows_before"
  return "$rc"
}

gate_record_stage_outcome() {
  # gate_record_stage_outcome <alias> <segment> <kind> <attempt> <rc> <rows-before>
  #
  # Two of the five row kinds that had no writer at all. Their absence was not
  # bookkeeping: `cost` is the only input `gate_b4_cost` has, so the cost
  # boundary read an empty set, took its fail-open guard, and could never fire
  # however low the declared ceiling was — the guard treats a missing value as
  # temporary and with no writer the absence is permanent. `stage-result` is
  # what the morning report counts terminal classes from, and what the
  # implementation-review separation rule reads ancestry from; with no rows that
  # rule returns early and passes vacuously on every run it exists to catch.
  local alias="$1" seg="$2" kind="$3" attempt="$4" rc="$5" before="$6"
  local out="$RUN_DIR/log/$seg.json" res cost subtype sid klass after denials prev total n_stage psha iserr

  res=$( { grep '"type":"result"' "$out" 2>/dev/null || true; } | tail -1)
  # A launch that never STARTED is reported as such. With no result line the
  # classification falls to `크래시`, which is the right bucket — the dispatch
  # did fail — but it reads as "the stage ran and died", and a reader then looks
  # for the stage's own fault. Measured: an unbound variable in the launch path
  # left `종단 부류=크래시 rc=1` in the ledger with no pid file and no process
  # ever created, and the diagnosis went to the stage first.
  [ -n "$res" ] || warn "스테이지 프로세스가 시작되지 않았습니다 ($seg) — 종단 result 줄이 없습니다. 스테이지가 아니라 기동 경로를 보세요"
  cost=$(printf '%s' "$res"    | jq -r '.total_cost_usd // empty' 2>/dev/null || true)
  subtype=$(printf '%s' "$res" | jq -r '.subtype // empty'        2>/dev/null || true)
  sid=$(printf '%s' "$res"     | jq -r '.session_id // empty'     2>/dev/null || true)

  # The terminal class, from what the GATE can observe and nothing more. A stage
  # that performed a gated act left rows; one that left none either never got
  # started or arrived somewhere it would not pass. `permission_denials` is the
  # trace that separates those two — the contract asks for exactly that
  # discriminator, "a trace of reaching a decision point", and a denial is one.
  #
  # `의도된 park` and `적용 불명` are NOT among the values written here, and the
  # omission is deliberate: both are claims about the stage's own intent and are
  # read from its halt record, which the halt contract owns. Guessing them from
  # outside would put a value in the ledger that nothing verified.
  after=$(gate_rows '자율 승인' | gate_count)
  # `is_error` is read as well as the status and the subtype. Measured: a stage
  # that slept mid-response returned `subtype: success` WITH `is_error: true`,
  # and only the non-zero status caught it — the same object with a zero status
  # would have been classified as a normal completion.
  iserr=$(printf '%s' "$res" | jq -r '.is_error // false' 2>/dev/null || true)
  if [ "$rc" != "0" ] || [ "${subtype:-}" != "success" ] || [ "${iserr:-false}" = "true" ]; then
    klass='크래시'
  elif [ "${after:-0}" -gt "${before:-0}" ]; then
    klass='정상 완료'
  else
    denials=$( { grep -c 'permission_denials' "$out" 2>/dev/null || true; } | tail -1)
    if [ "${denials:-0}" != "0" ]; then klass='산출물 없는 정지'; else klass='공허한 성공'; fi
  fi

  # `plan_sha256`, and only for the implement arm. That arm is split into two
  # processes and process B enters ONLY when this field is on the row — its
  # admission predicate says so and forbids re-deriving a plan instead. Nothing
  # wrote the field, so every dispatch resolved as process A, emitted the plan
  # again and stopped. The tree stayed clean, which is correct for process A, so
  # "A finished" and "B will never come" were indistinguishable from outside.
  #
  # Taken from the stage's own emitted object first, because that is the digest
  # the admission predicate compares against; the plan FILE is the fallback, and
  # it is a fact the gate can compute rather than one the stage reports.
  psha=""
  if [ "$kind" = "implement" ]; then
    psha=$(printf '%s' "$res" | jq -r '(.result // empty) | fromjson? | .plan_sha256 // empty' 2>/dev/null || true)
    [ -n "$psha" ] || psha=$(printf '%s' "$res" | jq -r '.plan_sha256 // empty' 2>/dev/null || true)
    if [ -z "$psha" ] && [ -f "$RUN_DIR/implement-$seg.plan.md" ]; then
      psha=$(shasum -a 256 "$RUN_DIR/implement-$seg.plan.md" | cut -d' ' -f1)
    fi
  fi
  if [ -n "$psha" ]; then
    gate_append 'stage-result' "세그먼트=$seg" "스테이지=$seg" "종류=$kind" \
      "종료 코드=$rc" "실행 버전=$attempt" "세션 id=${sid:-미상}" \
      "부모=${CLAUDE_CODE_SESSION_ID:-미상}" "plan_sha256=$psha" "종단 부류=$klass"
  else
    gate_append 'stage-result' "세그먼트=$seg" "스테이지=$seg" "종류=$kind" \
      "종료 코드=$rc" "실행 버전=$attempt" "세션 id=${sid:-미상}" \
      "부모=${CLAUDE_CODE_SESSION_ID:-미상}" "종단 부류=$klass"
  fi

  # The cost row ACCUMULATES, because that is the shape its only reader wants:
  # the boundary compares one number against the declared ceiling rather than
  # summing the file on every act.
  if [ -n "$cost" ]; then
    prev=$(gate_rows 'cost' | tail -1 | tr '|' '\n' \
           | sed -n 's/^ *누적 usd=//p' | sed 's/[[:space:]]*$//' | tail -1)
    total=$(awk -v a="${prev:-0}" -v b="$cost" 'BEGIN{ printf "%.4f", a + b }')
    n_stage=$(gate_rows 'stage-result' | gate_count)
    gate_append 'cost' "누적 usd=$total" "스테이지 수=${n_stage:-1}" "관측 시각=$(now_iso)"
  fi

  log "스테이지 종단 — $seg ($kind) $klass rc=$rc${cost:+ · ${cost} USD}"
}

gate_session_lineage() {
  # Every session id this run has had. A `--resume` gives the run a NEW id and
  # leaves the earlier transcript behind, so an approval issued before the break
  # is answered in one file and looked for in another. The lineage is recorded
  # on every entry and searched as a set.
  local f="$RUN_DIR/session-lineage"
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && {
    grep -qxF "$CLAUDE_CODE_SESSION_ID" "$f" 2>/dev/null || \
      printf '%s\n' "$CLAUDE_CODE_SESSION_ID" >> "$f"
  }
  cat "$f" 2>/dev/null || true
}

gate_transcript_files() {
  # Files, plural, and searched by NAME rather than pinned by path+offset: the
  # `--resume` sibling-file case is exactly what a pinned path gets wrong. The
  # transcript directory is keyed by cwd and therefore shared with unrelated
  # sessions, so the search is confined to this run's own lineage.
  local dir sid
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [ -d "$dir" ] || return 1
  for sid in $(gate_session_lineage); do
    [ -n "$sid" ] || continue
    find "$dir" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null
  done
}

gate_close() {
  # Resolving an approval reads the HARNESS-WRITTEN transcript rather than the
  # router's prose, so the entity that asks is not the entity that records. The
  # separation is the whole value: a router that could type its own answer would
  # be issuing approvals to itself, and the record would be indistinguishable
  # from one a person gave.
  #
  # That channel is meaningful only while the hook denies Write and Edit to the
  # transcript directory — which is the run settings' job, not this script's.
  # This verb's contract is the narrow one it can actually keep: it never
  # accepts an answer that did not come out of that file.
  #
  # Two outcomes, and both need the same transcript line. `--void` records
  # `무효` — the question should not have been asked — instead of `승인`. Before
  # it there was exactly one recording path, so a pending approval had two
  # possible ends: granted, or pending forever. Pending is not inert; it counts
  # against termination condition 2 and suspends the stagnation boundaries, so
  # one approval nobody wants to grant stalls the rest of the run.
  #
  # Voiding is NOT the conservative direction — it REMOVES a blocker — so it
  # keeps the transcript binding rather than becoming a router-writable escape.
  # What it buys a person is the ability to answer "this should not have been
  # asked" without also granting the act.
  local id="$1" void="${2:-0}" row state q tx ans f
  # `|| true` on every match: a `grep` that finds nothing exits 1, `pipefail`
  # promotes it, and `set -e` then kills the verb with status 1 and NO message —
  # which reads exactly like a refusal and is not one.
  row=$( { gate_rows '승인' | grep -F "승인 id=$id " || true; } | tail -1)
  [ -n "$row" ] || die "그런 승인 id 가 원장에 없습니다: $id"
  state=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
  [ "$state" = "대기" ] || die "승인 '$id' 은 이미 '$state' 입니다 — 해소된 승인은 다시 닫지 않습니다"

  q=$(printf '%s' "$row" | tr '|' '\n' | sed -n 's/^ *질문 문면=//p' | sed 's/[[:space:]]*$//' | tail -1)

  tx=$(gate_transcript_files || true)
  if [ -z "$tx" ]; then
    warn "트랜스크립트를 찾지 못해 승인을 닫을 수 없습니다 — 라우터가 타이핑한 답은 받지 않습니다"
    exit "$GATE_EXIT_APPROVAL"
  fi

  # BOTH the approval id and the question text must appear on the same line.
  # Binding only the id lets the router point `close` at a different question
  # that WAS genuinely answered, and it then obtains an approval without
  # forging anything at all.
  ans=""
  for f in $tx; do
    [ -f "$f" ] || continue
    ans=$( { grep -F "$id" "$f" 2>/dev/null || true; } | { grep -F "$q" || true; } | tail -1)
    [ -n "$ans" ] && break
  done

  if [ -z "$ans" ]; then
    # A TORN LINE is not an absence, and under this design the two mean opposite
    # things. The gate reads the transcript while the harness is still appending
    # to it, so the ledger's "discard only the last line" rule does not carry
    # over — that rule assumes the gate is the writer, and here the harness is.
    # An incomplete final line that might hold the very id being looked for
    # makes "not found" ambiguous between "not answered yet" and "half
    # written", so the verdict is HELD rather than decided.
    for f in $tx; do
      [ -f "$f" ] || continue
      if [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then
        warn "트랜스크립트의 마지막 줄이 완결되지 않았습니다 — 판정 보류, 다음 판정에서 다시 봅니다"
        exit "$GATE_EXIT_APPROVAL"
      fi
    done
    warn "트랜스크립트에 이 승인의 질문에 대한 응답이 없습니다 — 대기 상태를 유지합니다"
    exit "$GATE_EXIT_APPROVAL"
  fi

  if [ "$void" = "1" ]; then
    gate_append '승인' "승인 id=$id" "상태=무효" "질문 문면=$q" \
      "답변 문면=트랜스크립트 판독(무효)" "해소 시각=$(now_iso)"
    log "승인 무효 — $id (행위는 수행되지 않습니다)"
    return 0
  fi
  gate_append '승인' "승인 id=$id" "상태=승인" "질문 문면=$q" \
    "답변 문면=트랜스크립트 판독" "해소 시각=$(now_iso)"
  log "승인 해소 — $id"
  return 0
}

# ---------------------------------------------------------------------------
# Termination — nine conditions on the gate side, and a router-side proposal
# that must carry evidence rather than prose.
#
# The disagreement runs BOTH ways and the draft had only one direction. A gate
# that can refuse a proposal but never cause one leaves the router alone
# deciding when the night ends, which is not a conjunction at all. So a router
# that declines to propose while every condition holds must name a specific,
# admissible next obligation — and failing to name one ends the run.
# ---------------------------------------------------------------------------
readonly TERMINAL_SEGMENT_STATES="머지됨 park"

gate_done_conditions() {
  # Prints one line per UNMET condition, numbered. Empty output means all nine
  # hold. Never silently empty on an unreadable ledger — that is condition 4.
  local sid st n

  # 1 — every segment in a terminal state.
  #
  # And at least one segment must exist. Over the empty set "every segment is
  # terminal" is vacuously TRUE, so a run that has not started yet satisfies all
  # nine — which made the very first act of every run trip the rule below that
  # demands a next obligation when everything is already done. A run with no
  # segments has not finished; it has not begun.
  local n_seg
  n_seg=$(gate_rows 'segment' | gate_count)
  [ "$n_seg" = "0" ] && printf '1 세그먼트가 하나도 없습니다 — 런이 아직 아무것도 만들지 않았습니다\n'
  for sid in $(gate_rows 'segment' | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$sid" ] || continue
    st=$(gate_segment_field "$sid" '상태')
    case " $TERMINAL_SEGMENT_STATES " in
      *" $st "*) ;;
      *) printf '1 세그먼트 %s 의 상태가 종단이 아닙니다 (%s)\n' "$sid" "${st:-미상}" ;;
    esac
  done

  # 2 — no approval still waiting
  n=$(gate_pending_approval_ids | gate_count)
  [ "$n" = "0" ] || printf '2 대기 중인 승인이 %s건 있습니다\n' "$n"

  # 3 — obligations empty, or excused. The excuse is NARROW: the obligation
  # belongs to a parked segment AND the act that created it graded at or below
  # `워크트리쓰기`. An obligation made by a higher-graded act is never excused,
  # because that is precisely the obligation whose effects left the machine.
  gate_open_obligations | while IFS= read -r o; do
    [ -n "$o" ] || continue
    gate_obligation_excused "${o#obligation=}" || printf '3 미해결 의무가 남아 있습니다: %s\n' "${o#obligation=}"
  done

  # 4 — ledger damage
  n=$(gate_ledger_damage)
  [ "$n" = "0" ] || printf '4 원장 손상 행이 %s건입니다\n' "$n"

  # 5 — run-scope blocks resolved or enumerated
  #
  # LAST ROW PER `사유` WINS, the way conditions 2 and 9 already read approvals
  # and review obligations. Counting raw rows made this a one-way latch: a
  # ledger row is never deleted, so a single run-scope block — including one the
  # watcher raised on a false positive — took the run's ability to propose done
  # away permanently. The comment above promised "resolved or enumerated" and
  # the code implemented neither.
  #
  # Measured: an audit stage completed normally, the watcher observed a stall
  # that had not happened, the gate transcribed it, and the run then satisfied
  # the other eight conditions and was refused on this one with no verb in
  # existence that could clear it.
  #
  # `원인=무효화` is deliberately NOT resolvable. That is the enforcement-surface
  # block, whose own resume line says this run's baseline is never retaken — a
  # run that could clear it would be re-authorizing itself past the boundary
  # that had just refused it.
  local reason last cause
  gate_rows 'blocked' | grep -F '스코프=run' | tr '|' '\n' \
    | sed -n 's/^ *사유=//p' | sed 's/[[:space:]]*$//' | sort -u \
    | while IFS= read -r reason; do
        [ -n "$reason" ] || continue
        last=$( { gate_rows 'blocked' | grep -F '스코프=run' | grep -F "사유=$reason " || true; } | tail -1)
        cause=$(printf '%s' "$last" | tr '|' '\n' | sed -n 's/^ *원인=//p' | sed 's/[[:space:]]*$//' | tail -1)
        [ "$cause" = "해소" ] && continue
        if [ "$cause" = "무효화" ]; then
          printf '5 런 스코프 blocked 가 해소 불가입니다 (%s) — 이 런은 끝났습니다\n' "$reason"
        else
          printf '5 런 스코프 blocked 가 미해소입니다 (%s) — 해소했다면 act --kind blocked 로 원인=해소 행을 쓰세요\n' "$reason"
        fi
      done

  # 6 — terminal-act cap
  gate_terminal_cap_ok || printf '6 말단 행위 상한을 넘었습니다\n'

  # 7 — no live stage process
  n=$(gate_live_stages)
  [ "$n" = "0" ] || printf '7 살아 있는 스테이지가 %s개입니다\n' "$n"

  # 8 — report file exists
  [ -f "$BASE/docs/pipeline-run/$RUN_ID.md" ] || printf '8 리포트 파일이 없습니다\n'

  # 9 — no unfulfilled review obligation. Condition 3 does not subsume this:
  # 3 narrows when an EXISTING obligation is excused, and 9 holds the ones
  # `선머지후리뷰` deliberately deferred. This design's own four slices all
  # declare that mode, so the first run of it against itself takes this path.
  n=$(gate_unfulfilled_review_obligations | gate_count)
  [ "$n" = "0" ] || printf '9 미이행 리뷰 의무가 %s건입니다\n' "$n"
}

gate_pending_approval_ids() {
  local id st
  for id in $(gate_rows '승인' | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { gate_rows '승인' | grep -F "승인 id=$id " || true; } | tail -1 \
         | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "대기" ] && printf '%s\n' "$id"
  done
  return 0
}

gate_unfulfilled_review_obligations() {
  local id st
  for id in $(gate_rows '리뷰 의무' | tr '|' '\n' | sed -n 's/^ *의무 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    st=$( { gate_rows '리뷰 의무' | grep -F "의무 id=$id " || true; } | tail -1 \
         | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1)
    [ "$st" = "미이행" ] && printf '%s\n' "$id"
  done
  return 0
}

gate_obligation_excused() {
  # gate_obligation_excused <identity>
  local ident="$1" seg st grade
  seg=$( { gate_rows 'problem' | grep -F "동일성=$ident " || true; } | tail -1 \
        | tr '|' '\n' | sed -n 's/^ *세그먼트=//p' | sed 's/[[:space:]]*$//' | tail -1)
  [ -n "$seg" ] || return 1
  st=$(gate_segment_field "$seg" '상태')
  [ "$st" = "park" ] || return 1
  grade=$( { gate_rows 'problem' | grep -F "동일성=$ident " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *생성 등급=//p' | sed 's/[[:space:]]*$//' | tail -1)
  case "$grade" in
    읽기|워크트리쓰기) return 0 ;;
    *) return 1 ;;
  esac
}

gate_terminal_cap_ok() {
  local a cap n
  for a in $(target_aliases); do
    cap=$(target_field "$a" '말단 행위 상한')
    case "$cap" in ''|없음) continue ;; esac
    n=$(gate_rows '자율 승인' | grep -F "대상=$a " | grep -c '절단점=머지' || true)
    [ "$n" -le "$cap" ] || return 1
  done
  return 0
}

gate_live_stages() {
  # `kill -0` on recorded pids, never `wait -n` — that builtin does not exist on
  # the interpreter floor, and a re-attached stage is not this shell's child so
  # `wait` would report a clean exit for a process it never reaped.
  local f pid n=0
  for f in "$RUN_DIR"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# The four boundaries.
#
# All four convert to a PENDING APPROVAL rather than a park: the run has not
# failed, it has stopped moving, and a night should not be spent on a condition
# one sentence from the user would clear.
#
# B1..B3 are SUSPENDED while an approval is open. A run in that state is not
# stalled, it is waiting — and without the suspension B1's own remedy would
# reset the counter that fired it, which is the same defect the progress vector
# was rebuilt to remove, reappearing one layer up.
# ---------------------------------------------------------------------------
readonly B1_STAGNATION_N=3
readonly B2_OBLIGATION_M=3
readonly B3_ACT_BUDGET=40

gate_boundaries() {
  local pending
  pending=$(gate_pending_approval_ids | gate_count)

  if [ "$pending" = "0" ]; then
    gate_b1_stagnation
    gate_b2_obligations
    gate_b3_act_budget
  fi
  # B4 stays live even while waiting: cost can still climb.
  gate_b4_cost
}

gate_b1_stagnation() {
  local h prev n
  h=$(gate_progress_digest)
  prev=$(cat "$RUN_DIR/progress-digest" 2>/dev/null || true)
  n=$(cat "$RUN_DIR/progress-repeat" 2>/dev/null || printf '0')
  if [ "$h" = "$prev" ]; then
    n=$((n + 1))
  else
    n=0
  fi
  printf '%s
' "$h" > "$RUN_DIR/progress-digest"
  printf '%s
' "$n" > "$RUN_DIR/progress-repeat"
  # The counter lives in the run directory and NOT in the hashed vector. Putting
  # it inside its own input is the original defect: raising it 0→1 changed the
  # hash and reset the very count being raised.
  [ "$n" -lt "$B1_STAGNATION_N" ] && return 0
  gate_issue_boundary_approval B1 "진전 해시가 연속 ${n}회 판정 동안 불변입니다"
}

gate_b2_obligations() {
  # B2 catches the repeat defect B1 cannot. Fixing the same fault a different
  # way each time moves `head_sha`, so B1 never fires — but the obligation
  # multiset's elements are defined by IDENTITY, so however the patch differs
  # the element stays put. Progress means `|O|` genuinely fell, or an element
  # left and no element of the same identity came back.
  local cur prev n
  cur=$(gate_open_obligations | sort | shasum -a 256 | cut -d' ' -f1)
  prev=$(cat "$RUN_DIR/obligation-digest" 2>/dev/null || true)
  n=$(cat "$RUN_DIR/obligation-repeat" 2>/dev/null || printf '0')
  if [ "$cur" = "$prev" ]; then n=$((n + 1)); else n=0; fi
  printf '%s\n' "$cur" > "$RUN_DIR/obligation-digest"
  printf '%s\n' "$n"   > "$RUN_DIR/obligation-repeat"
  [ "$n" -lt "$B2_OBLIGATION_M" ] && return 0
  [ "$(gate_open_obligations | gate_count)" = "0" ] && return 0
  gate_issue_boundary_approval B2 "의무 집합이 연속 ${n}개 사이클 동안 진전 없이 그대로입니다"
}

gate_b3_act_budget() {
  # Counts only `exec` acts graded above `읽기` since the last progress move.
  # Without that qualifier B3 fires on GRAMMAR: the argv-vector rule turns one
  # pipeline step into three gate calls, and the dry-run verbs exist so the
  # router never has to spend the budget finding out whether something passes.
  # `grep` with no match exits 1, `pipefail` promotes it, and `set -e` then
  # kills the whole gate on the ordinary case of "no exec acts yet" — silently,
  # with the exit status of a refusal and none of the message.
  local n
  n=$( { gate_rows '자율 승인' | grep '결정=exec' || true; } | { grep -v '축2=읽기' || true; } | gate_count)
  [ "$n" -lt "$B3_ACT_BUDGET" ] && return 0
  gate_issue_boundary_approval B3 "마지막 진전 이후 읽기 초과 exec 가 ${n}회입니다"
}

gate_b4_cost() {
  local declared spent pct
  declared=$(manifest_field '인가' '비용 천장')
  case "$declared" in ''|없음) return 0 ;; esac
  spent=$(gate_rows 'cost' | tail -1 | tr '|' '
' | sed -n 's/^ *누적 usd=//p' | sed 's/[[:space:]]*$//' | tail -1)
  [ -n "$spent" ] || return 0
  pct=$(awk -v s="$spent" -v d="$declared" 'BEGIN{ if (d+0==0) print 0; else printf "%d", (s/d)*100 }')
  [ "$pct" -lt 80 ] && return 0
  gate_issue_boundary_approval B4 "비용이 선언 천장의 ${pct}%% 입니다 (${spent}/${declared})"
}

gate_issue_boundary_approval() {
  # gate_issue_boundary_approval <name> <question>
  #
  # A boundary approval has NO act, so it can fill neither an act digest nor an
  # argv digest. The cutpoint slot carries the literal `경계` and the binding
  # tuple is (boundary name, H at firing, related segment set) — which is why
  # the three approval shapes share one series rather than needing three.
  local name="$1" q="$2" id
  id="${name}-$(printf '%s' "$RUN_ID$name$(gate_progress_digest)" | shasum -a 256 | cut -c1-8)"
  gate_has_row '승인' "승인 id=$id " && return 0
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=-" "절단점=경계" \
    "행위 다이제스트=-" "구속 튜플=$name|$(gate_progress_digest)" "막는 세그먼트=-" \
    "질문 문면=$q" "답변 문면=-" "발행 시각=$(now_iso)" "해소 시각=-"
  warn "경계 $name 발동 — 승인 대기 $id: $q"
}

# The same seam run.sh carries, for the same reason: the tests need the
# definitions without a manifest, a run directory, or a verb. `test-snapshot.sh`
# calls `gate_progress_digest` directly against a fixture ledger, which is the
# only way to assert that issuing an approval leaves the digest unchanged — the
# regression that guards the boundary counters against resetting themselves.
if [ "${CC_GATE_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

gate_main "$@"
