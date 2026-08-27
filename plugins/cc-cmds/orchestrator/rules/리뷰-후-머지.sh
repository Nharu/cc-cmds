#!/bin/sh
# 이 브랜치의 현재 HEAD 를 덮는 리뷰 기록이 있고 P0·P1 이 0인가.
#
# 머지 등급의 행위에만 발동한다. 그 아래 등급은 리뷰 의무를 만들지 않는다.
[ "$GATE_ACT" = "머지" ] || exit 0

[ -f "$GATE_LEDGER" ] || { echo "리뷰-후-머지: 원장을 읽을 수 없습니다" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || {
  echo "리뷰-후-머지: 머지 행위에 세그먼트가 지정되지 않았습니다" >&2
  exit 1
}

row=$(grep -E '^- `cycle`' "$GATE_LEDGER" | grep -F "세그먼트=$GATE_SEGMENT " | tail -1)
[ -n "$row" ] || {
  echo "리뷰-후-머지: 세그먼트 '$GATE_SEGMENT' 의 리뷰 기록이 없습니다" >&2
  exit 1
}

field() { printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$1=//p" | sed 's/[[:space:]]*$//' | tail -1; }

p0=$(field 'P0'); p1=$(field 'P1'); reviewed=$(field '리뷰 HEAD')
[ -n "$p0" ] || p0=0
[ -n "$p1" ] || p1=0

if [ "$p0" != "0" ] || [ "$p1" != "0" ]; then
  echo "리뷰-후-머지: 미해결 지적이 남아 있습니다 (P0=$p0 P1=$p1)" >&2
  exit 1
fi

[ -n "$reviewed" ] || {
  echo "리뷰-후-머지: 리뷰 기록에 HEAD 가 없어 신선도를 판정할 수 없습니다" >&2
  exit 1
}

seg_row=$(grep -E '^- `segment`' "$GATE_LEDGER" | grep -F "id=$GATE_SEGMENT " | tail -1)
wt=$(printf '%s' "$seg_row" | tr '|' '\n' | sed -n 's/^ *워크트리=//p' | sed 's/[[:space:]]*$//' | tail -1)
[ -d "$wt" ] || { echo "리뷰-후-머지: 세그먼트 워크트리가 없습니다: $wt" >&2; exit 1; }

now=$(cd "$wt" && git rev-parse HEAD 2>/dev/null)
[ -n "$now" ] || { echo "리뷰-후-머지: 현재 HEAD 를 읽을 수 없습니다" >&2; exit 1; }

# 등급 1 — 무이동
[ "$now" = "$reviewed" ] && exit 0

# 등급 2 — 동일 트리. 커밋은 다르나 트리가 같다.
t_now=$(cd "$wt" && git rev-parse "$now^{tree}" 2>/dev/null)
t_rev=$(cd "$wt" && git rev-parse "$reviewed^{tree}" 2>/dev/null)
if [ -n "$t_now" ] && [ "$t_now" = "$t_rev" ]; then
  exit 0
fi

# 등급 3~5 — 전부 거부이며, 어느 것인지만 다르게 보고한다.
if (cd "$wt" && git merge-base --is-ancestor "$reviewed" "$now" 2>/dev/null); then
  echo "리뷰-후-머지: 리뷰 이후 커밋이 추가됐습니다 (리뷰 ${reviewed} → 현재 ${now})" >&2
else
  echo "리뷰-후-머지: 리뷰 HEAD 가 현재 HEAD 의 조상이 아닙니다 (리뷰 ${reviewed}, 현재 ${now})" >&2
fi
exit 1
