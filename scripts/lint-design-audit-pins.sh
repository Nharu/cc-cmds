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

# assert_re_in_text <ere> <text> <label> <region> — for tokens that are
# substrings of one another and cannot be pinned by substring.
assert_re_in_text() {
  local ere="$1" text="$2" label="$3" region="$4"
  if ! printf '%s\n' "$text" | grep -Eq -- "$ere"; then
    echo "FAIL: $label — pinned token missing from $region: /$ere/" >&2
    fail=1
  fi
}

# extract_between <start_ere> <end_ere> <file> <label> [include-start]
# Prints the lines between the first line matching <start_ere> and the first
# subsequent line matching <end_ere>. The start line is excluded unless the
# fifth argument is `include-start`, which a single-line region needs. Both
# anchors are pinned: a missing start, or an end that never occurs after the
# start, is a loud failure. It replaces two same-named extractors that had
# drifted into different semantics (one included its heading and kept scanning,
# the other did neither) — so this body is kept byte-identical to the copy in
# `lint-verification-literals.sh`, which is the whole point of collapsing them.
extract_between() {
  local start_ere="$1" end_ere="$2" file="$3" label="$4" mode="${5:-exclude-start}"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $label — file not found: $file" >&2
    fail=1
    return 0
  fi
  if ! grep -Eq -- "$start_ere" "$file"; then
    echo "FAIL: $label — region start anchor missing: /$start_ere/" >&2
    fail=1
    return 0
  fi
  # The regexes travel through the environment, not through `awk -v`: `-v`
  # processes escape sequences in the value, so a `\(` in the pattern would
  # reach awk as a bare `(` and open an unterminated group.
  if ! SC_START="$start_ere" SC_END="$end_ere" awk '
        BEGIN { s = ENVIRON["SC_START"]; e = ENVIRON["SC_END"] }
        !started && $0 ~ s { started = 1; next }
        started && $0 ~ e  { found = 1; exit }
        END { exit(found ? 0 : 1) }
      ' "$file"; then
    echo "FAIL: $label — region terminator literal missing after the start anchor: /$end_ere/" >&2
    fail=1
    return 0
  fi
  SC_START="$start_ere" SC_END="$end_ere" SC_MODE="$mode" awk '
    BEGIN { s = ENVIRON["SC_START"]; e = ENVIRON["SC_END"]
            inc = (ENVIRON["SC_MODE"] == "include-start") }
    started && $0 ~ e { exit }
    !started && $0 ~ s { started = 1; if (inc) print; next }
    started { print }
  ' "$file"
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

invariants_body=$(extract_between '^## Control-Flow Invariants[[:space:]]*$' \
                                  '^## Workflow[[:space:]]*$' \
                                  "$SKILL" 'design-audit/SKILL.md (CFI body)')

for lit in "${CONSTANTS[@]}"; do
  n=$(count_lines "$lit" "$SKILL")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: design-audit/SKILL.md (constants) — '$lit' must appear on exactly 1 line, found $n" >&2
    fail=1
  fi
  assert_in_text "$lit" "$invariants_body" \
    "design-audit/SKILL.md (constants)" "the '## Control-Flow Invariants' body"
done

# ---------- (i)/(ii) reader prompt — whole-file pins ---------------------------

PROMPT_PINS=(
  # (i) the injected round/pass token. A stateless hook matches on this line;
  # without the slot it has no match target and silently never fires.
  'This review is Round {round} of pass {pass}.'
  # the anchors a reader must cite when reporting a bookkeeping remainder
  '§검증 기록'
  '§구현 시 검증 항목'
  # the byte-identity requirement that keeps reinforcement multiplicity meaningful
  'byte-identical'
)

for lit in "${PROMPT_PINS[@]}"; do
  assert_in_file "$lit" "$PROMPT" "design-audit/references/01-reader-prompt.md"
done

# ---------- (ii) reader prompt — the two regions, pinned independently --------
#
# The measurement INSTRUCTION and the output-contract TABLE both carry the three
# anchor verdicts. Pinning them whole-file lets either region be deleted whole
# while the other keeps the pin satisfied, so each region is checked on its own.

measure_region=$(extract_between '^REPO GROUND-TRUTH MEASUREMENT \(MANDATORY' \
                                 '^## 앵커 대조표[[:space:]]*$' \
                                 "$PROMPT" 'design-audit/references/01-reader-prompt.md (measurement clause)')
table_region=$(extract_between '^## 앵커 대조표[[:space:]]*$' \
                               '^### F-\{role-slug\}-<n>' \
                               "$PROMPT" 'design-audit/references/01-reader-prompt.md (anchor table)')

VERDICT_TOKENS=('\bMATCH\b' '\bMISMATCH\b' '\bABSENT\b')

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
# `make lint` and `make test` stayed green. The pinned bytes already exist; no
# file is edited to satisfy this.

REFERENCE_PINS=(
  "02|run ONCE, outside the replication channel"
  "02|By reference, never by copy."
  "03|## Non-recursion rules (hard)"
  "03|## Routing — five named owners, exactly one each"
  "03|## Synthesis question (mandatory terminal act)"
  "03|Never take a maximum across readers."
)

for entry in "${REFERENCE_PINS[@]}"; do
  which_file="${entry%%|*}"
  lit="${entry#*|}"
  case "$which_file" in
    02) target="$CHECKS"; label='design-audit/references/02-deterministic-checks.md' ;;
    03) target="$ADJUST"; label='design-audit/references/03-adjustment-pass.md' ;;
    *)  echo "FAIL: internal — unknown reference-pin file tag '$which_file'" >&2; fail=1; continue ;;
  esac
  assert_in_file "$lit" "$target" "$label"
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
)

# The two fences are the region anchors, so `extract_between` pins them; a slot
# key that survives only in prose outside the fences no longer satisfies its pin.
slot_region=$(extract_between '^<!-- cc-design-audit-disclosure v1 begin -->[[:space:]]*$' \
                              '^<!-- /cc-design-audit-disclosure v1 end -->[[:space:]]*$' \
                              "$DISCLOSURE" 'design-audit/references/04-disclosure-block.md (slot block)')

for lit in "${DISCLOSURE_PINS[@]}"; do
  assert_in_text "$lit" "$slot_region" \
    'design-audit/references/04-disclosure-block.md' 'the disclosure fences'
done

# Order is part of the grammar the block declares, so it is checked, not assumed.
observed_order=$(printf '%s\n' "$slot_region" | grep -oE '^\*\*[^*]+\*\*' || true)
expected_order=$(printf '%s\n' "${DISCLOSURE_PINS[@]}")
if [[ "$observed_order" != "$expected_order" ]]; then
  echo "FAIL: design-audit/references/04-disclosure-block.md — slot keys are not the declared set in the declared order, one per line" >&2
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
)

# The denylist body is a region so the token's POSITION is bound too. Counting
# alone fixes how many times a token appears and says nothing about where: move
# the whole denylist into ordinary prose and a count-only rule stays green.
denylist_body=$(extract_between '^### CFI-6 ' '^## Workflow[[:space:]]*$' \
                                "$SKILL" 'design-audit/SKILL.md (CFI-6 denylist)')

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
      if grep -Fq -- "$lit" "$ref"; then
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
  echo "OK:   design-audit pins — ${#CONSTANTS[@]} constants (CFI body) + ${#PROMPT_PINS[@]} reader-prompt + ${#MEASURE_PINS[@]} measurement + ${#VERDICT_TOKENS[@]} verdict tokens x2 regions + ${#REFERENCE_PINS[@]} reference + ${#DISCLOSURE_PINS[@]} disclosure (in-fence, ordered) + ${#FORBIDDEN[@]} denylist (in CFI-6) all intact"
fi

exit "$fail"
