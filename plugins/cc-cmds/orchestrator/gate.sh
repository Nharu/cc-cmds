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
#   gate.sh close    --manifest <path> --approval <id> [--void|--reject]
#
# `act --kind skill` also takes `--resume <session-id>` to RE-ATTACH a stage that
# was cut mid-flight instead of running it again. The id must appear on a
# `stage-result` row for that segment in this run's ledger.
#
# Three `act` kinds take FIELDS rather than a command after `--`, because what
# they perform is the ledger row itself:
#   gate.sh act --kind segment --target <alias> --segment <id> ... \\
#               -- 상태=<계획됨|실행중|리뷰중|머지됨|완료|적용 준비|park> 워크트리=<path> [브랜치=… PR=…]
#   gate.sh act --kind cycle   --target <alias> --segment <id> ... \\
#               -- 사이클=<n> P0=<n> P1=<n> '리뷰 HEAD=<sha>' [리포트 경로=…]
#   gate.sh act --kind obligation --target <alias> ... \\
#               -- '의무 id=<RO-…>' 근거=<무엇을 보고 이행으로 판정했는가>
# `obligation` takes no `--segment`: it reads one from the row it closes, so the
# obligation cannot be fulfilled into a segment other than the one it was issued
# for.
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
# The read-only predicates about a run's state. Sourced for the same reason
# `credentials.sh` is: three consumers used to answer "is this run still going?"
# with three implementations, and the render's answer disagreed with the
# termination condition's on the same run. One file, one rule.
# shellcheck source=/dev/null
. "$GATE_DIR/liveness.sh"

readonly GATE_EXIT_VOCAB=2
readonly GATE_EXIT_RULE=3
readonly GATE_EXIT_STALE=4
readonly GATE_EXIT_APPROVAL=5
readonly GATE_EXIT_GRADE=6
readonly GATE_EXIT_SURFACE=7

# AN INTERNAL SIGNAL AND NOT AN EXIT CODE. `gate_issue_judgment_approval`
# returns it to say "this question already has an answer, so nothing was
# issued" — a state its callers must route rather than propagate, because the
# two of them route it in opposite directions. Kept out of the exit range on
# purpose: a value that escaped to the shell would tell the router a code the
# contract never defined.
readonly GATE_APPROVAL_ANSWERED=9

readonly GATE_ROW_MAX=1024

# The cone row's segment list, bounded like every other free-length value on a
# row. Its neighbours on that row are three Korean free-text fields clipped at
# 400 bytes each, so the budget left for a list is small — and the list is the
# one field that grows with the SIZE OF THE NIGHT, which is exactly when the
# mechanism is needed. The same defect was measured once already on the
# termination-rejection row at 1228 bytes with nine segments in flight and fixed
# there by writing a bounded summary; this is that prescription applied to the
# field that inherited the shape.
readonly GATE_CONE_LIST_MAX=200

# ---------------------------------------------------------------------------
# The park-scope vocabulary, on the gate side.
#
# The driver has held this closed set since the falsifiability clause was made
# mechanical, but the check lived in ONE place — `park()` in run.sh — and the
# gate never went through it: every `blocked` row here spells its scope as a
# literal. So the token that decides the blast radius of a stop was, on the
# router path, whatever the caller typed.
#
# A misspelled scope is not a loud failure. It slips past termination condition
# 5's `스코프=run` filter AND past the cone predicate, so what lands is a park
# that stands nothing up: no segment is held, no run-scope block is enumerated,
# and the morning report shows a row that did nothing. That is why a `blocked`
# row with NO `스코프` field at all is refused here as well — absence produces
# the same silent nothing as a typo.
readonly GATE_SCOPES="act cone run"

gate_check_scope() {
  # gate_check_scope <scope> — 0 when the token is in the closed set.
  case " $GATE_SCOPES " in *" $1 "*) return 0 ;; esac
  warn "blocked 행의 「스코프」가 어휘 밖입니다: ${1:-없음} — 허용 토큰: ${GATE_SCOPES}"
  warn "어휘 밖 스코프는 종료 조건 5 의 스코프=run 필터도 원뿔 술어도 모두 피해서 아무것도 세우지 않는 park 이 됩니다"
  return "$GATE_EXIT_VOCAB"
}

gate_clip() {
  # gate_clip <text> <max-bytes> — clipped values SAY they were clipped. A
  # silent truncation reads in the morning as the whole answer.
  #
  # MEASURED AND CUT IN THE SAME UNIT, AND THE MARKER IS INSIDE THE BUDGET.
  # `wc -c` counts BYTES while `cut -c` counts CHARACTERS on this host —
  # measured, `cut -c1-3` over Korean returns three characters, nine bytes — so
  # a 400-byte budget returned up to ~1200 bytes and the marker was appended on
  # top of that. The function that exists to keep rows under `GATE_ROW_MAX`
  # broke it: a judgment approval whose question ran past ~133 Korean characters
  # could not be ISSUED, and `gate_close` could not RECORD an answer of ordinary
  # length, so the answer a person gave never reached the one durable copy of it.
  # The marker was also stamped on values that were never cut, because the
  # length test and the cut disagreed about what they were counting.
  #
  # The cut is BYTE-EXACT rather than merely re-budgeted. GNU coreutils
  # implements `-c` as `-b`, so on that side the same call already lands inside a
  # UTF-8 sequence and writes invalid bytes into the ledger — widening the budget
  # would move the defect from a loud refusal to silent corruption when the
  # platform changes. The trailing partial sequence is dropped by reading the
  # last lead byte's announced length: a cut is mid-character exactly when the
  # bytes present are fewer than that length. Everything runs under `LC_ALL=C`,
  # where `awk`'s `length` and `substr` are the byte operations this needs.
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

gate_row_safe() {
  # gate_row_safe <text> <max-bytes> — one row-safe field value.
  #
  # `|` separates fields and a newline ends the row, so a value carrying either
  # splices the grammar rather than merely looking untidy. The contract's other
  # answer is to fence the value and put the fence's info string on the row;
  # what a normalized excerpt buys instead is that the bytes stay ON the row,
  # where the morning reader is already looking, and the row-length cap of 1024
  # is honoured by construction.
  gate_clip "$(printf '%s' "$1" | tr '|' '/' | tr '\n\r' '  ' | tr -s ' ')" "$2"
}

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
surface_of_terraform() {
  # `terraform` was graded by its NAME alone, so `plan` — which the pipeline
  # contract explicitly classifies as a read — issued an approval every time.
  # Unattended there is nobody to answer one, so a stage that needed to look at
  # infrastructure state simply could not, and the run lost the investigation
  # rather than the change.
  #
  # Same shape as `git` and `gh`: the subcommand decides. Global options are
  # skipped so `terraform -chdir=x plan` grades like `terraform plan`, and an
  # unrecognized dash option yields `등급 미상` rather than a guess.
  # No `shift` here — the caller has already dropped argv0, so `$1` is the
  # subcommand. Shifting again ate it and every `terraform <anything>` graded as
  # the empty case.
  while [ $# -gt 0 ]; do
    case "$1" in
      -chdir=*|-help|-version|--help|--version) shift ;;
      -*) printf '등급 미상'; return 0 ;;
      *) break ;;
    esac
  done
  case "${1:-}" in
    plan|show|output|providers|version|validate|fmt|graph|state)
      # `state` without a subcommand lists; `state rm|mv` mutates and is caught
      # by the arm below.
      case "${1:-}" in
        state)
          case "${2:-}" in
            list|show|pull|'') printf '읽기' ;;
            *) printf '외부상태변경' ;;
          esac ;;
        fmt)
          # `fmt` rewrites files in place unless asked only to check.
          case " $* " in *" -check "*|*" --check "*) printf '읽기' ;; *) printf '워크트리쓰기' ;; esac ;;
        *) printf '읽기' ;;
      esac ;;
    '') printf '읽기' ;;
    *) printf '외부상태변경' ;;
  esac
}

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
    # `lockf` WRAPS another command, so it carries no grade of its own. Three
    # unattended skills make the document lock a MUST — every write to a design
    # document goes through `lockf -k -t 0 <lockfile> <command>` — and with no
    # row here that mandated spelling fell to `등급 미상`, which refuses. A stage
    # was then left with three moves: break its own skill's MUST and write
    # unlocked, hide argv0 behind an interpreter and launder the act, or stop.
    # One stopped, classified `gate-unanswerable`, which is the honest move and
    # also a night spent.
    #
    # A FIXED grade would be the laundering this table refuses — `lockf … curl …`
    # would record a network act as whatever constant this row named. So the
    # grade is the WRAPPED command's, exactly as `git` and `gh` delegate to
    # their subcommand. The digest-tool comment above records the first instance
    # of this shape; this is the second.
    lockf) surface_of_lockf "$@" ;;
    make|npm|npx|yarn|pnpm|pytest|go|cargo|bash|sh|zsh|python3|node)
      printf '워크트리쓰기' ;;
    mkdir|touch|cp|mv|rm|sed|tee|install)
      printf '워크트리쓰기' ;;
    terraform)
      surface_of_terraform "$@" ;;
    curl|wget|ssh|scp|rsync|kubectl|aws|gcloud|docker)
      printf '외부상태변경' ;;
    # Browser automation. With no row here every spelling fell to `등급 미상`,
    # which refuses — so a stage that needed a browser either spent the night in
    # an approval nobody was awake to answer, or reached it through `bash -c`
    # and passed while the ledger recorded a network session as a worktree
    # write. The second is worse than the first: the morning report reads axis 2
    # to say what left the machine, so the laundered spelling makes the audit
    # trail quietly false rather than merely stuck.
    #
    # Graded `외부상태변경` unconditionally, and NOT split by subcommand the way
    # `git` and `terraform` are. Those two have subcommands whose names decide
    # the effect; a browser driver's argv says which page to open, and opening
    # any page is already a network act. There is no read-only arm to carve out.
    playwright|playwright-cli|chromedriver|geckodriver|puppeteer|selenium)
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

surface_of_lockf() {
  # surface_of_lockf lockf [-k] [-s] [-t <sec>] <lockfile> <command> [args...]
  #
  # Skip lockf's own options and its lockfile operand, then grade what is left.
  # `-t` takes a value; `-k` and `-s` do not. The lockfile is the first
  # non-option word and is never itself the command.
  #
  # A lock with nothing after it locks and exits — that is a worktree write (it
  # creates the lockfile) and there is no wrapped command to defer to.
  local seen_file=0
  shift                                   # drop `lockf` itself
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) shift 2 || return 0 ;;
      -t*) shift ;;
      -k|-s|-n) shift ;;
      -*) printf '등급 미상'; return 0 ;;
      *)
        if [ "$seen_file" = 0 ]; then seen_file=1; shift; continue; fi
        surface_of_argv0 "$@"
        return 0 ;;
    esac
  done
  [ "$seen_file" = 1 ] && { printf '워크트리쓰기'; return 0; }
  printf '등급 미상'
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
    status|log|show|diff|rev-parse|rev-list|merge-base|blame|cat-file|ls-files)
      printf '읽기' ;;
    # Three subcommands whose NAME says nothing about their effect, and all three
    # sat on the read arm above: `git worktree add` creates a working tree,
    # `git branch -D` deletes a ref, and `git config --global` rewrites the
    # user's own configuration under $HOME — each recorded as a read. Two things
    # broke at once. The reversibility floor read `git config --global <k> <v>`
    # as a costless undo, so an act could be auto-adopted on the strength of a
    # rollback that edits $HOME. And a worktree creation declared honestly as
    # `워크트리쓰기` came back exit 6 while the same act declared `읽기` ran, so
    # the only spelling that worked was the false one.
    #
    # None of the three shifts. The caller already dropped argv0 and the
    # global-option loop above has ended, so `$1` is still the subcommand and
    # `$2` onward are its arguments — the reading `surface_of_terraform` records
    # for `state`.
    worktree) surface_of_git_worktree "$@" ;;
    branch)   surface_of_git_branch "$@" ;;
    config)   surface_of_git_config "$@" ;;
    add|commit|checkout|switch|restore|rebase|merge|cherry-pick|revert|stash|apply|am|reset|tag)
      printf '워크트리쓰기' ;;
    remote)   surface_of_git_remote "$@" ;;
    push|fetch|pull|clone)
      printf '외부상태변경' ;;
    *) printf '등급 미상' ;;
  esac
}

surface_of_git_remote() {
  # `git remote` and `git remote -v` list what local config already records —
  # no packet leaves the machine. Lumping them with `push`/`fetch` made reading
  # the remote configuration issue an approval, and unattended there is nobody
  # to answer it, so a stage could not even see the state it was about to act
  # on. The same repair was already made for `terraform`, whose comment records
  # the identical reasoning; this row is that repair reaching `git remote`.
  case "${2:-}" in
    ''|-v|--verbose)                                   printf '읽기' ;;
    add|remove|rm|rename|set-url|set-head|set-branches) printf '워크트리쓰기' ;;
    # `show` and `update` and `prune` contact the remote. `show -n` does not,
    # but grading on a flag that may sit anywhere in argv is the kind of
    # precision this table refuses to fake — the safe direction is the wider
    # grade, which costs a manifest line rather than a false audit trail.
    show|update|prune)                                  printf '외부상태변경' ;;
    *)                                                  printf '등급 미상' ;;
  esac
}

surface_of_git_worktree() {
  # `git worktree list` is what the verification contract's boundary gate runs
  # before and after every recipe, so it has to stay a read. Everything else
  # here adds, removes, relocates or locks a working tree.
  case "${2:-}" in
    list|'') printf '읽기' ;;
    add|remove|move|prune|repair|lock|unlock) printf '워크트리쓰기' ;;
    *) printf '등급 미상' ;;
  esac
}

surface_of_git_branch() {
  # Listing by default; creating, deleting, renaming, copying or repointing an
  # upstream writes a ref.
  #
  # The option scan exists for ONE reason: `--contains`, `--merged`, `--sort`
  # and their kin take the NEXT WORD as their value, and a value left in place
  # looks like a positional branch name — which would grade `git branch
  # --contains HEAD`, a pure query, as a branch creation. `--color` is on the
  # valueless side on purpose: git spells it `--color[=<when>]`, so eating the
  # next word there would make `git branch --color newbr` read as a query, which
  # is the same mistake with its sign flipped.
  local a skip=1 want=0
  for a in "$@"; do
    # The first word is `branch` itself — this function is handed the whole
    # subcommand argv and does not shift.
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$want" = 1 ]; then want=0; continue; fi
    case "$a" in
      -d|-D|--delete|-m|-M|--move|-c|-C|--copy|-u|--set-upstream-to|--set-upstream-to=*|--unset-upstream|--edit-description|-f|--force)
        printf '워크트리쓰기'; return 0 ;;
      --contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format)
        want=1 ;;
      -a|--all|-r|--remotes|-v|-vv|--verbose|-q|--quiet|-l|--list|--show-current)
        : ;;
      -i|--ignore-case|--omit-empty|--no-abbrev|--no-color|--column|--no-column|--track|--no-track|--color)
        : ;;
      --contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*|--sort=*|--format=*|--abbrev=*|--column=*|--color=*)
        : ;;
      -*) printf '등급 미상'; return 0 ;;
      # Options accounted for and a word left over: it is a branch NAME, and
      # naming one here creates it.
      *) printf '워크트리쓰기'; return 0 ;;
    esac
  done
  # A value-taking option with nothing after it is malformed, and this table
  # refuses rather than guesses.
  [ "$want" = 1 ] && { printf '등급 미상'; return 0; }
  printf '읽기'
}

surface_of_git_config() {
  # Two axes multiply here — the OPERATION (query or write) and the SCOPE (in
  # the tree or outside it) — so no single list decides the grade.
  #
  # A `git config` not spelled as an explicit query grades as a write, and that
  # over-grade is deliberate. This table sees argv alone, so `git config
  # --global user.name` (a query) and `git config --global user.name x` (a
  # write) differ by one word, and deciding on word COUNT would hang the whole
  # grade on details like whether `-f` consumed the next one. Of the two ways to
  # be wrong, demanding authorization for a query costs a line in the manifest,
  # while letting a rewrite of $HOME through as a read is the hole this repair
  # exists to close. A query spelled with `--get` still grades exactly `읽기`,
  # so the form the pipeline actually runs loses nothing.
  local a skip=1 want=0 scope='' query=0
  for a in "$@"; do
    # The first word is `config` itself.
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$want" = 1 ]; then want=0; continue; fi
    case "$a" in
      --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list)
        query=1 ;;
      --global|--system)  scope='트리밖쓰기' ;;
      --file|-f)          scope='트리밖쓰기'; want=1 ;;
      --file=*)           scope='트리밖쓰기' ;;
      --local|--worktree) : ;;
      -*) printf '등급 미상'; return 0 ;;
      # A key or a value. Neither decides anything on its own — the options
      # above already did.
      *) : ;;
    esac
  done
  [ "$want" = 1 ] && { printf '등급 미상'; return 0; }
  [ "$query" = 1 ] && { printf '읽기'; return 0; }
  printf '%s' "${scope:-워크트리쓰기}"
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
  # THE CHAIN TIP IS READ INSIDE THE LOCK, and it used to be read outside it.
  # This is a read-then-act whose critical section excluded the value that makes
  # the row correct: two concurrent appends read the same tip and both wrote
  # rows carrying the same `prev`, so the verifier reported a break for a ledger
  # nobody had touched. Measured on a 227-row ledger written by one stage going
  # through the gate for each of its Bash calls — rows 85 and 86 chained to the
  # same parent, both present and well-formed, and the run was told it had been
  # spliced.
  #
  # A false break is worse than no chain: a real splice then looks exactly like
  # the noise a reader has learned to skip.
  local series="$1"; shift
  local body f k v

  # EVERY FIELD VALUE IS MADE ROW-SAFE HERE, NOT AT THE CALL SITES.
  #
  # `|` separates fields and a newline ends the row, so a value carrying either
  # SPLICES the grammar. `gate_row_safe` performs exactly this transform but is
  # applied to a hand-picked few fields, and the values the ROUTER supplies —
  # `사유`, `근거`, `선행`, `선언 파일 집합`, `의존 세그먼트`, `재개 명령` —
  # went in raw. Korean review prose contains pipes routinely.
  #
  # What made that more than untidy is that the write-time checks and the
  # readers had DIFFERENT FIELD VIEWS. A check reads the argv list through
  # `gate_field_of`, one element per field; every reader splits the row TEXT on
  # `|`. A pipe inside one argv element is invisible to the first and is a new
  # field to the second, so `사유=… | 스코프=run` passed the cone check as
  # `cone` and then enumerated as an unresolved run-scope block in termination
  # condition 5. The same splice reaches `gate_segment_ids`, whose greedy `id=`
  # extraction takes the LAST match and therefore changes which segment a row is
  # about.
  #
  # Normalizing before the body is assembled collapses the two views into one:
  # after this loop no field value can contain a separator, so reading the argv
  # and reading the row give the same answer by construction — and no writer
  # added later can forget. A value that legitimately needs a pipe uses the
  # contract's other answer (a fence plus its info string); the one value in this
  # file that used `|` as an internal separator now spells it `/`.
  # Rotated through the positional parameters rather than collected into an
  # array: the interpreter floor is bash 3.2 and the argument list is the one
  # ordered container available without one.
  local n_args=$# i=0
  while [ "$i" -lt "$n_args" ]; do
    f="$1"; shift; i=$((i + 1))
    case "$f" in
      *=*) k="${f%%=*}"; v="${f#*=}"
           f="$k=$(printf '%s' "$v" | tr '|' '/' | tr '\n\r' '  ')" ;;
    esac
    set -- "$@" "$f"
  done

  # THE SCOPE CHECK SITS HERE AND NOT AT THE CALL SITES. Cone rows are appended
  # through this function rather than through `park()`, and the four literal
  # spellings already in this file plus every one added later are covered in one
  # place by putting the check where the row is actually written. It runs AFTER
  # the normalization above so that what it reads is what the row will say.
  if [ "$series" = "blocked" ]; then
    local scope=""
    for f in "$@"; do
      case "$f" in 스코프=*) scope="${f#스코프=}" ;; esac
    done
    gate_check_scope "$scope" || return "$GATE_EXIT_VOCAB"
  fi

  body="- \`$series\`"
  for f in "$@"; do body="$body | $f"; done

  # The length check runs on the body plus a 64-character stand-in, because
  # `prev` is a sha256 in every case and its width is therefore known before the
  # value is. Deferring the whole check into the lock would put a `die` inside
  # the critical section.
  local n
  n=$(printf '%s | prev=%s\n' "$body" "0000000000000000000000000000000000000000000000000000000000000000" | wc -c | tr -d ' ')
  if [ "$n" -gt "$GATE_ROW_MAX" ]; then
    die "원장 행이 상한을 넘습니다 (${n} > ${GATE_ROW_MAX} 바이트) — 긴 값은 사이드카로 빼야 합니다: ${series}"
  fi

  # The tip logic is inlined rather than calling `gate_chain_tip`, because the
  # locked command is `/bin/sh` and cannot see this shell's functions. The row
  # prefix is passed as a positional argument so the backtick in it is never
  # parsed by either shell.
  local tool rc=0
  tool=$(lock_tool)
  if [ -n "$tool" ] && [ -n "${RUN_DIR:-}" ]; then
    "$tool" -k "$RUN_DIR/ledger.lock" \
      /bin/sh -c '
        last=$(grep "$3" "$2" 2>/dev/null | tail -1)
        [ -n "$last" ] || last="$4"
        prev=$(printf "%s" "$last" | shasum -a 256 | cut -d" " -f1)
        printf "%s | prev=%s\n" "$1" "$prev" >> "$2"
      ' _ "$body" "$LEDGER" '^- `' "## 실행 $RUN_ID" || rc=$?
  else
    # No lock tool means no concurrency to serialize, so the same sequence is
    # correct here — it is the interleaving that the lock removes, not the order.
    local prev
    prev=$(gate_chain_tip)
    printf '%s | prev=%s\n' "$body" "$prev" >> "$LEDGER" || rc=$?
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
  # `cycle` rows are progress and were missing. A review completing, a
  # remediation landing, a re-review coming back clean — each writes one, and
  # none of them moved this vector, so a run could record a review, push a
  # branch and merge a pull request while the boundary counted it as motionless.
  # They are safe to include for the same reason segment rows are: the gate does
  # not write one on every act, only when a cycle is actually recorded.
  gate_rows 'cycle' \
    | sed -n 's/.*세그먼트=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u \
    | while IFS= read -r cseg; do
        [ -n "$cseg" ] || continue
        printf 'cycle=%s|%s\n' "$cseg" \
          "$( { gate_rows 'cycle' | grep -F "세그먼트=$cseg " || true; } | gate_count)"
      done
  # The router's OWN acts were missing, and they are most of what a run does
  # between stages. A commit, a push, a pull request, a merge — every one is
  # authorised through this gate and writes a row, and none of them moved this
  # vector. So a router that spent an hour landing fixes read as motionless and
  # the stagnation boundary fired on it. That is not a cosmetic false positive:
  # the approval it opens suspends B1..B3 and blocks termination until a PERSON
  # closes it, and the gate accepts no answer the router typed — so a run doing
  # visible work stops and waits for someone who may be asleep.
  #
  # Only acts graded ABOVE `읽기`. Reads are how the router looks around and
  # they happen constantly; counting them would keep this vector permanently in
  # motion and the boundary would never fire on anything.
  #
  # Safe for the same reason `cycle` rows are, and the reason has to hold or
  # this re-introduces the original defect: the boundary's remedy writes an
  # `승인` row, never an `exec` one, so nothing here can reset the counter that
  # fired it.
  # Selected POSITIVELY — the row must carry a grade, and that grade must not be
  # `읽기`. Excluding `읽기` alone would also count a row with no `축2=` field at
  # all, and a row whose surface grade is unknown is not evidence that anything
  # changed. Unknown is not progress; counting it as progress would let the
  # boundary be reset by a row that says nothing about what was done.
  printf 'acts=%s\n' \
    "$( { gate_rows '자율 승인' | grep '결정=exec' || true; } \
       | { grep -F '축2=' || true; } \
       | { grep -v '축2=읽기' || true; } | gate_count)"
  # Settling a clause and clearing a run-scope block are progress by definition
  # — they are the only two moves whose whole purpose is to bring the run nearer
  # to being able to end. A run that spends a judgment doing one of them and is
  # then told it has not moved is being told something false.
  printf 'clauses=%s\n' "$( { gate_rows 'clause' || true; } | gate_count)"
  printf 'unblocks=%s\n' \
    "$( { gate_rows 'blocked' | grep -F '원인=해소' || true; } | gate_count)"
  gate_open_obligations | sort
}

gate_progress_digest() {
  gate_progress_vector | shasum -a 256 | cut -d' ' -f1
}

gate_snapshot_digest() {
  # TWO DIGESTS, BECAUSE ONE VALUE CANNOT HAVE BOTH PROPERTIES.
  #
  # The stagnation boundary needs a value that moves only on PROGRESS — that is
  # `gate_progress_digest`, and every ledger append must be invisible to it or
  # the gate's own writes would reset the counter that watches for the gate not
  # writing.
  #
  # `--snapshot-digest` needs the opposite. It exists to catch a router acting
  # on state that has moved, explicitly including a compacted router carrying a
  # remembered value instead of re-reading. With the progress vector as its
  # source it could not do that: the vector is manifest-derived plus segment
  # rows plus obligations, so it is constant across long stretches of a run —
  # measured, two runs against different manifests, one with a 3-row ledger and
  # one with 227, produced the byte-identical value. Exit 4 could not fire, and
  # the check passed while the premise it protected was false.
  #
  # So this one is the vector PLUS the ledger's observable state. The tip alone
  # would do, since it is the hash of the last row; the count is carried with it
  # so a revert to an earlier length is not mistaken for no change at all.
  local n
  n=$( { grep -c '^- `' "$LEDGER" 2>/dev/null || true; } | tr -d ' ')
  { gate_progress_vector
    printf 'ledger=%s|%s\n' "${n:-0}" "$(gate_chain_tip)"
  } | shasum -a 256 | cut -d' ' -f1
}

gate_segment_field() {
  # Last row for this segment id wins — the append-only advance of contract 3.4.
  local sid="$1" key="$2"
  # The `grep` is guarded for the same reason as `cc_unresolved_blocked`: asking
  # for a segment id that has no rows yet is ordinary — the router does it on the
  # first act of every run — and an unguarded middle `grep` turns that into a
  # `pipefail` non-zero which `set -e` reads as a fatal, message-less failure.
  gate_rows 'segment' \
    | { grep -F "id=$sid " || true; } | tail -1 \
    | tr '|' '\n' | sed -n "s/^ *$key=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_row_field() {
  # gate_row_field <row-text> <key> — the last value with that key in ONE row.
  # `gate_field_of` reads an argv field LIST; carrying a value forward needs a
  # field of a row already written, and the two are not interchangeable.
  local row="$1" key="$2"
  printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$key=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_open_obligations() {
  # An obligation is closed only by a LATER cycle row for the same segment whose
  # report no longer carries the identity — a `problem` row records an attempt,
  # not a resolution, so reading closure from it would mark every re-try as a fix.
  # `LC_ALL=C` here and at every other `sort -u` over a FIELD VALUE. These sorts
  # are set operations, not presentation, and `-u` drops whatever collation calls
  # equal — the `en_US.UTF-8` collation orders no Hangul, so two different Korean
  # values compare equal and one of them disappears. `동일성` is Korean free text
  # by contract, so this is the sort where it bites hardest: distinct problems
  # would merge into one, the cone built from them would be wrong, and every
  # check over it would report success.
  gate_rows 'problem' \
    | tr '|' '\n' | sed -n 's/^ *동일성=//p' | sed 's/[[:space:]]*$//' \
    | LC_ALL=C sort -u | while IFS= read -r ident; do
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
  printf '  "H": "%s"\n' "$(gate_snapshot_digest)"
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
      "$(gate_json_escape "$(gate_rows '승인' | { grep -F "승인 id=$id " || true; } | tail -1 \
          | tr '|' '\n' | sed -n 's/^ *막는 세그먼트=//p' | sed 's/[[:space:]]*$//' | tail -1)")"
  done
  [ "$first" = "1" ] || printf '\n'
}

gate_render_snapshot() {
  local a
  printf '목표      : %s\n' "$(manifest_field '인가' '종료 지점')"
  printf '진전 해시 : %s\n' "$(gate_progress_digest)"
  printf '스냅숏 해시: %s\n' "$(gate_snapshot_digest)"
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
  # Counting pid FILES reported stages that were not there: measured 21 files
  # against 5 live processes, and a render claiming "진행 중" for a run whose
  # recorded pid was dead. The shared predicate tests the process.
  n_live=$(cc_live_stages "$RUN_DIR")
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
    | LC_ALL=C sort -u | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')

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
  local before after tmpdir base lk="${RUN_DIR:-}/settings.lock"
  [ -n "${RUN_DIR:-}" ] || return 0
  # The WHOLE sequence is inside the lock — read, compare, rewrite, re-measure,
  # re-baseline. Guarding only the write would leave the guard below reading a
  # baseline another process is about to replace, which is the same read-then-act
  # with the lock on the wrong half.
  gate_settings_lock "$lk" || return 0
  before=$(gate_surface_digest_raw)

  # ONLY FROM A KNOWN-GOOD BASELINE. If the surface has already moved, this is
  # not the place to decide about it — `gate_surface_check` owns that verdict,
  # and rewriting here would erase the very evidence it reads. Without this
  # guard the re-derivation silently repairs and re-baselines an edit made by
  # anything at all, which is exactly the detection the digest exists for.
  base=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || true)
  if [ -z "$base" ] || [ "$before" != "$base" ]; then
    gate_settings_unlock "$lk"; return 0
  fi

  tmpdir="$(gate_settings_dir).probe.$$"
  rm -rf "$tmpdir"
  ( CC_GATE_SETTINGS_OVERRIDE="$tmpdir"; export CC_GATE_SETTINGS_OVERRIDE
    gate_write_settings >/dev/null 2>&1 ) || { rm -rf "$tmpdir"; gate_settings_unlock "$lk"; return 0; }
  if diff -r -q "$tmpdir" "$(gate_settings_dir)" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; gate_settings_unlock "$lk"; return 0
  fi
  rm -rf "$tmpdir"

  gate_write_settings >/dev/null 2>&1 || { gate_settings_unlock "$lk"; return 0; }
  after=$(gate_surface_digest_raw)
  printf '%s\n' "$after" > "$RUN_DIR/surface-digest"
  gate_append '대상 추가' "별칭=-" "원격 슬러그=-" \
    "메인 워크트리=-" "공통 git 디렉터리=-" "베이스 브랜치=-" "층=0" \
    "발견 경로=인가 디렉터리 재유도 (${before} → ${after})" "기록 시각=$(now_iso)"
  gate_settings_unlock "$lk"
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
  # THE NINE FIELDS ARE CHECKED FOR PRESENCE, because until now exactly one of
  # them was ever read. The contract fixes the block at nine fields in a fixed
  # order and gives it no rewrite form — a block appended with a field missing
  # is frozen that way, and re-authorizing is a NEW run rather than an edit. So
  # a check that runs after the block is written cannot repair it; what it can
  # do is refuse to run on it, which is the only remaining moment the omission
  # is cheap. Measured: the kickoff's own template emitted eight, dropping
  # `직렬 웨이브 고지`, and nothing anywhere noticed.
  local gf
  for gf in '인가 일시' '종료 지점' '권한 절단점' '말단 행위 상한' '직렬 웨이브 고지' \
            '시각 정합 마커' '사용자 확인 문면' '설계 문서 전체 sha256' '보고서'; do
    if [ -z "$(gate_grant_field "${gf}")" ]; then
      warn "인가 기록에 「${gf}」가 없습니다 — 계약은 아홉 필드를 전부 요구하며 이 블록에는 재작성 형태가 없습니다"
      return "$GATE_EXIT_RULE"
    fi
  done

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
gate_settings_lock() {
  # A mutex over the settings directory, held by BOTH the readers and the
  # writer. `mkdir` because it is atomic on every filesystem this runs on and
  # needs no external tool — `lockf` is darwin-only here, and this hazard is not.
  #
  # Locking only the writer would not be enough: `gate_write_settings` truncates
  # each file in place (`cat > "$f"`), so a concurrent digest walks a directory
  # that is half old and half new and gets a value that matches neither side.
  # That is what turned two parallel stages into a pair of re-derivations
  # undoing each other — measured as A→B then B→A in one run's ledger, with no
  # directory actually added and the run invalidated inside twelve minutes.
  local lockdir="$1" waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    waited=$(( waited + 1 ))
    # Give up rather than hang. A caller that could not take the lock returns
    # its previous answer, which is the safe direction: the digest is compared
    # against a baseline, and a stale-but-consistent value refuses rather than
    # permits.
    [ "$waited" -gt 200 ] && return 1
    sleep 0.05
  done
  return 0
}

gate_settings_unlock() { rmdir "$1" 2>/dev/null || true; }

gate_surface_digest() {
  local lk="${RUN_DIR:-}/settings.lock" out
  if [ -n "${RUN_DIR:-}" ] && gate_settings_lock "$lk"; then
    out=$(gate_surface_digest_raw)
    gate_settings_unlock "$lk"
    printf '%s' "$out"
  else
    gate_surface_digest_raw
  fi
}

gate_surface_digest_raw() {
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
  local approval="" render=0 worktree="" review_policy="" void=0 reject=0
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
      --reject)          reject=1; shift ;;
      --resume)          GATE_RESUME="$2"; shift 2 ;;
      --)                shift; break ;;
      *) printf 'gate: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  [ -n "$MANIFEST" ] || { printf 'gate: --manifest 가 필요합니다\n' >&2; exit 2; }
  # ABSOLUTE, BEFORE ANYTHING COMPARES AGAINST IT. The manifest write guard asks
  # whether an act names this file, and it asked by comparing strings — so the
  # same file reached through a relative path, or through any other spelling of
  # the same absolute path, was a different string and the guard missed it. The
  # value is a path the caller chose; normalizing it once here is what makes
  # every later comparison a question about the FILE.
  #
  # Only when the directory exists. `cd` into a missing directory fails, and
  # letting the failure through would leave `/$(basename …)` — a path naming
  # nothing, which the guard would then compare against and never match. A
  # manifest whose directory is absent is a hard stop one line later anyway, so
  # keeping the original value costs nothing and removes a way to disarm the
  # guard by pointing it somewhere unreachable.
  #
  # LOGICAL, not physical, and deliberately so. `MANIFEST` is also the value the
  # digest path reads, the value the refusal messages print and the value a
  # caller sees echoed back, so resolving symlinks here would rewrite the path
  # every caller spelled into one they never used. Symlink identity belongs to
  # the comparison that needs it: `gate_manifest_write_guard` resolves both
  # sides physically at the point of comparison and leaves this value alone.
  if [ -d "$(dirname "$MANIFEST")" ]; then
    MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
  fi
  check_manifest
  derive_paths_from_manifest
  gate_check_grant || exit $?
  rundir_init

  # THE HANDLES A LATER READER NEEDS, written on EVERY entry rather than at run
  # open. A run that was cut and resumed still has to be findable, and the run
  # open block below runs once per run — putting these inside it would leave a
  # resumed run without the files that make it addressable.
  #
  # `ledger-path` exists because the ledger's location is derived from the
  # manifest's `origin-worktree`, and the things that need to read the ledger —
  # a status line, anything outside the driver — do not know the manifest. The
  # gate does. Idempotent overwrite.
  printf '%s\n' "$LEDGER" > "$RUN_DIR/ledger-path"

  # The FORWARD index: session id → run ids. `session-lineage` runs the other
  # way (run → its session ids) and answering "which run belongs to this
  # session?" from it means scanning every run directory. One session can hold
  # several runs, so this is a LIST — one run id per line, appended, deduped.
  # Entries for runs whose directory is gone are left alone: the reader filters
  # with `[ -d ]`, and pruning would add a write to a path that has none.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session"
    grep -qxF "$RUN_ID" \
      "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session/$CLAUDE_CODE_SESSION_ID" 2>/dev/null \
      || printf '%s\n' "$RUN_ID" \
           >> "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/session/$CLAUDE_CODE_SESSION_ID"
  fi

  # Lineage is recorded here rather than only where it is consumed. Its one
  # caller was `gate_transcript_files`, which is reached only by `close` — so a
  # run that never opened an approval had no lineage at all, and a `--resume`
  # across that gap left the earlier session id unrecorded for good.
  #
  # THE GUARD IS THE POINT, not a precaution. Lineage is what
  # `gate_transcript_files` searches to find the transcript an approval was
  # answered in, so every id in it is an id allowed to ANSWER. Promoting the
  # call to the entry point without this test would enrol every stage: stages
  # reach the gate too — the pre-tool hook routes each of their Bash, Write and
  # Edit through it — and each carries its own session id. The run's approvals
  # would then be answerable from inside the very stages they gate, which is the
  # self-approval path the separation exists to keep shut.
  #
  # `CC_PIPELINE_STAGE_ID` is exported to stage children by the driver and to
  # nothing else, so its presence is the router/stage distinction rather than a
  # heuristic.
  [ -n "${CC_PIPELINE_STAGE_ID:-}" ] || gate_session_lineage >/dev/null

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
      # The two refusing dispositions are different CLAIMS about the same
      # approval — one says the question should not have been asked, the other
      # that it was asked and the answer is no. Taking both would leave the
      # row's state decided by whichever branch runs first, so the pair is
      # refused rather than ranked.
      if [ "$void" = "1" ] && [ "$reject" = "1" ]; then
        printf 'gate: --void 와 --reject 는 서로 다른 처분입니다 — 하나만 고르세요\n' >&2; exit 2
      fi
      gate_close "$approval" "$void" "$reject"
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

# ---------------------------------------------------------------------------
# The dependency cone.
#
# A question raises a cone and NOT a run stop: what stands on the refuted
# premise is held, and its siblings keep going. The cone is a PREDICATE, not a
# frozen set — at the moment a question goes up the dependent may not have
# branched yet, and freezing then would leave it outside forever. Everything
# below recomputes from the ledger and the live worktrees each time it is asked.
# ---------------------------------------------------------------------------
gate_segment_ids() {
  gate_rows 'segment' | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sort -u
}

gate_segment_count_including() {
  # gate_segment_count_including <segment> — how many segments this ledger knows
  # once the row about to be written is counted. The row's own id is included
  # because the question the caller asks is about the state AFTER the write.
  local sid n=0 seen=0
  for sid in $(gate_segment_ids); do
    [ -n "$sid" ] || continue
    n=$((n + 1))
    if [ "$sid" = "$1" ]; then seen=1; fi
  done
  if [ "$seen" != "1" ]; then n=$((n + 1)); fi
  printf '%s' "$n"
}

gate_segment_worktree() { gate_segment_field "$1" '워크트리'; }

gate_segment_terminal() {
  local st
  st=$(gate_segment_field "$1" '상태')
  case " $TERMINAL_SEGMENT_STATES " in *" $st "*) return 0 ;; esac
  return 1
}

gate_segment_common_git() {
  local wt out
  wt=$(gate_segment_worktree "$1")
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  out=$( { cd "$wt" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null; } || true)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

gate_segment_tip() {
  local wt out
  wt=$(gate_segment_worktree "$1")
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  out=$( { cd "$wt" 2>/dev/null && git rev-parse HEAD 2>/dev/null; } || true)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

gate_dep_tokens() {
  # gate_dep_tokens <선행 값> — the dependency ids as whitespace-separated
  # tokens. THE ONE NORMALIZATION, used by the reader and by the write-time
  # floor alike.
  #
  # Two defects lived in having two of them. The reader split on comma AND
  # whitespace while the monotonicity floor DELETED whitespace and split on
  # comma only, so `선행=SA SB` — an ordinary prose spacing that flows in
  # verbatim from the design document's slice declaration, which `slice_field`
  # does not normalize — became the single token `SASB` to the floor. Restating
  # the same value then failed the floor, and since a repository with two
  # segments must carry `선행` on every row, that segment could not write a
  # second row at all: not a widening, not a state advance, nothing. The refusal
  # blamed a removal that had not happened.
  #
  # And `없음` was matched against the WHOLE value rather than per token, so
  # `없음,S1` kept `없음` as a dependency id. Nothing lands a segment named
  # `없음`, so the landing check refused that segment forever — and the
  # monotonicity floor refused the correction, because dropping `없음` is a
  # removal. That state is reached by FOLLOWING the instructions: the router is
  # told the field may be added to and not subtracted from, and a router holding
  # `없음` that acquires a dependency does exactly this.
  #
  # THE SENTINEL SET AND THE `슬라이스 ` PREFIX ARE SHARED WITH `run.sh`'s
  # `dep_tokens`, character for character. The driver's readers already accepted
  # `-` as a null and already stripped the prefix a design document's slice
  # declaration writes; this one did neither, so `**선행**: 슬라이스 SA` was one
  # dependency to the driver and two unknown tokens to the write-time floor that
  # decides whether the row may be written at all. Two normalizations for one
  # field is how the two sides came to disagree about whether a segment had any
  # dependencies.
  local t out=""
  for t in $(printf '%s' "${1:-}" | tr ',' ' '); do
    case "$t" in ''|'-'|'없음'|'(없음)') continue ;; esac
    t=${t#슬라이스}
    case "$t" in ''|'-'|'없음'|'(없음)') continue ;; esac
    out="$out $t"
  done
  printf '%s' "${out# }"
}

gate_deps_of() {
  # gate_deps_of <segment> — the `선행` of that segment's last row, as
  # whitespace-separated ids. `없음` yields the empty set, which is also what an
  # absent field yields — the two are told apart at WRITE time, because that is
  # the only moment at which the difference exists.
  gate_dep_tokens "$(gate_segment_field "$1" '선행')"
}

gate_ancestor_of() {
  # gate_ancestor_of <A> <B> — 0 A's tip is an ancestor of B's tip, 1 it is not,
  # 2 the question could not be answered.
  #
  # THE THREE EXIT CODES ARE NOT FOLDED INTO TWO. `--is-ancestor` answers 1 for
  # "no" and 128 for "that object is not here" — a vanished worktree path, a
  # damaged object database, a permission failure. Reading 128 as "no" turns
  # every one of those into "not in the cone, so nothing is held", which would
  # be this design's single unconditional fail-open. What the accepted residual
  # authorizes is STRUCTURAL under-parking, never under-parking caused by a
  # fault.
  #
  # AND IT IS A PROPER ANCESTOR — an equal tip is NOT an edge. `git merge-base
  # --is-ancestor X X` is true, which is the right answer to the question git was
  # asked and the wrong answer to the question this function asks. What the
  # ancestry axis trades on is "that member has already merged, so the candidate
  # stands on its commits"; a member whose tip IS the candidate's tip has
  # contributed no commit the candidate could stand on, so the implication is
  # simply absent. Left in, every segment sitting on one worktree answered
  # "ancestor" for every other, and a cone anchored on any one of them swallowed
  # the whole group. A genuine dependency between two such segments is still
  # seen: the declared axis is evaluated before this one and reads it straight
  # off `선행`.
  local tipa tipb wtb rc=0
  tipa=$(gate_segment_tip "$1") || return 2
  tipb=$(gate_segment_tip "$2") || return 2
  [ "$tipa" != "$tipb" ] || return 1
  wtb=$(gate_segment_worktree "$2")
  [ -d "$wtb" ] || return 2
  ( cd "$wtb" && git merge-base --is-ancestor "$tipa" "$tipb" ) >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

gate_record_undecidable() {
  # An ancestry probe that came back 2 or higher. The disposition is FAIL-CLOSED
  # — the candidate STAYS in the cone — and the row exists so that what the
  # morning reads is "this could not be measured" rather than "this was measured
  # and stood up".
  local m="$1" s="$2" why
  why="조상 관계 판정 불가 ${m}→${s}"
  gate_has_row 'blocked' "사유=$why" && return 0
  gate_append 'blocked' "대상=${CC_PIPELINE_TARGET:--}" "스코프=cone" "원인=판정 불가" \
    "사유=$why" \
    "근거=$(gate_row_safe "워크트리 ${m}=$(gate_segment_worktree "$m") · ${s}=$(gate_segment_worktree "$s")" 300)" \
    "관측=$(now_iso)" \
    "재개 명령=세그먼트 워크트리와 객체 DB 를 복구한 뒤 같은 앵커로 원뿔을 다시 기록하세요"
  warn "조상 관계를 재지 못했습니다 (${m}→${s}) — 그 세그먼트는 원뿔 안에 남습니다"
}

gate_fileset_escape() {
  # gate_fileset_escape <segment> — the paths this segment changed that its
  # declared file set does not cover, one per line.
  #
  # This is the one premise refutation the gate OBSERVES rather than infers, and
  # git cannot answer it at all: ancestry says whether B was built on A, and
  # says nothing about whether a segment reached outside what it declared. The
  # only input to that judgment is the `선언 파일 집합` field, which is why the
  # field is carried even though nothing about the cone's ancestry axis needs
  # it. A segment that declared nothing is silent here — a claim nobody made
  # cannot be violated.
  #
  # NEITHER SIDE OF THE COMPARISON IS WORD-SPLIT, because a path is not a word
  # and a declared prefix is not one either. `for f in $(git diff --name-only)`
  # tore `docs/설계 노트.md` into two fragments, neither of which any declaration
  # covers, so a segment that stayed strictly inside what it declared raised a
  # cone against itself — and the identical splitting on the declaration side
  # tore a prefix containing a space into two prefixes that cover nothing, which
  # fails the other way and lets a real escape through. `core.quotePath=false` is
  # the other half of the same repair: without it git renders every non-ASCII
  # byte as a `\nnn` escape inside double quotes, so a Korean path is compared in
  # a spelling it never has on disk and can never match its own prefix.
  local decl base wt f p covered decls
  decl=$(gate_segment_field "$1" '선언 파일 집합')
  case "$decl" in ''|'없음'|'(없음)') return 0 ;; esac
  base=$(gate_segment_field "$1" '베이스 sha')
  [ -n "$base" ] || return 0
  wt=$(gate_segment_worktree "$1")
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0
  decls=$(printf '%s' "$decl" | tr ',' '\n' \
          | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)
  # The loop sits on the right of a pipe and therefore in a subshell. That is
  # harmless here and only here: this function reports on STDOUT and keeps no
  # state across iterations, so nothing it computes has to outlive the subshell.
  { cd "$wt" 2>/dev/null \
    && git -c core.quotePath=false diff -z --name-only "$base" HEAD 2>/dev/null || true; } \
  | while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      covered=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$f" in "$p"|"$p"*) covered=1 ;; esac
      done <<DECL
$decls
DECL
      [ "$covered" = "1" ] || printf '%s\n' "$f"
    done
}

gate_cone_edge() {
  # gate_cone_edge <member> <candidate> — does <candidate> stand on <member>?
  local m="$1" s="$2" cgm cgs d rc=0
  # THE DECLARED AXIS IS ANSWERED FIRST, BEFORE ANYTHING READS A REPOSITORY.
  #
  # It is pure ledger data — no worktree, no git, no object database — so putting
  # it behind the repository probe made it pay for a measurement it does not use,
  # and it lost twice for that. A dependency declared ACROSS repositories was
  # answered by the cross-repository arm below and disappeared from the cone,
  # even though `선행` naming a member is the router stating the dependency on
  # purpose and is the only axis that sees one before the predecessor merges. And
  # when a member's worktree could not be read, the pair was written down as
  # unmeasurable while the declaration sitting right there answered it exactly.
  #
  # Nothing below is weakened by the move: the arms it precedes all answer "does
  # git place these two", and a declaration is not a claim about git.
  for d in $(gate_deps_of "$s"); do
    if [ "$d" = "$m" ]; then return 0; fi
  done

  # A CROSS-REPOSITORY PAIR IS SETTLED WITHOUT ASKING GIT. Commits do not stack
  # across repositories, so such an edge orders work rather than placing it in
  # the cone. Splitting it off first is also what leaves `--is-ancestor`'s 128
  # meaning a genuine fault: without it the commonest benign case and every real
  # failure would arrive as the same number.
  cgm=$(gate_segment_common_git "$m" || true)
  cgs=$(gate_segment_common_git "$s" || true)
  if [ -n "$cgm" ] && [ -n "$cgs" ]; then
    if [ "$cgm" != "$cgs" ]; then return 1; fi
  else
    # ONE SIDE'S REPOSITORY COULD NOT BE READ, and that is settled HERE rather
    # than left to the ancestry probe below.
    #
    # The guard used to require both values to be non-empty, so an unreadable
    # one made it false and control fell through to `gate_ancestor_of` — which
    # returns 2 for the same reason — and the fail-closed arm then accepted the
    # edge. The effect was not one extra segment: a single member whose worktree
    # had been cleaned up (or whose path went stale across a `--resume`) emitted
    # an edge to EVERY candidate, including candidates in other repositories, so
    # the cone became the whole run. That is precisely the run stop a cone exists
    # instead of, and the residual this design accepted is STRUCTURAL
    # under-parking — not unbounded over-parking caused by a fault.
    #
    # The disposition splits by WHICH side is unreadable, because fail-closed is
    # a statement about the candidate:
    #   - the CANDIDATE is unmeasurable → it stays in the cone. Nothing can be
    #     shown about it, and holding one segment is the conservative direction.
    #   - the MEMBER is unmeasurable → no edge. The pair cannot even be placed in
    #     one repository, so "candidate stands on member" is not a question git
    #     was asked and answered; answering it yes for every candidate everywhere
    #     is the failure above. The candidate is still reachable through any
    #     other member that CAN be measured.
    # Either way the fact that it could not be measured is recorded.
    gate_record_undecidable "$m" "$s"
    if [ -z "$cgs" ]; then return 0; fi
    return 1
  fi

  # The ancestor axis — declaration-independent, so it catches stacking nobody
  # wrote down and rebases that pulled a segment in late.
  gate_ancestor_of "$m" "$s" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  gate_record_undecidable "$m" "$s"
  return 0
}

gate_cone_members() {
  # gate_cone_members <anchor> — the cone as of now, one segment id per line.
  #
  #   anchor          the segment that raised the question, unconditionally
  #   defect identity segments sharing a `problem.동일성` with the anchor
  #   file-set escape non-terminal segments that reached outside what they
  #                   declared — seeding rather than anchoring can only WIDEN
  #                   the cone, and widening is the direction already declared
  #                   safe
  #   declared axis   non-terminal segments whose `선행` names a member
  #   ancestor axis   non-terminal segments whose tip has a member's tip as an
  #                   ancestor
  #
  # THE LAST TWO COVER DIFFERENT WINDOWS. Segments branch from the resolved base
  # rather than from one another, so a member's tip being an ancestor means that
  # member has already merged — and the moment a cone typically stands up is
  # before that. In that window the ancestor axis is empty and only the declared
  # axis holds. In the other direction the ancestor axis catches what nobody
  # declared. Building one and calling it done leaves a suite that passes with
  # the main case void.
  local anchor="$1" members grew sid m ident idents
  members=" $anchor "

  # THE FIELD TERMINATOR IS PART OF THE MATCH. A trailing space alone ends the
  # value only when the next character is the separator, so `동일성=로그인 실패 `
  # also matched `동일성=로그인 실패 재현 불가` and pulled a different defect's
  # segments into this cone. `gate_append` writes ` | ` between every pair of
  # fields and always appends `prev=` last, so no field a caller supplies is ever
  # the final one and the pipe is always there to anchor against.
  idents=$( { gate_rows 'problem' | grep -F "세그먼트=$anchor |" || true; } \
            | tr '|' '\n' | sed -n 's/^ *동일성=//p' | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u)
  while IFS= read -r ident; do
    [ -n "$ident" ] || continue
    for sid in $( { gate_rows 'problem' | grep -F "동일성=$ident |" || true; } \
                  | sed -n 's/.*세그먼트=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u); do
      case "$members" in *" $sid "*) continue ;; esac
      # THE SAME TERMINAL FILTER THE OTHER THREE AXES CARRY. This seed loop was
      # the one that did not, so a segment already landed or abandoned was pulled
      # back in on a shared defect identity and held work that had nothing left
      # to wait for. Seeding widens the cone by design; widening it with segments
      # that are finished is not that design, it is the filter being missing from
      # one of four places.
      gate_segment_terminal "$sid" && continue
      members="$members$sid "
    done
  done <<EOF
$idents
EOF

  for sid in $(gate_segment_ids); do
    [ -n "$sid" ] || continue
    case "$members" in *" $sid "*) continue ;; esac
    gate_segment_terminal "$sid" && continue
    [ -n "$(gate_fileset_escape "$sid")" ] || continue
    members="$members$sid "
  done

  grew=1
  while [ "$grew" = "1" ]; do
    grew=0
    for sid in $(gate_segment_ids); do
      [ -n "$sid" ] || continue
      case "$members" in *" $sid "*) continue ;; esac
      gate_segment_terminal "$sid" && continue
      for m in $members; do
        gate_cone_edge "$m" "$sid" || continue
        members="$members$sid "
        grew=1
        break
      done
    done
  done

  for m in $members; do printf '%s\n' "$m"; done
}

gate_record_cone() {
  # gate_record_cone <alias> <키=값>...
  #
  # The row is a RECORD, not the enforcement: membership is recomputed at every
  # cone judgment, so what this leaves behind is what stood up and the command
  # that resumes it. What the gate does NOT do is take the router's declaration
  # on trust.
  local alias="$1"; shift
  local anchor declared derived d missing="" cause
  cause=$(gate_field_of '원인' "$@")
  if [ "$cause" != "막힘" ]; then
    warn "원뿔 행의 「원인」은 「막힘」이어야 합니다 (관측: ${cause:-없음}) — 무효화는 런이 끝났다는 뜻이고 원뿔은 그것이 아닙니다"
    return "$GATE_EXIT_VOCAB"
  fi
  anchor=$(gate_field_of '앵커 세그먼트' "$@")
  if [ -z "$anchor" ]; then
    warn "원뿔 행에 「앵커 세그먼트」가 필요합니다 — 유도가 시작할 자리입니다"
    return "$GATE_EXIT_VOCAB"
  fi
  if [ -z "$(gate_segment_field "$anchor" '상태')" ]; then
    warn "앵커 세그먼트의 segment 행이 없습니다: $anchor — 원장에서 해소되지 않는 앵커로는 원뿔을 세우지 않습니다"
    return "$GATE_EXIT_VOCAB"
  fi

  derived=$(gate_cone_members "$anchor" | tr '\n' ',' | sed 's/,$//')
  if [ -z "$derived" ]; then
    warn "원뿔이 비었습니다 — 앵커조차 들어 있지 않은 원뿔은 기록하지 않습니다"
    return "$GATE_EXIT_VOCAB"
  fi

  # THE FULL LIST GOES SOMEWHERE THE ROW CANNOT HOLD IT. `gate_append` dies over
  # 1024 bytes, and this row carries three Korean free-text fields whose own
  # clip budget is 400 bytes EACH — so the list is the field that has to be
  # bounded, and the morning still needs the whole of it. stderr is where the
  # reader is already looking; the run directory is where a later process can
  # find it.
  local nderived
  nderived=$(printf '%s' "$derived" | tr ',' '\n' | gate_count)
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
    printf '%s\n' "$derived" > "$RUN_DIR/cone.$anchor" 2>/dev/null || true
  fi

  declared=$(gate_field_of '의존 세그먼트' "$@")
  # LENGTH IS JUDGED BEFORE THE SUPERSET, because the two refusals send the
  # reader to different repairs and the length one is the more fundamental: a
  # declaration that cannot be written is not a declaration whose CONTENT is
  # worth reporting on. Refused here rather than inside the writer, whose `die`
  # prescribes "move long values to a sidecar" — something no caller of this
  # verb can do, since declaring the field and omitting it write the same bytes.
  if [ -n "$declared" ] \
     && [ "$(printf '%s' "$declared" | wc -c | tr -d ' ')" -gt "$GATE_CONE_LIST_MAX" ]; then
    warn "선언된 「의존 세그먼트」가 ${GATE_CONE_LIST_MAX} 바이트를 넘습니다 — 원장 행 상한(${GATE_ROW_MAX}) 안에 들어가지 않습니다"
    warn "선언을 생략하면 게이트가 유도한 목록을 경계 있는 형태로 기록하고 전체는 ${RUN_DIR:-<런 디렉터리>}/cone.${anchor} 에 둡니다"
    return "$GATE_EXIT_VOCAB"
  fi
  if [ -n "$declared" ]; then
    # SUPERSET ONLY. Widening passes and narrowing does not, so the lie that
    # would pay — leaving a dependent out so it keeps running on a premise that
    # has been refuted — is the one direction refused.
    for d in $(printf '%s' "$derived" | tr ',' ' '); do
      case ",$declared," in *",$d,"*) ;; *) missing="$missing $d" ;; esac
    done
    if [ -n "$missing" ]; then
      warn "선언된 「의존 세그먼트」가 유도 결과의 진부분집합입니다 — 빠진 것:${missing}"
      return "$GATE_EXIT_GRADE"
    fi
    gate_append 'blocked' "대상=$alias" "$@" "의존 세그먼트 수=$nderived" || return $?
  else
    gate_append 'blocked' "대상=$alias" "$@" "의존 세그먼트 수=$nderived" \
      "의존 세그먼트=$(gate_row_safe "$derived" "$GATE_CONE_LIST_MAX")" || return $?
  fi
  printf 'gate: 원뿔 전체 목록 (앵커 %s · %s개): %s\n' "$anchor" "$nderived" "$derived" >&2
  log "의존 원뿔 기록 — 앵커 $anchor · $nderived 개"
}

# ---------------------------------------------------------------------------
# Judgment approvals — the path grade 2's own refusal used to promise.
# ---------------------------------------------------------------------------
gate_judgment_question() {
  # gate_judgment_question <기준> <근거> — the question text, canonically.
  #
  # ONE PLACE, because the approval's identity and the text a person reads must
  # be derived from the same bytes. They were not: the id hashed `기준` alone
  # while the row carried `기준 — 근거`, so two judgments sharing a short,
  # writer-authored standard were ONE approval however different the rest of the
  # question was.
  gate_row_safe "${1:-미상} — ${2:-근거 없음}" 400
}

gate_judgment_approval_id() {
  # gate_judgment_approval_id <segment> <질문 문면>
  #
  # Derived from the JUDGMENT rather than from an act, so the same judgment
  # submitted twice yields one approval instead of a queue of duplicates. The
  # act variant hashes an argv, and a judgment has none.
  #
  # IT HASHES THE WHOLE QUESTION AND NOT JUST `기준`. A judgment approval has no
  # binding tuple — a question's answer is durable, so there is no tree to
  # re-derive freshness against — which means identity is the ONLY thing
  # separating one answered question from the next. Keyed on `기준`, a short
  # free-text field the submitting side writes, a later judgment that merely
  # reused the phrase inherited the earlier `승인` and was adopted without ever
  # meeting the auto-adoption floor and without anyone reading it. Hashing the
  # text a person actually saw makes the id and the answer inseparable.
  printf 'J-%s' "$(printf '%s|%s|%s' "$RUN_ID" "$1" \
    "$(printf '%s' "$2" | shasum -a 256 | cut -d' ' -f1)" | shasum -a 256 | cut -c1-8)"
}

gate_judgment_approval_disposition() {
  # gate_judgment_approval_disposition <rc> — the issuer's three returns turned
  # into a disposition a caller can act on.
  #
  # THE POINT IS THAT THE SIGNAL STOPS HERE. `GATE_APPROVAL_ANSWERED` is an
  # internal value; the comment beside its declaration says a copy escaping to
  # the shell would tell the router a code the contract never defined, and three
  # callers reached the issuer without translating anything at all. Naming the
  # translation once means a new caller has somewhere to go other than dropping
  # the value.
  case "$1" in
    0) printf '발행' ;;
    "$GATE_APPROVAL_ANSWERED") printf '답있음' ;;
    "$GATE_EXIT_RULE") printf '닫힘' ;;
    *) printf '미상' ;;
  esac
}

gate_issue_judgment_approval() {
  # gate_issue_judgment_approval <alias> <segment> <기준> <근거>
  #
  # THE BINDING TUPLE IS `-`, AND THAT IS THE DIFFERENCE FROM AN ACT APPROVAL.
  # An act approval's answer is valid now and its window closes with the night,
  # so it carries head and base shas and re-derives freshness against the tree
  # it named. A question's answer is an input to work that has not happened yet
  # — it is durable, and there is no tree to measure.
  #
  # THE GATE ISSUES IT AND THE ROUTER CANNOT. The router only ever submits its
  # own recommendation through `act --kind judgment`; whether that becomes a
  # question is decided here.
  local alias="$1" seg="$2" std="$3" why="$4" id q
  q=$(gate_judgment_question "$std" "$why")
  id=$(gate_judgment_approval_id "$seg" "$q")
  # THE ID GOES OUT WITH THE RETURN VALUE. Every one of the three returns below
  # tells a caller WHAT happened and none of them tells it WHICH approval it
  # happened to, so a caller that wants to record the outcome has no id to name
  # and cannot re-derive one — the derivation needs the question text this
  # function built. Exported the way `GATE_ACT_CWD` and `GATE_SURFACE` already
  # are.
  GATE_LAST_JUDGMENT_APPROVAL_ID="$id"; export GATE_LAST_JUDGMENT_APPROVAL_ID
  # THE STATE DECIDES, AND THE FOUR STATES DECIDE DIFFERENTLY. Narrowing to
  # `대기` alone was half the repair: it stopped an answered approval from
  # silently satisfying a re-submission, but everything that was not `대기` then
  # fell through to the append below and RE-OPENED the same id as `대기` again.
  # So an approval a person had closed came back as an open question — the exact
  # loop the id derivation exists to prevent, reached from the other side. A
  # closed approval must not be re-opened by anyone resubmitting the judgment;
  # only a genuinely different question, which hashes to a different id, may open
  # one.
  local st
  st=$(gate_approval_state "$id")
  case "$st" in
    대기)
      log "판단 승인 $id 이 이미 열려 있습니다 — 같은 판단은 승인 하나로 모입니다"
      return 0 ;;
    무효|거부)
      # A CLOSED-NEGATIVE APPROVAL IS AN ANSWER TOO. Re-issuing here would ask
      # the person the same question they already declined, every night, off one
      # refusal they already gave.
      warn "판단 승인 $id 은 이미 '$st' 로 닫혔습니다 — 같은 물음을 다시 열지 않습니다"
      warn "그 판단이 여전히 필요하다면 기준과 근거를 달리한 새 물음으로 올리세요"
      return "$GATE_EXIT_RULE" ;;
    승인)
      # There is an answer on file. Whether it may open THIS judgment depends on
      # whether it has been spent, and that is the caller's question rather than
      # this function's — issuing is what this function does, and here there is
      # nothing to issue.
      return "$GATE_APPROVAL_ANSWERED" ;;
  esac
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=판단" \
    "행위 다이제스트=-" "구속 튜플=-" "막는 세그먼트=${seg:--}" \
    "질문 문면=$q" "답변 문면=-" "발행 시각=$(now_iso)" "해소 시각=-"
  warn "판단 승인 대기 발행 $id — 이 판단은 사람의 답을 기다립니다 (런은 그 옆으로 계속 갑니다)"
}

gate_revert_surface() {
  # gate_revert_surface <되돌리는 법> — the axis-2 grade of the undo command.
  #
  # Prose has no argv0 the table recognises, so it lands on `등급 미상` — which
  # is exactly the discrimination arm (b-1) wants. An undo nobody can run is not
  # an undo, and a reversibility floor that accepts a sentence is a floor made
  # of the claim it was supposed to check.
  [ -n "${1:-}" ] || { printf '등급 미상'; return 0; }
  # Deliberately unquoted: the value is a command line and the table grades its
  # words, argv0 first.
  # shellcheck disable=SC2086
  surface_of_argv0 $1
}

gate_physical_path() {
  # gate_physical_path <경로> — the path with its directory resolved through
  # `pwd -P` and a symlinked final component followed, so that two spellings of
  # one file compare equal.
  #
  # `readlink -f` would do this in one call and is the spelling that differs
  # between the BSD and GNU builds, so the walk is written out. Bounded at eight
  # hops: a symlink cycle is a filesystem a caller can build, and an unbounded
  # follow would hang the gate rather than refuse anything.
  local p="$1" d b link n=0
  d=$(dirname "$p"); b=$(basename "$p")
  [ -d "$d" ] || { printf '%s' "$p"; return 0; }
  p="$(cd "$d" && pwd -P)/$b"
  while [ -L "$p" ] && [ "$n" -lt 8 ]; do
    link=$(readlink "$p" 2>/dev/null) || break
    [ -n "$link" ] || break
    case "$link" in
      /*) p="$link" ;;
      *) p="$(dirname "$p")/$link" ;;
    esac
    d=$(dirname "$p"); b=$(basename "$p")
    [ -d "$d" ] || break
    p="$(cd "$d" && pwd -P)/$b"
    n=$((n + 1))
  done
  printf '%s' "$p"
}

gate_path_spelling() {
  # gate_path_spelling <경로> — the path with redundant separators folded away: a
  # run of `/` becomes one, and a `/./` segment becomes `/`.
  #
  # Sibling of `gate_physical_path`, folding one layer below it. That one makes
  # two spellings of a DIRECTORY compare equal by resolving symlinks; this one
  # makes two spellings of a SEPARATOR compare equal. Arm 2 of the manifest guard
  # compares the caller's own bytes against a value the gate normalized, and those
  # two differ by separators alone whenever a path was built by concatenation:
  # `mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"` on a host whose `TMPDIR` ends in `/`
  # hands back `…/T//x.abc`, while the `cd`+`pwd` normalization at argument-parse
  # time folds the gate's copy to `…/T/x.abc`.
  #
  # Written out rather than delegated to `readlink -f` for the same reason
  # `gate_physical_path` is: that spelling differs between the BSD and GNU builds.
  #
  # Both folds have overlapping matches — `///` leaves a `//` behind, `/././`
  # leaves a `/./` — so this runs to a fixpoint rather than in one pass. Each pass
  # either shortens the string or changes nothing, so the loop terminates.
  local p="$1" prev=''
  while [ "$p" != "$prev" ]; do
    prev=$p
    p=${p//\/\//\/}
    p=${p//\/.\//\/}
  done
  printf '%s' "$p"
}

gate_manifest_write_refuse() {
  # The refusal text, in one place because three arms reach it. Two arms with
  # their own wording would read as two different rules to whoever hits them.
  warn "매니페스트에 쓰려 합니다 — 이 파일은 킥오프만 씁니다: $MANIFEST"
  warn "「## 인가」의 자동 채택 행은 사람이 지켜보는 자리에서만 선언됩니다 — 런이 자기 사전 채택 목록을 늘리는 것은 인가의 자기확장입니다"
}

gate_manifest_write_guard() {
  # gate_manifest_write_guard <graded-surface> <argv...>
  #
  # THE MANIFEST BECAME AN AUTHORIZATION RECORD AND DID NOT GET THE GUARD ONE
  # HAS. `## 인가` now carries `자동 채택` rows, and one more of those means every
  # judgment of that class is adopted with no person and no reversibility
  # requirement — the same KIND of value the grant holds. The grant has a
  # structural guard (`인가-자기확장-금지` refuses any act that writes it); the
  # manifest had none, in this file or in the rule catalog, so an ordinary
  # `워크트리쓰기` act could append to its own pre-adoption list.
  #
  # The rule catalog is the natural home for this and is not reachable: it is an
  # enforcement surface, and a run editing the surface that binds it is the move
  # every other branch here refuses. So the guard lives on the gate's own path,
  # which is the layer this run may change.
  #
  # Shaped exactly like the grant arm it mirrors: any non-read act naming the
  # manifest is refused, whatever the cutpoint. Cutpoints say how far an act may
  # go; this act would change the answer.
  #
  # THREE ARMS, EACH CLOSING A SPELLING THE OTHERS CANNOT SEE. Equality on argv
  # elements had two ways out and both were reachable by ordinary spellings. A
  # different spelling of the same absolute path — an extra `/./`, a relative
  # path — is a different string; that half is closed by normalizing `MANIFEST`
  # at argument-parse time and by resolving both sides physically in arm 3. The
  # other half is not a path problem at all: `bash -c 'printf x >> <경로>'` puts
  # the path INSIDE an argv element, so no element equals the manifest and the
  # loop ran to the end while the redirection wrote the file.
  #
  # What each arm actually measures — spelled out because the sentence that stood
  # here claimed the basename scan by itself caught interpreter wrapping, and
  # measurement showed it caught only the one spelling that writes the path
  # verbatim. That claim was read as a check by someone auditing this guard, who
  # closed a finding on it and had to withdraw the closure:
  #   arm 2  an interpreter's or wrapper's WHOLE command line, against the
  #          basename, the basename's stem, the manifest's directory in three
  #          spellings — logical, physical, and relative to the act's own
  #          directory — and the two variable names. The stem is what catches
  #          `X.plan.m?`, a glob that shares no basename with the file it will
  #          open and need not name the directory at all when the act already
  #          runs there. The directory needles catch the spellings that name a
  #          place instead of a file, `find <디렉터리> … -exec` among them. Saying
  #          where is not the same as spelling it the gate's way, so both sides
  #          are separator-folded first; arm 2 below records what that cost.
  #   arm 3  physical path identity for elements shaped like a path. It is the
  #          only arm that sees an alias symlink, which shares neither basename
  #          nor directory with the file it writes.
  #   last   basename containment, for an element not shaped like a path at all.
  #          This is what refuses `tee …/X.plan.md` today.
  #
  # AND WHAT REMAINS OPEN, in the same breath. Arm 2 fires on an argv0 in its own
  # list, so a wrapper outside that list, reaching the file through a constructed
  # string, is not seen here. The stem needle lives in arm 2 only and not in the
  # basename scan below, so an element that carries the stem without an
  # interpreter around it passes — the measured bypass went through an
  # interpreter, and the scan below is already the arm with known false
  # positives. Those are acts that merely mention a file of that name elsewhere
  # in the tree, a cost kept on purpose rather than traded for the coverage. The
  # act-cwd-relative directory needle is as specific as the manifest's own
  # placement makes it: a manifest one level under the act's directory yields a
  # single-component needle, and every interpreter command naming that component
  # is refused. And none of the arms anchors a rollback: a write that gets past
  # all of them is caught at the next entry, where the binding digest is compared
  # against the frozen set.
  #
  # The false positives this admits are reads that merely MENTION the file, and
  # the read arm above has already returned for those. What is left is an act
  # that changes something and carries the manifest's name in its command line,
  # which is the thing to refuse.
  local graded="$1"; shift
  # NO COMMAND MEANS NOTHING TO GUARD. The arms below read `$1` to classify the
  # act, and under `set -u` an empty argv makes that read fatal rather than
  # falsy — the gate died before it could enumerate its own conditions, which
  # reads as the run being broken rather than as this call having nothing to do.
  [ "$#" -ge 1 ] || return 0
  [ -n "${MANIFEST:-}" ] || return 0
  # THE READ GRADE IS NOT A PASS FOR A COMMAND THAT DELEGATES. `find` grades
  # `읽기` from argv0 alone, so `find <디렉터리> … -exec sh -c 'printf x >> {}' \;`
  # arrived here declared and graded as a read, returned on this line, and the
  # guard never looked at the argv that was about to write. The self-declaration
  # check cannot catch it either: the declaration MATCHES the grade, and both are
  # wrong about the same command.
  #
  # Two axes decide, not one — whether the argv carries a primary that executes
  # or deletes, and whether argv0 is a wrapper that runs some other command.
  # `find` is deliberately NOT in the argv0 list: a plain `find` with no primary
  # has to keep returning here, or every read that walks the manifest's directory
  # becomes a refusal.
  case "$graded" in
    읽기)
      case " $* " in
        *" -exec "*|*" -execdir "*|*" -ok "*|*" -okdir "*|*" -delete "*) ;;
        *)
          case "${1##*/}" in
            command|env|xargs|lockf|nice|nohup|time|timeout|stdbuf) ;;
            *) return 0 ;;
          esac ;;
      esac ;;
  esac
  local a mbase mstem mdir mdirp mreal adir areal joined argv0 joinedn
  local mdirn mdirpn mdirrel actcwdn
  mbase=$(basename "$MANIFEST")
  [ -n "$mbase" ] || return 0
  mdir=$(dirname "$MANIFEST")
  # BOTH SPELLINGS OF THE DIRECTORY, because arm 2 matches the caller's own
  # bytes and the caller may have written either one. `MANIFEST` is normalized
  # logically, so on a host where the temp or state root is itself a symlink the
  # physical spelling is a different string that names the same directory.
  #
  # A FALLBACK AND NOT AN OVERWRITE. Arm 2 now tests three needles instead of
  # one, and an empty needle matches every command line — so a `pwd -P` that
  # returns nothing would turn this guard into a refusal of everything. Each
  # needle is screened for emptiness below as well; this keeps the value itself
  # from ever being the empty one.
  mdirp=$(cd "$mdir" 2>/dev/null && pwd -P) || mdirp="$mdir"
  [ -n "$mdirp" ] || mdirp="$mdir"

  # ARM 2 — AN INTERPRETER HIDES THE PATH OPERAND, SO THE WHOLE COMMAND LINE IS
  # THE OPERAND. `bash -c` takes a program, not arguments: there is no element to
  # resolve and no way to tell which bytes of it will become a filename. So the
  # test here is containment over the joined argv, and it is deliberately wider
  # than the one below — the manifest's DIRECTORY counts, not only its basename.
  #
  # The directory is what closes the glob spelling. `…/X.plan.m?` shares no
  # basename with `X.plan.md`, but a glob that is going to reach the file has to
  # say where the file is. The environment variable names are here for the same
  # reason one step earlier: `printf x >> "$CC_PIPELINE_MANIFEST"` never spells
  # the path at all.
  #
  # HAVING TO SAY WHERE IS NOT HAVING TO SPELL IT THE GATE'S WAY. The sentence
  # that stood here said the glob "names the same directory verbatim", and that
  # was measured false in this very tree: the caller's bytes carried `…/T//x.abc`
  # — a `TMPDIR` ending in `/` fed straight into a `mktemp` template, which
  # `mktemp` returns as given — while the gate held `…/T/x.abc`, folded by the
  # `cd`+`pwd` normalization at argument-parse time. Same directory, different
  # spelling, containment missed, and the glob went through with the two other
  # arms blind to it by construction. The physical spelling `mdirp` did not help:
  # it was added for a symlinked root, which is a different divergence.
  #
  # So both sides go through `gate_path_spelling` before the comparison. That
  # closes every duplicate- and dot-separator spelling of this arm at once —
  # `//`, `///`, `/./` all fold to the same bytes — rather than the one glob that
  # happened to be measured. The basename and variable-name tests carry no
  # separator and are left on the raw bytes.
  # THE LIST IS INTERPRETERS AND WRAPPERS, for one reason. A wrapper cannot say
  # which bytes of its tail will become a filename any more than `bash -c` can,
  # so the whole command line is the operand there too. `find` is here because
  # `find <매니페스트 디렉터리> … -exec` reaches the file through an element that
  # is neither the manifest's path nor its basename; `lockf` is here because
  # three unattended skills MANDATE it around every document write, which made it
  # a wrapper the guard was guaranteed to meet.
  #
  # Applying arm 2 to every argv0 was measured and REJECTED: the directory needle
  # then fires on an unrelated file that merely lives beside the manifest, which
  # is an upper bound this suite already holds green.
  argv0=${1##*/}
  case "$argv0" in
    bash|sh|zsh|dash|ksh|python|python3|perl|ruby|node|npx|make|env|xargs|find|lockf|command|nice|nohup|time|timeout|stdbuf)
      joined=$(printf '%s ' "$@")
      case "$joined" in *"$mbase"*|*CC_PIPELINE_MANIFEST*|*MANIFEST*)
        gate_manifest_write_refuse; return "$GATE_EXIT_RULE" ;;
      esac
      # THE STEM ERASES THE ABSOLUTE/RELATIVE DISTINCTION. A glob one character
      # short of the basename shares no basename, and it need not spell the
      # directory at all when the act already runs there — so both needles above
      # and the directory needles below look past `printf x >> <이름>.plan.m?`
      # written from the manifest's own directory. The stem is the part of the
      # name a glob cannot drop while still opening the file, and it appears in
      # the command line however the caller spelled the path.
      #
      # Cut at the LAST dot, not the first. A manifest named `<런 id>.plan.md`
      # cut at the first dot yields the run id, which is also the run
      # directory's basename — and then every command mentioning the run
      # directory is refused. Screened for emptiness and for equality with the
      # basename: a name with no dot yields the basename back, and testing it
      # twice is a needle that costs a pass and buys nothing.
      mstem=${mbase%.*}
      case "$mstem" in
        ''|"$mbase") ;;
        *) case "$joined" in *"$mstem"*)
             gate_manifest_write_refuse; return "$GATE_EXIT_RULE" ;;
           esac ;;
      esac
      joinedn=$(gate_path_spelling "$joined")
      mdirn=$(gate_path_spelling "$mdir")
      mdirpn=$(gate_path_spelling "$mdirp")
      # THE DIRECTORY AS THE ACT WOULD SPELL IT. Both spellings above are
      # absolute, and an act running inside the tree writes the relative one.
      # The needle is built only when the act's directory is an ANCESTOR of the
      # manifest's, so there is no path by which it takes a value from another
      # repository or another worktree.
      mdirrel=''
      if [ -n "${GATE_ACT_CWD:-}" ]; then
        actcwdn=$(gate_path_spelling "$GATE_ACT_CWD")
        case "$mdirn" in "$actcwdn"/*) mdirrel=${mdirn#"$actcwdn"/} ;; esac
      fi
      # ONE SENTINEL PER NEEDLE, WHICH IS THE PREMISE OF WIDENING AT ALL. The
      # single screen that stood here read `mdirn` and then tested `mdirpn`
      # beside it, so an empty physical spelling refused every act while the
      # screen reported itself satisfied. With three needles the same hole is
      # three holes. Written as three blocks rather than a loop over a list:
      # this file has to run under bash 3.2, where arrays are the thing that
      # quietly differs.
      case "$mdirn" in
        ''|'/'|'.') ;;
        *) case "$joinedn" in *"$mdirn"*)
             gate_manifest_write_refuse; return "$GATE_EXIT_RULE" ;;
           esac ;;
      esac
      case "$mdirpn" in
        ''|'/'|'.') ;;
        *) case "$joinedn" in *"$mdirpn"*)
             gate_manifest_write_refuse; return "$GATE_EXIT_RULE" ;;
           esac ;;
      esac
      case "$mdirrel" in
        ''|'/'|'.') ;;
        *) case "$joinedn" in *"$mdirrel"*)
             gate_manifest_write_refuse; return "$GATE_EXIT_RULE" ;;
           esac ;;
      esac
      ;;
  esac

  # ARM 3 — PATH IDENTITY, RESOLVED PHYSICALLY ON BOTH SIDES. An element shaped
  # like a path is resolved the same way the manifest is and compared as a file
  # rather than as a string, so a symlinked directory in the path — or an alias
  # symlink pointing AT the manifest under some other name — is the manifest
  # here. The alias case is the one no other arm can reach: it shares neither
  # basename nor directory with the file it writes.
  #
  # Both sides are resolved in this function rather than trusting the value
  # normalized at argument-parse time. A comparison where only one side followed
  # symlinks is a comparison of spellings again, which is what all of this is
  # for.
  mreal=$(gate_physical_path "$MANIFEST")
  for a in "$@"; do
    case "$a" in */*) ;; *) continue ;; esac
    adir=$(dirname "$a")
    [ -d "$adir" ] || continue
    areal=$(gate_physical_path "$a")
    [ "$areal" = "$mreal" ] || continue
    gate_manifest_write_refuse
    return "$GATE_EXIT_RULE"
  done

  # THE BASENAME CONTAINMENT SCAN STAYS, BEHIND THE TWO ARMS ABOVE. It is the
  # only one of the three that catches a manifest name carried by an element
  # that is not shaped like a path at all, and it is what refuses `tee` on the
  # ordinary spelling today. Its cost is refusing acts that merely mention a
  # file of that name elsewhere in the tree, which is a false positive this
  # keeps rather than trade for the coverage.
  for a in "$@"; do
    case "$a" in *"$mbase"*) ;; *) continue ;; esac
    gate_manifest_write_refuse
    return "$GATE_EXIT_RULE"
  done
  return 0
}

gate_autoadopt_ok() {
  # gate_autoadopt_ok <판단 부류> <되돌리는 법> — 0 adopt, non-zero escalate.
  #
  # THE FLOOR IS A UNION AND NOT AN INTERSECTION. Either arm alone admits. Under
  # an intersection even a class the manifest declared in advance would still
  # have to produce an undo command, so the night would stand in front of MORE
  # questions rather than fewer — which inverts what the floor is for.
  #
  # ONE IMPLEMENTATION, TWO CALLERS. The router submits judgments through
  # `act --kind judgment`; a stage has no verb at all and emits its judgment in
  # its terminal message. If the emitted path had its own copy of the floor, that
  # copy is the one that would drift into being the loose one, and a stage would
  # then adopt by emitting — which is this design routed around wholesale rather
  # than one check missed.
  local cls="$1" revert="$2" line mcls
  case "$cls" in '') return 1 ;; esac

  # THE FORBIDDEN CLASSES FALL OUT BEFORE EITHER ARM.
  #
  # `judgment_class_forbidden` had exactly one caller — `check_manifest`'s rule
  # 11 — and that one guards arm (a) only. Arm (b) branches on the argv0 grade
  # of the undo command and nothing else, so `판단 부류=시각-면제` with
  # `되돌리는 법=git checkout -- tests/visual/` was ADOPTED at runtime while
  # declaring the same class in the manifest is a hard stop. The whole mechanical
  # defence of "a decision that hands risk to the user" sat at freeze time, and
  # the runtime path walked around it.
  #
  # The disposition is ESCALATION and not row refusal. Recording a judgment of a
  # forbidden class is allowed by the contract; what is forbidden is adopting one
  # without a person. Returning non-zero routes to
  # `gate_issue_judgment_approval`, and that is what "a person decides this"
  # means here. Placed before both arms so a manifest declaration cannot admit
  # one either — the two guards then agree instead of contradicting.
  if judgment_class_forbidden "$cls"; then
    warn "자동 채택 불성립 — 「${cls}」 는 미리 채택할 수 없는 판단 부류입니다 (위험을 사용자에게 넘기는 결정)"
    warn "이 판단은 거절되지 않고 승인으로 올라갑니다 — 기록은 허용이고 무인 채택만 금지입니다"
    return 1
  fi

  # Arm (a) — declared in advance. What makes this input one a run cannot forge
  # is now stated as what it IS rather than as four claims two of which were
  # false. It holds on three legs: `## 인가` must be exactly one section and this
  # scan reads only that section; the binding digest serializes these rows, so
  # appending one moves the digest and `check_manifest` refuses at the next gate
  # entry; and `gate_manifest_write_guard` refuses an act that writes the
  # manifest at all.
  #
  # The residual is stated rather than papered over: the manifest has no
  # ROLLBACK-proof anchor outside itself — both sides of the digest comparison
  # are read from the same file — so the guarantee is that a write is refused and,
  # failing that, detected at the next act. It is not that a write is impossible.
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      mcls=$(printf '%s' "$line" | tr '|' '\n' | sed -n 's/^ *판단 부류=//p' | sed 's/[[:space:]]*$//' | tail -1)
      if [ "$mcls" = "$cls" ]; then
        log "자동 채택 — 팔 (a) 사전 선언 ($cls)"
        return 0
      fi
    done <<EOF
$(manifest_autoadopt_rows)
EOF
  fi

  # Arm (b) — reversible. The undo command's first token goes through the same
  # argv0 grading table every act goes through, so prose lands on `등급 미상`
  # and falls out here. The distinction that buys is between ASSERTING that
  # something is reversible and PRODUCING the thing that reverses it.
  #
  # THE ACCEPTED SET IS THE WORKTREE-WRITE GRADE ALONE, AND `읽기` IS NOT IN IT.
  # A command that reverses something CHANGES something — that is what reversing
  # is. `읽기` was the most permissive arm here while naming the grade with the
  # least power to undo anything: the first row of the grading table reads
  # `cat|ls|find|grep|…` as `읽기`, so `되돌리는 법=ls docs/` admitted a judgment
  # on the strength of an undo that cannot undo. There was no upper bound either,
  # but the upper end is the side an author has no incentive to reach — the
  # cheap, quiet spelling is a read, and it was the one being accepted.
  #
  # The grades above `워크트리쓰기` stay out for the reason they always did: an
  # undo that writes outside the tree or changes external state is not something
  # to adopt without a person, whatever it claims to reverse.
  case "$(gate_revert_surface "$revert")" in
    워크트리쓰기)
      # The second half of arm (b) — the act being at or below the target's
      # cutpoint — is `절단점-준수`'s, and that rule carries a lower order index,
      # so arriving here IS that condition holding.
      log "자동 채택 — 팔 (b) 가역 ($cls · $revert)"
      return 0 ;;
  esac
  warn "자동 채택 불성립 — 부류 '$cls' 는 매니페스트가 선언하지 않았고 되돌리는 법이 워크트리를 되돌리는 명령이 아닙니다"
  return 1
}

gate_judgment_fields_ok() {
  # gate_judgment_fields_ok <키=값>... — the vocabulary floor for a judgment
  # row. Its caller runs it BEFORE the auto-adoption floor, not after.
  #
  # ORDER IS THE POINT. The floor is consulted on every grade-1 judgment, and a
  # row missing a required field fails it for the wrong reason — arm (a) has no
  # class to match and arm (b) has no undo command to grade — so a MALFORMED row
  # came back as "a person has to answer this", exit 5, with an approval written
  # for a question nobody asked. The most fundamental reason that holds must
  # win, and a missing field is more fundamental than an unmet floor.
  #
  # THE TWO NEW FIELDS ARE REQUIRED AT GRADE 1 AND NOWHERE ELSE. `판단 부류` has
  # exactly one consumer — arm (a) of that floor — and the floor runs only when
  # the grade is 1; `되돌리는 법` is read by arm (b) and by the morning's account
  # of what can be undone. A grade-2 judgment reaches neither, because it goes to
  # a person. Demanding them there would make ESCALATING a decision harder than
  # adopting one, which is the wrong polarity, and it would strand a router
  # mid-run for a field neither of its escalations can use.
  local jk jcls jgrade
  jgrade=$(gate_field_of '등급' "$@")
  for jk in '등급' '기준' '근거'; do
    [ -n "$(gate_field_of "${jk}" "$@")" ] \
      || { warn "판단 행에 「${jk}」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
  done
  # The grade vocabulary itself is NOT decided here — `gate_record_row` owns it,
  # and it is the one place that knows what each grade does next. What this
  # function reads the grade for is which fields the row must carry.
  [ "$jgrade" = "1" ] || return 0
  for jk in '되돌리는 법' '판단 부류'; do
    [ -n "$(gate_field_of "${jk}" "$@")" ] \
      || { warn "판단 행에 「${jk}」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
  done
  # `판단 부류` and NOT `자율 승인.kind`. That field has never carried a
  # classification — its declared tokens appear zero times in the artifacts and
  # what does land there is the act kind — and the ledger is append-only, so the
  # rows already written can never be repaired. Arm (a) asks whether the manifest
  # declared this class in advance; on a field that also carries the act kind,
  # one manifest line would pre-adopt every stage dispatch there is.
  jcls=$(gate_field_of '판단 부류' "$@")
  if ! judgment_class_ok "$jcls"; then
    warn "판단 행의 「판단 부류」가 어휘 밖입니다: $jcls — 허용: $JUDGMENT_CLASSES"
    return "$GATE_EXIT_VOCAB"
  fi
  return 0
}

gate_record_row() {
  # gate_record_row <kind> <segment-id> <target-alias> <키=값>...
  #
  # The alias is a parameter and not a global because two of the arms below
  # issue an approval, and an approval row names the target it blocks.
  #
  # The router's writer for the two row kinds the fixed graph used to own. This
  # is not bookkeeping polish. With no writer on this path `리뷰-후-머지` refuses
  # EVERY merge — not because a review is missing but because the row it reads
  # can never exist, so no argv, no ordering and no preparatory act satisfies it
  # — and termination condition 1 can never hold, so the run has no ending it is
  # able to propose. Both failures read as the mechanism working, which is why
  # the absence stayed invisible until a run tried to finish.
  local kind="$1" seg="$2" alias="$3"; shift 3
  local f k

  # `blocked` is the exception, and it has to be: the row it resolves is
  # run-scope, so demanding a segment would make the one kind that describes the
  # WHOLE run unwritable without naming a part of it. `obligation` is exempt for
  # the opposite reason — it HAS a segment and reads it from the row it closes,
  # so asking the router to name one again only creates a way for the two to
  # disagree.
  if [ "$kind" != "blocked" ] && [ "$kind" != "clause" ] && [ "$kind" != "judgment" ] \
     && [ "$kind" != "obligation" ] \
     && { [ -z "$seg" ] || [ "$seg" = "-" ]; }; then
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
        계획됨|실행중|리뷰중|머지됨|완료|park|'적용 준비') : ;;
        *) warn "segment 행의 「상태」가 어휘 밖입니다: ${st:-없음} — 계획됨 실행중 리뷰중 머지됨 완료 「적용 준비」 park"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      # `리뷰-후-머지` resolves the branch's current HEAD by entering this value,
      # so a segment row without it turns a merge refusal into one that names a
      # missing worktree instead of the review — the wrong repair at 3am.
      [ -n "$wt" ] || { warn "segment 행에 「워크트리」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }

      # `선행` — the declared axis of the cone, and the two floors the ledger can
      # hold on its own. The superset check cannot supply them: it compares the
      # router's cone declaration against the gate's derivation, and `선행` is
      # now an INPUT to that derivation, so declaring narrowly shrinks both sides
      # together and the comparison notices nothing.
      local deps prior prev_deps d nseg
      deps=$(gate_field_of '선행' "$@")
      prior=$( { gate_rows 'segment' | grep -F "id=$seg " || true; } | tail -1)
      nseg=$(gate_segment_count_including "$seg")

      # ABSENCE AND `없음` ARE DIFFERENT THINGS, and write time is the only
      # moment at which the difference exists — read later they are the same
      # empty set. `없음` is a positive statement of independence; a missing
      # field is a writer who did not consider the question. A repository
      # carrying one segment is not asked, because there is nothing there for it
      # to depend on.
      if [ -z "$deps" ] && [ "${nseg:-0}" -ge 2 ]; then
        warn "세그먼트가 둘 이상인 레포의 segment 행에는 「선행」이 필요합니다 — 독립이면 「선행=없음」이라고 적으세요"
        warn "부재와 「없음」은 다릅니다: 조용한 누락이 적는 쪽에게 들리는 거절이 되는 자리가 여기뿐입니다"
        return "$GATE_EXIT_VOCAB"
      fi

      # MONOTONE PER SEGMENT ID. Rows are append-only and the last row wins, so
      # the lie that pays is retroactive — narrowing `선행` AFTER the predecessor
      # parks takes this segment out of the cone. A later row may ADD and may not
      # REMOVE, which is the same polarity every other check here uses.
      # BOTH SIDES THROUGH ONE NORMALIZATION. Comparing a whitespace-stripped
      # haystack against comma-split needles made the floor reject values its
      # own reader accepts, and matched `없음` only as a whole value — see
      # `gate_dep_tokens` for what each of those cost.
      local cur_deps
      cur_deps=$(gate_dep_tokens "$deps")
      if [ -n "$prior" ]; then
        prev_deps=$(gate_dep_tokens "$(gate_row_field "$prior" '선행')")
        for d in $prev_deps; do
          case " $cur_deps " in
            *" $d "*) ;;
            *) warn "「선행」은 세그먼트마다 단조롭습니다 — 앞선 행의 '$d' 가 이번 행에 없습니다 (더할 수는 있어도 뺄 수 없습니다)"
               return "$GATE_EXIT_VOCAB" ;;
          esac
        done
      fi

      # EVERY TOKEN NAMES A SEGMENT THIS LEDGER KNOWS, checked at write time.
      # `선행` is monotone, so a token that resolves to nothing is not a typo the
      # next row can correct: it is permanently required and permanently
      # un-landable, and the failure surfaces much later as "the predecessor has
      # not landed (상태=없음)", which sends the reader to look for a segment
      # rather than at the spelling. Refusing here lets the message say the true
      # thing — there is no such segment — at the moment it is cheap.
      local known
      known=" $(gate_segment_ids | tr '\n' ' ') $seg "
      for d in $cur_deps; do
        case "$known" in
          *" $d "*) ;;
          *) warn "「선행」이 지목한 세그먼트가 원장에 없습니다: '$d' — 그런 세그먼트는 착지할 수 없고 「선행」은 단조로우므로 이 행을 쓰면 되돌릴 수 없습니다"
             warn "선행 세그먼트의 segment 행을 먼저 쓰거나, 의존이 없다면 「선행=없음」이라고 적으세요"
             return "$GATE_EXIT_VOCAB" ;;
        esac
      done

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
    clause)
      # SETTLING ONE AUTHORIZED TERMINATION CLAUSE. The manifest holds the
      # question and this row holds the answer, so condition 10 can be decided
      # from the ledger rather than from a rationale's wording.
      local cid cst
      cid=$(gate_field_of 'id' "$@")
      cst=$(gate_field_of '상태' "$@")
      [ -n "$cid" ] || { warn "종료 절 행에 「id」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      case " $(gate_clause_ids | tr '\n' ' ') " in
        *" $cid "*) : ;;
        *) warn "매니페스트에 없는 종료 절입니다: ${cid}"; return "$GATE_EXIT_VOCAB" ;;
      esac
      case "$cst" in
        충족|불가능) : ;;
        보류)
          # A CLAUSE HANDED TO THE NEXT RUN, and its disposition is not
          # `불가능`'s. Impossible ends the clause forever; on hold says a
          # person's answer is outstanding and the successor picks it up. So the
          # evidence has to BE that outstanding question — an open approval
          # whose cutpoint is the literal `판단`, found in the ledger rather than
          # asserted in the wording.
          #
          # THE WHOLE SET, AND NOT THE LAST MATCH. The collection loop below used
          # to overwrite one variable on every hit, so a rationale naming two
          # approvals was checked against one of them — the last — and the other
          # could hold a second clause with nothing objecting. The extraction is
          # a function now because the `done` file's reporter has to derive its
          # answer from the same bytes; two expressions over one field is how the
          # gate came to check an id the morning never saw and report one the gate
          # never measured.
          local cev jid ojid cev_ids other last_other other_ids
          cev=$(gate_field_of '근거' "$@")
          cev_ids=$(gate_clause_evidence_ids "$cev")
          if [ -z "$cev_ids" ]; then
            warn "「보류」인 종료 절의 「근거」는 열려 있는 절단점=판단 승인 id 를 지목해야 합니다 (관측: ${cev:-없음})"
            return "$GATE_EXIT_VOCAB"
          fi
          # EVERY named id must be open, not merely one of them. A rationale that
          # names an answered approval beside an open one would otherwise settle
          # the clause on the strength of the open one while telling the morning
          # it waits on both.
          for jid in $cev_ids; do
            gate_judgment_approval_open "$jid" && continue
            warn "「보류」인 종료 절의 근거가 지목한 ${jid} 은 열려 있는 절단점=판단 승인이 아닙니다"
            return "$GATE_EXIT_VOCAB"
          done
          # ONE QUESTION HOLDS ONE CLAUSE.
          #
          # Condition 10 is the only one of the ten that measures what the USER
          # authorized the run against, and `보류` settles a clause for it — so
          # with no constraint here a single grade-2 judgment, submitted once,
          # could be cited by every clause in the manifest and the run would
          # propose `done` with nothing actually settled. The morning would read
          # a run that ended with one open question, which is a state the design
          # deliberately permits, while none of the authorized clauses had been
          # met.
          #
          # Distinctness is the floor rather than "the question must name the
          # clause": the gate can verify that two clauses do not lean on one
          # answer, and it cannot verify that a free-text question is ABOUT a
          # clause. What it refuses is the amplification — one answer excusing
          # many obligations — which is the whole of the failure.
          for other in $(gate_clause_ids); do
            [ -n "$other" ] || continue
            [ "$other" = "$cid" ] && continue
            last_other=$( { gate_rows '종료 절' | grep -F "id=$other " || true; } | tail -1)
            [ -n "$last_other" ] || continue
            [ "$(gate_row_field "$last_other" '상태')" = "보류" ] || continue
            other_ids=$(gate_clause_evidence_ids "$(gate_row_field "$last_other" '근거')")
            for jid in $cev_ids; do
              for ojid in $other_ids; do
                [ "$jid" = "$ojid" ] || continue
                warn "승인 ${jid} 은 이미 종료 절 ${other} 을 보류시키고 있습니다 — 답 하나가 여러 절을 정산할 수 없습니다"
                warn "이 절을 보류하려면 이 절에 대한 물음을 따로 올리세요 (조건 10 은 사용자가 인가한 것을 재는 유일한 조건입니다)"
                return "$GATE_EXIT_VOCAB"
              done
            done
          done ;;
        *) warn "종료 절 행의 「상태」는 충족·불가능·보류 중 하나여야 합니다 (관측: ${cst:-없음})"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      # Evidence is a ledger reference or an observable artifact, never prose —
      # a clause settled by assertion is the same hollow value the whole
      # contract exists to remove.
      [ -n "$(gate_field_of '근거' "$@")" ] \
        || { warn "종료 절 행에 「근거」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      gate_append '종료 절' "$@"
      log "종료 절 정산 — $cid ($cst)"
      ;;
    judgment)
      # GRADE 1, WHICH HAD NO WRITER. The contract and the kickoff both say a
      # grade-1 judgment is adopted together with a row carrying `등급`·`기준`·
      # `되돌리는 법`, and the gate had no entry point for one: the three places
      # that append `자율 승인` are all the gate judging an ACT, `등급=` appears
      # once and is hard-coded to 0, and `되돌리는 법=` once with a fixed value.
      # So the autonomous decisions a night is made of left no trace, and the
      # morning report's whole premise — that they are cheap to undo because
      # they are written down — had nothing to stand on.
      # The field floor is per grade and lives in one place, because the acting
      # path has to apply it BEFORE the auto-adoption floor reads those same
      # fields — see `gate_judgment_fields_ok`.
      local jcls jgrade
      gate_judgment_fields_ok "$@" || return "$GATE_EXIT_VOCAB"
      jcls=$(gate_field_of '판단 부류' "$@")
      jgrade=$(gate_field_of '등급' "$@")
      case "$jgrade" in
        1) : ;;
        2)
          # THE PATH THE OLD REFUSAL PROMISED. It said in as many words that
          # grade 2 is raised to an approval, while refusing — and no such path
          # existed anywhere in the tree, so the one grade whose entire
          # definition is "a person decides this" had nowhere to go but a
          # vocabulary error.
          #
          # AND THE PATH BACK, WHICH IS WHAT WAS MISSING. Raising the question
          # was only half a lifecycle: a grade-2 judgment never reaches the
          # resolution block on the acting path (that block runs only when the
          # auto-adoption floor escalated, and the floor is consulted for grade 1
          # alone), so once the person answered there was no arm that noticed.
          # Every re-submission came back here and asked again. Reading the
          # state BEFORE issuing is what turns an answer into an adoption.
          local jq_id jq_st jq_rc=0
          jq_id=$(gate_judgment_approval_id "$seg" \
                  "$(gate_judgment_question "$(gate_field_of '기준' "$@")" "$(gate_field_of '근거' "$@")")")
          jq_st=$(gate_approval_state "$jq_id")
          if [ "$jq_st" = "승인" ]; then
            # ONE ANSWER OPENS ONE JUDGMENT, the same floor the acting path
            # applies. A judgment approval carries no binding tuple, so nothing
            # about it expires — without this the first answer would adopt every
            # later judgment that hashed to the same id.
            if gate_has_row '자율 승인' "해소 승인=$jq_id "; then
              warn "승인 $jq_id 은 이미 한 번 채택에 쓰였습니다 — 답 하나는 판단 하나를 엽니다"
              warn "같은 기준으로 다른 판단을 올리는 것이라면 새 질문으로 다시 물어야 합니다"
              return "$GATE_EXIT_RULE"
            fi
            log "승인 $jq_id 이 해소되어 이 판단을 채택으로 엽니다"
            GATE_RESOLVED_APPROVAL="$jq_id"
          else
            gate_issue_judgment_approval "$alias" "$seg" \
              "$(gate_field_of '기준' "$@")" "$(gate_field_of '근거' "$@")" || jq_rc=$?
            # THROUGH THE TRANSLATION, not around it. Propagating the raw value
            # sent the router exit 9 for an answered-but-spent approval, which
            # is the one code the contract does not define. `이미 닫힌 물음` and
            # `이미 쓰인 답` are both refusals of this submission, so both leave
            # as the rule refusal the router already knows.
            case "$(gate_judgment_approval_disposition "$jq_rc")" in
              발행) return "$GATE_EXIT_APPROVAL" ;;
              *) return "$GATE_EXIT_RULE" ;;
            esac
          fi ;;
        *) warn "판단 행은 등급 1 과 2 만 받습니다 — 0 은 기록이 필요 없습니다 (관측: ${jgrade:-없음})"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      # `해소 승인` NAMES THE ANSWER THAT OPENED THIS ADOPTION, and `-` says the
      # floor admitted it on its own. Without the field there is no way to ask
      # whether an answer has already been spent, and a judgment approval has no
      # binding tuple to expire — so one answered question opened every later
      # judgment that hashed to the same id.
      gate_append '자율 승인' "kind=judgment" "결정=채택" "세그먼트=${seg:--}" \
        "해소 승인=${GATE_RESOLVED_APPROVAL:--}" "$@"
      # The grade is read from the row rather than hard-coded: a grade-2 judgment
      # whose question has been answered lands here too, and a line claiming
      # grade 1 for it would misdescribe the one event the morning most needs to
      # tell apart — an adoption the floor admitted on its own from one a person
      # opened.
      # `부류` may legitimately be empty here: it is required at grade 1 alone,
      # because its only consumer is the auto-adoption floor and a grade-2
      # judgment never reaches that floor — it reaches a person.
      log "판단 등급 $jgrade 기록 — 부류 ${jcls:-없음}"
      ;;
    blocked)
      # THE ROUTER MAY RESOLVE A RUN-SCOPE BLOCK, AND MAY NOT CREATE ONE. Blocks
      # are raised by the gate itself — the surface check and the watcher's
      # transcription — so a router that could write an arbitrary one would be
      # inventing the very state that governs whether the run may end. What it
      # gets is the other half, which nothing had: the disposition of a stall
      # observation is the router's job, and until now that job had no verb.
      #
      # `스코프=cone` IS THE OTHER HALF, and its polarity is the opposite one:
      # the router MAY create a cone. A cone is not a run stop — it holds what
      # stands on a refuted premise and lets the siblings keep going — which is
      # exactly the disposition an open question needs and the one nothing could
      # express. The gate does not take the declaration on trust: it derives the
      # cone itself and refuses a declaration that is narrower.
      local why cause prior scope
      scope=$(gate_field_of '스코프' "$@")
      # AN ABSENT SCOPE MEANS `run`, and that default is compatibility rather
      # than convenience. Before the cone existed the resolution form carried no
      # scope at all — `act --kind blocked -- 원인=해소 사유=… 근거=…` — because
      # `run` was the only thing a router could resolve, and the arm wrote the
      # field itself. Making the field required turned every existing caller of
      # that form into an exit 2, which is the same shape as the two open issues
      # about a newly required field invalidating runs already in flight. The
      # vocabulary check still runs; it just runs on a value that is filled in.
      [ -n "$scope" ] || scope=run
      why=$(gate_field_of '사유' "$@")
      cause=$(gate_field_of '원인' "$@")
      gate_check_scope "$scope" || return "$GATE_EXIT_VOCAB"
      [ -n "$why" ] || { warn "blocked 행에 「사유」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      [ -n "$(gate_field_of '근거' "$@")" ] \
        || { warn "blocked 행에 「근거」가 필요합니다 — 무엇을 보고 해소로 판정했는지가 아침에 남는 전부입니다"; return "$GATE_EXIT_VOCAB"; }
      if [ "$scope" = "cone" ]; then
        gate_record_cone "$alias" "$@" || return $?
        return 0
      fi
      if [ "$scope" != "run" ]; then
        warn "라우터가 쓸 수 있는 blocked 스코프는 run(해소)과 cone(원뿔)뿐입니다 — act 스코프 막힘은 게이트가 씁니다 (관측: ${scope})"
        return "$GATE_EXIT_VOCAB"
      fi
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
    obligation)
      # THE ONLY EXIT FROM TERMINATION CONDITION 9. `리뷰 의무` rows are written
      # in exactly one place and always as `상태=미이행`, nothing in the tree
      # wrote `상태=이행`, and the router's row-writing kinds did not include the
      # series — so the condition held against every run that ever deferred a
      # review, and no such run could propose that it was done. Condition 3's
      # excusal is for a different series and does not reach this one. The
      # refusal read as the mechanism working, which is why it survived until a
      # run tried to finish.
      #
      # Fulfilling is an APPEND, not an edit: the reader takes the LAST row per
      # obligation id, so the issuing row stays where it is and the morning can
      # still see both when the review was deferred and when it landed.
      local oid oprior ost
      oid=$(gate_field_of '의무 id' "$@")
      [ -n "$oid" ] || { warn "의무 행에 「의무 id」가 필요합니다"; return "$GATE_EXIT_VOCAB"; }
      # Evidence, on the same terms the `blocked` arm already demands it. An
      # obligation closed on the router's say-so is a review that did not happen
      # and left a row saying it did — which is worse than leaving it open,
      # because the open one is at least visible in the morning.
      [ -n "$(gate_field_of '근거' "$@")" ] \
        || { warn "의무 행에 「근거」가 필요합니다 — 무엇을 보고 이행으로 판정했는지가 아침에 남는 전부입니다"; return "$GATE_EXIT_VOCAB"; }
      oprior=$( { gate_rows '리뷰 의무' | grep -F "의무 id=$oid " || true; } | tail -1)
      if [ -z "$oprior" ]; then
        warn "이행할 리뷰 의무 행이 없습니다: ${oid}"
        return "$GATE_EXIT_VOCAB"
      fi
      ost=$(gate_row_field "$oprior" '상태')
      if [ "$ost" != "미이행" ]; then
        warn "이미 닫힌 리뷰 의무입니다: ${oid} (상태=${ost:-없음})"
        return "$GATE_EXIT_VOCAB"
      fi
      # The carried fields come from the row being closed and never from argv.
      # `세그먼트` is what ties the fulfillment to the merge it belongs to, and
      # `생성 등급` is the value the excusal rule reads later — a router that
      # could restate either could also restate it wrongly.
      gate_append '리뷰 의무' "$@" "상태=이행" \
        "세그먼트=$(gate_row_field "$oprior" '세그먼트')" \
        "머지 커밋=$(gate_row_field "$oprior" '머지 커밋')" \
        "생성 등급=$(gate_row_field "$oprior" '생성 등급')" \
        "발행 시각=$(gate_row_field "$oprior" '발행 시각')" \
        "이행 시각=$(now_iso)"
      log "리뷰 의무 이행 $oid"
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
    # THE KEY IS "THIS 사유 IS CURRENTLY UNRESOLVED", not "this 사유 appears
    # anywhere in the ledger". Substring-matching the whole ledger meant the
    # second stall of a run never landed — including one that came after a
    # person had written the resolving row — and the observation file is
    # truncated below, so that observation vanished with nothing recording it.
    # The morning report and termination condition 5 then could not tell "it
    # stalled once and was resolved" from "it is still stalling".
    if [ "$( { cc_unresolved_blocked "$LEDGER" | cut -f2- | grep -cxF "$why" || true; } )" != "0" ]; then
      continue
    fi
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
  # A DONE PROPOSAL HAS NO ACT BEHIND IT, so the merge arm below must not judge
  # it. `--cutpoint` is required of every acting call and carries no meaning
  # here — there is nothing for it to authorize — yet the deadline read it and
  # refused the proposal as if it were a merge. The consequence is the worst
  # available one: a run past its deadline could not record that it had ended,
  # so no `done` file was written, the snapshot rendered it in flight forever,
  # and the watcher never reaped itself.
  [ "$kind" = "propose-done" ] && return 0
  merge_idx=$(cutpoint_index '머지') || return 0
  idx=$(cutpoint_index "$cut") || return 0
  if [ "$idx" -ge "$merge_idx" ]; then
    warn "벽시계 마감이 지났습니다 ($dl) — 마감 뒤로 머지는 없습니다"
    return "$GATE_EXIT_RULE"
  fi
  return 0
}

gate_act_worktree() {
  # gate_act_worktree <별칭> — the directory this target's acts actually run in.
  #
  # `실행 워크트리` FIRST, the main worktree as the fallback. One field could not
  # carry both duties: the sidecar path has to converge on the main worktree so
  # that N linked worktrees of one repository do not split the state a single
  # writer owns, while the act has to run where the branch actually is. For a pr
  # or branch anchor those are never the same directory — git refuses to check a
  # branch out twice.
  #
  # ONE RESOLUTION FOR THREE READERS, and that is the whole reason this is a
  # function. Each of the three read the field itself, and they disagreed: the
  # act ran in the execution worktree while its approval's binding tuple was
  # frozen against the MAIN worktree's head and compared against that same head
  # later. So an answer given at 22:00 stayed "fresh" through a night of commits
  # landing in the tree the act was actually run in, and a sibling segment moving
  # the main worktree expired approvals about a tree that had not moved. Freezing
  # and comparing must resolve identically or every approval already issued goes
  # stale at once and a person is asked the same question all over again.
  local wt
  wt=$(target_field "$1" '실행 워크트리')
  case "$wt" in
    ''|'(없음)') wt=$(target_field "$1" '메인 워크트리') ;;
  esac
  printf '%s' "$wt"
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

  # Snapshot binding, and it sits HERE — after the state-independent argument
  # and vocabulary checks, and before anything that writes. Under parallel
  # segments a background stage can land a row between the router reading the
  # snapshot and calling here; the main session also compacts, and a compacted
  # router carrying a remembered digest is a correctness failure that is
  # otherwise invisible. Exit 4 turns both into a loud re-read.
  #
  # It used to sit further down, after target resolution — which registers an
  # undeclared target by APPENDING a `대상 추가` row. The digest was therefore
  # compared against a ledger the gate itself had just changed, so an act that
  # registered a target could never satisfy its own binding. That was invisible
  # while the digest ignored the ledger; making the digest honest made the
  # ordering matter. A check on observed state has to run before the observer
  # mutates that state.
  if [ "$verb" != "plan" ]; then
    [ -n "$snapdig" ] || { printf 'gate: --snapshot-digest 가 필요합니다\n' >&2; exit 2; }
    local now
    now=$(gate_snapshot_digest)
    if [ "$snapdig" != "$now" ]; then
      warn "낡은 스냅숏 다이제스트: 관측 '$snapdig' vs 현재 '$now'"
      exit "$GATE_EXIT_STALE"
    fi
  fi
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
    segment|cycle|problem|blocked|clause|judgment|obligation)
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
    # the caller's directory and is bounded by the layers above instead. The
    # resolution itself lives in gate_act_worktree, which the approval's freeze
    # and staleness comparison call too — a stage woke on the main worktree's
    # branch every time until this was resolved in one place.
    GATE_ACT_CWD=$(gate_act_worktree "$alias")
    export GATE_ACT_CWD
  fi
  GATE_SURFACE="$graded"; export GATE_SURFACE

  gate_manifest_write_guard "$graded" "$@" || exit $?

  # WHAT THE AUTO-ADOPTION RULE READS. A rule checker is a separate `/bin/sh`
  # process and cannot call this file's functions, so the gate resolves the
  # vocabulary and hands over values — the same division `절단점-준수` already
  # has, where the checker receives two integers rather than a copy of the
  # ladder. `GATE_REVERT_SURFACE` in particular is the argv0 grading of the undo
  # command, and re-deriving it inside the checker would put a second copy of
  # the grading table where the portability lint does not look.
  GATE_KIND="$kind"
  GATE_JUDGMENT_CLASS=""
  GATE_REVERT=""
  GATE_REVERT_SURFACE=""
  # Set only when an ANSWERED approval is what opened this act, so the row can
  # say which one and a second use of the same answer is refusable.
  GATE_RESOLVED_APPROVAL=""
  if [ "$kind" = "judgment" ]; then
    # THE ROW IS WELL-FORMED BEFORE THE FLOOR IS ASKED ABOUT IT. Otherwise a
    # judgment missing a required field fails the floor for want of the very
    # field it is missing, and the refusal that reaches the router is exit 5 —
    # "a person must answer this" — for what is actually a typo. Worse, the
    # approval gets WRITTEN, so the run then carries an open question nobody
    # asked and termination waits on it.
    gate_judgment_fields_ok "$@" || exit "$GATE_EXIT_VOCAB"
    GATE_JUDGMENT_CLASS=$(gate_field_of '판단 부류' "$@")
    GATE_REVERT=$(gate_field_of '되돌리는 법' "$@")
    GATE_REVERT_SURFACE=$(gate_revert_surface "$GATE_REVERT")
  fi
  export GATE_KIND GATE_JUDGMENT_CLASS GATE_REVERT GATE_REVERT_SURFACE

  local rules_rc=0
  gate_run_rules "$cutpoint" "$alias" "$segment" "$argv" || rules_rc=$?

  # THE AUTO-ADOPTION FLOOR. It runs beside the catalog rather than only inside
  # it because its other consumer — a judgment a stage emitted in its terminal
  # message — is not an act and never reaches `gate_run_rules` at all. Keeping
  # one implementation for both is what stops the emitted path from becoming the
  # loose one.
  if [ "$rules_rc" = "0" ] && [ "$kind" = "judgment" ] \
     && [ "$(gate_field_of '등급' "$@")" = "1" ]; then
    gate_autoadopt_ok "$GATE_JUDGMENT_CLASS" "$GATE_REVERT" || rules_rc="$GATE_EXIT_APPROVAL"
  fi
  # THE RESOLUTION IS READ BEFORE THE DRY-RUN ARM. `plan` answers "would this
  # act pass", and once the approval is answered the honest answer is yes — an
  # arm that reported "still needs an approval" would be describing a state that
  # no longer exists, and it is the arm a router consults before acting.
  if [ "$rules_rc" = "$GATE_EXIT_APPROVAL" ]; then
    local ap_id ap_st
    if [ "$kind" = "judgment" ]; then
      # A JUDGMENT'S APPROVAL IS THE JUDGMENT APPROVAL. Keying it on the act
      # variant would hash an argv that is a list of fields and attach a binding
      # tuple describing a tree the question has nothing to do with — and the
      # same judgment resubmitted would then produce a second approval instead
      # of finding the first.
      ap_id=$(gate_judgment_approval_id "$segment" \
              "$(gate_judgment_question "$(gate_field_of '기준' "$@")" "$(gate_field_of '근거' "$@")")")
    else
      ap_id=$(gate_act_approval_id "$alias" "$argv")
    fi
    ap_st=$(gate_approval_state "$ap_id")
    case "$ap_st" in
      승인)
        # AN ANSWER IS SPENT ONCE. A judgment approval carries no binding tuple,
        # so nothing about it goes stale — `gate_approval_state` returns `승인`
        # for that id for the rest of the run, and the arm below turned every
        # later judgment resolving to the same id into an adoption that never
        # met the floor. Recording which approval opened which adoption is what
        # makes "already used" a question the ledger can answer.
        if [ "$kind" = "judgment" ] && gate_has_row '자율 승인' "해소 승인=$ap_id "; then
          warn "승인 $ap_id 은 이미 한 번 채택에 쓰였습니다 — 답 하나는 판단 하나를 엽니다"
          warn "같은 기준으로 다른 판단을 올리는 것이라면 새 질문으로 다시 물어야 합니다"
        elif [ "$kind" != "judgment" ] && ! gate_act_approval_fresh "$ap_id" "$alias"; then
          # THE TUPLE IS WHAT MAKES AN ACT APPROVAL EXPIRE. A question's answer
          # is durable and carries no tuple; an act's answer was given about a
          # tree, and this arm is the only place that says so. `rules_rc` is left
          # at `GATE_EXIT_APPROVAL` on purpose so the issuing path below
          # supersedes the stale row with a fresh question.
          warn "승인 $ap_id 은 답을 받은 뒤 트리가 움직였습니다 — 그 답으로 이 행위를 열지 않습니다"
          warn "같은 argv 라도 다른 트리 위의 행위이므로 승인을 다시 발행합니다"
        else
          log "승인 $ap_id 이 해소되어 이 행위를 엽니다"
          GATE_RESOLVED_APPROVAL="$ap_id"
          rules_rc=0
        fi ;;
      무효)
        warn "승인 $ap_id 이 무효로 닫혔습니다 — 이 행위는 수행하지 않습니다"
        exit "$GATE_EXIT_RULE" ;;
      거부)
        # A REFUSAL IS AN ANSWER, AND WITHOUT THIS ARM IT READS AS SILENCE.
        # `거부` is neither `대기` nor `승인`, so control fell out of this
        # `case` and reached the issuing path below — which re-opened the very
        # question that had just been answered no. The person would have got
        # the same question again the next morning, and every morning after,
        # off one answer they already gave.
        warn "승인 $ap_id 은 거부로 닫혔습니다 — 이 행위는 수행하지 않습니다"
        exit "$GATE_EXIT_RULE" ;;
    esac
  fi

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
    # Nothing above resolved it, so the act is genuinely blocked. A rule asking
    # for an approval and the gate not WRITING one is the same hole as recording
    # without performing, in the other direction: the run stops, nothing says
    # why, and the termination conditions never see the thing that is blocking
    # them. The row is the approval — issuing it is not bookkeeping after the
    # fact.
    if [ "$kind" = "judgment" ]; then
      # NO `자율 승인` ROW IS WRITTEN HERE. The refusal lands before the act is
      # recorded, which is what keeps a judgment from being adopted merely
      # because somebody submitted it — the union floor is the whole of the
      # admission, and a row written first would BE the adoption.
      # Reaching here with an ANSWERED approval means the resolution block above
      # found it spent — an unspent answer would have cleared `rules_rc` and this
      # branch would not run. So there is nothing to issue and nothing to adopt:
      # the judgment needs a question of its own.
      local iss_rc=0
      gate_issue_judgment_approval "$alias" "$segment" \
        "$(gate_field_of '기준' "$@")" "$(gate_field_of '근거' "$@")" || iss_rc=$?
      case "$(gate_judgment_approval_disposition "$iss_rc")" in
        발행) exit "$GATE_EXIT_APPROVAL" ;;
        답있음|닫힘) exit "$GATE_EXIT_RULE" ;;
        *) exit "$iss_rc" ;;
      esac
    fi
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

    # ORDER, AND THE SECOND CONSUMER OF `선행`.
    #
    # With only the cone's declared axis reading it, declaring narrowly would be
    # free: a segment that names no predecessor simply stays out of the cone, and
    # staying out is the direction that pays. The field costs something only when
    # its two consumers pull in opposite directions, and this is the other one —
    # a predecessor that has not LANDED is not a base this segment can be
    # dispatched onto, because the work it depends on is not in any tree yet.
    #
    # `머지됨` and `완료` only. `park` is terminal and did NOT land, so a
    # dependent dispatched over a parked predecessor is precisely the ordering
    # failure the declaration exists to prevent.
    local dep dst
    for dep in $(gate_deps_of "$segment"); do
      [ -n "$dep" ] || continue
      dst=$(gate_segment_field "$dep" '상태')
      case "$dst" in
        머지됨|완료) : ;;
        *) warn "선행 세그먼트 ${dep} 이 아직 착지하지 않았습니다 (상태=${dst:-없음}) — 이 세그먼트는 그 위에서 갈라져야 합니다"
           warn "선행이 머지됨·완료가 된 뒤에 다시 디스패치하거나, 의존이 없다면 segment 행의 「선행」을 다시 적으세요"
           exit "$GATE_EXIT_RULE" ;;
      esac
    done
  fi

  # The nine conditions are evaluated on EVERY act, not only on a done proposal.
  # A gate that can refuse a proposal but never cause one leaves the router
  # alone deciding when the night ends — so when every condition holds and the
  # router reaches for something else, it has to name what is left.
  local unmet
  unmet=$(gate_done_conditions)
  if [ "$kind" = "propose-done" ]; then
    # AN INVALIDATED RUN MUST STILL BE ABLE TO SAY IT ENDED. Condition 5 counts
    # a run-scope `blocked` row whose cause is `무효화` as permanently unmet —
    # deliberately, because clearing it would be the run re-authorizing itself
    # past the boundary that refused it. But the consequence was that such a run
    # could never write `done`: the snapshot rendered it `진행 중` forever, the
    # watcher's own exit condition never held, and a person had to kill three
    # processes by hand.
    #
    # The run is over either way. What changes here is only whether that fact
    # reaches disk. So when the invalidation is the ONLY thing left unmet, the
    # proposal is accepted and the `done` file records the run as invalidated
    # rather than as satisfied — the two must not read alike in the morning.
    local unmet_other
    unmet_other=$(printf '%s' "$unmet" | grep -v '해소 불가입니다' || true)
    if [ -n "$unmet" ] && [ -z "$unmet_other" ]; then
      warn "런이 무효화된 채로 종료를 기록합니다 — 충족이 아니라 무효로 남습니다"
      gate_append '자율 승인' "kind=$kind" "결정=act" "대상=$alias" "세그먼트=$segment" \
        "절단점=$cutpoint" "축2=$graded" "등급=1" "기준=무효화 종료" \
        "되돌리는 법=새 런으로 다시 킥오프" "근거=$rationale"
      printf '%s 종단 — 무효화 · 근거 %s\n' "$(now_iso)" "$rationale" > "$RUN_DIR/done"
      return 0
    fi
    if [ -n "$unmet" ]; then
      warn "종료 제안 기각 — 미충족 조건:"
      case "$unmet" in
        *"종료 절"*) warn "미정산 절은 act --kind clause 로 근거를 남기거나 불가능으로 표시하세요" ;;
      esac
      printf '%s\n' "$unmet" >&2
      # THE ROW CARRIES A SUMMARY, NOT THE WHOLE LIST. Joining every unmet
      # condition made this field grow with the run — one unmet segment per
      # non-terminal segment, one per unsettled clause — and the row has a
      # 1024-byte cap, so a run with enough of them could not record its own
      # rejection: the append died and the router got exit 1 with no row at all.
      # Measured at 1228 bytes with nine segments in flight.
      #
      # The full text is already on stderr immediately above, which is where a
      # reader looks; what the row needs is enough to say what happened and how
      # many, bounded by construction.
      local unmet_n unmet_ids
      unmet_n=$(printf '%s\n' "$unmet" | grep -c . || true)
      unmet_ids=$(printf '%s\n' "$unmet" | sed -n 's/^\([0-9]\{1,2\}\) .*/\1/p' \
                  | sort -un | tr '\n' ',' | sed 's/,$//')
      gate_append '자율 승인' "kind=$kind" "결정=기각" "대상=$alias" "세그먼트=$segment" \
        "절단점=$cutpoint" "축2=$graded" "등급=0" "기준=종료 조건 아홉" \
        "되돌리는 법=해당 없음(거부)" \
        "근거=미충족 ${unmet_n}건 · 조건 ${unmet_ids:-미상}"
      exit "$GATE_EXIT_RULE"
    fi
    log "종료 조건이 전부 성립합니다"
    # The run's END, recorded as a FILE in the run directory. The ledger already
    # carries the row, but a row is not a thing another process can test cheaply
    # — and two processes need to: the liveness watcher, whose loop had no exit
    # condition and therefore outlived every run it watched, and a person asking
    # "is this still going?" without knowing the row grammar.
    #
    # A THIRD TERMINAL CLASS, because a run may now end while questions are
    # still open. No eleventh termination condition is created for it — a
    # condition exists to REFUSE a proposal, and an open question must not
    # refuse one; that refusal is the defect being removed. So the residual is
    # recorded in the `done` file beside `무효화`, which already sits there for
    # the same structural reason, and the morning tells the three apart at a
    # glance.
    local qids qn held
    qids=$(gate_pending_approval_ids 판단 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    qn=$(gate_pending_approval_ids 판단 | gate_count)
    # THE HELD CLAUSES ARE NAMED. `보류` settles condition 10, so a clause on
    # hold leaves no trace in the unmet list — and a run that answered every
    # authorized clause and one that deferred all of them behind questions would
    # otherwise write the same terminal line. This is the residual class the
    # design put in this file rather than in an eleventh condition, so it has to
    # carry what is actually outstanding.
    held=$(gate_held_clause_ids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ -n "$qids" ]; then
      printf '%s 종단 — 질의 잔여 %s건 · 승인 %s%s · 근거 %s\n' \
        "$(now_iso)" "$qn" "$qids" "${held:+ · 보류 절 $held}" "$rationale" > "$RUN_DIR/done"
    else
      printf '%s 종단 — 종료 조건 성립%s · 근거 %s\n' \
        "$(now_iso)" "${held:+ · 보류 절 $held}" "$rationale" > "$RUN_DIR/done"
    fi
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
    segment|cycle|problem|blocked|clause|judgment|obligation) gate_record_row "$kind" "$segment" "$alias" "$@"; return $? ;;
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

gate_act_approval_id() {
  # gate_act_approval_id <alias> <argv>
  #
  # Factored out because TWO places must agree on it: the one that issues the
  # approval and the one that asks whether it has since been answered. They were
  # one expression in one place, so nothing could ask.
  printf 'A-%s' "$(printf '%s|%s|%s' "$RUN_ID" "$1" \
    "$(printf '%s' "$2" | shasum -a 256 | cut -d' ' -f1)" | shasum -a 256 | cut -c1-8)"
}

gate_approval_state() {
  # The LAST row for this id wins, the way the termination conditions already
  # read approvals and review obligations.
  { gate_rows '승인' | grep -F "승인 id=$1 " || true; } | tail -1 \
    | tr '|' '\n' | sed -n 's/^ *상태=//p' | sed 's/[[:space:]]*$//' | tail -1
}

gate_approval_field() {
  # gate_approval_field <승인 id> <키> — the last value that key ever carried on
  # a row for this approval.
  #
  # NOT "the last row's value", which is what `gate_approval_state` wants and
  # this does not: `close` appends a resolution row carrying only the id, the
  # state, the question, the answer and the time, so a reader that looked at the
  # last row for `구속 튜플` found nothing on every answered approval — that is,
  # on exactly the approvals whose tuple anyone would want to check.
  { gate_rows '승인' | grep -F "승인 id=$1 " || true; } \
    | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1
}

gate_act_tuple_head() {
  # gate_act_tuple_head <승인 id> — the head fragment frozen into an act
  # approval's binding tuple, or nothing when the tuple holds none.
  #
  # The tuple is `<별칭>/<베이스 브랜치>/<head 앞자리>/<축2 등급>`, and a base
  # branch may itself contain `/`. So the fragment is taken by dropping the LAST
  # component and then taking the last of what remains — cutting at the second
  # `/` would read `feat` out of `feat/x` and compare a branch name against a
  # sha for the rest of the run.
  local t rest
  t=$(gate_approval_field "$1" '구속 튜플')
  # `-` (a question) and `B1` (a boundary) are tuples with no tree in them.
  case "$t" in */*/*/*) : ;; *) return 0 ;; esac
  rest=${t%/*}
  printf '%s' "${rest##*/}"
}

gate_act_approval_fresh() {
  # gate_act_approval_fresh <승인 id> <별칭> — 0 when the tree this approval was
  # answered against is still the tree in front of us.
  #
  # THE BINDING TUPLE FINALLY HAS A READER. It was written at issue time and read
  # by nothing anywhere in the tree, so the property stated beside it — an act
  # approval's answer is valid only against the tree it named, which is the whole
  # reason it carries shas and a question does not — was a sentence rather than a
  # check. An answer given at 22:00 opened the same argv at 04:00 across every
  # commit that had landed in between.
  #
  # It compares the head fragment ALONE. The alias is the lookup key, the base
  # branch is not what the act is about, and the axis-2 grade is re-derived on
  # every entry anyway. The comparison takes the CURRENT head's first bytes to
  # the stored fragment's length, because the fragment is stored clipped.
  #
  # UNMEASURABLE READS AS FRESH, deliberately. This exists to catch a tree that
  # MOVED; a tuple with no head in it, or a worktree whose HEAD cannot be read
  # now, is not a moved tree, and re-opening an approval over it would ask a
  # person a question the second asking cannot answer any better.
  #
  # THE TREE IT NAMED IS THE ONE THE ACT RUNS IN, resolved through
  # gate_act_worktree — the same call the issuer freezes through, so the two
  # sides cannot drift apart.
  local frag cur
  frag=$(gate_act_tuple_head "$1")
  [ -n "$frag" ] || return 0
  cur=$(cd "$(gate_act_worktree "$2")" 2>/dev/null && git rev-parse HEAD 2>/dev/null || true)
  [ -n "$cur" ] || {
    warn "승인 $1 의 구속 튜플을 대조할 HEAD 를 읽지 못했습니다 — 움직인 트리가 아니므로 신선한 것으로 봅니다"
    return 0
  }
  [ "$frag" = "${cur:0:${#frag}}" ]
}

gate_issue_act_approval() {
  # gate_issue_act_approval <alias> <segment> <cutpoint> <grade> <argv>
  #
  # An ACT approval, as against the boundary variant: the binding tuple is
  # act-shaped, so staleness is re-derived against the tree it named. The id is
  # derived from the act rather than random, so the same blocked act asked twice
  # produces one pending approval instead of a queue of duplicates.
  local alias="$1" seg="$2" cut="$3" grade="$4" argv="$5" id ad base head st
  ad=$(printf '%s' "$argv" | shasum -a 256 | cut -d' ' -f1)
  id=$(gate_act_approval_id "$alias" "$argv")
  # PRESENCE WAS THE WRONG GUARD ONCE THE TUPLE GOT A READER. The id is derived
  # from the alias and the argv and holds no sha, so an approval that has gone
  # stale keeps its id — and a presence check then refused to issue the very
  # re-approval the staleness finding asks for, leaving the act exiting 5 with
  # nothing pending for anyone to answer. What each state does:
  #   대기  one open approval per act, which is the original property
  #   승인  reached only when the caller found the tuple stale, so SUPERSEDE it
  #         by appending a fresh `대기` row under the same id — the id names the
  #         act and the row sequence tells the morning what happened to it
  #   그 외 `거부`/`무효` are terminal and the caller exits before arriving here
  st=$(gate_approval_state "$id")
  case "$st" in
    대기) return 0 ;;
    ''|승인) : ;;
    *) return 0 ;;
  esac
  base=$(target_field "$alias" '베이스 브랜치')
  head=$(cd "$(gate_act_worktree "$alias")" 2>/dev/null && git rev-parse HEAD 2>/dev/null || true)
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=$cut" \
    "행위 다이제스트=$ad" "구속 튜플=$alias/$base/${head:0:12}/$grade" \
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
  # A termination clause, named by its id and actually marked unmet. The arm
  # here used to accept any rationale CONTAINING the word `미충족` — no clause
  # id, no check that anything was unmet — which is the prose path the comment
  # above denies, sitting on the function's own last line. It meant the only
  # thing standing between a run and an early "satisfied" ending was whether the
  # router happened to use one Korean word.
  for o in $(gate_unmet_clause_ids); do
    case "$why" in *"$o"*) return 0 ;; esac
  done
  return 1
}

gate_clause_ids() {
  # The termination point, decomposed at kickoff into checkable rows. The gate
  # never read these at all — `종료 절` appears zero times in it — so the nine
  # conditions measured the ledger's shape and never the thing the user actually
  # authorized the run against.
  grep -E '^- `종료 절`' "$MANIFEST" 2>/dev/null \
    | sed -n 's/.*id=\([^|]*\).*/\1/p' | sed 's/[[:space:]]*$//'
}

gate_clause_evidence_ids() {
  # gate_clause_evidence_ids <근거> — every `J-<8자리 16진>` the rationale names,
  # one per line, deduplicated.
  #
  # ONE EXTRACTION FOR THE CHECK AND FOR THE REPORT, which is the whole reason
  # this exists as a function. The write-time floor looped over pending approvals
  # and kept the LAST match, while the `done` file's reporter ran a different
  # expression that took the FIRST — so the set the gate refused duplicates over
  # and the set the morning was told about were two different values read out of
  # one field, and neither of them was the whole set.
  #
  # It reads the TEXT rather than intersecting with the pending list, because the
  # reporter must still name an approval that has since been answered. Requiring
  # the ids to be open is a separate question, asked by the write-time floor
  # alone.
  { printf '%s' "${1:-}" | tr -c '0-9A-Za-z-' '\n' \
      | grep -E '^J-[0-9a-f]{8}$' || true; } | sort -u
}

gate_judgment_approval_open() {
  # gate_judgment_approval_open <승인 id> — 0 when that id is an OPEN
  # `절단점=판단` approval, which is what `보류` evidence has to be.
  case " $(gate_pending_approval_ids 판단 | tr '\n' ' ') " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

gate_clause_settled() {
  # A clause is settled when a `종료 절` row in the LEDGER names it — written by
  # the router through `act --kind clause` with its evidence, or marked
  # impossible. The manifest holds the question; the ledger holds the answer.
  # The value is CAPTURED, not piped into `grep -q`: an early-exiting reader on
  # the right of a pipe kills the writer with SIGPIPE, and under `pipefail` the
  # whole pipeline then reports failure even though the match was found. This
  # file's own scanner catches that shape, and it caught this one.
  #
  # `보류` COUNTS AS SETTLED HERE, DELIBERATELY, and the reason is worth stating
  # because the opposite reading is the obvious one. A condition exists to
  # REFUSE a proposal, and an open question must not refuse one — that refusal
  # is the defect this slice removes, and it is why no eleventh condition was
  # created. What keeps `보류` from being a free pass is not this function: it is
  # the write-time floor (the evidence must be an OPEN `절단점=판단` approval,
  # and no two clauses may lean on the same one) plus the `done` file recording
  # every held clause with the question holding it. The state's disposition is
  # visible; it is not silent the way `충족` would be.
  #
  # AND `보류` KEEPS COUNTING ONCE THE ANSWER ARRIVES. The opposite reading was
  # here first — the clause went back to unsettled the moment its question closed
  # — and it made a run a person ANSWERED leave less behind than one nobody
  # touched: the answer flipped condition 10 back to unmet, the done proposal was
  # refused, and the terminal line that carries the run's residual was never
  # written at all. The contract hands an answered hold to the SUCCESSOR run
  # rather than re-opening this one, so re-settling the clause as `충족` or
  # `불가능` is that run's work, with the answer in hand. What travels across the
  # boundary is the `done` file, which names the clause, every approval holding
  # it, and the state each of those approvals is now in.
  local last ids
  last=$( { gate_rows '종료 절' | grep -F "id=$1 " || true; } | tail -1)
  [ -n "$last" ] || return 1
  if [ "$(gate_row_field "$last" '상태')" = "보류" ]; then
    ids=$(gate_clause_evidence_ids "$(gate_row_field "$last" '근거')")
    # No id at all is not "nothing to check" — the write-time floor refuses such
    # a row, so one here means the field was lost, and unsettled is the safe read.
    [ -n "$ids" ] || return 1
  fi
  return 0
}

gate_held_clause_ids() {
  # Clauses whose LAST row is `보류`, with the approvals each is waiting on.
  # These settle condition 10 and are therefore invisible to `gate_done_conditions`
  # — which is exactly why the `done` file has to name them, or a run that
  # settled nothing and a run that settled everything write the same ending.
  #
  # ALL of them, from the same extraction the write-time floor uses. A clause may
  # legitimately name more than one approval, and reporting the first while the
  # floor checked the last meant the morning could read an id the gate had never
  # measured anything about.
  #
  # EACH ID CARRIES ITS APPROVAL'S CURRENT STATE. A hold whose answer has already
  # arrived and a hold still waiting are otherwise the same string, and those are
  # the two things the morning most needs to tell apart — the first is work the
  # successor run can finish, the second is a question still owed to a person.
  # The clause stays settled either way, so this line is the only place where the
  # arrival of an answer becomes visible.
  local cid last jid jst jids
  for cid in $(gate_clause_ids); do
    [ -n "$cid" ] || continue
    last=$( { gate_rows '종료 절' | grep -F "id=$cid " || true; } | tail -1)
    [ -n "$last" ] || continue
    [ "$(gate_row_field "$last" '상태')" = "보류" ] || continue
    jids=""
    for jid in $(gate_clause_evidence_ids "$(gate_row_field "$last" '근거')"); do
      [ -n "$jid" ] || continue
      jst=$(gate_approval_state "$jid")
      jids="$jids $jid:${jst:-미상}"
    done
    jids=${jids# }
    printf '%s(%s)\n' "$cid" "${jids:-승인 미상}"
  done
}

gate_unmet_clause_ids() {
  local cid
  for cid in $(gate_clause_ids); do
    [ -n "$cid" ] || continue
    gate_clause_settled "$cid" || printf '%s\n' "$cid"
  done
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
  CC_PIPELINE_STAGE_ID="$seg#$attempt" \
  bash "$wrapper" \
    --settings "$(gate_settings_file "$kind")" \
    --plugin-dir "$plugin_dir" \
    $id_flag \
    -- "$@" > "$RUN_DIR/log/$seg.json" 2> "$RUN_DIR/log/$seg.err" < /dev/null &
  local spid=$!
  printf '%s\n' "$spid" > "$RUN_DIR/$seg.pid"
  # Pinned on the WRITE side too. The watcher pins it on the read side, and a
  # fingerprint is only a fingerprint if both sides format it the same way —
  # under a Korean locale this line yields `2026년 8월 28일 …`, the comparison
  # never matches, and the watcher silently skips every stage while reporting
  # "0 live". That failure is invisible: it does not error, it under-counts.
  #
  # `LC_ALL`, not `LC_TIME`. The variable that decides the format is whichever
  # one outranks the others in the process that runs `ps`, and `LC_ALL` outranks
  # `LC_TIME` everywhere. This side clears `LC_ALL` at startup so `LC_TIME` was
  # enough here, but the reader is a different process with a different
  # environment; pinning the rank that nothing overrides removes the dependency
  # on what the reader happens to have inherited.
  LC_ALL=C ps -o lstart= -p "$spid" 2>/dev/null \
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
  # A STAGE THAT PARKED ITSELF IS NOT A SUCCESS, and this arm could not tell the
  # difference. The halt contract names the orchestrator as the reader and three
  # skills write the record, but nothing on this path opened it — so a stage that
  # stopped deliberately, wrote down why, and left the tree untouched was filed
  # as `정상 완료` when it had written a row, and as `공허한 성공` when it had
  # not. Measured twice in one night: a stage refuted a pre-implementation check
  # and halted correctly, and the only way to see that was to open the worktree
  # by hand.
  #
  # The record is checked BEFORE the row-count arms because its answer is more
  # specific than theirs. A halted stage may well have written rows first.
  local haltf
  haltf="$RUN_DIR/halt/$seg#$attempt.md"
  [ -f "$haltf" ] || haltf="$RUN_DIR/halt/$seg.md"
  if [ "$rc" = "0" ] && [ -s "$haltf" ] \
     && [ "$( { grep -vE '^[[:space:]]*$' "$haltf" 2>/dev/null || true; } | tail -1)" = '<!-- /cc-pipeline-halt v1 -->' ]; then
    klass='의도된 park'
  elif [ "$rc" != "0" ] || [ "${subtype:-}" != "success" ] || [ "${iserr:-false}" = "true" ]; then
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
    # FOUR PATHS, and the two that matter are the last two — the first two ask
    # for JSON the stage does not emit. What a process-A stage actually writes
    # is PROSE: a `## 프로세스 A 완료 — 계획 방출` section carrying
    # `**plan_sha256**: <hex>` and a `**계획**:` path. Measured: a stage
    # completed normally, emitted its plan and stated the digest, and the row
    # still had no field — so process B could not enter and every dispatch
    # re-ran as process A.
    psha=$(printf '%s' "$res" | jq -r '(.result // empty) | fromjson? | .plan_sha256 // empty' 2>/dev/null || true)
    [ -n "$psha" ] || psha=$(printf '%s' "$res" | jq -r '.plan_sha256 // empty' 2>/dev/null || true)
    # The stage's own terminal text. `[0-9a-f]\{64\}` rather than a looser
    # match so a sentence mentioning the field cannot be mistaken for a value.
    if [ -z "$psha" ]; then
      psha=$(printf '%s' "$res" | jq -r '.result // empty' 2>/dev/null \
             | sed -n 's/.*plan_sha256[^0-9a-f]*\([0-9a-f]\{64\}\).*/\1/p' | sed -n '1p')
    fi
    # And the plan file, at the name the stage actually uses — `<segment>.plan.md`
    # in the run directory, not `implement-<segment>.plan.md`.
    if [ -z "$psha" ] && [ -f "$RUN_DIR/$seg.plan.md" ]; then
      psha=$(shasum -a 256 "$RUN_DIR/$seg.plan.md" | cut -d' ' -f1)
    fi
    if [ -z "$psha" ] && [ -f "$RUN_DIR/implement-$seg.plan.md" ]; then
      psha=$(shasum -a 256 "$RUN_DIR/implement-$seg.plan.md" | cut -d' ' -f1)
    fi
  fi
  # THE DOCUMENT'S HASH AT EACH STAGE TERMINATION. The kickoff freezes one, the
  # audit is contractually required to EDIT the document (its reconciliation
  # pass is where findings land, and the largest routing bucket is "apply"), and
  # the implement stage compares against the frozen value — so audit followed by
  # implement in one run halts on freeze-mismatch every time. That is the basic
  # shape of the pipeline blocking itself.
  #
  # The gate is the only writer here, the row is chained like any other, and the
  # value is measured rather than supplied by the stage. What it does NOT decide
  # is whether post-audit bytes should be re-audited before implementation —
  # that question is open (#307) and this row is what makes it answerable, since
  # until now nothing recorded that the bytes had moved at all.
  local dkey dcur
  dkey=$(manifest_field '요소' '설계 문서')
  case "$dkey" in
    ''|'(없음)') : ;;
    *)
      dcur=$( { [ -f "$BASE/$dkey" ] && shasum -a 256 "$BASE/$dkey"; } 2>/dev/null | cut -d' ' -f1)
      [ -n "$dcur" ] || dcur=$( { [ -f "/$dkey" ] && shasum -a 256 "/$dkey"; } 2>/dev/null | cut -d' ' -f1)
      if [ -n "$dcur" ]; then
        gate_has_row '문서 해시' "스테이지=$seg 이후 sha256=$dcur" \
          || gate_append '문서 해시' "스테이지=$seg 이후" "sha256=$dcur" \
               "동결값=$(manifest_field '요소' '설계 문서 전체 sha256')" "관측=$(now_iso)"
      fi ;;
  esac

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

  gate_absorb_emitted_judgment "$alias" "$seg" "$res"

  log "스테이지 종단 — $seg ($kind) $klass rc=$rc${cost:+ · ${cost} USD}"
}

gate_absorb_issue() {
  # gate_absorb_issue <alias> <segment> <기준> <근거> <문맥> — issue the approval
  # an emitted judgment needs and dispose of every one of the issuer's three
  # returns. ALWAYS returns 0.
  #
  # The absorber runs in the middle of recording a stage result, and this file
  # inherits `set -euo pipefail` from the driver it sources. So an unhandled
  # non-zero here does not "fall through": it kills the gate part way through
  # writing the result row, or — where it is returned rather than run bare — it
  # reaches the router as exit 9, which is a value the contract never defined.
  # Both were reachable from all three call sites, and all three simply dropped
  # the value and returned 0.
  #
  # A SILENT `return 0` IS NOT ONE OF THE DISPOSITIONS. The stage has already
  # acted on the decision inside its own turn; if the gate writes neither a row
  # nor an approval nor a warning, the judgment exists only in a terminal
  # message nobody will read again.
  local alias="$1" seg="$2" std="$3" why="$4" ctx="$5" rc=0
  gate_issue_judgment_approval "$alias" "$seg" "$std" "$why" || rc=$?
  case "$(gate_judgment_approval_disposition "$rc")" in
    발행) ;;
    답있음)
      # An answer is on file for exactly this question, so the answer opens this
      # judgment — the same disposition the acting path reaches through
      # `GATE_RESOLVED_APPROVAL`. The row names the approval it spent, which is
      # what makes a second use of one answer refusable.
      gate_append '자율 승인' "kind=judgment" "결정=채택" "세그먼트=$seg" \
        "판단 부류=-" "등급=-" \
        "기준=$(gate_row_safe "$std" 150)" "되돌리는 법=-" \
        "근거=$(gate_row_safe "$why" 150)" \
        "출처=스테이지 방출" "해소 승인=${GATE_LAST_JUDGMENT_APPROVAL_ID:--}"
      log "스테이지가 방출한 판단에 이미 답이 있어 그 답으로 엽니다 — $ctx (승인 ${GATE_LAST_JUDGMENT_APPROVAL_ID:--})"
      ;;
    닫힘)
      warn "스테이지가 방출한 판단의 물음은 이미 닫혀 있습니다 — 같은 물음을 다시 열지 않았습니다 ($ctx, 승인 ${GATE_LAST_JUDGMENT_APPROVAL_ID:--})"
      ;;
    *)
      warn "스테이지가 방출한 판단의 승인 발행이 알 수 없는 값으로 끝났습니다 ($ctx, rc=$rc) — 채택하지 않고 넘어갑니다"
      ;;
  esac
  return 0
}

gate_absorb_emitted_judgment() {
  # gate_absorb_emitted_judgment <alias> <segment> <result-line>
  #
  # A STAGE CANNOT REACH THE JUDGMENT PATH DIRECTLY, because it writes no
  # sidecar and holds no gate verb. Its only channel for a decision it made is
  # its own terminal message — the same channel `plan_sha256` already travels
  # on — and the gate parses it here.
  #
  # THE EMITTED LINE GOES THROUGH THE SAME UNION FLOOR. Without that, emitting
  # four lines would be enough to adopt anything at all, and the floor would be
  # bypassed by the one path that never touches it — which is the whole design
  # routed around rather than one check missed. When it does not pass, no
  # `자율 승인` row is written and an approval is issued instead.
  local alias="$1" seg="$2" res="$3" txt cls grade std revert why
  txt=$(printf '%s' "$res" | jq -r '.result // empty' 2>/dev/null || true)
  [ -n "$txt" ] || return 0

  # EVERY MARKER IS READ BEFORE ANY OF THEM DECIDES. The class used to gate the
  # rest, so a return here meant "no judgment was emitted" AND "a judgment was
  # emitted without a class" — and the second is the shape a stage naturally
  # produces, because the three-grade marking convention names `기준` and
  # `되돌리는 법` and has never required a class at all. That judgment vanished:
  # no row, no approval, no warning, while the stage had already ACTED on the
  # decision inside its own turn. It is the exact opposite disposition from a
  # class that is present but out of vocabulary, which escalates.
  cls=$(printf '%s' "$txt" | sed -n 's/.*\*\*판단 부류\*\*: *\([^ *`]*\).*/\1/p' | sed -n '1p')
  grade=$(printf '%s' "$txt"  | sed -n 's/.*\*\*판단 등급\*\*: *\([0-9]\).*/\1/p' | sed -n '1p')
  std=$(printf '%s' "$txt"    | sed -n 's/.*\*\*판단 기준\*\*: *\(.*\)/\1/p' | sed -n '1p')
  revert=$(printf '%s' "$txt" | sed -n 's/.*\*\*판단 되돌리는 법\*\*: *\(.*\)/\1/p' | sed -n '1p')
  why=$(printf '%s' "$txt"    | sed -n 's/.*\*\*판단 근거\*\*: *\(.*\)/\1/p' | sed -n '1p')

  # No marker of ANY kind — the stage recorded no decision, which is the common
  # case and the only one that may return quietly.
  if [ -z "$cls" ] && [ -z "$grade" ] && [ -z "$std" ] && [ -z "$revert" ] && [ -z "$why" ]; then
    return 0
  fi

  # Grade 0 records nothing by contract — an already-written rule fully
  # determined the answer, so there was no decision to record.
  case "${grade:-}" in 0) return 0 ;; esac

  if [ -z "$cls" ]; then
    warn "스테이지가 판단을 방출했으나 「판단 부류」가 없습니다 — 행을 쓰지 않고 승인을 발행합니다"
    gate_absorb_issue "$alias" "$seg" "${std:-미상}" "${why:-스테이지 방출}" "판단 부류 없음"
    return 0
  fi
  if ! judgment_class_ok "$cls"; then
    warn "스테이지가 방출한 「판단 부류」가 어휘 밖입니다: $cls — 행을 쓰지 않고 승인을 발행합니다"
    gate_absorb_issue "$alias" "$seg" "${std:-미상}" "${why:-스테이지 방출}" "어휘 밖 부류 $cls"
    return 0
  fi
  if [ "${grade:-2}" = "2" ] || ! gate_autoadopt_ok "$cls" "$revert"; then
    warn "스테이지가 방출한 판단이 자동 채택의 합집합을 통과하지 못했습니다 ($cls) — 행을 쓰지 않고 승인을 발행합니다"
    gate_absorb_issue "$alias" "$seg" "${std:-미상}" "${why:-스테이지 방출}" "자동 채택 불성립 $cls"
    return 0
  fi
  gate_append '자율 승인' "kind=judgment" "결정=채택" "세그먼트=$seg" \
    "판단 부류=$cls" "등급=$grade" \
    "기준=$(gate_row_safe "${std:-미상}" 150)" \
    "되돌리는 법=$(gate_row_safe "$revert" 150)" \
    "근거=$(gate_row_safe "${why:-스테이지 방출}" 150)" \
    "출처=스테이지 방출"
  log "스테이지가 방출한 판단을 채택했습니다 — $seg 부류 $cls"
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

gate_negative_answer_hit() {
  # gate_negative_answer_hit <답 바이트> — prints the negative term the answer
  # matched, or nothing at all.
  #
  # THE VOCABULARY LIVES HERE AND IN NO OTHER PLACE. Spread across the call
  # sites it would drift, and a scan that is thorough in one caller and thin in
  # another reads as one floor while behaving as two.
  #
  # The two halves are matched differently because the languages differ. Korean
  # has no word boundary a scan can rest on, so its terms are matched as plain
  # substrings. The Latin terms are matched against a copy whose punctuation
  # and multibyte bytes have become spaces and which is space-padded on both
  # ends, so `no` cannot fire on `note`, `known` or `nothing` — the bare
  # substring would have made this scan useless in the other direction, which
  # for a check standing between an answer and a recorded approval is worse
  # than the constant it replaces.
  #
  # THE KOREAN HALF CARRIES THE PRODUCTIVE FORMS AND NOT ONLY THE STANDALONE
  # WORDS. Korean negates mainly by ending — `-지 않다`, `-지 말다` — and by the
  # adverbs `안` and `못`; a list of standalone refusals therefore knew none of
  # the ordinary ways to say no, and `승인하지 않습니다` or `반대합니다` closed as
  # grants. The ending terms are spelled without their trailing verb (`지 않`) so
  # one term covers every conjugation of it.
  local ans="$1" lower flat t
  lower=$(printf '%s' "$ans" | tr 'A-Z' 'a-z')
  # THE ADVERB TERMS ARE SPELLED SEVERAL WAYS BECAUSE KOREAN CONJUGATION CHANGES
  # THE STEM SYLLABLE ITSELF AND NOT ONLY WHAT FOLLOWS IT. `안 되` does not occur
  # in `안 됩니다` at all — the stem `되` has become `됩` — so one dictionary-form
  # spelling would know the form nobody writes and miss the form everybody does.
  # The ending terms above need no such spread: `않` and `말` survive their own
  # conjugations.
  for t in 아니오 아니요 거부 거절 '하지 마' 하지마 '지 않' '지 말' \
           '안 되' '안 됩' '안 돼' '못 하' '못 합' '못 해' '못 한' 반대 불가; do
    case "$lower" in *"$t"*) printf '%s' "$t"; return 0 ;; esac
  done
  flat=" $(printf '%s' "$lower" | tr -c "a-z0-9'" ' ') "
  for t in no nope reject "don't" not negative decline disagree nah; do
    case "$flat" in *" $t "*) printf '%s' "$t"; return 0 ;; esac
  done
  return 0
}

gate_positive_answer_hit() {
  # gate_positive_answer_hit <답 바이트> — prints the affirmative term the answer
  # matched, or nothing at all.
  #
  # A MISS IS `극성 미상`, NOT AN AFFIRMATION. With only the negative scan in
  # place, silence read as consent: an answer carrying none of its terms closed
  # as `승인`, so every refusal phrased in a word the vocabulary happens not to
  # know became a grant. Requiring an affirmative term instead moves the cost of
  # an unknown word onto a question that stays open — which the run survives,
  # since a `대기` judgment approval is carried to the next cycle — rather than
  # onto an approval nobody gave, which nothing downstream can undo.
  #
  # Matched in the same two ways as the negative half and for the same reasons:
  # Korean as plain substrings, Latin against the space-padded flattened copy.
  local ans="$1" lower flat t
  lower=$(printf '%s' "$ans" | tr 'A-Z' 'a-z')
  for t in 네 예 좋 승인 채택 진행 그렇게 해주세요; do
    case "$lower" in *"$t"*) printf '%s' "$t"; return 0 ;; esac
  done
  flat=" $(printf '%s' "$lower" | tr -c "a-z0-9'" ' ') "
  for t in yes ok okay approve agreed "go ahead"; do
    case "$flat" in *" $t "*) printf '%s' "$t"; return 0 ;; esac
  done
  return 0
}

gate_strip_question() {
  # gate_strip_question <바이트> <질문 문면> — the bytes with every verbatim
  # occurrence of the question removed.
  #
  # Written as a prefix/suffix trimming loop rather than `${v//"$q"/}` so the
  # substitution stays inside what the portability lint accepts, and so removal
  # is literal: the question text is arbitrary prose and would otherwise be read
  # as a pattern.
  local body="$1" q="$2" out='' head
  [ -n "$q" ] || { printf '%s' "$body"; return 0; }
  while :; do
    case "$body" in
      *"$q"*)
        head=${body%%"$q"*}
        out="$out$head"
        body=${body#*"$q"}
        ;;
      *) out="$out$body"; break ;;
    esac
  done
  printf '%s' "$out"
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
  # Three outcomes, and every one of them needs the same transcript line.
  # `--void` records `무효` — the question should not have been asked — and
  # `--reject` records `거부` — it was asked, and the answer is no. Before them
  # there was exactly one recording path, so a pending approval had two possible
  # ends: granted, or pending forever. Pending is not inert; it counts against
  # termination condition 2 and suspends the stagnation boundaries, so one
  # approval nobody wants to grant stalls the rest of the run.
  #
  # Voiding is NOT the conservative direction — it REMOVES a blocker — so it
  # keeps the transcript binding rather than becoming a router-writable escape.
  # What it buys a person is the ability to answer "this should not have been
  # asked" without also granting the act.
  #
  # `거부` IS THE OUTCOME A PERSON'S OWN WORDS CAN REACH, and until it existed
  # they could not reach one. `무효` and `승인` are both dispositions the router
  # selects; the recording path held the single literal `상태=승인` and read
  # nothing about the answer's polarity, so an answer of "no" written into the
  # transcript was recorded as a grant. Every refusal on the unattended
  # adoption surface converges on this channel, so a channel that emits a
  # constant leaves the floors above it deciding nothing.
  local id="$1" void="${2:-0}" reject="${3:-0}" row state q tx ans f cutp abody hit scanbody phit
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
  # THE ANSWER BYTES ARE THE ARTIFACT WHEN THE APPROVAL IS A QUESTION.
  #
  # For an act approval the answer is binary — the act happens or it does not —
  # so the fixed literal lost nothing and the row stayed short. A question's
  # answer is what the next step consumes, and this row is the run's only
  # durable copy of it: dropping it means the person answered and the run kept
  # nothing but the fact that they did.
  #
  # Act approvals keep the literal, so no existing reader and no existing
  # assertion changes.
  # THE ANSWER IS EXTRACTED FROM THE TRANSPORT FRAME, NOT SHIPPED WITH IT.
  #
  # `$ans` is the matched transcript LINE, and a harness transcript line is a
  # JSON object whose `message.content` sits behind `uuid`, `parentUuid`,
  # `sessionId` and `timestamp` and is itself an array of blocks. Recording the
  # line verbatim put four hundred bytes of scaffolding in the field the
  # contract calls the run's only durable copy of the answer, with the answer
  # itself beyond the clip. Unlike the clip-unit defect this fired on every real
  # transcript, and the fixture missed it because a hand-written one-line object
  # puts the answer near the front.
  #
  # The raw line is the FALLBACK rather than the primary: a line that is not
  # JSON, or is JSON of a shape this does not know, still yields the bytes it
  # has. The transcript binding is untouched — the id and the question text must
  # already have been found on this line before extraction runs.
  cutp=$(gate_row_field "$row" '절단점')
  abody='트랜스크립트 판독'
  if [ "$cutp" = "판단" ]; then
    local extracted
    extracted=$(printf '%s' "$ans" | jq -r '
      (.message.content? // .content?) as $c
      | if $c == null then empty
        elif ($c | type) == "string" then $c
        elif ($c | type) == "array" then
          [ $c[] | if (type == "object") then (.text // empty) else tostring end ] | join(" ")
        else ($c | tostring) end
    ' 2>/dev/null || true)
    [ -n "$extracted" ] || extracted="$ans"
    abody=$(gate_row_safe "$extracted" 400)
  fi

  # THE POLARITY IS READ BEFORE `승인` IS WRITTEN.
  #
  # A scan over natural language is a heuristic and will sometimes be wrong;
  # recording a constant is not a heuristic and was always wrong in one
  # direction. The refusal is the conservative side of the heuristic's error —
  # it never grants against the words, it only asks the closer to say which
  # refusal they mean.
  #
  # LIMITED TO `절단점=판단`, and the limit is not caution but availability. A
  # question's answer is prose, and the bytes extracted above ARE that prose.
  # An act approval's answer is binary and its `답변 문면` is a fixed literal,
  # so there is nothing extracted to scan — the only text on hand is `$ans`,
  # the whole transport frame, whose ids, paths and timestamps would make a
  # substring scan mostly noise. An act approval is refused by the closer
  # naming `--void` or `--reject`.
  #
  # THE QUESTION IS NOT PART OF THE ANSWER, AND IT IS ALWAYS IN THESE BYTES.
  # The transcript line was selected by requiring the approval id AND the
  # question text on it, so whenever the binding holds the question text is
  # inside `$abody` by construction. A judgment question is built from the
  # router's own `<기준> — <근거>`, so a standard reading "이 발견을 이번
  # 사이클에서 거절할지" put `거절` into the scanned bytes and the approval could
  # not be closed as a grant whatever the person wrote. Removing the question
  # first is the mirror of widening the vocabulary: one error grants against the
  # words, the other refuses regardless of them, and both scans must look at the
  # same bytes or the floor is two floors again.
  #
  # `$abody` ITSELF IS NOT TOUCHED. It is what goes into `답변 문면`, which the
  # contract calls the run's only durable copy of the answer; the split is
  # between what is scanned and what is recorded.
  if [ "$cutp" = "판단" ] && [ "$reject" = "0" ]; then
    scanbody=$(gate_strip_question "$abody" "$q")
    # Whitespace-only remainder means the line held the question and nothing
    # else — a person echoing the question is not an answer, and "no answer" and
    # "an answer that is no" are different states.
    if [ -z "$(printf '%s' "$scanbody" | tr -d '[:space:]')" ]; then
      warn "이 줄에서 질문 문면을 빼면 남는 답이 없습니다 — ${id} 을 승인으로도 거부로도 닫지 않고 대기로 둡니다"
      exit "$GATE_EXIT_APPROVAL"
    fi
    hit=$(gate_negative_answer_hit "$scanbody")
    if [ -n "$hit" ]; then
      warn "이 답은 부정으로 읽힙니다 (매치: ${hit}) — ${id} 을 승인으로 닫지 않습니다"
      warn "물었고 답이 아니오라면 close --reject 로, 애초에 물어서는 안 됐다면 close --void 로 닫으세요"
      exit "$GATE_EXIT_RULE"
    fi
    phit=$(gate_positive_answer_hit "$scanbody")
    if [ -z "$phit" ]; then
      warn "이 답에서 긍정도 부정도 읽어내지 못했습니다 — ${id} 은 대기로 남고 다음 판정에서 다시 봅니다"
      warn "긍정으로 인식하는 표현: 네 예 좋 승인 채택 진행 그렇게 해주세요 yes ok okay approve agreed go ahead"
      exit "$GATE_EXIT_APPROVAL"
    fi
  fi

  if [ "$reject" = "1" ]; then
    gate_append '승인' "승인 id=$id" "상태=거부" "질문 문면=$q" \
      "답변 문면=$abody" "해소 시각=$(now_iso)"
    log "승인 거부 — $id (물었고 답이 아니오입니다)"
    return 0
  fi

  gate_append '승인' "승인 id=$id" "상태=승인" "질문 문면=$q" \
    "답변 문면=$abody" "해소 시각=$(now_iso)"
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
# `TERMINAL_SEGMENT_STATES` — the enumeration and the reasoning behind its third
# element live in `liveness.sh`, sourced above. It is not re-declared here: the
# status line reads the same set through the same file, and a copy is how the
# render and this check came to disagree about the same segment.

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

  # 2 — no ACT approval still waiting. `절단점=판단` is excluded deliberately:
  # its answer is an input to work that has not begun, so it survives the night
  # and a successor run consumes it, while an act approval's answer is valid
  # only against the tree its binding tuple named. A run that could never end
  # while a question was open is the failure this whole design removes.
  n=$(gate_pending_approval_ids act | gate_count)
  [ "$n" = "0" ] || printf '2 대기 중인 행위 승인이 %s건 있습니다\n' "$n"

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
  # The fold itself lives in `liveness.sh` so that this condition and the status
  # line read one rule rather than two copies of it. What stays here is the
  # RENDERING: these two sentences are the only place a person is told how to
  # clear the block, so they are not the shared function's business.
  local reason cause
  cc_unresolved_blocked "$LEDGER" \
    | while IFS="$(printf '\t')" read -r cause reason; do
        [ -n "$reason" ] || continue
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

  # 10 — every authorized termination clause is settled.
  #
  # The other nine measure the ledger's SHAPE — segments terminal, approvals
  # closed, no damage, no live stage. None of them measures the thing the user
  # actually authorized the run against, so a run with five of six clauses
  # unsettled passed all nine and ended as `충족`. The clauses were frozen into
  # the binding digest at kickoff and then read by nothing: `종료 절` appeared
  # zero times in this file.
  for sid in $(gate_unmet_clause_ids); do
    [ -n "$sid" ] || continue
    # TERSE ON PURPOSE. Every unmet line is joined into the rejection row's
    # `근거` field, and that row has a 1024-byte cap — a verbose condition with
    # several clauses overflowed it and turned a rule refusal into a `die`. The
    # repair instruction belongs beside the refusal, not inside the row.
    printf '10 종료 절 %s 미정산\n' "$sid"
  done

  # 10b — the clause list is not EMPTY. Condition 10 iterates the parsed clauses
  # and reports the unsettled ones, so a manifest whose `종료 절` rows are spelled
  # such that none matches yields an empty list and the condition is satisfied
  # VACUOUSLY — the run can propose done the moment it starts, having been
  # measured against nothing. The `종료 지점` prose still reads correctly to a
  # person, which is why this passes every human check.
  #
  # This fires HERE and not in `check_manifest`, deliberately. A hard stop at
  # entry would refuse every manifest already written without clause rows —
  # including runs in flight, which is the failure mode two open issues in this
  # repository are about. Refusing the PROPOSAL instead costs nothing to a run
  # that never tries to end and blocks exactly the thing that was wrong.
  [ -n "$(manifest_clauses)" ] \
    || printf '10 매니페스트에 파싱되는 종료 절이 하나도 없습니다 — 종료 지점이 산문으로만 있어 이 런은 무엇에도 대조되지 않습니다\n'

  # 9 — no unfulfilled review obligation. Condition 3 does not subsume this:
  # 3 narrows when an EXISTING obligation is excused, and 9 holds the ones
  # `선머지후리뷰` deliberately deferred. This design's own four slices all
  # declare that mode, so the first run of it against itself takes this path.
  n=$(gate_unfulfilled_review_obligations | gate_count)
  [ "$n" = "0" ] || printf '9 미이행 리뷰 의무가 %s건입니다\n' "$n"
}

gate_pending_approval_ids() {
  # gate_pending_approval_ids [act|판단] — pending approval ids, optionally
  # narrowed by whether the row's `절단점` is the literal `판단`.
  #
  # The narrowing exists because the two kinds of answer have different lifetimes
  # and only one of them expires with the night. An ACT approval's answer is
  # valid now — its binding tuple carries head and base shas and freshness is
  # re-derived against them — so a run may not end while one is open. A QUESTION
  # approval's answer is an input to work that has not started; it is durable,
  # and a successor run can consume it. Counting the second kind in termination
  # condition 2 is what made one open question a run that could never say it was
  # done, which is the defect this design exists to remove.
  local want="${1:-}" id st row cut
  for id in $(gate_rows '승인' | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    row=$( { gate_rows '승인' | grep -F "승인 id=$id " || true; } | tail -1)
    st=$(gate_row_field "$row" '상태')
    [ "$st" = "대기" ] || continue
    if [ -n "$want" ]; then
      cut=$(gate_row_field "$row" '절단점')
      case "$want" in
        act)  [ "$cut" = "판단" ] && continue ;;
        판단) [ "$cut" = "판단" ] || continue ;;
      esac
    fi
    printf '%s\n' "$id"
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
  # Delegated. This is termination condition 7's only input, and condition 7 has
  # no resolving verb — so a pid that had been reused blocked the run's end
  # PERMANENTLY, since pid files are removed only when a stage exits normally.
  # `kill -0` alone cannot see that; the shared predicate compares the recorded
  # start-time fingerprint too.
  cc_live_stages "$RUN_DIR"
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
  # `act` AND NOT EVERY APPROVAL. This helper gained a narrowing argument and
  # three of its four call sites got one; this was the fourth, so `want` was
  # empty, the narrowing was skipped entirely, and a `절단점=판단` approval
  # counted here.
  #
  # Before questions could stay open past the night, every approval class that
  # could be open also counted toward termination condition 2, so the B1..B3
  # suspension was tied to the run's ability to end. Making a run able to end
  # with an open question cut that tie and left the suspension unbounded: one
  # grade-2 judgment at 22:10, with nobody awake to answer it — the premise of
  # this whole slice — switched off stagnation detection, obligation backlog and
  # the 40-act budget until the wall-clock deadline. The reason recorded for the
  # suspension ("waiting, not stalled") is false for this class specifically,
  # because the design promises the run keeps going alongside the question.
  local pending
  pending=$(gate_pending_approval_ids act | gate_count)

  if [ "$pending" = "0" ]; then
    gate_b1_stagnation
    gate_b2_obligations
    gate_b3_act_budget
  fi
  # B4 stays live even while waiting: cost can still climb.
  gate_b4_cost
}

gate_b1_stagnation() {
  # A RUN WITH A LIVE STAGE IS NOT STALLED, and without this the boundary fires
  # on every healthy run. The vector is manifest-derived plus segment rows plus
  # obligations plus cycles; a stage doing its work writes none of those, so the
  # digest is constant for as long as it runs — by construction, not by
  # accident. Any stage making four gate calls therefore issued B1 against
  # itself.
  #
  # And the false positive did not end there: an open approval suspends B1, B2
  # and B3, so one of these a few minutes into the first stage switched off
  # stagnation detection for the rest of the night. The three boundaries were
  # spent before they could do the thing they exist for.
  #
  # This is a suppression rather than a reset: the counter is left alone so that
  # a run which really does stop after its stages end still reaches the
  # threshold on the following judgements.
  local h prev n
  if [ "$(gate_live_stages)" != "0" ]; then
    return 0
  fi
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
  #
  # THE WINDOW IS THE WHOLE POINT, AND IT USED TO BE MISSING. The sentence above
  # said "since the last progress move" while the count ran over the entire
  # ledger from the run's first row, so the budget was a LIFETIME cap wearing the
  # name of a window. Past it the boundary fired on every judgment for the rest
  # of the run — and because the count is in the message, and the message is in
  # the approval id, each firing opened a NEW pending approval rather than
  # re-opening one. Every pending approval blocks termination condition 1 and
  # can only be closed by a person, so a run that crossed the budget could not
  # be finished at all: each act needed to reach the end re-armed the thing
  # stopping it. Measured at 71 against a budget of 40.
  #
  # The reset mirrors B1 and B2 — a digest of the progress vector beside the
  # count it belongs to. What differs is what is stored: B1 counts repeats of an
  # unchanged digest, while this counts acts SINCE that digest last changed, so
  # the companion file holds the baseline the current total is measured from
  # rather than a repeat tally.
  local n total prev base h
  # Positively selected, matching the progress vector: the grade must be present
  # and must not be `읽기`. Excluding `읽기` alone also counts a row carrying no
  # grade at all, and here that spends budget on an act nobody established was
  # above a read.
  total=$( { gate_rows '자율 승인' | grep '결정=exec' || true; } \
         | { grep -F '축2=' || true; } \
         | { grep -v '축2=읽기' || true; } | gate_count)
  h=$(gate_progress_digest)
  prev=$(cat "$RUN_DIR/act-budget-digest" 2>/dev/null || true)
  base=$(cat "$RUN_DIR/act-budget-base" 2>/dev/null || printf '0')
  # Progress moved: this act is the first of a new window, so the acts before it
  # are spent history and the baseline becomes the total as of now.
  if [ "$h" != "$prev" ]; then
    base="$total"
    printf '%s\n' "$h"     > "$RUN_DIR/act-budget-digest"
    printf '%s\n' "$base"  > "$RUN_DIR/act-budget-base"
  fi
  n=$((total - base))
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
    "행위 다이제스트=-" "구속 튜플=$name/$(gate_progress_digest)" "막는 세그먼트=-" \
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
