#!/usr/bin/env bash
# Lint SKILL.md + references/*.md for two AskUserQuestion (AUQ) construction
# invariants:
#   Rule 1 (presence-check / wiring gate) — every SKILL.md that loads
#     AskUserQuestion via `ToolSearch("select:AskUserQuestion")` MUST also
#     reference the shared construction spec `_common/askuserquestion.md`.
#   Rule 2 (denylist) — no AUQ option menu in SKILL.md or references/*.md may
#     hard-code a manual "Other"-equivalent label; the tool auto-provides one,
#     so a manual copy is redundant and risks an option-count overflow.
#
# Rationale: malformed authored templates breed malformed live AUQ calls.
# Rule 1 guarantees the construction spec is in context wherever AUQ is used;
# Rule 2 catches the one denylist class that is reliably grep-detectable.
# Header-length and missing-description violations are semantic and governed
# by the spec's authoring rule, not by this lint.
#
# Usage:
#   bash scripts/lint-skill-auq-spec.sh
#
# Env override:
#   SKILLS_ROOT=<dir>   # test fixture runner; scans <dir>/*/SKILL.md and
#                       # <dir>/*/references/*.md
#
# Same-line escape comment (Rule 2 only):
#   A line containing `# lint-skill-auq-spec: disable=other-option` suppresses
#   the denylist hit on that line — for legitimate prose that quotes a banned
#   token.
#
# Exit codes:
#   0 — all inputs pass
#   1 — at least one violation found
#   2 — no scannable files found

set -euo pipefail

SELECT_TOKEN='select:AskUserQuestion'
SPEC_REF='askuserquestion.md'
SPEC_BASENAME='askuserquestion.md'
SUPPRESS='lint-skill-auq-spec: disable=other-option'

# Double-quoted manual "Other"-equivalent labels. The tool auto-appends an
# "Other" free-text choice, so any of these in an authored menu is redundant.
DENY=('"직접 지정"' '"기타"' '"직접 입력"' '"Other"')

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# Collect SKILL.md files (one per skill dir; portable read loop, no mapfile).
SKILL_FILES=()
while IFS= read -r f; do
  SKILL_FILES+=("$f")
done < <(find "$skills_root" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

# Collect reference markdown files.
REF_FILES=()
while IFS= read -r f; do
  REF_FILES+=("$f")
done < <(find "$skills_root" -path '*/references/*.md' | sort)

if [[ ${#SKILL_FILES[@]} -eq 0 && ${#REF_FILES[@]} -eq 0 ]]; then
  echo "lint-skill-auq-spec: no scannable files found" >&2
  exit 2
fi

fail=0

# ---------- Rule 1: presence-check / wiring gate ------------------------------
#
# A SKILL.md that loads AskUserQuestion must Read the construction spec so its
# hard constraints are in context for every call. Detection keys on the
# canonical `select:AskUserQuestion` token (not a naive `AskUserQuestion` grep),
# so opt-out skills that merely mention the tool name are not falsely flagged.

for file in ${SKILL_FILES[@]+"${SKILL_FILES[@]}"}; do
  if grep -qF "$SELECT_TOKEN" "$file"; then
    if grep -qF "$SPEC_REF" "$file"; then
      echo "OK:   $file — loads AUQ and references the construction spec"
    else
      echo "FAIL: $file — loads '$SELECT_TOKEN' but does not reference '$SPEC_REF'" >&2
      fail=1
    fi
  fi
done

# ---------- Rule 2: denylist grep ---------------------------------------------
#
# Flag any double-quoted manual Other-equivalent label. The shared spec names
# these tokens in prose by design, so it is excluded whole-file (by basename)
# to avoid self-firing. A same-line `disable=other-option` comment suppresses a
# legitimate prose quote.

scan_denylist() {
  local file="$1"
  local base
  base=$(basename "$file")
  if [[ "$base" == "$SPEC_BASENAME" ]]; then
    return 0
  fi
  local line_no=0
  local line token
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    case "$line" in
      *"$SUPPRESS"*) continue ;;
    esac
    for token in "${DENY[@]}"; do
      case "$line" in
        *"$token"*)
          echo "FAIL: $file:$line_no — manual Other-equivalent option label ${token}; the tool auto-provides 'Other'. Remove it, or add '# $SUPPRESS' on this line if it is legitimate prose." >&2
          fail=1
          ;;
      esac
    done
  done < "$file"
}

for file in ${SKILL_FILES[@]+"${SKILL_FILES[@]}"} ${REF_FILES[@]+"${REF_FILES[@]}"}; do
  scan_denylist "$file"
done

exit "$fail"
