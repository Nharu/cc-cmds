#!/usr/bin/env bash
# Lint SKILL.md files for two invariants:
#   (A) Position rule — every non-exempt SKILL.md places a
#       "## Control-Flow Invariants" section within the first ~4000 tokens
#       (approximated by words × 1.3).
#   (B) Phrase-presence sync rule — for each (base, lite) pair where the lite
#       skill inlines the base's invariants, both files MUST contain every
#       REQUIRED phrase verbatim within their Control-Flow Invariants body.
#       Permits structural simplification (lite may omit auto-decide rows etc.)
#       while enforcing termination-contract phrase sync.
#
# Rationale: post-compaction reattaches only the first ~5K tokens of SKILL.md
# with priority. Control-flow invariants placed beyond that boundary may be
# summarized away, causing silent mis-termination of the orchestration loop.
# The 4000-token lint cap leaves ~20% safety margin under the 5K budget.
# Phrase sync prevents lite drift from base's termination contract.
#
# Usage:
#   bash scripts/lint-skill-invariants.sh                # lint all plugin skills
#   bash scripts/lint-skill-invariants.sh path/to/SKILL.md [more.md ...]
#
# Exit codes:
#   0 — all inputs pass
#   1 — at least one input failed
#   2 — invalid invocation

set -euo pipefail

TOKEN_BUDGET=4000
WORDS_PER_TOKEN_RATIO=1.3   # tokens ≈ words × 1.3 (conservative over-estimate)
INVARIANT_HEADING='^## Control-Flow Invariants[[:space:]]*$'

# Skills that are exempt from rule (A) — tiny orchestration-only skills that
# have no outer/inner termination loop and cannot silently mis-terminate.
EXEMPT_SKILLS=("design-upgrade" "implement" "design" "review" "design-lite" "review-lite")

# Resolve skills root (allow SKILLS_ROOT env override for tests).
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# Collect input files
if [[ $# -eq 0 ]]; then
  # Portable alternative to `mapfile` (not available in bash 3.2 / macOS)
  FILES=()
  while IFS= read -r line; do
    FILES+=("$line")
  done < <(find "$skills_root" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
else
  FILES=("$@")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-skill-invariants: no SKILL.md files to check" >&2
  exit 2
fi

fail=0

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — file not found" >&2
    fail=1
    continue
  fi

  # Determine skill name from path: .../skills/<name>/SKILL.md
  skill_name=$(basename "$(dirname "$file")")

  # Check exemption
  exempt=false
  for e in "${EXEMPT_SKILLS[@]}"; do
    if [[ "$skill_name" == "$e" ]]; then
      exempt=true
      break
    fi
  done

  if [[ "$exempt" == "true" ]]; then
    echo "SKIP: $file — skill '$skill_name' is exempt (no termination-loop invariants)"
    continue
  fi

  # Count words and approximate tokens
  word_count=$(wc -w < "$file" | tr -d ' ')
  approx_tokens=$(awk -v w="$word_count" -v r="$WORDS_PER_TOKEN_RATIO" 'BEGIN{printf "%.0f", w*r}')

  # Find the first line of the invariant heading; if none, fail immediately
  heading_line=$(grep -n -E "$INVARIANT_HEADING" "$file" | head -1 | cut -d: -f1 || true)

  if [[ -z "$heading_line" ]]; then
    echo "FAIL: $file — missing '## Control-Flow Invariants' heading (approx ${approx_tokens} tokens total)" >&2
    fail=1
    continue
  fi

  # Approximate tokens up to and including the heading line
  words_up_to=$(head -n "$heading_line" "$file" | wc -w | tr -d ' ')
  tokens_up_to=$(awk -v w="$words_up_to" -v r="$WORDS_PER_TOKEN_RATIO" 'BEGIN{printf "%.0f", w*r}')

  if (( tokens_up_to > TOKEN_BUDGET )); then
    echo "FAIL: $file — heading appears at line $heading_line (~${tokens_up_to} tokens, budget ${TOKEN_BUDGET})" >&2
    fail=1
    continue
  fi

  echo "OK:   $file — heading at line $heading_line (~${tokens_up_to}/${TOKEN_BUDGET} tokens)"
done

# ---------- Phrase-presence sync rule (B) -------------------------------------
#
# For each (base, lite) pair, extract the body of "## Control-Flow Invariants"
# (heading line through the next "^## " heading or EOF) from both files and
# assert all REQUIRED_PHRASES are present verbatim in BOTH bodies.
#
# Pair entries follow "base_skill_dir|lite_skill_dir" — relative to the
# plugin skills root. The rule activates only when both files exist on disk;
# missing lite (e.g., during incremental rollout) silently skips the pair so
# this script remains green for commit-by-commit work.

PAIRS=(
  "design-review|design-review-lite"
)

REQUIRED_PHRASES=(
  'consecutive_no_major >= 2'
  'inner_converged_cleanly()'
  'severity (post-upgrade) ∈ {critical, major}'
  'INNER_EXIT_REASON == "clean-convergence"'
  'INNER_EXIT_REASON == "safety-limit-fresh-outer"'
  'INNER_EXIT_REASON == "safety-limit-outer-terminate"'
)

# Extract the Control-Flow Invariants section body of a SKILL.md file.
# Body = lines from the heading match through the next "^## " heading (exclusive)
# or EOF. Heading line itself is included so phrases inside the header are
# captured (none today, but kept for stability if section title changes).
extract_invariants_body() {
  local file="$1"
  awk '
    /^## Control-Flow Invariants[[:space:]]*$/ { capture=1; print; next }
    capture && /^## / { capture=0 }
    capture { print }
  ' "$file"
}

for pair in "${PAIRS[@]}"; do
  base_dir="${pair%%|*}"
  lite_dir="${pair##*|}"
  base_file="$skills_root/$base_dir/SKILL.md"
  lite_file="$skills_root/$lite_dir/SKILL.md"

  if [[ ! -f "$base_file" || ! -f "$lite_file" ]]; then
    # Pair is incomplete (e.g., lite not yet authored). Silent skip so
    # incremental commits remain green; the rule activates once both exist.
    continue
  fi

  base_body=$(extract_invariants_body "$base_file")
  lite_body=$(extract_invariants_body "$lite_file")

  pair_failed=0
  for phrase in "${REQUIRED_PHRASES[@]}"; do
    if [[ "$base_body" != *"$phrase"* ]]; then
      echo "FAIL: $base_file — phrase missing from Control-Flow Invariants: $phrase" >&2
      fail=1
      pair_failed=1
    fi
    if [[ "$lite_body" != *"$phrase"* ]]; then
      echo "FAIL: $lite_file — phrase missing from Control-Flow Invariants: $phrase" >&2
      fail=1
      pair_failed=1
    fi
  done

  if (( pair_failed == 0 )); then
    echo "SYNC: $base_dir ↔ $lite_dir — all ${#REQUIRED_PHRASES[@]} phrases present"
  fi
done

exit "$fail"
