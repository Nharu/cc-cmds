#!/usr/bin/env bash
# lint-bash-portability: self-skip
# 런 계측 수집기 — 모집단·판독 규칙·집계·순 효과·트리거 일곱.
#
# 이 스위트가 있는 이유. 수집기의 오판은 대부분 오류가 아니라 자신 있는 틀린 수로
# 나타난다 — 줄 단위로 합한 요청 수, 세션만으로 묶어 역행하는 누적, 폴백 하나에 접힌
# 두 시도의 이중 비용, 잘린 로그를 성공으로 읽은 짧은 수. 그래서 단언은 대부분 「수가
# 정확히 이것이다」이고, 트리거는 저마다 홀로 발화하는 픽스처와 발화하지 않아야 하는
# 대조군을 함께 갖는다. 트리거는 수집기의 출력이므로 여기서 재고, 필링 스위트는 그
# 출력을 소비만 한다.
#
# Usage: bash scripts/test-collect-run-metrics.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
COLLECT="$repo_root/plugins/cc-cmds/orchestrator/collect-run-metrics.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-metrics-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# --- 픽스처 ---------------------------------------------------------------------

LEDGER_DIR="$WORK/repo/docs/pipeline-run"
STATE="$WORK/state"
HOME_A="$WORK/home/.claude"; HOME_B="$WORK/home/.claude-cc"; HOME_C="$WORK/home/.claude-cci"
JOURNAL="$WORK/j.jsonl"
BASE_EPOCH=1790000000
NOW=$((BASE_EPOCH + 86400))
mkdir -p "$LEDGER_DIR" "$STATE/run" "$HOME_A/projects" "$HOME_B/projects" "$HOME_C/projects" \
         "$WORK/home/.claude.bak/projects"

ts() { jq -rn --argjson n "$((BASE_EPOCH + $1))" '$n | todate'; }

mk_ledger() {
  # mk_ledger <run-id> <행…> — 헤더 한 줄과 산문 한 줄 뒤에 행들.
  local rid="$1"; shift
  {
    printf '# 파이프라인 런 보고서 — %s\n\n' "$rid"
    printf '이 줄은 산문이고 compact_boundary 라는 낱말을 담지만 행이 아니다.\n'
    printf '%s\n' "$@"
  } > "$LEDGER_DIR/$rid.md"
}
sr_row() {
  # sr_row <seg> <stage> <kind> <ver> <sid> <class> <window|__none__> <lane>
  local win=""
  [ "$7" = "__none__" ] || win=" | 압축 창=$7"
  printf -- '- `stage-result` | 세그먼트=%s | 스테이지=%s | 종류=%s | 종료 코드=0 | 실행 버전=%s | 세션 id=%s | 부모=- | 기록자=게이트 | 종단 부류=%s%s | 레인=%s | 교대=0 | prev=abc' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$win" "$8"
}
cycle_row() {
  # cycle_row <seg> <cycle> <P0|__none__>
  local p0=""
  [ "$3" = "__none__" ] || p0=" | P0=$3"
  printf -- '- `cycle` | 세그먼트=%s | 사이클=%s | 리포트 경로=r.md | 리뷰 HEAD=abc%s | P1=0 | 교대=0 | prev=abc' "$1" "$2" "$p0"
}
shift_row() {
  # shift_row <서수> <사유> <기록 시각> <sid> <lane> <window>
  printf -- '- `교대 기동` | 서수=%s | 사유=%s | 대상=x | 기록 시각=%s | 세션 id=%s | 레인=%s | 압축 창=%s | 교대=0 | prev=abc' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
mk_rundir() {
  # mk_rundir <run-id> [nodone] — log/·config-dir·done.
  mkdir -p "$STATE/run/$1/log" "$STATE/run/$1/config-dir"
  [ "${2:-}" = "nodone" ] || : > "$STATE/run/$1/done"
}
mk_stream() {
  # mk_stream <경로> <result 줄 수> [truncate|-] [cost] [duration_ms]
  local f="$1" n="$2" mode="${3:--}" cost="${4:-0.5}" dur="${5:-1000}" i=0
  : > "$f"
  printf '{"type":"system","subtype":"init","session_id":"s"}\n' >> "$f"
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    printf '{"type":"result","subtype":"success","is_error":false,"result_index":%s,"total_cost_usd":%s,"duration_ms":%s,"session_id":"s"}\n' "$i" "$cost" "$dur" >> "$f"
  done
  [ "$mode" = "truncate" ] && printf '{"type":"result","result_in' >> "$f"
  return 0
}
tl_assist() {
  # tl_assist <ts-offset> <message id> <input> <creation> <read>
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$(ts "$1")" "$2" "$3" "$4" "$5"
}
tl_boundary() {
  # tl_boundary <ts-offset> <sid> <agent> <trigger> <pre> <post> <dur> <cum> [snake|camel] [drop-field]
  local meta key="${9:-camel}" drop="${10:-}"
  meta=$(jq -cn --arg t "$4" --argjson pre "$5" --argjson post "$6" --argjson dur "$7" --argjson cum "$8" --arg drop "$drop" \
    '{trigger: $t, preTokens: $pre, postTokens: $post, durationMs: $dur, cumulativeDroppedTokens: $cum} | if $drop == "" then . else del(.[$drop]) end')
  if [ "$key" = "snake" ]; then
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","sessionId":"%s","agentId":"%s","compact_metadata":%s}\n' "$(ts "$1")" "$2" "$3" "$meta"
  else
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","sessionId":"%s","agentId":"%s","compactMetadata":%s}\n' "$(ts "$1")" "$2" "$3" "$meta"
  fi
}
tl_prose() {
  # tl_prose <ts-offset> — 표지 문자열을 본문에 담은 사용자 줄. 압축 기록이 아니다.
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"system compact_boundary compactMetadata 를 말로만 담은 줄"}}\n' "$(ts "$1")"
}
mk_transcript() {
  # mk_transcript <홈> <슬러그> <sid> [subpath] <줄…을 stdin 으로>
  local home="$1" slug="$2" sid="$3" sub="${4:-}" f
  if [ -n "$sub" ]; then f="$home/projects/$slug/$sid/subagents/$sub"; else f="$home/projects/$slug/$sid.jsonl"; fi
  mkdir -p "$(dirname "$f")"
  cat > "$f"
}

OUT=""; rc=0
collect() {
  # collect [추가 인자…] — 고정 인자로 수집기를 부른다. stdout 은 $OUT, rc 는 $rc.
  OUT=$(bash "$COLLECT" --ledger-dir "$LEDGER_DIR" --state-root "$STATE" \
        --config-home "$HOME_A" --config-home "$HOME_B" --config-home "$HOME_C" \
        --journal "$JOURNAL" --now "$NOW" "$@" 2>"$WORK/err"); rc=$?
}
jline() { printf '%s' "$OUT" | jq -r "$1"; }
jsum()  { jq -r "$1" "$LEDGER_DIR/metrics.json"; }
jrec()  { jq -r "$2" "$LEDGER_DIR/metrics/$1.json"; }
reset_all() {
  # 한 주제가 끝나면 원장·기록·저널·상태·전사를 비운다 — 주제 사이에 회차가 새지 않게.
  rm -rf "$LEDGER_DIR" "$STATE" "$JOURNAL" "$WORK/home"
  mkdir -p "$LEDGER_DIR" "$STATE/run" "$HOME_A/projects" "$HOME_B/projects" "$HOME_C/projects" \
           "$WORK/home/.claude.bak/projects"
}

# --- 0. 인자와 종료 코드 ------------------------------------------------------------

OUT=$(bash "$COLLECT" 2>/dev/null); rc=$?
check "0: --ledger-dir 없이 부르면 exit 2 다" "$rc" "2"
OUT=$(bash "$COLLECT" --ledger-dir "$WORK/없는곳" 2>/dev/null); rc=$?
check "0: 원장 디렉터리가 없으면 exit 3 다" "$rc" "3"
OUT=$(bash "$COLLECT" --ledger-dir "$LEDGER_DIR" --switch-window abc 2>/dev/null); rc=$?
check "0: 전환 창 폭이 정수가 아니면 exit 2 다" "$rc" "2"

# --- 1. 판독 규칙 — 로그 이름·폴백 접힘·잘림·산문 -------------------------------------

R1=20260901-aaaaaaa1
mk_rundir "$R1"
mk_stream "$STATE/run/$R1/log/S1#1.json" 1 - 0.25 2000
mk_stream "$STATE/run/$R1/log/S2.json" 2 - 0.75 3000
mk_stream "$STATE/run/$R1/log/S3.json" 1 - 1.0 4000
mk_stream "$STATE/run/$R1/log/S5.json" 1 truncate 9.0 5000
mk_ledger "$R1" \
  "$(sr_row S1 S1 implement 1 sid-a '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S2 S2 review '2.1.258 (Claude Code)' sid-b '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S3 S3 review 1 sid-c '크래시' '300000(argv)' '~/.claude')" \
  "$(sr_row S3 S3 review 2 sid-c '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S4 S4 audit 1 sid-d '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S5 S5 audit 1 sid-e '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S6 S6 design 1 '' '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S7 S7 design 1 '미상' '정상 완료' 'zzz' '~/.claude')" \
  "$(cycle_row S1 1 2)" "$(cycle_row S2 1 __none__)" \
  "$(shift_row 1 승인 "$(ts 100)" sid-shift '~/.claude-cc' '-')"
# S1 의 전사 — 메인·서브·한 단 더 깊은 서브, 그리고 산문 줄과 다중 블록 줄.
{
  tl_assist 10 m1 1000 2000 3000
  tl_assist 11 m1 1000 2000 3000
  tl_prose 12
  tl_boundary 20 sid-a "" auto 200000 50000 4000 150000
  tl_assist 21 m2 1000 9000 0
  tl_assist 30 m3 1000 0 8000
} | mk_transcript "$HOME_A" -repo sid-a
tl_boundary 25 sid-a ag1 auto 100000 20000 1000 80000 snake | mk_transcript "$HOME_A" -repo sid-a a.jsonl
tl_boundary 26 sid-a ag2 auto 100000 20000 1000 80000 | mk_transcript "$HOME_A" -repo sid-a deeper/b.jsonl
# 백업 디렉터리의 같은 세션 — 절대 들어오면 안 된다.
tl_boundary 27 sid-a ag9 auto 100000 20000 1000 80000 | mk_transcript "$WORK/home/.claude.bak" -repo sid-a
# 교대 세션의 전사 — 다른 홈에 있다.
{ tl_assist 100 sm1 100 100 100; tl_boundary 110 sid-shift "" auto 150000 30000 500 120000; tl_assist 111 sm2 100 100 100; } \
  | mk_transcript "$HOME_B" -repo sid-shift
collect
check "1: 수집기가 회차를 기록한다(exit 0)" "$rc" "0"
check "1: 시도 스코프 이름과 평문 폴백이 섞여도 스테이지 수가 정확하다" "$(jrec "$R1" '.stages | length')" "8"
check "1: 판 이름 꼴 실행 버전은 시도 번호로 읽히지 않는다" "$(jrec "$R1" '.stages[1].attempt')" "null"
check "1: 판 이름 꼴 행도 평문 폴백으로 종단 줄을 찾는다" "$(jrec "$R1" '.stages[1].complete')" "true"
check "1: 숫자 실행 버전은 시도 번호다" "$(jrec "$R1" '.stages[0].attempt')" "1"
check "1: 폴백 하나로 접힌 두 시도가 비용을 두 번 싣지 않는다" \
  "$(jrec "$R1" '[.stages[] | select(.segment == "S3") | .cost_usd] | map(select(. != null)) | length')" "1"
check "1: 종단 result 줄이 없는 스테이지는 complete:false 다" "$(jrec "$R1" '.stages[4].complete')" "false"
# S4(로그 없음)·S5(잘림)·S6·S7(로그 없음) 넷.
check "1: complete:false 스테이지는 집계에서 빠지되 제외 목록에 남는다" "$(jsum '.excluded.incomplete')" "4"
check "1: 마지막 줄이 잘린 로그는 truncated 다" "$(jrec "$R1" '.stages[5].truncated')" "true"
check "1: 잘린 로그는 성공으로 읽히지 않는다(집계 제외)" \
  "$(jsum '[.strata | to_entries[] | select(.key | startswith("audit|"))] | length')" "0"
check "1: 표지 문자열을 본문에 담은 산문 줄은 압축 기록이 아니다" "$(jrec "$R1" '.stages[0].boundaries | length')" "3"
check "1: 세 경로 단(메인·서브·깊은 서브)이 모두 열거된다" "$(jrec "$R1" '[.stages[0].boundaries[].agent] | sort | join(",")')" ",ag1,ag2"
check "1: 백업 디렉터리의 기록은 들어오지 않는다" "$(jrec "$R1" '[.stages[0].boundaries[] | select(.agent == "ag9")] | length')" "0"
check "1: 두 철자(compactMetadata·compact_metadata)를 모두 읽는다" "$(jrec "$R1" '[.stages[0].boundaries[] | select(.pre != null)] | length')" "3"
check "1: 다중 블록 줄은 요청을 부풀리지 않는다" "$(jrec "$R1" '.stages[0].requests')" "3"
check "1: 교대 세션은 shift 층으로 구별된다" "$(jsum '.strata | has("shift|-|~/.claude-cc")')" "true"
check "1: 교대 세션의 압축 기록이 순 효과에 든다" "$(jsum '.strata["shift|-|~/.claude-cc"].A3.count')" "1"
check "1: 문법 밖 압축 창은 거부로 세어 인쇄된다" "$(jsum '.rejected_window')" "1"
check "1: 빈 세션 id 와 미상은 다른 수로 인쇄된다" "$(jsum '[.unattributed.empty, .unattributed.unknown] | join("/")')" "1/1"
check "1: 귀속되지 않는 행도 종단 부류 통계에는 남는다" "$(jrec "$R1" '[.stages[] | select(.session_id == "" or .session_unknown)] | length')" "2"
check "1: P0 는 사이클 행에서 세그먼트로 조인된다" "$(jrec "$R1" '.stages[0].p0')" "2"
check "1: P0 필드 없는 사이클 행은 unknown 이지 0 이 아니다" "$(jrec "$R1" '.stages[1].p0')" "unknown"
check "1: 사이클 행이 없는 세그먼트도 unknown 이다" "$(jrec "$R1" '.stages[2].p0')" "unknown"
check "1: 스트림 result 줄의 subtype·is_error 는 기록에 오르지 않는다" "$(jrec "$R1" '[.stages[] | keys[]] | unique | map(select(. == "subtype" or . == "is_error")) | length')" "0"
# 순 효과의 두 부호와 단위.
check "1: 순 효과는 두 항의 쌍이다" "$(jsum '.strata["implement|정상 완료|~/.claude"].net | keys | join(",")')" "time,token"
check "1: 토큰 항 = 버린 토큰 − 압축 직후 캐시 생성 (USD 는 피연산자가 아니다)" \
  "$(jsum '.strata["implement|정상 완료|~/.claude"].net.token')" "$((150000 + 80000 + 80000 - 9000 - 0 - 0))"
check "1: 벽시계는 전사 시각 범위 그대로다(압축 소요를 빼지 않는다)" "$(jsum '.strata["implement|정상 완료|~/.claude"].A5.wall_ms')" "20000"
check "1: 시간 항 = 압축 소요 합 ÷ 벽시계" "$(jsum '.strata["implement|정상 완료|~/.claude"].net.time')" "0.3"
check "1: 캐시 적중률은 토큰 가중 비율이다" "$(jsum '.strata["implement|정상 완료|~/.claude"].A1 * 1000 | round')" "440"
check "1: 요청당 컨텍스트는 중앙값·p90·최댓값을 함께 낸다" "$(jsum '.strata["implement|정상 완료|~/.claude"].A2 | [.median, .p90, .max] | join(",")')" "9000,10000,10000"
check "1: 전사 없는 스테이지의 벽시계는 스트림 소요 합이고 출처가 stream 이다" "$(jrec "$R1" '.stages[1] | [.wall_ms, .wall_source] | join(",")')" "3000,stream"
# 회차 저널.
check "1: 저널 줄이 stdout 에 그대로 난다" "$(jline '.round')" "1"
check "1: 이 회차의 새 런이 new_runs 에 실린다" "$(jline '.new_runs | join(",")')" "$R1"
check "1: 넷의 수가 실린다" "$(jline '.counts | [.["수집됨"], .["미수집"], .["사라짐"], .["미종단"]] | join(",")')" "1,0,0,0"
check "1: 프로브가 성립한 회차는 ok 다" "$(jline '.probe')" "ok"
check "1: 저널 줄의 키가 고정돼 있다" "$(jline 'keys_unsorted | join(",")')" "round,at,repo,counts,new_runs,probe,mixed_window,strata,fired,close,excluded"
check "1: 저널의 at 은 --now 로 주입한 시각이다" "$(jline '.at')" "$(jq -rn --argjson n "$NOW" '$n | todate')"
check "1: 요약은 시각을 담지 않는다" "$(jsum 'tostring | test("2026-")')" "false"
check "1: .pending 표지는 정상 종료가 지운다" "$([ -e "$LEDGER_DIR/metrics.json.pending" ] && printf 있음 || printf 없음)" "없음"
# 멱등과 바이트 동일성.
cp "$LEDGER_DIR/metrics.json" "$WORK/sum1.json"; cp "$LEDGER_DIR/metrics/$R1.json" "$WORK/rec1.json"
collect
check "1: 두 번째 회차는 새 런이 없어 아무 트리거도 내지 않는다" "$(jline '.fired | length')" "0"
check "1: 기록이 있는 런은 다시 만들지 않는다(멱등)" "$(cmp -s "$WORK/rec1.json" "$LEDGER_DIR/metrics/$R1.json" && printf 같음 || printf 다름)" "같음"
check "1: 요약 파일을 두 번 써도 바이트가 같다" "$(cmp -s "$WORK/sum1.json" "$LEDGER_DIR/metrics.json" && printf 같음 || printf 다름)" "같음"
collect --recollect
check "1: 같은 픽스처를 다시 세면 런별 기록까지 바이트가 같다" "$(cmp -s "$WORK/rec1.json" "$LEDGER_DIR/metrics/$R1.json" && printf 같음 || printf 다름)" "같음"
check "1: 회차 수는 저널의 줄 수다" "$(jline '.round')" "3"
check "1: 저널이 세 줄이다" "$(grep -c '' "$JOURNAL")" "3"

# --- 2. 증분 항등·계열 키·같은 세션 두 행·미종단·차단 -----------------------------------
reset_all
R2=20260902-aaaaaaa2; R2B=20260902-aaaaaab2; R2C=20260902-aaaaaac2; R2D=20260902-aaaaaad2
mk_rundir "$R2"
mk_stream "$STATE/run/$R2/log/S1#1.json" 1
mk_stream "$STATE/run/$R2/log/S1#2.json" 1
mk_stream "$STATE/run/$R2/log/S2#1.json" 1
mk_ledger "$R2" \
  "$(sr_row S1 S1 review 1 sid-x '외부 종료' '300000(argv)' '~/.claude')" \
  "$(sr_row S1 S1 review 2 sid-x '정상 완료' '250000(레인)' '~/.claude')" \
  "$(sr_row S2 S2 review 1 sid-y '정상 완료' '300000(argv)' '~/.claude')" \
  "$(cycle_row S1 1 0)" "$(cycle_row S2 1 0)"
# sid-x: 첫 기록은 절대형(앞 전사의 누적을 이어받음), 둘째부터 증분 항등. agentId 가 섞여도
# 계열마다 누적한다 — 세션만으로 묶으면 1000 → 500 → 2000 으로 역행해 보인다.
{
  tl_assist 10 x1 1000 1000 1000
  tl_boundary 20 sid-x "" auto 90000 60000 100 10000
  tl_boundary 30 sid-x ag auto 50000 49500 100 500
  tl_boundary 40 sid-x "" auto 90000 60000 100 40000
  tl_assist 50 x2 1000 1000 1000
} | mk_transcript "$HOME_C" -repo sid-x
{ tl_assist 10 y1 1000 1000 1000; tl_assist 20 y2 1000 1000 1000; } | mk_transcript "$HOME_C" -repo sid-y
# R2B: 모집단 밖(미종단) — done 없고 세그먼트 행 없음, 원장은 신선하다.
mk_rundir "$R2B" nodone
mk_ledger "$R2B" "$(sr_row S1 S1 review 1 sid-z '정상 완료' '300000(argv)' '~/.claude')"
# R2C: 모집단 안인데 log/ 가 없다 — 회수됐다.
mk_ledger "$R2C" "$(sr_row S1 S1 review 1 sid-w '정상 완료' '300000(argv)' '~/.claude')"
mkdir -p "$STATE/run/$R2C"; : > "$STATE/run/$R2C/done"
collect
check "2: 증분 항등은 증분형이고 첫 기록의 절대형은 통과한다" "$(jline '.probe')" "ok"
check "2: agentId 가 섞여도 누적이 역행하지 않는다(계열 단위)" "$(jrec "$R2" '.stages[0].probe_fail')" "false"
check "2: 같은 세션의 두 행은 전사를 한 번만 열어 압축 기록이 중복되지 않는다" \
  "$(jrec "$R2" '[.stages[] | .boundaries | length] | join(",")')" "3,0,0"
check "2: 같은 세션 두 행의 압축 창이 다르면 창 불일치 세션으로 보고된다" "$(jsum '.window_mismatch_sessions | join(",")')" "sid-x"
check "2: 미종단 런은 미수집이 아니라 넷째 수다" "$(jline '.counts | [.["수집됨"], .["미수집"], .["사라짐"], .["미종단"]] | join(",")')" "1,0,1,1"
check "2: 미종단이 있어도 판정은 막히지 않는다" "$(jline '.probe')" "ok"
check "2: 입력 파일 수는 원장 파일 수다" "$(jsum '.input_files')" "3"
# 모집단 안의 미수집 — 기록 디렉터리 자리에 파일이 있어 기록을 쓸 수 없다.
mk_ledger "$R2D" "$(sr_row S1 S1 review 1 sid-v '정상 완료' '300000(argv)' '~/.claude')"
mk_rundir "$R2D"
rm -rf "$LEDGER_DIR/metrics"; : > "$LEDGER_DIR/metrics"
collect
check "2: 모집단 안에 미수집이 있으면 판정이 막힌다(probe=차단)" "$(jline '.probe')" "차단"
check "2: 막힌 회차는 트리거를 내지 않는다" "$(jline '.fired | length')" "0"
check "2: 미수집 수가 인쇄된다" "$(jline '.counts["미수집"]')" "2"
rm -f "$LEDGER_DIR/metrics"

# --- 3. 그림자 첫 압축·전환 창·manual 제외 --------------------------------------------
reset_all
R3=20260903-aaaaaaa3
mk_rundir "$R3"
mk_stream "$STATE/run/$R3/log/S1#1.json" 1
mk_stream "$STATE/run/$R3/log/S2#1.json" 1
SWITCH_AT=$(ts 1000)
mk_ledger "$R3" \
  "$(sr_row S1 S1 review 1 sid-s '정상 완료' '300000(argv)' '~/.claude')" \
  "$(sr_row S2 S2 review 1 sid-t '정상 완료' '300000(argv)' '~/.claude')" \
  "$(shift_row 1 상한 "$SWITCH_AT" sid-shift2 '~/.claude-cc' '300000(레인)')" \
  "$(cycle_row S1 1 0)" "$(cycle_row S2 1 0)"
# sid-s: 첫 auto 기록이 창의 105% 를 넘는다(창이 켜지기 전부터 들고 있던 컨텍스트) → 그림자.
# manual 기록 하나가 섞여 있다.
{
  tl_assist 10 s1 1000 1000 1000
  tl_boundary 20 sid-s "" auto 400000 50000 3000 350000
  tl_assist 21 s2 1000 5000 0
  tl_boundary 30 sid-s "" manual 100000 40000 1000 410000
  tl_boundary 40 sid-s "" auto 200000 50000 2000 560000
  tl_assist 41 s3 1000 7000 0
  tl_assist 50 s4 1000 0 1000
} | mk_transcript "$HOME_A" -repo sid-s
# sid-t: 요청 셋과 압축 하나가 전환 시각부터 900초 안에 있다 → 순 효과에서 빠진다.
{
  tl_assist 1010 t1 1000 1000 1000
  tl_boundary 1100 sid-t "" auto 200000 50000 2000 150000
  tl_assist 1101 t2 1000 6000 0
  tl_assist 1200 t3 1000 0 1000
  tl_assist 3000 t4 1000 0 1000
} | mk_transcript "$HOME_A" -repo sid-t
collect
check "3: 그림자 첫 압축이 A3 에 따로 표시된다" "$(jsum '.strata["review|정상 완료|~/.claude"].A3.shadow')" "1"
check "3: 그림자 첫 압축은 순 효과에서 빠진다" "$(jrec "$R3" '.stages[0].net_token')" "$((150000 - 7000))"
check "3: manual 기록은 제외되고 수가 인쇄된다" "$(jline '.excluded.manual')" "1"
check "3: manual 기록은 A3 의 압축 횟수에 들지 않는다" "$(jsum '.strata["review|정상 완료|~/.claude"].A3.count')" "1"
check "3: 전환 창 안의 요청이 순 효과에서 빠지고 수가 인쇄된다" "$(jline '.excluded.switch_window')" "3"
check "3: 전환 창 안의 압축 기록도 순 효과에서 빠진다" "$(jrec "$R3" '.stages[1].net_token')" "0"
check "3: 요약이 쓰인 전환 창 폭을 인쇄한다" "$(jsum '.switch_window_s')" "900"
collect --recollect --switch-window 30
check "3: --switch-window 로 폭을 바꾸면 인쇄 값도 바뀐다" "$(jsum '.switch_window_s')" "30"
check "3: 좁힌 폭(30초)에서는 전환 뒤 10초의 요청 하나만 남고 나머지는 다시 든다" "$(jline '.excluded.switch_window')" "1"

# --- 4. 트리거 — T2·T3·T4·T5·T7 각각 홀로, 그리고 대조군 ---------------------------------
fire_ids() { jline '[.fired[].signature] | sort | join(",")'; }

# T2 — 종단 줄 없음 ∧ 종단 부류 ∉ {크래시, 외부 종료}.
reset_all
R4=20260904-aaaaaaa4
mk_rundir "$R4"
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
{ tl_assist 10 q1 1000 1000 1000; tl_boundary 20 sid-q "" auto 267000 50000 100 217000; tl_assist 21 q2 1 1 1; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: T2 는 종단 줄 없는 정상 완료 스테이지에서 홀로 발화한다" "$(fire_ids)" "T2/review"
reset_all
mk_rundir "$R4"
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '크래시' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
collect
check "4: 크래시 스테이지에 종단 줄이 없어도 T2 는 발화하지 않는다" "$(fire_ids)" ""
reset_all
mk_rundir "$R4"
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '외부 종료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
collect
check "4: 외부 종료 스테이지도 T2 의 범위 밖이다" "$(fire_ids)" ""

# T3 — 델타의 모든 행에 압축 창 키가 없다(P0 는 있어 T5 는 서지 않는다).
reset_all
mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' __none__ '~/.claude')" "$(cycle_row S1 1 0)"
{ tl_assist 10 q1 1000 1000 1000; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: T3 는 압축 창 키가 전혀 없는 회차에서 홀로 발화한다" "$(fire_ids)" "T3/review"
check "4: 키가 없는 행은 실험 이전 행이지 거부가 아니다" "$(jsum '.rejected_window')" "0"

# T4 — 창이 정수인데 최대 컨텍스트가 절단 지점을 넘겼음에도 auto 압축이 0건.
reset_all
mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
{ tl_assist 10 q1 1000 1000 1000; tl_assist 20 q2 10000 10000 260000; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: T4 는 절단 지점을 넘긴 컨텍스트에 압축 0건일 때 홀로 발화한다" "$(fire_ids)" "T4/review"
reset_all
mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
{ tl_assist 10 q1 1000 1000 1000; tl_assist 20 q2 10000 10000 200000; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: 절단 지점에 닿은 적 없는 스테이지에서는 T4 가 발화하지 않는다" "$(fire_ids)" ""

# T5 — 판정 필드(압축 창 값·조인된 P0)가 모든 행에서 비어 있다.
reset_all
mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' '-' '~/.claude')"
{ tl_assist 10 q1 1000 1000 1000; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: T5 는 판정 필드가 전부 빈 회차에서 홀로 발화한다" "$(fire_ids)" "T5/review"

# T7 — 유도 절단(창 − 33000)과 auto preTokens 하위 5% 분위의 차가 ±5% 밖.
t7_fixture() {
  # t7_fixture <기록된 창> <preTokens>
  reset_all
  mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
  mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' "$1(argv)" '~/.claude')" "$(cycle_row S1 1 0)"
  { tl_assist 10 q1 1000 1000 1000; tl_boundary 20 sid-q "" auto "$2" 50000 100 $(( $2 - 50000 )); tl_assist 21 q2 1 1 1; } \
    | mk_transcript "$HOME_A" -repo sid-q
  collect
}
t7_fixture 300000 217000
check "4: 기록된 창 300000 에 관측 절단 217000 이면 T7 이 발화한다" "$(fire_ids)" "T7/review"
t7_fixture 250000 217000
check "4: 인접 창 250000 으로 기록됐으면 같은 관측에서 발화하지 않는다(창을 가른다)" "$(fire_ids)" ""
t7_fixture 300000 277000
check "4: 대역 안(+3.7%)의 어긋남으로는 T7 이 발화하지 않는다" "$(fire_ids)" ""
t7_fixture 300000 252000
check "4: 대역 밖(−5.6%)의 어긋남으로는 T7 이 발화한다" "$(fire_ids)" "T7/review"

# 목록 밖 조건 — 건강한 런은 아무것도 내지 않는다.
reset_all
mk_rundir "$R4"; mk_stream "$STATE/run/$R4/log/S1#1.json" 1
mk_ledger "$R4" "$(sr_row S1 S1 review 1 sid-q '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 0)"
{ tl_assist 10 q1 1000 1000 1000; tl_boundary 20 sid-q "" auto 267000 50000 100 217000; tl_assist 21 q2 1 1 1; } | mk_transcript "$HOME_A" -repo sid-q
collect
check "4: 결함 형태 조건이 없으면 아무 트리거도 발화하지 않는다" "$(fire_ids)" ""
collect
check "4: 그 회차에 새로 들어온 행이 없으면 어떤 트리거도 발화하지 않는다" "$(fire_ids)" ""
check "4: 새 런이 없는 회차의 new_runs 는 비어 있다" "$(jline '.new_runs | length')" "0"

# T1 — 입력 파일 0건 위의 집계가 비어 있지 않다(옛 기록만 남은 디렉터리).
rm -f "$LEDGER_DIR"/*.md
collect
check "4: T1 은 입력 파일이 0건인데 집계가 비어 있지 않을 때 발화한다" "$(fire_ids)" "T1/-"

# --- 5. T6 — 규약 일곱·워밍업·P0 거부권·unknown·닫기 -------------------------------------
# 회차마다 새 런 하나를 넣는다 — 트리거는 델타에만 걸리므로 연속은 회차 수로만 오른다.
t6_run() {
  # t6_run <run-id> <창> <dropped> <rebuild> <dur_ms> <wall_s> <P0|__none__> [둘째 스테이지 창]
  local rid="$1" win="$2" dropped="$3" rebuild="$4" dur="$5" wall="$6" p0="$7" win2="${8:-}"
  local sid="sid-$rid" rows
  mk_rundir "$rid"; mk_stream "$STATE/run/$rid/log/S1#1.json" 1
  rows="$(sr_row S1 S1 review 1 "$sid" '정상 완료' "$win(argv)" '~/.claude')"
  if [ -n "$win2" ]; then
    mk_stream "$STATE/run/$rid/log/S2#1.json" 1
    rows="$rows
$(sr_row S2 S2 review 1 "$sid-2" '정상 완료' "$win2(argv)" '~/.claude')
$(cycle_row S2 1 0)"
    { tl_assist 10 b1 1000 1000 1000; tl_boundary 20 "$sid-2" "" auto 217000 117000 100 100000; tl_assist 21 b2 1 1 1; tl_assist 30 b3 1 1 1; } \
      | mk_transcript "$HOME_A" -repo "$sid-2"
  fi
  mk_ledger "$rid" "$rows" "$(cycle_row S1 1 "$p0")"
  # preTokens 는 창 300000 의 유도 절단 지점(267000)에 맞춘다 — T7 이 끼어들지 않게.
  { tl_assist 10 a1 1000 1000 1000
    tl_boundary 20 "$sid" "" auto 267000 $((267000 - dropped)) "$dur" "$dropped"
    tl_assist 21 a2 1000 "$rebuild" 0
    tl_assist $((10 + wall)) a3 1 1 1
  } | mk_transcript "$HOME_A" -repo "$sid"
  collect
}
strat() { jline ".strata[\"review|$1\"].$2"; }
reset_all
t6_run 20260905-aaaaaa01 300000 100000 1000 1000 1000 5
check "5: 첫 회차의 층은 워밍업이다" "$(strat 300000 warmup)" "true"
t6_run 20260905-aaaaaa02 300000 100000 1000 1000 1000 5
t6_run 20260905-aaaaaa03 300000 100000 1000 1000 1000 5
check "5: 선행 회차 둘까지는 워밍업이다" "$(strat 300000 warmup)" "true"
t6_run 20260905-aaaaaa04 300000 10000 5000 100000 100 5
check "5: 선행 회차 셋이면 평가되고 두 항이 나쁜 회차는 연속 1 이다" "$(strat 300000 consecutive_bad)" "1"
check "5: 연속 1 로는 발화하지 않는다" "$(fire_ids)" ""
t6_run 20260905-aaaaaa05 300000 10000 5000 100000 100 5
check "5: 두 항이 나쁜 회차 연속 2" "$(strat 300000 consecutive_bad)" "2"
# 창이 섞인 회차 — 올리지도 리셋하지도 않고 평가하지 않는다.
t6_run 20260905-aaaaaa06 300000 10000 5000 100000 100 5 250000
check "5: 창이 섞인 회차는 mixed_window 로 기록된다" "$(jline '.mixed_window')" "true"
check "5: 섞인 회차는 연속을 올리지 않는다" "$(strat 300000 consecutive_bad)" "2"
check "5: 섞인 회차는 T6 을 평가하지 않는다" "$(fire_ids)" ""
# 프로브 실패 회차 — 네 필드 중 하나가 빠졌다.
R6P=20260905-aaaaaa07
mk_rundir "$R6P"; mk_stream "$STATE/run/$R6P/log/S1#1.json" 1
mk_ledger "$R6P" "$(sr_row S1 S1 review 1 sid-p '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 5)"
{ tl_assist 10 p1 1000 1000 1000; tl_boundary 20 sid-p "" auto 60000 50000 100000 10000 camel durationMs; tl_assist 21 p2 1 5000 0; tl_assist 110 p3 1 1 1; } \
  | mk_transcript "$HOME_A" -repo sid-p
collect
check "5: 네 필드 중 하나가 빠지면 저널에 프로브 실패가 적힌다" "$(jline '.probe')" "프로브 실패"
check "5: 프로브 실패 회차는 연속을 건드리지 않는다" "$(strat 300000 consecutive_bad)" "2"
check "5: 프로브 실패 회차는 T6 을 평가하지 않는다" "$(fire_ids)" ""
t6_run 20260905-aaaaaa08 300000 10000 5000 100000 100 5
check "5: 두 항이 나쁜 회차 연속 3 에서 T6 이 발화한다" "$(fire_ids)" "T6/review"
check "5: 연속 수는 저널에서 온다(요약 파일에는 없다)" "$(jsum 'tostring | test("consecutive")')" "false"
# 증분 항등이 깨진 회차도 프로브 실패다.
R6Q=20260905-aaaaaa09
mk_rundir "$R6Q"; mk_stream "$STATE/run/$R6Q/log/S1#1.json" 1
mk_ledger "$R6Q" "$(sr_row S1 S1 review 1 sid-r '정상 완료' '300000(argv)' '~/.claude')" "$(cycle_row S1 1 5)"
{ tl_assist 10 r1 1000 1000 1000; tl_boundary 20 sid-r "" auto 60000 50000 100 10000; tl_boundary 30 sid-r "" auto 60000 50000 100 30000; tl_assist 31 r2 1 1 1; } \
  | mk_transcript "$HOME_A" -repo sid-r
collect
check "5: 증분 항등이 깨진 기록이 있으면 프로브 실패다" "$(jline '.probe')" "프로브 실패"
# 한 항만 나쁜 회차는 발화하지 않는다 — 토큰 항은 나쁘고 시간 항은 좋다.
t6_run 20260905-aaaaaa10 300000 10000 5000 10 1000 5
check "5: 한 항만 나쁜 회차는 연속을 0 으로 되돌린다" "$(strat 300000 consecutive_bad)" "0"
check "5: 한 항만 나쁜 회차는 발화하지 않는다" "$(fire_ids)" ""
# 닫기 — 한 회차의 반전으로는 닫히지 않고 연속 3 에서만 닫힌다.
t6_run 20260905-aaaaaa11 300000 200000 1000 10 2000 5
check "5: 두 항이 좋은 회차 하나로는 닫히지 않는다" "$(jline '.close | length')" "0"
t6_run 20260905-aaaaaa12 300000 200000 1000 10 2000 5
t6_run 20260905-aaaaaa13 300000 200000 1000 10 2000 5
check "5: 두 항이 좋은 회차 연속 3 에서 닫기 서명이 실린다" "$(jline '.close | join(",")')" "T6/review"
# P0 거부권 — 두 항이 좋아도 P0 가 기준 중앙값보다 줄면 나쁜 회차다.
t6_run 20260905-aaaaaa14 300000 200000 1000 10 2000 1
check "5: 두 항이 좋아도 P0 가 기준 대비 줄면 거부권이 발화 방향으로 센다" "$(strat 300000 consecutive_bad)" "1"
check "5: 거부권 회차는 좋은 연속을 끊는다" "$(strat 300000 consecutive_good)" "0"
# unknown — 그 층에 P0 없는 행이 하나라도 있으면 거부권을 평가하지 않는다.
t6_run 20260905-aaaaaa15 300000 200000 1000 10 2000 __none__
check "5: P0 가 unknown 이면 거부권을 평가하지 않는다(좋은 회차로 남는다)" "$(strat 300000 consecutive_good)" "1"
check "5: unknown 은 0 으로 읽히지 않는다" "$(strat 300000 p0)" "unknown"
# 창 변경 리셋 — 나쁜 회차 둘 뒤 창이 바뀌면 새 층이고 계수는 0 이다.
t6_run 20260905-aaaaaa16 300000 10000 5000 100000 100 5
t6_run 20260905-aaaaaa17 300000 10000 5000 100000 100 5
check "5: (선행) 나쁜 회차 연속 2" "$(strat 300000 consecutive_bad)" "2"
t6_run 20260905-aaaaaa18 250000 10000 5000 100000 100 5
check "5: 창 값이 바뀌면 계수가 0 으로 리셋된다" "$(strat 250000 consecutive_bad)" "0"
check "5: 바뀐 창의 층은 워밍업이다" "$(strat 250000 warmup)" "true"
check "5: 창이 바뀐 회차는 발화하지 않는다" "$(fire_ids)" ""
# 전환 창을 빼고 나면 표본이 부족한 회차 — 평가하지 않는다.
R6S=20260905-aaaaaa19
mk_rundir "$R6S"; mk_stream "$STATE/run/$R6S/log/S1#1.json" 1
mk_ledger "$R6S" "$(sr_row S1 S1 review 1 sid-u '정상 완료' '300000(argv)' '~/.claude')" \
  "$(shift_row 1 상한 "$(ts 5)" sid-sh '~/.claude' '300000(레인)')" "$(cycle_row S1 1 5)"
{ tl_assist 10 u1 1000 1000 1000; tl_boundary 20 sid-u "" auto 60000 50000 100000 10000; tl_assist 21 u2 1 5000 0; tl_assist 110 u3 1 1 1; } \
  | mk_transcript "$HOME_A" -repo sid-u
collect
# 직전 300000 층의 연속 2(회차 16·17)가 그대로 넘어온다.
check "5: 전환 창을 빼고 표본이 없는 회차는 연속을 건드리지 않는다" "$(strat 300000 consecutive_bad)" "2"
check "5: 그 회차는 T6 을 발화하지 않는다" "$(fire_ids)" ""

printf '\n통과 %s · 실패 %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
