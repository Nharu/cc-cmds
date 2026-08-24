#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Lint the unattended pipeline skills for two absence invariants and one
# parity invariant.
#
#   Rule 1 (no human-question surface) — an unattended arm must not load or
#     call AskUserQuestion / EnterPlanMode / ExitPlanMode. Every point that
#     would have asked resolves to a halt record instead.
#   Rule 2 (no notification surface) — an unattended arm must not reach
#     PushNotification / notify.sh / terminal-notifier. Reaching a sleeping
#     user is the driver's exclusive job; a stage that works AND notifies is
#     forbidden without exception.
#   Rule 3 (forked-spine constant parity) — where an unattended arm forks a
#     base skill that pins fixed constants under `### CFI-0`, the fork's
#     fenced block must be byte-identical to the base's. A forked spine's one
#     real drift risk is a budget that quietly diverges, so it is pinned
#     rather than trusted.
#
# Why these are checkable here and not in general: each unattended arm lives
# in its OWN file and carries exactly one arm, so a whole-file predicate is
# an arm-level predicate. The same predicate over a two-arm file proves
# nothing about either arm, which is why the arms were split into files in
# the first place.
#
# What Rules 1 and 2 do NOT prove: that the model never asks. A model can ask
# in prose and answer itself, and no text or tool roster removes that. These
# rules prove the file contains no instruction to ask and no reachable
# notification call — a necessary condition, not a sufficient one.
#
# Patterns anchor on CALL FORM, not on a bare token mention. Every one of
# these files legitimately discusses the tools it must not use ("AskUserQuestion
# is deliberately NOT loaded"), so a token-level denylist would flag exactly
# the sentences that document the invariant.
#
# Usage:
#   bash scripts/lint-unattended-surfaces.sh
#
# Env override:
#   SKILLS_ROOT=<dir> bash scripts/lint-unattended-surfaces.sh   # fixture test
#
# Posture: a skill absent from disk is a silent skip, so this script stays
# green during an incremental rollout and activates as each arm lands.
#
# Exit codes:
#   0 — all present targets pass
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# Explicit allowlist. Deliberately NOT a `*-unattended` glob: the scan set is
# the set of skills the pipeline dispatches as a stage, and `design-reconverge`
# is one of those without carrying the suffix. A glob would also silently drop
# a renamed arm instead of failing.
UNATTENDED_SKILLS=(
  "implement-unattended"
  "design-audit-unattended"
  "review-unattended"
  "design-reconverge"
)

# Fork parity pairs: "<fork>|<base>". Only pairs whose base pins constants
# under `### CFI-0` need an entry; a base with no such block is not a pair.
PARITY_PAIRS=(
  "design-audit-unattended|design-audit"
)

# Rule 1 — human-question call forms.
QUESTION_RE='ToolSearch\("select:[^"]*AskUserQuestion|AskUserQuestion\(|EnterPlanMode\(|ExitPlanMode\('

# Rule 2 — notification call forms. Byte-identical to the predicate the
# design's residual verification item fixed, and for its stated reasons:
# `grep -q` inside an `if` so the 0-hit case does not trip `set -e`, and
# call-form anchoring so a prose mention in a README sentence is not a hit.
NOTIFY_RE='PushNotification\(|notify\.sh[[:space:]]+(arm|fire-now|cancel)|terminal-notifier[[:space:]]+-'

fail=0
checked=0
skipped=0

for skill in "${UNATTENDED_SKILLS[@]}"; do
  file="$skills_root/$skill/SKILL.md"
  if [[ ! -f "$file" ]]; then
    echo "SKIP: $skill — not present"
    skipped=$((skipped + 1))
    continue
  fi
  checked=$((checked + 1))

  if grep -qE "$QUESTION_RE" "$file"; then
    echo "FAIL: $skill — reaches a human-question surface" >&2
    grep -nE "$QUESTION_RE" "$file" >&2
    fail=1
  fi

  if grep -qE "$NOTIFY_RE" "$file"; then
    echo "FAIL: $skill — reaches a notification surface" >&2
    grep -nE "$NOTIFY_RE" "$file" >&2
    fail=1
  fi

  if [[ "$fail" -eq 0 ]]; then
    echo "OK:   $skill — no question surface, no notification surface"
  fi
done

# Extract the fenced block that immediately follows the `### CFI-0` heading.
# Fence-delimited by the first ``` after the heading through the next ```.
extract_cfi0_block() {
  awk '
    /^### CFI-0/ { seen=1; next }
    seen && /^```/ { if (infence) { exit } ; infence=1; next }
    seen && infence { print }
  ' "$1"
}

for pair in ${PARITY_PAIRS[@]+"${PARITY_PAIRS[@]}"}; do
  fork="${pair%%|*}"
  base="${pair##*|}"
  fork_file="$skills_root/$fork/SKILL.md"
  base_file="$skills_root/$base/SKILL.md"

  if [[ ! -f "$fork_file" || ! -f "$base_file" ]]; then
    echo "SKIP: $fork <- $base — parity pair incomplete on disk"
    continue
  fi

  fork_block=$(extract_cfi0_block "$fork_file")
  base_block=$(extract_cfi0_block "$base_file")

  if [[ -z "$base_block" ]]; then
    echo "FAIL: $base — no fenced block under '### CFI-0'; the parity pair names a base that no longer pins constants" >&2
    fail=1
    continue
  fi

  if [[ "$fork_block" != "$base_block" ]]; then
    echo "FAIL: $fork — CFI-0 constants diverge from $base" >&2
    echo "--- $base" >&2
    printf '%s\n' "$base_block" >&2
    echo "--- $fork" >&2
    printf '%s\n' "$fork_block" >&2
    fail=1
  else
    echo "OK:   $fork — CFI-0 constants byte-identical to $base"
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "lint-unattended-surfaces: violations found" >&2
  exit 1
fi

echo "lint-unattended-surfaces: ${checked} skill(s) checked, ${skipped} absent"
exit 0
