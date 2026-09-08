#!/bin/sh
# 이 세그먼트의 머지가 그 세그먼트의 리뷰 정책이 요구하는 것을 만족하는가.
#
# 정책은 게이트가 해소해 정수로 넘긴다. 정책 이름의 리터럴을 이 파일에 두지
# 않는 이유는, 같은 어휘가 두 곳에 살면 게이트가 해소한 집합과 검사기가 아는
# 집합이 갈라질 수 있고 그 차이가 거절이 아니라 통과로 나타나기 때문이다.
#
# 지수는 선언 순서를 그대로 따르며 커질수록 느슨하다 — 0 리뷰 먼저,
# 1 머지 먼저, 2 리뷰 없음.
#
# 거절 문면은 전부 룰 이름을 싣는다. 이 파일의 거절과 다른 룰의 거절이 같은
# 종료 코드로 돌아오므로, 이름이 없으면 어느 룰이 세웠는지 단언할 수 없다.

# 발동 칸은 「머지」 한 칸이 아니라 머지 이상이다. 머지를 그보다 위 칸으로
# 신고하면 이 검사를 통째로 지나가던 경로가 있었다.
# 절단점 지수가 없으면 게이트가 이 행위를 머지 사다리에 올리지 않은 것이다.
# 그때는 판정할 것이 없으므로 통과한다. 이 자리를 거절로 두면 머지가 아닌
# 평범한 행위가 이 룰에 걸린다 — 실측으로 읽기·워크트리 쓰기·판단 채택이
# 전부 rc 3 으로 막혔다. 「판정 불가는 통과가 아니다」는 아래 정책 지수에
# 걸리는 말이고 이 지수에는 걸리지 않는다. 저신고된 머지를 잡는 것은 이
# 부재가 아니라 아래의 지수 비교다.
[ -n "$GATE_ACT_INDEX" ] && [ -n "$GATE_MERGE_INDEX" ] || exit 0
[ "$GATE_ACT_INDEX" -ge "$GATE_MERGE_INDEX" ] || exit 0

# 세상을 바꾸지 않는 행위는 통과한다. 발동 칸을 머지 이상으로 넓히면서 이
# 자리가 필요해졌다 — 배포로 신고된 평범한 행위(디렉터리 생성·파일 읽기)가
# 사다리 위칸에 있다는 이유만으로 이 룰에 들어오기 때문이다.
#
# 좁히는 축은 세그먼트가 아니라 등급된 표면이다. 세그먼트 부재로 좁히면
# 머지 argv 에서 --segment 하나를 빼는 것만으로 이 검사 전체를 건너뛸 수
# 있고, 그 구멍은 가장 엄격한 정책에서도 열린다 — 앵커 검사는 선머지후리뷰
# 에서만 발동하므로 그것을 대신 세워 주지 않는다. 머지는 언제나
# 외부상태변경이므로 이 대조는 머지를 하나도 놓치지 않는다.
case "$GATE_SURFACE" in
  읽기|워크트리쓰기) exit 0 ;;
esac

[ -n "$GATE_REVIEW_POLICY_INDEX" ] || {
  echo "룰 거부: 리뷰-후-머지 — 리뷰 정책을 받지 못해 판정할 수 없습니다" >&2
  exit 1
}

# 리뷰 없음 — 원장을 읽기 전에 통과한다. 원장 가독성 검사를 앞에 두면 정책이
# 면제한 세그먼트가 정책과 무관한 이유로 멈춘다.
[ "$GATE_REVIEW_POLICY_INDEX" = "2" ] && exit 0

# 머지 먼저 — 이 세그먼트에 미이행 리뷰 의무가 남아 있는가만 본다. 열린 의무
# 집합은 게이트가 접어서 넘긴다. 이 파일이 원장을 다시 세면 「무엇이 열려
# 있는가」의 사본이 게이트·종료 조건과 함께 셋이 되고, 셋은 갈라진다.
if [ "$GATE_REVIEW_POLICY_INDEX" = "1" ]; then
  [ -z "$GATE_SEGMENT_OPEN_OBLIGATIONS" ] && exit 0
  echo "룰 거부: 리뷰-후-머지 — 이 세그먼트에 미이행 리뷰 의무가 있습니다 ($GATE_SEGMENT_OPEN_OBLIGATIONS)" >&2
  exit 1
fi

# 그 밖은 거절한다. 판정 불가는 통과가 아니다.
[ "$GATE_REVIEW_POLICY_INDEX" = "0" ] || {
  echo "룰 거부: 리뷰-후-머지 — 해소된 리뷰 정책 지수를 알 수 없습니다 ($GATE_REVIEW_POLICY_INDEX)" >&2
  exit 1
}

# 리뷰 먼저 — 아래는 신선도 사다리다. 「리뷰가 있었다」와 「리뷰가 지금 머지될
# 것을 덮는다」는 다른 명제이고, 이 사다리가 재는 것은 뒤쪽이다.
[ -f "$GATE_LEDGER" ] || { echo "룰 거부: 리뷰-후-머지 — 원장을 읽을 수 없습니다" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || {
  echo "룰 거부: 리뷰-후-머지 — 머지 행위에 세그먼트가 지정되지 않았습니다" >&2
  exit 1
}

row=$(grep -E '^- `cycle`' "$GATE_LEDGER" | grep -F "세그먼트=$GATE_SEGMENT " | tail -1)
[ -n "$row" ] || {
  echo "룰 거부: 리뷰-후-머지 — 세그먼트 '$GATE_SEGMENT' 의 리뷰 기록이 없습니다" >&2
  exit 1
}

field() { printf '%s' "$row" | tr '|' '\n' | sed -n "s/^ *$1=//p" | sed 's/[[:space:]]*$//' | tail -1; }

p0=$(field 'P0'); p1=$(field 'P1'); reviewed=$(field '리뷰 HEAD')
[ -n "$p0" ] || p0=0
[ -n "$p1" ] || p1=0

if [ "$p0" != "0" ] || [ "$p1" != "0" ]; then
  echo "룰 거부: 리뷰-후-머지 — 미해결 지적이 남아 있습니다 (P0=$p0 P1=$p1)" >&2
  exit 1
fi

[ -n "$reviewed" ] || {
  echo "룰 거부: 리뷰-후-머지 — 리뷰 기록에 HEAD 가 없어 신선도를 판정할 수 없습니다" >&2
  exit 1
}

seg_row=$(grep -E '^- `segment`' "$GATE_LEDGER" | grep -F "id=$GATE_SEGMENT " | tail -1)
wt=$(printf '%s' "$seg_row" | tr '|' '\n' | sed -n 's/^ *워크트리=//p' | sed 's/[[:space:]]*$//' | tail -1)
[ -d "$wt" ] || { echo "룰 거부: 리뷰-후-머지 — 세그먼트 워크트리가 없습니다: $wt" >&2; exit 1; }

now=$(cd "$wt" && git rev-parse HEAD 2>/dev/null)
[ -n "$now" ] || { echo "룰 거부: 리뷰-후-머지 — 현재 HEAD 를 읽을 수 없습니다" >&2; exit 1; }

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
  echo "룰 거부: 리뷰-후-머지 — 리뷰 이후 커밋이 추가됐습니다 (리뷰 ${reviewed} → 현재 ${now})" >&2
else
  echo "룰 거부: 리뷰-후-머지 — 리뷰 HEAD 가 현재 HEAD 의 조상이 아닙니다 (리뷰 ${reviewed}, 현재 ${now})" >&2
fi
exit 1
