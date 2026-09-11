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
#   1  the emitter reads exactly the REGISTERED SET of `CC_CMDS_` switches —
#      no more and no fewer — once the test seams are dropped
#   2  each switch's own guidance sentence occurs exactly once in its own
#      document and names exactly one `CC_CMDS_` token
#   3  the two SETS, code side and prose side, are equal                 [fail]
#
# WHY RULE 1 IS A SET AND NOT A COUNT. It used to read "exactly one", and that
# form has no way to accept a second switch: the moment a second one is added the
# rule fails, and widening the file glob does not help because the two are then
# counted inside the wider set as well. A registered set says the thing actually
# wanted — a name that is not on the list is not a switch, it is a name nobody
# was ever told to type — and adding a switch stays a deliberate edit here.
#
# THE EXTRACTION RULE IS THE WHOLE DESIGN, and it is written down outside this
# script — in the design document and in that slice's plan — so that a seam added
# later is a deliberate edit here rather than a silent false positive.
#
#   emitter side  — take every `CC_CMDS_*` token, DROP the ones prefixed
#                   `CC_CMDS_NOTIFY_` (that prefix is the notification helper's
#                   family of test seams, and the emitter reads several of them),
#                   and the survivors are the kill switches.
#   prose side    — per switch, take the one `CC_CMDS_*` token carried by that
#                   switch's own marker sentence: 「전부 끄시려면」 in the
#                   kickoff, 「이 머신의 일반 세션 배너를 끄시려면」 in the seat
#                   contract. The two markers do not overlap as substrings, so
#                   neither can pollute the other's count.
#
# Without a rule on the emitter side the lint catches every seam name and fails
# forever on the ones no document mentions; without one on the prose side it
# would take the names FROM the prose and merely check that the emitter contains
# them, which is a tautology that passes while the drift it exists to catch is
# present.
#
# Usage:
#   bash scripts/lint-notify-env-name.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding notify-run.sh
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/SKILL.md
#   HOOKS_ROOT=<dir>    # hooks root holding README.md (the seat contract)
#
# THE THIRD ROOT IS NOT OPTIONAL SCAFFOLDING. Without it a fixture run resolves
# the seat contract against the REAL repository, so every fixture would be
# measured partly against the tree it is supposed to be isolated from.
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
hooks_root="${HOOKS_ROOT:-$repo_root/plugins/cc-cmds/hooks}"
EMITTER="$orch_root/notify-run.sh"
KICKOFF="$skills_root/autopilot/SKILL.md"
SEATDOC="$hooks_root/README.md"

# The registered set, sorted, one per line — the shape the extractions below
# produce, so the comparisons are plain string equality.
KNOWN_SWITCHES=$(printf '%s\n' CC_CMDS_AUTOPILOT_NOTIFY CC_CMDS_SESSION_NOTIFY | sort)

if [[ ! -f "$EMITTER" ]]; then
  echo "SKIP: notify-run.sh not found under $orch_root — banner emitter not present"
  exit 0
fi
if [[ ! -f "$KICKOFF" ]]; then
  echo "SKIP: autopilot/SKILL.md not found under $skills_root"
  exit 0
fi
if [[ ! -f "$SEATDOC" ]]; then
  echo "SKIP: hooks/README.md not found under $hooks_root — session seats not present"
  exit 0
fi

fail=0
prose_names_all=""

# --- Emitter side ----------------------------------------------------------
# Comments are stripped first. Prose in this file legitimately names the seam
# family and the switch itself, and a lint that reads a comment as a declaration
# would be measuring the file's documentation rather than what it reads.
emitter_names=$(sed 's/#.*//' "$EMITTER" \
  | grep -ohE 'CC_CMDS_[A-Z0-9_]+' \
  | sort -u \
  | grep -vE '^CC_CMDS_NOTIFY_' || true)

if [[ "$emitter_names" != "$KNOWN_SWITCHES" ]]; then
  echo "FAIL: notify-run.sh — 시험 이음매(CC_CMDS_NOTIFY_*)를 뺀 CC_CMDS_ 변수 집합이 등록된 집합과 다르다" >&2
  echo "       찾은 것: $(printf '%s' "$emitter_names" | tr '\n' ' ')" >&2
  echo "       등록된 것: $(printf '%s' "$KNOWN_SWITCHES" | tr '\n' ' ')" >&2
  fail=1
fi

# --- Prose side (rule 2), once per switch ----------------------------------
# One function rather than two copies: the second switch was added by adding a
# call, and a copy is what would let the two halves grow apart — which is the
# same class of drift the whole file exists to catch, one level up.
check_prose() {
  local label="$1" file="$2" marker="$3" line n_line names n_names
  line=$(grep -F "$marker" "$file" || true)
  n_line=$(printf '%s\n' "$line" | grep -c . || true)
  if [[ "${n_line:-0}" != "1" ]]; then
    echo "FAIL: ${label} — 「${marker}」 문장이 ${n_line:-0}회 (기대 1회)" >&2
    fail=1
    return 0
  fi
  names=$(printf '%s' "$line" | grep -ohE 'CC_CMDS_[A-Z0-9_]+' | sort -u || true)
  n_names=$(printf '%s\n' "$names" | grep -c . || true)
  if [[ "${n_names:-0}" != "1" ]]; then
    echo "FAIL: ${label} — 「${marker}」 문장이 담은 CC_CMDS_ 토큰이 ${n_names:-0}개 (기대 1개)" >&2
    fail=1
    return 0
  fi
  prose_names_all="${prose_names_all}${names}
"
  return 0
}

check_prose "autopilot/SKILL.md" "$KICKOFF" '전부 끄시려면'
check_prose "hooks/README.md"    "$SEATDOC" '이 머신의 일반 세션 배너를 끄시려면'

# --- Rule 3: the two SETS agree --------------------------------------------
# Set against set, not string against string. The moment rule 1 became a set the
# code side had two entries and the prose side one per document, so an equality
# between two single strings could never hold again — it would have failed
# forever on a tree that was correct.
if [[ "$fail" == "0" ]]; then
  prose_set=$(printf '%s' "$prose_names_all" | grep -v '^$' | sort -u || true)
  if [[ "$emitter_names" != "$prose_set" ]]; then
    echo "FAIL: 킬스위치 이름 집합이 코드와 문면 사이에서 갈렸다" >&2
    echo "       emitter: $(printf '%s' "$emitter_names" | tr '\n' ' ')" >&2
    echo "       문면   : $(printf '%s' "$prose_set" | tr '\n' ' ')" >&2
    fail=1
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-notify-env-name: violations found" >&2
  exit 1
fi

echo "OK:   notify env name — 킬스위치 집합 [$(printf '%s' "$emitter_names" | tr '\n' ' ')] 이 emitter 와 두 안내 문면에서 일치"
exit 0
