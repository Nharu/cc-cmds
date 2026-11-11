#!/usr/bin/env bash
#
# lint-kickoff-recommendations.sh — every recommendation line of the autopilot
# kickoff says where its recommendation comes from.
#
# The kickoff shows two kinds of recommendation that look alike on screen: one
# the entry judgment chose for this work (` ← 추천`, ` ← 에이전트 추천`) and one
# the skill fixes as policy whatever the work (` ← 기본값`). A person who cannot
# tell them apart reads a fixed policy default as advice about the task. Each
# line that carries recommendation wording therefore carries a backquoted source
# token, and this lint is what notices a line that lost it or never had it.
#
# Targets — a closed list, not a glob, so a rename fails instead of silently
# dropping a file: `autopilot/SKILL.md` and `autopilot/references/boundaries.md`
# under the skills root. The other autopilot files with recommendation wording
# are not kickoff questions (the seat's gate approval suffix, the morning
# report's tally exclusion).
#
# Detector (per line): `[Rr]ecommend|← 추천|← 에이전트 추천|← 기본값|\(권장\)`.
#
# Markers: the string `← 추천`, `← 에이전트 추천` or `← 기본값` right after one
# space, inside or outside backquotes. A mention such as (`← 추천`) names the
# marker — a backquote or a parenthesis stands before it — and is not a marker.
#
# Tokens: the backquoted spans of the line that start with `추천 출처:` or equal
# `추천 없음`. The closed set is
#   `추천 출처: 판정 <key>`   — <key> must be a property of the entry-plan schema
#   `추천 출처: 기본값`
#   `추천 출처: 킥오프 기본값`
#   `추천 없음`
#
# Rules, on every detected line:
#   1. [fail] `(권장)` appears.
#   2. [fail] a span starts with `추천 출처:` and is not one of the closed forms.
#   3. [fail] a judgment token names a key outside the schema's `properties`.
#   4. [fail] the line carries at least one marker, and the number of judgment
#      tokens differs from the number of ` ← 추천` + ` ← 에이전트 추천` markers,
#      or the number of default tokens differs from the number of ` ← 기본값`
#      markers, or the line carries `추천 없음`. `추천 출처: 킥오프 기본값` pairs
#      with no marker and is not counted.
#   5. [fail] the line carries no marker and no token of the closed set.
#   6. [fail] a target file or the schema is missing, or the schema's
#      `properties` cannot be read.
#
# WHAT THIS DOES NOT CHECK: a recommendation written without the word
# "recommend" and without a marker is not detected, and whether `추천 없음` is
# used honestly is a reviewer's call, not this lint's.
#
# Usage: bash scripts/lint-kickoff-recommendations.sh
#
# Env overrides (fixture runner):
#   SKILLS_ROOT        skills directory (default plugins/cc-cmds/skills)
#   ENTRY_PLAN_SCHEMA  entry-plan schema (default
#                      plugins/cc-cmds/orchestrator/prompts/entry-plan.schema.json)
#
# Exit codes:
#   0  pass
#   1  at least one violation
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
schema="${ENTRY_PLAN_SCHEMA:-$repo_root/plugins/cc-cmds/orchestrator/prompts/entry-plan.schema.json}"

TARGETS="autopilot/SKILL.md autopilot/references/boundaries.md"

DETECT_RE='[Rr]ecommend|← 추천|← 에이전트 추천|← 기본값|\(권장\)'
JUDGED_RE='^추천 출처: 판정 [A-Za-z_][A-Za-z0-9_]*$'

fail=0
checked=0

if [[ ! -f "$schema" ]]; then
  echo "FAIL: 진입 판단 스키마가 없다: $schema" >&2
  exit 1
fi
if ! schema_keys=$(jq -er '.properties | keys[]' "$schema" 2>/dev/null); then
  echo "FAIL: 진입 판단 스키마의 properties 를 읽지 못했다: $schema" >&2
  exit 1
fi

# Number of occurrences of a fixed string in a line. Captured rather than
# piped into an early-exiting reader, so `pipefail` never sees a SIGPIPE.
count_fixed() {
  printf '%s\n' "$1" | grep -oF -- "$2" | grep -c . || true
}

for rel in $TARGETS; do
  file="$skills_root/$rel"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: 검사 대상 파일이 없다: $file" >&2
    fail=1
    continue
  fi
  checked=$((checked + 1))
  bad=0
  hits=0

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    lineno="${entry%%:*}"
    line="${entry#*:}"
    hits=$((hits + 1))
    why=""

    # Backquoted spans: the even fields when the line is split on backquotes.
    spans=$(printf '%s\n' "$line" | awk -F'`' '{ for (i = 2; i < NF; i += 2) print $i }')

    n_judged=0
    n_default=0
    n_kickoff=0
    n_none=0
    while IFS= read -r span; do
      [[ -n "$span" ]] || continue
      case "$span" in
        "추천 없음")
          n_none=$((n_none + 1)) ;;
        "추천 출처: 기본값")
          n_default=$((n_default + 1)) ;;
        "추천 출처: 킥오프 기본값")
          n_kickoff=$((n_kickoff + 1)) ;;
        "추천 출처:"*)
          is_judged=$(printf '%s\n' "$span" | grep -cE "$JUDGED_RE" || true)
          if [[ "$is_judged" = "1" ]]; then
            key="${span#추천 출처: 판정 }"
            known=$(printf '%s\n' "$schema_keys" | grep -cxF -- "$key" || true)
            if [[ "$known" = "0" ]]; then
              why="${why:+$why; }스키마 properties 에 없는 판정 키 '$key'"
            fi
            n_judged=$((n_judged + 1))
          else
            why="${why:+$why; }닫힌 집합 밖 출처 토큰 '$span'"
          fi
          ;;
      esac
    done <<EOF
$spans
EOF

    if [[ "$(count_fixed "$line" '(권장)')" != "0" ]]; then
      why="${why:+$why; }(권장) 이 남아 있다"
    fi

    m_judged=$(( $(count_fixed "$line" ' ← 추천') + $(count_fixed "$line" ' ← 에이전트 추천') ))
    m_default=$(count_fixed "$line" ' ← 기본값')

    if (( m_judged + m_default > 0 )); then
      if (( n_judged != m_judged )); then
        why="${why:+$why; }판정 표지 ${m_judged}개에 판정 토큰 ${n_judged}개"
      fi
      if (( n_default != m_default )); then
        why="${why:+$why; }기본값 표지 ${m_default}개에 기본값 토큰 ${n_default}개"
      fi
      if (( n_none > 0 )); then
        why="${why:+$why; }표지가 있는 줄에 \`추천 없음\`"
      fi
    elif (( n_judged + n_default + n_kickoff + n_none == 0 )); then
      why="${why:+$why; }출처 토큰이 없다"
    fi

    if [[ -n "$why" ]]; then
      echo "FAIL: $rel:$lineno — $why: ${line:0:100}" >&2
      bad=$((bad + 1))
    fi
  done < <(grep -nE "$DETECT_RE" "$file" || true)

  if [[ "$bad" = "0" ]]; then
    echo "OK:   $rel — 추천 문면 ${hits}줄 모두 출처 토큰을 지닌다"
  else
    fail=1
  fi
done

if [[ "$fail" != "0" ]]; then
  echo "lint-kickoff-recommendations: violations found" >&2
  exit 1
fi
echo "lint-kickoff-recommendations: $checked file(s) checked"
exit 0
