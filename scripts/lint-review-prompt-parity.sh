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
# Used ONLY for the relative base==lite occurrence-count parity below (defence in
# depth against asymmetric drift in NON-pinned narrative prose). Absolute presence
# is pinned by the two contract-read sentences instead — a whole-file single grep
# is structurally blind to a partial regression (only one of three sites reverting).
READ_KEYED='review_proposals.r$inner_round.md'
# The two contract-read sentences, pinned per file by absolute presence. Each is
# truncated before the base `(a)–(j)` / lite `(a)–(i)` tail so one literal covers
# both surfaces.
READ_S1='**witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to'
READ_S2='b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round'\''s proposals.'
# The zero-proposal publish clause, pinned in both prompt surfaces.
CLAUSE='including when this round has zero proposals'
# Removed literals — must NOT survive on any surface.
SEED_LINE='echo "" > "$INNER_TEMP_DIR/review_proposals.md"'
OVERWRITE_LINE='Write all proposals to {TEMP_DIR}/review_proposals.md (overwrite the file at the start of the round).'

# --- #63 round-number injection parity (lowercase {round}) ---
# Positive: the injection instruction, present in BOTH prompt surfaces.
DERIV_NEW='Use {round} as the round number everywhere below'
# Negatives: the removed self-derivation seed sentences. OLD2 is the FULL tail —
# the surviving E1 prose still contains the `"## Review Round" entries` substring,
# so a bare match would false-fail.
DERIV_OLD1='to determine the current round number'
DERIV_OLD2='"## Review Round" entries exist in the log, this is Round 1'
# Substitution-contract {round} bullet landing proof. A bare `{round}` is vacuous
# (it already occurs in the PROP-ID / publish path), so target the per-surface
# bullet lead: base uses a colon, lite uses an arrow.
SUBST_BASE='- `{round}`:'
SUBST_LITE='- `{round}` →'
# Site-3 (async_observed_return, in `## Strategy` — outside the CFI window that
# rule B in lint-skill-invariants.sh extracts), mirrored across both SKILLs.
DERIV_CFI='injected into the agent'\''s spawn prompt as {round} by the main session'
# --- #64 EXIT_TRIGGER durable-record structural literal. The `- Inner exit trigger:`
# key occurs 3× per surface: the anti-fabrication anchor prose (base 97 / lite 98),
# the Step 16 flush write-site (base 456 / lite 554), and the Step 20 restore
# write-site (base 509 / lite 607). All 3 sit outside the CFI window and are
# mirrored across surfaces — rule B cannot pin them — so check (9) enforces the
# base↔lite parity of that 3-count, and check (9b) pins the restore direction
# marker so a symmetric drop of the Step 20 restore line cannot pass silently. ---
EXIT_KEY='- Inner exit trigger:'
# Restore direction marker — present ONLY on the Step 20 restore line (exactly 1×
# per surface). Pinned mechanism-agnostically (does NOT pin `grep`/`tail`), so it
# survives the selector expression. ---
RESTORE_MARKER='← restore from'
# --- #64 per-trigger reason variant contract (ALL FOUR EXIT_TRIGGER values:
# inner-limit / async-slow / lostwrite / trigger-neutral). The pin set derives from
# this 4-variant contract, NOT from "whatever lite currently has" — a subset (the
# regression that shipped 2-of-4 lite clauses and passed green) must fail. Each
# variant's downstream early-termination clause has its single source in base
# §3.9.4.f and is mirrored into lite. async-slow / lostwrite / inner-limit occur
# exactly 1× per surface → count parity. trigger-neutral occurs 2× in base
# references/05 (the L108 partial-iteration banner example + the L239 definition)
# but 1× in lite → presence-only, count_equal deliberately dropped. Only
# early-termination clauses are pinned (summary clauses ride the same bullet). ---
BASE_TEMPLATES="$skills_root/design-review/references/05-korean-ux-templates.md"
ASYNC_SLOW_CLAUSE='비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨'
LOSTWRITE_CLAUSE='라운드 결과 파일이 반복 유실되어 조기 종료됨'
INNER_LIMIT_CLAUSE='내부 라운드가 안전 한계로 조기 종료됨'
NEUTRAL_CLAUSE='내부 라운드가 조기 종료됨'
# trigger-neutral SUMMARY clause. Unlike NEUTRAL_CLAUSE (early-termination) which
# also appears in the L108 partial-iteration banner, this rides ONLY the
# definition line (base05 1× / lite 1×), so it anchors the definition and closes
# the presence-only hole where deleting the definition leaves the banner green.
NEUTRAL_SUMMARY='이터레이션 조기 종료 시점에 미해소'

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
  if ! grep -Fq -- "$literal" "$file"; then
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
  if grep -Fq -- "$literal" "$file"; then
    echo "FAIL: $label — removed literal still present: $literal" >&2
    fail=1
  fi
}

# Relative base==lite occurrence-count parity of a literal (line-counted). Catches
# an asymmetric drift in prose the absolute pins do not cover (e.g. the narrative
# "published … to <round-keyed>" line dropping its key on ONE surface only).
assert_count_equal() {
  local literal="$1" file_a="$2" file_b="$3" label="$4" ca cb
  ca=$(grep -Fc -- "$literal" "$file_a" || true)
  cb=$(grep -Fc -- "$literal" "$file_b" || true)
  if [[ "$ca" != "$cb" ]]; then
    echo "FAIL: $label — base/lite occurrence-count mismatch ($ca vs $cb): $literal" >&2
    fail=1
  fi
}

# Base↔lite content identity of a single anchored line (regex anchor, e.g.
# '^- Inner exit trigger:'). Extracts the first matching line from each surface
# and string-compares. Wording-agnostic: pins the mirrored line's whole content
# (selector expression + any gate clause) without naming a literal. A one-surface
# reword reds this; a symmetric deletion leaves both empty and is caught by the
# presence marker instead (check 9b).
assert_line_identical() {
  local anchor="$1" file_a="$2" file_b="$3" label="$4" la lb
  la=$(grep -m1 -E -- "$anchor" "$file_a" || true)
  lb=$(grep -m1 -E -- "$anchor" "$file_b" || true)
  if [[ "$la" != "$lb" ]]; then
    echo "FAIL: $label — base/lite restore line content differs" >&2
    fail=1
  fi
}

base_prompt_block=$(extract_prompt_block "$BASE_PROMPT")
lite_prompt_block=$(extract_prompt_block "$LITE_SKILL")

# (1) Positive — round-keyed publish path present in BOTH prompt surfaces.
assert_present_in_text "$PROMPT_KEYED" "$base_prompt_block" "references/06-review-agent-prompt.md (prompt)"
assert_present_in_text "$PROMPT_KEYED" "$lite_prompt_block" "design-review-lite/SKILL.md (inline prompt)"

# (1b) Positive — the zero-proposal publish clause present in BOTH prompt surfaces.
assert_present_in_text "$CLAUSE" "$base_prompt_block" "references/06-review-agent-prompt.md (zero-proposal clause)"
assert_present_in_text "$CLAUSE" "$lite_prompt_block" "design-review-lite/SKILL.md (zero-proposal clause)"

# (2) Positive — the two contract-read sentences present per file (absolute), plus
#     the round-keyed occurrence count symmetric across base/lite (relative). A
#     single whole-file grep would pass even if two of the three read sites regress.
assert_present "$READ_S1" "$BASE_SKILL" "design-review/SKILL.md (witness-present read)"
assert_present "$READ_S1" "$LITE_SKILL" "design-review-lite/SKILL.md (witness-present read)"
assert_present "$READ_S2" "$BASE_SKILL" "design-review/SKILL.md (item-b read)"
assert_present "$READ_S2" "$LITE_SKILL" "design-review-lite/SKILL.md (item-b read)"
assert_count_equal "$READ_KEYED" "$BASE_SKILL" "$LITE_SKILL" "design-review SKILL.md base↔lite read-keyed count parity"

# (3) Negative — the Step 8 seed line must be gone from BOTH SKILL.md.
assert_absent "$SEED_LINE" "$BASE_SKILL" "design-review/SKILL.md (Step 8 seed)"
assert_absent "$SEED_LINE" "$LITE_SKILL" "design-review-lite/SKILL.md (Step 8 seed)"

# (4) Negative — the full-overwrite prompt sentence must be gone from BOTH surfaces.
assert_absent "$OVERWRITE_LINE" "$BASE_PROMPT" "references/06-review-agent-prompt.md (overwrite sentence)"
assert_absent "$OVERWRITE_LINE" "$LITE_SKILL" "design-review-lite/SKILL.md (overwrite sentence)"

# (5) #63 injection — positive in both prompt blocks + base↔lite count parity.
assert_present_in_text "$DERIV_NEW" "$base_prompt_block" "references/06-review-agent-prompt.md (round injection)"
assert_present_in_text "$DERIV_NEW" "$lite_prompt_block" "design-review-lite/SKILL.md (round injection)"
assert_count_equal "$DERIV_NEW" "$BASE_PROMPT" "$LITE_SKILL" "round-injection base↔lite count parity"

# (6) #63 — the two removed self-derivation seeds gone from BOTH prompt surfaces.
assert_absent "$DERIV_OLD1" "$BASE_PROMPT" "references/06-review-agent-prompt.md (self-derive seed 1)"
assert_absent "$DERIV_OLD1" "$LITE_SKILL" "design-review-lite/SKILL.md (self-derive seed 1)"
assert_absent "$DERIV_OLD2" "$BASE_PROMPT" "references/06-review-agent-prompt.md (self-derive seed 2)"
assert_absent "$DERIV_OLD2" "$LITE_SKILL" "design-review-lite/SKILL.md (self-derive seed 2)"

# (7) #63 — substitution-contract {round} bullet lands per surface (surface-specific lead).
assert_present "$SUBST_BASE" "$BASE_PROMPT" "references/06-review-agent-prompt.md ({round} contract bullet)"
assert_present "$SUBST_LITE" "$LITE_SKILL" "design-review-lite/SKILL.md ({round} contract bullet)"

# (8) #63 site-3 (E8) — CFI-outside async_observed_return injection prose, both SKILLs + parity.
assert_present "$DERIV_CFI" "$BASE_SKILL" "design-review/SKILL.md (async_observed_return injection)"
assert_present "$DERIV_CFI" "$LITE_SKILL" "design-review-lite/SKILL.md (async_observed_return injection)"
assert_count_equal "$DERIV_CFI" "$BASE_SKILL" "$LITE_SKILL" "async_observed_return injection base↔lite count parity"

# (9) #64 EXIT_TRIGGER structural literal — Step 16 flush + Step 20 write-site, both SKILLs + parity.
assert_present "$EXIT_KEY" "$BASE_SKILL" "design-review/SKILL.md (Inner exit trigger key)"
assert_present "$EXIT_KEY" "$LITE_SKILL" "design-review-lite/SKILL.md (Inner exit trigger key)"
assert_count_equal "$EXIT_KEY" "$BASE_SKILL" "$LITE_SKILL" "Inner exit trigger key base↔lite count parity"

# (9b) #64 EXIT_TRIGGER restore direction marker — present on the Step 20 restore
#      line of BOTH SKILLs (exactly 1× each). Guards the check-(9) blind spot: a
#      symmetric removal of the Step 20 restore line keeps the 3→2 count parity and
#      presence true, so #64's durable-record restore could regress green. This
#      marker pins the restore line itself; mechanism-agnostic (survives the
#      grep -m1 → tail -1 selector change).
assert_present "$RESTORE_MARKER" "$BASE_SKILL" "design-review/SKILL.md (Step 20 restore marker)"
assert_present "$RESTORE_MARKER" "$LITE_SKILL" "design-review-lite/SKILL.md (Step 20 restore marker)"

# (9c) #64 EXIT_TRIGGER restore-line content identity — the Step 20 restore line
#      is mirrored byte-identical across both SKILLs. Guards the (9b) blind spot:
#      a one-surface reword (base lands, lite missed) keeps the marker present and
#      the count parity intact, so (9b)+(9) both stay green. This pins the whole
#      line content so an asymmetric edit of any part (selector, gate clause) reds.
assert_line_identical '^- Inner exit trigger:' "$BASE_SKILL" "$LITE_SKILL" "design-review SKILL.md base↔lite Step 20 restore-line identity"

# (10) #64 per-trigger reason variants — base template (§3.9.4.f) ↔ lite Step-16 inline.
#      LOCAL file guard (NOT the blanket skip at the top): a fixture without the
#      template still exercises every check above. All FOUR EXIT_TRIGGER variants are
#      pinned so a subset regression (2-of-4) fails; each distinctive clause is a
#      single occurrence per surface except trigger-neutral (2× in base — see below).
if [[ -f "$BASE_TEMPLATES" ]]; then
  assert_present "$ASYNC_SLOW_CLAUSE" "$BASE_TEMPLATES" "references/05 (§3.9.4.f async-slow variant)"
  assert_present "$ASYNC_SLOW_CLAUSE" "$LITE_SKILL" "design-review-lite/SKILL.md (async-slow variant)"
  assert_count_equal "$ASYNC_SLOW_CLAUSE" "$BASE_TEMPLATES" "$LITE_SKILL" "async-slow variant base↔lite count parity"
  assert_present "$LOSTWRITE_CLAUSE" "$BASE_TEMPLATES" "references/05 (§3.9.4.f lostwrite variant)"
  assert_present "$LOSTWRITE_CLAUSE" "$LITE_SKILL" "design-review-lite/SKILL.md (lostwrite variant)"
  assert_count_equal "$LOSTWRITE_CLAUSE" "$BASE_TEMPLATES" "$LITE_SKILL" "lostwrite variant base↔lite count parity"
  assert_present "$INNER_LIMIT_CLAUSE" "$BASE_TEMPLATES" "references/05 (§3.9.4.f inner-limit variant)"
  assert_present "$INNER_LIMIT_CLAUSE" "$LITE_SKILL" "design-review-lite/SKILL.md (inner-limit variant)"
  assert_count_equal "$INNER_LIMIT_CLAUSE" "$BASE_TEMPLATES" "$LITE_SKILL" "inner-limit variant base↔lite count parity"
  # trigger-neutral: presence-only. The clause occurs 2× in base references/05 (the
  # L108 banner example + the L239 definition) but 1× in lite, so count_equal would
  # false-fail on the real tree — presence on both surfaces suffices for regression.
  assert_present "$NEUTRAL_CLAUSE" "$BASE_TEMPLATES" "references/05 (§3.9.4.f trigger-neutral variant)"
  assert_present "$NEUTRAL_CLAUSE" "$LITE_SKILL" "design-review-lite/SKILL.md (trigger-neutral variant)"
  assert_present "$NEUTRAL_SUMMARY" "$BASE_TEMPLATES" "references/05 (trigger-neutral summary clause)"
  assert_present "$NEUTRAL_SUMMARY" "$LITE_SKILL" "design-review-lite/SKILL.md (trigger-neutral summary clause)"
  assert_count_equal "$NEUTRAL_SUMMARY" "$BASE_TEMPLATES" "$LITE_SKILL" "trigger-neutral summary clause base↔lite count parity"
elif grep -Fq -- "$ASYNC_SLOW_CLAUSE" "$LITE_SKILL" \
  || grep -Fq -- "$LOSTWRITE_CLAUSE" "$LITE_SKILL" \
  || grep -Fq -- "$INNER_LIMIT_CLAUSE" "$LITE_SKILL" \
  || grep -Fq -- "$NEUTRAL_CLAUSE" "$LITE_SKILL"; then
  # references/05 absent but lite still carries at least one per-trigger reason
  # variant → the per-trigger mechanism is live and only the base template
  # moved/renamed, which the local -f guard would otherwise silently disable.
  # Keyed on ALL FOUR variants (not just async-slow) so rewording any single
  # clause cannot re-open the silent-skip. Fail loud rather than skip.
  echo "FAIL: review-prompt-parity — references/05 template absent but a per-trigger reason variant is still present on lite (base template moved/renamed?)" >&2
  fail=1
fi

if (( fail == 0 )); then
  echo "OK:   review-prompt-parity — round-keyed publish/read present on both surfaces, seed + overwrite literals removed"
fi

exit "$fail"
