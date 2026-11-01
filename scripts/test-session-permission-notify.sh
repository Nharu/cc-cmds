#!/usr/bin/env bash
# Test the permission prompt seat — plugins/cc-cmds/hooks/session-permission-notify.sh.
#
# WHAT THIS SUITE CAN AND CANNOT SEE. It drives the hook the way the harness
# does — a role argument and a JSON payload on stdin — and reads back the
# attention spool, the seat's state files, the exit status and the bytes on
# stdout and stderr. Whether the harness runs the hook, and what its payloads
# look like, was observed at the run's kickoff and is not re-observed here.
#
# EVERYTHING IS CONFINED TO ONE WORK DIRECTORY: HOME, TMPDIR (the seat's state
# root and its attachment files), XDG_STATE_HOME (the session title file) and
# CC_CMDS_ATTENTION_ROOT (the spool). The pipeline markers are unset for every
# run: inside an unattended stage `cc_caller_is_router` is false, and every
# negative assertion below would then pass for the wrong reason.
#
# THE POSITIVE CONTROL COMES FIRST. A suite that only measures suppression is
# green against a hook that writes nothing at all.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
HOOK="$PLUGIN_ROOT/hooks/session-permission-notify.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
finish() {
  printf 'test-session-permission-notify: %s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit $?
}

if [ ! -f "$HOOK" ]; then
  bad "훅 스크립트" "$HOOK 가 없다"
  finish
fi

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — the seat parses JSON and nothing can be driven without it"
  echo "test-session-permission-notify: 0 passed, 0 failed"
  exit 0
fi
BASH_BIN=$(command -v bash 2>/dev/null || true)
MKTEMP_BIN=$(command -v mktemp 2>/dev/null || true)
if [ -z "$BASH_BIN" ] || [ -z "$MKTEMP_BIN" ]; then
  bad "시험 환경" "PATH 에서 bash 나 mktemp 를 찾지 못했다"
  finish
fi
if command -v shasum >/dev/null 2>&1; then
  SHA() { shasum -a 256; }
else
  SHA() { sha256sum; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-perm-seat.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Three PATH roots. The full one holds jq and a notifier stub that logs every
# call, so "no new local banner" is a count of zero rather than an absence of
# evidence. The no-jq root is the WHOLE PATH (a jq in /usr/bin would otherwise
# still be found). The slow root puts a `mktemp` that sleeps in front: only the
# detached half of `request` calls it.
BIN="$WORK/bin"
BIN_NO_JQ="$WORK/bin-nj"
BIN_SLOW="$WORK/bin-slow"
mkdir -p "$BIN" "$BIN_NO_JQ" "$BIN_SLOW"
cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$BIN/terminal-notifier"
cp "$BIN/terminal-notifier" "$BIN_NO_JQ/terminal-notifier"
ln -s "$JQ" "$BIN/jq"
ln -s "$BASH_BIN" "$BIN_NO_JQ/bash"
cat > "$BIN_SLOW/mktemp" <<STUB
#!$BASH_BIN
sleep 3
exec "$MKTEMP_BIN" "\$@"
STUB
chmod +x "$BIN_SLOW/mktemp"

PATH_FULL="$BIN:/usr/bin:/bin"
PATH_NO_JQ="$BIN_NO_JQ"
PATH_SLOW="$BIN_SLOW:$BIN:/usr/bin:/bin"

T="$WORK/tmp"
SPOOL="$WORK/spool"
STATE="$WORK/state"
HOMEDIR="$WORK/home"
BASE="$T/cc-cmds-permission"
mkdir -p "$T" "$SPOOL" "$STATE/cc-cmds/session-title-now" "$HOMEDIR"
NOTIFY_LOG="$WORK/notifier.log"
: > "$NOTIFY_LOG"
ERR="$WORK/hook.err"
OUTF="$WORK/hook.out"
P="$WORK/payload.json"

now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

# Every run is checked for exit 0 and empty stdout and stderr; the failures are
# collected and reported once per case label.
noisy=""
hook_run() {
  local role="$1" path="$2"; shift 2
  : > "$ERR"; : > "$OUTF"
  env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID \
      -u CC_PIPELINE_REENTRY -u CC_PIPELINE_RUN_ID -u RUN_ID -u RUN_DIR \
      -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_AUTOPILOT_NOTIFY -u TMUX -u TMUX_PANE \
      PATH="$path" \
      HOME="$HOMEDIR" \
      TMPDIR="$T" \
      XDG_STATE_HOME="$STATE" \
      CC_CMDS_ATTENTION_ROOT="$SPOOL" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_PERMISSION_SYNC=1 \
      CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      "$@" \
      bash "$HOOK" "$role" < "$P" > "$OUTF" 2> "$ERR"
  local rc=$?
  if [ "$rc" -ne 0 ] || [ -s "$OUTF" ] || [ -s "$ERR" ]; then
    noisy="$noisy [$role rc=$rc out=$(wc -c < "$OUTF" | tr -d ' ') err=$(head -c 200 "$ERR")]"
  fi
  return 0
}

reset() { rm -rf "$BASE" "$SPOOL/events" "$SPOOL/handled"; }
n_events()  { find "$SPOOL/events" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
n_handled() { find "$SPOOL/handled" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
events_json()  { if [ -d "$SPOOL/events" ];  then find "$SPOOL/events"  -name '*.json' -type f -exec cat {} + | jq -s -c 'sort_by(.created_at_ms)'; else echo '[]'; fi; }
handled_json() { if [ -d "$SPOOL/handled" ]; then find "$SPOOL/handled" -name '*.json' -type f -exec cat {} + | jq -s -c 'sort_by(.at_ms)'; else echo '[]'; fi; }
ev() { events_json | jq -r "$1"; }

# The fingerprint, computed here from its definition rather than by the hook.
fp_of() { jq -cS '{tool_name, tool_input}' "$1" | SHA | cut -c1-16; }

# The handled rule of the event contract: an exact marker on the same slot, or a
# prefix marker the slot starts with, whose time is later than the event's.
handled_state() {
  local slot="$1"
  jq -rn --argjson e "$(events_json)" --argjson h "$(handled_json)" --arg s "$slot" '
    ($e | map(select(.slot == $s)) | first) as $ev
    | if $ev == null then "없음"
      elif any($h[]; .slot as $m | (if .prefix then ($s | startswith($m)) else $m == $s end) and .at_ms > $ev.created_at_ms)
      then "처리됨" else "열림" end'
}

perm() { # perm <sid> <tool> <tool_input json> [extra jq object]
  local x="${4:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg s "$1" --arg t "$2" --argjson i "$3" --argjson x "$x" \
    '{session_id: $s, hook_event_name: "PermissionRequest", tool_name: $t, tool_input: $i, permission_mode: "default"} + $x' > "$P"
}
post() { # post <sid> <event> <tool> <tool_input json> [extra]
  local x="${5:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg s "$1" --arg e "$2" --arg t "$3" --argjson i "$4" --argjson x "$x" \
    '{session_id: $s, hook_event_name: $e, tool_name: $t, tool_input: $i, tool_response: {ok: true}} + $x' > "$P"
}
plain() { # plain <sid> <event> [extra]
  local x="${3:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg s "$1" --arg e "$2" --argjson x "$x" '{session_id: $s, hook_event_name: $e} + $x' > "$P"
}

# ---------------------------------------------------------------------------
# 1. The positive control: one main-session request, one event of the agreed shape.
# ---------------------------------------------------------------------------
reset
S=sess-1
IN='{"command":"make check","description":"run the checks"}'
perm "$S" Bash "$IN"
FP=$(fp_of "$P")
hook_run request "$PATH_FULL"
check "사건 하나가 생긴다" "$(n_events)" "1"
check "kind" "$(ev '.[0].kind')" "permission"
check "token" "$(ev '.[0].token')" "permission"
check "slot 은 세션@지문" "$(ev '.[0].slot')" "cc-cmds-permission-$S@$FP"
check "제목 (세션 제목 없음)" "$(ev '.[0].title')" "cc-cmds · 권한 확인을 기다립니다"
check "본문은 도구 이름 한 줄과 요약" "$(ev '.[0].body')" "Bash
make check — run the checks"
check "actionable 거짓" "$(ev '.[0].actionable')" "false"
check "accepts 비어 있음" "$(ev '.[0].accepts | tojson')" "[]"
check "reply 네 필드" "$(ev '.[0].reply | tojson')" \
  "$(jq -cn --arg s "$S" '{surface: "permission", session_id: $s, tool_name: "Bash", input_summary: "make check — run the checks"}')"
check "origin.session_id" "$(ev '.[0].origin.session_id')" "$S"
check "open 표시가 남고 pending 은 없다" \
  "$([ -f "$BASE/$S/open.$FP" ] && [ ! -e "$BASE/$S/pending.$FP" ] && echo yes || echo no)" "yes"
check "seen 이 기록된다" "$([ -s "$BASE/$S/seen" ] && echo yes || echo no)" "yes"
check "첨부 임시 파일이 남지 않는다" "$(find "$T" -maxdepth 1 -name 'cc-attention-detail.*' | wc -l | tr -d ' ')" "0"

# The session title, read from the title hook's current title file.
reset
S=sess-titled
printf 'cc-session-title-now v1\n작업 이름\n' > "$STATE/cc-cmds/session-title-now/$S"
perm "$S" Read '{"file_path":"/etc/hosts"}'
hook_run request "$PATH_FULL"
check "제목 (세션 제목 있음)" "$(ev '.[0].title')" "cc-cmds · 작업 이름 · 권한 확인을 기다립니다"

# The permission mode is not read.
reset
perm sess-bp Bash '{"command":"ls"}' '{"permission_mode":"bypassPermissions"}'
hook_run request "$PATH_FULL"
check "우회 모드에서도 사건이 생긴다" "$(n_events)" "1"

# ---------------------------------------------------------------------------
# 2. Gates.
# ---------------------------------------------------------------------------
reset
perm sess-agent Bash '{"command":"ls"}' '{"agent_id":"a1b2"}'
before=$(now_ms)
hook_run request "$PATH_FULL"
check "agent_id 가 있으면 사건이 없다" "$(n_events)" "0"
seen=$(cat "$BASE/sess-agent/seen" 2>/dev/null || echo 0)
check "agent_id 가 있어도 seen 은 갱신된다" "$([ "${seen:-0}" -ge "$before" ] && echo yes || echo no)" "yes"
check "agent_id 가 있으면 대기·열림 표시가 없다" \
  "$(find "$BASE/sess-agent" -name 'open.*' -o -name 'pending.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

gate_case() { # gate_case <label> <sid> [env...]
  local label="$1" sid="$2"; shift 2
  reset
  perm "$sid" Bash '{"command":"ls"}'
  hook_run request "$PATH_FULL" "$@"
  check "$label — 사건 없음" "$(n_events)" "0"
  check "$label — 상태 파일 없음" "$(find "$BASE" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}
gate_case "스위치 꺼짐" sess-off CC_CMDS_SESSION_NOTIFY=0
gate_case "파이프라인 표지 SEGMENT" sess-p1 CC_PIPELINE_SEGMENT=A
gate_case "파이프라인 표지 STAGE_ID" sess-p2 'CC_PIPELINE_STAGE_ID=A#1'
gate_case "파이프라인 표지 SHIFT_ID" sess-p3 CC_PIPELINE_SHIFT_ID=s1
gate_case "파이프라인 표지 REENTRY" sess-p4 CC_PIPELINE_REENTRY=1
gate_case "빈 세션 id" ""
gate_case "알파벳 밖 세션 id" "a/b"
gate_case "세션 id 가 .." ".."

# ---------------------------------------------------------------------------
# 3. Redaction — no raw value anywhere under the spool root or the state root.
# ---------------------------------------------------------------------------
reset
TG="123456789:AAbbCCddEEffGGhhIIjjKKllMMnnOOppQQr"
SECRETS=(
  "ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
  "gho_Zyx987654321Zyx987654321"
  "github_pat_11ABCDEFG0123456789_abcdefghijk"
  "sk-ant-api03-Secretvalue_0123456789"
  "xoxb-1111-2222-SlackSecretValue"
  "AKIAABCDEFGHIJKLMNOP"
  "AIzaSyDummyGoogleKey0123456789"
  "pk_1234_StripeLikeValue99"
  "$TG"
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpM"
  "BearerSecretValue987"
  "dXNlcjpwYXNzQmFzaWM"
  "hunter2xyz"
  "K3yValue55"
  "pa55wordInUrl"
  "TokFlagValue123"
  "PwFlagValue987"
  "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC"
)
CMD="curl -H 'Authorization: Bearer ${SECRETS[10]}' https://user:${SECRETS[14]}@example.com/x --token ${SECRETS[15]} --password=${SECRETS[16]}"
CMD="$CMD; echo ${SECRETS[0]} ${SECRETS[1]} ${SECRETS[2]} ${SECRETS[3]} ${SECRETS[4]} ${SECRETS[5]} ${SECRETS[6]} ${SECRETS[7]} ${SECRETS[8]} ${SECRETS[9]}"
CMD="$CMD; export password=${SECRETS[12]}; http -a x Basic ${SECRETS[11]}"
IN=$(jq -cn --arg c "$CMD" --arg k "${SECRETS[13]}" '{command: $c, description: ("api_key: " + $k)}')
perm sess-red Bash "$IN"
hook_run request "$PATH_FULL"
check "가림 — Bash 사건이 생긴다" "$(n_events)" "1"
PEM="-----BEGIN RSA PRIVATE KEY-----
${SECRETS[17]}
-----END RSA PRIVATE KEY-----"
perm sess-red Write "$(jq -cn --arg c "key:
$PEM
done" '{file_path: "/tmp/k.pem", content: $c}')"
hook_run request "$PATH_FULL"
check "가림 — Write 사건이 생긴다" "$(n_events)" "2"
leaks=""
for s in "${SECRETS[@]}"; do
  if grep -rqF -- "$s" "$SPOOL" "$BASE" "$T" 2>/dev/null; then leaks="$leaks $s"; fi
done
check "가림 — 원문 값이 스풀·상태 어느 파일에도 없다" "${leaks:-없음}" "없음"
check "가림 — 가림 표시가 본문에 있다" "$(ev '[.[] | .body | contains("[가림]")] | all')" "true"
check "가림 — 키 이름은 남는다" \
  "$(ev '[.[0].reply.input_summary | contains("password="), contains("api_key: "), contains("--token "), contains("Authorization: ")] | all')" "true"

# ---------------------------------------------------------------------------
# 4. Per-tool summaries.
# ---------------------------------------------------------------------------
summary_case() { # summary_case <label> <tool> <tool_input> <expected summary>
  reset
  perm sess-sum "$2" "$3"
  hook_run request "$PATH_FULL"
  check "요약 — $1" "$(ev '.[0].reply.input_summary')" "$4"
}
summary_case "Bash (설명 없음)" Bash '{"command":"ls -la"}' "ls -la"
summary_case "Edit" Edit '{"file_path":"/a/b.txt","old_string":"x","new_string":"y"}' "경로: /a/b.txt
바꿀 문자열:
x
새 문자열:
y"
summary_case "Edit 의 나머지 키" Edit '{"file_path":"/a","old_string":"x","new_string":"y","replace_all":true}' "경로: /a
바꿀 문자열:
x
새 문자열:
y
기타 입력: {\"replace_all\":true}"
summary_case "MultiEdit" MultiEdit '{"file_path":"/m","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d","replace_all":true}]}' "경로: /m
편집 1 — 바꿀 문자열:
a
편집 1 — 새 문자열:
b
편집 2 — 바꿀 문자열:
c
편집 2 — 새 문자열:
d
편집 2 — 기타 입력: {\"replace_all\":true}"
summary_case "Write" Write '{"file_path":"/w","content":"line1\nline2"}' "경로: /w
내용:
line1
line2"
summary_case "NotebookEdit" NotebookEdit '{"notebook_path":"/n.ipynb","new_source":"print(1)","cell_id":"c1"}' "노트북 경로: /n.ipynb
새 소스:
print(1)
기타 입력: {\"cell_id\":\"c1\"}"
summary_case "Read" Read '{"file_path":"/r"}' "경로: /r"
summary_case "WebFetch" WebFetch '{"url":"https://example.com/","prompt":"summarize"}' "URL: https://example.com/
기타 입력: {\"prompt\":\"summarize\"}"
summary_case "WebSearch" WebSearch '{"query":"jq gsub"}' "질의: jq gsub"
summary_case "Glob" Glob '{"pattern":"**/*.sh"}' "패턴: **/*.sh"
summary_case "Grep" Grep '{"pattern":"foo","path":"/src","output_mode":"content"}' "패턴: foo
경로: /src
기타 입력: {\"output_mode\":\"content\"}"
summary_case "모르는 도구" mcp__x__do '{"a":1,"b":{"c":[1,2]}}' '{
  "a": 1,
  "b": {
    "c": [
      1,
      2
    ]
  }
}'
summary_case "핵심 필드 없는 아는 도구" Bash '{"timeout":5}' '{
  "timeout": 5
}'

reset
LONG=$(head -c 10000 /dev/zero | tr '\0' 'a')
perm sess-long Bash "$(jq -cn --arg c "echo $LONG" '{command: $c}')"
hook_run request "$PATH_FULL"
check "약 10 000 자 명령이 잘리지 않는다" "$(ev '.[0].reply.input_summary | length')" "10005"

# ---------------------------------------------------------------------------
# 5. Settling.
# ---------------------------------------------------------------------------
settle_case() { # settle_case <label> <event name>
  reset
  local sid=sess-settle in='{"command":"make test"}' fp
  perm "$sid" Bash "$in"
  fp=$(fp_of "$P")
  hook_run request "$PATH_FULL"
  post "$sid" "$2" Bash "$in"
  hook_run settle "$PATH_FULL"
  check "$1 — 정확한 슬롯 표지 하나" "$(handled_json | jq -c '[.[] | {slot, prefix, cause}]')" \
    "$(jq -cn --arg s "cc-cmds-permission-$sid@$fp" '[{slot: $s, prefix: false, cause: "permission-settled"}]')"
  check "$1 — 처리됨" "$(handled_state "cc-cmds-permission-$sid@$fp")" "처리됨"
  check "$1 — open 표시가 지워진다" "$([ -e "$BASE/$sid/open.$fp" ] && echo yes || echo no)" "no"
}
settle_case "PostToolUse" PostToolUse
settle_case "PostToolUseFailure" PostToolUseFailure
settle_case "PermissionDenied" PermissionDenied

reset
perm sess-other Bash '{"command":"make test"}'
hook_run request "$PATH_FULL"
post sess-other PostToolUse Bash '{"command":"make lint"}'
hook_run settle "$PATH_FULL"
check "다른 입력의 결과는 표지를 쓰지 않는다" "$(n_handled)" "0"
post sess-other PostToolUse Bash '{"command":"make test"}' '{"agent_id":"sub1"}'
hook_run settle "$PATH_FULL"
check "agent_id 가 있는 결과는 표지를 쓰지 않는다" "$(n_handled)" "0"

# Two dialogs at once: settling A leaves B open under the contract's rule.
reset
perm sess-par Bash '{"command":"echo A"}'; FPA=$(fp_of "$P"); hook_run request "$PATH_FULL"
perm sess-par Bash '{"command":"echo B"}'; FPB=$(fp_of "$P"); hook_run request "$PATH_FULL"
post sess-par PostToolUse Bash '{"command":"echo A"}'
hook_run settle "$PATH_FULL"
check "병렬 — A 는 처리됨" "$(handled_state "cc-cmds-permission-sess-par@$FPA")" "처리됨"
check "병렬 — B 는 열림" "$(handled_state "cc-cmds-permission-sess-par@$FPB")" "열림"

# ---------------------------------------------------------------------------
# 6. Detached writing, and a settle that arrives before the event is written.
# ---------------------------------------------------------------------------
reset
perm sess-race Bash '{"command":"sleep 1"}'
FPR=$(fp_of "$P")
t0=$(now_ms)
hook_run request "$PATH_SLOW" CC_CMDS_NOTIFY_PERMISSION_SYNC=
t1=$(now_ms)
check "떼어 내기 — request 가 2초 안에 돌아온다" "$([ $((t1 - t0)) -lt 2000 ] && echo yes || echo "no ($((t1 - t0)) ms)")" "yes"
check "떼어 내기 — 돌아온 순간 대기 표시가 있다" "$([ -e "$BASE/sess-race/pending.$FPR" ] && echo yes || echo no)" "yes"
post sess-race PostToolUse Bash '{"command":"sleep 1"}'
hook_run settle "$PATH_FULL"
check "엇갈림 — 대기 중의 처리 신호는 표지를 바로 쓰지 않는다" "$(n_handled)" "0"
i=0
while [ "$i" -lt 100 ] && { [ "$(n_events)" -lt 1 ] || [ "$(n_handled)" -lt 1 ]; }; do
  sleep 0.1; i=$((i + 1))
done
check "떼어 내기 — 사건이 10초 안에 생긴다" "$(n_events)" "1"
check "엇갈림 — 사건 뒤 표지가 정확히 하나" "$(n_handled)" "1"
check "엇갈림 — 표지 시각이 사건 시각보다 늦다" \
  "$(jq -rn --argjson e "$(events_json)" --argjson h "$(handled_json)" '$h[0].at_ms > $e[0].created_at_ms')" "true"
check "엇갈림 — 사건은 처리됨" "$(handled_state "cc-cmds-permission-sess-race@$FPR")" "처리됨"
check "엇갈림 — 대기·열림 표시가 남지 않는다" \
  "$(find "$BASE/sess-race" -name 'open.*' -o -name 'pending.*' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# 7. Turn end and return.
# ---------------------------------------------------------------------------
close_case() { # close_case <role> <event> <cause>
  reset
  local sid=sess-close fpa
  perm "$sid" Bash '{"command":"echo 1"}'; fpa=$(fp_of "$P"); hook_run request "$PATH_FULL"
  perm "$sid" Bash '{"command":"echo 2"}'; hook_run request "$PATH_FULL"
  plain "$sid" "$2" '{"agent_id":"sub9"}'
  hook_run "$1" "$PATH_FULL"
  check "$1 — agent_id 가 있으면 닫지 않는다" "$(n_handled)" "0"
  plain "$sid" "$2"
  hook_run "$1" "$PATH_FULL"
  check "$1 — 접두 표지 하나" "$(handled_json | jq -c '[.[] | {slot, prefix, cause}]')" \
    "$(jq -cn --arg s "cc-cmds-permission-$sid@" --arg c "$3" '[{slot: $s, prefix: true, cause: $c}]')"
  check "$1 — 두 사건 모두 처리됨" \
    "$(handled_state "cc-cmds-permission-$sid@$fpa")" "처리됨"
  check "$1 — 열린 표시가 지워진다" "$(find "$BASE/$sid" -name 'open.*' | wc -l | tr -d ' ')" "0"
  hook_run "$1" "$PATH_FULL"
  check "$1 — 열린 파일이 없으면 아무것도 쓰지 않는다" "$(n_handled)" "1"
}
close_case stop Stop permission-settled
close_case prompt UserPromptSubmit return

# ---------------------------------------------------------------------------
# 8. The fallback signal.
# ---------------------------------------------------------------------------
notif() { plain "$1" Notification "$(jq -cn --arg t "${2:-permission_prompt}" '{notification_type: $t, message: "Claude needs your permission to use Bash"}')"; }

reset
notif sess-n1
hook_run notification "$PATH_FULL"
check "보조 신호 — PermissionRequest 가 없었으면 사건이 생긴다" "$(n_events)" "1"
check "보조 신호 — 슬롯" "$(ev '.[0].slot')" "cc-cmds-permission-sess-n1@notification"
check "보조 신호 — reply 는 null" "$(ev '.[0].reply')" "null"
check "보조 신호 — 본문" "$(ev '.[0].body')" "도구를 알 수 없는 권한 확인이 열렸습니다
Claude needs your permission to use Bash"
check "보조 신호 — open.notification" "$([ -f "$BASE/sess-n1/open.notification" ] && echo yes || echo no)" "yes"
plain sess-n1 Stop
hook_run stop "$PATH_FULL"
check "보조 신호 사건은 차례 끝의 접두 표지로 닫힌다" "$(handled_state "cc-cmds-permission-sess-n1@notification")" "처리됨"

reset
perm sess-n2 Bash '{"command":"ls"}'
hook_run request "$PATH_FULL"
notif sess-n2
hook_run notification "$PATH_FULL"
check "보조 신호 — 10초 안의 PermissionRequest 뒤에는 사건이 없다" "$(ev '[.[] | select(.slot | endswith("@notification"))] | length')" "0"

reset
perm sess-n3 Bash '{"command":"ls"}' '{"agent_id":"sub3"}'
hook_run request "$PATH_FULL"
notif sess-n3
hook_run notification "$PATH_FULL"
check "보조 신호 — 서브에이전트의 PermissionRequest 도 억제한다" "$(n_events)" "0"

reset
mkdir -p "$BASE/sess-n4"
printf '%s\n' "$(( $(now_ms) - 20000 ))" > "$BASE/sess-n4/seen"
plain sess-n4 SubagentStart '{"agent_id":"sub4","agent_type":"general-purpose"}'
hook_run agent-start "$PATH_FULL"
notif sess-n4
hook_run notification "$PATH_FULL"
check "보조 신호 — 서브에이전트 실행 중에는 없다" "$(n_events)" "0"
plain sess-n4 SubagentStop '{"agent_id":"sub4","agent_type":"general-purpose"}'
hook_run agent-stop "$PATH_FULL"
check "SubagentStop 이 실행 표시를 지운다" "$([ -e "$BASE/sess-n4/agent.sub4" ] && echo yes || echo no)" "no"
notif sess-n4
hook_run notification "$PATH_FULL"
check "보조 신호 — SubagentStop 뒤, 10초 지난 seen 이면 생긴다" "$(n_events)" "1"

reset
notif sess-n5 idle_prompt
hook_run notification "$PATH_FULL"
check "보조 신호 — 다른 알림 종류는 무시한다" "$(n_events)" "0"

# ---------------------------------------------------------------------------
# 9. Every path is quiet, with and without jq; no local banner.
# ---------------------------------------------------------------------------
reset
for role in request notification settle agent-start agent-stop stop prompt bogus ""; do
  perm sess-nj Bash '{"command":"ls"}'
  hook_run "$role" "$PATH_NO_JQ"
done
check "jq 없는 PATH — 상태도 사건도 없다" "$(find "$BASE" "$SPOOL" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
check "모든 실행이 종료 0, stdout·stderr 비어 있음" "${noisy:-없음}" "없음"
check "알림 도구가 한 번도 불리지 않았다" "$(grep -c . "$NOTIFY_LOG" 2>/dev/null || true)" "0"

# ---------------------------------------------------------------------------
# 10. The nine hooks.json entries.
# ---------------------------------------------------------------------------
entry() { # entry <event> <matcher or -> <role>
  jq -r --arg e "$1" --arg m "$2" --arg r "$3" '
    [.hooks[$e][]?
     | select(if $m == "-" then (has("matcher") | not) else .matcher == $m end)
     | .hooks[]
     | select(.command == ("bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-permission-notify.sh\" " + $r))
     | select(.timeout == 5)] | length' "$HOOKS_JSON"
}
check "hooks.json PermissionRequest → request" "$(entry PermissionRequest - request)" "1"
check "hooks.json Notification(permission_prompt) → notification" "$(entry Notification permission_prompt notification)" "1"
check "hooks.json PostToolUse(*) → settle" "$(entry PostToolUse '*' settle)" "1"
check "hooks.json PostToolUseFailure(*) → settle" "$(entry PostToolUseFailure '*' settle)" "1"
check "hooks.json PermissionDenied(*) → settle" "$(entry PermissionDenied '*' settle)" "1"
check "hooks.json SubagentStart → agent-start" "$(entry SubagentStart - agent-start)" "1"
check "hooks.json SubagentStop → agent-stop" "$(entry SubagentStop - agent-stop)" "1"
check "hooks.json Stop → stop" "$(entry Stop - stop)" "1"
check "hooks.json UserPromptSubmit → prompt" "$(entry UserPromptSubmit - prompt)" "1"
check "hooks.json 의 좌석 항목은 모두 아홉" \
  "$(jq -r '[.hooks[][]?.hooks[] | select(.command | contains("session-permission-notify.sh"))] | length' "$HOOKS_JSON")" "9"

finish
