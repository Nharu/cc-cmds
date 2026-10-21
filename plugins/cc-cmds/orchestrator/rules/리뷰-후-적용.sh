#!/bin/sh
# 층3 — 리뷰를 거치지 않은 CLAUDE.md 적용을 거부한다.
#
# 발동은 GATE_ACT 가 아니라 층2 가 넘긴 슬롯이다. 사다리에 「적용」 토큰이 없어
# 형제 룰의 관용구를 베끼면 첫 줄에서 항상 통과한다 — 선언 파일이 그 이유를
# 적어 두었다.
[ -n "${GATE_CLAUDEMD_SLOT:-}" ] || exit 0

# 슬롯을 지목하지 못한 적용은 거부한다. 어느 파일이 움직이는지 모르면 원장
# 행도 롤백도 대상이 없다.
if [ "$GATE_CLAUDEMD_SLOT" = "(세탁됨)" ]; then
  echo "리뷰-후-적용: the apply target must be written as an argv element — a path hidden inside an interpreter cannot be named by the ledger" >&2
  exit 1
fi

[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || {
  echo "리뷰-후-적용: no 세그먼트 was given for the apply act — cannot judge which review covers it" >&2
  exit 1
}

# 이 파일은 원장을 훑지 않는다. 세그먼트의 마지막 cycle 행은 게이트가 필드
# 동등으로 골라 넘긴다 — 부분 문자열로 고르면 다른 세그먼트의 행에 든
# `선행 세그먼트=<seg>` 나 이웃 id 의 행을 이 세그먼트의 리뷰로 읽는다.
row="${GATE_SEGMENT_LAST_CYCLE:-}"
[ -n "$row" ] || {
  echo "리뷰-후-적용: no review record for 세그먼트 '$GATE_SEGMENT'" >&2
  exit 1
}

field() { printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$1=//p" | sed 's/[[:space:]]*$//' | tail -1; }

p0=$(field 'P0'); p1=$(field 'P1'); reviewed=$(field '적용 대상')

# 빈 카운트는 0 으로 읽지 않는다 — 카운트를 잃은 행이 깨끗한 리뷰로 읽힌다.
# 이 룰은 이월을 보지 않는다. CLAUDE.md 적용을 덮는 리뷰는 발견이 0 이어야 한다.
if [ "$p0" != "0" ] || [ "$p1" != "0" ]; then
  echo "리뷰-후-적용: unresolved or unreadable findings (P0='$p0' P1='$p1')" >&2
  exit 1
fi

[ -n "$reviewed" ] || {
  echo "리뷰-후-적용: the review record has no 「적용 대상」, so freshness cannot be judged — the review stage must leave the sha256 of the proposal it approved on that row" >&2
  exit 1
}

now="${GATE_CLAUDEMD_DIGEST:-}"
[ -n "$now" ] || {
  echo "리뷰-후-적용: the gate did not pass the digest of the proposal to be applied — undecidable is not an allow" >&2
  exit 1
}

if [ "$reviewed" != "$now" ]; then
  echo "리뷰-후-적용: the proposal the review approved differs from the one about to be applied (reviewed=$reviewed · now=$now)" >&2
  exit 1
fi

# 무인 스테이지가 받는 개인 블록은 사람이 정한다. 제안본과 슬롯의 무인 블록을
# 같은 추출기로 뽑아 바이트로 대조하므로, 태그의 추가·삭제·뒤집기, 무인 불릿
# 본문 편집, 무태그와 태그 모드 사이의 전환이 모두 잡힌다. 무태그 원천은 빈
# 블록이 아니라 레거시 줄을 내므로 전환도 바이트 차이로 드러난다. 대화형 불릿
# 편집과 태그 없는 불릿은 무인 블록을 바꾸지 않아 통과한다.
proposal="${GATE_CLAUDEMD_PROPOSAL:-}"
[ -n "$proposal" ] || {
  echo "리뷰-후-적용: the gate did not name the proposal being applied — put the proposal under \$RUN_DIR/claudemd/ as <name>.proposed.md and pass it as an operand of the apply act" >&2
  exit 1
}
[ -f "$proposal" ] || {
  echo "리뷰-후-적용: the proposal '$proposal' does not exist — put the proposal under \$RUN_DIR/claudemd/ as <name>.proposed.md and pass it as an operand of the apply act" >&2
  exit 1
}

# 게이트는 GATE_DIR 를 넘기지 않으므로 추출기는 이 파일의 자리에서 찾는다.
rules_dir=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
extractor="${rules_dir%/*}/stage-rules.sh"
[ -f "$extractor" ] || {
  echo "리뷰-후-적용: the stage rules extractor '$extractor' is missing — the unattended block of the proposal cannot be compared with the slot's, and undecidable is not an allow" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/review-apply.XXXXXX") || {
  echo "리뷰-후-적용: cannot create a scratch directory to compare the unattended blocks" >&2
  exit 1
}
trap 'rm -rf "$work"' EXIT

# 슬롯 파일이 없으면 추출기가 빈 원천으로 읽는다 — 그 출력이 레거시 줄이다.
if ! bash "$extractor" extract --source "$proposal" > "$work/proposal" 2> "$work/err"; then
  echo "리뷰-후-적용: extracting the unattended block of the proposal failed — $(head -c 200 "$work/err" | head -1)" >&2
  exit 1
fi
if ! bash "$extractor" extract --source "$GATE_CLAUDEMD_SLOT" > "$work/slot" 2> "$work/err"; then
  echo "리뷰-후-적용: extracting the unattended block of the slot failed — $(head -c 200 "$work/err" | head -1)" >&2
  exit 1
fi

if ! cmp -s "$work/proposal" "$work/slot"; then
  echo "리뷰-후-적용: this proposal changes the unattended block of $GATE_CLAUDEMD_SLOT — which rules reach an unattended stage is the person's to decide, so this change waits for a person" >&2
  exit 1
fi

exit 0
