#!/usr/bin/env bash
# Pin the load-bearing literals of the `design-audit` skill.
#
# `design-audit` replaces an unbounded review loop with a single pass over a
# frozen document. Three of its properties cannot survive as prose alone, so
# they are pinned here:
#
#   (i)   the reader prompt's round/pass token, injected verbatim. A stateless
#         spawn-time hook can only match on the prompt text; if the token slot
#         disappears the hook has nothing to match and silently never fires.
#   (ii)  the reader contract's repo ground-truth measurement clause. A contract
#         that lives only in prose evaporates at call time, and this clause is
#         what makes readers open the files the document cites instead of
#         grading the document against itself.
#   (iii) the fixed-constants block. A hook reads the reader count from SKILL.md
#         directly rather than trusting a spawn prompt, because a copy drifts.
#
# It also carries a NEGATIVE fence: the loop machinery the overhaul deleted must
# not reappear under this skill. Each forbidden token is asserted to occur on
# exactly one line of SKILL.md — its own denylist entry — and on zero lines of
# any reference file. That shape pins the denylist's completeness (deleting a
# token from the denylist drops its count to 0 and fails) at the same time as it
# fences resurrection.
#
# Posture: if the skill is absent (not yet rolled out / incremental commit) the
# whole check is a silent skip so the script stays green; it activates once the
# skill exists. This matches `lint-verification-literals.sh`.
#
# Usage:
#   bash scripts/lint-design-audit-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-design-audit-pins.sh   # fixture test
#
# Exit codes:
#   0 — all pins intact (or skill absent → skip)
#   1 — at least one pin broken

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SKILL="$skills_root/design-audit/SKILL.md"
PROMPT="$skills_root/design-audit/references/01-reader-prompt.md"
DISCLOSURE="$skills_root/design-audit/references/04-disclosure-block.md"

if [[ ! -f "$SKILL" ]]; then
  echo "SKIP: design-audit/SKILL.md not found under $skills_root — skill not present"
  exit 0
fi

fail=0

# ---------- helpers -----------------------------------------------------------

# count_lines <literal> <file> — number of lines containing the fixed literal.
# Never trips `set -e`: grep's no-match exit 1 is absorbed.
count_lines() {
  local literal="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  grep -Fc -- "$literal" "$file" 2>/dev/null || true
}

# assert_in_file <literal> <file> <label>
assert_in_file() {
  local literal="$1" file="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return
  fi
  if ! grep -Fq -- "$literal" "$file"; then
    echo "FAIL: $label — pinned literal missing: $literal" >&2
    fail=1
  fi
}

# assert_in_text <literal> <text> <label> <region>
assert_in_text() {
  local literal="$1" text="$2" label="$3" region="$4"
  if [[ "$text" != *"$literal"* ]]; then
    echo "FAIL: $label — pinned literal missing from $region: $literal" >&2
    fail=1
  fi
}

# Extract the `## Control-Flow Invariants` section body: from the heading
# through the line before the next top-level heading. Mirrors the section-body
# extraction of `lint-skill-invariants.sh` rule (B).
extract_invariants_body() {
  awk '
    incap && /^## / { exit }
    /^## Control-Flow Invariants[[:space:]]*$/ { incap = 1; next }
    incap { print }
  ' "$1"
}

# ---------- (iii) fixed constants — SKILL.md, exactly once, inside the CFI body

CONSTANTS=(
  'READER_COUNT = 3'
  'ROUNDS_PER_READER = 1'
  'OUTER_ITERATIONS = 0'
  'ADJUSTMENT_PASSES = 1'
  'ROUND_TOKEN = 1'
  'PASS_TOKEN = fanout'
)

invariants_body=$(extract_invariants_body "$SKILL")
if [[ -z "$invariants_body" ]]; then
  echo "FAIL: design-audit/SKILL.md — '## Control-Flow Invariants' section body not found" >&2
  fail=1
fi

for lit in "${CONSTANTS[@]}"; do
  n=$(count_lines "$lit" "$SKILL")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: design-audit/SKILL.md (constants) — '$lit' must appear on exactly 1 line, found $n" >&2
    fail=1
  fi
  assert_in_text "$lit" "$invariants_body" \
    "design-audit/SKILL.md (constants)" "the '## Control-Flow Invariants' body"
done

# ---------- (i) round/pass token + (ii) repo-measurement clause — reader prompt

PROMPT_PINS=(
  # (i) the injected round/pass token. A stateless hook matches on this line;
  # without the slot it has no match target and silently never fires.
  'This review is Round {round} of pass {pass}.'
  # (ii) the repo ground-truth measurement clause and its output contract
  'REPO GROUND-TRUTH MEASUREMENT (MANDATORY'
  '## 앵커 대조표'
  'MATCH'
  'MISMATCH'
  'ABSENT'
  'required but created by no step'
  # the anchors a reader must cite when reporting a bookkeeping remainder
  '§검증 기록'
  '§구현 시 검증 항목'
  # the byte-identity requirement that keeps reinforcement multiplicity meaningful
  'byte-identical'
)

for lit in "${PROMPT_PINS[@]}"; do
  assert_in_file "$lit" "$PROMPT" "design-audit/references/01-reader-prompt.md"
done

# ---------- (iv) disclosure block — fences and the 14 slot keys ---------------

DISCLOSURE_PINS=(
  '<!-- cc-design-audit-disclosure v1 begin -->'
  '<!-- /cc-design-audit-disclosure v1 end -->'
  '**동결 문서 sha256**'
  '**동결 시각**'
  '**리뷰어 수**'
  '**원시 발견 수**'
  '**고유 결함 수**'
  '**미보강 잔여 수**'
  '**라우팅 — 조정 패스 적용**'
  '**라우팅 — 미해결 이슈**'
  '**라우팅 — implement 사전 게이트**'
  '**라우팅 — design-conformance**'
  '**라우팅 — 기각**'
  '**하류 흡수 가정**'
  '**조정 패스 시작**'
  '**조정 패스 종료**'
)

for lit in "${DISCLOSURE_PINS[@]}"; do
  assert_in_file "$lit" "$DISCLOSURE" "design-audit/references/04-disclosure-block.md"
done

# ---------- negative fence — loop machinery must not reappear ----------------

FORBIDDEN=(
  'consecutive_no_major'
  'COUNT_APPLIED'
  'escalate_applied'
  'INNER_EXIT_REASON'
  'inner_round'
  'outer_iter'
  'outer_log.md'
  'ack_items.md'
  'pending_applies.md'
  'INNER_TEMP_DIR'
)

for lit in "${FORBIDDEN[@]}"; do
  # Exactly one line in SKILL.md: its own denylist entry. 0 means the denylist
  # lost the token; >1 means the token is in use somewhere besides the denylist.
  n=$(count_lines "$lit" "$SKILL")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: design-audit/SKILL.md (denylist) — '$lit' must appear on exactly 1 line (its denylist entry), found $n" >&2
    fail=1
  fi
done

# Zero occurrences anywhere under references/.
if [[ -d "$skills_root/design-audit/references" ]]; then
  while IFS= read -r ref; do
    for lit in "${FORBIDDEN[@]}"; do
      if grep -Fq -- "$lit" "$ref"; then
        echo "FAIL: ${ref#"$skills_root/"} — loop-machinery token present: $lit" >&2
        fail=1
      fi
    done
    # The reader count is referred to BY NAME everywhere outside the constants
    # block; a numeric reviewer-count literal in a reference file is a second
    # source of truth that will drift away from CFI-0.
    if grep -Eq '리더 [0-9]+인|[0-9]+ readers|three readers' "$ref"; then
      echo "FAIL: ${ref#"$skills_root/"} — reviewer-count literal present; refer to READER_COUNT by name" >&2
      fail=1
    fi
  done < <(find "$skills_root/design-audit/references" -type f -name '*.md' | sort)
fi

if (( fail == 0 )); then
  echo "OK:   design-audit pins — ${#CONSTANTS[@]} constants (CFI body) + ${#PROMPT_PINS[@]} reader-prompt + ${#DISCLOSURE_PINS[@]} disclosure + ${#FORBIDDEN[@]} denylist all intact"
fi

exit "$fail"
