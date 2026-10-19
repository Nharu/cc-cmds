#!/usr/bin/env bash
# Test the autopilot kickoff's target-hook check (orchestrator/kickoff-hook-probe.sh).
#
# WHAT THIS SUITE IS FOR. The helper is the only place a person learns, before
# the cutpoint is frozen, that a target's own Bash guard will refuse a command
# the run needs at that cutpoint. Its failure is silent in both directions: a
# reach it reports too high is a segment parked at night, and one it reports too
# low is a cutpoint the person lowers for nothing. So each guard of the shared
# fixtures (`scripts/target-guard-fixtures.sh`) is held to the reach and the
# question it must produce, and the session shell's resolution of a bare form's
# first word is held to the shell's own answer.
#
# Every helper call goes through `kh`, with the pipeline's variables removed:
# this suite runs inside implementation stages that inherit them, and the helper
# refuses outright there. Exactly one case calls it with one set, to assert that
# refusal. `SHELL`, `HOME` and `ZDOTDIR` point at empty fixture directories, so
# the host's shell start-up files cannot change a verdict.
#
# Usage: bash scripts/test-kickoff-hook-probe.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
ORCH="$repo_root/plugins/cc-cmds/orchestrator"
HELPER="$ORCH/kickoff-hook-probe.sh"
GATE="$ORCH/gate.sh"
SKILL="$repo_root/plugins/cc-cmds/skills/autopilot/SKILL.md"
BOUNDARIES="$repo_root/plugins/cc-cmds/skills/autopilot/references/boundaries.md"

# shellcheck disable=SC1091
. "$script_dir/target-guard-fixtures.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-kickoff-hook-probe-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()    { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { failed=$((failed + 1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

for v in $(compgen -e | grep -E '^CC_PIPELINE_' || true); do
  unset "$v"
done
CC_CMDS_AUTOPILOT_NOTIFY=0
export CC_CMDS_AUTOPILOT_NOTIFY
EMPTY="$WORK/empty-home"; mkdir -p "$EMPTY"
HOME="$EMPTY"; ZDOTDIR="$EMPTY"
BASH_PATH=$(command -v bash)
SHELL="$BASH_PATH"
export HOME ZDOTDIR SHELL
unset XDG_CONFIG_HOME

kh() { "$BASH" "$HELPER" "$@"; }
# probe <dir> <cutpoint> — the single-target call, where the root is the worktree.
probe() { kh --worktree "$1" --root "$1" --gate-path "$GATE" --cutpoint "$2"; }

reach()  { printf '%s\n' "$1" | awk -F'\t' '$1 == "닿는 칸" { print $2; exit }'; }
cls()    { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == "모양" && $3 == n { print $4; exit }'; }
wv()     { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == "모양" && $3 == n { print $5; exit }'; }
bv()     { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == "모양" && $3 == n { print $6; exit }'; }
nrows()  { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k' | grep -c . || true; }
question() { printf '%s\n' "$1" | awk -F'\t' '$1 == "질문" { print $2; exit }'; }

# The ladder, from the driver, so the test does not carry a copy of it either.
LADDER=$(CC_ORCH_SOURCE_ONLY=1 "$BASH" -c '. "$1" >/dev/null 2>&1; printf "%s" "$CUTPOINTS"' _ "$ORCH/run.sh")
TOP=${LADDER##* }
idx() { local i=0 c; for c in $LADDER; do i=$((i + 1)); [ "$c" = "$1" ] && { printf '%s' "$i"; return; }; done; printf '0'; }
at_least() {   # at_least <label> <reach> <cell>
  if [ "$2" != 없음 ] && [ "$(idx "$2")" -ge "$(idx "$3")" ]; then ok "$1"; else bad "$1" "reach '$2', want $3 or above"; fi
}
below() {      # below <label> <reach> <cell>
  if [ "$2" = 없음 ] || [ "$(idx "$2")" -lt "$(idx "$3")" ]; then ok "$1"; else bad "$1" "reach '$2', want below $3"; fi
}
Q_LOWER='이 대상의 Bash 훅 아래에서 런이 닿을 수 있는 칸은 커밋 이고 정한 절단점은 머지 입니다 — 쓸 수 없는 모양: '
Q_NONE='이 대상을 런에서 빼거나 킥오프를 멈출까요?'
starts() { case "$2" in "$3"*) ok "$1" ;; *) bad "$1" "got '$2'" ;; esac; }
ends()   { case "$2" in *"$3") ok "$1" ;; *) bad "$1" "got '$2'" ;; esac; }

# ---------------------------------------------------------------------------
# 거부와 인자
# ---------------------------------------------------------------------------
tgf_repo "$WORK/plain"
out=$(CC_PIPELINE_RUN_ID=x "$BASH" "$HELPER" --worktree "$WORK/plain" --root "$WORK/plain" --gate-path "$GATE" --cutpoint 머지 2>/dev/null); rc=$?
check "파이프라인 런 안에서는 3 으로 거부한다" "$rc" "3"
check "거부할 때 stdout 은 비어 있다" "$out" ""
out=$(kh 2>/dev/null); rc=$?
check "인자가 없으면 2" "$rc" "2"
check "인자 오류일 때 stdout 은 비어 있다" "$out" ""
kh --worktree plain --root "$WORK/plain" --gate-path "$GATE" --cutpoint 머지 >/dev/null 2>&1; rc=$?
check "상대 경로는 2" "$rc" "2"
kh --worktree "$WORK/plain" --root "$WORK/plain" --gate-path "$GATE" --cutpoint '머지 후 후속 착수' >/dev/null 2>&1; rc=$?
check "표시형 절단점은 2" "$rc" "2"
kh --worktree "$WORK/plain" --root "$WORK/plain" --gate-path "$GATE" --cutpoint 없는칸 >/dev/null 2>&1; rc=$?
check "어휘 밖 절단점은 2" "$rc" "2"
kh --worktree "$WORK/plain" --root "$WORK/plain" --gate-path "$GATE" --cutpoint 머지 --extra x >/dev/null 2>&1; rc=$?
check "모르는 인자는 2" "$rc" "2"

# ---------------------------------------------------------------------------
# 훅 없는 레포
# ---------------------------------------------------------------------------
out=$(probe "$WORK/plain" 머지); rc=$?
check "훅 없는 레포: 종료 0" "$rc" "0"
check "첫 줄은 판 머리" "$(printf '%s\n' "$out" | sed -n 1p)" "cc-kickoff-hook-probe v1"
check "훅 없는 레포: 대상 훅 없음" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "대상 훅" { print $2 }')" "없음"
check "훅 없는 레포: 최상위 칸까지 닿는다" "$(reach "$out")" "$TOP"
check "훅 없는 레포: 질문 행 없음" "$(nrows "$out" 질문)" "0"

# ---------------------------------------------------------------------------
# 풀 수 없는 가드 — 닿는 칸 커밋과 질문
# ---------------------------------------------------------------------------
tgf_repo "$WORK/nopush" guard_nopush.sh
out=$(probe "$WORK/nopush" 머지)
check "guard_nopush: 대상 훅 있음" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "대상 훅" { print $2 }')" "있음"
check "guard_nopush: 닿는 칸 커밋" "$(reach "$out")" "커밋"
check "guard_nopush: push 모양은 거절" "$(cls "$out" git-push)" "거절"
starts "guard_nopush: 고정된 질문 문면" "$(question "$out")" "$Q_LOWER"
case "$(question "$out")" in
  *'push/git-push 거절: '*'pushing is not allowed from this repository'*) ok "guard_nopush: 질문이 거절된 모양과 가드 문면을 인용한다" ;;
  *) bad "guard_nopush: 질문이 거절된 모양과 가드 문면을 인용한다" "$(question "$out")" ;;
esac
ends "guard_nopush: 질문은 내리자고 묻는다" "$(question "$out")" "절단점을 커밋 로 내릴까요, 머지 로 둘까요?"
out=$(probe "$WORK/nopush" 커밋)
check "guard_nopush: 정한 칸이 닿는 칸 이하이면 질문 없음" "$(nrows "$out" 질문)" "0"

# ---------------------------------------------------------------------------
# 닿는 칸이 없는 가드
# ---------------------------------------------------------------------------
tgf_repo "$WORK/outside" guard_outside.sh
out=$(probe "$WORK/outside" 머지)
check "guard_outside: 닿는 칸 없음" "$(reach "$out")" "없음"
check "guard_outside: 게이트 경로 모양이 거절된다" "$(cls "$out" snapshot)" "거절"
ends "guard_outside: 빼거나 멈추자고 묻는다" "$(question "$out")" "$Q_NONE"
out=$(probe "$WORK/outside" 커밋)
check "guard_outside: 정한 칸이 커밋이어도 없음이면 묻는다" "$(nrows "$out" 질문)" "1"

# ---------------------------------------------------------------------------
# B0 — 자유문 민감과 맨만 통과
# ---------------------------------------------------------------------------
tgf_repo "$WORK/naive" guard_b0_naive.py
out=$(probe "$WORK/naive" 머지)
check "guard_b0_naive: 자유문 민감 행" "$(nrows "$out" '자유문 민감')" "1"
tgf_repo "$WORK/b0" guard_b0.py
out=$(probe "$WORK/b0" 머지)
check "guard_b0: 자유문 민감 없음" "$(nrows "$out" '자유문 민감')" "0"
check "guard_b0: 감싼 push 는 거절" "$(wv "$out" git-push)" "거절"
check "guard_b0: 맨 push 는 통과" "$(bv "$out" git-push)" "통과"
check "guard_b0: push 모양은 맨만 통과" "$(cls "$out" git-push)" "맨만 통과"
check "guard_b0: admit 캡처 형태는 통과" "$(cls "$out" admit)" "통과"
at_least "guard_b0: push 이상 닿는다" "$(reach "$out")" push

# ---------------------------------------------------------------------------
# 풀 수 있는 가드
# ---------------------------------------------------------------------------
tgf_repo "$WORK/words" guard_words.sh
out=$(probe "$WORK/words" 머지)
check "guard_words: push 모양은 맨만 통과" "$(cls "$out" git-push)" "맨만 통과"
check "guard_words: PR 생성 모양은 맨만 통과" "$(cls "$out" gh-pr-create)" "맨만 통과"
at_least "guard_words: push 이상 닿는다" "$(reach "$out")" push
check "guard_words: 질문 행 없음" "$(nrows "$out" 질문)" "0"

# ---------------------------------------------------------------------------
# defer — 종단은 쓸 수 없는 형태
# ---------------------------------------------------------------------------
tgf_repo "$WORK/defer" guard_defer.sh
out=$(probe "$WORK/defer" 머지)
check "guard_defer: 맨 git push 는 종단" "$(bv "$out" git-push)" "종단"
check "guard_defer: 감싼 git push 는 통과라 모양은 통과" "$(cls "$out" git-push)" "통과"
# The bare form counts as unusable: with the wrapped form refused besides (the
# words guard in the tracked settings), the shape has no usable form left.
tgf_repo "$WORK/defer2" guard_words.sh
tgf_install_local "$WORK/defer2" guard_defer.sh
out=$(probe "$WORK/defer2" 머지)
check "guard_words+guard_defer: 감싼 push 는 거절" "$(wv "$out" git-push)" "거절"
check "guard_words+guard_defer: push 모양은 종단" "$(cls "$out" git-push)" "종단"
below "guard_words+guard_defer: push 아래에서 멈춘다" "$(reach "$out")" push
starts "guard_words+guard_defer: 고정된 질문 문면" "$(question "$out")" "$Q_LOWER"

# ---------------------------------------------------------------------------
# 훅의 실패와 시간 초과
# ---------------------------------------------------------------------------
tgf_repo "$WORK/exit1" guard_exit1.sh
out=$(probe "$WORK/exit1" 머지)
at_least "guard_exit1: push 이상 닿는다" "$(reach "$out")" push
case "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "비차단 오류" { print $4; exit }')" in
  *'exit 1'*) ok "guard_exit1: 비차단 오류와 종료 코드를 적는다" ;;
  *) bad "guard_exit1: 비차단 오류와 종료 코드를 적는다" "$out" ;;
esac
tgf_repo "$WORK/exit1b" guard_exit1_block.sh
out=$(probe "$WORK/exit1b" 머지)
check "guard_exit1_block: 닿는 칸 없음" "$(reach "$out")" "없음"
check "guard_exit1_block: 게이트 경로 모양이 거절된다" "$(cls "$out" act-segment)" "거절"
tgf_repo "$WORK/slow" guard_slow.sh
out=$(THP_TIMEOUT=1 probe "$WORK/slow" 머지)
check "guard_slow: 모양은 판정 불가" "$(cls "$out" snapshot)" "판정 불가"
check "guard_slow: 맨 형태도 판정 불가" "$(bv "$out" git-push)" "판정 불가"

# ---------------------------------------------------------------------------
# 세션 셸의 첫 낱말 풀이
# ---------------------------------------------------------------------------
shell_case() {   # shell_case <label> <shell path> <rc dir> <rc files…>
  local label="$1" sh="$2" d="$3" f o
  shift 3
  mkdir -p "$d"
  for f in "$@"; do printf 'git() { command git "$@"; }\n' >"$d/$f"; done
  o=$(SHELL="$sh" HOME="$d" ZDOTDIR="$d" probe "$WORK/words" 머지)
  check "$label: 셸 정의 git=함수 행" "$(printf '%s\n' "$o" | awk -F'\t' '$1 == "셸 정의" { print $2; exit }')" "git=함수"
  check "$label: git 으로 시작하는 맨 형태는 판정 불가" "$(bv "$o" git-push)" "판정 불가"
  check "$label: gh 로 시작하는 맨 형태는 그대로 판정된다" "$(bv "$o" gh-pr-create)" "통과"
  check "$label: 닿는 칸 커밋" "$(reach "$o")" "커밋"
  starts "$label: 고정된 질문 문면" "$(question "$o")" "$Q_LOWER"
  for f in "$@"; do rm -f "$d/$f"; done
  o=$(SHELL="$sh" HOME="$d" ZDOTDIR="$d" probe "$WORK/words" 머지)
  check "$label: 정의를 지우면 셸 정의 행 없음" "$(nrows "$o" '셸 정의')" "0"
  at_least "$label: 정의를 지우면 push 이상 닿는다" "$(reach "$o")" push
}
if command -v zsh >/dev/null 2>&1; then
  shell_case zsh "$(command -v zsh)" "$WORK/zdot" .zshrc
else
  printf 'NOTE: zsh 가 이 호스트에 없어 zsh 셸 정의 갈래를 건너뛴다\n'
fi
shell_case bash "$BASH_PATH" "$WORK/bhome" .bash_profile .bashrc
out=$(SHELL=/bin/sh probe "$WORK/words" 머지)
check "zsh·bash 가 아닌 셸: 셸 질의 판정 불가 행" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "셸 질의" { print $2; exit }')" "판정 불가"
check "zsh·bash 가 아닌 셸: 맨 형태는 판정 불가" "$(bv "$out" gh-pr-create)" "판정 불가"

# ---------------------------------------------------------------------------
# 두 레포 — 홈 가드가 홈이 아닌 대상의 모양을 판정한다
# ---------------------------------------------------------------------------
tgf_repo "$WORK/home" guard_b0.py
# A second hook in the home's local settings records every command string the
# home's hooks are handed, so the bare spelling can be read back.
LOG="$WORK/home-seen.log"
mkdir -p "$WORK/home/.claude/hooks"
printf '#!/usr/bin/env bash\njq -r .tool_input.command >>%s\nexit 0\n' "$LOG" >"$WORK/home/.claude/hooks/log.sh"
jq -n '{hooks:{PreToolUse:[{matcher:"Bash", hooks:[{type:"command", command:"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/log.sh\""}]}]}}' \
  >"$WORK/home/.claude/settings.local.json"
tgf_repo "$WORK/seg"
( cd "$WORK/seg" && git remote add origin git@github.com:fx/seg-target.git )
out=$(kh --worktree "$WORK/seg" --root "$WORK/home" --gate-path "$GATE" --cutpoint 머지)
check "두 레포: 루트는 다른 레포" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "루트" { print $3 }')" "다른 레포"
check "두 레포: 대상 훅 없음" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "대상 훅" { print $2 }')" "없음"
check "두 레포: 맨 push 를 홈 가드가 통과시킨다" "$(cls "$out" git-push)" "맨만 통과"
at_least "두 레포: push 이상 닿는다" "$(reach "$out")" push
if grep -qxF "git -C $WORK/seg push origin seg/kickoff-probe-A" "$LOG"; then
  ok "두 레포: 맨 push 는 git -C <워크트리> 철자로 홈 가드에 간다"
else
  bad "두 레포: 맨 push 는 git -C <워크트리> 철자로 홈 가드에 간다" "$(grep push "$LOG" | awk 'NR<=3')"
fi
if grep -q '^gh -R fx/seg-target pr create ' "$LOG"; then
  ok "두 레포: 맨 PR 생성은 gh -R <slug> 철자로 홈 가드에 간다"
else
  bad "두 레포: 맨 PR 생성은 gh -R <slug> 철자로 홈 가드에 간다" "$(grep create "$LOG" | awk 'NR<=3')"
fi
tgf_install "$WORK/seg" guard_words.sh
out=$(kh --worktree "$WORK/seg" --root "$WORK/home" --gate-path "$GATE" --cutpoint 머지)
check "두 레포·대상 훅: 닿는 칸 커밋" "$(reach "$out")" "커밋"
check "두 레포·대상 훅: 홈 아님 행" "$(nrows "$out" '홈 아님')" "1"
case "$(question "$out")" in
  *"$Q_LOWER"*) ok "두 레포·대상 훅: 고정된 질문 문면" ;;
  *) bad "두 레포·대상 훅: 고정된 질문 문면" "$(question "$out")" ;;
esac

# ---------------------------------------------------------------------------
# 다른 킥오프 도우미의 경계와 스킬 문면
# ---------------------------------------------------------------------------
if bash "$repo_root/scripts/lint-kickoff-defaults.sh" >/dev/null 2>&1; then
  ok "기본값 린트 규칙 1·4 가 이 도우미를 잡지 않는다"
else
  bad "기본값 린트 규칙 1·4 가 이 도우미를 잡지 않는다" "$(bash "$repo_root/scripts/lint-kickoff-defaults.sh" 2>&1 | tail -n 3)"
fi
check "boundaries.md 가 도우미 호출 철자를 한 번 담는다" \
  "$(grep -cF 'bash <plugin root>/orchestrator/kickoff-hook-probe.sh --worktree <that target'"'"'s main worktree> --root <issuing root> --gate-path' "$BOUNDARIES")" "1"
check "boundaries.md 가 「절단점이 정해진 직후」 를 한 번 담는다" "$(grep -cF '절단점이 정해진 직후' "$BOUNDARIES")" "1"
check "SKILL.md 가 경계 질문지에 싣지 않는 절단점 질문을 한 번 담는다" "$(grep -cF "**The hook check's cutpoint question**" "$SKILL")" "1"
check "SKILL.md 가 재킥오프 경로의 훅 검사 문장을 한 번 담는다" "$(grep -cF '**The hook check runs on this path too.**' "$SKILL")" "1"
# 재킥오프의 「여덟 질문」 밖에서 묻는다는 예외와, 낮춘 칸을 초안에 싣는 두 쓰기(키 줄과 --targets)
rk_line=$(grep -F '**The hook check runs on this path too.**' "$SKILL")
for frag in '**This question is asked on top of the eight of item 6 in `references/rekickoff.md`**' \
            '`7.7 절단점 <별칭>`' 'add `--targets <파일>` to 7.1' '`닿는 칸 없음`, nothing is asked and no target is dropped' \
            'call `bash <plugin root>/orchestrator/kickoff-hook-probe.sh`'; do
  case "$rk_line" in
    *"$frag"*) ok "재킥오프 훅 검사 문단: $frag" ;;
    *) bad "재킥오프 훅 검사 문단: $frag" "문단에 없음" ;;
  esac
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
