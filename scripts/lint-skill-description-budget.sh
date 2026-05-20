#!/usr/bin/env bash
# Lint frontmatter `description` + `when_to_use` combined char budget for
# model-invocable skills (`disable-model-invocation: false`). Claude Code
# truncates the combined text at 1,536 characters in the skill listing
# (https://code.claude.com/docs/en/skills) — exceeding the cap silently
# drops the tail of `when_to_use`, which holds disambiguation logic.
#
# Rules:
#   1  description ≤ 1024 chars (Agent Skills hard limit)               [fail]
#   2  description + when_to_use ≤ 1536 chars (Claude Code listing cap) [fail]
#   3  combined > 1350 chars → headroom warning                         [warn]
#
# Skipped: skills with `disable-model-invocation: true` (slash-command-only
# skills do not occupy the eager listing surface).
#
# Char count is Unicode codepoints via python3 (NOT bytes — wc -c is wrong
# for Korean text; wc -m is locale-dependent and unreliable).
#
# Usage:
#   bash scripts/lint-skill-description-budget.sh                 # all skills
#   bash scripts/lint-skill-description-budget.sh path/to/SKILL.md [more.md ...]

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=./_yq-preflight.sh
source "$script_dir/_yq-preflight.sh"
yq_preflight

HARD_DESC=1024
HARD_COMBINED=1536
WARN_COMBINED=1350

fail_count=0
warn_count=0

count_chars() {
  python3 -c 'import sys; print(len(sys.argv[1]))' "$1"
}

lint_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — file not found" >&2
    fail_count=$((fail_count + 1))
    return
  fi

  local disable_invoke
  disable_invoke=$(yq eval '."disable-model-invocation" // false' --front-matter=extract "$file")
  if [[ "$disable_invoke" != "false" ]]; then
    echo "SKIP: $file — disable-model-invocation: $disable_invoke (not eager-listed)"
    return
  fi

  local description when_to_use
  description=$(yq eval '.description // ""' --front-matter=extract "$file")
  when_to_use=$(yq eval '.when_to_use // ""' --front-matter=extract "$file")

  local desc_len wtu_len combined
  desc_len=$(count_chars "$description")
  wtu_len=$(count_chars "$when_to_use")
  combined=$(( desc_len + wtu_len ))

  local failed=0
  if (( desc_len > HARD_DESC )); then
    echo "FAIL: $file — description length=$desc_len exceeds Agent Skills hard limit ($HARD_DESC)" >&2
    fail_count=$((fail_count + 1))
    failed=1
  fi

  if (( combined > HARD_COMBINED )); then
    echo "FAIL: $file — description+when_to_use combined=$combined exceeds Claude Code listing cap ($HARD_COMBINED). Tail of when_to_use will be silently truncated." >&2
    fail_count=$((fail_count + 1))
    failed=1
  fi

  if (( failed )); then
    return
  fi

  if (( combined > WARN_COMBINED )); then
    echo "WARN: $file — combined=$combined exceeds target headroom ($WARN_COMBINED; cap=$HARD_COMBINED). Consider trimming to retain truncation buffer." >&2
    warn_count=$((warn_count + 1))
    return
  fi

  echo "OK:   $file — description=$desc_len, when_to_use=$wtu_len, combined=$combined (cap=$HARD_COMBINED)"
}

if [[ $# -eq 0 ]]; then
  FILES=()
  while IFS= read -r line; do
    FILES+=("$line")
  done < <(find "$repo_root/plugins/cc-cmds/skills" \
                -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
else
  FILES=("$@")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-skill-description-budget: no SKILL.md files to check" >&2
  exit 2
fi

for f in "${FILES[@]}"; do
  lint_file "$f"
done

if (( fail_count > 0 )); then
  echo "lint-skill-description-budget: $fail_count failure(s), $warn_count warning(s)" >&2
  exit 1
fi

if (( warn_count > 0 )); then
  echo "lint-skill-description-budget: 0 failures, $warn_count warning(s)"
fi

exit 0
