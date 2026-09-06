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
# Second rule — the team witness directory's root and basename.
#   The agent-team protocol moved the witness dir off `${TMPDIR}` and dropped
#   the `cc-` prefix from its basename: it is `${CC_PIPELINE_RUN_DIR}/
#   team-witness-<slug>` when that variable is set and a `mktemp -d` under
#   `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/` otherwise. Nine
#   consumer SKILL.md files kept spelling the old `${TMPDIR:-/tmp}/
#   cc-team-witness-<slug>.XXXXXX`, so the move never reached the stages that
#   actually run: a `${TMPDIR}` directory is collected within about an hour on
#   this host, and the witness is the anti-fabrication anchor — gone, the lead
#   either parks forever or synthesizes a round product it never observed. The
#   basename half matters for a different reason: the cleanup contract's path
#   guard recognizes exactly one spelling, so two spellings mean the guard
#   knows a name nothing creates while the created one is never swept.
#   Hand-fixing the nine files does not stop the tenth from being written with
#   the old spelling, which is what this rule is for.
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

# Witness-directory rule (POSIX ERE). Two branches:
#   1. the retired `cc-team-witness-` basename, anywhere;
#   2. a witness path ROOTED AT `${TMPDIR}` / `$TMPDIR` — the `/` after the
#      expansion is required, so prose that merely names the variable (the
#      protocol's own paragraph explaining why `${TMPDIR}` cannot hold this)
#      is not a hit. Branch 2 stands on its own because dropping the `cc-`
#      prefix while keeping `${TMPDIR}` fixes the name and leaves the lifetime
#      defect, which is the half that loses the witness.
WITNESS_BANNED_RE='(cc-team-witness-|[$][{]TMPDIR[^}]*[}]/[^[:space:]]*team-witness|[$]TMPDIR/[^[:space:]]*team-witness)'

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
    # CAPTURED, NOT `grep -q`. An early-exiting reader on the right of a pipe
    # kills the writer with SIGPIPE, and under `pipefail` the pipeline then
    # reports failure even though the match was found.
    banned_hit=$(printf '%s\n' "$stripped" | grep -cE "$BANNED_RE" || true)
    if [[ "${banned_hit:-0}" != "0" ]]; then
      echo "FAIL: $file — line $line_no: $line" >&2
      file_violations=$((file_violations + 1))
    fi
    # The RAW line, not the stripped one: the `${CLAUDE_CONFIG_DIR:-…}` strips
    # above exist to hide a permitted fallback from the `.claude` rule and have
    # nothing to say about a witness path, so running this branch on the
    # stripped text would only add a way for the two rules to interfere.
    witness_hit=$(printf '%s\n' "$line" | grep -cE "$WITNESS_BANNED_RE" || true)
    if [[ "${witness_hit:-0}" != "0" ]]; then
      echo "FAIL: $file — line $line_no (위트니스 경로): $line" >&2
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
