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

# ---------- the notice block ---------------------------------------------------
#
# Every payload below carries the edit itself, and the scratch user-scope file
# is written first as the edit left it: the hook reads the file as edited. The
# block is asserted on the context cut from the first `Rule enforcement
# check:` to its end — the status before it lists the untagged bullets'
# first 40 characters too, so the whole context would pass without a block.

mkdir -p "$PLUG/hooks"
printf 'push guard\n' > "$PLUG/hooks/guard.sh"
TB=$'\t'

# ep <tool name> <tool_input object> — a payload for the user-scope file.
ep() {
  jq -cn --arg t "$1" --arg p "$CFG/CLAUDE.md" --argjson ti "$2" \
    '{tool_name: $t, tool_input: ({file_path: $p} + $ti)}'
}
# eo <old> <new> — one edit.
eo() { jq -cn --arg o "$1" --arg n "$2" '{old_string: $o, new_string: $n}'; }
# after <text> — the user-scope file as the edit left it.
after() { printf '%s' "$1" > "$CFG/CLAUDE.md"; }
# blk — the notice block of ctx, or nothing.
blk() {
  case "$ctx" in
    *"Rule enforcement check:"*) printf '%s' "Rule enforcement check:${ctx#*Rule enforcement check:}" ;;
  esac
}
# base_ctx — the context the hook gives for this file with no edit in the payload.
base_ctx() { hook_run "$(payload "$CFG/CLAUDE.md")"; spoke "$1 (기준 문맥)"; base="$ctx"; }
# same_as_base <label> — the last run spoke the status alone.
same_as_base() {
  spoke "$1"
  check "$1: 덩어리 없음" "$(blk)" ""
  check "$1: 문맥이 편집 없는 문맥과 바이트로 같다" "$ctx" "$base"
}
# count_in_block <text> — how many lines of the block carry the text.
count_in_block() { blk | grep -c -F -e "$1" || true; }

# the positive control: a new bullet without a marker
after '- [대화형] alpha kept rule
- [대화형] brand new rule
'
hook_run "$(ep Edit "$(eo '- [대화형] alpha kept rule' '- [대화형] alpha kept rule
- [대화형] brand new rule')")"
spoke "새 불릿 Edit"
has "새 불릿 Edit: 덩어리가 있다" "$(blk)" "Rule enforcement check:"
has "새 불릿 Edit: 덩어리에 새 불릿" "$(blk)" "line 2${TB}brand new rule${TB}no marker"
check "새 불릿 Edit: old_string 으로 잡은 앞 불릿은 덩어리에 없다" "$(count_in_block 'alpha kept rule')" "0"
check "새 불릿 Edit: 끝 표시 없음" "$(count_in_block '[and ')" "0"
has "새 불릿 Edit: 덩어리는 상태 뒤에 붙는다" "${ctx%%Rule enforcement check:*}" "Status ("

# a Write carries only the number of targets in the whole file
after '- [대화형] write one
- [대화형] write two
- [대화형] write three
    산문: decided
'
hook_run "$(ep Write "$(jq -cn --arg c "$(cat "$CFG/CLAUDE.md")" '{content: $c}')")"
spoke "Write"
has "Write: 대상 수 2" "$(blk)" "This file has 2 rule(s) that the check above applies to"
check "Write: 대상 줄을 늘어놓지 않는다" "$(count_in_block 'write one')" "0"
after '- [대화형] write one
    산문: decided
'
base_ctx "산문 Write"
hook_run "$(ep Write "$(jq -cn --arg c "$(cat "$CFG/CLAUDE.md")" '{content: $c}')")"
same_as_base "모든 불릿이 산문인 Write"

# a new bullet with a prose marker, and an edit without new_string
after '- [대화형] alpha kept rule
- [대화형] decided rule
    산문: no means yet
'
base_ctx "산문 새 불릿"
hook_run "$(ep Edit "$(eo '- [대화형] alpha kept rule' '- [대화형] alpha kept rule
- [대화형] decided rule
    산문: no means yet')")"
same_as_base "산문 표지 새 불릿 Edit"
hook_run "$(ep Edit '{"old_string": "x"}')"
same_as_base "new_string 없는 Edit"

# past the status cap: the block stays whole and the status is cut
{
  printf -- '- [무인] alpha rule one\n'
  i=1
  while [ "$i" -le 400 ]; do
    printf -- '- padding item %d with a few more words to list\n' "$i"
    i=$((i + 1))
  done
  printf -- '- [대화형] the very new rule\n'
} > "$CFG/CLAUDE.md"
hook_run "$(ep Edit "$(eo '- padding item 400 with a few more words to list' '- padding item 400 with a few more words to list
- [대화형] the very new rule')")"
spoke "잘린 상태와 덩어리"
has "잘린 상태와 덩어리: 상태가 잘린다" "$ctx" "[truncated: run bash \"$PLUG/orchestrator/stage-rules.sh\" status for the full status]"
has "잘린 상태와 덩어리: 덩어리가 온전하다" "$(blk)" "line 402${TB}the very new rule${TB}no marker"

# the 2000-byte block cap, ASCII and Korean
mkmany() { # mkmany <count> <text prefix>
  local i=1
  while [ "$i" -le "$1" ]; do
    printf -- '- [대화형] %s %03d\n' "$2" "$i"
    i=$((i + 1))
  done
}
block_bytes() { blk | LC_ALL=C wc -c | tr -d ' '; }
cap_case() { # cap_case <label> <count> <text prefix>
  local new shown
  new=$(mkmany "$2" "$3")
  after "- [대화형] anchor rule
    산문: decided
$new
"
  hook_run "$(ep Edit "$(eo '' "$new")")"
  spoke "$1"
  check "$1: 덩어리 2000 바이트 이하" "$([ "$(block_bytes)" -le 2000 ] && echo yes || echo no)" "yes"
  shown=$(count_in_block "${TB}no marker")
  has "$1: 끝 표시가 담지 못한 줄 수" "$(blk)" "[and $(( $2 - shown )) more: run bash \"$PLUG/orchestrator/stage-rules.sh\" enforcement]"
  check "$1: 담은 줄이 있다" "$([ "$shown" -gt 0 ] && echo yes || echo no)" "yes"
}
cap_case "2000 바이트 상한" 60 "a fairly long rule text to fill the block"
cap_case "2000 바이트 상한 한글" 60 "한글로 된 꽤 긴 규칙 문면으로 덩어리를 채운다"
LONGP=$(printf '%01500d' 0)
after "- [대화형] long one
    강제: 훅 /no-such-dir/$LONGP
- [대화형] long two
    강제: 훅 /no-such-dir/$LONGP
"
hook_run "$(ep Edit "$(eo '' "$(cat "$CFG/CLAUDE.md")")")"
spoke "첫 줄부터 못 담는 덩어리"
check "첫 줄부터 못 담는 덩어리: 머리와 끝 표시만" "$(blk | grep -c '' || true)" "2"
has "첫 줄부터 못 담는 덩어리: n 은 대상 줄 전체 수" "$(blk)" "[and 2 more: run "

# MultiEdit
after '- [대화형] multi kept one
    산문: decided
- [대화형] multi new rule
'
hook_run "$(ep MultiEdit "$(jq -cn --argjson a "$(eo 'multi kept zero' 'multi kept one')" \
  --argjson b "$(eo '    산문: decided' '    산문: decided
- [대화형] multi new rule')" '{edits: [$a, $b]}')")"
spoke "MultiEdit"
has "MultiEdit: 새 불릿만 덩어리에 있다" "$(blk)" "line 3${TB}multi new rule${TB}no marker"
check "MultiEdit: 다른 항목의 불릿은 없다" "$(count_in_block 'multi kept one')" "0"
base_ctx "edits 없는 MultiEdit"
hook_run "$(ep MultiEdit '{}')"
same_as_base "edits 없는 MultiEdit"

# edits of part of a line
after '- [대화형] keep rule one
    산문: decided
- [대화형] word rule omega
'
hook_run "$(ep Edit "$(eo 'alpha' 'omega')")"
spoke "첫 줄 낱말 하나"
has "첫 줄 낱말 하나: 그 불릿이 찍힌다" "$(blk)" "line 3${TB}word rule omega${TB}no marker"
after '- [대화형] keep rule one
    산문: decided
- [대화형] 낱말 규칙 다라
'
hook_run "$(ep Edit "$(eo '가나' '다라')")"
spoke "첫 줄 한글 낱말 하나"
has "첫 줄 한글 낱말 하나: 그 불릿이 찍힌다" "$(blk)" "line 3${TB}낱말 규칙 다라${TB}no marker"
after '- keep rule one
    산문: decided
- [무인] newly unattended
'
hook_run "$(ep Edit "$(eo '- newly' '- [무인] newly')")"
spoke "태그 끼우기"
has "태그 끼우기: 그 불릿이 찍힌다" "$(blk)" "line 3${TB}newly unattended${TB}no marker"
after '- [대화형] anchored rule
    강제: 훅 plugin:hooks/guard.sh#nope
'
hook_run "$(ep Edit "$(eo '#push' '#nope')")"
spoke "앵커 고치기"
has "앵커 고치기: 죽은 수단 사유와 함께 찍힌다" "$(blk)" \
  "line 1${TB}anchored rule${TB}means lost; dead 훅 plugin:hooks/guard.sh#nope anchor not found"
after '- [대화형] b two
- [대화형] b one
'
base_ctx "순서 바꾸기"
hook_run "$(ep Edit "$(eo '- [대화형] b one
- [대화형] b two' '- [대화형] b two
- [대화형] b one')")"
same_as_base "한 편집 안의 순서 바꾸기"
after '- [대화형] cont rule
    the changed continuation words
'
base_ctx "연속 줄"
hook_run "$(ep Edit "$(eo 'continuation old' 'changed continuation')")"
same_as_base "연속 줄 낱말"
after '- [대화형] ctx twin rule
    강제: 훅 plugin:hooks/none.sh
- [대화형] new twin rule
    강제: 훅 plugin:hooks/none.sh
'
hook_run "$(ep Edit "$(eo '- [대화형] ctx twin rule
    강제: 훅 plugin:hooks/none.sh' '- [대화형] ctx twin rule
    강제: 훅 plugin:hooks/none.sh
- [대화형] new twin rule
    강제: 훅 plugin:hooks/none.sh')")"
spoke "문맥과 같은 표지 줄"
has "문맥과 같은 표지 줄: 새 불릿이 찍힌다" "$(blk)" "line 3${TB}new twin rule${TB}means lost"
after '- [대화형] keep rule one
    산문: decided
- [대화형] moved rule
'
hook_run "$(ep MultiEdit "$(jq -cn --argjson a "$(eo '- [대화형] moved rule
' '')" --argjson b "$(eo '    산문: decided' '    산문: decided
- [대화형] moved rule')" '{edits: [$a, $b]}')")"
spoke "MultiEdit 지우고 더하기"
has "MultiEdit 지우고 더하기: 더한 불릿이 찍힌다" "$(blk)" "line 3${TB}moved rule${TB}no marker"
after '- [대화형] has foo here
    산문: decided
- [대화형] also foo there
    산문: decided
- [대화형] bare rule elsewhere
'
hook_run "$(ep Edit "$(eo 'bar' 'foo')")"
spoke "두 번 있는 짧은 new_string"
check "두 번 있는 짧은 new_string: 덩어리 없음" "$(blk)" ""

# the remaining branches the decision names
after '- [대화형] zz word and zz again
'
hook_run "$(ep Edit '{"old_string": "yy", "new_string": "zz", "replace_all": true}')"
spoke "replace_all"
check "replace_all: 그 불릿이 한 번 찍힌다" "$(count_in_block 'zz word and zz again')" "1"
after '- [대화형] numeric rule
'
base_ctx "문자열 아닌 new_string"
hook_run "$(ep Edit '{"old_string": "x", "new_string": 5}')"
same_as_base "문자열 아닌 new_string"
after '- [대화형] alpha kept rule
    산문: decided
- [대화형] no old rule
'
hook_run "$(ep Edit '{"new_string": "- [대화형] no old rule"}')"
spoke "old_string 없음"
has "old_string 없음: 새 불릿이 찍힌다" "$(blk)" "line 3${TB}no old rule${TB}no marker"
after '- [대화형] far rule
    강제: 훅 plugin:hooks/none.sh
- [대화형] near rule
    산문: decided
- [대화형] near new rule
    강제: 훅 plugin:hooks/none.sh
'
hook_run "$(ep Edit "$(eo '    산문: decided' '    산문: decided
- [대화형] near new rule
    강제: 훅 plugin:hooks/none.sh')")"
spoke "먼 불릿의 같은 표지 줄"
has "먼 불릿의 같은 표지 줄: 새 불릿" "$(blk)" "line 5${TB}near new rule${TB}means lost"
has "먼 불릿의 같은 표지 줄: 먼 불릿" "$(blk)" "line 1${TB}far rule${TB}means lost"
after '- [대화형] locked rule
'
chmod 000 "$CFG/CLAUDE.md"
if [ -r "$CFG/CLAUDE.md" ]; then
  echo "SKIP: 읽을 수 없는 편집 파일 — 이 사용자는 권한을 걷어도 읽는다 (root)"
else
  hook_run "$(ep Edit "$(eo 'x' '- [대화형] locked rule')")"
  check "읽을 수 없는 편집 파일: rc 0" "$HOOK_RC" "0"
  check "읽을 수 없는 편집 파일: stderr 비어 있음" "$(err_bytes)" "0"
  check "읽을 수 없는 편집 파일: 덩어리 없음" \
    "$(grep -c 'Rule enforcement check:' "$OUTF" || true)" "0"
fi
chmod 600 "$CFG/CLAUDE.md"

# a deleted marker line picks the bullet that held it
after '- [대화형] marked rule
- [대화형] next rule
    산문: decided
'
hook_run "$(ep Edit "$(eo '- [대화형] marked rule
    강제: 훅 plugin:hooks/guard.sh' '- [대화형] marked rule')")"
spoke "강제 줄 삭제"
has "강제 줄 삭제: 그 불릿이 no marker 로 찍힌다" "$(blk)" "line 1${TB}marked rule${TB}no marker"
check "강제 줄 삭제: 다음 불릿은 없다" "$(count_in_block 'next rule')" "0"
hook_run "$(ep Edit "$(eo '- [대화형] marked rule
    산문: decided' '- [대화형] marked rule')")"
spoke "산문 줄 삭제"
has "산문 줄 삭제: 그 불릿이 찍힌다" "$(blk)" "line 1${TB}marked rule${TB}no marker"
after '- [대화형] two means rule
    강제: 훅 plugin:hooks/none.sh
'
hook_run "$(ep Edit "$(eo '- [대화형] two means rule
    강제: 훅 plugin:hooks/guard.sh
    강제: 훅 plugin:hooks/none.sh' '- [대화형] two means rule
    강제: 훅 plugin:hooks/none.sh')")"
spoke "살아 있는 강제 줄 삭제"
has "살아 있는 강제 줄 삭제: means lost" "$(blk)" "line 1${TB}two means rule${TB}means lost"
after '- [대화형] still guarded rule
    강제: 린트 plugin:hooks/guard.sh
'
base_ctx "여전히 enforced"
hook_run "$(ep Edit "$(eo '- [대화형] still guarded rule
    강제: 훅 plugin:hooks/guard.sh
    강제: 린트 plugin:hooks/guard.sh' '- [대화형] still guarded rule
    강제: 린트 plugin:hooks/guard.sh')")"
same_as_base "표지 줄을 지워도 enforced"
after '- [대화형] marked rule
- [대화형] next rule
    산문: decided
'
base_ctx "받아들인 한계"
hook_run "$(ep Edit "$(eo '    강제: 훅 plugin:hooks/guard.sh
' '')")"
same_as_base "받아들인 한계: new_string 이 빈 표지 줄 삭제"
after '- [대화형] dup head
- [대화형] dup head x
    산문: decided
'
base_ctx "받아들인 한계 둘"
hook_run "$(ep Edit "$(eo '- [대화형] dup head
    강제: 훅 plugin:hooks/guard.sh' '- [대화형] dup head')")"
same_as_base "받아들인 한계: 두 번 있는 new_string 의 표지 줄 삭제"
after '- [대화형] keep rule one
    산문: decided
- [대화형] multi marked rule
'
hook_run "$(ep MultiEdit "$(jq -cn --argjson a "$(eo 'keep rule zero' 'keep rule one')" \
  --argjson b "$(eo '- [대화형] multi marked rule
    강제: 훅 plugin:hooks/guard.sh' '- [대화형] multi marked rule')" '{edits: [$a, $b]}')")"
spoke "MultiEdit 표지 줄 삭제"
has "MultiEdit 표지 줄 삭제: 그 불릿이 찍힌다" "$(blk)" "line 3${TB}multi marked rule${TB}no marker"

echo "test-stage-rules-edit-hook: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
