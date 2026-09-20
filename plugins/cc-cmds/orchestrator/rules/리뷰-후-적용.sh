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

[ -f "$GATE_LEDGER" ] || { echo "리뷰-후-적용: cannot read the ledger" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || {
  echo "리뷰-후-적용: no 세그먼트 was given for the apply act — cannot judge which review covers it" >&2
  exit 1
}

row=$(grep -E '^- `cycle`' "$GATE_LEDGER" | grep -F "세그먼트=$GATE_SEGMENT " | tail -1)
[ -n "$row" ] || {
  echo "리뷰-후-적용: no review record for 세그먼트 '$GATE_SEGMENT'" >&2
  exit 1
}

field() { printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$1=//p" | sed 's/[[:space:]]*$//' | tail -1; }

p0=$(field 'P0'); p1=$(field 'P1'); reviewed=$(field '적용 대상')
[ -n "$p0" ] || p0=0
[ -n "$p1" ] || p1=0

if [ "$p0" != "0" ] || [ "$p1" != "0" ]; then
  echo "리뷰-후-적용: unresolved findings remain (P0=$p0 P1=$p1)" >&2
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
