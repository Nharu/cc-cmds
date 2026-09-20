#!/usr/bin/env bash
# Pin the load-bearing literals of the reviewer/reader model tier.
#
# The tier exists because seat models were chosen per run from prose
# ("size, complexity, the depth the role needs") and every seat ended up on
# the same model anyway. Collapsing the choice to one table only helps if the
# collapse is held in place, so four things are pinned here:
#
#   (i)   every class id occurs on exactly ONE row of the tier file's table,
#         AND that row's model cell holds the model the class is supposed to
#         get. A duplicate row is how a class quietly acquires two models, and
#         a missing row is how a seat falls through to the unclassified
#         fallback while looking classified. Pinning the id alone leaves the
#         binding this whole lever exists for unpinned: flipping `security` to
#         `sonnet`, or deleting the model column outright, keeps every class id
#         on exactly one row. So the expected model is restated here. The
#         duplication is the point — a pin that reads the same file it guards
#         guards nothing.
#   (ii)  each of the four skills that CHOOSE a seat model carries a Read
#         pointer to the tier file. A skill that stops reading it keeps
#         choosing — just from nothing.
#   (iii) a NEGATIVE fence: the three sentences the tier replaced must not
#         reappear anywhere under the skills root. Each of them instructs a
#         lead to decide the model itself, so a single one surviving a merge
#         puts a second, contradictory rule back in front of the same reader.
#   (iv)  the report template carries the `모델 티어` block exactly once. The
#         block is what makes requested-vs-served comparable after the fact;
#         zero occurrences lose the record and two make it ambiguous which
#         one a reader fills.
#
# Posture: skip-if-absent. With the tier file gone the whole lint skips, so
# reverting the lever leaves the tree green instead of making the revert break
# `make check`.
#
# Usage:
#   bash scripts/lint-team-model-tier-pins.sh
#   SKILLS_ROOT=<dir> bash scripts/lint-team-model-tier-pins.sh   # fixture test
#
# Exit codes:
#   0 — all pins intact, or the tier file is absent
#   1 — at least one pin broken

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
# A fixture runner passes the root with a trailing slash. Strip it: paths are
# built from this value by concatenation and a doubled separator would make a
# file lookup miss while reporting the file absent.
while [[ "$skills_root" == */ && "$skills_root" != "/" ]]; do
  skills_root="${skills_root%/}"
done

TIER="$skills_root/_common/team-model-tier.md"
TEMPLATE="$skills_root/review/references/02-review-report-template.md"

# The skills bound by the tier file — the ones whose step CHOOSES a model.
# `review-lite` and `design-lite` write a literal and are deliberately absent.
BOUND_SKILLS=(
  review
  review-unattended
  design-audit
  design-audit-unattended
)

# `<class id> <model>` — the binding the tier file exists to hold still.
CLASS_ROWS=(
  'security opus'
  'contract opus'
  'data opus'
  'concurrency opus'
  'integration opus'
  'coordinator opus'
  'logic sonnet'
  'performance sonnet'
  'tests sonnet'
  'conformance sonnet'
  'quality sonnet'
  'portability sonnet'
  'audit-reader opus'
)

# The sentences the tier replaced. Each one told a lead to pick the model on
# its own, which is the state this lever exists to end.
RETIRED_PHRASES=(
  'Do not fix defaults'
  'rather than fixing defaults'
  'omits `model`'
)

POINTER='_common/team-model-tier.md'
TEMPLATE_LINE='- **모델 티어**:'

if [[ ! -f "$TIER" ]]; then
  echo "SKIP: _common/team-model-tier.md not found under $skills_root"
  exit 0
fi

fail=0
checked=0

# count_in_file <literal> <file>
count_in_file() {
  [[ -f "$2" ]] || { echo 0; return; }
  grep -Fc -- "$1" "$2" 2>/dev/null || true
}

# ---------- (i) one table row per class id, carrying that class's model ------

# row_model <class id> — the last non-empty cell of that class's table row.
# A markdown row splits on `|` into a leading empty field, the cells, and a
# trailing empty field, so the model is $(NF-1). Deleting the model column
# shifts `covers` into that slot, which is why this catches the deletion too.
row_model() {
  grep -F -- "| \`$1\` |" "$TIER" 2>/dev/null \
    | awk -F'|' 'NR == 1 { cell = $(NF-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell); print cell }'
}

for row in "${CLASS_ROWS[@]}"; do
  cid=${row%% *}
  want=${row##* }

  checked=$((checked + 1))
  # The row anchor is the first cell verbatim, which no prose line carries.
  n=$(count_in_file "| \`$cid\` |" "$TIER")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: _common/team-model-tier.md — class id '$cid' must occupy exactly 1 table row, found $n" >&2
    fail=1
  fi

  checked=$((checked + 1))
  got=$(row_model "$cid")
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: _common/team-model-tier.md — class '$cid' must bind model '$want', found '$got'" >&2
    fail=1
  fi
done

# ---------- (ii) the four bound skills point at the tier file ----------------

for skill in "${BOUND_SKILLS[@]}"; do
  target="$skills_root/$skill/SKILL.md"
  # Gated on the SKILL.md existing: a fixture root carries only the files its
  # case is about, and a missing skill there is not this lint's finding.
  [[ -f "$target" ]] || continue
  checked=$((checked + 1))
  n=$(count_in_file "$POINTER" "$target")
  if [[ "$n" == "0" ]]; then
    echo "FAIL: $skill/SKILL.md — chooses a seat model but carries no Read pointer to $POINTER" >&2
    fail=1
  fi
done

# ---------- (iii) negative fence — the retired sentences stay retired --------

while IFS= read -r target; do
  [[ -f "$target" ]] || continue
  rel=${target#"$skills_root/"}
  for phrase in "${RETIRED_PHRASES[@]}"; do
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      echo "FAIL: $rel:${hit%%:*} — retired model-choice sentence is back: $phrase" >&2
      fail=1
    done < <(grep -nF -- "$phrase" "$target" || true)
  done
done < <(
  {
    find "$skills_root" -mindepth 2 -maxdepth 2 -name '*.md'
    find "$skills_root" -mindepth 3 -maxdepth 3 -path '*/references/*.md'
  } | sort
)
checked=$((checked + 1))

# ---------- (iv) the report template's record block --------------------------

if [[ -f "$TEMPLATE" ]]; then
  checked=$((checked + 1))
  n=$(count_in_file "$TEMPLATE_LINE" "$TEMPLATE")
  if [[ "$n" != "1" ]]; then
    echo "FAIL: review/references/02-review-report-template.md — '$TEMPLATE_LINE' must appear exactly once, found $n" >&2
    fail=1
  fi
fi

if (( fail == 0 )); then
  echo "OK:   team model tier pins — $checked check(s) intact, fence clean"
fi

exit "$fail"
