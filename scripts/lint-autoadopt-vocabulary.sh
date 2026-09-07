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
# digits, hyphens AND SPACES is a value claim. WHICH STRING those shapes are
# matched against follows the same split the rest of this rule makes: a
# terminated capture is a field and is matched whole, an unterminated one is a
# sentence and is matched by the token the vocabulary comparison will actually
# receive. Matching the whole remainder in both cases leaked in both directions
# at once — see `is_metasyntax`.
#
# WHERE THE VALUE ENDS is the other half of that judgment, and leaving it
# unanswered made this rule report prose. A field ends at a terminator: a ledger
# row separates fields with `|`, an argv quotes its value, a comment wraps it in
# backticks, a capture group closes with `)`. A sentence reaches none of them —
# it runs to the end of the line — so a line reading
# `판단 부류=감사-발견 인 경우에는 사람에게 묻지 않는다` was read as one long
# class name and reported as out of vocabulary. A lint that reports a sentence
# as a vocabulary violation gets switched off at its first false positive, and
# the multi-token detection this rule exists for goes off with it.
#
# So a capture that REACHED a terminator is a field and is compared whole. A
# capture that ran to the end of the line is judged by its TOKENS instead,
# because that is what separates the two shapes able to appear there:
#
#   - every token names a class and there is more than one — the multi-token
#     bypass, whose whole trick is that its parts are all real class names
#     sitting next to each other, so it FAILS;
#   - the first token names a class and the rest are ordinary words — prose
#     about a class, and it is skipped;
#   - the first token names no class — an out-of-vocabulary claim written bare,
#     so it FAILS.
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

# Metasyntax, not a claim about a value. Recognised by SHAPE rather than by
# "contains only Hangul, letters, digits and hyphens", because that older test
# also skipped every value carrying a space — and a space is exactly what a
# multi-token value carries. The driver's vocabulary check used to accept such a
# value whenever the tokens it named were adjacent in the vocabulary string, so
# the one shape this lint most needs to catch was the one shape it silently
# walked past.
#
# THE ARGUMENT IS THE STRING BEING JUDGED, and passing the wrong one leaked both
# ways from a single root. This used to be asked about the whole unterminated
# remainder while the vocabulary comparison ran on the first token, so a slash
# anywhere in a sentence matched the parser-pattern shape and skipped the line
# whole — an out-of-vocabulary token at its head was never compared, and slashes
# are common in these documents. In the other direction the sentinel arm wants
# the remainder to BE `-`, so a sentence beginning with the sentinel did not
# match it and the token path then reported `-` as out of vocabulary — the value
# this header calls a shape and not an exception. Callers pass the field when the
# capture reached a terminator and the first token when it did not.
is_metasyntax() {
  case "$1" in
    '$'*) return 0 ;;   # a shell expansion
    '<'*) return 0 ;;   # a schema placeholder
    */*)  return 0 ;;   # a parser's own sed pattern
    '-')  return 0 ;;   # the ledger's "no value" sentinel
  esac
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

# The characters that END a field. A ledger row separates fields with `|`, an
# argv quotes its value, a comment wraps it in backticks, and a parser's capture
# group closes with `)`. A value that reaches none of them ran to the end of the
# line, which is what a sentence does and a field does not.
VALUE_TERMINATORS="\"'\`|)"

files=$(find "$scan_root/plugins" "$scan_root/scripts" -type f 2>/dev/null | sort || true)
scanned=0
hits=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$f" ]] || continue
  # The marker is looked for in the first few lines only, so a file that merely
  # mentions it in prose is still scanned.
  # CAPTURED, NOT `grep -q`. An early-exiting reader on the right of a pipe
  # kills the writer with SIGPIPE, and under `pipefail` the pipeline then reports
  # failure even though the match was found. `grep -c` has the same truth value
  # and reads its input to the end; the count is captured rather than discarded,
  # because BSD grep short-circuits when its output goes to /dev/null.
  selfskip=$(sed -n '1,5p' "$f" | grep -cF 'lint-autoadopt-vocabulary: self-skip' || true)
  if [[ "${selfskip:-0}" != "0" ]]; then
    continue
  fi
  grep -qF '판단 부류=' "$f" 2>/dev/null || continue
  scanned=$((scanned + 1))
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    line="${n#*:}"
    lno="${n%%:*}"
    # THE REMAINDER IS KEPT, not only the capture. Whether the value ended at a
    # terminator or ran off the end of the line is the one signal on the line
    # that tells a field from a sentence, and capturing alone throws it away.
    rest=$(printf '%s' "$line" | sed -n 's/.*판단 부류=//p')
    [[ -n "$rest" ]] || continue
    field=${rest%%[$VALUE_TERMINATORS]*}
    terminated=1
    if [[ "$field" == "$rest" ]]; then
      terminated=0
    fi
    v=$(printf '%s' "$field" | sed 's/[[:space:]]*$//')
    [[ -n "$v" ]] || continue
    # NO CHARACTER-RANGE FILTER HERE. `is_metasyntax` separates metasyntax by
    # SHAPE, and everything it does not name is a claim about a value — including
    # a value spelled with characters this lint did not anticipate, which is
    # out of vocabulary and has to be reported rather than skipped.
    #
    # The filter that used to sit here was `grep -qE '^[<Hangul range>A-Za-z0-9 -]+$'`,
    # and a multibyte character range is not portable: BSD grep matched Korean
    # syllables through it and GNU grep did not, so on the GNU side every Korean
    # value fell through `continue` and the vocabulary was never consulted. The
    # suite caught it only on the Linux leg — the macOS run was green with the
    # same source, which is the shape of a portability bug that survives local
    # verification.
    if [[ "$terminated" = "1" ]]; then
      # The field, whole — that is the string compared against the vocabulary
      # two lines down, so it is the string the shape test has to be asked about.
      if is_metasyntax "$v"; then
        continue
      fi
      hits=$((hits + 1))
      if ! in_vocab "$v"; then
        echo "FAIL: ${f#"$scan_root"/}:${lno} — 판단 부류 '$v' 가 어휘 밖이다" >&2
        echo "       허용: $classes" >&2
        fail=1
      fi
      continue
    fi
    # Unterminated — decided by tokens. `set -f` around the split is required:
    # the words being split are arbitrary document text, and an unquoted
    # expansion would otherwise let a `*` in a sentence expand to filenames.
    ntok=0; nvocab=0; first=""
    set -f
    for t in $v; do
      ntok=$((ntok + 1))
      if [[ -z "$first" ]]; then first="$t"; fi
      if in_vocab "$t"; then nvocab=$((nvocab + 1)); fi
    done
    set +f
    # The first token, because that is the string every branch below compares —
    # `in_vocab "$first"` directly, and the multi-token arm through the count
    # that includes it. A metasyntax token is in no vocabulary, so the bypass arm
    # cannot fire on one and this single test covers both.
    if is_metasyntax "$first"; then
      continue
    fi
    if [[ "$ntok" -gt 1 && "$nvocab" -eq "$ntok" ]]; then
      hits=$((hits + 1))
      echo "FAIL: ${f#"$scan_root"/}:${lno} — 판단 부류 '$v' 가 어휘 밖이다 (부류 이름 ${ntok}개를 이어 붙인 값이다)" >&2
      echo "       허용: $classes" >&2
      fail=1
    elif ! in_vocab "$first"; then
      hits=$((hits + 1))
      echo "FAIL: ${f#"$scan_root"/}:${lno} — 판단 부류 '$first' 가 어휘 밖이다" >&2
      echo "       허용: $classes" >&2
      fail=1
    elif [[ "$ntok" -eq 1 ]]; then
      hits=$((hits + 1))
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
  # `LC_ALL=C` ON THE SORT IS LOAD-BEARING, and the sort is where it matters.
  # `sort -u` drops "duplicates" by COLLATION, and the `en_US.UTF-8` collation
  # has no ordering for Hangul: every marker in this set compares equal to every
  # other, so `-u` keeps one and discards the rest. Measured on one six-marker
  # file — grep emitted 6, `tr` passed 6 through, and `sort -u` returned 1 under
  # `en_US.UTF-8` against 6 under `ko_KR.UTF-8` and under `C`.
  #
  # The failure is silent and symmetric, which is what made it survive: markers
  # collapse on BOTH sides of the comparison, the two sides therefore agree, and
  # the rule reports success over a set it never really read. It reproduced only
  # on a CI runner whose locale is `en_US.UTF-8` while the developer shell ran
  # `ko_KR.UTF-8` — same source, honestly green in one place and hollow in the
  # other.
  #
  # The grep gets the same pin for the same reason: its delimiters are ASCII and
  # what it walks over is arbitrary bytes, so byte semantics are what it wants.
  LC_ALL=C grep -rhoE '\\?\*\\?\*판단 [^*\\]+\\?\*\\?\*' "$@" 2>/dev/null | tr -d '\\' | LC_ALL=C sort -u
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
