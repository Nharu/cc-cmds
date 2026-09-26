#!/usr/bin/env bash
#
# lint-interview-convention-refs.sh — the shared requirements-interview
# convention is read by exactly the skills it lists, once each, where it says.
#
# 스킬 문면을 비교하며 기록을 보지 않는다. The interview's discipline was moved
# out of `design` into `_common/requirements-interview.md` so that the
# unattended kickoff asks with the same depth. What keeps that true is text, and
# text drifts in ways no stage test sees: a consumer drops its read sentence and
# interviews shallowly, a second copy of the discipline grows back in a consumer
# and the two diverge, the unattended design stage starts reading a file full of
# questions it may not ask, or the kickoff's same-turn rule slides out of the
# block that survives compaction.
#
# Assertions (each FAIL line names its number as `[단언 N]`):
#    1. If any skill carries the read phrase, the convention file exists. With
#       neither, the mechanism is absent and the lint SKIPs.
#    2. The convention's `## Consumers` lists `design/SKILL.md` and
#       `autopilot/SKILL.md`.
#    3. Each listed consumer carries the read phrase exactly once, inside the
#       zone its `## Consumers` line opens.
#    4. Every file carrying the read phrase is a listed consumer.
#    5. The unattended design stage does not name the convention.
#    6. The seven discipline phrases are in the convention and in no consumer.
#    7. Outside its `## Consumers` section the convention names no consumer
#       step: no `Step <digit>` and no standalone `5a`–`5n`.
#    8. In autopilot, `**5j — ` comes before `**5a — `.
#    9. The autopilot CFI block holds exactly one `**CFI-9 — ` line.
#   10. The fixed trailer line is in autopilot exactly once, inside that block.
#
# A zone runs from the line that opens it to the next line matching
# `^\*\*5[a-n]( |\(|—)` or `^#{1,4} ` outside a code fence.
#
# Usage: bash scripts/lint-interview-convention-refs.sh
#
# Env override:
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#
# Exit codes:
#   0  pass, or a SKIP because neither the convention nor a reader exists
#   1  at least one assertion is broken
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

RI_REL="_common/requirements-interview.md"
RI="$skills_root/$RI_REL"
AP="$skills_root/autopilot/SKILL.md"
DDU="$skills_root/design-discuss-unattended/SKILL.md"

READ_PHRASE='${CLAUDE_SKILL_DIR}/../_common/requirements-interview.md'
REQUIRED='design/SKILL.md
autopilot/SKILL.md'
FENCE_PHRASES='Ask deep, non-obvious questions
covering all aspects of the task
Avoid generic or superficial questions
Single filter test
Two-tier fallback when reproduction fails
Scan the other open issues
Iterate between interviewing and codebase exploration'
TRAILER='런은 아직 시작되지 않았습니다 — 아래 질문에 답하셔야 이어집니다'

# zone <file> <opening prefix> — the lines of the zone the prefix opens.
zone() {
  awk -v p="$2" '
    started == 0 { if (index($0, p) == 1) { started = 1; print } ; next }
    /^```/ { fence = !fence; print; next }
    fence == 0 && ($0 ~ /^\*\*5[a-n]( |\(|—)/ || $0 ~ /^(#|##|###|####) /) { exit }
    { print }
  ' "$1"
}

# count <needle> — occurrences of a fixed string in stdin.
count() { { grep -oF -- "$1" || true; } | wc -l | tr -d ' '; }

fail=0
flag() {
  # flag <n> <file> <message>
  echo "FAIL: [단언 $1] $2 — $3" >&2
  fail=1
}

readers=$(cd "$skills_root" && { grep -rlF --include='*.md' -- "$READ_PHRASE" . || true; } \
  | sed 's|^\./||' | grep -vxF "$RI_REL" | sort || true)

# --- 1. A reader implies the convention --------------------------------------
if [[ ! -f "$RI" ]]; then
  if [[ -z "$readers" ]]; then
    echo "SKIP: $RI_REL — 공유 인터뷰 규약도 그것을 읽는 스킬도 없다"
    exit 0
  fi
  flag 1 "$RI" "없다 ; 읽기 문구를 담은 스킬이 있다: $(printf '%s\n' "$readers" | paste -sd ' ' -)"
  echo "lint-interview-convention-refs: violations found" >&2
  exit 1
fi

consumers=$(awk '/^## Consumers$/ { f = 1; next } f && /^## / { exit } f { print }' "$RI" \
  | sed -n 's/^- `\([^`]*\)` — `\(.*\)`$/\1	\2/p')

# --- 2. The two consumers are listed ----------------------------------------
consumer_files=$(printf '%s\n' "$consumers" | cut -f1)
while IFS= read -r req; do
  grep -qxF -- "$req" <<< "$consumer_files" \
    || flag 2 "$RI" "## Consumers 에 $req 가 없다"
done <<< "$REQUIRED"

# --- 3. Each consumer reads it once, in its zone ----------------------------
while IFS='	' read -r rel opener; do
  [[ -n "$rel" ]] || continue
  file="$skills_root/$rel"
  if [[ ! -f "$file" ]]; then
    flag 3 "$file" "등록된 소비자 파일이 없다"
    continue
  fi
  in_file=$(count "$READ_PHRASE" < "$file")
  in_zone=$(zone "$file" "$opener" | count "$READ_PHRASE")
  if [[ "$in_zone" != "1" || "$in_file" != "1" ]]; then
    flag 3 "$file" "읽기 문구가 「${opener}」 구역에 ${in_zone}번, 파일 전체에 ${in_file}번 있다 ; 구역 안에 정확히 한 번이어야 한다"
  fi
done <<< "$consumers"

# --- 4. Every reader is listed -----------------------------------------------
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  grep -qxF -- "$rel" <<< "$consumer_files" \
    || flag 4 "$skills_root/$rel" "읽기 문구를 담았지만 ## Consumers 에 등록되지 않았다"
done <<< "$readers"

# --- 5. The unattended design stage stays away -------------------------------
if [[ -f "$DDU" ]] && grep -qF 'requirements-interview' "$DDU"; then
  flag 5 "$DDU" "무인 설계 스테이지가 공유 인터뷰 규약을 부른다 ; 물을 수 없는 질문을 읽게 된다"
fi

# --- 6. The discipline lives in one place -----------------------------------
while IFS= read -r phrase; do
  grep -qF -- "$phrase" "$RI" || flag 6 "$RI" "울타리 문구 「${phrase}」 가 없다"
  while IFS='	' read -r rel opener; do
    [[ -n "$rel" && -f "$skills_root/$rel" ]] || continue
    grep -qF -- "$phrase" "$skills_root/$rel" \
      && flag 6 "$skills_root/$rel" "울타리 문구 「${phrase}」 가 소비자에 남아 있다 ; 사본은 갈라진다"
  done <<< "$consumers"
done <<< "$FENCE_PHRASES"

# --- 7. The convention names no consumer step --------------------------------
outside=$(awk '/^## Consumers$/ { skip = 1; next } skip && /^## / { skip = 0 } !skip { print NR ": " $0 }' "$RI")
hits=$(printf '%s\n' "$outside" | grep -E 'Step [0-9]|(^|[^[:alnum:]])5[a-n]([^[:alnum:]]|$)' || true)
[[ -z "$hits" ]] || flag 7 "$RI" "## Consumers 밖에서 소비자의 단계를 부른다: $(printf '%s\n' "$hits" | sed -n 1p | cut -c1-120)"

# --- 8–10. autopilot's order and its CFI block -------------------------------
if [[ ! -f "$AP" ]]; then
  flag 8 "$AP" "없다"
else
  j=$({ grep -n '^\*\*5j — ' "$AP" || true; } | sed -n 1p | cut -d: -f1)
  a=$({ grep -n '^\*\*5a — ' "$AP" || true; } | sed -n 1p | cut -d: -f1)
  if [[ -z "$j" || -z "$a" ]]; then
    flag 8 "$AP" "**5j — 또는 **5a — 문단이 없다"
  elif (( j > a )); then
    flag 8 "$AP" "**5j — (${j}행)가 **5a — (${a}행)보다 뒤다 ; 요구가 경계 질문보다 먼저 정해져야 한다"
  fi

  cfi=$(awk '/^## Control-Flow Invariants$/ { f = 1; next } f && /^## / { exit } f { print }' "$AP")
  n9=$(printf '%s\n' "$cfi" | grep -c '^\*\*CFI-9 — ' || true)
  [[ "$n9" == "1" ]] || flag 9 "$AP" "CFI 블록에 **CFI-9 — 줄이 ${n9}개다 ; 정확히 하나여야 한다"

  t_all=$(count "$TRAILER" < "$AP")
  t_cfi=$(printf '%s\n' "$cfi" | count "$TRAILER")
  if [[ "$t_all" != "1" || "$t_cfi" != "1" ]]; then
    flag 10 "$AP" "꼬리 문장이 파일에 ${t_all}번, CFI 블록에 ${t_cfi}번 있다 ; CFI 블록 안에 정확히 한 번이어야 한다"
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-interview-convention-refs: violations found" >&2
  exit 1
fi
echo "OK:   interview convention refs — 소비자 $(printf '%s\n' "$consumers" | grep -c .)개가 각자 구역에서 한 번 읽는다"
exit 0
