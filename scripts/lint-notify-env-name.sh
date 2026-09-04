#!/usr/bin/env bash
# Lint the autopilot banner kill switch's NAME across the code/prose boundary.
#
# The switch is parsed in exactly one place — the shared banner emitter — so two
# processes can no longer grow two grammars for its VALUE. What that does not
# close is the other drift: the kickoff document tells a user which variable to
# type, and if that name and the one the emitter reads come apart, the user sets
# something nothing reads, believes the banners are off, and goes on receiving
# them. The value can only be chosen before a run starts, so there is no moment
# during the night when the mismatch could be noticed either.
#
# Rules:
#   1  the emitter reads exactly one `CC_CMDS_` variable that is not a test seam
#   2  the kickoff's "전부 끄시려면" sentence names exactly one `CC_CMDS_` token
#   3  those two names are the same string                              [fail]
#
# THE EXTRACTION RULE IS THE WHOLE DESIGN, and it is written down outside this
# script — in the design document and in that slice's plan — so that a seam added
# later is a deliberate edit here rather than a silent false positive.
#
#   emitter side  — take every `CC_CMDS_*` token, DROP the ones prefixed
#                   `CC_CMDS_NOTIFY_` (that prefix is the notification helper's
#                   family of test seams, and the emitter reads two of them),
#                   and the single survivor is the kill switch.
#   prose side    — take the one `CC_CMDS_*` token carried by the sentence that
#                   begins 「전부 끄시려면」.
#
# Without a rule on the emitter side the lint catches all three names and fails
# forever on the two the kickoff never mentions; without one on the prose side it
# would take the name FROM the prose and merely check that the emitter contains
# it, which is a tautology that passes while the drift it exists to catch is
# present.
#
# Usage:
#   bash scripts/lint-notify-env-name.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding notify-run.sh
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/SKILL.md
#
# Posture: if the emitter is absent the whole check is a silent skip, so the
# script stays green during an incremental rollout.
#
# Exit codes:
#   0 — pass (or skipped)
#   1 — at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
EMITTER="$orch_root/notify-run.sh"
KICKOFF="$skills_root/autopilot/SKILL.md"

if [[ ! -f "$EMITTER" ]]; then
  echo "SKIP: notify-run.sh not found under $orch_root — banner emitter not present"
  exit 0
fi
if [[ ! -f "$KICKOFF" ]]; then
  echo "SKIP: autopilot/SKILL.md not found under $skills_root"
  exit 0
fi

fail=0

# --- Emitter side ----------------------------------------------------------
# Comments are stripped first. Prose in this file legitimately names the seam
# family and the switch itself, and a lint that reads a comment as a declaration
# would be measuring the file's documentation rather than what it reads.
emitter_names=$(sed 's/#.*//' "$EMITTER" \
  | grep -ohE 'CC_CMDS_[A-Z0-9_]+' \
  | sort -u \
  | grep -vE '^CC_CMDS_NOTIFY_' || true)

n_emitter=$(printf '%s\n' "$emitter_names" | grep -c . || true)
if [[ "${n_emitter:-0}" != "1" ]]; then
  echo "FAIL: notify-run.sh — 시험 이음매(CC_CMDS_NOTIFY_*)를 뺀 CC_CMDS_ 변수가 ${n_emitter:-0}개 (기대 1개)" >&2
  echo "       찾은 것: $(printf '%s' "$emitter_names" | tr '\n' ' ')" >&2
  fail=1
fi

# --- Prose side ------------------------------------------------------------
switch_line=$(grep -F '전부 끄시려면' "$KICKOFF" || true)
n_line=$(printf '%s\n' "$switch_line" | grep -c . || true)
if [[ "${n_line:-0}" != "1" ]]; then
  echo "FAIL: autopilot/SKILL.md — 「전부 끄시려면」 문장이 ${n_line:-0}회 (기대 1회)" >&2
  fail=1
fi

prose_names=$(printf '%s' "$switch_line" | grep -ohE 'CC_CMDS_[A-Z0-9_]+' | sort -u || true)
n_prose=$(printf '%s\n' "$prose_names" | grep -c . || true)
if [[ "${n_prose:-0}" != "1" ]]; then
  echo "FAIL: autopilot/SKILL.md — 「전부 끄시려면」 문장이 담은 CC_CMDS_ 토큰이 ${n_prose:-0}개 (기대 1개)" >&2
  fail=1
fi

# --- Rule 3: the two names agree -------------------------------------------
if [[ "$fail" == "0" ]]; then
  if [[ "$emitter_names" != "$prose_names" ]]; then
    echo "FAIL: 킬스위치 이름이 코드와 문면 사이에서 갈렸다" >&2
    echo "       emitter: $emitter_names" >&2
    echo "       문면   : $prose_names" >&2
    fail=1
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-notify-env-name: violations found" >&2
  exit 1
fi

echo "OK:   notify env name — 킬스위치 '$emitter_names' 가 emitter 와 킥오프 문면에서 일치"
exit 0
