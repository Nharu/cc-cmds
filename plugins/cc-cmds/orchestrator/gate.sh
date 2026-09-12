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
#   prompt     the canonical question and menu the router must ask for one
#              approval, as JSON — changes nothing
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
#   8, 9  DELIBERATELY EMPTY. 9 is held by `GATE_APPROVAL_ANSWERED` as an
#      internal signal and 8 belongs to a rejection landing in a separate
#      change. A hole with no stated reason is read as a mistake and filled.
#  10  merge anchor unreadable — the segment row cannot say WHAT would be
#      merged. Not 2 (the argv is correct and the ledger row is wrong) and not
#      3 (this refusal is not in the catalog and survives turning the review
#      rule off). Repair the segment row and re-issue the same call.
#
# Usage:
#   gate.sh snapshot --manifest <path> [--render]
#   gate.sh grade    --manifest <path> -- <argv...>
#   gate.sh plan     --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> -- <argv...>
#   gate.sh act      --manifest <path> --kind <k> --target <alias> [--segment <id>]
#                    --cutpoint <token> --snapshot-digest <hex> --rationale <text>
#                    [--emit-digest] -- <argv...>
#   gate.sh exec     --manifest <path> --target <alias> [--segment <id>]
#                    --cutpoint <token> --surface <token>
#                    --snapshot-digest <hex> --rationale <text>
#                    [--emit-digest] -- <argv...>
#   gate.sh close    --manifest <path> --approval <id> [--void|--reject]
#   gate.sh prompt   --manifest <path> --approval <id>
#
# `close` reads the answer from the harness-written transcript by FRAME, not by
# text: the line must be the `tool_result` of an `AskUserQuestion` whose
# question carried the approval id (joined by `tool_use_id`) and must hold the
# harness's `toolUseResult.answers` map. For a judgment approval the answer is
# then compared by whole-string equality — recommendation suffix removed —
# against the gate's own labels (`승인`·`거부`·`무효`); `--void`/`--reject` may
# only agree with what the person chose. An answer equal to no label is FREE
# INPUT: the approval stays `대기` (exit 5), the answer is kept in the approval
# sidecar, and the row gains `처분 사유=자유 입력` so the morning can see it. Act
# and boundary approvals have no menu; the frame decides and the flag is the
# disposition, as before.
#
# `prompt` is how the router learns what to ask: `question` is the canonical
# `승인 <id> — <질문>` to carry verbatim into `AskUserQuestion`, and `options[]`
# are the labels to render verbatim (empty for act and boundary approvals).
#
# `--emit-digest` writes, after this call's LAST ledger row, a
# one-line JSON object
# `{"H":…,"obligations_total":…,"pending_approvals_total":…,"actor":…}` into
# `<run-dir>/digest/gate-digest-<actor>.json` — a path the GATE derives, so no
# caller names one,
# whose `H` is the value the NEXT acting call passes to `--snapshot-digest`, and
# whose `actor` is the emitting stage id verbatim (`router` when there is none)
# so a reader can tell a foreign emission from a stale one. It
# removes the read-back `snapshot` call, not the flag: the binding is unchanged
# and the digest is still compared against live state. `plan` emits nothing (it
# writes no row and performs nothing), and a caller that finds no file — an
# emission that failed, or a gate older than this flag — falls back to
# `gate.sh snapshot … | jq -r .H`. The flag is not passed unconditionally for
# that second reason: a gate that predates it exits 2 on the unknown argument.
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
# for. Its `--target` IS compared against that row's `대상` and a mismatch is
# exit 2 — the landing test runs in that target's anchor repository, so the wrong
# target measures the right commit in the wrong place and answers confidently.
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
# The banner emitter, sourced for the same reason as the two above. The watcher
# raises notices for this run as well, and a group string spelled two ways turns
# two runs into one slot — so the title, group and sound come from one file or
# they come from two that drift.
#
# It also owns the caller predicate this file needs, and every marker that
# predicate reads. The two existing checks here each read ONE of the stage
# variables, and a banner path built from either of those copies would raise a
# notice from a stage call while every test written against the other variable
# went on passing.
# shellcheck source=/dev/null
. "$GATE_DIR/notify-run.sh"

# ---------------------------------------------------------------------------
# THE SEAT QUESTION HAS ONE OWNER, AND IT IS NOT THIS FILE.
#
# `cc_caller_is_router` reads all three markers a non-router caller can carry:
# `CC_PIPELINE_SEGMENT` and `CC_PIPELINE_STAGE_ID` for a launched STAGE, and
# `CC_PIPELINE_SHIFT_ID` for a routing SHARD. The shard's marker was tested HERE
# for a while, and that arrangement is the defect this alias records rather than
# keeps: a test in this wrapper covers only the callers that come through it.
# Firing does; clearing does not, because `cc_notify_clear` calls the predicate
# directly. A shard was therefore refused a banner and still permitted to remove
# one — and removing is what decides what is on a person's screen right now.
#
# THE NAME SURVIVES THOUGH THE TEST MOVED. Seven firing sites call it, and
# leaving the alias in place means the fix touched none of them; an eighth site
# added later still reaches the one predicate its siblings already use.
# ---------------------------------------------------------------------------
gate_may_raise_banner() {
  cc_caller_is_router
}

readonly GATE_EXIT_VOCAB=2
readonly GATE_EXIT_RULE=3
readonly GATE_EXIT_STALE=4
readonly GATE_EXIT_APPROVAL=5
readonly GATE_EXIT_GRADE=6
readonly GATE_EXIT_SURFACE=7

# The act that declared a rung BELOW the one its own argv climbs. `ladder_of_argv0`
# reads a rung out of argv0 and its subcommand; where that derivation is STRICTLY
# HIGHER than `--cutpoint`, every consumer downstream was being handed a value the
# argv itself contradicts, and all of them open on the low side — the rule catalog
# never fires, the target's ceiling is never compared, the wall-clock deadline lets
# a merge through, an undeclared target gets registered, and no review obligation
# is issued. One misspelled word did all five.
#
# OVER-DECLARATION IS NOT REFUSED, and that asymmetry is the design rather than an
# omission. The router labels every act with its TARGET's cutpoint, so
# `--cutpoint 배포 -- git commit …` is the ordinary path all night; refusing it
# would be a wall rather than a check. The high declaration simply loses to the
# derived rung, and the ledger records both.
#
# NOT 3. A rule refusal is switchable — every catalog entry answers to a
# `## 룰 설정` line — and this refusal stands ABOVE the rule loop and survives all
# of them. NOT 6 either: `GATE_EXIT_GRADE` already carries two meanings whose
# prescriptions point in opposite directions ("do not re-declare to match" and
# "declare wider and retry"), and this is a third whose repair is "raise the
# declaration" — which, done on an act the target cannot authorize, lands on a
# DIFFERENT code entirely (`절단점-준수` answers 3). A code that cannot be stated
# truly in one sentence is a code the router cannot route at three in the morning.
readonly GATE_EXIT_LADDER=8

# The merge that cannot say what it merges. Issued when the review obligation's
# anchor — the tip of the segment worktree being merged — cannot be read, so the
# row that would be written could never be closed.
#
# 8 IS TAKEN by the under-declaration rejection declared directly above; 9 IS
# SKIPPED because `GATE_APPROVAL_ANSWERED` below already holds that value as an
# internal signal, and assigning it here would make one number both a sentinel
# and a contract code, falsifying the three comments in this tree that defend the
# sentinel. That gap is not an accident, and the router's exit-code table says so
# — a hole with no reason is read as a mistake and filled by the next person to
# add a code.
#
# NOT 2 and NOT 3. 2 tells the router to fix its argv, but here the argv is
# correct and the ledger's segment row is wrong, so a router obeying 2 retries
# the same argv into the same refusal forever. 3 says a rule refused, but this
# refusal is not in the catalog and survives `**리뷰-후-머지**: 끔` — reporting
# it as 3 would cancel, on the surface the router actually reads, the property
# that turning the rule off does not turn this off.
readonly GATE_EXIT_ANCHOR=10

# AN INTERNAL SIGNAL AND NOT AN EXIT CODE. `gate_issue_judgment_approval`
# returns it to say "this question already has an answer, so nothing was
# issued" — a state its callers must route rather than propagate, because the
# two of them route it in opposite directions. Kept out of the exit range on
# purpose: a value that escaped to the shell would tell the router a code the
# contract never defined.
readonly GATE_APPROVAL_ANSWERED=9

readonly GATE_ROW_MAX=1024

# ---------------------------------------------------------------------------
# The approval vocabulary and the answer-binding constants.
#
# `APPROVAL_STATES` IS THE SINGLE SOURCE OF TRUTH FOR `승인.상태`, the way
# run.sh's `CUTPOINTS` is for the cutpoint ladder, and
# `scripts/lint-approval-state-vocabulary.sh` reads it here. Six values. `기각`
# is written by nothing today and stays in the set anyway: the contract table
# is the authority and it does not drop a value for being unobserved, so a
# writer that needs it later finds a token instead of improvising one. `철회` is
# the state a boundary approval takes when the condition that raised it is gone
# — no clock, no answer; a person's later answer can still close it — and today
# it is ACCEPTED here and REQUIRED nowhere: the one transition into it lives
# beside the boundary predicates and lands with them, not with this vocabulary.
# ---------------------------------------------------------------------------
readonly APPROVAL_STATES="대기 승인 거부 무효 기각 철회"

gate_check_approval_state() {
  # gate_check_approval_state <state> — 0 when the token is in the closed set.
  case " $APPROVAL_STATES " in *" $1 "*) return 0 ;; esac
  warn "승인 행의 「상태」가 어휘 밖입니다: ${1:-없음} — 허용 토큰: ${APPROVAL_STATES}"
  return "$GATE_EXIT_VOCAB"
}

# The menu a judgment approval is asked with. THE GATE OWNS THE LABELS and the
# router renders them verbatim: an answer is read by whole-string equality
# against this set, never by scanning prose for a word that sounds like yes.
# `gate_menu_labels` prints the three in order; `gate_menu_description` prints
# the one-line description the router puts beside each. The version token goes
# into the binding tuple so a row says which menu it MEANT — the row is a
# pointer to this table, and the table is what an answer is compared against.
readonly GATE_MENU_VERSION=v1

gate_menu_labels() { printf '승인 거부 무효'; }

gate_menu_description() {
  case "$1" in
    승인) printf '이 판단을 채택합니다 — 게이트가 승인 행을 쓰고 런이 그 답으로 이어갑니다' ;;
    거부) printf '물었고 답은 아니오입니다 — 이 판단은 채택되지 않습니다' ;;
    무효) printf '애초에 물어서는 안 됐던 질문입니다 — 행위 없이 승인만 닫습니다' ;;
    *) return 1 ;;
  esac
}

gate_menu_normalize() {
  # gate_menu_normalize <label> — the label with its recommendation suffix
  # dropped. The AUQ authoring rule this repo lints for marks the recommended
  # option by appending ` ← 추천` or ` ← 에이전트 추천` to the label ITSELF, so
  # the transcript's `options[].label` and the answer a person chose both read
  # `승인 ← 추천` while this table says `승인`. Compared raw, a healthy answer
  # fails the menu check or falls through to the free-input rung. The suffix
  # is removed at comparison time and never added to the table.
  printf '%s' "${1%% ← *}"
}

# EXCERPT LENGTHS, DERIVED BY ARITHMETIC AGAINST `GATE_ROW_MAX` and not chosen
# for readability. Measured worst rows: issue 738B, close(승인) 993B, close(무효)
# 635B. With the fields this design adds — a filled binding tuple, a sidecar
# anchor, a response token, an answer digest — a 256-byte answer excerpt puts a
# `승인` close row at 1034B, over the cap. 160 leaves the thinnest row (`무효`
# close) roughly 61 bytes of headroom. The question excerpt keeps its 400: the
# arithmetic above was done on that premise, and what this design discards is
# the raw-line CLIP PATH, not the clip length.
readonly GATE_Q_EXCERPT=400
readonly GATE_A_EXCERPT=160
readonly GATE_REASON_EXCERPT=120
# The snapshot component of a judgment binding tuple is the first 12 of the
# snapshot digest — the `head 12자` convention the act tuple already uses. The
# full 129-byte value would leave an issue row 26 bytes under the cap.
readonly GATE_TUPLE_SNAP_LEN=12

# The harness's own words for a dismissed dialog. A `tool_result` carrying
# `is_error` AND this exact string means a person was at the screen and closed
# the question without choosing; any other `is_error` says only that the call
# collapsed, cause unobserved. The two get different warnings because they are
# opposite evidence about whether a person is present.
readonly GATE_DISMISSAL_TEXT="The user doesn't want to proceed with this tool use"

# HOW FAR BACK AN OBSERVED TIP MAY SIT AND STILL COUNT AS AN ANCESTOR. The tip
# axis accepts a value the chain has since grown past, which is what a
# concurrent writer leaves behind. Unbounded, it also accepted a value read
# hours earlier — and the state changes that make a held digest dangerous (a
# pending approval opened, a stage crashed, a run-scope park, a broken chain, a
# handoff) move no component of the progress vector, so nothing else refuses
# them either. The bound is what keeps "somebody appended just now" from meaning
# "anything that ever happened".
#
# K IS A BOUND ON CONCURRENT WRITERS AND NOT ON TIME. An observed tip T is
# carried by the FIRST row appended after it, so if n rows landed between the
# read and the act, T sits n rows from the end and the admission condition is
# n <= K. The measured storm was at most four consecutive refusals against a
# single command in one session, so the observed n topped out at 4; this is
# twice that. The slack is deliberate and the asymmetry is the reason: too low
# refuses a legitimate concurrent writer, which is the refusal storm the split
# was written to end, while a few rows too high only narrows a check that
# previously did not narrow at all slightly later than it could have. A night's
# ledger runs to hundreds of rows, so a single digit still puts "read hours ago"
# far outside — measured against a live 107-row ledger, eight rows is a few
# minutes.
#
# DO NOT RAISE THIS TO MAKE A REFUSAL GO AWAY. Raised far enough it restores the
# unbounded behaviour while leaving no trace that it was restored; the honest
# way back is to change what the window MEANS, deliberately, not its number.
readonly GATE_ANCESTRY_WINDOW=8

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

surface_of_eas() {
  # Expo Application Services CLI. A build is a billed job on someone else's
  # machines, `update` publishes over the air to installed apps, and the
  # channel/branch verbs write server records — every one of those outlives the
  # run directory, so the DEFAULT here is `외부상태변경` and not an unknown
  # grade. Measured: with no row at all every spelling fell to `등급 미상`,
  # which refuses outright rather than issuing an approval, and that closed all
  # three ways out at once — `--surface` is a checked claim and any claim
  # mismatches an unknown grade, the basename normalization makes the
  # absolute-path spelling identical, and `bash -c` would record a paid cloud
  # build as a worktree write. A run holding the `배포` cutpoint could not reach
  # its own apply command at all.
  #
  # Split by subcommand, the way `git` and `gh` are and unlike the CI/CD trigger
  # below, because this CLI spells the read/write distinction in the subcommand
  # itself: the `:view` and `:list` forms query, the bare verbs act. That split
  # is load-bearing rather than tidy — a manifest that declares
  # `적용 주체: 파이프라인` must also declare an apply PROBE, and the probe for a
  # channel is `eas channel:view`. Without the split the probe would need a
  # pre-authorization row naming the same argv prefix as the apply, which grants
  # the apply as a side effect of declaring the check for it.
  #
  # The unrecognized arm is the top of the range, not the bottom. Guessing low
  # on a verb this table does not name is the laundering the whole table exists
  # to stop, and guessing high costs one line in the manifest.
  case "${1:-}" in
    ''|-v|-h|--version|--help) printf '읽기' ;;
    whoami|config|diagnostics)  printf '읽기' ;;
    *:view|*:list|*:info)       printf '읽기' ;;
    *)                          printf '외부상태변경' ;;
  esac
}

surface_of_openssl() {
  # The subcommand decides, for the reason the digest row states in as many
  # words: this one name covers hashing, key generation, file conversion and
  # opening a socket, so a name-level grade would have to pick one of four.
  #
  # The default is the TOP of the range, not the bottom. An unrecognized
  # subcommand is refused rather than read as harmless, because the subcommands
  # this table does not name include `s_client` and `s_server` — and a grade
  # that guesses low on those is the laundering the whole table exists to stop.
  #
  # `-out <path>` is checked across every arm, not per subcommand. `rand` and
  # `dgst` both accept it, so an arm that graded `rand` as a read on the
  # strength of its name alone would let `openssl rand -out secrets.bin 32`
  # through as one.
  case " $* " in *" -out "*|*" -keyout "*) printf '워크트리쓰기'; return 0 ;; esac
  case "${1:-}" in
    rand|dgst|sha256|sha1|version|list|help) printf '읽기' ;;
    '') printf '읽기' ;;
    *) printf '등급 미상' ;;
  esac
}

gate_orchestrator_script_hint() {
  # gate_orchestrator_script_hint <argv0> — one extra warn line when an ungraded
  # argv0 names a script this plugin SHIPS.
  #
  # `등급 미상` is the table's answer for every name it does not carry, so two
  # very different situations arrive wearing the same string: a tool nobody has
  # ever added a row for, and a script this plugin SHIPS whose row landed in a
  # commit this gate copy does not have. The second one is not the caller's
  # mistake and there is nothing for them to respell — the run is being
  # adjudicated by a gate older than the tree it is adjudicating, because the
  # hook takes the gate as a runtime parameter and nothing requires that copy to
  # be the one under review.
  #
  # Measured: a slice added a script and its grading row in one commit; the run
  # reviewing that slice was adjudicated by a different, dirty checkout without
  # the row. Both exits from the refusal were bad — an interpreter in front
  # passes while restoring the very laundering the row existed to stop, and the
  # honest fallback drops an artifact — and the refusal text said nothing that
  # would let a reader tell this apart from an unknown tool.
  #
  # WHAT IS LOOKED AT IS THE CALLER'S PATH, NOT THIS GATE'S NEIGHBOURS. The
  # first version of this checked whether a file of the same basename sat next
  # to the gate, and that check can never fire in the case it was written for: a
  # script and its grading row land in the SAME commit, so a copy without the
  # row has no such file either. "No row" implies "no neighbour", which makes
  # the miss structural rather than unlikely — the only window it did fire in
  # was a partially applied checkout, which is not the motivating case at all.
  #
  # The observable that survives is the ARGV0 THE CALLER HANDED OVER. The
  # grading table throws the path away and matches on the basename, but the path
  # is still right here: a caller in the newer tree passes something that
  # resolves, and its parent directory is this plugin's `orchestrator/`. That is
  # precisely the skew — the caller's tree has the script, this gate does not
  # have the row.
  #
  # The neighbour test is KEPT as a second trigger rather than replaced, because
  # it covers what the path test cannot: an argv0 given as a bare name, with no
  # path to inspect. Either one alone leaves a hole the other closes.
  #
  # A false positive costs one advisory sentence, so both tests are loose on
  # purpose. What they must not be is silent in the normal case, which is what
  # the first version was.
  local b="${1##*/}" hit='' parent=''
  case "$b" in
    *.sh) ;;
    *) return 0 ;;
  esac
  case "$1" in
    */*)
      if [ -f "$1" ]; then
        parent=$(cd "$(dirname "$1")" 2>/dev/null && pwd) || parent=''
        case "$parent" in
          */orchestrator) hit="$1" ;;
        esac
      fi ;;
  esac
  if [ -z "$hit" ] && [ -f "$GATE_DIR/$b" ]; then hit="$GATE_DIR/$b"; fi
  [ -n "$hit" ] || return 0
  warn "그 이름은 이 플러그인이 싣는 오케스트레이터 스크립트입니다 ($hit) — 모르는 도구가 아니라 이 게이트 사본이 그 등급 행을 실은 트리보다 낡았다는 뜻입니다. 판정에 쓰이는 게이트는 $GATE_DIR/gate.sh 이고, 다른 사본의 등급표를 고쳐도 이 판정은 바뀌지 않습니다. 인터프리터를 앞에 붙이거나 더 낮은 철자로 우회하지 마세요 — 전자는 통과하면서 그 행이 막으려던 것을 되살리고, 후자는 산출물을 잃습니다"
}

surface_of_argv0() {
  local cmd="${1##*/}"
  shift
  case "$cmd" in
    # This column has no way to run some other command. `which git merge` is a
    # read and rightly so — it looks a name up and prints it.
    cat|ls|grep|head|tail|wc|stat|file|diff|which)
      printf '읽기' ;;
    # THESE THREE RUN WHAT THEY WRAP, so a name cannot answer for them. They sat
    # in the read row above and graded `읽기` unconditionally, which made
    # `command git merge` an HONESTLY declared read — and the review rule exits
    # on the read grade before it ever reaches the history-integration predicate,
    # so a wrapped merge was exempted from the review requirement outright.
    # Widening that predicate cannot reach this: the exemption happens one layer
    # up, in the grade. Measured on this tree, with the rule's read early-return
    # standing fifteen lines above the line that first reads the predicate.
    #
    # DELEGATED, NOT DELETED FROM THE TABLE. Dropping the three names answers
    # `등급 미상`, which refuses — every ordinary `find` and `rg` read in this
    # pipeline would stop, including the walks over the manifest's own directory
    # the guard below is written to keep passing. And a maintainer who hits that
    # puts the names back on the read row, which reopens this hole exactly as it
    # was. The delegation form is the one `git`, `gh` and `lockf` already use.
    command) surface_of_command "$@" ;;
    find)    surface_of_find "$@" ;;
    rg)      surface_of_rg "$@" ;;
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
    # Witness primitives. The same DEADLOCK shape as the digest tools above, one
    # layer out: the agent-team protocol requires a scratch directory and a
    # CSPRNG nonce before any member is spawned, and it forbids the model
    # generating that nonce itself. With no row here every spelling was refused,
    # so a review stage could not reach the point of dispatching its team at all
    # — and the merge rule wants a review record, so one missing row closed the
    # whole back half of the pipeline. Measured: a review stage arrived, tried
    # `mktemp -d`, `openssl rand`, `uuidgen`, `xxd` and `od` in turn, was refused
    # on every one, and halted before spawning.
    #
    # `uuidgen` takes no file operand and writes nothing, so its grade is the
    # same as reading. `mktemp` DOES write, and where it writes depends on a
    # template it may or may not be given, so it takes the higher of the two
    # spellings rather than a guess — `트리밖쓰기` covers a tree path too.
    #
    # `xxd` and `od` stay out. They were tried here only as nonce fallbacks and
    # are not needed once the two above resolve; `xxd` also takes an output file
    # as its second operand, so a bare-name grade would be the same imprecision
    # the `openssl` note below refuses.
    uuidgen)
      printf '읽기' ;;
    mktemp)
      printf '트리밖쓰기' ;;
    # The team witness directory, minted by one script rather than by four
    # statements the caller has to run in a single shell. Same grade as the
    # `mktemp` above because that is what it does — it roots under the driver's
    # run directory or the system temp dir, both out of tree, and writes one
    # `.attempt` file inside the directory it just made. Nothing under the
    # worktree is touched on any path.
    #
    # THE ROW IS WHAT MAKES THE HONEST DECLARATION POSSIBLE. Four statements in
    # one call is `bash -c`, and `bash` is graded a worktree write below without
    # inspecting what it wraps; the comparator is strict equality, so declaring
    # the effect that actually happens was refused exactly as laundering is
    # refused. The caller was left choosing between a false declaration and not
    # running.
    cc-team-witness-init.sh)
      printf '트리밖쓰기' ;;
    # The note above says `openssl` may not sit in the digest row because one
    # name would cover both hashing and opening a socket. That reasoning holds
    # and is not overturned here — it is the reason this is a subcommand table
    # rather than a name, the same shape `git`, `gh` and `terraform` already use.
    openssl) surface_of_openssl "$@" ;;
    eas|eas-cli) surface_of_eas "$@" ;;
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

    # CI/CD triggers. Same shape as the database clients above and the same
    # measured failure: a run whose target carries the `배포` cutpoint reached
    # its apply command and was refused, because the manifest's apply command is
    # a site-local script and no row named it. `등급 미상` refuses rather than
    # issuing an approval, so all three ways out were closed at once —
    # `--surface` is a checked claim and every claim mismatches an unknown
    # grade, the basename normalization makes the absolute-path spelling
    # identical, and `bash -c` would record a production deploy as a worktree
    # write, which is the laundering this table exists to refuse. The run could
    # not deploy at all despite holding the cutpoint that authorizes it.
    #
    # Graded `외부상태변경` from argv0 alone, so a read-only probe of the same
    # script (`--probe`) grades the same way. That is the intended side of the
    # trade: a probe needing a pre-authorization row costs a line in the
    # manifest, while a deploy passing as a read costs the environment.
    dasee-jenkins-trigger.sh)
      printf '외부상태변경' ;;
    *) printf '등급 미상' ;;
  esac
}

gate_unwrap_lockf() {
  # gate_unwrap_lockf <resolver> <lock-only> <unknown-opt> [-k] [-s] [-t <sec>] <lockfile> <command> [args...]
  #
  # Skip lockf's own options and its lockfile operand, then hand what is left to
  # <resolver>. `-t` takes a value; `-k`, `-s` and `-n` do not. The lockfile is
  # the first non-option word and is never itself the command.
  #
  # ONE UNWRAP SHARED BY TWO TABLES. The grader and the history-integration
  # predicate both have to see through `lockf`, and while each carried its own
  # skip loop the two could resolve the SAME argv differently — a wrapped local
  # merge graded `워크트리쓰기` while the predicate answered "not an integration"
  # and exempted it from the review rule. Only the terminal answers differ, so
  # only those are parameters: the grader passes `워크트리쓰기`/`등급 미상`, the
  # predicate passes `0`/`1`.
  #
  # ARGV0 IS ALREADY GONE. `surface_of_argv0` drops it before dispatching and the
  # lockf arm of the predicate drops it explicitly, so this loop starts at the
  # first option. The old code shifted a SECOND time here, which ate whatever
  # stood first: `lockf <file> git status` then read `git` as the lockfile and
  # graded `status` alone, and `lockf -t 5 <file> git commit` read `5` as the
  # lockfile. Both are the shapes the fixtures below now pin.
  local resolver="$1" lock_only="$2" unknown_opt="$3"; shift 3
  local seen_file=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # `-t` with no value after it emits NOTHING, which is what this did before
      # it was factored out. Repairing that here would mix a second change into
      # the one these fixtures measure.
      -t) shift 2 || return 0 ;;
      -t*) shift ;;
      -k|-s|-n) shift ;;
      -*) printf '%s' "$unknown_opt"; return 0 ;;
      *)
        if [ "$seen_file" = 0 ]; then seen_file=1; shift; continue; fi
        "$resolver" "$@"
        return 0 ;;
    esac
  done
  # A lock with nothing after it locks and exits — that is a worktree write (it
  # creates the lockfile) and there is no wrapped command to defer to.
  [ "$seen_file" = 1 ] && { printf '%s' "$lock_only"; return 0; }
  printf '%s' "$unknown_opt"
}

surface_of_lockf() {
  # surface_of_lockf <lockf-args-after-argv0...>
  gate_unwrap_lockf surface_of_argv0 '워크트리쓰기' '등급 미상' "$@"
}

gate_unwrap_command() {
  # gate_unwrap_command <resolver> <no-exec> <unknown-opt> <command's args after argv0...>
  #
  # `command` skips shell functions and aliases and runs the NEXT word. Its own
  # options are `-p` (default PATH) and `-v`/`-V`, which print what would run and
  # execute nothing. Everything after that belongs to the wrapped command.
  #
  # THE SAME ONE-UNWRAP-TWO-TABLES SHAPE AS `gate_unwrap_lockf`, and for the same
  # reason: the grader and the history-integration predicate both have to see
  # through this word, and two copies of the skip loop are two chances for them
  # to disagree about which word is the command. Only the terminal answers are
  # parameters — the grader passes `읽기`/`등급 미상`, the predicate `0`/`1`.
  local resolver="$1" no_exec="$2" unknown_opt="$3"; shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -v|-V|-pv|-pV|-vp|-Vp) printf '%s' "$no_exec"; return 0 ;;
      -p) shift ;;
      --) shift; break ;;
      -*) printf '%s' "$unknown_opt"; return 0 ;;
      *)  break ;;
    esac
  done
  [ "$#" -ge 1 ] || { printf '%s' "$no_exec"; return 0; }
  "$resolver" "$@"
}

gate_unwrap_find() {
  # gate_unwrap_find <resolver> <walk-only> <writes> <find's args after argv0...>
  #
  # Two ways a `find` writes. Four primaries hand the match to another command,
  # and five act on their own — `-delete` removes the match, while `-fprintf`,
  # `-fprint`, `-fprint0` and `-fls` each open a file named in argv and write to
  # it. The last four are GNU-only, so on a BSD host `find` rejects them before
  # anything happens; on the Linux CI runner they are the cheapest way to
  # overwrite a file through a command that argv0 alone grades as a read.
  # THE OPTION SET IS NOT INVENTED HERE — it is the one this file already carries
  # in both write guards below, and a fifth spelling of the same list is how
  # those two quietly drift apart.
  #
  # THIS LIST IS NOT CLAIMED TO BE COMPLETE. It is the set the two guards below
  # enforce, and the three have to be changed together; a reader checking one
  # against the others finds them equal, which says nothing about whether some
  # sixth primary writes.
  #
  # A PLAIN `find` WITH NO PRIMARY KEEPS COMING BACK `읽기`. The manifest guard
  # states that cost in place: without it every read that walks the manifest's
  # directory becomes a refusal.
  local resolver="$1" walk_only="$2" writes="$3"; shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -exec|-execdir|-ok|-okdir)
        shift
        [ "$#" -ge 1 ] || { printf '%s' "$writes"; return 0; }
        "$resolver" "$@"
        return 0 ;;
      -delete|-fprintf|-fprint|-fprint0|-fls) printf '%s' "$writes"; return 0 ;;
      *) shift ;;
    esac
  done
  printf '%s' "$walk_only"
}

gate_unwrap_rg() {
  # gate_unwrap_rg <resolver> <search-only> <truncated> <rg's args after argv0...>
  #
  # `--pre` names a program every searched file is fed through before the search.
  # The value is one program and takes no arguments of its own, so exactly that
  # one word goes to the resolver.
  local resolver="$1" search_only="$2" truncated="$3"; shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pre)
        shift
        [ "$#" -ge 1 ] || { printf '%s' "$truncated"; return 0; }
        "$resolver" "$1"
        return 0 ;;
      --pre=*)
        "$resolver" "${1#--pre=}"
        return 0 ;;
      *) shift ;;
    esac
  done
  printf '%s' "$search_only"
}

# The grader's terminal answers. They point the OPPOSITE way from the
# predicate's, which is deliberate and is the discipline the two-table comment
# below already sets: this table answers `등급 미상` to what it does not
# understand and the gate refuses, while the predicate answers `1` and keeps the
# act under the check.
surface_of_command() { gate_unwrap_command surface_of_argv0 '읽기' '등급 미상' "$@"; }
surface_of_find()    { gate_unwrap_find    surface_of_argv0 '읽기' '워크트리쓰기' "$@"; }
surface_of_rg()      { gate_unwrap_rg      surface_of_argv0 '읽기' '등급 미상' "$@"; }

gate_history_integration() {
  # gate_history_integration <argv...> — prints 1 when this argv integrates one
  # line of history into another, 0 when it does not.
  #
  # THIS EXISTS BECAUSE THE GRADED SURFACE CANNOT SPLIT ITS OWN WORKTREE-WRITE
  # CELL. The table below grades a local `merge`, `rebase` and `cherry-pick` as
  # `워크트리쓰기`, and the same cell holds `mkdir` and `touch`. Exempting the
  # cell lets a local merge carry an honest segment and pass the review rule
  # with no review record at all; checking the cell whole demands a review
  # record from an ordinary directory creation, and that is not an edge case —
  # the router labels every act with its TARGET's cutpoint, so an ordinary write
  # declared at `배포` is the normal path, not noise.
  #
  # THE SPLITTING VALUE IS READ FROM argv AND NEVER FROM A DECLARATION. `--kind`
  # has no vocabulary check, so any word at all rides there; and `exec` refuses
  # `--kind` outright, so under that verb the kind is always the empty string.
  # A cell split on the kind would therefore exempt both `exec -- git merge` and
  # `act --kind x -- git merge`, which is the surface-exemption hole surviving
  # with nothing changed but the axis it hides behind.
  #
  # AN UNRECOGNIZED SPELLING ANSWERS 1, AND THAT IS WHY THIS IS NOT A SECOND
  # COPY OF THE GRADING TABLE. That table answers `등급 미상` and refuses; this
  # one answers "check it". The two therefore fail in OPPOSITE directions, so
  # where they drift the drift can only over-check — one manifest line — and
  # never open the bypass this rule exists to close.
  #
  # THE argv0 LAYER IS A TABLE, NOT AN EQUALITY AGAINST `git`. Comparing argv0
  # to one name answered 0 for every wrapper, so both spellings that reach the
  # `워크트리쓰기` CELL without the grading table seeing what they wrap fell out
  # of the check entirely: `lockf … git merge` and `bash -c 'git merge …'` each
  # graded `워크트리쓰기` and each answered "not an integration". That is the
  # exemption this predicate exists to close, reached by the shortest possible
  # detour.
  #
  # THAT COUNT IS SCOPED TO THAT CELL AND TO NOTHING ELSE. Stated without the
  # scope it reads as a census of every wrapper this file is blind to, and it
  # never was one — the sentence stood unscoped here while three more wrappers
  # were escaping through a DIFFERENT cell, and a maintainer reading it went
  # looking for the leak in the argv0 list below, where it could not be. The
  # three were `command`, `find` and `rg`: each runs some other command, each was
  # graded `읽기` from argv0 alone, and the review rule exits on the read grade
  # fifteen lines before it first reads this predicate. So `command git merge`
  # declared `읽기` honestly, agreed with its own grade, and was exempted with
  # this predicate never consulted. Widening the list below could not have
  # touched it.
  #
  # They are fixed in the grading table instead (`surface_of_command`,
  # `surface_of_find`, `surface_of_rg`), and the arms below consume those SAME
  # unwraps so the two tables cannot disagree about which word was wrapped. IF A
  # WRAPPER IS ESCAPING THIS CHECK, LOOK AT ITS GRADE FIRST — the grade decides
  # whether the rule ever gets here.
  local cmd="${1##*/}"
  case "$cmd" in
    # `lockf` wraps, so unwrap it with the same routine the grader uses and ask
    # this question of what it wrapped. Sharing the unwrap is the point: two
    # copies of the skip loop are two chances for the tables to disagree about
    # which word is the command.
    lockf)
      shift
      gate_unwrap_lockf gate_history_integration '0' '1' "$@"
      return 0 ;;
    # The three the grading table now sees through. THIS HALF IS NOT OPTIONAL:
    # move `command git merge` into `워크트리쓰기` and leave this predicate
    # answering 0, and the review rule exempts it again on the very next line —
    # the repair would be green and inert. The unwraps are shared with the grader
    # for the reason the `lockf` arm above gives.
    command)
      shift
      gate_unwrap_command gate_history_integration '0' '1' "$@"
      return 0 ;;
    find)
      shift
      gate_unwrap_find gate_history_integration '0' '1' "$@"
      return 0 ;;
    rg)
      shift
      gate_unwrap_rg gate_history_integration '0' '1' "$@"
      return 0 ;;
    # Names the grading table answers `워크트리쓰기` WITHOUT asking what they
    # wrap. This predicate cannot parse a shell word without being a shell, so
    # it answers 1 rather than guessing — the direction the paragraph above
    # already commits to, where drift can only over-check. What that costs is
    # bounded: the review rule exits before asking for a record unless the
    # target's cutpoint is at or above `머지`.
    bash|sh|zsh|make|npm|npx|yarn|pnpm|pytest|go|cargo|python3|node)
      printf '1'; return 0 ;;
    git) ;;
    *) printf '0'; return 0 ;;
  esac
  shift
  # The same global-option skip the grader does, spelled the same way, because a
  # global option left in place puts a non-subcommand in the slot below. The one
  # divergence is the unknown arm, for the reason given above.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        [ $# -ge 2 ] || { printf '1'; return 0; }
        shift 2 ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
        shift ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects)
        shift ;;
      --literal-pathspecs|--no-optional-locks|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        shift ;;
      -*) printf '1'; return 0 ;;
      *)  break ;;
    esac
  done
  # `merge-base` is a query and is NOT on this list — `case` matches whole
  # patterns, so it does not reach the `merge` arm. `pull` is here even though
  # the grader puts it in `외부상태변경`, a cell this split never reaches: the
  # list states what the predicate MEANS rather than what the caller happens to
  # ask about, and a predicate that omits a case because today's caller cannot
  # reach it is one refactor away from being wrong.
  #
  # `reset` IS ON THE LIST EVEN THOUGH ITS NAME DOES NOT DECIDE. Aimed at another
  # ref it moves this branch onto another line of history, which is the thing
  # this predicate names; aimed at nothing but `--hard` it only discards local
  # work. Telling those apart means telling a ref operand from a pathspec, and
  # that needs the repository — so the name goes on the list and the cost is an
  # over-check. `revert` stays OFF: it writes a new commit on this branch undoing
  # one already in this branch's history, so no second line is integrated.
  case "${1:-}" in
    merge|rebase|cherry-pick|am|pull|reset) printf '1' ;;
    *) printf '0' ;;
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
    # `project` sits beside `issue` because filing an issue and putting it on the
    # board are one obligation, not two. A run that files the issue and then
    # cannot reach the board leaves the tracking half-done in the direction that
    # hides itself: the issue exists, so nothing looks missing, and it is absent
    # from the only place the items are enumerated. Measured — three issues were
    # filed and all three `item-add` calls came back `등급 미상`.
    pr|issue|project|release|repo|workflow|run) printf '외부상태변경' ;;
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
# The permission RUNG argv itself claims — a second reading of the same argv,
# answering a different question from the grading table above.
#
# Axis 2 asks "how far out of this worktree does this reach"; this asks "which
# rung of the permission ladder does this climb". They are orthogonal: `gh pr
# merge` and `curl` share the `외부상태변경` cell and only one of them is a merge.
#
# THE RETURN IS A `CUTPOINTS` TOKEN OR THE EMPTY STRING, and never an integer and
# never a `등급 미상`-shaped sentinel. An integer would put a copy of the ladder's
# ORDER here, which is the drift `gate_export_cutpoints` already refuses on the
# checkers' behalf. A sentinel is worse: to be comparable it would have to enter
# `CUTPOINTS`, and then every caller of `cutpoint_index` — seventeen of them
# across this file and `run.sh` — acquires an exception. The empty string asserts
# nothing and needs no rung, so the comparison below simply does not run.
#
# THE DEFAULT IS SILENCE, AND IT POINTS THE OPPOSITE WAY FROM THE GRADING TABLE.
# That table answers `등급 미상` to what it does not recognize and the gate
# refuses, because guessing low there is the laundering it exists to stop. Here
# guessing HIGH is what costs: an over-derivation is a refusal the run cannot
# widen — `리뷰-후-머지` is a refusal and not a delay — so a wrong high answer
# bricks the night, while the empty string falls back to the declared value,
# which is exactly today's behaviour.
#
# WHAT THIS TABLE DELIBERATELY STAYS SILENT ABOUT, and the silence is load-bearing.
# `git push`, `git merge` and `git branch` have no row. A refspec's destination
# decides whether a push IS the merge, and knowing that means reading the
# manifest's target row — which this table does not do and must not start doing,
# because it runs before target resolution. Worse, guessing `push` for them turns
# an honestly declared `--cutpoint 머지` into an OVER-declaration and drags the
# effective rung DOWN below the merge rung, switching off the review rule and the
# obligation issuer for the very act they exist to cover.
ladder_of_argv0() {
  [ "$#" -ge 1 ] || return 0
  local cmd="${1##*/}"
  shift
  case "$cmd" in
    # The four wrappers run some other command, so a name cannot answer for them.
    # The unwraps are SHARED with the grading table and the history-integration
    # predicate rather than re-spelled, for the reason `gate_unwrap_lockf` states:
    # two copies of a skip loop are two chances to disagree about which word is
    # the command. Only the terminal answers are parameters, and both of this
    # table's are the empty string — a wrapper whose payload cannot be read
    # asserts nothing, the same as any other name with no row.
    lockf)   gate_unwrap_lockf   ladder_of_argv0 '' '' "$@" ;;
    command) gate_unwrap_command ladder_of_argv0 '' '' "$@" ;;
    find)    gate_unwrap_find    ladder_of_argv0 '' '' "$@" ;;
    rg)      gate_unwrap_rg      ladder_of_argv0 '' '' "$@" ;;
    git)       ladder_of_git "$@" ;;
    gh)        ladder_of_gh "$@" ;;
    terraform) ladder_of_terraform "$@" ;;
    *) : ;;
  esac
  return 0
}

ladder_of_git() {
  # The SAME global-option skip `surface_of_git` performs, spelled the same way,
  # because a global left in place puts a non-subcommand in the slot below. The
  # unknown arm diverges: that table answers `등급 미상` and refuses, this one
  # answers silence and defers to the declaration.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        [ $# -ge 2 ] || return 0
        shift 2 ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
        shift ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects)
        shift ;;
      --literal-pathspecs|--no-optional-locks|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        shift ;;
      -*) return 0 ;;
      *)  break ;;
    esac
  done
  case "${1:-}" in
    # `커밋` is the BOTTOM rung, so this row can never produce an
    # under-declaration — its only effect is to pull an over-declared commit back
    # down to what it is. That is the common case rather than a corner: the
    # router labels an ordinary commit with its target's cutpoint.
    commit) printf '커밋' ;;
    # `push`, `merge`, `branch` are deliberately absent — see the note above.
    *) : ;;
  esac
  return 0
}

ladder_of_gh() {
  case "${1:-}" in
    api) ladder_of_gh_api "$@" ;;
    pr)
      case "${2:-}" in
        merge)  printf '머지' ;;
        create) printf 'PR' ;;
        # `view`, `list`, `review`, `comment` and everything else this row does
        # not name assert nothing. Naming them would be guessing, and the guess
        # that costs is the high one.
        *) : ;;
      esac ;;
    *) : ;;
  esac
  return 0
}

ladder_of_gh_api() {
  # `gh pr merge` is not the only spelling of a merge — `gh api -X PUT
  # repos/o/r/pulls/1/merge` is the same act through the other door, and it is
  # the door a run takes when it wants the merge method spelled out. So the same
  # method resolution `surface_of_gh_api` does is done here, and the PATH decides
  # on top of it: a non-GET against `…/pulls/<n>/merge` is a merge, and every
  # other endpoint asserts nothing.
  shift
  local m="" body=0 path=""
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
      # The first bare word is the endpoint. Anything later is a positional this
      # table has no use for, so the first one wins and the scan continues —
      # stopping here would leave a trailing `-X` unread.
      -*) shift ;;
      *)  [ -n "$path" ] || path="$1"; shift ;;
    esac
  done
  if [ -z "$m" ]; then
    if [ "$body" = "1" ]; then m=POST; else m=GET; fi
  fi
  case "$m" in GET|get|HEAD|head) return 0 ;; esac
  case "$path" in
    */pulls/*/merge) printf '머지' ;;
    *) : ;;
  esac
  return 0
}

ladder_of_terraform() {
  # The same global skip `surface_of_terraform` performs, so `terraform -chdir=x
  # apply` reads like `terraform apply`.
  while [ $# -gt 0 ]; do
    case "$1" in
      -chdir=*|-help|-version|--help|--version) shift ;;
      -*) return 0 ;;
      *) break ;;
    esac
  done
  case "${1:-}" in
    # `배포` and not `머지`: these two change an environment, and the ladder puts
    # that rung above merge. `state rm`/`import` reach production state too, but
    # they are not the rung a manifest authorizes a deploy for — silence there
    # keeps the declared value, and the axis-2 grade already refuses them out of
    # a read.
    apply|destroy) printf '배포' ;;
    *) : ;;
  esac
  return 0
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
  # Byte-exact for the same reason `gate_chain_verify` is, and it has to be the
  # SAME reason on both sides: this is the value the verifier's walk is compared
  # against, so a locale that changed one and not the other would manufacture
  # breaks out of nothing. See that function for why pinning the character-type
  # axis leaves the forced-surface digest alone.
  local LC_CTYPE=C; export LC_CTYPE
  last=$( { grep '^- `' "$LEDGER" 2>/dev/null || true; } | tail -1)
  [ -n "$last" ] || last="## 실행 $RUN_ID"
  printf '%s' "$last" | shasum -a 256 | cut -d' ' -f1
}

gate_ancestry_window() {
  # The last GATE_ANCESTRY_WINDOW rows — the set an observed tip may still be an
  # ancestor from. See that constant for why the window is a bound on concurrent
  # writers rather than on elapsed time.
  #
  # ROWS AND NOT LINES, for the reason gate_chain_tip records one function up:
  # the ledger is also the morning report, so prose lands in it between rows.
  # Reading raw lines would let a few paragraphs shrink the window without
  # anybody choosing to, and the shrink would show up as a refusal nobody could
  # explain.
  { grep '^- `' "$LEDGER" 2>/dev/null || true; } | tail -n "$GATE_ANCESTRY_WINDOW"
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

  # EVERY FIELD IS MADE ROW-SAFE HERE, KEY AND VALUE ALIKE, NOT AT THE CALL
  # SITES.
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
  #
  # THE KEY HALF USED TO GO THROUGH UNTRANSFORMED, and the header above said
  # "every field value" because that was all this loop did. It split `키=값`,
  # mapped the separators out of the VALUE, and put the key back exactly as the
  # caller spelled it — so a caller that spliced BEFORE the first `=` kept both
  # characters. A pipe there forges a field boundary; a newline there forges a
  # whole second ROW, and among the rows worth forging is a `승인` row saying
  # `상태=승인`. Both halves take the same two maps now. `%%=*` guarantees the key
  # holds no `=`, so reassembling cannot change how many fields the row has, and
  # for every field this file writes today the key transform is the identity.
  # Rotated through the positional parameters rather than collected into an
  # array: the interpreter floor is bash 3.2 and the argument list is the one
  # ordered container available without one.
  local n_args=$# i=0
  while [ "$i" -lt "$n_args" ]; do
    f="$1"; shift; i=$((i + 1))
    case "$f" in
      *=*) k="${f%%=*}"; v="${f#*=}"
           k=$(printf '%s' "$k" | tr '|' '/' | tr '\n\r' '  ')
           v=$(printf '%s' "$v" | tr '|' '/' | tr '\n\r' '  ')
           f="$k=$v" ;;
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
  # THE APPROVAL STATE IS CHECKED HERE FOR THE SAME REASON. Every reader of the
  # `승인` series takes the last row's `상태` as current and compares it against
  # literals, so a value outside the set is not a row that says something odd —
  # it is an approval no reader can see as open, closed, or anything. `철회` is
  # in the set and written by nothing yet; the check accepts it because the
  # vocabulary is the contract's and not the caller list's.
  if [ "$series" = "승인" ]; then
    local astate=""
    for f in "$@"; do
      case "$f" in 상태=*) astate="${f#상태=}" ;; esac
    done
    gate_check_approval_state "$astate" || return "$GATE_EXIT_VOCAB"
  fi

  # THE SHIFT SCALE IS ADDED HERE, WHERE EVERY ROW IS WRITTEN AND NOWHERE
  # ELSE. The morning report asks how many routing shifts ran after the
  # instruction files were applied, and no row carried a shift number at all —
  # so the question had no scale to be answered on. Put on one series it could
  # only count that series; put here it is on every row by construction, and a
  # writer added later cannot forget it.
  #
  # A caller that supplies its own `교대` keeps it. The `handoff` row names the
  # shift that is ENDING, which is the number as of before this row — the same
  # value this function would derive, stated by the writer that knows why.
  # Deriving it a second time would put two spellings of one field on one row.
  local has_shift=0
  for f in "$@"; do case "$f" in 교대=*) has_shift=1 ;; esac; done
  body="- \`$series\`"
  [ "$has_shift" = "1" ] || body="$body | 교대=$(gate_shift_number)"
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
  # THE TOOL IS SELECTED BY PLATFORM AND USED ONLY IF IT IS THERE. Selection
  # answers "which lock does this platform use"; it does not observe the file.
  # The suite drives the darwin branches on any runner by injecting the host OS,
  # so on a linux runner this arm was reached with a BSD path that does not
  # exist — the locked command failed, the row was never appended, and the
  # assertion above it read an empty ledger. Falling through on absence is the
  # same disposition the comment below already states for "no tool at all".
  if [ -n "$tool" ] && [ -x "$tool" ] && [ -n "${RUN_DIR:-}" ]; then
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
  # A STAGE FINISHING NORMALLY IS PROGRESS, and until now nothing here saw it.
  # Segment rows move only when the STATE changes, so a segment that runs several
  # stages under `실행중` contributes a constant — and the two processes of one
  # implement stage are BOTH `실행중`, so not even that transition is expressible
  # as a segment row. Measured: a stage terminated normally, the ledger grew by a
  # `stage-result` row and a `cost` row, the chain stayed intact, and both the
  # progress digest and the stagnation window key came back byte-identical.
  #
  # A ROW COUNT AND NOT A SET. `gate_record_stage_outcome` writes `세그먼트=$seg`
  # and `스테이지=$seg` from one variable, so a set keyed on that pair collapses
  # to the segment alone — twenty-one normal terminations became three elements
  # on a real ledger. And the element count was the wrong measure regardless:
  # what the act budget watches is the GAP between movements, and replaying a
  # real run's 1033 rows put the worst gap at 59 for the count against 128 for
  # the best set and 195 for the vector without this line.
  #
  # Selected POSITIVELY — the field must be present and its value must be exactly
  # `정상 완료`. An exclusion-based selector (`everything but 크래시`) would count
  # `공허한 성공`, and that class exists precisely to name a stage that produced
  # nothing, so counting it as progress voids the reason it was named.
  #
  # Parsed rather than substring-matched, in ONE awk pass. The driver writes a
  # prose `관측=` field on these rows, so a match on the class value alone can be
  # satisfied by a sentence; this locates the field by its delimiter and compares
  # the WHOLE value. The last occurrence wins, the way every other field read in
  # this file does. And it is awk rather than a shell loop because the vector is
  # walked five times per act — a per-row subshell measured 1.92 seconds against
  # 0.007 for this on the same ledger.
  #
  # `LC_ALL=C` makes `index`, `substr` and `length` byte operations on both the
  # BWK awk this ships on and the gawk a Linux runner has, so the two hosts agree
  # on where a field starts. Without it the same row could be cut at a different
  # offset on each side and the vector would be host-dependent.
  printf 'stage-normal=%s\n' \
    "$( { gate_rows 'stage-result' || true; } | LC_ALL=C awk '
        BEGIN { key = " | 종단 부류="; klen = length(key); sep = " | "; n = 0 }
        {
          rest = $0; value = ""; seen = 0
          while ((p = index(rest, key)) > 0) {
            rest = substr(rest, p + klen)
            q = index(rest, sep)
            value = (q > 0) ? substr(rest, 1, q - 1) : rest
            seen = 1
          }
          if (seen && value == "정상 완료") n++
        }
        END { printf "%d", n }
      ')"
  # Settling a clause and clearing a run-scope block are progress by definition
  # — they are the only two moves whose whole purpose is to bring the run nearer
  # to being able to end. A run that spends a judgment doing one of them and is
  # then told it has not moved is being told something false.
  #
  # The series is `종료 절`, not `clause`. `gate_rows` matches on the ROW HEAD,
  # and the only writer of a settlement row spells it `종료 절`; `clause` is the
  # `--kind` token on the authorisation row, which is a field value and never a
  # row head. Written the wrong way this counter is a constant zero — measured
  # on a real run whose ledger held four settlements and zero `clause` rows —
  # so the one move that takes a run closest to being able to end contributed
  # nothing to the vector that decides whether it is moving.
  printf 'clauses=%s\n' "$( { gate_rows '종료 절' || true; } | gate_count)"
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
  # SO THIS ONE CARRIES BOTH, AND CARRIES THEM SEPARABLY. The two halves are
  # joined by `-` rather than hashed together, and that is the whole repair.
  #
  # Folded into one hash, the ledger's tip made EVERY append invalidate the value
  # no matter who wrote it — and `gate_verb_act` appends its authorisation row
  # before dispatching, so one actor's successful act invalidated every other
  # actor's digest the moment it landed. Measured in a single review session:
  # twelve exit 4s, as many as four in a row against one command, every one of
  # them cleared by re-running the identical argv with nothing else changed. A
  # check that a bare retry satisfies is not testing the premise it names; it is
  # a toll on concurrency. There was no ceiling on the re-reads and no backoff.
  #
  # Kept apart, each half is compared the way it should be — the vector for exact
  # equality, the tip for ANCESTRY — and the comparison lives at the call site
  # because only there is refusing an option. See `gate_verb_act`.
  #
  # ONE PASS OVER THE VECTOR. It is the expensive half: this file already
  # measured the row scan at 1.92s per-row-subshell against 0.007s in `awk`, and
  # calling `gate_progress_digest` for the first component would walk it a second
  # time for a value this function already holds.
  local vec
  vec=$(gate_progress_vector)
  printf '%s-%s' \
    "$(printf '%s\n' "$vec" | shasum -a 256 | cut -d' ' -f1)" \
    "$(gate_chain_tip)"
}

gate_snapshot_digest_legacy() {
  # THE PRE-SPLIT FORM, KEPT ONLY TO BE COMPARED AGAINST. A caller carrying a
  # one-part digest got it from a gate that hashed the progress vector together
  # with the ledger's length and tip, and honouring that value's original meaning
  # — exact equality — requires being able to compute it. The callers this exists
  # for are runs that were already in flight when the format split, and other
  # sessions' older copies of this file.
  #
  # NOTHING PRODUCES THIS FORMAT ANY MORE, so this is a reader and not a second
  # writer: the two forms cannot drift apart into two live conventions.
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
  # Pinned for the same reason as the chain walk, and it is not optional here
  # either: `grep` on an invalid byte under a UTF-8 locale can fail outright, and
  # this reader's caller interpolates its output into the snapshot object. A
  # reader that dies mid-object truncates the JSON, so the ledger's DAMAGE COUNT
  # — the field whose whole job is to report a malformed ledger — became
  # unreadable on exactly the ledgers it exists to describe.
  local LC_CTYPE=C; export LC_CTYPE
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
  # The merge rung as an integer, for checkers that fire at merge OR ABOVE. A
  # checker comparing the token would need its own copy of the ladder order to
  # know what "above" means, and a second copy of an order is the drift this
  # exporter exists to prevent — so the gate, which holds the table, resolves it
  # and the checker compares two integers.
  GATE_MERGE_INDEX=$(cutpoint_index '머지') || return "$GATE_EXIT_VOCAB"
  export GATE_ACT_INDEX GATE_TARGET_CUTPOINT GATE_TARGET_INDEX GATE_MERGE_INDEX
  return 0
}

# gate_resolve_review_policy <segment> <alias>
#
# Resolves this act's review policy and publishes it to the rule checkers, which
# are separate `/bin/sh` processes and have no other way to learn it. Same
# division of labour as the cutpoint exporter directly above: the gate holds
# run.sh's tables and resolves the vocabulary, the catalog decides.
#
# The effective value comes from the ledger's segment row, the ceiling from the
# manifest's target row. ABSENCE IS THE STRICT VALUE on both sides, and on the
# segment side that is not "the default" — the segment arm of `gate_record_row`
# carries the field forward on every write, so a row with no value is a segment
# that never had one.
#
# EXCEEDING THE CEILING IS A REFUSAL AND NOT A CLAMP. Quietly tightening makes a
# forged row and a conservative row indistinguishable in the ledger.
#
# This runs on EVERY act and BEFORE the rule loop. Behind the loop there would
# be nothing for the checkers to read; behind `gate_rule_enabled` it would be
# something `끔` could switch off, and the ceiling is the one part of this axis
# that a manifest may not turn off — that is the whole reason it lives here and
# not inside a checker.
gate_resolve_review_policy() {
  local seg="$1" alias="$2" kind="$3" pol ceil apol api
  shift 3
  pol=$(gate_segment_field "$seg" '리뷰 정책')
  [ -n "$pol" ] || pol='선리뷰후머지'
  ceil=$(target_field "$alias" '리뷰 정책 상한')
  [ -n "$ceil" ] || ceil='선리뷰후머지'
  GATE_REVIEW_POLICY_INDEX=$(review_policy_index "$pol") || {
    warn "세그먼트 '$seg' 의 리뷰 정책 토큰이 어휘에 없습니다: '$pol'"
    return "$GATE_EXIT_VOCAB"
  }
  GATE_REVIEW_CEILING_INDEX=$(review_policy_index "$ceil") || {
    warn "대상 '$alias' 의 리뷰 정책 상한 토큰이 어휘에 없습니다: '$ceil'"
    return "$GATE_EXIT_VOCAB"
  }
  # THE TIGHTENING ROW IS ALWAYS WRITABLE. This resolution runs before the rule
  # loop AND before the ledger writer, so a segment row that already carries a
  # value above the ceiling had no verb left to repair it: writing the corrected
  # row needs `act --kind segment` on that same id, and that act re-enters here
  # and is refused on the OLD value first. The segment then stays in a
  # non-terminal state, termination condition 1 never holds, and the run has no
  # ending it can propose. Keying the row on a different segment does not reach
  # the stuck id, so nothing else could unstick it.
  #
  # So the ONE act that can repair it resolves from its own argv instead of from
  # the prior row — and only when that argv is at or below the ceiling. Relaxing
  # past the ceiling is refused exactly as before, so the property the refusal
  # protects is untouched: what changes is only that the direction which restores
  # compliance stops being unreachable.
  if [ "$kind" = "segment" ]; then
    apol=$(gate_field_of '리뷰 정책' "$@")
    if [ -n "$apol" ] && api=$(review_policy_index "$apol" 2>/dev/null) \
       && [ "$api" -le "$GATE_REVIEW_CEILING_INDEX" ]; then
      pol="$apol"
      GATE_REVIEW_POLICY_INDEX="$api"
    fi
  fi
  if [ "$GATE_REVIEW_POLICY_INDEX" -gt "$GATE_REVIEW_CEILING_INDEX" ]; then
    warn "세그먼트 '$seg' 의 리뷰 정책 '$pol' 이 대상 '$alias' 의 상한 '$ceil' 을 넘습니다 — 상한 위반은 조여 넣지 않고 거절합니다"
    return "$GATE_EXIT_VOCAB"
  fi
  GATE_REVIEW_POLICY="$pol"
  export GATE_REVIEW_POLICY GATE_REVIEW_POLICY_INDEX GATE_REVIEW_CEILING_INDEX
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
  # A rule is on unless the manifest turns it off. FOUR ignore the setting, and
  # the `case` below is the list: `절단점-준수`, `사전-인가-대조`,
  # `인가-자기확장-금지` and `리뷰-후-적용`. This comment named three of them
  # while the code exempted four, which is the shape that makes an operator
  # believe a rule can be switched off when it cannot.
  #
  # The authorization record means nothing if the first two can be switched off;
  # a self-widening ban that can be switched off is not a ban at all — after the
  # first time it is turned off, the record does not even say what was turned
  # off; and `리뷰-후-적용` guards a change to the instruction file this whole
  # mechanism reads.
  #
  # `리뷰-후-머지` IS NOT ON THIS LIST and must not be added to it. What that
  # rule holds is a policy the manifest is entitled to relax, and the parts of
  # the review axis a manifest may NOT relax — the ceiling comparison and the
  # anchor check — already live outside the catalog, where `끔` cannot reach
  # them.
  local name="$1"
  case "$name" in
    절단점-준수|사전-인가-대조|인가-자기확장-금지|리뷰-후-적용) return 0 ;;
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

# The unmet-condition TEXT list is capped; its NUMBERS are not, and the two are
# carried together for that reason. Conditions 1 and 3 emit one line per segment
# and per obligation, so they grow with the length of the night and take the
# front of this list — which pushes the singleton tails off it, and those tails
# (the review obligation, "no termination clause parses") are exactly the answer
# to "why can this run not end". The number list is deduplicated and cannot
# exceed ten values, so it survives any night. There is no arrangement that keeps
# the cap and drops the numbers: dropping them means dropping the cap too.
readonly GATE_UNMET_CAP=20

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

  # THE COUNT BESIDE THE ARRAY, because the array alone could not be read as a
  # number. `obligations` has carried its total since it was capped; this side
  # had only the list, so anything wanting the count — the render line, and now
  # the emitted digest — had to derive it, and two derivations of one number is
  # how two surfaces come to disagree about the same run.
  printf '  "pending_approvals_total": %s,\n' "$(gate_pending_approval_ids | gate_count)"

  printf '  "pending_approvals": [\n'
  gate_pending_approvals_json
  printf '  ],\n'

  # WHAT IS KEEPING THE RUN FROM ENDING, in the object the router is contracted
  # to read every turn. The top-level keys carried the goal, the targets, the
  # obligations, the approvals, the damage count and the two digests — and
  # nothing at all about the termination conditions. So a router obeying the
  # contract and reading only this could learn what blocked the end only by
  # proposing it and reading the refusal, which is finding out by doing on the
  # one question looking was supposed to answer.
  local unmet unmet_total
  unmet=$(gate_done_conditions)
  unmet_total=$(printf '%s\n' "$unmet" | grep -c . || true)
  printf '  "unmet_conditions": [\n'
  shown=0
  printf '%s\n' "$unmet" | awk -v cap="$GATE_UNMET_CAP" 'NF { c++; if (c <= cap) print }' \
    | while IFS= read -r u; do
        [ -n "$u" ] || continue
        [ "$shown" = "0" ] || printf ',\n'
        shown=1
        printf '    "%s"' "$(gate_json_escape "$u")"
      done
  [ "${unmet_total:-0}" = "0" ] || printf '\n'
  printf '  ],\n'
  printf '  "unmet_conditions_total": %s,\n' "${unmet_total:-0}"
  # UNCAPPED, and that is the point of carrying it beside the capped list. It is
  # deduplicated, ascending, and cannot exceed ten values, so it never loses its
  # tail — while the text list loses precisely the singleton causes once a long
  # night fills its front with per-segment and per-obligation lines.
  printf '  "unmet_condition_numbers": [%s],\n' \
    "$(gate_unmet_numbers "$unmet" | tr '\n' ',' | sed 's/,$//')"
  printf '  "disposition": "%s",\n' "$(gate_json_escape "$(gate_done_disposition "$unmet")")"

  # WHAT A SUCCESSOR SHIFT NEEDS AND WHAT `--resume` USED TO SUPPLY INSTEAD.
  # Until the routing loop moved out of the lead session, a cut router was
  # resumed rather than replaced, so the conversation history carried the
  # segments, the blocks and the cycle results and nobody noticed the snapshot
  # did not. A shift is a NEW process with no history at all: handed the object
  # as it stood, it could not name a single segment. The claim that the router
  # holds no state a snapshot does not was false the moment it was written and
  # became load-bearing only now.
  #
  # Every block is BOUNDED. The point of the shift is a smaller starting
  # context, and an unbounded resume payload spends on the first turn exactly
  # what the mechanism exists to save.
  printf '  "segments": [\n'
  gate_snapshot_segments_json
  printf '  ],\n'
  printf '  "segments_total": %s,\n' "$(gate_segment_ids | gate_count)"
  printf '  "blocked": [\n'
  gate_snapshot_blocked_json
  printf '  ],\n'
  printf '  "cycles": [\n'
  gate_snapshot_cycles_json
  printf '  ],\n'
  printf '  "shift": %s,\n' "$(gate_shift_state)"
  printf '  "handoff": [\n'
  gate_snapshot_handoff_json
  printf '  ],\n'

  # THE LOST-DISPATCH ALARM, and it is in the snapshot rather than only in the
  # render because the router reads the object and is judged on doing so. A key
  # that exists in the output and nowhere in the contract is a key nothing looks
  # for; this one names the failure whose whole cost was that no layer said it.
  printf '  "orphan_stages": [%s],\n' \
    "$( { cc_orphan_stages "$RUN_DIR" || true; } | sed 's/.*/"&"/' | paste -sd, - )"
  printf '  "ledger_damage": %s,\n' "$(gate_ledger_damage)"
  printf '  "chain_intact": %s,\n' "$(gate_chain_verify >/dev/null 2>&1 && printf 'true' || printf 'false')"
  printf '  "H": "%s"\n' "$(gate_snapshot_digest)"
  printf '}\n'
}

# ---------------------------------------------------------------------------
# The post-mutation digest, written to a file the caller names.
#
# WHAT IT BUYS. Every acting call has to carry `--snapshot-digest`, and the only
# way to learn that value was a separate `snapshot` call — so each act cost two
# gate invocations, and the first of the two existed solely to read back a value
# this process had just finished deciding. Emitting it at the end of the act the
# caller already made removes the read-back without weakening the binding: the
# flag stays in the argv, the comparison stays where it was, and what changes is
# only where the caller gets the number.
#
# WHY A FILE AND NOT A FILE DESCRIPTOR. "One value, one file under the run
# directory" is this script's dominant idiom already — `surface-digest`,
# `ledger-path` and `progress-digest` are all written that way — and there is
# not one `exec 3>` in the file to copy instead. A fixed descriptor also
# collides with the `exec` verb structurally: `gate_run_readonly` runs the
# wrapped argv in a subshell, which inherits every open descriptor, so the
# judgment channel would be writable by the command under judgment. bash 3.2 is
# the floor here, so `{fd}>` dynamic allocation is not available either, and a
# fixed number would have to be opened by the hook, the test suite and the stage
# wrapper — three call sites frozen as literal lines.
#
# WHY THE TWO TOTALS COME ALONG. A caller reading this file is reading it
# INSTEAD of a `snapshot` round trip, and those two counts are the other things
# it would have gone there for. The key names match `snapshot`'s exactly so no
# consumer has to learn a second vocabulary for the same values.
#
# BEST EFFORT, and deliberately so. This runs after the act and after its ledger
# row; refusing here would report a failure that did not happen. A caller that
# finds no file falls back to `snapshot | jq -r .H`, which is the same path a
# gate too old to know this flag already leaves it on.
# ---------------------------------------------------------------------------
gate_digest_path() {
  # gate_digest_path — where THIS process emits, derived in one place.
  #
  # ONE DERIVATION, BECAUSE TWO DRIFT. The hook tells a stage which file to
  # open, and it used to build that path itself — same shape, but interpolating
  # the stage id verbatim while this file sanitizes it. Every stage id this
  # pipeline mints carries a character outside the sanitized class, so the two
  # paths agreed only for the router, which is the one actor the hook is never
  # installed for. The failure was silent in both directions: the gate emitted
  # correctly, the stage opened a name that did not exist, and it fell back to
  # the round trip the flag exists to remove — with the run green throughout.
  #
  # Anything that needs the path asks for it now. `gate.sh digest-path` prints
  # this same value, so a second copy of the rule cannot exist.
  printf '%s/digest/gate-digest-%s.json' "$RUN_DIR" \
    "$(printf '%s' "${CC_PIPELINE_STAGE_ID:-router}" | tr -c 'A-Za-z0-9._-' '-')"
}

gate_emit_digest() {
  # THE EXIT STATUS ON THE WAY OUT IS NOT THIS FUNCTION'S TO CHANGE. This runs
  # from an EXIT trap, and a trap body that fails under `errexit` REPLACES the
  # status the script was exiting with — so a hiccup here could turn a refusal
  # into a success, which is the one outcome this whole file exists to make
  # impossible. The status is captured first and restored last, and the body
  # runs with `errexit` off so no single command can short-circuit that.
  local __rc=$?
  set +e
  gate_emit_digest_body
  set -e
  return "$__rc"
}

gate_emit_digest_body() {
  [ -n "${GATE_EMIT_DIGEST_TO:-}" ] || return 0
  # NOT SINGLE SHOT, AND THERE ARE NO EXPLICIT CALLS LEFT. Disarming on the
  # first success made the trap cover only "exits that happen before the first
  # emission" — any ledger append landing after that call was invisible to it,
  # which is the same defect the enumeration had, turned around. The rule is
  # "the value the caller reads is the state at exit", so the only call site is
  # the trap and the last write wins.
  #
  # THE TEMP IS MINTED, NOT NAMED. A predictable sibling can be pre-created as a
  # symlink by anything that can write this directory, and `>` follows it — so
  # the redirection would land wherever the link points, outside every check the
  # target path passed. `mktemp` in the same directory keeps the rename atomic
  # and takes the name out of the attacker's hands.
  local tmp
  tmp=$(mktemp "$(dirname "$GATE_EMIT_DIGEST_TO")/.gate-digest.XXXXXX" 2>/dev/null) || {
    warn "다이제스트 임시 파일을 만들지 못했습니다: $GATE_EMIT_DIGEST_TO — 소비 측은 snapshot 으로 폴백합니다"
    return 0
  }
  # Same directory as the target by construction, so the rename is atomic and a
  # reader never sees a half-written object.
  # THE EMITTING ACTOR TRAVELS WITH THE VALUE. The file name separates actors by
  # convention, and a convention is exactly what a caller can get wrong — so the
  # object also says who wrote it, and a consumer that finds an id other than
  # its own knows it is holding someone else's digest rather than a stale one.
  # `CC_PIPELINE_STAGE_ID` is empty in the router and set in a stage, which is
  # the same distinction this file already relies on elsewhere.
  #
  # WRITTEN RAW, so a consumer can compare it against its own
  # `$CC_PIPELINE_STAGE_ID` VERBATIM. A first version sanitized it on the same
  # character class the directory names use, and every stage id this pipeline
  # mints carries a character outside that class — `<segment>#<attempt>` from
  # the gate, `S5:<segment>:<cycle>` from the driver — so a verbatim comparison
  # reported every stage's own file as someone else's. Only the two characters
  # that would break the JSON string are replaced.
  if printf '{"H":"%s","obligations_total":%s,"pending_approvals_total":%s,"actor":"%s"}\n' \
       "$(gate_snapshot_digest)" \
       "$(gate_open_obligations | gate_count)" \
       "$(gate_pending_approval_ids | gate_count)" \
       "$(printf '%s' "${CC_PIPELINE_STAGE_ID:-router}" | tr -d '\000-\037' | tr '"\\' '__')" >"$tmp" 2>/dev/null \
     && mv "$tmp" "$GATE_EMIT_DIGEST_TO" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  warn "다이제스트를 방출하지 못했습니다: $GATE_EMIT_DIGEST_TO — 소비 측은 snapshot 으로 폴백합니다"
  return 0
}

gate_pending_approvals_json() {
  # THE CUTPOINT AND THE QUESTION TRAVEL WITH THE ID, because the array mixes two
  # kinds of answer whose lifetimes are opposite and gave the router no field to
  # tell them apart. Termination condition 2 does not count an approval whose
  # cutpoint is `판단`: an act approval's answer is valid only against the tree
  # its binding tuple named, while a question's answer is durable and a successor
  # run consumes it. A router reading this array as uniformly blocking cannot end
  # a run that one open question does not block — which is the defect this design
  # exists to remove, arriving through a different door.
  #
  # The question text comes along for the same reason the id alone was not
  # enough: an id is a hash and says nothing about what is being asked, so a
  # person handed the array had to go read the ledger to know what to answer.
  local ids id state row first=1
  # Pinned for the same reason as the chain walk. This one emits INTO the
  # snapshot object, so a `tr`/`sed` that dies on an invalid byte does not just
  # lose the approvals array — it truncates the JSON at that point and every
  # field after it, including the chain verdict, never reaches the reader. The
  # ledger the reader most needs a verdict about is precisely the malformed one.
  #
  # NOTE FOR ANYONE WIDENING THIS: this function DOES contain a `sort -u`, and
  # the pin is still safe. The order it produces is decided by `LC_COLLATE`,
  # which the driver has already fixed to C; `LC_CTYPE` does not enter into it.
  # The "no `sort` in scope" reasoning that once justified the narrower pin was
  # never the load-bearing part, and repeating it here would make this look like
  # a violation of a rule that does not exist.
  local LC_CTYPE=C; export LC_CTYPE
  ids=$(gate_rows '승인' \
        | tr '|' '\n' | sed -n 's/^ *승인 id=//p' | sed 's/[[:space:]]*$//' | sort -u)
  for id in $ids; do
    # The LAST row for the id decides, and it is read once here rather than
    # re-grepped per field — three reads of the same row could straddle a
    # concurrent append and describe two different rows as one object.
    row=$( { gate_rows '승인' | grep -F "승인 id=$id " || true; } | tail -1)
    state=$(gate_row_field "$row" '상태')
    [ "$state" = "대기" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    # `disposition` IS HOW A FREE-INPUT ANSWER REACHES THE MORNING. An approval
    # whose last `대기` row carries `처분 사유` was answered by a person and the
    # gate could derive no disposition from the answer; without this field it
    # is indistinguishable in the array from one nobody has answered.
    local disp
    disp=$(gate_row_field "$row" '처분 사유'); [ -n "$disp" ] || disp='-'
    printf '    {"id": "%s", "blocks": "%s", "cutpoint": "%s", "disposition": "%s", "question": "%s"}' \
      "$(gate_json_escape "$id")" \
      "$(gate_json_escape "$(gate_row_field "$row" '막는 세그먼트')")" \
      "$(gate_json_escape "$(gate_row_field "$row" '절단점')")" \
      "$(gate_json_escape "$disp")" \
      "$(gate_json_escape "$(gate_row_field "$row" '질문 문면')")"
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

  # PENDING APPROVALS, AND THIS LINE DOES NOT DISAPPEAR AT ZERO. The JSON carried
  # them and the render did not, so a run held by an approval printed `원장 손상`,
  # `해시 체인` and `미해결 의무` in a row — three lines all reading fine — while
  # a person was the only thing that could move it, and the word `승인` appeared
  # nowhere in the whole output. A line that shows up only when the count is
  # non-zero cannot be told apart from a line nobody wrote, which is the same
  # absence wearing a different face.
  local n_pending
  n_pending=$(gate_pending_approval_ids | gate_count)
  printf '대기 승인 : %s건\n' "$n_pending"

  # WHY THE RUN CANNOT END, beside the rest of it. NO COUNT OF CONDITIONS GOES ON
  # THIS LINE — the number was already written down wrong in two comments, and a
  # third copy is a third thing to keep in step with a function that decides it.
  # What the line carries is the disposition and the condition numbers, both
  # derived at the moment of printing.
  local r_unmet r_disposition r_numbers
  r_unmet=$(gate_done_conditions)
  r_disposition=$(gate_done_disposition "$r_unmet")
  r_numbers=$(gate_unmet_numbers "$r_unmet" | tr '\n' ',' | sed 's/,$//')
  if [ "$r_disposition" = "충족" ]; then
    printf '미충족 조건: 없음 — 종료 조건이 전부 성립합니다\n'
  elif [ "$r_disposition" = "무효화" ]; then
    printf '미충족 조건: 조건 %s — 무효화만 남았습니다. act --kind propose-done 이 충족이 아니라 무효로 기록하고 런을 닫습니다. 이 런의 기준선은 다시 잡히지 않습니다\n' \
      "${r_numbers:-미상}"
  else
    printf '미충족 조건: 조건 %s\n' "${r_numbers:-미상}"
  fi

  # LIVENESS, because "is this still going?" had no cheap answer. The heartbeat
  # a watcher prints goes to a stdout that its launching tool call already
  # closed, so it reaches nobody; the render did not carry a live-stage count,
  # a ledger age, or the run's own terminal state. Answering it needed the row
  # grammar and a manual pid comparison.
  local n_live now_s led_s hb_s done_line orphans
  # Counting pid FILES reported stages that were not there: measured 21 files
  # against 5 live processes, and a render claiming "진행 중" for a run whose
  # recorded pid was dead. The shared predicate tests the process.
  n_live=$(cc_live_stages "$RUN_DIR")
  now_s=$(date -u +%s)
  led_s=$(gate_mtime "$LEDGER")
  hb_s=$(gate_mtime "$RUN_DIR/watch.heartbeat")
  printf '살아 있는 스테이지: %s개\n' "$n_live"
  # Rendered only when there is one. A line that reads "0" every night is a line
  # nobody sees on the night it reads 1, and unlike the pending-approval count
  # this one has no second reading to preserve — no orphan is no line.
  orphans=$( { cc_orphan_stages "$RUN_DIR" || true; } | paste -sd' ' -)
  [ -n "$orphans" ] && \
    printf '잃어버린 파견: %s — 파견 기록이 남았는데 그 프로세스가 없습니다. 스테이지 결과가 기록되지 않았습니다\n' "$orphans"
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
  # `-e` RATHER THAN `-f`, because the reap lock is a DIRECTORY and dating it is
  # what lets a lock with no readable owner line expire instead of standing
  # forever. `date -u -r` takes a directory on both platforms — verified on this
  # host — and every other caller passes a file, so widening the guard adds a
  # case rather than changing one.
  [ -e "$1" ] || return 0
  date -u -r "$1" +%s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Bounded reclamation of the state directory.
#
# WHERE, AND WHY ONLY THERE. The gate is re-entered on every verb, so the one
# place that runs exactly once per run is the run-open branch further down. A
# reap on every entry was ruled out by measurement rather than by taste: the
# busiest run's ledger carries 875 rows and gate entries outnumber them, which at
# ~400ms a victim is six minutes of pure overhead per run.
#
# 보존 기준 30일 — the retention floor, in seconds. This is the one constant here
# that gets restated outside its own declaration (in this block's prose and in
# the gate suite's fixtures), which is why it is the one that gets a lint:
# `scripts/lint-reap-retention.sh` extracts it from the line below and refuses a
# bare copy of the number anywhere else. The extraction anchors on the whole
# line, so this has to stay a single `readonly <NAME>=<digits>` and nothing more.
readonly GATE_REAP_RETENTION=2592000
# The other three correct themselves when wrong — a cap set too low leaves work
# for the next cycle, a budget set too tight ends the pass early, an interval set
# too long only delays it — so they get `readonly` and no lint. 20 x (75ms of
# state predicate + 400ms of removal), plus the pre-filter, the age checks and
# one index scan, is about 11.1s: the count cap and the wall clock bite together.
readonly GATE_REAP_MAX=20
readonly GATE_REAP_BUDGET_S=12
readonly GATE_REAP_INTERVAL=21600

gate_reap_root() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
}

gate_reap_day_epoch() {
  # gate_reap_day_epoch <YYYYMMDD> — 00:00:00Z of that day in epoch seconds, or
  # empty for anything that is not eight digits or not a real date.
  #
  # ARITHMETIC RATHER THAN `date`. The two spellings that parse a date string,
  # `date -d` and `date -j`, are both on the portability lint's denylist because
  # they diverge between GNU and BSD, so the days-from-civil conversion is done
  # here instead. March is treated as the first month, which is what removes the
  # leap-day special case from the expression.
  local s="$1" y m d era yoe doy doe days
  case "$s" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) return 0 ;;
  esac
  y=$((10#${s:0:4})); m=$((10#${s:4:2})); d=$((10#${s:6:2}))
  { [ "$m" -ge 1 ] && [ "$m" -le 12 ]; } || return 0
  { [ "$d" -ge 1 ] && [ "$d" -le 31 ]; } || return 0
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  printf '%s' $(( days * 86400 ))
}

gate_reap_eligible() {
  # gate_reap_eligible <run-dir> <run-id> <now> — 0 when all five clauses hold.
  #
  # FAIL-CLOSED IN EVERY CLAUSE. Reclamation needs positive evidence of age: a
  # clock that is missing, empty, unreadable or unparsable means "unknown", and
  # unknown is never reclaimed. The `age=$(cc_mtime …); [ -z "$age" ] && age=0`
  # shape is forbidden here for exactly that reason — it reads a ledger that a
  # `git clean` in some other repo removed as "1970, infinitely old", which turns
  # that command into a remote delete for this run's state directory.
  local rd="$1" id="$2" now="$3" started ledger state day_epoch
  # 4 — a symlink is not a candidate at all. This is also what makes the
  # slash-free victim path safe rather than merely tidy.
  [ ! -L "$rd" ] || return 1
  [ -d "$rd" ] || return 1
  # 3 — never the current run. Structurally unreachable anyway, because
  # `rundir_init` rewrites this run's `started-at` to `now` before the run-open
  # branch is reached, but the comparison is one test and says so out loud.
  [ "$rd" != "${RUN_DIR:-}" ] || return 1
  # 2 — the retention clock is the CONTENT of `started-at`, which `rundir_init`
  # rewrites on every gate entry. Its name says "run start" and its meaning is
  # "last gate entry", and the second is what retention actually asks: is anyone
  # still reaching for this? Selection sorts on `done`/ledger mtime instead, so
  # the two clocks diverge — measured, in one direction only (97 runs at +0 days,
  # 2 at +1, 1 at +2, 3 at +4, and zero the other way), because every gate entry
  # that could write `done` rewrote `started-at` first. Retention is therefore
  # always the more conservative of the two and the early-delete direction is
  # unreachable.
  started=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$rd/started-at" 2>/dev/null || true)
  [ -n "$started" ] || return 1
  [ "$started" -gt 0 ] 2>/dev/null || return 1
  [ $((now - started)) -ge "$GATE_REAP_RETENTION" ] || return 1
  # 1 — terminal, evaluated HERE and never from a cache. A run with no
  # `ledger-path` hands an empty ledger to the predicate, which then counts zero
  # segments and cannot answer 종단, so those fall out of candidacy on their own.
  # The thresholds are passed explicitly rather than inherited, per the rule that
  # two consumers must not grade one run with two values; this clause's answer
  # happens to be independent of both.
  ledger=$(cat "$rd/ledger-path" 2>/dev/null || true)
  state=$(cc_run_state "$rd" "$ledger" 180 3600 2>/dev/null || true)
  [ "$state" = "종단" ] || return 1
  # 5 — an id that parses as a date must not be NEWER than the retention clock it
  # is paired with. An id that does not parse passes: the clause is a conditional
  # and its antecedent is "parses as a date".
  case "$id" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*)
      day_epoch=$(gate_reap_day_epoch "${id%%-*}")
      [ -n "$day_epoch" ] || return 0
      [ "$day_epoch" -le "$started" ] || return 1
      ;;
  esac
  return 0
}

gate_reap_note() {
  # One line of PROSE into this run's report, which is the same file as its
  # ledger. Deliberately not a row: every row predicate anchors on a backticked
  # series token at the start of the line, so a line opening with a timestamp is
  # invisible to all of them and is counted toward no termination condition.
  # `gate_drain_notify_state` is the existing precedent for the shape.
  #
  # THE REPORT OF THE RUN THAT DID THE REAPING, not of the run that was reaped.
  # The victim's report is a closed record of a finished run, may live in another
  # repo entirely, and would have the run writing down that it was deleted.
  [ -n "${LEDGER:-}" ] || return 0
  printf '%s · %s\n' "$(now_iso)" "$1" >> "$LEDGER" 2>/dev/null || true
  return 0
}

gate_reap_unwind() {
  # gate_reap_unwind <trash> <run-dir> <id> <now> — the last reversal point of a
  # reclamation. Returns 0 when the victim was NOT reclaimed (restored, or parked
  # in the trash under a `.keep`), 1 when its clock still says reclaim and the
  # caller should proceed with the removal.
  #
  # THE RETENTION CLOCK IS READ AGAIN, AFTER THE RENAME. Nothing holds a lock on
  # the victim between the verdict and this call: `.reap.lock` excludes reapers
  # from one another and says nothing about the run being judged, and the
  # never-the-current-run clause compares against the reaping process's own
  # `RUN_DIR` only. So an ordinary gate entry can land on this id after the
  # eligibility clock was read — and `rundir_init` rewrites `started-at` to now
  # on every entry — while the reaper is still inside `cc_run_state` and the
  # recursive `du -sk` walk.
  #
  # Deleting through that window does not merely lose a live run. The run's own
  # verbs carry on to an unguarded `mkdir -p "$RUN_DIR/log"` and rebuild the
  # directory with no `started-at` in it, which the eligibility clock then
  # refuses forever while the `-mtime` pre-filter hides it for another 25 days:
  # this feature would be manufacturing the immortal run it exists to remove.
  #
  # The rename is what makes the re-read possible and it is the last moment at
  # which the deletion is still reversible. `started-at` moved with the
  # directory, so a writer that got in first left its bytes on this same inode,
  # and reading them costs one `sed`. A missing or zero clock is "unknown" and
  # unknown is not reclaimed, exactly as in the eligibility clause.
  #
  # IT IS A FUNCTION AND NOT THREE LINES INLINE because the only way into its two
  # outcomes is a race the caller cannot stage: the fresh clock has to be written
  # by some other process in the window between two reads of one file. Inline,
  # both arms were unreachable from any test — the whole re-verification could be
  # deleted with the suite staying green — and a cross-review found a real defect
  # inside one of them. Named, each arm is reached by calling this with the state
  # the race would have produced.
  local trash="$1" rd="$2" id="$3" now2="$4" started2
  started2=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$trash/started-at" 2>/dev/null || true)
  if [ -n "$started2" ] && [ "$started2" -gt 0 ] 2>/dev/null \
     && [ $((now2 - started2)) -ge "$GATE_REAP_RETENTION" ]; then
    return 1
  fi
  # PUT IT BACK ONLY IF ITS PLACE IS STILL EMPTY. `mv a b` with `b` an existing
  # directory moves `a` INSIDE it, so an unguarded restore against an
  # already-resurrected `run/<id>` would nest the old run under the new one — a
  # second husk, in a stranger shape than the one being avoided. When the place
  # is taken the copy stays in the trash under a `.keep` sibling the sweep
  # honours, because at that moment it is the only copy of the run's handles and
  # settings that exists.
  #
  # THE `mv` RESULT IS PART OF THE CONDITION rather than assumed: a restore that
  # fails after the emptiness test passes — the place filled in between, the
  # filesystem refused — would otherwise write "restored" into the report for a
  # directory still sitting in the trash, and the report is the only record that
  # the reclamation was undone.
  if [ ! -e "$rd" ] && mv "$trash" "$rd" 2>/dev/null; then
    gate_reap_note "회수 취소: 런 $id — 판정 이후 보존 시계가 신선해져 제자리로 되돌렸다"
  else
    : > "$trash.keep" 2>/dev/null || true
    gate_reap_note "회수 보류: 런 $id — 판정 이후 보존 시계가 신선해졌으나 제자리가 이미 차 있어 .reap-trash 에 남긴다"
  fi
  return 0
}

gate_reap_lock() {
  # gate_reap_lock <root> — ONE ATTEMPT, NO WAITING. Contention means another
  # gate is already reaping, so the work is being done and queueing behind it
  # buys nothing. That is why this cannot be `gate_settings_lock`, which waits;
  # and `ledger.lock` is worse still — it is scoped per run, it guards a file in
  # the repo, and it lives INSIDE a directory a reap may be deleting.
  #
  # A lock older than fifteen minutes is broken, judged from the owner line
  # written straight after the `mkdir`. Without that line the expiry cannot be
  # decided at all, and what a never-expiring lock produces here is a reaper that
  # is switched off forever with no symptom.
  local root="$1" lock owner ots now
  lock="$root/.reap.lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date -u +%s)" > "$lock/owner" 2>/dev/null || true
    return 0
  fi
  owner=$(cat "$lock/owner" 2>/dev/null || true)
  ots=$(printf '%s' "$owner" | sed -n 's/^[0-9][0-9]*[[:space:]][[:space:]]*\([0-9][0-9]*\)$/\1/p')
  # AN UNREADABLE OWNER LINE FALLS BACK TO THE LOCK DIRECTORY'S OWN mtime, and
  # refusing outright was the bug rather than the caution. Refusing was meant to
  # avoid racing a live holder, but it also made an owner-less lock PERMANENT,
  # and that shape was reachable with no crash at all: the release used to remove
  # the owner line and then the directory, so every ordinary release passed
  # through it, and any failure of the second step froze the reaper for good with
  # no symptom anywhere. The directory is created by the `mkdir` above and its
  # mtime is set then, so it dates the acquisition exactly as the owner line
  # does — a holder younger than the expiry is still protected, because the same
  # threshold decides both.
  [ -n "$ots" ] || ots=$(gate_mtime "$lock")
  [ -n "$ots" ] || return 1
  now=$(date -u +%s)
  [ $((now - ots)) -ge 900 ] || return 1
  rm -rf "$lock" 2>/dev/null || true
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s %s\n' "$$" "$(date -u +%s)" > "$lock/owner" 2>/dev/null || true
  return 0
}

gate_reap_sweep() {
  # gate_reap_sweep <root> <cycle-start> — empties `.reap-trash/` and prints the
  # names it has given up on, space separated.
  #
  # An entry there is a directory whose rename succeeded and whose removal did
  # not. It is invisible to every enumeration of runs, because `.reap-trash/` is
  # a SIBLING of `run/`, but it still holds the bytes the cycle came for.
  local root="$1" start="$2"
  local trash entry name fails now swept=0 gave_up=""
  trash="$root/.reap-trash"
  [ -d "$trash" ] || return 0
  for entry in "$trash"/*; do
    # Also what skips the `.fails` and `.keep` siblings: those are files.
    [ -d "$entry" ] || continue
    # A `.keep` SIBLING IS A DELIBERATE HOLD, NOT A LEFTOVER. The deletion loop
    # writes one when a victim's retention clock turned out to be fresh after
    # the rename and its place in `run/` had already been taken. The copy here
    # is then the only one there is, so sweeping it would destroy the very run
    # the re-read had just saved. It is not folded into `gave_up`: that name
    # means "the OS refused to remove this", and reporting a deliberate hold
    # under it would erase the distinction. The record of the hold is the
    # `회수 보류` line written at the moment it happened.
    [ ! -e "$entry.keep" ] || continue
    now=$(date -u +%s)
    [ "$swept" -lt "$GATE_REAP_MAX" ] || break
    [ $((now - start)) -lt "$GATE_REAP_BUDGET_S" ] || break
    name=$(basename "$entry")
    fails=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$entry.fails" 2>/dev/null || true)
    [ -n "$fails" ] || fails=0
    # THREE STRIKES AND THE NAME GOES IN THE SUMMARY LINE. Retrying forever turns
    # a local failure into a global one — it eats the cycle's budget every cycle.
    if [ "$fails" -ge 3 ]; then gave_up="$gave_up $name"; continue; fi
    rm -rf "$entry" 2>/dev/null || true
    if [ ! -e "$entry" ]; then
      rm -f "$entry.fails" 2>/dev/null || true
    else
      printf '%s\n' "$((fails + 1))" > "$entry.fails" 2>/dev/null || true
    fi
    swept=$((swept + 1))
  done
  printf '%s' "${gave_up# }"
  return 0
}

gate_reap_prune_index() {
  # gate_reap_prune_index <root> <pair-file> — drops from the forward session
  # index every entry whose run directory is gone, and appends one
  # `<id> <index-file-name>` line per removal to <pair-file>, which is what lets
  # each victim's report line name its own share.
  #
  # THE CRITERION IS RE-DERIVED FROM DISK rather than carried over from the
  # deletions above, and that is what makes the prune STATELESS BETWEEN CYCLES: a
  # file this cycle gives up on is simply walked again by the next one. Carrying
  # the id list instead would make "given up for this cycle" indistinguishable
  # from "stuck forever", because the next cycle would arrive with a different
  # list and never look at the skipped file's real contents again.
  #
  # ONE BATCH SCAN PER CYCLE, not one per victim: the scan cost is FLAT in the
  # number of victims (0.40s for one, 0.37s for three). The reverse index cannot
  # stand in for it — `session-lineage` covers 143 of 930 forward entries,
  # because the forward append has no stage guard and lineage does.
  #
  # AFTER THE DELETIONS, and the order is the whole point of the criterion. Run
  # before them and every victim still has a directory, so nothing is pruned at
  # all; run after and the entries that survive are exactly the runs that did. An
  # index entry whose directory is gone is a stale pointer the reader already
  # filters out; a directory whose index entry is gone is a live run nobody can
  # find.
  #
  # COMPARE AND SWAP ON (size, mtime), immediately before the swap, and the
  # contract is SAFETY GUARANTEED, PROGRESS NOT. The append side takes no lock
  # and runs on every gate entry, so a naive read-modify-write loses concurrent
  # appends — measured 384 to 401 of 1200. Re-reading both turns that loss into a
  # skip. Under unbroken append pressure every attempt skips and nothing is ever
  # pruned (0 writes in 3600 appends); at the cadence a real gate produces, 6 of
  # 6 succeeded on the first try. The asymmetry is the right way round: a lost
  # append costs that session its status-line pin, while an unpruned entry costs
  # nothing at all, since the reader skips entries whose directory is gone.
  local root="$1" pairs="$2"
  local dir f tmp line kept dropped n_after size_before size_after
  local mtime_before mtime_after
  dir="$root/session"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.reap-tmp.*) continue ;; esac
    # THE FIRST PASS ONLY ASKS WHETHER THERE IS ANYTHING TO DROP, and it forks
    # nothing. Most index files have no stale entry at all, and they leave here
    # without paying for the two stat calls the swap below needs.
    dropped=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ -d "$root/run/$line" ] || { dropped="있음"; break; }
    done < "$f"
    [ -n "$dropped" ] || continue
    # THE STAMP IS TAKEN BEFORE THE READ IT GUARDS, and that order is the whole
    # of what makes the comparison below mean anything. Reading first and
    # stamping afterwards leaves a window — from the last line read to the
    # stamp — in which an append lands, is counted into `size_before`, matches
    # `size_after` exactly, and is dropped by a swap that believes nothing
    # moved. The second pass re-reads underneath the stamp, so an append in that
    # window is either seen by the read or caught by the comparison. A lost
    # append is the one failure this function is not allowed to have.
    size_before=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    mtime_before=$(gate_mtime "$f")
    kept=""; dropped=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ -d "$root/run/$line" ]; then
        kept="$kept$line
"
      else
        dropped="$dropped$line
"
      fi
    done < "$f"
    [ -n "$dropped" ] || continue
    # The temp file is in the SAME directory, so the swap is one `rename(2)`.
    tmp="$f.reap-tmp.$$"
    printf '%s' "$kept" > "$tmp" 2>/dev/null || { continue; }
    n_after=$(grep -c . "$tmp" 2>/dev/null || true)
    [ -n "$n_after" ] || n_after=0
    size_after=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    mtime_after=$(gate_mtime "$f")
    if [ "$size_after" != "$size_before" ] || [ "$mtime_after" != "$mtime_before" ]; then
      # Give this file up FOR THIS CYCLE and leave no state behind.
      rm -f "$tmp" 2>/dev/null || true
      continue
    fi
    if [ "$n_after" -eq 0 ]; then
      # An index with nothing left in it is REMOVED, not emptied.
      rm -f "$f" "$tmp" 2>/dev/null || true
    else
      mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; continue; }
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s %s\n' "$line" "$(basename "$f")" >> "$pairs" 2>/dev/null || true
    done <<< "$dropped"
  done
  return 0
}

gate_reap_locked() {
  # gate_reap_locked <root> — the body, split out so the unlock has one caller
  # rather than one per return path. This file has no `trap` habit
  # (`gate_settings_unlock` is called by hand on each path), so the split follows
  # that rather than introducing one.
  local root="$1"
  local start now cand cand_list id rd trash kb bytes days started
  local now2 started2
  local recfile pairs v_items v_files sweep_note
  local deleted=0 candidates=0 total_bytes=0 capped="미도달" gave_up=""
  start=$(date -u +%s)

  # THE SWEEP GOES FIRST, and draws on the same wall clock as the deletions.
  gave_up=$(gate_reap_sweep "$root" "$start")

  mkdir -p "$root/.reap-trash" 2>/dev/null || true
  recfile=$(mktemp "${TMPDIR:-/tmp}/cc-reap-rec.XXXXXX" 2>/dev/null) || return 1
  pairs=$(mktemp "${TMPDIR:-/tmp}/cc-reap-pairs.XXXXXX" 2>/dev/null) \
    || { rm -f "$recfile" 2>/dev/null || true; return 1; }

  # THE PRE-FILTER IS A SUPERSET AND NOTHING MORE. `+25` rather than `+30` is
  # SLACK, not a constant: BSD `find -mtime +30` selects 31 days and over —
  # measured, it missed exactly 30 days, 30 days + 1 second and 30 days + 12
  # hours, a one-day systematic error rather than a rounding edge — so five days
  # of margin keeps this a superset of the authoritative check on any `find`.
  # THE POLICY IS DEFINED BY THE EPOCH ARITHMETIC IN `gate_reap_eligible` AND BY
  # NOTHING ELSE. Anyone "tidying" this to 30 restores that error.
  cand_list=$(find "$root/run" -maxdepth 1 -mindepth 1 -type d -mtime +25 2>/dev/null || true)
  candidates=$(printf '%s' "$cand_list" | grep -c . || true)
  [ -n "$candidates" ] || candidates=0

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    now=$(date -u +%s)
    if [ "$deleted" -ge "$GATE_REAP_MAX" ] \
       || [ $((now - start)) -ge "$GATE_REAP_BUDGET_S" ]; then
      capped="걸림"; break
    fi
    # The victim path is assembled from a basename off the directory listing and
    # nothing else — no manifest string, no ledger field, nothing a model wrote —
    # and carries NO TRAILING SLASH, because `rm -rf dir/` follows a symlink on
    # BSD.
    id=$(basename "$cand")
    rd="$root/run/$id"
    gate_reap_eligible "$rd" "$id" "$now" || continue
    started=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$rd/started-at" 2>/dev/null || true)
    days=$(( (now - started) / 86400 ))
    # Measured BEFORE the rename: after the removal there is nothing left to
    # measure. `du -sk` reports allocation blocks, so this is size on disk rather
    # than the sum of the file lengths.
    kb=$(du -sk "$rd" 2>/dev/null | sed -n '1s/^\([0-9][0-9]*\).*/\1/p')
    [ -n "$kb" ] || kb=0
    bytes=$((kb * 1024))
    trash="$root/.reap-trash/$id.$$.$now"
    # RENAME, THEN DELETE. `rm -rf` under a concurrent writer does not fail
    # cleanly — measured rc=1 with a `watch.heartbeat`-only husk left in place,
    # and a husk with no `ledger-path` counts zero segments and is permanently
    # non-terminal. A partially failed reclamation would therefore MANUFACTURE
    # the immortal run this whole change exists to remove. One atomic
    # `rename(2)` takes the directory out of `run/` first.
    mv "$rd" "$trash" 2>/dev/null || continue
    # THE RETENTION CLOCK IS READ AGAIN, AFTER THE RENAME. Nothing holds a lock
    # on the victim between the verdict and this line: `.reap.lock` excludes
    # reapers from one another and says nothing about the run being judged, and
    # clause 3 compares against THIS process's `RUN_DIR` only. So an ordinary
    # gate entry can land on this id after clause 2 read its clock — and
    # `rundir_init` rewrites `started-at` to now on every entry — while the
    # reaper is still inside `cc_run_state` and the recursive `du -sk` walk
    # above. That is hundreds of milliseconds per victim, times up to
    # `GATE_REAP_MAX` victims a cycle.
    #
    # Deleting through that window does not merely lose a live run. The run's
    # own verbs carry on to an unguarded `mkdir -p "$RUN_DIR/log"` and rebuild
    # the directory with no `started-at` in it, which clause 2 then refuses
    # forever while the `-mtime` pre-filter hides it for another 25 days: this
    # feature would be manufacturing the immortal run it exists to remove.
    #
    # The rename is what makes the re-read possible and it is the last moment at
    # which the deletion is still reversible. `started-at` moved with the
    # directory, so a writer that got in first left its bytes on this same
    # inode, and reading them costs one `sed`. A missing or zero clock is
    # "unknown" and unknown is not reclaimed, exactly as in clause 2.
    if gate_reap_unwind "$trash" "$rd" "$id" "$(date -u +%s)"; then
      continue
    fi
    # A failing removal now leaves the bytes in the trash rather than a husk in
    # `run/`, and the next cycle's sweep takes it from there.
    rm -rf "$trash" 2>/dev/null || true
    deleted=$((deleted + 1))
    total_bytes=$((total_bytes + bytes))
    printf '%s\t%s\t%s\n' "$id" "$days" "$bytes" >> "$recfile" 2>/dev/null || true
  done <<< "$cand_list"

  gate_reap_prune_index "$root" "$pairs"

  # One line per deletion, then one summary line. The per-deletion line carries
  # the run id (the surviving ledger is findable by it), the age AND WHAT THE AGE
  # IS OF — "since the last gate entry", not "since it ended", because the two
  # clocks diverge and an unnamed age is read as the wrong one — the byte count
  # (the only size information that outlives the directory) and the index share.
  # IT DOES NOT CARRY A PATH: the path derives from the id and the state root,
  # and a path in a report is a thing somebody pastes into a command.
  while IFS="$(printf '\t')" read -r id days bytes; do
    [ -n "$id" ] || continue
    v_items=$(grep -c "^$id " "$pairs" 2>/dev/null || true)
    [ -n "$v_items" ] || v_items=0
    v_files=$( { grep "^$id " "$pairs" 2>/dev/null || true; } \
                 | LC_ALL=C sort -u | grep -c . || true )
    [ -n "$v_files" ] || v_files=0
    gate_reap_note "회수: 런 $id — 마지막 게이트 진입 이후 ${days}일 · ${bytes}바이트 · 인덱스 항목 ${v_items}개/${v_files}개 파일에서 제거"
  done < "$recfile"

  # THE SUMMARY IS WRITTEN EVEN WHEN NOTHING WAS DELETED. That is what separates
  # "nothing qualified" from "the reaper never ran" — the distinction this
  # codebase keeps drawing about silence. It is not written when the cadence gate
  # returned early, because that is "not this cycle's turn" rather than "ran and
  # found none".
  now=$(date -u +%s)
  sweep_note=""
  if [ -n "$gave_up" ]; then sweep_note=" · 스윕 포기: $gave_up"; fi
  gate_reap_note "회수 요약: 후보 ${candidates}건 · 삭제 ${deleted}건 · 상한 ${capped} · $((now - start))초 · ${total_bytes}바이트${sweep_note}"

  rm -f "$recfile" "$pairs" 2>/dev/null || true
  return 0
}

gate_reap_cycle() {
  local root stamp now rc lock dead
  root=$(gate_reap_root)
  [ -d "$root/run" ] || return 0
  now=$(date -u +%s)
  # THE CADENCE GATE, one cheap read. autopilot opens runs in bursts, so "once
  # per run" is not the same as "rarely".
  #
  # NOT fail-closed, unlike the retention predicate. A missing or unparsable
  # stamp means "this has never run", not "we cannot tell how old something is":
  # the stamp answers whose turn it is, never whether a directory may die.
  stamp=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$root/reap.stamp" 2>/dev/null || true)
  if [ -n "$stamp" ] && [ $((now - stamp)) -lt "$GATE_REAP_INTERVAL" ]; then
    return 0
  fi
  gate_reap_lock "$root" || return 0
  gate_reap_locked "$root"; rc=$?
  # THE STAMP ADVANCES WHETHER OR NOT THE CAP WAS HIT. Candidates left over wait
  # for the next window rather than being picked up by the next run-open, which
  # is the premise the backlog arithmetic rests on — 103 directories in about six
  # cycles rather than in one burst.
  date -u +%s > "$root/reap.stamp" 2>/dev/null || true
  # THE RELEASE IS ONE RENAME, so no moment exists in which the lock stands
  # without its owner line. Removing the owner and then the directory put every
  # ordinary release through that state, and a `rmdir` that failed for any reason
  # — a leftover artifact inside, `EBUSY`, a filesystem that renames on delete —
  # left behind a lock nothing could date and nothing could break. What this form
  # leaves behind when its own cleanup fails is an inert directory beside the
  # lock: no scan here walks it and no later cycle consults it.
  lock="$root/.reap.lock"
  dead="$lock.dead.$$"
  if mv "$lock" "$dead" 2>/dev/null; then
    rm -rf "$dead" 2>/dev/null || true
  fi
  return $rc
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
# `shift` IS A SETTINGS VARIANT, NOT A UNIT OF WORK. Nothing dispatches into
# it — it IS the routing loop, moved out of the lead session and into a
# headless one. It is on this list because this list is what
# `gate_write_settings` iterates and what `gate_settings_file` resolves
# against, and the shift needs a settings file of its own precisely so it can
# be handed LESS than any stage gets.
#
# TWO LAYERS, TWO NAMES, AND THEY ARE NOT THE SAME NAME. `act --kind
# router-shift` is the LEDGER ROW KIND that authorises the launch; `shift`
# here is the SETTINGS VARIANT handed to the wrapper. Spelling either one in
# the other's slot produces a shift running under settings that are not its
# own — which is the same confusion the warning about the first token after
# `--` already names one layer down.
readonly STAGE_KINDS="design implement review audit reconverge generic shift"

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
  local kind_dirs kind_allow
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

  # THE READ ALLOW-LIST, AND WHY IT IS NOT A DIRECTORY WIDENING. A stage that
  # builds a CLAUDE.md proposal has to read the live file, and the live slots sit
  # outside every directory above. `additionalDirectories` would reach them, but
  # it opens whole trees — the user config directory holds credentials-adjacent
  # state and a skill that handles external logins, and the workspace root holds
  # every sibling repository. Measured: a `permissions.allow` entry naming ONE
  # FILE grants that read and nothing else, and the same read without the entry
  # is refused outright ("Claude requested permissions to read from … but you
  # haven't granted it yet"). So the narrow form is not merely preferable, it is
  # sufficient, and the wide one buys nothing this needs.
  #
  # DERIVED, NEVER ENUMERATED. The slots are absolute paths outside the
  # repository and differ per machine; a literal list would be correct on the
  # author's box and silently empty everywhere else. The set built here is
  # exactly the chain the harness itself loads into every session's prefix — the
  # user-scope file plus a `CLAUDE.md` in each ancestor of the base worktree — so
  # granting a read of it grants nothing the stage's own prompt did not already
  # contain.
  local cfgdir adir aprev allow_extra=""
  cfgdir="${CLAUDE_CONFIG_DIR:-}"
  [ -n "$cfgdir" ] || cfgdir="${HOME:-}${HOME:+/.claude}"
  cfgdir="${cfgdir%/}"
  # `Read(` takes the path with ONE extra leading slash — the repo's own
  # `.claude/settings.local.json` spells `/tmp` as `Read(//tmp/**)`. These values
  # are already absolute, so the literal here is a single slash and the path
  # supplies the second. A third slash was measured and it also resolves, so this
  # is a convention rather than a correctness constraint; it is written the one
  # way the tree already spells it so a reader comparing the two files does not
  # have to wonder which spelling is the working one.
  [ -n "$cfgdir" ] && allow_extra="\"Read(/$cfgdir/CLAUDE.md)\""
  # TERMINATION IS ON `dirname` SHRINKING, not on reaching `/`. `dirname .` is
  # `.` and `dirname x` is `.` as well, so a relative or empty `BASE` walks this
  # loop forever — and it runs at run open, before anything has been recorded, so
  # the run would hang with no row saying why. The `/` test alone never fires on
  # those inputs. Bounded twice: the value has to keep changing, and it has to be
  # absolute to contribute a rule at all.
  adir="$BASE"
  while [ -n "$adir" ] && [ "$adir" != "/" ]; do
    case "$adir" in
      /*) if [ -n "$allow_extra" ]; then allow_extra="$allow_extra, "; fi
          allow_extra="$allow_extra\"Read(/$adir/CLAUDE.md)\"" ;;
      *)  break ;;
    esac
    aprev="$adir"
    adir=$(dirname "$adir")
    [ "$adir" != "$aprev" ] || break
  done

  for k in $STAGE_KINDS; do
    f=$(gate_settings_file "$k")
    # `design` alone loses the network-fetch tools. The per-stage spend cap that
    # motivates it cannot be enforced by the argv0 grading table at all — a
    # `WebFetch` call has no argv0 and never reaches the gate — so the only
    # enforcement point available is the settings file the wrapper injects.
    deny_extra=""
    [ "$k" = "design" ] && deny_extra='"WebFetch", "WebSearch", '

    # THE SHIFT VARIANT IS NARROWER THAN EVERY STAGE, AND THE NARROWING HAS TO
    # HAPPEN INSIDE THIS LOOP. `extra_dirs` and the read allow-list are computed
    # ONCE above and interpolated identically into every variant; the only thing
    # that has ever branched per kind is `deny_extra`. So adding the token to
    # `STAGE_KINDS` without this branch writes the file and leaves the
    # permissions wide — the file exists, the launch succeeds, and nothing says
    # the narrowing did not happen.
    #
    # A shift writes no files. Its loop is snapshot → decide → gate, and
    # everything it changes goes through the gate's own bash path, so a Write
    # that leaked would land somewhere git has no history to undo it.
    # `additionalDirectories` is READ authorisation as well, so the stage list
    # would also let the routing seat read files routing has no use for — and
    # every directory in that list is an element of the enforcement-surface
    # digest, so an unnecessary one widens the surface an `exit 7` is measured
    # against.
    #
    # BOTH HALVES COME OUT, and dropping only one is the trap. The directories
    # go out through `additionalDirectories` and the individual CLAUDE.md reads
    # through `permissions.allow`; leaving the allow-list in place re-opens
    # exactly as much as narrowing the directory list just closed.
    #
    # THE HOOK'S CLAUDE.md REFUSAL ARM STAYS IN EVERY VARIANT, THIS ONE
    # INCLUDED. It never fires here, because the path is unreachable to begin
    # with. But where a run reaches those files through the read allow-list
    # instead of through a directory grant, that arm is the only defence left,
    # so it is not this branch's to remove.
    kind_dirs="$extra_dirs"
    kind_allow="$allow_extra"
    if [ "$k" = "shift" ]; then
      kind_dirs=""
      kind_allow=""
      deny_extra="${deny_extra}\"Write\", \"Edit\", \"MultiEdit\", \"NotebookEdit\", "
    fi
    cat > "$f" <<JSON
{
  "permissions": {
    "deny": [ ${deny_extra}"Bash(sudo:*)" ],
    "allow": [ ${kind_allow} ],
    "additionalDirectories": [ ${kind_dirs} ]
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
  #
  # ONE PROCESS FOR THE WHOLE LEDGER, NOT THREE PER ROW. This walk used to spawn
  # `sed`, `shasum` and `cut` once per row — exactly 3n+2 processes for n rows —
  # and on this platform `shasum` is itself a Perl program wrapping
  # `Digest::SHA`. Calling that module directly is therefore not a different hash
  # implementation but the SAME ENGINE with n-1 interpreter startups removed,
  # which is the strongest equivalence argument available for rewriting a path
  # that issues verdicts.
  #
  # THE CHARACTER-TYPE PIN IS GONE FROM THIS FUNCTION, and its absence is not a
  # relaxation. The pin was here because `sed` extracted `prev=`, and under a
  # UTF-8 `LC_CTYPE` that extractor stopped being a function of the row's
  # content — BSD `sed` aborted on an invalid byte and printed nothing, GNU `sed`
  # returned output with the unsubstituted prefix still attached, and neither was
  # the hex the row carried. There is no `sed` here now: the file is opened raw
  # and matched as bytes unconditionally, which is what the pin was buying. The
  # other three ledger readers still pin, because they still shell out.
  local walk rc broke cause
  # AN ABSENT LEDGER USED TO VERIFY. The redirection below fails, the loop body
  # never runs, `broke` stays 0, and the function returns "intact" for a file it
  # never opened — so deleting the ledger outright was quieter than editing one
  # row of it. Nothing can be said about a chain that was not read, and this is
  # the difference between "verified intact" and "not verified".
  if [ ! -f "$LEDGER" ]; then
    warn "원장 파일이 없어 해시 체인을 검증하지 못했습니다 — 무결이 아니라 미검증입니다: $LEDGER"
    return 1
  fi
  # The whole walk, in one pass. Four behaviours are decided deliberately here
  # and none of them is incidental:
  #
  #   * ROW SELECTION and ROW NUMBERING are unchanged — a line is a row when it
  #     starts with "- `", and an unreadable row still consumes its number, so
  #     every committed fixture keeps the `broke` value it pins.
  #   * THE EXTRACTOR keeps its greedy match, so it takes the LAST `| prev=` on
  #     the row and yields nothing unless what follows is hex all the way to the
  #     end of the line.
  #   * A ROW WHOSE `prev=` CANNOT BE READ IS A BREAK, not a row to step over.
  #     Stepping over it left `prev` un-advanced, so the chain re-joined across
  #     the row as though it had never been there and a forged approval spliced
  #     in with no `prev=` — or with one made unreadable by a single invalid
  #     byte — was reported as intact. That is a fixed defect; reproducing it
  #     here for the sake of "same verdict as before" would be an instruction to
  #     regress.
  #   * `read`'s EOF SEMANTICS ARE NOT REPRODUCED, and dropping them tightens
  #     detection rather than relaxing it. A final chunk with no terminating
  #     newline used to end the walk before it was counted, so a forged approval
  #     row appended with the newline left off was never visited at all — while
  #     every other consumer read it as a valid row and the authorization took
  #     effect. It is cheaper to produce than any of the three shapes above:
  #     not printing one byte is the whole attack.
  #
  #     A FALSE POSITIVE IS NOT POSSIBLE HERE, and the reason is in `gate_append`
  #     rather than in this function. That is the ledger's only writer, and both
  #     of its branches — the locked `/bin/sh -c` and the no-lock fallback — write
  #     through a `printf` whose format ends in `\n`. A ledger the gate wrote
  #     therefore always ends with a newline, so a final row that does not is by
  #     itself evidence of a write that did not come through the gate.
  #
  #     Only a ROW-SHAPED chunk is judged. A partial write that is not row-shaped
  #     — a truncated heading, half a prose line — still ends the walk silently,
  #     because counting a non-row as a row would move the `broke` value every
  #     committed fixture pins.
  #
  #     The other thing NOT reproduced is what `read` does to a NUL byte — it
  #     drops or truncates there depending on the interpreter, and hashing the
  #     row's true bytes instead is a gain in detection, listed as such rather
  #     than hidden.
  walk=$(perl -MDigest::SHA=sha256_hex -e '
    my ($ledger, $seed) = @ARGV;
    open(my $fh, "<", $ledger) or exit 3;
    binmode($fh);
    my $prev = sha256_hex($seed);
    my ($n, $broke, $cause) = (0, 0, 0);
    while (defined(my $line = <$fh>)) {
      unless ($line =~ s/\n\z//) {
        last unless substr($line, 0, 3) eq "- `";
        $n++; $broke = $n; $cause = 2; last;
      }
      next unless substr($line, 0, 3) eq "- `";
      $n++;
      my $want = $line =~ /^.*\| prev=([0-9a-f]*)\z/ ? $1 : "";
      if ($want eq "") { $broke = $n; $cause = 1; last }
      if ($want ne $prev) { $broke = $n; last }
      $prev = sha256_hex($line);
    }
    print "$broke $cause\n";
    exit 0;
  ' -- "$LEDGER" "## 실행 $RUN_ID" 2>&1)
  rc=$?
  # A FAILING TOOL AND A BROKEN CHAIN ARE NOT THE SAME FINDING. If `perl` or the
  # module is missing, or the process dies, then no verdict was reached at all —
  # and answering "splice, delete or reorder" there sends the morning reader
  # looking for something that did not happen. Every morning report would say the
  # chain broke, and a reader who sees that daily learns to skip the one field
  # that would have told them. The 0/1 return contract is NOT widened: two
  # consumers read it as a boolean, and what separates the two cases is the
  # sentence. stderr is folded into the captured output so a diagnostic cannot
  # reach the render path, which reads any stderr as a break.
  case "$walk" in
    [0-9]*" "[012]) ;;
    *) rc=1 ;;
  esac
  if [ "$rc" != 0 ]; then
    warn "원장 해시 체인을 검증하지 못했습니다 — 단일 패스 검증기가 판정을 내지 못했습니다 (perl 또는 Digest::SHA): ${walk}"
    return 1
  fi
  broke=${walk%% *}
  cause=${walk##* }
  [ "$broke" = "0" ] && return 0
  # Three causes, three sentences. They are NOT the same finding: a mismatch
  # means some row moved, an unreadable `prev=` means THIS row cannot be placed
  # in the chain at all, and a row that does not end with a newline means the row
  # was appended by something other than the gate. Pointing a reader at
  # splice/delete/reorder for either of the last two sends them to look for
  # something that did not happen. `cause` is an encoding internal to this
  # function — the 0/1 return contract and the boolean `chain_intact` field both
  # stay exactly as they were, and the two consumers go on reading non-zero as a
  # break. What the number selects is the sentence.
  if [ "$cause" = "2" ]; then
    warn "원장 해시 체인이 ${broke}번째 행에서 끊겼습니다 — 그 행이 개행으로 끝나지 않습니다 (게이트가 쓴 원장은 언제나 개행으로 끝나므로 게이트 밖에서 덧붙여진 행입니다)"
  elif [ "$cause" = "1" ]; then
    warn "원장 해시 체인이 ${broke}번째 행에서 끊겼습니다 — 그 행의 prev= 를 읽을 수 없습니다 (필드가 없거나 hex 가 아니거나 무효 바이트가 섞였습니다)"
  else
    warn "원장 해시 체인이 ${broke}번째 행에서 끊겼습니다 — 스플라이스·삭제·재배열 중 하나입니다"
  fi
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
  # Through `owner_doc_match`, which is the driver's reader too. Two readers with
  # independently spelled acceptance sets is what let a grant pass kickoff and
  # then have every act here refused — the stage did nothing, exited clean, and
  # was recorded as a hollow success.
  mowner=$(manifest_hdr_field 'owner-doc')
  gowner=$(grant_owner_doc)
  if [ -z "$gowner" ]; then
    warn "인가 기록에 owner-doc= 이 없습니다 — fail-closed"
    return "$GATE_EXIT_RULE"
  fi
  if ! owner_doc_match "$mowner" "$gowner"; then
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
  # gate_surface_check <호출 동사>
  #
  # Compared on every act, not only at run start. The four surfaces the hook
  # cannot deny a write to get after-the-fact detection only, and after-the-fact
  # is still before the NEXT act — which is the difference between one act
  # slipping through and the rest of the night doing so.
  #
  # THE VERB DECIDES ONLY WHETHER THE CONSEQUENCE IS RECORDED, never whether the
  # comparison happens. Everything down to the verdict is a pure read — the
  # baseline file, the digest, the equality — so a dry run can answer this axis
  # exactly and cheaply, and a verb that could answer it and returned zero
  # instead is the defect class this whole change removes.
  # NO BASELINE FILE AND AN EMPTY ONE ARE DIFFERENT ANSWERS, and reading them as
  # the same one made this check fail OPEN on exactly the input it exists to
  # catch. A missing file means the run has not been baselined yet — kickoff
  # writes it, and every act before that has nothing to compare against, so
  # returning zero there is the only thing it can do. A file that is PRESENT and
  # EMPTY means the baseline was written and the value in it is gone: the digest
  # this comparison needs was lost, not never taken. Collapsed together, that
  # second state passed every act for the rest of the night without ever
  # comparing anything, silently, while the surrounding documentation promises
  # the opposite — that a run whose surface moved does not recover. Lost signal
  # takes the same exit as a moved surface, which is what fail-closed means here.
  local verb="${1:-act}" base now
  [ -f "$RUN_DIR/surface-digest" ] || return 0
  base=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || true)
  if [ -z "$base" ]; then
    warn "강제 표면 기준선 파일이 비어 있습니다 — 기준선이 기록된 뒤 값이 사라졌으므로 비교할 것이 없습니다"
    base='(비어 있음)'
  fi
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
  # A DRY RUN STOPS HERE, and the three things below are each independently a
  # reason it must. The row it would append carries `원인=무효화`, which
  # condition 5 declares permanently unresolvable — so a question about the run
  # would end the run. The `done` path then opens for a run nobody proposed to
  # finish. And the same branch fires a desktop banner at a sleeping person to
  # report an event that did not happen.
  #
  # What the caller gets instead is the exit code by itself: on `plan`, 7 is a
  # forecast rather than an event.
  if [ "$verb" = "plan" ]; then
    warn "plan(dry-run): 같은 argv 의 act 는 여기서 exit 7 을 받습니다 — 예고이므로 blocked 행도 배너도 남기지 않았습니다"
    return "$GATE_EXIT_SURFACE"
  fi
  if ! gate_has_row 'blocked' '사유=강제 표면 이동'; then
    gate_append 'blocked' "대상=${CC_PIPELINE_TARGET:--}" "스코프=run" "원인=무효화" \
      "사유=강제 표면 이동" "관측=$(now_iso)" \
      "재개 명령=새 런으로 다시 킥오프 — 이 런의 기준선은 다시 잡히지 않습니다"
    # THE RUN ANCHORED AND CANNOT BE UNANCHORED. This is one of the two places
    # the run's own end is decided rather than observed, and the notice belongs
    # here because the other channel cannot carry it: the watcher's terminal arm
    # keys on a predicate that requires zero unresolved run-scope blocks, and
    # this row is exactly such a block, so that arm is silent for this run
    # forever.
    #
    # `rekick` and not `hands`: the gate refuses to resolve a block whose cause
    # is invalidation, so it is not something a person can put their hands on. It
    # fails the stacking test — "an individually identified thing that stays put
    # until a person touches THAT" — so it takes the per-run replace slot, and
    # the title names the one action actually available here, which is to open a
    # fresh run because this one's baseline cannot be taken again.
    if gate_may_raise_banner && [ -n "${RUN_DIR:-}" ] && [ ! -f "$RUN_DIR/notify.announced-void" ]; then
      : > "$RUN_DIR/notify.announced-void" 2>/dev/null || true
      cc_notify_fire rekick \
        "이 런은 여기서 끝났습니다 — 기준선은 다시 잡히지 않으니 새 런으로 다시 킥오프하세요" || true
    fi
  fi
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
  local approval="" render=0 worktree="" void=0 reject=0
  local emit_digest_seen=0 emit_digest_dir=""
  GATE_RESUME=""; export GATE_RESUME
  # The emit path travels to `gate_verb_act` as a global rather than as an
  # eleventh positional argument, the same way `GATE_RESUME`, `GATE_ACT_CWD` and
  # `GATE_SURFACE` already do. Adding a position would mean fixing the call site
  # and the `shift 9` arithmetic inside the callee at the same time, for a value
  # neither of them decides anything on.
  GATE_EMIT_DIGEST_TO=""; export GATE_EMIT_DIGEST_TO
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
      # A BOOLEAN. It took a path once; see the emission block for why it does
      # not any more. The old spelling is refused rather than ignored, because a
      # caller passing a path believes it chose where the value lands.
      --emit-digest)     emit_digest_seen=1; shift ;;
      --emit-digest-to)  printf 'gate: --emit-digest-to 는 없어졌습니다 — 경로 없이 --emit-digest 를 쓰세요 (게이트가 런 디렉터리 아래 경로를 정합니다)\n' >&2
                         exit 2 ;;
      --rationale)       rationale="$2"; shift 2 ;;
      --approval)        approval="$2"; shift 2 ;;
      --worktree)        worktree="$2"; shift 2 ;;
      --render)          render=1; shift ;;
      --void)            void=1; shift ;;
      --reject)          reject=1; shift ;;
      --resume)          GATE_RESUME="$2"; shift 2 ;;
      --)                shift; break ;;
      *) printf 'gate: 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  # THE EMIT PATH IS SETTLED BEFORE ANYTHING READS THE LEDGER, because its
  # failure is an argv error and not a run state — and because the failure the
  # caller cannot afford is the silent one. A caller that asked for the digest
  # and got no file falls back to the round trip forever, which looks exactly
  # like the flag working and saving nothing. Refusing with the same exit 2 the
  # unknown-argument arm uses is what makes that case audible.
  # ARGV SHAPE ONLY. Everything that touches the filesystem moved below
  # `rundir_init`, and the reason is not tidiness: creating the parent directory
  # here happened before the manifest existence check, before `check_manifest`,
  # before `gate_check_grant` and before the run directory exists, so a call
  # that was about to be refused had already made a directory and no row
  # recorded it.
  # ACCEPTED ONLY WHERE IT DOES SOMETHING. Emission happens on the acting verbs
  # and nowhere else, but the flag used to be parsed, validated and have its
  # parent directory created on every verb — so `snapshot`, `grade` and `plan`
  # took a value they would never use and made a directory for it. A flag that
  # is silently inert is a flag a caller believes is working.
  if [ "$emit_digest_seen" = "1" ]; then
    case "$verb" in
      act|exec) ;;
      *) printf 'gate: --emit-digest 는 act 와 exec 에서만 쓰입니다 (받은 동사: %s)\n' "$verb" >&2
         exit 2 ;;
    esac
  fi

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

  # THE GATE CHOOSES THE PATH. THE CALLER DOES NOT NAME ONE.
  #
  # This flag used to take a path, and four review cycles were spent on the
  # checks that made a caller-named path safe: confinement to the run
  # directory, then to a quarantine inside it, a basename pattern, a `..`
  # rejection, physical resolution of both sides, an ordering between the
  # creation guard and the physical test. Each round closed a hole and two of
  # them opened a new one — the anchor derived from the component it was
  # confining, and a `mkdir -p` that ran before the test that would refuse it.
  #
  # None of those checks buy anything, because no caller ever needed to choose.
  # The gate already knows the run directory and already knows the actor, so the
  # path is a value it can compute — and a value it computes is a value nobody
  # can point somewhere else. Removing the parameter removes the entire class,
  # rather than adding a seventh check to it.
  if [ "$emit_digest_seen" = "1" ]; then
    emit_digest_dir="$RUN_DIR/digest"
    mkdir -p "$emit_digest_dir" 2>/dev/null || true
    GATE_EMIT_DIGEST_TO=$(gate_digest_path)
    # THE RULE IS "EVERY PATH THAT APPENDS A ROW EMITS AFTER ITS LAST APPEND",
    # and an enumeration of exit points is the wrong shape for it — the first
    # enumeration missed four refusals that append a row and then exit, and a
    # caller reading no file there falls back to the round trip forever, which
    # looks exactly like the flag working and saving nothing. A trap states the
    # rule once and cannot fall behind a new exit.
    #
    # Emitting on a path that appended nothing is harmless: the value is the
    # current digest either way, and a caller holding a correct digest is the
    # point. `plan` is excluded because it is excluded by contract, not because
    # it happens to write no row.
    case "$verb" in
      act|exec) trap 'gate_emit_digest' EXIT ;;
    esac
  fi

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
  # NO LOCK HERE, and that is a decision rather than an omission. This path runs
  # on every gate entry (over 875 times in the busiest run), and the one failure
  # the lock would close SELF-HEALS: the append is unconditional, so the session's
  # next gate entry puts a lost id back. The prune side carries the
  # compare-and-swap instead.
  #
  # Entries for runs whose directory is gone stay put until a reap cycle removes
  # them: the reader filters with `[ -d ]`, and that filter is what makes an entry
  # outliving its directory harmless — which in turn is why the prune can run on a
  # sparse schedule instead of tracking every deletion.
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
  # AND NOT A SHIFT EITHER, WHICH THE STAGE TEST ALONE DOES NOT COVER. A router
  # shift IS a router, so it walks through this gate and gets enrolled — and an
  # enrolled session id is an id allowed to ANSWER, so `gate_close` would then
  # read the shift's own transcript as a person's reply. That is the
  # self-approval path the separation exists to keep shut, arriving through the
  # one door the guard was not watching. A person can answer only at the lead,
  # so the lead is the only seat lineage holds.
  #
  # `CC_PIPELINE_SHIFT_ID` is exported by `gate_launch_shift` and by nothing
  # else, so like the stage marker beside it this is a structural distinction
  # rather than a heuristic.
  #
  # THE WRITER IS A SEPARATE FUNCTION FROM THE READER, and that is what makes
  # this guard the whole door rather than one of several. While enrolment was a
  # side effect of reading, anything that read the lineage enrolled its caller
  # past this test — `gate_shift_state` reaches the reader from `snapshot`, so a
  # stage that took a snapshot put itself in the set of ids allowed to answer.
  [ -n "${CC_PIPELINE_STAGE_ID:-}" ] || [ -n "${CC_PIPELINE_SHIFT_ID:-}" ] \
    || gate_session_lineage_record

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
    # `강제 코드` and `베이스 청결` are the two the morning reads. The surface
    # digest above deliberately excludes the plugin files — a redeploy that
    # rewrites a rule must not kill a running run, and that exclusion is what
    # makes it safe. The cost is that the code actually enforcing this run is
    # unrecorded, so these two record it instead of detecting it: the base HEAD
    # at kickoff, and whether that tree had uncommitted changes. A run opened on
    # a dirty tree ran enforcement code no review saw, and without this field the
    # morning cannot tell that apart from a clean night.
    gate_append 'run' "run-id=$RUN_ID" "시작=$(now_iso)" \
      "설계 문서=${DOC_KEY:-(없음)}" "전체 sha256=$(whole_digest 2>/dev/null || printf '(해당 없음)')" \
      "구속면 다이제스트=$(cat "$RUN_DIR/surface-digest" 2>/dev/null || printf '(미기록)')" \
      "강제 코드=$( { cd "$BASE" 2>/dev/null && git rev-parse HEAD 2>/dev/null; } || printf '(미상)')" \
      "베이스 청결=$( { cd "$BASE" 2>/dev/null && [ -z "$(git status --porcelain 2>/dev/null)" ]; } && printf '예' || printf '아니오')" \
      "RUN_DIR=$RUN_DIR" "보고서=$LEDGER"
    # AFTER the `run` row, and only here. Before it, a reap that died would leave
    # the run without so much as its own opening row; and this is the one branch
    # that runs once per run rather than once per gate entry.
    #
    # `|| true` because reclamation is housekeeping, not the run's work. A run
    # must not fail to open because a directory somewhere else could not be
    # removed.
    gate_reap_cycle || true
  else
    gate_resettle_settings
  fi

  case "$verb" in
    digest-path)
      # Reading, not acting: it prints where an emission would land and writes
      # nothing. The hook calls this instead of rebuilding the path.
      gate_digest_path; printf '\n' ;;
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
      #
      # The version-skew hint belongs here as much as on the acting path, and
      # arguably more: `grade` is what a caller runs to find out what to declare,
      # so this is where the answer "the table has no row for a script sitting
      # next to me" is cheapest to receive. The acting path reaches the same
      # helper through `gate_verb_act`; this arm never gets there, because it
      # calls the table directly and returns.
      if [ "$g" = "등급 미상" ]; then
        gate_orchestrator_script_hint "$1"
        exit "$GATE_EXIT_VOCAB"
      fi
      ;;
    plan|act|exec)
      gate_verb_act "$verb" "$kind" "$alias" "$segment" "$cutpoint" "$surface" \
                    "$snapdig" "$rationale" "$worktree" "$@"
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
    prompt)
      # Reading, not acting: it prints the canonical question and the gate's
      # menu for one approval and writes nothing.
      [ -n "$approval" ] || { printf 'gate: prompt 는 --approval 이 필요합니다\n' >&2; exit 2; }
      gate_prompt "$approval"
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
# The approval sidecar — `<base>/docs/pipeline-approval/<run-id>.md`.
#
# A `승인` row carries an EXCERPT of the question and of the answer and a digest
# of each; the full text lives here, one block per approval id, so the digests
# on the row have something to be compared against. Keyed on the RUN and not on
# the design document: a run may start from a pull request or a bare intent
# and have no document to derive a slug from, so this kind proves its ownership
# with `owner-run=<run-id>` plus the existence of that run's authorization
# record, and a file that fails either half is not read and not extended.
#
# THE GATE IS ITS ONLY WRITER AND CREATES ITS DIRECTORY. The sidecar contract
# makes the directory the writer's duty, and without the `mkdir -p` the first
# approval of a fresh checkout would fail exactly on the path this file exists
# for — the free-input answer that the ledger deliberately does not carry.
#
# Blocks are `## 승인 <id>`. The IMMUTABLE region — the question's sha256 and
# its fenced text — is written when the approval is issued and never rewritten;
# the MUTABLE region — the answer's sha256 and its fenced text — is filled when
# the approval closes, and re-filled if a later answer supersedes an earlier
# one. Writes take the contract's atomic form: a temp file in the same
# directory, a compare-and-swap against the bytes the build read, a plain `mv`,
# a bounded retry. Nothing here deletes.
# ---------------------------------------------------------------------------
readonly GATE_APPROVAL_SIDECAR_KIND="cc-pipeline-approval v1"

gate_approval_sidecar_path() {
  # Nothing when either half of the path is unknown: a caller sourcing this
  # file without a manifest has no base and no run, and `/docs/pipeline-approval/.md`
  # is a real path that must not be created by accident.
  [ -n "${BASE:-}" ] && [ -n "${RUN_ID:-}" ] || return 1
  printf '%s/docs/pipeline-approval/%s.md' "$BASE" "$RUN_ID"
}

gate_approval_sidecar_anchor() {
  # gate_approval_sidecar_anchor <승인 id> — the row field that names the block.
  printf '%s#%s' "${RUN_ID:-(미상)}" "$1"
}

gate_approval_sidecar_ok() {
  # gate_approval_sidecar_ok [<path>] — 0 when the file is absent (creation is
  # legitimate) or proves itself this run's: the kind token is strictly equal,
  # `owner-run=` names this run, and the run's authorization record exists.
  # Anything else is fail-closed for reading and writing alike.
  local f="${1:-}" hdr
  [ -n "$f" ] || f=$(gate_approval_sidecar_path) || { warn "승인 사이드카 경로를 유도할 수 없습니다 (BASE·RUN_ID 미상)"; return 1; }
  [ -e "$f" ] || { [ -n "${GRANT:-}" ] && [ -f "$GRANT" ] && return 0; warn "승인 사이드카를 쓰려면 이 런의 인가 기록이 있어야 합니다: ${GRANT:-(미상)}"; return 1; }
  hdr=$(sed -n '2p' "$f" 2>/dev/null || true)
  case "$hdr" in
    "<!-- $GATE_APPROVAL_SIDECAR_KIND; "*"owner-run=$RUN_ID;"*) ;;
    *) warn "승인 사이드카의 머신 헤더가 이 런의 것이 아닙니다 (kind·owner-run 불일치) — 읽지도 쓰지도 않습니다: $f"; return 1 ;;
  esac
  [ -n "${GRANT:-}" ] && [ -f "$GRANT" ] || { warn "승인 사이드카의 증명쌍 절반인 인가 기록이 없습니다: ${GRANT:-(미상)} — 읽지도 쓰지도 않습니다"; return 1; }
  return 0
}

gate_fence_for() {
  # gate_fence_for <text> — a backtick fence one longer than the longest run
  # of backticks in the text, never shorter than three, so the payload cannot
  # close its own fence.
  local n
  n=$(printf '%s\n' "$1" | LC_ALL=C awk '
    { m = 0; c = 0; for (i = 1; i <= length($0); i++) { if (substr($0, i, 1) == "`") { c++; if (c > m) m = c } else c = 0 } if (m > best) best = m }
    END { printf "%d", (best + 1 > 3) ? best + 1 : 3 }')
  printf '%*s' "$n" '' | tr ' ' '`'
}

gate_approval_sidecar_header() {
  printf '# 파이프라인 승인 기록 — %s\n' "$RUN_ID"
  printf '<!-- %s; writer=gate; reader=gate; owner-run=%s; owner-doc=%s; NOT a design doc; mechanism-local, never staged by a skill -->\n' \
    "$GATE_APPROVAL_SIDECAR_KIND" "$RUN_ID" "${DOC_KEY:-(없음)}"
}

gate_approval_sidecar_region() {
  # gate_approval_sidecar_region <label> <text> — one fenced region: the
  # digest line, the fence, the text, the fence.
  local label="$1" text="$2" fence
  fence=$(gate_fence_for "$text")
  printf '**%s sha256**: %s\n' "$label" "$(printf '%s' "$text" | shasum -a 256 | cut -d' ' -f1)"
  printf '%stext\n%s\n%s\n' "$fence" "$text" "$fence"
}

gate_approval_sidecar_build() {
  # gate_approval_sidecar_build <snap> <id> <region-file> <mode> — the whole
  # new file on stdout, built from the snapshot. `mode` is `issue` (add the
  # block with its question region if no block exists; leave an existing block
  # alone) or `answer` (replace or add the answer region inside the block).
  #
  # Fence-aware: a `## 승인` line inside an open fence is payload, and the
  # tracker matches the CLOSING fence by the exact backtick string that opened
  # it, so a shorter run of backticks in the payload does not close it.
  local snap="$1" id="$2" region="$3" mode="$4"
  if [ ! -s "$snap" ]; then
    gate_approval_sidecar_header
    printf '\n## 승인 %s\n' "$id"
    cat "$region"
    return 0
  fi
  LC_ALL=C awk -v id="$id" -v mode="$mode" -v regionfile="$region" '
    function flush_region(   line) {
      while ((getline line < regionfile) > 0) print line
      close(regionfile)
    }
    function fence_len(s,   i, n) { n = 0; for (i = 1; i <= length(s); i++) { if (substr(s, i, 1) == "`") n++; else break } return n }
    BEGIN { infence = 0; inblock = 0; found = 0; inanswer = 0; done = 0 }
    {
      line = $0
      if (infence) {
        if (fence_len(line) == flen && length(line) == flen) { infence = 0 }
        if (inblock && mode == "answer" && inanswer) next
        print line; next
      }
      fl = fence_len(line)
      if (fl >= 3) {
        infence = 1; flen = fl
        if (inblock && mode == "answer" && inanswer) next
        print line; next
      }
      if (line ~ /^## 승인 /) {
        if (inblock && mode == "answer" && !done) { flush_region(); done = 1 }
        inblock = (line == "## 승인 " id); if (inblock) found = 1
        inanswer = 0
        print line; next
      }
      if (inblock && mode == "answer" && line ~ /^\*\*답변 sha256\*\*: /) { inanswer = 1; next }
      if (inblock && mode == "answer" && inanswer && line ~ /^[[:space:]]*$/) { next }
      inanswer = 0
      print line
    }
    END {
      if (mode == "answer" && inblock && !done) { flush_region(); done = 1 }
      if (!found) { printf "\n## 승인 %s\n", id; flush_region() }
    }
  ' "$snap"
}

gate_approval_sidecar_write() {
  # gate_approval_sidecar_write <id> <mode> <label> <text> — commit one region
  # through the atomic compare-and-swap. 0 on commit; non-zero means nothing
  # was written and the caller must not proceed as if it had.
  local id="$1" mode="$2" label="$3" text="$4" f dir snap t region attempt
  f=$(gate_approval_sidecar_path) || { warn "승인 사이드카 경로를 유도할 수 없습니다 (BASE·RUN_ID 미상)"; return 1; }
  dir=$(dirname "$f")
  gate_approval_sidecar_ok "$f" || return 1
  region=$(mktemp) || return 1
  gate_approval_sidecar_region "$label" "$text" > "$region"
  for attempt in 1 2 3; do
    mkdir -p "$dir" || { rm -f "$region"; return 1; }
    snap=$(mktemp) || { rm -f "$region"; return 1; }
    cp "$f" "$snap" 2>/dev/null || : > "$snap"
    t=$(mktemp "$dir/.$(basename "$f").XXXXXX") || { rm -f "$snap" "$region"; return 1; }
    if ! gate_approval_sidecar_build "$snap" "$id" "$region" "$mode" > "$t"; then
      rm -f "$t" "$snap" "$region"; return 1
    fi
    [ -s "$t" ] || { rm -f "$t" "$snap" "$region"; return 1; }
    if { [ -e "$f" ] && cmp -s "$snap" "$f"; } || { [ ! -e "$f" ] && [ ! -s "$snap" ]; }; then
      if mv "$t" "$f"; then
        rm -f "$snap" "$region"
        # Read-back: this attempt's own block heading must be present.
        grep -qxF "## 승인 $id" "$f" 2>/dev/null || { warn "승인 사이드카 되짚어 읽기 실패 — 블록이 보이지 않습니다: $f ## 승인 $id"; return 1; }
        return 0
      fi
    fi
    rm -f "$t" "$snap"
  done
  rm -f "$region"
  warn "승인 사이드카 쓰기가 세 번의 시도 안에 확정되지 않았습니다 — 아무것도 쓰지 않았습니다: $f"
  return 1
}

gate_approval_sidecar_question() {
  # gate_approval_sidecar_question <id> — the full question text of a block,
  # or nothing when the file fails its proof pair or holds no such block.
  local f
  f=$(gate_approval_sidecar_path) || return 0
  [ -f "$f" ] || return 0
  gate_approval_sidecar_ok "$f" 2>/dev/null || return 0
  LC_ALL=C awk -v id="$1" '
    function fence_len(s,   i, n) { n = 0; for (i = 1; i <= length(s); i++) { if (substr(s, i, 1) == "`") n++; else break } return n }
    BEGIN { inblock = 0; want = 0; infence = 0 }
    {
      if (infence) {
        if (fence_len($0) == flen && length($0) == flen) { infence = 0; if (want) exit; next }
        if (want) print; next
      }
      fl = fence_len($0)
      if (fl >= 3) { infence = 1; flen = fl; next }
      if ($0 ~ /^## 승인 /) { inblock = ($0 == "## 승인 " id); next }
      if (inblock && $0 ~ /^\*\*질문 sha256\*\*: /) { want = 1; next }
    }
  ' "$f"
}

gate_canon_prompt() {
  # gate_canon_prompt <id> <question> — the canonical prompt. `승인 <id> — <question>`
  # is what the router must put verbatim into the question it asks, and the id
  # riding inside that question is how the answer frame is found again.
  #
  # ON STDERR AT ISSUE TIME AND ON STDOUT ONLY THROUGH THE `prompt` VERB. The
  # issuing paths run inside `act` and `exec`, whose stdout belongs to the act —
  # a boundary approval opening in the middle of `exec -- git rev-parse HEAD`
  # would otherwise put this line in front of the sha a caller captured. The
  # router gets the same bytes, as JSON, from `gate.sh prompt --approval <id>`.
  printf '승인 %s — %s' "$1" "$2"
}

gate_warn_canon_prompt() {
  warn "$(gate_canon_prompt "$1" "$2")"
}

gate_prompt() {
  # gate_prompt <승인 id> — the question the router must put to a person, as
  # one JSON object: `{"id","cutpoint","state","question","menu_version",
  # "options":[{"label","description"}...]}`. THIS IS THE CONSUMPTION POINT OF
  # THE CANONICAL PROMPT. The router carries `question` verbatim into
  # `AskUserQuestion` and renders `options[]` verbatim (adding at most the
  # authoring rule's ` ← 추천` suffix to one label); the gate then finds the
  # answer frame by the id inside that question and compares the menu the
  # person saw against the same table this printed from. Act and boundary
  # approvals have no menu, so `options` is empty for them and the router asks
  # as it does today.
  #
  # The question text is the sidecar's full text when the block exists and
  # proves itself this run's, and the row's excerpt otherwise — an approval
  # issued before the sidecar existed is still askable.
  local id="$1" row cutp full l opts
  row=$(gate_approval_last_row "$id")
  [ -n "$row" ] || die "그런 승인 id 가 원장에 없습니다: $id"
  cutp=$(gate_row_field "$row" '절단점')
  full=$(gate_approval_sidecar_question "$id" || true)
  [ -n "$full" ] || full=$(gate_row_field "$row" '질문 문면')
  opts='[]'
  if [ "$cutp" = "판단" ]; then
    opts=$(for l in $(gate_menu_labels); do
      jq -n --arg label "$l" --arg description "$(gate_menu_description "$l")" '{label: $label, description: $description}'
    done | jq -s '.')
  fi
  jq -n --arg id "$id" --arg cutpoint "$cutp" --arg state "$(gate_row_field "$row" '상태')" \
        --arg question "$(gate_canon_prompt "$id" "$full")" --arg mv "$GATE_MENU_VERSION" \
        --argjson options "$opts" \
        '{id: $id, cutpoint: $cutpoint, state: $state, question: $question, menu_version: $mv, options: $options}'
}

gate_tuple_snap() {
  # The snapshot component of a judgment binding tuple: the first
  # `GATE_TUPLE_SNAP_LEN` characters of the snapshot digest, which is the
  # progress-vector half — the value that moves on progress and on nothing else.
  local h
  h=$(gate_snapshot_digest)
  printf '%s' "${h:0:$GATE_TUPLE_SNAP_LEN}"
}

gate_approval_last_row() {
  # gate_approval_last_row <승인 id> — the last `승인` row for this id, or nothing.
  { gate_rows '승인' | grep -F "승인 id=$1 " || true; } | tail -1
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
  # THE BINDING TUPLE IS `<세그먼트>/<질문 sha256>/<선택지판>/<스냅숏 앞자리>`, AND
  # THAT IS THE DIFFERENCE FROM AN ACT APPROVAL. An act approval's answer is
  # valid now and its window closes with the night, so it carries head and base
  # shas and re-derives freshness against the tree it named. A question's
  # answer is an input to work that has not happened yet — it is durable, and
  # there is no tree to measure — so what its tuple binds is not a tree but the
  # QUESTION a person saw and the MENU they were shown: the digest of the full
  # question text (compared against the sidecar block the anchor names) and the
  # version token of the gate's own label table (compared, at close, by
  # re-deriving the labels from that table against the transcript's menu).
  #
  # THE GATE ISSUES IT AND THE ROUTER CANNOT. The router only ever submits its
  # own recommendation through `act --kind judgment`; whether that becomes a
  # question is decided here.
  local alias="$1" seg="$2" std="$3" why="$4" id q qfull qdig
  # The full text goes to the sidecar and is what the row's digest is OF; the
  # row itself carries the 400-byte excerpt, and the id keeps hashing the excerpt
  # so every id issued before the sidecar existed still derives to itself.
  qfull="${std:-미상} — ${why:-근거 없음}"
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
  # THE SIDECAR BLOCK IS WRITTEN BEFORE THE ROW, so the anchor the row carries
  # names a block that exists. A block whose row never lands is an orphan and
  # harmless; a row whose block never lands is an anchor to nothing, and the
  # digest beside it then proves nothing. The write failing is loud and does not
  # stop the issue: an act refused with nothing pending is the worse failure,
  # and the row still carries the digest a later reader can check the text
  # against once the sidecar is repaired.
  gate_approval_sidecar_write "$id" issue '질문' "$qfull" \
    || warn "승인 사이드카에 질문 전문을 쓰지 못했습니다 — 행은 발행되나 앵커 $(gate_approval_sidecar_anchor "$id") 가 가리키는 블록이 없습니다"
  qdig=$(printf '%s' "$qfull" | shasum -a 256 | cut -d' ' -f1)
  # `유도 절단점=-` AND NOT THE EXPORTED GLOBAL, for the same reason the act
  # digest beside it is `-`: a judgment approval HAS NO ACT. `GATE_ACT_DERIVED`
  # may well be set — the judgment is raised while some act is being adjudicated
  # — and carrying that value here would say the argv of an unrelated act was
  # the argv of this row, which has none. The field is written rather than
  # omitted because `절단점` is on the row, and a reader that finds one of the
  # pair without the other cannot tell "nothing was derived" from "this
  # recording site was forgotten".
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=판단" \
    "유도 절단점=-" \
    "행위 다이제스트=-" "구속 튜플=${seg:--}/$qdig/$GATE_MENU_VERSION/$(gate_tuple_snap)" \
    "막는 세그먼트=${seg:--}" "질문 문면=$q" "답변 문면=-" \
    "사이드카 앵커=$(gate_approval_sidecar_anchor "$id")" \
    "발행 시각=$(now_iso)" "해소 시각=-"
  warn "판단 승인 대기 발행 $id — 이 판단은 사람의 답을 기다립니다 (런은 그 옆으로 계속 갑니다)"
  gate_warn_canon_prompt "$id" "$q"
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

gate_claudemd_digest() {
  # The sha256 the review approved and the sha256 about to be applied have to be
  # computed the same way or the comparison is theatre. One definition, here, and
  # both sides call it: the review stage writes the value onto its `cycle` row,
  # the layer-3 checker receives this one and compares strings.
  #
  # Slot order is `LC_ALL=C sort`, not glob order, because glob order over these
  # names is locale-dependent and a digest that changes with the caller's locale
  # would refuse every apply on a machine with a different one.
  local d="${RUN_DIR:-}/claudemd" f
  [ -d "$d" ] || { printf '(제안본 없음)'; return 0; }
  f=$(ls "$d"/*.proposed.md 2>/dev/null | LC_ALL=C sort)
  [ -n "$f" ] || { printf '(제안본 없음)'; return 0; }
  # shellcheck disable=SC2086
  cat $f | shasum -a 256 | cut -d' ' -f1
}

gate_claudemd_slot_guard() {
  # gate_claudemd_slot_guard <graded-surface> <argv...>
  #
  # LAYER 2, AND IT REFUSES NOTHING. Its whole output is two exported values;
  # the decision belongs to the `리뷰-후-적용` rule, which is layer 3. Written as
  # a guard beside `gate_manifest_write_guard` because it needs the same thing
  # that one needs — the argv as it actually is, before an interpreter hides the
  # operand — and putting a second copy of that scanning inside a `/bin/sh`
  # checker would be the copy that drifts.
  #
  # THE EXPORT IS A DELIVERABLE, NOT A SIDE EFFECT. The rule fires on
  # `GATE_CLAUDEMD_SLOT` being non-empty and cannot fire on anything else: the
  # cutpoint ladder has no `적용` token, so the `GATE_ACT` idiom every other rule
  # opens with would `exit 0` on the first line, forever, while reading as a
  # check that passes. A layer 2 that catches the act and returns without
  # exporting leaves layer 3 asleep and the failure looks exactly like success.
  #
  # WHY THE READ GRADE RETURNS EARLY. A proposal stage has to read the live file
  # to write a proposal against it, and firing the rule on that read would demand
  # a review record for an act that changes nothing. The delegation caveat from
  # the sibling guard is kept verbatim in shape: a command graded `읽기` from
  # argv0 alone can still write through `-exec` or a wrapper, and those two axes
  # are the ones that decide.
  GATE_CLAUDEMD_SLOT=""
  GATE_CLAUDEMD_DIGEST=""
  export GATE_CLAUDEMD_SLOT GATE_CLAUDEMD_DIGEST
  local graded="$1"; shift
  [ "$#" -ge 1 ] || return 0
  case "$graded" in
    읽기)
      case " $* " in
        *" -exec "*|*" -execdir "*|*" -ok "*|*" -okdir "*|*" -delete "*) ;;
        *" -fprintf "*|*" -fprint "*|*" -fprint0 "*|*" -fls "*) ;;
        *)
          case "${1##*/}" in
            command|env|xargs|lockf|nice|nohup|time|timeout|stdbuf) ;;
            *) return 0 ;;
          esac ;;
      esac ;;
  esac

  local a argv0 joined slot=""
  # ARM 1 — the act names its target as an argv element, which is the shape the
  # sanctioned apply has (`cp <제안본> <슬롯>`). This is the only arm that yields
  # a slot path, and the slot path is what the ledger row and the morning report
  # are able to say something about.
  for a in "$@"; do
    case "${a##*/}" in
      CLAUDE.md|CLAUDE.local.md) slot="$a" ;;
    esac
  done

  if [ -n "$slot" ]; then
    GATE_CLAUDEMD_SLOT=$(gate_physical_path "$slot")
    [ -n "$GATE_CLAUDEMD_SLOT" ] || GATE_CLAUDEMD_SLOT="$slot"
    GATE_CLAUDEMD_DIGEST=$(gate_claudemd_digest)
    return 0
  fi

  # ARM 2 — AN INTERPRETER HID THE OPERAND. `bash -c 'cat p > ~/.claude-cc/CLAUDE.md'`
  # has no element whose basename is the file, so arm 1 sees nothing while the
  # redirection writes it. Here the whole command line is the operand, exactly as
  # the manifest guard reasons about the same evasion.
  #
  # THE SLOT IS DELIBERATELY NOT PARSED OUT OF IT. Recovering a path from a
  # program text needs a shell parser, and a wrong answer here is worse than no
  # answer: it would name a slot the act does not touch, and the row, the report
  # and the rollback would all point at the wrong file. So the value is the
  # marker below, and layer 3 refuses on it — an application has to name its
  # target as an element, which the sanctioned form already does.
  argv0=${1##*/}
  case "$argv0" in
    bash|sh|zsh|dash|ksh|python|python3|perl|ruby|node|npx|make|env|xargs|find|lockf|command|nice|nohup|time|timeout|stdbuf)
      joined=$(printf '%s ' "$@")
      case "$joined" in
        *CLAUDE.md*|*CLAUDE.local.md*)
          GATE_CLAUDEMD_SLOT='(세탁됨)'
          GATE_CLAUDEMD_DIGEST=$(gate_claudemd_digest) ;;
      esac ;;
  esac
  return 0
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
        *" -fprintf "*|*" -fprint "*|*" -fprint0 "*|*" -fls "*) ;;
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

gate_notify_segment_park() {
  # gate_notify_segment_park <segment>
  #
  # THE ONLY CHANNEL FOR A STOP NO TERMINAL CLASS CARRIES. The router can read a
  # snapshot and stand a segment down on its own judgment, with no stage-result
  # row in front of it — the stage-side notice cannot see that park and this one
  # can. Nothing in the gate holds segment rows to the router, though, so a stage
  # call reaches this site too; it raises nothing, and below it also leaves
  # nothing.
  #
  # THE OVERLAP IS EXACTLY ONE CASE and the marker settles it: a stage ends as a
  # deliberate park, the stage-side notice fires and leaves a marker named by the
  # segment, and the router then records that same segment as parked. Those are
  # one stop, so this side stays quiet when it finds the marker.
  #
  # THE MARKER IS SHORT-LIVED BY DESIGN and its expiry lives in the segment-row
  # writer, not here: keyed by the segment alone, a marker that outlived the park
  # would make a segment that was unblocked, re-dispatched and parked again read
  # as the same stop, and its second wait for a person would never be announced.
  #
  # THIS SIDE DERIVES NO ATTEMPT NUMBER. A segment row carries no such field —
  # the contract puts it on the stage-result row — and the only existing idiom
  # for deriving one counts ledger rows, which is time-sensitive. Two independent
  # derivations that disagree would give one stop two group keys and spend two of
  # the eight stacking slots on it. With no marker there is no attempt to be had,
  # so the item key carries the segment alone.
  local seg="$1" mk
  if [ -z "${RUN_DIR:-}" ]; then return 0; fi
  mk="$RUN_DIR/notify/park-$seg"
  if [ -f "$mk" ]; then return 0; fi
  if gate_may_raise_banner; then
    # THE MARKER IS WRITTEN ONLY BY A CALL THAT ACTUALLY RAISED THE NOTICE, and
    # being inside the guard is the whole of it. Written above the guard, one
    # stage call — which raises nothing — leaves the marker behind, and the
    # router's own park for that segment then reads it as "one stop, already
    # announced" and stays quiet forever. Nothing carries this class afterwards,
    # so the banner is not delayed by a pass; it is gone.
    mkdir -p "$RUN_DIR/notify" 2>/dev/null || true
    : > "$mk" 2>/dev/null || true
    cc_notify_fire hands \
      "세그먼트 \`$seg\` 가 park 되었습니다 — 아침 보고서의 보류 큐를 보세요" "park-$seg" || true
  fi
  return 0
}

gate_notify_approval() {
  # gate_notify_approval <approval-id> <question>
  #
  # THE CALLER BOUNDARY EARNS ITS KEEP HERE AND ESSENTIALLY NOWHERE ELSE. The
  # stage-result and segment sites are router calls by construction, but an act
  # approval is issued exactly when a STAGE reaches past its pre-authorization,
  # and the boundary approvals are evaluated on every act — so both open under
  # stage calls routinely. A stage-opened approval leaves its row and the watcher
  # carries it one pass later; only a router-opened one appears at once.
  #
  # THE DEDUPLICATION FILE IS THE WATCHER'S, BY NAME, and renaming it is the one
  # move that must not be made here: a plugin update landing mid-run leaves the
  # already-running watcher reading the old name while a fresh gate process
  # writes the new one, and every approval notice then arrives twice. The price
  # of keeping it is that the prefix now lies slightly about who writes the file,
  # which is cheaper than the rename.
  #
  # The id is written to that file ONLY when this seat actually raised the
  # notice. Writing it on a stage call would silence the watcher for an approval
  # nobody had been told about — which is the one route a stage-opened approval
  # has.
  #
  # ONE RACE IS ACCEPTED AND WRITTEN DOWN: a watcher pass overlapping a gate call
  # can leave both blind to the marker and both raising the same notice. The cost
  # is one duplicate banner; the fix would put a lock on the critical path of
  # every act. Recorded here because otherwise a later reader deletes one of the
  # two firing points and restores the delay this whole seat removed.
  local id="$1" q="$2"
  # A SHIFT DOES NOT DECIDE WHETHER A BANNER REACHES THE USER. It was launched
  # by the lead, and a launched process choosing what the user sees is the one
  # thing the notification rules forbid outright. That test used to sit here as a
  # second early return of its own, which is what left the other six firing sites
  # answering the seat question with a predicate that cannot see a shift; it now
  # lives in `gate_may_raise_banner` and this site reads it like every other one.
  #
  # NO BANNER IS LOST BY THIS. The watcher's approval arm fires from its own
  # seat the moment an approval is issued, and the watcher is orphaned to init
  # rather than launched by anyone — so this suppression tidies the seating
  # rather than removing the notice.
  if ! gate_may_raise_banner; then return 0; fi
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
    if ! grep -qxF "$id" "$RUN_DIR/watch.announced-approvals" 2>/dev/null; then
      printf '%s\n' "$id" >> "$RUN_DIR/watch.announced-approvals" 2>/dev/null || true
    fi
  fi
  cc_notify_fire answer "$q" "$id" || true
  return 0
}

gate_notify_overflow_settled() {
  # THE WAITING-SLOT BANNER HAS TO COME DOWN TOO, and nothing was taking it down.
  #
  # An individual approval's notice is addressed by its own id, so closing that
  # approval clears it. The ninth and later arrivals never got an individual
  # address — they were demoted into the one shared waiting slot — so the
  # id-addressed clear at a close site aims at a group that never carried a
  # banner. The result was the exact inversion of what the address was added for:
  # the eight individual notices vanished as they were answered while "there is
  # more to answer — N" stayed on screen alone, telling a person that a run with
  # nothing left to answer still had N waiting.
  #
  # THE CONDITION IS "NOTHING IS WAITING", NOT "THE STACK IS EMPTY". An empty
  # stack means every notice that held an individual seat has been answered, and
  # says nothing about the demoted ones — which may still be open. Clearing on
  # that signal would take down a banner that is telling the truth.
  #
  # AND "NOTHING IS WAITING" IS NOT "NO APPROVAL IS OPEN". That was the first
  # form of this check and it had the same hole one population over: the waiting
  # slot does not hold approvals alone. The stacking branch admits `answer` AND
  # `hands` against one cap and demotes either the same way, so a stop summons
  # can be the thing the slot stands for — and a stop is not an approval row.
  # With approvals as the whole population, the last approval closing took down
  # a banner whose subject was still waiting for a person, and the stop firing
  # points all sit behind once-markers, so it never came back. The slot's own
  # occupants are the population, so this walks them.
  #
  # THE OVERFLOW LIST IS NOT RECLAIMED HERE. Whether a demoted item is ever
  # promoted back into an individual seat is a separate accepted trade-off; this
  # takes a false count off the screen and nothing else.
  #
  # No caller guard on this line: the clear verb carries the seat guard inside
  # itself, which is the whole reason it was put there rather than at call sites.
  local o key
  [ "$(cc_notify_overflow_count)" != "0" ] || return 0
  o="${RUN_DIR:-}/notify.overflow"
  [ -f "$o" ] || return 0
  # Redirected from the file rather than piped, so an early return leaves the
  # function rather than a subshell.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if gate_notify_slot_key_alive "$key"; then return 0; fi
  done < "$o"
  cc_notify_clear overflow || true
  return 0
}

gate_notify_slot_key_alive() {
  # gate_notify_slot_key_alive <item-key> — 0 when the thing this key stands for
  # may still be waiting for a person, 1 when it is settled.
  #
  # UNKNOWN MEANS ALIVE. Of the two ways to be wrong, holding a banner that is no
  # longer needed shows a person something stale that one glance corrects, while
  # taking down a banner that is still true removes the only trace the demoted
  # item ever had — nobody can miss a notice that never arrived. So every arm
  # that cannot prove settlement answers "alive".
  local key="$1" seg st row
  case "$key" in
    park-*)
      # `park-<seg>` and `park-<seg>#<attempt>` both resolve to ONE marker file
      # named by the segment alone, which is why the attempt is the marker's
      # contents rather than part of its name. The router expires that marker the
      # moment the segment lands in any state other than park, and that writer is
      # the only one that sees the departure happen — so its absence is the
      # settlement signal and no second bookkeeping is needed.
      seg="${key#park-}"
      seg="${seg%%#*}"
      [ -f "${RUN_DIR:-}/notify/park-$seg" ] && return 0
      return 1 ;;
    stop-*|run-*)
      # NEITHER OF THESE HAS AN EXPIRY PATH. A stop with no artifact writes no
      # marker, and a run-scope anchor's key is a reason slug with nothing that
      # retires it. With no signal that says "settled", the honest answer is the
      # conservative one, and the cost is a waiting-slot banner that outlives its
      # subject rather than one that predeceases it.
      return 0 ;;
  esac
  # Everything else is an approval id — the same last-row-per-id fold the pending
  # census uses, applied to one id.
  row=$( { gate_rows '승인' | grep -F "승인 id=$key " || true; } | tail -1)
  [ -n "$row" ] || return 0
  st=$(gate_row_field "$row" '상태')
  [ "$st" = "대기" ] && return 0
  return 1
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
     && [ "$kind" != "obligation" ] && [ "$kind" != "handoff" ] \
     && { [ -z "$seg" ] || [ "$seg" = "-" ]; }; then
    warn "$kind 행에는 --segment 가 필요합니다"
    return "$GATE_EXIT_VOCAB"
  fi
  [ $# -ge 1 ] || { warn "$kind 행에 필드가 하나도 없습니다"; return "$GATE_EXIT_VOCAB"; }

  # THE KEY IS CHECKED HERE AND NOT ONLY NORMALIZED IN `gate_append`. The two are
  # not redundant. Normalization rewrites the field silently; this path is the one
  # whose refusal reaches the caller, and a caller that spelled a separator into a
  # field name should be told rather than have the name quietly changed under it.
  # A key carrying a newline is an attempt to append a SECOND row — the row worth
  # forging is a `승인` saying `상태=승인` — and a key carrying a pipe forges a
  # field boundary inside the row it is on. The remaining half of the invariant,
  # that a key holds no `=`, is discharged by the split itself: `%%=*` cuts at the
  # first one, so there is nothing left for a branch here to find.
  #
  # THE NEWLINE IS A LITERAL, because `$(printf '\n')` is the EMPTY STRING —
  # command substitution strips exactly the character this pattern has to hold,
  # and an empty pattern matches every key there is.
  local nl='
'
  for f in "$@"; do
    case "$f" in
      *=*) k="${f%%=*}" ;;
      *) warn "$kind 행의 필드는 「키=값」이어야 합니다: $f"; return "$GATE_EXIT_VOCAB" ;;
    esac
    case "$k" in
      *"$nl"*|*'|'*)
        warn "$kind 행의 필드 키에 개행이나 파이프를 담을 수 없습니다: $k"
        return "$GATE_EXIT_VOCAB" ;;
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

      # `리뷰 정책` — OPTIONAL on this row, and its absence in a LATER row is
      # INHERITANCE and not a reset. The router's row template carries the
      # required fields and not the optional ones, so an ordinary state
      # transition would otherwise erase a value an earlier row carried; every
      # later resolution would then fall to the strict default and nothing on any
      # surface would say why the merge was refused.
      #
      # CARRIED FORWARD AT WRITE TIME rather than folded at read time. A
      # read-time fallback would be a SECOND reader of this series holding a
      # different meaning from the first, and the one that drifts is the one
      # nobody is looking at. Writing it forward also means every row states the
      # policy in force at that moment, so the last row alone answers the
      # question.
      #
      # THE CARRY IS ON THIS FIELD ONLY, and deliberately not on `워크트리`. That
      # one is REQUIRED on every row above, so it cannot be erased in the first
      # place — and putting a required field into an inheritance loop creates a
      # branch that never runs, whose mere existence teaches the next reader that
      # the field is optional. That drifts the writer in the loosening direction,
      # which is worse than the defect the carry exists to fix.
      local rpol rceil rpi rci
      rpol=$(gate_field_of '리뷰 정책' "$@")
      if [ -z "$rpol" ] && [ -n "$prior" ]; then
        rpol=$(gate_row_field "$prior" '리뷰 정책')
        [ -n "$rpol" ] && set -- "$@" "리뷰 정책=$rpol"
      fi
      if [ -n "$rpol" ]; then
        # THE CEILING IS COMPARED BEFORE THE APPEND. The ledger is append-only,
        # so a value admitted here can never be taken back — the whole content of
        # this ordering is that the check precedes the only write on this arm.
        # And exceeding the ceiling is REFUSED, not clamped: a quietly tightened
        # row is indistinguishable from a conservative one.
        rpi=$(review_policy_index "$rpol") || {
          warn "segment 행의 「리뷰 정책」이 어휘 밖입니다: '$rpol' — 허용 토큰: ${REVIEW_POLICIES}"
          return "$GATE_EXIT_VOCAB"
        }
        rceil=$(target_field "$alias" '리뷰 정책 상한')
        [ -n "$rceil" ] || rceil='선리뷰후머지'
        rci=$(review_policy_index "$rceil") || {
          warn "대상 '$alias' 의 「리뷰 정책 상한」이 어휘 밖입니다: '$rceil'"
          return "$GATE_EXIT_VOCAB"
        }
        if [ "$rpi" -gt "$rci" ]; then
          warn "segment 행의 「리뷰 정책」 '$rpol' 이 대상 '$alias' 의 상한 '$rceil' 을 넘습니다 — 상한 위반은 조여 넣지 않고 거절합니다"
          return "$GATE_EXIT_VOCAB"
        fi
      fi

      # THE CALLER'S OWN `id=` CAN STILL WIN HERE, and this order is left alone
      # deliberately. `cycle` and `problem` below carry the same shape for
      # `세그먼트=`, so all three share this note.
      #
      # REORDERING MOVES THE HOLE RATHER THAN CLOSING IT, and that is why the
      # obvious repair is not the one to reach for. Readers do not agree on
      # which duplicate wins: this file's three take the LAST value, and
      # `feed.sh` takes the FIRST. Putting the gate's field last would close the
      # override for the readers here and open it for that one. The repair that
      # closes it for every reader is to REFUSE a caller-supplied `id=` or
      # `세그먼트=` in `gate_record_row` — the same file already refuses a
      # spliced key there, so the shape exists.
      #
      # THE GRAMMAR IS ALSO PINNED, which is the second reason to leave the
      # order alone. Fixtures assert this row in two shapes — `교대=<n> | id=<seg>`
      # and `id=<seg> | <first caller field>` — so that the grammar is asserted
      # rather than assumed. One of those pins carries a note saying so; the
      # others are footing that rests on it. Counting them here would go stale
      # the moment one is added, so the shapes are named and the count is not.
      gate_append 'segment' "id=$seg" "$@"
      if [ "$st" = "park" ]; then
        gate_notify_segment_park "$seg"
      elif [ -n "${RUN_DIR:-}" ]; then
        # THE PARK MARKER EXPIRES HERE, and this is the only writer that sees it
        # happen. The marker is keyed by the segment id alone, so without an
        # expiry a segment that leaves park and is parked again is read as the
        # same stop and its second wait for a person is swallowed. Any state
        # other than park is that departure.
        rm -f "$RUN_DIR/notify/park-$seg" 2>/dev/null || true
      fi
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
      # "NOT EMPTY" IS NOT A SHAPE. The merge rule interpolates this field as a
      # revision expression, so `HEAD`, `@`, a branch name or `HEAD@{0}` all
      # resolve — against the tree the rule is reading at that moment, which is
      # the merged one. A review recorded that way passes the freshness ladder by
      # construction, no matter which tree was actually reviewed.
      #
      # CONSTRAINED AT WRITE TIME AND NOT AT READ TIME. Putting the check in the
      # rule would make a second copy of this vocabulary in a file that already
      # records the two drifting apart, and it would leave rows already on the
      # append-only ledger asserting a review that never happened. Here the value
      # the writer supplies is pinned before anything can read it.
      local rh rh_bad
      rh=$(gate_field_of '리뷰 HEAD' "$@")
      # `case` globbing and `${#rh}` rather than a regex engine, which is the
      # idiom the rest of this file uses and calls no second process.
      case "$rh" in
        *[!0-9a-f]*) rh_bad=1 ;;
        *) rh_bad=0 ;;
      esac
      if [ "$rh_bad" = 1 ] || [ "${#rh}" -lt 7 ] || [ "${#rh}" -gt 40 ]; then
        warn "cycle 행의 「리뷰 HEAD」는 해소된 커밋 sha 여야 합니다 — 7~40자 소문자 16진만 받습니다: '$rh'"
        return "$GATE_EXIT_VOCAB"
      fi
      # SAME DEFERRED DECISION AS THE `segment` ARM ABOVE, for `세그먼트` rather
      # than `id`.
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
      # SAME DEFERRED DECISION AS THE `segment` ARM ABOVE, for `세그먼트` rather
      # than `id`.
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
      # NO BANNER HERE, and this is the most dangerous of the sites that write a
      # run-scope block. It is the RESOLUTION path — a person has just cleared
      # the block — so instrumenting "a run-scope block row was added", which is
      # the obvious pattern, raises "the run has anchored" at the exact moment
      # somebody unblocked it.
      gate_append 'blocked' "대상=-" "스코프=run" "$@"
      log "런 스코프 막힘 해소 — $why"
      ;;
    handoff)
      # THE ROW THAT CARRIES WHAT THE SNAPSHOT CANNOT. A shift ends and its
      # successor starts from the snapshot alone, and the snapshot is a record
      # of PROGRESS — it says what landed, never what was tried and dropped. So
      # the successor re-walks the predecessor's dead ends, and the morning
      # report's request for the rejected alternative is answerable only if a
      # router happened to write it into free-text rationale, where no reader
      # looks.
      #
      # A shift is an event of the WHOLE RUN, so `--segment` is not required —
      # the same exemption `blocked`, `clause` and `judgment` already hold, and
      # for the same reason: demanding a part makes the kind that describes the
      # whole unwritable.
      local hn hwhy hd hb hc hlen hw=300
      hn=$(gate_field_of '교대' "$@")
      hwhy=$(gate_field_of '사유' "$@")
      case "$hwhy" in
        상한|승인|종단|중단) : ;;
        *) warn "handoff 행의 「사유」가 어휘 밖입니다: ${hwhy:-없음} — 상한 승인 종단 중단"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      case "$hn" in
        ''|*[!0-9]*)
           warn "handoff 행에는 「교대=<정수>」가 필요합니다 — 아침 보고서의 「적용 이후 교대 수」가 이 눈금 위에 섭니다"
           return "$GATE_EXIT_VOCAB" ;;
      esac
      # THREE FREE-TEXT FIELDS AT 300 CHARACTERS, THEN NARROWED AGAIN IF THE ROW
      # STILL DOES NOT FIT. Three Korean fields at their full width are past the
      # 1024-byte row cap on their own, and `gate_append` answers that with a
      # `die` — which would turn the row that reports a handoff into the thing
      # that kills the run performing it. The declared width is the ceiling; the
      # cap is the constraint; this loop is where the two are reconciled instead
      # of colliding at 3am.
      while [ "$hw" -ge 40 ]; do
        hd=$(gate_row_safe "$(gate_field_of '버린 선택지' "$@")" "$hw")
        hb=$(gate_row_safe "$(gate_field_of '막힌 지점' "$@")" "$hw")
        hc=$(gate_row_safe "$(gate_field_of '다음 후보' "$@")" "$hw")
        hlen=$(printf -- '- `handoff` | 교대=%s | 사유=%s | 버린 선택지=%s | 막힌 지점=%s | 다음 후보=%s | 대상=%s | 기록 시각=%s | prev=%064d\n' \
                 "$hn" "$hwhy" "$hd" "$hb" "$hc" "$alias" "$(now_iso)" 0 \
               | wc -c | tr -d ' ')
        [ "$hlen" -le "$GATE_ROW_MAX" ] && break
        hw=$((hw - 40))
      done
      gate_append 'handoff' "교대=$hn" "사유=$hwhy" \
        "버린 선택지=$hd" "막힌 지점=$hb" "다음 후보=$hc" \
        "대상=$alias" "기록 시각=$(now_iso)"
      log "교대 $hn 기록 — 사유 $hwhy"
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
      local oid oprior ost oalias oseg omerge olanding ocover overdict orhead
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
      oalias=$(gate_row_field "$oprior" '대상')
      oseg=$(gate_row_field "$oprior" '세그먼트')
      omerge=$(gate_row_field "$oprior" '머지 커밋')

      # `--target` IS COMPARED AND NOT MERELY RECORDED. The landing test below
      # runs in the anchor repository of the target the merge was authorized
      # against, so a fulfillment aimed at a different target measures the right
      # commit in the wrong repository and reports 미착지 with full confidence.
      # The code is the vocabulary one because every other refusal in this arm is,
      # and because the repair really is to fix the argv — which is exactly what 2
      # tells the router to do.
      if [ -n "$oalias" ] && [ "$oalias" != "-" ] && [ "$alias" != "$oalias" ]; then
        warn "이행하려는 의무 ${oid} 의 대상은 '$oalias' 인데 --target 은 '$alias' 입니다"
        warn "그 행이 지목하는 대상으로 다시 부르세요 — 착지 판정이 도는 저장소가 대상마다 다릅니다"
        return "$GATE_EXIT_VOCAB"
      fi

      # LANDING FIRST, CONTAINMENT SECOND. Reversed, a merge that never landed is
      # judged on whether some review covered it, and the retry path for that
      # merge breaks along with the judgment.
      #
      # A row carrying `머지 커밋=-` predates the anchor and cannot be measured at
      # all, so it passes with `이행 판정=앵커 없음` rather than being refused —
      # refusing it would strand obligations written before this field existed.
      # THIS ARM DISAPPEARS when `리뷰 의무` rows with `머지 커밋=-` reach zero at
      # the ledger root, and nothing else expires it.
      if [ -z "$omerge" ] || [ "$omerge" = "-" ]; then
        overdict='앵커 없음'
      else
        # CALLED PLAINLY, never through `$(…)`: the sentence rides on a global and
        # a command substitution runs the predicate in a subshell, which discards
        # it. The verdict rides on a global for the same reason.
        gate_obligation_landing "${oalias:-$alias}" "$omerge"
        olanding="$GATE_LANDING_VERDICT"
        case "$olanding" in
          미착지) overdict='미착지' ;;
          착지)
            orhead=$(gate_segment_review_head "$oseg")
            gate_obligation_covers "${oalias:-$alias}" "$omerge" "$orhead"
            ocover="$GATE_COVER_VERDICT"
            case "$ocover" in
              '덮는다') overdict='착지·포함' ;;
              '덮지 않는다')
                warn "의무 ${oid} 의 머지 커밋 ${omerge} 을 덮는 리뷰가 없습니다: ${GATE_COVER_WHY}"
                warn "그 커밋을 덮는 cycle 행을 먼저 기록하고 같은 argv 로 다시 부르세요"
                return "$GATE_EXIT_VOCAB" ;;
              *)
                warn "의무 ${oid} 의 포함 여부를 판정하지 못했습니다: ${GATE_COVER_WHY}"
                return "$GATE_EXIT_VOCAB" ;;
            esac ;;
          *)
            # 판정 불가 IS A REFUSAL AND NEVER A VALUE — there is no row to carry
            # it on, because the row exists only when the obligation is fulfilled.
            # The exit code is shared with the other refusals here and the SENTENCE
            # carries the distinction: which of fetch, ref or ancestry failed to
            # answer. No automatic retry sits here either — how many attempts at
            # what interval is not a number anybody has measured.
            warn "의무 ${oid} 의 착지를 판정하지 못했습니다: ${GATE_LANDING_WHY}"
            warn "자동 재시도는 두지 않습니다 — 판정이 가능해진 뒤 같은 argv 로 다시 부르세요"
            return "$GATE_EXIT_VOCAB" ;;
        esac
      fi

      # The carried fields come from the row being closed and never from argv.
      # `세그먼트` is what ties the fulfillment to the merge it belongs to,
      # `생성 등급` is the value the excusal rule reads later, and `대상` names the
      # repository the landing test just ran in — a router that could restate any
      # of them could also restate it wrongly. They sit AFTER `"$@"` so the
      # router's argv is overwritten rather than merely accompanied.
      #
      # `이행 판정` IS WRITTEN ON EVERY BRANCH. Written conditionally it becomes a
      # key outside the carried set, the router's argv survives in that position,
      # and the field built to COUNT exemptions turns into the handle that inflates
      # them. Its value set is closed at three; there is no fourth and no
      # `판정 불가`, because that outcome refused above and left no row.
      gate_append '리뷰 의무' "$@" "상태=이행" \
        "세그먼트=$oseg" \
        "대상=${oalias:-$alias}" \
        "머지 커밋=$omerge" \
        "생성 등급=$(gate_row_field "$oprior" '생성 등급')" \
        "이행 판정=$overdict" \
        "발행 시각=$(gate_row_field "$oprior" '발행 시각')" \
        "이행 시각=$(now_iso)"
      # THE LANDING SENTENCE IS LOGGED EVEN WHEN NOTHING WAS REFUSED. `미착지` is
      # a passing disposition, so without this line the only witness to WHY it
      # did not land is a variable nobody reads — and the two 미착지 sentences
      # differ in the one way an operator acts on: one says the base does not
      # contain it yet, the other that no retry will ever make it.
      log "리뷰 의무 이행 $oid — 대상 ${oalias:-$alias} · 이행 판정 $overdict${GATE_LANDING_WHY:+ · $GATE_LANDING_WHY}"
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
    # NO BANNER HERE EITHER. Every condition transcribed on this path was already
    # announced by the watcher two lines before it wrote the observation, so a
    # notice here is the same event reaching the user a second time — under a
    # different title and a different group, and spending one of the eight
    # stacking slots that an approval actually waiting for an answer needs.
    #
    # `원인=불명` is written HERE AND NOWHERE ELSE, which is what lets the
    # watcher's anchored arm exclude "conditions the watcher authored" by
    # structure instead of by a list of reason strings that goes stale silently.
    gate_append 'blocked' "대상=-" "스코프=run" "원인=불명" "사유=$why" \
      "관측=$ts" "재개 명령=$cmd"
  done < "$f"
  : > "$f"
}

gate_drain_notify_state() {
  # The emitter's own active state, moved from the run directory into the report
  # as one line of prose.
  #
  # WHY THE INDIRECTION. Days later a reader cannot tell "nothing happened" from
  # "the banners were switched off" — the kickoff says the resolved state out
  # loud and that utterance goes with the session. Both seats therefore record
  # it, and neither appends to the report itself: the watcher takes no lock and
  # this process does, so two unlocked appends to one file interleave and what
  # breaks is the ledger ROW beside the prose, not the prose. This is the
  # ledger's writer, so this is where the line becomes durable.
  #
  # The hash chain is untouched by construction: it hashes only lines carrying
  # the row prefix, and the kickoff's own stub already puts prose in this file.
  #
  # THE MARKER IS SEPARATE FROM THE OBSERVATION. Using the state file as its own
  # once-guard is the mistake the stall arm already made — the gate empties that
  # file on every act, the guard came back to life, and the arm re-fired every
  # pass.
  local f m
  if [ -z "${RUN_DIR:-}" ]; then return 0; fi
  f="$RUN_DIR/notify.state"; m="$RUN_DIR/notify.reported"
  if [ ! -s "$f" ]; then return 0; fi
  if [ -f "$m" ]; then return 0; fi
  printf '%s · 배너 좌석: %s\n' "$(now_iso)" \
    "$( { cat "$f" 2>/dev/null || true; } | sed -n '1p')" >> "$LEDGER" 2>/dev/null || true
  : > "$m" 2>/dev/null || true
  return 0
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

gate_plan_unchecked_axes() {
  # gate_plan_unchecked_axes <kind> — the axes this dry run did NOT evaluate,
  # named on stderr.
  #
  # A forecast that reports only its verdict reads as a complete answer, and the
  # router acts on it as one. Two axes stay structurally out of reach here, and
  # each of them returns a code the router has no other way to anticipate — so
  # what this turns a passing `plan` into is "these held, and these two were not
  # looked at" rather than a green light.
  #
  # THE ENFORCEMENT SURFACE IS DELIBERATELY ABSENT FROM THIS LIST. It used to be
  # unreachable for this verb and is now compared like any other read; listing it
  # here would keep telling the router to expect a blind spot that was closed.
  local kind="$1"
  warn "plan(dry-run) 미검사 축 — 아래는 이 예고가 평가하지 않은 축입니다:"
  # Not compared, because a dry run is not bound to the state it read: the guard
  # on the way in skips it for this verb outright. So the same argv issued as
  # `act` can still come back 4 when a sibling segment landed a row in between.
  warn "  - 스냅숏 다이제스트 — act 는 --snapshot-digest 를 현재 값과 대조하며 어긋나면 4 입니다"
  case "$kind" in
    segment|cycle|problem|blocked|clause|judgment|obligation)
      # The `키=값` list after `--` is validated by the row writer, and the row
      # writer runs only on the performing path. Four known divergences live
      # behind this one line — a predecessor-monotonicity violation, a
      # predecessor segment absent from the ledger, a `cycle` row missing a
      # required field, and a missing cone anchor row — so naming the axis is
      # what lets the router expect them instead of meeting them.
      warn "  - 기록 행 필드 유효성(${kind}) — -- 뒤 키=값 필드는 기록 시점에 검사되므로 같은 argv 의 act 가 2 나 6 으로 돌아올 수 있습니다" ;;
  esac
}

gate_kind_is_bookkeeping() {
  # gate_kind_is_bookkeeping <kind> — the row kinds an `act` performs by
  # APPENDING A ROW and doing nothing else. Every one of them grades `읽기`.
  #
  # THE SET IS SPELLED ONCE. Two readers need it — the dispatch that performs
  # them and the all-met arm that must not refuse them — and when the arm carried
  # no copy at all, the terminal shift could not write the one row the protocol
  # requires it to write.
  case "$1" in
    segment|cycle|problem|blocked|clause|judgment|obligation|handoff) return 0 ;;
  esac
  return 1
}

gate_verb_act() {
  local verb="$1" kind="$2" alias="$3" segment="$4" cutpoint="$5" surface="$6"
  local snapdig="$7" rationale="$8" worktree="$9"
  shift 9
  local argv="$*"

  [ -n "$alias" ]    || { printf 'gate: --target 이 필요합니다\n' >&2; exit 2; }
  [ -n "$cutpoint" ] || { printf 'gate: --cutpoint 이 필요합니다\n' >&2; exit 2; }
  # `propose-done` is the one kind with no act behind it — it asks whether the
  # run may stop, and demanding an argv would force the router to invent a
  # command whose only purpose is to satisfy a parser.
  if [ "$kind" != "propose-done" ]; then
    [ $# -ge 1 ] || { printf 'gate: -- 뒤에 argv 가 필요합니다\n' >&2; exit 2; }
  fi
  # `exec` DOES NOT TAKE `--kind`, AND THE USAGE HEADER ALREADY SAID SO. A kind
  # names a row the gate PERFORMS, which is an `act`/`plan` notion; `exec`
  # declares its surface with `--surface` and runs the argv itself. But the
  # option parser is verb-agnostic, so `exec --kind skill` arrived here carrying
  # a kind, and two arms below read `kind` without asking which verb they are
  # under: the grading arm pins `워크트리쓰기` instead of consulting the argv0
  # table, and the manifest write guard is skipped outright.
  #
  # Both arms rest on ONE premise — a dispatch argv is a prompt a launcher
  # consumes, not a command line this process runs — and only `act` reaches a
  # launcher. `exec` hands the argv to the read-scoped runner, which runs `"$@"`
  # verbatim, so under that verb the premise is false and the two arms gave a
  # real write both a false grade and an exemption from the guard. The
  # self-declaration check could not catch it either: it compares the declared
  # surface against the value the grading arm just pinned, so `--surface
  # 워크트리쓰기` agreed with itself by construction and exit 6 was unreachable.
  #
  # REFUSING THE FLAG IS WHAT CLOSES BOTH ARMS AT ONCE. Narrowing each arm to
  # `verb = act` closes them one at a time and leaves the next kind-reading arm
  # to remember the verb on its own; making `kind` unreachable under `exec`
  # makes every such arm `act`-only by construction, without either arm naming
  # the verb.
  if [ "$verb" = "exec" ] && [ -n "$kind" ]; then
    printf 'gate: exec 은 --kind 를 받지 않습니다 — exec 의 표면은 --surface 로 선언하고, kind 가 붙는 행위는 act 입니다\n' >&2
    exit 2
  fi

  # Vocabulary first, and by return status rather than `die` — see surface_index.
  cutpoint_index "$cutpoint" >/dev/null || exit "$GATE_EXIT_VOCAB"

  # ---- the argv ladder, derived and compared against the declaration --------
  #
  # THE SEAM IS HERE AND NOT AT `gate_export_cutpoints`, and the position is the
  # whole of the repair. Five consumers read the declared rung as a threshold —
  # the rule catalog's `GATE_ACT`, the target-ceiling exporter, the wall-clock
  # deadline, the undeclared-target layers and the obligation issuer — and
  # #Nharu/cc-cmds#505 names only the first. Fixing the rule call site alone
  # leaves the other four open to the identical misspelling, so the value is
  # corrected once, above all of them. The exporter cannot be that place: three
  # of the five already sit above it.
  #
  # DERIVE FIRST, AND ONLY WHERE THE argv IS A COMMAND. `propose-done` has no act
  # behind it, a `skill` or `router-shift` argv begins with a stage kind or a
  # handoff reason, and a bookkeeping act's argv is a list of `키=값` fields.
  # Feeding any of those to the table asks a question it cannot answer, so the
  # split is the same one `GATE_HISTORY_INTEGRATION` already makes verbatim a few
  # hundred lines below — and for the same reason, which is that the answer there
  # would be a guess rather than a fact.
  GATE_ACT_DERIVED=""
  case "$kind" in
    propose-done|skill|router-shift) : ;;
    *) gate_kind_is_bookkeeping "$kind" \
         || GATE_ACT_DERIVED=$(ladder_of_argv0 "$@") ;;
  esac
  GATE_ACT_EFFECTIVE="$cutpoint"
  if [ -n "$GATE_ACT_DERIVED" ]; then
    local d_idx r_idx
    d_idx=$(cutpoint_index "$GATE_ACT_DERIVED") || exit "$GATE_EXIT_VOCAB"
    r_idx=$(cutpoint_index "$cutpoint") || exit "$GATE_EXIT_VOCAB"
    if [ "$d_idx" -gt "$r_idx" ]; then
      # UNDER-DECLARATION, AND IT IS REFUSED BEFORE exit 4 ON PURPOSE. Exit 4
      # tells the router "re-read the snapshot and try again", and a retry with
      # the same misspelled argv walks straight back into this same refusal —
      # so the staleness comparison below must not get to answer first.
      # THE RULE IS DESCRIBED AND NOT NAMED, and the omission is deliberate. The
      # catalog refusal spells its own rule's name on stderr — `룰 거부:
      # 절단점-준수` — and that name is the only thing separating the two
      # refusals for a reader scanning the transcript. Spelling it here as part
      # of a PRESCRIPTION would put it on the exit-8 message too, and then the
      # two consumers this axis exists to tell apart become one string again:
      # deleting either check leaves the other answering for it. The router's
      # exit-code table carries the name; this message carries the repair.
      warn "저신고: argv 는 '$GATE_ACT_DERIVED' 등급인데 '$cutpoint' 로 신고됐습니다 — 낮은 신고는 인가를 넓히지 않습니다"
      warn "신고를 '$GATE_ACT_DERIVED' 로 올려 같은 argv 로 다시 부르세요. 다만 올려도 대상의 절단점을 넘으면 인가되지 않은 것이며, 그때의 처방은 다시 올리는 것이 아니라 park 입니다 — 그 거절은 이 exit 8 이 아니라 인가 상한 룰의 exit 3 으로 돌아옵니다"
      exit "$GATE_EXIT_LADDER"
    fi
    if [ "$d_idx" -lt "$r_idx" ]; then
      # OVER-DECLARATION PASSES, AND THE CONSUMERS TAKE THE DERIVED RUNG. The
      # router labels every act with its target's cutpoint, so this is the
      # ordinary path and refusing it would be a wall. What it is not is silent:
      # the ledger carries both values and this line carries the third thing
      # neither field can say, which is that one of them was lowered.
      warn "과신고: argv 는 '$GATE_ACT_DERIVED' 등급인데 '$cutpoint' 로 신고됐습니다 — 이 행위는 유도 등급으로 판정합니다"
      GATE_ACT_EFFECTIVE="$GATE_ACT_DERIVED"
    fi
  fi
  export GATE_ACT_DERIVED GATE_ACT_EFFECTIVE

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
    local now nowvec nowtip obsvec obstip stale=0 twopart=0
    now=$(gate_snapshot_digest)
    nowvec="${now%%-*}"; nowtip="${now##*-}"
    case "$snapdig" in
      *-*) twopart=1; obsvec="${snapdig%%-*}"; obstip="${snapdig##*-}" ;;
      # THE OLD ONE-PART FORM KEEPS ITS OLD MEANING, WHICH IS EXACT EQUALITY. The
      # permission hook's own instructions, this repository's fixtures and other
      # sessions' copies of this file all carry a bare digest, so a format change
      # that refused it would stop runs that are already in flight over a
      # spelling. Left empty here and handled as a whole-string compare below.
      *) obsvec=""; obstip="" ;;
    esac
    if [ "$twopart" = "0" ]; then
      [ "$snapdig" = "$(gate_snapshot_digest_legacy)" ] || stale=1
    else
      # BOTH HALVES ARE CHECKED FOR SHAPE BEFORE EITHER IS COMPARED, and an empty
      # half is a FORMAT error rather than a comparison that happens to succeed.
      # `<벡터해시>-` has the two-part form, so it reached the ancestry probe with
      # an empty tip and the probe degenerated to `grep -qF "prev="` — true of
      # every ledger holding a single row. The one value that still had to be
      # right, the vector half, is printed in full by the refusal message, so
      # there was nothing left to guess.
      #
      # THE ARM IS SELECTED ON THE FORM AND NOT ON AN EMPTY VECTOR HALF. That
      # selector had the mirror defect: `-<팁>` is two-part by the `case` above
      # but carries an empty vector, so it fell through to the one-part formula
      # and was refused for a reason that was not its own.
      case "$obsvec$obstip" in
        *[!0-9a-f]*) stale=1 ;;
      esac
      { [ ${#obsvec} -eq 64 ] && [ ${#obstip} -eq 64 ]; } || stale=1
      # THE VECTOR HALF IS EXACT, and that is where the check earns its keep: the
      # vector moves only on progress, so a mismatch is a router acting on state
      # that genuinely moved — a compacted one carrying a remembered value
      # included. Nothing about this half is relaxed.
      [ "$obsvec" = "$nowvec" ] || stale=1
      # AND THE TIP HALF IS BOUNDED ANCESTRY RATHER THAN EQUALITY. Equal is the
      # ordinary case. Otherwise the tip the caller observed has to appear as the
      # `prev` of one of the last GATE_ANCESTRY_WINDOW rows — a point the chain
      # has grown past while somebody else appended between the read and the act,
      # which is concurrency and not staleness. A tip that is on no row at all,
      # or on a row the chain has left far behind, is neither.
      #
      # WHAT THE BOUND DOES NOT BUY. K measures DISTANCE and not KIND, so a
      # digest presented a few rows after a pending approval was opened still
      # passes. The vector cannot be widened to cover that: the vector's own note
      # explains that a boundary firing always issues an approval, so counting
      # approvals would let the remedy reset the counter that fired it. What the
      # bound removes is the property that a value read hours ago passed forever.
      #
      # ANCHORED TO THE FIELD BOUNDARY AND TO END OF LINE. The boundary alone
      # still matched a carrier that supplies no separator at all, because a
      # fixed-string probe matches anywhere in the row. `prev` is the last field
      # by construction, so the row anchor costs nothing and refuses that third
      # carrier. `$obstip` is 64 lowercase hex by the shape check above, so it
      # carries no regular-expression metacharacter.
      #
      # ANCHORED TO THE FIELD BOUNDARY. A row's real `prev` is its last field and
      # is written as ` | prev=<hex>`, and gate_append maps `|` out of every field
      # a caller supplies, KEY AND VALUE ALIKE, so no field can forge that
      # boundary. The key half of that transform landed later than this anchor,
      # which is why both halves are named: while the maps covered values only,
      # a caller could spell ` | prev` as a field's KEY and put the separator into
      # the very row this probe reads. Unanchored,
      # `근거=prev=<hex>` matched: the authorisation row carries the caller's own
      # rationale verbatim, so ONE act with a valid digest let a caller mint the
      # ancestor token it would present later, while knowing no real value in the
      # ledger. Measured on a live 107-row ledger: the rows carrying `prev=` and
      # the rows carrying ` | prev=` are the same rows, so the anchor loses no
      # legitimate ancestor.
      #
      # NOT A PIPE. `grep -q` exits at its first match, which closes the pipe on
      # an upstream that is still writing — under `pipefail` that SIGPIPE turns a
      # found ancestor into a failed test. The window is bounded rows, so a here
      # string costs nothing and removes the race the lint refuses.
      #
      # THE SHAPE CHECK ABOVE AND THIS ANCHOR CLOSE DIFFERENT DOORS, and neither
      # closes the other's. A prefix of a real tip satisfies a substring match
      # even anchored, so the length check is what refuses it; a minted token is a
      # perfect 64-character lowercase hex, so the anchor is what refuses it.
      if [ "$stale" = "0" ] && [ "$obstip" != "$nowtip" ] \
         && ! grep -qE " \| prev=$obstip\$" <<<"$(gate_ancestry_window)"; then
        stale=1
      fi
    fi
    if [ "$stale" != "0" ]; then
      warn "낡은 스냅숏 다이제스트: 관측 '$snapdig' vs 현재 '$now'"
      exit "$GATE_EXIT_STALE"
    fi
  fi
  case " $(target_aliases | tr '\n' ' ') " in
    *" $alias "*) : ;;
    # THE EFFECTIVE RUNG AND NOT THE DECLARED ONE, here and at the six sites
    # below. This one decides whether an undeclared repository is refused
    # outright or quietly REGISTERED with a `대상 추가` row, so a merge spelled
    # `--cutpoint 커밋` used to walk past the refusal and leave the registration
    # behind it.
    *) gate_undeclared_target "$alias" "$GATE_ACT_EFFECTIVE" "$worktree" || exit $? ;;
  esac

  # The router's declared surface is a CHECKED CLAIM, not a self-grant. A
  # mismatch is exit 6 — the same idiom the slicing declaration's `슬라이스 수`
  # already uses, where a value the writer supplies is compared against one the
  # reader derives instead of being trusted.
  local graded
  case "$kind" in
    propose-done)
      graded="읽기" ;;
    skill|router-shift)
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
      #
      # A ROUTING SHIFT HAS THE SAME SHAPE AND WAS LEFT OUT OF IT. Its first
      # token is the handoff reason — `상한`, `승인` — which is no more a command
      # than a stage kind is, so it graded `등급 미상` and the launcher could not
      # be reached at all: declared `읽기` the act came back 6, declared not at
      # all it came back 2. It starts its successor the way a stage dispatch
      # starts one, under the same read-scoped credential, so it takes the same
      # grade rather than a second answer to one question.
      graded="워크트리쓰기" ;;
    *)
      if gate_kind_is_bookkeeping "$kind"; then
        # A bookkeeping act: its argv is a list of `키=값` fields, not a command,
        # and what it performs is the ledger row the gate would write anyway. It
        # reaches nothing outside the ledger, so it grades `읽기`.
        #
        # THE SET IS ASKED FOR HERE, NOT SPELLED AGAIN. This site carried a
        # private copy of the list and that copy was missing `handoff`, so the
        # one act whose argv begins with `교대=0` graded `등급 미상` and the
        # terminal shift's own row came back 6 — refused by the axis that was
        # never about it.
        graded="읽기"
      else
        graded=$(surface_of_argv0 "$@")
      fi ;;
  esac
  if [ -n "$surface" ]; then
    surface_index "$surface" >/dev/null || exit "$GATE_EXIT_VOCAB"
    if [ "$surface" != "$graded" ]; then
      warn "축2 자기선언 불일치: 선언 '$surface' vs 등급 '$graded'"
      if [ "$graded" = "등급 미상" ]; then gate_orchestrator_script_hint "$1"; fi
      exit "$GATE_EXIT_GRADE"
    fi
  fi
  if [ "$graded" = "등급 미상" ]; then
    # THE GENERIC MESSAGE COMES FIRST SO THE SPECIFIC ONE IS READ LAST. Both
    # lines name a repair and the two repairs are opposites: the generic one
    # says respell the command, the version-skew advisory says do NOT respell it
    # because both respellings available here are losses. Printed the other way
    # round the reader's last instruction was the one that does not apply, and
    # the two spellings it invites are exactly the two the advisory forbids.
    #
    # The generic message names WHICH repair, because two different things
    # arrive here: a tool the table has never listed (widen the table), and a
    # recognized tool in a form the sub-table could not parse (respell the
    # command). Without the distinction the router sees one refusal and has no
    # way to tell which.
    warn "축2 등급 미상 — 등급표에 없는 argv0 는 읽기로 떨어지지 않습니다: $1 (그 도구가 표에 오른 적이 없다면 표를 넓혀야 하고, 표에 있는 도구인데 형태를 못 읽은 것이라면 하위 명령이 보이도록 다시 쓰세요)"
    gate_orchestrator_script_hint "$1"
    [ "$verb" = "plan" ] || exit "$GATE_EXIT_VOCAB"
  fi

  # The watcher's observations, transcribed into properly chained rows. It
  # records them as a file precisely because it is not the ledger's writer; this
  # is the writer, so this is where they become rows.
  gate_drain_stall
  # This seat's own state, then the watcher's — both go through the same file, so
  # whichever wrote it first is the one line the report carries and the two seats
  # cannot leave two lines for one fact.
  cc_notify_seat_state || true
  gate_drain_notify_state

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
    gate_deadline_ok "$kind" "$GATE_ACT_EFFECTIVE" || exit $?
  fi

  if [ "${GATE_UNDECLARED:-0}" != "1" ]; then
    gate_export_cutpoints "$alias" "$GATE_ACT_EFFECTIVE" || exit $?
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

  # THE SECOND argv-DERIVED VALUE, PUBLISHED BESIDE THE FIRST. `리뷰-후-머지`
  # narrows on the graded surface and then splits that surface's worktree-write
  # cell with this; keeping the two exports together is what stops a later
  # editor from moving one and leaving the other behind.
  #
  # THE KIND-PINNED ARMS ANSWER 0, AND THAT 0 IS A FACT RATHER THAN A GUESS.
  # Where the grade came from the kind rather than from the table, the argv is
  # not a command at all — a bookkeeping act's argv is a list of `키=값` fields,
  # a stage dispatch's first token is a stage kind, a routing shift's is a
  # handoff reason. Asking "does this command integrate history" of a field list
  # has no answer, and 0 is the honest one: no history is being integrated.
  GATE_HISTORY_INTEGRATION=0
  case "$kind" in
    propose-done|skill|router-shift) : ;;
    *) gate_kind_is_bookkeeping "$kind" \
         || GATE_HISTORY_INTEGRATION=$(gate_history_integration "$@") ;;
  esac
  export GATE_HISTORY_INTEGRATION

  # A DISPATCH ARGV IS A PROMPT, NOT A COMMAND LINE, so the guard below has
  # nothing to look at there. `skill` and `router-shift` hand their argv to a
  # launcher — the first token is consumed as the stage kind or the handoff
  # reason and the rest goes to the wrapper — and no byte of it is ever run as a
  # command by this process. What the successor then does comes back through
  # this gate as its own act and is guarded there, which is the same reading the
  # grading arm above already gives these two kinds.
  #
  # WITHOUT THIS THE PROTOCOL REFUSED ITS OWN MANDATED FORM. A shift is
  # dispatched as `-p "/cc-cmds:autopilot-router-shift <매니페스트>"` because the
  # successor has to be told which run it is resuming, and the guard's last arm
  # is basename containment over the argv elements — so that one element carries
  # the manifest's name and every routing shift was refused with `매니페스트에
  # 쓰려 합니다`, exit 3. It stayed invisible while a routing shift graded
  # `등급 미상`, because the vocabulary refusal above returns before this line;
  # giving it the `워크트리쓰기` grade is what moved the act into this range.
  #
  # Residual, stated rather than hidden: a dispatch is no longer measured by
  # this guard at all, so a prompt that instructs the successor to write the
  # manifest is not caught here. It is caught where it becomes an act — the
  # successor's own gate call — which is the only place the write actually
  # exists.
  case "$kind" in
    skill|router-shift) : ;;
    *) gate_manifest_write_guard "$graded" "$@" || exit $? ;;
  esac

  # Layer 2 of the CLAUDE.md audit. It refuses nothing; it publishes the two
  # values the `리뷰-후-적용` rule reads. Placed after the manifest guard so an
  # act that is refused outright never reaches a rule at all.
  gate_claudemd_slot_guard "$graded" "$@"

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

  # THE REVIEW POLICY, RESOLVED BEFORE THE CATALOG RUNS. The checkers are
  # separate processes and receive this as ambient state; resolving it after the
  # loop would leave them nothing to read. It is also outside `gate_rule_enabled`
  # on purpose — the ceiling comparison is the part of this axis a manifest may
  # not switch off, and putting it inside a checker would let one setting turn
  # off both the check and the ceiling that bounds it.
  gate_resolve_review_policy "$segment" "$alias" "$kind" "$@" || exit $?

  # WHAT THE ORDER PREDICATE READS. The checker is a separate `/bin/sh` and
  # cannot call the reader above it, and letting it grep the ledger itself would
  # put a THIRD copy of "which obligations are open" beside this file's reader
  # and termination condition 9 — the gate folds it, the checker receives the
  # value. Narrowed to this segment for the reason the reader's own comment
  # gives: run-wide, a sibling's open obligation refuses this segment's merge.
  GATE_SEGMENT_OPEN_OBLIGATIONS=$(gate_unfulfilled_review_obligations "$segment" \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  export GATE_SEGMENT_OPEN_OBLIGATIONS

  local rules_rc=0
  # THE CHECKERS ARE NOT TOUCHED BY THIS AXIS AT ALL, and that is the point of
  # putting the seam upstream: `GATE_ACT` arrives already corrected, so not one
  # line of the catalog changes and no checker acquires a second copy of the
  # ladder.
  gate_run_rules "$GATE_ACT_EFFECTIVE" "$alias" "$segment" "$argv" || rules_rc=$?

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
    gate_issue_act_approval "$alias" "$segment" "$GATE_ACT_EFFECTIVE" "$graded" "$argv"
    exit "$GATE_EXIT_APPROVAL"
  fi
  [ "$rules_rc" = "0" ] || exit "$rules_rc"

  # THE ONE KIND THAT OUTLIVES THE SURFACE MOVE IS THE RUN SAYING IT ENDED.
  #
  # A moved enforcement surface is permanent: the branch below writes a run-scope
  # `blocked` row with `원인=무효화` and refuses every act after it. Termination
  # condition 5 then reads that row as unmet forever, and the whole point of the
  # invalidated arm further down is that such a run must still be able to write
  # `done` — as invalidated, never as satisfied.
  #
  # Without this bypass that arm could not be reached by the state it exists for.
  # The check sits above it, so the only `propose-done` that ever got past here
  # was one on a run whose blocked row had been placed by hand, and a real
  # invalidated run stayed `진행 중` forever — the exact condition the arm was
  # added to end. The render line that tells a person to propose done in this
  # state was, for the same reason, an instruction that could not be followed.
  #
  # The bypass is narrow in both directions. It needs the row to be there
  # ALREADY, so the first act after a surface move still takes the refusal, the
  # row and the banner — the detection is not weakened, only the second visit is
  # let through. And `propose-done` authorizes nothing: with that row present the
  # disposition is `무효화` by construction, so the only thing this can reach is
  # the arm that records the run as invalid.
  if ! { [ "$kind" = "propose-done" ] && gate_has_row 'blocked' '사유=강제 표면 이동'; }; then
    gate_surface_check "$verb" || exit $?
  fi

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
  # NO `act` CONJUNCT. Both checks below are pure reads of rows already written,
  # and excluding the dry run from them was the mechanism rather than a side
  # effect: moving the early return alone leaves this arm still keyed on `act`,
  # so `plan --kind skill` would go on answering "통과 예상" for a segment with no
  # row and for a predecessor that has not landed.
  if [ "$kind" = "skill" ]; then
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

  # The ten conditions are evaluated on EVERY act, not only on a done proposal.
  # A gate that can refuse a proposal but never cause one leaves the router
  # alone deciding when the night ends — so when every condition holds and the
  # router reaches for something else, it has to name what is left.
  local unmet disposition
  unmet=$(gate_done_conditions)
  disposition=$(gate_done_disposition "$unmet")
  if [ "$kind" = "propose-done" ]; then
    # THE DRY RUN ANSWERS AND WRITES NOTHING, and this arm sits ABOVE all three
    # of the arms that write, because two of them do it with an exit status of
    # zero. Without it, asking whether the run may stop ENDED the run: the `done`
    # file was created with an empty rationale, the terminal banner fired on a
    # live run, and the status was 0 in both directions — while the accepting arm
    # writes no ledger row at all. Neither the exit code nor the ledger told the
    # question apart from the act; only the file did.
    if [ "$verb" = "plan" ]; then
      # THE UNCHECKED AXES ARE NAMED HERE TOO, and this is the forecast that
      # needs them most. Every other `plan` announces what it did not look at
      # before returning; this one returned straight from the verdict, so the
      # single question that decides whether the night ends — "may the run
      # stop?" — was the one answered without disclosing its blind spot. The
      # snapshot digest is not compared on any dry run, so a `충족` here can
      # still meet exit 4 as an act when a sibling segment lands a row in
      # between, and nothing said so.
      case "$disposition" in
        충족)
          gate_plan_unchecked_axes "$kind"
          printf '통과 예상: 종료 조건이 전부 성립합니다 — act 로 내면 done 을 기록합니다\n'
          return 0 ;;
        무효화)
          gate_plan_unchecked_axes "$kind"
          printf '통과 예상: 무효화 종료 — act 로 내면 충족이 아니라 무효로 기록합니다\n'
          return 0 ;;
        *)
          warn "plan(dry-run): 종료 제안은 기각됩니다 — $(gate_unmet_summary "$unmet")"
          printf '%s\n' "$unmet" >&2
          exit "$GATE_EXIT_RULE" ;;
      esac
    fi
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
    # Tested by POSITIVE equality against the token, and the arm below tests the
    # other accepted value the same way. Everything the function did not name —
    # including a value it never printed — falls through to the refusing arm.
    if [ "$disposition" = "무효화" ]; then
      warn "런이 무효화된 채로 종료를 기록합니다 — 충족이 아니라 무효로 남습니다"
      gate_append '자율 승인' "kind=$kind" "결정=act" "대상=$alias" "세그먼트=$segment" \
        "절단점=$GATE_ACT_EFFECTIVE" "유도 절단점=${GATE_ACT_DERIVED:--}" \
        "축2=$graded" "등급=1" "기준=무효화 종료" \
        "되돌리는 법=새 런으로 다시 킥오프" "근거=$rationale"
      printf '%s 종단 — 무효화 · 근거 %s\n' "$(now_iso)" "$rationale" > "$RUN_DIR/done"
      # `ended` and not `rekick`: the run has WRITTEN its ending here, so what is
      # left for a person is to read the result rather than to re-open anything.
      # The instruction to kick off again belongs to the site that anchors the
      # run, which has already spoken by the time this one does.
      if gate_may_raise_banner; then
        cc_notify_fire ended "런이 무효화된 채로 종료됐습니다 — 아침 보고서를 확인하세요" || true
      fi
      return 0
    fi
    if [ "$disposition" != "충족" ]; then
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
      gate_append '자율 승인' "kind=$kind" "결정=기각" "대상=$alias" "세그먼트=$segment" \
        "절단점=$GATE_ACT_EFFECTIVE" "유도 절단점=${GATE_ACT_DERIVED:--}" \
        "축2=$graded" "등급=0" "기준=종료 조건 아홉" \
        "되돌리는 법=해당 없음(거부)" \
        "근거=$(gate_unmet_summary "$unmet")"
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
    # The notification seat is carried over from the other parent; its own
    # `done` write is not. That write spelled the same file with the older
    # single-class line and would have run after the branch above, overwriting
    # the very distinction that branch exists to record. The banner is kept
    # whole and fires on every terminal class, including the one holding open
    # questions — that is still an ending someone should be told about.
    # The other arm that decides the run's end. `ended`, because what a person
    # does next here is look at the result and decide what follows — the per-run
    # replace slot is exactly right for a fact that supersedes any earlier state
    # of the same run, and re-raising it costs nothing.
    if gate_may_raise_banner; then
      cc_notify_fire ended "런이 종단했습니다 — 아침 보고서를 확인하세요" || true
    fi
  # BOOKKEEPING IS EXEMPT, AND THE EXEMPTION IS THIS ARM'S OWN PURPOSE READ
  # CORRECTLY. What it refuses is a router that walks past a satisfied ending and
  # keeps routing; a row recording WHY the seat stopped is not walking past
  # anything. Without it all eight bookkeeping kinds are refused with exit 3 in
  # exactly the state where the protocol requires the terminal shift to write its
  # `handoff` row — and no `--rationale` reaches them, because the three sources
  # `gate_names_next_obligation` can name are all empty precisely when `unmet`
  # is. The morning then loses the last shift's rejected alternatives whole.
  elif [ -z "$unmet" ] && ! gate_kind_is_bookkeeping "$kind"; then
    # THE LITERAL TEST STAYS. Every other site compares the disposition token by
    # positive equality, and this one cannot: the chain ends at `fi`, so there is
    # no refusing arm to fall into, and the polarity is inverted — ENTERING this
    # branch is what produces the refusal. Written as `= "충족"` an unrecognized
    # value would SKIP the obligation check and let the act proceed unexamined,
    # which is the one place the token form would be looser than the literal.
    #
    # `--rationale` does not switch this axis off. Skipping it removes a rare
    # false red and opens a false green in the far commoner all-met state, where
    # there is nothing to name and `act` refuses every rationale too — so the
    # skip would make `plan` answer 0 exactly where `act` answers 3. What the
    # missing input gets instead is disclosure.
    if [ "$verb" = "plan" ] && [ -z "$rationale" ]; then
      warn "plan(dry-run): --rationale 이 없어 의무 지목 축을 빈 근거로 평가했습니다 — 라우터가 실제로 낼 argv 로 다시 물으면 정확해집니다"
    fi
    if ! gate_names_next_obligation "$rationale"; then
      warn "종료 조건이 전부 성립하는데 다음 의무를 지목하지 못했습니다 — 런은 충족으로 종료합니다"
      exit "$GATE_EXIT_RULE"
    fi
  fi

  # THE ANCHOR CHECK, and its position is the whole of its effect. It sits AFTER
  # the rule loop and UPSTREAM OF BOTH APPENDS — the `자율 승인` row below and
  # the obligation row the issuer writes — so a merge refused here leaves no row
  # of either kind. It also sits above the forecast arm, so `plan` answers with
  # the same code: an arm that forecast "통과 예상" and then had `act` refuse is
  # the state a router cannot plan around.
  # THIS SITE AND THE ISSUER BELOW TAKE THE EFFECTIVE RUNG TOGETHER, and splitting
  # them is the one wrong way to do it: both narrow on `= 머지`, so leaving the
  # anchor check on the declared value lets an under-declared merge skip the
  # anchor and reach the issuer anyway — a row with no commit to close it.
  gate_check_merge_anchor "$segment" "$GATE_ACT_EFFECTIVE" || exit $?

  # THE FORECAST IS ISSUED HERE, past every read-only axis and before every
  # write. Above this line sit the surface comparison, the segment-row existence
  # check, the predecessor-landing check, the termination conditions, the
  # obligation-naming arm and the anchor check — all reads, and all of them axes
  # the same argv meets as an `act`. Below it sit the boundaries, the credential
  # resolution, the ledger append and the act itself.
  if [ "$verb" = "plan" ]; then
    gate_plan_unchecked_axes "$kind"
    # The forecast reports the rung the act would be ADJUDICATED at, and names the
    # derived one beside it. Reporting the declared word would make the dry run
    # disagree with the row the same argv writes as an `act` — which is the one
    # thing a forecast must not do.
    printf '통과 예상: kind=%s target=%s 절단점=%s 유도=%s 축2=%s\n' \
      "$kind" "$alias" "$GATE_ACT_EFFECTIVE" "${GATE_ACT_DERIVED:--}" "$graded"
    return 0
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

  # A BOOKKEEPING KIND IS DECIDED BEFORE THE APPROVAL ROW IS WRITTEN, and every
  # other kind after it. The two orderings look inconsistent and are not: what
  # the early row buys is a record surviving a crash PART WAY THROUGH AN ACT,
  # and a bookkeeping kind performs no act — its entire effect is one atomic
  # `gate_append`, which either lands whole or not at all. So writing approval
  # first buys nothing there and costs the thing this ordering must not cost: a
  # REFUSED row still leaves a row saying the gate approved it, and refusals on
  # this arm are ordinary (a ceiling excess, a missing `워크트리`, an obligation
  # naming another target). A refusal that grows the ledger is indistinguishable
  # in the morning from an act that happened.
  #
  # THE SET IS STILL SPELLED ONCE. Moving the branch above the approval row is
  # an ordering change and not a second copy of the vocabulary — re-spelling the
  # kinds here would leave this arm behind the moment a kind is added, which is
  # exactly what `gate_kind_is_bookkeeping` exists to prevent.
  local rc=0
  local bookkeeping=
  if gate_kind_is_bookkeeping "$kind"; then
    bookkeeping=1
    gate_record_row "$kind" "$segment" "$alias" "$@" || return $?
  fi

  # TWO FIELDS AND NOT ONE. `절단점` is what the gate ADJUDICATED this act as and
  # `유도 절단점` is what the argv itself said, `-` where the table stayed silent.
  # Folded into one field, "the argv says this is a merge" and "the caller says
  # this is a merge" become the same sentence — and telling those apart is the
  # entire subject of this axis.
  gate_append '자율 승인' "kind=$kind" "결정=$verb" "대상=$alias" "세그먼트=$segment" \
    "절단점=$GATE_ACT_EFFECTIVE" "유도 절단점=${GATE_ACT_DERIVED:--}" \
    "축2=$graded" "자격=$credmode" "근거=$rationale"
  log "게이트 통과 — $verb $GATE_ACT_EFFECTIVE ($alias)"

  # The RESOLVED policy and not a flag value. What decides whether a merge defers
  # its review is the segment row bounded by the target's ceiling, and a caller
  # that could name the policy on the command line could also name one the
  # ceiling forbids.
  # THE FIFTH CONSUMER, AND IT SITS BELOW THE SEAM — so the seam alone does not
  # reach it and this call site is corrected on its own. Left reading the declared
  # rung it would go on comparing `= 머지` against a word the caller chose, and
  # "an under-declared merge issues no obligation" would survive the whole repair.
  gate_issue_review_obligation "$segment" "$GATE_ACT_EFFECTIVE" "$graded" "$GATE_REVIEW_POLICY" "$alias"

  [ -n "$bookkeeping" ] && return 0

  # ---- and now PERFORM it -------------------------------------------------
  #
  # Recording without performing is what the first cut of this file did, and it
  # makes the whole layer unreachable: layer 1 denies every bash line that is
  # not this script, so if this script does not run the line, nothing runs at
  # all. The row is written BEFORE the act, deliberately — a row with no act is
  # an over-report a person can see in the morning, and an act with no row is
  # the thing this design exists to prevent.
  # EVERY RETURN FROM HERE DOWN EMITS, AND EMITS LAST. The emission runs from an
  # EXIT trap, so it sees the state after this call's final ledger write — and
  # the exits below write different numbers of rows: the `자율 승인` row above is
  # the last write for `exec`, for `act --kind skill` and for a bookkeeping kind
  # (whose own row was already written above it), and a failed act writes one
  # more at the bottom. A pre-append value would hand the caller a digest already
  # stale on arrival and every acting call after it would come back exit 4 — a
  # run that deadlocks loudly on the mechanism meant to speed it up. `plan` never
  # reaches this line and emits nothing, which is why the re-read after a `plan`
  # stays in the router's contract.
  [ "$kind" = "propose-done" ] && return 0
  case "$verb" in
    exec)
      # The stage's own credential set: read-scoped, so a `gh pr merge` spelled
      # here fails at the API rather than at a string match.
      gate_run_readonly "$@" || rc=$?
      ;;
    act)
      case "$kind" in
        skill) gate_launch_stage "$alias" "$segment" "$@" || rc=$? ;;
        # The first token after `--` is the HANDOFF REASON here, the way it is
        # the stage kind for `skill`. Same shape, different layer: this one
        # decides whether the suppressor below applies, and the settings variant
        # is always `shift`.
        router-shift) gate_launch_shift "$alias" "$@" || rc=$? ;;
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
      "절단점=$GATE_ACT_EFFECTIVE" "유도 절단점=${GATE_ACT_DERIVED:--}" \
      "축2=$graded" "근거=rc=$rc"
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
  # The merge rung travels with the act rung, exactly as on the declared path.
  # A checker that fires at merge OR ABOVE needs both integers to decide it is
  # NOT firing, so shipping only one makes it refuse for want of an index — and
  # that refusal lands on acts far below merge, where the checker had nothing to
  # say. Fail-closed in a checker is right; reaching it with a half-filled
  # environment is the caller's defect.
  GATE_MERGE_INDEX=$(cutpoint_index '머지') || return "$GATE_EXIT_VOCAB"
  export GATE_TARGET_CUTPOINT GATE_TARGET_INDEX GATE_ACT_INDEX GATE_MERGE_INDEX
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
  # THE QUESTION IS A FIXED LITERAL AND THE BLOCK IS STILL WRITTEN: the anchor on
  # the row has to name something, and the close path fills the answer region
  # of this block the same way it does a judgment's.
  #
  # THE FIFTH RECORDING SITE sits on the row below. `$cut` is already the
  # EFFECTIVE rung — the caller resolved it before the rule loop — so the
  # derived value is read from the exported global rather than threaded through
  # a sixth parameter. A question a person answers in the morning has to say
  # which rung it is about, and the rung the run acted on is the effective one.
  local q='사전 인가 밖 행위를 수행할까요'
  gate_approval_sidecar_write "$id" issue '질문' "$q" \
    || warn "승인 사이드카에 질문을 쓰지 못했습니다 — 행은 발행되나 앵커 $(gate_approval_sidecar_anchor "$id") 가 가리키는 블록이 없습니다"
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$alias" "절단점=$cut" \
    "유도 절단점=${GATE_ACT_DERIVED:--}" \
    "행위 다이제스트=$ad" "구속 튜플=$alias/$base/${head:0:12}/$grade" \
    "막는 세그먼트=$seg" "질문 문면=$q" \
    "답변 문면=-" "사이드카 앵커=$(gate_approval_sidecar_anchor "$id")" \
    "발행 시각=$(now_iso)" "해소 시각=-"
  # Raised the moment the row is seated. The row's own idempotence guard is the
  # early return above, so the notice inherits it exactly — same key, same
  # condition — and an act blocked twice produces one pending approval and one
  # banner rather than a queue of either.
  gate_notify_approval "$id" "$q — $alias / $cut / $grade"
  warn "승인 대기 발행 $id — $alias / $cut / $grade"
  gate_warn_canon_prompt "$id" "$q"
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

# gate_check_merge_anchor <segment> <cutpoint>
#
# A merge that cannot say WHAT IT MERGES is refused before it happens. The
# obligation this act is about to issue carries the tip of the segment worktree
# as its anchor, and the fulfilling review is matched against that commit — so
# an obligation issued without one is a row nobody can ever close, and
# termination condition 9 then holds the run open on it forever. Refusing at the
# issuing point costs one merge; writing the unanchorable row costs the run.
#
# THE THREE FAILURES GET THREE DIFFERENT SENTENCES, and none of the three uses
# the word 「룰」. That is a load-bearing prohibition rather than a matter of
# style: a refusal phrased as a rule refusal is folded into the rule catalog by
# the next reader, and every entry of that catalog is switchable — so the fold
# would quietly bring this refusal inside the range of `끔`, which is precisely
# what its own exit code exists to deny.
gate_check_merge_anchor() {
  local seg="$1" cut="$2" wt tip
  [ "${GATE_REVIEW_POLICY:-}" = "선머지후리뷰" ] || return 0
  [ "$cut" = "머지" ] || return 0

  # `상태` is required on every segment row, so its absence is the absence of the
  # row rather than of one field.
  if [ -z "$seg" ] || [ "$seg" = "-" ] || [ -z "$(gate_segment_field "$seg" '상태')" ]; then
    warn "머지될 커밋을 지목할 세그먼트 행이 원장에 없습니다: '${seg:--}'"
    warn "세그먼트 행을 먼저 기록하고 같은 argv 로 다시 부르세요"
    return "$GATE_EXIT_ANCHOR"
  fi
  wt=$(gate_segment_worktree "$seg")
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    warn "세그먼트 '$seg' 의 워크트리 디렉터리가 없습니다: '${wt:--}'"
    warn "그 자리에서 머지될 커밋을 읽을 수 없으므로 이 머지는 발행되지 않습니다"
    return "$GATE_EXIT_ANCHOR"
  fi
  tip=$(gate_segment_tip "$seg") || tip=""
  if [ -z "$tip" ]; then
    warn "세그먼트 '$seg' 의 워크트리 '$wt' 에서 HEAD 를 해소하지 못했습니다"
    warn "머지될 커밋을 적을 수 없으므로 이 머지는 발행되지 않습니다"
    return "$GATE_EXIT_ANCHOR"
  fi
  # Resolved once and reused by the issuer below, so the value on the row is the
  # same one this check passed on. Re-reading it there would open a window in
  # which the refusal and the row disagree about the same worktree.
  GATE_MERGE_ANCHOR="$tip"
  export GATE_MERGE_ANCHOR
  return 0
}

# The two judgments the fulfillment arm makes, and the sentence each leaves
# behind. They are functions rather than inline blocks because each has THREE
# outcomes and the third one — "the world did not answer" — is the one an inline
# block loses: folded into either neighbour it becomes a confident yes or a
# confident no about something nothing measured.
# THE VERDICT TRAVELS IN A VARIABLE, NOT ON STDOUT. Both predicates answer with a
# verdict AND a sentence, and a caller that took the verdict through `$(…)` ran
# the function in a subshell — so the sentence, set on a global, was discarded at
# the moment it was assigned. Every refusal then printed its reason as the empty
# string, which is precisely the state the third value exists to prevent: the
# operator is told the gate could not decide and not told what failed to answer.
# Returning both the same way is what keeps them together.
GATE_LANDING_VERDICT=""
GATE_LANDING_WHY=""
GATE_COVER_VERDICT=""
GATE_COVER_WHY=""

gate_landing_unlanded_why() {
  # gate_landing_unlanded_why <root> <ref> <머지 커밋>
  #
  # WORDING ONLY. Two commits with no common ancestor are not going to acquire one
  # by waiting, and an operator reading 미착지 needs to know which of the two they
  # are looking at. The DISPOSITION is 미착지 either way: a fourth outcome here
  # would leak into `이행 판정`, whose value set is closed at three.
  local root="$1" ref="$2" m="$3"
  if ( cd "$root" && git merge-base "$m" "$ref" >/dev/null 2>&1 ); then
    printf '%s 가 머지 커밋을 담고 있지 않습니다' "$ref"
  else
    printf '머지 커밋과 %s 에 공통 조상이 없습니다 — 재시도로 풀리지 않습니다' "$ref"
  fi
}

gate_landing_rewritten_landed() {
  # gate_landing_rewritten_landed <root> <ref> <머지 커밋>
  #
  # A REWRITING MERGE NEVER MAKES THE TIP AN ANCESTOR. `--squash` and `--rebase`
  # build new commits on the server side, so the ancestry test answers no for
  # that sha forever while the change itself IS on the base branch. Left at that,
  # every deferred obligation in such a repository closes on `근거` alone and the
  # containment predicate is never called once — the debt is discharged having
  # consulted no review at all.
  #
  # The second clause is TREE EQUALITY, on the same grounds the staleness ladder
  # already admits a same-tree exception: a rewrite that leaves the tree
  # byte-identical carried the content across. The window is bounded to what the
  # base gained since it forked from the merged commit — outside that window an
  # equal tree says nothing about THIS merge. No common ancestor means no window
  # and the answer stays no, which is the case the wording helper already calls
  # unrecoverable.
  local root="$1" ref="$2" m="$3" t mb tt
  t=$( cd "$root" && git rev-parse --verify --quiet "${m}^{tree}" 2>/dev/null ) || t=""
  [ -n "$t" ] || return 1
  mb=$( cd "$root" && git merge-base "$m" "$ref" 2>/dev/null ) || mb=""
  [ -n "$mb" ] || return 1
  for tt in $( cd "$root" && git log --format=%T "${mb}..${ref}" 2>/dev/null ); do
    [ "$tt" = "$t" ] && return 0
  done
  return 1
}

gate_obligation_landing() {
  # gate_obligation_landing <대상 별칭> <머지 커밋>
  #
  # Prints 착지 / 미착지 / 판정 불가 and leaves the explaining sentence in
  # `GATE_LANDING_WHY`.
  #
  # IT RUNS IN THE TARGET'S ANCHOR REPOSITORY AND NOT IN THE SEGMENT WORKTREE.
  # Collapsing those two directories into one is the most common misreading of
  # this design: the worktree holds the commit that was merged, and the base
  # branch it has to land on lives in the target's own repository root.
  local al="$1" m="$2" root br rc
  GATE_LANDING_VERDICT=""
  GATE_LANDING_WHY=""
  root=$(alias_root "$al" 2>/dev/null) || root=""
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    GATE_LANDING_WHY="대상 '$al' 의 앵커 저장소 루트를 해소하지 못했습니다"
    GATE_LANDING_VERDICT='판정 불가'; return 0
  fi
  br=$(base_branch "$al" 2>/dev/null) || br=""
  if [ -z "$br" ]; then
    GATE_LANDING_WHY="대상 '$al' 의 베이스 브랜치를 해소하지 못했습니다"
    GATE_LANDING_VERDICT='판정 불가'; return 0
  fi

  # The local branch first, and when it answers yes NOTHING TOUCHES THE NETWORK.
  # An unresolvable `refs/heads/<베이스>` is ordinary rather than an error — a
  # fresh clone need not carry one — and falls through to the remote arm.
  rc=0
  ( cd "$root" && git merge-base --is-ancestor "$m" "refs/heads/$br" >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" = "0" ]; then
    GATE_LANDING_WHY="로컬 refs/heads/$br 가 이미 머지 커밋을 담고 있습니다"
    GATE_LANDING_VERDICT='착지'; return 0
  fi

  # No origin means the local refs ARE the whole world, so the answer above is
  # final rather than provisional. Reaching for a remote that does not exist would
  # turn a settled 미착지 into an unsettleable one.
  if ! ( cd "$root" && git remote get-url origin >/dev/null 2>&1 ); then
    case "$rc" in
      1) if gate_landing_rewritten_landed "$root" "refs/heads/$br" "$m"; then
           GATE_LANDING_WHY="원격이 없고 로컬 refs/heads/$br 가 머지 커밋과 같은 트리의 커밋을 담고 있습니다 — 다시 쓰인 머지입니다"
           GATE_LANDING_VERDICT='착지'; return 0
         fi
         GATE_LANDING_WHY="원격이 없어 로컬 refs/heads/$br 가 세계 전부입니다 — $(gate_landing_unlanded_why "$root" "refs/heads/$br" "$m")"
         GATE_LANDING_VERDICT='미착지'; return 0 ;;
      *) GATE_LANDING_WHY="원격이 없고 로컬 refs/heads/$br 에 대한 조상 검사가 답하지 못했습니다 (git rc=$rc)"
         GATE_LANDING_VERDICT='판정 불가'; return 0 ;;
    esac
  fi

  # A FAILED FETCH IS A REFUSAL AND NOT A 미착지. The failure leaves the stale
  # tracking ref exactly where it was, so the ancestor test below would run and
  # would answer — with the confidence of a measurement and the content of a
  # guess. `base_fetch` cannot be used here: it reports success on a dead remote.
  if ! base_fetch_ref "$al" "$br"; then
    GATE_LANDING_WHY="원격 fetch 가 실패해 refs/remotes/origin/$br 가 낡은 채로 남았습니다"
    GATE_LANDING_VERDICT='판정 불가'; return 0
  fi
  # A fetch that succeeded and still left no tracking ref is also a refusal. That
  # the branch has zero population today means the answer is MISSING, not that it
  # is no.
  if ! ( cd "$root" && git rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null 2>&1 ); then
    GATE_LANDING_WHY="fetch 는 성공했으나 refs/remotes/origin/$br 가 없습니다"
    GATE_LANDING_VERDICT='판정 불가'; return 0
  fi
  # THREE BRANCHES, NEVER FOLDED TO TWO. A merge commit that does not resolve in
  # this repository exits 128 here, and 128 is a refusal rather than a no.
  rc=0
  ( cd "$root" && git merge-base --is-ancestor "$m" "refs/remotes/origin/$br" >/dev/null 2>&1 ) || rc=$?
  case "$rc" in
    0) GATE_LANDING_WHY="refs/remotes/origin/$br 가 머지 커밋을 담고 있습니다"
       GATE_LANDING_VERDICT='착지'; return 0 ;;
    1) if gate_landing_rewritten_landed "$root" "refs/remotes/origin/$br" "$m"; then
         GATE_LANDING_WHY="refs/remotes/origin/$br 가 머지 커밋과 같은 트리의 커밋을 담고 있습니다 — 다시 쓰인 머지입니다"
         GATE_LANDING_VERDICT='착지'; return 0
       fi
       GATE_LANDING_WHY=$(gate_landing_unlanded_why "$root" "refs/remotes/origin/$br" "$m")
       GATE_LANDING_VERDICT='미착지'; return 0 ;;
    *) GATE_LANDING_WHY="refs/remotes/origin/$br 에 대한 조상 검사가 답하지 못했습니다 (git rc=$rc)"
       GATE_LANDING_VERDICT='판정 불가'; return 0 ;;
  esac
}

gate_segment_review_head() {
  # gate_segment_review_head <segment> — the `리뷰 HEAD` of that segment's LAST
  # `cycle` row. Last and not first: a segment reviewed twice is answered by the
  # review that happened most recently, which is the one the containment test is
  # about.
  local row
  row=$( { gate_rows 'cycle' | grep -F "세그먼트=$1 " || true; } | tail -1)
  [ -n "$row" ] || return 0
  gate_row_field "$row" '리뷰 HEAD'
}

gate_obligation_covers() {
  # gate_obligation_covers <대상 별칭> <머지 커밋> <리뷰 HEAD>
  #
  # Prints 덮는다 / 덮지 않는다 / 판정 불가 and leaves the sentence in
  # `GATE_COVER_WHY`. The question is whether the review that closed this
  # obligation actually looked at the commit that was merged — a review of the
  # segment is not the same thing as a review of that commit.
  local al="$1" m="$2" r="$3" root rc tm tr
  GATE_COVER_VERDICT=""
  GATE_COVER_WHY=""
  # NO REVIEW AT ALL IS `덮지 않는다`, NOT `판정 불가`. The third value is for a
  # question the world declined to answer — an unresolvable sha, a dead remote, a
  # missing ref — and it is a refusal whose repair is "make the judgment possible
  # and call again". The absence of a `cycle` row is not that: it is a complete,
  # confident answer that no review covers this commit, and its repair is "record
  # the review". Folding the two together sends the operator to look for a broken
  # repository when what is missing is the review itself.
  if [ -z "$r" ] || [ "$r" = "-" ]; then
    GATE_COVER_WHY="이 세그먼트에 「리뷰 HEAD」를 실은 cycle 행이 없습니다"
    GATE_COVER_VERDICT='덮지 않는다'; return 0
  fi
  root=$(alias_root "$al" 2>/dev/null) || root=""
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    GATE_COVER_WHY="대상 '$al' 의 앵커 저장소 루트를 해소하지 못했습니다"
    GATE_COVER_VERDICT='판정 불가'; return 0
  fi
  # `--is-ancestor` answers the equal case with 0 as well, so "ancestor of, or the
  # same as" is one test rather than two.
  rc=0
  ( cd "$root" && git merge-base --is-ancestor "$m" "$r" >/dev/null 2>&1 ) || rc=$?
  case "$rc" in
    0) GATE_COVER_WHY="리뷰 HEAD $r 가 머지 커밋을 담고 있습니다"
       GATE_COVER_VERDICT='덮는다'; return 0 ;;
    1) : ;;
    *) GATE_COVER_WHY="리뷰 HEAD $r 에 대한 조상 검사가 답하지 못했습니다 (git rc=$rc)"
       GATE_COVER_VERDICT='판정 불가'; return 0 ;;
  esac
  # The tree exception, on the same terms the freshness ladder already grants it.
  # A rebase or an amend moves the commit id and leaves the reviewed bytes
  # identical; refusing those would refuse reviews that did happen.
  tm=$( { cd "$root" 2>/dev/null && git rev-parse "${m}^{tree}" 2>/dev/null; } || true)
  tr=$( { cd "$root" 2>/dev/null && git rev-parse "${r}^{tree}" 2>/dev/null; } || true)
  if [ -n "$tm" ] && [ "$tm" = "$tr" ]; then
    GATE_COVER_WHY="리뷰 HEAD $r 의 트리가 머지 커밋의 트리와 같습니다 (리베이스·amend)"
    GATE_COVER_VERDICT='덮는다'; return 0
  fi
  GATE_COVER_WHY="리뷰 HEAD $r 가 머지 커밋을 담지 않고 트리도 다릅니다"
  GATE_COVER_VERDICT='덮지 않는다'; return 0
}

gate_issue_review_obligation() {
  # gate_issue_review_obligation <segment> <cutpoint> <grade> <policy> <alias>
  #
  # `선머지후리뷰` does not REMOVE the review, it defers it — and a deferral with
  # no record is a removal that nobody wrote down. The row is what makes the
  # deferral survive the merge: termination condition 9 refuses to let the run
  # end while one is unfulfilled.
  #
  # `생성 등급` is the axis-2 grade of the act that created the obligation, and
  # NOTHING IN THIS TREE READS IT ON THIS SERIES. The excusal rule reads a field
  # of the same name on `problem` rows, which is a different series with a
  # different writer, and this comment used to claim that reader as its own — so
  # the field looked load-bearing and an implementer changing it would have
  # searched for a consumer that does not exist. It is kept because the morning
  # wants to know what kind of act deferred the review, not because a predicate
  # is waiting on it.
  #
  # THE ALIAS ARRIVES AS AN ARGUMENT because there is nowhere else to get it: it
  # is on neither the segment row nor this series, and only the calling scope
  # knows which target the merge was authorized against. The row carries it as
  # `대상` so the fulfilling side runs its landing test in THAT target's anchor
  # repository rather than in the segment worktree — two directories the shape
  # of this design invites collapsing into one.
  #
  # `머지 커밋` IS THE COMMIT BEING MERGED and not a commit the merge creates:
  # the tip of the segment worktree at issue time. A `cycle` row's `리뷰 HEAD`
  # lives in that same ref space, and the containment test between the two means
  # nothing unless both name commits that exist before the merge does.
  #
  # THE DUPLICATE GUARD ASKS ABOUT STATE, NOT EXISTENCE. A fulfillment row
  # carries the same `의무 id=`, so an existence test suppressed every issue
  # after the first fulfillment — a segment's second merge then created no
  # obligation at all, which is the hole this series exists to close. And the
  # question is narrowed to THIS segment: asked run-wide, a sibling segment's
  # open obligation suppresses this one's, trading a defect inside a segment for
  # the guarantee between segments.
  local seg="$1" cut="$2" grade="$3" policy="$4" alias="$5" id tip
  [ "$policy" = "선머지후리뷰" ] || return 0
  [ "$cut" = "머지" ] || return 0
  [ -n "$seg" ] && [ "$seg" != "-" ] || return 0
  # THE ANCHOR IS RESOLVED BEFORE THE ID, because the id is keyed on it. The
  # order is safe: this issuer runs only under `선머지후리뷰` at cutpoint `머지`,
  # which is exactly the window in which the pre-issue anchor check has already
  # run and refused an unreadable tip, so nothing new can fail here.
  tip="${GATE_MERGE_ANCHOR:-}"
  [ -n "$tip" ] || { tip=$(gate_segment_tip "$seg") || tip=""; }
  if [ -z "$tip" ]; then
    warn "세그먼트 '$seg' 의 팁을 읽지 못해 리뷰 의무를 발행할 수 없습니다"
    return "$GATE_EXIT_ANCHOR"
  fi
  # The id is keyed on (run, segment, ANCHOR) and NOT on the review cycle: it is
  # the key of a review SLOT, not of a cycle. Re-keying it per cycle would change
  # what termination condition 9 counts.
  #
  # THE ANCHOR IS IN THE KEY BECAUSE (run, segment) ALONE COLLAPSES N MERGES INTO
  # ONE DEBT. Under `끔` the ordering predicate does not run, so a second merge at
  # a NEW tip reaches this issuer with the first tip's slot still open and the
  # duplicate guard below returns without a row — the second merge leaves no
  # trace at all. Fulfilling the one slot then closes on the first tip, which a
  # review does cover, and everything between the two tips lands on the base
  # branch reviewed by nobody with nothing in the ledger to say so. The reason
  # cycle-keying was rejected does not carry over: an unreviewed second merge
  # SHOULD raise the count condition 9 holds the run open on.
  id="RO-$(printf '%s|%s|%s' "$RUN_ID" "$seg" "$tip" | shasum -a 256 | cut -c1-8)"
  # Membership is decided over a VALUE rather than over a pipeline exit status:
  # ids are `RO-` plus hex and carry no whitespace, so the word-splitting loop
  # this file already uses for the same list reads them exactly.
  local open_id
  for open_id in $(gate_unfulfilled_review_obligations "$seg"); do
    [ "$open_id" = "$id" ] && return 0
  done
  gate_append '리뷰 의무' "의무 id=$id" "상태=미이행" "세그먼트=$seg" \
    "대상=$alias" "머지 커밋=$tip" "생성 등급=$grade" \
    "발행 시각=$(now_iso)" "이행 시각=-"
  log "리뷰 의무 발행 $id — 세그먼트 $seg · 대상 $alias · 머지 커밋 $tip (선머지후리뷰)"
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

gate_pin_attempt() {
  # gate_pin_attempt <segment> — pin this dispatch's attempt number, echo it.
  #
  # A NAMED FUNCTION rather than a block inside the launcher, so a test can burn
  # it. Inlined, the only thing a suite could reach was the launcher's source
  # text, and a shape assertion stays green as long as the literals survive —
  # deleting the advance loop below leaves every literal in place and lands two
  # dispatches on one path with nothing red.
  #
  # THE ROW COUNT IS THE STARTING POINT AND NOT THE ANSWER. A dispatch that died
  # before its row landed leaves the count where it was, and the router
  # re-dispatches the same segment id — so two attempts would land on one path.
  # The driver pins the same way and for the same reason, and its readers consult
  # the pin FIRST, which is what makes one file the answer for both sides instead
  # of each deriving its own.
  #
  # The count is taken from the gate's OWN rows and not from the driver's
  # `stage_attempt`: the gate has already appended this dispatch's `자율 승인` row
  # by the time it gets here, while the driver counts `stage-result` rows that
  # only land at termination. Two counting bases, one pin — the advance loop is
  # what makes them agree on the file.
  local seg="$1" attempt
  attempt=$( { gate_rows '자율 승인' | grep -F 'kind=skill ' || true; } \
             | { grep -cF "세그먼트=$seg " || true; } )
  [ "${attempt:-0}" -ge 1 ] || attempt=1
  mkdir -p "$RUN_DIR/log"
  while [ -e "$RUN_DIR/log/$seg#$attempt.json" ] || [ -e "$RUN_DIR/log/$seg#$attempt.err" ]; do
    attempt=$(( attempt + 1 ))
  done
  printf '%s\n' "$attempt" > "$RUN_DIR/$seg.attempt"
  printf '%s' "$attempt"
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
  # Derived from the ledger and NOT taken as argv: adding an `--attempt` flag
  # would let a router re-type the number it used last time, which reproduces the
  # collision through the one surface that is supposed to prevent it. The
  # derivation and the pin both live in `gate_pin_attempt` so a test can burn
  # them.
  local attempt
  attempt=$(gate_pin_attempt "$seg")

  # THE STREAM IS SCOPED BY ATTEMPT AND OPENED FOR APPEND. This launcher is the
  # one the router actually uses, and it wrote every dispatch of one segment to a
  # single truncating path — so the implementation stage's transcript was erased
  # by the review stage of the same segment, and the readers on the other side
  # (`stage_session_id`, `predicate_reconverge`, `decision_point_reached`) were
  # reading a file this side could zero at any moment. The transcript is the only
  # record of what a stage read and concluded, and in an unattended run nobody
  # was there to see it happen.
  #
  # THE PATH COMES FROM THE READER'S OWN FUNCTION rather than from a second copy
  # of the rule. The pin was written one line above, so `stage_log_path` — the
  # same function `stage_session_id` and `predicate_reconverge` call — resolves to
  # this attempt's name and nothing else. Spelling the rule twice is what let the
  # writer and the readers come apart in the first place.
  local out err
  out=$(stage_log_path "$seg")
  err="${out%.json}.err"

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
    -- "$@" >> "$out" 2>> "$err" < /dev/null &
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
  gate_record_stage_outcome "$alias" "$seg" "$kind" "$attempt" "$rc" "$n_rows_before" "$out"
  return "$rc"
}

gate_record_stage_outcome() {
  # gate_record_stage_outcome <alias> <segment> <kind> <attempt> <rc> <rows-before> [stream]
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
  # THE STREAM THIS DISPATCH ACTUALLY WROTE, handed down rather than re-derived.
  # Re-deriving is how the writer and the reader came apart once already; the
  # unsuffixed name stays as the fallback for a caller that predates the argument.
  local out="${7:-}" res cost subtype sid klass after denials prev total n_stage psha iserr
  [ -n "$out" ] || out="$RUN_DIR/log/$seg.json"

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
  #
  # THE NAME COMES FROM THE DRIVER'S OWN RULE, not from a second copy of it. This
  # side used to try the attempt-scoped name and fall back to the unsuffixed one
  # WHATEVER THE PIN SAID, which is the opposite of what the driver does: with a
  # pin the scoped name is the only answer. Two readers of one artifact then
  # disagreed about the same dispatch — a run started before the driver scoped its
  # stage ids leaves an unsuffixed record, and resuming that run id pins attempt 2,
  # so the driver saw no record and classified `정상 완료` while this side found the
  # first attempt's record and wrote `의도된 park` into the ledger. The row and the
  # control flow then describe different runs.
  local haltf
  haltf=$(halt_record_path "$seg")
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

  # A TERMINAL CLASS THAT LEFT EVIDENCE OF REACHING A POINT NEEDING A PERSON is
  # announced the instant the row is seated — before the cost block, because the
  # row is the fact and the cost is bookkeeping.
  #
  # NO ONCE-MARKER, and that is deliberate rather than an omission. This function
  # is called exactly once, immediately after the child is waited on; a
  # re-dispatch is a genuinely new event and deserves a second notice.
  #
  # THE SPLIT IS A PREDICATE, NOT AN ENUMERATION — did the stage leave evidence
  # that it reached a point needing a person? A deliberate park and a stop with
  # no artifact both did: one says so in its halt record, the other left the
  # trace of arriving at a decision point it declined to settle.
  #
  # A CLASS WHOSE NEED FOR A PERSON CANNOT BE KNOWN HERE IS NOT ANNOUNCED. A
  # crash and a hollow success left nothing this side can read, so at
  # classification time there is no way to tell a stage that needs a person from
  # one that merely died and will be re-dispatched — and a notice sent on that
  # ignorance asks a sleeping person for an action the gate would refuse anyway.
  # If such a condition really does stop the run's progress, it becomes visible
  # where stalling is observable rather than guessed: a park, an anchored run, a
  # stall arm, a termination. A class added later divides itself the same way,
  # and THE DEFAULT IS SILENCE.
  #
  # THE SUBSTITUTE PATH IS NOT ALWAYS IMMEDIATE, and the cost is written down
  # rather than rounded to zero. The predicate that counts unresolved blockage
  # filters on run scope alone while the driver also parks at cone scope, so on
  # that branch the segment park row catches it, and failing that the stall arm
  # does — one silence ceiling later. The delay is the price; losing the
  # condition is not among the outcomes.
  local q
  if [ "$klass" != '정상 완료' ]; then
    case "$klass" in
      '의도된 park')
        # The body is the stage's own Korean question, verbatim from the halt
        # record. The contract binds the WRITER to record it without summarizing,
        # so the reading rule has to be stated somewhere and this is it: take the
        # rest of the `질문 문면` line. The path is already resolved above — the
        # firing point is inside the function that opened it.
        q=$( { sed -n 's/^\*\*질문 문면\*\*: *//p' "$haltf" 2>/dev/null || true; } | sed -n '1p')
        # THE FALLBACK IS NOT FOR A CRASH MID-WRITE. This class requires the
        # closing fence as the record's last non-empty line, so a record cut off
        # part-way is classified as something else and never reaches here. What
        # is reachable is a COMPLETE record whose field could not be read, and
        # the wording says exactly that. An empty extraction must not kill the
        # shell either: this sits on the critical path of an exit-on-error shell.
        #
        # THE QUESTION IS REPORTED, NOT ASKED. Now that a title carries an
        # instruction, handing the stage's raw question straight to the body puts
        # "직접 손대세요" over "계속할까요?" — the title commands, the body asks, and
        # there is nowhere on that screen to answer. The question stays verbatim
        # because it is the best wording this design has; it is wrapped in a
        # statement so the two halves make one speech act. The fallback takes the
        # same form for the same reason.
        if [ -n "$q" ]; then
          q="\`${seg}\` 스테이지가 물음 앞에서 멈췄습니다 — 「${q}」"
        else
          q="\`${seg}\` 스테이지가 스스로 멈췄습니다 — 중단 기록을 확인하세요"
        fi
        # The segment-park marker, written HERE because the attempt number is an
        # argument of this function and is NOT a field of a segment row. The file
        # is named by the segment alone so the segment-row side can find it
        # without deriving an attempt of its own; the attempt is the contents.
        mkdir -p "$RUN_DIR/notify" 2>/dev/null || true
        printf '%s\n' "$attempt" > "$RUN_DIR/notify/park-$seg" 2>/dev/null || true
        if gate_may_raise_banner; then
          cc_notify_fire hands "$q" "park-$seg#$attempt" || true
        fi ;;
      '산출물 없는 정지')
        # ITS OWN WORDING, and it must not borrow the fallback above: this class
        # is DEFINED by the absence of a halt record, so "check the halt record"
        # would send a person to a file that does not exist — the same
        # wrong-instruction failure this channel was built to remove.
        if gate_may_raise_banner; then
          cc_notify_fire hands \
            "\`$seg\` 스테이지가 결정 지점에서 멈췄습니다 — 사용자 대신 정하지 않았습니다" \
            "stop-$seg#$attempt" || true
        fi ;;
    esac
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
  # THE VALUE ENDS AT THE NEXT MARKER, NOT AT THE END OF THE LINE. A stage's
  # terminal message is one JSON string, so the five markers ordinarily arrive on
  # a single line — and `\(.*\)` then hands each free-text field everything that
  # follows it, markers included. Measured on that ordinary spelling: the undo
  # command came back carrying the standard and the rationale glued onto it. The
  # row keeps that value, and the undo command is what a person reads in the
  # morning, so a swallowed field is worse than an absent one.
  std=$(printf '%s' "$txt"    | sed -n 's/.*\*\*판단 기준\*\*: *\(.*\)/\1/p' | sed -n '1p' | sed 's/ *\*\*판단 .*$//')
  revert=$(printf '%s' "$txt" | sed -n 's/.*\*\*판단 되돌리는 법\*\*: *\(.*\)/\1/p' | sed -n '1p' | sed 's/ *\*\*판단 .*$//')
  why=$(printf '%s' "$txt"    | sed -n 's/.*\*\*판단 근거\*\*: *\(.*\)/\1/p' | sed -n '1p' | sed 's/ *\*\*판단 .*$//')

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

gate_session_lineage_record() {
  # THE ONLY WRITER, and it is called from the one place the stage/shift guard
  # stands. Enrolment used to live inside the reader below, so every path that
  # merely READ the lineage enrolled its caller as a side effect — and the
  # guard at the entry point could not see those paths at all. `gate_shift_state`
  # put one of them on the `snapshot` path: a caller whose own transcript is
  # absent falls through to the lineage search, so a stage taking a snapshot
  # enrolled itself. An enrolled id is an id allowed to ANSWER, which is exactly
  # the self-approval path the guard exists to keep shut, reached through the
  # reader instead of through the door. Reading is side-effect free from here on.
  local f="$RUN_DIR/session-lineage"
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 0
  grep -qxF "$CLAUDE_CODE_SESSION_ID" "$f" 2>/dev/null || \
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID" >> "$f"
}

gate_session_lineage() {
  # Every session id this run has had. A `--resume` gives the run a NEW id and
  # leaves the earlier transcript behind, so an approval issued before the break
  # is answered in one file and looked for in another. The lineage is recorded
  # on every entry by the function above and searched as a set here.
  local f="$RUN_DIR/session-lineage"
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

gate_transcript_torn() {
  # gate_transcript_torn — 0 when any lineage transcript ends mid-line.
  #
  # A TORN LINE IS NOT AN ABSENCE, and under this design the two mean opposite
  # things. The gate reads the transcript while the harness is still appending
  # to it, so the ledger's "discard only the last line" rule does not carry
  # over — that rule assumes the gate is the writer, and here the harness is.
  # An incomplete final line that might hold the very id being looked for makes
  # "not found" ambiguous between "not answered yet" and "half written", so the
  # verdict is HELD rather than decided. Checked FIRST, before any search: a
  # search that ran over the torn file would decide on the lines before the
  # tear as if they were the whole file.
  local f
  for f in $(gate_transcript_files || true); do
    [ -f "$f" ] || continue
    if [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then return 0; fi
  done
  return 1
}

gate_frame_candidate() {
  # gate_frame_candidate <승인 id> — the binding candidate for an approval.
  #
  # Sets GATE_FRAME_FILE, GATE_FRAME_LINE and GATE_FRAME_KIND:
  #   answers  a line carrying the id AND a `toolUseResult.answers` map — the
  #            only kind that can close an approval
  #   result   the `tool_result` of an `AskUserQuestion` that asked this id but
  #            produced no answer map (a dismissed dialog, a collapsed call)
  #   asked    the question was put (a `tool_use` carries the id) and no result
  #            frame exists yet
  #   other    a line carries the id and is none of the above — the router's
  #            own tool output echoing the ledger, typically
  #   none     nothing in the lineage carries the id
  #
  # THE BINDING IS THE ID ALONE, NOT THE ID AND THE QUESTION TEXT. Requiring the
  # question on the same line was meant to stop the router pointing `close` at a
  # different question; what it actually did was qualify every line the router
  # READ THE LEDGER on — the ledger row holds both — and reject boundary
  # approvals whose fixed-literal question is shared by dozens of ids. The
  # frame approval below is the real guard: a line closes an approval only if
  # it is the harness-written result of an `AskUserQuestion` whose question
  # carried the id, and the router cannot manufacture that frame.
  #
  # ANSWER FRAMES ARE SEARCHED ACROSS THE WHOLE LINEAGE FIRST, and the first
  # file holding one wins with its LAST such line — latest answer wins, which is
  # the rule a person changing their mind needs. The diagnostic kinds are looked
  # for only when no answer frame exists anywhere, so a dialog dismissed in an
  # earlier session cannot shadow the answer given in a later one.
  local id="$1" f line tid
  GATE_FRAME_FILE=""; GATE_FRAME_LINE=""; GATE_FRAME_KIND="none"
  for f in $(gate_transcript_files || true); do
    [ -f "$f" ] || continue
    line=$( { grep -F "$id" "$f" 2>/dev/null || true; } | { grep -F '"answers":{' || true; } | tail -1)
    if [ -n "$line" ]; then
      GATE_FRAME_FILE="$f"; GATE_FRAME_LINE="$line"; GATE_FRAME_KIND="answers"; return 0
    fi
  done
  for f in $(gate_transcript_files || true); do
    [ -f "$f" ] || continue
    tid=$( { grep -F "$id" "$f" 2>/dev/null || true; } | { grep -F '"name":"AskUserQuestion"' || true; } | tail -1 \
      | jq -r --arg id "$id" '
          [ .message.content[]? | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion")
            | select([ .input.questions[]? | .question | tostring | contains($id) ] | any) | .id ] | last // ""' 2>/dev/null || true)
    if [ -n "$tid" ]; then
      line=$( { grep -F "\"tool_use_id\":\"$tid\"" "$f" 2>/dev/null || true; } | tail -1)
      GATE_FRAME_FILE="$f"
      if [ -n "$line" ]; then GATE_FRAME_LINE="$line"; GATE_FRAME_KIND="result"; else GATE_FRAME_KIND="asked"; fi
      return 0
    fi
    line=$( { grep -F "$id" "$f" 2>/dev/null || true; } | tail -1)
    if [ -n "$line" ]; then
      GATE_FRAME_FILE="$f"; GATE_FRAME_LINE="$line"; GATE_FRAME_KIND="other"; return 0
    fi
  done
  return 1
}

gate_frame_parse() {
  # gate_frame_parse <file> <line> <승인 id> — take one transcript line apart.
  #
  # Sets GATE_FRAME_TYPE (the line's `type`), GATE_FRAME_TID (the `tool_result`
  # block's `tool_use_id`), GATE_FRAME_ERR (1 when that block says `is_error`),
  # GATE_FRAME_ERRTEXT (the first bytes of its content, for the dismissal test),
  # GATE_FRAME_TOOL (the `.name` of the `tool_use` the id joins to, in the same
  # file), GATE_FRAME_HASANS (1 when `toolUseResult.answers` is an object),
  # GATE_FRAME_KEY (the question slot carrying the id — the answers map's key),
  # GATE_FRAME_ANSWER (that slot's answer, verbatim) and GATE_FRAME_LABELS (the
  # `options[].label` the person was shown for that slot, one per line).
  #
  # THE JOIN IS THE FRAME APPROVAL. A `tool_result` names the call it answers by
  # `tool_use_id`; following that id back to its `tool_use` and reading `.name`
  # is what tells an `AskUserQuestion` answer apart from a `Bash` result that
  # happens to contain the same bytes. Nothing about the text decides it.
  #
  # THE SLOT IS FOUND BY CONTAINMENT, NOT POSITION. Measured over the corpus,
  # the id sits at the front of the question in a sixth of the slots and
  # anywhere from offset 1 to past 100 in the rest; a prefix test would reject
  # most of what already exists. The canonical prompt fixes where the gate PUTS
  # the id; this reads it wherever it is.
  local f="$1" line="$2" id="$3" tu
  GATE_FRAME_TYPE=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null || true)
  GATE_FRAME_TID=$(printf '%s' "$line" | jq -r '
    [ .message.content[]? | select(type == "object" and .type == "tool_result") | .tool_use_id ] | last // ""' 2>/dev/null || true)
  GATE_FRAME_ERR=$(printf '%s' "$line" | jq -r '
    [ .message.content[]? | select(type == "object" and .type == "tool_result") | (.is_error == true) ] | last // false
    | if . then "1" else "0" end' 2>/dev/null || printf '0')
  # Clipped inside jq rather than by `head -c` on the right of the pipe: an
  # early-exiting reader there kills the writer under `pipefail`.
  GATE_FRAME_ERRTEXT=$(printf '%s' "$line" | jq -r '
    [ .message.content[]? | select(type == "object" and .type == "tool_result") | (.content | tostring)[0:300] ] | last // ""' 2>/dev/null || true)
  GATE_FRAME_HASANS=$(printf '%s' "$line" | jq -r '
    if (.toolUseResult.answers? | type) == "object" then "1" else "0" end' 2>/dev/null || printf '0')
  GATE_FRAME_KEY=$(printf '%s' "$line" | jq -r --arg id "$id" '
    [ .toolUseResult.questions[]? | .question | select(type == "string" and contains($id)) ] | first // ""' 2>/dev/null || true)
  [ -n "$GATE_FRAME_KEY" ] || GATE_FRAME_KEY=$(printf '%s' "$line" | jq -r --arg id "$id" '
    [ .toolUseResult.answers? | objects | keys[] | select(contains($id)) ] | first // ""' 2>/dev/null || true)
  # THE SLOT AND ITS ENTRY ARE TWO FACTS. A question slot can carry the id while
  # the answers map has no entry under that key — measured at 2.8% of slots in
  # the corpus, a failure mode distinct from free input — so `GATE_FRAME_HASKEY`
  # says whether the map holds the key at all, and an empty answer is not
  # mistaken for an answer of nothing.
  GATE_FRAME_ANSWER=""; GATE_FRAME_HASKEY=0
  if [ -n "$GATE_FRAME_KEY" ]; then
    GATE_FRAME_HASKEY=$(printf '%s' "$line" | jq -r --arg k "$GATE_FRAME_KEY" '
      if (.toolUseResult.answers? | type) == "object" and (.toolUseResult.answers | has($k)) then "1" else "0" end' 2>/dev/null || printf '0')
    GATE_FRAME_ANSWER=$(printf '%s' "$line" | jq -r --arg k "$GATE_FRAME_KEY" '
      .toolUseResult.answers[$k]? // "" | if type == "string" then . else tojson end' 2>/dev/null || true)
  fi
  GATE_FRAME_TOOL=""; GATE_FRAME_LABELS=""
  if [ -n "$GATE_FRAME_TID" ]; then
    tu=$( { grep -F "\"id\":\"$GATE_FRAME_TID\"" "$f" 2>/dev/null || true; } | { grep -F '"type":"tool_use"' || true; } | tail -1)
    if [ -n "$tu" ]; then
      GATE_FRAME_TOOL=$(printf '%s' "$tu" | jq -r --arg tid "$GATE_FRAME_TID" '
        [ .message.content[]? | select(type == "object" and .type == "tool_use" and .id == $tid) | .name ] | last // ""' 2>/dev/null || true)
      GATE_FRAME_LABELS=$(printf '%s' "$tu" | jq -r --arg tid "$GATE_FRAME_TID" --arg id "$id" '
        [ .message.content[]? | select(type == "object" and .type == "tool_use" and .id == $tid)
          | .input.questions[]? | select(.question | tostring | contains($id)) | .options[]? | .label | tostring ] | .[]' 2>/dev/null || true)
    fi
  fi
  return 0
}

gate_menu_matches() {
  # gate_menu_matches <labels, one per line> — 0 when the normalized set of
  # labels a person was shown is exactly the gate's own label set.
  #
  # THE COMPARISON RE-DERIVES THE LABELS FROM THE CONSTANT TABLE. The row
  # stores only a version token; the authority is `gate_menu_labels`, and what
  # is compared is the transcript's `options[].label` — what the person actually
  # saw — against it. A router that rendered its own menu fails here, before any
  # answer is read, which is what makes the label set the gate's and not the
  # router's.
  local shown want l
  shown=$(printf '%s\n' "$1" | while IFS= read -r l; do [ -n "$l" ] && gate_menu_normalize "$l" && printf '\n'; done | LC_ALL=C sort -u)
  want=$(for l in $(gate_menu_labels); do printf '%s\n' "$l"; done | LC_ALL=C sort -u)
  [ "$shown" = "$want" ]
}

gate_menu_label_of() {
  # gate_menu_label_of <answer> — the gate label the answer's normal form equals,
  # or nothing when it equals none of them (free input).
  local norm l
  norm=$(gate_menu_normalize "$1")
  for l in $(gate_menu_labels); do
    [ "$norm" = "$l" ] && { printf '%s' "$l"; return 0; }
  done
  return 0
}

gate_close_settle() {
  # gate_close_settle <승인 id> — the three notification releases every
  # terminal disposition performs, in one place.
  #
  # THE SLOT GOES BACK ON EVERY TERMINAL, and the key is the approval id because
  # that is what the firing site (`cc_notify_fire answer "$q" "$id"`) wrote into
  # the stack. Deriving it differently here would leave the seat occupied by a
  # key nothing releases.
  #
  # AND THE BANNER COMES OFF THE SCREEN. An approval that was voided, refused or
  # granted is equally done being waited on, so leaving its notice up is the
  # state the address was added to end: in the morning the answered and the
  # unanswered look the same. The two calls are deliberately NOT one —
  # reclaiming a slot erases a line in a file and delivers nothing, while
  # clearing changes what is on a person's screen right now, so only the second
  # carries a seat guard, and that guard lives inside the verb.
  cc_notify_stack_release "$1" || true
  cc_notify_clear answer "$1" || true
  gate_notify_overflow_settled || true
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
  #
  # THE LADDER, TOP DOWN. Rung 1 holds on a torn transcript. Rung 2 is FRAME
  # APPROVAL — the line is the harness-written result of an `AskUserQuestion`
  # whose question carried the id, joined by `tool_use_id`, and holds an
  # `answers` map — and inside it 2a refuses a menu that is not the gate's, 2b
  # closes on a label that equals one of the gate's by whole-string comparison,
  # and 2c holds on an answer that equals none (free input) or on a slot the
  # frame does not carry. Rung 3 names an ineligible frame (an `is_error`
  # result, another tool's result, a parse failure) and holds. Rung 4 is the
  # diagnostic: a line carries the id and is none of the above — the router's
  # own ledger read, typically — and NOTHING IS WRITTEN. Judgment approvals run
  # every rung; act and boundary approvals have no menu and no label set, so
  # they run 1, the frame approval of 2, 3 and 4 and never 2a/2b/2c.
  #
  # NO RAW-LINE FALLBACK AND NO PROSE SCAN. The fallback's whole observed record
  # was zero true positives and four false ones — a transport frame recorded as
  # the answer — and the polarity vocabulary was the ledger's own words (`승인`
  # is a series name), so it either missed real answers or read the ledger as
  # consent. An unknown shape is named and held; an unknown shape that is
  # guessed at produces an authorization nobody gave.
  local id="$1" void="${2:-0}" reject="${3:-0}" row state q cutp anchor afull adig aex label tok
  # `|| true` on every match: a `grep` that finds nothing exits 1, `pipefail`
  # promotes it, and `set -e` then kills the verb with status 1 and NO message —
  # which reads exactly like a refusal and is not one.
  row=$(gate_approval_last_row "$id")
  [ -n "$row" ] || die "그런 승인 id 가 원장에 없습니다: $id"
  state=$(gate_row_field "$row" '상태')
  # `철회` IS THE ONE NON-`대기` STATE A LATER ANSWER MAY STILL CLOSE. A withdrawn
  # approval is one whose raising condition went away — no clock, no answer —
  # and a person answering it afterwards is answering a real question; refusing
  # that answer would make the withdrawal decide for them.
  case "$state" in
    대기|철회) ;;
    *) die "승인 '$id' 은 이미 '$state' 입니다 — 해소된 승인은 다시 닫지 않습니다" ;;
  esac
  q=$(gate_row_field "$row" '질문 문면')
  cutp=$(gate_row_field "$row" '절단점')
  anchor=$(gate_approval_sidecar_anchor "$id")

  if [ -z "$(gate_transcript_files || true)" ]; then
    warn "트랜스크립트를 찾지 못해 승인을 닫을 수 없습니다 — 라우터가 타이핑한 답은 받지 않습니다"
    exit "$GATE_EXIT_APPROVAL"
  fi

  # ---- rung 1
  if gate_transcript_torn; then
    warn "트랜스크립트의 마지막 줄이 완결되지 않았습니다 — 판정 보류, 다음 판정에서 다시 봅니다"
    exit "$GATE_EXIT_APPROVAL"
  fi

  gate_frame_candidate "$id" || true
  case "$GATE_FRAME_KIND" in
    none)
      warn "트랜스크립트에 이 승인의 응답 프레임이 없습니다 — 대기 상태를 유지합니다"
      exit "$GATE_EXIT_APPROVAL" ;;
    asked)
      warn "승인 $id 의 질문은 물어졌으나 응답 프레임이 아직 없습니다 — 대기 상태를 유지합니다"
      exit "$GATE_EXIT_APPROVAL" ;;
    other)
      # ---- rung 4: a candidate, and not a frame of any kind this ladder knows.
      gate_frame_parse "$GATE_FRAME_FILE" "$GATE_FRAME_LINE" "$id"
      warn "승인 $id 를 담은 줄은 있으나 답 프레임이 아닙니다 (관측 프레임: type=${GATE_FRAME_TYPE:-미상} tool=${GATE_FRAME_TOOL:-없음}) — 원장에 아무것도 쓰지 않고 대기로 둡니다"
      exit "$GATE_EXIT_APPROVAL" ;;
  esac

  # ---- rung 2 / rung 3: frame approval
  gate_frame_parse "$GATE_FRAME_FILE" "$GATE_FRAME_LINE" "$id"
  if [ "$GATE_FRAME_ERR" = "1" ]; then
    # Two warnings for two opposite facts. The harness's dismissal text means a
    # person was at the screen and closed the dialog without choosing; any
    # other `is_error` says only that the call collapsed, cause unobserved.
    case "$GATE_FRAME_ERRTEXT" in
      *"$GATE_DISMISSAL_TEXT"*)
        warn "승인 $id 의 질문 다이얼로그가 취소됐습니다 (다이얼로그 취소 — 사람이 답 없이 닫음) — 대기로 둡니다" ;;
      *)
        warn "승인 $id 의 질문 호출이 실패했습니다 (is_error, 원인 미관측) — 대기로 둡니다" ;;
    esac
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ "$GATE_FRAME_KIND" = "result" ]; then
    warn "승인 $id 의 응답 프레임에 answers 맵이 없습니다 (프레임 부적격) — 대기로 둡니다"
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ -z "$GATE_FRAME_TID" ] || [ "$GATE_FRAME_TYPE" != "user" ]; then
    warn "승인 $id 의 결속 후보를 tool_result 프레임으로 읽지 못했습니다 (파싱 실패, type=${GATE_FRAME_TYPE:-미상}) — 대기로 둡니다"
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ "$GATE_FRAME_TOOL" != "AskUserQuestion" ]; then
    warn "승인 $id 의 결속 후보는 AskUserQuestion 이 아닌 도구의 결과입니다 (tool=${GATE_FRAME_TOOL:-미상}) — 프레임 부적격, 대기로 둡니다"
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ "$GATE_FRAME_HASANS" != "1" ]; then
    warn "승인 $id 의 결속 후보에 toolUseResult.answers 객체가 없습니다 (파싱 실패) — 대기로 둡니다"
    exit "$GATE_EXIT_APPROVAL"
  fi
  tok="$GATE_FRAME_TID"

  if [ "$cutp" != "판단" ]; then
    # ---- act and boundary approvals: the frame decides, the closer's flag is
    # the disposition. There is no menu to compare and no label set to read, so
    # `--void` and `--reject` remain the closer's word; what changed is that the
    # frame must be a real answer to THIS id, and the answer's bytes are kept.
    if [ -z "$GATE_FRAME_KEY" ] || [ "$GATE_FRAME_HASKEY" != "1" ]; then
      warn "승인 $id 의 답 프레임에 그 id 를 담은 질문 슬롯의 엔트리가 없습니다 — 원장에 아무것도 쓰지 않고 대기로 둡니다"
      exit "$GATE_EXIT_APPROVAL"
    fi
    afull="$GATE_FRAME_ANSWER"
    adig=$(printf '%s' "$afull" | shasum -a 256 | cut -d' ' -f1)
    gate_approval_sidecar_write "$id" answer '답변' "$afull" \
      || warn "승인 사이드카에 답변 전문을 쓰지 못했습니다 — 행은 종결되나 앵커 $anchor 의 답변 구간이 비어 있습니다"
    if [ "$void" = "1" ]; then
      gate_append '승인' "승인 id=$id" "상태=무효" "질문 문면=$q" \
        "답변 문면=트랜스크립트 판독(무효)" "해소 시각=$(now_iso)" \
        "응답 토큰=$tok" "답변 다이제스트=$adig" "사이드카 앵커=$anchor"
      gate_close_settle "$id"
      log "승인 무효 — $id (행위는 수행되지 않습니다)"
      return 0
    fi
    if [ "$reject" = "1" ]; then
      gate_append '승인' "승인 id=$id" "상태=거부" "질문 문면=$q" \
        "답변 문면=트랜스크립트 판독" "해소 시각=$(now_iso)" \
        "응답 토큰=$tok" "답변 다이제스트=$adig" "사이드카 앵커=$anchor"
      gate_close_settle "$id"
      log "승인 거부 — $id (물었고 답이 아니오입니다)"
      return 0
    fi
    gate_append '승인' "승인 id=$id" "상태=승인" "질문 문면=$q" \
      "답변 문면=트랜스크립트 판독" "해소 시각=$(now_iso)" \
      "응답 토큰=$tok" "답변 다이제스트=$adig" "사이드카 앵커=$anchor"
    gate_close_settle "$id"
    log "승인 해소 — $id"
    return 0
  fi

  # ---- judgment approvals: 2a, 2b, 2c
  if [ -n "$GATE_FRAME_KEY" ] && [ "$GATE_FRAME_HASKEY" = "1" ]; then
    # 2a — the menu the person saw must be the gate's. Compared BEFORE the
    # answer is read: a menu that is not the gate's makes every label on it a
    # label the gate did not define, and an answer chosen from it is not a
    # choice among the gate's dispositions whatever it happens to spell.
    if ! gate_menu_matches "$GATE_FRAME_LABELS"; then
      warn "승인 $id 의 메뉴가 게이트의 선택지 집합과 다릅니다 (본 것: $(printf '%s' "$GATE_FRAME_LABELS" | tr '\n' '/') · 게이트: $(gate_menu_labels | tr ' ' '/')) — 라우터는 prompt 동사가 낸 라벨을 축자로 렌더해야 합니다. 대기로 둡니다"
      exit "$GATE_EXIT_RULE"
    fi
    afull="$GATE_FRAME_ANSWER"
    label=$(gate_menu_label_of "$afull")
  else
    afull=""; label=""
  fi

  if [ -n "$label" ]; then
    # 2b — whole-string equality against the gate's labels, on the normal form
    # (recommendation suffix removed). THE FLAGS MAY ONLY AGREE WITH THE ANSWER:
    # a closer naming `--void` over an answer of `승인` is proposing a
    # disposition against the person's words, and the person's words win.
    if [ "$void" = "1" ] && [ "$label" != "무효" ]; then
      warn "close --void 는 답과 어긋납니다 — 사람은 '$(gate_menu_normalize "$afull")' 을 골랐습니다. 플래그는 답과 동의만 할 수 있습니다"
      exit "$GATE_EXIT_RULE"
    fi
    if [ "$reject" = "1" ] && [ "$label" != "거부" ]; then
      warn "close --reject 는 답과 어긋납니다 — 사람은 '$(gate_menu_normalize "$afull")' 을 골랐습니다. 플래그는 답과 동의만 할 수 있습니다"
      exit "$GATE_EXIT_RULE"
    fi
    adig=$(printf '%s' "$afull" | shasum -a 256 | cut -d' ' -f1)
    aex=$(gate_row_safe "$afull" "$GATE_A_EXCERPT")
    gate_approval_sidecar_write "$id" answer '답변' "$afull" \
      || warn "승인 사이드카에 답변 전문을 쓰지 못했습니다 — 행은 종결되나 앵커 $anchor 의 답변 구간이 비어 있습니다"
    gate_append '승인' "승인 id=$id" "상태=$label" "질문 문면=$q" \
      "답변 문면=$aex" "해소 시각=$(now_iso)" \
      "응답 토큰=$tok" "답변 다이제스트=$adig" "사이드카 앵커=$anchor"
    gate_close_settle "$id"
    case "$label" in
      승인) log "승인 해소 — $id" ;;
      거부) log "승인 거부 — $id (물었고 답이 아니오입니다)" ;;
      무효) log "승인 무효 — $id (행위는 수행되지 않습니다)" ;;
    esac
    return 0
  fi

  # 2c — a real answer frame whose answer equals no label (free input), or a
  # frame that does not carry this approval's slot at all. `대기` STAYS, THE
  # ANSWER GOES TO THE SIDECAR ONLY, AND THE ROW GETS A REASON. The ledger row
  # must not carry the answer: `gate_approval_field` returns the last value a
  # key ever had, so an answer on a `대기` row would read to every later reader
  # as an answer with no mark of what it was. The person's words are not
  # discarded either — they are in the sidecar block the anchor names — and the
  # reason field is what the morning report reads to surface the approval as
  # "answered, disposition not derived" rather than "nobody answered". Exit 5
  # and not 0: 0 means resolved, and this approval is not.
  local reason
  if [ -n "$GATE_FRAME_KEY" ] && [ "$GATE_FRAME_HASKEY" = "1" ]; then reason='자유 입력'; else reason='슬롯 부재'; fi
  if [ "$(gate_row_field "$row" '처분 사유')" = "$reason" ] && [ "$(gate_row_field "$row" '응답 토큰')" = "$tok" ]; then
    warn "승인 $id 은 이미 이 답 프레임에 대해 '$reason' 으로 기록돼 있습니다 — 대기로 둡니다 (새 답이 오면 다시 봅니다)"
    exit "$GATE_EXIT_APPROVAL"
  fi
  if [ "$reason" = "자유 입력" ]; then
    if ! gate_approval_sidecar_write "$id" answer '답변' "$afull"; then
      warn "승인 $id 의 자유 입력 답을 사이드카에 쓰지 못했습니다 — 답을 버리지 않기 위해 원장에도 쓰지 않고 다음 판정에서 다시 봅니다"
      exit "$GATE_EXIT_APPROVAL"
    fi
    warn "승인 $id 의 답이 제시된 어느 라벨과도 같지 않습니다 (자유 입력, $(printf '%s' "$afull" | wc -c | tr -d ' ')바이트 — 사이드카 $anchor 에 기록) — 처분은 유도되지 않았고 대기로 둡니다"
  else
    warn "승인 $id 의 답 프레임에 그 id 를 담은 질문 슬롯이 없습니다 (슬롯 부재) — 처분은 유도되지 않았고 대기로 둡니다"
  fi
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=$(gate_row_field "$row" '대상')" "절단점=$cutp" \
    "막는 세그먼트=$(gate_row_field "$row" '막는 세그먼트')" "질문 문면=$q" \
    "처분 사유=$reason" "응답 토큰=$tok" "사이드카 앵커=$anchor" "관측 시각=$(now_iso)"
  exit "$GATE_EXIT_APPROVAL"
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

gate_done_disposition() {
  # gate_done_disposition <미충족 텍스트> — one of `충족`, `무효화`, `미충족`.
  #
  # Takes the ALREADY COMPUTED text rather than calling `gate_done_conditions`
  # again: three callers each want this verdict about the same evaluation, and a
  # second evaluation could disagree with the first because the ledger moved
  # between them.
  #
  # NEVER THE EMPTY STRING, on any path. The value is compared by equality at
  # every call site and one of those comparisons decides whether the run's `done`
  # file is written — an empty answer there reads as "not this branch" at each
  # arm in turn and falls out of the chain having decided nothing.
  #
  # The recognized values are used with POSITIVE equality by every caller that
  # ACCEPTS on them, so an unrecognized value and the empty string both land in
  # the refusing arm. That is what makes a token here as fail-closed as a
  # predicate would be, which was the one property the predicate form had over
  # this one.
  local unmet="$1" other
  [ -n "$unmet" ] || { printf '충족'; return 0; }
  # Condition 5's invalidation line is the one unmet cause that is permanent by
  # construction. A run left with only that is over — it may record its end, but
  # as invalidated rather than as satisfied.
  #
  # THE MATCH IS ANCHORED TO THE FIXED HEAD OF THAT LINE, not to the phrase
  # wherever it appears. Every condition interpolates free text — a segment's
  # status, an obligation's text, a blocked row's reason — and all of it lands
  # AFTER the line's fixed prose, never at the start. An unanchored substring
  # filter therefore let one router-typed value carrying the phrase delete a
  # genuine unmet cause from this verdict, and a run with conditions actually
  # outstanding recorded itself as invalidated and stopped. Anchoring makes the
  # only line this can drop the one the gate itself writes.
  other=$(printf '%s' "$unmet" | grep -v '^5 런 스코프 blocked 가 해소 불가입니다 ' || true)
  [ -n "$other" ] || { printf '무효화'; return 0; }
  printf '미충족'
}

gate_unmet_summary() {
  # gate_unmet_summary <미충족 텍스트> — the count and the condition numbers,
  # bounded by construction.
  #
  # The row this feeds has a 1024-byte cap and the full list grows with the run
  # — one line per non-terminal segment, one per unsettled clause — so joining
  # the text made a run with enough of them unable to record its own rejection.
  # The numbers cannot exceed ten distinct values, so this field cannot.
  local unmet="$1" n ids
  n=$(printf '%s\n' "$unmet" | grep -c . || true)
  ids=$(printf '%s\n' "$unmet" | sed -n 's/^\([0-9]\{1,2\}\) .*/\1/p' \
        | sort -un | tr '\n' ',' | sed 's/,$//')
  printf '미충족 %s건 · 조건 %s' "${n:-0}" "${ids:-미상}"
}

gate_unmet_numbers() {
  # gate_unmet_summary's numbers alone, deduplicated and ascending, one per line.
  # Carried separately from the capped text list because it is the half that
  # cannot be truncated: it answers "why can this run not end" in ten values at
  # most, while the text grows without bound and loses its tail exactly when the
  # night has been long enough for the tail to matter.
  printf '%s\n' "$1" | sed -n 's/^\([0-9]\{1,2\}\) .*/\1/p' | sort -un
}

gate_done_conditions() {
  # Prints one line per UNMET condition, numbered. Empty output means all TEN
  # hold. Never silently empty on an unreadable ledger — that is condition 4.
  #
  # Ten and not nine: condition 10 splits into two arms and both print `10`, so
  # the numbering runs 1..10 while the count of printable causes is larger.
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
  # gate_unfulfilled_review_obligations [segment]
  #
  # With no argument this is the run-wide list that termination condition 9
  # counts. With one it is narrowed to that segment, which is what the issuing
  # guard and the order predicate need — asked run-wide, they would let a
  # sibling segment's open obligation answer a question posed about this one,
  # and the answer would be wrong in the permissive direction for the issuer and
  # in the refusing direction for the predicate.
  local want="${1:-}" id st row seg
  for id in $(gate_rows '리뷰 의무' | tr '|' '\n' | sed -n 's/^ *의무 id=//p' | sed 's/[[:space:]]*$//' | sort -u); do
    [ -n "$id" ] || continue
    row=$( { gate_rows '리뷰 의무' | grep -F "의무 id=$id " || true; } | tail -1)
    st=$(gate_row_field "$row" '상태')
    [ "$st" = "미이행" ] || continue
    if [ -n "$want" ]; then
      seg=$(gate_row_field "$row" '세그먼트')
      [ "$seg" = "$want" ] || continue
    fi
    printf '%s\n' "$id"
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
    # THE FIELD SEPARATOR IS PART OF THE PATTERN, and without it this counts every
    # merge TWICE. The row now carries `유도 절단점=` beside `절단점=`, and an
    # unanchored substring matches inside the longer key — so one merge whose argv
    # derived `머지` would consume two of the target's terminal-act budget. Anchored
    # to ` | `, `| 유도 절단점=머지 ` cannot match, because the text immediately
    # before `절단점` there is `유도 ` and not `| `.
    #
    # `결정=(act|exec)` IS PART OF THE PATTERN FOR THE SECOND HALF OF THE SAME
    # COUNTING ERROR. An act that FAILS writes a `결정=결과` row carrying the
    # identical `절단점`, so one merge that could not reach its remote consumed
    # TWO of the target's terminal budget — and the budget is spent by acts
    # PERFORMED, under either verb `act` or `exec`, not by rows written about
    # them. A succeeding merge writes no result row, which is why this never
    # showed up until an argv that fails by construction (`gh pr merge` against
    # a local bare remote) was counted. The refusal and void rows the
    # propose-done path writes are excluded by the same token.
    #
    # BOTH VERBS, NOT ONE. The row above carries `결정=$verb`, and a stage session
    # performs every merge it makes as `exec` — the hook forces that verb on all
    # of its bash. Narrowed to `act` alone, a merge the stage pushed passed this
    # count untouched and a run past its cap could still propose its own end.
    n=$(gate_rows '자율 승인' | grep -F "대상=$a " | grep -E '\| 결정=(act|exec) \|' \
          | grep -cF '| 절단점=머지 ' || true)
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
# The router shift — the session cap, measured from here.
#
# Cost grows as N x (P + C) / 2, so a routing loop that never restarts pays for
# its whole history on every turn. The remedy is to end the routing session on a
# threshold and start a successor, and the reason it is measured HERE is that
# nobody else can: the router cannot read its own context (an estimate would be
# memory wearing a number), and the watcher refuses on charter — it resumes
# nothing, retries nothing and decides nothing. The gate already holds the three
# pieces this needs: it can tell a router from a stage, it knows where the
# transcripts are, and reading the tail of one costs milliseconds.
#
# THE SOFT CAP IS 300K BECAUSE MARGINAL RETURN COLLAPSES BELOW IT. Measured on
# the worst observed session at a 75K restart floor: 500K saves 46.5%, 300K
# saves 64.9%, 250K saves 68.8%. The step down to 300K buys 18.4 points; the next
# one buys 4.6 and takes the shift count from 28 to 36, and every shift pays for
# a successor re-finding its bearings.
#
# THE HARD CAP IS 1.5x THE SOFT ONE. Past the soft cap a shift still needs room
# to finish what it started — receive a dispatch result, write its handoff row —
# and at a median 926 tokens per turn that is roughly 162 turns of slack, which
# does not reach the 500K band where 39.1% of all cost sits.
#
# TURN COUNT IS A SECOND-ORDER TRIPWIRE AND NOT A SHIFT TRIGGER. Turns per shift
# spread 57..277, a 4.9x spread, which makes them a poor proxy for the quantity
# actually being capped. What the tripwire catches is a pathological low-cost
# loop — hundreds of turns adding almost nothing — and that is a failure of
# PROGRESS rather than of context, so it belongs to the stagnation boundary that
# already exists and not here.
#
# A SESSION CAP IS A ROUTING INSTRUCTION, NOT AN APPROVAL. Every one of B1..B4
# writes a `상태=대기` approval and stops the run until a person answers, so
# routing the cap through that machinery would end the night at the first
# threshold crossing. The one exception is the livelock guard below, and it is
# marked as one where it lives.
# ---------------------------------------------------------------------------
readonly SHIFT_SOFT_TOKENS=300000
readonly SHIFT_HARD_TOKENS=450000
readonly SHIFT_TURN_TRIPWIRE=400
readonly SHIFT_HANDOFF_CAP=3
readonly SHIFT_FLOOR_MAX=130000

# THE LAUNCHER'S OWN NON-ZERO, and it sits outside the gate's 2..7 refusal band on
# purpose: a hold is not a refusal, and borrowing a refusal code would make "the
# shift is waiting on a live stage" unreadable against "the gate said no". Zero is
# the one value it must not be — in this system zero means the successor ran to
# completion, and three different outcomes were reporting it.
readonly GATE_EXIT_SHIFT_HELD=10

gate_shift_launches() {
  # How many routing shifts this ledger has actually LAUNCHED: the count of
  # `교대 기동` rows, which `gate_launch_shift` writes immediately before it execs
  # the wrapper and in no other place.
  #
  # AN ATTEMPT IS NOT A LAUNCH, and counting the act's `자율 승인` row made the two
  # one thing. `gate_verb_act` appends that row BEFORE the dispatch, so it is on
  # the ledger even when the launcher turns back — held behind a live stage, or
  # stopped at the handoff floor — and both of those return having started
  # nothing. Every turned-back attempt therefore consumed an ordinal, and the
  # ordinal is what names `log/shift-<n>.json`: the file for that number was never
  # written by any run, so a morning reader following the scale landed on nothing.
  # Neither arm is exotic — the held one is the recovery `autopilot` prescribes.
  #
  # LAUNCHES AND NOT ENDINGS EITHER. The count of `handoff` rows stood here before
  # that, and it diverges the moment a shift dies before writing its own row.
  # Counting the launch directly is the only form that survives both.
  local n
  if [ -z "${LEDGER:-}" ] || [ ! -f "$LEDGER" ]; then printf '0'; return 0; fi
  n=$( { gate_rows '교대 기동' || true; } | gate_count)
  printf '%s' "${n:-0}"
}

gate_shift_number() {
  # The number of the shift that HOLDS THE ROUTING SEAT as this row is written.
  # `0` is the lead's own seat and the sidecar reserves it for a run whose
  # routing never left the lead, so a shard must never stamp it.
  #
  # A SHIFT READS ITS OWN MARKER. `CC_PIPELINE_SHIFT_ID` is `<run-id>#<n>` and the
  # launcher wrote that `<n>` from `gate_shift_launches`, so the number a shard
  # stamps is the number it was launched under — one expression carried across
  # the process boundary rather than re-derived on the far side of it. The count
  # of ENDED handoffs used to stand here, and it is a different quantity: shift 1
  # stamped `0` right up to its own handoff row, byte-identical to the value that
  # means routing never left the lead, and no reader could tell the two apart.
  #
  # AND THE ABSENCE OF THAT MARKER IS A SEAT, NOT A COUNT. This fell through to
  # `gate_shift_launches`, so from the first launch of the night onward every row
  # the LEAD wrote stamped the number of the shift then running — and `0`, the
  # value the sidecar reserves for "routing never left the lead", stopped being
  # written at all. The lead's rows became byte-identical to that shift's, which
  # is the same indistinguishability the paragraph above describes, arriving from
  # the other side.
  #
  # ONE EXPRESSION MUST NOT ANSWER TWO QUESTIONS. "How many shifts have been
  # launched" belongs to `gate_launch_shift`'s ordinal and nothing else; "who is
  # sitting in the routing seat as this row is written" is this function. Sharing
  # one expression between them is the root of the defect rather than a detail of
  # it, so the fallback here is the constant the seat is defined as.
  local n
  if [ -n "${CC_PIPELINE_SHIFT_ID:-}" ]; then
    n="${CC_PIPELINE_SHIFT_ID##*#}"
    case "$n" in ''|*[!0-9]*) n='' ;; esac
    if [ -n "$n" ]; then printf '%s' "$n"; return 0; fi
  fi
  printf '0'
}

gate_transcript_of_session() {
  # The transcript file for one session id, or nothing. Searched by NAME for the
  # same reason `gate_transcript_files` does: the directory is keyed by cwd and
  # shared with unrelated sessions.
  local sid="$1" dir f
  [ -n "$sid" ] || return 0
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [ -d "$dir" ] || return 0
  # Globbed rather than piped into an early-terminating reader. A reader that
  # stops at the first line kills the writer on its left, and under `pipefail`
  # that turns "found it" into a failed pipeline. The two patterns are the two
  # depths `-maxdepth 2` covered, and the first existing match still wins.
  for f in "$dir/$sid.jsonl" "$dir"/*/"$sid.jsonl"; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 0
}

gate_usage_scan() {
  # Reads a JSONL stream on stdin and prints "<첫 턴 총 컨텍스트> <마지막 턴 cache_read>".
  #
  # THE TWO ENDS ARE MEASURED DIFFERENTLY BECAUSE THEY ARE DIFFERENT QUANTITIES.
  # The current context is the last turn's `cache_read_input_tokens`: by then the
  # prefix is cached and the read is the whole of it. The FLOOR is the first
  # turn's read PLUS its creation — on a session's opening turn the cache
  # breakpoint has not been established, so most of the prefix is billed as
  # creation and the read component alone reports a floor several times too
  # small. Conflating the two is the error this file's own measurement history
  # records: a floor quoted at 21,736 was the read component of a turn whose
  # actual context was 116,055.
  awk '
    {
      r = 0; c = 0
      if (match($0, /"cache_read_input_tokens":[ ]*[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/[^0-9]*/, "", s); r = s + 0
      }
      if (match($0, /"cache_creation_input_tokens":[ ]*[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/[^0-9]*/, "", s); c = s + 0
      }
      if (r == 0 && c == 0) next
      if (first == 0) first = r + c
      last = r
    }
    END { printf "%d %d", first + 0, last + 0 }
  ' 2>/dev/null
}

gate_router_context() {
  # The routing session's context right now, in tokens, or `0`.
  #
  # THE CURRENT SESSION COMES FIRST AND THE LINEAGE IS THE FALLBACK, and the
  # order is not a preference. A shift is deliberately kept OUT of
  # `session-lineage` — that is what stops it answering its own approvals — so
  # lineage holds lead sessions only, and a shift asking lineage how big it is
  # would be handed the lead's number instead of its own.
  #
  # Bounded read. The tail is where the last turn is, and 256KB of it is many
  # records; on a 42MB transcript this costs milliseconds, which is what makes it
  # affordable on a path the gate takes often.
  local f v
  f=$(gate_transcript_of_session "${CLAUDE_CODE_SESSION_ID:-}")
  if [ -z "$f" ]; then
    f=$( { gate_transcript_files 2>/dev/null || true; } | tail -1)
  fi
  [ -n "$f" ] && [ -f "$f" ] || { printf '0'; return 0; }
  v=$(tail -c 262144 "$f" 2>/dev/null | gate_usage_scan | awk '{print $2}')
  case "${v:-}" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

gate_shift_floor() {
  # The context this routing session STARTED at — the price of having restarted.
  #
  # A shift is a new process and inherits no compaction summary, so its floor is
  # the static prefix plus the snapshot plus the handoff rows: measured at
  # 73K..77K, against 109K..118K for an automatic compaction whose floor carries
  # a 37K..49K summary inside it. The difference is part of what the mechanism
  # buys, and quoting the compaction floor here would erase it.
  local f v
  f=$(gate_transcript_of_session "${CLAUDE_CODE_SESSION_ID:-}")
  if [ -z "$f" ]; then
    f=$( { gate_transcript_files 2>/dev/null || true; } | tail -1)
  fi
  [ -n "$f" ] && [ -f "$f" ] || { printf '0'; return 0; }
  v=$(head -c 1048576 "$f" 2>/dev/null | gate_usage_scan | awk '{print $1}')
  case "${v:-}" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

gate_shift_state() {
  # The `shift` block of the snapshot, as a JSON object.
  local n ctx floor over
  n=$(gate_shift_number)
  ctx=$(gate_router_context)
  floor=$(gate_shift_floor)
  over=false
  [ "${ctx:-0}" -ge "$SHIFT_SOFT_TOKENS" ] && over=true
  printf '{"n": %s, "context": %s, "soft": %s, "hard": %s, "over_soft": %s, "floor": %s}' \
    "${n:-0}" "${ctx:-0}" "$SHIFT_SOFT_TOKENS" "$SHIFT_HARD_TOKENS" "$over" "${floor:-0}"
}

gate_snapshot_segments_json() {
  local out sid
  out=$( gate_segment_ids | while IFS= read -r sid; do
           [ -n "$sid" ] || continue
           printf '    {"id": "%s", "상태": "%s", "워크트리": "%s", "선행": "%s", "커밋": "%s", "마지막 스테이지": "%s"},\n' \
             "$(gate_json_escape "$sid")" \
             "$(gate_json_escape "$(gate_segment_field "$sid" '상태')")" \
             "$(gate_json_escape "$(gate_segment_field "$sid" '워크트리')")" \
             "$(gate_json_escape "$(gate_segment_field "$sid" '선행')")" \
             "$(gate_json_escape "$(gate_segment_field "$sid" '커밋')")" \
             "$(gate_json_escape "$(gate_row_field "$( { gate_rows 'stage-result' | grep -F "세그먼트=$sid " || true; } | tail -1)" '스테이지')")"
         done )
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%,}"
}

gate_snapshot_blocked_json() {
  # Unresolved only, AND THE FOLD THAT DECIDES IT IS THE CANONICAL ONE. Resolution
  # in this ledger is an APPEND, not an edit: the closing row carries `원인=해소`
  # and the row it closes stays exactly where it is. Filtering the closing row out
  # therefore kept the block and dropped the evidence that it was gone — the
  # opposite of what this comment used to promise — and the successor has no
  # history to notice with, so a block somebody had already cleared sat in every
  # shard's input for the rest of the night.
  #
  # `cc_unresolved_blocked` takes the LAST row per `사유` and drops it when that
  # row resolves. Termination condition 5 and the status line already read it,
  # and its own header says it exists so those two read one rule rather than two
  # copies of it; this projector was a third copy and the only wrong one.
  #
  # RUN SCOPE, because that is the span the canonical fold covers. Narrowing here
  # is deliberate — a fourth private copy of the fold is precisely the defect.
  local out reason row
  out=$( { cc_unresolved_blocked "${LEDGER:-}" || true; } | cut -f2- \
         | tail -40 | while IFS= read -r reason; do
           [ -n "$reason" ] || continue
           row=$( { gate_rows 'blocked' | grep -F '스코프=run' \
                    | grep -F "사유=$reason " || true; } | tail -1)
           printf '    {"스코프": "run", "사유": "%s", "앵커": "%s"},\n' \
             "$(gate_json_escape "$reason")" \
             "$(gate_json_escape "$(gate_row_field "$row" '앵커 세그먼트')")"
         done )
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%,}"
}

gate_snapshot_cycles_json() {
  local out row
  out=$( { gate_rows 'cycle' || true; } | tail -20 | while IFS= read -r row; do
           [ -n "$row" ] || continue
           printf '    {"세그먼트": "%s", "사이클": "%s", "P0": "%s", "P1": "%s"},\n' \
             "$(gate_json_escape "$(gate_row_field "$row" '세그먼트')")" \
             "$(gate_json_escape "$(gate_row_field "$row" '사이클')")" \
             "$(gate_json_escape "$(gate_row_field "$row" 'P0')")" \
             "$(gate_json_escape "$(gate_row_field "$row" 'P1')")"
         done )
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%,}"
}

gate_snapshot_handoff_json() {
  # The last `SHIFT_HANDOFF_CAP` handoffs and no more. The whole series would
  # grow without bound across a night, and an unbounded resume payload spends on
  # the successor's first turn exactly what the shift exists to save.
  local out row
  out=$( { gate_rows 'handoff' || true; } | tail -"$SHIFT_HANDOFF_CAP" | while IFS= read -r row; do
           [ -n "$row" ] || continue
           printf '    {"교대": "%s", "버린 선택지": "%s", "막힌 지점": "%s", "다음 후보": "%s"},\n' \
             "$(gate_json_escape "$(gate_row_field "$row" '교대')")" \
             "$(gate_json_escape "$(gate_row_field "$row" '버린 선택지')")" \
             "$(gate_json_escape "$(gate_row_field "$row" '막힌 지점')")" \
             "$(gate_json_escape "$(gate_row_field "$row" '다음 후보')")"
         done )
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%,}"
}

gate_launch_shift() {
  # gate_launch_shift <alias> <사유> <cli args...>
  #
  # The successor routing session. It runs under the `shift` settings variant,
  # which is narrower than any stage's, and it is NOT recorded in
  # `session-lineage` — see the marker's own comment at the entry point.
  local alias="$1" reason="$2"; shift 2
  local wrapper="$GATE_DIR/stage-wrapper.sh"
  [ -f "$wrapper" ] || { warn "스테이지 래퍼가 없습니다: $wrapper"; return 127; }
  [ -n "${CLI_BIN:-}" ] || { warn "게이트가 CLI 바이너리를 해소하지 못했습니다"; return 127; }

  case "$reason" in
    상한|승인|종단|중단) : ;;
    *) warn "교대 사유가 어휘 밖입니다: ${reason:-없음} — 상한 승인 종단 중단"
       return "$GATE_EXIT_VOCAB" ;;
  esac

  # THE SUPPRESSOR, AND ITS RANGE IS `상한` ALONE.
  #
  # A live stage is the router's child: end the routing session while it runs and
  # the stage is orphaned. So a shift waits — and waiting costs nothing, because
  # the router's context barely grows while a stage works, which is precisely why
  # the stagnation boundary already declines to call such a run stalled.
  #
  # IT MUST NOT REACH `승인` OR `종단`. A shift that received exit 5 ends so the
  # LEAD can answer; holding it behind a live stage means the approval waits out
  # that stage, and overnight that is the whole night. The same applies at the
  # hard cap. The three ending reasons and this suppressor have opposite
  # polarity — those END a shift, this one keeps it from ending — so they are not
  # one list and must not be given one condition.
  if [ "$reason" = "상한" ] && [ "$(gate_live_stages)" != "0" ]; then
    printf '교대 보류: 살아 있는 스테이지가 있습니다 — 상한 교대는 스테이지 종단 뒤에 다시 시도하세요\n'
    log "상한 교대 보류 — 살아 있는 스테이지"
    return "$GATE_EXIT_SHIFT_HELD"
  fi

  # THE LIVELOCK GUARD, AND IT IS THE ONE PLACE A CAP BECOMES AN APPROVAL.
  #
  # If the handoff floor grows with every shift the design inverts: simulated on
  # the measured trajectory, a floor fixed at 75K saves 64.9% over 28 shifts,
  # while one growing 8K per shift costs 1083% more than doing nothing and
  # livelocks at 2,613 shifts. Handing the whole ledger to the successor is the
  # most natural way to build exactly that shape.
  #
  # 130,000 IS CHOSEN AGAINST THRASHING, NOT AGAINST ECONOMICS. The break-even
  # moved 34% in a single round of re-derivation, and a guard hung on a number
  # that moves like that is a guard on nothing. At a 150K floor the shift count
  # goes 28 → 42 and turns per shift 151 → 96: handoff is already half the work,
  # well before break-even. 130,000 sits before that degradation shows, and the
  # derivation does not depend on the break-even assumption at all.
  #
  # AND THE RESPONSE IS AN APPROVAL RATHER THAN A SHIFT. A floor near a third of
  # the cap is not a state routing can fix, so neither trimming the floor nor
  # warning and continuing is right. THIS IS THE SOLE EXCEPTION TO "a session cap
  # is a routing instruction, not an approval" — written here because an
  # implementer following that rule would otherwise decline to raise one.
  # AND IT MEASURES THE OUTGOING SHIFT, NOT THE PROCESS DOING THE LAUNCHING.
  #
  # `gate_shift_floor` reads the transcript of the session RUNNING THIS CODE. When
  # the lead calls it that is the lead's opening context — a constant that does
  # not move all night, and not the growing quantity the paragraph above is about
  # at all. It failed in both directions: below the cap the guard never spoke, and
  # above it the FIRST launch of the night issued an approval and returned with no
  # successor, leaving the run without a routing seat.
  #
  # A SHIFT calling this IS the predecessor being replaced, so its own opening
  # context is the handoff floor that grows shift to shift. The lead is not
  # measured: a floor that does not exist yet cannot be compared, and a guard that
  # measures nothing beats one that measures the wrong process.
  local floor=0
  if [ -n "${CC_PIPELINE_SHIFT_ID:-}" ]; then
    floor=$(gate_shift_floor)
  fi
  if [ "${floor:-0}" -gt "$SHIFT_FLOOR_MAX" ]; then
    # Bound to the progress digest, as before this argument existed: the floor
    # itself grows shift to shift, and salting with it would mint one approval
    # per launch attempt for a single condition.
    gate_issue_boundary_approval SHIFT-FLOOR \
      "인수인계 바닥이 ${floor} 토큰으로 상한 ${SHIFT_FLOOR_MAX} 를 넘었습니다 — 교대가 일을 대신하고 있어 라우팅으로 풀리지 않습니다" \
      "$(gate_progress_digest)"
    warn "교대 중단: 인수인계 바닥 ${floor} > ${SHIFT_FLOOR_MAX} — 승인을 발행했습니다"
    # AN ISSUED APPROVAL REPORTS AS ONE. Every other approval site in this file
    # answers `GATE_EXIT_APPROVAL`, and the conversion that does it for the rule
    # path runs before the dispatch that reaches here — so a `return 0` handed the
    # caller the code meaning "the successor ran to completion" for a call that
    # started nothing at all. The duplicate-suppressed re-issue answers 5 too: the
    # approval is open either way, and only the first call would otherwise say so.
    return "$GATE_EXIT_APPROVAL"
  fi

  local plugin_dir n rc=0
  plugin_dir=$(cd "$(dirname "$GATE_DIR")" && pwd)
  # ONE EXPRESSION OWNS THE SCALE. `gate_shift_launches` counts the rows written
  # by launches that actually happened, and THIS launch has not written its own
  # yet — it is written a few lines below, past both early returns — so the
  # ordinal is that count plus one.
  #
  # The count used to include this act's own `자율 승인` row and was taken as the
  # ordinal directly. That put attempts and launches on one scale: the two early
  # returns above leave the act row behind and start nothing, so a held attempt
  # moved the scale and the number it consumed named a `log/shift-N.json` no run
  # ever wrote. Adding one to a count of ENDED handoffs, the form before that, put
  # the identifier a notch above the number the successor's own rows would carry.
  n=$(( $(gate_shift_launches) + 1 ))
  [ "${n:-0}" -ge 1 ] || n=1
  mkdir -p "$RUN_DIR/log"

  # AN EXPIRY TIMESTAMP AND NOT AN EMPTY MARKER. The watcher's after-stage arm
  # reads this file to keep from calling a shift "router silent after a stage
  # ended" — a misreading that writes a run-scope `blocked` row with cause
  # unknown, and an unresolved run-scope block is an input to the termination
  # condition, so the run cannot finish. But `RUN_DIR` is never pruned: written
  # as a bare marker and tested with `[ ! -f ]`, a shift that dies right after
  # its handoff leaves the file behind for the rest of the night and the safety
  # device becomes a silent hole. 300 seconds is the cold-start budget a first
  # run is expected to measure against.
  printf '%s\n' "$(( $(date +%s) + 300 ))" > "$RUN_DIR/shift.in-progress"

  # NO PID FILE, DELIBERATELY. A pid file is what makes a STAGE visible to the
  # watcher's liveness count, and a shift recorded there would read as a live
  # stage — which suppresses the very arms that exist to notice a router that
  # stopped. The expiry marker above is the shift's liveness token instead.
  # THE LAUNCH ROW, AND THE SCALE IS COUNTED FROM IT RATHER THAN FROM THE ACT.
  # It sits below both early returns and above the exec, so it exists exactly
  # when a successor was actually started. `gate_shift_launches` reads it.
  #
  # THE FIELD IS `서수`, NOT `교대`. `gate_append` stamps the routing SEAT on every
  # row unless the caller supplies `교대` itself, so spelling this field `교대`
  # would suppress that stamp on the one row whose whole purpose is to carry an
  # ordinal — and the two numbers are different quantities: the seat is who
  # launched this shift, the ordinal is which shift was launched.
  gate_append '교대 기동' "서수=$n" "사유=$reason" "대상=$alias" "기록 시각=$(now_iso)"
  log "교대 $n 시작 — 사유 $reason"
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CC_ORCH_BG_WAIT_CEILING_MS:-3600000}" \
  CC_CLAUDE_BIN="$CLI_BIN" \
  CC_PIPELINE_RUN_ID="$RUN_ID" \
  CC_PIPELINE_RUN_DIR="$RUN_DIR" \
  CC_PIPELINE_MANIFEST="$MANIFEST" \
  CC_PIPELINE_LEDGER="$LEDGER" \
  CC_PIPELINE_GRANT="$GRANT" \
  CC_PIPELINE_GATE="$GATE_DIR/gate.sh" \
  CC_PIPELINE_TARGET="$alias" \
  CC_PIPELINE_SHIFT_ID="$RUN_ID#$n" \
  bash "$wrapper" \
    --settings "$(gate_settings_file shift)" \
    --plugin-dir "$plugin_dir" \
    --session-id "$(session_uuid "shift" "$n")" \
    -- "$@" > "$RUN_DIR/log/shift-$n.json" 2> "$RUN_DIR/log/shift-$n.err" < /dev/null || rc=$?
  rm -f "$RUN_DIR/shift.in-progress"
  log "교대 $n 종료 (rc=$rc)"
  return "$rc"
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
  # Bound to the digest this predicate just compared — the value that, by
  # construction, has not moved for `n` judgments.
  gate_issue_boundary_approval B1 "진전 해시가 연속 ${n}회 판정 동안 불변입니다" "$h"
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
  # Bound to the open-obligation digest, which is what this predicate reads;
  # the progress digest can move under an unchanged obligation set.
  gate_issue_boundary_approval B2 "의무 집합이 연속 ${n}개 사이클 동안 진전 없이 그대로입니다" "$cur"
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
  # THE WINDOW KEY EXCLUDES THIS COUNTER'S OWN INPUT, and getting that wrong is
  # how the boundary was silently disarmed once already.
  #
  # `total` above is byte-for-byte the same pipeline as the vector's `acts=`
  # line, so if the window were keyed on the full progress digest the count
  # would sit inside its own hash input and BOTH branches would yield zero:
  # when `total` moves the digest moves, the baseline is reset to `total`, and
  # `n` is 0; when `total` does not move the baseline already equals it, and `n`
  # is 0 again. The boundary then cannot fire on any input at all. Measured on a
  # live run: baseline 72 against a budget of 40, and `n` was 0.
  #
  # That is the counter-inside-its-own-hash defect this file names in
  # `gate_progress_vector`'s preamble and keeps B1's counter in the run
  # directory to avoid. Spending budget is not the kind of progress that should
  # open a new window — if it were, no amount of spending could ever exhaust
  # one — so the key is the vector with that line removed.
  h=$(gate_progress_vector | grep -v '^acts=' | shasum -a 256 | cut -d' ' -f1)
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
  # Bound to the window key — the vector with `acts=` removed — because that is
  # the value that opens and closes the window this count lives in. Salting with
  # the full progress digest put the count inside the id: every act over budget
  # then minted a new approval, which is the run-cannot-finish loop above.
  gate_issue_boundary_approval B3 "마지막 진전 이후 읽기 초과 exec 가 ${n}회입니다" "$h"
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
  # B4 HAS NO BINDING VALUE OF ITS OWN YET. It holds one integer percentage and
  # one threshold; a bucket tier would need a bucket width, and no width can be
  # validated against a boundary that has never fired in the corpus. So the
  # shape changes with its siblings — the caller passes the value — and the
  # value stays today's progress digest until a width is decided. When it is,
  # this one argument changes and nothing else does.
  gate_issue_boundary_approval B4 "비용이 선언 천장의 ${pct}%% 입니다 (${spent}/${declared})" "$(gate_progress_digest)"
}

gate_issue_boundary_approval() {
  # gate_issue_boundary_approval <name> <question> <binding>
  #
  # A boundary approval has NO act, so it can fill neither an act digest nor an
  # argv digest. The cutpoint slot carries the literal `경계` and the binding
  # tuple is (boundary name, the binding value) — which is why the three
  # approval shapes share one series rather than needing three.
  #
  # THE BINDING VALUE IS THE CALLER'S, AND IT IS THE VALUE THE CALLER'S OWN
  # PREDICATE READ. This function used to salt every boundary's id with the
  # progress digest, while B2 decides on the open-obligation digest and B3 on
  # the window key with `acts=` removed — so two of the four were deduplicated
  # on a value their predicate never looks at, and the progress digest moving
  # underneath an unchanged obligation set minted a fresh id per evaluation
  # (measured: 27 distinct ids over 30 B2 cycles, 50 over 90 B3 acts). B1's
  # binding IS the progress digest, so for B1 this is the same equivalence
  # class as before; B4 passes the progress digest until its bucket width is
  # decided, so its shape changes here and its value does not.
  #
  # `RUN_ID` STAYS IN THE SALT. Without it the same condition in two runs shares
  # one id, and the suppression below then reaches across run boundaries.
  #
  # DUPLICATE SUPPRESSION IS "THE LAST ROW IS `대기`", NOT "ANY ROW EXISTS". The
  # existence test swallowed every recurrence after the first resolution for
  # good: a stagnation answered at 22:00 and recurring at 03:00 could never ask
  # again, because the id had a row. A resolved id re-opens with a fresh `대기`
  # row and the row sequence says what happened to it; an OPEN id is not
  # re-appended, which is the property the existence test was really for.
  local name="$1" q="$2" binding="$3" id
  id="${name}-$(printf '%s' "$RUN_ID$name$binding" | shasum -a 256 | cut -c1-8)"
  [ "$(gate_approval_state "$id")" = "대기" ] && return 0
  gate_approval_sidecar_write "$id" issue '질문' "$q" \
    || warn "승인 사이드카에 질문을 쓰지 못했습니다 — 행은 발행되나 앵커 $(gate_approval_sidecar_anchor "$id") 가 가리키는 블록이 없습니다"
  # `유도 절단점=-` FOR THE SAME REASON THE ACT DIGEST IS `-`. A boundary has no
  # act, so there is no argv to derive a rung from, and `경계` in the slot beside
  # it is not a rung at all. Taking the ambient `GATE_ACT_DERIVED` would attach
  # the argv of whatever act happened to trip the boundary to a row that is not
  # about that act.
  gate_append '승인' "승인 id=$id" "상태=대기" "대상=-" "절단점=경계" \
    "유도 절단점=-" \
    "행위 다이제스트=-" "구속 튜플=$name/$binding" "막는 세그먼트=-" \
    "질문 문면=$q" "답변 문면=-" "사이드카 앵커=$(gate_approval_sidecar_anchor "$id")" \
    "발행 시각=$(now_iso)" "해소 시각=-"
  # The boundary approvals are the slowest class this design has, by
  # construction: they are evaluated on every act, so one opened while a long
  # stage runs waits out that whole stage — and one of them carries a dollar
  # figure. That is a declared consequence of raising notices only on router
  # calls, not a defect, and it is written down here so it is not rediscovered
  # as one.
  gate_notify_approval "$id" "$q"
  warn "경계 $name 발동 — 승인 대기 $id: $q"
  gate_warn_canon_prompt "$id" "$q"
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
