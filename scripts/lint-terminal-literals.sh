#!/usr/bin/env bash
#
# lint-terminal-literals.sh — the terminal literals the driver matches are still
# carried, byte for byte, by the skills that emit and quote them.
#
# `run.sh` recognises the end of a design, audit or re-convergence stage by
# finding a fixed literal in the stage's stream (`LIT_DESIGN_TERMINAL`,
# `LIT_AUDIT_TERMINAL`, `LIT_RECONVERGE_TERMINAL`). The same literal is written
# in places the driver never reads: the skill that tells the model to print it,
# and the skills that quote it to match it or to describe the match. Nothing
# else checks that those copies still exist. Trimming a skill's prose can delete
# the sentence while every test stays green, and from then on every such stage
# ends as a vacuous success.
#
# The values are EXTRACTED from `run.sh`, never restated here: the driver's
# declaration is the one source, so changing it without the skills is itself a
# violation this lint reports.
#
# Rules:
#   1. [exit 2] `run.sh` declares each of the three on exactly one line of the
#      shape `readonly LIT_<KIND>_TERMINAL='<text>'`, with a non-empty value.
#      No `run.sh`, no declaration or two declarations all mean there is no
#      single source, which is not a verdict about the skills.
#   2. [fail] Each emitter carries its literal at least once. A missing emitter
#      file is a failure, not a skip: an emitter that disappeared is exactly the
#      case where the driver stops recognising the stage.
#   3. [fail] Each consumer carries each literal it quotes exactly as many times
#      as the table below says, counted per OCCURRENCE (`grep -o`), not per
#      line. A copy changed by one character looks the same as a copy that is
#      absent, so a consumer can only be checked against an expected count, and
#      a line count would still pass when the second copy on a line is the one
#      that changed. A (file, literal) pair the table does not list is not
#      checked. A missing consumer file is a failure.
#
# Usage: bash scripts/lint-terminal-literals.sh
#
# Env override:
#   ORCH_ROOT    orchestrator directory (default plugins/cc-cmds/orchestrator)
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#
# Exit codes:
#   0  every pin holds
#   1  at least one pin is broken
#   2  `run.sh` does not give a single source for some literal
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"

RUN_SH="$orch_root/run.sh"
NAMES="LIT_DESIGN_TERMINAL LIT_AUDIT_TERMINAL LIT_RECONVERGE_TERMINAL"

# <path under SKILLS_ROOT> <literal name>
EMITTERS="design/SKILL.md LIT_DESIGN_TERMINAL
design-audit/SKILL.md LIT_AUDIT_TERMINAL
design-discuss-unattended/SKILL.md LIT_DESIGN_TERMINAL
design-reconverge/SKILL.md LIT_RECONVERGE_TERMINAL
design-audit-unattended/SKILL.md LIT_AUDIT_TERMINAL"

# <path under SKILLS_ROOT> <literal name> <occurrences>
CONSUMERS="_common/pipeline-sidecar.md LIT_DESIGN_TERMINAL 2
_common/pipeline-sidecar.md LIT_AUDIT_TERMINAL 1
autopilot-router-shift/SKILL.md LIT_DESIGN_TERMINAL 2
autopilot-router-shift/SKILL.md LIT_RECONVERGE_TERMINAL 1
autopilot/SKILL.md LIT_DESIGN_TERMINAL 2"

# --- Rule 1: extract the source ----------------------------------------------
#
# The anchor is the WHOLE LINE, so a trailing comment or a second statement on
# the declaration line surfaces as "no source" rather than as a wrong value.
if [[ ! -f "$RUN_SH" ]]; then
  echo "FAIL: $RUN_SH — 없다 ; 종단 리터럴의 원천을 읽을 수 없다" >&2
  exit 2
fi

for name in $NAMES; do
  value=$(sed -n "s/^readonly ${name}='\\(.*\\)'\$/\\1/p" "$RUN_SH")
  count=$(printf '%s\n' "$value" | grep -c . || true)
  if [[ "$count" == "0" ]]; then
    echo "FAIL: $RUN_SH — readonly ${name}='<문면>' 을 찾지 못했다 (원천 부재)" >&2
    exit 2
  fi
  if [[ "$count" != "1" ]]; then
    echo "FAIL: $RUN_SH — ${name} 선언이 ${count}개다 ; 정확히 하나여야 원천이 성립한다" >&2
    exit 2
  fi
  printf -v "$name" '%s' "$value"
done

fail=0

# --- Rule 2: every emitter still prints its literal ----------------------------
n_emit=0
while read -r rel name; do
  [[ -n "$rel" ]] || continue
  n_emit=$((n_emit + 1))
  file="$skills_root/$rel"
  lit="${!name}"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — 발신 파일이 없다 ; ${name} 「${lit}」 을 낼 곳이 사라졌다" >&2
    fail=1
  elif ! grep -qF -- "$lit" "$file"; then
    echo "FAIL: $file — ${name} 「${lit}」 을 담지 않는다 ; 드라이버가 이 스테이지의 종료를 알아보지 못한다" >&2
    fail=1
  fi
done <<< "$EMITTERS"

# --- Rule 3: every consumer quotes the source byte for byte --------------------
n_cons=0
seen=" "
while read -r rel name want; do
  [[ -n "$rel" ]] || continue
  case "$seen" in *" $rel "*) ;; *) seen="$seen$rel "; n_cons=$((n_cons + 1)) ;; esac
  file="$skills_root/$rel"
  lit="${!name}"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $file — 소비 파일이 없다 ; ${name} 사본 ${want}개를 확인할 수 없다" >&2
    fail=1
    continue
  fi
  got=$( { grep -oF -- "$lit" "$file" || true; } | wc -l)
  got=$((got))
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $file — ${name} 「${lit}」 의 원천과 같은 사본이 ${got}개다 ; 기대 ${want}개" >&2
    fail=1
  fi
done <<< "$CONSUMERS"

if [[ "$fail" != "0" ]]; then
  echo "lint-terminal-literals: violations found" >&2
  exit 1
fi
echo "OK:   terminal literals — run.sh 원천 3개, 발신 ${n_emit}개, 소비 ${n_cons}개 파일이 온전하다"
exit 0
