#!/bin/sh
# 행위 등급이 그 대상의 절단점 이하인가.
#
# 어휘 해소는 게이트가 한다 — 여기 도착하는 것은 이미 정수 두 개다. 검사기가
# 어휘를 다시 해소하면 run.sh 의 사다리 사본이 하나 더 생기고, 그 사본은
# lint-cutpoint-vocabulary.sh 가 보지 않는 자리에 있다.
[ -n "$GATE_ACT_INDEX" ] && [ -n "$GATE_TARGET_INDEX" ] || {
  echo "절단점-준수: 게이트가 등급을 넘겨주지 않았습니다" >&2
  exit 1
}
if [ "$GATE_ACT_INDEX" -le "$GATE_TARGET_INDEX" ]; then
  exit 0
fi
echo "절단점-준수: 행위 '$GATE_ACT' 가 대상 '$GATE_ALIAS' 의 절단점 '$GATE_TARGET_CUTPOINT' 를 넘습니다" >&2
exit 1
