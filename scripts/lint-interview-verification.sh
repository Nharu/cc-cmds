#!/usr/bin/env bash
#
# lint-interview-verification.sh — the kickoff's consented tests and its
# verification-convention read trace stay wired from the contract to the check.
#
# 스킬 문면을 비교하며 기록을 보지 않는다. The interview record's
# `## 검증 선결` opens with a `**검증 규약**` line carrying the hash of the
# verification convention the kickoff read, items whose consented test ran
# carry `시험:`·`동의:`·`관측:`, and the kickoff freezes the record only after
# `orchestrator/interview-check.sh` passes it. That chain is text across five
# files; a step dropped from one of them leaves the others standing and nothing
# fails, while the convention read goes unchecked again.
#
# The truth is EXTRACTED from the contract, never restated: the convention path
# is the one the `**검증 규약**` line of the `### 2b.5` fence names.
#
# Assertions (each FAIL line names its number as `[단언 N]`):
#    1. The `## 검증 선결` block of the `### 2b.5` fence carries a
#       `**검증 규약**:` line, the `시험:`, `동의:` and `관측:` keys, and the
#       `반증됨 — ` verdict.
#    2. The convention file that line names exists under the skills root, and
#       the checker script carries both the `**검증 규약**` key and that path.
#    3. The 5m zone of `autopilot/references/boundaries.md` calls
#       `interview-check.sh`.
#    4. The closed stage vocabulary of `### 2b.6` and autopilot's Act 1
#       boundary token list both carry `규약 읽기`, and the 5j zone names
#       `단계=규약 읽기` and `## 검증 선결`.
#    5. The Verification-first item of the shared interview convention carries
#       both the convention's read phrase and the consented-test phrase.
#
# A zone runs from the line that opens it to the next line matching
# `^\*\*5[a-z]( |\(|—)` or `^#{1,4} ` outside a code fence.
#
# Usage: bash scripts/lint-interview-verification.sh
#
# Env override:
#   SKILLS_ROOT  skills directory (default plugins/cc-cmds/skills)
#   ORCH_ROOT    orchestrator directory (default $SKILLS_ROOT/../orchestrator)
#
# Exit codes:
#   0  every assertion holds
#   1  at least one assertion is broken
#
# Compatibility: bash 3.2 (macOS) — no associative arrays, no mapfile.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
skills_root="${SKILLS_ROOT:-$repo_root/plugins/cc-cmds/skills}"
orch_root="${ORCH_ROOT:-$skills_root/../orchestrator}"

PS="$skills_root/_common/pipeline-sidecar.md"
RI="$skills_root/_common/requirements-interview.md"
AP="$skills_root/autopilot/SKILL.md"
APB="$skills_root/autopilot/references/boundaries.md"
CHECKER="$orch_root/interview-check.sh"

KEY='**검증 규약**'
READ_PHRASE='${CLAUDE_SKILL_DIR}/../_common/verification.md'
CONSENT_PHRASE='**Consented test — settle now what only an outside service can answer.**'
TRACE_TOKEN='`규약 읽기`'

# zone <file> <opening prefix> — the lines of the zone the prefix opens.
zone() {
  awk -v p="$2" '
    started == 0 { if (index($0, p) == 1) { started = 1; print } ; next }
    /^```/ { fence = !fence; print; next }
    fence == 0 && ($0 ~ /^\*\*5[a-z]( |\(|—)/ || $0 ~ /^(#|##|###|####) /) { exit }
    { print }
  ' "$1"
}

# The stdin filters below read to the end instead of exiting at their last
# line: under pipefail a reader that exits early can SIGPIPE the writer.

# fence_of — the lines inside the first four-backtick fence of stdin.
fence_of() {
  awk '/^````/ { n++; next } n == 1 { print }'
}

# block <heading> — the lines under a `## ` heading of stdin up to the next one.
block() {
  awk -v h="$1" '$0 == h { f = 1; next } /^## / { f = 0 } f { print }'
}

# para <prefix> — the paragraph of stdin that begins with the prefix, up to the
# first blank line.
para() {
  awk -v p="$1" 'f && /^[ \t]*$/ { f = 0; done = 1 } !done && !f && index($0, p) == 1 { f = 1 } f { print }'
}

# item <prefix> — the top-level bullet of stdin that begins with the prefix,
# with its nested lines, up to the next top-level bullet or heading.
item() {
  awk -v p="$1" 'f && (/^- / || /^#/) { f = 0; done = 1 } !done && !f && index($0, p) == 1 { f = 1 } f { print }'
}

# has <needle> <text> — a fixed string in a text.
has() { grep -qF -- "$1" <<< "$2"; }

fail=0
flag() {
  # flag <n> <file> <message>
  echo "FAIL: [단언 $1] $2 — $3" >&2
  fail=1
}

# --- 1. The contract's verification block ------------------------------------
vblock=""
if [[ ! -f "$PS" ]]; then
  flag 1 "$PS" "없다 ; 인터뷰 기록 계약을 읽을 수 없다"
else
  vblock=$(zone "$PS" '### 2b.5 ' | fence_of | block '## 검증 선결')
  if [[ -z "$vblock" ]]; then
    flag 1 "$PS" "### 2b.5 울타리에 ## 검증 선결 블록이 없다"
  else
    has "$KEY: " "$vblock" || flag 1 "$PS" "## 검증 선결 블록에 $KEY: 줄이 없다"
    for k in '시험:' '동의:' '관측:'; do
      grep -q "^  $k" <<< "$vblock" || flag 1 "$PS" "## 검증 선결 블록에 $k 키가 없다"
    done
    has '반증됨 — ' "$vblock" || flag 1 "$PS" "## 검증 선결 블록에 반증됨 — 판정이 없다"
  fi
fi

# --- 2. The named convention exists and the checker reads it -----------------
conv_rel=$(printf '%s\n' "$vblock" | sed -n 's/^\*\*검증 규약\*\*: \([^ ]*\) sha256=.*/\1/p' | sed -n 1p)
if [[ -z "$conv_rel" ]]; then
  flag 2 "$PS" "$KEY 줄에서 규약 파일 경로를 뽑지 못했다"
else
  [[ -f "$skills_root/$conv_rel" ]] \
    || flag 2 "$skills_root/$conv_rel" "$KEY 줄이 이름 붙인 규약 파일이 스킬 루트에 없다"
  if [[ ! -f "$CHECKER" ]]; then
    flag 2 "$CHECKER" "검사기가 없다"
  else
    grep -qF -- "$KEY" "$CHECKER" || flag 2 "$CHECKER" "검사기가 $KEY 키를 담지 않는다"
    grep -qF -- "$conv_rel" "$CHECKER" || flag 2 "$CHECKER" "검사기가 $conv_rel 경로를 담지 않는다"
  fi
fi

# --- 3. 5m freezes through the checker ---------------------------------------
if [[ ! -f "$APB" ]]; then
  flag 3 "$APB" "없다"
else
  z5m=$(zone "$APB" '**5m — ')
  if [[ -z "$z5m" ]]; then
    flag 3 "$APB" "**5m — 구역이 없다"
  else
    has 'interview-check.sh' "$z5m" || flag 3 "$APB" "**5m — 구역이 interview-check.sh 를 부르지 않는다"
  fi
fi

# --- 4. The trace token is in the vocabulary, the boundary list and 5j --------
if [[ -f "$PS" ]]; then
  vocab=$(zone "$PS" '### 2b.6 ' | para '**The stage vocabulary is closed**')
  if [[ -z "$vocab" ]]; then
    flag 4 "$PS" "### 2b.6 에 닫힌 단계 어휘 문단이 없다"
  else
    has "$TRACE_TOKEN" "$vocab" || flag 4 "$PS" "### 2b.6 의 닫힌 단계 어휘에 $TRACE_TOKEN 이 없다"
  fi
fi
if [[ ! -f "$AP" ]]; then
  flag 4 "$AP" "없다"
else
  bound=$(para '**At every Act 1 boundary the order is' < "$AP")
  if [[ -z "$bound" ]]; then
    flag 4 "$AP" "Act 1 경계 토큰 열거 문단이 없다"
  else
    has "$TRACE_TOKEN" "$bound" || flag 4 "$AP" "Act 1 경계 토큰 열거에 $TRACE_TOKEN 이 없다"
  fi
  z5j=$(zone "$AP" '**5j — ')
  if [[ -z "$z5j" ]]; then
    flag 4 "$AP" "**5j — 구역이 없다"
  else
    has '단계=규약 읽기' "$z5j" || flag 4 "$AP" "**5j — 구역에 단계=규약 읽기 가 없다"
    has '## 검증 선결' "$z5j" || flag 4 "$AP" "**5j — 구역에 ## 검증 선결 이 없다"
  fi
fi

# --- 5. The shared convention carries the consented test ---------------------
if [[ ! -f "$RI" ]]; then
  flag 5 "$RI" "없다"
else
  vf=$(item '- **Verification-first' < "$RI")
  if [[ -z "$vf" ]]; then
    flag 5 "$RI" "Verification-first 항목이 없다"
  else
    has "$READ_PHRASE" "$vf" || flag 5 "$RI" "Verification-first 항목에 검증 규약 읽기 문구가 없다"
    has "$CONSENT_PHRASE" "$vf" || flag 5 "$RI" "Verification-first 항목에 동의받은 시험 고정 문구가 없다"
  fi
fi

if [[ "$fail" != "0" ]]; then
  echo "lint-interview-verification: violations found" >&2
  exit 1
fi
echo "OK:   interview verification — 검증 선결 계약·검사기·5j·5m·공유 규약이 이어져 있다"
exit 0
