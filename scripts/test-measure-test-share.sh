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
#   - idle sessions: no test command and no `git commit` call is `제외`, out
#     of the sums and of `--first`; a commit alone or a test alone counts;
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

# ---- idle sessions: no test command and no commit -----------------------------
L6="$LEDGERS/20261008-fffffff6.md"
row_run "$L6" 0 20261008-fffffff6 2026-10-08T00:00:00Z
row_seg "$L6" A Nharu/cc-cmds
mkdir -p "$LANES/.lane6/projects/f"
b=$(jq -n '"2026-10-08T01:00:00Z" | fromdateiso8601')
I1=44444444-0000-4000-8000-000000000001
I2=44444444-0000-4000-8000-000000000002
I3=44444444-0000-4000-8000-000000000003
for sid in "$I1" "$I2" "$I3"; do row_res "$L6" A implement "$sid" '~/.lane6'; done
T="$LANES/.lane6/projects/f/$I1.jsonl"
j_bash "$T" "$b" i1 false "git status"
j_res  "$T" $((b + 1)) i1 "clean"
j_edit "$T" $((b + 60))
j_text "$T" $((b + 300))
T="$LANES/.lane6/projects/f/$I2.jsonl"
j_bash "$T" "$b" i2 false "$GATE_ABS exec --surface 워크트리쓰기 -- git commit -q -m x"
j_res  "$T" $((b + 1)) i2 "done"
j_text "$T" $((b + 600))
T="$LANES/.lane6/projects/f/$I3.jsonl"
j_bash "$T" "$b" i3 false "make check"
j_res  "$T" $((b + 60)) i3 "ok"
j_text "$T" $((b + 600))
want=$(cat <<EOF
run${TAB}segment${TAB}session${TAB}stage_min${TAB}test_min${TAB}share${TAB}bg_launches${TAB}same_set_relaunch${TAB}unclosed
20261008-fffffff6${TAB}A${TAB}$I1${TAB}5.0${TAB}0.0${TAB}제외${TAB}0${TAB}0${TAB}0
20261008-fffffff6${TAB}A${TAB}$I2${TAB}10.0${TAB}0.0${TAB}0.0%${TAB}0${TAB}0${TAB}0
20261008-fffffff6${TAB}A${TAB}$I3${TAB}10.0${TAB}1.0${TAB}10.0%${TAB}0${TAB}0${TAB}0
시험 몫 = 1.0분/20.0분 = 5.0%
판정: 달성
EOF
)
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-08 --until 2026-10-08 2>/dev/null)
if [[ "$got" == "$want" ]]; then
  pass "시험도 커밋도 없는 세션은 제외로 보이고 합에서 빠진다 (커밋만 있거나 시험만 있으면 센다)"
else
  fail "제외 세션 골든"
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
fi
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-08 --until 2026-10-08 --first 2 2>/dev/null)
if [[ "$(printf '%s\n' "$got" | tail -n 1)" == "판정: 달성" && "$got" == *"$I3"* ]]; then
  pass "--first 2: 제외한 세션은 개수에 들지 않는다"
else
  fail "--first 2: 제외한 세션이 개수에 들었다"
fi
got=$(bash "$measure" --ledger-dir "$LEDGERS" --lane-root "$LANES" --since 2026-10-08 --until 2026-10-08 --first 3 2>/dev/null)
if [[ "$(printf '%s\n' "$got" | tail -n 1)" == "판정: 표본 부족" ]]; then
  pass "--first 3: 센 세션이 둘뿐이면 표본 부족이다"
else
  fail "--first 3: 표본 부족이 아니다"
fi

# ---- the run-log report ---------------------------------------------------------
# A fixture repository holds a copy of the script, the ledgers under its main
# checkout and the boundary file's history; XDG_STATE_HOME points at the fixture
# state directory in every call, so no call can reach a real run root.
STATE="$WORK/state"
RUNS="$STATE/cc-cmds/run"
FREPO="$WORK/repo"
EMPTY_STATE="$WORK/empty-state"
mkdir -p "$RUNS" "$EMPTY_STATE" "$FREPO/scripts" "$FREPO/docs/pipeline-run"
cp "$measure" "$FREPO/scripts/measure-test-share.sh"
fgit() { # commit time, then the git arguments
  local at=$1
  shift
  (cd "$FREPO" && GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@") >/dev/null 2>&1
}
fgit 2026-09-01T00:00:00Z init -q
fgit 2026-09-01T00:00:00Z commit -q --allow-empty -m base
rep() { XDG_STATE_HOME="$STATE" bash "$FREPO/scripts/measure-test-share.sh" "$@" 2>"$WORK/err"; }
cell() { # section, then the leading columns joined by | — prints the rest of that row
  awk -F '\t' -v sec="## $1" -v want="$2" '
    /^## / { on = ($0 == sec); next }
    on {
      n = split(want, W, "|"); ok = 1
      for (i = 1; i <= n; i++) if ($i != W[i]) ok = 0
      if (!ok) next
      r = ""
      for (i = n + 1; i <= NF; i++) r = r (r == "" ? "" : " ") $i
      print r
    }'
}
is() { # label, got, want
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — 「$2」 (기대 「$3」)"; cat "$WORK/err" >&2; fi
}
ep() { jq -n -r --arg t "$1" '$t | fromdateiso8601'; }

j_note_sys() { # file tool_use_id status summary output_file
  jq -n -c --arg id "$2" --arg s "$3" --arg m "$4" --arg o "$5" \
    '{type:"system",subtype:"task_notification",task_id:"k",tool_use_id:$id,status:$s,summary:$m,output_file:$o}' >> "$1"
}
j_err() { # file epoch id text — a failed tool result
  jq -n -c --arg ts "$(ts_of "$2")" --arg id "$3" --arg x "$4" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:true,content:$x}]}}' >> "$1"
}
row_stage() { # ledger segment stage version kind
  printf -- '- `stage-result` | 교대=1 | 세그먼트=%s | 스테이지=%s | 종류=%s | 종료 코드=0 | 실행 버전=%s | prev=0\n' "$2" "$3" "$5" "$4" >> "$1"
}
row_ci() { printf -- '- `CI 처분` | 교대=2 | 세그먼트=%s | PR=1 | 처분=재실행 | 상태=요청 | 관측=%s | prev=0\n' "$2" "$3" >> "$1"; }
short_stage() { # log, start epoch — one minute of make lint in a two-minute stage
  mkdir -p "$(dirname "$1")"
  j_bash "$1" "$2" s1 false "make lint"
  j_res  "$1" $(($2 + 60)) s1 "ok"
  j_text "$1" $(($2 + 120))
}

# Run r1: before the boundary. A#1 holds the classes and the check-push ends.
R1=20261101-00000001
FL="$FREPO/docs/pipeline-run/$R1.md"
row_run "$FL" 0 "$R1" 2026-11-01T00:00:00Z
row_run "$FL" 1 "$R1" 2026-11-20T00:00:00Z
row_seg "$FL" A Nharu/cc-cmds
row_seg "$FL" B Other/repo
row_stage "$FL" A A 1 implement
row_stage "$FL" A A 2 implement
row_stage "$FL" B B 1 implement
row_stage "$FL" - V 1 reconverge
row_stage "$FL" - D1 1 design
row_ci "$FL" A 2026-11-01T05:00:00Z
row_ci "$FL" A 2026-11-11T05:00:00Z
row_ci "$FL" B 2026-11-01T05:00:00Z
mkdir -p "$RUNS/$R1/log"
T="$RUNS/$R1/log/A#1.json"
b=$(ep 2026-11-01T01:00:00Z)
CP="make check-push CHECK_PUSH_SECTIONS=5"
OUT1="$WORK/cp1.output"
DEFER='(유도로만 들어왔고 직접 대상이 바뀌지 않음, PR 의 rest-tests 가 돌린다)'
{
  echo "2026-11-01T01:00:00Z [run] 게이트 통과 — exec"
  echo "check-push: CI 몫 — run/a $DEFER"
  echo "check-push: CI 몫 — run/a $DEFER"
  echo "check-push: CI 몫 — run/b $DEFER"
  echo "check-push: CI 몫 — run/c (이 커밋의 시도에서 시간 예산에 두 번 잘림, PR 의 rest-tests 가 돌린다)"
  echo "check-push: CI 몫 — run/d (로컬에서 돌리지 않았다)"
  echo "note check-push: CI 몫 — run/e $DEFER"
  echo "check-push: 판정 — 미완(시간 예산 20초) · 끝난 항목 lint"
} > "$OUT1"
BG="Command running in background with ID: k1. Output is being written to: /x"
# 첫 실행, 600 s in the background: the notification has no time of its own.
j_bash "$T" "$b" p1 true "$GATE_ABS exec --rationale 'x' -- $CP"
j_res  "$T" $((b + 1)) p1 "$BG"
j_note_sys "$T" p1 failed 'Background command "x" failed with exit code 2' "$OUT1"
j_text "$T" $((b + 600))
# 같은 입력, 60 s, stopped at its limit. A rationale that names git commit is not
# an edit.
j_bash "$T" $((b + 600)) g0 false "$GATE_ABS exec --rationale 'git commit 전 확인' -- git status"
j_res  "$T" $((b + 600)) g0 "clean"
j_bash "$T" $((b + 600)) p2 true "$CP"
j_res  "$T" $((b + 601)) p2 "$BG"
j_note_sys "$T" p2 stopped 'Background command "x" was stopped after reaching its background time limit' "$WORK/none.output"
j_text "$T" $((b + 660))
# 고친 뒤 전부 재실행, 120 s, exit 1.
j_edit "$T" $((b + 660))
j_bash "$T" $((b + 660)) p3 true "$CP"
j_res  "$T" $((b + 661)) p3 "$BG"
j_note_sys "$T" p3 failed 'Background command "x" failed with exit code 2' ""
j_text "$T" $((b + 780))
# 고친 뒤 일부 재실행, 180 s in the foreground, exit 0.
j_bash "$T" $((b + 780)) g1 false "git commit -m x"
j_res  "$T" $((b + 780)) g1 "done"
j_bash "$T" $((b + 780)) p4 false "CHECK_PUSH_SECTIONS=6 make check-push"
j_res  "$T" $((b + 960)) p4 "ok"
# 고정 검사, 60 s, whatever ran before it.
j_bash "$T" $((b + 960)) p5 false "make check-push"
j_res  "$T" $((b + 1020)) p5 "ok"
# Refused calls did not run: a hook, and the gate on a stale digest.
j_bash "$T" $((b + 1020)) x1 false "make check-cheap"
j_err  "$T" $((b + 1050)) x1 "PreToolUse:Bash hook error: no"
j_bash "$T" $((b + 1050)) x2 false "$GATE_ABS exec -- make check-cheap"
j_err  "$T" $((b + 1080)) x2 "Exit code 4
stale snapshot digest"
# A failing test behind the gate did run.
j_bash "$T" $((b + 1080)) x3 false "$GATE_ABS exec -- make check-items CHECK_PUSH_SECTIONS=5"
j_err  "$T" $((b + 1140)) x3 "Exit code 2
[run] 게이트 통과 — exec"
# A foreground lint moved to the background: its end is the notification, 240 s.
j_bash "$T" $((b + 1140)) l1 false "make lint readme"
j_res  "$T" $((b + 1200)) l1 "Command exceeded its limit and was moved to the background with ID: k9."
j_note_sys "$T" l1 completed 'Background command "x" completed (exit code 0)' ""
j_text "$T" $((b + 1380))
# A notification ahead of its foreground result changes nothing: 60 s, 같은 입력.
j_bash "$T" $((b + 1380)) l2 false "make lint readme"
j_note_sys "$T" l2 completed 'Lint' ""
j_res  "$T" $((b + 1440)) l2 "ok"
# One call per remaining tool, 60 s each.
t=$((b + 1440))
for c in "bash scripts/test-gate.sh --sections 5" "bash scripts/test-x.sh" "bash scripts/check-push.sh --self-test" "make run-x-selftest" "make check-push-verify"; do
  j_bash "$T" "$t" "m$t" false "$c"
  j_res  "$T" $((t + 60)) "m$t" "ok"
  t=$((t + 60))
done
# 1740: a gap with no test, then a background test nothing closed, 100 s.
j_text "$T" $((b + 1840))
j_bash "$T" $((b + 1840)) u1 true "make check-push CHECK_PUSH_GOALS=g"
j_res  "$T" $((b + 1841)) u1 "$BG"
j_text "$T" $((b + 1940))

short_stage "$RUNS/$R1/log/A#2.json" "$(ep 2026-11-12T00:00:00Z)"
short_stage "$RUNS/$R1/log/B#1.json" "$b"
short_stage "$RUNS/$R1/log/D1#1.json" "$b"
short_stage "$RUNS/$R1/log/V#1.json" "$b"
short_stage "$RUNS/$R1/log/Z#1.json" "$b"
short_stage "$RUNS/$R1/log/shift-1.json" "$b"
printf '{"type":"system","subtype":"init"}\n' > "$RUNS/$R1/log/A#3.json"
# Run r2 has no ledger.
short_stage "$RUNS/20261102-00000002/log/A#1.json" "$(ep 2026-11-02T00:00:00Z)"

# No boundary: one group.
got=$(rep --since 2026-10-30)
is "보고: 경계가 없으면 종료 코드 0 이고 한 묶음이다" "$? $(printf '%s\n' "$got" | cell 원인\ \(스테이지당\ 분\) 전체 | cut -d' ' -f1)" "0 3"
case "$got" in *"경계: 없음"*) pass "보고: 경계 없음을 적는다" ;; *) fail "보고: 경계 없음 줄이 없다" ;; esac

# The boundary file enters the first-parent history by a merge at 2026-11-10;
# its own commit is older and is not the boundary. A later commit does not move it.
fgit 2026-11-05T00:00:00Z checkout -q -b side
: > "$FREPO/scripts/check-push-ci.tsv"
fgit 2026-11-05T00:00:00Z add scripts/check-push-ci.tsv
fgit 2026-11-05T00:00:00Z commit -q -m list
fgit 2026-11-05T00:00:00Z checkout -q -
fgit 2026-11-10T00:00:00Z merge -q --no-ff -m merge side
echo x > "$FREPO/scripts/check-push-ci.tsv"
fgit 2026-11-15T00:00:00Z commit -q -a -m later
got=$(rep)
rc=$?
is "보고: 첫 줄의 창과 경계" "$rc ${got%%$'\n'*}" "0 창: 2026-11-03T00:00:00Z ~ 지금 · 경계: 2026-11-10T00:00:00Z"
is "보고: 창은 경계 7일 전부터라 앞선 런은 빠진다" "$(printf '%s\n' "$got" | cell 스테이지\ 종류 이전)" ""
case "$got" in *"이후 표본 없음") pass "보고: 이후 표본 없음" ;; *) fail "보고: 이후 표본 없음 줄이 없다" ;; esac
case "$got" in *판정:*) fail "보고: 판정 줄이 있다" ;; *) pass "보고: 판정 줄이 없다" ;; esac

# origin/master, when it is there, decides instead of HEAD.
fgit 2026-11-15T00:00:00Z update-ref refs/remotes/origin/master HEAD~2
got=$(rep --since 2026-10-30)
case "${got%%$'\n'*}" in
  *"경계: 없음") pass "보고: origin/master 가 있으면 그 이력으로 경계를 본다" ;;
  *) fail "보고: origin/master 이력을 보지 않았다" ;;
esac
fgit 2026-11-15T00:00:00Z update-ref -d refs/remotes/origin/master

got=$(rep --since 2026-10-30)
is "보고: 이전 묶음의 implement 행 (수·벽시계·시험·몫·대기·알림 없음)" \
  "$(printf '%s\n' "$got" | cell 스테이지\ 종류 '이전|implement')" "1 32.3 29.7 91.8% 29.6 1"
is "보고: 세그먼트 없는 reconverge 는 그대로 센다" "$(printf '%s\n' "$got" | cell 스테이지\ 종류 '이전|reconverge')" "1 2.0 1.0 50.0% 1.0 0"
is "보고: 원장이나 맞는 행이 없는 스테이지는 없음 행에만 센다" "$(printf '%s\n' "$got" | cell 스테이지\ 종류 '-|없음')" "2 4.0 2.0 50.0% 2.0 0"
is "보고: 경계 뒤에 뜬 앞 런의 스테이지는 걸침" "$(printf '%s\n' "$got" | grep -c '^걸침	스테이지 1개')" "1"
case "$got" in *design*) fail "보고: design 스테이지가 나왔다" ;; *) pass "보고: 정한 종류만 낸다" ;; esac

W='도구와 되풀이 갈래'
is "갈래: check-push 다섯 갈래" "$(printf '%s\n' "$got" | cell "$W" '이전|check-push' | tr '\n' ';')" \
  "첫 실행 2 11.7;같은 입력 1 1.0;고친 뒤 일부 재실행 1 3.0;고친 뒤 전부 재실행 1 2.0;고정 검사 1 1.0;"
is "갈래: 배경으로 넘어간 포그라운드 lint 는 알림까지, 알림이 앞선 호출은 결과까지" \
  "$(printf '%s\n' "$got" | cell "$W" '이전|lint' | tr '\n' ';')" "첫 실행 2 5.0;같은 입력 1 1.0;"
is "갈래: 게이트를 지나 실패한 check-items 는 센다" "$(printf '%s\n' "$got" | cell "$W" '이전|check-items')" "첫 실행 1 1.0"
is "갈래: 훅이나 게이트가 거절한 호출은 세지 않는다" "$(printf '%s\n' "$got" | cell "$W" '이전|check-cheap')" ""
is "갈래: test-gate" "$(printf '%s\n' "$got" | cell "$W" '이전|test-gate')" "첫 실행 1 1.0"
is "갈래: 스위트와 자기 시험" "$(printf '%s\n' "$got" | cell "$W" '이전|스위트')" "첫 실행 2 2.0"
is "갈래: 목표" "$(printf '%s\n' "$got" | cell "$W" '이전|목표')" "첫 실행 2 2.0"
is "check-push 의 끝 다섯" "$(printf '%s\n' "$got" | cell 'check-push 의 끝' 이전 | tr '\n' ';')" \
  "종료 0 2 4.0;실패 1 2.0;미완 1 10.0;상한 잘림 1 1.0;알림 없음 1 1.7;"
is "원인 줄: CI 몫 은 처음부터 미룬 목표만 실행마다 한 번 (두 번 잘림·verify·줄머리 아닌 줄 제외), 나머지는 스테이지당 분" \
  "$(printf '%s\n' "$got" | cell '원인 (스테이지당 분)' 이전)" "2 2 9.3 0.5 1.0 0.5 1.5 15.3"
is "원인 줄: 이후 표본이 없으면 분은 -" "$(printf '%s\n' "$got" | cell '원인 (스테이지당 분)' 이후)" "0 0 - - - - - -"
is "CI 처분 행: 이 저장소 세그먼트만, 경계 뒤의 앞 런은 걸침" \
  "$(printf '%s\n' "$got" | cell '원장의 CI 처분 행' 이전) $(printf '%s\n' "$got" | cell '원장의 CI 처분 행' 이후) $(printf '%s\n' "$got" | cell '원장의 CI 처분 행' 걸침)" "1 0 1"

# The same report from a linked worktree reads the main checkout's ledgers.
fgit 2026-11-15T00:00:00Z worktree add -q --detach "$WORK/linked" HEAD
cp "$measure" "$WORK/linked/scripts/measure-test-share.sh"
is "보고: 딸린 워크트리에서 불러도 메인 체크아웃의 원장을 읽는다" \
  "$(XDG_STATE_HOME="$STATE" bash "$WORK/linked/scripts/measure-test-share.sh" --since 2026-10-30 2>"$WORK/err")" "$got"
is "--run-root 로 준 루트는 같은 보고를 낸다" "$(XDG_STATE_HOME="$EMPTY_STATE" bash "$FREPO/scripts/measure-test-share.sh" --run-root "$RUNS" --since 2026-10-30 2>"$WORK/err")" "$got"

# A run at the boundary's own second is after it.
R3=20261110-00000003
FL="$FREPO/docs/pipeline-run/$R3.md"
row_run "$FL" 0 "$R3" 2026-11-10T00:00:00Z
row_seg "$FL" A Nharu/cc-cmds
row_stage "$FL" A A 1 lead-fix
row_ci "$FL" A 2026-11-10T05:00:00Z
short_stage "$RUNS/$R3/log/A#1.json" "$(ep 2026-11-10T01:00:00Z)"
got=$(rep)
is "이후: 경계에 시작한 런은 이후 묶음이다" "$(printf '%s\n' "$got" | cell '스테이지 종류' '이후|lead-fix') / $(printf '%s\n' "$got" | cell '원장의 CI 처분 행' 이후)" "1 2.0 1.0 50.0% 1.0 0 / 1"
case "$got" in *"이후 표본 없음"*) fail "이후: 표본이 있는데 이후 표본 없음" ;; *) pass "이후: 표본이 있으면 이후 표본 없음 줄이 없다" ;; esac
case "$(rep --until 2026-11-09)" in *"이후 표본 없음") pass "--until 앞의 창이면 이후 표본 없음" ;; *) fail "--until 이 런을 자르지 않았다" ;; esac

# No ledger directory: only what the ledgers say is missing.
mv "$FREPO/docs/pipeline-run" "$WORK/ledgers-away"
got=$(rep --since 2026-10-30)
is "원장 없음: 종료 코드 0, 스테이지는 모두 없음 행, CI 처분은 없음" \
  "$? $(printf '%s\n' "$got" | cell '스테이지 종류' '-|없음' | cut -d' ' -f1) $(printf '%s\n' "$got" | cell '스테이지 종류' 이전) $(printf '%s\n' "$got" | cell '원장의 CI 처분 행' 이전)" "0 8  없음"
mv "$WORK/ledgers-away" "$FREPO/docs/pipeline-run"

# Arguments. Every call has XDG_STATE_HOME on a fixture.
rc_of() { XDG_STATE_HOME="$EMPTY_STATE" bash "$FREPO/scripts/measure-test-share.sh" "$@" >"$WORK/out" 2>"$WORK/err"; echo $?; }
is "인자 없음: 기본 런 루트가 없으면 종료 코드 0" "$(rc_of)" "0"
case "$(cat "$WORK/out")" in *"이후 표본 없음") pass "인자 없음: 기본 런 루트가 없으면 이후 표본 없음" ;; *) fail "인자 없음: 이후 표본 없음 줄이 없다" ;; esac
is "--run-root·--since·--until 만 주면 종료 코드 0" "$(rc_of --run-root "$RUNS" --since 2026-11-01 --until 2026-11-30)" "0"
is "둘 없이 --repo → 2" "$(rc_of --repo a/b)" "2"
is "둘 없이 --first → 2" "$(rc_of --first 1)" "2"
is "둘 없이 --session → 2" "$(rc_of --session "$S1")" "2"
is "--run-root 와 --ledger-dir → 2" "$(rc_of --run-root "$RUNS" --ledger-dir "$LEDGERS")" "2"
is "--run-root 와 --lane-root → 2" "$(rc_of --run-root "$RUNS" --lane-root "$LANES")" "2"
is "--run-root 와 둘 다 → 2" "$(rc_of --run-root "$RUNS" --ledger-dir "$LEDGERS" --lane-root "$LANES")" "2"
is "디렉터리가 아닌 --run-root → 2" "$(rc_of --run-root "$WORK/none")" "2"
is "빈 --ledger-dir → 2" "$(rc_of --ledger-dir "")" "2"
is "형식이 틀린 --since 는 보고에서도 2" "$(rc_of --since 2026/10/01)" "2"

# A floor on the pass count, so a case that silently stops running fails here.
if (( failures == 0 && passed < 63 )); then
  fail "통과 수 $passed 가 하한 63 보다 적다 — 경우가 조용히 빠졌다"
fi


echo "test-measure-test-share: $passed passed, $failures failed"
(( failures == 0 ))
