#!/bin/sh
# 리뷰 세션과 구현 세션의 조상 폐포가 서로소인가.
#
# 리뷰 등급의 행위에만 발동한다. 이 룰의 입력은 `stage-result` 행의
# `세션 id` 와 `부모` 이며, 그 둘을 기록하는 것은 드라이버다.
case "$GATE_ACT" in
  머지|배포|머지후착수) ;;
  *) exit 0 ;;
esac

[ -f "$GATE_LEDGER" ] || { echo "구현-리뷰-분리: 원장을 읽을 수 없습니다" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || exit 0

field() { printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1; }

rows=$(grep -E '^- `stage-result`' "$GATE_LEDGER" 2>/dev/null | grep -F "세그먼트=$GATE_SEGMENT " || true)
[ -n "$rows" ] || exit 0

impl_row=$(printf '%s\n' "$rows" | grep -F '스테이지=S4' | tail -1)
rev_row=$(printf '%s\n' "$rows" | grep -F '스테이지=S5' | tail -1)
[ -n "$impl_row" ] && [ -n "$rev_row" ] || exit 0

impl_sid=$(field "$impl_row" '세션 id'); impl_par=$(field "$impl_row" '부모')
rev_sid=$(field "$rev_row" '세션 id');  rev_par=$(field "$rev_row" '부모')

# A missing id is not a pass. The whole reason this rule was rewritten is that
# an unrecordable input made it vacuously true, and treating "unknown" as
# "disjoint" would put it straight back in that state.
for v in "$impl_sid" "$impl_par" "$rev_sid" "$rev_par"; do
  [ -n "$v" ] && [ "$v" != "미상" ] || {
    echo "구현-리뷰-분리: 세션 계보가 기록되지 않아 분리를 판정할 수 없습니다 — 판정 불가는 통과가 아닙니다" >&2
    exit 1
  }
done

# The ancestor closure of each side is {id, parent}. Two sessions are separate
# only when those sets do not meet: sharing a parent means one fork reviewed
# what its sibling wrote from the same context, and being each other's parent is
# the direct case.
for a in "$impl_sid" "$impl_par"; do
  for b in "$rev_sid" "$rev_par"; do
    if [ "$a" = "$b" ]; then
      echo "구현-리뷰-분리: 리뷰 세션과 구현 세션의 조상이 겹칩니다 ($a) — 자기 작업을 리뷰한 것입니다" >&2
      exit 1
    fi
  done
done
exit 0
