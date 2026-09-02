#!/usr/bin/env bash
# lint-autoadopt-vocabulary: self-skip
# Lint the judgment-class vocabulary against its single source of truth.
#
# `판단 부류` is the field the auto-adoption floor's first arm reads: the
# manifest declares a class in advance, and a judgment carrying that class is
# adopted without asking. So the set has to be closed, and closed on the FIRST
# DAY — which is the property that made a new field necessary rather than a
# reuse of `자율 승인.kind`. That field carries the act kind in practice, the
# ledger is append-only, and the rows already written can never be repaired; a
# lint over it could only ever warn. Here there are zero legacy rows, so the
# closed set can be enforced with no exception at all.
#
# Rules:
#   1  `JUDGMENT_CLASSES_FORBIDDEN` is a subset of `JUDGMENT_CLASSES`   [fail]
#   2  every literal `판단 부류=<값>` in the tree names one of the eight [fail]
#   3  the five emitted-judgment markers are defined under `_common/`    [fail]
#
# Rule 1 is not bookkeeping. The design's whole point about the two forbidden
# values is that they are NAMED and forbidden rather than left out: a class with
# no token has to borrow a permitted one when the decision is recorded, and that
# borrowing is the leak. With a token, the leak arrives as a refusal. Dropping
# either from the vocabulary would restore the leak silently, and rule 1 is what
# makes that a failing build.
#
# What counts as a literal: the three metasyntactic shapes the tree actually
# contains are recognised by shape and skipped — a shell expansion
# (`판단 부류=$cls`), a schema placeholder (`판단 부류=<여덟 값 중 하나>`) and a
# parser's own pattern (`s/^ *판단 부류=//p`) — and everything else made of
# Hangul, ASCII letters, digits, hyphens AND SPACES is a value claim.
#
# Spaces are inside that set deliberately. A value carrying a space is the shape
# this lint most needs to see: the driver's vocabulary check accepted one
# whenever the tokens it named sat next to each other in the vocabulary string,
# so `스테이지-재시도 팀-구성` read as permitted while also missing the
# forbidden list. Skipping space-carrying values as metasyntax made the lint
# blind to exactly that.
#
# Residual, stated rather than hidden: a file carrying the `self-skip` marker on
# its second line is not scanned at all, and `scripts/test-gate.sh` carries one
# because asserting that an out-of-vocabulary value is REFUSED requires writing
# one down. A typo in that file's good values is therefore not caught here; it
# is caught by the assertion itself failing.
#
# Usage:
#   bash scripts/lint-autoadopt-vocabulary.sh
#
# Env overrides (fixture runner):
#   ORCH_ROOT=<dir>   # directory holding run.sh, the vocabulary's SOT
#   SCAN_ROOT=<dir>   # tree to scan for occurrences
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
scan_root="${SCAN_ROOT:-$repo_root}"
DRIVER="$orch_root/run.sh"

if [[ ! -f "$DRIVER" ]]; then
  echo "SKIP: run.sh not found under $orch_root — 판단 부류 어휘 SOT 부재"
  exit 0
fi

# --- SOT extraction --------------------------------------------------------
classes=$(sed -n 's/^readonly JUDGMENT_CLASSES="\(.*\)"$/\1/p' "$DRIVER")
forbidden=$(sed -n 's/^readonly JUDGMENT_CLASSES_FORBIDDEN="\(.*\)"$/\1/p' "$DRIVER")
if [[ -z "$classes" ]]; then
  echo "FAIL: run.sh — readonly JUDGMENT_CLASSES=\"…\" 를 찾지 못했다 (어휘 SOT 부재)" >&2
  exit 1
fi

fail=0

in_vocab() {
  local t
  for t in $classes; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# --- Rule 1: the forbidden set is a subset of the vocabulary ----------------
for t in $forbidden; do
  if ! in_vocab "$t"; then
    echo "FAIL: 금지 부류 '$t' 가 JUDGMENT_CLASSES 에 없다 — 어휘에서 빼면 그 결정이 허용된 토큰을 빌려 쓰게 되고 그것이 누수다" >&2
    fail=1
  fi
done

# --- Rule 2: every literal occurrence names one of the eight ---------------
files=$(find "$scan_root/plugins" "$scan_root/scripts" -type f 2>/dev/null | sort || true)
scanned=0
hits=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$f" ]] || continue
  # The marker is looked for in the first few lines only, so a file that merely
  # mentions it in prose is still scanned.
  if sed -n '1,5p' "$f" | grep -qF 'lint-autoadopt-vocabulary: self-skip'; then
    continue
  fi
  grep -qF '판단 부류=' "$f" 2>/dev/null || continue
  scanned=$((scanned + 1))
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    line="${n#*:}"
    lno="${n%%:*}"
    v=$(printf '%s' "$line" \
        | sed -n 's/.*판단 부류=\([^"'"'"'`|)]*\).*/\1/p' \
        | sed 's/[[:space:]]*$//')
    [[ -n "$v" ]] || continue
    # Metasyntax, not a claim about a value. Recognised by SHAPE rather than by
    # "contains only Hangul, letters, digits and hyphens", because that older
    # test also skipped every value carrying a space — and a space is exactly
    # what a multi-token value carries. The driver's vocabulary check used to
    # accept such a value whenever the tokens it named were adjacent in the
    # vocabulary string, so the one shape this lint most needs to catch was the
    # one shape it silently walked past.
    case "$v" in
      '$'*) continue ;;   # a shell expansion
      '<'*) continue ;;   # a schema placeholder
      */*)  continue ;;   # a parser's own sed pattern
    esac
    printf '%s' "$v" | grep -qE '^[가-힣A-Za-z0-9 -]+$' || continue
    hits=$((hits + 1))
    if ! in_vocab "$v"; then
      echo "FAIL: ${f#"$scan_root"/}:${lno} — 판단 부류 '$v' 가 어휘 밖이다" >&2
      echo "       허용: $classes" >&2
      fail=1
    fi
  done <<EOF
$(grep -nF '판단 부류=' "$f" 2>/dev/null || true)
EOF
done <<EOF
$files
EOF

# --- Rule 3: the five emitted-judgment markers are DEFINED somewhere -------
#
# The gate parses five markers out of a stage's terminal message and absorbs the
# judgment through the auto-adoption floor. The PARSER existed and the PRODUCER
# did not: no stage skill defined these spellings anywhere, so a stage had no way
# to know what to write, and a decision it made and acted on inside its own turn
# reached the ledger only if it guessed the bytes.
#
# The check is EXISTENCE and nothing more. It does not demand that each skill
# reference the definition, because the referencing form differs from skill to
# skill and pinning it mechanically would freeze the prose rather than the
# contract. What it catches is the failure that actually happened — a wiring
# whose producer side is prose in one file and disappears when that file is
# edited.
common_root="$scan_root/plugins/cc-cmds/skills/_common"
if [[ -d "$common_root" ]]; then
  markers_missing=""
  nmark=0
  for m in '**판단 부류**:' '**판단 등급**:' '**판단 기준**:' '**판단 되돌리는 법**:' '**판단 근거**:'; do
    nmark=$((nmark + 1))
    if ! grep -rqF -- "$m" "$common_root" 2>/dev/null; then
      markers_missing="$markers_missing $m"
    fi
  done
  if [[ -n "$markers_missing" ]]; then
    echo "FAIL: 방출 판단 마커가 _common/ 어느 문서에도 정의돼 있지 않다:$markers_missing" >&2
    echo "       게이트는 이 다섯을 스테이지의 종단 메시지에서 파싱한다 — 산출자 쪽 정의가 없으면 스테이지는 무엇을 적어야 하는지 알 방법이 없다" >&2
    fail=1
  fi
else
  echo "SKIP: _common 디렉터리가 없어 방출 마커 정의 검사를 건너뛴다"
  nmark=0
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-autoadopt-vocabulary: violations found" >&2
  exit 1
fi

ncls=0; for t in $classes; do ncls=$((ncls + 1)); done
nfb=0;  for t in $forbidden; do nfb=$((nfb + 1)); done
echo "OK:   judgment-class vocabulary — 토큰 ${ncls}개(금지 ${nfb}개), 파일 ${scanned}건에서 리터럴 ${hits}건 대조, 방출 마커 ${nmark}개 정의 확인"
exit 0
