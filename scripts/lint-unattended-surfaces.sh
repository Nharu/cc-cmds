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
#   Rule 4 (inherited question points are dispositioned) — an arm does not
#     copy its `references/`, it SHARES the base skill's tree, and the two
#     shipped question points in this repo are in exactly that tree. The arm
#     cannot delete them, because the interactive arm needs them, so what it
#     owes is a statement of what it does instead, naming the file. Checked in
#     both directions: an undispositioned question point is a surface the arm
#     claims not to have, and a disposition for a file carrying none is a
#     clause pointing at nothing.
#
# Why these are checkable here and not in general: each unattended arm lives
# in its OWN file and carries exactly one arm, so a whole-file predicate is
# an arm-level predicate. The same predicate over a two-arm file proves
# nothing about either arm, which is why the arms were split into files in
# the first place.
#
# Rule 4 exists because Rules 1 and 2 could not reach those two points twice
# over, and repairing either layer alone leaves them still passing. The scan
# set opened one file per arm — `<skill>/SKILL.md` — and the shared tree is
# not under the arm's directory at all. The pattern then required an opening
# parenthesis, while both occurrences are a backticked bare name inside a
# sentence. A contract that asserts an absence, measured by a device that
# cannot reach the place the absence is claimed about, is green forever.
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
# Rule 4 is the deliberate asymmetry: inside a reference tree the pattern
# matches the BARE NAME. That is sound exactly where the call-form rule is not,
# because a reference file carries instructions and no meta-discussion of this
# invariant — nothing there is documenting what must not be reached. It is also
# necessary, since a question point written as prose ("surface it with at most
# one `AskUserQuestion`") is a real routing instruction wearing no parenthesis.
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

# Rule 4 — "<arm>|<skill whose references/ tree the arm reads>". Explicit for
# the same reason the skill list is: the sharing is stated in prose inside each
# arm and nothing derives it, so a glob would silently drop a renamed arm
# instead of failing. An arm that shares nobody's tree names itself.
REFERENCE_TREES=(
  "implement-unattended|implement"
  "design-audit-unattended|design-audit"
  "review-unattended|review"
  "design-reconverge|design-reconverge"
)

# Rule 4 — the question-surface pattern used INSIDE a reference tree. Bare name,
# no call form required; see the asymmetry note in the header.
REF_QUESTION_RE='AskUserQuestion|EnterPlanMode|ExitPlanMode'

# The clause an arm owes for each shared reference file that holds a question
# point. Fixed prefix plus the file's own name in backticks, so the check is a
# byte comparison rather than a guess at how the disposition was worded.
DISPOSITION_PREFIX='**Inherited question point** — '

fail=0
checked=0
skipped=0
refs_checked=0

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

for pair in ${REFERENCE_TREES[@]+"${REFERENCE_TREES[@]}"}; do
  arm="${pair%%|*}"
  base="${pair##*|}"
  arm_file="$skills_root/$arm/SKILL.md"
  ref_dir="$skills_root/$base/references"

  [[ -f "$arm_file" ]] || continue
  if [[ ! -d "$ref_dir" ]]; then
    echo "SKIP: $arm — $base/references/ not present"
    continue
  fi
  refs_checked=$((refs_checked + 1))

  # Both sides collected whole, as basenames, and neither written down here.
  # `LC_ALL=C` on the sort is load-bearing wherever `-u` is used as a set
  # operation: `-u` drops "duplicates" by collation, and a locale with no
  # ordering for a script compares every element equal to every other.
  hit_files=$(LC_ALL=C grep -rlE "$REF_QUESTION_RE" "$ref_dir" 2>/dev/null \
    | sed 's|.*/||' | LC_ALL=C sort -u || true)
  disp_files=$(LC_ALL=C grep -F -- "$DISPOSITION_PREFIX" "$arm_file" 2>/dev/null \
    | sed -n 's/.*\*\*Inherited question point\*\* — `\([^`]*\)`.*/\1/p' \
    | LC_ALL=C sort -u || true)

  while IFS= read -r bn; do
    [[ -n "$bn" ]] || continue
    # CAPTURED, NOT `grep -qxF`. An early-exiting reader on the right of a pipe
    # kills the writer with SIGPIPE, and under `pipefail` the pipeline then
    # reports failure even though the match was found.
    hit=$(printf '%s\n' "$disp_files" | grep -xF -- "$bn" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: $arm — $base/references/$bn 가 질문 지점을 갖는데 이 갈래가 그 처분을 적지 않았다" >&2
      echo "       공유하는 트리라 지울 수 없다 — 대신 무엇을 하는지를 파일 이름과 함께 적어야 한다" >&2
      LC_ALL=C grep -nE "$REF_QUESTION_RE" "$ref_dir/$bn" >&2 || true
      fail=1
    fi
  done <<EOF
$hit_files
EOF

  while IFS= read -r bn; do
    [[ -n "$bn" ]] || continue
    hit=$(printf '%s\n' "$hit_files" | grep -xF -- "$bn" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: $arm — $base/references/$bn 의 처분을 적었는데 그 파일에는 질문 지점이 없다" >&2
      echo "       가리키는 것이 없는 절은 다음 독자에게 아직 상속받는 중이라고 읽힌다" >&2
      fail=1
    fi
  done <<EOF
$disp_files
EOF
done

if [[ "$fail" -ne 0 ]]; then
  echo "lint-unattended-surfaces: violations found" >&2
  exit 1
fi

echo "lint-unattended-surfaces: ${checked} skill(s) checked, ${skipped} absent, ${refs_checked} shared reference tree(s) checked"
exit 0
