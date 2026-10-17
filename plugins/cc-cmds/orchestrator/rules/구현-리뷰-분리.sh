#!/bin/sh
# 리뷰 세션과 구현 세션의 조상 폐포가 서로소인가.
#
# 리뷰 등급의 행위에만 발동한다. 이 룰의 입력은 `stage-result` 행의
# `세션 id` 와 `부모` 이며, 그 둘을 기록하는 것은 드라이버다.
case "$GATE_ACT" in
  머지|배포|머지후착수) ;;
  *) exit 0 ;;
esac

[ -f "$GATE_LEDGER" ] || { echo "구현-리뷰-분리: cannot read the ledger" >&2; exit 1; }
[ -n "$GATE_SEGMENT" ] && [ "$GATE_SEGMENT" != "-" ] || exit 0

field() { printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1; }

rows=$(grep -E '^- `stage-result`' "$GATE_LEDGER" 2>/dev/null | grep -F "세그먼트=$GATE_SEGMENT " || true)
[ -n "$rows" ] || exit 0

# 종류 로 먼저 고르고 S4/S5 로 물러선다. 스테이지 번호는 고정 그래프의 것이라
# 라우터가 디스패치한 행에는 없고, 번호로만 고르면 이 룰이 라우터 경로에서 언제나
# 빈 집합을 읽어 조용히 통과한다 — 이 룰이 없애려고 다시 쓰인 바로 그 상태다.
#
# 번호 폴백은 `종류` 필드가 없는 행, 곧 드라이버가 쓴 고정 그래프 행에만 건다.
# 라우터 경로의 행은 `스테이지=` 에 세그먼트 id 를 싣으므로, 슬라이스 이름이 `S5` 인
# 세그먼트의 구현 행이 리뷰 행으로도 집혀 같은 세션을 두 번 읽고, 리뷰가 아직 없는데도
# 그 세그먼트의 머지 등급 행위가 전부 거절됐다. 값도 부분 문자열이 아니라 필드로 비교한다.
#
# 둘째 인자는 고를 행들이다. 주지 않으면 세그먼트의 행 전부이고, 빈 값을 주면 빈
# 집합이다 — 리드 수정 행 앞의 행만 볼 때 그 앞에 아무것도 없으면 아무것도 고르지 않는다.
#
# `_all` 은 맞는 행을 원장 순서대로 전부, 이름 없는 쪽은 그 마지막 행 하나를 낸다.
pick_all() { printf '%s\n' "${2-$rows}" | grep -F "종류=$1"; }
pick() { pick_all "$@" | tail -1; }
pick_fixed_all() {
  printf '%s\n' "${2-$rows}" | while IFS= read -r r; do
    [ -z "$(field "$r" '종류')" ] && [ "$(field "$r" '스테이지')" = "$1" ] && printf '%s\n' "$r"
  done
}
pick_fixed() { pick_fixed_all "$@" | tail -1; }
impl_row=$(pick implement); [ -n "$impl_row" ] || impl_row=$(pick_fixed S4)
rev_row=$(pick review);     [ -n "$rev_row" ]  || rev_row=$(pick_fixed S5)
# 리드 수정은 한 세그먼트에 여럿일 수 있다 — 확인 리뷰 뒤 런 안 추가 처리가 리드 수정을
# 다시 낸다. 그래서 하나가 아니라 전부를 모으고, lf_row 는 그 첫 행이다.
lf_rows=$(pick_all lead-fix); [ -n "$lf_rows" ] || lf_rows=$(pick_fixed_all S5F)
lf_row=$(printf '%s\n' "$lf_rows" | sed -n '1p')

# judge <저작 행> <리뷰 행> <저작 쪽 이름> [쌍 표지] — 두 행의 조상 폐포가 서로소이면
# 0, 아니면 사유를 stderr 에 쓰고 1.
judge() {
  a_sid=$(field "$1" '세션 id'); a_par=$(field "$1" '부모')
  b_sid=$(field "$2" '세션 id'); b_par=$(field "$2" '부모')

  # A missing id is not a pass. The whole reason this rule was rewritten is that
  # an unrecordable input made it vacuously true, and treating "unknown" as
  # "disjoint" would put it straight back in that state.
  for v in "$a_sid" "$a_par" "$b_sid" "$b_par"; do
    [ -n "$v" ] && [ "$v" != "미상" ] || {
      echo "구현-리뷰-분리: session lineage is not recorded, so separation cannot be judged — undecidable is not a pass${4:+ ($4)}" >&2
      return 1
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
  if [ "$a_par" = "$b_par" ] && [ "$a_par" != "$a_sid" ] && [ "$a_par" != "$b_sid" ]; then
    dispatcher="$a_par"
  fi

  # The ancestor closure of each side is {id, parent} minus the dispatcher. Two
  # sessions are separate only when those sets do not meet: sharing a parent that
  # authored means one fork reviewed what its sibling wrote from the same context,
  # and being each other's parent is the direct case.
  for a in "$a_sid" "$a_par"; do
    if [ -n "$dispatcher" ] && [ "$a" = "$dispatcher" ]; then continue; fi
    for b in "$b_sid" "$b_par"; do
      if [ -n "$dispatcher" ] && [ "$b" = "$dispatcher" ]; then continue; fi
      if [ "$a" = "$b" ]; then
        echo "구현-리뷰-분리: the review session and the $3 session share an ancestor ($a) — this is a review of its own work${4:+ ($4)}" >&2
        return 1
      fi
    done
  done
  return 0
}

if [ -z "$lf_row" ]; then
  [ -n "$impl_row" ] && [ -n "$rev_row" ] || exit 0
  judge "$impl_row" "$rev_row" implement || exit 1
  exit 0
fi

# A LEAD FIX ADDS AN AUTHOR, SO THREE PAIRS ARE JUDGED, not one. The re-check
# review is judged against every lead fix that wrote code (b) and against the
# last implementation it also reads (c). The cap review stays paired with that
# implementation too (a): before the lead fix existed, merging after the cap
# review checked exactly that pair, and the re-check judges the implementation
# only through the cap review's items — dropping the pair would take a check the
# merge used to make. "Before the lead fix" is ledger order before the FIRST lead
# fix, on both the `종류` rows and the fixed-graph rows.
#
# (b) runs over every lead fix, not only one. A segment that gets a second lead
# fix after its re-check carries code from both into the last review, so judging
# one of them alone passes a last review that descends from the other.
before=$(printf '%s\n' "$rows" | LF_ROW="$lf_row" awk '$0 == ENVIRON["LF_ROW"] { exit } { print }')
cap_row=$(pick review "$before"); [ -n "$cap_row" ] || cap_row=$(pick_fixed S5 "$before")
if [ -n "$impl_row" ] && [ -n "$cap_row" ]; then
  judge "$impl_row" "$cap_row" implement "쌍 a: 마지막 구현 × 리드 수정 앞의 마지막 리뷰" || exit 1
fi
if [ -n "$rev_row" ]; then
  k=0
  while IFS= read -r lf; do
    k=$((k + 1))
    judge "$lf" "$rev_row" lead-fix "쌍 b: 리드 수정 $k × 마지막 리뷰" || exit 1
  done <<EOF
$lf_rows
EOF
fi
if [ -n "$impl_row" ] && [ -n "$rev_row" ]; then
  judge "$impl_row" "$rev_row" implement "쌍 c: 마지막 구현 × 마지막 리뷰" || exit 1
fi
exit 0
