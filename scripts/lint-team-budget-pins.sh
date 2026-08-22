#!/usr/bin/env bash
# Pin the load-bearing literals of the team-size and round budgets.
#
# Both budgets exist because the same numbers had drifted across eight files
# and ended up stating different values — two of them binding and mutually
# contradictory. Collapsing them to one source of truth only helps if the
# collapse is held in place, so this script does four things.
#
#   (i)   ANCHOR vs PIN are separate. A short anchor (`### `REMOVE``) decides
#         whether a lever is present; the full heading line is a PIN. Deleting
#         a whole section is a legitimate revert and yields green plus a
#         `WARN:` naming what was skipped; REWORDING a heading leaves the
#         anchor matching and fails the pin, which is red. Folding the two
#         together is what let a heading rewording switch off the very check
#         that should have caught it.
#   (ii)  Cardinality is counted in OCCURRENCES, not lines, and each
#         section-scoped pin is checked as a PAIR: exactly once inside its
#         section AND no further occurrence anywhere else in the file. Neither
#         half alone is the contract — scoping says "exactly here", the pair
#         says "and nowhere else". Counting lines instead of occurrences let
#         the same literal be written twice on one line and still pass.
#   (iii) The sentences that carry the budgets' meaning rather than their
#         numbers are pinned too — the coordinator-class carve-out, the
#         narrowed third-round trigger, the cost-reason ban, the
#         risk-over-size precedence, the `MERGE`-Coordinator prohibition. Each
#         can be deleted during an unrelated rewrite with every other check
#         still green.
#   (iv)  A NEGATIVE fence: budget-stating phrasing must not reappear in a
#         consuming skill or reference file, because that is how the numbers
#         got scattered in the first place. The fence is case-insensitive:
#         a lowercase paraphrase is the same regression as a verbatim copy,
#         and matching only the exact case rewarded paraphrasing.
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
# SECTION, not by file, and the exemption is paired with a POSITIVE assertion
# that the section still carries exactly one carve-out sentence naming the
# shared source of truth.
#
# Posture: every block is skip-if-absent and every skip is announced. A lever
# whose anchor is not present is not checked, so reverting one lever leaves
# the tree green instead of making the revert itself break `make check` — but
# the `WARN:` line and the real-tree pin total below keep a silent skip from
# reading as coverage.
#
# Usage:
#   bash scripts/lint-team-budget-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-team-budget-pins.sh   # fixture test
#
# Exit codes:
#   0 — all present pins intact (absent levers skipped and announced)
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

# Anchors gate; they are deliberately shorter than the headings they find so a
# reworded tail still resolves and then fails its pin.
ROUND_ANCHOR='### Round budget'
TEAM_ANCHOR='### Team size budget'
REMOVE_ANCHOR='### `REMOVE`'
MERGE_ANCHOR='### `MERGE`'
# The pin is the EXPECTED heading, never the one just found. Pinning whatever
# `find_heading` returned would be circular — it matches itself by
# construction, so a reworded heading would satisfy its own pin and the
# rewording path would stay exactly as invisible as before the split.
REMOVE_HEADING='### `REMOVE` (drop a role whose domain no longer needs its own seat)'
MERGE_HEADING='### `MERGE` (two roles → one, both parents replaced)'
GATE_ANCHOR='#### Small-work gate'
# `review-lite` is the exception to the anchor/pin split: its heading STATES
# the value, so the anchor is the whole line on purpose. If that value is
# edited the anchor stops resolving, the exemption stops applying, and the
# fence turns the tree red — a stronger property than the design promised,
# and the reason this one is not shortened.
LITE_HEADING='#### Round structure (fixed — round hard-cap = 2)'

if [[ ! -f "$PROTOCOL" ]]; then
  echo "SKIP: _common/agent-team-protocol.md not found under $skills_root"
  exit 0
fi

fail=0
checked=0
skipped=0
WARNINGS=()

# ---------- helpers -----------------------------------------------------------

# find_heading <file> <anchor-prefix> — the first heading line starting with the
# anchor. Empty output means the lever is absent.
find_heading() {
  local file="$1" anchor="$2"
  [[ -f "$file" ]] || return 0
  awk -v a="$anchor" 'index($0, a) == 1 { print; exit }' "$file"
}

# note_skip <lever-label> <pins-not-checked>
note_skip() {
  WARNINGS+=("WARN: $1 — anchor absent, $2 pin(s) not checked (a section deleted wholesale is a legitimate revert; a reworded heading is not this path)")
  skipped=$((skipped + $2))
}

# extract_section <file> <exact-heading-line>
# Prints the heading line plus its body, stopping at the next heading of the
# same level or higher. The heading itself is INCLUDED because a heading can
# carry a pinned literal. FENCED CODE BLOCKS ARE TRACKED: a `###` inside a
# ``` fence is illustrative text, not a heading, and treating it as one ends
# the section early and silently drops every pin below it.
extract_section() {
  local file="$1" heading="$2"
  [[ -f "$file" ]] || return 0
  awk -v h="$heading" '
    function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    substr($0, 1, 3) == "```" { fence = !fence; if (incap) print; next }
    !incap && $0 == h { incap = 1; lvl = hlevel($0); print; next }
    incap && !fence && substr($0, 1, 1) == "#" {
      n = hlevel($0)
      if (n >= 2 && n <= lvl) exit
    }
    incap { print }
  ' "$file"
}

# section_range <file> <exact-heading-line> — "<start> <end>" line numbers of
# the section including its heading. Same fence tracking as extract_section;
# the two must agree or the fence exemption covers a different span than the
# positive assertion reads.
section_range() {
  local file="$1" heading="$2"
  [[ -f "$file" ]] || return 0
  awk -v h="$heading" '
    function hlevel(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    substr($0, 1, 3) == "```" { fence = !fence; next }
    !incap && $0 == h { incap = 1; lvl = hlevel($0); start = NR; next }
    incap && !fence && substr($0, 1, 1) == "#" {
      n = hlevel($0)
      if (n >= 2 && n <= lvl) { print start, NR - 1; found = 1; exit }
    }
    END { if (incap && !found) print start, NR }
  ' "$file"
}

# occurrences_in_text <literal> <text> — OCCURRENCES, not lines. Writing the
# same literal twice on one line is the duplication this must catch.
occurrences_in_text() {
  printf '%s\n' "$2" | grep -oF -- "$1" 2>/dev/null | grep -c '' || true
}

# occurrences_in_file <literal> <file>
occurrences_in_file() {
  [[ -f "$2" ]] || { echo 0; return; }
  grep -oF -- "$1" "$2" 2>/dev/null | grep -c '' || true
}

# assert_once_in_section <literal> <section-text> <file> <label>
# The pair: exactly one occurrence inside the section, and none outside it.
assert_once_in_section() {
  local literal="$1" text="$2" file="$3" label="$4" n m
  checked=$((checked + 1))
  n=$(occurrences_in_text "$literal" "$text")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — must occur exactly once in its section, found $n: $literal" >&2
    fail=1
    return
  fi
  m=$(occurrences_in_file "$literal" "$file")
  if [[ "$m" != "$n" ]]; then
    echo "FAIL: $label — restated outside its section ($m occurrence(s) in the file, $n in the section): $literal" >&2
    fail=1
  fi
}

# assert_once_in_file <literal> <file> <label>
assert_once_in_file() {
  local literal="$1" file="$2" label="$3" n
  checked=$((checked + 1))
  n=$(occurrences_in_file "$literal" "$file")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $label — must occur exactly once, found $n: $literal" >&2
    fail=1
  fi
}

# ---------- lever 04 — round budget -------------------------------------------

ROUND_PINS=(
  # the two constants
  '**Default = 2 rounds.**'
  '**Hard cap = 3 rounds.**'
  # the narrowing — without it the third round is a schedule again
  '**A member names a concrete, actionable measurement it has not yet run**'
  # the second entry path, without which a sweep refutation has nowhere to go
  "**The lead's pre-save sweep produced a refuting verdict.**"
)

round_present=0
round_heading=$(find_heading "$PROTOCOL" "$ROUND_ANCHOR")
if [[ -n "$round_heading" ]]; then
  round_present=1
  round_body=$(extract_section "$PROTOCOL" "$round_heading")
  for lit in "${ROUND_PINS[@]}"; do
    assert_once_in_section "$lit" "$round_body" "$PROTOCOL" \
      "agent-team-protocol.md ($round_heading)"
  done
else
  note_skip "lever 04 (round budget)" "${#ROUND_PINS[@]}"
fi

# ---------- lever 01 — team size budget ---------------------------------------

TEAM_PINS=(
  # the three thresholds
  '**Up to 4 roles**'
  '**5 roles**'
  '**6 or more**'
  # the carve-out, without which the ceiling breaks the largest reviews
  '**Coordinator-class carve-out — meta/coordination roles are not counted.**'
)

team_heading=$(find_heading "$PROTOCOL" "$TEAM_ANCHOR")
if [[ -n "$team_heading" ]]; then
  team_body=$(extract_section "$PROTOCOL" "$team_heading")
  for lit in "${TEAM_PINS[@]}"; do
    assert_once_in_section "$lit" "$team_body" "$PROTOCOL" \
      "agent-team-protocol.md ($team_heading)"
  done
else
  note_skip "lever 01 (team size budget)" "${#TEAM_PINS[@]}"
fi

# ---------- lever 01 — the reducing operations --------------------------------

# The two headings are gated by their own anchors and pinned as full lines, and
# `MERGE` is gated INDEPENDENTLY of `REMOVE`: nesting the merge check inside the
# remove block made the `MERGE`-Coordinator prohibition disappear whenever the
# remove anchor moved, which is the opposite of what a prohibition is for.
remove_heading=$(find_heading "$UPGRADE_CORE" "$REMOVE_ANCHOR")
merge_heading=$(find_heading "$UPGRADE_CORE" "$MERGE_ANCHOR")

UPGRADE_PROSE_PINS=(
  # the ban that keeps a savings pass from eating review quality
  '**The cost-reason ban is the load-bearing half of the reversal.**'
  'argued from cost, token budget, or headcount alone'
  # the scope limit the no-migration verdict rests on
  '**`REMOVE` / `MERGE` are pre-spawn only.**'
)

if [[ -n "$remove_heading" ]]; then
  assert_once_in_file "$REMOVE_HEADING" "$UPGRADE_CORE" "team-upgrade-analysis.md (REMOVE heading)"
  for lit in "${UPGRADE_PROSE_PINS[@]}"; do
    assert_once_in_file "$lit" "$UPGRADE_CORE" "team-upgrade-analysis.md"
  done
else
  note_skip "lever 01 (REMOVE operation)" $(( 1 + ${#UPGRADE_PROSE_PINS[@]} ))
fi

if [[ -n "$merge_heading" ]]; then
  assert_once_in_file "$MERGE_HEADING" "$UPGRADE_CORE" "team-upgrade-analysis.md (MERGE heading)"
  # Required exactly when `MERGE` exists: reversing the forbidden-set's
  # direction is the one point that OPENS a hole rather than closing one, and
  # the shipped `SPLIT-REPLACE`-Coordinator ban stops covering it the moment a
  # merge operation is available.
  assert_once_in_file '`MERGE`-Coordinator is **forbidden**' "$REVIEW_UPGRADE" \
    "review-upgrade/SKILL.md"
else
  note_skip "lever 01 (MERGE operation)" 2
fi

# ---------- lever 03 — small-work gate ----------------------------------------

GATE_PINS=(
  # Risk-over-size precedence: the gate's size row is the only signal that can
  # quietly overrule a risk signal, and a pin catches deletion (not dilution).
  '**Risk indicators outrank the size row.**'
  # The threshold the gate reuses rather than inventing.
  '**Small patch** (<30 lines, single concern)'
)

gate_heading=$(find_heading "$REVIEW" "$GATE_ANCHOR")
if [[ -n "$gate_heading" ]]; then
  for lit in "${GATE_PINS[@]}"; do
    assert_once_in_file "$lit" "$REVIEW" "review/SKILL.md (small-work gate)"
  done
else
  note_skip "lever 03 (small-work gate)" "${#GATE_PINS[@]}"
fi

# ---------- review-lite — section exemption + its paired positive assertion ---

CARVE_LITERAL='**Deliberate carve-out from the shared Round budget.**'
lite_exempt_start=0
lite_exempt_end=0
if (( round_present == 1 )) && [[ -f "$REVIEW_LITE" ]] && grep -Fxq -- "$LITE_HEADING" "$REVIEW_LITE"; then
  lite_body=$(extract_section "$REVIEW_LITE" "$LITE_HEADING")

  # Positive half of the pair: the exempted section must still say, in exactly
  # one place, that its divergence is deliberate AND name the shared SOT. A
  # file-wide exemption would let this sentence vanish with the numbers left
  # behind, which reads identically to drift.
  checked=$((checked + 1))
  carve_count=$(occurrences_in_text "$CARVE_LITERAL" "$lite_body")
  if [[ "$carve_count" != "1" ]]; then
    echo "FAIL: review-lite/SKILL.md ($LITE_HEADING) — exactly 1 carve-out sentence required, found $carve_count" >&2
    fail=1
  elif ! printf '%s\n' "$lite_body" | grep -F -- "$CARVE_LITERAL" | grep -Fq -- '`### Round budget`'; then
    echo "FAIL: review-lite/SKILL.md ($LITE_HEADING) — the carve-out sentence must name the shared '### Round budget'" >&2
    fail=1
  fi

  # Negative half: the line range the fence below skips.
  lite_range=$(section_range "$REVIEW_LITE" "$LITE_HEADING")
  lite_exempt_start=${lite_range%% *}
  lite_exempt_end=${lite_range##* }
elif (( round_present == 1 )); then
  note_skip "review-lite carve-out" 1
fi

# ---------- negative fence — budget phrasing must not scatter again -----------

# Gated on lever 04's presence for the same reason as the pins: reverting that
# lever restores the prose this fence forbids, and a revert must not turn the
# tree red on its way back.
#
# The SOT file is excluded FILE-WIDE and that is not a blanket exemption: every
# budget literal it holds is covered by a positive pin above, so the exclusion
# removes a guaranteed self-hit while leaving the same bytes guarded. Excluding
# a file the pins do NOT cover would be a real hole, which is why this comment
# names the pairing rather than the path.
if (( round_present == 1 )); then
  FENCE='hard[- ]cap|rounds default|round hard-cap|total team-internal rounds|minimum [0-9]+ rounds|no cost throttle|repeat( this cycle)? until convergence'
  while IFS= read -r target; do
    [[ -f "$target" ]] || continue
    [[ "$target" == "$PROTOCOL" ]] && continue
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
    done < <(grep -niE "$FENCE" "$target" || true)
  done < <(
    {
      find "$skills_root" -mindepth 2 -maxdepth 2 -name 'SKILL.md'
      find "$skills_root" -path '*/references/*' -name '*.md'
      find "$skills_root/_common" -maxdepth 1 -name '*.md' 2>/dev/null
    } | sort -u
  )
fi

# ---------- real-tree pin total ----------------------------------------------

# Fixture roots deliberately hold a subset of the levers, so this runs only
# against the committed tree. It is the one check a heading rewording cannot
# dodge by taking its own pin down with it: the anchor stops resolving, the
# lever is skipped, and the reached-pin count falls below the expected total.
if [[ -z "${SKILLS_ROOT:-}" ]]; then
  # round 4 + team 4 + upgrade 5 + MERGE ban 1 + gate 2 + lite carve-out 1 = 17
  # Keep this decomposition next to the constant. Raising the number without
  # updating the arithmetic is the reflex this comment exists to make visible;
  # note that it does NOT catch a swap (one pin removed, one added), which the
  # total leaves to code review by design.
  EXPECTED_PINS=17
  if (( checked != EXPECTED_PINS )); then
    echo "FAIL: committed tree — expected $EXPECTED_PINS pins to be reached, reached $checked (skipped $skipped)" >&2
    fail=1
  fi
fi

for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
  echo "$w"
done

if (( fail == 0 )); then
  echo "OK:   team budget pins — $checked pin(s) checked, $skipped skipped, fence clean"
fi

exit "$fail"
