#!/usr/bin/env bash
# Pin the round scope of the progress-checkpoint parameter.
#
# The parameter is charged per member-ROUND — one dedicated turn each time —
# while the loss it converts from total to partial is confined to round 1 by
# the definition of the probability the break-even is written against: a crash
# before the member's first witness lands, and that witness lands at the end
# of round 1. Charging every round for a benefit only round 1 can realise was
# a scope mismatch, and it was closed by restricting the write to round 1.
#
# That restriction lives in prose, in two places that have to agree, and this
# repository's own history is that prose contracts drift apart when nothing
# counts them — which is why the interlock, the ledger row length, the cutpoint
# vocabulary and the team budget are all pinned the same way. This is that pin.
#
# ---------------------------------------------------------------------------
# WHAT THIS LINT MEASURES
#
#   (i)   THE SEAM AND THE INJECTED CLAUSE BOTH CARRY THE RESTRICTION. The
#         seam's cadence bullet is what a reader of the contract sees; the
#         clause block is what a member actually receives. A restriction in
#         only one of them is the drift this pin exists to catch, and it is
#         the asymmetric case that reads plausibly: the seam can say "round 1
#         only" while the clause injected into members still says nothing,
#         and every member then keeps writing every round.
#   (ii)  THE UNRESTRICTED FORMS STAY GONE (negative fence). Both the old
#         cadence bullet opener and the old clause heading are asserted
#         absent, so a revert that restores either — the way a rewrite
#         restores a sentence it thinks was truncated — fails rather than
#         silently re-widening the charge.
#   (iii) THE RATIONALE IS PRESENT, ONCE. The reason is what makes the
#         restriction re-derivable by someone who did not run the
#         measurement; without it the clause reads as an arbitrary limit and
#         the next editor removes it as noise.
#   (iv)  THE TWO GIVE-UPS ARE WRITTEN DOWN. The restriction is not free: a
#         later-round crash now recovers only the round-1 witness, and the
#         round-2 checkpoint is no longer available as a second independent
#         suppressor for the recovery arm's interlock. Both are disclosures
#         rather than defects, and a disclosure that can be deleted without
#         a failure is a disclosure that will be.
#   (v)   THE RECOVERY ARM RECORDS THAT ITS EXAMPLE IS NO LONGER MINTED. The
#         arm's round-first rationale is argued from a seat holding a
#         round-2 checkpoint beside a round-1 witness, which the restriction
#         makes unproducible under the current contract. The rule stays —
#         older corpora still present that shape and round 1 still needs it —
#         but a rationale whose example cannot occur reads as dead text and
#         invites deletion of the rule with it.
#
# WHAT THIS LINT DOES NOT MEASURE — stated because a pin believed to check
# more than it checks is worse than no pin.
#
#   * IT DOES NOT EVALUATE THE BREAK-EVEN. What is fixed is wording, not the
#     arithmetic behind it. If the turn-count denominator moves, this lint
#     keeps passing on prose that has become the wrong call.
#   * IT DOES NOT CHECK THAT MEMBERS OBEY. Whether a spawned member honours
#     the restriction is observable only on disk, after a run, in the
#     `partial/` corpus — not here.
#   * IT DOES NOT COVER SKILLS THAT INLINE THE CLAUSE. The three opted-in
#     skills append it by reference, which is what makes one pin sufficient;
#     a skill that ever pastes its own copy is outside this check, and the
#     seam's own by-reference rule is what keeps that from happening.
# ---------------------------------------------------------------------------
#
# Usage:
#   bash scripts/lint-checkpoint-round-scope.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-checkpoint-round-scope.sh  # fixture
#
# Exit codes:
#   0 — all present pins intact (seam heading absent ⇒ skipped)
#   1 — at least one pin broken

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
while [[ "$skills_root" == */ && "$skills_root" != "/" ]]; do
  skills_root="${skills_root%/}"
done

PROTOCOL="$skills_root/_common/agent-team-protocol.md"
ARM="$skills_root/review-unattended/SKILL.md"

SEAM_HEADING='### Parameter — progress checkpoint (opt-in)'

fail=0
checked=0

# ---------- helpers -----------------------------------------------------------

has_heading() {
  [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"
}

# extract_section <file> <exact-heading-line>
# Heading plus body, stopping at the next heading of the same level or higher.
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

# fold_text <text> — collapse each paragraph onto one line, keep blank-line
# boundaries. A wrapped clause becomes reachable by a fixed-string search
# without splicing two unrelated paragraphs into a match neither contains.
fold_text() {
  printf '%s\n' "$1" | awk '
    function flush() { if (para != "") { print para; para = "" } }
    {
      line = $0
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      if (line == "") { flush(); next }
      para = (para == "" ? line : para " " line)
    }
    END { flush() }
  '
}

fold_file() {
  [[ -f "$1" ]] || return 0
  fold_text "$(cat "$1")"
}

count_occurrences() {
  local n
  n=$(printf '%s\n' "$2" | grep -oF -- "$1" | grep -c '' || true)
  printf '%s' "${n:-0}"
}

# assert_count <literal> <folded-text> <want> <label>
assert_count() {
  local literal="$1" text="$2" want="$3" label="$4" n
  n=$(count_occurrences "$literal" "$text")
  checked=$((checked + 1))
  if [[ "$n" != "$want" ]]; then
    echo "FAIL: $label — expected $want occurrence(s), found $n: $literal" >&2
    fail=1
  fi
}

# ---------- skip when the seam is gone ----------------------------------------

if ! has_heading "$PROTOCOL" "$SEAM_HEADING"; then
  echo "SKIP: checkpoint-round-scope — seam heading not found in ${PROTOCOL#"$repo_root"/}"
  exit 0
fi

seam_body=$(fold_text "$(extract_section "$PROTOCOL" "$SEAM_HEADING")")
proto_body=$(fold_file "$PROTOCOL")
arm_body=$(fold_file "$ARM")

seam_label="_common/agent-team-protocol.md ($SEAM_HEADING)"

# ---------- (i) the restriction is in the seam AND in the injected clause -----

assert_count \
  '**Cadence — round 1 only.**' \
  "$seam_body" 1 "$seam_label — cadence bullet carries the round scope"

assert_count \
  'In round 2 and later a member writes no checkpoint at all' \
  "$seam_body" 1 "$seam_label — cadence bullet states the negative case"

assert_count \
  '**Progress checkpoint (MUST — round 1 only)**' \
  "$proto_body" 1 "agent-team-protocol.md — injected clause heading carries the round scope"

assert_count \
  'this applies in round 1 and in no later round; from round 2 on, write no checkpoint' \
  "$proto_body" 1 "agent-team-protocol.md — injected clause states the restriction to the member"

# ---------- (ii) the unrestricted forms stay gone -----------------------------

assert_count \
  '**Progress checkpoint (MUST)**' \
  "$proto_body" 0 "agent-team-protocol.md — unrestricted clause heading must not return"

assert_count \
  '- **Cadence** — once the first finding clears' \
  "$proto_body" 0 "agent-team-protocol.md — unrestricted cadence bullet must not return"

# ---------- (iii) the rationale is present, once ------------------------------

assert_count \
  '**Why round 1 and no later round.**' \
  "$seam_body" 1 "$seam_label — rationale heading"

assert_count \
  'Charging every round for a benefit that only round 1 can realise' \
  "$seam_body" 1 "$seam_label — rationale names the scope mismatch"

# ---------- (iv) the two give-ups are written down ----------------------------

assert_count \
  '**What this gives up, stated rather than implied.**' \
  "$seam_body" 1 "$seam_label — give-ups disclosure heading"

assert_count \
  'no longer available as a second, independent suppressor' \
  "$seam_body" 0 "$seam_label — suppressor wording lives in its own sentence below, not here"

assert_count \
  'one of **two independent ways** the recovery arm' \
  "$seam_body" 1 "$seam_label — give-up 2, the interlock suppressor"

# ---------- (v) the arm records that its example is no longer minted ----------

if [[ -f "$ARM" ]]; then
  assert_count \
    '**That seat is no longer minted, and the rule is kept regardless.**' \
    "$arm_body" 1 "review-unattended/SKILL.md — round-first example reachability"

  assert_count \
    'count of independent suppressors' \
    "$arm_body" 1 "review-unattended/SKILL.md — what the restriction changes"
fi

# ---------- verdict ------------------------------------------------------------

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: checkpoint-round-scope — $checked assertion(s) checked, at least one broken" >&2
  exit 1
fi

echo "OK:   checkpoint round scope — $checked assertion(s) intact"
