#!/usr/bin/env bash
# Test the session title hook — plugins/cc-cmds/hooks/session-title.sh.
#
# The hook is driven the way the harness drives it — a `UserPromptSubmit` JSON
# payload on stdin — and the exit status, stdout, stderr and the two state
# directories are read back. "Quiet" is rc 0 with nothing on stdout or stderr;
# "titled X" is rc 0, empty stderr, and exactly one stdout line whose
# `hookSpecificOutput` names `UserPromptSubmit` and carries `sessionTitle == X`.
#
# EVERY CASE GETS ITS OWN SCRATCH ROOT (`fresh`): `HOME`, `XDG_STATE_HOME`,
# `CLAUDE_CONFIG_DIR`, `CLAUDE_PLUGIN_ROOT` and the project directory all live
# under it. The `/clear` adoption lookup reads every file in the ownership
# directory, so one case's file left in a shared directory would decide the
# next case.
#
# THE PIPELINE MARKERS AND THE SWITCH ARE UNSET FOR EVERY RUN except the cases
# that set them, so the suite means the same inside an unattended stage.
#
# THE POSITIVE CONTROL COMES FIRST. A suite that only measures silence is green
# against a hook that never speaks.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
HOOK="$repo_root/plugins/cc-cmds/hooks/session-title.sh"
HOOKS_JSON="$repo_root/plugins/cc-cmds/hooks/hooks.json"

passed=0
failed=0
ok()   { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook parses JSON and nothing can be driven without it"
  echo "test-session-title-hook: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-session-title-hook.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

OUTF="$WORK/hook.out"
ERR="$WORK/hook.err"
TITLES="$WORK/titles"
: > "$TITLES"

# fresh — a new scratch root for one case; sets s, OWN, NOW, PCWD.
fresh() {
  s=$(mktemp -d "$WORK/case.XXXXXX")
  mkdir -p "$s/home" "$s/state" "$s/cfg" "$s/plugin" "$s/proj"
  OWN="$s/state/cc-cmds/session-title"
  NOW="$s/state/cc-cmds/session-title-now"
  PCWD="$s/proj"
}

# pl <sid> <prompt> [<session title>] — the payload; no third argument means the
# `session_title` key is absent, as the harness sends it for an untitled session.
pl() {
  if [ "$#" -ge 3 ]; then
    jq -cn --arg s "$1" --arg p "$2" --arg c "$PCWD" --arg t "$3" \
      '{session_id: $s, hook_event_name: "UserPromptSubmit", prompt: $p, cwd: $c, session_title: $t}'
  else
    jq -cn --arg s "$1" --arg p "$2" --arg c "$PCWD" \
      '{session_id: $s, hook_event_name: "UserPromptSubmit", prompt: $p, cwd: $c}'
  fi
}

# hook_run <stdin> [<env assignment>...] — sets HOOK_RC; output in OUTF / ERR.
# Runs from the case root, so a relative `cwd` would resolve there if the hook
# ever accepted one.
hook_run() {
  local input="$1"; shift
  ( cd "$s" && printf '%s' "$input" | env -u CC_PIPELINE_RUN_ID -u CC_PIPELINE_SEGMENT \
      -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID -u CC_CMDS_SESSION_TITLE \
      HOME="$s/home" XDG_STATE_HOME="$s/state" CLAUDE_CONFIG_DIR="$s/cfg" \
      CLAUDE_PLUGIN_ROOT="$s/plugin" CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 "$@" \
      bash "$HOOK" > "$OUTF" 2> "$ERR" )
  HOOK_RC=$?
}
out_bytes() { wc -c < "$OUTF" | tr -d ' '; }
err_bytes() { wc -c < "$ERR" | tr -d ' '; }

quiet() {
  check "$1: rc 0" "$HOOK_RC" "0"
  check "$1: stdout 비어 있음" "$(out_bytes)" "0"
  check "$1: stderr 비어 있음" "$(err_bytes)" "0"
}

titled() {
  local got
  check "$1: rc 0" "$HOOK_RC" "0"
  check "$1: stderr 비어 있음" "$(err_bytes)" "0"
  check "$1: stdout 한 줄" "$(wc -l < "$OUTF" | tr -d ' ')" "1"
  check "$1: hookEventName" \
    "$(jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' "$OUTF" 2>/dev/null)" "true"
  got=$(jq -r '.hookSpecificOutput.sessionTitle' "$OUTF" 2>/dev/null)
  check "$1: 제목" "$got" "$2"
  printf '%s\n' "$got" >> "$TITLES"
}

# file_is <label> <path> <line>... — the file holds exactly those lines.
file_is() {
  local label="$1" path="$2"
  shift 2
  printf '%s\n' "$@" > "$WORK/expect"
  if cmp -s "$WORK/expect" "$path"; then ok "$label"; else
    bad "$label" "$(cat "$path" 2>/dev/null || echo '(없음)')"
  fi
}
absent() { if [ -e "$2" ]; then bad "$1" "$2 이 있다"; else ok "$1"; fi; }
same_file() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "바이트가 달라졌다"; fi; }
# mtime by perl lstat — the portability lint keeps `stat -f`/`stat -c` out.
mt() { perl -e 'print +(lstat $ARGV[0])[9]' "$1"; }
own_with() { mkdir -p "$OWN"; printf '%s\n' "$@" > "$OWN/$sid"; }
now_with() { mkdir -p "$NOW"; printf '%s\n' "$@" > "$NOW/$sid"; }

L='review·#1085'
S1='cc-session-title v1'
N1='cc-session-title-now v1'

# 1. positive control
fresh; sid=c01
hook_run "$(pl "$sid" '/cc-cmds:autopilot docs/x.md')"
titled "1 양성 대조" 'autopilot·x'
file_is "1 상태 파일" "$OWN/$sid" "$S1" 'autopilot·x'

# 2-4. not a target
fresh; sid=c02
hook_run "$(pl "$sid" 'hello world')"
quiet "2 평문 프롬프트"
absent "2 소유 상태 파일 없음" "$OWN/$sid"

fresh; sid=c03
hook_run "$(pl "$sid" '  /cc-cmds:ask x')"
quiet "3 앞 공백"

fresh; sid=c04
hook_run "$(pl "$sid" '/Users/x/foo bar')"
quiet "4 경로 꼴 프롬프트"
absent "4 소유 상태 파일 없음" "$OWN/$sid"

# 5. someone else's title, no state
fresh; sid=c05
hook_run "$(pl "$sid" '/cc-cmds:review 1085' '내 작업')"
quiet "5 상태 없이 남의 제목"
file_is "5 해제 기록" "$OWN/$sid" "$S1" '!released'

# 6. released is final
fresh; sid=c06
own_with "$S1" '!released'
cp "$OWN/$sid" "$WORK/c06.before"
for t in '' '내 작업' "$L"; do
  hook_run "$(pl "$sid" '/cc-cmds:review 1085' "$t")"
  quiet "6 해제 고정 (T='$t')"
  same_file "6 해제 파일 그대로 (T='$t')" "$WORK/c06.before" "$OWN/$sid"
done

# 7. own title, exact match
fresh; sid=c07
own_with "$S1" "$L"
hook_run "$(pl "$sid" '/cc-cmds:implement docs/a.md' "$L")"
titled "7 자기 제목 정확 일치" 'implement·a'
file_is "7 상태에 새 제목" "$OWN/$sid" "$S1" "$L" 'implement·a'

fresh; sid=c07b
own_with "$S1" 'ask·one' 'ask·two' 'ask·three' 'ask·four'
hook_run "$(pl "$sid" '/cc-cmds:implement docs/a.md' 'ask·four')"
titled "7 넷이 찬 상태" 'implement·a'
file_is "7 가장 오래된 것이 빠짐" "$OWN/$sid" "$S1" 'ask·two' 'ask·three' 'ask·four' 'implement·a'

# 8. repeats
for t in "$L" "$L-bright-brook"; do
  fresh; sid=c08
  own_with "$S1" "$L"
  cp "$OWN/$sid" "$WORK/c08.before"
  hook_run "$(pl "$sid" '/cc-cmds:review 1085' "$t")"
  quiet "8 되풀이 (T='$t')"
  same_file "8 파일 그대로 (T='$t')" "$WORK/c08.before" "$OWN/$sid"
done

# 9. uniqueness suffix rows
for t in "$L-calm-fox" "$L-calm-fox-12" "$L-calm-fox-1234"; do
  fresh; sid=c09
  own_with "$S1" "$L"
  hook_run "$(pl "$sid" '/cc-cmds:ask x' "$t")"
  titled "9 자기 것 (T='$t')" 'ask·x'
done
for t in "$L-Calm-Fox" "$L-fox" "$L-calm-fox-12345" "$L-2" "$L 재검토" 'X-calm-fox'; do
  fresh; sid=c09
  own_with "$S1" "$L"
  hook_run "$(pl "$sid" '/cc-cmds:ask x' "$t")"
  quiet "9 남의 것 (T='$t')"
  file_is "9 해제 (T='$t')" "$OWN/$sid" "$S1" '!released'
done

# 10. built-in commands
for p in '/rename foo' '/clear' '/model x'; do
  fresh; sid=c10
  own_with "$S1" "$L"
  cp "$OWN/$sid" "$WORK/c10.before"
  hook_run "$(pl "$sid" "$p" "$L")"
  quiet "10 내장 명령 '$p'"
  same_file "10 상태 그대로 '$p'" "$WORK/c10.before" "$OWN/$sid"
  sid=c10b
  hook_run "$(pl "$sid" "$p")"
  quiet "10 내장 명령 '$p' (파일 없음)"
  absent "10 없던 파일은 생기지 않음 '$p'" "$OWN/$sid"
done

# 11. bare-name resolution: each of the five places on its own
fresh
for place in "plugin/skills/foo/SKILL.md" "cfg/skills/foo/SKILL.md" "cfg/commands/foo.md" \
             "proj/.claude/skills/foo/SKILL.md" "proj/.claude/commands/foo.md"; do
  mkdir -p "$(dirname "$s/$place")"
  : > "$s/$place"
  sid=c11; rm -rf "$OWN"
  hook_run "$(pl "$sid" '/foo bar')"
  titled "11 맨 이름 풀이 ($place)" 'foo·bar'
  rm -f "$s/$place"
done
mkdir -p "$s/proj/.claude/commands"
: > "$s/proj/.claude/commands/foo.md"
sid=c11; rm -rf "$OWN"
hook_run "$(pl "$sid" '/fooo bar')"
quiet "11 풀리지 않는 이름"
PCWD=proj
hook_run "$(pl "$sid" '/foo bar')"
quiet "11 절대 경로가 아닌 cwd"
PCWD="$s/proj"
for p in '/..' '/.x'; do
  hook_run "$(pl "$sid" "$p")"
  quiet "11 정규식에 걸리지 않는 '$p'"
done

# 12. summary rules, one rule per case
while IFS='|' read -r args want; do
  fresh; sid=c12
  hook_run "$(pl "$sid" "/cc-cmds:ask $args")"
  titled "12 요약 규칙 '$args'" "$want"
done <<'EOF'
--x v rest|ask·rest
--declared-files "a b" rest|ask·rest
--x=v rest|ask·rest
--recover --scratch-dir d rest|ask·rest
https://github.com/o/r/pull/1085|ask·#1085
https://github.com/o/r/issues/77|ask·#77
1085|ask·#1085
5m|ask·5m
/a/b/doc.md|ask·doc
20261001-b8806f18-A|ask·b8806f18-A
"quoted words" 'single q'|ask·quoted words single q
세그먼트 A (사이클 1)|ask·세그먼트 A (사이클 1)
EOF

# 13. stage environment has no effect
fresh
hook_run "$(pl c13 '/cc-cmds:review 1085')"
cp "$OUTF" "$WORK/c13.plain.out"
hook_run "$(pl c13s '/cc-cmds:review 1085')" CC_PIPELINE_RUN_ID=20261001-b8806f18 \
  CC_PIPELINE_SEGMENT=A CC_PIPELINE_STAGE_ID='A#1'
same_file "13 스테이지 환경: 표준 출력" "$WORK/c13.plain.out" "$OUTF"
same_file "13 스테이지 환경: 상태 파일" "$OWN/c13" "$OWN/c13s"

# 14. stage prompt shapes (the run.sh templates with fixed values)
while IFS='|' read -r p want; do
  fresh; sid=c14
  hook_run "$(pl "$sid" "$p")"
  titled "14 스테이지 프롬프트 '$want'" "$want"
done <<'EOF'
/cc-cmds:design-discuss-unattended /Users/x/repo/docs/session-title-hook.md 세션 식별 표시|design-discuss-unattended·session-titl
/cc-cmds:design-audit-unattended /Users/x/repo/docs/session-title-hook.md|design-audit-unattended·session-title-
/cc-cmds:implement-unattended anchor-brief "세그먼트 A (사이클 1) · 선언 파일: a.sh, b.sh"|implement-unattended·anchor-brief 세그
/cc-cmds:implement-unattended /Users/x/repo/docs/session-title-hook.md "세그먼트 A (사이클 1) · 선언 파일: a.sh"|implement-unattended·session-title-hoo
/cc-cmds:review-unattended seg/20261001-b8806f18-A --recover --scratch-dir /tmp/a,/tmp/b --report-path /tmp/r.md "설계는 /Users/x/repo/docs/session-title-hook.md"|review-unattended·b8806f18-A 설계는 se
EOF

# 15. width. The fixed rows run against the hook's own `cw`/`cut` lines.
defs=$(grep -E '^def (cw:|cut\()' "$HOOK")
check "15 cw·cut 정의가 한 줄씩" "$(printf '%s\n' "$defs" | wc -l | tr -d ' ')" "2"
cutn() { jq -rn --arg s "$1" --argjson n "$2" "$defs"' $s | cut($n)'; }
cells() { jq -rn --arg s "$1" "$defs"' [$s | explode[] | cw] | add // 0'; }
check "15 고정 결과 1" "$(cutn 'autopilot·가나다라마바사아자차카타파하거너더' 38)" 'autopilot·가나다라마바사아자차카타파하'
check "15 고정 결과 2" "$(cutn 'autopilot·abcdefghijklmnopqrstuvwxyz0123456789' 38)" 'autopilot·abcdefghijklmnopqrstuvwxyz01'
check "15 고정 결과 3" "$(cutn 'implement·가 나다' 13)" 'implement·가'
check "15 고정 결과 4" "$(cutn 'implement·가a나' 12)" 'implement·가'
fresh; sid=c15
hook_run "$(pl "$sid" '/cc-cmds:autopilot 가나다라마바사아자차카타파하거너더')"
titled "15 한글 꼬리 자르기" 'autopilot·가나다라마바사아자차카타파하'
fresh; sid=c15
hook_run "$(pl "$sid" '/cc-cmds:autopilot abcdefghijklmnopqrstuvwxyz0123456789')"
titled "15 ASCII 꼬리 자르기" 'autopilot·abcdefghijklmnopqrstuvwxyz01'
long=""
i=0
while [ "$i" -lt 200 ]; do long="${long}가"; i=$((i + 1)); done
fresh; sid=c15
hook_run "$(pl "$sid" "/cc-cmds:ask $long")"
got=$(jq -r '.hookSpecificOutput.sessionTitle' "$OUTF" 2>/dev/null)
printf '%s\n' "$got" >> "$TITLES"
check "15 200음절 인자: 38칸 이하" "$([ "$(cells "$got")" -le 38 ] && echo yes || echo no)" "yes"
check "15 200음절 인자: 넣을 수 있는 만큼" "$(cells "$got")" "38"
fresh; sid=c15
hook_run "$(pl "$sid" '/cc-cmds:abcdefghijklmnopqrstuvwxyz0123456789abcdefghi x')"
titled "15 45자 이름" 'abcdefghijklmnopqrstuvwxyz0123456789ab'

# 16. normalisation
ctl=$(printf 'a\tb\rc\302\205d\342\200\250e\342\200\213f\302\255g\342\200\256h\342\201\246i\363\240\201\201j')
fresh; sid=c16
hook_run "$(pl "$sid" "/cc-cmds:ask $ctl")"
titled "16 정규화 집합" 'ask·a b c d e f g h i j'
got=$(jq -r '.hookSpecificOutput.sessionTitle' "$OUTF" 2>/dev/null)
check "16 집합의 문자가 남지 않음" \
  "$(jq -rn --arg s "$got" '[$s | explode[] | select(. == 9 or . == 13 or . == 133 or . == 8232 or . == 8203 or . == 173 or . == 8238 or . == 8294 or . == 917569)] | length')" "0"
fresh; sid=c16
hook_run "$(pl "$sid" "/cc-cmds:ask $(printf '\343\200\200x y\302\240')")"
titled "16 양 끝 U+3000·U+00A0" 'ask·x y'

# 17. the switch
for v in 0 off OFF false no; do
  fresh; sid=c17
  hook_run "$(pl "$sid" '/cc-cmds:review 1085' 'x')" CC_CMDS_SESSION_TITLE="$v"
  quiet "17 스위치 끔 '$v'"
  absent "17 상태 없음 '$v'" "$OWN/$sid"
  absent "17 현재 제목 파일 없음 '$v'" "$NOW/$sid"
done
for v in 1 yes ''; do
  fresh; sid=c17
  hook_run "$(pl "$sid" '/cc-cmds:review 1085')" CC_CMDS_SESSION_TITLE="$v"
  titled "17 스위치 켬 '$v'" "$L"
done

# 18. schema mismatch
fresh; sid=c18
own_with 'cc-session-title v0' "$L"
hook_run "$(pl "$sid" '/cc-cmds:ask x')"
titled "18 v0 파일, 빈 T" 'ask·x'
file_is "18 v1 로 다시 씀" "$OWN/$sid" "$S1" 'ask·x'
fresh; sid=c18
own_with 'cc-session-title v0' "$L"
hook_run "$(pl "$sid" '/cc-cmds:ask x' "$L")"
quiet "18 v0 파일, T = L"

# 19. /clear adoption
adopt_case() {  # <label> <T> <prompt> <other line>...
  local label="$1" t="$2" p="$3"
  shift 3
  fresh; sid=new-sid
  mkdir -p "$OWN"
  printf '%s\n' "$@" > "$OWN/other-sid"
  hook_run "$(pl "$sid" "$p" "$t")"
}
adopt_case a "$L" '/cc-cmds:ask x' "$S1" "$L"
titled "19a T = L 채택" 'ask·x'
file_is "19a 새 파일" "$OWN/new-sid" "$S1" "$L" 'ask·x'
adopt_case b "$L-bright-brook" '/cc-cmds:ask x' "$S1" "$L"
titled "19b 접미사 붙은 T 채택" 'ask·x'
adopt_case c "$L" '/cc-cmds:ask x' "$S1" '!released' "$L"
quiet "19c 해제된 파일"
file_is "19c 해제" "$OWN/new-sid" "$S1" '!released'
adopt_case d "$L" '/cc-cmds:ask x' 'cc-session-title v0' "$L"
quiet "19d 스키마 v0"
adopt_case e "$S1" '/cc-cmds:ask x' "$S1" "$L"
quiet "19e T = 스키마 줄"
file_is "19e 해제" "$OWN/new-sid" "$S1" '!released'
adopt_case f '!released' '/cc-cmds:ask x' "$S1" '!released'
quiet "19f T = !released"
fresh; sid=new-sid
mkdir -p "$OWN"
printf '%s\n' "$S1" "$L" > "$OWN/.other-sid.AbCdEf"
hook_run "$(pl "$sid" '/cc-cmds:ask x' "$L")"
quiet "19g 점 파일에만 있음"
file_is "19g 해제" "$OWN/new-sid" "$S1" '!released'
adopt_case h 'ask·x' '/cc-cmds:ask x' "$S1" 'ask·x'
quiet "19h 채택 뒤 되풀이"
absent "19h 소유 상태 파일이 생기지 않음" "$OWN/new-sid"
adopt_case i "$L" '/cc-cmds:ask x' "$S1" "$L" 'ask·y'
quiet "19i 마지막이 아닌 줄"
file_is "19i 해제" "$OWN/new-sid" "$S1" '!released'

# 20. no jq: the whole PATH is a directory holding only bash
BASH_BIN=$(command -v bash 2>/dev/null || true)
fresh; sid=c20
mkdir -p "$s/bin-nj"
ln -s "$BASH_BIN" "$s/bin-nj/bash"
hook_run "$(pl "$sid" '/cc-cmds:review 1085')" PATH="$s/bin-nj"
quiet "20 jq 없음"
absent "20 상태 없음" "$OWN/$sid"

# 21. not JSON, empty stdin
fresh
hook_run 'not json'
quiet "21 JSON 아님"
hook_run ''
quiet "21 빈 표준 입력"

# 22. bad session ids
fresh
before=$(cd "$s/state" && find . | LC_ALL=C sort)
hook_run "$(pl '' '/cc-cmds:review 1085' '내 작업')"
quiet "22 빈 id"
hook_run '{"hook_event_name":"UserPromptSubmit","prompt":"/cc-cmds:review 1085","session_title":"x"}'
quiet "22 id 없음"
hook_run "$(pl '../x' '/cc-cmds:review 1085' '내 작업')"
quiet "22 '../x'"
hook_run "$(pl 'a/b' '/cc-cmds:review 1085' '내 작업')"
quiet "22 'a/b'"
check "22 상태 뿌리 그대로" "$(cd "$s/state" && find . | LC_ALL=C sort)" "$before"

# 23. agent_id
fresh; sid=c23
hook_run "$(pl "$sid" '/cc-cmds:review 1085' '내 작업' | jq -c '. + {agent_id: "a1"}')"
quiet "23 agent_id 있음"
absent "23 상태 없음" "$OWN/$sid"
absent "23 현재 제목 파일 없음" "$NOW/$sid"

# 24. XDG_STATE_HOME unset
fresh; sid=c24
( cd "$s" && printf '%s' "$(pl "$sid" '/cc-cmds:review 1085')" | env -u CC_PIPELINE_RUN_ID \
    -u CC_PIPELINE_SEGMENT -u CC_PIPELINE_STAGE_ID -u CC_PIPELINE_SHIFT_ID -u CC_CMDS_SESSION_TITLE \
    -u XDG_STATE_HOME HOME="$s/home" CLAUDE_CONFIG_DIR="$s/cfg" CLAUDE_PLUGIN_ROOT="$s/plugin" \
    CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1 bash "$HOOK" > "$OUTF" 2> "$ERR" )
HOOK_RC=$?
titled "24 XDG_STATE_HOME 없음" "$L"
file_is "24 HOME 아래 상태 파일" "$s/home/.local/state/cc-cmds/session-title/$sid" "$S1" "$L"

# 25 / 33. unwritable directories
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: 25·33 — root ignores directory modes"
else
  fresh; sid=c25
  mkdir -p "$OWN"; chmod 500 "$OWN"
  hook_run "$(pl "$sid" '/cc-cmds:review 1085')"
  quiet "25 쓸 수 없는 소유 상태 디렉터리"
  check "25 임시 파일이 남지 않음" "$(find "$OWN" -name ".$sid.*" | wc -l | tr -d ' ')" "0"
  chmod 700 "$OWN"

  fresh; sid=c33
  mkdir -p "$NOW"; chmod 500 "$NOW"
  hook_run "$(pl "$sid" '/cc-cmds:review 1085')"
  titled "33 쓸 수 없는 현재 제목 디렉터리" "$L"
  check "33 임시 파일이 남지 않음" "$(find "$NOW" -name ".$sid.*" | wc -l | tr -d ' ')" "0"
  chmod 700 "$NOW"
fi

# 26. the 30-day sweep, both directories
fresh; sid=c26
mkdir -p "$OWN" "$NOW"
for d in "$OWN" "$NOW"; do
  : > "$d/old-sid"; touch -t 202001010000 "$d/old-sid"
  : > "$d/new-sid"
done
hook_run "$(pl "$sid" 'hello world')"
quiet "26 조용한 호출"
for d in "$OWN" "$NOW"; do
  check "26 조용한 호출은 지우지 않음 ($(basename "$d"))" "$([ -e "$d/old-sid" ] && echo kept || echo gone)" "kept"
done
hook_run "$(pl "$sid" '/cc-cmds:review 1085')"
titled "26 내보내는 호출" "$L"
for d in "$OWN" "$NOW"; do
  check "26 오래된 형제 지워짐 ($(basename "$d"))" "$([ -e "$d/old-sid" ] && echo kept || echo gone)" "gone"
  check "26 새 형제 남음 ($(basename "$d"))" "$([ -e "$d/new-sid" ] && echo kept || echo gone)" "kept"
done

# 27. registration
check "27 UserPromptSubmit 항목 둘" "$(jq -r '.hooks.UserPromptSubmit | length' "$HOOKS_JSON")" "2"
check "27 session-title.sh 항목 하나, matcher 없음, timeout 5" \
  "$(jq -r '[.hooks.UserPromptSubmit[] | select(any(.hooks[]; .command | test("session-title\\.sh")))]
           | length == 1 and (.[0] | has("matcher") | not) and (.[0].hooks[0].timeout == 5)' "$HOOKS_JSON")" "true"
check "27 session-return-dismiss.sh 항목 하나" \
  "$(jq -r '[.hooks.UserPromptSubmit[] | select(any(.hooks[]; .command | test("session-return-dismiss\\.sh")))] | length' "$HOOKS_JSON")" "1"
check "27 실행 권한" "$([ -x "$HOOK" ] && echo yes || echo no)" "yes"

# 28. plain prompt with a user title
fresh; sid=c28
hook_run "$(pl "$sid" 'hello world' '내 작업')"
quiet "28 평문 프롬프트와 사용자 제목"
file_is "28 현재 제목 파일" "$NOW/$sid" "$N1" '내 작업'
absent "28 소유 상태 파일 없음" "$OWN/$sid"

# 31. same value again: bytes and mtime unchanged
cp "$NOW/$sid" "$WORK/c31.before"
touch -t 202001010000 "$NOW/$sid"
m0=$(mt "$NOW/$sid")
hook_run "$(pl "$sid" 'hello world' '내 작업')"
quiet "31 같은 값으로 다시"
same_file "31 바이트 그대로" "$WORK/c31.before" "$NOW/$sid"
check "31 mtime 그대로" "$(mt "$NOW/$sid")" "$m0"

# 37. removed by the sweep, then back on the next prompt
rm -f "$NOW/$sid"
hook_run "$(pl "$sid" 'hello world' '내 작업')"
quiet "37 지운 뒤 다시"
file_is "37 되살아남" "$NOW/$sid" "$N1" '내 작업'

# 29. the emitting path
fresh; sid=c29
hook_run "$(pl "$sid" '/cc-cmds:review 1085')"
titled "29 내보내는 경로" "$L"
file_is "29 현재 제목 파일" "$NOW/$sid" "$N1" "$L"

# 30. released session, a person's title
fresh; sid=c30
own_with "$S1" '!released'
hook_run "$(pl "$sid" '/cc-cmds:review 1085' '사람 이름')"
quiet "30 해제된 세션"
file_is "30 현재 제목 파일" "$NOW/$sid" "$N1" '사람 이름'

# 32. switch off leaves the current title file alone
fresh; sid=c32
hook_run "$(pl "$sid" 'hello world' '내 작업')" CC_CMDS_SESSION_TITLE=0
absent "32 파일이 없던 세션" "$NOW/$sid"
now_with "$N1" '옛 제목'
touch -t 202001010000 "$NOW/$sid"
cp "$NOW/$sid" "$WORK/c32.before"
m0=$(mt "$NOW/$sid")
hook_run "$(pl "$sid" 'hello world' '내 작업')" CC_CMDS_SESSION_TITLE=0
quiet "32 스위치 끔"
same_file "32 바이트 그대로" "$WORK/c32.before" "$NOW/$sid"
check "32 mtime 그대로" "$(mt "$NOW/$sid")" "$m0"

# 34. empty title removes the file
fresh; sid=c34
now_with "$N1" '옛 제목'
hook_run "$(pl "$sid" 'hello world' '')"
quiet "34 빈 T"
absent "34 파일 지워짐" "$NOW/$sid"

# 35. control characters in the title
fresh; sid=c35
hook_run "$(pl "$sid" 'hello world' "$(printf 'a\tb\n\nc\rd')")"
quiet "35 제어 문자 제목"
check "35 정확히 두 줄" "$(wc -l < "$NOW/$sid" | tr -d ' ')" "2"
file_is "35 연속이 공백 하나로" "$NOW/$sid" "$N1" 'a b c d'

# 36. wrong schema line
fresh; sid=c36
now_with 'cc-session-title-now v0' '내 작업'
hook_run "$(pl "$sid" 'hello world' '내 작업')"
quiet "36 스키마 줄 불일치"
file_is "36 다시 씀" "$NOW/$sid" "$N1" '내 작업'

# 15 (all cases). no emitted title ends with `·` or a space
bad_end=0
while IFS= read -r t; do
  case "$t" in *'·'|*' ') bad_end=$((bad_end + 1)) ;; esac
done < "$TITLES"
check "15 어떤 제목도 · 나 공백으로 끝나지 않음" "$bad_end" "0"

echo "test-session-title-hook: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
