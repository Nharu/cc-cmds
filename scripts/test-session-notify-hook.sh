#!/usr/bin/env bash
# Test the two general-session banner hooks —
# plugins/cc-cmds/hooks/session-ask-notify.sh and session-turn-notify.sh.
#
# WHAT THIS SUITE CAN AND CANNOT SEE. It drives each hook the way the harness
# does — a JSON payload on stdin — and reads three things back: the argv the
# notifier was called with, the exit status, and the byte counts of stdout and
# stderr. It cannot see whether anything appeared on a screen, and no assertion
# here pretends to.
#
# THE NOTIFIER IS INTERCEPTED ON PATH, and both prepend seams are pinned so
# neither the real binary nor the host check can put an assertion out of reach.
# The hook prepends the Homebrew directories itself, so without the seam a stub
# placed first on PATH is shadowed by whatever is really installed.
#
# THE PIPELINE VARIABLES ARE UNSET FOR EVERY RUN. This suite may itself be run
# from inside an unattended stage, where `CC_PIPELINE_SEGMENT` is exported — and
# in that environment `cc_caller_is_router` is false, so every hook would exit
# early and every negative assertion below would pass for the wrong reason. That
# is a green that cannot go red, which is worse than a red.
#
# THE POSITIVE CONTROL IS NOT OPTIONAL. A suite that only measures suppression is
# green against a hook that fires nothing at all, so each seat has a case that
# asserts a banner IS raised before any case asserts one is not.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
PLUGIN_ROOT="$repo_root/plugins/cc-cmds"
ASK_HOOK="$PLUGIN_ROOT/hooks/session-ask-notify.sh"
TURN_HOOK="$PLUGIN_ROOT/hooks/session-turn-notify.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

for f in "$ASK_HOOK" "$TURN_HOOK"; do
  if [ ! -f "$f" ]; then
    bad "훅 스크립트" "$f 가 없다"
    printf 'test-session-notify-hook: %s passed, %s failed\n' "$passed" "$failed"
    exit 1
  fi
done

JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: jq not installed — both seats parse JSON and nothing can be driven without it"
  echo "test-session-notify-hook: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-session-hook.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Three PATH roots, each missing exactly one thing, so the two fail-open claims
# are driven by absence rather than by a flag that only pretends to remove it.
BIN="$WORK/bin"                  # notifier stub + jq
BIN_NO_NOTIFIER="$WORK/bin-nn"   # jq only
BIN_NO_JQ="$WORK/bin-nj"         # notifier stub only
mkdir -p "$BIN" "$BIN_NO_NOTIFIER" "$BIN_NO_JQ"

cat > "$BIN/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_NOTIFY_LOG"
STUB
chmod +x "$BIN/terminal-notifier"
cp "$BIN/terminal-notifier" "$BIN_NO_JQ/terminal-notifier"
ln -s "$JQ" "$BIN/jq"
ln -s "$JQ" "$BIN_NO_NOTIFIER/jq"

# REMOVING `jq` CANNOT BE DONE BY PUTTING A DIRECTORY IN FRONT. Measured on this
# host: `jq` is installed at `/usr/bin/jq`, so a PATH of `<root>:/usr/bin:/bin`
# still finds it and the hook sails past the guard the case exists to exercise —
# the case then reports a banner where it expected none, which is how this was
# caught rather than passing quietly. The no-jq root is therefore the WHOLE PATH.
# It holds `bash` (which `env` resolves through the new PATH, so the hook could
# not start without it) and the notifier stub — the stub is deliberately present
# so that a hook which DID get past the guard would have something to call and
# the assertion would see the banner.
BASH_BIN=$(command -v bash 2>/dev/null || true)
if [ -z "$BASH_BIN" ]; then
  bad "시험 환경" "PATH 에서 bash 를 찾지 못했다 — jq 부재 경로를 만들 수 없다"
  printf 'test-session-notify-hook: %s passed, %s failed\n' "$passed" "$failed"
  exit 1
fi
ln -s "$BASH_BIN" "$BIN_NO_JQ/bash"

PATH_FULL="$BIN:/usr/bin:/bin"
PATH_NO_NOTIFIER="$BIN_NO_NOTIFIER:/usr/bin:/bin"
PATH_NO_JQ="$BIN_NO_JQ"

NOTIFY_LOG="$WORK/notifier.log"
ERR="$WORK/hook.err"
OUTF="$WORK/hook.out"

# The emitter launches the notifier detached and never asks its status, so a
# write can land after the hook process has already exited. Bounded wait for the
# positive cases, boolean assertion — never a comparison of elapsed seconds.
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
# A negative case cannot wait for a value that never arrives, so it waits a fixed
# window instead. The window is the same order as the settle above, so a banner
# this suite calls absent had at least as long to appear as one it calls present.
notify_quiet_window() { sleep 0.5; }
notify_lines() { grep -c . "$NOTIFY_LOG" 2>/dev/null || true; }

# HOOK_RC / HOOK_OUT_BYTES / HOOK_ERR_BYTES are what every case reads.
hook_run() {
  local hook="$1" payload="$2" path="$3"; shift 3
  : > "$NOTIFY_LOG"; : > "$ERR"; : > "$OUTF"
  env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u RUN_ID -u RUN_DIR \
      -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_AUTOPILOT_NOTIFY \
      PATH="$path" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin \
      CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      "$@" \
      bash "$hook" < "$payload" > "$OUTF" 2> "$ERR"
  HOOK_RC=$?
  HOOK_OUT_BYTES=$(wc -c < "$OUTF" | tr -d ' ')
  HOOK_ERR_BYTES=$(wc -c < "$ERR" | tr -d ' ')
}

# T15 is not one case, it is the same pair of assertions after every case. Held
# as a running tally so a single scenario cannot be the only one measured.
quiet_violations=0
quiet_checked=0
assert_quiet() {
  quiet_checked=$((quiet_checked + 1))
  if [ "$HOOK_OUT_BYTES" != "0" ] || [ "$HOOK_ERR_BYTES" != "0" ]; then
    quiet_violations=$((quiet_violations + 1))
    printf 'FAIL: T15 — %s 에서 stdout=%s bytes stderr=%s bytes\n' \
      "$1" "$HOOK_OUT_BYTES" "$HOOK_ERR_BYTES" >&2
    printf '       stderr: %s\n' "$(tr '\n' ' ' < "$ERR")" >&2
  fi
}

pay() { printf '%s' "$1" > "$WORK/payload.json"; printf '%s' "$WORK/payload.json"; }

# ---------------------------------------------------------------------------
# Seat 1 — PreToolUse / AskUserQuestion
# ---------------------------------------------------------------------------

# T20 first: the positive control comes before every negative one.
P=$(pay '{"session_id":"S-T20","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금 머지할까요?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "T20 일반 세션 페이로드 — 발사한다 (양성 대조군)" "$(notify_lines)" "1"
check "T20 종료 코드" "$HOOK_RC" "0"
assert_quiet "T20"

# T8 reads the argv the positive control raised: title, body and the session slot.
check "T8 1건 — 제목" \
  "$(grep -cF -- '-title cc-cmds · 답하세요 ' "$NOTIFY_LOG" || true)" "1"
check "T8 1건 — 본문이 <header> — <question>" \
  "$(grep -cF -- '-message 머지 — 지금 머지할까요? ' "$NOTIFY_LOG" || true)" "1"
check "T8 1건 — 그룹이 세션 슬롯이다" \
  "$(grep -cF -- '-group cc-cmds-session-S-T20 ' "$NOTIFY_LOG" || true)" "1"
check "T8 1건 — 오토파일럿 슬롯으로 함몰하지 않았다" \
  "$(grep -cF -- '-group cc-cmds-autopilot-' "$NOTIFY_LOG" || true)" "0"

# T19 — three questions. The count and the headers travel; the first question's
# text does not, and that absence is the assertion, because a build that carries
# only the first question passes any check that merely looks for "some question
# text in the argv".
P=$(pay '{"session_id":"S-T19","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"이것은 첫 질문의 본문이며 세 건일 때는 배너에 실리지 않아야 한다"},{"header":"판올림","question":"두 번째"},{"header":"배포","question":"세 번째"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "T19 3건 — 건수와 header 들을 싣는다" \
  "$(grep -cF -- '-message 질문 3건 — 머지 · 판올림 · 배포 ' "$NOTIFY_LOG" || true)" "1"
check "T19 3건 — 첫 건의 question 이 본문에 없다" \
  "$(grep -cF -- '이것은 첫 질문의 본문이며' "$NOTIFY_LOG" || true)" "0"
assert_quiet "T19"

# T9 — a subagent payload. `agent_id` is present ONLY inside a subagent, and the
# gate reads that field rather than `agent_type` for the reason in the seat
# contract: `agent_type` is present on an `--agent` main thread too.
P=$(pay '{"session_id":"S-T9","agent_id":"AG-1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_quiet_window
check "T9 agent_id 가 있으면 무발사" "$(notify_lines)" "0"
check "T9 종료 코드" "$HOOK_RC" "0"
assert_quiet "T9"

# Seat 6 of the contract: an empty session id would put every session into one
# group string, and the prefix would still be right, so nothing downstream can
# catch it.
P=$(pay '{"session_id":"","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_quiet_window
check "세션 id 가 비면 무발사 (계약 6)" "$(notify_lines)" "0"
assert_quiet "빈 세션 id"

# Zero questions still raises a banner: the session is waiting either way, and the
# body says only that much.
P=$(pay '{"session_id":"S-T0","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "0건 — 본문은 질문이 있다는 사실만 싣는다" \
  "$(grep -cF -- '-message 답을 기다리는 질문이 있습니다 ' "$NOTIFY_LOG" || true)" "1"
assert_quiet "0건"

# ---------------------------------------------------------------------------
# Seat 2 — Stop / marker
# ---------------------------------------------------------------------------

# T10, positive control for this seat, in the shape that is easiest to implement
# wrongly: the marker is followed by blank lines. Anchoring on the LITERAL last
# line instead of the last NON-EMPTY one loses this case, and loses it silently.
P=$(pay '{"session_id":"S-T10","last_assistant_message":"본문 한 줄.\n\n**cc-cmds 차례 넘김**: 자격 입력이 필요합니다\n\n\n"}')
hook_run "$TURN_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "T10 마커 뒤에 빈 줄이 여럿이어도 발사한다 (양성 대조군)" "$(notify_lines)" "1"
check "T10 제목" \
  "$(grep -cF -- '-title cc-cmds · 차례가 넘어왔습니다 ' "$NOTIFY_LOG" || true)" "1"
check "T10 본문은 마커 뒤 한 줄 이유다" \
  "$(grep -cF -- '-message 자격 입력이 필요합니다 ' "$NOTIFY_LOG" || true)" "1"
check "T10 그룹이 세션 슬롯이다" \
  "$(grep -cF -- '-group cc-cmds-session-S-T10 ' "$NOTIFY_LOG" || true)" "1"
check "T10 종료 코드" "$HOOK_RC" "0"
assert_quiet "T10"

# T11 — the six false positives. Every one of them is refused by the SAME rule
# (anchor at the start of the last non-empty line) rather than by six rules, so
# the point of enumerating them is to show the rule covers all six.
t11_case() {
  local label="$1" msg="$2"
  P=$(pay "{\"session_id\":\"S-T11\",\"last_assistant_message\":\"$msg\"}")
  hook_run "$TURN_HOOK" "$P" "$PATH_FULL"
  notify_quiet_window
  check "T11 오탐 — $label" "$(notify_lines)" "0"
  assert_quiet "T11/$label"
}
t11_case "마커 없음"        '평범하게 끝난 턴입니다.'
t11_case "인용 안"          '본문\n> **cc-cmds 차례 넘김**: 인용된 마커'
t11_case "불릿 안"          '본문\n- **cc-cmds 차례 넘김**: 불릿의 마커'
t11_case "들여쓰기"         '본문\n  **cc-cmds 차례 넘김**: 들여쓴 마커'
t11_case "코드펜스 안"      '본문\n```\n**cc-cmds 차례 넘김**: 펜스 안의 마커\n```'
t11_case "줄 중간에 혼입"   '본문\n앞말이 붙었다 **cc-cmds 차례 넘김**: 줄 중간'

# T12 — the field is `.optional()` in the payload schema, so its absence is a
# normal path and it reads as "no marker". It is NOT a reason to go looking in
# the transcript; that is the one change that would break the source invariant.
P=$(pay '{"session_id":"S-T12"}')
hook_run "$TURN_HOOK" "$P" "$PATH_FULL"
notify_quiet_window
check "T12 last_assistant_message 키 부재 — 무발사" "$(notify_lines)" "0"
check "T12 종료 코드" "$HOOK_RC" "0"
assert_quiet "T12"

# ---------------------------------------------------------------------------
# The switches, and the two fail-open paths
# ---------------------------------------------------------------------------

# T13 — the session kill switch. Every value in the off set, because a grammar
# that only honours `0` is a grammar that silently ignores what a user typed.
for v in 0 off OFF false no; do
  P=$(pay '{"session_id":"S-T13","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
  hook_run "$ASK_HOOK" "$P" "$PATH_FULL" CC_CMDS_SESSION_NOTIFY="$v"
  notify_quiet_window
  check "T13 세션 킬스위치 '$v' — 무발사" "$(notify_lines)" "0"
  check "T13 세션 킬스위치 '$v' — 종료 코드" "$HOOK_RC" "0"
  assert_quiet "T13/$v"
done

# The unrecognized value reads as ON, deliberately and without a warning — see
# the seat contract. The cost is that a typo leaves the banners on; the opposite
# polarity would make a typo remove them, silently.
P=$(pay '{"session_id":"S-T13b","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL" CC_CMDS_SESSION_NOTIFY=flase
notify_settle 1
check "인식 못 한 세션 스위치 값은 켜짐으로 읽는다" "$(notify_lines)" "1"
assert_quiet "세션 스위치 오타값"

# T23 — a typo in the AUTOPILOT switch must not put a byte on this hook's stderr.
# Before the scope dispatcher existed the session path reached
# `cc_notify_warn_unrecognized`, whose once-guard marker lives under the run
# directory and therefore never takes hold for a session: the warning came out on
# every single firing, measured at 145 bytes.
P=$(pay '{"session_id":"S-T23","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL" CC_CMDS_AUTOPILOT_NOTIFY=flase
notify_settle 1
check "T23 오토파일럿 스위치 오타값 — 세션은 그대로 발사한다" "$(notify_lines)" "1"
check "T23 오토파일럿 스위치 오타값 — stderr 0바이트" "$HOOK_ERR_BYTES" "0"
assert_quiet "T23"

# T14 — the notifier is simply not installed. Fail open, exit 0, say nothing.
P=$(pay '{"session_id":"S-T14","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_NO_NOTIFIER"
check "T14 terminal-notifier 부재 — 종료 코드 0 (fail-open)" "$HOOK_RC" "0"
assert_quiet "T14"

# T24 — `jq` is not on PATH. Without the guard the shell writes
# `command not found` to stderr, which breaks contract 3 for a user who switched
# nothing off; and because a test host almost always HAS jq, nothing else in this
# suite would ever notice.
for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  P=$(pay '{"session_id":"S-T24","last_assistant_message":"본문\n**cc-cmds 차례 넘김**: 이유","tool_input":{"questions":[{"header":"머지","question":"지금?"}]}}')
  hook_run "$hook" "$P" "$PATH_NO_JQ"
  notify_quiet_window
  check "T24 jq 부재 ($(basename "$hook")) — 무발사" "$(notify_lines)" "0"
  check "T24 jq 부재 ($(basename "$hook")) — 종료 코드 0" "$HOOK_RC" "0"
  assert_quiet "T24/$(basename "$hook")"
done

# ---------------------------------------------------------------------------
# T15 — the running tally
# ---------------------------------------------------------------------------
if [ "$quiet_violations" = "0" ]; then
  ok "T15 모든 시나리오(${quiet_checked}건)에서 stdout·stderr 가 0바이트다"
else
  bad "T15 stdout·stderr" "${quiet_violations}/${quiet_checked} 시나리오가 바이트를 냈다"
fi

printf 'test-session-notify-hook: %s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" != "0" ]; then exit 1; fi
exit 0
