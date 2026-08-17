#!/usr/bin/env bash
# Pin the load-bearing literals and fences of the `review-remediate` skill.
#
# The command consumes a review report exactly once, records a disposition per
# finding, and writes to public issue trackers. Six of its properties cannot
# survive as prose alone:
#
#   (i)   the fixed-constants block. The nesting invariant is what the numeric
#         budget clause demands be *machine-checkable*; prose is not grepped.
#   (ii)  the emitted `검증 시점` enum, narrowed by this producer to two values.
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

# The emitted value must carry a non-empty parenthesised phase. A bare `구현 중`
# clears the consumer's presence check, matches no value arm, and lands as an
# out-of-vocabulary value — which leaves this producer with no residual that
# gates at all. Pinning the positive declaration (rather than forbidding the bare
# substring) keeps the region free to *discuss* the bare form in prose.
if require_region '<!-- RITEM-EMIT-BEGIN -->' '<!-- RITEM-EMIT-END -->' "$SKILL" 'R-item emit'; then
  ritem=$(region_body '<!-- RITEM-EMIT-BEGIN -->' '<!-- RITEM-EMIT-END -->' "$SKILL")
  for lit in '`구현 중(<착지>)` / `구현 후`만' '구현 후'; do
    if ! printf '%s\n' "$ritem" | grep -Fq -- "$lit"; then
      echo "FAIL: review-remediate/SKILL.md — R-item emit region must declare the parenthesised enum verbatim: $lit" >&2
      fail=1
    fi
  done
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

if require_region '<!-- DRYRUN-SUPPRESS-BEGIN -->' '<!-- DRYRUN-SUPPRESS-END -->' "$SKILL" 'dry-run suppression'; then
  suppress=$(region_body '<!-- DRYRUN-SUPPRESS-BEGIN -->' '<!-- DRYRUN-SUPPRESS-END -->' "$SKILL")
  SUPPRESS_SITES=(
    '이슈 생성'
    '라벨 생성'
    '이슈 자동 만료'
    '기존 이슈 코멘트'
    '산출물 저작'
    '판정 원장 기록'
  )
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
    missing=$(
      awk '/^    - \*\*Binding\*\*/,/^    - `## 권장 구현 순서` is reference/' "$CONSUMER" \
        | grep -oE '`## [^`]+`' | tr -d '`' | sort -u \
        | while IFS= read -r h; do
            grep -Fqx -- "$h" "$TEMPLATE" || printf '%s\n' "$h"
          done
    )
    if [[ -n "$missing" ]]; then
      echo "FAIL: consumer tier enumeration is not contained in the producer heading set; missing from the template:" >&2
      printf '  %s\n' $missing >&2
      fail=1
    fi
  fi
fi

# ---- (iii) the output H2 set -------------------------------------------------

if [[ -f "$TEMPLATE" ]]; then
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
fi

# ---- (v) spawn-zero fence ----------------------------------------------------

if require_region '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL" 'spawn denylist'; then
  decl=$(region_body '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL")
  outside=$(region_outside '<!-- SPAWN-DENY-BEGIN -->' '<!-- SPAWN-DENY-END -->' "$SKILL")
  for lit in 'Agent(' 'subagent_type' 'SendMessage'; do
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
    extra=$(printf '%s\n' "$c_line" | grep -oF '·' | wc -l | tr -d ' ' || true)
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
for lit in 'remote get-url' '.git/config'; do
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

if (( fail == 0 )); then
  echo "OK:   review-remediate pins — ${#CONSTANTS[@]} constants + ${#H2[@]} H2 + ${#FORBIDDEN[@]} denylist + ${#REASONS[@]} reason tokens + 5 compartment fences all intact"
fi

exit "$fail"
