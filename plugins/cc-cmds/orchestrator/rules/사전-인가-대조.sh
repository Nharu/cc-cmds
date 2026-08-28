#!/bin/sh
# 되돌릴 수 없는 행위가 사전 인가 목록 안인가.
#
# 반환 규약이 다른 룰과 다르다 — 목록 밖이면 exit 1(거부)이 아니라 exit 5
# (승인 대기 발행)를 낸다. 게이트가 그 코드를 그대로 전파한다.
case "$GATE_SURFACE" in
  읽기|워크트리쓰기)
    exit 0 ;;
  트리밖쓰기)
    # 되돌리는 명령이 기록될 것을 조건으로 통과. 그 기록을 강제하는 것은
    # 게이트의 행 스키마이며, 여기서는 등급만 본다.
    exit 0 ;;
  "등급 미상")
    # 인용이 필요하다 — 축2 등급 토큰 중 유일하게 공백이 들어 있어, 인용하지
    # 않으면 `case` 패턴이 두 단어로 갈라져 파일 전체가 문법 오류가 된다.
    # 명시적으로 적는다. 예전에는 이 값이 아래 외부 상태 변경 팔로 흘러
    # 내려갔고, 그 조합이 스테이지 디스패치를 전부 승인 대기로 만들었다.
    # fail-closed 자체는 옳으므로 처분은 같지만, 흘러내려 그렇게 된 것과
    # 그러기로 정한 것은 다르다 — 전자는 읽는 사람이 의도를 볼 수 없다.
    echo "사전-인가-대조: 축2 등급이 미상입니다 — 판정 불가는 통과가 아닙니다" >&2
    exit 5 ;;
esac

# 외부상태변경 — 인가 목록과 대조한다.
[ -f "$GATE_MANIFEST" ] || { echo "사전-인가-대조: 매니페스트를 읽을 수 없습니다" >&2; exit 1; }

argv0=$(printf '%s' "$GATE_ARGV" | awk '{print $1; exit}')
sub=$(printf '%s' "$GATE_ARGV" | awk '{print $2; exit}')

matched=0
while IFS= read -r line; do
  case "$line" in
    '- `사전 인가`'*) ;;
    *) continue ;;
  esac
  shape=$(printf '%s' "$line" | tr '|' '\n' | sed -n 's/^ *형태=//p' | sed 's/[[:space:]]*$//')
  [ -n "$shape" ] || continue
  case "$argv0 $sub" in
    $shape*) matched=1; break ;;
  esac
  case "$argv0" in
    $shape*) matched=1; break ;;
  esac
done < "$GATE_MANIFEST"

if [ "$matched" = "1" ]; then
  exit 0
fi
echo "사전-인가-대조: '$argv0 $sub' 가 사전 인가 목록 밖입니다 — 승인 대기를 발행합니다" >&2
exit 5
