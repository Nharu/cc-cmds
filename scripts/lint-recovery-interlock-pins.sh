#!/usr/bin/env bash
# Pin the prose of the recovery arm's termination-predicate interlock.
#
# The interlock is stated twice — once as instructions in the unattended
# review arm and once as a contract in the report template — and the two
# statements have to agree or the arm emits a line the template forbids.
# Four review cycles on this slice produced thirteen P1 findings and ten of
# them were prose contracts drifting apart, so the agreement is pinned here
# the way this repo already pins ledger row length, watcher thresholds and
# cutpoint vocabulary: a fixed literal per load-bearing clause, counted
# against the source of truth.
#
# ---------------------------------------------------------------------------
# WHAT THIS LINT MEASURES
#
#   (i)   EMISSION AND SUPPRESSION ARE STATED AS A PAIR IN BOTH FILES. The
#         emission condition carries three conjuncts and the suppression
#         clause carries their negation, in the arm and in the template
#         alike. Each of the four clauses is asserted to occur exactly once,
#         so deleting one — the way a rewrite deletes a clause it thinks is
#         redundant — is caught rather than absorbed.
#   (ii)  THE `equals` FORM STAYS BURIED (negative fence). An earlier cycle
#         replaced "every resolution round EQUALS the last recorded round"
#         with "no resolution round is BELOW it", because the equals form
#         decided neither emission nor suppression for a role that ran ahead
#         of the ledger column. The fence keys on equals-shaped phrasing so
#         the discarded form cannot come back in either file.
#   (iii) THE RESOLUTION-ROUND DEFINITION LIVES IN EXACTLY ONE PLACE — once
#         in the arm, never in the template. Two definitions is the defect a
#         previous cycle closed; a second copy drifts silently because both
#         copies read plausibly on their own.
#   (iv)  THE PLACES THAT STATE THE COMPARISON ALL STATE THE SAME ONE. The
#         two comparison phrasings are counted across each whole section, so
#         a fifth site appearing with its own wording, or one of the known
#         sites quietly losing its comparison, moves a total.
#   (v)   THE TWO DISCLOSURES THAT COST THE LAST CYCLE A FINDING. The arm and
#         the template each carry, in one pinned sentence, the fact that the
#         ledger-column comparand falls with the work on a crash before the
#         round-2 flip — so a round-1-only corpus in which every seat resolved
#         at the highest round it reached emits the ordinary line. That sentence
#         is the only place the hole is written down.
#   (vi)  THE REAP-STAMP CLAIM STAYS RETRACTED (negative fence). "the size of
#         the window is recoverable after the fact" must not reappear in the
#         arm; the stamp carries no timestamp, so the claim is false and it
#         sat directly in front of this arm's acceptance argument.
#   (vii) THE PROVENANCE TABLE CARRIES BOTH ROUNDS. Resolution round and
#         reached round in the arm's item 9 and in the template's skeleton,
#         which is what makes a descended seat visible to a reader.
#  (viii) THE THREE ANCHORS ARE PRESENT TOGETHER, OR ABSENT TOGETHER WITH THE
#         PROSE GONE. A partial set is a retitle rather than a revert, and it is
#         a failure; so is a set that is wholly absent while the pinned interlock
#         prose is still in the file, which is what retitling, deleting or
#         demoting all three at once produces. Both checks are floors on the
#         assertion set rather than assertions, so neither moves the `checked`
#         total.
#
# WHAT THIS LINT DOES NOT MEASURE — stated because a pin that is believed to
# check more than it checks is worse than no pin.
#
#   * IT DOES NOT EVALUATE PROPOSITIONS. What is fixed is wording, not logic.
#     Two clauses can both be present and no longer be each other's exact
#     complement; this lint passes on that.
#   * IT DOES NOT SAY THE COMPARAND IS RIGHT. It freezes the current state,
#     in which the first comparison reads the ledger's own round column. That
#     column falls with the work when a crash lands before the round-2 flip,
#     so a round-1-only recovery in which every seat resolved at the highest
#     round it reached still emits the ordinary line. GREEN HERE DOES NOT MEAN
#     THE INTERLOCK IS CORRECT — it means the wording did not move. Item (v)
#     pins the sentence that admits the hole, not a fix for it.
#   * IT DOES NOT REACH THE DRIVER. `run.sh` lives outside SKILLS_ROOT, so
#     the regex that matches the findings-summary line and the fact that the
#     partial-recovery line does not match it are owned by
#     `plugins/cc-cmds/orchestrator/test-run.sh`, not by this script.
#   * IT DOES NOT REACH `CHANGELOG.md` OR `docs/`. Both are outside
#     SKILLS_ROOT. A claim corrected in one of those and left standing in a
#     skill file is exactly the drift that produced a P1, and this lint sees
#     only the skill-file half of it.
#   * IT FOLDS WHITESPACE, AND NOTHING ELSE. Line wrapping inside a paragraph
#     is erased before comparison, which is why the template's wrapped prose
#     is reachable at all. Emphasis markers, punctuation and word choice are
#     not normalised — a reworded clause fails. The direction is fail-closed:
#     the failure is loud and the fix is to re-pin deliberately.
#   * IT DOES NOT PARSE MARKDOWN FENCES. Section extraction stops at the
#     first line that looks like a heading of the same level or higher, and a
#     heading inside a ``` block looks exactly like one. Pins that live past
#     such a fence are asserted file-wide instead, and that is why some
#     assertions below are file-scoped rather than section-scoped.
#   * ITS SKIP-IF-ABSENT POSTURE IS SECTION-GRAINED AND QUALIFIED BY THE PROSE.
#     Removing all three interlock anchors **together with the clauses they
#     head** leaves the tree green, so reverting the feature does not have to
#     fight `make check`. Removing one clause from a section that is still
#     present turns the tree red — that is the thing being pinned. Retitling one
#     anchor while the others stand turns the tree red as well, and so does
#     retitling all three: a retitle is not a revert, and a silently skipped
#     block would report success for exactly the rewrite being guarded against.
#   * IT DOES NOT SURVIVE A WHOLESALE REWRITE. The all-or-nothing gate above
#     keys on three headings and the absent branch keys on five literals, so the
#     state it still passes is the one where all three headings are retitled and
#     every pinned clause is rewritten at the same time — an interlock rebuilt
#     from scratch under new headings. That is one edit further out than the
#     state this lint was last extended to catch, and it is named here rather
#     than claimed closed: what would close it is a check on the interlock's
#     *meaning* rather than on its wording, which this script does not do and
#     the first bullet of this list already says it does not do.
# ---------------------------------------------------------------------------
#
# Usage:
#   bash scripts/lint-recovery-interlock-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-recovery-interlock-pins.sh  # fixture
#
# Exit codes:
#   0 — all present pins intact (all three anchors absent **and the pinned
#       prose gone with them** ⇒ skipped)
#   1 — at least one pin broken, or the anchors are only partially present

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
# A fixture runner passes the root with a trailing slash. Strip it so the
# paths built below carry no doubled separator.
while [[ "$skills_root" == */ && "$skills_root" != "/" ]]; do
  skills_root="${skills_root%/}"
done

ARM="$skills_root/review-unattended/SKILL.md"
TPL="$skills_root/review/references/02-review-report-template.md"

ARM_HEADING='## Recovery arm (`--recover`)'
TPL_HEADING='## Recovery report — the termination-predicate interlock'
TPL_VARIANT_HEADING='### Recovery-report variant'

fail=0
checked=0

# ---------- helpers -----------------------------------------------------------

# has_heading <file> <exact-heading-line>
has_heading() {
  [[ -f "$1" ]] && grep -Fxq -- "$2" "$1"
}

# extract_section <file> <exact-heading-line>
# Prints the heading line plus its body, stopping at the next heading of the
# same level or higher. Fence-blind by design — see the header.
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

# fold_text <text>
# Collapses each paragraph onto one line: whitespace runs become one space and
# wrapped lines are joined, while blank lines stay as paragraph boundaries. The
# join is what makes a clause that the template wraps across three lines
# reachable by a fixed-string search; keeping the boundaries is what stops two
# unrelated paragraphs from being spliced into a match that neither contains.
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

# fold_file <file>
fold_file() {
  [[ -f "$1" ]] || return 0
  fold_text "$(cat "$1")"
}

# count_occurrences <literal> <folded-text>
# Occurrences, not matching lines: a folded paragraph is one line, so a
# line-counting form would report 1 for a clause that had been duplicated
# inside the same paragraph — which is one of the states being pinned against.
count_occurrences() {
  local n
  n=$(printf '%s\n' "$2" | grep -oF -- "$1" | grep -c '' || true)
  printf '%s' "${n:-0}"
}

# assert_count <literal> <folded-text> <want> <label>
assert_count() {
  local literal="$1" text="$2" want="$3" label="$4" n
  checked=$((checked + 1))
  n=$(count_occurrences "$literal" "$text")
  if [[ "$n" != "$want" ]]; then
    echo "FAIL: $label — expected $want occurrence(s), found $n: $literal" >&2
    fail=1
  fi
}

# assert_absent_re <ere> <folded-text> <label>
assert_absent_re() {
  local re="$1" text="$2" label="$3" hit
  checked=$((checked + 1))
  hit=$(printf '%s\n' "$text" | grep -oE -- "$re" | grep -c '' || true)
  if [[ "${hit:-0}" != "0" ]]; then
    echo "FAIL: $label — discarded phrasing is back ($hit match(es)): $re" >&2
    fail=1
  fi
}

# The equals form both files discarded. Applied to each section that is
# present, in either file, because the form's whole failure mode was living in
# one file while the other carried the below form.
EQUALS_FENCE='resolution rounds? (is|are) equal|equal to the last (recorded )?round|rounds equal the last'

# ---------- the anchors, as one set ------------------------------------------

arm_present=0
tpl_present=0
var_present=0
if has_heading "$ARM" "$ARM_HEADING"; then arm_present=1; fi
if has_heading "$TPL" "$TPL_HEADING"; then tpl_present=1; fi
if has_heading "$TPL" "$TPL_VARIANT_HEADING"; then var_present=1; fi

# The three anchors are one feature, so the only two honest states are all three
# present and none present. A partial set is what a retitle produces, and a
# retitle is the rewrite this lint exists to catch — skipping the block of a
# missing anchor silently would report success for exactly that edit. This is a
# floor on the assertion set rather than an assertion, so it does not move
# `checked`: an unchanged tree still reports the same total it did before.
present=$((arm_present + tpl_present + var_present))
if (( present != 0 && present != 3 )); then
  echo "FAIL: interlock anchors are partially present (arm=$arm_present template=$tpl_present variant=$var_present)" >&2
  fail=1
fi

# Absent anchors are a revert only if the prose went with them. Retitling,
# deleting or demoting all three at once leaves every pinned clause in place
# while skipping every block that would have checked it, so the absent state is
# qualified by the prose it is supposed to have taken away. Skip-on-missing is
# untouched: a root holding neither file folds to nothing and matches nothing,
# which is the posture the four sibling pin lints share. Like the partial gate
# above this is a floor on the assertion set rather than an assertion, so it
# does not move `checked`.
if (( present == 0 )); then
  for pin_file in "$ARM" "$TPL"; do
    pin_body=$(fold_file "$pin_file")
    [[ -n "$pin_body" ]] || continue
    for pin_literal in \
      'resolution round is below' \
      '발견 요약(부분 복구)' \
      'every role resolved to `witness`' \
      '최저 계층 라운드 미달' \
      'What the ledger-round term catches'
    do
      if [[ "$(count_occurrences "$pin_literal" "$pin_body")" != "0" ]]; then
        echo "FAIL: interlock anchors are all absent but pinned interlock prose is still in $pin_file: $pin_literal" >&2
        fail=1
      fi
    done
  done
fi

# ---------- the arm (skip-if-absent) -----------------------------------------

if (( arm_present )); then
  arm_body=$(fold_text "$(extract_section "$ARM" "$ARM_HEADING")")
  arm_file=$(fold_file "$ARM")
  arm_label="review-unattended/SKILL.md ($ARM_HEADING)"

  # (i) the pair, arm side
  assert_count \
    "no role's resolution round is below the last round the ledger block's \`round/phase\` column records" \
    "$arm_body" 1 "$arm_label — emission, ledger comparison"
  assert_count \
    "or if every role resolved to \`witness\` but any of them did so at a round below that last recorded round" \
    "$arm_body" 1 "$arm_label — suppression, ledger comparison"
  assert_count \
    "no role's resolution round is below the highest round at which that role left anything at all" \
    "$arm_body" 1 "$arm_label — emission, reached-round comparison"
  assert_count \
    "or if any role's resolution round is below the highest round at which that role left anything at all" \
    "$arm_body" 1 "$arm_label — suppression, reached-round comparison"

  # The reached-round comparand is not a new input; it is the value the ladder
  # already starts from. If that sentence goes, the suppression clause above
  # starts costing an input it does not cost.
  assert_count \
    'start at the highest round at which that role left anything at all' \
    "$arm_body" 1 "$arm_label — the ladder's starting round"

  # (iii) one definition, and it is here
  assert_count \
    "The role's **resolution round** is" \
    "$arm_body" 1 "$arm_label — resolution-round definition"

  # (iv) totals across the section
  assert_count \
    'resolution round is below the last round the ledger block' \
    "$arm_body" 1 "$arm_label — ledger comparison, section total"
  assert_count \
    'resolution round is below the highest round at which that role left anything at all' \
    "$arm_body" 2 "$arm_label — reached-round comparison, section total"

  # (v) the disclosure
  assert_count \
    'What the ledger-round term catches is bounded by its comparand' \
    "$arm_body" 1 "$arm_label — comparand-falls-with-the-work disclosure"

  # (vii) both rounds in the provenance row spec
  assert_count \
    'role / tier / resolution round / **reached round** / file' \
    "$arm_body" 1 "$arm_label — provenance row carries both rounds"

  # (vi) the retracted claim, file-wide: the sentence sat in this section, but
  # a rewrite that moves it elsewhere in the file re-publishes it just as well.
  assert_count \
    'the size of the window is recoverable after the fact' \
    "$arm_file" 0 "review-unattended/SKILL.md — retracted reap-stamp claim"

  # (ii)
  assert_absent_re "$EQUALS_FENCE" "$arm_body" "$arm_label"
fi

# ---------- the template (skip-if-absent) ------------------------------------

if (( tpl_present )); then
  tpl_body=$(fold_text "$(extract_section "$TPL" "$TPL_HEADING")")
  tpl_file=$(fold_file "$TPL")
  tpl_label="review/references/02-review-report-template.md ($TPL_HEADING)"

  # (i) the pair, template side
  assert_count \
    "every role resolved to \`witness\` but any of them did so at a round below the last round the ledger block records" \
    "$tpl_body" 1 "$tpl_label — suppression, ledger comparison"
  assert_count \
    "or in which any role's resolution round is below the highest round at which that role left anything at all" \
    "$tpl_body" 1 "$tpl_label — suppression, reached-round comparison"
  assert_count \
    "every role resolved to \`witness\`, no role's resolution round is below the last round the ledger block records, and no role's resolution round is below the highest round at which that role left anything at all" \
    "$tpl_body" 1 "$tpl_label — emission, both comparisons"

  # (v) the round-1-only case and the hole it leaves named
  assert_count \
    'That case takes the partial-recovery line with `최저 계층 라운드 미달` where the ledger block records a round of 2 or higher, and also where any seat resolved at a round below the one it reached' \
    "$tpl_body" 1 "$tpl_label — the round-1-only case names both conditions"
  assert_count \
    'Where the ledger block records only round 1, neither condition fires on any corpus in which every seat resolved to `witness` at the highest round it reached, and that is a hole rather than a design.' \
    "$tpl_body" 1 "$tpl_label — the hole is written down"

  # (iii) the definition does NOT live here
  assert_count \
    "The role's **resolution round** is" \
    "$tpl_body" 0 "$tpl_label — resolution-round definition must not be restated"

  # (iv) totals across the section
  assert_count \
    'resolution round is below the last round the ledger block' \
    "$tpl_body" 1 "$tpl_label — ledger comparison, section total"
  assert_count \
    'resolution round is below the highest round at which that role left anything at all' \
    "$tpl_body" 2 "$tpl_label — reached-round comparison, section total"

  # (ii)
  assert_absent_re "$EQUALS_FENCE" "$tpl_body" "$tpl_label"

  # (vii) the skeleton and its reader live past a ``` fence, so file-scoped.
  assert_count \
    '| 역할 | 계층 | 해소 라운드 | 도달 라운드 | 파일 | seq | nonce 미검증 |' \
    "$tpl_file" 1 "02-review-report-template.md — provenance skeleton carries both rounds"
  assert_count \
    "is the **minimum** of this table's \`해소 라운드\` column" \
    "$tpl_file" 1 "02-review-report-template.md — 최저 라운드 names which column it minimises"
fi

# ---------- the variant section (skip-if-absent) -----------------------------

if (( var_present )); then
  var_body=$(fold_text "$(extract_section "$TPL" "$TPL_VARIANT_HEADING")")
  var_label="02-review-report-template.md ($TPL_VARIANT_HEADING)"

  assert_count \
    "the ordinary line when every role resolved to \`witness\`, no role's resolution round is below the last round the ledger block records, and no role's resolution round is below the highest round at which that role left anything at all" \
    "$var_body" 1 "$var_label — emission restated with both comparisons"
  assert_absent_re "$EQUALS_FENCE" "$var_body" "$var_label"
fi

if (( checked == 0 && fail == 0 )); then
  echo "SKIP: no recovery interlock section found under $skills_root"
  exit 0
fi

if (( fail == 0 )); then
  echo "OK:   recovery interlock pins — $checked assertion(s) intact"
fi

exit "$fail"
