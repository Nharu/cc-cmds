#!/usr/bin/env bash
# lint-bash-portability: self-skip
# Test the run's layer-1 PreToolUse hook by feeding it the JSON the harness
# feeds it and asserting the decision it emits.
#
# The hook is driven directly rather than through a live CLI session for one
# reason: the branches that matter are the ones a live session almost never
# reaches — a missing `jq`, an install with no run directory, a write aimed at
# the settings file that decides whether the hook runs at all. A test that only
# exercised the happy path would pass on a hook that fails open everywhere else,
# and failing open is the entire failure mode.
#
# Two assertions here are about NOT inheriting the sibling hook's shape:
#   - `jq` missing must DENY. The sibling exits 0 and defers to the default
#     permission gate; under `--dangerously-skip-permissions` there is no
#     default gate, so the same line allows everything.
#   - no `applyPermissionRules` anywhere. It makes an allow session-persistent,
#     which turns a per-act gate into a once-per-session gate.
#
# Usage: bash scripts/test-orchestrator-pretool-hook.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/gate-pretool.sh"
GATE="$repo_root/plugins/cc-cmds/orchestrator/gate.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-hook-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RUN_DIR="$WORK/run"; mkdir -p "$RUN_DIR/settings"
LEDGER="$WORK/ledger.md"; GRANT="$WORK/grant.md"; MANIFEST="$WORK/plan.md"
: > "$LEDGER"; : > "$GRANT"; : > "$MANIFEST"

# `grep -q` on the right of a pipe exits as soon as it matches, which kills the
# writer with SIGPIPE — and under `pipefail` the whole pipeline then reports
# failure even though the match was found. GNU sed makes it loud ("couldn't
# flush stdout: Broken pipe") and BSD sed usually does not, so this failed only
# on the Linux leg and only once a scanned function grew long enough for the
# race to be real.
#
# `grep -c` has the same truth value and consumes its input to the end, so the
# writer never sees a closed pipe. The count goes to /dev/null; only the exit
# status is wanted.
grep_all_q() {
  # The count is CAPTURED, not redirected to /dev/null: BSD grep short-circuits
  # when its output is being discarded, which reintroduces the very SIGPIPE this
  # helper exists to avoid. Measured — `sed … | grep -c … >/dev/null` returns
  # 141 while `n=$(grep -c …)` returns 0.
  local n
  n=$(grep -c "$@" || true)
  [ "${n:-0}" != "0" ]
}

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

# `decide` runs the hook with the standard arguments and leaves the decision in
# `dec` and the whole object in `out`.
dec=""; out=""
decide() {
  out=$(printf '%s' "$1" | bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE" \
          --ledger "$LEDGER" --grant "$GRANT" --manifest "$MANIFEST" 2>/dev/null)
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
}
bash_json()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }
write_json() { printf '{"tool_name":"Write","tool_input":{"file_path":%s}}' "$(jq -Rn --arg p "$1" '$p')"; }

# ---------------------------------------------------------------------------
# 1. The hook is well-formed at all
# ---------------------------------------------------------------------------
if bash -n "$HOOK" 2>/dev/null; then ok "훅이 파싱된다"; else bad "훅 파싱" "bash -n 실패"; fi

decide "$(bash_json 'ls -la')"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  ok "훅 출력이 유효한 JSON 이다"
else
  bad "훅 출력" "JSON 이 아니다: $out"
fi

# ---------------------------------------------------------------------------
# 2. Default deny, and the denial is an escalation
# ---------------------------------------------------------------------------
check "평범한 배시는 기본 거부된다" "$dec" "deny"

reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *"$GATE exec"*) ok "거부 문면이 게이트의 exec 동사로 유도한다" ;;
  *) bad "에스컬레이션 문면" "'$reason'" ;;
esac
case "$reason" in
  *"ls -la"*) ok "거부 문면이 원래 명령을 그대로 되돌려 준다" ;;
  *) bad "명령 인용" "'$reason'" ;;
esac

# The evasions a deny-list falls to, and an allow-list does not.
for evasion in \
    'echo "gh pr merge 1" > /tmp/x.sh && bash /tmp/x.sh' \
    'env FOO=1 gh pr merge 1' \
    'git -c core.editor=true commit -m x' \
    'bash -c "gh pr merge 1"' \
    'eval "$(printf %s "gh pr merge 1")"'; do
  decide "$(bash_json "$evasion")"
  check "거부 목록이라면 뚫렸을 형태도 거부된다: ${evasion:0:28}…" "$dec" "deny"
done

# A newline-carrying command must still produce parseable JSON — a heredoc is
# the ordinary case, and a raw newline inside a JSON string is a parse error the
# harness reads as a broken hook rather than as a denial.
decide "$(bash_json 'cat <<EOT
line one
line two
EOT')"
check "여러 줄 명령도 거부로 답한다" "$dec" "deny"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  ok "여러 줄 명령에서도 출력이 유효한 JSON 이다"
else
  bad "개행 처리" "JSON 이 깨졌다"
fi

# ---------------------------------------------------------------------------
# 3. The allow-list is one shape, anchored
# ---------------------------------------------------------------------------
decide "$(bash_json "$GATE exec --manifest /m.md -- ls")"
check "게이트 호출은 허용된다" "$dec" "allow"

decide "$(bash_json "bash $GATE snapshot --manifest /m.md")"
check "bash 접두가 붙은 게이트 호출도 허용된다" "$dec" "allow"

decide "$(bash_json "bash '$GATE' snapshot --manifest /m.md")"
check "따옴표로 감싼 경로도 같은 호출로 인정된다" "$dec" "allow"

decide "$(bash_json "ls -la ; $GATE exec --manifest /m.md -- ls")"
check "게이트 호출을 뒤에 붙이는 형태는 허용되지 않는다" "$dec" "deny"

decide "$(bash_json "gate.sh exec --manifest /m.md -- ls")"
check "같은 이름의 다른 게이트는 허용되지 않는다 (절대 경로로만 인정)" "$dec" "deny"

# ---------------------------------------------------------------------------
# 4. Enforcement surfaces — Write and Edit
# ---------------------------------------------------------------------------
decide "$(write_json "$RUN_DIR/settings/implement.json")"
check "런 설정 파일 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "$LEDGER")"
check "원장 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "$GRANT")"
check "인가 기록 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "/some/repo/.claude/settings.json")"
check "프로젝트 스코프 설정 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "/some/repo/.claude/settings.local.json")"
check "프로젝트 스코프 로컬 설정 쓰기도 거부된다" "$dec" "deny"

decide "$(write_json "$HOME/.claude/projects/abc/session.jsonl")"
check "세션 트랜스크립트 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "$repo_root/plugins/cc-cmds/orchestrator/rules/절단점-준수.sh")"
check "룰 카탈로그 쓰기는 거부된다" "$dec" "deny"

decide "$(write_json "$HOOK")"
check "훅 스크립트 자신에 대한 쓰기는 거부된다" "$dec" "deny"

# The user-scope config directory is relocatable, and the literal `.claude`
# globs stop matching when it moves. The protection was present on a default
# install and absent on a relocated one, which is the shape that survives review.
cfgdir="$WORK/.claude-cc"
decide_cfg() {
  out=$(printf '%s' "$1" | CLAUDE_CONFIG_DIR="$cfgdir" bash "$HOOK" --run-dir "$RUN_DIR" \
          --gate "$GATE" --ledger "$LEDGER" --grant "$GRANT" 2>/dev/null)
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
}

decide_cfg "$(write_json "$cfgdir/settings.json")"
check "재배치된 사용자 스코프 설정 쓰기도 거부된다" "$dec" "deny"

decide_cfg "$(write_json "$cfgdir/settings.local.json")"
check "재배치된 사용자 스코프 로컬 설정 쓰기도 거부된다" "$dec" "deny"

decide_cfg "$(write_json "$cfgdir/projects/abc/session.jsonl")"
check "재배치된 트랜스크립트 쓰기도 거부된다" "$dec" "deny"

# Not vacuous: the arms are anchored at the resolved directory, so a sibling
# whose name merely starts with it stays writable.
decide_cfg "$(write_json "${cfgdir}-other/settings.json")"
check "이름이 접두로만 겹치는 이웃 디렉터리는 여전히 허용된다" "$dec" "allow"

# And relocating must not remove the default coverage: with the variable set to
# somewhere else, a project-scope `.claude` is still refused.
decide_cfg "$(write_json "/some/repo/.claude/settings.json")"
check "재배치 상태에서도 프로젝트 스코프 설정은 거부된다" "$dec" "deny"

# The denial set must not be vacuous in the other direction: this pipeline's job
# is editing repositories, so an ordinary source file has to stay writable.
decide "$(write_json "/some/repo/src/main.ts")"
check "평범한 소스 파일 쓰기는 허용된다" "$dec" "allow"

decide "$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$LEDGER")"
check "Bash 도 편집도 아닌 도구는 대상이 아니다" "$dec" "allow"

# ---------------------------------------------------------------------------
# 5. Fail-closed where the sibling hook fails open
# ---------------------------------------------------------------------------
mkdir -p "$WORK/emptybin"
# Fed from a FILE, not a pipe. These two branches deny BEFORE reading stdin, so
# a writing pipe meets a closed reader and reports a write error — which is the
# same early-exit shape this suite refuses elsewhere.
bash_json 'ls' > "$WORK/in.json"
out=$(PATH="$WORK/emptybin" CC_CMDS_GATE_PATH_DISABLE_PREPEND=1 \
        /bin/bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE" < "$WORK/in.json" 2>/dev/null)
dec=$(printf '%s' "$out" | grep -o '"permissionDecision":"[a-z]*"' | sed 's/.*:"//;s/"//')
check "jq 가 없으면 허용이 아니라 거부다" "$dec" "deny"

out=$(bash "$HOOK" --gate "$GATE" < "$WORK/in.json" 2>/dev/null)
dec=$(printf '%s' "$out" | grep -o '"permissionDecision":"[a-z]*"' | sed 's/.*:"//;s/"//')
check "런 디렉터리 없이 설치되면 아무것도 인가하지 않는다" "$dec" "deny"

out=$(printf '' | bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE" 2>/dev/null)
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
check "빈 입력도 거부로 답한다" "$dec" "deny"

# ---------------------------------------------------------------------------
# 6. The two precedents that are NOT inherited
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$HOOK" | grep_all_q 'applyPermissionRules'; then
  bad "세션 지속 허용" "applyPermissionRules 가 있다 — 한 번의 허용이 세션 내내 게이트를 우회시킨다"
else
  ok "applyPermissionRules 를 쓰지 않는다 (판정은 물어본 그 호출에 한정된다)"
fi

if grep -vE '^[[:space:]]*#' "$HOOK" | grep_all_q -E 'command -v jq[^|]*\|\|[[:space:]]*exit 0'; then
  bad "조용한 fail-open" "jq 부재를 exit 0 으로 넘긴다"
else
  ok "jq 부재를 조용히 넘기지 않는다"
fi

# The hook must not be registered in the plugin's own hook file: that file loads
# for every session that loads the plugin, and a default-deny Bash hook in the
# user's interactive session is a catastrophe rather than a boundary.
if grep -q 'gate-pretool' "$repo_root/plugins/cc-cmds/hooks/hooks.json"; then
  bad "훅 등록 위치" "플러그인 hooks.json 에 등록됐다 — 사용자 대화형 세션까지 기본 거부가 걸린다"
else
  ok "플러그인 hooks.json 에 등록하지 않는다 (런 설정으로만 도달한다)"
fi

# ---------------------------------------------------------------------------
# 6b. The session banner seats' registration
#
# THE EVENT KEY IS ASSERTED, NOT JUST THE TIMEOUT. The two seats sit in
# structurally different places — seat 1 is a sibling element inside the existing
# `PreToolUse` array, seat 2 opens a top-level `Stop` key that did not exist —
# and putting the `Stop` element into the `PreToolUse` array instead is a SILENT
# failure: the harness passes it over on a matcher miss and seat 2 never runs.
# A check that only looks for `"timeout": 5` is green on exactly that mistake,
# and the resulting silence cannot be told apart from nobody marking a turn.
#
# This block lives beside the registration check above rather than in a suite of
# its own, because both are answering one question — what does this repo's
# hooks.json actually declare — and splitting it is how the next entry gets
# added without anything noticing.
# ---------------------------------------------------------------------------
HOOKS_JSON="$repo_root/plugins/cc-cmds/hooks/hooks.json"

check "T16 PreToolUse 에 AskUserQuestion 매처 항목이 정확히 하나 있다" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "AskUserQuestion")] | length' "$HOOKS_JSON")" "1"
check "T16 최상위에 Stop 키가 있다" \
  "$(jq -r 'if (.hooks | has("Stop")) then "yes" else "no" end' "$HOOKS_JSON")" "yes"
check "T16 Stop 배열에 항목이 정확히 하나 있다" \
  "$(jq -r '.hooks.Stop | length' "$HOOKS_JSON")" "1"
check "T16 두 세션 항목 모두 timeout 5 를 가진다" \
  "$(jq -r '[(.hooks.PreToolUse[]? | select(.matcher == "AskUserQuestion")), (.hooks.Stop[]?)] | [.[].hooks[].timeout] | map(select(. == 5)) | length' "$HOOKS_JSON")" "2"
# The negative form of the same claim: a matcher-less element inside PreToolUse
# is what a misplaced Stop entry looks like, and it is well-formed JSON.
check "T16 매처 없는 원소가 PreToolUse 배열에 들어가 있지 않다" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(has("matcher") | not)] | length' "$HOOKS_JSON")" "0"
check "T16 두 세션 훅의 스크립트가 각각 제 자리를 가리킨다" \
  "$(jq -r '[(.hooks.PreToolUse[]? | select(.matcher == "AskUserQuestion") | .hooks[].command | select(contains("session-ask-notify.sh"))), (.hooks.Stop[]?.hooks[].command | select(contains("session-turn-notify.sh")))] | length' "$HOOKS_JSON")" "2"

# T17 — the existing Bash entry is untouched. The matchers are deliberately NOT
# merged into `"Bash|AskUserQuestion"`: merging would turn the sibling hook's
# `non-Bash matcher slip → noop` line into a permanently active path instead of
# the defence it is. That decision is not observable from behaviour — both
# scripts drop a payload that is not theirs — so the assertion is structural.
check "T17 기존 Bash 항목이 그대로다" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[] | select(.command | contains("active-notify-pretool.sh"))] | length' "$HOOKS_JSON")" "1"
check "T17 Bash 매처가 다른 도구 이름과 합쳐지지 않았다" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher? // "" | test("\\|"))] | length' "$HOOKS_JSON")" "0"

# ---------------------------------------------------------------------------
# 7. The wrapper's hard stops — the other half of layer 1
#
# The hook only reaches a stage that was launched WITH the settings, so the
# wrapper's refusals are what make the hook's coverage non-optional. Every one
# of these is a hard stop rather than a warning, and the reason is the measured
# failure mode: a stage launched without settings runs ungated and reports
# success, so degrading here would re-introduce the exact bug under a nicer
# name.
# ---------------------------------------------------------------------------
WRAP="$repo_root/plugins/cc-cmds/orchestrator/stage-wrapper.sh"
wrun() { wout=$(bash "$WRAP" "$@" 2>&1); }
mkdir -p "$WORK/plug"; : > "$WORK/s.json"

wrun --plugin-dir "$WORK/plug" --session-id x -- -p x
case "$wout" in *"--settings is required"*) ok "래퍼: 설정 없이 스테이지를 띄우지 않는다" ;;
  *) bad "래퍼 설정 필수" "$wout" ;; esac

wrun --settings "$WORK/s.json" --session-id x -- -p x
case "$wout" in *"--plugin-dir is required"*) ok "래퍼: 플러그인 디렉터리 없이 띄우지 않는다" ;;
  *) bad "래퍼 플러그인 필수" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" -- -p x
case "$wout" in *"--session-id or --resume is required"*) ok "래퍼: 세션 식별 없이 띄우지 않는다" ;;
  *) bad "래퍼 세션 필수" "$wout" ;; esac

wrun --settings "$WORK/absent.json" --plugin-dir "$WORK/plug" --session-id x -- -p x
case "$wout" in *"settings file not found"*) ok "래퍼: 존재하지 않는 설정은 하드 스톱" ;;
  *) bad "래퍼 설정 존재" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" --session-id x --mode Z -- -p x
case "$wout" in *"unknown mode"*) ok "래퍼: 어휘 밖 모드는 거부" ;;
  *) bad "래퍼 모드 어휘" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" --session-id x
case "$wout" in *"CLI arguments are required after --"*) ok "래퍼: CLI 인자 없이 띄우지 않는다" ;;
  *) bad "래퍼 argv 필수" "$wout" ;; esac

# The stage must be HANDED what the hook will demand of it. Layer 1 routes every
# Bash line, Write and Edit through the gate, and the gate's argv needs a
# manifest path, a target and a snapshot digest. Measured: an implementation
# stage was blocked fourteen times, edited nothing, left the tree byte-identical
# and exited 0 with `subtype: success` — it could not even write a halt record,
# because that path derives its location from the run id and reading the run id
# needs the Bash the hook had just refused.
for v in CC_PIPELINE_MANIFEST CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT \
         CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_LEDGER CC_PIPELINE_GRANT; do
  if grep -vE '^[[:space:]]*#' "$GATE" | grep_all_q -F "$v="; then
    ok "게이트가 스테이지에 $v 를 넘긴다"
  else
    bad "스테이지 환경" "$v 가 스테이지에 도달하지 않는다 — 훅이 요구하는 값을 채울 수 없다"
  fi
done

# The refusal has to be a line the stage can TYPE. Angle-bracket placeholders it
# cannot fill make the correct behaviour (stop and report) indistinguishable
# from a stage that produced nothing.
decide "$(bash_json 'git status')"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *'$CC_PIPELINE_MANIFEST'*) ok "거부 문면이 스테이지가 가진 변수를 쓴다" ;;
  *) bad "재호출 형태" "스테이지가 채울 수 없는 자리표시자를 준다: $reason" ;;
esac
case "$reason" in
  *'snapshot --manifest'*) ok "거부 문면이 해시를 받아 오는 줄을 함께 준다 (해시는 얼려 줄 수 없다)" ;;
  *) bad "스냅숏 해시" "$reason" ;;
esac

# The wrapper declares `#!/usr/bin/env bash` and uses `set -o pipefail`. Naming
# an interpreter on the command line OVERRIDES the shebang, so launching it with
# `/bin/sh` kills it at its second line on any distribution whose `/bin/sh` is
# dash — and takes every stage launch with it. macOS hides this completely
# because its `/bin/sh` is bash.
for caller in "$repo_root/plugins/cc-cmds/orchestrator/run.sh" \
              "$repo_root/plugins/cc-cmds/orchestrator/gate.sh"; do
  if sed 's/#.*//' "$caller" | grep_all_q -F '/bin/sh "$ORCH_DIR/stage-wrapper.sh"'; then
    bad "래퍼 호출 인터프리터" "$(basename "$caller") 가 /bin/sh 로 래퍼를 띄운다"
  elif sed 's/#.*//' "$caller" | grep_all_q -E '/bin/sh "\$wrapper"'; then
    bad "래퍼 호출 인터프리터" "$(basename "$caller") 가 /bin/sh 로 래퍼를 띄운다"
  else
    ok "래퍼: $(basename "$caller") 가 bash 로 띄운다 (셰방보다 명령줄 인터프리터가 이긴다)"
  fi
done

# The rule checkers ARE `/bin/sh` scripts by design and must stay POSIX, so the
# gate launching them that way is correct rather than an oversight.
if sed 's/#.*//' "$GATE" | grep_all_q -F '/bin/sh "$checker"'; then
  ok "룰 검사기는 /bin/sh 로 띄운다 (설계상 POSIX)"
else
  bad "검사기 호출" "검사기 호출 형태가 바뀌었다 — POSIX 전제가 유지되는지 확인 필요"
fi

# `--include-partial-messages` must stay off: it multiplies stream volume for a
# stage nobody is watching character by character, and the terminal
# classification is read off the `result` line either way.
if grep -vE '^[[:space:]]*#' "$WRAP" | grep_all_q 'include-partial-messages'; then
  bad "스트림 볼륨" "--include-partial-messages 를 싣는다"
else
  ok "래퍼: --include-partial-messages 를 싣지 않는다"
fi

# ---------------------------------------------------------------------------
# N. THE DENY MESSAGE MUST NAME A SHAPE THIS ALLOW-LIST ACCEPTS
#
# It did not. The message prescribed `H=$(<gate> snapshot …) && <gate> exec …`,
# whose first token is `H=$(<gate>` — so the hook denied the exact command it
# had just asked for, and a stage that read the message carefully and complied
# was refused with the same boilerplate it was already holding. Measured: a
# review stage tried it twice, combined and split, and stopped without writing
# its report.
#
# Every command the message prescribes is extracted from the message ITSELF and
# fed back through the hook, so the two cannot drift apart again.
# ---------------------------------------------------------------------------
decide "$(bash_json 'ls -la')"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')

# The old shape must not come back.
case "$reason" in
  *'H=$('*) bad "거부 문면 형태" "명령 치환을 지시한다 — 이 훅이 거부하는 형태다" ;;
  *)        ok "거부 문면이 명령 치환을 지시하지 않는다" ;;
esac

# Every gate-path occurrence in the message is the start of a command it is
# telling the stage to run. Each must be allowed.
#
# CUT AT ONE COMMAND, NOT AT THE END OF THE MESSAGE. Taking the whole tail made
# this assertion vacuous past the first token: the hook matches argv0, so any
# trailing prose rode along and every candidate passed no matter what followed.
# The message separates its prescribed commands with a standalone `.`, which is
# where a command actually ends, so that is where the extraction stops.
n_shapes=0; n_denied=0; n_thin=0
for frag in $(printf '%s' "$reason" | tr ' ' '\n' | grep -nF "$GATE" | sed 's/:.*//'); do
  cand=$(printf '%s' "$reason" | tr ' ' '\n' | sed -n "${frag},\$p" \
         | awk 'NR>1 && ($0=="." || $0=="』" || $0=="『") {exit} {print}' | tr '\n' ' ')
  n_shapes=$((n_shapes + 1))
  # A candidate that carries no `--manifest` is not a command this message
  # prescribes — it is a fragment the cut got wrong, and passing it through the
  # hook would assert nothing. A lone separator is red here rather than green.
  case "$cand" in
    *--manifest*) ;;
    *) n_thin=$((n_thin + 1)) ;;
  esac
  decide "$(bash_json "$cand")"
  [ "$dec" = "allow" ] || n_denied=$((n_denied + 1))
done
check "뽑아낸 조각이 전부 실제 게이트 명령이다 (자름이 어긋나지 않았다)" "$n_thin" "0"
# A BARE `.` MUST NOT SIT WHERE AN ARGUMENT WOULD. The message ends its
# prescriptions with a marker rather than a sentence period, because a period
# copied along with the command reaches the shell as a word — `--fields H .`
# hands the gate a stray positional and the documented fallback fails on first
# use. A period glued to the field name is the same failure in another spelling
# — `--fields H.` names a field that does not exist — so both shapes are
# refused, here and on every other denial that prescribes this fallback.
assert_no_period_after_fields() {
  case "$2" in
    *'--fields H .'*) bad "$1 — 처방된 명령이 문장 마침표로 끝나지 않는다" "--fields H 뒤에 홑 . 이 인자로 붙는다" ;;
    *'--fields H.'*)  bad "$1 — 처방된 명령이 문장 마침표로 끝나지 않는다" "필드 이름에 . 이 붙어 H. 가 된다" ;;
    *)                ok "$1 — 처방된 명령이 문장 마침표로 끝나지 않는다" ;;
  esac
}
assert_no_period_after_fields "Bash 거부" "$reason"
# THE FALLBACK IS A BARE GATE CALL, NOT A PIPE. The previous prescription piped
# the snapshot into `jq -r .H`, and the hook carried a special case to let that
# one pipe through; `snapshot --fields H` prints the value alone, so the special
# case retired with it. A message that still prescribes the pipe hands out a
# command this hook refuses.
case "$reason" in
  *'--fields H'*) ok "Bash 거부 문면이 --fields H 로 스냅숏 폴백을 처방한다" ;;
  *) bad "Bash 거부 문면의 스냅숏 폴백" "--fields H 가 문면에 없다" ;;
esac
case "$reason" in
  *'jq -r .H'*) bad "Bash 거부 문면이 옛 파이프 폴백을 처방하지 않는다" "'| jq -r .H' 가 남아 있다" ;;
  *) ok "Bash 거부 문면이 옛 파이프 폴백을 처방하지 않는다" ;;
esac

# THE HOOK DOES NOT BUILD THE PATH; IT ASKS. Two programs agreeing on one
# string disagreed for every stage in the pipeline — the gate sanitizes the
# stage id into the filename and this hook interpolated it verbatim, so the two
# matched only for the router, the one actor this hook is never installed for.
# The failure is silent at both ends: the gate emits correctly, the stage opens
# a name that does not exist, and it falls back to the round trip the flag
# exists to remove. What this suite can measure is that the derivation lives in
# one place; that the printed value equals the file actually written is the
# gate suite's half.
if grep -q 'digest-path' "$HOOK"; then
  ok "훅이 게이트에게 방출 경로를 묻는다"
else
  bad "훅이 게이트에게 방출 경로를 묻는다" "스스로 조립하고 있다"
fi
if grep -q 'gate-digest-\${CC_PIPELINE_STAGE_ID' "$HOOK"; then
  bad "훅이 스테이지 id 로 파일명을 조립하지 않는다" "게이트의 정제 규칙을 복제하고 있다"
else
  ok "훅이 스테이지 id 로 파일명을 조립하지 않는다"
fi

# THE MESSAGE CARRIES BOTH HALVES OF THE CONTRACT IT PRESCRIBES. Asserting only
# that the commands pass the hook says nothing about whether they are the
# commands the current contract names — the flag could vanish and the path could
# be wrong, and the shapes would still be allowed.
case "$reason" in
  *'--emit-digest'*) ok "거부 문면이 방출 플래그를 처방한다" ;;
  *) bad "거부 문면이 방출 플래그를 처방한다" "플래그가 문면에 없다" ;;
esac
case "$reason" in
  *'--emit-digest-to'*) bad "거부 문면이 옛 경로 인자 형태를 처방하지 않는다" "옛 철자가 남아 있다" ;;
  *) ok "거부 문면이 옛 경로 인자 형태를 처방하지 않는다" ;;
esac
case "$reason" in
  *'/digest/gate-digest-'*) ok "거부 문면이 방출 파일 경로를 지목한다" ;;
  *) bad "거부 문면이 방출 파일 경로를 지목한다" "격리 경로가 문면에 없다" ;;
esac
if [ "$n_shapes" -ge 2 ]; then
  ok "거부 문면이 게이트로 시작하는 명령을 둘 이상 제시한다 ($n_shapes)"
else
  bad "거부 문면 형태" "게이트로 시작하는 명령이 ${n_shapes}개뿐이다 — 수행할 exec 와, 방출 파일이 없을 때의 스냅숏 폴백 둘이 필요하다"
fi
check "그 명령들이 전부 이 훅을 통과한다" "$n_denied" "0"

# NO PIPE RIDES ON THE GATE, the retired special case included. `| jq -r .H`
# was the one pipe the hook used to let through; now that the fallback is
# `--fields H` the pipe is refused like any other, and the refusal names the
# replacement so the stage that copied an old message can fix its command.
decide "$(bash_json "$GATE snapshot --manifest /tmp/m.md | jq -r .H")"
check "옛 특례 파이프 '| jq -r .H' 도 이제 거부된다" "$dec" "deny"
reason_pipe=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason_pipe" in
  *'--fields H'*) ok "파이프 거부 문면이 --fields H 를 처방한다" ;;
  *) bad "파이프 거부 문면" "'$reason_pipe'" ;;
esac
decide "$(bash_json "$GATE snapshot --manifest /tmp/m.md --fields H")"
check "특례를 대신하는 --fields H 는 맨 게이트 호출이라 통과한다" "$dec" "allow"

# And the laundering shapes stay denied.
decide "$(bash_json "H=\$($GATE snapshot --manifest /tmp/m.md)")"
check "명령 치환으로 감싼 게이트는 여전히 거부된다" "$dec" "deny"
decide "$(bash_json "echo x; $GATE snapshot --manifest /tmp/m.md")"
check "앞에 다른 명령을 붙인 형태도 거부된다" "$dec" "deny"

# ---------------------------------------------------------------------------
# CLAUDE.md — the one edit target git does not watch
#
# These are the arms the whole three-layer audit stands on. Write/Edit is the
# only path that leaves no ledger row, so if it stays open for these files the
# other two layers are unreachable: a stage edits the prefix and nothing records
# that it did. Asserted per spelling because the arm is a glob and a glob that
# stops matching fails silently.
# ---------------------------------------------------------------------------
for slot in \
    "$HOME/.claude-cc/CLAUDE.md" \
    "$HOME/dev/CLAUDE.md" \
    "$HOME/dev/cc-cmds/CLAUDE.md" \
    "$HOME/Documents/orderbook/CLAUDE.md" \
    "/some/other/place/CLAUDE.md" \
    "CLAUDE.md" \
    "/a/b/CLAUDE.local.md"; do
  decide "$(write_json "$slot")"
  check "CLAUDE.md 슬롯 쓰기가 거부된다: $slot" "$dec" "deny"
done

# The denial has to hand back a command the stage can actually run, the same way
# the Bash denial does. A refusal with no route is one an unattended stage works
# around or stops on.
decide "$(write_json "$HOME/.claude-cc/CLAUDE.md")"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *"$GATE exec"*) ok "CLAUDE.md 거부 문면이 게이트 exec 로 유도한다" ;;
  *) bad "CLAUDE.md 에스컬레이션 문면" "'$reason'" ;;
esac
case "$reason" in
  *'--fields H'*) ok "CLAUDE.md 거부 문면이 스냅숏 폴백 명령을 싣는다 (아래 단언이 공허하지 않다)" ;;
  *) bad "CLAUDE.md 거부 문면의 스냅숏 폴백" "'$reason'" ;;
esac
case "$reason" in
  *'jq -r .H'*) bad "CLAUDE.md 거부 문면이 옛 파이프 폴백을 처방하지 않는다" "'| jq -r .H' 가 남아 있다" ;;
  *) ok "CLAUDE.md 거부 문면이 옛 파이프 폴백을 처방하지 않는다" ;;
esac
assert_no_period_after_fields "CLAUDE.md 거부" "$reason"

# A file merely NAMED like one of these somewhere unrelated is still the same
# channel, but a file that only CONTAINS the name is not — asserted so the arm
# is not "fixed" into a containment test.
decide "$(write_json "/tmp/CLAUDE.md.bak")"
check "이름을 포함하기만 하는 파일은 대상이 아니다" "$dec" "allow"

# ---------------------------------------------------------------------------
# The rollback sources — baseline copies and per-version history
#
# Both are read-only evidence for the morning comparison. A stage that can write
# either one can make its own edit look like it was always there, and then the
# comparison succeeds while meaning nothing.
# ---------------------------------------------------------------------------
# `decide_cfg` and `cfgdir` are the relocated-config helpers defined above; this
# section reuses them rather than defining a second pair. A shadowing redefinition
# reads as harmless and is not — the tree's own lint flags a call that precedes
# the surviving definition, and the earlier calls then run against a helper the
# reader is no longer looking at.
for evid in "$cfgdir/backups/20260906/home-CLAUDE.md" "$cfgdir/file-history/abc123.md"; do
  decide_cfg "$(write_json "$evid")"
  check "롤백 증거 쓰기가 거부된다: ${evid#"$cfgdir"/}" "$dec" "deny"
done
decide_cfg "$(write_json "$WORK/unrelated/backups/x.md")"
check "다른 트리의 같은 이름 디렉터리는 대상이 아니다" "$dec" "allow"

# 매니페스트는 인가 기록이다. 게이트의 Bash 경로는 그것에 대한 쓰기를 거부하는데 이
# 경로는 거부하지 않아, 같은 편집이 한 도구로는 거절되고 다른 도구로는 통과했다.
# 「## 인가」의 자동 채택 행은 사람 없이 채택되는 판단 부류를 정하므로 — 인가 기록이
# 쥔 것과 같은 종류의 값이고, 인가 기록에는 이 팔이 처음부터 있었다.
decide "$(write_json "$MANIFEST")"
check "매니페스트 쓰기는 거부된다" "$dec" "deny"
case "$out" in
  *"자동 채택"*) ok "그 거절이 왜 인가의 자기확장인지 말한다" ;;
  *) bad "매니페스트 거절 문면" "$out" ;;
esac
# 대조군 — 이름만 비슷한 이웃은 대상이 아니다. 접두만 보는 구현이 아니다.
decide "$(write_json "$MANIFEST.bak")"
check "매니페스트와 이름이 겹치는 이웃 파일은 대상이 아니다" "$dec" "allow"
# 그리고 그 경로는 인자로 건네받는다. 환경 변수는 스테이지 자신의 프로세스 트리에
# 있어 스테이지가 바꿀 수 있다.
if grep -qF -- "--manifest '\$MANIFEST'" "$repo_root/plugins/cc-cmds/orchestrator/gate.sh"; then
  ok "게이트가 생성하는 훅 명령이 매니페스트 경로를 인자로 싣는다"
else
  bad "훅 명령" "매니페스트 경로가 인자로 넘어가지 않는다 — 스테이지가 바꿀 수 있는 환경 변수에 기대게 된다"
fi

# ---------------------------------------------------------------------------
# 런 디렉터리 판정 — 이 팔에는 단언이 하나도 없었다
#
# 스테이지가 쓰도록 선언된 것은 `halt/<stage-id>.md` 와 `<segment>.plan.md` 뿐이고
# 나머지는 게이트가 매 행위마다 되읽는 기준선이다. 여기에 더해 팀 위트니스
# 디렉터리가 예외인데, 그 이름은 `cc-team-witness-init.sh` 가 실제로 만드는 접두여야
# 한다 — 실재하지 않는 이름으로 예외를 적으면 발행이 전부 거부되고, 위트니스를
# 관측하지 못한 리드는 멈추거나 보지 못한 산출물을 합성하게 된다.
# ---------------------------------------------------------------------------
decide "$(write_json "$RUN_DIR/log/SD.json")"
check "런 디렉터리의 스테이지 로그 쓰기는 거부된다" "$dec" "deny"
decide "$(write_json "$RUN_DIR/settings/generic.json")"
check "런 설정 디렉터리 쓰기는 거부된다" "$dec" "deny"
decide "$(write_json "$RUN_DIR/halt/a/b.md")"
check "halt 아래 두 단계는 거부된다" "$dec" "deny"
decide "$(write_json "$RUN_DIR/halt/SD#1.md")"
check "선언된 이름 halt/<stage-id>.md 는 거부되지 않는다" "$([ "$dec" = deny ] && printf deny || printf 'not-deny')" "not-deny"
decide "$(write_json "$RUN_DIR/SD.plan.md")"
check "선언된 이름 <segment>.plan.md 도 거부되지 않는다" "$([ "$dec" = deny ] && printf deny || printf 'not-deny')" "not-deny"
# 예외 이름은 생성 스크립트를 실제로 돌려 얻는다. 훅의 리터럴만 확인하는 단언은
# 두 파일이 어긋나도 초록이다.
HWPUB=$(CC_PIPELINE_RUN_DIR="$RUN_DIR" \
        "$repo_root/plugins/cc-cmds/orchestrator/cc-team-witness-init.sh" review-alpha 2>/dev/null)
case "$HWPUB" in
  "$RUN_DIR"/cc-team-witness-*) ok "생성 스크립트가 런 루트 바로 아래에 디렉터리를 만든다 (아래 단언이 실제 경로를 잰다)" ;;
  *) bad "위트니스 픽스처" "생성 스크립트가 런 디렉터리 아래 경로를 내지 않았다: ${HWPUB:-(빈 값)}" ;;
esac
decide "$(write_json "$HWPUB/reviewer.round-1.md")"
check "생성 스크립트가 만든 위트니스 디렉터리로의 쓰기는 거부되지 않는다" "$([ "$dec" = deny ] && printf deny || printf 'not-deny')" "not-deny"
decide "$(write_json "$RUN_DIR/witness/r1.md")"
check "아무도 만들지 않는 witness/ 철자는 예외가 아니다" "$dec" "deny"
# 공유 세대 디렉터리 — 교대가 산출물을 `shared/<gen>/` 아래에 발행한다. 예외는 한
# 세대 아래에만 열리고, `shared/` 바로 밑의 파일은 세대가 없으므로 기준선으로 돌아간다.
decide "$(write_json "$RUN_DIR/shared/1/snapshot.json")"
check "shared/<gen>/ 아래 한 단계의 쓰기는 거부되지 않는다" "$([ "$dec" = deny ] && printf deny || printf 'not-deny')" "not-deny"
decide "$(write_json "$RUN_DIR/shared/loose.json")"
check "shared/ 바로 아래의 파일은 예외가 아니다" "$dec" "deny"
reason_shared=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason_shared" in
  *'a file directly under shared/ is not'*) ok "shared/ 거부 문면이 바로 아래를 예외 밖으로 지목한다" ;;
  *) bad "shared/ 거부 문면" "'$reason_shared'" ;;
esac
if grep -qF 'shared/*/*' "$HOOK" && grep -qF 'shared/*/*' "$repo_root/plugins/cc-cmds/orchestrator/gate.sh"; then
  ok "훅과 게이트가 같은 shared/<gen>/ 예외를 싣는다"
else
  bad "shared/ 예외 합의" "훅과 게이트의 shared/*/* 철자가 어긋난다"
fi

# ---------------------------------------------------------------------------
# 8. 라우터 입력 디렉터리 — cc-lane 설정·상태 디렉터리와 페이싱 디렉터리
#
# 셋 다 이 런이 끝난 뒤 라우터·게이트·디스패처가 읽는 입력이라 파일 편집 도구로
# 쓸 수 없어야 한다. 루트마다 같은 행을 세우고, 판정과 함께 어느 루트의 문면이
# 답했는지를 단언한다 — 판정만 보면 다른 팔이 우연히 거부한 것과 구별되지 않는다.
#
# 루트가 없는 상태의 행이 핵심이다. 루트가 실재하면 공통 아이노드 층이 대부분의
# 철자를 이미 막으므로, 운영자 스코프 팔을 문자 그대로 복제한 팔과 이 팔을 가르는
# 것은 루트 부재의 대소문자 변형(행 3), 합집합 철자(행 6), 조상 링크의 대문자 꼬리
# (행 8), 루트 부재의 펌링크 철자(행 11), 부모 부재의 대소문자 변형(행 13)이다.
#
# 이 파일은 CI 에서 리눅스에서만 돈다. 행 11 은 데이터 볼륨 철자가 실제로 같은
# 디렉터리로 해소될 때만 서므로 다윈 로컬 실행에서만 단언되고, 그 행이 부모
# 아이노드 비교를 홀로 가리는 유일한 행이다. 부모마저 없을 때의 펌링크 철자는
# 어휘 비교만 남아 통과하는 잔여라 통과로도 거부로도 고정하지 않는다.
# ---------------------------------------------------------------------------
t_ino() {
  # t_ino <경로> — 이 호스트에서 통하는 철자로 dev:ino 를 낸다. 통하는 철자가 없으면
  # 아무것도 내지 않는다. BSD 는 `-f` 가 포맷 지정자이고 GNU 는 `-f` 가
  # `--file-system` 이라, 한 철자만 적으면 다른 쪽에서는 에러 없이 엉뚱한 것을 찍는다.
  local o
  o=$(stat -L -f '%d:%i' "$1" 2>/dev/null)
  case "$o" in [0-9]*:[0-9]*) printf '%s' "$o"; return 0 ;; esac
  o=$(stat -L -c '%d:%i' "$1" 2>/dev/null)
  case "$o" in [0-9]*:[0-9]*) printf '%s' "$o"; return 0 ;; esac
  return 1
}

# 앵커를 만드는 넷(`HOME`·`CLAUDE_CONFIG_DIR`·`XDG_CONFIG_HOME`·`XDG_STATE_HOME`)을
# 매 호출에 전부 고정한다. 하나라도 물려받으면 훅이 개발자의 실제 홈을 앵커하거나,
# XDG 가 설정된 CI 러너에서만 픽스처 밖을 앵커해 러너에서만 붉어진다 — 형제 시험
# 파일이 그 사고를 한 번 겪었다.
HH=""; XC=""; XS=""; rh_n=0; reason=""
decide_home() {
  out=$(printf '%s' "$1" | HOME="$HH" CLAUDE_CONFIG_DIR="$HH/.claude-x" \
          XDG_CONFIG_HOME="$XC" XDG_STATE_HOME="$XS" \
          bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE" \
          --ledger "$LEDGER" --grant "$GRANT" --manifest "$MANIFEST" 2>/dev/null)
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
}
# 빈 `HOME` 은 위 헬퍼로 표현할 수 없다. 같은 넷을 고정하되 `HOME` 은 빈 값, XDG 둘은
# unset 이다.
decide_emptyhome() {
  out=$(printf '%s' "$1" | env -u XDG_CONFIG_HOME -u XDG_STATE_HOME \
          HOME= CLAUDE_CONFIG_DIR="$WORK/.claude-empty" \
          bash "$HOOK" --run-dir "$RUN_DIR" --gate "$GATE" \
          --ledger "$LEDGER" --grant "$GRANT" --manifest "$MANIFEST" 2>/dev/null)
  dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
}
tool_json() {
  # tool_json <도구> <경로> — NotebookEdit 는 `notebook_path` 로 싣는다.
  case "$1" in
    NotebookEdit) jq -n --arg t "$1" --arg p "$2" '{"tool_name":$t,"tool_input":{"notebook_path":$p}}' ;;
    *)            jq -n --arg t "$1" --arg p "$2" '{"tool_name":$t,"tool_input":{"file_path":$p}}' ;;
  esac
}
row_decider=decide_home
router_row() {
  # router_row <이름> <도구> <경로> <기대 판정> [<기대 문면 조각>] — 판정과 문면
  # 조각을 둘 다 단언한다.
  local label="$1" want="$4" frag="${5:-}"
  "$row_decider" "$(tool_json "$2" "$3")"
  if [ "$dec" != "$want" ]; then
    bad "$label" "got '$dec' ($reason), want '$want'"; return
  fi
  if [ -n "$frag" ]; then
    case "$reason" in
      *"$frag"*) ;;
      *) bad "$label" "문면에 '$frag' 가 없다: $reason"; return ;;
    esac
  fi
  ok "$label"
}
fresh_home() {
  # 행마다 독립 픽스처 홈. 루트와 부모의 실재·부재를 행이 스스로 정한다.
  rh_n=$((rh_n + 1))
  HH="$WORK/rh$rh_n"; mkdir -p "$HH/.claude-x" "$HH/w"
  XC="$HH/.config"; XS="$HH/.local/state"
}
root_spec() {
  # root_spec <종류> — 홈 기준 부모, XDG 기준 부모 꼬리와 그 XDG 변수, 이름, 문면
  # 조각, 대소문자 변형, 접두 이웃.
  case "$1" in
    config) R_PAR=.config;             R_XVAR=XC; R_XSUB="";       R_N=cc-lane
            R_FRAG='the cc-lane configuration directory'; R_VARS='CC-LANE Cc-Lane'
            R_NB='cc-lane-other/x cc-lanex' ;;
    state)  R_PAR=.local/state;        R_XVAR=XS; R_XSUB="";       R_N=cc-lane
            R_FRAG='the cc-lane state directory';         R_VARS='CC-LANE Cc-Lane'
            R_NB='cc-lane-other/x cc-lanex' ;;
    pace)   R_PAR=.local/state/cc-cmds; R_XVAR=XS; R_XSUB=/cc-cmds; R_N=pace
            R_FRAG='the pacing directory';                R_VARS='PACE Pace'
            R_NB='pace-other/x paced' ;;
  esac
  R_UP="${R_VARS%% *}"
}

for kind in config state pace; do
  root_spec "$kind"
  row_decider=decide_home

  # 1. 루트 부재·부모 실재, 직접 철자.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P"
  router_row "라우터 입력 $kind 1: 루트 부재 직접 철자 거부" Write "$P/$R_N/x.json" deny "$R_FRAG"

  # 2. 루트 실재, 직접 철자.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"
  router_row "라우터 입력 $kind 2: 루트 실재 직접 철자 거부" Write "$P/$R_N/x.json" deny "$R_FRAG"

  # 3. 루트 부재, 마지막 성분의 대소문자 변형.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P"
  for v in $R_VARS; do
    router_row "라우터 입력 $kind 3: 루트 부재 대소문자 변형 $v 거부" Write "$P/$v/x.json" deny "$R_FRAG"
  done

  # 4. 루트 실재, 대소문자 변형 — 조건 없이 선다. 다윈에서는 아이노드 경로가,
  # 대소문자를 구분하는 리눅스 볼륨에서는 부모 아이노드의 대소문자 무시 꼬리와
  # 어휘 비교가 답한다. 어느 쪽이든 거부여야 한다.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"
  for v in $R_VARS; do
    router_row "라우터 입력 $kind 4: 루트 실재 대소문자 변형 $v 거부" Write "$P/$v/x.json" deny "$R_FRAG"
  done

  # 5. 상위 참조 철자.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/sib"
  router_row "라우터 입력 $kind 5: 상위 참조 철자 거부" Write "$P/sib/../$R_N/x.json" deny "$R_FRAG"

  # 6. XDG 를 HOME 밖으로 옮긴다. XDG 철자도, HOME 기본 철자도 거부(합집합)이고, 이
  # 런의 허용 이름은 그대로 허용이다.
  fresh_home; XC="$WORK/xdg$rh_n/config"; XS="$WORK/xdg$rh_n/state"
  eval "XP=\"\$$R_XVAR$R_XSUB\""
  P="$HH/$R_PAR"; mkdir -p "$P" "$XP"
  router_row "라우터 입력 $kind 6: XDG 재지정 시 XDG 철자 거부" Write "$XP/$R_N/x.json" deny "$R_FRAG"
  router_row "라우터 입력 $kind 6: XDG 재지정 시 HOME 기본 철자도 거부" Write "$P/$R_N/x.json" deny "$R_FRAG"
  router_row "라우터 입력 $kind 6: XDG 재지정 시 이 런의 halt 기록은 허용" Write "$RUN_DIR/halt/x.md" allow

  # 7. 말단 심링크 — 앵커 밖의 링크가 앵커 안 파일을 가리킨다.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"; : > "$P/$R_N/t.json"
  ln -s "$P/$R_N/t.json" "$HH/w/leaf-link"
  router_row "라우터 입력 $kind 7: 말단 심링크 거부" Write "$HH/w/leaf-link" deny "$R_FRAG"

  # 8. 조상 심링크 깊이 1, 루트 부재·부모 실재. 루트가 실재하면 기존 아이노드 층이
  # 답해 복제한 팔과 구별되지 않으므로 반드시 부재로 세운다. 복제한 팔과 가르는 것은
  # 대문자 예다.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P"
  ln -s "$P" "$HH/w/anc"
  router_row "라우터 입력 $kind 8: 조상 심링크 소문자 거부" Write "$HH/w/anc/$R_N/L2.json" deny "$R_FRAG"
  router_row "라우터 입력 $kind 8: 조상 심링크 대문자 $R_UP 거부" Write "$HH/w/anc/$R_UP/usage.json" deny "$R_FRAG"

  # 9. 기존 파일로의 하드링크 — 새 팔이 아니라 링크 수 술어가 일반 문면으로 거부한다.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"; : > "$P/$R_N/usage.json"
  ln "$P/$R_N/usage.json" "$HH/w/HARD-usage"
  router_row "라우터 입력 $kind 9: 하드링크 거부" Write "$HH/w/HARD-usage" deny 'the edit target is a hard link'

  # 10. 기존 파일 하나에 대한 나머지 편집 도구.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"; : > "$P/$R_N/f.json"
  for t in Edit MultiEdit NotebookEdit; do
    router_row "라우터 입력 $kind 10: 기존 파일 $t 거부" "$t" "$P/$R_N/f.json" deny "$R_FRAG"
  done

  # 11. 루트 부재·부모 실재, 펌링크 철자. 기존 층이 허용하는 철자라 부모 아이노드
  # 비교만 답한다. 부모의 두 철자가 같은 아이노드일 때만 서고, 아니면 건너뛴 사실을
  # 한 줄로 남긴다 — 세지 않는 건너뜀은 커버리지가 사라진 것과 구별되지 않는다.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P"
  PP=$(cd "$P" 2>/dev/null && pwd -P)
  FIRM="/System/Volumes/Data${PP:-$P}"
  if [ -n "$(t_ino "$FIRM")" ] && [ "$(t_ino "$FIRM")" = "$(t_ino "$P")" ]; then
    router_row "라우터 입력 $kind 11: 루트 부재 펌링크 철자 거부" Write "$FIRM/$R_N/x.json" deny "$R_FRAG"
  else
    printf 'NOTE: 데이터 볼륨 철자가 부모에 해소되지 않아 라우터 입력 %s 행 11 을 건너뛴다 (%s)\n' "$kind" "$FIRM"
  fi

  # 12. 루트 부재, 루트 자신을 파일 경로로(꼬리 없음).
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P"
  router_row "라우터 입력 $kind 12: 루트 자신을 파일로 쓰기 거부" Write "$P/$R_N" deny "$R_FRAG"

  # 13. 부모 부재. 어휘 비교와 접힌 패스의 합이 지키는 행이다 — 두 패스의 문면이
  # 같아 어느 쪽이 답했는지는 가르지 않는다.
  fresh_home; P="$HH/$R_PAR"
  router_row "라우터 입력 $kind 13: 부모 부재 직접 철자 거부" Write "$P/$R_N/x.json" deny "$R_FRAG"
  router_row "라우터 입력 $kind 13: 부모 부재 대소문자 변형 $R_UP 거부" Write "$P/$R_UP/x.json" deny "$R_FRAG"

  # 음성 대조 — 접두 이웃은 허용이다. XDG 재지정 유무 양쪽에서.
  fresh_home; P="$HH/$R_PAR"; mkdir -p "$P/$R_N"
  for nb in $R_NB; do
    router_row "라우터 입력 $kind 대조: 접두 이웃 $nb 허용" Write "$P/$nb" allow
  done
  fresh_home; XC="$WORK/xdg$rh_n/config"; XS="$WORK/xdg$rh_n/state"
  eval "XP=\"\$$R_XVAR$R_XSUB\""
  P="$HH/$R_PAR"; mkdir -p "$P/$R_N" "$XP/$R_N"
  for nb in $R_NB; do
    router_row "라우터 입력 $kind 대조: XDG 재지정 시 XDG 쪽 접두 이웃 $nb 허용" Write "$XP/$nb" allow
    router_row "라우터 입력 $kind 대조: XDG 재지정 시 HOME 쪽 접두 이웃 $nb 허용" Write "$P/$nb" allow
  done
done

# 평범한 소스 파일은 고정 홈 아래에서도 허용이다.
row_decider=decide_home
fresh_home
router_row "라우터 입력 대조: 평범한 소스 파일 허용" Write "$WORK/src/main.ts" allow

# 기존 팔의 대조군은 각자의 문면으로 거부된다 — 새 팔이 앞에서 가로채지 않는다.
fresh_home; mkdir -p "$HH/.config" "$HH/.local/state/cc-cmds/run"
router_row "라우터 입력 대조: 운영자 스코프는 기존 문면으로 거부" Write "$HH/.config/cc-cmds/x" deny 'the operator-scope configuration directory'
router_row "라우터 입력 대조: 형제 런은 기존 문면으로 거부" Write "$HH/.local/state/cc-cmds/run/other/x" deny 'this is another run directory'

# 빈 `HOME` 에 XDG 가 없으면 앵커를 만들지 않는다. 뒤의 것은 빈 기반에 `/cc-cmds` 를
# 합성한 부모 철자라, 부모 문자열만 보고 앵커하는 구현을 이 대조가 잡는다. 같은
# 환경에서 페이싱 루트의 기본 철자가 되는 자리는 보호되지 않는 잔여라 넣지 않는다.
row_decider=decide_emptyhome
router_row "라우터 입력 대조: 빈 HOME 에서 /cc-lane/x 허용" Write "/cc-lane/x" allow
router_row "라우터 입력 대조: 빈 HOME 에서 /cc-cmds/pace/x 허용" Write "/cc-cmds/pace/x" allow
row_decider=decide_home

# 앵커 변수에 제어 문자가 있으면 레코드가 쪼개져 엉뚱한 앵커가 서므로 판정 불가다.
fresh_home
XC="$HH/.config
/tmp"
router_row "라우터 입력: 앵커 변수의 제어 문자는 판정 불가로 거부" Write "$WORK/src/main.ts" deny 'carries a control character'

printf '\ntest-orchestrator-pretool-hook: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
