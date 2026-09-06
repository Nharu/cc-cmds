#!/usr/bin/env bash
#
# lint-judgment-grade.sh — every ask point carries a grade, every grade has a
# disposition.
#
# The unattended arms used to park at any point that would have asked. Inverting
# that — adopt the recommendation, escalate only what must be escalated — is not
# a matter of editing N places, because the arms never enumerated their ask
# points: each carried one blanket substitution sentence. So the inversion was
# either indiscriminate or it required building the per-point grading that did
# not exist. This lint is the second option's accounting.
#
# WHY A SEPARATE FILE FROM `lint-unattended-surfaces.sh`. That one proves an
# ABSENCE — no question surface, no notification surface — and this one counts a
# PRESENCE. Put them in one file and the two purposes blur: a skipped absence
# check and a zero-count presence check both print nothing, and only one of them
# is a pass.
#
# Rules:
#   1. [fail] Every line of an attended skill that matches the narrow ask-call
#      form carries exactly one grade token, unless it is on the exemption list
#      below. The narrow form is a call with an option list; prose ABOUT the
#      tool has no option list and is not an ask point.
#   2. [fail] Every grade token anywhere in a scanned skill is in the closed set
#      `등급 0` | `등급 1` | `등급 2`.
#   3. [fail] Every unattended counterpart carries a disposition line for each
#      of the three grades. A grade with a mark and no disposition is an arm
#      that will improvise at exactly that point.
#
# WHAT THIS DOES NOT CHECK, stated because a counting lint read as a correctness
# lint is worse than no lint: it cannot tell a `등급 1` that should have been
# `등급 2`, and it cannot find an ask point that carries no mark AND no option
# list. Rule 1's detector is a narrow form, not a complete one.
#
# Usage: bash scripts/lint-judgment-grade.sh
#
# Env override:
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#
# Exit codes:
#   0  pass, or a silent skip because a skill is not present
#   1  at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

# "<attended>|<unattended>". Same shape as the sibling lint's pair table, and
# deliberately an explicit list rather than a glob for the same reason: the scan
# set is the skills the pipeline dispatches as a stage, and a rename must fail
# rather than silently drop an arm.
PAIRS="implement|implement-unattended review|review-unattended design-audit|design-audit-unattended design|design-reconverge"

GRADE_RE='등급 [0-9]'
VALID_RE='등급 [012]'

# The narrow ask-call form: a mention of the tool on a line that also carries an
# option list. A recommendation arrow, an abort option, or an explicit options
# clause are the three renderings this tree uses.
ASK_RE='AskUserQuestion'
OPTS_RE='←|/ 중단|옵션 `|with three options|header chip'

# Lines that match the narrow form and are NOT ask points: prose defining the
# convention itself. Matched by a distinctive substring rather than by line
# number, which moves. Same idiom as the portability lint's self-skip sentinel
# and the driver's self-check exemption list.
EXEMPT_RE='One issue per surface|Recommendation contract|Default ordering|Cap-handling|recommendation convention|Before calling AskUserQuestion|ToolSearch\("select:'

fail=0
checked=0

for pair in $PAIRS; do
  att="${pair%%|*}"
  una="${pair##*|}"
  att_file="$skills_root/$att/SKILL.md"
  una_file="$skills_root/$una/SKILL.md"

  if [[ ! -f "$att_file" ]]; then
    echo "SKIP: $att — not present"
    continue
  fi
  checked=$((checked + 1))

  # --- Rule 1 -------------------------------------------------------------
  unmarked=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n=$(printf '%s\n' "$line" | grep -oE "$GRADE_RE" | grep -c . || true)
    if [[ "$n" != "1" ]]; then
      echo "FAIL: $att — ask 지점에 등급 토큰이 ${n}개다 (정확히 하나여야 한다): ${line:0:100}" >&2
      unmarked=$((unmarked + 1))
    fi
  done < <(grep -E "$ASK_RE" "$att_file" | grep -E "$OPTS_RE" | grep -vE "$EXEMPT_RE" || true)
  [[ "$unmarked" = "0" ]] || fail=1

  # --- Rule 2 -------------------------------------------------------------
  badtok=0
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    # CAPTURED, NOT `grep -q`. An early-exiting reader on the right of a pipe
    # kills the writer with SIGPIPE, and under `pipefail` the pipeline then
    # reports failure even though the match was found. `grep -c` has the same
    # truth value and reads its input to the end.
    tok_hit=$(printf '%s' "$tok" | grep -cE "^$VALID_RE$" || true)
    if [[ "${tok_hit:-0}" = "0" ]]; then
      echo "FAIL: $att — 어휘 밖 등급 토큰: '$tok'" >&2
      badtok=$((badtok + 1))
    fi
  done < <(grep -ohE "$GRADE_RE" "$att_file" | LC_ALL=C sort -u || true)
  [[ "$badtok" = "0" ]] || fail=1

  n_marks=$(grep -ohE "$GRADE_RE" "$att_file" | grep -c . || true)
  if [[ "$n_marks" = "0" ]]; then
    echo "FAIL: $att — 등급 토큰이 하나도 없다 — 무인 갈래가 어느 지점을 채택하고 어느 지점을 올릴지 정할 근거가 없다" >&2
    fail=1
  else
    echo "OK:   $att — ask 지점 등급 표시 ${n_marks}건"
  fi

  # --- Rule 3 -------------------------------------------------------------
  if [[ ! -f "$una_file" ]]; then
    echo "SKIP: $una — not present"
    continue
  fi
  missing=0
  for g in 0 1 2; do
    grep -qE "등급 $g" "$una_file" || {
      echo "FAIL: $una — 등급 $g 의 처분 문장이 없다" >&2
      missing=$((missing + 1))
    }
  done
  if [[ "$missing" = "0" ]]; then
    echo "OK:   $una — 세 등급 전부에 처분이 있다"
  else
    fail=1
  fi
done

if [[ "$checked" = "0" ]]; then
  echo "SKIP: 대상 스킬이 하나도 없다"
  exit 0
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-judgment-grade: violations found" >&2
  exit 1
fi
echo "lint-judgment-grade: $checked pair(s) checked"
exit 0
