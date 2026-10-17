#!/usr/bin/env bash
#
# kickoff-hook-probe.sh — the autopilot kickoff's check of a target's own
# PreToolUse Bash hooks against the commands a run will issue there.
#
# WHY THE KICKOFF RUNS THE HOOKS. A target repository may carry a Bash guard of
# its own, and that guard judges every command string the run's sessions issue
# in it — the deny of any loaded hook wins over the run's own allow. A guard
# that refuses a shape the run needs at its cutpoint does not fail loudly at
# night: the segment parks on the first refused act. A static look at the
# matcher cannot say which shapes such a guard refuses, so this program runs the
# hooks on disk against a fixed corpus of the commands each cutpoint needs, and
# the kickoff asks the person to lower the cutpoint before it is frozen when the
# corpus cannot get past the guard at the chosen one.
#
# WHAT IT JUDGES WITH. The verdicts come from the hooks a session started at
# `--root` loads — the issuing root, where the target's acts are issued from —
# read by the shared probe engine (`../hooks/target-hook-probe.sh`, sourced,
# never copied). `--worktree`'s hooks only decide whether the target has a
# hook. When the two are different repositories (a router run's target that is
# not the home), the target's guard is loaded by no session of the run, so at
# most `커밋` is reachable there, whatever the home guard says.
#
# EACH SHAPE IN TWO FORMS. The wrapped form is the gate call that runs the
# command; the bare form is the plain command, which the run issues through the
# request capture and `admit --request last` and whose first word the session's
# shell resolves. A bare form counts only when the capture form itself gets past
# the guard, and only when the session shell does not resolve its first word to
# a function or an alias — the shell is asked with `"$SHELL" -l -i -c`, from
# `--root`, in this program's own environment.
#
# ONLY THE KICKOFF CALLS THIS, like the other kickoff helpers in this
# directory. Inside a pipeline run (`CC_PIPELINE_RUN_ID`,
# `CC_PIPELINE_STAGE_ID` or `CC_PIPELINE_SHIFT_ID` set) it refuses with exit 3
# before it reads anything. It writes nothing; the probe's own temporary files
# are removed by the engine.
#
# Usage
#
#   kickoff-hook-probe.sh --worktree <target main worktree> --root <issuing root>
#                         --gate-path <absolute gate path> --cutpoint <token>
#
# Output is TAB-separated, the first line `cc-kickoff-hook-probe v1`:
#
#   루트          <issuing root>  <같은 레포|다른 레포>
#   대상 훅        <있음|없음|판정 불가>  <target worktree>
#   발행 루트 훅    <있음|없음|판정 불가>  <issuing root>
#   셸 정의        <word>=<함수|별칭>
#   전역 별칭      <name>
#   셸 질의        판정 불가  <why>
#   모양          <cell>  <shape>  <class>  <wrapped verdict>  <bare verdict|->  <guard text>
#   자유문 민감     <guard text>
#   비차단 오류     <shape>  <감쌈|맨>  <guard text>
#   홈 아님        <fixed text>
#   닿는 칸        <cell|없음>
#   질문          <fixed text>                (only when the cutpoint is above the reach)
#
# A class is `통과` (the wrapped form can be used), `맨만 통과` (only the bare
# form), or — when neither can — the bare form's verdict (`거절`, `종단`,
# `판정 불가`), the wrapped form's when the shape has no bare form. A verdict is
# `통과`, `비차단 오류` (the harness runs the tool; usable), `거절`, `종단`
# (defer: the tool does not run and the session ends) or `판정 불가` (the probe
# could not tell, a probe timeout included). The reach is the highest cell of
# the driver's ladder up to which every shape is usable. A cell with no corpus
# of its own was not measured, so it is never reported on the strength of the
# cell below it: it takes the verdict of the nearest cell above it that has a
# corpus (`브랜치` stands or falls with `push`), and only the cells above the
# last such cell take the one below.
#
# Exit codes: 0 judged · 2 usage · 3 refused (inside a run, or the engine, the
# driver's vocabulary or jq could not be loaded). On 2 and 3 stdout is empty and
# stderr carries one line.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`.

set -uo pipefail

KHP_PROG='kickoff-hook-probe.sh'
KHP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

khp_refuse() { printf '%s: %s\n' "$KHP_PROG" "$1" >&2; exit 3; }
khp_usage()  { printf '%s: %s\n' "$KHP_PROG" "$1" >&2; exit 2; }

for khp_v in CC_PIPELINE_RUN_ID CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID; do
  eval "khp_val=\${$khp_v:-}"
  if [ -n "$khp_val" ]; then
    khp_refuse "파이프라인 런 안에서는 돌지 않습니다 — 대상 훅 사전 검사는 킥오프만 부릅니다 ($khp_v 가 설정돼 있습니다)"
  fi
done

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
KHP_WT=''; KHP_ROOT=''; KHP_GATE=''; KHP_CUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree|--root|--gate-path|--cutpoint)
      [ $# -ge 2 ] && [ -n "$2" ] || khp_usage "$1 에 값이 없습니다"
      case "$1" in
        --worktree)  [ -z "$KHP_WT" ]   || khp_usage "--worktree 는 한 번만 씁니다";  KHP_WT="$2" ;;
        --root)      [ -z "$KHP_ROOT" ] || khp_usage "--root 는 한 번만 씁니다";      KHP_ROOT="$2" ;;
        --gate-path) [ -z "$KHP_GATE" ] || khp_usage "--gate-path 는 한 번만 씁니다"; KHP_GATE="$2" ;;
        --cutpoint)  [ -z "$KHP_CUT" ]  || khp_usage "--cutpoint 는 한 번만 씁니다";  KHP_CUT="$2" ;;
      esac
      shift 2 ;;
    *) khp_usage "모르는 인자: '$1'" ;;
  esac
done
[ -n "$KHP_WT" ]   || khp_usage "--worktree 가 필요합니다"
[ -n "$KHP_ROOT" ] || khp_usage "--root 가 필요합니다"
[ -n "$KHP_GATE" ] || khp_usage "--gate-path 가 필요합니다"
[ -n "$KHP_CUT" ]  || khp_usage "--cutpoint 가 필요합니다"
for khp_p in "$KHP_WT" "$KHP_ROOT" "$KHP_GATE"; do
  case "$khp_p" in /*) ;; *) khp_usage "경로는 절대 경로여야 합니다: '$khp_p'" ;; esac
done
[ -d "$KHP_WT" ]   || khp_usage "--worktree 가 디렉터리가 아닙니다: '$KHP_WT'"
[ -d "$KHP_ROOT" ] || khp_usage "--root 가 디렉터리가 아닙니다: '$KHP_ROOT'"
# The gate path and the worktree are written into command strings unquoted, so
# a byte a guard would split or unquote differently is refused here rather than
# judged as some other string.
for khp_p in "$KHP_GATE" "$KHP_WT"; do
  case "$khp_p" in
    *[!A-Za-z0-9_@%+=:,./-]*) khp_usage "경로에 공백·따옴표·셸 특수 문자가 있어 명령 말뭉치에 그대로 싣지 못합니다: '$khp_p'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || khp_refuse "jq 가 없어 훅 설정을 읽을 수 없습니다"

# ---------------------------------------------------------------------------
# The driver's ladder and the probe engine — both sourced, never copied. The
# definitions-only seam loads the driver's constants and functions and returns
# before any pipeline runs; the strict modes it imports are dropped right after.
# ---------------------------------------------------------------------------
[ -r "$KHP_DIR/run.sh" ] || khp_refuse "run.sh 를 읽을 수 없습니다: $KHP_DIR/run.sh"
# shellcheck disable=SC1091
CC_ORCH_SOURCE_ONLY=1 . "$KHP_DIR/run.sh" >/dev/null 2>&1 || khp_refuse "run.sh 를 들여오지 못했습니다"
set +e +u
set +o pipefail
[ -n "${CUTPOINTS:-}" ] || khp_refuse "run.sh 에서 절단점 어휘를 읽지 못했습니다"
command -v cutpoint_index >/dev/null 2>&1 || khp_refuse "run.sh 에 cutpoint_index 가 없습니다"

KHP_ENGINE="$KHP_DIR/../hooks/target-hook-probe.sh"
[ -r "$KHP_ENGINE" ] || khp_refuse "프로브 엔진을 읽을 수 없습니다: $KHP_ENGINE"
# shellcheck disable=SC1090
. "$KHP_ENGINE" || khp_refuse "프로브 엔진을 들여오지 못했습니다"
for khp_f in thp_probe thp_bash_hook_entries thp_common_dir thp_phys; do
  command -v "$khp_f" >/dev/null 2>&1 || khp_refuse "프로브 엔진에 $khp_f 가 없습니다"
done

khp_in() {   # khp_in <word> <space-separated list>
  case "$1" in ''|*[[:space:]]*) return 1 ;; esac
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}
khp_idx() { cutpoint_index "$1" 2>/dev/null; }

if ! khp_in "$KHP_CUT" "$CUTPOINTS"; then
  if khp_tok=$(cutpoint_token "$KHP_CUT" 2>/dev/null) && [ -n "$khp_tok" ]; then
    khp_usage "--cutpoint 는 토큰으로 씁니다 — '$KHP_CUT' 대신 '$khp_tok'"
  fi
  khp_usage "--cutpoint 가 절단점 어휘에 없습니다: '$KHP_CUT' — 허용: $CUTPOINTS"
fi
# The corpus is written per cell, so a ladder that no longer has one of these
# cells would leave its commands unjudged.
for khp_c in 커밋 push PR 머지; do
  khp_in "$khp_c" "$CUTPOINTS" || khp_refuse "절단점 어휘에 말뭉치의 칸 '$khp_c' 가 없습니다 — 말뭉치를 어휘에 맞춰 고쳐야 합니다"
done

# One field of a TSV row: no TAB, no newline, no control byte.
khp_cell() { printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' '; }
khp_row() {
  local first=1 a
  for a in "$@"; do
    if [ "$first" = 1 ]; then first=0; else printf '\t'; fi
    khp_cell "$a"
  done
  printf '\n'
}

# ---------------------------------------------------------------------------
# The two roots
# ---------------------------------------------------------------------------
KHP_WT=$(thp_phys "$KHP_WT")
KHP_ROOT=$(thp_phys "$KHP_ROOT")
KHP_SAME=0
if [ "$KHP_WT" = "$KHP_ROOT" ]; then
  KHP_SAME=1
else
  khp_cw=$(thp_common_dir "$KHP_WT"); khp_cr=$(thp_common_dir "$KHP_ROOT")
  [ -n "$khp_cw" ] && [ "$khp_cw" = "$khp_cr" ] && KHP_SAME=1
fi

khp_hook_state() {   # khp_hook_state <dir> → 있음 | 없음 | 판정 불가
  local out rc=0
  out=$(thp_bash_hook_entries "$1") || rc=$?
  if [ -n "$out" ]; then printf '있음'
  elif [ "$rc" -ne 0 ]; then printf '판정 불가'
  else printf '없음'
  fi
}
KHP_WT_HOOK=$(khp_hook_state "$KHP_WT")
KHP_ROOT_HOOK=$(khp_hook_state "$KHP_ROOT")

# The remote slug the bare `gh` forms name, from the target's `origin`; a fixed
# placeholder when it cannot be read, since a guard judges the shape, not the
# repository it names.
khp_slug() {
  local u s
  u=$( cd "$KHP_WT" && git config --get remote.origin.url 2>/dev/null ) || u=''
  u="${u%/}"; u="${u%.git}"
  s=$(printf '%s' "$u" | sed -E 's#^.*[:/]([^/:]+)/([^/:]+)$#\1/\2#')
  if printf '%s\n' "$s" | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' >/dev/null; then
    printf '%s' "$s"
  else
    printf 'OWNER/NAME'
  fi
}
KHP_SLUG=$(khp_slug)

# ---------------------------------------------------------------------------
# The session shell's reading of the bare forms' first words
# ---------------------------------------------------------------------------
KHP_FIRST_WORDS='git gh command'
KHP_SHELL_FAIL=''     # why the query failed, empty when it answered
KHP_DEFS=''           # `<word>=<함수|별칭>` per line
KHP_GALIASES=''       # zsh global alias names, one per line
KHP_SHELL_BOUND="${KHP_SHELL_BOUND:-20}"

khp_shell_query() {
  local sh="${SHELL:-}" kind script td out pid wpid rc line w t
  case "$(basename "$sh" 2>/dev/null)" in
    zsh)  kind=zsh
          script='for w in '"$KHP_FIRST_WORDS"'; do print -r -- "khp-def $(whence -w $w)"; done; for a in ${(k)galiases}; do print -r -- "khp-galias $a"; done; print -r -- khp-end' ;;
    bash) kind=bash
          script='for w in '"$KHP_FIRST_WORDS"'; do printf "khp-def %s: %s\n" "$w" "$(type -t "$w")"; done; printf "khp-end\n"' ;;
    *) KHP_SHELL_FAIL="세션 셸이 zsh·bash 가 아닙니다: ${sh:-(SHELL 없음)}"; return 0 ;;
  esac
  td=$(mktemp -d "${TMPDIR:-/tmp}/khp-shell.XXXXXX") || { KHP_SHELL_FAIL='임시 디렉터리를 만들지 못했습니다'; return 0; }
  ( cd "$KHP_ROOT" && exec "$sh" -l -i -c "$script" ) </dev/null >"$td/out" 2>/dev/null &
  pid=$!
  ( sleep "$KHP_SHELL_BOUND"; : >"$td/timeout"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  rc=0; wait "$pid" || rc=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  if [ -e "$td/timeout" ]; then
    KHP_SHELL_FAIL="세션 셸 질의가 ${KHP_SHELL_BOUND}초 안에 끝나지 않았습니다"
  elif ! grep -qx 'khp-end' "$td/out" 2>/dev/null; then
    KHP_SHELL_FAIL="세션 셸 질의가 답하지 않았습니다 ($kind, exit $rc)"
  else
    while IFS= read -r line; do
      case "$line" in
        'khp-def '*)
          line="${line#khp-def }"; w="${line%%:*}"; t="${line#*: }"
          case "$t" in
            function) KHP_DEFS="${KHP_DEFS}${w}=함수
" ;;
            alias) KHP_DEFS="${KHP_DEFS}${w}=별칭
" ;;
          esac ;;
        'khp-galias '*) KHP_GALIASES="${KHP_GALIASES}${line#khp-galias }
" ;;
      esac
    done <"$td/out"
  fi
  rm -rf "$td"
}
khp_shell_query

khp_def_of() {   # khp_def_of <word> → `함수` | `별칭` | nothing
  printf '%s' "$KHP_DEFS" | awk -F= -v w="$1" '$1 == w { print $2; exit }'
}

# ---------------------------------------------------------------------------
# The corpus. Each shape: its cell, its name, its wrapped form (the gate call)
# and its bare form (empty for the gate's own vocabulary, which has only the
# gate head). The free-text shape is a diagnostic — a wrapped form whose only
# difference from `git-status` is a rationale carrying the standalone words
# `git` and `gh` — and does not count toward the reach: the run can keep those
# words out of its rationale, a guard that splits naively cannot be told to.
# No other rationale here carries a command word.
# ---------------------------------------------------------------------------
KHP_WHY="'판정용 문장'"
KHP_FREE_WHY="'git 과 gh 를 이 문장에만 적는다'"
KHP_BRANCH='seg/kickoff-probe-A'
KHP_SHA='0000000000000000000000000000000000000000'
KHP_N=0

khp_wrap() {   # khp_wrap <cell> <surface> <reach|-> <argv> [<rationale>]
  local r=''
  [ "$3" = - ] || r=" --reach $3"
  printf '%s exec --manifest m --target t --segment A --cutpoint %s --surface %s%s --rationale %s -- %s' \
    "$KHP_GATE" "$1" "$2" "$r" "${5:-$KHP_WHY}" "$4"
}
# The bare spelling. A router run's target that is not the home is reached from
# the home root, so its bare forms name the worktree and the repository.
khp_bare_git() {
  if [ "$KHP_SAME" = 1 ]; then printf 'git %s' "$1"; else printf 'git -C %s %s' "$KHP_WT" "$1"; fi
}
khp_bare_ghpr() {
  if [ "$KHP_SAME" = 1 ]; then printf 'gh pr %s' "$1"; else printf 'gh -R %s pr %s' "$KHP_SLUG" "$1"; fi
}
khp_shape() {   # khp_shape <cell> <name> <wrapped> <bare> [diag]
  S_CELL[KHP_N]="$1"; S_NAME[KHP_N]="$2"; S_WRAP[KHP_N]="$3"; S_BARE[KHP_N]="$4"; S_DIAG[KHP_N]="${5:-0}"
  KHP_N=$((KHP_N + 1))
}

khp_shape 커밋 snapshot "$KHP_GATE snapshot --manifest m --fields H" ''
khp_shape 커밋 act-segment "$KHP_GATE act --kind segment --manifest m --target t --segment A --rationale $KHP_WHY" ''
khp_shape 커밋 git-add "$(khp_wrap 커밋 워크트리쓰기 - 'git add -A')" "$(khp_bare_git 'add -A')"
khp_shape 커밋 git-commit "$(khp_wrap 커밋 워크트리쓰기 - 'git commit -m kickoff-probe')" "$(khp_bare_git 'commit -m kickoff-probe')"
khp_shape 커밋 git-status "$(khp_wrap 커밋 읽기 - 'git status --short')" "$(khp_bare_git 'status --short')"
khp_shape 커밋 git-fetch "$(khp_wrap 커밋 읽기 협업 'git fetch origin')" "$(khp_bare_git 'fetch origin')"
khp_shape 커밋 free-text "$(khp_wrap 커밋 읽기 - 'git status --short' "$KHP_FREE_WHY")" '' 1
khp_shape push git-push "$(khp_wrap push 외부상태변경 협업 "git push origin $KHP_BRANCH")" "$(khp_bare_git "push origin $KHP_BRANCH")"
khp_shape PR gh-pr-create "$(khp_wrap PR 외부상태변경 협업 "gh pr create --head $KHP_BRANCH --title kickoff-probe --body kickoff-probe")" "$(khp_bare_ghpr "create --head $KHP_BRANCH --title kickoff-probe --body kickoff-probe")"
khp_shape PR gh-pr-view "$(khp_wrap PR 읽기 협업 'gh pr view 1')" "$(khp_bare_ghpr 'view 1')"
khp_shape PR gh-pr-list "$(khp_wrap PR 읽기 협업 "gh pr list --head $KHP_BRANCH")" "$(khp_bare_ghpr "list --head $KHP_BRANCH")"
khp_shape PR gh-pr-checks "$(khp_wrap PR 읽기 협업 'gh pr checks 1')" "$(khp_bare_ghpr 'checks 1')"
khp_shape PR gh-pr-diff "$(khp_wrap PR 읽기 협업 'gh pr diff 1')" "$(khp_bare_ghpr 'diff 1')"
khp_shape PR gh-api-repo "$(khp_wrap PR 읽기 협업 "gh api repos/$KHP_SLUG")" "gh api repos/$KHP_SLUG"
khp_shape PR gh-present "$(khp_wrap PR 읽기 - 'command -v gh')" 'command -v gh'
khp_shape PR admit "$KHP_GATE admit --request last --manifest m --target t --segment A --surface 외부상태변경 --reach 협업 --snapshot-digest h --rationale $KHP_WHY" ''
KHP_ADMIT=$((KHP_N - 1))
khp_shape 머지 gh-api-merge "$(khp_wrap 머지 외부상태변경 협업 "gh api -X PUT repos/$KHP_SLUG/pulls/1/merge -f sha=$KHP_SHA")" "gh api -X PUT repos/$KHP_SLUG/pulls/1/merge -f sha=$KHP_SHA"

# ---------------------------------------------------------------------------
# Judging
# ---------------------------------------------------------------------------
khp_usable() { case "$1" in 통과|'비차단 오류') return 0 ;; esac; return 1; }

KHP_SEQ=0
khp_judge() {   # khp_judge <command> → sets KHP_V (verdict) and KHP_T (guard text)
  local out v
  KHP_SEQ=$((KHP_SEQ + 1))
  out=$(thp_probe "$KHP_ROOT" "$1" "$KHP_ROOT" "kickoff-probe-$KHP_SEQ")
  v=$(printf '%s\n' "$out" | sed -n '1p'); KHP_T=$(printf '%s\n' "$out" | sed -n '2p')
  case "$v" in
    통과|'비차단 오류'|거절|종단|'판정 불가') KHP_V="$v" ;;
    '시간 초과') KHP_V='판정 불가' ;;
    *) KHP_V='판정 불가'; KHP_T="프로브가 알 수 없는 판정을 냈다: $v" ;;
  esac
}

KHP_NB=''   # 비차단 오류 rows
i=0
while [ "$i" -lt "$KHP_N" ]; do
  khp_judge "${S_WRAP[i]}"
  S_WV[i]="$KHP_V"; S_WT[i]="$KHP_T"
  [ "$KHP_V" = '비차단 오류' ] && KHP_NB="${KHP_NB}$(khp_row '비차단 오류' "${S_NAME[i]}" 감쌈 "$KHP_T")
"
  S_BV[i]='-'; S_BT[i]=''
  if [ -n "${S_BARE[i]}" ]; then
    fw="${S_BARE[i]%% *}"
    d=$(khp_def_of "$fw")
    if [ -n "$KHP_SHELL_FAIL" ]; then
      S_BV[i]='판정 불가'; S_BT[i]="셸 질의 실패: $KHP_SHELL_FAIL"
    elif [ -n "$d" ]; then
      S_BV[i]='판정 불가'; S_BT[i]="셸 정의 $fw=$d"
    else
      khp_judge "${S_BARE[i]}"
      S_BV[i]="$KHP_V"; S_BT[i]="$KHP_T"
      [ "$KHP_V" = '비차단 오류' ] && KHP_NB="${KHP_NB}$(khp_row '비차단 오류' "${S_NAME[i]}" 맨 "$KHP_T")
"
    fi
  fi
  i=$((i + 1))
done

# Classes. A bare form is usable only when the capture form gets past the guard.
KHP_ADMIT_OK=0
khp_usable "${S_WV[KHP_ADMIT]}" && KHP_ADMIT_OK=1
i=0
while [ "$i" -lt "$KHP_N" ]; do
  if khp_usable "${S_WV[i]}"; then
    S_CLASS[i]='통과'; S_OK[i]=1; S_TXT[i]="${S_WT[i]}"
  elif [ "${S_BV[i]}" != - ] && khp_usable "${S_BV[i]}"; then
    S_CLASS[i]='맨만 통과'; S_OK[i]=$KHP_ADMIT_OK; S_TXT[i]="${S_WT[i]}"
  elif [ "${S_BV[i]}" != - ]; then
    S_CLASS[i]="${S_BV[i]}"; S_OK[i]=0
    S_TXT[i]="감쌈: ${S_WT[i]:-${S_WV[i]}} · 맨: ${S_BT[i]:-${S_BV[i]}}"
  else
    S_CLASS[i]="${S_WV[i]}"; S_OK[i]=0; S_TXT[i]="${S_WT[i]:-${S_WV[i]}}"
  fi
  i=$((i + 1))
done

# The reach: up the ladder while every cell so far is usable. `C_OK` is a
# corpus cell's own verdict (every shape usable), empty for a cell without one.
khp_n=0
for khp_c in $CUTPOINTS; do
  C_NAME[khp_n]="$khp_c"; C_OK[khp_n]=''
  i=0
  while [ "$i" -lt "$KHP_N" ]; do
    if [ "${S_CELL[i]}" = "$khp_c" ] && [ "${S_DIAG[i]}" = 0 ]; then
      [ -n "${C_OK[khp_n]}" ] || C_OK[khp_n]=1
      [ "${S_OK[i]}" = 1 ] || C_OK[khp_n]=0
    fi
    i=$((i + 1))
  done
  khp_n=$((khp_n + 1))
done
KHP_REACH='없음'
p=0
while [ "$p" -lt "$khp_n" ]; do
  khp_e="${C_OK[p]}"
  q=$p
  while [ -z "$khp_e" ] && [ "$q" -lt "$khp_n" ]; do khp_e="${C_OK[q]}"; q=$((q + 1)); done
  # No corpus cell above: the cells below were all usable to get here.
  [ -n "$khp_e" ] || khp_e=1
  [ "$khp_e" = 1 ] || break
  KHP_REACH="${C_NAME[p]}"
  p=$((p + 1))
done

# A target that is not the router run's home and has a hook of its own: no
# session of the run loads that guard, so none of the run's commands is judged
# by it, and nothing above `커밋` is offered.
KHP_NOT_HOME=''
if [ "$KHP_SAME" = 0 ] && [ "$KHP_WT_HOOK" != 없음 ]; then
  KHP_NOT_HOME='이 대상은 라우터 런의 홈이 아니어서 어떤 런 세션도 이 대상의 Bash 훅을 불러오지 않습니다 — 그 가드는 런의 어떤 명령도 판정하지 못하므로 닿을 수 있는 칸은 많아야 커밋입니다'
  if [ "$KHP_REACH" != 없음 ] && [ "$(khp_idx "$KHP_REACH")" -gt "$(khp_idx 커밋)" ]; then
    KHP_REACH='커밋'
  fi
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
printf 'cc-kickoff-hook-probe v1\n'
if [ "$KHP_SAME" = 1 ]; then khp_row 루트 "$KHP_ROOT" '같은 레포'; else khp_row 루트 "$KHP_ROOT" '다른 레포'; fi
khp_row '대상 훅' "$KHP_WT_HOOK" "$KHP_WT"
khp_row '발행 루트 훅' "$KHP_ROOT_HOOK" "$KHP_ROOT"
if [ -n "$KHP_SHELL_FAIL" ]; then
  khp_row '셸 질의' '판정 불가' "$KHP_SHELL_FAIL"
fi
printf '%s' "$KHP_DEFS" | while IFS= read -r khp_l; do [ -n "$khp_l" ] && khp_row '셸 정의' "$khp_l"; done
printf '%s' "$KHP_GALIASES" | while IFS= read -r khp_l; do [ -n "$khp_l" ] && khp_row '전역 별칭' "$khp_l"; done
i=0
while [ "$i" -lt "$KHP_N" ]; do
  if [ "${S_DIAG[i]}" = 0 ]; then
    khp_row 모양 "${S_CELL[i]}" "${S_NAME[i]}" "${S_CLASS[i]}" "${S_WV[i]}" "${S_BV[i]}" "${S_TXT[i]}"
  fi
  i=$((i + 1))
done
# Free-text sensitivity: the diagnostic is refused where the same command with a
# plain rationale is not.
i=0
while [ "$i" -lt "$KHP_N" ]; do
  if [ "${S_DIAG[i]}" = 1 ] && ! khp_usable "${S_WV[i]}"; then
    j=0
    while [ "$j" -lt "$KHP_N" ]; do
      if [ "${S_NAME[j]}" = git-status ] && khp_usable "${S_WV[j]}"; then
        khp_row '자유문 민감' "${S_WT[i]:-${S_WV[i]}}"
      fi
      j=$((j + 1))
    done
  fi
  i=$((i + 1))
done
printf '%s' "$KHP_NB"
[ -z "$KHP_NOT_HOME" ] || khp_row '홈 아님' "$KHP_NOT_HOME"
khp_row '닿는 칸' "$KHP_REACH"

# The question, when the chosen cutpoint is above the reach. It quotes every
# unusable shape at or below the chosen cell and its guard's text.
khp_cut_i=$(khp_idx "$KHP_CUT")
if [ "$KHP_REACH" = 없음 ] || [ "$khp_cut_i" -gt "$(khp_idx "$KHP_REACH")" ]; then
  khp_list=''
  i=0
  while [ "$i" -lt "$KHP_N" ]; do
    if [ "${S_DIAG[i]}" = 0 ] && [ "${S_OK[i]}" != 1 ] && [ "$(khp_idx "${S_CELL[i]}")" -le "$khp_cut_i" ]; then
      khp_t="${S_TXT[i]}"
      [ "${S_CLASS[i]}" = '맨만 통과' ] && khp_t="맨 형태만 통과하는데 admit --request last 가 거절된다 — ${S_WT[KHP_ADMIT]:-${S_WV[KHP_ADMIT]}}"
      khp_list="${khp_list:+$khp_list; }${S_CELL[i]}/${S_NAME[i]} ${S_CLASS[i]}: $(printf '%s' "$khp_t" | cut -c1-300)"
    fi
    i=$((i + 1))
  done
  khp_lead=''
  [ -z "$KHP_NOT_HOME" ] || khp_lead="$KHP_NOT_HOME. "
  if [ "$KHP_REACH" = 없음 ]; then
    khp_row 질문 "${khp_lead}이 대상의 Bash 훅 아래에서는 게이트 경로부터 쓸 수 없어 런이 이 대상에서 닿을 수 있는 칸이 없습니다 — 쓸 수 없는 모양: ${khp_list:-없음} — 이 대상을 런에서 빼거나 킥오프를 멈출까요?"
  else
    khp_row 질문 "${khp_lead}이 대상의 Bash 훅 아래에서 런이 닿을 수 있는 칸은 ${KHP_REACH} 이고 정한 절단점은 ${KHP_CUT} 입니다 — 쓸 수 없는 모양: ${khp_list:-없음} — 절단점을 ${KHP_REACH} 로 내릴까요, ${KHP_CUT} 로 둘까요?"
  fi
fi
exit 0
