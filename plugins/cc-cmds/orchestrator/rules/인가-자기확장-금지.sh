#!/bin/sh
# 인가를 스스로 넓히는 두 형태를 절단점과 무관하게 거부한다.
#
# 절단점 대조보다 먼저 볼 필요는 없다 — 어느 순서로 걸리든 거부는 거부이고,
# 이 룰이 통과시키는 것은 절단점이 다시 판정한다.

# 형태 1 — 브랜치 보호 우회. `--admin` 은 gh 의 플래그이지만 인자 어디에
# 나타나든 같은 뜻이므로 위치를 보지 않는다.
for a in $GATE_ARGV; do
  case "$a" in
    --admin|--admin=*)
      echo "인가-자기확장-금지: --admin 은 어떤 절단점에서도 인가되지 않습니다 — 보호 규칙에 막힌 머지는 park 합니다" >&2
      exit 1 ;;
  esac
done

# 형태 2 — 인가 기록 자체에 대한 쓰기. 드라이버도 라우터도 이 파일을 읽기만
# 한다. 추가 게이트는 동결된 블록의 편집을 거부할 수 있어도 「더 많이 주는
# 잘 만들어진 새 블록」은 평범한 append 로 통과시키므로, 쓰기 경로를 없애는
# 것이 유일하게 잔여를 남기지 않는 처방이다.
[ -n "$GATE_GRANT" ] || exit 0
for a in $GATE_ARGV; do
  [ "$a" = "$GATE_GRANT" ] || continue
  case "$GATE_SURFACE" in
    읽기) exit 0 ;;
  esac
  echo "인가-자기확장-금지: 인가 기록에 쓰려 합니다 — 이 파일은 킥오프만 씁니다: $GATE_GRANT" >&2
  exit 1
done
exit 0
