#!/bin/sh
# 되돌릴 수 없는 행위가 사전 인가 목록 안인가.
#
# 반환 규약이 다른 룰과 다르다 — 목록 밖이면 exit 1(거부)이 아니라 exit 5
# (승인 대기 발행)를 낸다. 게이트가 그 코드를 그대로 전파한다.
#
# 탐침 모드: `GATE_PREAUTH_PROBE=1` 이면 거부하지 않고 판정만 stdout 한 줄로
# 내보내고 exit 0 한다 — `P=<0|1> 형태=<완전|러너|없음> Pd=<0|1>`. 처분 평가기가
# 이 한 사본을 부르므로 매칭 규칙이 두 군데로 갈리지 않는다.
probe="${GATE_PREAUTH_PROBE:-0}"

if [ "$probe" != "1" ]; then
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
      echo "사전-인가-대조: the axis-2 grade is unknown — undecidable is not a pass" >&2
      exit 5 ;;
  esac
fi

[ -f "$GATE_MANIFEST" ] || {
  [ "$probe" = "1" ] && { echo "P=0 형태=없음 Pd=0"; exit 0; }
  echo "사전-인가-대조: cannot read the manifest" >&2; exit 1; }

# 불투명 러너 — 게이트의 등급표가 `워크트리쓰기` 로 고정하는 이름들과 같다.
# 이 목록이 하는 일은 하나뿐이다: 형태가 「러너만 적힌 것」인지 가른다.
runners=" bash sh zsh python3 node make npm npx yarn pnpm pytest go cargo docker "

# 정규화 — argv0 은 basename 으로, `-*=*` 단어는 버린다.
#
# basename 이 없으면 `/usr/bin/gh pr view` 가 `gh pr` 행과 한 글자도 맞지 않아
# 인가된 행위가 승인 대기로 떨어졌다. `-*=*` 버리기는 `terraform -chdir=<dir>
# apply` 처럼 전역 플래그가 하위 명령 앞에 오는 철자를 위한 것이고, 값이 떨어져
# 있는 형태(`git -C <path> commit`)는 여기서 알아볼 수 없어 손대지 않는다 —
# 바로 다음 단어를 값이 아니라 하위 명령으로 읽으면 더 나쁜 답이 된다.
norm=$(printf '%s' "$GATE_ARGV" | awk '
  {
    for (i = 1; i <= NF; i++) {
      w = $i
      if (i == 1) { n = split(w, parts, "/"); w = parts[n] }
      else if (w ~ /^-.*=/) continue
      printf "%s%s", (out++ ? " " : ""), w
    }
    print ""
  }')
argv0=$(printf '%s' "$norm" | awk '{print $1; exit}')
sub=$(printf '%s' "$norm" | awk '{print $2; exit}')

# 러너의 첫 비옵션 operand 자리 — 형태가 그 자리까지 담아야 「완전 형태」다.
# `bash scripts/deploy-dev.sh` 는 담았고 `bash` 나 `npm run` 은 담지 않았다.
operand_pos=$(printf '%s' "$norm" | awk '
  { for (i = 2; i <= NF; i++) { if ($i ~ /^-/) continue; print i; exit } }')
[ -n "$operand_pos" ] || operand_pos=2

# 행위 표지가 파괴인가 — 게이트가 `GATE_MARK` 로 실어 준다. 러너만 적힌 형태는
# 파괴 행위를 매칭하지 않는다(D14 호환 규칙).
act_destructive=0
[ "${GATE_MARK:-}" = "파괴" ] && act_destructive=1

matched=0; matched_kind=없음; pd=0
while IFS= read -r line; do
  case "$line" in
    '- `사전 인가`'*) ;;
    *) continue ;;
  esac
  shape=$(printf '%s' "$line" | tr '|' '\n' | sed -n 's/^ *형태=//p' | sed 's/[[:space:]]*$//')
  [ -n "$shape" ] || continue

  nwords=$(printf '%s' "$shape" | awk '{print NF}')
  first=$(printf '%s' "$shape" | awk '{print $1; exit}')
  kind=완전
  case "$runners" in
    *" $first "*) [ "$nwords" -gt "$operand_pos" ] || kind=러너 ;;
  esac

  if [ "$kind" = "완전" ]; then
    # 완전 형태 N 단어는 정규화한 argv 의 앞 N 단어와 단어 단위로 같아야 한다.
    # 접두 매칭이 아니어서 `gh pr` 가 `gh project` 를 인가하던 번짐이 없다.
    head=$(printf '%s' "$norm" | awk -v n="$nwords" '{ for (i = 1; i <= n && i <= NF; i++) printf "%s%s", (i > 1 ? " " : ""), $i; print "" }')
    [ "$head" = "$shape" ] || continue
    matched=1; matched_kind=완전
    # 파괴 명시 — 표지를 준 트리거 단어가 이 형태 안에 단어로 있어야 한다.
    # 형태를 다시 표지 함수에 넣는 방식은 형태가 행위와 다른 파괴 단어를 가질 때
    # 열리는 쪽으로 틀리므로 쓰지 않는다.
    if [ -n "${GATE_MARK_TRIGGER:-}" ]; then
      for w in $shape; do
        [ "$w" = "$GATE_MARK_TRIGGER" ] && { pd=1; break; }
      done
    fi
    break
  fi

  # 러너만 적힌 형태 — 기존 매니페스트가 계속 동작하도록 오늘의 접두 매칭을
  # 유지하되, 비파괴 행위에만 적용하고 lift 로는 세지 않는다.
  [ "$act_destructive" = "1" ] && continue
  case "$argv0 $sub" in
    $shape*) matched=1; matched_kind=러너; break ;;
  esac
  case "$argv0" in
    $shape*) matched=1; matched_kind=러너; break ;;
  esac
done < "$GATE_MANIFEST"

if [ "$probe" = "1" ]; then
  echo "P=$matched 형태=$matched_kind Pd=$pd"
  exit 0
fi

if [ "$matched" = "1" ]; then
  exit 0
fi
echo "사전-인가-대조: '$argv0 $sub' is outside the preauthorization list — issuing an approval request" >&2
exit 5
