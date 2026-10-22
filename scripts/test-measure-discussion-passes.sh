#!/usr/bin/env bash
# Test scripts/measure-discussion-passes.sh against synthetic corpora built in a
# temporary directory.
#
# The corpora are SYNTHETIC on purpose: the real ones live under the state home
# and in the untracked `docs/design-audit/`, so a test pointed at them would
# pass or fail by what this machine happens to hold. Every root the script
# reads is passed explicitly, except in the one case that checks how the
# default audit directory is found from a linked worktree.
#
# Usage: bash scripts/test-measure-discussion-passes.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
MEASURE="$script_dir/measure-discussion-passes.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-discussion-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

RR="$WORK/run"; SR="$WORK/seat"; AD="$WORK/audit"
mkdir -p "$RR" "$SR" "$AD"

# w <path> <line>... — a witness file with the given body lines and a sentinel.
w() { local f="$1"; shift; mkdir -p "$(dirname "$f")"; { printf '%s\n' "$@"; printf '<!-- witness-complete -->\n'; } > "$f"; }

# --- doc-a: open with a measurement named, revisions chosen, mixed readings --------
A="$RR/20261001-aaaaaaa1/design/doc-a/witness"
w "$A/alpha.round-1.md" "제안"
w "$A/beta.round-1.md" "제안"
# The last declaration wins across both forms, so alpha declares none.
w "$A/alpha.round-2.md" "round-3: measure — 지난 측정" "round-3: none"
w "$A/beta.round-2.md" "round-3: none"
w "$A/beta.round-2-rev1.md" "round-3: measure — 지연을 잰다"
w "$A/alpha.round-3.md" "최종"
w "$A/beta.round-3.md" "최종"
touch -t 202610010900.00 "$A"/*.round-2*.md
touch -t 202610010902.05 "$A/alpha.round-3.md"
touch -t 202610010901.00 "$A/beta.round-3.md"
w "$A/alpha.fidelity.md" "- type: decision-reopen" "findings: 3"
w "$A/beta.fidelity.md" "findings: 2"
w "$A/beta.fidelity-rev1.md" "- type: decision-reopen" "  - type: decision-reopen" "findings: 4"
w "$A/alpha.coherence.md" "findings: 5"
w "$A/beta.coherence.md" "- type: anchor" "- type: gap"
printf 'round-3: sweep — 첫 주장\nround-3: sweep — 둘째 주장\n다른 줄\n' > "$A/SWEEP.md"
printf '| lead | sweep |\n' > "$A/INDEX.md"
{ printf '<!-- cc-design-audit-disclosure v1 begin -->\n**고유 결함 수**: 7\n**동결 문서 바이트**: 20000\n<!-- /cc-design-audit-disclosure v1 end -->\n'; } > "$AD/doc-a.md"

# --- doc-b: open, an undeclared R2 witness, no later passes, no SWEEP.md -----------
B="$RR/20261001-aaaaaaa2/design/doc-b/witness"
w "$B/alpha.round-1.md" "제안"
w "$B/alpha.round-2.md" "입장"
w "$B/alpha.round-3.md" "최종"

# --- doc-c: no round-1 witness (the solo branch) ----------------------------------
mkdir -p "$RR/20261001-aaaaaaa3/design/doc-c/witness"
printf 'x\n' > "$RR/20261001-aaaaaaa3/design/doc-c/witness/INDEX.md"

# --- doc-d: closed with a measurement named; the older readings --------------------
D="$RR/20261001-aaaaaaa4/design/doc-d/witness"
w "$D/alpha.round-1.md" "제안"
w "$D/alpha.round-2.md" "round-3: measure — 처리량을 잰다"
w "$D/alpha.fidelity.md" "Fidelity confirmed — 그대로다"
w "$D/alpha.coherence.md" "자유 모양의 발견"
: > "$D/SWEEP.md"

# --- doc-e: two corpora — closed all none, and open all none ----------------------
E="$RR/20261001-aaaaaaa5/design/doc-e/witness"
w "$E/alpha.round-1.md" "제안"
w "$E/alpha.round-2.md" "round-3: none"
E2="$RR/20261001-aaaaaaa6/design/doc-e/witness"
w "$E2/alpha.round-1.md" "제안"
w "$E2/alpha.round-2.md" "round-3: none"
w "$E2/alpha.round-3.md" "최종"

# --- doc-f (seat): files outside the grammar, and a subdirectory corpus ------------
F="$SR/doc-f/witness"
w "$F/alpha.round-1.md" "제안"
w "$F/alpha.round-2.md" "round-3: none"
w "$F/alpha.coherence.md" "findings: 1"
w "$F/alpha.coherence.epoch-6.md" "findings: 9"
w "$F/alpha.coherence.prompt.md" "지시"
printf 'x\n' > "$F/notes.txt"
printf 'x\n' > "$F/INDEX.md"
FS="$F/redesign-20261010"
w "$FS/gamma.round-1.md" "제안"
w "$FS/delta.round-1.md" "제안"
w "$FS/gamma.round-2.md" "round-3: none"
w "$FS/delta.round-2.md" "round-3: none"

OUT=""; rc=0
run() { OUT=$(bash "$MEASURE" "$@" 2>"$WORK/err"); rc=$?; }
# field <witness dir> <column name> — that column of the corpus's row.
field() {
  printf '%s\n' "$OUT" | awk -F'\t' -v d="$1" -v c="$2" '
    NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $2 == d { print $(col[c]); exit }'
}
rows() { printf '%s\n' "$OUT" | awk 'NR > 1 && NF' | wc -l | tr -d ' '; }

# --- 0. arguments -----------------------------------------------------------------
run --모름
check "0: 모르는 인자는 exit 2 다" "$rc" "2"
run --run-root
check "0: 값 없는 --run-root 는 exit 2 다" "$rc" "2"
run --run-root "$WORK/없음" --seat-root "$WORK/없음" --audit-dir "$AD"
check "0: 말뭉치가 없으면 exit 0 이다" "$rc" "0"
check "0: 말뭉치가 없어도 머리 줄은 낸다" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-3)" "$(printf '출처\t말뭉치\t슬러그')"
check "0: 말뭉치가 없으면 행이 없다" "$(rows)" "0"

# --- 1. the fixture set -------------------------------------------------------------
run --run-root "$RR" --seat-root "$SR" --audit-dir "$AD"
check "1: exit 0 이다" "$rc" "0"
check "1: round-1 증인이 없는 말뭉치는 행이 없고, 하위 디렉터리는 따로 센다" "$(rows)" "7"

check "1: 출처 열이 런 루트를 밝힌다" "$(field "$A" 출처)" "run"
check "1: 팀원은 round-1 증인 수다" "$(field "$A" 팀원)" "2"
check "1: R3 증인이 있으면 열림이다" "$(field "$A" R3)" "열림"
check "1: 개정판이 원본을 대신하고 선언은 두 형식을 가로질러 마지막 줄이다" "$(field "$A" '측정 지명')" "1"
check "1: 열림에 측정 지명이 있으면 측정 지명이다" "$(field "$A" 'R3 사유')" "측정 지명"
check "1: R3 분은 마지막 R2 와 마지막 R3 의 수정 시각 차를 분으로 내린다" "$(field "$A" 'R3 분')" "2"
check "1: 스윕 반박은 접두로 시작하는 줄 수다" "$(field "$A" '스윕 반박')" "2"
check "1: 충실도 좌석은 고른 증인 수다" "$(field "$A" '충실도 좌석')" "2"
check "1: 충실도 발견은 고른 증인의 findings 합이다(원본과 개정판을 함께 세지 않는다)" "$(field "$A" '충실도 발견')" "7"
check "1: 모든 좌석이 줄을 가지면 판독은 줄이다" "$(field "$A" '충실도 판독')" "줄"
check "1: 충실도 재개는 고른 증인의 decision-reopen 줄 수다" "$(field "$A" '충실도 재개')" "3"
check "1: 줄이 없는 좌석은 type 줄로 센다" "$(field "$A" '정합 발견')" "7"
check "1: 두 판독이 섞이면 섞임이다" "$(field "$A" '정합 판독')" "섞임"
check "1: SWEEP.md 와 INDEX.md 는 문법 밖 수에 들지 않는다" "$(field "$A" '문법 밖')" "0"
check "1: 감사 보고서와 슬러그로 잇는다(고유)" "$(field "$A" '감사 고유')" "7"
check "1: 감사 보고서와 슬러그로 잇는다(바이트)" "$(field "$A" '감사 바이트')" "20000"

check "1: 선언 없는 R2 증인만 있으면 측정 지명은 미상이다" "$(field "$B" '측정 지명')" "미상"
check "1: 열림에 선언 없는 증인이 있으면 미상이다" "$(field "$B" 'R3 사유')" "미상"
check "1: SWEEP.md 가 없으면 스윕 반박은 미상이다" "$(field "$B" '스윕 반박')" "미상"
check "1: 좌석이 0 이면 발견은 0 이 아니라 미상이다" "$(field "$B" '충실도 발견')" "미상"
check "1: 좌석이 0 이면 판독은 - 다" "$(field "$B" '충실도 판독')" "-"
check "1: 좌석이 0 이면 재개는 미상이다" "$(field "$B" '충실도 재개')" "미상"
check "1: 감사 보고서가 없으면 미상이다" "$(field "$B" '감사 고유')" "미상"

check "1: 닫힘에 측정 지명이 있으면 지명 미개방이다" "$(field "$D" 'R3 사유')" "지명 미개방"
check "1: 닫히면 R3 분은 미상이다" "$(field "$D" 'R3 분')" "미상"
check "1: 빈 SWEEP.md 는 0 이다" "$(field "$D" '스윕 반박')" "0"
check "1: Fidelity confirmed 만 있는 옛 증인은 0 이다" "$(field "$D" '충실도 발견')" "0"
check "1: 옛 판독은 옛이다" "$(field "$D" '충실도 판독')" "옛"
check "1: 어느 판독으로도 세지 못한 좌석이 있으면 미상이다" "$(field "$D" '정합 발견')" "미상"
check "1: 세지 못한 좌석도 옛 판독으로 읽힌 것이다" "$(field "$D" '정합 판독')" "옛"

check "1: 닫힘에 모두 none 이면 해당 없음이다" "$(field "$E" 'R3 사유')" "해당 없음"
check "1: 열림에 모두 none 이면 선언 없음이다" "$(field "$E2" 'R3 사유')" "선언 없음"

check "1: 출처 열이 좌석 루트를 밝힌다" "$(field "$F" 출처)" "seat"
check "1: 문법 밖 파일을 센다" "$(field "$F" '문법 밖')" "3"
check "1: 문법 밖 파일은 증인으로 세지 않는다" "$(field "$F" '정합 발견')" "1"
check "1: 하위 디렉터리는 별도 말뭉치다" "$(field "$FS" 팀원)" "2"
check "1: 하위 디렉터리 말뭉치도 문서 슬러그로 잇는다" "$(field "$FS" 슬러그)" "doc-f"
check "1: 하위 디렉터리는 상위 말뭉치의 문법 밖 수에 들지 않는다" "$(field "$FS" '문법 밖')" "0"

# --- 2. the default audit directory is the main worktree's ---------------------------
M="$WORK/main"; L="$WORK/linked"
mkdir -p "$M/docs/design-audit"
cp "$AD/doc-a.md" "$M/docs/design-audit/doc-a.md"
( cd "$M" && git init -q && git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init \
  && git worktree add -q "$L" >/dev/null 2>&1 )
OUT=$(cd "$L" && bash "$MEASURE" --run-root "$RR" --seat-root "$WORK/없음" 2>/dev/null); rc=$?
check "2: 링크드 워크트리에서도 exit 0 이다" "$rc" "0"
check "2: 기본 감사 디렉터리는 주 워크트리의 것이라 링크드 워크트리에서도 잇는다" "$(field "$A" '감사 고유')" "7"

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
