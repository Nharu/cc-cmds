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
#   3  the same pair again, against `cc_run_grade`'s arms                [fail]
#
# RULE 3 EXISTS BECAUSE THE VOCABULARY LIVES IN THREE PLACES, not two. Adding a
# token means touching `cc_run_state` (the SOT), the render `case`, and
# `cc_run_grade`. Rules 1 and 2 tie the first and second together, so an edit
# that fixes both and forgets the grade passes — and this lint is precisely what
# trains that edit. The forgotten token then falls to `cc_run_grade`'s `*)` arm,
# whose own comment calls it SILENT, and takes the worst rank. It does not
# vanish into the fallback: it loses the line to every other run in the session,
# so an ACTIVE run is beaten by a finished one and the symptom this design set
# out to remove walks back in through a third door.
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
#
# EVERY OCCURRENCE, NOT THE LAST ONE PER LINE. The first shape here was
# `s/.*printf '([^']*)'.*/\1/p`, whose leading `.*` is greedy: on a line holding
# two literals only the second survived. Driven to its end that is a real
# defect and not a tidiness point — with `if x; then printf 'A'; else printf
# 'B'; fi` on one line and an arm only for `B`, this lint printed
# `양방향 일대일` and exited 0 on exactly the shape the header above says it
# exists to catch. The `grep -o` stage collects them all, exists on BSD and GNU
# alike, and keeps the no-`awk` posture. It closes a second hole with the same
# stroke: a trailing code comment (`printf 'REAL'  # printf 'DECOY'`) used to
# lose `REAL` and invent `DECOY`, because the strip above only handles WHOLE
# comment lines. Now both are collected, the real token survives, and the decoy
# fails loudly under rule 2 instead of quietly replacing it.
tokens=$(sed -n '/^cc_run_state() {/,/^}/p' "$LIVENESS" \
  | { grep -v '^[[:space:]]*#' || true; } \
  | { grep -o "printf '[^']*'" || true; } \
  | sed -n -E "s/^printf '(.*)'$/\1/p" \
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
# `|` and `*` are ADMITTED here and judged below rather than filtered out, and
# the reason is message quality, not a hole. Rule 1 walks the TOKEN set and not
# the arms, so a grouped arm (`정지경고|버려짐)`) dropped at extraction would
# still leave each of its tokens with a truthful `팔이 0개` — nothing goes
# silent either way. What admitting them buys is a report that names the actual
# mistake instead of two lines that send the reader hunting for arms that are
# sitting right there.
arms=$(sed -n '/^case "\$best_state" in$/,/^esac$/p' "$STATUSLINE" \
  | { grep -v '^[[:space:]]*#' || true; } \
  | sed -n -E 's/^[[:space:]]*([^[:space:]()=$"]+)\)[[:space:]]*$/\1/p')

# --- Grade arm extraction --------------------------------------------------
#
# The same shape one function over, with one difference: `cc_run_grade` puts the
# arm body on the label's own line (`도는중)   printf '1' ;;`), so the tail is
# optional here rather than absent. Built on the repaired primitive above and in
# the SAME EDIT as that repair — written against the greedy one it would have
# reproduced that hole a function away, which is the whole reason the two were
# not split into two passes.
grade_arms=$(sed -n '/^cc_run_grade() {/,/^}/p' "$LIVENESS" \
  | { grep -v '^[[:space:]]*#' || true; } \
  | sed -n -E 's/^[[:space:]]*([^[:space:]()=$"]+)\)[[:space:]]*(printf.*)?$/\1/p')

# Separated from a rule violation for the same reason the token check above is:
# "the grade function is there and could not be read" is a different event from
# "its arms are wrong", and folding them would let a broken `sed` report a
# violation it never checked.
if [[ -z "$grade_arms" ]]; then
  echo "FAIL: liveness.sh — cc_run_grade 의 case 팔을 하나도 추출하지 못했다 (등급 기제 부재)" >&2
  exit 2
fi

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

# --- Rule 3: the same pair, against `cc_run_grade` -------------------------
#
# The failure this catches costs something DIFFERENT from a missing render arm,
# so the message says so. A missing render arm prints the "no run" bytes; a
# missing grade arm prints a correct line and then loses it to every other run
# in the session.
for t in $tokens; do
  n=0
  while IFS= read -r arm; do
    [[ -n "$arm" ]] || continue
    [[ "$arm" == "$t" ]] && n=$((n + 1))
  done <<EOF
$grade_arms
EOF
  if [[ "$n" != "1" ]]; then
    echo "FAIL: 토큰 '$t' 의 cc_run_grade 팔이 ${n}개 (기대 1개)" >&2
    echo "       팔이 없으면 기본 팔이 최악 등급을 조용히 돌려주므로, 그 런은" >&2
    echo "       폴백으로 사라지는 대신 같은 세션의 다른 모든 런에게 화면을 내준다." >&2
    fail=1
  fi
done

ngrade=0
while IFS= read -r arm; do
  [[ -n "$arm" ]] || continue
  [[ "$arm" == "*" ]] && continue
  case "$arm" in
    *"|"*)
      echo "FAIL: cc_run_grade 팔 '$arm' 이 토큰을 묶었다 — 팔은 토큰당 하나여야 한다" >&2
      fail=1
      continue
      ;;
  esac
  ngrade=$((ngrade + 1))
  found=0
  for t in $tokens; do [[ "$t" == "$arm" ]] && found=1; done
  if [[ "$found" != "1" ]]; then
    echo "FAIL: cc_run_grade 팔 '$arm' 을 cc_run_state 가 낼 수 없다" >&2
    fail=1
  fi
done <<EOF
$grade_arms
EOF

if [[ "$fail" != "0" ]]; then
  echo "lint-statusline-token-arms: violations found" >&2
  exit 1
fi

ntok=0; for t in $tokens; do ntok=$((ntok + 1)); done
echo "OK:   statusline token arms — 토큰 ${ntok}개, case 팔 ${narm}개, 등급 팔 ${ngrade}개, 삼중 일대일"
exit 0
