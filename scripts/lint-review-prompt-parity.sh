#!/usr/bin/env bash
# Lint the round-keyed atomic-publish parity of the review-agent proposals path
# across its two prompt surfaces (`design-review/references/06-review-agent-prompt.md`
# and the inline prompt in `design-review-lite/SKILL.md`) and the two main-session
# read sites in each SKILL.md.
#
# The review agent no longer overwrites a single reused `review_proposals.md`; it
# writes a hidden same-dir temp and atomically publishes to a round-keyed
# `review_proposals.r<N>.md`. This introduces three renders of one stem
# (`review_proposals\.r[N{$]`): `.r{round}` (agent prompt template), `.r$inner_round`
# (main-session shell read sites), `.rN` (CFI prose). REQUIRED_PHRASES (rule B in
# lint-skill-invariants.sh) cannot pin this — the writes/reads live OUTSIDE the
# `## Control-Flow Invariants` section that rule B extracts, and the base write
# lives in references/06 (a separate file entirely). This script pins them so a
# copy that regresses to the bare overwrite path, or drops the round-key on one
# surface, fails CI.
#
# Models `scripts/lint-verification-literals.sh`: region-scoped positive presence
# in each copy's inlined review-agent prompt block, plus targeted negatives for
# the two removed literals (the Step 8 seed line, the full-overwrite prompt
# sentence). The negative is deliberately NOT a blanket bare-`review_proposals.md`
# scan: the tri-state death predicate prose legitimately references the bare
# filename when describing publish-method-agnostic liveness.
#
# Usage:
#   bash scripts/lint-review-prompt-parity.sh          # lint real plugin skills
#   SKILLS_ROOT=<dir> bash scripts/lint-review-prompt-parity.sh   # fixture test
#
# Exit codes:
#   0 — all parity checks pass (or a required file absent → skip, matching rule B)
#   1 — a round-keyed literal missing, or a removed literal still present

set -euo pipefail

# Resolve skills root (allow SKILLS_ROOT env override for tests).
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

BASE_PROMPT="$skills_root/design-review/references/06-review-agent-prompt.md"
BASE_SKILL="$skills_root/design-review/SKILL.md"
LITE_SKILL="$skills_root/design-review-lite/SKILL.md"

# Any required file absent → mechanism not present in this tree → silent skip so
# the script stays green for incremental / fixture-partial trees (matching the
# rule-B posture in lint-skill-invariants.sh).
for f in "$BASE_PROMPT" "$BASE_SKILL" "$LITE_SKILL"; do
  if [[ ! -f "$f" ]]; then
    echo "SKIP: review-prompt-parity — required file absent: $f"
    exit 0
  fi
done

# The round-keyed publish path in the agent-facing prompt template.
PROMPT_KEYED='review_proposals.r{round}.md'
# The round-keyed read path in the main-session Step 12 prose (shell render).
READ_KEYED='review_proposals.r$inner_round.md'
# Removed literals — must NOT survive on any surface.
SEED_LINE='echo "" > "$INNER_TEMP_DIR/review_proposals.md"'
OVERWRITE_LINE='Write all proposals to {TEMP_DIR}/review_proposals.md (overwrite the file at the start of the round).'

fail=0

# Extract a copy's inlined review-agent prompt block: from the reviewer sentinel
# line through the next code fence (exclusive). Mirrors lint-verification-literals.sh.
extract_prompt_block() {
  awk '
    /^```[[:space:]]*$/ { if (incap) exit }
    /You are a design document reviewer\./ { incap = 1 }
    incap { print }
  ' "$1"
}

assert_present() {
  local literal="$1" file="$2" label="$3"
  if ! grep -Fq "$literal" "$file"; then
    echo "FAIL: $label — expected literal missing: $literal" >&2
    fail=1
  fi
}

assert_present_in_text() {
  local literal="$1" text="$2" label="$3"
  if [[ "$text" != *"$literal"* ]]; then
    echo "FAIL: $label — expected literal missing from review-agent prompt block: $literal" >&2
    fail=1
  fi
}

assert_absent() {
  local literal="$1" file="$2" label="$3"
  if grep -Fq "$literal" "$file"; then
    echo "FAIL: $label — removed literal still present: $literal" >&2
    fail=1
  fi
}

base_prompt_block=$(extract_prompt_block "$BASE_PROMPT")
lite_prompt_block=$(extract_prompt_block "$LITE_SKILL")

# (1) Positive — round-keyed publish path present in BOTH prompt surfaces.
assert_present_in_text "$PROMPT_KEYED" "$base_prompt_block" "references/06-review-agent-prompt.md (prompt)"
assert_present_in_text "$PROMPT_KEYED" "$lite_prompt_block" "design-review-lite/SKILL.md (inline prompt)"

# (2) Positive — round-keyed read path present in BOTH SKILL.md main-session prose
#     (the witness-present read + the item-b read both use this render).
assert_present "$READ_KEYED" "$BASE_SKILL" "design-review/SKILL.md (read sites)"
assert_present "$READ_KEYED" "$LITE_SKILL" "design-review-lite/SKILL.md (read sites)"

# (3) Negative — the Step 8 seed line must be gone from BOTH SKILL.md.
assert_absent "$SEED_LINE" "$BASE_SKILL" "design-review/SKILL.md (Step 8 seed)"
assert_absent "$SEED_LINE" "$LITE_SKILL" "design-review-lite/SKILL.md (Step 8 seed)"

# (4) Negative — the full-overwrite prompt sentence must be gone from BOTH surfaces.
assert_absent "$OVERWRITE_LINE" "$BASE_PROMPT" "references/06-review-agent-prompt.md (overwrite sentence)"
assert_absent "$OVERWRITE_LINE" "$LITE_SKILL" "design-review-lite/SKILL.md (overwrite sentence)"

if (( fail == 0 )); then
  echo "OK:   review-prompt-parity — round-keyed publish/read present on both surfaces, seed + overwrite literals removed"
fi

exit "$fail"
