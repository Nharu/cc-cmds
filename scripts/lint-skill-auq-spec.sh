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
# COMMENTS ARE NOT CONTENT. Every markdown file this lint reads is read through a
# comment-blanked copy. Wrapping a section in OUT-OF-LINE comment markers leaves
# the heading bytes intact, so a matcher anchored on the heading fires exactly as
# before while a reader sees nothing there — measured on this lint at exit 0 with
# a success line byte-identical to the unwrapped run. Commenting the heading line
# ITSELF turns the run red, but that is a parse failure rather than detection and
# it is not the shape an editor produces when removing a section.
#
# The strip is not sufficient on its own and is not offered as such: a roster
# built over a comment-blind derivation is defeated exactly as a count is,
# because an elided member still contributes itself to the observed set. The
# declaration and the derivation are two obligations, not one.
# shellcheck source=./_strip-html-comments.sh
source "$script_dir/_strip-html-comments.sh"
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
  visible=$(stripped_copy "$file")
  if grep -qF "$SELECT_TOKEN" "$visible"; then
    if grep -qF "$SPEC_REF" "$visible"; then
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
  # Two streams, one per line, and the split is deliberate. CONTENT is read from
  # the blanked copy, because a banned label a reader cannot see is not a label
  # this lint should be flagging. The SUPPRESSION marker is read from the raw
  # line, because a lint directive belongs in a comment — that is where the
  # convention puts it, and blanking it would turn a legitimate suppression into
  # a false failure on prose that is doing exactly what the diagnostic asks.
  visible_file=$(stripped_copy "$file")
  while IFS= read -r raw_line <&3 && IFS= read -r line <&4; do
    line_no=$((line_no + 1))
    case "$raw_line" in
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
  done 3< "$file" 4< "$visible_file"
}

for file in ${SKILL_FILES[@]+"${SKILL_FILES[@]}"} ${REF_FILES[@]+"${REF_FILES[@]}"}; do
  scan_denylist "$file"
done

exit "$fail"
