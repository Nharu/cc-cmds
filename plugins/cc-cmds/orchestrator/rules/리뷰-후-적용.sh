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
  echo "리뷰-후-적용: 적용 대상을 argv 원소로 적어야 합니다 — 인터프리터 안에 숨은 경로는 원장이 지목할 수 없습니다" >&2
  exit 1
fi

[ -f "$GATE_LEDGER" ] || { echo "리뷰-후-적용: 원장을 읽을 수 없습니다" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || {
  echo "리뷰-후-적용: 적용 행위에 세그먼트가 지정되지 않았습니다 — 어느 리뷰가 덮는지 판정할 수 없습니다" >&2
  exit 1
}

row=$(grep -E '^- `cycle`' "$GATE_LEDGER" | grep -F "세그먼트=$GATE_SEGMENT " | tail -1)
[ -n "$row" ] || {
  echo "리뷰-후-적용: 세그먼트 '$GATE_SEGMENT' 의 리뷰 기록이 없습니다" >&2
  exit 1
}

field() { printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$1=//p" | sed 's/[[:space:]]*$//' | tail -1; }

p0=$(field 'P0'); p1=$(field 'P1'); reviewed=$(field '적용 대상')
[ -n "$p0" ] || p0=0
[ -n "$p1" ] || p1=0

if [ "$p0" != "0" ] || [ "$p1" != "0" ]; then
  echo "리뷰-후-적용: 미해결 지적이 남아 있습니다 (P0=$p0 P1=$p1)" >&2
  exit 1
fi

[ -n "$reviewed" ] || {
  echo "리뷰-후-적용: 리뷰 기록에 「적용 대상」이 없어 신선도를 판정할 수 없습니다 — 리뷰 스테이지가 승인한 제안본의 sha256 을 그 행에 남겨야 합니다" >&2
  exit 1
}

now="${GATE_CLAUDEMD_DIGEST:-}"
[ -n "$now" ] || {
  echo "리뷰-후-적용: 적용될 제안본의 다이제스트를 게이트가 넘기지 않았습니다 — 판정 불가는 허용이 아닙니다" >&2
  exit 1
}

if [ "$reviewed" != "$now" ]; then
  echo "리뷰-후-적용: 리뷰가 승인한 제안본과 지금 적용될 제안본이 다릅니다 (리뷰=$reviewed · 현재=$now)" >&2
  exit 1
fi

exit 0
