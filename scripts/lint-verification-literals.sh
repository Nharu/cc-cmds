#!/usr/bin/env bash
# Lint the frozen in-session-verification literals against the SOT and its one
# live consumer copy.
#
# The verification vocabulary (grades, residual reasons, execution-caution
# classes, classification tokens, the verification-timing enum, the field key,
# the section headings, and the detection-grammar markers) is defined ONCE in
# the SOT `_common/verification.md`. Exactly one live inline copy exists: the
# routing prose of `implement/SKILL.md` partitions on the verification-timing
# enum, so that value and the pinned value arm that detects it are both pinned
# there too, region-scoped to the 1.5a bullet (see (2)). Semantic prose drift
# cannot be linted, but the frozen byte-exact literals can — this script pins
# them so a rename that is not mirrored to the consumer fails CI.
#
# Region-scoping follows `scripts/lint-skill-invariants.sh` rule (B), which
# extracts a named section body and checks phrases within it: a token surviving
# only in unrelated prose elsewhere in the file must not mask a deletion from
# the region that matters. The SOT is NOT a sync target but the authority, so
# its completeness check is whole-file ("is every frozen token defined
# somewhere in the SOT").
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
CONSUMER="$skills_root/implement/SKILL.md"

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
  # NOTE: `구현 시 검증` is NOT here — it is a substring of `**구현 시 검증 기록**`
  # and of `## 구현 시 검증 항목`, so a whole-file pin on it can never fail alone.
  # It is pinned region-scoped to the vocabulary table below, where no
  # superstring occurs.
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
  # verification-timing enum (3)
  '구현 전'
  '구현 중'
  '구현 후'
  # field key + note-line key
  '검증 등급'
  '**구현 시 검증 기록**'
  # section headings
  '## 검증 기록'
  '## 구현 시 검증 항목'
  # NOTE: the spelling lock is NOT a positive pin here — `검증불가(` is a
  # substring of `검증불가(드리프트)`, so it is satisfied by the very token it is
  # meant to constrain and can never fail on its own. What the lock actually
  # asserts is the ABSENCE of the spaced spelling, and that is checked below as
  # a negative assertion, which can fail independently.
)

# Region-scoped grade tokens — pinned where they are DEFINED, not wherever they
# happen to occur. A whole-file pin on a token that is a substring of another
# frozen literal is satisfied by the superstring and therefore has no
# discriminating power of its own.
#
# Scoping alone did NOT achieve that here, and the bare token was measured to
# have exactly zero discriminating power even inside its own region: the
# vocabulary table's row 1′ carries `**구현 시 검증 기록**`, which contains the
# token, so deleting row 4 — the row that DEFINES it — left the pin satisfied by
# a neighbouring row. What is pinned is therefore the defining table cell, with
# its delimiters: no superstring in this region satisfies it, and only the row's
# own deletion can.
GRADE_REGION_PINS=(
  '| `구현 시 검증` |'
)

# Negative assertions. Each one can fail on its own, which is exactly what the
# positive form of the same rule could not do.
FORBIDDEN_SPELLINGS=(
  '검증불가 ('
)

fail=0

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

# assert_in_text <literal> <text> <label> [region]  (region-scoped presence)
assert_in_text() {
  local literal="$1" text="$2" label="$3" region="${4:-the checked region}"
  if [[ "$text" != *"$literal"* ]]; then
    echo "FAIL: $label — frozen literal missing from $region: $literal" >&2
    fail=1
  fi
}

# shellcheck source=./_extract-between.sh
source "$script_dir/_extract-between.sh"

# (1) SOT completeness.
for lit in "${SOT_LITERALS[@]}"; do
  assert_in_file "$lit" "$SOT" "_common/verification.md (SOT)"
done

# (1a) Grade tokens, pinned inside the vocabulary table that defines them.
if grade_region=$(extract_between '^## 3\. Frozen vocabulary' '^### 3\.1 ' \
                                  "$SOT" '_common/verification.md (vocabulary table)'); then :
else fail=1
fi
for lit in "${GRADE_REGION_PINS[@]}"; do
  assert_in_text "$lit" "$grade_region" '_common/verification.md (SOT)' \
    'the frozen-vocabulary table'
done

# (1b) Spelling lock, as the negative assertion it actually is.
for bad in "${FORBIDDEN_SPELLINGS[@]}"; do
  if grep -Fq "$bad" "$SOT"; then
    echo "FAIL: _common/verification.md (SOT) — forbidden spelling present: $bad" >&2
    fail=1
  fi
done

# (2) Consumer sync — deliberately narrow. The verification-timing enum is the
# only frozen vocabulary with a live inline copy outside the SOT: implement's
# 1.5a routing prose partitions on it. Pin ONLY what that partition is made of —
# 14 of the 26 SOT_LITERALS (the residual reasons, the execution-caution
# classes, the classification tokens, and the `## 검증 기록` heading)
# legitimately do not appear in that file at all, so a whole-array check would
# fail on day one. (The five grade tokens DO appear there; they are out of scope
# here not because they are absent but because implement's copy of them is
# pinned by the Step-3 flip-gate prose, not by the 1.5a partition.)
# Region-scoped like rule (B), NOT whole-file: the values also occur in the
# 1.5b / Step-2 / Step-3 prose downstream, so a whole-file check stays green
# even when the 1.5a partition itself has been reverted to its two-bucket form
# — the exact regression this fence exists to catch. The region is the 1.5a
# bullet, and each pinned literal is independently deletable: no one of them is
# a substring of another, so each can fail on its own.
# A missing consumer file is a skip, not a failure (the file's existence is a
# precondition of the skill, not of these literals); a consumer that exists but
# has lost any one of them from its 1.5a bullet is a FAIL — that is the
# regression fence for the 1.5a three-way partition. A consumer that exists
# with no 1.5a bullet at all is also a FAIL: the region the fence guards is
# gone, so silence would no longer mean the partition is intact.
CONSUMER_1_5A=(
  # the three-bucket enumeration itself (no value arm is a superstring of this
  # form, so the enumeration losing a value fails on its own)
  '| `구현 후` —'
  # Step 1 (presence): separates "no 검증 시점 line" from "unrecognized value"
  '검증 시점): (.+)$'
  # Step 2 (value): one arm per bucket — deleting any one arm fails alone
  '검증 시점): 구현 전$'
  '검증 시점): 구현 중\(.+\)$'
  '검증 시점): 구현 후$'
  # gate entry is a positive selector on the save-time residual token; losing
  # it means every unhandled 검증 등급 state falls into the gate by default
  '검증 등급): 구현 시 검증$'
)

# Extract implement's 1.5a bullet — the routing prose that partitions on the
# verification-timing enum. The region runs from the bullet's opening line
# through everything that continues it, ending just before the next top-level
# bullet, the next heading, or a blank line. It is one physical line today, but
# reading the whole bullet rather than `grep -m1` means a pure reflow (same
# bytes, wrapped over several lines) does not report every literal as missing —
# a diagnostic that names deleted literals for an edit that deleted none.
# Mirrors rule (B)'s section-body extraction.
# The 1.5a bullet's region ends at the NEXT top-level bullet, named explicitly.
# The previous extractor ended at "the next top-level bullet, OR any heading, OR
# a blank line" — and the blank-line arm is the problem: a paragraph break
# inserted inside the bullet truncates the region early, after which the pins
# below its cut point read as deleted although nothing was deleted. Naming 1.5b
# as the terminator also makes the terminator itself pinned: delete it and the
# region does not silently swallow the rest of the file, it fails loudly.
#
# A consumer that is ABSENT is a FAIL, not a skip. Reporting OK for a fence
# whose target is gone is the same shape of defect this file exists to pin: the
# fence stops guarding and says nothing. `implement/SKILL.md` is a landed file
# of this repo, so its absence is a defect rather than a normal state.
if [[ ! -f "$CONSUMER" ]]; then
  echo "FAIL: implement/SKILL.md (consumer) — file not found; the 1.5a fence has no target and cannot report OK" >&2
  fail=1
else
  if consumer_bullet=$(extract_between '^- \*\*1\.5a ' '^- \*\*1\.5b ' \
                                       "$CONSUMER" 'implement/SKILL.md (consumer 1.5a bullet)' \
                                       include-start); then :
  else fail=1
  fi
  for lit in "${CONSUMER_1_5A[@]}"; do
    assert_in_text "$lit" "$consumer_bullet" \
      "implement/SKILL.md (consumer timing enum)" "the 1.5a bullet"
  done
fi

if (( fail == 0 )); then
  # Every pinned literal belongs to a counted group and every group's size is
  # named here, so dropping any one of them changes this line and the OK fixture
  # detects it. A pin whose group size is not reported has no independent
  # coverage.
  echo "OK:   verification frozen literals — ${#SOT_LITERALS[@]} SOT (whole-file) + ${#GRADE_REGION_PINS[@]} SOT (vocabulary table) + ${#FORBIDDEN_SPELLINGS[@]} forbidden spelling + ${#CONSUMER_1_5A[@]} consumer (1.5a bullet) all present"
fi

exit "$fail"
