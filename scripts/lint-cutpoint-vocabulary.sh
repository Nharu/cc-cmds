#!/usr/bin/env bash
# Lint the permission-cutpoint vocabulary against its single source of truth.
#
# The cutpoint ladder exists in two forms that are NOT the same string: the
# STORED TOKEN the driver compares (`머지후착수`) and the DISPLAY FORM a human
# reads (`머지 후 후속 착수`). That difference shipped as a live defect — the
# documents rendered the display form, a grant written from it matched no token,
# `cutpoint_index` answered 0, and `authorized()` silently denied every act. The
# most permissive grant authorized nothing, and nothing said so.
#
# Rules:
#   1  every token in CUTPOINTS has exactly one `cutpoint_display` arm   [fail]
#   2  every `cutpoint_display` arm names a token that is in CUTPOINTS   [fail]
#   3  each consumer document renders the ladder EXACTLY as the display
#      forms joined in CUTPOINTS order, exactly once                     [fail]
#
# Rule 3 is the one that would have caught the shipped defect: it derives the
# expected ladder string from the driver rather than pinning a literal, so the
# check cannot drift away from the value it is protecting.
#
# Usage:
#   bash scripts/lint-cutpoint-vocabulary.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding run.sh
#   SKILLS_ROOT=<dir>   # skills root holding the consumer documents
#
# Posture: if run.sh is absent the whole check is a silent skip, so the script
# stays green during an incremental rollout.
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
DRIVER="$orch_root/run.sh"

if [[ ! -f "$DRIVER" ]]; then
  echo "SKIP: run.sh not found under $orch_root — cutpoint mechanism not present"
  exit 0
fi

# Consumer documents that render the ladder for a human. A document absent from
# disk is skipped rather than failed, for the same incremental-rollout reason.
CONSUMERS="autopilot/SKILL.md _common/pipeline-sidecar.md"

fail=0

# --- SOT extraction --------------------------------------------------------
tokens=$(sed -n 's/^readonly CUTPOINTS="\(.*\)"$/\1/p' "$DRIVER")
if [[ -z "$tokens" ]]; then
  echo "FAIL: run.sh — readonly CUTPOINTS=\"…\" 를 찾지 못했다 (어휘 SOT 부재)" >&2
  exit 1
fi

# Display arms, rendered as `<token>\t<display>` lines. The arm body is a single
# `printf '<display>'`, which is what makes this extractable without evaluating
# the script.
arms=$(awk '
  /^cutpoint_display\(\)/ { inf=1; next }
  inf && /^}/             { inf=0 }
  inf && /^[[:space:]]*[^*[:space:]][^)]*)[[:space:]]*printf/ {
    line=$0
    sub(/^[[:space:]]*/, "", line)
    tok=line; sub(/\).*/, "", tok)
    disp=line; sub(/^[^)]*\)[[:space:]]*printf[[:space:]]*./, "", disp); sub(/.[[:space:]]*;;.*/, "", disp)
    print tok "\t" disp
  }
' "$DRIVER")

# --- Rule 1: every token has exactly one arm -------------------------------
for t in $tokens; do
  n=$(printf '%s\n' "$arms" | awk -F'\t' -v t="$t" '$1==t{c++} END{print c+0}')
  if [[ "$n" != "1" ]]; then
    echo "FAIL: 토큰 '$t' 의 cutpoint_display arm 이 ${n}개 (기대 1개)" >&2
    fail=1
  fi
done

# --- Rule 2: every arm names a real token ----------------------------------
while IFS=$'\t' read -r tok disp; do
  [[ -n "$tok" ]] || continue
  found=0
  for t in $tokens; do [[ "$t" == "$tok" ]] && found=1; done
  if [[ "$found" != "1" ]]; then
    echo "FAIL: cutpoint_display arm '$tok' 이 CUTPOINTS 에 없다" >&2
    fail=1
  fi
done <<EOF
$arms
EOF

# --- Derive the expected ladder --------------------------------------------
ladder=""
for t in $tokens; do
  d=$(printf '%s\n' "$arms" | awk -F'\t' -v t="$t" '$1==t{print $2; exit}')
  [[ -n "$d" ]] || d="$t"
  if [[ -z "$ladder" ]]; then ladder="$d"; else ladder="$ladder → $d"; fi
done

# --- Rule 3: consumers render exactly that, exactly once -------------------
checked=0
for rel in $CONSUMERS; do
  f="$skills_root/$rel"
  [[ -f "$f" ]] || { echo "SKIP: $rel — not present"; continue; }
  checked=$((checked + 1))
  n=$(grep -cF "$ladder" "$f" || true)
  if [[ "$n" != "1" ]]; then
    echo "FAIL: $rel — 유도된 사다리 문면이 ${n}회 출현 (기대 1회)" >&2
    echo "       기대: $ladder" >&2
    fail=1
  fi
done

if [[ "$fail" != "0" ]]; then
  echo "lint-cutpoint-vocabulary: violations found" >&2
  exit 1
fi

echo "OK:   cutpoint vocabulary — 토큰 $(printf '%s\n' $tokens | grep -c .)개, 소비자 문서 ${checked}건, 사다리 유도 일치"
exit 0
