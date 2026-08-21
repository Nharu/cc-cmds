#!/usr/bin/env bash
# Pin the load-bearing literals and fences of the `review-remediate` skill.
#
# The command consumes a review report exactly once, records a disposition per
# finding, and writes to public issue trackers. Six of its properties cannot
# survive as prose alone:
#
#   (i)   the fixed-constants block. The nesting invariant is what the numeric
#         budget clause demands be *machine-checkable*; prose is not grepped.
#   (ii)  the emitted `검증 시점` enum, narrowed by this producer to a single value.
#         Omitting the field defaults to a value that gates unconditionally, so
#         a dropped pin turns a semantic slip into a repo-wide block downstream.
#   (iii) the output H2 set. The consumer decides binding tier by exact section
#         identity, so a suffix silently drops a section out of that tier.
#   (iv)  the loop-machinery denylist. Each token must appear on exactly one
#         line — its own denylist entry — so deleting an entry fails the pin at
#         the same time as resurrection is fenced.
#   (v)   the spawn-zero fence. The three counted literals are declared inside a
#         marker region and asserted absent everywhere else; without excluding
#         the declaration the fence would break itself.
#   (vi)  the single-callsite fence, the boundary/candidate vocabulary ordering,
#         the budget-option compartment, and the routing compartment. Each is a
#         claim the design registered as a verification item; each is checked
#         against a named marker region because a whole-file search fires on
#         legitimate prose and then the check does not hold.
#
# Posture: if the skill is absent (not yet rolled out / incremental commit) the
# whole check is a silent skip so the script stays green; it activates once the
# skill exists. This matches `lint-verification-literals.sh`.
#
# Usage:
#   bash scripts/lint-review-remediate-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-review-remediate-pins.sh   # fixture test
#
# Exit codes:
#   0 — all pins intact (or skill absent → skip)
#   1 — at least one pin broken

set -euo pipefail

# ---- abort guard -------------------------------------------------------------
#
# This does not *catch* an abort — `set -e` still ends the run. What it adds is
# that the abort says WHICH LINE ended it and with what code. Without that line
# an unchecked non-zero exit leaves exit 1 and no stdout, which is byte-identical
# to a legitimate pin failure; the reader then "fixes" a pin that never ran. That
# is not hypothetical — a single unguarded pipeline in this file did exactly it,
# and the fixture aimed at the branch it killed was reported as passing.
#
# The distinguishing load is carried by the ABORT: marker string, NOT by a
# distinct exit code. Moving it to a code would change what every FAIL fixture
# exits with, and the runner's expectations rest on that staying 1.
#
# It covers the whole file rather than an enumerated set of pipelines, so a
# pipeline added later is covered on the day it is added.
#
# `set -E` is deliberately NOT set: with errtrace, command-substitution subshells
# inherit the trap and the same abort prints twice.
lint_abort_line=0
lint_abort_code=0
trap 'lint_abort_code=$?; lint_abort_line=$LINENO' ERR
lint_abort_report() {
  if (( lint_abort_line != 0 )); then
    printf 'ABORT: %s ended at line %s with exit %s before the pins finished — an unchecked non-zero exit, not a pin failure\n' \
      "${BASH_SOURCE[0]##*/}" "$lint_abort_line" "$lint_abort_code" >&2
  fi
}
trap lint_abort_report EXIT

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SKILL="$skills_root/review-remediate/SKILL.md"
TEMPLATE="$skills_root/review-remediate/references/output-template.md"

if [[ ! -f "$SKILL" ]]; then
  echo "SKIP: review-remediate/SKILL.md not found under $skills_root — skill not present"
  exit 0
fi

fail=0

# Checks that did NOT run, by name. A pass message that lists only what passed
# reads as full coverage even when a guard was skipped for want of its input, so
# the OK line carries this ledger too — a guard that speaks only when it fails is
# silent at exactly the two moments its input went missing.
NOT_RUN=()

# Body of a named marker region, exclusive of the marker lines themselves.
region_body() {
  awk -v b="$1" -v e="$2" '
    index($0, b) { s = 1; next }
    index($0, e) { s = 0 }
    s
  ' "$3"
}

# Everything OUTSIDE a named marker region, marker lines excluded.
region_outside() {
  awk -v b="$1" -v e="$2" '
    index($0, b) { s = 1; next }
    index($0, e) { s = 0; next }
    !s
  ' "$3"
}

require_region() {
  local begin="$1" end="$2" file="$3" label="$4"
  local nb ne
  nb=$(grep -cF -- "$begin" "$file" || true)
  ne=$(grep -cF -- "$end" "$file" || true)
  if [[ "$nb" != "1" || "$ne" != "1" ]]; then
    echo "FAIL: ${file#"$skills_root/"} — $label marker region must appear exactly once (begin=$nb end=$ne)" >&2
    fail=1
    NOT_RUN+=("$label compartment body")
    return 1
  fi
  return 0
}

# ---- (i) fixed constants ----------------------------------------------------

CONSTANTS=(
  'REMEDIATION_PASSES  = 2'
  'MAX_USER_QUESTIONS  = 10'
  'STRUCTURAL_CONFIRMS = 2'
  'PARSE_INTEGRITY_CONFIRMS = 1'
  'assert STRUCTURAL_CONFIRMS + PARSE_INTEGRITY_CONFIRMS <= MAX_USER_QUESTIONS'
  'BACKLOG_LABEL          = review-remediate'
  'BACKLOG_CAP_MULTIPLIER = 1'
  'EXPIRY_DAYS            = 30'
  'AUTOSTOP_WINDOW_MONTHS = 3'
  'AUTOSTOP_THRESHOLD     = 2'
)
for lit in "${CONSTANTS[@]}"; do
  if ! grep -Fq -- "$lit" "$SKILL"; then
    echo "FAIL: review-remediate/SKILL.md — constant pin missing: $lit" >&2
    fail=1
  fi
done

# A retired constant must not come back without meeting the numeric-budget clause.
if grep -Fq -- 'MAX_FORKS' "$SKILL"; then
  echo "FAIL: review-remediate/SKILL.md — MAX_FORKS was retired (fossil of a superseded shape); reintroducing it needs the nesting invariant rewritten" >&2
  fail=1
fi

# ---- (ii) the narrowed 검증 시점 enum ----------------------------------------

# Narrowed to `구현 후` alone. The only deterministic phase label this producer
# holds is a file path, so an item emitted as `구현 중(<착지>)` matches the
# consumer's value arm yet belongs to no phase — disclosed as out-of-scope on
# every invocation, never executed, and never surfaced as malformed either.
# Pinning the positive declaration (rather than forbidding the withdrawn form)
# keeps the region free to *discuss* why the second value went away, which is
# the entire rationale for the narrowing.
if require_region '<!-- RITEM-EMIT-BEGIN -->' '<!-- RITEM-EMIT-END -->' "$SKILL" 'R-item emit'; then
  ritem=$(region_body '<!-- RITEM-EMIT-BEGIN -->' '<!-- RITEM-EMIT-END -->' "$SKILL")
  if ! printf '%s\n' "$ritem" | grep -Fq -- '`구현 후`만'; then
    echo "FAIL: review-remediate/SKILL.md — R-item emit region must declare the closed enum verbatim: \`구현 후\`만" >&2
    fail=1
  fi
  # The refusal is pinned to the literal it refuses. A paraphrase ("the default")
  # is not checkable — the previous form of this check required exactly that
  # paraphrase, so the value being refused never had to appear at all.
  if ! printf '%s\n' "$ritem" | grep -Fq -- '`구현 전`을 거부한다'; then
    echo "FAIL: review-remediate/SKILL.md — R-item emit region must refuse the default value by naming it verbatim" >&2
    fail=1
  fi
fi

# ---- the six --dry-run suppression sites ------------------------------------
#
# Bound by NAME, not by count. A count-only pin is satisfied by five-for-five, so
# half the list can go unimplemented and still verify. Two of these six were
# declared in the frontmatter and never suppressed in the execution path, and a
# third appeared in neither list.
#
# DECLARED EXCEPTION to the "a pin cross-checks its consumer" rule that the other
# pins in this file follow: the consumer of the suppression list is this command's
# own execution path, so there is no external artifact to compare against. Writing
# the exception down here is what stops the next audit from re-raising it as the
# same defect.

SUPPRESS_SITES=(
  '이슈 생성'
  '라벨 생성'
  '이슈 자동 만료'
  '기존 이슈 코멘트'
  '산출물 저작'
  '판정 원장 기록'
)
if require_region '<!-- DRYRUN-SUPPRESS-BEGIN -->' '<!-- DRYRUN-SUPPRESS-END -->' "$SKILL" 'dry-run suppression'; then
  suppress=$(region_body '<!-- DRYRUN-SUPPRESS-BEGIN -->' '<!-- DRYRUN-SUPPRESS-END -->' "$SKILL")
  for lit in "${SUPPRESS_SITES[@]}"; do
    if ! printf '%s\n' "$suppress" | grep -Fq -- "$lit"; then
      echo "FAIL: review-remediate/SKILL.md — suppression site missing from the execution-semantics list: $lit" >&2
      fail=1
    fi
  done
  # The frontmatter quotes this list; it must not re-declare a shorter one.
  if ! grep -Fq -- '위 여섯 자리를 전부 건너뛴다' "$SKILL"; then
    echo "FAIL: review-remediate/SKILL.md — the Safety declaration must quote the execution-semantics list, not restate a shorter one" >&2
    fail=1
  fi
fi

# ---- consumer cross-check (repo-fixed path; absence is a failure) ------------
#
# Pinned to the repository path rather than to SKILLS_ROOT on purpose: a fixture
# tree does not carry the consumer, and resolving against the fixture would turn
# every fixture run into a silent skip — which is the very failure mode this
# check exists to close.

CONSUMER="$repo_root/plugins/cc-cmds/skills/implement/SKILL.md"
if [[ ! -f "$CONSUMER" ]]; then
  echo "FAIL: consumer not found at ${CONSUMER#"$repo_root/"} — the cross-check cannot hold and must not pass silently" >&2
  fail=1
else
  # (1) The consumer's value arm requires a non-empty parenthesised phase. If it
  #     ever loosens to a bare form this producer's narrowing is over-strict; if
  #     it disappears the narrowing is aimed at nothing.
  if ! grep -Fq -- '구현 중\(.+\)' "$CONSUMER"; then
    echo "FAIL: ${CONSUMER#"$repo_root/"} — consumer no longer pins a parenthesised 구현 중 value arm; the producer's narrowing is aimed at nothing" >&2
    fail=1
  fi
  # (2) Heading tiers: the consumer's enumeration must be CONTAINED IN the
  #     producer's heading set — one direction, not set equality. Four producer
  #     headings are deliberately outside both consumer enumerations (the
  #     consumer assigns them no tier), so equality yields four false failures
  #     and invites deleting healthy sections to satisfy the lint.
  if [[ -f "$TEMPLATE" ]]; then
    # The pipeline is guarded AND its result is asserted non-empty. Guarding
    # alone converts a loud abort into a silent pass: `grep` exits 1 when the
    # consumer's anchors stop matching, and an empty extraction makes `missing`
    # empty, which reads as "nothing missing" — the strongest possible pass
    # produced by the check having no input at all. Both halves land together;
    # with only the guard, the whole suite goes green and none of this file's
    # predicates fire.
    consumer_headings=$(
      awk '/^    - \*\*Binding\*\*/,/^    - `## 권장 구현 순서` is reference/' "$CONSUMER" \
        | grep -oE '`## [^`]+`' | tr -d '`' | sort -u || true
    )
    if [[ -z "$consumer_headings" ]]; then
      echo "FAIL: ${CONSUMER#"$repo_root/"} — tier-enumeration extraction produced an empty list; the range anchors no longer match" >&2
      echo "      anchors: '    - **Binding**' … '    - \`## 권장 구현 순서\` is reference'" >&2
      fail=1
    else
      missing=$(
        while IFS= read -r h; do
          grep -Fqx -- "$h" "$TEMPLATE" || printf '%s\n' "$h"
        done <<< "$consumer_headings"
      )
      if [[ -n "$missing" ]]; then
        echo "FAIL: consumer tier enumeration is not contained in the producer heading set; missing from the template:" >&2
        # Quoted read loop — an unquoted expansion word-splits a heading that
        # contains spaces, printing one heading as several lines.
        while IFS= read -r h; do printf '  %s\n' "$h" >&2; done <<< "$missing"
        fail=1
      fi
    fi
  else
    NOT_RUN+=("tier containment (no output template)")
  fi
fi

# ---- (iii) the output H2 set -------------------------------------------------

H2=(
  '## 개요'
  '## 재현·근본원인'
  '## 합의된 아키텍처'
  '## 주요 결정사항과 근거'
  '## 검증 기록'
  '## 미해결 이슈 / 트레이드오프'
  '## 구현 시 검증 항목'
  '## 판정 원장'
  '## 이월 이슈'
  '## 권장 구현 순서'
  '## 잔여 공개'
)
if [[ -f "$TEMPLATE" ]]; then
  for lit in "${H2[@]}"; do
    if ! grep -Fqx -- "$lit" "$TEMPLATE"; then
      echo "FAIL: review-remediate/references/output-template.md — H2 pin missing (bare exact line): $lit" >&2
      fail=1
    fi
  done
  # A suffixed heading is the observed failure this pin exists to catch.
  if grep -Eq '^## (개요|재현·근본원인|합의된 아키텍처|주요 결정사항과 근거|검증 기록|구현 시 검증 항목|판정 원장|이월 이슈|권장 구현 순서|잔여 공개) .' "$TEMPLATE"; then
    echo "FAIL: review-remediate/references/output-template.md — suffixed H2 present; the consumer decides tier by exact section identity" >&2
    fail=1
  fi
else
  echo "FAIL: review-remediate/references/output-template.md missing — the H2 set has no pinned home" >&2
  fail=1
fi

# ---- (iv) loop-machinery denylist -------------------------------------------

FORBIDDEN=(
  'consecutive_clean' 'consecutive_no_major' 'converged' 'convergence_round'
  'stability_count' 'no_new_findings' 'outer_iter' 'inner_round' 'cycle_count'
  'outer_log.md' 'iteration_log.md' 'pending_applies.md' 'carryover.md'
  'ack_items.md' 'COUNT_APPLIED' 'escalate_applied' 'INNER_EXIT_REASON'
  'INNER_TEMP_DIR'
)
for lit in "${FORBIDDEN[@]}"; do
  n=$(grep -Fc -- "$lit" "$SKILL" || true)
  if [[ "$n" != "1" ]]; then
    echo "FAIL: review-remediate/SKILL.md — denylist token must occur on exactly 1 line (its own entry), found $n: $lit" >&2
    fail=1
  fi
done
if [[ -d "$skills_root/review-remediate/references" ]]; then
  while IFS= read -r ref; do
    for lit in "${FORBIDDEN[@]}"; do
      if grep -Fq -- "$lit" "$ref"; then
        echo "FAIL: ${ref#"$skills_root/"} — loop-machinery token present: $lit" >&2
        fail=1
      fi
    done
  done < <(find "$skills_root/review-remediate/references" -type f -name '*.md' | sort)
else
  NOT_RUN+=("references sweep (no references directory)")
fi

# ---- (v) spawn-zero fence ----------------------------------------------------

SPAWN_LITERALS=('Agent(' 'subagent_type' 'SendMessage')
if require_region '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL" 'spawn denylist'; then
  decl=$(region_body '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL")
  outside=$(region_outside '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL")
  for lit in "${SPAWN_LITERALS[@]}"; do
    if ! printf '%s\n' "$decl" | grep -Fq -- "$lit"; then
      echo "FAIL: review-remediate/SKILL.md — spawn-deny region must name the counted literal: $lit" >&2
      fail=1
    fi
    if printf '%s\n' "$outside" | grep -Fq -- "$lit"; then
      echo "FAIL: review-remediate/SKILL.md — spawn literal outside its declaration region: $lit" >&2
      fail=1
    fi
  done
fi

# ---- (vi) the four compartment fences ---------------------------------------

# Single call site — the question tool's name appears only inside its compartment.
if require_region '<!-- AUQ-CALLSITE-BEGIN -->' '<!-- AUQ-CALLSITE-END -->' "$SKILL" 'AUQ callsite'; then
  n=$(region_outside '<!-- AUQ-CALLSITE-BEGIN -->' '<!-- AUQ-CALLSITE-END -->' "$SKILL" | grep -cE 'AskUserQuestion' || true)
  if [[ "$n" != "0" ]]; then
    echo "FAIL: review-remediate/SKILL.md — question-tool name occurs $n time(s) outside the single-callsite compartment" >&2
    fail=1
  fi
fi

# Boundary ⊊ candidate — equal vocabularies make the section guard identically false.
if require_region '<!-- VOCAB-BEGIN -->' '<!-- VOCAB-END -->' "$SKILL" 'vocabulary'; then
  vocab=$(region_body '<!-- VOCAB-BEGIN -->' '<!-- VOCAB-END -->' "$SKILL")
  b_line=$(printf '%s\n' "$vocab" | grep -E '^B \(경계\) *=' || true)
  c_line=$(printf '%s\n' "$vocab" | grep -E '^C \(후보\) *=' || true)
  if [[ -z "$b_line" || -z "$c_line" ]]; then
    echo "FAIL: review-remediate/SKILL.md — vocabulary region must define both B (경계) and C (후보) on their own lines" >&2
    fail=1
  else
    # C must name B (superset) and must add at least one member beyond it.
    if ! printf '%s\n' "$c_line" | grep -Fq 'B ∪'; then
      echo "FAIL: review-remediate/SKILL.md — C must be written as a superset of B (B ∪ …)" >&2
      fail=1
    fi
    # `grep` exits 1 when it matches nothing, which under `set -euo pipefail`
    # ends the whole script — and the branch below is precisely the one that
    # fires when there is nothing to match. So the check could never report:
    # the script died first, the runner saw only an exit code, and the fixture
    # that targets this case was reported as passing for the wrong reason.
    # Every adjacent site here is already guarded; this was the only one that
    # was not. Protecting the pipe is half the repair — the branch it killed
    # has to come back with it, or the guard is restored around dead code.
    # Count ELEMENTS, not separators, and scope to the brace body first.
    # A separator count conflates the two cases it has to tell apart: a
    # one-element complement and an empty one both yield zero separators, so
    # the one-element form — a legitimate proper superset — is rejected while
    # the empty form is the only thing this branch exists to catch. Lowering the
    # threshold instead would accept the empty form; the predicate itself is
    # what is wrong, so this is a correction and not a restoration.
    c_body=${c_line#*\{}
    c_body=${c_body%\}*}
    extra=$(printf '%s\n' "$c_body" | tr '·' '\n' | LC_ALL=C awk 'NF{n++} END{print n+0}')
    if [[ "${extra:-0}" -lt 1 ]]; then
      echo "FAIL: review-remediate/SKILL.md — C \\ B is empty; the section guard becomes identically false" >&2
      fail=1
    fi
  fi
  if ! printf '%s\n' "$vocab" | grep -Fq 'assert B ⊊ C'; then
    echo "FAIL: review-remediate/SKILL.md — vocabulary region must carry the proper-subset assertion" >&2
    fail=1
  fi
fi

# Budget options — the issue-externalisation arm must be unreachable from the top band.
if require_region '<!-- BUDGET-OPTIONS-BEGIN -->' '<!-- BUDGET-OPTIONS-END -->' "$SKILL" 'budget options'; then
  n=$(region_body '<!-- BUDGET-OPTIONS-BEGIN -->' '<!-- BUDGET-OPTIONS-END -->' "$SKILL" | grep -cE 'P0' || true)
  if [[ "$n" != "0" ]]; then
    echo "FAIL: review-remediate/SKILL.md — top-band token occurs $n time(s) inside the budget-option compartment" >&2
    fail=1
  fi
fi

# Routing — exactly one destination signal, and no second-signal literals anywhere.
if require_region '<!-- ROUTING-BEGIN -->' '<!-- ROUTING-END -->' "$SKILL" 'routing'; then
  n=$(region_outside '<!-- ROUTING-BEGIN -->' '<!-- ROUTING-END -->' "$SKILL" | grep -cE 'github\.com' || true)
  if [[ "$n" != "0" ]]; then
    echo "FAIL: review-remediate/SKILL.md — destination literal occurs $n time(s) outside the routing compartment" >&2
    fail=1
  fi
fi
# Invocation pin — the command line the two awk scripts are run with, and the
# two literals whose loss is what the pin exists to prevent. This compartment was
# declared with no check claiming it; the derived marker-region ledger below is
# what surfaced that, and this is the check it was missing.
INVOCATION_PINS=(
  'LC_ALL=C awk -f parse-review-report.awk'
  'LC_ALL=C awk -f row-key.awk'
  # Both failure modes, named. The loud one is self-announcing; the silent one is
  # not, and a reader who sees no error concludes the locale was fine. Dropping
  # the silent arm is the loss this pin refuses.
  '정규식이 컴파일되지 않거나(요란)'
  '발견이 전량 사라진다(조용)'
  # The join operand. Written as records rather than FIND records, the arm
  # describes an equality that never holds, and following the prose stops every
  # healthy run. It has drifted back to the wrong operand once already.
  '테이프 **FIND** 레코드 수 ≠ 발행된 키 수'
)
if require_region '<!-- INVOCATION-PIN-BEGIN -->' '<!-- INVOCATION-PIN-END -->' "$SKILL" 'invocation pin'; then
  invocation=$(region_body '<!-- INVOCATION-PIN-BEGIN -->' '<!-- INVOCATION-PIN-END -->' "$SKILL")
  for lit in "${INVOCATION_PINS[@]}"; do
    if ! printf '%s\n' "$invocation" | grep -Fq -- "$lit"; then
      echo "FAIL: review-remediate/SKILL.md — invocation-pin compartment must carry the literal: $lit" >&2
      fail=1
    fi
  done
fi
# The byte-mode discipline is per-command, never exported: an exported locale is
# lost by any subshell that resets the environment, and the loss is the silent
# failure mode above.
if grep -Eq '^[[:space:]]*export[[:space:]]+LC_ALL' "$SKILL"; then
  echo "FAIL: review-remediate/SKILL.md — LC_ALL is exported; the byte-mode pin requires it on the command line" >&2
  fail=1
fi

ROUTING_SIGNALS=('remote get-url' '.git/config')
for lit in "${ROUTING_SIGNALS[@]}"; do
  if grep -Fq -- "$lit" "$SKILL"; then
    echo "FAIL: review-remediate/SKILL.md — second routing signal present: $lit" >&2
    fail=1
  fi
done

# ---- the four disposition-reason tokens (exactly four, no fifth) -------------

REASONS=(
  '보류 불가(상한)'
  '보류 불가(상한 미도출)'
  '보류 불가(트래커 없음)'
  '보류 불가(트래커 도달 불가)'
)
for lit in "${REASONS[@]}"; do
  if ! grep -Fq -- "$lit" "$SKILL"; then
    echo "FAIL: review-remediate/SKILL.md — drain reason token missing: $lit" >&2
    fail=1
  fi
done

# ---- subsumption guard -------------------------------------------------------
#
# Within one pin list, no element may be a substring of another. A subsumed
# element can never fail on its own: every occurrence of the shorter literal is
# already an occurrence of the longer one, so deleting the shorter pin's subject
# from the skill still satisfies the shorter pin. The pin looks present and
# checks nothing.
#
# It does not merely refuse the subsumption — it names BOTH literals and the list
# they belong to. Seven lists go through one loop, so a bare "subsumption found"
# would leave the reader to re-derive which pair in which list.
#
# The two inline `for lit in …` lists were promoted to named arrays for this
# guard. That promotion is the point: the one real subsumption this file ever had
# lived in an inline list, not in a named array, so a guard that only walked the
# named arrays would have been green while sitting next to the defect. That
# particular pair is gone — narrowing the emitted enum to a single value removed
# the longer of the two literals — so the guard ships with nothing to catch here
# and stands for the next list instead.
subsumption_check() {
  local list_name="$1"
  shift
  local -a items=("$@")
  local i j
  for ((i = 0; i < ${#items[@]}; i++)); do
    for ((j = 0; j < ${#items[@]}; j++)); do
      if (( i != j )) && [[ "${items[j]}" == *"${items[i]}"* ]]; then
        echo "FAIL: pin list $list_name — '${items[i]}' is a substring of '${items[j]}'; the shorter literal can never fail on its own" >&2
        fail=1
      fi
    done
  done
}

# ---- derived ledger: marker regions -----------------------------------------
#
# The set of compartments is DERIVED from both sides rather than written out
# here: the skill's declared `<!-- X-BEGIN -->` markers, and the regions this
# file actually passes to require_region. An enumeration would go stale the day
# a compartment is added on one side only, and would go stale silently — the
# hard-coded fence count in the pass line below had already drifted from 5 to 7
# without any check noticing.
#
# An empty derived set is treated as a failure, not as "no compartments". An
# empty set here means the derivation stopped matching, and that is "unknown",
# not "none" — reading it as none is what makes a broken derivation print a
# clean pass.
#
# Known limit, stated rather than hidden: the checked-side derivation greps this
# script itself, and nothing guards that self-reference. The empty-set failure
# above is the whole of the mitigation.
LINT_SELF="${BASH_SOURCE[0]}"
declared_regions=$(grep -oE '<!-- [A-Z0-9-]+-BEGIN -->' "$SKILL" | LC_ALL=C awk '{print $2}' | LC_ALL=C sort -u || true)
checked_regions=$(grep -oE "require_region '<!-- [A-Z0-9-]+-BEGIN -->'" "$LINT_SELF" | LC_ALL=C awk '{print $3}' | LC_ALL=C sort -u || true)

if [[ -z "$declared_regions" || -z "$checked_regions" ]]; then
  echo "FAIL: marker-region ledger derived an empty set — an empty set is 'unknown', not 'none'" >&2
  echo "      declared side: $SKILL" >&2
  echo "      checked side:  $LINT_SELF" >&2
  fail=1
else
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    echo "FAIL: compartment $r is declared in the skill but no check claims it" >&2
    fail=1
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$declared_regions") <(printf '%s\n' "$checked_regions"))
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    echo "FAIL: compartment $r is checked here but the skill declares no such marker" >&2
    fail=1
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$declared_regions") <(printf '%s\n' "$checked_regions"))
fi

subsumption_check CONSTANTS       "${CONSTANTS[@]}"
subsumption_check INVOCATION_PINS "${INVOCATION_PINS[@]}"
subsumption_check SUPPRESS_SITES "${SUPPRESS_SITES[@]}"
subsumption_check H2             "${H2[@]}"
subsumption_check FORBIDDEN      "${FORBIDDEN[@]}"
subsumption_check SPAWN_LITERALS "${SPAWN_LITERALS[@]}"
subsumption_check ROUTING_SIGNALS "${ROUTING_SIGNALS[@]}"
subsumption_check REASONS        "${REASONS[@]}"

if (( ${#NOT_RUN[@]} == 0 )); then
  not_run_txt='none'
else
  not_run_txt=$(printf '%s; ' "${NOT_RUN[@]}")
  not_run_txt=${not_run_txt%'; '}
fi

if (( fail == 0 )); then
  n_fences=$(printf '%s\n' "$checked_regions" | LC_ALL=C awk 'NF{n++} END{print n+0}')
  echo "OK:   review-remediate pins — ${#CONSTANTS[@]} constants + ${#H2[@]} H2 + ${#FORBIDDEN[@]} denylist + ${#REASONS[@]} reason tokens + $n_fences compartment fences intact; not run: $not_run_txt"
elif (( ${#NOT_RUN[@]} > 0 )); then
  # The ledger is emitted on the failure path too, and that is where it is
  # reachable: a compartment body is skipped only when its marker check already
  # failed, so on a green run this list is empty by construction. Without this
  # line the skipped bodies would be reported nowhere at all — and a skipped
  # check's subject is unknown, not clean.
  echo "NOT RUN: $not_run_txt" >&2
fi

exit "$fail"
