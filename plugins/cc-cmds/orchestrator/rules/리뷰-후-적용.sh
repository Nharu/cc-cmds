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

exit 0
