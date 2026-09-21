#!/usr/bin/env bash
# collect-run-metrics.sh — 종단한 런의 계측을 모아 요약·저널을 쓰고 트리거를 낸다.
#
# 용도. 레포별 원장 디렉터리(`<base>/docs/pipeline-run/`)의 런 원장을 훑어, 종단한
# 런마다 스테이지 전사·스트림 로그에서 압축 기록·요청 사용량·벽시계를 읽고, 다섯
# 집계(캐시 적중률 · 요청당 컨텍스트 · 압축 횟수와 버린 토큰 · 스테이지 비용 · P0 와
# 벽시계)를 `(종류, 종단 부류, 레인)` 층으로 낸다. 트리거 일곱은 이 회차에 처음
# 수집된 런의 행에만 걸고, 그 결과를 저널 한 줄로 낸다 — 게이트가 그 줄을 읽어 이슈를
# 등록·코멘트·닫기 한다. 이 스크립트 자신은 `gh` 를 부르지 않는다.
#
# 입력.
#   --ledger-dir <dir>        런 원장 디렉터리(필수). 이름이 `<8자리>-<8hex>.md` 인
#                             파일만 원장이다 — `.interview.md`·`.plan.md`·`metrics*`
#                             는 제외.
#   --state-root <dir>        런 디렉터리 `run/<run-id>` 가 있는 상태 루트
#                             (기본 `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds`).
#   --config-home <dir>...    전사를 찾을 CLI 설정 홈. 하나도 주지 않으면 축자 셋
#                             `$HOME/.claude`·`$HOME/.claude-cc`·`$HOME/.claude-cci`.
#                             접두 글롭은 쓰지 않으므로 백업 디렉터리는 들어오지 않는다.
#   --journal <path>          추가 전용 회차 저널
#                             (기본 `<상태 루트>/metrics/<repo-key>/rounds.jsonl`).
#   --now <epoch>             저널 시각(시험용 주입).
#   --switch-window <초>      계정 전환 직후 제외 구간의 폭(기본 900, 환경변수
#                             `CC_METRICS_SWITCH_WINDOW_S` 로도 지정). 미확정 기본값이며
#                             요약의 `switch_window_s` 가 쓰인 값을 인쇄한다.
#   --recollect               이미 있는 런별 기록도 다시 만든다(시험용).
#
# 출력.
#   <ledger-dir>/metrics.json              요약(`jq -S`, 시각 없음 — 같은 입력이면 같은 바이트)
#   <ledger-dir>/metrics.json.pending      회차 시작 표지. 정상 종료가 지운다.
#   <ledger-dir>/metrics/<run-id>.json     런별 수집 기록(멱등 — 있으면 다시 만들지 않는다)
#   <저널>                                 회차마다 한 줄 JSON 추가. 회차 수·연속 수·시각은
#                                          여기에만 있다.
#   stdout                                 그 회차의 저널 줄 한 줄. stderr 에는 진단만.
#
# 종료 코드. 0 회차 기록됨 · 2 인자 오류 · 3 입력 디렉터리 없음.
#
# 판독 규칙. 성공·실패는 원장의 `종단 부류` 로만 판정한다 — 스트림 result 줄의
# `subtype`·`is_error` 는 전수가 성공이라고 말하면서 그중 일부가 오류 플래그를 다는
# 값이라 어느 판정에도 쓰지 않는다. 요청은 `message.id` 로 중복 제거해 첫 것만 센다.
# 같은 세션 id 의 행이 여럿이면 전사는 한 번만 연다. `실행 버전` 은 값이 숫자일 때만
# 시도 번호다. 압축 기록은 줄을 파싱해 판정하고 메타데이터 철자 둘을 모두 안다.
#
# 호환. bash 3.2 — 연관 배열·mapfile 없음. 수치 계산은 전부 jq 가 한다.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
. "$script_dir/liveness.sh"

cm_usage() {
  printf 'usage: collect-run-metrics.sh --ledger-dir <dir> [--state-root <dir>] [--config-home <dir>]... [--journal <path>] [--now <epoch>] [--switch-window <초>] [--recollect]\n' >&2
}

cm_diag() { printf 'collect-run-metrics: %s\n' "$*" >&2; }

# --- 인자 ------------------------------------------------------------------

CM_LEDGER_DIR=""
CM_STATE_ROOT=""
CM_HOMES=""
CM_JOURNAL=""
CM_NOW=""
CM_SWITCH_WINDOW="${CC_METRICS_SWITCH_WINDOW_S:-900}"
CM_RECOLLECT=0

cm_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger-dir)    [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_LEDGER_DIR="$2"; shift 2 ;;
      --state-root)    [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_STATE_ROOT="$2"; shift 2 ;;
      --config-home)   [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_HOMES="$CM_HOMES
$2"; shift 2 ;;
      --journal)       [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_JOURNAL="$2"; shift 2 ;;
      --now)           [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_NOW="$2"; shift 2 ;;
      --switch-window) [ $# -ge 2 ] || { cm_usage; exit 2; }; CM_SWITCH_WINDOW="$2"; shift 2 ;;
      --recollect)     CM_RECOLLECT=1; shift ;;
      -h|--help)       cm_usage; exit 2 ;;
      *) cm_diag "알 수 없는 인자: $1"; cm_usage; exit 2 ;;
    esac
  done
  [ -n "$CM_LEDGER_DIR" ] || { cm_usage; exit 2; }
  case "$CM_SWITCH_WINDOW" in
    ''|*[!0-9]*) cm_diag "--switch-window 는 초 단위 정수여야 한다: '$CM_SWITCH_WINDOW'"; exit 2 ;;
  esac
  if [ -n "$CM_NOW" ]; then
    case "$CM_NOW" in
      *[!0-9]*) cm_diag "--now 는 epoch 초여야 한다: '$CM_NOW'"; exit 2 ;;
    esac
  else
    CM_NOW=$(date -u +%s)
  fi
  [ -d "$CM_LEDGER_DIR" ] || { cm_diag "원장 디렉터리가 없다: $CM_LEDGER_DIR"; exit 3; }
  CM_LEDGER_DIR=$(cd "$CM_LEDGER_DIR" && pwd)
  [ -n "$CM_STATE_ROOT" ] || CM_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds"
  if [ -z "$CM_HOMES" ]; then
    CM_HOMES="$HOME/.claude
$HOME/.claude-cc
$HOME/.claude-cci"
  fi
  # repo-key 는 원장 디렉터리의 부모(레포 베이스) 절대 경로의 `/` 를 `-` 로 바꾼 것 —
  # 전사 슬러그와 같은 규칙.
  CM_REPO=$(cd "$CM_LEDGER_DIR/.." && pwd)
  CM_REPO_KEY=$(printf '%s' "$CM_REPO" | tr '/' '-')
  [ -n "$CM_JOURNAL" ] || CM_JOURNAL="$CM_STATE_ROOT/metrics/$CM_REPO_KEY/rounds.jsonl"
}

# --- 원장 판독 --------------------------------------------------------------

cm_ledger_rows() {
  # cm_ledger_rows <원장> <계열> — `- \`<계열>\` | ` 로 시작하는 줄만. 산문·헤더·빈 줄은
  # 행이 아니다.
  sed -n "/^- \`$2\` | /p" "$1" 2>/dev/null || true
}

cm_field() {
  # cm_field <행> <키> — 마지막 등장의 값. 중복 키 행(`id=S1 | id=S1`)이 실재한다.
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^ *$2=//p" | sed 's/[[:space:]]*$//' | tail -1
}

cm_has_field() {
  # cm_has_field <행> <키> — 키의 존재. 값이 `-` 인 것과 키 자체가 없는 것은 다른 관측이다.
  printf '%s' "$1" | tr '|' '\n' | grep -c "^ *$2=" >/dev/null 2>&1
}

cm_window_ok() {
  # cm_window_ok <값> — `압축 창` 문법 안인가.
  case "$1" in
    -|"(꺼짐)"|"(미상)") return 0 ;;
  esac
  printf '%s' "$1" | grep -qE '^[0-9]+\((argv|런설정|프로젝트|레인)\)$'
}

cm_window_int() {
  # cm_window_int <값> — 정수형이면 그 정수, 아니면 빈 문자열.
  printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\)(.*)$/\1/p'
}

cm_window_source() {
  printf '%s' "$1" | sed -n 's/^[0-9][0-9]*(\(.*\))$/\1/p'
}

# --- 스트림 로그 ---------------------------------------------------------------

cm_stream_of() {
  # cm_stream_of <런 디렉터리> <스테이지> <시도> — 시도 스코프 이름이 있으면 그것, 없으면
  # 평문 폴백. 파일이 없으면 빈 문자열.
  local rd="$1" st="$2" at="$3"
  if [ -n "$at" ] && [ -f "$rd/log/$st#$at.json" ]; then
    printf '%s' "$rd/log/$st#$at.json"; return 0
  fi
  if [ -f "$rd/log/$st.json" ]; then printf '%s' "$rd/log/$st.json"; return 0; fi
  printf ''
}

cm_stream_result() {
  # cm_stream_result <파일> — `{complete, truncated, cost_usd, duration_ms, session_id}`.
  # 종단 줄은 `type=result` 줄들 중 `result_index` 최댓값(없으면 마지막 것). 마지막 줄이
  # JSON 이 아니면 `truncated` — 성공으로 읽지 않는다. `subtype`·`is_error` 는 읽지 않는다.
  local f="$1" trunc=false last
  if [ -z "$f" ]; then
    printf '{"complete":false,"truncated":false,"cost_usd":null,"duration_ms":null,"session_id":""}'
    return 0
  fi
  last=$(tail -n 1 "$f" 2>/dev/null || true)
  if [ -n "$last" ] && ! printf '%s' "$last" | jq -e . >/dev/null 2>&1; then trunc=true; fi
  jq -Rn --argjson trunc "$trunc" '
    [inputs | fromjson? | select(.type == "result")] as $rs
    | (if ($rs | length) == 0 then null
       elif ($rs | map(.result_index? // null) | any(. != null)) then ($rs | max_by(.result_index // -1))
       else $rs[-1] end) as $r
    | {complete: ($r != null), truncated: $trunc,
       cost_usd: ($r.total_cost_usd // null), duration_ms: ($r.duration_ms // null),
       session_id: ($r.session_id // "")}' "$f" 2>/dev/null \
    || printf '{"complete":false,"truncated":%s,"cost_usd":null,"duration_ms":null,"session_id":""}' "$trunc"
}

# --- 전사 -----------------------------------------------------------------------

cm_transcripts() {
  # cm_transcripts <세션 id> — 메인 전사와 그 옆 `subagents/` 아래의 모든 `.jsonl`(깊이
  # 제한 없음). 설정 홈은 축자 열거이므로 `~/.claude.bak` 같은 이웃은 들어오지 않는다.
  local sid="$1" home main sub
  [ -n "$sid" ] || return 0
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    [ -d "$home/projects" ] || continue
    while IFS= read -r main; do
      [ -n "$main" ] || continue
      printf '%s\n' "$main"
      sub="${main%.jsonl}/subagents"
      if [ -d "$sub" ]; then
        find "$sub" -type f -name '*.jsonl' 2>/dev/null | LC_ALL=C sort
      fi
    done <<MAINS
$(find "$home/projects" -mindepth 2 -maxdepth 2 -type f -name "$sid.jsonl" 2>/dev/null | LC_ALL=C sort)
MAINS
  done <<HOMES
$CM_HOMES
HOMES
}

cm_scan_session() {
  # cm_scan_session <전사 파일…> — 압축 기록·요청·시각 범위 하나의 JSON. 줄 단위로 읽고
  # JSON 이 아닌 줄(잘린 꼬리)은 건너뛴다. 요청은 `message.id` 첫 등장만 남긴다.
  jq -Rn '
    reduce (inputs | fromjson? | objects) as $l (
      {b: [], r: [], seen: {}, tmin: null, tmax: null};
      (if ($l.timestamp? // null) != null then
         .tmin = (if .tmin == null or $l.timestamp < .tmin then $l.timestamp else .tmin end)
         | .tmax = (if .tmax == null or $l.timestamp > .tmax then $l.timestamp else .tmax end)
       else . end)
      | if $l.type == "system" and $l.subtype == "compact_boundary" then
          .b += [{ts: ($l.timestamp // null), sid: ($l.sessionId // ""), agent: ($l.agentId // ""),
                  meta: ($l.compactMetadata // $l.compact_metadata // null)}]
        elif $l.type == "assistant" and (($l.message.id? // null) != null) then
          if .seen[$l.message.id] then . else
            .seen[$l.message.id] = true
            | .r += [{id: $l.message.id, ts: ($l.timestamp // null),
                      input: ($l.message.usage.input_tokens // 0),
                      creation: ($l.message.usage.cache_creation_input_tokens // 0),
                      read: ($l.message.usage.cache_read_input_tokens // 0)}]
          end
        else . end
    ) | del(.seen)' "$@"
}

cm_switch_windows() {
  # cm_switch_windows <원장> — `교대 기동 | 사유=상한` 행의 `기록 시각` 부터 폭만큼의
  # 구간을 `[[시작, 끝], …]`(epoch) 로. 전환 시각의 출처는 이 행 하나다.
  local row t rows=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(cm_field "$row" '사유')" = "상한" ] || continue
    t=$(cm_field "$row" '기록 시각')
    [ -n "$t" ] || continue
    rows="$rows
$t"
  done <<ROWS
$(cm_ledger_rows "$1" '교대 기동')
ROWS
  printf '%s\n' "$rows" | jq -R -s --argjson w "$CM_SWITCH_WINDOW" '
    split("\n") | map(select(length > 0))
    | map(sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null)
    | map(select(. != null)) | map([., . + $w])'
}

# 스테이지 하나의 세션 자료를 파생 필드까지 펼치는 jq 프로그램. 인자: $win(정수 창 또는
# null), $sw(전환 구간 배열), $dup(같은 세션의 앞 행이 이미 전사를 소비했으면 true).
CM_JQ_STAGE='
def ep: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) end;
def median: if length == 0 then null else (sort | if length % 2 == 1 then .[((length - 1) / 2)] else ((.[length / 2 - 1] + .[length / 2]) / 2) end) end;
def pct($q): if length == 0 then null else (sort | .[(((length * $q) | ceil) - 1) | if . < 0 then 0 else . end]) end;
def in_switch($t): ($t != null) and any($sw[]; $t >= .[0] and $t < .[1]);
(if $dup then {b: [], r: [], tmin: null, tmax: null} else . end) as $s
| ($s.r | sort_by(.ts)) as $reqs
| ($s.b | sort_by(.ts)) as $bs
| ($reqs | map({ts, epoch: (.ts | ep), ctx: (.input + .creation + .read), input, creation, read, sw: in_switch((.ts | ep))})) as $R
| (reduce range(0; $bs | length) as $i ({out: [], last: {}, first: {}, probe_fail: false};
     $bs[$i] as $b
     | ($b.meta // {}) as $m
     | ($b.sid + "/" + $b.agent) as $k
     | ((($m.trigger? // null) == null) or (($m.preTokens? // null) == null) or (($m.postTokens? // null) == null)
        or (($m.durationMs? // null) == null) or (($m.cumulativeDroppedTokens? // null) == null)) as $missing
     | (if $missing then .probe_fail = true else . end)
     | (if $missing or ((.last[$k] // null) == null) then null else ($m.cumulativeDroppedTokens - .last[$k]) end) as $dcum
     | (if ($missing | not) and $dcum != null and $dcum != ($m.preTokens - $m.postTokens) then .probe_fail = true else . end)
     | (if $missing then . else .last[$k] = $m.cumulativeDroppedTokens end)
     | (($missing | not) and $m.trigger == "auto") as $auto
     | ($auto and ((.first[$k] // false) | not)) as $is_first_auto
     | (if $auto then .first[$k] = true else . end)
     | ($is_first_auto and $win != null and (($m.preTokens // 0) > ($win * 1.05))) as $shadow
     | ($b.ts | ep) as $bep
     | in_switch($bep) as $insw
     | ([$R[] | select(.epoch != null and $bep != null and .epoch > $bep)] | first // null) as $nxt
     | .out += [{ts: $b.ts, agent: $b.agent, trigger: ($m.trigger // null),
                 pre: ($m.preTokens // null), post: ($m.postTokens // null), dur: ($m.durationMs // null),
                 cumulative: ($m.cumulativeDroppedTokens // null),
                 dropped_delta: (if $missing then null else ($m.preTokens - $m.postTokens) end),
                 shadow: $shadow, in_switch_window: $insw, rebuild_creation: ($nxt.creation // 0),
                 missing: $missing}])) as $B
| ($B.out | map(select(.trigger == "auto" and (.shadow | not) and (.in_switch_window | not) and (.missing | not)))) as $inc
| ($R | map(select(.sw | not))) as $Rinc
| {boundaries: $B.out,
   probe_fail: $B.probe_fail,
   requests: ($R | length),
   requests_included: ($Rinc | length),
   ctx: {median: ([$R[].ctx] | median), p90: ([$R[].ctx] | pct(0.9)), max: ([$R[].ctx] | max)},
   ctx_values: ([$R[].ctx] | sort),
   cache: {read: ([$R[].read] | add // 0), creation: ([$R[].creation] | add // 0), input: ([$R[].input] | add // 0)},
   wall_ms: (if ($s.tmin | ep) != null and ($s.tmax | ep) != null then ((($s.tmax | ep) - ($s.tmin | ep)) * 1000) else null end),
   excluded: {manual: ([$B.out[] | select((.missing | not) and .trigger != "auto")] | length),
              shadow: ([$B.out[] | select(.shadow)] | length),
              switch_window: ([$R[] | select(.sw)] | length)},
   net_token: (([$inc[].dropped_delta] | add // 0) - ([$inc[].rebuild_creation] | add // 0)),
   compaction_ms: ([$inc[].dur] | add // 0),
   auto_count: ([$B.out[] | select(.trigger == "auto")] | length),
   included_count: ($inc | length),
   pre_auto: [$inc[].pre]}'

# --- 런별 수집 -----------------------------------------------------------------

cm_collect_run() {
  # cm_collect_run <run-id> <원장> <런 디렉터리> <상태> <출력 파일> — 런별 기록을 만든다.
  # 실패하면 1 을 돌려주고 파일을 남기지 않는다.
  local rid="$1" ledger="$2" rd="$3" state="$4" out="$5"
  local tmp row seg st kind ver attempt sid class win has_win lane wint wsrc stream_f stream
  local sess_dir seen_sids seen_streams="" sess_json dup an rejected=0 unemp=0 unk=0 sw p0 mism="" wins_seen
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cc-metrics-run.XXXXXX") || return 1
  sess_dir="$tmp/sess"; mkdir -p "$sess_dir"
  : > "$tmp/stages.jsonl"; : > "$tmp/shifts.jsonl"; : > "$tmp/p0.tsv"
  sw=$(cm_switch_windows "$ledger")
  [ -n "$sw" ] || sw='[]'

  # P0 는 원장의 cycle 행에서 세그먼트로 조인한다 — 필드 없는 행은 unknown 이지 0 이 아니다.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    seg=$(cm_field "$row" '세그먼트')
    if cm_has_field "$row" 'P0'; then p0=$(cm_field "$row" 'P0'); else p0="unknown"; fi
    case "$p0" in ''|*[!0-9]*) p0="unknown" ;; esac
    printf '%s\t%s\n' "$seg" "$p0" >> "$tmp/p0.tsv"
  done <<ROWS
$(cm_ledger_rows "$ledger" 'cycle')
ROWS

  seen_sids=""
  wins_seen=""
  # cm_row_emit <행> <종류 덮어쓰기> <출력 파일> — stage-result 와 교대 기동 행의 공통
  # 경로. 교대 행은 종류 `shift` 로 들어오고 스트림 로그를 읽지 않는다.
  cm_row_emit() {
    local row="$1" kind_override="$2" sink="$3"
    seg=$(cm_field "$row" '세그먼트'); st=$(cm_field "$row" '스테이지')
    if [ -n "$kind_override" ]; then kind="$kind_override"; else kind=$(cm_field "$row" '종류'); fi
    [ -n "$kind" ] || kind="-"
    ver=$(cm_field "$row" '실행 버전')
    case "$ver" in ''|*[!0-9]*) attempt="" ;; *) attempt="$ver" ;; esac
    sid=$(cm_field "$row" '세션 id')
    class=$(cm_field "$row" '종단 부류'); [ -n "$class" ] || class="-"
    if cm_has_field "$row" '압축 창'; then has_win=true; win=$(cm_field "$row" '압축 창'); else has_win=false; win=""; fi
    lane=$(cm_field "$row" '레인'); [ -n "$lane" ] || lane="-"
    wint=""; wsrc=""
    if [ "$has_win" = true ]; then
      if cm_window_ok "$win"; then
        wint=$(cm_window_int "$win"); wsrc=$(cm_window_source "$win")
      else
        rejected=$((rejected + 1)); wint=""; wsrc=""
      fi
    fi
    [ -n "$st" ] || st="$seg"
    if [ -n "$kind_override" ]; then
      stream='{"complete":true,"truncated":false,"cost_usd":null,"duration_ms":null,"session_id":""}'
    else
      stream_f=$(cm_stream_of "$rd" "$st" "$attempt")
      case "$seen_streams" in
        *" $stream_f "*)
          # 여러 시도가 평문 폴백 하나로 접혔다 — 파일은 한 번만 열고, 두 번째 행은 그 봉투의
          # 비용·소요를 다시 싣지 않는다(A4 가 한 봉투를 두 번 세지 않도록).
          stream=$(cm_stream_result "$stream_f" | jq -c '.cost_usd = null | .duration_ms = null | .shared = true') ;;
        *)
          [ -z "$stream_f" ] || seen_streams="$seen_streams $stream_f "
          stream=$(cm_stream_result "$stream_f") ;;
      esac
    fi
    # 세션 귀속. 빈 값과 미상은 다른 관측이며 둘 다 조인 모집단에서만 빠진다.
    dup=false
    if [ -z "$sid" ]; then
      unemp=$((unemp + 1)); sess_json='{"b":[],"r":[],"tmin":null,"tmax":null}'
    elif [ "$sid" = "미상" ]; then
      unk=$((unk + 1)); sess_json='{"b":[],"r":[],"tmin":null,"tmax":null}'
    else
      case "$seen_sids" in
        *" $sid "*)
          dup=true
          # 한 묶음 안에서 압축 창 값이 다르면 두 팔에 걸친 세션 — 보고하고 버리지 않는다.
          case "$wins_seen" in
            *" $sid=$win "*) : ;;
            *) case " $mism " in *" $sid "*) : ;; *) mism="$mism $sid" ;; esac ;;
          esac ;;
        *)
          seen_sids="$seen_sids $sid "
          wins_seen="$wins_seen $sid=$win "
          if [ ! -f "$sess_dir/$sid.json" ]; then
            local files oldifs
            files=$(cm_transcripts "$sid")
            if [ -n "$files" ]; then
              # 파일 목록은 줄 단위다 — 경로에 공백이 있어도 한 인자로 남도록 IFS 를 줄바꿈으로만 둔다.
              oldifs=$IFS; set -f; IFS='
'
              # shellcheck disable=SC2086
              set -- $files
              IFS=$oldifs; set +f
              cm_scan_session "$@" > "$sess_dir/$sid.json" 2>/dev/null \
                || printf '{"b":[],"r":[],"tmin":null,"tmax":null}' > "$sess_dir/$sid.json"
            else
              printf '{"b":[],"r":[],"tmin":null,"tmax":null}' > "$sess_dir/$sid.json"
            fi
          fi ;;
      esac
      sess_json=$(cat "$sess_dir/$sid.json")
    fi
    an=$(printf '%s' "$sess_json" | jq -c --argjson win "${wint:-null}" --argjson sw "$sw" --argjson dup "$dup" "$CM_JQ_STAGE" 2>/dev/null) \
      || an='{"boundaries":[],"probe_fail":true,"requests":0,"requests_included":0,"ctx":{"median":null,"p90":null,"max":null},"ctx_values":[],"cache":{"read":0,"creation":0,"input":0},"wall_ms":null,"excluded":{"manual":0,"shadow":0,"switch_window":0},"net_token":0,"compaction_ms":0,"auto_count":0,"included_count":0,"pre_auto":[]}'
    p0=$(awk -F'\t' -v s="$seg" 'BEGIN { n = 0; u = 0 } $1 == s { n++; if ($2 == "unknown") u = 1; else t += $2 } END { if (n == 0 || u) print "unknown"; else print t }' "$tmp/p0.tsv")
    jq -cn --arg seg "$seg" --arg st "$st" --arg kind "$kind" --arg attempt "$attempt" --arg sid "$sid" \
      --arg class "$class" --arg win "$win" --argjson has_win "$has_win" --arg wint "$wint" --arg wsrc "$wsrc" \
      --arg lane "$lane" --argjson stream "$stream" --argjson an "$an" --arg p0 "$p0" --argjson dup "$dup" '
      {segment: $seg, stage: $st, kind: $kind,
       attempt: (if $attempt == "" then null else ($attempt | tonumber) end),
       session_id: $sid, session_unknown: ($sid == "미상"), session_dup: $dup,
       class: $class,
       window: (if $has_win then $win else null end), window_present: $has_win,
       window_int: (if $wint == "" then null else ($wint | tonumber) end), window_source: $wsrc,
       lane: $lane,
       complete: $stream.complete, truncated: $stream.truncated,
       wall_ms: (if $an.wall_ms != null then $an.wall_ms else ($stream.duration_ms // null) end),
       wall_source: (if $an.wall_ms != null then "transcript" elif $stream.duration_ms != null then "stream" else "none" end),
       cost_usd: $stream.cost_usd,
       requests: $an.requests, requests_included: $an.requests_included,
       ctx: $an.ctx, ctx_values: $an.ctx_values, cache: $an.cache,
       boundaries: $an.boundaries, probe_fail: $an.probe_fail,
       excluded: $an.excluded, net_token: $an.net_token, compaction_ms: $an.compaction_ms,
       auto_count: $an.auto_count, included_count: $an.included_count, pre_auto: $an.pre_auto,
       p0: (if $p0 == "unknown" then "unknown" else ($p0 | tonumber) end)}' >> "$sink"
  }

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cm_row_emit "$row" "" "$tmp/stages.jsonl"
  done <<ROWS
$(cm_ledger_rows "$ledger" 'stage-result')
ROWS
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cm_row_emit "$row" "shift" "$tmp/shifts.jsonl"
  done <<ROWS
$(cm_ledger_rows "$ledger" '교대 기동')
ROWS

  mkdir -p "$(dirname "$out")" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  jq -Sn --arg rid "$rid" --arg state "$state" --argjson rejected "$rejected" \
     --argjson unemp "$unemp" --argjson unk "$unk" --arg mism "$mism" \
     --slurpfile stages "$tmp/stages.jsonl" --slurpfile shifts "$tmp/shifts.jsonl" '
     {run_id: $rid, state: $state, stages: $stages, shifts: $shifts,
      rejected_window: $rejected,
      unattributed: {empty: $unemp, unknown: $unk},
      window_mismatch_sessions: ($mism | split(" ") | map(select(length > 0))),
      probe_fail: ([$stages[], $shifts[]] | any(.probe_fail))}' > "$tmp/record.json" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  if ! jq -e . "$tmp/record.json" >/dev/null 2>&1; then rm -rf "$tmp"; return 1; fi
  mv -f "$tmp/record.json" "$out" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

# --- 모집단 ---------------------------------------------------------------------

cm_population() {
  # cm_population — 원장마다 `<run-id>\t<상태>\t<원장>\t<런 디렉터리>` 한 줄. 상태는
  # `cc_run_state` 그대로이고 모집단 판별자를 새로 만들지 않는다.
  local f rid rd state
  for f in "$CM_LEDGER_DIR"/*.md; do
    [ -f "$f" ] || continue
    rid=$(basename "$f" .md)
    printf '%s' "$rid" | grep -qE '^[0-9]{8}-[0-9a-f]{8}$' || continue
    rd="$CM_STATE_ROOT/run/$rid"
    state=$(cc_run_state "$rd" "$f" 180 3600)
    printf '%s\t%s\t%s\t%s\n' "$rid" "$state" "$f" "$rd"
  done
}

# --- 집계 --------------------------------------------------------------------------

CM_JQ_DEFS='
def median: if length == 0 then null else (sort | if length % 2 == 1 then .[((length - 1) / 2)] else ((.[length / 2 - 1] + .[length / 2]) / 2) end) end;
def pct($q): if length == 0 then null else (sort | .[(((length * $q) | ceil) - 1) | if . < 0 then 0 else . end]) end;
def dist: {min: (if length == 0 then null else min end), median: median, max: (if length == 0 then null else max end)};
def cutoff($w): ([$w, 1000000] | min) - 33000;
def p0sum: if any(. == "unknown") then "unknown" else (add // 0) end;
def rows: [.[] | (.stages[], .shifts[])];
def included_rows: rows | map(select(.complete and (.truncated | not)));
'

cm_aggregate() {
  # cm_aggregate <기록 배열 파일> — 요약의 strata 와 제외 수. 전수 재계산이고 시각이 없다.
  jq -S --argjson sws "$CM_SWITCH_WINDOW" "$CM_JQ_DEFS"'
    (rows) as $all
    | (included_rows) as $inc
    | {strata: ($inc | group_by(.kind + "|" + .class + "|" + .lane)
        | map({key: (.[0].kind + "|" + .[0].class + "|" + .[0].lane),
               value: ((. ) as $g
                 | ([$g[].boundaries[] | select(.trigger == "auto" and (.shadow | not) and (.in_switch_window | not) and (.missing | not))]) as $bs
                 | (([$g[].cache.read] | add // 0) + ([$g[].cache.creation] | add // 0) + ([$g[].cache.input] | add // 0)) as $den
                 | {A1: (if $den == 0 then null else (([$g[].cache.read] | add // 0) / $den) end),
                    A2: {median: ([$g[].ctx_values[]] | median), p90: ([$g[].ctx_values[]] | pct(0.9)), max: ([$g[].ctx_values[]] | max)},
                    A3: {count: ($bs | length), dropped: ([$bs[].dropped_delta] | add // 0),
                         pre: ([$bs[].pre] | dist), post: ([$bs[].post] | dist), dur: ([$bs[].dur] | dist),
                         shadow: ([$g[].excluded.shadow] | add // 0), manual: ([$g[].excluded.manual] | add // 0),
                         switch_window: ([$g[].boundaries[] | select(.in_switch_window)] | length)},
                    A4: {usd: ([$g[].cost_usd | select(. != null)] | add // 0), stages: ($g | length)},
                    A5: {p0: ([$g[].p0] | p0sum), wall_ms: ([$g[].wall_ms | select(. != null)] | add // 0)},
                    net: {token: ([$g[].net_token] | add // 0),
                          time: (([$g[].wall_ms | select(. != null)] | add // 0) as $w | if $w == 0 then null else (([$g[].compaction_ms] | add // 0) / $w) end)}})})
        | from_entries),
       excluded: {manual: ([$all[].excluded.manual] | add // 0), shadow: ([$all[].excluded.shadow] | add // 0),
                  switch_window: ([$all[].excluded.switch_window] | add // 0),
                  rejected_window: ([.[].rejected_window] | add // 0),
                  unattributed_empty: ([.[].unattributed.empty] | add // 0),
                  unattributed_unknown: ([.[].unattributed.unknown] | add // 0),
                  incomplete: ([$all[] | select((.complete | not) or .truncated)] | length)},
       switch_window_s: $sws,
       unattributed: {empty: ([.[].unattributed.empty] | add // 0), unknown: ([.[].unattributed.unknown] | add // 0)},
       rejected_window: ([.[].rejected_window] | add // 0),
       window_mismatch_sessions: ([.[].window_mismatch_sessions[]] | unique)}' "$1"
}

cm_journal_tail() {
  # cm_journal_tail — 저널의 기존 줄들을 JSON 배열로(없으면 []). 깨진 줄은 건너뛴다.
  if [ -f "$CM_JOURNAL" ]; then
    jq -Rn '[inputs | fromjson? | objects]' "$CM_JOURNAL" 2>/dev/null || printf '[]'
  else
    printf '[]'
  fi
}

cm_triggers() {
  # cm_triggers <델타 기록 배열 파일> <저널 배열 파일> <차단 여부> — 저널 줄의 본체
  # (probe · mixed_window · strata · fired · close · excluded). 트리거는 델타에만 건다.
  jq -c --slurpfile prior "$2" --argjson blocked "$3" "$CM_JQ_DEFS"'
    ($prior[0]) as $J
    | (rows) as $all
    | (included_rows) as $inc
    | ([.[] | select(.probe_fail)] | length > 0) as $probe_fail
    # 종류마다 실효 창이 둘 이상 섞였는가 — 섞인 종류의 층은 올리지도 리셋하지도 않는다.
    | ($inc | group_by(.kind) | map({key: .[0].kind, value: ([.[].window_int | select(. != null)] | unique | length > 1)}) | from_entries) as $mixed
    | ($mixed | to_entries | any(.value)) as $mixed_any
    # T6 층: (종류, 실효 창) — 이 회차 델타의 두 항과 P0.
    | ($inc | map(select(.window_int != null)) | group_by(.kind + "|" + (.window_int | tostring))
       | map(. as $g | (.[0].kind + "|" + (.[0].window_int | tostring)) as $key
         | ($J | map(.strata[$key]? // empty)) as $hist
         | ($hist | map(.token | numbers)) as $ht
         | ($hist | map(.time | numbers)) as $htime
         | ($hist | map(.p0 | numbers)) as $hp0
         | ([$g[].wall_ms | select(. != null)] | add // 0) as $w
         | ([$g[].net_token] | add // 0) as $token
         | (if $w == 0 then null else (([$g[].compaction_ms] | add // 0) / $w) end) as $time
         | ([$g[].p0] | p0sum) as $p0
         | (($hist | length) < 3) as $warmup
         | (([$g[].included_count] | add // 0) + ([$g[].requests_included] | add // 0) == 0) as $thin
         | ($hist | last // {consecutive_bad: 0, consecutive_good: 0}) as $prev
         # 값을 믿을 수 없는 회차(차단·프로브 실패·창 섞임·표본 없음)는 두 항을 null 로 남겨
         # 뒤 회차의 기준 중앙값에도 들지 않는다. 워밍업 회차는 평가만 않고 값은 남긴다.
         | ($blocked or $probe_fail or $mixed[.[0].kind] or $thin) as $untrusted
         | ($untrusted or $warmup or $time == null or ($ht | length) == 0 or ($htime | length) == 0) as $skip
         | ($ht | median) as $bt | ($htime | median) as $btime | ($hp0 | median) as $bp0
         | (if $skip then false else ($token < $bt and $time > $btime) end) as $bad
         | (if $skip then false else ($token > $bt and $time < $btime) end) as $good
         | (if $skip or ($good | not) or $p0 == "unknown" or $bp0 == null then false else ($p0 < $bp0) end) as $veto
         | {key: $key,
            value: {token: (if $untrusted then null else $token end), time: (if $untrusted then null else $time end),
                    p0: (if $untrusted then null else $p0 end),
                    consecutive_bad: (if $skip then ($prev.consecutive_bad // 0) elif ($bad or $veto) then (($prev.consecutive_bad // 0) + 1) else 0 end),
                    consecutive_good: (if $skip then ($prev.consecutive_good // 0) elif ($good and ($veto | not)) then (($prev.consecutive_good // 0) + 1) else 0 end),
                    warmup: $warmup, evaluated: ($skip | not), veto: $veto}})
       | from_entries) as $strata
    | (if $blocked then [] else
        # T1 은 델타가 아니라 전수 위의 모순이라 셸 쪽(cm_main)이 건다.
        # T2 — 종단 result 줄이 없는데 종단 부류가 크래시·외부 종료가 아니다.
        ([$all[] | select(.kind != "shift" and (.complete | not) and (.class != "크래시") and (.class != "외부 종료")) | .kind] | unique
           | map({id: "T2", kind: ., signature: ("T2/" + .), body: "종단 result 줄이 없는 스테이지의 종단 부류가 크래시도 외부 종료도 아니다 — 그 스테이지의 기동·종료 경로를 본다"}))
        # T3 — 델타의 모든 행에 압축 창 키 자체가 없다.
        + (if ($all | length) > 0 and ($all | all(.window_present | not)) then
             ([$all[].kind] | unique | map({id: "T3", kind: ., signature: ("T3/" + .), body: "이 회차 델타의 모든 행에 압축 창 키가 없다 — 수집기가 기대하는 스키마와 기록된 스키마가 어긋났다"}))
           else [] end)
        # T4 — 창이 정수인데 최대 컨텍스트가 절단 지점을 넘겼음에도 auto 압축이 0건이다.
        + ([$inc[] | select(.window_int != null and .ctx.max != null and .ctx.max > cutoff(.window_int) and .auto_count == 0) | .kind] | unique
           | map({id: "T4", kind: ., signature: ("T4/" + .), body: "압축 창이 정수로 기록됐고 요청 최대 컨텍스트가 그 창의 절단 지점을 넘겼는데 auto 압축 기록이 0건이다 — 창이 실제로는 걸리지 않았다"}))
        # T5 — 판정 필드(압축 창 값과 조인된 P0)가 델타의 모든 행에서 비어 있다.
        + (if ($all | length) > 0 and ($all | all((.window_int == null) and (.p0 == "unknown"))) then
             ([$all[].kind] | unique | map({id: "T5", kind: ., signature: ("T5/" + .), body: "판정에 쓰이는 필드(압축 창 정수와 세그먼트로 조인한 P0)가 이 회차 표본의 모든 행에서 비어 있다 — 기록과 판정이 서로 다른 필드를 보고 있다"}))
           else [] end)
        # T6 — 두 항이 둘 다 나쁜 쪽(또는 P0 거부권)인 회차가 연속 3.
        + ($strata | to_entries | map(select(.value.evaluated and .value.consecutive_bad >= 3)) | map(.key | split("|")[0]) | unique
           | map({id: "T6", kind: ., signature: ("T6/" + .), body: "토큰 항과 시간 항이 같은 층의 선행 회차 중앙값 대비 둘 다 나쁜 쪽(또는 P0 거부권)인 회차가 연속 3회다 — 창 값이 이 스테이지 종류에 맞지 않는다"}))
        # T7 — auto 기록 preTokens 하위 5% 분위와 유도 절단 지점의 차가 ±5% 대역 밖이다.
        + ($inc | map(select(.window_int != null)) | group_by(.kind + "|" + (.window_int | tostring))
           | map(select(([.[].pre_auto[]] | length) > 0)
                 | select(([.[].pre_auto[]] | pct(0.05)) as $p5 | cutoff(.[0].window_int) as $c | (($p5 - $c) | fabs) > ($c * 0.05)))
           | map(.[0].kind) | unique
           | map({id: "T7", kind: ., signature: ("T7/" + .), body: "기록된 실효 창에서 유도한 절단 지점과 관측된 auto 압축 preTokens 하위 5% 분위가 ±5% 대역 밖으로 어긋난다 — 기록된 창과 실제로 적용된 창이 다르다"}))
      end) as $fired
    | ($strata | to_entries | map(select(.value.evaluated and .value.consecutive_good >= 3)) | map("T6/" + (.key | split("|")[0])) | unique) as $close
    | {probe: (if $blocked then "차단" elif $probe_fail then "프로브 실패" else "ok" end),
       mixed_window: $mixed_any,
       strata: ($strata | with_entries(.value |= {token, time, p0, consecutive_bad, consecutive_good, warmup})),
       fired: $fired, close: (if $blocked then [] else $close end),
       excluded: {manual: ([$all[].excluded.manual] | add // 0), shadow: ([$all[].excluded.shadow] | add // 0),
                  switch_window: ([$all[].excluded.switch_window] | add // 0),
                  rejected_window: ([.[].rejected_window] | add // 0),
                  unattributed_empty: ([.[].unattributed.empty] | add // 0),
                  unattributed_unknown: ([.[].unattributed.unknown] | add // 0),
                  incomplete: ([$all[] | select((.complete | not) or .truncated)] | length)}}' "$1"
}

cm_write_summary() {
  # cm_write_summary <요약 JSON> — 임시 파일에 쓴 뒤 `mv -f`, 그다음 `.pending` 을 지운다.
  local tmp
  tmp=$(mktemp "$CM_LEDGER_DIR/.metrics.json.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CM_LEDGER_DIR/metrics.json" || { rm -f "$tmp"; return 1; }
  rm -f "$CM_LEDGER_DIR/metrics.json.pending"
}

cm_append_journal() {
  # cm_append_journal <줄> — 저널에 한 줄 추가하고 그 줄을 stdout 으로 낸다.
  mkdir -p "$(dirname "$CM_JOURNAL")" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$CM_JOURNAL" || return 1
  printf '%s\n' "$1"
}

# --- 본체 ------------------------------------------------------------------------

cm_main() {
  local tmp line rid state ledger rd rec input_files=0
  local n_collected=0 n_uncollected=0 n_gone=0 n_open=0 new_runs="" blocked=false
  local summary round at body counts journal_line all_f delta_f prior_f
  cm_args "$@"
  : > "$CM_LEDGER_DIR/metrics.json.pending"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cc-metrics.XXXXXX") || exit 1
  all_f="$tmp/all.json"; delta_f="$tmp/delta.json"; prior_f="$tmp/prior.json"
  : > "$tmp/delta.list"
  while IFS=$'\t' read -r rid state ledger rd; do
    [ -n "$rid" ] || continue
    input_files=$((input_files + 1))
    case "$state" in
      종단|버려짐) ;;
      *) n_open=$((n_open + 1)); continue ;;
    esac
    rec="$CM_LEDGER_DIR/metrics/$rid.json"
    if [ -f "$rec" ] && [ "$CM_RECOLLECT" = "0" ] && jq -e . "$rec" >/dev/null 2>&1; then
      n_collected=$((n_collected + 1)); continue
    fi
    if [ ! -d "$rd/log" ]; then
      n_gone=$((n_gone + 1)); continue
    fi
    if cm_collect_run "$rid" "$ledger" "$rd" "$state" "$rec"; then
      n_collected=$((n_collected + 1))
      printf '%s\n' "$rid" >> "$tmp/delta.list"
      new_runs="$new_runs $rid"
    else
      n_uncollected=$((n_uncollected + 1))
      cm_diag "런 $rid 의 기록을 만들지 못했다"
    fi
  done <<POP
$(cm_population)
POP
  [ "$n_uncollected" -gt 0 ] && blocked=true

  # 전수 재계산 — 기록 디렉터리의 모든 런별 기록.
  if [ -d "$CM_LEDGER_DIR/metrics" ]; then
    jq -s '.' "$CM_LEDGER_DIR"/metrics/*.json > "$all_f" 2>/dev/null || printf '[]' > "$all_f"
  else
    printf '[]' > "$all_f"
  fi
  jq -e 'type == "array"' "$all_f" >/dev/null 2>&1 || printf '[]' > "$all_f"
  jq -Rn '[inputs]' "$tmp/delta.list" > "$tmp/ids.json"
  jq -c --slurpfile ids "$tmp/ids.json" '[.[] | select(.run_id as $r | $ids[0] | index($r) != null)]' "$all_f" > "$delta_f" 2>/dev/null \
    || printf '[]' > "$delta_f"
  cm_journal_tail > "$prior_f"

  counts=$(jq -cn --argjson a "$n_collected" --argjson b "$n_uncollected" --argjson c "$n_gone" --argjson d "$n_open" \
    '{"수집됨": $a, "미수집": $b, "사라짐": $c, "미종단": $d}')
  summary=$(cm_aggregate "$all_f" | jq -S --argjson counts "$counts" --argjson n "$input_files" '. + {counts: $counts, input_files: $n}')
  [ -n "$summary" ] || summary='{}'
  cm_write_summary "$summary" || { cm_diag "요약을 쓰지 못했다"; }

  body=$(cm_triggers "$delta_f" "$prior_f" "$blocked")
  [ -n "$body" ] || body='{"probe":"프로브 실패","mixed_window":false,"strata":{},"fired":[],"close":[],"excluded":{}}'
  # T1 — 입력 파일이 0건인데 전수 집계가 비어 있지 않다. 델타가 아니라 전수 위의 모순이라
  # 여기서 건다(전수가 비어 있지 않다는 것은 옛 기록이 남아 있다는 뜻이다).
  if [ "$input_files" -eq 0 ] && [ "$blocked" = false ] \
     && [ "$(printf '%s' "$summary" | jq -r '.strata | length')" != "0" ]; then
    body=$(printf '%s' "$body" | jq -c '.fired = ([{id: "T1", kind: "-", signature: "T1/-", body: "입력 파일 0건 위에서 집계가 계산됐는데 결과가 비어 있지 않다 — 수집기의 입력 경로 해소가 틀렸다"}] + .fired)')
  fi
  round=$(( $(jq -r 'length' "$prior_f") + 1 ))
  at=$(jq -rn --argjson n "$CM_NOW" '$n | todate')
  journal_line=$(printf '%s' "$body" | jq -c --argjson round "$round" --arg at "$at" --arg repo "$CM_REPO" \
    --argjson counts "$counts" --arg new "$new_runs" '
    {round: $round, at: $at, repo: $repo, counts: $counts,
     new_runs: ($new | split(" ") | map(select(length > 0))),
     probe: .probe, mixed_window: .mixed_window, strata: .strata, fired: .fired, close: .close, excluded: .excluded}')
  rm -rf "$tmp"
  cm_append_journal "$journal_line" || { cm_diag "저널을 쓰지 못했다: $CM_JOURNAL"; exit 1; }
  exit 0
}

cm_main "$@"
