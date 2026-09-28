#!/usr/bin/env bash
# Test the edit-time stage-policy drift hook —
# plugins/cc-cmds/hooks/stage-policy-edit-drift.sh.
#
# The hook is driven the way the harness drives it — a `PostToolUse` JSON
# payload on stdin — and three things are read back: the exit status, stdout
# (the one JSON object the hook may write) and stderr (which must stay empty).
#
# THE PLUGIN ROOT IS A SCRATCH COPY. `CLAUDE_PLUGIN_ROOT` points at a directory
# holding the real checker beside a manifest built here from a fixture source,
# so the verdict is decided by bytes this suite controls. `HOME` is a scratch
# directory too: the checker reads its acknowledgement store and the hook reads
# the host map from under it, and the person's own files must never be read.
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
HOOK="$repo_root/plugins/cc-cmds/hooks/stage-policy-edit-drift.sh"
CHECKER="$repo_root/plugins/cc-cmds/orchestrator/stage-policy-drift.sh"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook parses JSON and nothing can be driven without it"
  echo "test-stage-policy-edit-hook: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-policy-edit-hook.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PLUG="$WORK/plugin"
CFG="$WORK/cfg"
LINKED="$WORK/linked-cfg"
FAKE_HOME="$WORK/home"
mkdir -p "$PLUG/orchestrator" "$CFG" "$FAKE_HOME"
ln -s "$CFG" "$LINKED"
cp "$CHECKER" "$PLUG/orchestrator/stage-policy-drift.sh"

BASE='- alpha rule one
    continued alpha
- beta rule two
'
printf '%s' "$BASE" > "$CFG/CLAUDE.md"
hash_of() {
  ( . "$CHECKER"; drift_entries user-scope "$CFG/CLAUDE.md" ) \
    | awk -F'\t' -v a="$1" 'index($1, a) == 1 { print $2 }'
}
{
  printf 'source\tanchor\tsha256\tdisposition\tnote\n'
  printf 'user-scope\talpha\t%s\tpolicy:Artifacts\t\n' "$(hash_of alpha)"
  printf 'user-scope\tbeta\t%s\tpolicy:Conduct\t\n' "$(hash_of beta)"
} > "$PLUG/orchestrator/stage-policy.sources.tsv"

payload() { jq -cn --arg p "$1" '{tool_name: "Edit", tool_input: {file_path: $p}}'; }

OUTF="$WORK/hook.out"
ERR="$WORK/hook.err"

# hook_run <stdin> [<env assignment>...] — sets HOOK_RC; output in OUTF / ERR.
hook_run() {
  local input="$1"; shift
  printf '%s' "$input" | env -u CC_PIPELINE_RUN_ID HOME="$FAKE_HOME" \
    CLAUDE_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$PLUG" "$@" \
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

# spoke <label> — rc 0, one PostToolUse JSON object carrying the finding and --ack.
spoke() {
  check "$1: rc 0" "$HOOK_RC" "0"
  check "$1: stderr 비어 있음" "$(err_bytes)" "0"
  check "$1: hookEventName" "$(jq -r '.hookSpecificOutput.hookEventName' "$OUTF" 2>/dev/null)" "PostToolUse"
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' "$OUTF" 2>/dev/null)
  case "$ctx" in
    *"changed user-scope alpha"*) ok "$1: 문맥에 changed 발견" ;;
    *) bad "$1: 문맥에 changed 발견" "$ctx" ;;
  esac
  case "$ctx" in
    *"--ack"*) ok "$1: 문맥에 --ack 안내" ;;
    *) bad "$1: 문맥에 --ack 안내" "$ctx" ;;
  esac
  check "$1: 문맥 6000 바이트 이하" "$([ "$(printf '%s' "$ctx" | wc -c | tr -d ' ')" -le 6000 ] && echo yes || echo no)" "yes"
}

# drift the policy row, then edit through both spellings of the path
printf '%s' '- alpha rule one
    continued alpha, edited
- beta rule two
' > "$CFG/CLAUDE.md"

hook_run "$(payload "$CFG/CLAUDE.md")"
spoke "설정 CLAUDE.md 편집 + 드리프트"

hook_run "$(payload "$LINKED/CLAUDE.md")"
spoke "링크된 설정 디렉터리를 거친 경로"

hook_run "$(payload "$CFG/notes.md")"
silent "다른 파일 경로"

hook_run "$(payload "$CFG/CLAUDE.md")" CC_PIPELINE_RUN_ID=x
silent "CC_PIPELINE_RUN_ID 설정"

hook_run 'not json {'
silent "깨진 stdin"

printf '%s' "$BASE" > "$CFG/CLAUDE.md"
hook_run "$(payload "$CFG/CLAUDE.md")"
silent "드리프트 없음"

check "호스트 ack 저장소를 만들지 않는다" \
  "$([ -e "$FAKE_HOME/.config/cc-cmds/stage-policy-ack" ] && echo made || echo none)" "none"

printf 'test-stage-policy-edit-hook: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
