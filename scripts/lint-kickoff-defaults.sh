#!/usr/bin/env bash
# Lint the kickoff defaults: only the kickoff reads them, and the key table has
# one owner on each side of the code/prose boundary.
#
# A person writes kickoff defaults ahead of time in a host file and in
# environment variables, and the kickoff shows them and takes one confirmation
# before freezing them into the manifest. The whole safety of that rests on the
# confirmation being the ONLY path from the file into a run: if the gate, the
# driver, the fleet or the watcher ever read the file, an edit to it would change
# a run that is already going, with nobody asked. A sentence in SKILL.md says so;
# this lint is what notices when an edit breaks it.
#
# Rules:
#   1  nothing under the orchestrator or the hooks — `rules/` included, because
#      the code the gate actually calls lives there — except the kickoff helper
#      itself names `autopilot-defaults`, `kickoff-defaults.sh` or
#      `CC_CMDS_AUTOPILOT_DEFAULT`. Comments count: a comment naming the helper
#      is how a caller starts.                                           [fail]
#   2  the helper's key table and the key table in SKILL.md 5o are the same
#      SET — a key the helper reads and the kickoff never mentions is a value
#      the person cannot find out how to write, and a key the kickoff mentions
#      that the helper does not read is one they write for nothing.     [fail]
#   3  the helper assigns none of the driver's vocabulary constants
#      (`CUTPOINTS=`, `REVIEW_POLICIES=`, `JUDGMENT_CLASSES=`,
#      `JUDGMENT_CLASSES_FORBIDDEN=`); it sources them, and a copy is what
#      would let the two vocabularies drift apart.                       [fail]
#   4  nothing under the orchestrator or the hooks except the re-kickoff
#      helper itself names `rekick.sh`. It reads a previous run's frozen
#      answers for a new kickoff to carry; a running run that called it would
#      be reading answers nobody confirmed for that run. Comments count, as in
#      rule 1. The pattern is the file name, so the notification kind `rekick`
#      the orchestrator already has is not caught.                       [fail]
#
# THE EXTRACTION RULE for rule 2:
#
#   code side   — the words of the two lines `KD_RUN_KEYS='…'` and
#                 `KD_REPO_KEYS='…'` in the helper.
#   prose side  — the first cell of every table row that starts with a
#                 backquoted key, inside the paragraph that begins `**5o — `
#                 and ends at the next `**5<letter> — ` or heading.
#
# Usage:
#   bash scripts/lint-kickoff-defaults.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # the orchestrator directory, holding kickoff-defaults.sh
#   HOOKS_ROOT=<dir>    # the hooks directory
#   SKILLS_ROOT=<dir>   # skills root holding autopilot/SKILL.md
#
# Posture: if the helper is absent the whole check is a silent skip.
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
hooks_root="${HOOKS_ROOT:-$repo_root/plugins/cc-cmds/hooks}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
HELPER="$orch_root/kickoff-defaults.sh"
REKICK="$orch_root/rekick.sh"
KICKOFF="$skills_root/autopilot/SKILL.md"

if [[ ! -f "$HELPER" ]]; then
  echo "SKIP: kickoff-defaults.sh not found under $orch_root — kickoff defaults not present"
  exit 0
fi
if [[ ! -f "$KICKOFF" ]]; then
  echo "SKIP: autopilot/SKILL.md not found under $skills_root"
  exit 0
fi

fail=0

# --- Rule 1: only the kickoff reads the defaults ----------------------------
readers=""
for dir in "$orch_root" "$hooks_root"; do
  [[ -d "$dir" ]] || continue
  hits=$(grep -rlE 'autopilot-defaults|kickoff-defaults\.sh|CC_CMDS_AUTOPILOT_DEFAULT' "$dir" 2>/dev/null || true)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == "$HELPER" ]] && continue
    readers="${readers}${f}
"
  done <<EOF
$hits
EOF
done
if [[ -n "$readers" ]]; then
  echo "FAIL: 킥오프 보조 밖에서 킥오프 기본값을 가리키는 파일이 있다 — 기본값은 킥오프만 읽는다" >&2
  printf '%s' "$readers" | sed 's/^/       /' >&2
  fail=1
fi

# --- Rule 2: the two key tables are one set ---------------------------------
code_keys=$(grep -E "^KD_(RUN|REPO)_KEYS='" "$HELPER" \
  | sed -E "s/^KD_(RUN|REPO)_KEYS='([^']*)'.*/\\2/" \
  | tr ' ' '\n' | grep -v '^$' | sort -u || true)
prose_keys=$(awk '/^\*\*5o — /{f=1; next} f&&(/^\*\*5[a-z] — /||/^#/){exit} f' "$KICKOFF" \
  | grep -E '^\| `[^`]+` \|' \
  | sed -E 's/^\| `([^`]+)` \|.*/\1/' | sort -u || true)

if [[ -z "$code_keys" ]]; then
  echo "FAIL: kickoff-defaults.sh — KD_RUN_KEYS·KD_REPO_KEYS 줄에서 키를 하나도 읽지 못했다" >&2
  fail=1
elif [[ -z "$prose_keys" ]]; then
  echo "FAIL: autopilot/SKILL.md — 5o 문단에서 키 표 행을 하나도 읽지 못했다" >&2
  fail=1
elif [[ "$code_keys" != "$prose_keys" ]]; then
  echo "FAIL: 킥오프 기본값 키 집합이 보조 스크립트와 SKILL.md 5o 사이에서 갈렸다" >&2
  echo "       보조 : $(printf '%s' "$code_keys" | tr '\n' ' ')" >&2
  echo "       5o 표: $(printf '%s' "$prose_keys" | tr '\n' ' ')" >&2
  fail=1
fi

# --- Rule 3: the vocabulary is sourced, never assigned ----------------------
# Comments are stripped first: the helper's prose names the constants it sources.
copies=$(sed 's/#.*//' "$HELPER" \
  | grep -nE '(^|[^A-Za-z0-9_])(CUTPOINTS|REVIEW_POLICIES|JUDGMENT_CLASSES|JUDGMENT_CLASSES_FORBIDDEN)=' || true)
if [[ -n "$copies" ]]; then
  echo "FAIL: kickoff-defaults.sh — 드라이버 어휘 상수를 대입한다 (소싱으로만 얻는다)" >&2
  printf '%s\n' "$copies" | sed 's/^/       /' >&2
  fail=1
fi

# --- Rule 4: only the kickoff calls the re-kickoff helper -------------------
callers=""
for dir in "$orch_root" "$hooks_root"; do
  [[ -d "$dir" ]] || continue
  hits=$(grep -rlE 'rekick\.sh' "$dir" 2>/dev/null || true)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == "$REKICK" ]] && continue
    callers="${callers}${f}
"
  done <<EOF
$hits
EOF
done
if [[ -n "$callers" ]]; then
  echo "FAIL: 재킥오프 보조 밖에서 rekick.sh 를 가리키는 파일이 있다 — 이전 런의 답은 킥오프만 읽는다" >&2
  printf '%s' "$callers" | sed 's/^/       /' >&2
  fail=1
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-kickoff-defaults: violations found" >&2
  exit 1
fi

echo "OK:   kickoff defaults — 킥오프만 읽고, 키 집합 $(printf '%s\n' "$code_keys" | grep -c .)개가 보조와 5o 에서 일치하며, 어휘 사본이 없고, 재킥오프 보조를 부르는 런 코드가 없다"
exit 0
