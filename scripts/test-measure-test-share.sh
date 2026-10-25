#!/usr/bin/env bash
# Test scripts/measure-test-share.sh against synthetic ledgers and transcripts
# built in a temporary directory.
#
# Nothing here reads real session history: the lane root is the fixture
# directory, and the script has no default that could point it anywhere else.
#
# What is pinned:
#   - only `<date>-<hex>.md` files are ledgers; side files that carry
#     implement rows of their own are ignored;
#   - sessions: implement rows only, the segment's repo must match, a repeated
#     session id is one session, a missing transcript is `기록 없음` and leaves
#     the sums;
#   - order and windows: run start is the first `run` row's `시작=`, sessions
#     sort by it, `--since`/`--until`/`--first`/`--session` cut the list;
#   - time: foreground and background intervals, their union, the 15-minute
#     cut that a spanning test interval suspends, unclosed background tests and
#     the same-set relaunch count;
#   - notifications: only the two delivered shapes are read (a `type: user`
#     string and a `queued_command` attachment prompt); quoted notification
#     text and queue records are not, and when shapes overlap the earliest
#     time wins;
#   - classification: every entry of the script's fixed list in six forms, the
#     list itself, and commands that only mention a test command;
#   - the two closing lines and the three verdicts;
#   - usage errors exit 2.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
measure="$script_dir/measure-test-share.sh"

# The fixture lines below spell gate and test commands; nothing here runs the
# gate family, but the suite follows the same isolation lines as those that do.
for v in $(compgen -e | grep '^CC_PIPELINE_' || true); do unset "$v"; done
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
CC_CMDS_DASHBOARD=off
export CC_CMDS_DASHBOARD

failures=0
passed=0
pass() { passed=$((passed + 1)); echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1" >&2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-measure-test-share.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LEDGERS="$WORK/ledgers"
LANES="$WORK/lanes"
mkdir -p "$LEDGERS" "$LANES"

GATE_ABS=/Users/x/.local/state/cc-cmds/run/r/plugin/cc-cmds/orchestrator/gate.sh

# ---- transcript writers ------------------------------------------------------
# Every timestamp carries milliseconds, the shape the real records have.
ts_of() { jq -n -r --argjson t "$1" '$t | todate | sub("Z$"; ".250Z")'; }
j_bash() { # file epoch id bg command
  jq -n -c --arg ts "$(ts_of "$2")" --arg id "$3" --argjson bg "$4" --arg cmd "$5" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"Bash",input:{command:$cmd,run_in_background:$bg}}]}}' >> "$1"
}
j_res() { # file epoch id text
  jq -n -c --arg ts "$(ts_of "$2")" --arg id "$3" --arg x "$4" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:$x}]}}' >> "$1"
}
note_text() { # task-id
  printf '<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n</task-notification>' "$1"
}
j_note() { # file epoch task-id
  jq -n -c --arg ts "$(ts_of "$2")" --arg x "$(note_text "$3")" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:$x}}' >> "$1"
}
j_queued() { # file epoch task-id — a notification delivered mid-turn
  jq -n -c --arg ts "$(ts_of "$2")" --arg x "$(note_text "$3")" \
    '{type:"attachment",timestamp:$ts,attachment:{type:"queued_command",prompt:$x,commandMode:"task-notification",origin:{kind:"task-notification"}}}' >> "$1"
}
j_quote_said() { # file epoch task-id — notification text quoted in assistant text
  jq -n -c --arg ts "$(ts_of "$2")" --arg x "seen: $(note_text "$3")" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"text",text:$x}]}}' >> "$1"
}
j_quote_res() { # file epoch task-id — notification text quoted in a tool result
  jq -n -c --arg ts "$(ts_of "$2")" --arg x "$(note_text "$3")" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"g",content:$x}]}}' >> "$1"
}
j_queue_op() { # file epoch task-id — a queue bookkeeping record
  jq -n -c --arg ts "$(ts_of "$2")" --arg x "$(note_text "$3")" \
    '{type:"queue-operation",operation:"enqueue",timestamp:$ts,content:$x}' >> "$1"
}
j_edit() { # file epoch
  jq -n -c --arg ts "$(ts_of "$2")" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:"e",name:"Edit",input:{file_path:"x"}}]}}' >> "$1"
}
j_text() { # file epoch
  jq -n -c --arg ts "$(ts_of "$2")" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"text",text:"ok"}]}}' >> "$1"
}

row_run()  { printf -- '- `run` | 교대=%s | run-id=%s | 시작=%s | prev=0\n' "$2" "$3" "$4" >> "$1"; }
row_seg()  { printf -- '- `segment` | 교대=0 | id=%s | 상태=계획됨 | 레포=%s | prev=0\n' "$2" "$3" >> "$1"; }
row_res()  { printf -- '- `stage-result` | 교대=1 | 세그먼트=%s | 스테이지=%s | 종류=%s | 종료 코드=0 | 세션 id=%s | 레인=%s | 종단 부류=정상 완료 | prev=0\n' "$2" "$2" "$3" "$4" "$5" >> "$1"; }

S1=11111111-0000-4000-8000-000000000001
S2=11111111-0000-4000-8000-000000000002
S3=11111111-0000-4000-8000-000000000003
S8=11111111-0000-4000-8000-000000000008
S9=11111111-0000-4000-8000-000000000009
SX=11111111-0000-4000-8000-00000000000a

mkdir -p "$LANES/.lane1/projects/p" "$LANES/.lane2/projects/q"

# ---- run 1: one session, foreground and background tests -------------------
L1="$LEDGERS/20261001-aaaaaaa1.md"
row_run "$L1" 0 20261001-aaaaaaa1 2026-10-01T00:00:00Z
row_seg "$L1" A Nharu/cc-cmds
row_seg "$L1" B Other/repo
row_res "$L1" A implement "$S1" '~/.lane1'
row_res "$L1" A review "$S8" '~/.lane1'
row_res "$L1" B implement "$S9" '~/.lane1'
row_res "$L1" A implement "$S1" '~/.lane1'

b=$(jq -n '"2026-10-01T01:00:00Z" | fromdateiso8601')
T="$LANES/.lane1/projects/p/$S1.jsonl"
j_bash "$T" "$b" u1 false "$GATE_ABS exec --manifest \"\$M\" --rationale 'a -- b' -- bash scripts/test-gate.sh --sections 0e"
j_res  "$T" $((b + 60)) u1 "test-gate: 3 passed, 0 failed"
j_bash "$T" $((b + 120)) u2 true "make check-push CHECK_PUSH_SECTIONS=0e"
j_res  "$T" $((b + 121)) u2 "Command running in background with ID: bk1. Output is being written to: /tmp/x"
j_note "$T" $((b + 300)) bk1
j_bash "$T" $((b + 360)) u3 false "git status"
j_res  "$T" $((b + 361)) u3 "clean"
j_bash "$T" $((b + 400)) u4 true "make check-push CHECK_PUSH_SECTIONS=0e"
j_res  "$T" $((b + 401)) u4 "Command running in background with ID: bk2."
j_note "$T" $((b + 500)) bk2
j_edit "$T" $((b + 520))
j_bash "$T" $((b + 600)) u5 true "make check-push CHECK_PUSH_SECTIONS=0e"
j_res  "$T" $((b + 601)) u5 "Command running in background with ID: bk3."
j_note "$T" $((b + 700)) bk3
j_bash "$T" $((b + 2700)) u6 false "git commit -m x"
j_res  "$T" $((b + 2701)) u6 "done"
j_bash "$T" $((b + 2760)) u7 false "make check"
j_res  "$T" $((b + 2820)) u7 "ok"

# ---- run 2: an unclosed background test spanning a long gap; a session with
# no transcript; a later shift whose own start must not move the run ---------
L2="$LEDGERS/20261002-bbbbbbb2.md"
row_run "$L2" 0 20261002-bbbbbbb2 2026-10-02T10:00:00Z
row_seg "$L2" A Nharu/cc-cmds
row_res "$L2" A implement "$S2" '~/.lane2'
row_res "$L2" A implement "$S3" '~/.lane2'
row_run "$L2" 1 20261002-bbbbbbb2 2026-10-05T00:00:00Z

b=$(jq -n '"2026-10-02T11:00:00Z" | fromdateiso8601')
T="$LANES/.lane2/projects/q/$S2.jsonl"
j_bash "$T" "$b" v1 true "bash scripts/lint-x.sh"
j_res  "$T" $((b + 1)) v1 "Command running in background with ID: bq."
j_bash "$T" $((b + 1000)) v2 false "ls"
j_res  "$T" $((b + 1001)) v2 "a b"

# ---- side files that look like ledgers but are not --------------------------
for side in 20261001-aaaaaaa1.plan.md 20261001-aaaaaaa1.interview.md 20261001-aaaaaaa1.kickoff.md \
            20261001-aaaaaaa1.c2-classification.md HANDOFF-x.md r35.md rerun.md \
            20261003-dddddddd.md.aborted-never-started metrics.md metrics-2026.tsv; do
  row_run "$LEDGERS/$side" 0 side 2026-10-01T00:00:00Z
  row_seg "$LEDGERS/$side" A Nharu/cc-cmds
  row_res "$LEDGERS/$side" A implement "$SX" '~/.lane1'
done
j_bash "$LANES/.lane1/projects/p/$SX.jsonl" "$b" w1 false "make check"
j_res  "$LANES/.lane1/projects/p/$SX.jsonl" $((b + 60)) w1 "ok"

# ---- golden: runs 1 and 2 ----------------------------------------------------
TAB=$(printf '\t')
want=$(cat <<EOF
run${TAB}segment${TAB}session${TAB}stage_min${TAB}test_min${TAB}share${TAB}bg_launches${TAB}same_set_relaunch${TAB}unclosed
20261001-aaaaaaa1${TAB}A${TAB}$S1${TAB}13.7${TAB}8.3${TAB}61.0%${TAB}3${TAB}1${TAB}0
20261002-bbbbbbb2${TAB}A${TAB}$S2${TAB}16.7${TAB}16.7${TAB}100.0%${TAB}1${TAB}0${TAB}1
20261002-bbbbbbb2${TAB}A${TAB}$S3${TAB}기록 없음${TAB}-${TAB}-${TAB}-${TAB}-${TAB}-
시험 몫 = 25.0분/30.4분 = 82.4%
판정: 미달
EOF
)
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --until 2026-10-02 2>"$WORK/err")
rc=$?
if [[ "$rc" == 0 && "$got" == "$want" ]]; then
  pass "골든: 두 런의 세션 행·합·판정 (부속 파일 무시, 다른 레포·다른 종류 제외, 같은 세션 하나, 기록 없음)"
else
  fail "골든 rc=$rc"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
  cat "$WORK/err" >&2
fi
case "$got" in
  *"$SX"*) fail "부속 파일의 행이 세션으로 읽혔다" ;;
  *) pass "부속 파일·중단 원장·지표 파일의 행은 읽지 않는다" ;;
esac

# ---- windows -------------------------------------------------------------------
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-03 --until 2026-10-06 2>/dev/null)
case "$got" in
  *"$S2"*) fail "--since: 뒤 교대의 시작으로 런을 옮겼다" ;;
  *) pass "--since: 런의 시작은 첫 run 행의 시작이다 (뒤 교대가 옮기지 않는다)" ;;
esac
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-02T10:00:00Z --until 2026-10-02T23:59:59Z 2>/dev/null)
case "$got" in
  *"$S1"*) fail "--since 시각: 앞 런이 남았다" ;;
  *"$S2"*) pass "--since 시각: 그 시각에 시작한 런부터 든다" ;;
  *) fail "--since 시각: 경계의 런이 빠졌다" ;;
esac
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --until 2026-10-02 --first 2 2>/dev/null)
last=$(printf '%s\n' "$got" | tail -n 1)
if [[ "$last" == "판정: 미달" && "$got" == *"$S2"* ]]; then
  pass "--first 2: 기록 있는 세션 둘을 센다"
else
  fail "--first 2: $last"
fi
case "$got" in
  *"$S3"*) fail "--first 2: 개수를 채운 뒤의 세션이 나왔다" ;;
  *) pass "--first 2: 개수를 채우면 멈춘다" ;;
esac
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --until 2026-10-02 --first 3 2>/dev/null)
if [[ "$(printf '%s\n' "$got" | tail -n 1)" == "판정: 표본 부족" ]]; then
  pass "--first 3: 기록 없는 세션은 개수에 들지 않아 표본 부족이다"
else
  fail "--first 3: 표본 부족이 아니다"
fi
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --session "$S2" 2>/dev/null)
n=$(printf '%s\n' "$got" | grep -c "$S2" || true)
case "$got" in
  *"$S1"*) fail "--session: 다른 세션이 나왔다" ;;
  *) if [[ "$n" == 1 ]]; then pass "--session: 그 세션 하나만"; else fail "--session: 행 ${n}개"; fi ;;
esac

# ---- classification -----------------------------------------------------------
# The list is pinned here; the script's array must be exactly it.
LIST=(
  'make check'
  'make check-*'
  'make test'
  'make test-*'
  'make lint'
  'make lint-*'
  'make run/scripts/test-*.sh'
  'make run-*-selftest'
  'make rest-shard'
  'bash scripts/test-*.sh'
  'bash scripts/lint-*.sh'
  'bash scripts/check-push.sh'
  'bash plugins/cc-cmds/orchestrator/test-run.sh'
  'scripts/suite-guard.sh'
  'gate-shard'
)
script_list=$(awk -v sq="'" '/^TEST_COMMANDS=\(/ { f = 1; next } f && /^\)/ { exit } f { sub("^ *" sq, ""); sub(sq " *$", ""); print }' "$measure")
if [[ "$script_list" == "$(printf '%s\n' "${LIST[@]}")" ]]; then
  pass "분류 목록이 고정한 열다섯 항목과 같다"
else
  fail "분류 목록이 바뀌었다"
  diff <(printf '%s\n' "${LIST[@]}") <(printf '%s\n' "$script_list") >&2 || true
fi

L3="$LEDGERS/20261004-ccccccc3.md"
row_run "$L3" 0 20261004-ccccccc3 2026-10-04T00:00:00Z
row_seg "$L3" A Nharu/cc-cmds
mkdir -p "$LANES/.lane3/projects/c"
b=$(jq -n '"2026-10-04T01:00:00Z" | fromdateiso8601')
nc=0
declare -a C_CMD C_WANT
add_case() { nc=$((nc + 1)); C_CMD[$nc]="$1"; C_WANT[$nc]="$2"; }
for entry in "${LIST[@]}"; do
  cmd=${entry//\*/zz}
  add_case "$cmd" 1.0
  add_case "$cmd FOO=1" 1.0
  add_case "FOO=1 $cmd" 1.0
  add_case "$GATE_ABS exec --surface 읽기 --rationale 'run it -- then read' -- $cmd" 1.0
  add_case "$GATE_ABS exec --manifest \"\$CC_PIPELINE_MANIFEST\" --surface 읽기 -- $cmd" 1.0
  add_case "GATE_SUITE_CMD='bash scripts/test-gate.sh --sections 8b' $cmd" 1.0
done
add_case "make -C . -j 4 -f Makefile check" 1.0
add_case "make -j8 lint" 1.0
add_case "bash /Users/x/repo/scripts/test-gate.sh --sections 0e" 1.0
add_case "make readme" 0.0
add_case "bash scripts/generate-readme.sh" 0.0
add_case "git status" 0.0
add_case "echo make check" 0.0
add_case "$GATE_ABS exec --rationale 'bash scripts/test-gate.sh 를 읽는다' -- git log -1" 0.0
add_case "$GATE_ABS exec --rationale 'no separator here' bash scripts/test-gate.sh" 0.0
add_case "FOO='make check' git status" 0.0
for i in $(seq 1 "$nc"); do
  sid=$(printf '22222222-0000-4000-8000-%012d' "$i")
  row_res "$L3" A implement "$sid" '~/.lane3'
  T="$LANES/.lane3/projects/c/$sid.jsonl"
  j_bash "$T" "$b" "c$i" false "${C_CMD[$i]}"
  j_res  "$T" $((b + 60)) "c$i" "ok"
  j_text "$T" $((b + 600))
done
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-04 --until 2026-10-04 2>/dev/null)
bad_cls=0
for i in $(seq 1 "$nc"); do
  sid=$(printf '22222222-0000-4000-8000-%012d' "$i")
  tm=$(printf '%s\n' "$got" | awk -F '\t' -v s="$sid" '$3 == s { print $5 }')
  if [[ "$tm" != "${C_WANT[$i]}" ]]; then
    bad_cls=$((bad_cls + 1))
    fail "분류: 「${C_CMD[$i]}」 시험 분 $tm (기대 ${C_WANT[$i]})"
  fi
done
if (( bad_cls == 0 )); then
  pass "분류: 목록 항목마다 여섯 형태와 make 옵션은 시험으로, 언급만 한 명령은 시험이 아닌 것으로 (${nc}개)"
fi
if [[ "$(printf '%s\n' "$got" | tail -n 1)" == "판정: 달성" ]]; then
  pass "30% 미만의 몫은 달성이다"
else
  fail "달성 판정이 아니다: $(printf '%s\n' "$got" | tail -n 2 | tr '\n' ' ')"
fi

# ---- usage errors -------------------------------------------------------------
bash "$measure" --ledger-dir "$LEDGERS" >/dev/null 2>&1
if [[ "$?" == 2 ]]; then pass "--lane-root 가 없으면 종료 코드 2 (실제 홈을 가리키는 기본값이 없다)"; else fail "--lane-root 없이 2 가 아니다"; fi
bash "$measure" --lane-root "$LANES" >/dev/null 2>&1
if [[ "$?" == 2 ]]; then pass "--ledger-dir 가 없으면 종료 코드 2"; else fail "--ledger-dir 없이 2 가 아니다"; fi
bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026/10/01 >/dev/null 2>&1
if [[ "$?" == 2 ]]; then pass "형식이 틀린 --since 는 종료 코드 2"; else fail "형식이 틀린 --since 가 2 가 아니다"; fi
bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --first 0 >/dev/null 2>&1
if [[ "$?" == 2 ]]; then pass "양의 정수가 아닌 --first 는 종료 코드 2"; else fail "--first 0 이 2 가 아니다"; fi

# ---- notifications: delivered shapes, quotes, queue records, overlap ----------
L5="$LEDGERS/20261007-eeeeeee5.md"
row_run "$L5" 0 20261007-eeeeeee5 2026-10-07T00:00:00Z
row_seg "$L5" A Nharu/cc-cmds
mkdir -p "$LANES/.lane5/projects/e"
b=$(jq -n '"2026-10-07T01:00:00Z" | fromdateiso8601')
for q in 1 2 3 4; do
  sid=$(printf '33333333-0000-4000-8000-%012d' "$q")
  row_res "$L5" A implement "$sid" '~/.lane5'
  T="$LANES/.lane5/projects/e/$sid.jsonl"
  j_bash "$T" "$b" "q$q" true "make check"
  j_res  "$T" $((b + 1)) "q$q" "Command running in background with ID: bq$q."
  case $q in
    1) j_queued "$T" $((b + 300)) bq1 ;;
    2) j_quote_said "$T" $((b + 60)) bq2; j_quote_res "$T" $((b + 120)) bq2; j_note "$T" $((b + 400)) bq2 ;;
    3) j_quote_said "$T" $((b + 60)) bq3; j_queue_op "$T" $((b + 90)) bq3; j_quote_res "$T" $((b + 120)) bq3 ;;
    4) j_note "$T" $((b + 320)) bq4; j_queued "$T" $((b + 300)) bq4 ;;
  esac
  j_text "$T" $((b + 600))
done
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-07 --until 2026-10-07 2>/dev/null)
N_WANT=(
  ""
  "5.0 0|턴 도중 queued_command 첨부의 통지로 닫힌다"
  "6.7 0|어시스턴트 글·도구 결과의 인용은 무시하고 type:user 문자열 통지로 닫힌다"
  "10.0 1|인용과 큐 기록만 있으면 닫히지 않고 세션 끝까지 돈다"
  "5.0 0|두 모양이 겹치면 기록 순서와 상관없이 가장 이른 통지로 닫힌다"
)
for q in 1 2 3 4; do
  sid=$(printf '33333333-0000-4000-8000-%012d' "$q")
  row=$(printf '%s\n' "$got" | awk -F '\t' -v s="$sid" '$3 == s { print $5 " " $9 }')
  want_row=${N_WANT[$q]%%|*}
  label=${N_WANT[$q]#*|}
  if [[ "$row" == "$want_row" ]]; then
    pass "통지 $q: $label"
  else
    fail "통지 $q: $label — test_min·unclosed 「${row}」 (기대 「${want_row}」)"
  fi
done

# A floor on the pass count, so a case that silently stops running fails here.
if (( failures == 0 && passed < 19 )); then
  fail "통과 수 $passed 가 하한 19 보다 적다 — 경우가 조용히 빠졌다"
fi

echo "test-measure-test-share: $passed passed, $failures failed"
(( failures == 0 ))
