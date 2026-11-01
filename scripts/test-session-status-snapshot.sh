#!/usr/bin/env bash
# Test the session status snapshot hook —
# plugins/cc-cmds/hooks/session-status-snapshot.sh.
#
# The hook is driven the way the harness drives it — one JSON payload per event
# on stdin — and the exit status, stdout, stderr, the spool's `status/` file and
# the one-shot marker under TMPDIR are read back.
#
# EVERY CASE GETS ITS OWN SCRATCH ROOT (`fresh`): `HOME`, `TMPDIR`, the spool
# root (`CC_CMDS_ATTENTION_ROOT`), `CLAUDE_CONFIG_DIR` and the working
# directories all live under it, and `CLAUDE_PLUGIN_ROOT` is this tree's plugin.
#
# THE PIPELINE MARKERS ARE UNSET FOR EVERY RUN except the cases that set them,
# so the suite means the same inside an unattended stage.
#
# THE POSITIVE CONTROL COMES FIRST. A suite that only measures silence is green
# against a hook that never writes.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN="$repo_root/plugins/cc-cmds"
HOOK="$PLUGIN/hooks/session-status-snapshot.sh"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook parses JSON and nothing can be driven without it"
  echo "test-session-status-snapshot: 0 passed, 0 failed"
  exit 0
fi

# The inherited pipeline markers would make every run a stage run.
for v in $(compgen -v CC_PIPELINE_); do unset "$v"; done

# Normalized by `pwd`, so a TMPDIR ending in `/` does not leave a `//` that the
# shell's own PWD would not carry.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cc-session-status.XXXXXX")" && pwd)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

OUTF="$WORK/hook.out"
ERR="$WORK/hook.err"
NLOG="$WORK/notifier.log"
LOUD=0     # runs that exited non-zero or wrote to stdout/stderr, over the suite

# A terminal-notifier stand-in first on PATH; the hook must never call it.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$NLOG" > "$WORK/bin/terminal-notifier"
chmod +x "$WORK/bin/terminal-notifier"

SID='sess-1'

# fresh — a new scratch root for one case; sets s, ROOT, SNAP, MARK, PROJ.
fresh() {
  s=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$s/home" "$s/tmp" "$s/cfg" "$s/root" "$s/proj" "$s/plain"
  ROOT="$s/root"
  SNAP="$ROOT/status/$SID.json"
  MARK="$s/tmp/cc-cmds-session-status/$SID.form"
  PROJ="$s/proj"
  CWD="$PROJ"
}

# repo_at <dir> <origin url> — a git repository whose origin is that url.
repo_at() {
  ( cd "$1" && git init -q . >/dev/null 2>&1 && git remote add origin "$2" ) >/dev/null 2>&1
}

# pl <event> [<extra JSON object>] — the payload, with this case's sid and cwd.
pl() {
  local x="${2:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg e "$1" --arg s "$SID" --arg c "$CWD" --argjson x "$x" \
    '{hook_event_name: $e, session_id: $s, cwd: $c} + $x'
}

# hook_run <stdin> [<env assignment>...] — sets HOOK_RC; output in OUTF / ERR.
hook_run() {
  local input="$1"; shift
  ( cd "$s/plain" && printf '%s' "$input" | env HOME="$s/home" TMPDIR="$s/tmp" \
      CC_CMDS_ATTENTION_ROOT="$ROOT" CLAUDE_CONFIG_DIR="$s/cfg" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      PATH="$WORK/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$s" "$@" \
      bash "$HOOK" > "$OUTF" 2> "$ERR" )
  HOOK_RC=$?
  if [ "$HOOK_RC" -ne 0 ] || [ -s "$OUTF" ] || [ -s "$ERR" ]; then
    LOUD=$((LOUD + 1))
    printf 'loud run: rc=%s stdout=%s stderr=%s\n' "$HOOK_RC" \
      "$(head -c 200 "$OUTF")" "$(head -c 200 "$ERR")" >&2
  fi
}

field() { jq -r "$1" "$SNAP" 2>/dev/null; }
absent() { if [ -e "$2" ]; then bad "$1" "$2 이 있다"; else ok "$1"; fi; }
present() { if [ -e "$2" ]; then ok "$1"; else bad "$1" "$2 이 없다"; fi; }
same_file() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "바이트가 달라졌다"; fi; }
listing() { ( cd "$1" 2>/dev/null && find . | LC_ALL=C sort ); }
mode_of() { perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$1"; }

# ---------------------------------------------------------------------------
# 1. Stop → idle; the nine keys and their values.
# ---------------------------------------------------------------------------
fresh
repo_at "$PROJ" 'git@github.com:o/n.git'
hook_run "$(pl Stop '{"last_assistant_message":"안녕\n끝"}')"
present "1 Stop 이 스냅숏을 쓴다" "$SNAP"
check "1 키 아홉" "$(jq -c 'keys' "$SNAP" 2>/dev/null)" \
  '["config_dir","cwd","excerpt","host","last_activity_ms","repo","schema","session_id","state"]'
check "1 schema 1" "$(field '.schema')" "1"
check "1 state idle" "$(field '.state')" "idle"
check "1 session_id" "$(field '.session_id')" "$SID"
check "1 excerpt" "$(field '.excerpt')" "$(printf '안녕\n끝')"
check "1 host-id 파일 없음 → local" "$(field '.host')" "local"
check "1 config_dir = CLAUDE_CONFIG_DIR" "$(field '.config_dir')" "$s/cfg"
check "1 cwd = 입력 cwd" "$(field '.cwd')" "$PROJ"
check "1 repo (scp 꼴 origin)" "$(field '.repo')" "o/n"
check "1 last_activity_ms 양의 정수" \
  "$(jq -r '.last_activity_ms | (type == "number" and . > 0 and . == floor)' "$SNAP" 2>/dev/null)" "true"

mkdir -p "$s/home/.config/cc-cmds"
printf 'box-1\n' > "$s/home/.config/cc-cmds/host-id"
hook_run "$(pl Stop '{"last_assistant_message":"x"}')"
check "1 host-id 파일 값" "$(field '.host')" "box-1"
printf 'Bad_ID\n' > "$s/home/.config/cc-cmds/host-id"
hook_run "$(pl Stop '{"last_assistant_message":"x"}')"
check "1 host-id 형식 틀림 → local" "$(field '.host')" "local"

hook_run "$(pl Stop '{"last_assistant_message":"x"}')" CLAUDE_CONFIG_DIR=
check "1 CLAUDE_CONFIG_DIR 비어 있음 → HOME/.claude" "$(field '.config_dir')" "$s/home/.claude"

fresh
repo_at "$PROJ" 'https://github.com/o/n'
hook_run "$(pl Stop '{"last_assistant_message":"x"}')"
check "1 repo (https origin)" "$(field '.repo')" "o/n"
CWD="$s/plain"
hook_run "$(pl Stop '{"last_assistant_message":"x"}')"
check "1 레포 밖 → repo null" "$(field '.repo')" "null"
hook_run "$(jq -cn --arg s "$SID" '{hook_event_name: "Stop", session_id: $s, last_assistant_message: "x"}')"
check "1 cwd 없음 → PWD" "$(field '.cwd')" "$s/plain"

# ---------------------------------------------------------------------------
# 2. Excerpt cutting.
# ---------------------------------------------------------------------------
fresh
long=$(i=1; while [ "$i" -le 300 ]; do printf '줄 %03d 가나다라마바사아자차카타파하\n' "$i"; i=$((i + 1)); done)
hook_run "$(pl Stop "$(jq -cn --arg m "$long" '{last_assistant_message: $m}')")"
check "2 끝쪽: 4096 바이트 이하, 원문 줄들의 끝쪽 연속 부분, 한 줄 더하면 넘침" \
  "$(jq -r --arg t "$long" '.excerpt as $e
     | ($e | utf8bytelength) <= 4096 and ($t | endswith($e))
       and ($t[0:(($t | length) - ($e | length))] | endswith("\n"))
       and (($t[0:(($t | length) - ($e | length) - 1)] | split("\n") | last | utf8bytelength)
            + 1 + ($e | utf8bytelength) > 4096)' "$SNAP" 2>/dev/null)" "true"

opts=$(jq -cn '[range(1; 301) | {label: ("선택지 \(.) 가나다라마바사아자차카타파하")}]')
ask=$(jq -cn --argjson o "$opts" '{tool_name: "AskUserQuestion",
  tool_input: {questions: [{header: "머리", question: "무엇을 할까요?", options: $o}]}}')
full=$(printf '%s' "$ask" | jq -r '.tool_input.questions[0] as $q
  | ([$q.header + " — " + $q.question] + [$q.options[] | "- " + .label]) | join("\n")')
hook_run "$(pl PreToolUse "$ask")"
check "2 앞쪽: 질문 발췌는 원문의 앞쪽 연속 부분" \
  "$(jq -r --arg t "$full" '.excerpt as $e
     | ($e | utf8bytelength) <= 4096 and ($t | startswith($e))
       and ($t[($e | length):] | startswith("\n"))' "$SNAP" 2>/dev/null)" "true"

one=$(jq -rn '[range(0; 2000) | "가"] | join("")')
hook_run "$(pl Stop "$(jq -cn --arg m "$one" '{last_assistant_message: $m}')")"
check "2 4096 바이트를 넘는 한 줄은 글자 경계에서 잘림" \
  "$(jq -r '.excerpt | (utf8bytelength) == 4095 and (explode | unique) == ("가" | explode)' "$SNAP" 2>/dev/null)" "true"
if jq -j '.excerpt' "$SNAP" 2>/dev/null \
     | perl -MEncode -0777 -ne 'Encode::decode("UTF-8", $_, Encode::FB_CROAK); exit 0' >/dev/null 2>&1; then
  ok "2 잘린 발췌가 UTF-8 로 읽힘"
else
  bad "2 잘린 발췌가 UTF-8 로 읽힘" "UTF-8 복호 실패"
fi

# ---------------------------------------------------------------------------
# 3. AskUserQuestion: PreToolUse → waiting-question, PostToolUse → working.
# ---------------------------------------------------------------------------
fresh
ask='{"tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"header":"범위","question":"어디까지?","options":[{"label":"A"},{"label":"B"}]},
  {"question":"둘째?","options":[{"label":"C"}]}]}}'
hook_run "$(pl PreToolUse "$ask")"
check "3 PreToolUse → waiting-question" "$(field '.state')" "waiting-question"
want=$(printf '범위 — 어디까지?\n- A\n- B\n질문 — 둘째?\n- C')
check "3 발췌: 머리말·질문·라벨, 머리말 없으면 질문" "$(field '.excerpt')" "$want"
hook_run "$(pl PostToolUse "$ask")"
check "3 PostToolUse → working" "$(field '.state')" "working"
check "3 working 발췌는 그대로" "$(field '.excerpt')" "$want"
cp "$SNAP" "$WORK/before"
hook_run "$(pl PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
same_file "3 다른 도구의 PreToolUse 는 쓰지 않음" "$WORK/before" "$SNAP"

# ---------------------------------------------------------------------------
# 4. The question form through PostToolBatch, and the one-shot marker.
# ---------------------------------------------------------------------------
fresh
batch='{"tool_calls":[
  {"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_use_id":"t1","tool_response":"QUESTION_FORM_OPEN not this one"},
  {"tool_name":"mcp__cc-cmds__question_form","tool_use_id":"t2",
   "tool_input":{"title":"설정","questions":[{"id":"q1","question":"색?","options":[{"label":"빨강"},{"label":"파랑"}]}]},
   "tool_response":[{"type":"text","text":"QUESTION_FORM_OPEN f1 질문 1건"}]}]}'
hook_run "$(pl PostToolBatch "$batch")"
check "4 질문지 열림 → waiting-question" "$(field '.state')" "waiting-question"
check "4 발췌 첫 줄은 제목" "$(field '.excerpt')" "$(printf '설정\n질문 — 색?\n- 빨강\n- 파랑')"
present "4 표지가 생긴다" "$MARK"
cp "$SNAP" "$WORK/before"
hook_run "$(pl Stop '{"last_assistant_message":"질문지를 열었습니다"}')"
same_file "4 이어진 Stop: 스냅숏 바이트 불변" "$WORK/before" "$SNAP"
absent "4 이어진 Stop: 표지 사라짐" "$MARK"
hook_run "$(pl Stop '{"last_assistant_message":"다음 차례"}')"
check "4 그다음 Stop → idle" "$(field '.state')" "idle"

cp "$SNAP" "$WORK/before"
busy='{"tool_calls":[{"tool_name":"mcp__cc-cmds__question_form","tool_use_id":"t3",
  "tool_input":{"title":"x","questions":[]},"tool_response":"QUESTION_FORM_BUSY f2"}]}'
hook_run "$(pl PostToolBatch "$busy")"
same_file "4 QUESTION_FORM_BUSY → 불변" "$WORK/before" "$SNAP"
absent "4 QUESTION_FORM_BUSY → 표지 없음" "$MARK"
hook_run "$(pl PostToolBatch '{"tool_calls":[{"tool_name":"Read","tool_input":{},"tool_use_id":"t4","tool_response":"ok"}]}')"
same_file "4 질문지 없는 묶음 → 불변" "$WORK/before" "$SNAP"

# ---------------------------------------------------------------------------
# 5. PermissionRequest.
# ---------------------------------------------------------------------------
fresh
hook_run "$(pl PermissionRequest '{"tool_name":"Bash","tool_input":{"command":"touch /tmp/probe","description":"d"}}')"
check "5 Bash → waiting-permission" "$(field '.state')" "waiting-permission"
check "5 발췌: 도구 이름과 명령" "$(field '.excerpt')" "$(printf 'Bash\ntouch /tmp/probe')"
hook_run "$(pl PermissionRequest '{"tool_name":"Edit","tool_input":{"file_path":"/a/b","old_string":"x"}}')"
check "5 file_path 도구 → 경로" "$(field '.excerpt')" "$(printf 'Edit\n/a/b')"
hook_run "$(pl PermissionRequest '{"tool_name":"WebFetch","tool_input":{"url":"https://e.x","prompt":"p"}}')"
check "5 다른 도구 → 압축 JSON" "$(field '.excerpt')" "$(printf 'WebFetch\n{"url":"https://e.x","prompt":"p"}')"
cp "$SNAP" "$WORK/before"
hook_run "$(pl PermissionRequest '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}')"
same_file "5 AskUserQuestion 권한 요청 → 불변" "$WORK/before" "$SNAP"
hook_run "$(pl PermissionRequest '{"tool_name":"mcp__cc-cmds__question_form","tool_input":{}}')"
same_file "5 질문지 권한 요청 → 불변" "$WORK/before" "$SNAP"

# ---------------------------------------------------------------------------
# 6. UserPromptSubmit and SessionEnd.
# ---------------------------------------------------------------------------
fresh
hook_run "$(pl Stop '{"last_assistant_message":"이전 출력"}')"
mkdir -p "$(dirname "$MARK")"; : > "$MARK"
hook_run "$(pl UserPromptSubmit '{"prompt":"다음"}')"
check "6 UserPromptSubmit → working" "$(field '.state')" "working"
check "6 working 발췌는 직전 것" "$(field '.excerpt')" "이전 출력"
absent "6 UserPromptSubmit 이 표지를 지움" "$MARK"
: > "$MARK"
hook_run "$(pl SessionEnd '{"reason":"clear"}')"
absent "6 SessionEnd 가 스냅숏을 지움" "$SNAP"
absent "6 SessionEnd 가 표지를 지움" "$MARK"
hook_run "$(pl UserPromptSubmit '{"prompt":"새로"}')"
check "6 직전 파일 없음 → 발췌 빈 문자열" "$(field '.excerpt')" ""

# ---------------------------------------------------------------------------
# 7. The cases that write nothing.
# ---------------------------------------------------------------------------
fresh
hook_run "$(pl Stop '{"last_assistant_message":"기준"}')"
before=$(listing "$ROOT")
cp "$SNAP" "$WORK/before"
hook_run "$(pl Stop '{"last_assistant_message":"x","agent_id":"a1","agent_type":"Explore"}')"
check "7 agent_id → 스풀 목록 불변" "$(listing "$ROOT")" "$before"
same_file "7 agent_id → 스냅숏 불변" "$WORK/before" "$SNAP"
for v in CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  hook_run "$(pl Stop '{"last_assistant_message":"x"}')" "$v=1"
  check "7 $v → 스풀 목록 불변" "$(listing "$ROOT")" "$before"
  same_file "7 $v → 스냅숏 불변" "$WORK/before" "$SNAP"
done
hook_run "$(jq -cn --arg c "$CWD" '{hook_event_name: "Stop", session_id: "", cwd: $c, last_assistant_message: "x"}')"
check "7 빈 session_id → 스풀 목록 불변" "$(listing "$ROOT")" "$before"
hook_run "$(pl SessionEnd '{"reason":"other","agent_id":"a1"}')"
present "7 agent_id 의 SessionEnd 는 지우지 않음" "$SNAP"
hook_run "$(pl Stop '{"last_assistant_message":"x"}')" CC_CMDS_ATTENTION_ROOT="$s/none"
absent "7 스풀 루트 없음 → 루트가 생기지 않음" "$s/none"
check "7 스풀 루트 없음 → 다른 스풀 목록 불변" "$(listing "$ROOT")" "$before"

# ---------------------------------------------------------------------------
# 8. The session is not changed.
# ---------------------------------------------------------------------------
fresh
hook_run "$(pl Stop '{"last_assistant_message":"배너 꺼짐"}')" CC_CMDS_SESSION_NOTIFY=0 CC_CMDS_AUTOPILOT_NOTIFY=0
check "8 CC_CMDS_SESSION_NOTIFY=0 에서도 쓴다" "$(field '.excerpt')" "배너 꺼짐"
hook_run 'not json at all'
hook_run "$(pl Notification '{"message":"m"}')"
check "8 모든 실행이 rc 0 이고 stdout·stderr 가 비어 있음" "$LOUD" "0"
absent "8 terminal-notifier 대역이 불리지 않음" "$NLOG"

# ---------------------------------------------------------------------------
# 9. File modes.
# ---------------------------------------------------------------------------
check "9 status/ 는 0700" "$(mode_of "$ROOT/status")" "700"
check "9 스냅숏은 0600" "$(mode_of "$SNAP")" "600"
check "9 status/ 에 점 파일 없음" "$(cd "$ROOT/status" && find . -name '.?*' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# 10. Registration.
# ---------------------------------------------------------------------------
TAB=$(printf '\t')
reg=$(jq -r '.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "") as $m
  | .hooks[] | "\($e)\t\($m)\t\(.command)\t\(.timeout // "")"' "$HOOKS_JSON" 2>/dev/null)
mine='bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-status-snapshot.sh"'
check "10 이 스크립트를 가리키는 항목은 일곱" \
  "$(printf '%s\n' "$reg" | grep -cF "$mine")" "7"
for em in 'PreToolUse	AskUserQuestion' 'PostToolUse	AskUserQuestion' 'PostToolBatch	' \
          'Stop	' 'UserPromptSubmit	' 'PermissionRequest	' 'SessionEnd	'; do
  if printf '%s\n' "$reg" | grep -qxF "$em$TAB$mine${TAB}5"; then
    ok "10 등록: ${em%%"$TAB"*} ${em#*"$TAB"}"
  else
    bad "10 등록: ${em%%"$TAB"*} ${em#*"$TAB"}" "항목이 없거나 timeout 이 5 가 아니다"
  fi
done
old=$(cat <<'EOF'
PreToolUse	Bash	bash "${CLAUDE_PLUGIN_ROOT}/hooks/active-notify-pretool.sh"
PreToolUse	AskUserQuestion	bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-ask-notify.sh"
PostToolUse	Edit|Write|MultiEdit	bash "${CLAUDE_PLUGIN_ROOT}/hooks/stage-rules-edit.sh"
PostToolUse	AskUserQuestion	bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-return-dismiss.sh"
Stop		bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-turn-notify.sh"
Stop		bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-return-dismiss.sh"
UserPromptSubmit		bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-return-dismiss.sh"
UserPromptSubmit		bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-title.sh"
SessionStart	startup	bash "${CLAUDE_PLUGIN_ROOT}/hooks/statusline-sessionstart.sh" --plugin-dir "${CLAUDE_PLUGIN_ROOT}"
EOF
)
missing=0
while IFS= read -r line; do
  printf '%s\n' "$reg" | cut -f1-3 | grep -qxF "$line" || missing=$((missing + 1))
done <<EOF
$old
EOF
check "10 기존 아홉 명령 항목이 그대로 있음" "$missing" "0"

echo "test-session-status-snapshot: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
