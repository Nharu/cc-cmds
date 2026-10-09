#!/usr/bin/env bash
# Test the return hook — plugins/cc-cmds/hooks/session-return-dismiss.sh — and
# the `dismiss` subcommand of the active-notify helper it calls.
#
# WHAT THIS SUITE CAN AND CANNOT SEE. It drives the hook the way the harness
# does — a JSON payload on stdin — against a STATEFUL terminal-notifier stub on
# PATH, and reads back the stub's table, its argv log, the hook's exit status and
# its stdout/stderr byte counts. It cannot see a screen, and whether `@` and `.`
# survive the real binary's `-group`/`-list`/`-remove` round trip is a separate
# measurement this suite does not replace.
#
# THE STUB keeps a table in the shape `-list ALL` prints (a header line, then
# tab-separated rows whose first column is the group): `-group` replaces the
# row of that group, a banner without a group appends a row whose first column
# is empty, `-remove` deletes exact matches only, and every call is logged. It
# takes a lock, because the seat clear runs detached and races the
# `-list ALL`/`-remove` pass of `notify.sh dismiss`.
#
# THE BANNERS ARE SEEDED THROUGH THE REAL ENTRY POINTS — `notify.sh arm` /
# `fire-now` for single, `--count=3` and repeat, and the seat-1 hook for the
# session slot — for two sessions whose ids are in a prefix relation (`abc`
# and `abc-x`). `armed_at` is a whole second, so two ARMs in the same second
# would give their first fires the same `@<armed_at>.1` group; the seed rewrites
# `armed_at` between ARMs instead of sleeping, and asserts that session A holds
# at least two `@` rows before any case acts.
#
# EVERY CASE ASSERTS THREE THINGS. (U1) exit 0 and zero bytes on stdout and
# stderr — a `UserPromptSubmit` hook's stdout reaches the model. (U2) both
# sessions' ARM flags are byte-identical (cksum) before and after. (U3) unless
# the case says otherwise, every row that is not session A's — session B's, the
# permission-test bypass row, the row without a group, the autopilot rows — is
# byte-identical. "Dismisses A" means A's slot, every `A@*` row and A's seat row
# are gone; "dismisses nothing" means the table is byte-identical and the stub
# log holds no `-list` or `-remove` line.
#
# THE PIPELINE VARIABLES ARE UNSET FOR EVERY RUN except the cases that set one:
# run from inside a stage, they would make every hook exit early and every
# negative assertion pass for the wrong reason.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
HOOK="$PLUGIN_ROOT/hooks/session-return-dismiss.sh"
SEAT1="$PLUGIN_ROOT/hooks/session-ask-notify.sh"
SEAT2="$PLUGIN_ROOT/hooks/session-turn-notify.sh"
NOTIFY_SH="$PLUGIN_ROOT/skills/active-notify/scripts/notify.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

for f in "$HOOK" "$SEAT1" "$SEAT2" "$NOTIFY_SH"; do
  if [ ! -f "$f" ]; then
    bad "스크립트" "$f 가 없다"
    printf 'test-active-notify-dismiss: %s passed, %s failed\n' "$passed" "$failed"
    exit 1
  fi
done

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — the hook parses JSON and nothing can be driven without it"
  echo "test-active-notify-dismiss: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-return-dismiss.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"          # stateful notifier stub + jq
BIN_NO_JQ="$WORK/bin-nj" # notifier stub + bash only — the WHOLE PATH of the no-jq case
mkdir -p "$BIN" "$BIN_NO_JQ"
NC_STATE="$WORK/nc.table"
NC_LOG="$WORK/nc.log"
TMPD="$WORK/tmp"         # the TMPDIR every hook and helper sees
STATE_DIR="$TMPD/cc-cmds-session-return"
FLAG_DIR="$TMPD/cc-cmds-active-notify"
ERR="$WORK/hook.err"
OUTF="$WORK/hook.out"

cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NC_LOG"
lock="$NC_STATE.lock"; i=0
while ! mkdir "$lock" 2>/dev/null; do
  sleep 0.01; i=$((i + 1)); [ "$i" -gt 500 ] && break
done
trap 'rmdir "$lock" 2>/dev/null' EXIT
group=''; has_group=0; title=''; msg=''; remove=''; list=''
while [ $# -gt 0 ]; do
  case "$1" in
    -group)   group="${2:-}"; has_group=1; shift 2 ;;
    -title)   title="${2:-}"; shift 2 ;;
    -message) msg="${2:-}"; shift 2 ;;
    -remove)  remove="${2:-}"; shift 2 ;;
    -list)    list="${2:-}"; shift 2 ;;
    *)        shift ;;
  esac
done
touch "$NC_STATE"
if [ -n "$list" ]; then
  printf 'GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n'
  if [ "$list" = "ALL" ]; then
    cat "$NC_STATE"
  else
    awk -F'\t' -v g="$list" '$1 == g' "$NC_STATE"
  fi
  exit 0
fi
if [ -n "$remove" ]; then
  awk -F'\t' -v g="$remove" '$1 != g' "$NC_STATE" > "$NC_STATE.tmp"
  mv "$NC_STATE.tmp" "$NC_STATE"
  exit 0
fi
if [ "$has_group" = 1 ]; then
  awk -F'\t' -v g="$group" '$1 != g' "$NC_STATE" > "$NC_STATE.tmp"
  mv "$NC_STATE.tmp" "$NC_STATE"
fi
printf '%s\t%s\t\t%s\t2026-10-09 00:00:00 +0000\n' "$group" "$title" "$msg" >> "$NC_STATE"
exit 0
STUB
chmod +x "$BIN/terminal-notifier"
cp "$BIN/terminal-notifier" "$BIN_NO_JQ/terminal-notifier"
ln -s "$JQ" "$BIN/jq"
BASH_BIN=$(command -v bash 2>/dev/null || true)
ln -s "$BASH_BIN" "$BIN_NO_JQ/bash"

# `jq` lives in /usr/bin on the hosts this runs on, so a PATH that merely puts a
# directory in front still finds it. The no-jq PATH is the whole PATH.
PATH_FULL="$BIN:/usr/bin:/bin"
PATH_NO_JQ="$BIN_NO_JQ"

# The base environment of every process this suite starts. Values the outer
# shell might carry are removed so they cannot decide a result.
base_env() {
  env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID \
      -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_SESSION_DISMISS -u CC_CMDS_AUTOPILOT_NOTIFY \
      -u RUN_ID -u RUN_DIR -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID \
      PATH="$PATH_FULL" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin \
      CC_CMDS_NOTIFY_DISMISS_SYNC=1 \
      TMPDIR="$TMPD" NC_STATE="$NC_STATE" NC_LOG="$NC_LOG" \
      "$@"
}

# ---------------------------------------------------------------------------
# Payloads
# ---------------------------------------------------------------------------
ups() {  # ups <sid> <prompt> [prompt_id]
  jq -cn --arg s "$1" --arg p "$2" --arg id "${3:-pid-1}" \
    '{session_id:$s,transcript_path:"/t.jsonl",cwd:"/",prompt_id:$id,permission_mode:"default",hook_event_name:"UserPromptSubmit",prompt:$p}'
}
crons() {  # crons <text>... — the observed session_crons entry shape
  jq -cn '$ARGS.positional | map({id:"a26dab58",schedule:"*/1 * * * *",recurring:true,prompt:.})' --args "$@"
}
stop_with() {  # stop_with <sid> <session_crons JSON>
  jq -cn --arg s "$1" --argjson c "$2" \
    '{session_id:$s,hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"done",session_crons:$c}'
}
stop_nokey() {
  jq -cn --arg s "$1" '{session_id:$s,hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"done"}'
}
aq() {  # aq <sid> <answer> [agent_id]
  jq -cn --arg s "$1" --arg a "$2" --arg ag "${3:-}" \
    '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"AskUserQuestion",tool_use_id:"tu1",
      tool_input:{questions:[{header:"H",question:"Q?"}]},tool_response:{answers:{"Q?":$a}}}
     + (if $ag == "" then {} else {agent_id:$ag} end)'
}

# ---------------------------------------------------------------------------
# Running the hook
# ---------------------------------------------------------------------------
u1_checked=0
hook_run() {  # hook_run <payload> [VAR=value]...
  printf '%s' "$1" > "$WORK/payload.json"; shift
  : > "$ERR"; : > "$OUTF"
  base_env "$@" bash "$HOOK" < "$WORK/payload.json" > "$OUTF" 2> "$ERR"
  local rc=$? ob eb
  ob=$(wc -c < "$OUTF" | tr -d ' ')
  eb=$(wc -c < "$ERR" | tr -d ' ')
  u1_checked=$((u1_checked + 1))
  if [ "$rc" != "0" ] || [ "$ob" != "0" ] || [ "$eb" != "0" ]; then
    bad "U1 ($CASE)" "rc=$rc stdout=${ob}B stderr=${eb}B: $(tr '\n' ' ' < "$ERR")"
  fi
}

# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------
an() {  # an <sid> <notify.sh args...>
  local sid="$1"; shift
  base_env CLAUDE_CODE_SESSION_ID="$sid" bash "$NOTIFY_SH" "$@" >/dev/null 2>&1
}
set_armed_at() {  # rewrite the flag's armed_at so the next fire gets its own group
  local f="$FLAG_DIR/pending-$1.flag"
  sed -E "s/\"armed_at\":[0-9]+/\"armed_at\":$2/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
nc_raw() { base_env terminal-notifier "$@" >/dev/null 2>&1; }
row_count() { awk -F'\t' -v g="$1" '$1 == g' "$NC_STATE" 2>/dev/null | grep -c . || true; }
wait_row() {  # wait_row <group> — the seats fire detached
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(row_count "$1")" -ge 1 ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
wait_row_gone() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(row_count "$1")" = "0" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
quiet_window() { sleep 0.5; }

seat1_fire() {
  printf '%s' "{\"session_id\":\"$1\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"header\":\"H\",\"question\":\"Q?\"}]}}" \
    | base_env bash "$SEAT1" >/dev/null 2>&1
  wait_row "cc-cmds-session-$1"
}

reset_state() { rm -rf "$STATE_DIR"; }

seed() {
  rm -rf "$FLAG_DIR"
  : > "$NC_STATE"; : > "$NC_LOG"
  local s
  for s in abc abc-x; do
    an "$s" arm "r" "c" single --count=1
    an "$s" fire-now "w" "single"
    an "$s" arm "r" "c" single --count=3
    set_armed_at "$s" 1000
    an "$s" fire-now "w" "count"
    an "$s" arm "r" "c" repeat
    set_armed_at "$s" 2000
    an "$s" fire-now "w" "repeat"
    seat1_fire "$s"
  done
  nc_raw -title "cc-cmds 알림 테스트" -message bypass -group cc-cmds-active-notify
  nc_raw -title "cc-cmds usage" -message nogroup
  nc_raw -title "cc-cmds 런" -message run -group cc-cmds-autopilot-r1
  nc_raw -title "cc-cmds 피드" -message feed -group cc-cmds-autopilot-r1-feed
  : > "$NC_LOG"
  SEED_TABLE=$(cat "$NC_STATE")
  SEED_OTHERS=$(others)
  SEED_FLAGS=$(flag_sums)
  SEED_A_AT=$(a_at_rows)
}

# Rows that are not session A's.
others() {
  awk -F'\t' '!($1 == "cc-cmds-active-notify-abc" || index($1, "cc-cmds-active-notify-abc@") == 1 || $1 == "cc-cmds-session-abc")' "$NC_STATE"
}
a_rows() {
  awk -F'\t' '$1 == "cc-cmds-active-notify-abc" || index($1, "cc-cmds-active-notify-abc@") == 1 || $1 == "cc-cmds-session-abc"' "$NC_STATE" | grep -c . || true
}
a_at_rows() {
  awk -F'\t' 'index($1, "cc-cmds-active-notify-abc@") == 1' "$NC_STATE" | grep -c . || true
}
flag_sums() { cksum "$FLAG_DIR/pending-abc.flag" "$FLAG_DIR/pending-abc-x.flag" 2>/dev/null; }
touch_lines() { grep -cE '^-(list|remove)( |$)' "$NC_LOG" 2>/dev/null || true; }

# U2 and U3, the assertions every case shares.
assert_u2() { check "U2 ($CASE) 두 세션의 ARM 플래그가 그대로다" "$(flag_sums)" "$SEED_FLAGS"; }
assert_u3() { check "U3 ($CASE) A 가 아닌 행이 바이트 단위로 같다" "$(others)" "$SEED_OTHERS"; }

expect_dismiss_a() {  # A is dismissed, nothing else changed
  wait_row_gone "cc-cmds-session-abc"
  check "$CASE — A 를 닫는다" "$(a_rows)" "0"
  assert_u2; assert_u3
}
expect_nothing() {  # the table is unchanged and the stub saw no -list/-remove
  quiet_window
  check "$CASE — 아무것도 닫지 않는다(표)" "$(cat "$NC_STATE")" "$SEED_TABLE"
  check "$CASE — 아무것도 닫지 않는다(-list·-remove 호출 없음)" "$(touch_lines)" "0"
  assert_u2; assert_u3
}
state_file() { printf '%s/%s.crons' "$STATE_DIR" "$1"; }
state_sum() { cksum "$(state_file "$1")" 2>/dev/null || printf 'absent'; }

# ---------------------------------------------------------------------------
# The seed itself is checked once: the cases below are only as good as the
# table they start from.
# ---------------------------------------------------------------------------
CASE=seed; reset_state; seed
check "씨 — A 의 단일 자리 행" "$(row_count cc-cmds-active-notify-abc)" "1"
check "씨 — A 의 세션 자리 행" "$(row_count cc-cmds-session-abc)" "1"
if [ "${SEED_A_AT:-0}" -ge 2 ]; then ok "씨 — A 의 @ 행이 둘 이상 ($SEED_A_AT)"; else bad "씨 — A 의 @ 행" "got ${SEED_A_AT:-0}"; fi
check "씨 — B 의 단일 자리 행" "$(row_count cc-cmds-active-notify-abc-x)" "1"
check "씨 — B 의 세션 자리 행" "$(row_count cc-cmds-session-abc-x)" "1"
check "씨 — 우회 행" "$(row_count cc-cmds-active-notify)" "1"
check "씨 — 그룹 없는 행" "$(row_count '')" "1"
check "씨 — autopilot 행 둘" "$(( $(row_count cc-cmds-autopilot-r1) + $(row_count cc-cmds-autopilot-r1-feed) ))" "2"

# ---------------------------------------------------------------------------
# 1–8 — a return dismisses A
# ---------------------------------------------------------------------------
CASE=1; reset_state; seed
hook_run "$(ups abc 'plain typed text')"
expect_dismiss_a
check "1 — 스텁이 -list ALL 을 한 번 받았다" "$(grep -c '^-list ALL$' "$NC_LOG" || true)" "1"

CASE=2; reset_state; seed
hook_run "$(aq abc 'Red' a55d2d70c84f09ea2)"
expect_dismiss_a

CASE=3; reset_state; seed
hook_run "$(aq abc 'Red')"
expect_dismiss_a

CASE=4; reset_state; seed
hook_run "$(ups abc 'plain typed text')" CC_CMDS_SESSION_DISMISS=maybe
expect_dismiss_a

CASE=5; reset_state; seed
hook_run "$(ups abc 'hello <b>')"
expect_dismiss_a

CASE=6; reset_state; seed
hook_run "$(ups abc '<= 3 items please')"
expect_dismiss_a

CASE=7; reset_state; seed
hook_run "$(ups abc "$(printf 'hi\n<task-notification>')")"
expect_dismiss_a

CASE=8a; reset_state; seed
hook_run "$(ups abc 'first message' same-id)"
expect_dismiss_a
CASE=8b; seed
hook_run "$(ups abc 'second message' same-id)"
expect_dismiss_a

# ---------------------------------------------------------------------------
# 9–15 — envelopes and the paste exception
# ---------------------------------------------------------------------------
CASE=9; reset_state; seed
printf '%s' '{"session_id":"abc","last_assistant_message":"본문 한 줄.\n**cc-cmds 차례 넘김**: 이유"}' \
  | base_env bash "$SEAT2" >/dev/null 2>&1
i=0; while [ "$i" -lt 50 ] && ! grep -q -- '-group cc-cmds-session-abc' "$NC_LOG"; do sleep 0.1; i=$((i + 1)); done
check "9 — 좌석 2 가 세션 자리를 다시 띄웠다" "$(row_count cc-cmds-session-abc)" "1"
SEED_TABLE=$(cat "$NC_STATE"); : > "$NC_LOG"
hook_run "$(ups abc "$(printf '<task-notification>\n<task-id>x</task-id>\n<tool-use-id>y</tool-use-id>')")"
expect_nothing
check "9 — 방금 띄운 세션 행이 남는다" "$(row_count cc-cmds-session-abc)" "1"

CASE=10; reset_state; seed
hook_run "$(ups abc '  <some-new-tag attr="1">x')"
expect_nothing

CASE=11; reset_state; seed
hook_run "$(ups abc "$(printf '<cross-session-message from="abc123">\nX-MARKER-1')")"
expect_nothing

CASE=12; reset_state; seed
hook_run "$(ups abc '<br/> tags everywhere')"
expect_nothing

CASE=13a; reset_state; seed
hook_run "$(ups abc "$(printf '<pasted_content id="1">\nlog line\n</pasted_content id="1">\nwhy?')")"
expect_dismiss_a
CASE=13b; seed
hook_run "$(ups abc "$(printf '  <pasted_content id="1">\nlog line\n</pasted_content id="1">\nwhy?')")"
expect_dismiss_a

CASE=14; reset_state; seed
hook_run "$(ups abc '<pasted_contentx>y')"
expect_nothing

CASE=15; reset_state; seed
hook_run "$(ups abc "$(printf 'please read\n<pasted_content id="1">\nlog line\n</pasted_content id="1">')")"
expect_dismiss_a

# ---------------------------------------------------------------------------
# 16–29 — the scheduled-task record
# ---------------------------------------------------------------------------
LOOP_TEXT='reply with the single word LOOPED and use no tools'

CASE=16; reset_state; seed
hook_run "$(stop_with abc "$(crons "$LOOP_TEXT")")"
expect_nothing
check "16 — 상태 파일이 JSON 배열이다" "$(jq -c . "$(state_file abc)" 2>/dev/null)" "$(jq -cn --arg t "$LOOP_TEXT" '[$t]')"

CASE=17
sum_before=$(state_sum abc)
hook_run "$(ups abc "$LOOP_TEXT")"
expect_nothing
check "17 — 읽는 쪽은 상태 파일을 쓰지 않는다" "$(state_sum abc)" "$sum_before"

CASE=18
hook_run "$(ups abc 'hello')"
expect_dismiss_a

CASE=19; seed
hook_run "$(ups abc "$LOOP_TEXT")"
expect_nothing

CASE=20; reset_state; seed
WAKE='WAKEPROBE-2 say the single word WOKE and use no tools'
hook_run "$(stop_with abc "$(jq -cn --arg t "$WAKE" '[{id:"bd62bd27",schedule:"47 22 * * *",recurring:false,prompt:$t}]')")"
hook_run "$(ups abc "$WAKE")"
expect_nothing
hook_run "$(stop_with abc '[]')"
check "20 — 빈 session_crons 의 Stop 뒤 상태 파일이 없다" "$(state_sum abc)" "absent"
hook_run "$(ups abc "$WAKE")"
expect_dismiss_a

CASE=21; reset_state; seed
MULTI=$(printf 'line one\nline two\twith tab "quoted"')
hook_run "$(stop_with abc "$(crons "$MULTI")")"
hook_run "$(ups abc "$MULTI")"
expect_nothing

CASE=22
hook_run "$(ups abc 'line one')"
expect_dismiss_a

CASE=23; reset_state; seed
hook_run "$(stop_with abc "$(crons '/babysit-prs check open PRs')")"
hook_run "$(ups abc '/babysit-prs check open PRs')"
expect_nothing
hook_run "$(ups abc '/loop 1m something else')"
expect_dismiss_a

HEAD='please check the deploy pipeline and report the status of every stage'
CASE=24; reset_state; seed
hook_run "$(stop_with abc "$(crons "$HEAD … [+57 chars]")")"
hook_run "$(ups abc "$HEAD in full detail, then summarise the failures for the team")"
expect_nothing

CASE=25; reset_state; seed
hook_run "$(stop_with abc "$(crons "$HEAD... [+57 chars]")")"
hook_run "$(ups abc "$HEAD in full detail, then summarise the failures for the team")"
expect_nothing

CASE=26; reset_state; seed
hook_run "$(stop_with abc "$(crons "$HEAD … [+57 chars]")")"
hook_run "$(ups abc "and now $HEAD")"
expect_dismiss_a

CASE=27a; reset_state; seed
hook_run "$(stop_with abc "$(crons "$LOOP_TEXT")")"
sum_before=$(state_sum abc)
hook_run "$(stop_nokey abc)"
check "27 — 키 없는 Stop 은 상태 파일을 그대로 둔다" "$(state_sum abc)" "$sum_before"
CASE=27b; reset_state
hook_run "$(stop_nokey abc)"
check "27 — 파일이 없을 때 키 없는 Stop 은 파일을 만들지 않는다" "$(state_sum abc)" "absent"
hook_run "$(ups abc 'plain typed text')"
expect_dismiss_a

T_TEXT='every minute check the queue and use no tools'
CASE=28; reset_state; seed
hook_run "$(stop_with abc-x "$(crons "$T_TEXT")")"
b_sum=$(state_sum abc-x)
hook_run "$(ups abc "$T_TEXT")"
expect_dismiss_a
check "28 — B 의 상태 파일이 그대로다" "$(state_sum abc-x)" "$b_sum"

CASE=29; seed
hook_run "$(ups abc-x "$T_TEXT")"
expect_nothing

# ---------------------------------------------------------------------------
# 30–37 — the switch and the stage gate stop both recording and dismissing
# ---------------------------------------------------------------------------
n=30
for v in 0 off false no OFF; do
  CASE="$n(CC_CMDS_SESSION_DISMISS=$v)"; reset_state; seed
  hook_run "$(stop_with abc "$(crons "$LOOP_TEXT")")" CC_CMDS_SESSION_DISMISS="$v"
  check "$CASE — 상태 파일이 생기지 않는다" "$(state_sum abc)" "absent"
  hook_run "$(ups abc 'plain typed text')" CC_CMDS_SESSION_DISMISS="$v"
  hook_run "$(aq abc 'Red' a1)" CC_CMDS_SESSION_DISMISS="$v"
  expect_nothing
  n=$((n + 1))
done

n=35
for var in CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID; do
  CASE="$n($var)"; reset_state; seed
  hook_run "$(stop_with abc "$(crons "$LOOP_TEXT")")" "$var=x"
  check "$CASE — 상태 파일이 생기지 않는다" "$(state_sum abc)" "absent"
  hook_run "$(ups abc 'plain typed text')" "$var=x"
  hook_run "$(aq abc 'Red' a1)" "$var=x"
  expect_nothing
  n=$((n + 1))
done

# ---------------------------------------------------------------------------
# 38–41 — errors and other events
# ---------------------------------------------------------------------------
CASE=38; reset_state; seed
for sid_json in '"session_id":"",' ''; do
  hook_run "{${sid_json}\"hook_event_name\":\"Stop\",\"session_crons\":[{\"prompt\":\"T\"}]}"
  hook_run "{${sid_json}\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"plain\"}"
  hook_run "{${sid_json}\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"AskUserQuestion\"}"
done
check "38 — 상태 디렉터리가 생기지 않는다" "$([ -e "$STATE_DIR" ] && echo present || echo absent)" "absent"
expect_nothing

CASE=39; reset_state; seed
hook_run "$(stop_with abc "$(crons "$LOOP_TEXT")")" PATH="$PATH_NO_JQ"
hook_run "$(ups abc 'plain typed text')" PATH="$PATH_NO_JQ"
hook_run "$(aq abc 'Red')" PATH="$PATH_NO_JQ"
check "39 — jq 가 없으면 상태 파일이 없다" "$(state_sum abc)" "absent"
expect_nothing

CASE=40; reset_state; seed
hook_run 'not json'
hook_run '{"session_id":"abc","hook_event_name":"Stop","session_crons":[{"prompt":"T"}'
hook_run '{"session_id":"abc","hook_event_name":"UserPromptSubmit","prompt":"plain'
hook_run '{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion",'
check "40 — 깨진 페이로드에 상태 파일이 없다" "$(state_sum abc)" "absent"
expect_nothing

CASE=41; reset_state; seed
hook_run '{"session_id":"abc","hook_event_name":"SessionStart","source":"startup"}'
hook_run '{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
hook_run '{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{}}'
hook_run "$(jq -cn --argjson c "$(crons "$LOOP_TEXT")" '{session_id:"abc",hook_event_name:"SubagentStop",agent_id:"a1",session_crons:$c}')"
check "41 — 다른 이벤트는 상태 파일을 쓰지 않는다" "$(state_sum abc)" "absent"
expect_nothing

# ---------------------------------------------------------------------------
# 42–47
# ---------------------------------------------------------------------------
CASE=42; reset_state; seed
P42=$(jq -cn --argjson c "$(crons "$LOOP_TEXT")" '{session_id:"abc",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"본문 한 줄.\n**cc-cmds 차례 넘김**: 이유",session_crons:$c}')
printf '%s' "$P42" | base_env bash "$SEAT2" >/dev/null 2>&1
hook_run "$P42"
i=0; while [ "$i" -lt 50 ] && ! grep -q -- '-group cc-cmds-session-abc' "$NC_LOG"; do sleep 0.1; i=$((i + 1)); done
check "42 — 좌석 2 가 오늘처럼 세션 자리를 띄운다" "$(grep -c -- '-group cc-cmds-session-abc' "$NC_LOG" || true)" "1"
check "42 — 상태 파일도 쓰인다" "$(jq -c . "$(state_file abc)" 2>/dev/null)" "$(jq -cn --arg t "$LOOP_TEXT" '[$t]')"
check "42 — 귀환 닫기 훅은 아무것도 지우지 않았다" "$(touch_lines)" "0"
assert_u2; assert_u3

CASE=43; reset_state; seed
hook_run "$(stop_with abc "$(crons "$T_TEXT")")"
hook_run "$(aq abc "$T_TEXT")"
expect_dismiss_a

CASE=44; reset_state; seed
hook_run "$(stop_with abc '[{"id":"x"},{"id":"y","prompt":5},{"id":"z","prompt":"T"}]')"
check "44 — 문자열이 아닌 prompt 는 버린다" "$(jq -c . "$(state_file abc)" 2>/dev/null)" '["T"]'
expect_nothing

CASE=45; reset_state; seed
EVIL='../x/y..'
hook_run "$(stop_with "$EVIL" "$(crons "$T_TEXT")")"
check "45 — 상태 파일이 cc-cmds-session-return/ 안에 있다" \
  "$(find "$TMPD" -name '*.crons' | sed "s#^$STATE_DIR/##")" ".._x_y...crons"
hook_run "$(ups "$EVIL" "$T_TEXT")"
expect_nothing

CASE=46; reset_state; seed
hook_run "$(ups abc 'plain typed text')"
expect_dismiss_a
check "46 — autopilot 두 행이 바이트 단위로 같다" \
  "$(awk -F'\t' 'index($1, "cc-cmds-autopilot-") == 1' "$NC_STATE")" \
  "$(printf '%s\n' "$SEED_TABLE" | awk -F'\t' 'index($1, "cc-cmds-autopilot-") == 1')"

CASE=47; reset_state; seed
hook_run "$(ups abc 'plain typed text')" CC_CMDS_SESSION_NOTIFY=0
quiet_window
check "47 — A 의 active-notify 행이 사라진다" \
  "$(awk -F'\t' '$1 == "cc-cmds-active-notify-abc" || index($1, "cc-cmds-active-notify-abc@") == 1' "$NC_STATE" | grep -c . || true)" "0"
check "47 — 세션 자리 -remove 가 없다" "$(grep -c '^-remove cc-cmds-session-abc$' "$NC_LOG" || true)" "0"
check "47 — 세션 행이 남는다" "$(row_count cc-cmds-session-abc)" "1"
assert_u2; assert_u3

# ---------------------------------------------------------------------------
# notify.sh dismiss on its own: no terminal-notifier, or not Darwin, is a quiet 0.
# ---------------------------------------------------------------------------
CASE=dismiss-gates; reset_state; seed
out=$(base_env CC_CMDS_NOTIFY_HOST_OS=Linux bash "$NOTIFY_SH" dismiss abc 2>&1); rc=$?
check "dismiss — Darwin 이 아니면 조용히 0" "$rc:$out:$(touch_lines)" "0::0"
out=$(base_env PATH="/usr/bin:/bin" bash "$NOTIFY_SH" dismiss abc 2>&1); rc=$?
check "dismiss — terminal-notifier 가 없으면 조용히 0" "$rc:$out:$(touch_lines)" "0::0"

check "U1 — 모든 훅 실행이 측정됐다 (0 건이면 공허하다)" "$([ "$u1_checked" -gt 0 ] && echo yes || echo no)" "yes"

printf 'test-active-notify-dismiss: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
exit 0
