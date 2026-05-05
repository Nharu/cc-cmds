#!/usr/bin/env bash
# Lint runtime SKILL.md / _common/*.md / */references/*.md for hardcoded
# `.claude` paths that ignore the CLAUDE_CONFIG_DIR environment variable.
#
# Background: when a user sets CLAUDE_CONFIG_DIR=~/.claude-foo, any Bash
# command that references `~/.claude/teams/...` (or `$HOME/.claude/...`,
# `${HOME}/.claude/...`, `/Users/<name>/.claude*`, `/home/<name>/.claude*`)
# silently operates on the wrong directory. Runtime SKILL prose / commands
# must use the form `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/<subpath>` so the
# fallback only applies when the env var is unset or empty.
#
# Whitelist policy:
#   - Only `${CLAUDE_CONFIG_DIR:-...}` (`:-`, NOT bare `-`) is permitted.
#     `${VAR-default}` skips the default when VAR is set-but-empty, which is
#     a silent runtime bug. Single-dash form is rejected as an emergent
#     behavior of the strip patterns below: STRIP_SED matches `:-` only, so
#     a single-dash form leaves its inner `$HOME/.claude` fallback exposed
#     and BANNED_RE catches it. Do NOT extend STRIP_SED to single-dash —
#     the rejection is intentional. Update the design doc + this lint
#     together if the policy ever needs to change.
#   - Inside the fallback, only `$HOME` or `${HOME}` is permitted. `~` does
#     NOT expand inside `${VAR:-...}` parameter substitution and produces a
#     literal `~/.claude` string — also a silent runtime bug. STRIP_SED is
#     deliberately narrowed to `$HOME` / `${HOME}` forms so a tilde-fallback
#     `${CLAUDE_CONFIG_DIR:-~/.claude}` falls through to BANNED_RE's
#     `~/\.claude` branch. The lint enforces the policy by behavior, not
#     just by documentation.
#
# Usage:
#   bash scripts/lint-skill-paths.sh                  # lint all runtime markdown
#   bash scripts/lint-skill-paths.sh path/to/file.md  # lint specific files
#
# Env override:
#   SKILLS_ROOT=<dir> bash scripts/lint-skill-paths.sh   # for fixture tests
#
# Exit codes:
#   0 — all inputs pass
#   1 — at least one violation found
#   2 — no scannable files found

set -euo pipefail

# 5-alternation BANNED_RE (POSIX ERE). `[{]` / `[}]` is the portable form for
# literal `{` / `}` that works under both BSD and GNU grep.
BANNED_RE='(~/\.claude|\$HOME/\.claude|\$[{]HOME[}]/\.claude|/Users/[^/[:space:]]+/\.claude|/home/[^/[:space:]]+/\.claude)'

# Strip the canonical `${CLAUDE_CONFIG_DIR:-$HOME/.claude...}` and
# `${CLAUDE_CONFIG_DIR:-${HOME}/.claude...}` forms so the bare BANNED_RE
# branches inside them are not flagged. Both substitutions are applied
# in a single sed invocation per line; do NOT branch on which form a line
# contains, because lines with mixed forms (e.g. canonical fallback + an
# unrelated violation) need both strips applied to surface only the violation.
STRIP_SED_BARE='s/[$][{]CLAUDE_CONFIG_DIR:-[$]HOME[^}]*[}]//g'
STRIP_SED_BRACED='s/[$][{]CLAUDE_CONFIG_DIR:-[$][{]HOME[}][^}]*[}]//g'

# Resolve skills root (allow SKILLS_ROOT env override for tests).
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# Collect input files.
if [[ $# -eq 0 ]]; then
  FILES=()
  while IFS= read -r line; do
    FILES+=("$line")
  done < <(
    {
      find "$skills_root" -mindepth 2 -maxdepth 2 -name "SKILL.md"
      [ -d "$skills_root/_common" ] && find "$skills_root/_common" -maxdepth 1 -name "*.md"
      find "$skills_root" -mindepth 3 -maxdepth 3 -path "*/references/*.md"
    } | sort
  )
else
  FILES=("$@")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "lint-skill-paths: no scannable files found" >&2
  exit 2
fi

total_files=${#FILES[@]}
violation_lines=0
violation_files=0

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — file not found" >&2
    violation_lines=$((violation_lines + 1))
    violation_files=$((violation_files + 1))
    continue
  fi

  file_violations=0
  line_no=0
  while IFS= read -r line; do
    line_no=$((line_no + 1))
    stripped=$(printf '%s\n' "$line" | sed -e "$STRIP_SED_BARE" -e "$STRIP_SED_BRACED")
    if printf '%s\n' "$stripped" | grep -qE "$BANNED_RE"; then
      echo "FAIL: $file — line $line_no: $line" >&2
      file_violations=$((file_violations + 1))
    fi
  done < "$file"

  if (( file_violations > 0 )); then
    violation_lines=$((violation_lines + file_violations))
    violation_files=$((violation_files + 1))
  else
    echo "OK: $file"
  fi
done

if (( violation_lines == 0 )); then
  echo "lint-skill-paths: all ${total_files} file(s) passed"
  exit 0
else
  echo "lint-skill-paths: ${violation_lines} violation(s) in ${violation_files} file(s)" >&2
  exit 1
fi
