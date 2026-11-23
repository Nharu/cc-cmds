#!/usr/bin/env bash
# lint-countermeasure-records — every countermeasure the tree can detect is
# recorded, exempted or baselined, and every record keeps its form.
#
# The protocol is scripts/countermeasure-protocol.md; the records live in
# scripts/countermeasure-records.md. A countermeasure is detected as a file in
# one of three branches:
#   린트       scripts/lint-*.sh
#   훅         every `${CLAUDE_PLUGIN_ROOT}/<path>` named by a command of
#              plugins/cc-cmds/hooks/hooks.json, read as plugins/cc-cmds/<path>
#              (the same derivation the Makefile `lint` recipe uses)
#   게이트 룰  plugins/cc-cmds/orchestrator/rules/*.rule
#
# Every detected path stands in exactly one place: the `**위치**` of a record
# whose `**판정**` is not `폐기`, the exemption list (`## 대책 아닌 감지 파일`),
# or the baseline (scripts/lint-countermeasure-records.baseline). The baseline
# holds what was in the tree before the protocol arrived; it only shrinks, and
# this script has no option that rewrites it — such an option would make
# baselining a new countermeasure one command.
#
# Assertions, each reported as one `FAIL: [단언 N] …` line on stderr:
#   1  every detected path stands in exactly one of record, exemption, baseline
#   2  every baseline line is a detected path
#   3  every exemption line is a detected path with a reason
#   4  every record has the required fields; 종류, 상태 and 판정 are in their
#      closed vocabularies
#   5  the 위치 of a record not retired exists, and its anchor is in that file
#   6  the pointers of 막을 사례 and 이웃 사례 are alive; a directory pointer
#      carries no anchor; a 린트, 훅 or 게이트 룰 record points at a test in
#      each column (a path under tests/fixtures/ or a scripts/test-*.sh); the
#      same pointer is not in both columns
#   7  a record whose 위치 is a detected path has that path's branch as 종류
#   8  a 상태 of 세션에 로드됨 or above is measured where it can be (a lint's
#      `bash <path>` inside the Makefile `lint:` recipe, a hook's entry in
#      hooks.json, a rule's checker beside it) and carries a 상태 근거 where it
#      cannot; 실제로 쓰임 and 효과 확인됨 carry a 상태 근거 that starts with a date
#   9  a 판정 other than 미판정 carries a 판정 근거 that starts with a date
#   10 the four cost fields are present, each `미측정` or holding a date
#
# A retired record (`**판정**: 폐기`) goes with the deletion of its file, so the
# location, pointer liveness, test pointer and load measurement checks (5, 6
# and 8) do not read it; assertions 4, 9 and 10 still do.
#
# Exit: 0 clean, 1 on any violation, 2 when the registry or hooks.json cannot be
# read or jq is missing. CM_ROOT overrides the root every path is resolved
# under (default: the repository root). bash 3.2: no associative arrays, no
# mapfile.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
ROOT=${CM_ROOT:-$(cd "$script_dir/.." && pwd)}
REG="$ROOT/scripts/countermeasure-records.md"
BASELINE="$ROOT/scripts/lint-countermeasure-records.baseline"
HOOKS_JSON="$ROOT/plugins/cc-cmds/hooks/hooks.json"
MAKEFILE="$ROOT/Makefile"
RULES_DIR="$ROOT/plugins/cc-cmds/orchestrator/rules"

UNSET=$'\001'
NFIELD=13
PLUGIN_PREFIX='${CLAUDE_PLUGIN_ROOT}/'
re_field='^\*\*([^*]+)\*\*: (.*)$'
re_exempt='^- `([^`]*)`(.*)$'
re_loc='^`([^`]+)`$'
re_date='^[0-9]{4}-[0-9]{2}-[0-9]{2}'
re_has_date='[0-9]{4}-[0-9]{2}-[0-9]{2}'

fails=0
fail() {
  fails=$((fails + 1))
  printf 'FAIL: [단언 %s] %s\n' "$1" "$2" >&2
}

# field_index <key> — sets ki to the slot of a record field; 1 when unknown.
field_index() {
  case "$1" in
    '종류') ki=0 ;;
    '위치') ki=1 ;;
    '막을 사례') ki=2 ;;
    '이웃 사례') ki=3 ;;
    '우회 경로') ki=4 ;;
    '오차단') ki=5 ;;
    '재시도') ki=6 ;;
    '사람 개입') ki=7 ;;
    '유지 보수') ki=8 ;;
    '상태') ki=9 ;;
    '상태 근거') ki=10 ;;
    '판정') ki=11 ;;
    '판정 근거') ki=12 ;;
    *) return 1 ;;
  esac
  return 0
}

# fv <record> <slot> — sets v to the field value (UNSET when absent).
fv() {
  v=${rec_f[$(( $1 * NFIELD + $2 ))]}
}

# det_add <path> <branch> — add a detected path once.
det_add() {
  local i=0
  while [ "$i" -lt "${#det_path[@]}" ]; do
    [ "${det_path[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  det_path[${#det_path[@]}]=$1
  det_kind[${#det_kind[@]}]=$2
}

# det_lookup <path> — sets dk to the branch of a detected path; 1 when not one.
det_lookup() {
  local i=0
  dk=''
  while [ "$i" -lt "${#det_path[@]}" ]; do
    if [ "${det_path[$i]}" = "$1" ]; then
      dk=${det_kind[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# parse_pointer <text> — split one pointer `<path>[#<anchor>]` into pp, pa and
# ph (1 when an anchor is present).
parse_pointer() {
  case "$1" in
    *'#'*) pp=${1%%'#'*}; pa=${1#*'#'}; ph=1 ;;
    *) pp=$1; pa=''; ph=0 ;;
  esac
}

# pointer_alive — 0 when the pointer in pp/pa/ph resolves under ROOT.
pointer_alive() {
  [ -n "$pp" ] || return 1
  case "$pp" in
    */)
      [ "$ph" = 0 ] || return 1
      [ -d "$ROOT/$pp" ] || return 1
      ;;
    *)
      [ -f "$ROOT/$pp" ] || return 1
      if [ "$ph" = 1 ]; then
        [ -n "$pa" ] || return 1
        LC_ALL=C grep -qF -- "$pa" "$ROOT/$pp" || return 1
      fi
      ;;
  esac
  return 0
}

# is_test_path <path> — a path under tests/fixtures/ or a scripts/test-*.sh.
is_test_path() {
  case "$1" in
    tests/fixtures/?*) return 0 ;;
    scripts/test-*.sh)
      case "${1#scripts/}" in */*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

# column_pointers <value> — sets cps to the pointers of one case column, one
# per line, and cbad to the items whose backtick is never closed.
column_pointers() {
  local rest item inner after last=0
  cps=''
  cbad=''
  rest=$1
  while [ "$last" = 0 ]; do
    case "$rest" in
      *'; '*) item=${rest%%'; '*}; rest=${rest#*'; '} ;;
      *) item=$rest; last=1 ;;
    esac
    case "$item" in
      '`'*)
        item=${item#'`'}
        case "$item" in
          *'`'*)
            inner=${item%%'`'*}
            after=${item#*'`'}
            case "$after" in
              ''|' — '*) cps="${cps}${inner}"$'\n' ;;
              *) cbad="${cbad}${inner}"$'\n' ;;
            esac
            ;;
          *) cbad="${cbad}${item}"$'\n' ;;
        esac
        ;;
    esac
  done
}

# recipe_registers <path> — 0 when the Makefile `lint:` recipe runs
# `bash <path>` on a line that is not a comment, as whole words.
recipe_registers() {
  case "$recipe" in
    *" bash $1 "*|*" bash $1\\"*) return 0 ;;
  esac
  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "lint-countermeasure-records: jq 가 없어 hooks.json 을 읽을 수 없다" >&2
  exit 2
fi
if [ ! -f "$REG" ] || [ ! -r "$REG" ]; then
  echo "lint-countermeasure-records: 등록부를 읽을 수 없다: ${REG}" >&2
  exit 2
fi
if [ ! -f "$HOOKS_JSON" ] || [ ! -r "$HOOKS_JSON" ]; then
  echo "lint-countermeasure-records: hooks.json 을 읽을 수 없다: ${HOOKS_JSON}" >&2
  exit 2
fi
if ! hook_cmds=$(jq -r '.hooks[][].hooks[].command' "$HOOKS_JSON" 2>/dev/null); then
  echo "lint-countermeasure-records: hooks.json 의 command 를 읽을 수 없다: ${HOOKS_JSON}" >&2
  exit 2
fi

# ---- detection set -----------------------------------------------------------
det_path=()
det_kind=()
for f in "$ROOT"/scripts/lint-*.sh; do
  [ -f "$f" ] || continue
  det_add "scripts/${f##*/}" '린트'
done
hook_refs=$(printf '%s\n' "$hook_cmds" | grep -oE '[$][{]CLAUDE_PLUGIN_ROOT[}]/[^" ]+' || true)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  det_add "plugins/cc-cmds/${p#"$PLUGIN_PREFIX"}" '훅'
done <<EOF
$hook_refs
EOF
for f in "$RULES_DIR"/*.rule; do
  [ -f "$f" ] || continue
  det_add "plugins/cc-cmds/orchestrator/rules/${f##*/}" '게이트 룰'
done

# ---- baseline ----------------------------------------------------------------
base_path=()
if [ -f "$BASELINE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    base_path[${#base_path[@]}]=$line
  done < "$BASELINE"
fi

# ---- registry ----------------------------------------------------------------
rec_name=()
rec_f=()
nrec=0
ex_path=()
ex_reason=()
section=''
cur=-1
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    '## '*) section=${line#'## '}; cur=-1; continue ;;
  esac
  case "$section" in
    '기록')
      case "$line" in
        '### '*)
          cur=$nrec
          nrec=$((nrec + 1))
          rec_name[$cur]=${line#'### '}
          k=0
          while [ "$k" -lt "$NFIELD" ]; do
            rec_f[$((cur * NFIELD + k))]=$UNSET
            k=$((k + 1))
          done
          continue
          ;;
      esac
      [ "$cur" -ge 0 ] || continue
      if [[ $line =~ $re_field ]]; then
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        if field_index "$key" && [ -n "$val" ]; then
          rec_f[$((cur * NFIELD + ki))]=$val
        fi
      fi
      ;;
    '대책 아닌 감지 파일')
      case "$line" in '- '*) ;; *) continue ;; esac
      if [[ $line =~ $re_exempt ]]; then
        epath=${BASH_REMATCH[1]}
        eafter=${BASH_REMATCH[2]}
        ereason=''
        case "$eafter" in ' — '*) ereason=${eafter#' — '} ;; esac
        ereason=$(printf '%s' "$ereason" | tr -d ' \t')
        ex_path[${#ex_path[@]}]=$epath
        ex_reason[${#ex_reason[@]}]=$ereason
      else
        fail 3 "면제 목록 줄의 꼴이 \`- \`<경로>\` — <사유>\` 가 아니다: ${line}"
      fi
      ;;
  esac
done < "$REG"

# ---- the Makefile lint recipe ------------------------------------------------
# The recipe starts on the line after `lint:` and ends right before the first
# line that starts in column 0 and is neither a `#` comment nor empty — the
# next target. Comment lines inside it are dropped and whitespace runs folded,
# so each kept line reads ` <words> ` for whole-word matching.
recipe=''
if [ -f "$MAKEFILE" ]; then
  recipe=$(awk '
    !inr && /^lint:/ { inr = 1; next }
    inr {
      if ($0 ~ /^[^ \t#]/) exit
      if ($0 ~ /^[ \t]*#/) next
      gsub(/[ \t]+/, " ")
      print " " $0 " "
    }' "$MAKEFILE")
fi

# ---- per-record location -----------------------------------------------------
rec_lpath=()
rec_lanchor=()
rec_lhas=()
rec_lok=()
r=0
while [ "$r" -lt "$nrec" ]; do
  fv "$r" 1
  rec_lpath[$r]=''
  rec_lanchor[$r]=''
  rec_lhas[$r]=0
  rec_lok[$r]=0
  if [ "$v" != "$UNSET" ] && [[ $v =~ $re_loc ]]; then
    parse_pointer "${BASH_REMATCH[1]}"
    rec_lpath[$r]=$pp
    rec_lanchor[$r]=$pa
    rec_lhas[$r]=$ph
    [ -n "$pp" ] && rec_lok[$r]=1
  fi
  r=$((r + 1))
done

# ---- assertion 1: exactly one place per detected path -------------------------
i=0
while [ "$i" -lt "${#det_path[@]}" ]; do
  d=${det_path[$i]}
  cnt=0
  r=0
  while [ "$r" -lt "$nrec" ]; do
    fv "$r" 11
    if [ "$v" != '폐기' ] && [ "${rec_lok[$r]}" = 1 ] && [ "${rec_lpath[$r]}" = "$d" ]; then
      cnt=$((cnt + 1))
    fi
    r=$((r + 1))
  done
  j=0
  while [ "$j" -lt "${#ex_path[@]}" ]; do
    [ "${ex_path[$j]}" = "$d" ] && cnt=$((cnt + 1))
    j=$((j + 1))
  done
  j=0
  while [ "$j" -lt "${#base_path[@]}" ]; do
    [ "${base_path[$j]}" = "$d" ] && cnt=$((cnt + 1))
    j=$((j + 1))
  done
  if [ "$cnt" -eq 0 ]; then
    fail 1 "기록 없는 새 대책: ${d} (${det_kind[$i]}) — scripts/countermeasure-records.md 에 기록을 더하거나, 대책이 아니면 면제 목록에 사유와 함께 적는다"
  elif [ "$cnt" -gt 1 ]; then
    fail 1 "중복: ${d} 가 기록·면제 목록·기준선에 ${cnt} 번 나온다 — 정확히 한 곳이어야 한다"
  fi
  i=$((i + 1))
done

# ---- assertion 2: baseline lines are detected paths ---------------------------
j=0
while [ "$j" -lt "${#base_path[@]}" ]; do
  if ! det_lookup "${base_path[$j]}"; then
    fail 2 "기준선 줄이 감지 집합에 없다: ${base_path[$j]} — 지워졌거나 옮겨진 경로의 줄은 같은 변경에서 지우거나 새 경로로 바꿔 적는다"
  fi
  j=$((j + 1))
done

# ---- assertion 3: exemption lines ---------------------------------------------
j=0
while [ "$j" -lt "${#ex_path[@]}" ]; do
  if ! det_lookup "${ex_path[$j]}"; then
    fail 3 "면제 목록 줄이 감지 집합에 없다: ${ex_path[$j]}"
  fi
  if [ -z "${ex_reason[$j]}" ]; then
    fail 3 "면제 목록 줄에 사유가 없다: ${ex_path[$j]}"
  fi
  j=$((j + 1))
done

# ---- per-record assertions 4–10 ------------------------------------------------
r=0
while [ "$r" -lt "$nrec" ]; do
  name=${rec_name[$r]}

  # 4: required fields and closed vocabularies
  missing=''
  for k in 0 1 2 3 4 5 6 7 8 9 11; do
    fv "$r" "$k"
    if [ "$v" = "$UNSET" ]; then
      case "$k" in
        0) missing="${missing} 종류" ;;
        1) missing="${missing} 위치" ;;
        2) missing="${missing} 막을 사례" ;;
        3) missing="${missing} 이웃 사례" ;;
        4) missing="${missing} 우회 경로" ;;
        5) missing="${missing} 오차단" ;;
        6) missing="${missing} 재시도" ;;
        7) missing="${missing} 사람 개입" ;;
        8) missing="${missing} 유지 보수" ;;
        9) missing="${missing} 상태" ;;
        11) missing="${missing} 판정" ;;
      esac
    fi
  done
  [ -z "$missing" ] || fail 4 "기록 「${name}」 에 필수 필드가 없다:${missing}"
  fv "$r" 0
  kind=$v
  case "$kind" in
    "$UNSET"|'린트'|'훅'|'게이트 룰'|'프롬프트 조항') ;;
    *) fail 4 "기록 「${name}」 의 종류가 닫힌 어휘 밖이다: ${kind}" ;;
  esac
  fv "$r" 9
  state=$v
  case "$state" in
    "$UNSET"|'문서에 있음'|'세션에 로드됨'|'실제로 쓰임'|'효과 확인됨') ;;
    *) fail 4 "기록 「${name}」 의 상태가 닫힌 어휘 밖이다: ${state}" ;;
  esac
  fv "$r" 11
  verdict=$v
  case "$verdict" in
    "$UNSET"|'미판정'|'채택'|'수정'|'폐기') ;;
    *) fail 4 "기록 「${name}」 의 판정이 닫힌 어휘 밖이다: ${verdict}" ;;
  esac

  lpath=${rec_lpath[$r]}
  retired=0
  [ "$verdict" = '폐기' ] && retired=1

  # 5: the location of a record not retired
  fv "$r" 1
  if [ "$retired" = 0 ] && [ "$v" != "$UNSET" ]; then
    if [ "${rec_lok[$r]}" != 1 ]; then
      fail 5 "기록 「${name}」 의 위치가 백틱으로 감싼 경로 하나가 아니다: ${v}"
    elif [ ! -e "$ROOT/$lpath" ]; then
      fail 5 "기록 「${name}」 의 위치 경로가 없다: ${lpath}"
    elif [ "${rec_lhas[$r]}" = 1 ]; then
      if [ ! -f "$ROOT/$lpath" ] || [ -z "${rec_lanchor[$r]}" ] \
         || ! LC_ALL=C grep -qF -- "${rec_lanchor[$r]}" "$ROOT/$lpath"; then
        fail 5 "기록 「${name}」 의 위치 앵커가 파일에 없다: ${lpath}#${rec_lanchor[$r]}"
      fi
    fi
  fi

  # 6: case pointers
  needs_test=0
  case "$kind" in '린트'|'훅'|'게이트 룰') needs_test=1 ;; esac
  fv "$r" 2
  col_block=$v
  fv "$r" 3
  col_nbr=$v
  block_ptrs=''
  for slot in 2 3; do
    if [ "$slot" = 2 ]; then cv=$col_block; cname='막을 사례'; else cv=$col_nbr; cname='이웃 사례'; fi
    [ "$cv" != "$UNSET" ] || continue
    column_pointers "$cv"
    if [ "$retired" = 0 ]; then
      while IFS= read -r bad_item; do
        [ -n "$bad_item" ] || continue
        fail 6 "기록 「${name}」 의 ${cname} 가리킴의 꼴이 깨졌다: ${bad_item}"
      done <<EOF
$cbad
EOF
    fi
    has_test=0
    while IFS= read -r ptr; do
      [ -n "$ptr" ] || continue
      parse_pointer "$ptr"
      if [ "$slot" = 2 ]; then
        block_ptrs="${block_ptrs}${ptr}"$'\n'
      else
        case $'\n'"$block_ptrs" in
          *$'\n'"$ptr"$'\n'*)
            fail 6 "기록 「${name}」 의 같은 가리킴이 막을 사례와 이웃 사례에 함께 있다: ${ptr}" ;;
        esac
      fi
      [ "$retired" = 0 ] || continue
      case "$pp" in
        */)
          if [ "$ph" = 1 ]; then
            fail 6 "기록 「${name}」 의 ${cname} 디렉터리 가리킴에 앵커가 붙었다: ${ptr}"
            continue
          fi
          ;;
      esac
      if ! pointer_alive; then
        fail 6 "기록 「${name}」 의 ${cname} 가리킴이 죽었다: ${ptr}"
        continue
      fi
      is_test_path "$pp" && has_test=1
    done <<EOF
$cps
EOF
    if [ "$retired" = 0 ] && [ "$needs_test" = 1 ] && [ "$has_test" = 0 ]; then
      fail 6 "기록 「${name}」 (${kind}) 의 ${cname} 에 시험을 가리키는 가리킴이 없다 — tests/fixtures/ 아래나 scripts/test-*.sh 를 가리킨다"
    fi
  done

  # 7: kind matches the detection branch
  if [ "${rec_lok[$r]}" = 1 ] && [ "$kind" != "$UNSET" ] && det_lookup "$lpath"; then
    if [ "$kind" != "$dk" ]; then
      fail 7 "기록 「${name}」 의 종류 ${kind} 가 위치 ${lpath} 의 감지 갈래 ${dk} 와 다르다"
    fi
  fi

  # 8: state measurement and evidence
  fv "$r" 10
  state_ev=$v
  if [ "$retired" = 0 ]; then
    case "$state" in
      '세션에 로드됨'|'실제로 쓰임'|'효과 확인됨')
        case "$kind" in
          '린트')
            if [ "${rec_lok[$r]}" != 1 ] || ! recipe_registers "$lpath"; then
              fail 8 "기록 「${name}」 이 ${state} 인데 Makefile 의 lint: 레시피에 bash ${lpath} 등록이 없다"
            fi
            ;;
          '훅')
            if ! { det_lookup "$lpath" && [ "$dk" = '훅' ]; }; then
              if [ "$state_ev" = "$UNSET" ]; then
                fail 8 "기록 「${name}」 은 hooks.json 밖의 훅이라 잴 수 없는데 ${state} 의 상태 근거가 없다"
              fi
            fi
            ;;
          '게이트 룰')
            case "$lpath" in
              *.rule) checker="${lpath%.rule}.sh" ;;
              *) checker='' ;;
            esac
            if [ -z "$checker" ] || [ ! -f "$ROOT/$checker" ]; then
              fail 8 "기록 「${name}」 이 ${state} 인데 같은 이름의 검사기 .sh 가 곁에 없다: ${lpath}"
            fi
            ;;
          '프롬프트 조항')
            if [ "$state_ev" = "$UNSET" ]; then
              fail 8 "기록 「${name}」 은 잴 수 없는 종류인데 ${state} 의 상태 근거가 없다"
            fi
            ;;
        esac
        ;;
    esac
    case "$state" in
      '실제로 쓰임'|'효과 확인됨')
        if [ "$state_ev" = "$UNSET" ] || ! [[ $state_ev =~ $re_date ]]; then
          fail 8 "기록 「${name}」 이 ${state} 인데 날짜로 시작하는 상태 근거가 없다"
        fi
        ;;
    esac
  fi

  # 9: verdict evidence
  case "$verdict" in
    "$UNSET"|'미판정') ;;
    *)
      fv "$r" 12
      if [ "$v" = "$UNSET" ] || ! [[ $v =~ $re_date ]]; then
        fail 9 "기록 「${name}」 의 판정이 ${verdict} 인데 날짜로 시작하는 판정 근거가 없다"
      fi
      ;;
  esac

  # 10: cost fields
  for k in 5 6 7 8; do
    case "$k" in
      5) cn='오차단' ;;
      6) cn='재시도' ;;
      7) cn='사람 개입' ;;
      8) cn='유지 보수' ;;
    esac
    fv "$r" "$k"
    if [ "$v" = "$UNSET" ]; then
      fail 10 "기록 「${name}」 에 운영 비용 칸 ${cn} 이 없다"
    elif [ "$v" != '미측정' ] && ! [[ $v =~ $re_has_date ]]; then
      fail 10 "기록 「${name}」 의 ${cn} 값이 미측정도 아니고 날짜도 없다: ${v}"
    fi
  done

  r=$((r + 1))
done

if [ "$fails" -gt 0 ]; then
  echo "lint-countermeasure-records: 위반 ${fails} 건" >&2
  exit 1
fi
echo "lint-countermeasure-records: ok — 감지 ${#det_path[@]} 개, 기록 ${nrec} 개, 면제 ${#ex_path[@]} 개, 기준선 ${#base_path[@]} 줄"
exit 0
