#!/usr/bin/env bash
# Test the attention taps inside the banner funnel — the event tap in
# `cc_notify_fire`, the handled tap in `cc_notify_clear`, and the attachments the
# seats hand them — by driving the seats' own entry points: the question seat
# hook, the return hook, the gate (sourced only, against a fixture run) and the
# watcher.
#
# WHAT THIS SUITE READS. The spool root is a directory this suite creates and
# names through `CC_CMDS_ATTENTION_ROOT`, so every record lands where the
# assertions can count it and none reaches the account spool. The notifier is a
# PATH stub that logs its argv, and the host is pinned through
# `CC_CMDS_NOTIFY_HOST_OS`, so the Darwin branch is reached on every leg.
#
# THE PIPELINE VARIABLES ARE CLEARED FOR EVERY RUN. This suite may run inside an
# unattended stage, where the stage markers are exported and every seat would
# then refuse to fire; a stage case sets its marker explicitly.
#
# Usage: bash scripts/test-attention-funnel.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
ORCH="$PLUGIN_ROOT/orchestrator"
ASK_HOOK="$PLUGIN_ROOT/hooks/session-ask-notify.sh"
RETURN_HOOK="$PLUGIN_ROOT/hooks/session-return-dismiss.sh"
GATE="$ORCH/gate.sh"
WATCH="$ORCH/watch.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
finish() {
  printf 'test-attention-funnel: %s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit $?
}

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — the seats and the tap parse JSON and nothing can be driven without it"
  echo "test-attention-funnel: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-attention-funnel.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Attachments are made under TMPDIR, so the suite's own directory is where a
# leftover would show.
DETAIL_TMP="$WORK/tmp"
mkdir -p "$DETAIL_TMP"

BIN="$WORK/bin"
BIN_NO_NOTIFIER="$WORK/bin-nn"
mkdir -p "$BIN" "$BIN_NO_NOTIFIER"
cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$BIN/terminal-notifier"
ln -s "$JQ" "$BIN/jq"
ln -s "$JQ" "$BIN_NO_NOTIFIER/jq"
PATH_FULL="$BIN:/usr/bin:/bin"
PATH_NO_NOTIFIER="$BIN_NO_NOTIFIER:/usr/bin:/bin"
NOTIFY_LOG="$WORK/notifier.log"
: > "$NOTIFY_LOG"
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR"

# The emitter launches the notifier detached, so a write can land after the
# process that raised it has exited.
notify_settle() {
  local want="$1" i=0 n
  while [ "$i" -lt 40 ]; do
    n=$(grep -c . "$NOTIFY_LOG" 2>/dev/null || true)
    if [ "${n:-0}" -ge "$want" ]; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

ROOT=""
spool() {
  # spool [absent] — a new spool root for one case; `absent` names one that is
  # never created.
  ROOT="$WORK/spool.$RANDOM$RANDOM"
  if [ "${1:-}" != "absent" ]; then mkdir -p "$ROOT"; fi
}
n_events()  { find "$ROOT/events" -type f -name '*.json' 2>/dev/null | grep -c . || true; }
n_handled() { find "$ROOT/handled" -type f -name '*.json' 2>/dev/null | grep -c . || true; }
event_file() { find "$ROOT/events" -type f -name '*.json' 2>/dev/null | head -1; }
event_jq()  { local f; f=$(event_file); [ -n "$f" ] || { printf 'no-event'; return 0; }; jq -r "$1" "$f"; }
n_leftover_detail() { find "$DETAIL_TMP" -name 'cc-attention-detail.*' 2>/dev/null | grep -c . || true; }

# One hook run in a clean environment: HOME, TMPDIR, PATH and the spool root are
# the suite's own, and every pipeline marker is absent unless a case passes one.
hook_run() {
  local hook="$1" payload="$2" path="$3"; shift 3
  env -i HOME="$HOME_DIR" PATH="$path" TMPDIR="$DETAIL_TMP" \
      CC_CMDS_ATTENTION_ROOT="$ROOT" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin \
      CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      XDG_STATE_HOME="$WORK/state" \
      "$@" < "$payload" > "$WORK/hook.out" 2> "$WORK/hook.err"
}
pay() { printf '%s' "$1" > "$WORK/payload.json"; printf '%s' "$WORK/payload.json"; }

SID="11111111-2222-3333-4444-555555555555"
AUQ_TWO='{"hook_event_name":"PreToolUse","session_id":"'"$SID"'","tool_name":"AskUserQuestion","tool_use_id":"toolu_01ABC","tool_input":{"questions":[{"header":"범위","question":"어디까지 바꿀까요?","multiSelect":false,"options":[{"label":"전부","description":"d"},{"label":"일부","description":"d"}]},{"header":"순서","question":"무엇부터 할까요?","multiSelect":true,"options":[{"label":"가","description":"d"},{"label":"나","description":"d"}]}]}}'

# --------------------------------------------------------------------------
# 1. The question seat — AskUserQuestion.
# --------------------------------------------------------------------------
spool
hook_run "$ASK_HOOK" "$(pay "$AUQ_TWO")" "$PATH_FULL" bash "$ASK_HOOK"
check "1 질문 좌석 훅의 종료 상태" "$?" "0"
check "1 질문 좌석 훅의 출력 없음" "$(cat "$WORK/hook.out" "$WORK/hook.err" | wc -c | tr -d ' ')" "0"
check "1 auq 사건 하나" "$(n_events)" "1"
check "1 사건 종류" "$(event_jq .kind)" "auq"
check "1 본문은 두 질문의 전체 문면" "$(event_jq .body)" "범위 — 어디까지 바꿀까요?
순서 — 무엇부터 할까요?"
check "1 답 대상의 도구 호출 id" "$(event_jq .reply.tool_use_id)" "toolu_01ABC"
check "1 답 대상의 다중 선택 여부" "$(event_jq '[.reply.questions[].multi_select] | map(tostring) | join(",")')" "false,true"
check "1 답 대상의 선택지 라벨" "$(event_jq '[.reply.questions[0].options[].label] | join(",")')" "전부,일부"
check "1 답할 수 있음" "$(event_jq .actionable)" "true"
check "1 슬롯은 세션 그룹" "$(event_jq .slot)" "cc-cmds-session-$SID"
check "1 첨부 파일이 남지 않음" "$(n_leftover_detail)" "0"

# An approval-shaped question anywhere in the call — here the second one — keeps
# the event from being answerable.
spool
APPR_SECOND=$(printf '%s' "$AUQ_TWO" | jq -c '.tool_input.questions[1].question = "승인 J-1a2b3c4d — 계속할까요?"')
hook_run "$ASK_HOOK" "$(pay "$APPR_SECOND")" "$PATH_FULL" bash "$ASK_HOOK"
check "1 둘째 질문이 승인 모양이면 사건은 남는다" "$(n_events)" "1"
check "1 둘째 질문이 승인 모양이면 답할 수 없음" "$(event_jq .actionable)" "false"

# The seats that must not fire leave no event.
spool
hook_run "$ASK_HOOK" "$(pay "$(printf '%s' "$AUQ_TWO" | jq -c '.agent_id = "agent-1"')")" "$PATH_FULL" bash "$ASK_HOOK"
check "1 띄운 에이전트에서는 사건 0" "$(n_events)" "0"
hook_run "$ASK_HOOK" "$(pay "$AUQ_TWO")" "$PATH_FULL" CC_PIPELINE_STAGE_ID='A#1' bash "$ASK_HOOK"
check "1 스테이지 표지가 있으면 사건 0" "$(n_events)" "0"
hook_run "$ASK_HOOK" "$(pay "$AUQ_TWO")" "$PATH_FULL" CC_CMDS_SESSION_NOTIFY=0 bash "$ASK_HOOK"
check "1 스위치가 꺼지면 사건 0" "$(n_events)" "0"
check "1 사건이 없는 길에서도 첨부 파일이 남지 않음" "$(n_leftover_detail)" "0"

# --------------------------------------------------------------------------
# 2. The question seat — the question form's call.
# --------------------------------------------------------------------------
FORM_STDIN='{"hook_event_name":"PreToolUse","session_id":"'"$SID"'","tool_name":"mcp__cc-cmds__question_form","tool_input":{"questions":[{"header":"범위","question":"어디까지 바꿀까요?"},{"header":"순서","question":"무엇부터 할까요?"}]}}'
FORM_ARG='{"form_id":"form-abc","questions":[{"id":"q1","header":"범위","question":"어디까지 바꿀까요?","kind":"single","conditional":false,"options":[{"label":"전부"},{"label":"일부"}]},{"id":"q2","header":"순서","question":"무엇부터 할까요?","kind":"single","conditional":false,"options":[{"label":"가"}]}]}'
spool
hook_run "$ASK_HOOK" "$(pay "$FORM_STDIN")" "$PATH_FULL" bash "$ASK_HOOK" "$FORM_ARG"
check "2 질문지 사건 하나" "$(n_events)" "1"
check "2 사건 종류" "$(event_jq .kind)" "question-form"
check "2 답 대상의 질문지 id" "$(event_jq .reply.form_id)" "form-abc"
check "2 답 대상의 질문 id" "$(event_jq '[.reply.questions[].id] | join(",")')" "q1,q2"
check "2 단일 선택만 있으면 답할 수 있음" "$(event_jq .actionable)" "true"
check "2 본문은 전체 문면" "$(event_jq .body)" "범위 — 어디까지 바꿀까요?
순서 — 무엇부터 할까요?"

spool
hook_run "$ASK_HOOK" "$(pay "$FORM_STDIN")" "$PATH_FULL" bash "$ASK_HOOK" \
  "$(printf '%s' "$FORM_ARG" | jq -c '.questions[1].kind = "multi"')"
check "2 복수 선택 질문이 있으면 답할 수 없음" "$(event_jq .actionable)" "false"
spool
hook_run "$ASK_HOOK" "$(pay "$FORM_STDIN")" "$PATH_FULL" bash "$ASK_HOOK" \
  "$(printf '%s' "$FORM_ARG" | jq -c '.questions[1].conditional = true')"
check "2 조건부 질문이 있으면 답할 수 없음" "$(event_jq .actionable)" "false"
spool
hook_run "$ASK_HOOK" "$(pay "$FORM_STDIN")" "$PATH_FULL" bash "$ASK_HOOK"
check "2 추가 인자가 없어도 질문지 사건" "$(event_jq .kind)" "question-form"
check "2 추가 인자가 없으면 답 대상 없음" "$(event_jq .reply)" "null"
check "2 추가 인자가 없으면 답할 수 없음" "$(event_jq .actionable)" "false"
check "2 첨부 파일이 남지 않음" "$(n_leftover_detail)" "0"

# --------------------------------------------------------------------------
# 3. The return hook closes the session's slot.
# --------------------------------------------------------------------------
spool
hook_run "$RETURN_HOOK" \
  "$(pay '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"다음으로 가자"}')" \
  "$PATH_FULL" CC_CMDS_NOTIFY_DISMISS_SYNC=1 bash "$RETURN_HOOK"
check "3 귀환 훅의 종료 상태" "$?" "0"
ret=$(find "$ROOT/handled" -type f -name '*.json' 2>/dev/null \
      | while IFS= read -r f; do jq -r 'select(.slot == "cc-cmds-session-'"$SID"'") | .cause' "$f"; done)
check "3 그 세션 슬롯의 return 처리 표지" "$ret" "return"

# --------------------------------------------------------------------------
# 4. The banner function itself: the tokens without events, a host without the
#    notifier, and the notifier's argv with and without a spool.
# --------------------------------------------------------------------------
emit_run() {
  # emit_run <path> <cmd...> — run emitter calls in a clean shell.
  local path="$1"; shift
  env -i HOME="$HOME_DIR" PATH="$path" TMPDIR="$DETAIL_TMP" \
      CC_CMDS_ATTENTION_ROOT="$ROOT" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      CC_NOTIFY_SESSION_ID="$SID" RUN_ID=R-funnel \
      bash -c '. "$1"; shift; "$@"' emit "$ORCH/notify-run.sh" "$@"
}
spool
emit_run "$PATH_FULL" cc_notify_fire focus-guide "안내" >/dev/null 2>&1
emit_run "$PATH_FULL" cc_notify_fire answer-run "런이 사람을 기다립니다" >/dev/null 2>&1
check "4 클릭 안내와 런 수준 요약은 사건 0" "$(n_events)" "0"

spool
out=$(emit_run "$PATH_NO_NOTIFIER" cc_notify_fire session-turn "차례" 2>&1; printf 'rc=%s' "$?")
check "4 알림 도구가 없어도 사건이 생긴다" "$(n_events)" "1"
check "4 알림 도구가 없을 때 배너 함수의 출력과 종료 상태" "$out" "rc=0"

argv_of() {
  # argv_of <root-mode> — the notifier argv for one fixed call.
  : > "$NOTIFY_LOG"
  spool "$1"
  emit_run "$PATH_FULL" cc_notify_fire hands "막혔습니다 — 손대세요" park-S1 >/dev/null 2>&1
  notify_settle 1
  cat "$NOTIFY_LOG"
}
with_root=$(argv_of present)
without_root=$(argv_of absent)
check "4 스풀이 있을 때와 없을 때 알림 도구 argv 가 같다" "$with_root" "$without_root"
check "4 argv 비교가 빈 값이 아니다" "$([ -n "$with_root" ] && echo yes || echo no)" "yes"

# An attachment handed to a call that returns before the tap is removed.
spool
d=$(env -i TMPDIR="$DETAIL_TMP" PATH="$PATH_FULL" bash -c '. "$1"; cc_attention_detail_make "{}"' x "$ORCH/notify-run.sh")
env -i HOME="$HOME_DIR" PATH="$PATH_FULL" CC_CMDS_ATTENTION_ROOT="$ROOT" CC_CMDS_NOTIFY_HOST_OS=Linux \
  CC_NOTIFY_ATTENTION_DETAIL="$d" bash -c '. "$1"; cc_notify_fire ended "끝"' x "$ORCH/notify-run.sh" >/dev/null 2>&1
check "4 Darwin 이 아닌 호스트에서 첨부를 지운다" "$([ -e "$d" ] && echo left || echo gone)" "gone"
d=$(env -i TMPDIR="$DETAIL_TMP" PATH="$PATH_FULL" bash -c '. "$1"; cc_attention_detail_make "{}"' x "$ORCH/notify-run.sh")
env -i HOME="$HOME_DIR" PATH="$PATH_FULL" CC_CMDS_ATTENTION_ROOT="$ROOT" CC_CMDS_NOTIFY_HOST_OS=Darwin \
  CC_CMDS_AUTOPILOT_NOTIFY=0 CC_NOTIFY_ATTENTION_DETAIL="$d" \
  bash -c '. "$1"; cc_notify_fire ended "끝"' x "$ORCH/notify-run.sh" >/dev/null 2>&1
check "4 꺼진 스위치에서 첨부를 지운다" "$([ -e "$d" ] && echo left || echo gone)" "gone"
check "4 그 두 길은 사건 0" "$(n_events)" "0"

# The library is read only inside the tap helper's child shell, so its
# top-level names never land in the shell that sourced the banner file.
defs=$(env -i HOME="$HOME_DIR" PATH="$PATH_FULL" bash -c \
  '. "$1"; type -t cc_attention_emit; type -t cc_attention_handled; true' x "$ORCH/notify-run.sh" 2>/dev/null)
check "4 배너 파일을 읽은 셸에 탭 함수가 정의되지 않는다" "$defs" ""

# --------------------------------------------------------------------------
# 5. The gate and the watcher on one fixture run.
# --------------------------------------------------------------------------
RID="R-funnel-0001"
AID="J-1a2b3c4d"
FULLQ="이 판단을 받아들일까요? 근거는 길고 원장 행에는 발췌만 실립니다 — 전체 문면은 사이드카에 있습니다"
EXCERPT="이 판단을 받아들일까요?"
CANON="승인 $AID — $FULLQ"

fixture_run() {
  # fixture_run — a base with the ledger, the authorization record and the
  # sidecar block of one waiting judgment approval, under a fresh case dir.
  FX="$WORK/fx.$RANDOM$RANDOM"
  BASE_DIR="$FX/base"
  RUN_DIR_FX="$FX/runs/$RID"
  LEDGER_FX="$BASE_DIR/docs/pipeline-run/$RID.md"
  GRANT_FX="$BASE_DIR/docs/pipeline-grant/$RID.md"
  mkdir -p "$BASE_DIR/docs/pipeline-run" "$BASE_DIR/docs/pipeline-grant" "$RUN_DIR_FX"
  printf '# 인가\n' > "$GRANT_FX"
  printf -- '- `승인` | 승인 id=%s | 상태=대기 | 절단점=판단 | 막는 세그먼트=S1 | 질문 문면=%s\n' \
    "$AID" "$EXCERPT" > "$LEDGER_FX"
  printf '%s\n' 1577836800 > "$RUN_DIR_FX/started-at"
  gate_src 'gate_approval_sidecar_write "$AID" issue 질문 "$FULLQ"' >/dev/null 2>&1
}
gate_src() {
  # gate_src <script> [env...] — run a script against the gate sourced only,
  # with the fixture run's paths, in a clean environment.
  local script="$1"; shift
  env -i HOME="$HOME_DIR" PATH="$PATH_FULL" TMPDIR="$DETAIL_TMP" \
      CC_CMDS_ATTENTION_ROOT="$ROOT" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      AID="$AID" FULLQ="$FULLQ" FX_BASE="$BASE_DIR" FX_RID="$RID" \
      FX_RD="$RUN_DIR_FX" FX_LG="$LEDGER_FX" FX_GR="$GRANT_FX" \
      CC_GATE_SOURCE_ONLY=1 "$@" \
      bash -c '
        g=$1; s=$2
        set --
        . "$g" >/dev/null 2>&1 || exit 3
        set +e
        unset CC_GATE_SOURCE_ONLY
        BASE=$FX_BASE; RUN_ID=$FX_RID; RUN_DIR=$FX_RD; LEDGER=$FX_LG; GRANT=$FX_GR
        eval "$s"
      ' gate-src "$GATE" "$script"
}
watch_pass() {
  env -i HOME="$HOME_DIR" PATH="$PATH_FULL" TMPDIR="$DETAIL_TMP" \
      CC_CMDS_ATTENTION_ROOT="$ROOT" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      FLEET_PACE_ROOT="$WORK/pace" XDG_STATE_HOME="$WORK/state" "$@" \
      bash "$WATCH" --run-dir "$RUN_DIR_FX" --ledger "$LEDGER_FX" --once >/dev/null 2>&1
}
appr_files() { find "$ROOT/events" -type f -name "*.appr.$RID.$AID.json" 2>/dev/null; }
# A watcher pass can raise other banners of the run as well, so the approval's
# own file is read by its deterministic name.
appr_jq() { local f; f=$(appr_files | head -1); [ -n "$f" ] || { printf 'no-event'; return 0; }; jq -r "$1" "$f"; }

# The gate's own helper derives the canonical question from the sidecar.
spool
fixture_run
check "5 게이트의 정규 질문은 사이드카의 전체 문면" \
  "$(gate_src 'gate_approval_canon_question "$AID"')" "$CANON"
check "5 행이 없는 승인 id 는 빈 출력과 0" \
  "$(gate_src 'gate_approval_canon_question J-ffffffff; printf "rc=%s" "$?"')" "rc=0"

# The router seat's act approval: the event body is the canonical question and
# the local banner keeps the text with alias, cut and grade.
spool
fixture_run
: > "$NOTIFY_LOG"
gate_src 'gate_notify_approval "$AID" "$FULLQ — alias / 커밋 / 워크트리쓰기"' >/dev/null 2>&1
notify_settle 1
check "5 라우터 좌석의 승인 사건 하나" "$(appr_files | grep -c . || true)" "1"
check "5 승인 사건 본문은 정규 질문" "$(appr_jq .body)" "$CANON"
check "5 승인 사건은 답할 수 없음" "$(appr_jq .actionable)" "false"
check "5 로컬 배너 문면은 이전과 같다" \
  "$(grep -cF -- "-message $FULLQ — alias / 커밋 / 워크트리쓰기 -group cc-cmds-autopilot-$RID-$AID " "$NOTIFY_LOG" || true)" "1"
check "5 게이트 자리의 첨부 파일이 남지 않음" "$(n_leftover_detail)" "0"

spool
fixture_run
gate_src 'gate_notify_approval "$AID" "$FULLQ"' CC_PIPELINE_STAGE_ID='A#1' >/dev/null 2>&1
check "5 스테이지 좌석에서는 사건 0" "$(n_events)" "0"

spool
fixture_run
gate_src 'cc_notify_clear answer "$AID"' >/dev/null 2>&1
check "5 라우터 좌석의 승인 닫기는 approval-closed 표지" \
  "$(find "$ROOT/handled" -type f -name '*.json' 2>/dev/null | while IFS= read -r f; do jq -r '.slot + " " + .cause' "$f"; done)" \
  "cc-cmds-autopilot-$RID-$AID approval-closed"

# The watcher: a stage opened this judgment approval, so only the watcher's
# pass raises it, and its event carries the sidecar's full question.
spool
fixture_run
watch_pass
check "5 감시자의 승인 사건 하나" "$(appr_files | grep -c . || true)" "1"
check "5 감시자 사건 본문은 사이드카의 전체 질문" "$(appr_jq .body)" "$CANON"
check "5 감시자는 게이트의 진입 기록을 남기지 않음" "$([ -e "$RUN_DIR_FX/ledger-path" ] && echo written || echo none)" "none"
check "5 감시자 자리의 첨부 파일이 남지 않음" "$(n_leftover_detail)" "0"

# Both orders. The announcement list is cleared between the two drives so the
# second site raises its banner too — the race the gate accepts — and the
# deterministic id then has to keep the first event as it was.
for order in gate-watch watch-gate; do
  spool
  fixture_run
  : > "$NOTIFY_LOG"
  case "$order" in
    gate-watch) gate_src 'gate_notify_approval "$AID" "$FULLQ — alias / 커밋 / 워크트리쓰기"' >/dev/null 2>&1 ;;
    watch-gate) watch_pass ;;
  esac
  first=$(appr_files | head -1)
  cp "$first" "$WORK/first.json" 2>/dev/null || : > "$WORK/first.json"
  rm -f "$RUN_DIR_FX/watch.announced-approvals"
  case "$order" in
    gate-watch) watch_pass ;;
    watch-gate) gate_src 'gate_notify_approval "$AID" "$FULLQ — alias / 커밋 / 워크트리쓰기"' >/dev/null 2>&1 ;;
  esac
  notify_settle 2
  check "5 $order — 두 자리 모두 배너를 올렸다" "$(grep -c -- "-group cc-cmds-autopilot-$RID-$AID " "$NOTIFY_LOG" || true)" "2"
  check "5 $order — 승인 사건 파일은 하나" "$(appr_files | grep -c . || true)" "1"
  check "5 $order — 본문은 정규 질문" "$(appr_jq .body)" "$CANON"
  check "5 $order — 두 번째 구동 뒤 파일 바이트가 같다" \
    "$(cmp -s "$WORK/first.json" "$(appr_files | head -1)" && echo same || echo changed)" "same"
done
check "5 첨부 파일이 어느 길로든 남지 않음" "$(n_leftover_detail)" "0"

finish
