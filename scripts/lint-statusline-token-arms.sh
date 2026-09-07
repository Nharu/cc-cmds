#!/usr/bin/env bash
# Lint the run-state vocabulary against the status line's render arms.
#
# WHY THIS IS A SHIPPING CONDITION AND NOT A NICETY. The render's `case` ends in
# `*) emit_fallback; exit 0 ;;`, and those bytes are deliberately identical to
# the "this session has no run" line. So a token that reaches the render without
# an arm does not raise an error — it produces a line that says the session has
# nothing to report. A reviewer cannot tell "we decided not to report this" from
# "there is nothing to report", and the suite, the render probe and the apply
# verification are all green. That is the same failure shape this whole design
# set out to remove, walking back in through a different door.
#
# Rules:
#   1  every token `cc_run_state` can print has exactly one `case` arm   [fail]
#   2  every non-default arm names a token `cc_run_state` can print      [fail]
#
# THE TOKEN SET IS EXTRACTED, NEVER RETYPED. Writing the tokens into this file
# would make it a third copy of the vocabulary, and a copy is the thing the lint
# exists to prevent. `lint-ledger-row-length.sh` pulls `GATE_ROW_MAX` out of its
# declaration for the same reason.
#
# Usage:
#   bash scripts/lint-statusline-token-arms.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>     # directory holding liveness.sh and statusline.sh
#
# Posture: if either file is absent the whole check is a silent skip, matching
# the sibling lints during an incremental rollout.
#
# Exit codes:
#   0 — pass (or skipped)
#   1 — at least one violation
#   2 — the mechanism is present but no token could be extracted
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no `mapfile`.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
orch_root="${ORCH_ROOT:-$repo_root/plugins/cc-cmds/orchestrator}"
LIVENESS="$orch_root/liveness.sh"
STATUSLINE="$orch_root/statusline.sh"

if [[ ! -f "$LIVENESS" ]] || [[ ! -f "$STATUSLINE" ]]; then
  echo "SKIP: liveness.sh 또는 statusline.sh 가 $orch_root 에 없다 — 기제 부재"
  exit 0
fi

fail=0

# --- SOT extraction --------------------------------------------------------
#
# NO awk, and that is deliberate — the same reason `lint-cutpoint-vocabulary.sh`
# gives. The tokens here are Korean by nature, and the macOS CI runner's awk
# mishandled exactly that in a sibling lint while two local builds passed. `sed`
# sees only byte patterns and the comparisons below are shell string equality,
# which is byte equality.
#
# Comment lines are dropped before the match so a `printf '…'` quoted inside a
# comment cannot become a token.
tokens=$(sed -n '/^cc_run_state() {/,/^}/p' "$LIVENESS" \
  | { grep -v '^[[:space:]]*#' || true; } \
  | sed -n -E "s/.*printf '([^']*)'.*/\1/p" \
  | LC_ALL=C sort -u)

if [[ -z "$tokens" ]]; then
  echo "FAIL: liveness.sh — cc_run_state 가 낼 수 있는 토큰을 하나도 추출하지 못했다 (어휘 SOT 부재)" >&2
  exit 2
fi

# --- Arm extraction --------------------------------------------------------
#
# An arm label is a whole line that is one bare word followed by `)`. The
# character class rules out every other line in that range that happens to end
# in `)` — a command substitution carries `$`, `(` and whitespace, an assignment
# carries `=`.
#
# `|` and `*` are ADMITTED here and judged below rather than filtered out. A
# grouped arm (`정지경고|버려짐)`) would otherwise vanish from the extraction and
# take its tokens' rule-1 check with it, which is the silent hole this lint is
# about.
arms=$(sed -n '/^case "\$best_state" in$/,/^esac$/p' "$STATUSLINE" \
  | { grep -v '^[[:space:]]*#' || true; } \
  | sed -n -E 's/^[[:space:]]*([^[:space:]()=$"]+)\)[[:space:]]*$/\1/p')

# --- Rule 1: every token has exactly one arm -------------------------------
for t in $tokens; do
  n=0
  while IFS= read -r arm; do
    [[ -n "$arm" ]] || continue
    [[ "$arm" == "$t" ]] && n=$((n + 1))
  done <<EOF
$arms
EOF
  if [[ "$n" != "1" ]]; then
    echo "FAIL: 토큰 '$t' 의 statusline case 팔이 ${n}개 (기대 1개)" >&2
    echo "       팔이 없으면 기본 팔이 폴백을 내므로, 「보고하지 않기로 했다」와" >&2
    echo "       「보고할 것이 없다」가 바이트 동일해진다." >&2
    fail=1
  fi
done

# --- Rule 2: every non-default arm names a real token ----------------------
narm=0
while IFS= read -r arm; do
  [[ -n "$arm" ]] || continue
  [[ "$arm" == "*" ]] && continue
  case "$arm" in
    *"|"*)
      echo "FAIL: case 팔 '$arm' 이 토큰을 묶었다 — 팔은 토큰당 하나여야 한다" >&2
      fail=1
      continue
      ;;
  esac
  narm=$((narm + 1))
  found=0
  for t in $tokens; do [[ "$t" == "$arm" ]] && found=1; done
  if [[ "$found" != "1" ]]; then
    echo "FAIL: case 팔 '$arm' 을 cc_run_state 가 낼 수 없다" >&2
    fail=1
  fi
done <<EOF
$arms
EOF

if [[ "$fail" != "0" ]]; then
  echo "lint-statusline-token-arms: violations found" >&2
  exit 1
fi

ntok=0; for t in $tokens; do ntok=$((ntok + 1)); done
echo "OK:   statusline token arms — 토큰 ${ntok}개, case 팔 ${narm}개, 양방향 일대일"
exit 0
