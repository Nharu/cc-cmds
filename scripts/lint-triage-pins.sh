#!/usr/bin/env bash
# Pin the landed-code section of the triage prompt.
#
# `prompts/triage.md` routes review findings into lanes for an unattended run.
# Two of those lanes (`fast`, `slow`) create implementation work, and
# implementation work against a segment that has already merged is a new
# segment the run cannot end without. The section pinned here says that a P2
# or P3 finding on a landed segment may not take those lanes — and it is
# prose in a prompt, so nothing at runtime notices when it is gone. The gate
# never reads `triage.md` (it is judgment-call input only), so the lane choice
# itself cannot be asserted by a fixture; what CAN be asserted is that the
# sentence the judgment reads is still there, exactly once.
#
# Not skip-if-absent, deliberately: this lint's whole purpose is to keep the
# section from disappearing, so an absent heading is the failure, not a
# revert to tolerate.
#
# Rules:
#   1. The section heading appears exactly once.
#   2. The predicate sentence — the one line that names the two ledger states
#      and the two lanes — appears exactly once.
#   3. Inside that section, the four load-bearing tokens are present:
#      `상태=머지됨`, `상태=완료`, `P0`, `P1` (the last two because the section
#      must say that P0 and P1 are NOT affected — dropping that clause would
#      make merged-code P0s wait for the morning).
#
# Usage:
#   bash scripts/lint-triage-pins.sh
#
# Env override:
#   PROMPT_DIR=<dir>   directory holding triage.md (fixture runner)
#
# Exit codes:
#   0 — all pins intact
#   1 — at least one pin broken, or triage.md missing
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
prompt_dir="${PROMPT_DIR:-$repo_root/plugins/cc-cmds/orchestrator/prompts}"

TRIAGE="$prompt_dir/triage.md"
HEADING='## Findings on landed code do not open a segment'
PREDICATE='Before choosing a lane, read the reviewed segment'"'"'s latest `segment` row: when its `상태=머지됨` or `상태=완료`, a P2 or P3 finding cannot take `fast` or `slow`.'

if [[ ! -f "$TRIAGE" ]]; then
  echo "FAIL: triage.md not found under $prompt_dir" >&2
  exit 1
fi

fail=0
rel=${TRIAGE#"$repo_root/"}

# count_lines <fixed-literal> <file>
count_lines() {
  grep -Fxc -- "$1" "$2" 2>/dev/null || true
}

# ---------- Rule 1 / 2: heading and predicate, exactly once each --------------

n=$(count_lines "$HEADING" "$TRIAGE")
if [[ "$n" != "1" ]]; then
  echo "FAIL: $rel — heading must appear on exactly 1 line, found $n: $HEADING" >&2
  fail=1
fi

n=$(count_lines "$PREDICATE" "$TRIAGE")
if [[ "$n" != "1" ]]; then
  echo "FAIL: $rel — predicate sentence must appear on exactly 1 line, found $n" >&2
  fail=1
fi

# ---------- Rule 3: tokens inside the section ----------------------------------

# The section body: from the heading to the next `##` heading (exclusive).
section=$(awk -v h="$HEADING" '
  !incap && $0 == h { incap = 1; next }
  incap && substr($0, 1, 3) == "## " { exit }
  incap { print }
' "$TRIAGE")

for tok in '상태=머지됨' '상태=완료' 'P0' 'P1'; do
  # Counted, not `grep -q`: an early-exiting reader can SIGPIPE the writer and
  # under `pipefail` that reads as a failure even when the token was found.
  hits=$(printf '%s\n' "$section" | grep -Fc -- "$tok" || true)
  if [[ "${hits:-0}" = "0" ]]; then
    echo "FAIL: $rel — token '$tok' missing from the landed-code section" >&2
    fail=1
  fi
done

if [[ "$fail" != "0" ]]; then
  echo "lint-triage-pins: violations found" >&2
  exit 1
fi
echo "OK:   triage pins — landed-code section heading, predicate and 4 tokens intact"
exit 0
