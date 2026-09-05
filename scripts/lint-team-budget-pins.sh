#!/usr/bin/env bash
# Pin the load-bearing literals of the team-size and round budgets.
#
# Both budgets exist because the same numbers had drifted across eight files
# and ended up stating different values — two of them binding and mutually
# contradictory. Collapsing them to one source of truth only helps if the
# collapse itself is held in place, so three things are pinned here:
#
#   (i)   the budget constants, each asserted to occur on exactly ONE line
#         INSIDE its own `###` section. A file-wide count is not enough: the
#         protocol file legitimately discusses rounds elsewhere, and a
#         second statement of the same constant outside the section is the
#         precise regression this lint exists to catch.
#   (ii)  the sentences that carry the budgets' meaning rather than their
#         numbers — the coordinator-class carve-out, the narrowed third-round
#         trigger, the cost-reason ban, the risk-over-size precedence, and
#         the `MERGE`-Coordinator prohibition. Each of those can be deleted
#         during an unrelated rewrite with every other check still green.
#   (iii) a NEGATIVE fence: budget-stating phrasings must not reappear in a
#         SKILL.md or a reference file, because that is how the numbers got
#         scattered in the first place.
#
# The fence is NOT a bare-number denylist. This repo ships many intentional
# literal numbers (`fixed 2-member`, `fixed 2x sonnet`, `exceeds 50 files`,
# `<30 lines`, `>~15 sections`), and `lint-design-audit-pins.sh` positively
# REQUIRES `READER_COUNT = 3` and friends — a bare-number rule would put two
# scripts in the same `make lint` into direct contradiction. The fence keys
# on budget-stating phrasing instead.
#
# The one skill that deliberately keeps a different value (`review-lite`,
# whose predictable token cost is the reason it exists) is exempted by
# SECTION, not by file, and the exemption is paired with a POSITIVE
# assertion that the section still carries exactly one carve-out sentence
# naming the shared source of truth. A file-wide exemption would let that
# skill's own numbers drift freely and would let the carve-out be deleted in
# silence — which is the same failure, one level up.
#
# Posture: every block is skip-if-absent. A lever whose `###` section is not
# present is simply not checked, so reverting one lever leaves the tree green
# instead of making the revert itself break `make check`.
#
# Usage:
#   bash scripts/lint-team-budget-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-team-budget-pins.sh   # fixture test
#
# Exit codes:
#   0 — all present pins intact (absent levers skipped)
#   1 — at least one pin broken

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
# A fixture runner passes the root with a trailing slash. Strip it: the fence
# below compares `find` output against a path built from this value, and a
# doubled separator would make the review-lite exemption silently miss.
while [[ "$skills_root" == */ && "$skills_root" != "/" ]]; do
  skills_root="${skills_root%/}"
done

PROTOCOL="$skills_root/_common/agent-team-protocol.md"
UPGRADE_CORE="$skills_root/_common/team-upgrade-analysis.md"
REVIEW="$skills_root/review/SKILL.md"
REVIEW_UPGRADE="$skills_root/review-upgrade/SKILL.md"
REVIEW_LITE="$skills_root/review-lite/SKILL.md"

ROUND_HEADING='### Round budget'
TEAM_HEADING='### Team size budget'
REMOVE_HEADING='### `REMOVE` (drop a role whose domain no longer needs its own seat)'
MERGE_HEADING='### `MERGE` (two roles → one, both parents replaced)'
GATE_HEADING='#### Small-work gate (evaluated once on entering this step)'
LITE_HEADING='#### Round structure (fixed — round hard-cap = 2)'

if [[ ! -f "$PROTOCOL" ]]; then
  echo "SKIP: _common/agent-team-protocol.md not found under $skills_root"
  exit 0
fi

fail=0
checked=0

# ---------- helpers -----------------------------------------------------------

# has_heading <file> <exact-heading-line>
has_heading() {
  [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"
}

# extract_section <file> <exact-heading-line>
# Prints the heading line plus its body, stopping at the next heading of the
# same level or higher. The heading itself is INCLUDED because a heading can
# carry a pinned literal (review-lite states its cap in the heading text).
extract_section() {
  local file="$1" heading="$2"
  [[ -f "$file" ]] || return 0
  awk -v h="$heading" '
    function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !incap && $0 == h { incap = 1; lvl = hlevel($0); print; next }
    incap && substr($0, 1, 1) == "#" {
      n = hlevel($0)
      if (n >= 2 && n <= lvl) exit
    }
    incap { print }
  ' "$file"
}

# count_in_text <literal> <text> — lines of <text> containing the fixed literal.
count_in_text() {
  printf '%s\n' "$2" | grep -Fc -- "$1" 2>/dev/null || true
}

# count_in_file <literal> <file>
count_in_file() {
  [[ -f "$2" ]] || { echo 0; return; }
  grep -Fc -- "$1" "$2" 2>/dev/null || true
}

# assert_once_in_section <literal> <section-text> <label>
assert_once_in_section() {
  local literal="$1" text="$2" label="$3" n
  checked=$((checked + 1))
  n=$(count_in_text "$literal" "$text")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — must appear on exactly 1 line of its section, found $n: $literal" >&2
    fail=1
  fi
}

# assert_once_in_file <literal> <file> <label>
assert_once_in_file() {
  local literal="$1" file="$2" label="$3" n
  checked=$((checked + 1))
  n=$(count_in_file "$literal" "$file")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — must appear on exactly 1 line, found $n: $literal" >&2
    fail=1
  fi
}

# ---------- lever 04 — round budget (skip-if-absent) --------------------------

round_present=0
if has_heading "$PROTOCOL" "$ROUND_HEADING"; then
  round_present=1
  round_body=$(extract_section "$PROTOCOL" "$ROUND_HEADING")
  ROUND_PINS=(
    # the two constants
    '**Default = 2 rounds.**'
    '**Hard cap = 3 rounds.**'
    # the narrowing — without it the third round is a schedule again
    '**A member names a concrete, actionable measurement it has not yet run**'
    # the second entry path, without which a sweep refutation has nowhere to go
    "**The lead's pre-save sweep produced a refuting verdict.**"
  )
  for lit in "${ROUND_PINS[@]}"; do
    assert_once_in_section "$lit" "$round_body" "agent-team-protocol.md ($ROUND_HEADING)"
  done
fi

# ---------- lever 01 — team size budget (skip-if-absent) ----------------------

if has_heading "$PROTOCOL" "$TEAM_HEADING"; then
  team_body=$(extract_section "$PROTOCOL" "$TEAM_HEADING")
  TEAM_PINS=(
    # the three thresholds
    '**Up to 4 roles**'
    '**5 roles**'
    '**6 or more**'
    # the carve-out, without which the ceiling breaks the largest reviews
    '**Coordinator-class carve-out — meta/coordination roles are not counted.**'
  )
  for lit in "${TEAM_PINS[@]}"; do
    assert_once_in_section "$lit" "$team_body" "agent-team-protocol.md ($TEAM_HEADING)"
  done
fi

# ---------- lever 01 — the reducing operations (skip-if-absent) ---------------

merge_present=0
if has_heading "$UPGRADE_CORE" "$REMOVE_HEADING"; then
  UPGRADE_PINS=(
    "$REMOVE_HEADING"
    "$MERGE_HEADING"
    # the ban that keeps a savings pass from eating review quality
    '**The cost-reason ban is the load-bearing half of the reversal.**'
    'argued from cost, token budget, or headcount alone'
    # the scope limit the no-migration verdict rests on
    '**`REMOVE` / `MERGE` are pre-spawn only.**'
  )
  for lit in "${UPGRADE_PINS[@]}"; do
    assert_once_in_file "$lit" "$UPGRADE_CORE" "team-upgrade-analysis.md"
  done
  has_heading "$UPGRADE_CORE" "$MERGE_HEADING" && merge_present=1
fi

# The `MERGE`-Coordinator prohibition is required exactly when `MERGE` exists:
# reversing the forbidden-set's direction is the one point that OPENS a hole
# rather than closing one, and the shipped `SPLIT-REPLACE`-Coordinator ban
# stops covering it the moment a merge operation is available.
if (( merge_present == 1 )); then
  assert_once_in_file '`MERGE`-Coordinator is **forbidden**' "$REVIEW_UPGRADE" \
    "review-upgrade/SKILL.md"
fi

# ---------- lever 03 — small-work gate (skip-if-absent) ----------------------

if has_heading "$REVIEW" "$GATE_HEADING"; then
  # Risk-over-size precedence: the gate's size row is the only signal that can
  # quietly overrule a risk signal, and a pin catches deletion (not dilution).
  assert_once_in_file '**Risk indicators outrank the size row.**' "$REVIEW" \
    "review/SKILL.md (small-work gate)"
  # The threshold the gate reuses rather than inventing.
  assert_once_in_file '**Small patch** (<30 lines, single concern)' "$REVIEW" \
    "review/SKILL.md (small-work gate)"
fi

# ---------- review-lite — section exemption + its paired positive assertion ---

lite_body=""
lite_exempt_start=0
lite_exempt_end=0
if (( round_present == 1 )) && has_heading "$REVIEW_LITE" "$LITE_HEADING"; then
  lite_body=$(extract_section "$REVIEW_LITE" "$LITE_HEADING")

  # Positive half of the pair: the exempted section must still say, in exactly
  # one line, that its divergence is deliberate AND name the shared SOT. A
  # file-wide exemption would let this sentence vanish with the numbers left
  # behind, which reads identically to drift.
  carve_lines=$(printf '%s\n' "$lite_body" \
    | grep -F -- '**Deliberate carve-out from the shared Round budget.**' || true)
  checked=$((checked + 1))
  carve_count=0
  [[ -n "$carve_lines" ]] && carve_count=$(printf '%s\n' "$carve_lines" | grep -c '' || true)
  if [[ "$carve_count" != "1" ]]; then
    echo "FAIL: review-lite/SKILL.md ($LITE_HEADING) — exactly 1 carve-out sentence required, found $carve_count" >&2
    fail=1
  else
    # CAPTURED, NOT `grep -Fq`. An early-exiting reader on the right of a pipe
    # kills the writer with SIGPIPE, and under `pipefail` the pipeline then
    # reports failure even though the match was found.
    names_budget=$(printf '%s\n' "$carve_lines" | grep -cF -- '`### Round budget`' || true)
    if [[ "${names_budget:-0}" = "0" ]]; then
      echo "FAIL: review-lite/SKILL.md ($LITE_HEADING) — the carve-out sentence must name the shared '### Round budget'" >&2
      fail=1
    fi
  fi

  # Negative half: the line range the fence below skips.
  lite_range=$(awk -v h="$LITE_HEADING" '
    function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    !incap && $0 == h { incap = 1; lvl = hlevel($0); start = NR; next }
    incap && substr($0, 1, 1) == "#" {
      n = hlevel($0)
      if (n >= 2 && n <= lvl) { print start, NR - 1; found = 1; exit }
    }
    END { if (incap && !found) print start, NR }
  ' "$REVIEW_LITE")
  lite_exempt_start=${lite_range%% *}
  lite_exempt_end=${lite_range##* }
fi

# ---------- negative fence — budget phrasing must not scatter again -----------

# Gated on lever 04's presence for the same reason as the pins: reverting that
# lever restores the prose this fence forbids, and a revert must not turn the
# tree red on its way back.
if (( round_present == 1 )); then
  FENCE='hard[- ]cap|rounds default|round hard-cap|Total team-internal rounds|minimum [0-9]+ rounds|no cost throttle'
  while IFS= read -r target; do
    [[ -f "$target" ]] || continue
    rel=${target#"$skills_root/"}
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      lineno=${hit%%:*}
      if [[ "$target" == "$REVIEW_LITE" ]] \
        && (( lite_exempt_start > 0 && lineno >= lite_exempt_start && lineno <= lite_exempt_end )); then
        continue
      fi
      echo "FAIL: $rel:$lineno — budget-stating phrasing outside the source of truth: ${hit#*:}" >&2
      fail=1
    done < <(grep -nE "$FENCE" "$target" || true)
  done < <(
    {
      find "$skills_root" -mindepth 2 -maxdepth 2 -name 'SKILL.md'
      find "$skills_root" -mindepth 3 -maxdepth 3 -path '*/references/*.md'
    } | sort
  )
fi

if (( fail == 0 )); then
  echo "OK:   team budget pins — $checked pinned literal(s) intact, fence clean"
fi

exit "$fail"
