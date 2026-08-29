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

# 종류 로 먼저 고르고 S4/S5 로 물러선다. 스테이지 번호는 고정 그래프의 것이라
# 라우터가 디스패치한 행에는 없고, 번호로만 고르면 이 룰이 라우터 경로에서 언제나
# 빈 집합을 읽어 조용히 통과한다 — 이 룰이 없애려고 다시 쓰인 바로 그 상태다.
pick() { printf '%s\n' "$rows" | grep -F "종류=$1" | tail -1; }
impl_row=$(pick implement); [ -n "$impl_row" ] || impl_row=$(printf '%s\n' "$rows" | grep -F '스테이지=S4' | tail -1)
rev_row=$(pick review);     [ -n "$rev_row" ]  || rev_row=$(printf '%s\n' "$rows" | grep -F '스테이지=S5' | tail -1)
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

# THE DISPATCHER IS NOT AN ANCESTOR IN THE SENSE THIS RULE MEANS.
#
# The router dispatches both stages, and the gate records the router as `부모`
# on both rows. So the two closures met at the router on every run a router
# drove, and this rule refused EVERY merge — the id it named was neither stage
# but the thing that launched them. Measured: a segment completed review, plan,
# implementation and re-review with P0 and P1 at zero, and the merge was refused
# naming the router's own session.
#
# What the rule is for is authorship: did the reviewing session see the work
# being made. A shared dispatcher does not imply that — the two stages share no
# output and each reads the tree independently.
#
# The discriminator needs no new field. In this design the author of an
# implementation is a STAGE, and a stage's own session id is on its row. So a
# common parent that is NEITHER side's session id never authored anything
# recorded; it is the dispatcher. A parent that IS the other side's session id
# is the fork case this rule exists for, and that comparison is untouched below.
#
# Residual, stated rather than hidden: a router that authored an implementation
# itself — through `exec` rather than through a stage — is not covered, and was
# not covered before either. Nothing records the router as an author.
dispatcher=""
if [ -n "$impl_par" ] && [ "$impl_par" = "$rev_par" ] \
   && [ "$impl_par" != "$impl_sid" ] && [ "$impl_par" != "$rev_sid" ]; then
  dispatcher="$impl_par"
fi

# The ancestor closure of each side is {id, parent} minus the dispatcher. Two
# sessions are separate only when those sets do not meet: sharing a parent that
# authored means one fork reviewed what its sibling wrote from the same context,
# and being each other's parent is the direct case.
for a in "$impl_sid" "$impl_par"; do
  if [ -n "$dispatcher" ] && [ "$a" = "$dispatcher" ]; then continue; fi
  for b in "$rev_sid" "$rev_par"; do
    if [ -n "$dispatcher" ] && [ "$b" = "$dispatcher" ]; then continue; fi
    if [ "$a" = "$b" ]; then
      echo "구현-리뷰-분리: 리뷰 세션과 구현 세션의 조상이 겹칩니다 ($a) — 자기 작업을 리뷰한 것입니다" >&2
      exit 1
    fi
  done
done
exit 0
