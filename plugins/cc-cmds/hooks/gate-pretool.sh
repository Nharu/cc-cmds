#!/usr/bin/env bash
#
# gate-pretool.sh — layer 1 of the run's enforcement, inverted.
#
# A PreToolUse hook that matches DANGEROUS command strings is a misuse detector,
# not a boundary: a script file, an alias, `git -c`, `env`, or a here-doc defeats
# it without ingenuity. So this one is inverted — it recognizes exactly one
# command shape (`gate.sh`) and denies everything else. An allow-list has the
# property a deny-list cannot: the "write it to a file and run the file" evasion
# works against a deny-list and does nothing against this.
#
# AND ITS PURPOSE IS NOT BLOCKING ACTS. It is LEDGER COMPLETENESS. A denial here
# is an escalation rather than a refusal — the reason text routes the model to
# `gate.sh exec -- <argv>`, which performs the very same command after checking
# and recording it. Nothing a stage legitimately needs becomes impossible; what
# becomes impossible is doing it without a row.
#
# WHY THIS SHIPS IN THE RUN SETTINGS AND NOT IN `hooks.json`. The plugin's hook
# file loads for every session that loads the plugin, the user's own interactive
# session included, and a default-deny Bash hook there would be a catastrophe
# rather than a boundary. This hook is written into `$RUN_DIR/settings/*.json`
# by the gate and reaches only the stage sessions the wrapper launches with
# `--settings`.
#
# TWO PRECEDENTS FROM THE SIBLING HOOK ARE DELIBERATELY NOT INHERITED, and both
# would be fatal here rather than merely wrong:
#
#   1. `command -v jq || exit 0` — a silent fail-open. For a default-deny gate
#      the missing-tool branch must DENY. A hook that disappears when its own
#      dependency is missing is a hook that an unattended run cannot rely on,
#      and the failure is invisible: every act proceeds and every row is absent.
#   2. `applyPermissionRules` — a session-persistent allow. It would let the
#      gate be consulted once and bypassed for the rest of the session, which
#      is the exact opposite of a per-act check. Every decision here is for the
#      one call it was asked about.
#
# `--run-dir` is REQUIRED and comes from the settings file the hook was loaded
# from, never from the environment. A stage that could disable the hook with
# `env -u CC_PIPELINE_RUN_ID` would have a one-word bypass; a value baked into a
# file the hook itself refuses writes to has none.
#
# Usage (as generated into the run settings, never typed by hand):
#   bash <plugin root>/hooks/gate-pretool.sh --run-dir <RUN_DIR> --gate <gate.sh>
#
# Exit codes: always 0 — the decision travels in the JSON on stdout, which is
# the only channel the harness reads. A non-zero exit here is an error in the
# hook, not a denial, and the two must not be confused.
#
# Compatibility: bash 3.2 — no associative arrays, no mapfile.

set -uo pipefail

RUN_DIR=""; GATE=""; LEDGER=""; GRANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --gate)    GATE="$2"; shift 2 ;;
    --ledger)  LEDGER="$2"; shift 2 ;;
    --grant)   GRANT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

deny() {
  # A denial carries the escalation, not just the refusal. The verb name must
  # match the gate's own table byte-for-byte: this text reaches the model
  # verbatim, and a name that does not resolve turns an escalation into a dead
  # end the model then works around.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$1"
  exit 0
}
allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$1"
  exit 0
}
jstr() {
  # Newlines collapse to spaces before the quoting runs. A denial reason quotes
  # the offending command back, a heredoc command carries newlines, and a raw
  # newline inside a JSON string is a parse error — which the harness reads as a
  # malformed hook rather than as a denial.
  printf '%s' "$1" | tr '\n\r\t' '   ' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$/"/'
}

if [ -z "$RUN_DIR" ]; then
  deny "$(jstr 'gate: 이 훅이 런 디렉터리 없이 설치됐습니다 — 게이트가 생성한 설정이 아닌 경로로 로드된 것이므로 아무것도 인가하지 않습니다')"
fi

# ---------------------------------------------------------------------------
# PATH COMPARISON: SPELLING IS NOT IDENTITY.
#
# Every deny arm below used to compare the path the tool handed us, verbatim,
# against a pattern. That is a deny-list over SPELLINGS, and this file's own
# header argues at length that a deny-list is what an allow-list replaced —
# the Write/Edit half had simply kept one. Measured on this machine: the data
# volume firmlink gives every file under `$HOME` a second absolute spelling
# (`/System/Volumes/Data/Users/…`) that is already absolute, already canonical,
# contains no `..`, and passes every arm. `..`, a relative path, a tilde, and a
# symlinked tail all do the same.
#
# So the comparison happens in two layers, because neither alone is enough:
#
#   1. LEXICAL NORMALIZATION closes `..`, relative paths, tildes and duplicate
#      separators, and it is the only layer the suffix-glob arms (`*/.claude/…`)
#      can use, since those have no anchor to compare an inode against.
#   2. DEVICE+INODE IDENTITY closes the rest, and it is REQUIRED rather than
#      belt-and-braces: `cd … && pwd -P` does NOT fold the firmlink spelling
#      (measured — `/Users` is a real directory, not a symlink, and both
#      spellings report the same device and inode), so no amount of spelling
#      normalization would have caught the one bypass that was actually
#      observed.
#
# The inode layer costs ONE `stat` call for the whole decision. Per-path calls
# would put dozens of forks on every edit a stage makes. What that budget rules
# out is a fork PER PATH, not a fixed handful per decision — the spelling probe
# below costs at most two and the symlink-leaf reading costs none at all, since
# it is a shell builtin, and neither grows with the number of paths a decision
# compares.
# ---------------------------------------------------------------------------
NL='
'
INOS=""; HOOK_INO=""; HOOK_TAIL=""; HOOK_NORM=""; NP_INO=""; np=""; ap=""
HOOK_STAT_FMT=""

hook_lexnorm() {
  # hook_lexnorm <경로> [keep] — 어휘 정규화만 해서 `HOOK_NORM` 에 넣는다. 틸드
  # 확장, 상대 경로의 절대화, `//` 와 `/./` 축약, `..` 해소, 후행 `/` 제거.
  # 파일시스템을 읽지 않으므로 심링크는 따르지 않는다 — 그 몫은 아래 아이노드
  # 비교가 진다. 절대 경로로 만들 수 없으면 거짓.
  #
  # 두 번째 인자가 있으면 `..` 를 접지 않고 보통 성분으로 흘려 보낸다. 접은 철자와
  # 접지 않은 철자는 심링크 디렉터리를 낀 경로에서 서로 다른 파일을 가리키고,
  # 둘 다 필요하다 — 접은 쪽은 앵커가 없는 접미 글롭이 쓰고, 접지 않은 쪽은
  # `stat -L` 에 넘겨 커널이 여는 파일을 재는 데 쓴다.
  #
  # 값을 찍지 않고 전역에 넣는 이유는 명령 치환이 곧 fork 이고, 이 함수가 한 번의
  # 판정 안에서 편집 대상과 앵커 전부에 대해 불리기 때문이다.
  local q="$1" keep="${2:-}" comp out="" oldifs
  HOOK_NORM=""
  case "$q" in
    '~')   q="${HOME:-}" ;;
    '~/'*) q="${HOME:-}/${q#\~/}" ;;
  esac
  case "$q" in
    /*) ;;
    *)  case "${PWD:-}" in
          /*) q="${PWD}/$q" ;;
          *)  return 1 ;;
        esac ;;
  esac
  oldifs="$IFS"; IFS='/'; set -f
  for comp in $q; do
    case "$comp" in
      ''|.) ;;
      ..)   if [ -n "$keep" ]; then out="$out/$comp"; else out="${out%/*}"; fi ;;
      *)    out="$out/$comp" ;;
    esac
  done
  set +f; IFS="$oldifs"
  HOOK_NORM="${out:-/}"
}

hook_abs() {
  # hook_abs <경로> — 위와 같되 `..` 를 접지 않는다. 후행 `/` 와 `/./` 는 여기서도
  # 없앤다: 없애지 않으면 `${ap%/*}` 로 부모를 떼는 자리가 한 단계 어긋난다.
  hook_lexnorm "$1" keep
}

hook_lexnorm_var() {
  # hook_lexnorm_var <변수명> — 앵커를 제자리에서 정규화한다. 비교의 한쪽만
  # 정규화하면 두 변이 서로 다른 네임스페이스에 놓여, 같은 파일을 가리키는 두
  # 철자가 여전히 갈린다 — 측정된 사례가 정확히 그것이었다: 런 디렉터리 경로에
  # 담긴 `//` 하나가 정규화된 편집 대상과 정규화되지 않은 레인 앵커를 갈라
  # 놓아, 형제 레인 거부가 통째로 통과했다.
  local cur
  eval "cur=\${$1:-}"
  # 빈 앵커는 손대지 않는다. 빈 문자열을 정규화하면 현재 디렉터리가 되어, 아무것도
  # 가리키지 않던 변수가 갑자기 실재하는 디렉터리를 가리키는 분기가 된다.
  [ -n "$cur" ] || return 0
  hook_lexnorm "$cur" || return 0
  [ -n "$HOOK_NORM" ] && eval "$1=\$HOOK_NORM"
  return 0
}

hook_ino() {
  # hook_ino <경로> — 위에서 한 번에 잰 표에서 그 경로의 디바이스:아이노드를
  # `HOOK_INO` 에 넣는다. 표에 없으면(그 경로가 실재하지 않으면) 거짓.
  # 명령 치환을 쓰지 않는 이유는 그것이 곧 fork 이고, 이 함수는 한 번의 판정
  # 안에서 수십 번 불리기 때문이다.
  local want="$1" line rest="$INOS"
  HOOK_INO=""
  while [ -n "$rest" ]; do
    line="${rest%%"$NL"*}"
    case "$rest" in
      *"$NL"*) rest="${rest#*"$NL"}" ;;
      *)       rest="" ;;
    esac
    # `%d:%i` 에는 공백이 없으므로 첫 공백 뒤가 곧 경로다 — 공백을 담은 경로도
    # 이 방식이면 온전히 복원된다.
    if [ "${line#* }" = "$want" ]; then HOOK_INO="${line%% *}"; return 0; fi
  done
  return 1
}

hook_stat_probe() {
  # 이 호스트의 stat 이 디바이스:아이노드를 내는 철자를 확정해 `HOOK_STAT_FMT` 에
  # 넣는다. 통하는 철자가 없으면 거짓.
  #
  # 철자가 둘인 이유: BSD stat 은 `-f` 가 포맷 지정자이고, GNU coreutils 는 `-f`
  # 가 `--file-system` 이라 같은 글자가 전혀 다른 것을 뜻한다. GNU 의 포맷 플래그는
  # `-c` 이고, GNU 의 `%N` 은 이름을 인용부호로 감싸므로 여기서는 `%n` 이어야
  # 아래 표 조회의 「첫 공백 뒤가 곧 경로」가 성립한다.
  #
  # 판정을 종료 코드가 아니라 출력의 모양으로 하는 이유: GNU 는 `-f` 를 받고도
  # 나머지 피연산자에 대해 파일시스템 블록을 성공적으로 찍으므로, 종료 코드만
  # 보면 「통했다」와 「엉뚱한 것을 찍었다」가 갈리지 않는다.
  local out
  out=$(stat -L -f '%d:%i %N' / 2>/dev/null)   # lint-bash-portability: disable=stat -f
  case "$out" in [0-9]*:[0-9]*' /') HOOK_STAT_FMT=bsd; return 0 ;; esac
  out=$(stat -L -c '%d:%i %n' / 2>/dev/null)   # lint-bash-portability: disable=stat -c
  case "$out" in [0-9]*:[0-9]*' /') HOOK_STAT_FMT=gnu; return 0 ;; esac
  HOOK_STAT_FMT=""; return 1
}

hook_leaf_is_symlink() {
  # hook_leaf_is_symlink <경로> — 말단 자신이 심링크인가. 셸 내장 `[ -L ]` 은
  # lstat 만 보므로 표적이 실재하는지와 무관하게 답한다: 매달린 심링크도
  # 「심링크 맞음」이고, 아직 만들어지지 않은 말단은 「심링크 아님」이 된다 —
  # 계획 방출과 중단 기록이 그 정상 경로다.
  #
  # 이전 형태는 `-L` 판독과 비-`-L` 판독을 비교했고 macOS 에서 틀렸다. BSD 의
  # `stat(1)` 은 `-L` 로 stat(2) 가 실패하면 조용히 lstat 판독을 내므로 매달린
  # 심링크에서 두 값이 같아져 「심링크 아님」이 됐다 — GNU 는 반대로 답해 같은
  # 코드가 플랫폼마다 다른 답을 냈다. 그리고 판독 실패와 「말단이 아직 없다」가
  # 한 분기로 접혀, 판정 불가가 허용으로 샜다. 내장 판정에는 그 두 실패가 없고,
  # 발산 철자를 늘리지 않으며, fork 를 하지 않는다.
  #
  # 하드링크는 이 검사로 잡히지 않고 그것이 맞는 답이다 — 하드링크에는 따라갈
  # 링크가 없고 표적과 아이노드를 공유하므로, 이름과 파일을 가르는 그 갈래는
  # 심링크 검사가 아니라 아이노드 쪽 판정이 져야 한다.
  [ -L "$1" ]
}

hook_is() {
  # hook_is <경로> — 정규화된 편집 대상이 그 경로와 같은 파일인가. 철자가 아니라
  # 아이노드로 답하므로 심링크 꼬리와 대체 절대 철자가 함께 닫힌다.
  [ -n "$NP_INO" ] || return 1
  hook_ino "$1" || return 1
  [ "$HOOK_INO" = "$NP_INO" ]
}

hook_under() {
  # hook_under <디렉터리> — 정규화된 편집 대상이 그 디렉터리 아래인가. 참이면
  # 그 아래의 꼬리를 `HOOK_TAIL` 에 남긴다(허용 목록 판정이 그것을 쓴다).
  #
  # 조상 사슬을 아래에서 위로 훑으므로 존재하지 않는 말단은 그대로 통과한다 —
  # 실재하는 최심 조상에서 동일성이 맞으면 되고, 그 위로는 볼 필요가 없다.
  # 「존재를 조건으로 걸지 않는다」는 아래 형제 레인 결정이 살아 있어야 한다.
  hook_ino "$1" || return 1
  local dino="$HOOK_INO" a base tail=""
  [ -n "$dino" ] || return 1
  a="$np"; HOOK_TAIL=""
  while [ "$a" != "/" ]; do
    base="${a##*/}"
    a="${a%/*}"; [ -n "$a" ] || a="/"
    tail="$base${tail:+/}$tail"
    if hook_ino "$a" && [ "$HOOK_INO" = "$dino" ]; then
      HOOK_TAIL="$tail"; return 0
    fi
  done
  return 1
}

HOOK_PHYS=""
hook_phys() {
  # hook_phys <절대 경로> — 실재하는 가장 깊은 조상에서 물리 철자를 한 번 얻고 그
  # 아래 남은 어휘 꼬리를 다시 이어 붙여 `HOOK_PHYS` 에 넣는다. 얻지 못하면 거짓.
  #
  # 왜 필요한가. 위 `hook_under` 는 조상 **성분**을 아이노드로 비교하지만 사슬을
  # 거슬러 오르는 것은 **어휘적**이다. 그래서 앵커된 디렉터리를 *가리키는* 링크는
  # 잡히고(그 성분의 아이노드가 앵커와 같다) 그 **안쪽**을 가리키는 링크는 잡히지
  # 않는다 — 그 성분의 아이노드는 앵커가 아니고, 그 성분의 부모는 어휘 사슬에 없어
  # 영원히 검사되지 않는다. `$RUN_DIR` 은 보호 대상이 바로 안에 있는 **말단 앵커**라
  # 링크가 반드시 앵커를 사슬에 등장시키지만, `run_root` 는 보호 대상이 한 단계 더
  # 깊은 **비말단 앵커**라 그 한 단계를 링크로 건너뛰면 앵커가 사슬에 아예 등장하지
  # 않는다. 무한한 것은 앵커할 파일 집합이 아니라 앵커와 보호 대상 사이의 깊이이므로
  # 팔을 하나 더 붙여 닫을 수 있는 형태가 아니고, 철자를 한 번 접는 것이 답이다.
  #
  # 존재를 조건으로 걸지 않는다. 아직 만들어지지 않은 디렉터리 아래로 쓰는 것은 이
  # 트리 어디서나 정당하므로, 실재하지 않는 부모에서 곧바로 거부하면 런 루트와 무관한
  # 경로까지 함께 막는다. 실재하는 조상에서 접으면 그 성질이 그대로 유지된다.
  #
  # 상대 경로와 빈 문자열은 거짓이다. 어휘 사슬을 거슬러 오르는 루프가 절대 경로를
  # 전제하므로, 아니면 `/` 에 닿지 못하고 돌지 않는 루프가 된다.
  local p="$1" tail="" base out
  HOOK_PHYS=""
  case "$p" in /*) : ;; *) return 1 ;; esac
  while :; do
    if [ -d "$p" ]; then
      out=$(cd "$p" 2>/dev/null && pwd -P) || return 1
      [ -n "$out" ] || return 1
      if [ -n "$tail" ]; then HOOK_PHYS="${out%/}/$tail"; else HOOK_PHYS="$out"; fi
      return 0
    fi
    [ "$p" != "/" ] || return 1
    base="${p##*/}"
    p="${p%/*}"; [ -n "$p" ] || p="/"
    tail="$base${tail:+/}$tail"
  done
}

hook_run_dir_verdict() {
  # hook_run_dir_verdict <이 런 디렉터리 아래의 꼬리> — 스테이지에게 선언된 쓰기
  # 표면인지 판정한다. 거부면 여기서 끝나고, 허용이면 돌아간다.
  #
  # 함수인 이유는 호출자가 둘이기 때문이다 — 호출자가 준 철자로 도는 1차 패스와,
  # 심링크 조상을 접은 물리 철자로 도는 2차 패스. 나란한 두 사본을 두면 한쪽만 고쳐도
  # 스위트가 초록이고, 그 실패 방식은 이 파일이 이미 여러 자리에 적어 둔 것이다.
  case "$1" in
    settings/*)
      deny "$(jstr 'gate: 런 설정 디렉터리는 강제 표면입니다 — 여기 한 번 쓰면 이 스테이지의 경계가 통째로 사라집니다')" ;;
    # 깊이 팔이 한 단계 팔보다 먼저 와야 한다. 반대 순서면 `halt/deep/x.md`
    # 가 한 단계 팔에 먼저 걸려 허용된다.
    halt/*/*)
      deny "$(jstr 'gate: 런 디렉터리의 중단 기록은 halt/<stage-id>.md 한 단계뿐입니다')" ;;
    halt/*)
      hook_leaf_is_symlink "$ap" \
        && deny "$(jstr 'gate: 런 디렉터리의 허용 이름이라도 말단이 심링크면 판정할 수 없습니다 — 허용된 것은 이름이 아니라 그 자리에 있는 파일입니다')" ;;
    */*)
      deny "$(jstr 'gate: 런 디렉터리에서 스테이지가 쓰도록 선언된 것은 halt/<stage-id>.md 와 <segment>.plan.md 뿐입니다 — 나머지는 게이트가 매 행위마다 되읽는 기준선이라, 스테이지가 고치면 강제 표면 검사가 자기 자신을 기준으로 다시 잡힙니다')" ;;
    # 허용되는 것은 이름이 아니라 그 자리에 있는 파일이다. 이름만 맞춘 심링크는
    # 이 디렉터리의 다른 어떤 파일로도 향할 수 있으므로 거부한다.
    *.plan.md)
      hook_leaf_is_symlink "$ap" \
        && deny "$(jstr 'gate: 런 디렉터리의 허용 이름이라도 말단이 심링크면 판정할 수 없습니다 — 허용된 것은 이름이 아니라 그 자리에 있는 파일입니다')" ;;
    *)
      deny "$(jstr 'gate: 런 디렉터리에서 스테이지가 쓰도록 선언된 것은 halt/<stage-id>.md 와 <segment>.plan.md 뿐입니다 — 나머지는 게이트가 매 행위마다 되읽는 기준선이라, 스테이지가 고치면 강제 표면 검사가 자기 자신을 기준으로 다시 잡힙니다')" ;;
  esac
  return 0
}

# Prepended so `jq` is discoverable regardless of the caller's PATH — the same
# convention the sibling hook uses. The disable switch exists so the fail-closed
# branch below is reachable in a test; on a machine with jq installed there is
# otherwise no way to exercise the one branch whose failure is invisible.
if [ -z "${CC_CMDS_GATE_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
if ! command -v jq >/dev/null 2>&1; then
  # Fail CLOSED. The sibling hook exits 0 here and defers to the default gate;
  # under `--dangerously-skip-permissions` there IS no default gate, so the same
  # line would allow everything.
  deny "$(jstr 'gate: jq 를 찾지 못해 이 호출을 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
fi

input=$(cat)
[ -n "$input" ] || deny "$(jstr 'gate: 훅 입력이 비어 있습니다 — 판정 불가는 허용이 아닙니다')"
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
# An empty tool name is not a tool this hook has no opinion about; it is an
# input it could not read. The two must not share a branch — the second is a
# reason to defer and the first is a reason to refuse.
[ -n "$tool" ] || deny "$(jstr 'gate: 도구 이름을 읽지 못했습니다 — 판정 불가는 허용이 아닙니다')"

# ---------------------------------------------------------------------------
# Write / Edit — the enforcement surfaces
#
# Six files decide whether enforcement holds at all, and a stage that writes one
# of them weakens the boundary it is standing inside. The hook covers all six
# rather than the two the first draft covered: the other four were left to
# after-the-fact digest comparison, and after-the-fact detection of a settings
# file rewrite is detection of a boundary that was already gone.
# ---------------------------------------------------------------------------
case "$tool" in
  Write|Edit|NotebookEdit|MultiEdit)
    p=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$p" ] || allow "$(jstr 'gate: 경로 없는 편집 — 판정 대상 아님')"
    hook_self=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

    # A CONTROL CHARACTER IN THE PATH IS UNJUDGEABLE, NOT HARMLESS. The identity
    # comparison below reads `stat`'s line-oriented output, so a path carrying a
    # newline would split a record and be compared against a fragment of itself.
    # Same rule as everywhere else in this file: cannot judge is not allow.
    if [ "$p" != "$(printf '%s' "$p" | tr -d '[:cntrl:]')" ]; then
      deny "$(jstr 'gate: 제어 문자를 담은 편집 경로는 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
    fi
    hook_lexnorm "$p" && np="$HOOK_NORM"
    [ -n "$np" ] || deny "$(jstr 'gate: 편집 대상을 절대 경로로 해소하지 못했습니다 — 판정 불가는 허용이 아닙니다')"
    # `..` 를 접지 않은 절대 철자. `stat -L` 에 이대로 넘기면 커널이 상위 참조와
    # 심링크를 자기 규칙으로 해소하므로, 그 값이 곧 도구가 실제로 여는 파일이다.
    hook_abs "$p" && ap="$HOOK_NORM"
    [ -n "$ap" ] || deny "$(jstr 'gate: 편집 대상을 절대 경로로 해소하지 못했습니다 — 판정 불가는 허용이 아닙니다')"

    # BOTH SIDES OF EVERY COMPARISON GET NORMALIZED, not just the edit target.
    # A guard anchored at a variable that still carries its raw spelling sits in
    # a different namespace from the normalized target, and the pattern stops
    # matching — a deny arm that silently becomes an allow, which is the exact
    # failure this whole layer exists to remove.
    hook_lexnorm_var RUN_DIR
    hook_lexnorm_var hook_self
    hook_lexnorm_var LEDGER
    hook_lexnorm_var GRANT
    hook_lexnorm_var HOME

    # THE USER-SCOPE CONFIG DIRECTORY IS RESOLVED, NOT ASSUMED. The literal
    # `*/.claude/...` arms further down cover a default installation and the
    # project-scope `.claude/` of any repository, but `CLAUDE_CONFIG_DIR`
    # relocates the USER-scope one — and on a machine where it points at, say,
    # `~/.claude-cc`, the glob stops matching and the deny silently becomes an
    # allow. That file holds `hooks` and `permissions`: it is the very
    # installation channel these arms exist to close. The failure signature is
    # invisibility — the patterns read correctly, and the protection is present
    # on the reviewer's default machine and absent on the one the pipeline runs
    # on. Relocating the config directory is supported usage, not an exotic
    # setup.
    #
    # Resolved up here rather than inline in an arm, because an arm built from
    # an empty variable would degrade into a pattern that matches something else
    # (`/settings.json`) instead of matching nothing.
    cfg="${CLAUDE_CONFIG_DIR:-}"
    [ -n "$cfg" ] || cfg="${HOME:-}${HOME:+/.claude}"
    cfg="${cfg%/}"
    # And the operator-scope one. The lane the driver records here is read by
    # every FUTURE run, so a write into it outlives this run entirely — the same
    # property the sibling-lane arms exist to deny, arriving through a different
    # tier. The whole directory is guarded rather than the one file: nothing a
    # stage legitimately does writes here, and naming a single file would leave
    # the next neighbouring file open for the same reason.
    xdgcc="${XDG_CONFIG_HOME:-}"
    [ -n "$xdgcc" ] || xdgcc="${HOME:-}${HOME:+/.config}"
    xdgcc="${xdgcc%/}"; xdgcc="${xdgcc:+$xdgcc/cc-cmds}"
    # AND THE ROOT EVERY RUN DIRECTORY HANGS OFF. `$RUN_DIR` names THIS run, so
    # every arm parameterized by it stops at the boundary of this run — and
    # another run's directory is literally a sibling of it, one component
    # across. Derived the same way the driver derives it, from the same two
    # variables, so the two cannot drift into different namespaces.
    #
    # Empty when neither variable is set, and the arm below is skipped rather
    # than anchored at `/.local/state/...` — an anchor built from an empty
    # variable degrades into one that matches something else, which is the
    # failure the `cfg` derivation above already argues against.
    run_root="${XDG_STATE_HOME:-}"
    [ -n "$run_root" ] || run_root="${HOME:-}${HOME:+/.local/state}"
    run_root="${run_root%/}"; run_root="${run_root:+$run_root/cc-cmds/run}"
    # 이 셋은 환경변수에서 방금 만들어졌으므로 앞의 일괄 정규화가 닿지 않는다.
    hook_lexnorm_var cfg
    hook_lexnorm_var xdgcc
    hook_lexnorm_var run_root

    # ONE `stat` CALL FOR THE WHOLE DECISION: the edit target's ancestor chain
    # plus every guarded path, measured together. `-L` follows symlinks, which
    # is what closes a symlinked tail; a nonexistent argument is skipped and the
    # rest still print, which is what lets a not-yet-created leaf stay allowed.
    #
    # THE DIRECTORY IS AN ANCHOR IN ADDITION TO THE FILES INSIDE IT, NOT INSTEAD
    # OF THEM — the two close different vectors and neither is a superset.
    #
    #   - The DIRECTORY anchor is what covers a lane whose `settings.json` does
    #     not exist yet: an anchor at that file makes the identity layer absent
    #     exactly in the window this file says it must cover, a stage creating a
    #     lane and writing its settings on the way in. The lane directory came
    #     from a glob so it always exists, and a tail comparison off it closes
    #     the case-insensitive spelling and the symlinked ancestor together.
    #   - The FILE anchor is what covers a symlinked LEAF. `hook_under` walks the
    #     ancestors of the edit target's own spelling, so a link sitting outside
    #     the lane and pointing at the lane's settings file has no ancestor in
    #     common with it and the directory anchor never fires — only comparing
    #     the leaf's own inode against that file's does. Measured: dropping the
    #     file anchors turned the symlinked-tail assertion from deny to allow.
    ap_par="${ap%/*}"; [ -n "$ap_par" ] || ap_par="/"
    np_par="${np%/*}"; [ -n "$np_par" ] || np_par="/"
    stat_args=( "$np" "$ap" "$ap_par" )
    a="$np"
    while [ "$a" != "/" ]; do
      a="${a%/*}"; [ -n "$a" ] || a="/"
      stat_args[${#stat_args[@]}]="$a"
    done
    stat_args[${#stat_args[@]}]="$RUN_DIR"
    stat_args[${#stat_args[@]}]="$RUN_DIR/settings"
    [ -n "$run_root" ] && stat_args[${#stat_args[@]}]="$run_root"
    stat_args[${#stat_args[@]}]="$hook_self"
    [ -n "$LEDGER" ] && stat_args[${#stat_args[@]}]="$LEDGER"
    [ -n "$GRANT" ]  && stat_args[${#stat_args[@]}]="$GRANT"
    if [ -n "$cfg" ]; then
      stat_args[${#stat_args[@]}]="$cfg"
      stat_args[${#stat_args[@]}]="$cfg/settings.json"
      stat_args[${#stat_args[@]}]="$cfg/settings.local.json"
      stat_args[${#stat_args[@]}]="$cfg/projects"
    fi
    [ -n "$xdgcc" ] && stat_args[${#stat_args[@]}]="$xdgcc"
    if [ -n "${HOME:-}" ]; then
      for lane in "$HOME"/.claude*; do
        case "$lane" in *'*') continue ;; esac
        stat_args[${#stat_args[@]}]="$lane"
        stat_args[${#stat_args[@]}]="$lane/settings.json"
        stat_args[${#stat_args[@]}]="$lane/settings.local.json"
        stat_args[${#stat_args[@]}]="$lane/projects"
      done
    fi
    # 철자를 먼저 확정한다. 확정되지 않으면 아이노드 계층이 통째로 없는 것이고,
    # 그 상태에서 계속 가면 「같은 파일이 아니다」와 「알 수 없다」가 같은 답을 낸다.
    hook_stat_probe || deny "$(jstr 'gate: 이 호스트의 stat 이 디바이스:아이노드를 내지 않아 경로 동일성을 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
    case "$HOOK_STAT_FMT" in
      bsd) INOS=$(stat -L -f '%d:%i %N' "${stat_args[@]}" 2>/dev/null) ;;  # lint-bash-portability: disable=stat -f
      gnu) INOS=$(stat -L -c '%d:%i %n' "${stat_args[@]}" 2>/dev/null) ;;  # lint-bash-portability: disable=stat -c
    esac
    # `/` 는 조상 사슬의 끝이라 언제나 피연산자에 있다. 그러므로 표에 `/` 조차
    # 없다는 것은 「그 경로가 실재하지 않는다」가 아니라 「표를 만들지 못했다」이고,
    # 그것은 판정이 아니라 판정 실패다. 실패를 삼키면 그 뒤의 모든 아이노드 팔이
    # 조용히 거짓이 되어, 어휘 팔이 놓치는 철자가 전부 통과한다.
    hook_ino / || deny "$(jstr 'gate: 경로 동일성 표를 만들지 못해 이 편집을 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"

    # 아이노드는 커널이 여는 경로에서 잰다. 어휘 정규화는 파일시스템을 읽지 않고
    # `..` 를 접으므로, 심링크 디렉터리를 낀 철자에서는 도구가 실제로 여는 파일과
    # 다른 파일의 아이노드를 정확하게 재는 결과가 된다.
    NP_INO=""
    hook_ino "$ap" && NP_INO="$HOOK_INO"

    # 말단이 심링크인데 표적이 없으면 아이노드를 잴 것이 없다. BSD 의 `stat -L` 은
    # 그때 lstat 로 떨어져 링크 자신의 값을 rc=0 으로 내고 GNU 는 줄을 내지 않아,
    # 어느 쪽이든 파일 앵커가 통째로 죽는다. 링크는 강제 표면 밖에 앉을 수 있어
    # 조상이 겹치지 않으므로 디렉터리 앵커도 서지 않고, 철자는 링크 자신의 것이라
    # 어휘 팔도 서지 않는다 — 그 상태로 허용하면 커널이 링크를 따라가 강제 표면
    # 안에 파일을 만든다. `[ -e ]` 는 심링크를 따라가므로 매달린 링크에서만 참이
    # 되고, 아직 만들어지지 않은 **일반** 말단(계획 방출·중단 기록)은 심링크가
    # 아니라 앞 조건에서 이미 갈린다.
    #
    # 아래 두 해소 대조보다 앞에 서야 한다. 그 둘은 아이노드 값의 일치를 보는데
    # 매달린 말단에서는 양쪽이 함께 비어 통과해 버린다.
    if hook_leaf_is_symlink "$ap" && [ ! -e "$ap" ]; then
      deny "$(jstr 'gate: 편집 대상의 말단이 표적 없는 심링크입니다 — 아이노드로 판정할 수 없으므로 거부합니다. 판정 불가는 허용이 아닙니다')"
    fi

    # 두 계층의 화해. 어휘 해소와 커널 해소가 서로 다른 것을 가리키면 훅 앞에는
    # 파일이 둘 있는 것이고, 어느 쪽을 판정 대상으로 삼을 근거가 없다. 두 쪽 모두
    # 실재하지 않으면 두 값이 다 비어 통과하므로, 아직 만들어지지 않은 말단이
    # 정상 통과한다는 성질은 유지된다. `..` 가 없는 철자는 두 변이 같은 문자열이라
    # 이 검사가 항상 통과한다 — 오늘 통과하는 경로의 판정은 바뀌지 않는다.
    lex_leaf=""; hook_ino "$np" && lex_leaf="$HOOK_INO"
    [ "$lex_leaf" = "$NP_INO" ] || deny "$(jstr 'gate: 이 경로의 어휘 해소와 커널 해소가 다른 파일을 가리킵니다 — 판정 불가는 허용이 아닙니다. 상위 참조와 심링크를 걷어낸 철자로 다시 부르세요')"
    phys_par=""; hook_ino "$ap_par" && phys_par="$HOOK_INO"
    lex_par="";  hook_ino "$np_par" && lex_par="$HOOK_INO"
    [ "$phys_par" = "$lex_par" ] || deny "$(jstr 'gate: 이 경로의 상위 디렉터리가 어휘 해소와 커널 해소에서 다릅니다 — 판정 불가는 허용이 아닙니다. 상위 참조와 심링크를 걷어낸 철자로 다시 부르세요')"

    # 런 설정 디렉터리는 런 디렉터리 안에서 아이노드 앵커가 없는 유일한 게이트
    # 소유 디렉터리였다. `hook_under` 는 조상 사슬을 아래에서 위로 훑어 가장 깊은
    # 일치에서 접으므로, 중간 성분이 이 디렉터리로 해소되면 그 조상이 아무와도
    # 비교되지 않고 사슬이 런 디렉터리까지 떨어진다 — 그러면 꼬리가 허용 이름으로
    # 나오고 허용 팔이 답한다. 같은 파일의 직접 철자는 거부되므로, 그 순간 허용
    # 목록 자신의 거부 팔이 철자만으로 우회된다. 아래 `settings/*` 팔은 꼬리
    # 철자를 보므로 이 경우를 볼 수 없다 — 앵커가 그 블록보다 앞에 서야 한다.
    # 같은 패턴이 이미 이 파일의 `$cfg/projects`·`$lane/projects` 앵커에 있다.
    if hook_under "$RUN_DIR/settings"; then
      deny "$(jstr 'gate: 런 설정 디렉터리는 강제 표면입니다 — 여기 한 번 쓰면 이 스테이지의 경계가 통째로 사라집니다')"
    fi

    # THE RUN DIRECTORY IS AN ALLOW-LIST, NOT A DENY-LIST — the same inversion
    # this file's header argues for, applied to the one storage area that was
    # still default-allow. It holds the values the gate itself re-reads as the
    # baseline of every act: a stage that rewrites `surface-digest` re-baselines
    # the enforcement-surface check against itself, and the Write/Edit half of
    # this hook carries no ledger requirement, so that write leaves no row
    # either. The contract table for this directory names exactly two paths whose
    # declared writer is a stage, and those two are the allow-list; it was not
    # invented here, only read off.
    run_tail=""
    if hook_under "$RUN_DIR"; then
      run_tail="$HOOK_TAIL"
    else
      case "$np" in
        "$RUN_DIR"/*) run_tail="${np#"$RUN_DIR"/}" ;;
      esac
    fi
    if [ -n "$run_tail" ]; then
      hook_run_dir_verdict "$run_tail"
    fi
    # AND THAT ALLOW-LIST IS PARAMETERIZED BY **THIS** RUN, WHICH LEFT EVERY
    # OTHER RUN DEFAULT-ALLOW. `run_tail` is computed from `$RUN_DIR` alone, so a
    # path one component across — another run's directory — matched no arm here
    # and fell through to the final allow. Measured: this run's `config-dir`,
    # `orchestrator-dir` and `settings/<kind>.json` all deny, and a sibling run's
    # same three names all allow. Neither is an incidental file.
    # `<run>/settings/<kind>.json` IS that run's hook and permission set — the
    # denial text a few lines up states its own weight — and `<run>/config-dir`
    # is the lane every dispatch of that run resolves its account from. One plain
    # `Write` with a plain absolute path reaches both: no link, no shell rider,
    # and the Write/Edit half of this hook carries no ledger requirement, so the
    # write leaves no row either.
    #
    # SO THE RUN ROOT IS ANCHORED IN ADDITION TO THIS RUN, and the structure is
    # inverted rather than extended: under the root but not under `$RUN_DIR` is
    # an immediate refusal, because a stage writing into a run that is not its
    # own has no legitimate form worth preserving. Under `$RUN_DIR` the list
    # above is unchanged.
    #
    # ORDER IS LOAD-BEARING. This arm runs AFTER that block and only when
    # `run_tail` came back empty. Placed before it, or without that test, it
    # would deny this run's own `halt/<stage-id>.md` and `<segment>.plan.md` —
    # the two paths whose declared writer is a stage.
    if [ -z "$run_tail" ] && [ -n "$run_root" ]; then
      if hook_under "$run_root" || hook_is "$run_root"; then
        deny "$(jstr 'gate: 다른 런의 디렉터리입니다 — 스테이지가 자기 런이 아닌 런의 디렉터리에 쓰는 정당한 경우는 없습니다. 그 아래에는 그 런의 훅·권한 설정과 레인 기록이 있어, 한 번 쓰면 그 런의 경계와 계정 선택이 이 스테이지의 손에 들어갑니다')"
      fi
      # 어휘 팔. 아직 만들어지지 않은 런 디렉터리에는 비교할 아이노드가 없고,
      # 그 창이야말로 위 결정이 덮겠다고 선언한 것이다 — 열리지 않은 런에 기록을
      # 심어 두면 그 런의 초기화가 그것을 보존한 채 시작한다.
      case "$np" in
        "$run_root"|"$run_root"/*)
          deny "$(jstr 'gate: 다른 런의 디렉터리입니다 — 스테이지가 자기 런이 아닌 런의 디렉터리에 쓰는 정당한 경우는 없습니다. 그 아래에는 그 런의 훅·권한 설정과 레인 기록이 있어, 한 번 쓰면 그 런의 경계와 계정 선택이 이 스테이지의 손에 들어갑니다')" ;;
      esac

      # 그리고 물리 철자로 한 번 더 판정한다 — 두 팔 모두 통과했다는 것이 「런 루트
      # 밖」을 뜻하지 않기 때문이다. 아이노드 팔은 조상 성분을 아이노드로 비교하되
      # 사슬을 **어휘적**으로 거슬러 오르므로, 피해 런 디렉터리를 가리키는 링크를 런
      # 루트 **밖**에 두고 그 아래로 쓰면 앵커가 사슬에 아예 등장하지 않는다. 어휘
      # 팔은 그 철자가 `run_root` 로 시작하지 않으니 당연히 서지 않는다. 실측된
      # 우회가 `L-victim/config-dir`·`L-victim/settings/impl.json`·
      # `L-victim/orchestrator-dir` 이고, 실제 `Write` 도구가 그 링크를 관통해 피해
      # 런 안에 파일을 만드는 것까지 확인됐다(링크는 링크로 남았다 — 관통이지 교체가
      # 아니다). 링크 생성이 무해하지도 않다: 맨 `ln -s` 는 게이트가 `등급 미상`으로
      # 거부하지만 `bash -c` 로 감싸면 통과하고, 그 뒤의 `Write` 는 원장에 행을 남기지
      # 않는다.
      #
      # 비교의 **양쪽을 함께** 접는다. 한쪽만 물리화하면 macOS 에서 `/tmp` 가
      # `/private/tmp` 로의 심링크라 앵커 전체와 갈려, 링크와 무관한 자기 런 직접
      # 철자까지 함께 무너진다 — 그 잘못된 패치를 실제로 넣은 관측이 420 passed,
      # 27 failed 였다.
      #
      # 판정 불가는 허용이 아니다. 실재하는 조상에서 `cd` 가 실패하면 이 경로가 어느
      # 런 아래인지 말할 수 없으므로 거부한다. 실재하지 않는 부모는 판정 불가가 아니라
      # 정상이며 `hook_phys` 가 위로 올라가 접는다.
      hook_phys "$ap" \
        || deny "$(jstr 'gate: 편집 대상의 물리 철자를 얻지 못해 어느 런 아래인지 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
      phys_np="$HOOK_PHYS"
      hook_phys "$run_root" \
        || deny "$(jstr 'gate: 런 루트의 물리 철자를 얻지 못해 이 편집을 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
      phys_rr="$HOOK_PHYS"
      hook_phys "$RUN_DIR" \
        || deny "$(jstr 'gate: 이 런 디렉터리의 물리 철자를 얻지 못해 이 편집을 판정할 수 없습니다 — 판정 불가는 허용이 아닙니다')"
      phys_rd="$HOOK_PHYS"
      # 이 런의 팔이 형제 런의 팔보다 앞에 와야 한다. `$RUN_DIR` 이 `run_root` 아래라
      # 반대 순서면 이 런의 허용 이름까지 형제 런 문면으로 거부된다.
      case "$phys_np" in
        "$phys_rd")   : ;;
        "$phys_rd"/*) hook_run_dir_verdict "${phys_np#"$phys_rd"/}" ;;
        "$phys_rr"|"$phys_rr"/*)
          deny "$(jstr 'gate: 다른 런의 디렉터리입니다 — 스테이지가 자기 런이 아닌 런의 디렉터리에 쓰는 정당한 경우는 없습니다. 그 아래에는 그 런의 훅·권한 설정과 레인 기록이 있어, 한 번 쓰면 그 런의 경계와 계정 선택이 이 스테이지의 손에 들어갑니다')" ;;
      esac
    fi
    if hook_under "$hook_self"; then
      deny "$(jstr 'gate: 훅 스크립트 자신은 강제 표면입니다')"
    fi
    case "$np" in
      "$hook_self"/*)
        deny "$(jstr 'gate: 훅 스크립트 자신은 강제 표면입니다')" ;;
    esac
    if [ -n "$xdgcc" ]; then
      if hook_under "$xdgcc" || hook_is "$xdgcc"; then
        deny "$(jstr 'gate: 운영자 스코프 설정 디렉터리는 강제 표면입니다 — 여기 기록된 레인은 이 런이 끝난 뒤의 런들이 읽으므로, 여기 쓰는 것은 런보다 오래 사는 편집입니다')"
      fi
      case "$np" in
        "$xdgcc"|"$xdgcc"/*)
          deny "$(jstr 'gate: 운영자 스코프 설정 디렉터리는 강제 표면입니다 — 여기 기록된 레인은 이 런이 끝난 뒤의 런들이 읽으므로, 여기 쓰는 것은 런보다 오래 사는 편집입니다')" ;;
      esac
    fi
    if [ -n "$LEDGER" ] && { [ "$np" = "$LEDGER" ] || hook_is "$LEDGER"; }; then
      deny "$(jstr 'gate: 원장의 기록자는 게이트뿐입니다 — 행을 남기려면 gate.sh act 또는 gate.sh exec 를 쓰세요')"
    fi
    if [ -n "$GRANT" ] && { [ "$np" = "$GRANT" ] || hook_is "$GRANT"; }; then
      deny "$(jstr 'gate: 인가 기록은 킥오프만 씁니다 — 런 중에는 읽기 전용입니다')"
    fi
    if [ -n "$cfg" ]; then
      case "$np" in
        "$cfg"/settings.json|"$cfg"/settings.local.json)
          deny "$(jstr 'gate: 사용자 스코프 설정은 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
        "$cfg"/projects/*)
          deny "$(jstr 'gate: 세션 트랜스크립트는 승인 판독 채널이라 강제 표면입니다')" ;;
        # THE ROLLBACK SOURCES. A run that applies CLAUDE.md is judged in the
        # morning by comparing the live file against a baseline taken before the
        # night, and the harness keeps its own per-version copies beside it. Both
        # are read-only evidence for that comparison: a stage that can write
        # either one can make its own edit look like it was there all along, and
        # the comparison then succeeds while meaning nothing. Denied for the same
        # reason the ledger is — the writer is not the party being audited.
        "$cfg"/backups/*|"$cfg"/file-history/*)
          deny "$(jstr 'gate: 롤백 기준선과 판본 이력은 아침 판정의 증거라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
      esac
      # 디렉터리 앵커. 그 아래의 두 파일과 `projects/` 는 아직 없을 수 있고,
      # 없는 파일에는 비교할 아이노드가 없다.
      if hook_under "$cfg"; then
        case "$HOOK_TAIL" in
          settings.json|settings.local.json)
            deny "$(jstr 'gate: 사용자 스코프 설정은 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
          projects/*)
            deny "$(jstr 'gate: 세션 트랜스크립트는 승인 판독 채널이라 강제 표면입니다')" ;;
        esac
      fi
      # 파일 앵커. 디렉터리 앵커는 편집 대상 자신의 조상 사슬을 훑으므로, 설정
      # 디렉터리 밖에 앉아 그 안을 가리키는 심링크는 조상이 겹치지 않아 걸리지
      # 않는다 — 말단의 아이노드를 그 파일의 것과 직접 대는 이쪽이 그것을 닫는다.
      if hook_is "$cfg/settings.json" || hook_is "$cfg/settings.local.json"; then
        deny "$(jstr 'gate: 사용자 스코프 설정은 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')"
      fi
      if hook_under "$cfg/projects"; then
        deny "$(jstr 'gate: 세션 트랜스크립트는 승인 판독 채널이라 강제 표면입니다')"
      fi
    fi
    # SIBLING LANES, and they are the hole the block above cannot close. `cfg`
    # is parameterized by the ONE config directory this stage happens to run in,
    # and the literal `*/.claude/...` arms below need the directory to be named
    # exactly `.claude` — so a stage running in `~/.claude-cc` may freely write
    # `~/.claude-cci/settings.json`. Measured: all nine deny arms driven, and
    # the sibling lane's user-scope settings were allowed. That file holds
    # `hooks`, so a stage can install a hook into the lane its own FUTURE runs
    # will load, which is the one edit that outlives the run entirely.
    #
    # THE DIRECTORY'S EXISTENCE IS DELIBERATELY NOT A CONDITION. Testing `-d`
    # would leave open the path where a stage CREATES the lane directory and
    # writes the settings on the way in — the guard would be absent exactly when
    # the lane is new, which is when nobody is looking at it.
    #
    # The `cfg` block above stays. `CLAUDE_CONFIG_DIR` can point outside `$HOME`
    # and this walk does not reach there; neither is a subset of the other.
    if [ -n "${HOME:-}" ]; then
      for lane in "$HOME"/.claude*; do
        # An unmatched glob expands to the literal pattern, and a pattern is not
        # a lane. Nothing here may depend on `nullglob`, which is off by default
        # and is not something a hook can assume of its caller.
        case "$lane" in *'*') continue ;; esac
        case "$np" in
          "$lane"/settings.json|"$lane"/settings.local.json)
            deny "$(jstr 'gate: 형제 레인의 사용자 스코프 설정도 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
          "$lane"/projects/*)
            deny "$(jstr 'gate: 형제 레인의 세션 트랜스크립트도 승인 판독 채널이라 강제 표면입니다')" ;;
        esac
        # 디렉터리 앵커. 글롭이 방금 낸 것이므로 반드시 실재하고, 그래서 말단의
        # 존재 여부와 무관하게 대소문자 변형·심링크 조상·대체 절대 철자가 전부
        # 아이노드로 만난다. 레인 안의 파일만 앵커로 삼으면 그 파일이 아직 없는
        # 새 레인에서 이 계층이 통째로 부재하는데, 새 레인이야말로 위 결정이
        # 덮겠다고 선언한 창이다.
        if hook_under "$lane"; then
          case "$HOOK_TAIL" in
            settings.json|settings.local.json)
              deny "$(jstr 'gate: 형제 레인의 사용자 스코프 설정도 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
            projects/*)
              deny "$(jstr 'gate: 형제 레인의 세션 트랜스크립트도 승인 판독 채널이라 강제 표면입니다')" ;;
          esac
        fi
        # 파일 앵커. 위가 편집 대상 자신의 조상 사슬을 훑으므로, 레인 밖에 앉아
        # 레인 안을 가리키는 심링크는 조상이 겹치지 않아 걸리지 않는다. 두 앵커는
        # 서로의 부분집합이 아니라 서로 다른 벡터를 닫는다.
        if hook_is "$lane/settings.json" || hook_is "$lane/settings.local.json"; then
          deny "$(jstr 'gate: 형제 레인의 사용자 스코프 설정도 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')"
        fi
        if hook_under "$lane/projects"; then
          deny "$(jstr 'gate: 형제 레인의 세션 트랜스크립트도 승인 판독 채널이라 강제 표면입니다')"
        fi
      done
      # THE LANE THAT DOES NOT EXIST YET. The loop above walks a glob, and a
      # glob only ever yields lanes that are already on disk — so the one shape
      # the decision above says must be covered, a stage CREATING a lane and
      # writing its settings on the way in, is the one shape the loop cannot
      # see. Lexical arms cover it, because there is no inode to compare
      # against when the file does not exist.
      #
      # 이 두 팔에 한해 대소문자를 무시한다. 대소문자를 무시하는 파일시스템에서
      # `.Claude-cci/settings.json` 은 진짜 형제 레인 안에 착지하는데, 디렉터리가
      # 아직 없으면 아이노드 팔이 없어 어휘 팔이 유일한 방어이기 때문이다.
      # 훅은 `bash "$HOOK"` 로 매번 새 셸에서 돌므로 진입 시 `nocasematch` 는 항상
      # off 다 — 그래서 저장·복원이 아니라 `-u` 로 되돌리는 것으로 충분하다.
      # 켜 둔 채로 빠져나가면 뒤따르는 접미 글롭 `case` 가 조용히 넓어진다.
      shopt -s nocasematch
      case "$np" in
        "$HOME"/.claude*/settings.json|"$HOME"/.claude*/settings.local.json)
          shopt -u nocasematch
          deny "$(jstr 'gate: 형제 레인의 사용자 스코프 설정도 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
        "$HOME"/.claude*/projects/*)
          shopt -u nocasematch
          deny "$(jstr 'gate: 형제 레인의 세션 트랜스크립트도 승인 판독 채널이라 강제 표면입니다')" ;;
      esac
      shopt -u nocasematch
    fi
    # The suffix globs have no anchor to compare an inode against, so these get
    # the lexical layer only — `..`, a relative path and a tilde are closed by
    # the normalization above, a symlinked ANCESTOR is not, and that residue is
    # stated rather than hidden.
    case "$np" in
      */.claude/settings.json|*/.claude/settings.local.json)
        deny "$(jstr 'gate: 프로젝트 스코프 설정은 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
      */.claude/projects/*|*/transcripts/*)
        deny "$(jstr 'gate: 세션 트랜스크립트는 승인 판독 채널이라 강제 표면입니다')" ;;
      */orchestrator/rules/*)
        deny "$(jstr 'gate: 룰 카탈로그는 강제 표면입니다 — 룰을 고치는 것은 런의 일이 아닙니다')" ;;
      # CLAUDE.md IS THE ONE EDIT TARGET GIT DOES NOT WATCH. Every other file a
      # stage touches is tracked, so a review reads its diff and the declared-file
      # check bounds it. These are untracked live files that enter the next
      # session's prefix the moment they change, and nothing downstream would
      # ever show what moved — the declared-file check cannot name them (it takes
      # repo-relative paths and these are neither in the repo nor relative to it),
      # and the cutpoint ladder never sees the edit at all.
      #
      # So this is not a refusal, it is a REROUTE, and the whole layering depends
      # on it: `Write`/`Edit` is the only path that leaves no ledger row, and
      # closing it forces the application onto `gate.sh exec`, where the argv is
      # graded, the row is written, and the review-before-apply rule can fire.
      # Leave this arm out and the other two layers are unreachable — an
      # unattended stage simply edits the file and nothing records that it did.
      #
      # DELIBERATELY EVERY `CLAUDE.md`, not an enumerated list of slots. The four
      # this machine has are absolute paths outside the repository; baking them
      # into a shipped hook would make the protection true on one machine and
      # silently absent everywhere else, which is the failure signature the
      # config-directory comment above already records once. `CLAUDE.local.md` is
      # here because it is the same channel under a different name, and leaving
      # it out would make the arm a one-rename bypass.
      */CLAUDE.md|CLAUDE.md|*/CLAUDE.local.md|CLAUDE.local.md)
        deny "$(jstr "gate: CLAUDE.md 는 git 이 추적하지 않는 라이브 프리픽스라, Write/Edit 로 고치면 원장에 아무 행도 남지 않습니다. 적용은 게이트를 거쳐야 합니다 — ${GATE} exec --manifest \"\$CC_PIPELINE_MANIFEST\" --target \"\$CC_PIPELINE_TARGET\" --segment \"\$CC_PIPELINE_SEGMENT\" --cutpoint 커밋 --surface 트리밖쓰기 --snapshot-digest <스냅숏 해시> --rationale '리뷰 채택본 적용' -- cp <제안본> ${p}")" ;;
    esac
    allow "$(jstr 'gate: 강제 표면 아님')"
    ;;
  Bash) ;;
  *) allow "$(jstr 'gate: Bash 가 아닌 도구는 이 훅의 대상이 아닙니다')" ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || deny "$(jstr 'gate: 명령 문자열을 읽지 못했습니다 — 판정 불가는 허용이 아닙니다')"

hook_unquoted_shell_op() {
  # hook_unquoted_shell_op <명령 문자열> — 인용되지 않은 셸 제어 연산자가 있으면 참.
  #
  # 셸을 해석하지 않는다. 세 상태(무인용 / `'` 안 / `"` 안)와 백슬래시 이스케이프만
  # 추적해서 **연산자가 살아 있는 자리인지**만 가른다. 인용 추적이 필요한 이유는
  # `--rationale "…; …"` 처럼 인용된 세미콜론이 게이트의 정당한 인자이기 때문이다 —
  # 그것까지 거부하면 이 허용 목록이 자기가 처방한 명령을 다시 거부하고, 그 실패는
  # 아래 재호출 주석이 이미 실측으로 적어 둔 것이다.
  #
  # 큰따옴표 안에서도 명령 치환과 백틱은 살아 있으므로 그 상태에서도 거부한다.
  # 리다이렉션(`>`·`<`)도 같은 부류로 거부한다 — 이 파일이 보장한다고 적은 성질은
  # 「행위를 막는다」가 아니라 「행이 남는다」이고, 원장 없이 셸이 파일을 여는 자리는
  # 임의 명령과 같은 무게다. 이 훅이 처방하는 두 명령에는 어느 것도 나오지 않는다.
  #
  # 파이프라인을 통째로 넘기는 형태(`-- bash -c '<파이프라인>'`)는 **조건부**다.
  # 아래 거부 문면이 그 조건을 함께 적는다 — 감싸면 등급기가 `-c` 문자열 안을 보지
  # 않아 미등재 명령이 `bash` 의 등급을 물려받고, 게이트가 `등급 미상`으로 내던
  # 거부가 세탁된다. 조건 없이 처방하면 그것이 곧 조건 없는 사용이다.
  #
  # bash 3.2 안전이고 외부 프로세스를 하나도 쓰지 않는다.
  #
  # ANSI-C 인용(`$'…'`)은 이 세 상태로 표현되지 않는다. bash 에서 `$'…'` 안의 `\'`
  # 는 이스케이프된 작은따옴표라 `$'\''` 가 **한 단어로 닫히는데**, 아래 상태 `s` 는
  # `'` 만 처리하고 백슬래시를 무시하므로 `\'` 의 `'` 가 인용을 닫고 이어지는 `'` 가
  # 다시 연다. 그러면 스캐너가 문자열 끝까지 인용 안에 갇혀 그 뒤 연산자가 전부
  # 보이지 않는다 — 실측된 우회가 13종이고 세미콜론·AND·파이프·개행 체인만이 아니라
  # 리다이렉션·명령 치환·임의 인터프리터까지 같은 여섯 글자로 열렸다.
  #
  # 술어는 홀짝이 아니다. `$'a\'b\'c'` 는 `\'` 가 짝수인데도 우회한다 — 두 `\'` 가
  # 각각 상태 `s` 와 `u` 에서 소비되어 상쇄되지 않기 때문이다. 올바른 조건은
  # **「`$'…'` 안에 `\'` 가 하나라도 있으면 어긋난다」**이며, 픽스처를 홀짝으로
  # 세우면 이 부류를 통째로 놓친다.
  #
  # 그래서 둘을 함께 둔다. (1) 원천 차단 — 상태 `u` 에서 `$` 다음이 `(`·`'`·`"` 중
  # 무엇이든 거부한다. 우회 13종이 전부 `$'` 를 필요로 하므로 이것 하나로 닫힌다.
  # (2) 그물 — 스캔이 끝났을 때 종단 상태가 `u` 가 아니면 거부한다. 어긋남을 만드는
  # 문법이 하나만 더 생겨도 (1) 의 열거가 조용히 낡기 때문에 (1) 만으로는 부족하다.
  # 미종료 인용은 bash 가 문법 오류로 거절하므로 (2) 는 **실행 가능한 명령을 하나도
  # 잃지 않는다.**
  #
  # 큰따옴표 안(`d`)에는 이 규칙이 없다 — bash 에서 `"…$'…'…"` 의 `$'` 는 ANSI-C
  # 인용이 아니라 평범한 두 글자라, 여기서 거부하면 정당한 문면을 막는다.
  local s="$1" n i c nx st=u
  n=${#s}; i=0
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    case "$st" in
      u)
        case "$c" in
          '\')                              i=$((i+2)); continue ;;
          "'")                              st=s ;;
          '"')                              st=d ;;
          ';'|'&'|'|'|'`'|'>'|'<'|"$NL")    return 0 ;;
          '$')  nx=${s:$((i+1)):1}
                case "$nx" in '('|"'"|'"') return 0 ;; esac ;;
        esac ;;
      s)
        case "$c" in "'") st=u ;; esac ;;
      d)
        case "$c" in
          '\')  i=$((i+2)); continue ;;
          '"')  st=u ;;
          '`')  return 0 ;;
          '$')  nx=${s:$((i+1)):1}; [ "$nx" = '(' ] && return 0 ;;
        esac ;;
    esac
    i=$((i+1))
  done
  [ "$st" = u ] || return 0
  return 1
}

# ---------------------------------------------------------------------------
# The allow-list is ONE shape, AND IT ENDS WHERE THE SHAPE ENDS.
#
# Anchored at the start of the command and matched against the gate's absolute
# path, so a same-named script elsewhere on PATH does not satisfy it. What
# follows the path is not inspected as a schema: the gate's own argument parser
# is the schema, and a second, weaker copy of it here would be the thing that
# drifts.
#
# BUT THE FIRST TOKEN IS NOT THE WHOLE COMMAND, and for a while this file
# behaved as though it were. Under a first-token rule `|`, `;`, `&&`, `&`, a
# newline and `$( )` are indistinguishable from one another, so blessing one of
# them — an earlier note here blessed the pipe — blessed all of them:
# `<gate> … ; <anything>` was allowed IN FULL, both halves ran in one shell, and
# the right-hand half reached it without a ledger row. The claim a few lines up
# that a `; gate.sh` suffix cannot satisfy the anchor was true only when the
# suffix was itself a gate call; with an arbitrary command in that position it
# was false. Measured: bare call, pipe, `;` chain, `&&` chain, command
# substitution, newline chain and background+chain all allowed; plain commands,
# a leading assignment and `bash -c` all denied.
#
# That is not a partial failure. LEDGER COMPLETENESS is the only property this
# file claims, and it was false for every command written that way.
#
# THE FIX DOES NOT TEACH THE MATCHER TO PARSE A SHELL. A second weak parser in
# an allow-list fails OPEN — the argument the re-invocation note below already
# makes. It goes the other way: keep the first-token check, then REFUSE when
# what follows carries an unquoted shell control operator. This is a
# character-class refusal INSIDE an already-allowed shape, so the "write it to a
# file and run the file" evasion has nothing to work with; the shape is still an
# allow-list and the refusal only narrows it.
# ---------------------------------------------------------------------------
# Tokenized rather than pattern-matched: a path is full of regex metacharacters,
# and an escaping bug in an allow-list fails OPEN.
first=$(printf '%s' "$cmd" | awk '{print $1; exit}')
case "$first" in
  bash|sh) first=$(printf '%s' "$cmd" | awk '{print $2; exit}') ;;
esac
# A quoted path is the same call. Denying `bash '/…/gate.sh' …` while allowing
# the unquoted spelling would train the model out of quoting a path, which is
# the opposite of what any other advice would tell it.
first=$(printf '%s' "$first" | sed -e "s/^['\"]//" -e "s/['\"]$//")
if [ -n "$GATE" ] && [ "$first" = "$GATE" ]; then
  # `| jq -r .H` 는 단 하나의 특례다. 아래 거부 문면이 처방하는 1번 명령이 그
  # 파이프를 쓰므로, 전면 거부하면 이 훅이 다시 자기 처방을 거부한다. 특례는
  # **명령 끝의 축자 연속 한 번**에만 성립한다 — 잘라 낸 뒤 남은 문자열에 제어
  # 연산자가 있으면 그대로 거부한다.
  #
  # 파이프 자체가 필요 없게 만드는 더 깔끔한 형태(스냅숏에 필드 선택 플래그를
  # 주어 `jq` 를 없애고 이 특례를 지우는 것)는 게이트 스크립트를 고쳐야 하는데,
  # 그 파일은 이 변경의 선언 파일 집합 밖이라 채택하지 않았다.
  scan="$cmd"
  while :; do
    case "$scan" in
      *[[:space:]]) scan="${scan%?}" ;;
      *)            break ;;
    esac
  done
  case "$scan" in
    *'| jq -r .H') scan="${scan%'| jq -r .H'}" ;;
    *'|jq -r .H')  scan="${scan%'|jq -r .H'}" ;;
  esac
  if hook_unquoted_shell_op "$scan"; then
    deny "$(jstr "gate: 첫 토큰은 게이트 경로가 맞지만 그 뒤에 인용되지 않은 셸 제어 연산자(\`;\` \`&\` \`|\` 개행 백틱 \$( ) \`>\` \`<\`)가 있거나, ANSI-C 인용(\$'…')처럼 이 훅이 판정할 수 없는 인용이 있습니다. 게이트 오른쪽에 올라탄 명령은 원장에 행을 남기지 않고 실행되므로, 이 훅이 보장하는 유일한 성질이 무력화됩니다. 허용되는 파이프는 명령 끝의 '| jq -r .H' 하나뿐입니다. 1순위는 명령을 나눠 각각 게이트로 실행하는 것입니다. 파이프라인 자체를 넘겨야 한다면 그 파이프라인의 각 명령이 등급표에 행을 가질 때에 한해 ${GATE} exec … -- bash -c '<파이프라인>' 형태를 쓰세요 — 게이트는 -c 문자열 안을 보지 않으므로, 등재되지 않은 argv0 가 그 안에 있으면 게이트가 내던 '등급 미상' 거부가 bash 의 등급으로 세탁되고 원장의 표면 축에 실제 행위와 다른 값이 남습니다. 거부된 명령: ${cmd}")"
  fi
  allow "$(jstr 'gate: 게이트 호출')"
fi

# The re-invocation line must be one the stage can actually TYPE — and one this
# hook actually ALLOWS. The earlier form failed the second half: it prescribed
# `H=$(<gate> snapshot …) && <gate> exec …`, whose first token is `H=$(<gate>`
# and therefore matches nothing above. So the hook denied the exact command it
# had just asked for, and a stage that read the message carefully and complied
# was refused with the same boilerplate it was already holding. Measured: a
# review stage tried the suggested form twice — combined with `&&`, then split
# across two lines — was denied both times, and stopped without writing its
# report rather than emit a `P0 0건 | P1 0건` summary having read nothing.
#
# TWO SEPARATE COMMANDS, then. Each one's first token is the gate path, which is
# the single shape this allow-list has. The alternative — teaching the matcher
# to see through a leading assignment and a command substitution — would put a
# second, weaker shell parser in the allow-list, and an escaping bug in an
# allow-list fails OPEN.
#
# EXACTLY ONE PIPE SPELLING IS FINE, and it is the one line 1 uses. An earlier
# note here said "a pipe is fine" without qualification, on the reasoning that
# the first token is what is matched and `jq` sits to the right of it — which is
# true, and is also true of every other operator, so the sentence blessed far
# more than it named. The check above now allows `| jq -r .H` as a trailing
# literal and refuses the rest.
#
# The snapshot hash is not baked in because it moves on every ledger write; the
# stage reads it from line 1 and types it into line 2.
#
# THE PRESCRIBED LINE QUOTES THE OFFENDING COMMAND BACK AFTER `--`, so when the
# denial was caused by a control operator, the prescription carries that
# operator too and the new check refuses it in turn. That is the correct
# behaviour rather than a loop: the operator has to leave the command before any
# form of it can run, and the way out is to SPLIT the command and run each half
# through the gate.
#
# WRAPPING THE PIPELINE IN `bash -c` IS THE SECOND ANSWER AND IT IS CONDITIONAL,
# because prescribing it unconditionally prescribes a bypass. The grader does not
# look inside the `-c` string, so an argv0 with no row in the grade table — which
# the gate itself defines as `등급 미상` and NEVER `읽기`, that is, a refusal —
# inherits `bash`'s grade and passes. Measured: `-- ln -s <path> /tmp/L` is
# refused as `등급 미상` under every self-declaration, while
# `-- bash -c "ln -s <path> /tmp/L"` is graded `워크트리쓰기`, passes, and the link
# is actually created. The row still gets written, so this is not a ledger-free
# bypass; what it corrupts is the SURFACE axis, which is the axis a later audit
# reads. So the condition is that every command inside the pipeline has a row of
# its own, and the denial text above states it rather than leaving it here.
#
# THE STRUCTURAL FIX IS IN THE GRADER, NOT HERE, and it is not made in this
# change: teaching the grader to tokenize the first argument of `bash -c`/`sh -c`
# and grade recursively — yielding `등급 미상` for the whole when the inner argv0
# has no row — requires editing `gate.sh`, which is outside this change's
# declared file set. Recorded so the next reader can tell what was deliberately
# left out from what was missed.
deny "$(jstr "gate: 이 런의 배시는 게이트를 거쳐야 원장에 남습니다. 아래 두 명령을 각각 따로 실행하세요 — 한 줄로 합치면(\`;\` \`&&\` \`&\` 개행 \$( )) 게이트 오른쪽 절반이 원장에 행을 남기지 않고 실행되므로 이 훅이 거부합니다. 허용되는 파이프는 (1) 끝의 \`| jq -r .H\` 하나뿐입니다. (1) 지금 시점의 스냅숏 해시를 받습니다: ${GATE} snapshot --manifest \"\$CC_PIPELINE_MANIFEST\" | jq -r .H  (2) 그 값을 --snapshot-digest 에 그대로 적어 실행합니다: ${GATE} exec --manifest \"\$CC_PIPELINE_MANIFEST\" --target \"\$CC_PIPELINE_TARGET\" --segment \"\$CC_PIPELINE_SEGMENT\" --cutpoint 커밋 --surface <읽기|워크트리쓰기|트리밖쓰기|외부상태변경> --snapshot-digest <(1)에서 받은 값> --rationale <왜 이 명령이 필요한가> -- ${cmd}")"
