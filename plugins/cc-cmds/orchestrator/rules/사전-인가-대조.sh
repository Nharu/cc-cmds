#!/bin/sh
# 되돌릴 수 없는 행위가 사전 인가 목록 안인가.
#
# 반환 규약이 다른 룰과 다르다 — 목록 밖이면 exit 1(거부)이 아니라 exit 5
# (승인 대기 발행)를 낸다. 게이트가 그 코드를 그대로 전파한다.
#
# 탐침 모드: `GATE_PREAUTH_PROBE=1` 이면 거부하지 않고 판정만 stdout 한 줄로
# 내보내고 exit 0 한다 —
#   `P=<0|1> 형태=<완전|러너|없음> Pd=<0|1> Pv=<0|1>
#    Sx=<ok|dropped|none|code> Sw=<단어|-> 제안=<형태|->`
# (실제로는 한 줄). `제안` 은 자유 문면이라 맨 끝에서 줄 끝까지다. 처분 평가기가
# 이 한 사본을 부르므로 매칭 규칙이 두 군데로 갈리지 않는다.
#
# 탐침이 더 받는 입력: `GATE_DESTRUCTIVE`(스테이지의 `--destructive`),
# `GATE_REACH_EFF`(처분이 정한 실효 도달).
probe="${GATE_PREAUTH_PROBE:-0}"

if [ "$probe" != "1" ]; then
  # 적용 행위 — 적용 명령은 매니페스트의 적용 지점이 정하고 게이트가 전제를
  # 확인한 뒤에만 이 값을 싣는다. 같은 명령을 exec 으로 내면 여기를 지나지 않는다.
  [ "${GATE_KIND:-}" = "apply" ] && [ "$GATE_ARGV" = "적용" ] && [ -n "${GATE_APPLY_COMMAND:-}" ] && exit 0
  # 정산 행위 — 적용이 같은 인가 아래서 돌리는 동결 프로브를 다시 돌릴 뿐이므로
  # 적용과 같은 근거로 연다. 표지는 게이트의 정산 전제 검사가 지났을 때만 실린다.
  [ "${GATE_KIND:-}" = "apply-settle" ] && [ "$GATE_ARGV" = "정산" ] && [ "${GATE_SETTLE_PRE:-}" = "1" ] && exit 0
  # 재실행 행위 — `act --kind ci-rerun --cutpoint PR -- 재실행 <head sha>` 만 연다.
  # 적격성은 여기서 보지 않는다: 이 행위에 대한 규칙 거부는 park 가 아니라 승인
  # 요청으로 끝나므로, 게이트의 전제 함수가 철자·라우팅·tip 을 먼저 확인하고 지났을
  # 때 `GATE_CI_RERUN_PRE=1` 을 싣는다. 표지가 없으면 열지 않는다.
  if [ "${GATE_KIND:-}" = "ci-rerun" ] && [ "${GATE_ACT:-}" = "PR" ] && [ "${GATE_CI_RERUN_PRE:-}" = "1" ]; then
    case "$GATE_ARGV" in
      "재실행 "*)
        rerun_sha="${GATE_ARGV#재실행 }"
        case "$rerun_sha" in
          ''|*[!0-9a-f]*) ;;
          *) [ "${#rerun_sha}" -eq 40 ] && exit 0 ;;
        esac ;;
    esac
  fi
  # 재실행의 다른 철자는 행이 일치해도 열지 않는다 — 재실행은 위 행위로만 나간다.
  # 등급 판정이 벗기는 투명 래퍼(env·genv 와 그 옵션·대입 낱말, command, nice, nohup,
  # timeout 과 시간 인자, stdbuf, time, lockf 와 파일 인자, g 접두 꼴)를 같은 순서로
  # 벗긴 뒤 argv0 을 basename 으로 읽는다. 감싼 철자를 지나쳐 보내면 등급이 외부 상태
  # 변경으로 매기는 같은 행위가 사전 인가 행으로 열린다. 대상은 `gh run rerun`
  # (-R·--repo·--hostname 과 그 값을 먼저 뗀다), 메서드와 무관한 REST 재실행·재요청
  # 경로 다섯, `rerequestCheckSuite` 를 담거나 질의를 argv 밖(`query=@`, `--input`)에서
  # 받는 `gh api graphql` 이다. 취소 철자는 여기서 보지 않는다.
  rerun_hit=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk '
    function base(s,   n, p) { n = split(s, p, "/"); return p[n] }
    function hexv(h,   d) {
      d = "0123456789abcdef"; h = tolower(h)
      return (index(d, substr(h, 1, 1)) - 1) * 16 + index(d, substr(h, 2, 1)) - 1
    }
    function pdec(s,   o, i, h) {
      o = ""
      while ((i = index(s, "%")) > 0) {
        h = substr(s, i + 1, 2)
        if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) { o = o substr(s, 1, i - 1) sprintf("%c", hexv(h)); s = substr(s, i + 3) }
        else { o = o substr(s, 1, i); s = substr(s, i + 1) }
      }
      return o s
    }
    function pnorm(s,   n, p, q, d, i, o) {
      n = split(s, p, "/"); d = 0
      for (i = 1; i <= n; i++) {
        if (p[i] == "" || p[i] == ".") continue
        if (p[i] == "..") { if (d > 0) d--; continue }
        q[++d] = p[i]
      }
      o = ""
      for (i = 1; i <= d; i++) o = o (i > 1 ? "/" : "") q[i]
      return o
    }
    {
      n = NF; i = 1
      while (i <= n) {
        b = base($i)
        if (b == "env" || b == "genv") {
          i++
          while (i <= n) {
            if ($i == "--") { i++; break }
            # `-S` 의 값은 펼쳐진 argv 에서 명령 낱말들 자신이므로 건너뛰지 않는다.
            if ($i ~ /^(-u|-C|-P|--unset|--chdir)$/) { i += 2; continue }
            if ($i ~ /^-/ || $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
            break
          }
        } else if (b == "command") {
          i++
          while (i <= n && $i ~ /^-/) { if ($i == "--") { i++; break } i++ }
        } else if (b == "nice" || b == "gnice") {
          i++
          while (i <= n && $i ~ /^-/) {
            if ($i == "--") { i++; break }
            if ($i == "-n" || $i == "--adjustment") { i += 2; continue }
            i++
          }
        } else if (b == "nohup" || b == "gnohup") {
          i++
        } else if (b == "timeout" || b == "gtimeout") {
          i++
          while (i <= n && $i ~ /^-/) {
            if ($i == "--") { i++; break }
            if ($i ~ /^(-s|-k|--signal|--kill-after)$/) { i += 2; continue }
            i++
          }
          i++
        } else if (b == "stdbuf" || b == "gstdbuf") {
          i++
          while (i <= n && $i ~ /^-/) {
            if ($i == "--") { i++; break }
            if ($i ~ /^-[ioe]$/ || $i ~ /^--(input|output|error)$/) { i += 2; continue }
            i++
          }
        } else if (b == "time" || b == "gtime") {
          i++
          while (i <= n && $i ~ /^-/) {
            if ($i == "--") { i++; break }
            if ($i ~ /^(-o|-f|--output|--format)$/) { i += 2; continue }
            i++
          }
        } else if (b == "lockf") {
          i++
          while (i <= n && $i ~ /^-/) {
            if ($i == "--") { i++; break }
            if ($i == "-t") { i += 2; continue }
            i++
          }
          i++
        } else break
      }
      if (i > n || base($i) != "gh") exit
      m = 0
      for (j = i + 1; j <= n; j++) {
        if ($j ~ /^(-R|--repo|--hostname)$/) { j++; continue }
        if ($j ~ /^(-R.|--repo=|--hostname=)/) continue
        r[++m] = $j
      }
      if (m >= 2 && r[1] == "run" && r[2] == "rerun") { print "run rerun"; exit }
      gql = 0; outside = 0
      # gh 가 요청 줄에서 떼는 query 와 fragment 를 떼고, `%xx` 를 풀고, 소문자로 접고,
      # 절대 URL 의 스킴과 호스트를 떼고, 빈 조각·`.` 조각을 지우고 `..` 를 앞 조각과
      # 상쇄해 본다 — 모두 같은 엔드포인트에 닿는 철자다. `repos/` 경로에 gh 가 채우는
      # `{owner}`·`{repo}` 밖의 자리표시자(`{branch}`)가 남으면 채워진 값이 재실행 경로가
      # 될 수 있으므로 닫는다.
      for (k = 1; k <= m; k++) {
        w = r[k]; sub(/[?#].*$/, "", w)
        w = tolower(pdec(w))
        if (w ~ /^https?:\/\//) { sub(/^https?:\/\/[^\/]*/, "", w) }
        w = pnorm(w)
        if (w ~ /(^|\/)actions\/runs\/[^\/]+\/rerun(-failed-jobs)?$/ ||
            w ~ /(^|\/)actions\/jobs\/[^\/]+\/rerun$/ ||
            w ~ /(^|\/)check-(suites|runs)\/[^\/]+\/rerequest$/) { print "rest " w; exit }
        if (w ~ /^repos\//) {
          p = w; gsub(/\{owner\}|\{repo\}/, "", p)
          if (index(p, "{")) { print "rest " w; exit }
        }
        if (w ~ /(^|\/)graphql$/) gql = 1
        if (index(r[k], "query=@") || r[k] == "--input" || r[k] ~ /^--input=/) outside = 1
      }
      if (gql && (index(tolower($0), "rerequestchecksuite") || outside)) print "graphql"
    }')
  if [ -n "$rerun_hit" ]; then
    echo "사전-인가-대조: a CI rerun ($rerun_hit) is not opened by a preauthorization row — issue it as \`act --kind ci-rerun --cutpoint PR -- 재실행 <head sha>\`" >&2
    [ "${GATE_AUTO_RESOLVE:-}" = "1" ] && exit 1
    exit 5
  fi
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

# 탐침은 매니페스트가 없어도 행이 없는 것으로 읽고 끝까지 계산한다 — 제안은 행과
# 무관하게 행위에서만 나온다.
[ -f "$GATE_MANIFEST" ] || [ "$probe" = "1" ] || {
  echo "사전-인가-대조: cannot read the manifest" >&2; exit 1; }

# 불투명 러너 — 게이트의 등급표가 `워크트리쓰기` 로 고정하는 이름들과 같다.
# 이 목록이 하는 일은 하나뿐이다: 형태가 「러너만 적힌 것」인지 가른다.
runners=" bash sh zsh python3 node make npm npx yarn pnpm pytest go cargo docker "
# 러너 중 스크립트 피연산자를 받는 인터프리터. 이들의 형태는 길이가 아니라 스크립트
# 자리의 단어와 그 앞 플래그로 완전 여부를 가른다(#1094).
interps=" bash sh zsh python3 node "

# 인터프리터 형태에서 스크립트 자리 앞 단어가 모두 프로그램 원문을 바꾸지 않는 닫힌
# 플래그인가. 셸은 -e -u -v -x, python3 는 -u -B -E -I -s -S -O 의 묶음만이고 node 는
# 없다. 코드 문자열·모듈·stdin 플래그(-c, -m, -e, -s 셸)와 값을 받는 옵션(-o, -W, -r)은
# 목록 밖이므로 따로 훑지 않아도 그 형태는 완전이 되지 않는다 — 값을 받는 옵션의 값이
# 스크립트 자리에 잡혀 뒤의 코드 플래그가 가려지는 `bash -o pipefail -c …` 도 같다.
# 킥오프 도우미의 kd_closed_flags_only 가 이 본문의 바이트 사본이고 시험이 둘을 비교한다.
closed_flags_only() {   # $1 interpreter, $2 shape, $3 script position: every word before it is a flag that changes no program source
  i=0; set -f
  for w in $2; do
    i=$((i + 1))
    { [ "$i" -ge 2 ] && [ "$i" -lt "$3" ]; } || continue
    case "$1:$w" in
      bash:-?*|sh:-?*|zsh:-?*) case "${w#-}" in *[!euvx]*) set +f; return 1 ;; esac ;;
      python3:-?*) case "${w#-}" in *[!uBEIsSO]*) set +f; return 1 ;; esac ;;
      *) set +f; return 1 ;;
    esac
  done
  set +f; return 0
}

# 단어열의 p 번째 단어.
word_at() { printf '%s\n' "$1" | awk -v p="$2" '{ print $p; exit }'; }

# 정규화 — argv0 은 basename 으로, `-*=*` 단어는 버린다.
#
# basename 이 없으면 `/usr/bin/gh pr view` 가 `gh pr` 행과 한 글자도 맞지 않아
# 인가된 행위가 승인 대기로 떨어졌다. `-*=*` 단어는 행이 담을 수 없으므로 정규화에서
# 버리고, 그 원 자리(`drop`)를 따로 기억해 행의 범위 안에서 떨어졌으면 그 행과
# 일치하지 않게 한다. 그래서 `terraform -chdir=<dir> apply` 처럼 `=` 철자로만 받는
# 옵션을 쓰는 행위는 어떤 행으로도 열리지 않는다. 값이 떨어져 있는 형태
# (`git -C <path> commit`)는 여기서 알아볼 수 없어 손대지 않는다 — 바로 다음 단어를
# 값이 아니라 하위 명령으로 읽으면 더 나쁜 답이 된다.
#
# 줄바꿈은 먼저 공백으로 편다. awk 는 입력 줄마다 본문을 돌므로, `gh pr create
# --body` 의 본문처럼 인자 하나에 줄바꿈이 들면 `norm` 이 여러 줄이 되고 한 줄짜리
# 형태와의 비교가 참이 될 수 없어 인가된 행위가 목록 밖으로 판정됐다.
norm=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk '
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
# 정규화 전 argv0 — 경로로 지명된 프로그램은 basename 이 같은 행으로 축자 일치가 서지 않는다.
argv0_raw=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk '{print $1; exit}')

# 러너의 첫 비옵션 operand 자리 — 형태가 그 자리까지 담아야 「완전 형태」다.
# `bash scripts/deploy-dev.sh` 는 담았고 `bash` 나 `npm run` 은 담지 않았다.
operand_pos=$(printf '%s' "$norm" | awk '
  { for (i = 2; i <= NF; i++) { if ($i ~ /^-/) continue; print i; exit } }')
[ -n "$operand_pos" ] || operand_pos=2
nf=$(printf '%s\n' "$norm" | awk '{ print NF; exit }')
[ -n "$nf" ] || nf=0

# 정규화 단어 k 번째의 원 단어 번호(`map`)와 떨어진 `-*=*` 단어의 원 번호(`drop`).
# 게이트는 argv 를 평탄화해 넘기므로 원 번호는 여기서 같은 규칙으로 센다. 행이 담는
# 구간 안에서 단어가 떨어졌으면 그 행이 무엇을 열었는지 말할 수 없다.
map=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk '
  { for (i = 1; i <= NF; i++) if (i == 1 || $i !~ /^-.*=/) printf "%s%d", (o++ ? " " : ""), i; print "" }')
drop=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk '
  { for (i = 2; i <= NF; i++) if ($i ~ /^-.*=/) printf "%s%d", (o++ ? " " : ""), i; print "" }')

# 행위 표지가 파괴인가 — 게이트가 `GATE_MARK` 로 실어 준다. 러너만 적힌 형태는
# 파괴 행위를 매칭하지 않는다(D14 호환 규칙). 표지 없이 스테이지가 `--destructive`
# 로 신고만 한 파괴는 게이트가 파괴 단어를 보지 못했으므로, 행위 전체를 축자로
# 담고 떨어진 단어가 없는 행만 그것을 명시한다.
act_destructive=0
[ "${GATE_MARK:-}" = "파괴" ] && act_destructive=1
declared_only=0
[ "$act_destructive" = "0" ] && [ "${GATE_DESTRUCTIVE:-0}" = "1" ] && declared_only=1

# 게이트 자신의 헬퍼 이름은 이름만으로 맞추지 않는다 — 워크트리에 같은 이름으로
# 쓴 파일도 basename 은 같다. 게이트가 argv0 의 실제 경로를 자기 옆의 사본과
# 대조해 표 등급을 준 경우(`GATE_GRADE_SOURCE=표`)에만 그 이름의 형태가 맞는다.
own_ok=1
case "$argv0" in
  clickup-create.py|clickup-relate.py|base-split.py|similar-items.py)
    [ "${GATE_GRADE_SOURCE:-}" = "표" ] || own_ok=0 ;;
esac

# 축자 일치가 설 수 있는 행위인가 — 정규화가 아무것도 바꾸지 않았을 때(argv0 에 경로가
# 없고 떨어진 단어가 없을 때)만 정규화 단어열이 원 argv 와 같다. 원소 경계(공백을 품은
# 원소)는 평탄화된 입력에서 보이지 않으므로 게이트가 따로 잰다.
verbatim_ok=0
case "$argv0_raw" in
  */*) ;;
  *) [ -z "$drop" ] && verbatim_ok=1 ;;
esac

# 모든 행을 훑는다 — 이른 break 가 없다. 첫 일치에서 멈추면 앞의 러너 행이나 짧은
# 완전 행이 뒤의 더 긴 행을 가려, 축자 일치와 파괴 명시가 그 행을 보지 못한다.
matched=0; any_full=0; any_runner=0; pd=0; pv=0
mf="$GATE_MANIFEST"; [ -f "$mf" ] || mf=/dev/null
while IFS= read -r line; do
  [ "$own_ok" = "1" ] || break
  case "$line" in
    '- `사전 인가`'*) ;;
    *) continue ;;
  esac
  shape=$(printf '%s' "$line" | tr '|' '\n' | sed -n 's/^ *형태=//p' | sed 's/[[:space:]]*$//')
  [ -n "$shape" ] || continue

  nwords=$(printf '%s' "$shape" | awk '{print NF}')
  first=$(printf '%s' "$shape" | awk '{print $1; exit}')
  # 행이 담는 구간 안에서 정규화가 단어를 떨어뜨렸으면 그 행은 이 행위와 일치하지
  # 않는다 — 완전 행이든 러너 행이든, 탐침이든 비탐침 통과든 같다. 행은 `-x=y`
  # 단어를 담을 수 없으므로 `node --require=/tmp/e.js scripts/x.js` 가 행
  # `node scripts/x.js` 로, `npm --script-shell=… run deploy` 가 행 `npm run` 으로
  # 열리면 행이 말하지 않은 옵션을 연 것이다. 행의 마지막 단어 뒤에서 떨어진 단어는
  # 행이 덮지 않는 꼬리라 일치를 막지 않는다.
  last=$(word_at "$map" "$nwords")
  dz_row=0
  for d in $drop; do
    if [ -z "$last" ] || [ "$d" -lt "$last" ]; then dz_row=1; break; fi
  done
  [ "$dz_row" = "0" ] || continue
  # 축자 일치 — 행이 행위 전체를 단어 하나까지 같게 적었다. 완전·러너 판정과 무관하게
  # 잰다(2단어 러너 행위 `make deploy` 도 행 `make deploy` 로 축자다).
  [ "$verbatim_ok" = "1" ] && [ "$shape" = "$norm" ] && pv=1
  # 형태의 완전 여부. 인터프리터가 아닌 러너는 첫 비옵션 operand 자리 너머까지 담아야
  # 완전이다. 인터프리터는 그 자리의 단어가 실제 스크립트 단어이고 — 비어 있지 않고,
  # 대시로 시작하지 않고, stdin 계열이 아니고 — 그 앞이 모두 닫힌 플래그일 때만
  # 완전이다. 스크립트 자리 뒤의 단어는 스크립트 인자라 보지 않는다. `+e` 처럼 `+` 로
  # 시작하는 단어는 옵션을 끄는 것이지 스크립트 단어가 아니다 — 거기서 멈춘 형태가
  # 완전이면 `bash +e -c …` 와 그 뒤 아무 경로나 연다.
  kind=완전
  case "$runners" in
    *" $first "*)
      kind=러너
      case "$interps" in
        *" $first "*)
          wop=$(word_at "$shape" "$operand_pos")
          case "$wop" in
            ''|-*|+*|/dev/stdin|/dev/fd/*|/proc/*/fd/*|'<('*) ;;
            *) closed_flags_only "$first" "$shape" "$operand_pos" && kind=완전 ;;
          esac ;;
        *) [ "$nwords" -gt "$operand_pos" ] && kind=완전 ;;
      esac ;;
  esac

  if [ "$kind" = "완전" ]; then
    # 완전 형태 N 단어는 정규화한 argv 의 앞 N 단어와 단어 단위로 같아야 한다.
    # 접두 매칭이 아니어서 `gh pr` 가 `gh project` 를 인가하던 번짐이 없다.
    head=$(printf '%s' "$norm" | awk -v n="$nwords" '{ for (i = 1; i <= n && i <= NF; i++) printf "%s%s", (i > 1 ? " " : ""), $i; print "" }')
    [ "$head" = "$shape" ] || continue
    matched=1; any_full=1
    # 파괴 명시 — 표지를 준 트리거 단어가 이 형태 안에 단어로 있어야 한다.
    # 형태를 다시 표지 함수에 넣는 방식은 형태가 행위와 다른 파괴 단어를 가질 때
    # 열리는 쪽으로 틀리므로 쓰지 않는다. 신고만 있는 파괴는 행위 전체를 담고
    # 떨어진 단어가 없는 행만 명시한다.
    pd_row=0
    if [ "$act_destructive" = "1" ]; then
      if [ -n "${GATE_MARK_TRIGGER:-}" ]; then
        for w in $shape; do
          [ "$w" = "$GATE_MARK_TRIGGER" ] && { pd_row=1; break; }
        done
      fi
    elif [ "$declared_only" = "1" ]; then
      [ "$nwords" = "$nf" ] && [ -z "$drop" ] && pd_row=1
    fi
    [ "$pd_row" = "1" ] && pd=1
    continue
  fi

  # 러너만 적힌 형태 — 기존 매니페스트가 계속 동작하도록 오늘의 접두 매칭을
  # 유지하되, 비파괴 행위에만 적용하고 lift 로는 세지 않는다.
  [ "$act_destructive" = "1" ] && continue
  case "$argv0 $sub" in
    $shape*) matched=1; any_runner=1; continue ;;
  esac
  case "$argv0" in
    $shape*) matched=1; any_runner=1 ;;
  esac
done < "$mf"

if [ "$probe" = "1" ]; then
  if [ "$any_full" = "1" ]; then matched_kind=완전
  elif [ "$any_runner" = "1" ]; then matched_kind=러너
  else matched_kind=없음; fi

  # 제안 — park 의 수리 문구가 붙여 넣을 행의 형태. 행위의 앞 L 단어이며, L 은 이
  # 행위를 덮는 최소 완전 형태의 길이와 칸이 요구하는 길이 중 가장 긴 것이다. 어떤
  # 행으로도 고칠 수 없으면 그 원인(`Sx`)을 내고 제안은 `-` 다.
  #
  # 최소 길이는 하위 명령(`sp`)과 그 피연산자까지 닿는다. 값을 받는 옵션의 목록을
  # 두지 않고 대시 단어는 모두 값을 받는다고 보아 다음 비대시 단어까지 건너뛰므로
  # (docker `run`·`create` 뒤의 값 없는 플래그는 그것 하나만), 틀리면 더 긴 행을
  # 제안하는 쪽으로만 틀린다. 피연산자가 없으면 행위 전체다. 옵션 이름이나 값에서
  # 끊긴 행(`cargo run --bin`)은 붙여 넣으면 형제 행위(`cargo run --bin wipe-db`)까지
  # 연다.
  sp_nx=$(printf '%s\n' "$norm" | awk '
    function nx(k,   j) {
      for (j = k + 1; j <= NF; j++) {
        if ($j ~ /^-/) {
          if (rc && j > rc && $j ~ /^(--rm|-d|--detach|-i|--interactive|-t|--tty|-it|-ti|--init|--privileged|--read-only|-P|--publish-all)$/) continue
          if (j < NF && $(j + 1) !~ /^-/) j++
          continue
        }
        return j
      }
      return NF
    }
    {
      rc = 0
      sp = nx(1)
      if (($1 == "docker" && $sp ~ /^(image|container|volume|network|node|service|secret|config|context|builder|buildx|manifest|plugin|system|compose|trust|swarm)$/) \
          || ($1 == "yarn" && $sp == "global")) sp = nx(sp)
      if ($1 == "docker" && ($sp == "run" || $sp == "create")) rc = sp
      print sp, nx(sp); exit
    }')
  sp=$(printf '%s\n' "$sp_nx" | awk '{ print $1; exit }'); [ -n "$sp" ] || sp=1
  nxs=$(printf '%s\n' "$sp_nx" | awk '{ print $2; exit }'); [ -n "$nxs" ] || nxs=0
  sx=ok; sw='-'; prop='-'
  case "$interps" in
    *" $argv0 "*)
      script_ok=0
      wop=$(word_at "$norm" "$operand_pos")
      case "$wop" in
        ''|-*|+*|/dev/stdin|/dev/fd/*|/proc/*/fd/*|'<('*) ;;
        *) closed_flags_only "$argv0" "$norm" "$operand_pos" && script_ok=1 ;;
      esac
      cmin=$operand_pos
      [ "$script_ok" = "1" ] || sx=code ;;
    *)
      case "$runners" in
        *" $argv0 "*) cmin=$((operand_pos + 1)); [ "$nxs" -gt "$cmin" ] && cmin=$nxs ;;
        *) cmin=2; [ "$sp" -gt "$cmin" ] && cmin=$sp ;;
      esac ;;
  esac
  L=2
  [ "$cmin" -gt "$L" ] && L=$cmin
  # 기기전역 칸에서 판단 없이 열리는 것은 축자 일치뿐이므로 그 칸의 제안은 행위 전체다 —
  # 러너의 2단어 행위(`make deploy`)처럼 완전 형태가 될 수 없는 행위도 축자 행으로는 열린다.
  # 한 단어 행위는 킥오프가 한 단어 형태를 거절하므로 행으로 고칠 수 없다.
  [ "${GATE_REACH_EFF:-}" = "기기전역" ] && { L=$nf; [ "$L" -ge 2 ] || L=2; }
  if [ "$act_destructive" = "1" ]; then
    # 표지가 있으면 그 트리거 단어까지. 트리거가 단어로 없으면 어떤 행도 명시할 수 없다.
    tpos=$(printf '%s\n' "$norm" | awk '{ for (k = 1; k <= NF; k++) if ($k == ENVIRON["GATE_MARK_TRIGGER"]) { print k; exit } }')
    [ -n "$tpos" ] || tpos=$((nf + 1))
    [ "$tpos" -gt "$L" ] && L=$tpos
  fi
  [ "$declared_only" = "1" ] && [ "$nf" -gt "$L" ] && L=$nf
  # 길이가 옵션 이름에서 끝나면 그 값까지 담는다.
  if [ "$L" -lt "$nf" ]; then
    case "$(word_at "$norm" "$L")" in
      -*) case "$(word_at "$norm" $((L + 1)))" in -*) ;; *) L=$((L + 1)) ;; esac ;;
    esac
  fi
  if [ "$sx" = "code" ]; then :
  elif [ "$L" -gt "$nf" ]; then sx=none
  else
    prop=$(printf '%s\n' "$norm" | awk -v n="$L" '{ for (k = 1; k <= n; k++) printf "%s%s", (k > 1 ? " " : ""), $k; print ""; exit }')
    case "$prop" in
      # `|` 는 매니페스트 행의 칸 구분자라 행이 그 단어를 담지 못한다.
      *'|'*) sx=none ;;
      *)
        last=$(word_at "$map" "$L")
        for d in $drop; do
          if [ "$d" -lt "$last" ] || [ "$declared_only" = "1" ]; then
            sx=dropped
            sw=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk -v p="$d" '{ print $p; exit }')
            break
          fi
        done
        # 기기전역 칸의 제안은 행위 전체라, 어디서 떨어졌든 떨어진 단어는 축자 행이 담지 못한다.
        if [ "$sx" = "ok" ] && [ "${GATE_REACH_EFF:-}" = "기기전역" ] && [ -n "$drop" ]; then
          sx=dropped
          sw=$(printf '%s' "$GATE_ARGV" | tr '\r\n' '  ' | awk -v p="${drop%% *}" '{ print $p; exit }')
        fi ;;
    esac
  fi
  [ "$sx" = "ok" ] || prop='-'

  echo "P=$matched 형태=$matched_kind Pd=$pd Pv=$pv Sx=$sx Sw=$sw 제안=$prop"
  exit 0
fi

if [ "$matched" = "1" ]; then
  exit 0
fi
echo "사전-인가-대조: '$argv0 $sub' is outside the preauthorization list — issuing an approval request" >&2
exit 5
