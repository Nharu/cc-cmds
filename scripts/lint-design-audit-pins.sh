#!/usr/bin/env bash
# Pin the load-bearing literals of the `design-audit` skill.
#
# Three reasons a literal is pinned here:
#   (i)   a stateless consumer matches on it, so losing the byte silently
#         disables the consumer rather than erroring;
#   (ii)  it is the only place a value is written, so a second copy would drift;
#   (iii) it is a control-flow invariant whose deletion is indistinguishable
#         from a deliberate relaxation six months later.
# A NEGATIVE fence also runs: the loop machinery this command replaced must not
# reappear anywhere under the skill.
#
# REGION SCOPING — why the pins are not whole-file.
#   A whole-file `grep -Fq` asks only whether a byte sequence exists somewhere.
#   Where the same token legitimately appears in two independent places, the two
#   vouch for each other and either region can be deleted whole while the lint
#   still reports "all intact". Every pin below is therefore evaluated inside the
#   region that must carry it, and a token that belongs in two regions is pinned
#   twice — once per region — so each region is independently defended.
#   The three heading pins are whole-line rather than region-scoped, and that is
#   now a choice rather than a necessity: each heading also opens a region below,
#   terminated for the last one by the file-end sentinel this release added. The
#   whole-line form is kept because it catches a different edit — a heading
#   surviving as part of a longer sentence — which no region pin can see.
#   This paragraph asserted the property before it held: three groups were still
#   whole-file when it was written. Do not restate it without re-measuring —
#   `grep -n assert_in_file` naming a pin array is the counterexample.
#
# COMMENTS ARE NOT CONTENT, AND THE STRIP HAS TO HAPPEN BEFORE THE CUT.
#   Whole-file assertions (`count_lines`, `assert_in_file`, `assert_line_in_file`)
#   read through `strip_html_comments` and are sound as they stand. Region-scoped
#   assertions are NOT made comment-aware by that, and an earlier form of this
#   paragraph claimed they were: `extract_between` excludes the start line by
#   construction, so a `<!--` opened above a region's start anchor is cut away
#   before any stripper sees it, and the region reads as ordinary prose while
#   sitting inside a comment. Every region-scoped call site below therefore
#   extracts from a comment-blanked COPY of the file — see
#   `scripts/_strip-html-comments.sh`. Two anchor pairs cannot: the disclosure
#   block's fences and the reference file-end sentinel are themselves HTML
#   comments, so a blanked copy leaves them nothing to match. Those read the raw
#   file, are named at their own call sites by the raw path they pass, and stay
#   comment-blind. The one assertion that must never strip is the file-end
#   sentinel pin, which is a comment by construction.
#
# TWO SCOPE LIMITS, STATED BECAUSE THE LABELS OVERSTATE THEM.
#   (a) The negative fence's zero-occurrence sweep walks `design-audit/references`
#       only. CFI-6 says "anywhere under this skill", and this sweep does not
#       cover the rest of the tree — a loop-machinery token reintroduced under
#       another skill's directory is outside what this file measures.
#   (b) `count_lines` counts LINES containing the literal, not occurrences. Two
#       copies on one physical line read as one, so the exactly-once rules below
#       bound placement rather than multiplicity.
#
# THE REGION TERMINATOR IS ITSELF PINNED.
#   `extract_between` fails loudly when its end anchor is absent after the start
#   anchor, instead of returning a region that silently widens to end of file. A
#   widened region still contains every pinned literal, so the lint would keep
#   reporting success while checking nothing about position — the exact shape of
#   green-means-nothing this file exists to prevent.
#
# WORD-BOUNDED TOKENS.
#   `MATCH` is a substring of `MISMATCH`, so a substring pin on `MATCH` can never
#   fail on its own: deleting every independent `MATCH` verdict leaves the pin
#   satisfied by the `MISMATCH` occurrences. Verdict tokens are therefore matched
#   with ERE word boundaries.
#
# Usage:
#   bash scripts/lint-design-audit-pins.sh                  # lint real skills
#   SKILLS_ROOT=<dir> bash scripts/lint-design-audit-pins.sh   # fixture test
#
# Exit codes:
#   0 — all pins intact (or the skill is absent → skip)
#   1 — at least one pin missing, mispositioned, or a denylist token present

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

SKILL="$skills_root/design-audit/SKILL.md"
PROMPT="$skills_root/design-audit/references/01-reader-prompt.md"
CHECKS="$skills_root/design-audit/references/02-deterministic-checks.md"
ADJUST="$skills_root/design-audit/references/03-adjustment-pass.md"
DISCLOSURE="$skills_root/design-audit/references/04-disclosure-block.md"

if [[ ! -f "$SKILL" ]]; then
  echo "SKIP: design-audit/SKILL.md not found under $skills_root — skill not present"
  exit 0
fi

fail=0

# ---------- helpers -----------------------------------------------------------

# `strip_html_comments` and `stripped_copy` come from the shared helper. They
# were defined here, which is what confined the fix to whole-file assertions:
# a stripper that lives beside the assertions can only ever run after the region
# has been cut, and the cut is where the comment state is lost. Measured before
# the strip existed at all: wrapping the whole of `03-adjustment-pass.md`'s body
# in a comment — and wrapping the ENTIRETY of `04-disclosure-block.md` — both
# left this lint at exit 0, `all intact`. Deletion was caught; commenting was
# not.
# shellcheck source=./_strip-html-comments.sh
source "$script_dir/_strip-html-comments.sh"

# substantive_lines <text> — non-blank lines remaining after comment stripping.
substantive_lines() {
  printf '%s\n' "$1" | strip_html_comments | grep -cE '[^[:space:]]' || true
}

# count_lines <literal> <file> — number of lines containing the fixed literal,
# comments excluded.
# Never trips `set -e`: grep's no-match exit 1 is absorbed.
count_lines() {
  local literal="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  strip_html_comments < "$file" | grep -Fc -- "$literal" 2>/dev/null || true
}

# assert_in_file <literal> <file> <label>
assert_in_file() {
  local literal="$1" file="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return
  fi
  if ! strip_html_comments < "$file" | grep -Fq -- "$literal"; then
    echo "FAIL: $label — pinned literal missing (comments do not count): $literal" >&2
    fail=1
  fi
}

# assert_in_text <literal> <text> <label> <region>
assert_in_text() {
  local literal="$1" text="$2" label="$3" region="$4"
  if [[ "$text" == "$REGION_UNAVAILABLE" ]]; then
    echo "FAIL: $label — region-unavailable ($region), so this pin was not evaluated: $literal" >&2
    fail=1
    return
  fi
  if ! printf '%s\n' "$text" | strip_html_comments | grep -Fq -- "$literal"; then
    echo "FAIL: $label — pinned literal missing from $region (comments do not count): $literal" >&2
    fail=1
  fi
}

# assert_line_in_file <literal> <file> <label> — the literal must be a WHOLE
# line, not a substring of one. This is the shape a section heading needs: a
# heading quoted inside prose satisfies a substring pin while the section it
# names is gone, which is the failure the heading pins exist to catch. It is
# also the only available shape for the last section of a file, which has no
# following heading to serve as a region terminator.
assert_line_in_file() {
  local literal="$1" file="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return
  fi
  if ! strip_html_comments < "$file" | grep -Fxq -- "$literal"; then
    echo "FAIL: $label — pinned heading is not present as a whole line outside a comment: $literal" >&2
    fail=1
  fi
}

# assert_raw_line_in_file <literal> <file> <label> — whole-line, WITHOUT comment
# stripping. Exactly one pin needs this and it is the file-end sentinel, which
# is an HTML comment by construction: it must not render as visible content, so
# the blanket "comments do not count" rule would erase the very line it is
# asserting. Do not reach for this anywhere else — for every other pin, being
# invisible to a reader is precisely the failure being tested for.
assert_raw_line_in_file() {
  local literal="$1" file="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return
  fi
  if ! grep -Fxq -- "$literal" "$file"; then
    echo "FAIL: $label — file-end sentinel missing as a whole line: $literal" >&2
    fail=1
  fi
}

# assert_re_in_text <ere> <text> <label> <region> — for tokens that are
# substrings of one another and cannot be pinned by substring.
assert_re_in_text() {
  local ere="$1" text="$2" label="$3" region="$4"
  if [[ "$text" == "$REGION_UNAVAILABLE" ]]; then
    echo "FAIL: $label — region-unavailable ($region), so this pin was not evaluated: /$ere/" >&2
    fail=1
    return
  fi
  if ! printf '%s\n' "$text" | strip_html_comments | grep -Eq -- "$ere"; then
    echo "FAIL: $label — pinned token missing from $region (comments do not count): /$ere/" >&2
    fail=1
  fi
}

# shellcheck source=./_extract-between.sh
source "$script_dir/_extract-between.sh"

# ---------- (iii) fixed constants — SKILL.md, exactly once, inside the CFI body

CONSTANTS=(
  'READER_COUNT = 3'
  'ROUNDS_PER_READER = 1'
  'OUTER_ITERATIONS = 0'
  'ADJUSTMENT_PASSES = 1'
  'ROUND_TOKEN = 1'
  'PASS_TOKEN = fanout'
)

if invariants_body=$(extract_between '^## Control-Flow Invariants[[:space:]]*$' \
                                     '^## Workflow[[:space:]]*$' \
                                     "$(stripped_copy "$SKILL")" 'design-audit/SKILL.md (CFI body)'); then :
else fail=1; invariants_body="$REGION_UNAVAILABLE"
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

# ---------- (i)/(ii) reader prompt — two regions, each pinned on its own -------
#
# These were whole-file until the region-scoping claim in this file's header was
# measured against them and found false. The two regions are not interchangeable:
# the preamble is instructions to the LEAD about how to render the prompt, and
# the body is the text the READER receives. A byte that migrates from one to the
# other has stopped doing its job while a whole-file pin still reports it intact.

PROMPT_PREAMBLE_PINS=(
  # the byte-identity requirement that keeps reinforcement multiplicity
  # meaningful. It binds the lead at substitution time, so it must sit ABOVE the
  # prompt body — inside the body it would be an instruction to the reader about
  # a rendering the reader does not perform.
  'byte-identical'
)

PROMPT_BODY_PINS=(
  # (i) the injected round/pass token. A stateless hook matches on this line;
  # without the slot it has no match target and silently never fires.
  'This review is Round {round} of pass {pass}.'
  # the anchors a reader must cite when reporting a bookkeeping remainder
  '§검증 기록'
  '§구현 시 검증 항목'
)

if prompt_preamble=$(extract_between '^# Reader Prompt[[:space:]]*$' \
                                     '^## Prompt body[[:space:]]*$' \
                                     "$(stripped_copy "$PROMPT")" 'design-audit/references/01-reader-prompt.md (preamble)'); then :
else fail=1; prompt_preamble="$REGION_UNAVAILABLE"
fi
if prompt_body=$(extract_between '^## Prompt body[[:space:]]*$' \
                                 '^## 앵커 대조표[[:space:]]*$' \
                                 "$(stripped_copy "$PROMPT")" 'design-audit/references/01-reader-prompt.md (prompt body)'); then :
else fail=1; prompt_body="$REGION_UNAVAILABLE"
fi

for lit in "${PROMPT_PREAMBLE_PINS[@]}"; do
  assert_in_text "$lit" "$prompt_preamble" \
    'design-audit/references/01-reader-prompt.md' 'the lead-facing preamble'
done

for lit in "${PROMPT_BODY_PINS[@]}"; do
  assert_in_text "$lit" "$prompt_body" \
    'design-audit/references/01-reader-prompt.md' 'the prompt body'
done

# ---------- (ii) reader prompt — the two regions, pinned independently --------
#
# The measurement INSTRUCTION and the output-contract TABLE both carry the three
# anchor verdicts. Pinning them whole-file lets either region be deleted whole
# while the other keeps the pin satisfied, so each region is checked on its own.

if measure_region=$(extract_between '^REPO GROUND-TRUTH MEASUREMENT \(MANDATORY' \
                                    '^## 앵커 대조표[[:space:]]*$' \
                                    "$(stripped_copy "$PROMPT")" 'design-audit/references/01-reader-prompt.md (measurement clause)'); then :
else fail=1; measure_region="$REGION_UNAVAILABLE"
fi
if table_region=$(extract_between '^## 앵커 대조표[[:space:]]*$' \
                                  '^### F-\{role-slug\}-<n>' \
                                  "$(stripped_copy "$PROMPT")" 'design-audit/references/01-reader-prompt.md (anchor table)'); then :
else fail=1; table_region="$REGION_UNAVAILABLE"
fi

# Spelled one per line like every other pinned array. Inline `(a b c)` reads as
# an expression rather than a pin group, and a group whose members do not look
# like pins is a group whose members get miscounted when the coverage figure is
# taken by eye.
VERDICT_TOKENS=(
  '\bMATCH\b'
  '\bMISMATCH\b'
  '\bABSENT\b'
)

for ere in "${VERDICT_TOKENS[@]}"; do
  assert_re_in_text "$ere" "$measure_region" \
    'design-audit/references/01-reader-prompt.md' 'the measurement clause'
  assert_re_in_text "$ere" "$table_region" \
    'design-audit/references/01-reader-prompt.md' 'the anchor table'
done

MEASURE_PINS=(
  'required but created by no step'
)

for lit in "${MEASURE_PINS[@]}"; do
  assert_in_text "$lit" "$measure_region" \
    'design-audit/references/01-reader-prompt.md' 'the measurement clause'
done

# ---------- positive pins for the two reference files that had none -----------
#
# Without these, the non-recursion rules, the routing table and the synthesis
# question could all be deleted — or every MUST NOT relaxed to may — and both
# `make lint` and `make test` stayed green.
#
# ONE FILE IS EDITED TO SATISFY THIS, deliberately, and the earlier claim that
# none was is retired with it: `03-adjustment-pass.md` gained a file-end
# sentinel. Its last section had no following heading, so it had no region
# terminator, and without one neither a content pin nor a span floor can be
# scoped to it — the section would keep the weakest pin in the file precisely
# because it is last. The sentinel is itself pinned below, so deleting it to
# "clean up" fails rather than silently re-opening that hole.

# The three section headings, asserted as WHOLE LINES. A substring pin on a
# heading is satisfied by any prose that quotes it, so the section could be
# deleted and its name left behind in a sentence describing what used to be
# there. **The whole-line form is not redundant with the section pins below** —
# it is what fails when the heading survives only as part of a longer line, and
# that property had zero fixture coverage until this release added one.
REFERENCE_HEADINGS=(
  '## Non-recursion rules (hard)'
  '## Routing — five named owners, exactly one each'
  '## Synthesis question (mandatory terminal act)'
)

# The file-end sentinel that gives the last section a region terminator.
REFERENCE_SENTINEL='<!-- cc-design-audit-reference: end -->'

# Section pins: each heading opens a region that must still CONTAIN something.
# `<file-tag>|<heading-ere>|<region-end-ere>|<span-floor>|<content-literal>`
#
# TWO ASSERTIONS PER SECTION, because they fail on different edits.
#   * the content literal catches a body rewritten around the heading;
#   * the span floor catches the ordinary careless edit — heading kept, the
#     paragraphs under it deleted — which a content pin alone can miss if the
#     one pinned sentence happens to survive.
# Neither is the clever attack. The clever attacks (comment-wrapping, quoting a
# heading in prose) are closed by `strip_html_comments` and by the whole-line
# heading pins. These two close the boring one, which is the likelier one.
#
# THE FLOOR IS A FLOOR, NOT A MEASUREMENT. It is set below the section's current
# substantive-line count so ordinary editing does not trip it; lowering a floor
# is therefore a deliberate relaxation and shows up as such in a diff, which is
# the same reason the disclosure block pins its slot-count integer.
REFERENCE_SECTION_PINS=(
  '03|^## Non-recursion rules \(hard\)$|^## Dedup and reinforcement|4|Spawning anything here is the first step back toward the loop'
  '03|^## Routing — five named owners, exactly one each$|^## Synthesis question |9|The five counts must sum to the unique-defect count'
  '03|^## Synthesis question \(mandatory terminal act\)$|^<!-- cc-design-audit-reference: end -->$|3|Its final act is to ask, once, in writing'
)

# The three prose sentences, scoped to the section that must carry each. Encoded
# `<file-tag>|<region-start-ere>|<region-end-ere>|<mode>|<literal>`; `mode` is
# `include-start` where the literal lives in the region's own opening line.
REFERENCE_REGION_PINS=(
  '02|^# Deterministic Checks |^## Checks[[:space:]]*$|include-start|run ONCE, outside the replication channel'
  '02|^# Deterministic Checks |^## Checks[[:space:]]*$|exclude-start|By reference, never by copy.'
  '03|^## Severity re-assignment |^## Routing — |exclude-start|Never take a maximum across readers.'
)

for lit in "${REFERENCE_HEADINGS[@]}"; do
  assert_line_in_file "$lit" "$ADJUST" 'design-audit/references/03-adjustment-pass.md'
done

assert_raw_line_in_file "$REFERENCE_SENTINEL" "$ADJUST" \
  'design-audit/references/03-adjustment-pass.md (file-end sentinel)'

for entry in "${REFERENCE_SECTION_PINS[@]}"; do
  which_file="${entry%%|*}"
  rest="${entry#*|}"
  sec_start="${rest%%|*}"; rest="${rest#*|}"
  sec_end="${rest%%|*}";   rest="${rest#*|}"
  sec_floor="${rest%%|*}"
  sec_lit="${rest#*|}"
  case "$which_file" in
    02) target="$CHECKS"; label='design-audit/references/02-deterministic-checks.md' ;;
    03) target="$ADJUST"; label='design-audit/references/03-adjustment-pass.md' ;;
    *)  echo "FAIL: internal — unknown section-pin file tag '$which_file'" >&2; fail=1; continue ;;
  esac
  # One of these three sections is terminated by the file-end sentinel, which is
  # an HTML comment. A blanked copy leaves that anchor with nothing to match, so
  # that entry — and only that entry — reads the raw file and stays
  # comment-blind. The opt-out is derived from the anchors rather than kept as a
  # hand-maintained list, so an entry added later cannot forget to declare
  # itself, and the other two entries of this same loop keep the strip.
  case "$sec_start$sec_end" in
    *'<!--'*) sec_src="$target" ;;
    *)        sec_src=$(stripped_copy "$target") ;;
  esac
  if sec_body=$(extract_between "$sec_start" "$sec_end" \
                                "$sec_src" "$label (section /$sec_start/)"); then :
  else fail=1; sec_body="$REGION_UNAVAILABLE"
  fi
  assert_in_text "$sec_lit" "$sec_body" "$label" "the section /$sec_start/"
  if [[ "$sec_body" == "$REGION_UNAVAILABLE" ]]; then
    echo "FAIL: $label — region-unavailable (/$sec_start/), so its span floor was not evaluated" >&2
    fail=1
  else
    n=$(substantive_lines "$sec_body")
    if (( n < sec_floor )); then
      echo "FAIL: $label — section /$sec_start/ has $n substantive line(s), below its declared floor of $sec_floor; a heading kept over an emptied body is the edit this catches" >&2
      fail=1
    fi
  fi
done

for entry in "${REFERENCE_REGION_PINS[@]}"; do
  which_file="${entry%%|*}"
  rest="${entry#*|}"
  region_start="${rest%%|*}"; rest="${rest#*|}"
  region_end="${rest%%|*}";   rest="${rest#*|}"
  region_mode="${rest%%|*}"
  lit="${rest#*|}"
  case "$which_file" in
    02) target="$CHECKS"; label='design-audit/references/02-deterministic-checks.md' ;;
    03) target="$ADJUST"; label='design-audit/references/03-adjustment-pass.md' ;;
    *)  echo "FAIL: internal — unknown reference-pin file tag '$which_file'" >&2; fail=1; continue ;;
  esac
  case "$region_start$region_end" in
    *'<!--'*) region_src="$target" ;;
    *)        region_src=$(stripped_copy "$target") ;;
  esac
  if region_body=$(extract_between "$region_start" "$region_end" \
                                   "$region_src" "$label (region /$region_start/)" \
                                   "$region_mode"); then :
  else fail=1; region_body="$REGION_UNAVAILABLE"
  fi
  assert_in_text "$lit" "$region_body" "$label" "the region /$region_start/"
done

# ---------- (iv) disclosure block — slots pinned INSIDE the fences, in order --

DISCLOSURE_PINS=(
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
  '**결손 수**'
)

# The declared-shortfall arm and the integer that fences it. The arm exists so a
# run short of readers is DECLARED rather than absorbed by lowering the reviewer
# count to match; pinning it plus the slot-count integer means the arm cannot be
# removed quietly — an unpinned relaxation is textually indistinguishable from a
# deletion once the commit that made it has scrolled away.
DISCLOSURE_ARM_PINS=(
  '**결손 사유**'
  '(ii-b) Declared shortfall.'
)

# The two fences are the region anchors, so `extract_between` pins them; a slot
# key that survives only in prose outside the fences no longer satisfies its pin.
#
# FORCED EXCEPTION — this reads the RAW file, not a comment-blanked copy, and it
# is one of the two anchor pairs in this repo that cannot be pre-stripped: both
# of its anchors are HTML comments, so a blanked copy has nothing left to match
# and the region becomes unavailable on a clean tree. Removing the exception
# turns a green tree red, which is what makes it forced rather than chosen. The cost is stated
# rather than hidden: this region stays comment-blind, so commenting out the
# slot block is not what this pin catches — deleting or reordering it is.
if slot_region=$(extract_between '^<!-- cc-design-audit-disclosure v1 begin -->[[:space:]]*$' \
                                 '^<!-- /cc-design-audit-disclosure v1 end -->[[:space:]]*$' \
                                 "$DISCLOSURE" 'design-audit/references/04-disclosure-block.md (slot block)'); then :
else fail=1; slot_region="$REGION_UNAVAILABLE"
fi

for lit in "${DISCLOSURE_PINS[@]}"; do
  assert_in_text "$lit" "$slot_region" \
    'design-audit/references/04-disclosure-block.md' 'the disclosure fences'
done

# Order is part of the grammar the block declares, so it is checked, not assumed.
if [[ "$slot_region" == "$REGION_UNAVAILABLE" ]]; then
  echo "FAIL: design-audit/references/04-disclosure-block.md — region-unavailable (the disclosure fences), so slot order was not evaluated" >&2
  fail=1
else
  observed_order=$(printf '%s\n' "$slot_region" | strip_html_comments | grep -oE '^\*\*[^*]+\*\*' || true)
  expected_order=$(printf '%s\n' "${DISCLOSURE_PINS[@]}")
  if [[ "$observed_order" != "$expected_order" ]]; then
    echo "FAIL: design-audit/references/04-disclosure-block.md — slot keys are not the declared set in the declared order, one per line" >&2
    fail=1
  fi
fi

# Scoped to the checks section that defines the arm. Whole-file was the wrong
# shape for the same reason the slot keys are fenced: `(ii-b) Declared shortfall.`
# relocated into the Korean-echo section or the honest-limit note is no longer a
# check, and a whole-file pin cannot tell the two placements apart.
if checks_section=$(extract_between '^## The four anti-vacuity checks[[:space:]]*$' \
                                    '^## Honest limit[[:space:]]*$' \
                                    "$(stripped_copy "$DISCLOSURE")" 'design-audit/references/04-disclosure-block.md (anti-vacuity checks)'); then :
else fail=1; checks_section="$REGION_UNAVAILABLE"
fi

for lit in "${DISCLOSURE_ARM_PINS[@]}"; do
  assert_in_text "$lit" "$checks_section" \
    'design-audit/references/04-disclosure-block.md' 'the anti-vacuity checks section'
done

# The slot-count integer stated in the prose must equal the pinned array's size.
# Either half drifting from the other is what this catches: adding a slot without
# updating the declared count, or relaxing the count without touching the block.
if ! strip_html_comments < "$DISCLOSURE" | grep -Fq -- "exactly ${#DISCLOSURE_PINS[@]} slot lines"; then
  echo "FAIL: design-audit/references/04-disclosure-block.md — the declared slot count does not say 'exactly ${#DISCLOSURE_PINS[@]} slot lines', which is the number of slot keys pinned here" >&2
  fail=1
fi

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
  # Scoped to this skill on purpose. The token also survives in a frozen pre-yq
  # snapshot of a deleted skill under tests/fixtures/, which is outside CFI-6's
  # reach ("anywhere under this skill") — registering it with a repo-wide
  # scanner would turn that fixture red for carrying a fossil it exists to hold.
  'convergence_table.md'
)

# The denylist body is a region so the token's POSITION is bound too. Counting
# alone fixes how many times a token appears and says nothing about where: move
# the whole denylist into ordinary prose and a count-only rule stays green.
if denylist_body=$(extract_between '^### CFI-6 ' '^## Workflow[[:space:]]*$' \
                                   "$(stripped_copy "$SKILL")" 'design-audit/SKILL.md (CFI-6 denylist)'); then :
else fail=1; denylist_body="$REGION_UNAVAILABLE"
fi

for lit in "${FORBIDDEN[@]}"; do
  # Exactly one line in SKILL.md: its own denylist entry. 0 means the denylist
  # lost the token; >1 means the token is in use somewhere besides the denylist.
  n=$(count_lines "$lit" "$SKILL")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: design-audit/SKILL.md (denylist) — '$lit' must appear on exactly 1 line (its denylist entry), found $n" >&2
    fail=1
  fi
  assert_in_text "$lit" "$denylist_body" \
    'design-audit/SKILL.md (denylist)' 'the CFI-6 denylist body'
done

# Zero occurrences anywhere under references/.
if [[ -d "$skills_root/design-audit/references" ]]; then
  while IFS= read -r ref; do
    for lit in "${FORBIDDEN[@]}"; do
      if strip_html_comments < "$ref" | grep -Fq -- "$lit"; then
        echo "FAIL: ${ref#"$skills_root/"} — loop-machinery token present: $lit" >&2
        fail=1
      fi
    done
  done < <(find "$skills_root/design-audit/references" -type f -name '*.md' | sort)
fi

if (( fail == 0 )); then
  # Every pinned literal belongs to a counted array, and every array's size is
  # named on this line. That is deliberate: a literal whose group size is not
  # reported here would be droppable without changing any output, so the OK
  # fixture could not detect its removal and the pin would have no independent
  # coverage. Adding a pin means adding it to an array, never as a loose call.
  echo "OK:   design-audit pins — ${#CONSTANTS[@]} constants (CFI body) + ${#PROMPT_PREAMBLE_PINS[@]} reader-prompt preamble + ${#PROMPT_BODY_PINS[@]} reader-prompt body + ${#MEASURE_PINS[@]} measurement + ${#VERDICT_TOKENS[@]} verdict tokens (each checked in 2 regions) + ${#REFERENCE_HEADINGS[@]} reference headings (whole-line) + 1 file-end sentinel + ${#REFERENCE_SECTION_PINS[@]} reference sections (content + span floor) + ${#REFERENCE_REGION_PINS[@]} reference prose (region-scoped) + ${#DISCLOSURE_PINS[@]} disclosure (in-fence, ordered) + ${#DISCLOSURE_ARM_PINS[@]} shortfall arm (in checks section) + ${#FORBIDDEN[@]} denylist (in CFI-6) all intact"
fi

exit "$fail"
