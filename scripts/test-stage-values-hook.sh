#!/usr/bin/env bash
# Test the SessionStart hook that hands an unattended stage its pipeline
# values (`plugins/cc-cmds/hooks/stage-values-sessionstart.sh`).
#
# WHAT IT HOLDS THE HOOK TO. Silence outside a pipeline; inside one, exactly one
# JSON object whose context carries every allow-listed name and the three
# derived values, and nothing else from the environment — the grant path and
# the token names and values above all. The registration itself is asserted by
# `scripts/test-statusline-hook.sh`, which owns the `SessionStart` key.
#
# Usage: bash scripts/test-stage-values-hook.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/stage-values-sessionstart.sh"

# THIS SUITE IS RUN FROM INSIDE PIPELINE STAGES TOO, so every variable the hook
# reads is cleared first and each case sets exactly what it means to.
for v in $(compgen -e); do
  case "$v" in CC_PIPELINE_*) unset "$v" ;; esac
done
unset CLAUDE_PLUGIN_ROOT GH_TOKEN GITHUB_TOKEN

# The fixture root is spelled without a doubled slash, so S3 can tell a `//`
# the hook made from one the host's TMPDIR brought in.
tbase="${TMPDIR:-/tmp}"
tbase="${tbase%/}"
d=$(mktemp -d "$tbase/cc-stage-values-test.XXXXXX")
trap 'rm -rf "$d"' EXIT

passed=0; failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' 없음" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "'$3' 가 있음" ;; *) ok "$1" ;; esac; }

NAMES="CC_PIPELINE_RUN_ID CC_PIPELINE_RUN_DIR CC_PIPELINE_MANIFEST CC_PIPELINE_LEDGER CC_PIPELINE_GATE CC_PIPELINE_TARGET CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_HALT_ANSWER CC_PIPELINE_REENTRY_CARD CC_PIPELINE_AUDIT_PASS"
RID=20991231-0badf00d
RUN_DIR="$d/run/$RID"
mkdir -p "$RUN_DIR" "$d/tmp"

# full_env — the environment of a stage: every allow-listed name, the grant
# path and the token variables, each holding a value no other variable shares.
full_env() {
  env -i PATH="$PATH" HOME="$d" TMPDIR="$d/tmp" \
    CC_PIPELINE_RUN_ID="$RID" \
    CC_PIPELINE_RUN_DIR="$RUN_DIR" \
    CC_PIPELINE_MANIFEST="$d/manifest.md" \
    CC_PIPELINE_LEDGER="$d/ledger.md" \
    CC_PIPELINE_GATE="$d/plugin/orchestrator/gate.sh" \
    CC_PIPELINE_TARGET=cc-cmds \
    CC_PIPELINE_SEGMENT=A \
    CC_PIPELINE_STAGE_ID='A#2' \
    CC_PIPELINE_SHIFT_ID= \
    CC_PIPELINE_HALT_ANSWER="$d/answer.md" \
    CC_PIPELINE_REENTRY_CARD= \
    CC_PIPELINE_AUDIT_PASS=2 \
    CC_PIPELINE_GRANT="$d/GRANT-MARKER-grant.md" \
    GH_TOKEN=TOKEN-MARKER-gh \
    GITHUB_TOKEN=TOKEN-MARKER-github \
    CLAUDE_PLUGIN_ROOT="$d/plugin" \
    "$@"
}

ctx_of() { jq -r '.hookSpecificOutput.additionalContext' <<< "$1" 2>/dev/null; }
line_of() { printf '%s\n' "$1" | grep -E "^$2=" | sed -n '1p'; }

# --- S1 outside a pipeline ------------------------------------------------
out=$(env -i PATH="$PATH" HOME="$d" bash "$HOOK" < /dev/null); rc=$?
check "S1 파이프라인 밖에서 rc 0" "$rc" "0"
check "S1 파이프라인 밖에서 출력 없음" "$out" ""
out=$(env -i PATH="$PATH" HOME="$d" CC_PIPELINE_RUN_ID= CC_PIPELINE_STAGE_ID='A#1' bash "$HOOK" < /dev/null); rc=$?
check "S1 빈 런 id 도 rc 0" "$rc" "0"
check "S1 빈 런 id 도 출력 없음" "$out" ""

# --- S2 a stage -------------------------------------------------------------
out=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | full_env bash "$HOOK"); rc=$?
check "S2 스테이지 환경에서 rc 0" "$rc" "0"
check "S2 출력이 JSON 한 개다" "$(jq -s 'length' <<< "$out" 2>/dev/null)" "1"
check "S2 hookEventName 이 SessionStart 다" \
  "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out" 2>/dev/null)" "SessionStart"
ctx=$(ctx_of "$out")
first=$(printf '%s\n' "$ctx" | sed -n '1p')
case "$first" in
  '[cc-stage-values] '*) ok "S2 첫 줄이 [cc-stage-values] 표지로 시작한다" ;;
  *) bad "S2 첫 줄이 [cc-stage-values] 표지로 시작한다" "$first" ;;
esac
has "S2 첫 줄이 스테이지 id 를 싣는다" "$first" "(A#2, 세션 시작 시점)"
has "S2 첫 줄이 마지막 블록을 쓰라고 한다" "$first" "블록이 여럿이면 마지막 블록을 쓴다"
missing=0
for n in $NAMES; do
  [ -n "$(line_of "$ctx" "$n")" ] || { missing=$((missing + 1)); printf '  빠진 이름: %s\n' "$n" >&2; }
done
check "S2 허용 목록 이름 열둘이 모두 있다" "$missing" "0"
check "S2 런 id 값" "$(line_of "$ctx" CC_PIPELINE_RUN_ID)" "CC_PIPELINE_RUN_ID=$RID"
check "S2 런 디렉터리 값" "$(line_of "$ctx" CC_PIPELINE_RUN_DIR)" "CC_PIPELINE_RUN_DIR=$RUN_DIR"
check "S2 빈 이름은 (없음)" "$(line_of "$ctx" CC_PIPELINE_SHIFT_ID)" "CC_PIPELINE_SHIFT_ID=(없음)"
check "S2 빈 재진입 카드도 (없음)" "$(line_of "$ctx" CC_PIPELINE_REENTRY_CARD)" "CC_PIPELINE_REENTRY_CARD=(없음)"
hasnt "S2 GRANT 이름이 없다" "$ctx" "CC_PIPELINE_GRANT"
hasnt "S2 GRANT 값이 없다" "$out" "GRANT-MARKER"
hasnt "S2 토큰 값이 없다" "$out" "TOKEN-MARKER"
hasnt "S2 GH_TOKEN 이름이 없다" "$ctx" "GH_TOKEN"
hasnt "S2 GITHUB_TOKEN 이름이 없다" "$ctx" "GITHUB_TOKEN"
check "S2 이름=값 줄은 허용 목록과 파생값 셋뿐이다" \
  "$(printf '%s\n' "$ctx" | sed -n '2,$p' | wc -l | tr -d ' ')" "15"
check "S2 플러그인 루트" "$(line_of "$ctx" CLAUDE_PLUGIN_ROOT)" "CLAUDE_PLUGIN_ROOT=$d/plugin"
check "S2 스테이지 키" "$(line_of "$ctx" 'stage key')" "stage key=A-2"
check "S2 작업 사본 접두" "$(line_of "$ctx" 'working-copy prefix')" \
  "working-copy prefix=$d/tmp/cc-proto-$RID-A-2."

# --- S3 a trailing slash on TMPDIR -----------------------------------------
out=$(full_env TMPDIR="$d/tmp/" bash "$HOOK" < /dev/null)
p=$(line_of "$(ctx_of "$out")" 'working-copy prefix')
hasnt "S3 끝 / 가 붙은 TMPDIR 에서도 접두에 // 가 없다" "$p" "//"
check "S3 그 접두는 / 없는 TMPDIR 의 접두와 같다" "$p" \
  "working-copy prefix=$d/tmp/cc-proto-$RID-A-2."

# --- S4 a routing shift (no stage id) ---------------------------------------
out=$(full_env CC_PIPELINE_STAGE_ID= CC_PIPELINE_SHIFT_ID=shift-7 bash "$HOOK" < /dev/null)
ctx=$(ctx_of "$out")
has "S4 시프트는 첫 줄에 시프트 id 를 싣는다" "$(printf '%s\n' "$ctx" | sed -n '1p')" "(shift-7, 세션 시작 시점)"
check "S4 스테이지 id 는 (없음)" "$(line_of "$ctx" CC_PIPELINE_STAGE_ID)" "CC_PIPELINE_STAGE_ID=(없음)"
check "S4 스테이지 키는 (없음)" "$(line_of "$ctx" 'stage key')" "stage key=(없음)"
check "S4 작업 사본 접두는 (없음)" "$(line_of "$ctx" 'working-copy prefix')" "working-copy prefix=(없음)"

# --- S5 no plugin root ------------------------------------------------------
out=$(full_env CLAUDE_PLUGIN_ROOT= bash "$HOOK" < /dev/null)
check "S5 플러그인 루트가 없으면 (없음)" \
  "$(line_of "$(ctx_of "$out")" CLAUDE_PLUGIN_ROOT)" "CLAUDE_PLUGIN_ROOT=(없음)"

# --- S6 structure: the names are a fixed list ------------------------------
# Comment lines are left out: the header explains what is kept out by name.
code=$(grep -v -E '^[[:space:]]*#' "$HOOK")
check "S6 (구조) 훅이 환경 전체를 훑지 않는다" \
  "$(printf '%s\n' "$code" | grep -c -E 'compgen|declare -p|export -p|\$\((env|printenv)|^[[:space:]]*(env|printenv)([[:space:]]|$)' | tr -d ' ')" "0"
check "S6 (구조) 훅 코드에 GRANT 이름이 없다" "$(printf '%s\n' "$code" | grep -c 'GRANT' | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
