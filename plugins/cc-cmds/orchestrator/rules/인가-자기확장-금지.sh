#!/bin/sh
# 인가를 스스로 넓히는 두 형태를 절단점과 무관하게 거부한다.
#
# 절단점 대조보다 먼저 볼 필요는 없다 — 어느 순서로 걸리든 거부는 거부이고,
# 이 룰이 통과시키는 것은 절단점이 다시 판정한다.

# 정규 argv 전송 — 게이트가 실어 줄 때만 쓰는 선택적 입력이다. 부재는 옛
# 경로이고, 그때 아래 두 루프는 예전과 바이트 동일하게 돈다. 있을 때 이것을
# 쓰는 이유는 단어 경계다 — 공백이나 줄바꿈을 품은 인자가 `$GATE_ARGV` 의 단순
# 분리에서는 여러 단어로 갈라져, 인가 기록 경로가 반 토막으로만 비교되었다.
#
# 단어를 풀지 않고 **비교할 값을 같은 방식으로 감싸서** 맞춘다. 먼저 풀면
# 공백·줄바꿈이 되살아나 단어 경계가 다시 사라지므로, 감싼 채로 두는 쪽만이
# 경계를 지킨다. `--admin` 은 감싸도 자기 자신이라 그대로 비교된다.
#
# 설정됐는데 빈 값인 것은 게이트의 버그다. 이 룰은 거부가 본업이므로 그 상태를
# 통과로 접으면 두 형태가 모두 무력해진다 — 막는 쪽으로 닫는다.
escape_word() {
  # RS 를 입력에 없는 바이트로 두어 값 전체를 한 레코드로 읽는다 — 기본 RS 면
  # 줄바꿈이 레코드 경계로 먹혀 `\n` 을 감쌀 기회 자체가 사라진다.
  printf '%s' "$1" | awk -v RS='\001' '
    {
      s = $0; n = length(s); out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\")     { out = out "\\\\";  continue }
        if (c == " ")      { out = out "\\x20"; continue }
        if (c == "\t")     { out = out "\\t";   continue }
        if (c == "\n")     { out = out "\\n";   continue }
        if (c == "\r")     { out = out "\\r";   continue }
        out = out c
      }
      printf "%s", out
    }'
}

if [ -n "${GATE_ARGV_CANON+set}" ]; then
  if [ -z "$GATE_ARGV_CANON" ]; then
    echo "인가-자기확장-금지: 정규 argv 가 빈 값입니다 — 인자를 확인할 수 없으므로 거부합니다" >&2
    exit 1
  fi
  # 이스케이프된 단어에는 공백도 줄바꿈도 없으므로 기본 분리가 곧 단어 경계다.
  argv_list=$GATE_ARGV_CANON
  grant_cmp=$(escape_word "$GATE_GRANT")
else
  argv_list=$GATE_ARGV
  grant_cmp=$GATE_GRANT
fi

# 형태 1 — 브랜치 보호 우회. `--admin` 은 gh 의 플래그이지만 인자 어디에
# 나타나든 같은 뜻이므로 위치를 보지 않는다.
for a in $argv_list; do
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
for a in $argv_list; do
  [ "$a" = "$grant_cmp" ] || continue
  case "$GATE_SURFACE" in
    읽기) exit 0 ;;
  esac
  echo "인가-자기확장-금지: 인가 기록에 쓰려 합니다 — 이 파일은 킥오프만 씁니다: $GATE_GRANT" >&2
  exit 1
done
exit 0
