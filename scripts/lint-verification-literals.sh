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
# Normalize a trailing slash away. Every other use joins with an explicit `/`
# and tolerates a doubled one; the roster discovery below strips this value as
# a path PREFIX, and there a trailing slash silently leaves every discovered
# path absolute, so nothing matches the roster and the fence reports arrivals
# for the whole tree.
skills_root="${skills_root%/}"

SOT="$skills_root/_common/verification.md"
CONSUMER="$skills_root/implement/SKILL.md"

# The `상태` key is the one key in the tree whose producer authorizes two
# renderings, and §3.4 of the SOT obliges every consumer of it to declare which
# ones it reads. Two consumers carry that declaration. Neither was pinned:
# deleting BOTH declarations left this lint's `OK:` line byte-identical at exit
# 0, which is the shape this file exists to prevent — prose landed in the
# consumers and no script opened them. Encoded `<path>|<label>|<literal>`.
STATE_RENDERING_DECLS=(
  'implement/SKILL.md|implement (상태 rendering declaration)|**Reading `상태` — both renderings, and absence is never a default.**'
  'review/references/01-reviewer-context-package.md|review reviewer-context (상태 rendering declaration)|**Which `상태` renderings this consumer reads — declared, because the key has two and the shared contract requires every consumer of it to say.**'
)

# The population check (3) is drawn from. Check (3) pins the two declarations it
# is handed; nothing in this file asked whether a THIRD consumer had landed, and
# one was landed as a demonstration — undeclared, and the `OK:` line came back
# byte-identical at exit 0. A roster alone would not have caught it either: the
# roster has to be compared against what the tree actually holds, in BOTH
# directions, because an arrival and a departure are different edits and a
# rename is both at once.
#
# The key is spelled here once, in the code-formatted form every file that
# refers to it uses. Discovery reads stripped copies: commenting a file's
# mentions out is the cheapest way to leave a consumer in place while removing
# the evidence that it is one.
STATE_KEY_SPELLING='`상태`'
STATE_KEY_ROSTER_REAL=(
  '_common/verification.md|contract'
  '_common/sidecar.md|producer'
  'design/SKILL.md|producer'
  'implement/SKILL.md|consumer'
  'review/references/01-reviewer-context-package.md|consumer'
)

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
  if [[ "$text" == "$REGION_UNAVAILABLE" ]]; then
    echo "FAIL: $label — region-unavailable ($region), so this pin was not evaluated: $literal" >&2
    fail=1
    return
  fi
  if [[ "$text" != *"$literal"* ]]; then
    echo "FAIL: $label — frozen literal missing from $region: $literal" >&2
    fail=1
  fi
}

# shellcheck source=./_extract-between.sh
source "$script_dir/_extract-between.sh"
# Comments are not content here either. An editor removing a contract usually
# comments it out, and both forms below read through the strip: whole-file pins
# run against a blanked copy, and every region-scoped pin EXTRACTS from that
# copy rather than stripping what the extractor returned. The order matters and
# is not a preference — `extract_between` drops the start line, so a `<!--`
# opened above a region's start anchor never reaches a stripper that runs on the
# output, and the region reads as ordinary prose while sitting inside a comment.
# Measured before this landed: wrapping the whole of `_common/verification.md`
# in one comment left this lint at exit 0 with an `OK:` line byte-identical to
# the unwrapped one. Neither anchor pair here is itself a comment, so neither
# site takes the forced exception that two sites in the pin lint do.
# shellcheck source=./_strip-html-comments.sh
source "$script_dir/_strip-html-comments.sh"
SOT_VISIBLE=$(stripped_copy "$SOT")

# (1) SOT completeness.
for lit in "${SOT_LITERALS[@]}"; do
  assert_in_file "$lit" "$SOT_VISIBLE" "_common/verification.md (SOT)"
done

# (1a) Grade tokens, pinned inside the vocabulary table that defines them.
if grade_region=$(extract_between '^## 3\. Frozen vocabulary' '^### 3\.1 ' \
                                  "$SOT_VISIBLE" '_common/verification.md (vocabulary table)'); then :
else fail=1; grade_region="$REGION_UNAVAILABLE"
fi
for lit in "${GRADE_REGION_PINS[@]}"; do
  assert_in_text "$lit" "$grade_region" '_common/verification.md (SOT)' \
    'the frozen-vocabulary table'
done

# (1b) Spelling lock, as the negative assertion it actually is.
for bad in "${FORBIDDEN_SPELLINGS[@]}"; do
  if grep -Fq "$bad" "$SOT_VISIBLE"; then
    echo "FAIL: _common/verification.md (SOT) — forbidden spelling present: $bad" >&2
    fail=1
  fi
done

# (2) Consumer sync — deliberately narrow. The verification-timing enum is the
# only frozen vocabulary with a live inline copy outside the SOT: implement's
# 1.5a routing prose partitions on it. Pin ONLY what that partition is made of —
# 13 of the 24 SOT_LITERALS (the 4 residual reasons, the 4 execution-caution
# classes, and the 5 classification tokens) legitimately do not appear in that
# file at all, so a whole-array check would fail on day one. The count and the
# enumeration were both wrong before: the number read 12, and the enumeration
# also named the `## 검증 기록` heading, which is present in that file. Both
# halves are re-derived by looping the array through `grep -Fq` against the
# consumer, not by arithmetic on the previous sentence. (The five grade tokens DO appear there; they are out of scope
# here not because they are absent but because implement's copy of them is
# pinned by the Step-3 flip-gate prose, not by the 1.5a partition.) The two
# figures above are counts of an array this file declares, so read them off the
# success line rather than from this comment — the prose said 26 while the array
# held 24, which is the drift this script exists to prevent, inside this script.
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
                                       "$(stripped_copy "$CONSUMER")" 'implement/SKILL.md (consumer 1.5a bullet)' \
                                       include-start); then :
  else fail=1; consumer_bullet="$REGION_UNAVAILABLE"
  fi
  for lit in "${CONSUMER_1_5A[@]}"; do
    assert_in_text "$lit" "$consumer_bullet" \
      "implement/SKILL.md (consumer timing enum)" "the 1.5a bullet"
  done
fi

# (3) The two `상태` rendering declarations. A missing consumer FILE is a failure
# here for the same reason the 1.5a fence treats it as one: these are landed
# files of this repo, and a fence reporting OK for a target that is gone is the
# defect this script pins against.
for entry in "${STATE_RENDERING_DECLS[@]}"; do
  decl_path="${entry%%|*}"; rest="${entry#*|}"
  decl_label="${rest%%|*}"
  decl_lit="${rest#*|}"
  assert_in_file "$decl_lit" "$(stripped_copy "$skills_root/$decl_path")" "$decl_label"
done

# (3b) Roster <-> tree, both directions.
#
# The roster's source is decided by comparing roots, not by testing whether the
# env override is set: pointing SKILLS_ROOT at the real tree would otherwise
# hand a fixture-shaped lookup to the real population. On the real tree the
# roster is the array above, hand-written and not derived from the files it
# checks. A fixture tree declares its own in a `STATE_ROSTER` file at its root
# (one `<relpath>|<role>` per line, the same shape) — the extension keeps it out
# of the `*.md` discovery below. A tree that declares nothing FAILS rather than
# passing: a fence with an empty roster is satisfied by every tree.
state_roster=()
if [[ "$skills_root" == "$repo_root/plugins/cc-cmds/skills" ]]; then
  state_roster=("${STATE_KEY_ROSTER_REAL[@]}")
elif [[ -f "$skills_root/STATE_ROSTER" ]]; then
  while IFS= read -r roster_line; do
    [[ -n "$roster_line" ]] || continue
    case "$roster_line" in \#*) continue ;; esac
    state_roster+=("$roster_line")
  done < "$skills_root/STATE_ROSTER"
else
  echo "FAIL: 상태 roster — no roster for this tree: $skills_root declares no STATE_ROSTER and is not the real skills root" >&2
  fail=1
fi

state_declared=$'\n'
for entry in "${state_roster[@]+"${state_roster[@]}"}"; do
  state_declared="${state_declared}${entry%%|*}"$'\n'
done

state_observed=$'\n'
while IFS= read -r md_file; do
  if grep -Fq "$STATE_KEY_SPELLING" "$(stripped_copy "$md_file")"; then
    state_observed="${state_observed}${md_file#"$skills_root/"}"$'\n'
  fi
done < <(find "$skills_root" -type f -name '*.md' | sort)

# Arrival: a file references the key and no roster row accounts for it. This is
# the direction the demonstration defeated.
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  case "$state_declared" in
    *$'\n'"$rel"$'\n'*) ;;
    *)
      echo "FAIL: 상태 roster — undeclared file references the key: $rel; add it to the roster with its role, and if it is a consumer give it a rendering declaration" >&2
      fail=1
      ;;
  esac
done <<< "$state_observed"

# Departure: a roster row's file is present but no longer references the key —
# a rename or a silent removal. Restricted to the roles check (3) does NOT
# cover: for a consumer the declaration pin above already fires on exactly this
# edit, and a second assertion that cannot fail on its own would be the same
# defect class this file is here to pin.
for entry in "${state_roster[@]+"${state_roster[@]}"}"; do
  rel="${entry%%|*}"; role="${entry#*|}"
  case "$role" in consumer) continue ;; esac
  [[ -f "$skills_root/$rel" ]] || continue
  case "$state_observed" in
    *$'\n'"$rel"$'\n'*) ;;
    *)
      echo "FAIL: 상태 roster — declared $role no longer references the key: $rel; the roster is stale or the key was renamed" >&2
      fail=1
      ;;
  esac
done

if (( fail == 0 )); then
  # Every pinned literal belongs to a counted group and every group's size is
  # named here, so dropping any one of them changes this line and the OK fixture
  # detects it. A pin whose group size is not reported has no independent
  # coverage.
  echo "OK:   verification frozen literals — ${#SOT_LITERALS[@]} SOT (whole-file) + ${#GRADE_REGION_PINS[@]} SOT (vocabulary table) + ${#FORBIDDEN_SPELLINGS[@]} forbidden spelling + ${#CONSUMER_1_5A[@]} consumer (1.5a bullet) + ${#STATE_RENDERING_DECLS[@]} 상태 rendering declarations + ${#state_roster[@]} 상태 roster entries all present"
fi

exit "$fail"
