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
# would put dozens of forks on every edit a stage makes.
# ---------------------------------------------------------------------------
NL='
'
INOS=""; HOOK_INO=""; HOOK_TAIL=""; HOOK_NORM=""; NP_INO=""; np=""

hook_lexnorm() {
  # hook_lexnorm <경로> — 어휘 정규화만 해서 `HOOK_NORM` 에 넣는다. 틸드 확장,
  # 상대 경로의 절대화, `//` 와 `/./` 축약, `..` 해소, 후행 `/` 제거. 파일시스템을
  # 읽지 않으므로 심링크는 따르지 않는다 — 그 몫은 아래 아이노드 비교가 진다.
  # 절대 경로로 만들 수 없으면 거짓.
  #
  # 값을 찍지 않고 전역에 넣는 이유는 명령 치환이 곧 fork 이고, 이 함수가 한 번의
  # 판정 안에서 편집 대상과 앵커 전부에 대해 불리기 때문이다.
  local q="$1" comp out="" oldifs
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
      ..)   out="${out%/*}" ;;
      *)    out="$out/$comp" ;;
    esac
  done
  set +f; IFS="$oldifs"
  HOOK_NORM="${out:-/}"
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
    # 이 둘은 환경변수에서 방금 만들어졌으므로 앞의 일괄 정규화가 닿지 않는다.
    hook_lexnorm_var cfg
    hook_lexnorm_var xdgcc

    # ONE `stat` CALL FOR THE WHOLE DECISION: the edit target's ancestor chain
    # plus every guarded path, measured together. `-L` follows symlinks, which
    # is what closes a symlinked tail; a nonexistent argument is skipped and the
    # rest still print, which is what lets a not-yet-created leaf stay allowed.
    stat_args=( "$np" )
    a="$np"
    while [ "$a" != "/" ]; do
      a="${a%/*}"; [ -n "$a" ] || a="/"
      stat_args[${#stat_args[@]}]="$a"
    done
    stat_args[${#stat_args[@]}]="$RUN_DIR"
    stat_args[${#stat_args[@]}]="$hook_self"
    [ -n "$LEDGER" ] && stat_args[${#stat_args[@]}]="$LEDGER"
    [ -n "$GRANT" ]  && stat_args[${#stat_args[@]}]="$GRANT"
    if [ -n "$cfg" ]; then
      stat_args[${#stat_args[@]}]="$cfg/settings.json"
      stat_args[${#stat_args[@]}]="$cfg/settings.local.json"
      stat_args[${#stat_args[@]}]="$cfg/projects"
    fi
    [ -n "$xdgcc" ] && stat_args[${#stat_args[@]}]="$xdgcc"
    if [ -n "${HOME:-}" ]; then
      for lane in "$HOME"/.claude*; do
        case "$lane" in *'*') continue ;; esac
        stat_args[${#stat_args[@]}]="$lane/settings.json"
        stat_args[${#stat_args[@]}]="$lane/settings.local.json"
        stat_args[${#stat_args[@]}]="$lane/projects"
      done
    fi
    INOS=$(stat -Lf '%d:%i %N' "${stat_args[@]}" 2>/dev/null || true)
    NP_INO=""
    hook_ino "$np" && NP_INO="$HOOK_INO"

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
      case "$run_tail" in
        settings/*)
          deny "$(jstr 'gate: 런 설정 디렉터리는 강제 표면입니다 — 여기 한 번 쓰면 이 스테이지의 경계가 통째로 사라집니다')" ;;
        halt/*) ;;
        */*)
          deny "$(jstr 'gate: 런 디렉터리에서 스테이지가 쓰도록 선언된 것은 halt/<stage-id>.md 와 <segment>.plan.md 뿐입니다 — 나머지는 게이트가 매 행위마다 되읽는 기준선이라, 스테이지가 고치면 강제 표면 검사가 자기 자신을 기준으로 다시 잡힙니다')" ;;
        *.plan.md) ;;
        *)
          deny "$(jstr 'gate: 런 디렉터리에서 스테이지가 쓰도록 선언된 것은 halt/<stage-id>.md 와 <segment>.plan.md 뿐입니다 — 나머지는 게이트가 매 행위마다 되읽는 기준선이라, 스테이지가 고치면 강제 표면 검사가 자기 자신을 기준으로 다시 잡힙니다')" ;;
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
      esac
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
      case "$np" in
        "$HOME"/.claude*/settings.json|"$HOME"/.claude*/settings.local.json)
          deny "$(jstr 'gate: 형제 레인의 사용자 스코프 설정도 훅 설치 채널이라 강제 표면입니다 — 이 런에서는 편집할 수 없습니다')" ;;
        "$HOME"/.claude*/projects/*)
          deny "$(jstr 'gate: 형제 레인의 세션 트랜스크립트도 승인 판독 채널이라 강제 표면입니다')" ;;
      esac
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
    esac
    allow "$(jstr 'gate: 강제 표면 아님')"
    ;;
  Bash) ;;
  *) allow "$(jstr 'gate: Bash 가 아닌 도구는 이 훅의 대상이 아닙니다')" ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || deny "$(jstr 'gate: 명령 문자열을 읽지 못했습니다 — 판정 불가는 허용이 아닙니다')"

# ---------------------------------------------------------------------------
# The allow-list is ONE shape.
#
# Anchored at the start of the command and matched against the gate's absolute
# path, so neither a `; gate.sh` suffix nor a same-named script elsewhere on
# PATH satisfies it. What follows the path is not inspected: the gate's own
# argument parser is the schema, and a second, weaker copy of it here would be
# the thing that drifts.
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
# allow-list fails OPEN. A pipe is fine and the first line uses one: what is
# matched is the first token, and `jq` sits on the right of it.
#
# The snapshot hash is not baked in because it moves on every ledger write; the
# stage reads it from line 1 and types it into line 2.
deny "$(jstr "gate: 이 런의 배시는 게이트를 거쳐야 원장에 남습니다. 아래 두 명령을 각각 따로 실행하세요 — 한 줄로 합치거나 \$( ) 로 감싸면 첫 토큰이 게이트 경로가 아니게 되어 이 훅이 다시 거부합니다. (1) 지금 시점의 스냅숏 해시를 받습니다: ${GATE} snapshot --manifest \"\$CC_PIPELINE_MANIFEST\" | jq -r .H  (2) 그 값을 --snapshot-digest 에 그대로 적어 실행합니다: ${GATE} exec --manifest \"\$CC_PIPELINE_MANIFEST\" --target \"\$CC_PIPELINE_TARGET\" --segment \"\$CC_PIPELINE_SEGMENT\" --cutpoint 커밋 --surface <읽기|워크트리쓰기|트리밖쓰기|외부상태변경> --snapshot-digest <(1)에서 받은 값> --rationale <왜 이 명령이 필요한가> -- ${cmd}")"
