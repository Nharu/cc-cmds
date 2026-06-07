#!/usr/bin/env bash
# Lint the frozen in-session-verification literals across their copies.
#
# The verification vocabulary (grades, residual reasons, execution-caution
# classes, classification tokens, the verification-timing enum, the field key,
# the section headings, and the detection-grammar markers) is defined ONCE in
# the SOT `_common/verification.md` and excerpted/inlined into two review
# copies (`design-review/references/06-review-agent-prompt.md` and
# `design-review-lite/SKILL.md`). Semantic prose drift cannot be linted, but
# the frozen byte-exact literals can — this script pins them so a rename in one
# copy that is not mirrored to the others fails CI.
#
# Models `scripts/lint-skill-invariants.sh` rule (B): a phrase-presence sync
# check between copies. As in rule (B) — which extracts the
# `## Control-Flow Invariants` section body and checks phrases within it — the
# drift target (the two review copies) is checked region-scoped, not whole-file:
# the criterion-#7 literals must appear inside each copy's inlined review-agent
# prompt block (delimited by the reviewer sentinel line through the next code
# fence), so a token surviving only in unrelated prose does not mask a deletion.
# The SOT is NOT a sync target but the authority, so its completeness check is
# whole-file ("is every frozen token defined somewhere in the SOT").
#
# Posture: if the SOT is absent (mechanism not yet rolled out / incremental
# commit), the whole check is a silent skip so the script stays green; it
# activates once the SOT exists.
#
# Usage:
#   bash scripts/lint-verification-literals.sh          # lint real plugin skills
#   SKILLS_ROOT=<dir> bash scripts/lint-verification-literals.sh   # fixture test
#
# Exit codes:
#   0 — all present (or SOT absent → skip)
#   1 — at least one frozen literal missing from a copy that must carry it

set -euo pipefail

# Resolve skills root (allow SKILLS_ROOT env override for tests).
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SOT="$skills_root/_common/verification.md"
EXCERPT="$skills_root/design-review/references/06-review-agent-prompt.md"
INLINE="$skills_root/design-review-lite/SKILL.md"

# SOT absent → mechanism not present in this tree → silent skip.
if [[ ! -f "$SOT" ]]; then
  echo "SKIP: _common/verification.md not found under $skills_root — verification mechanism not present"
  exit 0
fi

# (1) Full frozen vocabulary — must ALL be present in the SOT (whole-file).
SOT_LITERALS=(
  # grade tokens (5)
  '검증됨(통과)'
  '반증됨(실패)'
  '미검증'
  '구현 시 검증'
  '검증불가(드리프트)'
  # residual-reason closed set (4)
  '구현 필요'
  '검증 차단'
  '예산 소진'
  '분류 제외'
  # execution-caution closed class (4)
  '유료/외부 변이'
  '머신 상태 변이'
  '장시간(>10분)'
  '파괴적'
  # classification tokens (5)
  '정적 사실'
  '실행 측정'
  '외부 환경'
  '행동 가설'
  '미니 구현'
  # verification-timing enum (2)
  '구현 전'
  '구현 중'
  # field key + note-line key
  '검증 등급'
  '**구현 시 검증 기록**'
  # section headings
  '## 검증 기록'
  '## 구현 시 검증 항목'
  # spelling lock (drift-inventory head literal)
  '검증불가('
)

# (2) Criterion-#7 literals shared across the two review copies. Checked inside
# each copy's review-agent prompt block (region-scoped, per rule (B)).
PROMPT_SHARED=(
  '미검증'
  '검증 등급'
  '§검증 기록'
  '§구현 시 검증 항목'
  '| verification]'
  '| verification-bookkeeping]'
)

fail=0

# Extract a copy's inlined review-agent prompt block: from the reviewer
# sentinel line through the next code fence (exclusive). Mirrors rule (B)'s
# section-body extraction.
extract_prompt_block() {
  awk '
    /^```[[:space:]]*$/ { if (incap) exit }
    /You are a design document reviewer\./ { incap = 1 }
    incap { print }
  ' "$1"
}

# assert_in_file <literal> <file> <label>
assert_in_file() {
  local literal="$1" file="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return
  fi
  if ! grep -Fq "$literal" "$file"; then
    echo "FAIL: $label — frozen literal missing: $literal" >&2
    fail=1
  fi
}

# assert_in_text <literal> <text> <label>  (region-scoped presence)
assert_in_text() {
  local literal="$1" text="$2" label="$3"
  if [[ "$text" != *"$literal"* ]]; then
    echo "FAIL: $label — frozen literal missing from review-agent prompt block: $literal" >&2
    fail=1
  fi
}

# (1) SOT completeness.
for lit in "${SOT_LITERALS[@]}"; do
  assert_in_file "$lit" "$SOT" "_common/verification.md (SOT)"
done

# (2) Review-copy sync, region-scoped to the prompt block.
if [[ ! -f "$EXCERPT" ]]; then
  echo "FAIL: references/06-review-agent-prompt.md (excerpt) — file not found: $EXCERPT" >&2
  fail=1
  excerpt_block=""
else
  excerpt_block=$(extract_prompt_block "$EXCERPT")
fi

if [[ ! -f "$INLINE" ]]; then
  echo "FAIL: design-review-lite/SKILL.md (inline) — file not found: $INLINE" >&2
  fail=1
  inline_block=""
else
  inline_block=$(extract_prompt_block "$INLINE")
fi

for lit in "${PROMPT_SHARED[@]}"; do
  assert_in_text "$lit" "$excerpt_block" "references/06-review-agent-prompt.md (excerpt)"
  assert_in_text "$lit" "$inline_block" "design-review-lite/SKILL.md (inline)"
done

if (( fail == 0 )); then
  echo "OK:   verification frozen literals — ${#SOT_LITERALS[@]} SOT (whole-file) + ${#PROMPT_SHARED[@]} review-copy (prompt-block) all present"
fi

exit "$fail"
