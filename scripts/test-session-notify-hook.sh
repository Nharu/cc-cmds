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

# THE STATE ROOT IS CONFINED TO THE WORK DIRECTORY. Both seats read the session
# title hook's current title file under it, so an unconfined run would pick up
# whatever title the session running this suite happens to have, and the
# title-line assertions would depend on who ran them.
STATE="$WORK/state"
NOW_DIR="$STATE/cc-cmds/session-title-now"
mkdir -p "$NOW_DIR"

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
  env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID \
      -u RUN_ID -u RUN_DIR \
      -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_AUTOPILOT_NOTIFY -u TMUX -u TMUX_PANE \
      PATH="$path" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
      CC_CMDS_NOTIFY_HOST_OS=Darwin \
      CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
      XDG_STATE_HOME="$STATE" \
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

# THE TWO SEATS READ DIFFERENT FIELDS, so a case that has to drive both cannot
# reuse one payload: seat 1 needs `tool_name` plus `tool_input.questions`, seat 2
# needs a marker on the last non-empty line of `last_assistant_message`. This
# builds the minimal payload that the named seat actually fires on, and adds
# `agent_id` when one is given. Without it the bodies of the both-seat loops
# below would be duplicated per seat — which is the very duplication those loops
# exist to catch.
payload_for() {
  local hook="$1" sid="$2" agent="${3:-}" extra=''
  if [ -n "$agent" ]; then extra=",\"agent_id\":\"$agent\""; fi
  if [ "$hook" = "$TURN_HOOK" ]; then
    pay "{\"session_id\":\"$sid\"$extra,\"last_assistant_message\":\"본문 한 줄.\\n**cc-cmds 차례 넘김**: 이유\"}"
  else
    pay "{\"session_id\":\"$sid\"$extra,\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"header\":\"머지\",\"question\":\"지금?\"}]}}"
  fi
}

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

# Zero questions still raises a banner: the session is waiting either way, and the
# body says only that much.
P=$(pay '{"session_id":"S-T0","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}')
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "0건 — 본문은 질문이 있다는 사실만 싣는다" \
  "$(grep -cF -- '-message 답을 기다리는 질문이 있습니다 ' "$NOTIFY_LOG" || true)" "1"
assert_quiet "0건"

# THE CLICK VALUE COMES FROM THE HOOK'S OWN ENVIRONMENT. `hook_run` clears TMUX
# and TMUX_PANE, so a case has a pane only when it passes one — the suite run
# from inside tmux would otherwise hand every case the pane it happens to run in.
FOCUS_HANDLER="$(cd "$PLUGIN_ROOT/orchestrator" && pwd -P)/notify-focus.sh"
for hk in "$ASK_HOOK" "$TURN_HOOK"; do
  hn=$(basename "$hk")
  P=$(payload_for "$hk" S-CLICK)
  hook_run "$hk" "$P" "$PATH_FULL" TMUX="/tmp/tmux-hk/default,4242,7" TMUX_PANE="%48"
  notify_settle 1
  check "클릭 값 ($hn) — tmux pane 안의 훅은 그 pane 의 focus 값을 단다" \
    "$(grep -cF -- "-execute /bin/bash '$FOCUS_HANDLER' focus '/tmp/tmux-hk/default' '4242' '%48'" "$NOTIFY_LOG" || true)" "1"
  assert_quiet "클릭 값 ($hn) tmux 안"
  hook_run "$hk" "$P" "$PATH_FULL"
  notify_settle 1
  check "클릭 값 ($hn) — tmux 밖의 훅은 -execute : 를 단다" \
    "$(grep -cE -- '-execute :$' "$NOTIFY_LOG" || true)" "1"
  assert_quiet "클릭 값 ($hn) tmux 밖"
done

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
# The firing gate — BOTH SEATS
#
# The gate is four predicates and it is COPIED into each hook rather than shared,
# so "seat 1 refuses this payload" says nothing at all about seat 2. Every case
# below therefore walks both seats and puts the seat name in the label, so a
# failure names the copy that lost the predicate rather than the predicate.
#
# These come after T20 and T10 on purpose: each seat's positive control has
# already asserted that a banner IS raised, so a no-banner verdict here is a
# refusal rather than a seat that fires nothing.
# ---------------------------------------------------------------------------

# T9 — a subagent payload. `agent_id` is present ONLY inside a subagent, and the
# gate reads that field rather than `agent_type` for the reason in the seat
# contract: `agent_type` is present on an `--agent` main thread too. Losing this
# in either copy means banners from subagents.
for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  seat=$(basename "$hook")
  P=$(payload_for "$hook" S-T9 AG-1)
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_quiet_window
  check "T9 agent_id 가 있으면 무발사 ($seat)" "$(notify_lines)" "0"
  check "T9 종료 코드 ($seat)" "$HOOK_RC" "0"
  assert_quiet "T9/$seat"
done

# Contract 6: an empty session id would put every session into one group string,
# and the prefix would still be right, so nothing downstream can catch it — the
# shipped `hooks/README.md` says outright that the hook is the only place it can
# be caught. This measures that the catcher is alive in BOTH copies.
for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  seat=$(basename "$hook")
  P=$(payload_for "$hook" "")
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_quiet_window
  check "세션 id 가 비면 무발사 (계약 6, $seat)" "$(notify_lines)" "0"
  check "세션 id 가 비면 종료 코드 0 (계약 6, $seat)" "$HOOK_RC" "0"
  assert_quiet "빈 세션 id/$seat"
done

# ---------------------------------------------------------------------------
# The switches, and the two fail-open paths
# ---------------------------------------------------------------------------

# T13 — the session kill switch. Every value in the off set, because a grammar
# that only honours `0` is a grammar that silently ignores what a user typed —
# and both seats, because the switch is read by a copy of the gate in each hook.
# The failure this catches is banners that keep coming at a user who turned them
# off.
#
# WHAT IT CANNOT SEE, IN EITHER SEAT, is which copy of the guard did the
# refusing. The hook's guard and the emitter's `cc_notify_scope_enabled` read the
# same variable, and the design puts the hook's in FRONT of the emitter's rather
# than in place of it — so deleting the hook line leaves the outcome identical:
# no banner, exit 0, no bytes. Measured on both seats, one line at a time: the
# whole suite stays green. Every other gate predicate has no such twin and does
# go red. Killing this mutant needs an observation this suite does not have — it
# reads argv, exit status and byte counts, and nothing else — so the limit is
# named here rather than left for a reader to infer from a passing case.
for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  seat=$(basename "$hook")
  for v in 0 off OFF false no; do
    P=$(payload_for "$hook" S-T13)
    hook_run "$hook" "$P" "$PATH_FULL" CC_CMDS_SESSION_NOTIFY="$v"
    notify_quiet_window
    check "T13 세션 킬스위치 '$v' — 무발사 ($seat)" "$(notify_lines)" "0"
    check "T13 세션 킬스위치 '$v' — 종료 코드 ($seat)" "$HOOK_RC" "0"
    assert_quiet "T13/$v/$seat"
  done
done

# `cc_caller_is_router` — the second conjunct of the firing gate, and until this
# case existed neither seat exercised it: `hook_run` unsets both pipeline
# variables on every run and nothing set them back, so the predicate was true in
# every single case above.
#
# THE VALUE IS SET AT THE CALL SITE RATHER THAN REMOVED FROM `hook_run`'s `env -u`
# LIST, and that is deliberate. This suite may itself be run from inside an
# unattended stage, where those variables are already exported; the `-u` list is
# what stops every negative assertion above from passing for the wrong reason
# there. This case layers a value on top of that floor and measures the opposite
# direction only. Dropping the two names from the `-u` list would look like a
# simplification and would take the floor away.
#
# The failure this catches is a run banner and a session banner landing on top of
# each other in an unattended stage session.
for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  seat=$(basename "$hook")
  P=$(payload_for "$hook" S-ROUTER)
  hook_run "$hook" "$P" "$PATH_FULL" CC_PIPELINE_SEGMENT=S1
  notify_quiet_window
  check "스테이지 세션(cc_caller_is_router 거짓) — 무발사 ($seat)" "$(notify_lines)" "0"
  check "스테이지 세션(cc_caller_is_router 거짓) — 종료 코드 ($seat)" "$HOOK_RC" "0"
  assert_quiet "cc_caller_is_router/$seat"
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
# The question form drives seat 1
#
# The form's mod raises its banner by running this same seat as a child process,
# with a PreToolUse-shaped stdin whose `tool_name` is the form's tool. The seat
# never reads `tool_name`, so the payload below is the mod's own shape rather
# than AskUserQuestion's with one field renamed — what is asserted is that the
# shape the mod sends fires, and that the gate still refuses it where it must.
# ---------------------------------------------------------------------------
QF_PAYLOAD='{"hook_event_name":"PreToolUse","session_id":"S-QF","tool_name":"mcp__cc-cmds__question_form","tool_input":{"questions":[{"header":"범위","question":"어디까지?"},{"header":"순서","question":"무엇부터?"}]}}'
P=$(pay "$QF_PAYLOAD")
hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
notify_settle 1
check "질문지 — 대역이 한 번 불린다 (양성 대조군)" "$(notify_lines)" "1"
check "질문지 — 본문이 건수와 header 들이다" \
  "$(grep -cF -- '-message 질문 2건 — 범위 · 순서 ' "$NOTIFY_LOG" || true)" "1"
check "질문지 — 그룹이 세션 슬롯이다" \
  "$(grep -cF -- '-group cc-cmds-session-S-QF ' "$NOTIFY_LOG" || true)" "1"
check "질문지 — 종료 코드" "$HOOK_RC" "0"
assert_quiet "질문지"

P=$(pay "$QF_PAYLOAD")
hook_run "$ASK_HOOK" "$P" "$PATH_FULL" CC_PIPELINE_SEGMENT=S1
notify_quiet_window
check "질문지 — 파이프라인 표지가 있으면 무발사" "$(notify_lines)" "0"
assert_quiet "질문지/표지"

P=$(pay "$QF_PAYLOAD")
hook_run "$ASK_HOOK" "$P" "$PATH_FULL" CC_CMDS_SESSION_NOTIFY=0
notify_quiet_window
check "질문지 — 세션 배너가 꺼져 있으면 무발사" "$(notify_lines)" "0"
assert_quiet "질문지/꺼짐"

# ---------------------------------------------------------------------------
# The session title in the title line
#
# The value comes only from the current title file the session title hook
# writes. Every case above ran with no such file under the confined state root,
# so their title assertions are the "no file, today's wording" cases; the cases
# below put a file in place and read the title line back.
# ---------------------------------------------------------------------------

# now_file <sid> <line 1> <line 2> [nonl] — the hook writes both lines with a
# newline; `nonl` leaves the second one without, the shape a reader must accept.
now_file() {
  if [ "${4:-}" = nonl ]; then
    printf '%s\n%s' "$2" "$3" > "$NOW_DIR/$1"
  else
    printf '%s\n%s\n' "$2" "$3" > "$NOW_DIR/$1"
  fi
}
NOW_SCHEMA='cc-session-title-now v1'

for hook in "$ASK_HOOK" "$TURN_HOOK"; do
  seat=$(basename "$hook")
  if [ "$hook" = "$ASK_HOOK" ]; then action='답하세요'; else action='차례가 넘어왔습니다'; fi

  now_file S-TT "$NOW_SCHEMA" 'review·#1085'
  P=$(payload_for "$hook" S-TT)
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 파일이 있으면 제목 줄에 실린다 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · review·#1085 · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목/$seat"

  # Over 30 columns: the banner carries the 24-column cut, never the whole title.
  now_file S-TT "$NOW_SCHEMA" '세션제목이아주길어서삼십칸을넘는다'
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 30칸 넘는 제목은 24칸으로 잘려 실린다 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · 세션제목이아주길어서삼십 · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 30칸 초과/$seat"

  # Switching the title hook off stops it writing; it does not hide a file it
  # wrote before, because neither the seat nor the emitter reads that switch.
  now_file S-TT "$NOW_SCHEMA" 'review·#1085'
  hook_run "$hook" "$P" "$PATH_FULL" CC_CMDS_SESSION_TITLE=0
  notify_settle 1
  check "세션 제목 — 제목 스위치가 꺼져도 파일이 있으면 실린다 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · review·#1085 · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 스위치 끔/$seat"

  now_file S-TT 'cc-session-title-now v2' 'review·#1085'
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 스키마 줄이 다르면 지금 문구 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 스키마 불일치/$seat"

  now_file S-TT "$NOW_SCHEMA" ''
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 2행이 비면 지금 문구 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 빈 2행/$seat"

  now_file S-TT "$NOW_SCHEMA" 'review·#1085' nonl
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 2행이 개행 없이 끝나도 실린다 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · review·#1085 · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 개행 없음/$seat"

  # An id with a dot passes the seat's own empty-id gate but not the shape the
  # hook writes under. The file is there, so only the id check can refuse it.
  now_file S.DOT "$NOW_SCHEMA" 'review·#1085'
  P=$(payload_for "$hook" S.DOT)
  hook_run "$hook" "$P" "$PATH_FULL"
  notify_settle 1
  check "세션 제목 — 점을 품은 id 는 지금 문구 ($seat)" \
    "$(grep -cF -- "-title cc-cmds · $action " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "세션 제목 점 id/$seat"
done
rm -f "$NOW_DIR/S-TT" "$NOW_DIR/S.DOT"

# The fixed results of the 24-column cut, read back from the seat's title line:
# twelve Hangul syllables, a mixed title whose cut lands mid-word, and a cut that
# would end on `·` and loses it. The title sits between two ` · ` separators, so
# an exact line also says the cut kept no trailing space or `·`.
for pair in \
  '가나다라마바사아자차카타파하|가나다라마바사아자차카타' \
  'review·가나다라마바사아자차|review·가나다라마바사아' \
  'implement·abcdefghijklm·x|implement·abcdefghijklm'; do
  src="${pair%%|*}"; want="${pair#*|}"
  now_file S-CUT "$NOW_SCHEMA" "$src"
  P=$(payload_for "$ASK_HOOK" S-CUT)
  hook_run "$ASK_HOOK" "$P" "$PATH_FULL"
  notify_settle 1
  check "24칸 자르기 — $src" \
    "$(grep -cF -- "-title cc-cmds · $want · 답하세요 " "$NOTIFY_LOG" || true)" "1"
  assert_quiet "24칸 자르기/$src"
done
rm -f "$NOW_DIR/S-CUT"

# With neither HOME nor XDG_STATE_HOME the reader falls back to today's title
# under `set -u` without a byte on stderr — the question form hands the seat
# `CLAUDE_PLUGIN_ROOT` only. `hook_run` always sets the state root, so this
# case builds its own environment.
P=$(payload_for "$ASK_HOOK" S-NOHOME)
: > "$NOTIFY_LOG"; : > "$ERR"; : > "$OUTF"
env -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID \
    -u RUN_ID -u RUN_DIR -u HOME -u XDG_STATE_HOME \
    -u CC_CMDS_SESSION_NOTIFY -u CC_CMDS_AUTOPILOT_NOTIFY -u TMUX -u TMUX_PANE \
    PATH="$PATH_FULL" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 \
    CC_CMDS_NOTIFY_HOST_OS=Darwin \
    CC_TEST_NOTIFY_LOG="$NOTIFY_LOG" \
    bash "$ASK_HOOK" < "$P" > "$OUTF" 2> "$ERR"
check "상태 뿌리가 없으면 — 종료 코드 0" "$?" "0"
notify_settle 1
check "상태 뿌리가 없으면 — 지금 문구로 발사한다" \
  "$(grep -cF -- '-title cc-cmds · 답하세요 ' "$NOTIFY_LOG" || true)" "1"
check "상태 뿌리가 없어도 stdout·stderr 0바이트" \
  "$(wc -c < "$OUTF" | tr -d ' ')/$(wc -c < "$ERR" | tr -d ' ')" "0/0"

# THE TWO jq COPIES MUST NOT DRIFT. The hook and the emitter each carry `cw` and
# `cut` as one line starting at column 0; each file must yield exactly one line
# of each, and the two files' lines must be the same bytes. This suite runs in
# the Linux CI too, so the emitter's jq is measured there as well.
TITLE_HOOK="$PLUGIN_ROOT/hooks/session-title.sh"
ORCH_DIR="$PLUGIN_ROOT/orchestrator"
for def in '^def cw:' '^def cut\('; do
  n_hook=$(grep -cE -- "$def" "$TITLE_HOOK" || true)
  n_emit=$(grep -cE -- "$def" "$ORCH_DIR/notify-run.sh" || true)
  check "jq 사본 — session-title.sh 의 '$def' 줄이 정확히 하나" "$n_hook" "1"
  check "jq 사본 — notify-run.sh 의 '$def' 줄이 정확히 하나" "$n_emit" "1"
  if [ "$(grep -E -- "$def" "$TITLE_HOOK" || true)" = "$(grep -E -- "$def" "$ORCH_DIR/notify-run.sh" || true)" ]; then
    ok "jq 사본 — '$def' 줄이 두 파일에서 바이트로 같다"
  else
    bad "jq 사본 — '$def'" "session-title.sh 와 notify-run.sh 의 정의가 갈라졌다"
  fi
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
