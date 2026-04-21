#!/usr/bin/env bash
# Lint that SKILL.md files place a "## Control-Flow Invariants" section within
# the first ~4000 tokens (approximated by words × 1.3).
#
# Rationale: post-compaction reattaches only the first ~5K tokens of SKILL.md
# with priority. Control-flow invariants placed beyond that boundary may be
# summarized away, causing silent mis-termination of the orchestration loop.
# The 4000-token lint cap leaves ~20% safety margin under the 5K budget.
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

# Skills that are exempt from this rule — tiny orchestration-only skills that
# have no outer/inner termination loop and cannot silently mis-terminate.
EXEMPT_SKILLS=("design-upgrade" "implement" "design" "review")

# Collect input files
if [[ $# -eq 0 ]]; then
  script_dir=$(cd "$(dirname "$0")" && pwd)
  repo_root=$(cd "$script_dir/.." && pwd)
  # Portable alternative to `mapfile` (not available in bash 3.2 / macOS)
  FILES=()
  while IFS= read -r line; do
    FILES+=("$line")
  done < <(find "$repo_root/plugins/cc-cmds/skills" \
                -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
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

exit "$fail"
