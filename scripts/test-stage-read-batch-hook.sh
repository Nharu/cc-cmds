#!/usr/bin/env bash
# Test the PostToolBatch hook that tells a stage lead its last responses each
# carried a single read-only call (`plugins/cc-cmds/hooks/stage-read-batch.sh`).
#
# WHAT IT HOLDS THE HOOK TO. Silence outside a stage lead, for a team member,
# without `jq` and on input that is not JSON; inside a lead, a count of
# single-read responses in a row that any other response puts back to 0, and
# exactly one JSON hint when the count is 2, 6, 10, …; one registration under
# `PostToolBatch` with a 5-second timeout. Every case gets its own TMPDIR, so
# the state file of one case never leaks into the next.
#
# Usage: bash scripts/test-stage-read-batch-hook.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/stage-read-batch.sh"
HOOKS_JSON="$repo_root/plugins/cc-cmds/hooks/hooks.json"

# THIS SUITE IS RUN FROM INSIDE PIPELINE STAGES TOO, so every variable the hook
# reads is cleared first and each case sets exactly what it means to.
for v in $(compgen -e); do
  case "$v" in CC_PIPELINE_*) unset "$v" ;; esac
done
unset CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND

d=$(mktemp -d "${TMPDIR:-/tmp}/cc-read-batch-test.XXXXXX")
trap 'rm -rf "$d"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' 없음" ;; esac; }

SID='sess/1'
SAFE='sess_1'
GATE='/x/plugin/cc-cmds/orchestrator/gate.sh'

# A fresh TMPDIR per case.
newtmp() { mktemp -d "$d/case.XXXXXX"; }

# Call objects and the batch that carries them.
c_tool() { jq -cn --arg n "$1" '{tool_name: $n, tool_input: {file_path: "/f"}, tool_use_id: "t", tool_response: "ok"}'; }
c_bash() { jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}, tool_use_id: "t", tool_response: "ok"}'; }
batch() {
  local calls
  calls=$(printf '%s\n' "$@" | jq -cs '.')
  jq -cn --arg s "$SID" --argjson t "$calls" '{hook_event_name: "PostToolBatch", session_id: $s, tool_calls: $t}'
}

READ=$(c_tool Read)
EDIT=$(c_tool Edit)
EXEC_READ=$(c_bash "$GATE exec --manifest \"\$CC_PIPELINE_MANIFEST\" --cutpoint 커밋 --surface 읽기 --snapshot-digest 'h' --rationale 'r' -- grep -n x f")
EXEC_READ_EQ=$(c_bash "$GATE exec --manifest m --surface=읽기 -- grep x f")
EXEC_WRITE=$(c_bash "$GATE exec --manifest m --surface 워크트리쓰기 --rationale 'r' -- git commit -m x")
EXEC_AFTER=$(c_bash "$GATE exec --manifest m --surface 워크트리쓰기 -- grep --surface 읽기 f")
SNAP=$(c_bash "$GATE snapshot --manifest \"\$CC_PIPELINE_MANIFEST\" --fields H")

# run <tmpdir> <input> — the hook as a stage lead sees it; stdout to $out,
# stderr to $err, exit status to $rc.
run() {
  local t="$1" in="$2"
  out=$(printf '%s' "$in" | env CC_PIPELINE_STAGE_ID='A#1' TMPDIR="$t" bash "$HOOK" 2>"$d/err"); rc=$?
  err=$(cat "$d/err")
}
count_of() { cat "$1/cc-cmds-read-batch/$SAFE" 2>/dev/null; }
ctx_of() { jq -r '.hookSpecificOutput.additionalContext' <<< "$1" 2>/dev/null; }

# --- 1 no stage id ----------------------------------------------------------
t=$(newtmp)
out=$(batch "$READ" | env TMPDIR="$t" bash "$HOOK" 2>/dev/null); rc=$?
out2=$(batch "$READ" | env TMPDIR="$t" bash "$HOOK" 2>/dev/null)
check "1 스테이지 id 가 없으면 rc 0" "$rc" "0"
check "1 스테이지 id 가 없으면 출력 없음(두 번째 응답 뒤에도)" "$out$out2" ""
check "1 상태 파일이 생기지 않는다" "$([ -e "$t/cc-cmds-read-batch" ] && echo yes || echo no)" "no"

# --- 2 a member (agent_id) --------------------------------------------------
t=$(newtmp)
member=$(batch "$READ" | jq -c '. + {agent_id: "agent-7"}')
run "$t" "$member"; run "$t" "$member"
check "2 agent_id 가 있으면 rc 0" "$rc" "0"
check "2 agent_id 가 있으면 출력 없음" "$out" ""
check "2 agent_id 가 있으면 상태 파일이 생기지 않는다" "$([ -e "$t/cc-cmds-read-batch/$SAFE" ] && echo yes || echo no)" "no"

# --- 3 the second single-read response --------------------------------------
t=$(newtmp)
run "$t" "$(batch "$READ")"
check "3 첫 읽기 하나 응답 뒤 출력 없음" "$out" ""
check "3 첫 응답 뒤 연속 수 1" "$(count_of "$t")" "1"
run "$t" "$(batch "$READ")"
check "3 두 번째 응답 뒤 rc 0" "$rc" "0"
check "3 두 번째 응답 뒤 JSON 한 개" "$(jq -s 'length' <<< "$out" 2>/dev/null)" "1"
check "3 hookEventName 이 PostToolBatch" \
  "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out" 2>/dev/null)" "PostToolBatch"
ctx=$(ctx_of "$out")
case "$ctx" in
  '[cc-batch-hint] '*) ok "3 문면이 [cc-batch-hint] 로 시작한다" ;;
  *) bad "3 문면이 [cc-batch-hint] 로 시작한다" "$ctx" ;;
esac
has "3 문면이 연속 수 2 를 싣는다" "$ctx" "The last 2 responses"
check "3 문면은 한 줄의 ASCII" "$(printf '%s' "$ctx" | LC_ALL=C grep -c -a -E '[^ -~]' | tr -d ' ')" "0"
check "3 표준 오류는 비어 있다" "$err" ""

# --- 4 counts 3, 4, 5 are quiet, 6 speaks again ------------------------------
quiet=""
for i in 3 4 5; do
  run "$t" "$(batch "$READ")"
  quiet="$quiet$out"
done
check "4 연속 수 3·4·5 에서 출력 없음" "$quiet" ""
check "4 연속 수가 5 까지 올랐다" "$(count_of "$t")" "5"
run "$t" "$(batch "$READ")"
has "4 연속 수 6 에서 다시 나온다" "$(ctx_of "$out")" "The last 6 responses"

# --- 5 anything else puts the count back to 0 -------------------------------
t=$(newtmp)
run "$t" "$(batch "$READ")"
run "$t" "$(batch "$READ" "$READ")"
check "5 호출 둘을 실은 응답은 0 으로 되돌린다" "$(count_of "$t")" "0"
check "5 되돌린 응답은 출력 없음" "$out" ""
run "$t" "$(batch "$READ")"
run "$t" "$(batch "$EDIT")"
check "5 Edit 하나는 0 으로 되돌린다" "$(count_of "$t")" "0"
run "$t" "$(batch "$READ")"
run "$t" "$(batch "$EXEC_WRITE")"
check "5 워크트리쓰기 게이트 exec 하나는 0 으로 되돌린다" "$(count_of "$t")" "0"
run "$t" "$(batch "$READ")"
check "5 되돌린 뒤 첫 읽기 하나 응답은 1 이고 출력 없음" "$(count_of "$t"):$out" "1:"

# --- 6 gate reads count, an operand's --surface does not --------------------
t=$(newtmp)
run "$t" "$(batch "$EXEC_READ")"
check "6 --surface 읽기 의 게이트 exec 는 읽기" "$(count_of "$t")" "1"
run "$t" "$(batch "$SNAP")"
check "6 gate.sh snapshot 은 읽기" "$(count_of "$t")" "2"
has "6 게이트 읽기 둘 뒤에 안내가 나온다" "$(ctx_of "$out")" "The last 2 responses"
run "$t" "$(batch "$EXEC_READ_EQ")"
check "6 --surface=읽기 꼴도 읽기" "$(count_of "$t")" "3"
run "$t" "$(batch "$EXEC_AFTER")"
check "6 첫 -- 뒤 피연산자의 --surface 읽기 는 읽기가 아니다" "$(count_of "$t")" "0"

# --- 7 no jq ----------------------------------------------------------------
t=$(newtmp)
nojq="$d/nojq-bin"
mkdir -p "$nojq"
ln -s "$(command -v cat)" "$nojq/cat"
bash_bin=$(command -v bash)
out=$(batch "$READ" | env -i PATH="$nojq" TMPDIR="$t" CC_PIPELINE_STAGE_ID='A#1' \
  CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 "$bash_bin" "$HOOK" 2>"$d/err"); rc=$?
check "7 jq 가 없으면 rc 0" "$rc" "0"
check "7 jq 가 없으면 출력 없음" "$out$(cat "$d/err")" ""
check "7 jq 가 없으면 상태 파일이 생기지 않는다" "$([ -e "$t/cc-cmds-read-batch" ] && echo yes || echo no)" "no"

# --- 8 input that is not JSON -----------------------------------------------
t=$(newtmp)
run "$t" 'this is { not json'
check "8 JSON 이 아닌 입력은 rc 0" "$rc" "0"
check "8 JSON 이 아닌 입력은 출력이 비다" "$out" ""
check "8 JSON 이 아닌 입력은 표준 오류가 비다" "$err" ""

# --- 9 the registration -------------------------------------------------------
check "9 PostToolBatch 에 이 스크립트를 가리키는 항목이 정확히 하나" \
  "$(jq '[.hooks.PostToolBatch[]?.hooks[]? | select((.command // "") | contains("hooks/stage-read-batch.sh"))] | length' "$HOOKS_JSON" 2>/dev/null)" "1"
check "9 그 항목의 timeout 은 5" \
  "$(jq '[.hooks.PostToolBatch[]?.hooks[]? | select((.command // "") | contains("hooks/stage-read-batch.sh")) | .timeout] | .[0]' "$HOOKS_JSON" 2>/dev/null)" "5"
check "9 다른 이벤트에는 이 스크립트가 없다" \
  "$(jq '[.hooks | to_entries[] | select(.key != "PostToolBatch") | .value[]?.hooks[]? | select((.command // "") | contains("hooks/stage-read-batch.sh"))] | length' "$HOOKS_JSON" 2>/dev/null)" "0"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
