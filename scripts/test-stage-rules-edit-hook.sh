#!/usr/bin/env bash
# Test the stage rules edit hook — plugins/cc-cmds/hooks/stage-rules-edit.sh.
#
# The hook is driven the way the harness drives it — a `PostToolUse` JSON
# payload on stdin — and three things are read back: the exit status, stdout
# (the one JSON object the hook may write) and stderr (which must stay empty).
#
# THE PLUGIN ROOT IS A SCRATCH COPY holding the real `stage-rules.sh`, and
# `HOME` and `CLAUDE_CONFIG_DIR` are scratch directories too: the helper reads
# the host map from under `HOME`, and the person's own files must never be read.
#
# THE PIPELINE RUN ID IS UNSET FOR EVERY RUN except the case that sets it. This
# suite may run inside an unattended stage, where the hook exits at once — and
# every negative case would then pass for the wrong reason.
#
# THE POSITIVE CONTROL COMES FIRST. A suite that only measures silence is green
# against a hook that never speaks.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/stage-rules-edit.sh"
HELPER="$repo_root/plugins/cc-cmds/orchestrator/stage-rules.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no '$3' in: $2" ;; esac; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook parses JSON and nothing can be driven without it"
  echo "test-stage-rules-edit-hook: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-stage-rules-edit-hook.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PLUG="$WORK/plugin"
CFG="$WORK/cfg"
LINKED="$WORK/linked-cfg"
FAKE_HOME="$WORK/home"
REPO="$WORK/repo"
mkdir -p "$PLUG/orchestrator" "$CFG" "$FAKE_HOME" "$REPO"
ln -s "$CFG" "$LINKED"
cp "$HELPER" "$PLUG/orchestrator/stage-rules.sh"

payload() { jq -cn --arg p "$1" '{tool_name: "Edit", tool_input: {file_path: $p}}'; }

OUTF="$WORK/hook.out"
ERR="$WORK/hook.err"

# hook_run <stdin> [<env assignment>...] — sets HOOK_RC; output in OUTF / ERR.
hook_run() {
  local input="$1"; shift
  printf '%s' "$input" | env -u CC_PIPELINE_RUN_ID -u CC_GATE_STAGE_POLICY_SOURCES \
    HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$PLUG" "$@" \
    bash "$HOOK" > "$OUTF" 2> "$ERR"
  HOOK_RC=$?
}
out_bytes() { wc -c < "$OUTF" | tr -d ' '; }
err_bytes() { wc -c < "$ERR" | tr -d ' '; }

# silent <label> — rc 0, nothing on stdout, nothing on stderr.
silent() {
  check "$1: rc 0" "$HOOK_RC" "0"
  check "$1: stdout 비어 있음" "$(out_bytes)" "0"
  check "$1: stderr 비어 있음" "$(err_bytes)" "0"
}

# spoke <label> — rc 0, one PostToolUse JSON object within the cap; sets ctx.
spoke() {
  check "$1: rc 0" "$HOOK_RC" "0"
  check "$1: stderr 비어 있음" "$(err_bytes)" "0"
  check "$1: hookEventName" "$(jq -r '.hookSpecificOutput.hookEventName' "$OUTF" 2>/dev/null)" "PostToolUse"
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' "$OUTF" 2>/dev/null)
  check "$1: 문맥 6000 바이트 이하" \
    "$([ "$(printf '%s' "$ctx" | LC_ALL=C wc -c | tr -d ' ')" -le 6000 ] && echo yes || echo no)" "yes"
  has "$1: 문맥이 개인 규칙 블록의 원천이라고 말한다" "$ctx" "# Personal rules block"
  has "$1: 태그는 사람이 정한다" "$ctx" "tagging is theirs to decide"
}

printf '%s' '- [무인] alpha rule one
    continued alpha
- [대화형] beta rule two
- gamma rule three
' > "$CFG/CLAUDE.md"

hook_run "$(payload "$CFG/CLAUDE.md")"
spoke "설정 CLAUDE.md 편집"
has "설정 CLAUDE.md 편집: 상태 줄" "$ctx" "stage rules: ok unattended=1 "
has "설정 CLAUDE.md 편집: 태그 없는 불릿" "$ctx" "gamma rule three"
case "$ctx" in
  *"[truncated:"*) bad "설정 CLAUDE.md 편집: 잘림 표시 없음" "$ctx" ;;
  *) ok "설정 CLAUDE.md 편집: 잘림 표시 없음" ;;
esac

hook_run "$(payload "$LINKED/CLAUDE.md")"
spoke "링크된 설정 디렉터리를 거친 경로"
has "링크된 설정 디렉터리를 거친 경로: 상태 줄" "$ctx" "stage rules: ok unattended=1 "

# an untagged file: the legacy line and the fixed migrate text
printf '%s' '- alpha rule one
- beta rule two
' > "$CFG/CLAUDE.md"
hook_run "$(payload "$CFG/CLAUDE.md")"
spoke "무태그 파일"
has "무태그 파일: 레거시 줄" "$ctx" "stage rules: untagged — legacy v6 policy"
has "무태그 파일: 이관 고정 문면" "$ctx" "ClickUp 발행 슬라이스가 머지된 플러그인에서 이관"

# a status far past the cap: 400 untagged bullets beside a tagged one
{
  printf -- '- [무인] alpha rule one\n'
  i=1
  while [ "$i" -le 400 ]; do
    printf -- '- padding item %d with a few more words to list\n' "$i"
    i=$((i + 1))
  done
} > "$CFG/CLAUDE.md"
status_bytes=$(env -u CC_PIPELINE_RUN_ID -u CC_GATE_STAGE_POLICY_SOURCES HOME="$FAKE_HOME" \
  CLAUDE_CONFIG_DIR="$CFG" bash "$HELPER" status --source "$CFG/CLAUDE.md" 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')
check "잘림 픽스처: 상태가 6000 바이트를 넘는다" "$([ "$status_bytes" -gt 6000 ] && echo yes || echo no)" "yes"
hook_run "$(payload "$CFG/CLAUDE.md")"
spoke "잘린 상태"
has "잘린 상태: 잘림 표시" "$ctx" "[truncated: run bash \"$PLUG/orchestrator/stage-rules.sh\" status for the full status]"
has "잘린 상태: 상태 머리는 남는다" "$ctx" "stage rules: ok unattended=1 "

# silence: another CLAUDE.md, another file, a pipeline run, no helper, no path
printf '%s' '- [무인] repo rule
' > "$REPO/CLAUDE.md"
hook_run "$(payload "$REPO/CLAUDE.md")"
silent "다른 CLAUDE.md"

printf 'x\n' > "$CFG/notes.md"
hook_run "$(payload "$CFG/notes.md")"
silent "설정 디렉터리의 다른 파일"

hook_run "$(payload "$CFG/CLAUDE.md")" CC_PIPELINE_RUN_ID=20261020-deadbeef
silent "파이프라인 런 안"

mkdir -p "$WORK/empty-plugin/orchestrator"
hook_run "$(payload "$CFG/CLAUDE.md")" CLAUDE_PLUGIN_ROOT="$WORK/empty-plugin"
silent "도우미 없음"

hook_run '{"tool_name":"Edit","tool_input":{}}'
silent "file_path 없음"

hook_run "$(payload "$WORK/no-such-dir/CLAUDE.md")"
silent "없는 디렉터리"

echo "test-stage-rules-edit-hook: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
