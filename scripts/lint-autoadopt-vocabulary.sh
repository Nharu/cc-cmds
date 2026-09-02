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
#   3  the emitted-judgment markers agree between the gate's parser and
#      `_common/`, in BOTH directions                                   [fail]
#
# Rule 1 is not bookkeeping. The design's whole point about the two forbidden
# values is that they are NAMED and forbidden rather than left out: a class with
# no token has to borrow a permitted one when the decision is recorded, and that
# borrowing is the leak. With a token, the leak arrives as a refusal. Dropping
# either from the vocabulary would restore the leak silently, and rule 1 is what
# makes that a failing build.
#
# What counts as a literal: the four metasyntactic shapes the tree actually
# contains are recognised by shape and skipped — a shell expansion
# (`판단 부류=$cls`), a schema placeholder (`판단 부류=<여덟 값 중 하나>`), a
# parser's own pattern (`s/^ *판단 부류=//p`) and the ledger's "no value"
# sentinel (`판단 부류=-`) — and everything else made of Hangul, ASCII letters,
# digits, hyphens AND SPACES is a value claim.
#
# The sentinel is a shape and not an exception. Every field of a ledger row that
# has no value carries `-`, so a row written for a judgment whose class never
# arrived spells it that way too; reading that as a claim about a class made the
# lint demand that `-` be one of the eight.
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
#   ORCH_ROOT=<dir>   # directory holding run.sh (the vocabulary's SOT) and
#                     # gate.sh (the emitted-judgment parser rule 3 reads)
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
      '-')  continue ;;   # the ledger's "no value" sentinel
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

# --- Rule 3: the emitted-judgment markers agree on BOTH sides --------------
#
# The gate parses judgment markers out of a stage's terminal message and absorbs
# the judgment through the auto-adoption floor. The PARSER existed and the
# PRODUCER did not: no stage skill defined these spellings anywhere, so a stage
# had no way to know what to write, and a decision it made and acted on inside
# its own turn reached the ledger only if it guessed the bytes.
#
# BOTH SIDES ARE EXTRACTED and neither is written down here. A hardcoded list can
# only ever check the side it was copied from: renaming the parser's `판단 부류`
# to `판단 유형` left this lint green, because the literals it carried still
# existed under `_common/` and nothing ever compared them against the parser. The
# suite's own real-tree check reads the same one side, so two greens covered one
# surface.
#
# The comparison runs in BOTH directions because the two failures are repaired in
# different places. A marker only the parser knows is a producer that does not
# exist — a stage cannot write what no document defines. A marker only the
# documents know is a dead convention — prose telling stages to emit bytes the
# gate will never read. Naming which side a marker is missing from is therefore
# part of the failure, not decoration on it.
#
# One extraction serves both sides. The parser writes its markers inside a `sed`
# regex, so every asterisk carries a backslash, while the documents write plain
# markdown; stripping backslashes makes the two spellings one.
GATE_SH="$orch_root/gate.sh"
common_root="$scan_root/plugins/cc-cmds/skills/_common"
marker_scan() {
  grep -rhoE '\\?\*\\?\*판단 [^*\\]+\\?\*\\?\*' "$@" 2>/dev/null | tr -d '\\' | sort -u
}
nmark=0
if [[ ! -f "$GATE_SH" ]]; then
  # The same posture the top of this file takes for run.sh: an absent SOT is a
  # silent skip, not a violation.
  echo "SKIP: gate.sh not found under $orch_root — 방출 판단 파서 부재"
elif [[ ! -d "$common_root" ]]; then
  echo "SKIP: _common 디렉터리가 없어 방출 마커 대조를 건너뛴다"
else
  parser_side=$(marker_scan "$GATE_SH")
  doc_side=$(marker_scan "$common_root")
  if [[ -z "$parser_side" ]]; then
    echo "FAIL: gate.sh 에서 방출 판단 마커를 하나도 뽑지 못했다 — 파서가 사라졌거나 스펠링이 이 대조가 아는 꼴이 아니다" >&2
    fail=1
  fi
  # The value is CAPTURED rather than piped into `grep -q`: an early-exiting
  # reader on the right of a pipe kills the writer with SIGPIPE, and under
  # `pipefail` the whole pipeline then reports failure even though the match was
  # found.
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    nmark=$((nmark + 1))
    hit=$(printf '%s\n' "$doc_side" | grep -xF -- "$m" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: 방출 판단 마커 '$m' 가 파서에만 있다 — _common/ 어느 문서도 정의하지 않으므로 스테이지는 무엇을 적어야 하는지 알 방법이 없다" >&2
      fail=1
    fi
  done <<EOF
$parser_side
EOF
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    hit=$(printf '%s\n' "$parser_side" | grep -xF -- "$m" || true)
    if [[ -z "$hit" ]]; then
      echo "FAIL: 방출 판단 마커 '$m' 가 문서에만 있다 — 게이트 파서가 읽지 않으므로 스테이지가 그대로 적어도 흡수되는 것이 없다" >&2
      fail=1
    fi
  done <<EOF
$doc_side
EOF
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-autoadopt-vocabulary: violations found" >&2
  exit 1
fi

ncls=0; for t in $classes; do ncls=$((ncls + 1)); done
nfb=0;  for t in $forbidden; do nfb=$((nfb + 1)); done
echo "OK:   judgment-class vocabulary — 토큰 ${ncls}개(금지 ${nfb}개), 파일 ${scanned}건에서 리터럴 ${hits}건 대조, 방출 마커 ${nmark}개 양방향 대조"
exit 0
