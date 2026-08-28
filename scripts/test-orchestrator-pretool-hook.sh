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
LEDGER="$WORK/ledger.md"; GRANT="$WORK/grant.md"
: > "$LEDGER"; : > "$GRANT"

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
          --ledger "$LEDGER" --grant "$GRANT" 2>/dev/null)
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
case "$wout" in *"--settings 는 필수"*) ok "래퍼: 설정 없이 스테이지를 띄우지 않는다" ;;
  *) bad "래퍼 설정 필수" "$wout" ;; esac

wrun --settings "$WORK/s.json" --session-id x -- -p x
case "$wout" in *"--plugin-dir 는 필수"*) ok "래퍼: 플러그인 디렉터리 없이 띄우지 않는다" ;;
  *) bad "래퍼 플러그인 필수" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" -- -p x
case "$wout" in *"--session-id 또는 --resume"*) ok "래퍼: 세션 식별 없이 띄우지 않는다" ;;
  *) bad "래퍼 세션 필수" "$wout" ;; esac

wrun --settings "$WORK/absent.json" --plugin-dir "$WORK/plug" --session-id x -- -p x
case "$wout" in *"설정 파일이 없습니다"*) ok "래퍼: 존재하지 않는 설정은 하드 스톱" ;;
  *) bad "래퍼 설정 존재" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" --session-id x --mode Z -- -p x
case "$wout" in *"알 수 없는 모드"*) ok "래퍼: 어휘 밖 모드는 거부" ;;
  *) bad "래퍼 모드 어휘" "$wout" ;; esac

wrun --settings "$WORK/s.json" --plugin-dir "$WORK/plug" --session-id x
case "$wout" in *"-- 뒤에 CLI 인자"*) ok "래퍼: CLI 인자 없이 띄우지 않는다" ;;
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
n_shapes=0; n_denied=0
for frag in $(printf '%s' "$reason" | tr ' ' '\n' | grep -nF "$GATE" | sed 's/:.*//'); do
  cand=$(printf '%s' "$reason" | tr ' ' '\n' | sed -n "${frag},\$p" | tr '\n' ' ')
  n_shapes=$((n_shapes + 1))
  decide "$(bash_json "$cand")"
  [ "$dec" = "allow" ] || n_denied=$((n_denied + 1))
done
if [ "$n_shapes" -ge 2 ]; then
  ok "거부 문면이 게이트로 시작하는 명령을 둘 이상 제시한다 ($n_shapes)"
else
  bad "거부 문면 형태" "게이트로 시작하는 명령이 ${n_shapes}개뿐이다 — 스냅숏과 exec 둘이 필요하다"
fi
check "그 명령들이 전부 이 훅을 통과한다" "$n_denied" "0"

# The first line pipes into jq, and a pipe is fine — what is matched is the
# FIRST token. Asserted directly so nobody "fixes" the matcher into scanning the
# whole line and quietly breaks the shape the message hands out.
decide "$(bash_json "$GATE snapshot --manifest /tmp/m.md | jq -r .H")"
check "파이프가 붙어도 첫 토큰이 게이트면 통과한다" "$dec" "allow"

# And the laundering shapes stay denied.
decide "$(bash_json "H=\$($GATE snapshot --manifest /tmp/m.md)")"
check "명령 치환으로 감싼 게이트는 여전히 거부된다" "$dec" "deny"
decide "$(bash_json "echo x; $GATE snapshot --manifest /tmp/m.md")"
check "앞에 다른 명령을 붙인 형태도 거부된다" "$dec" "deny"

printf '\ntest-orchestrator-pretool-hook: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = "0" ]
