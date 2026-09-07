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
    case "$p" in
      "$RUN_DIR"/settings/*)
        deny "$(jstr 'gate: 런 설정 디렉터리는 강제 표면입니다 — 여기 한 번 쓰면 이 스테이지의 경계가 통째로 사라집니다')" ;;
      "$hook_self"/*)
        deny "$(jstr 'gate: 훅 스크립트 자신은 강제 표면입니다')" ;;
    esac
    [ -n "$LEDGER" ] && [ "$p" = "$LEDGER" ] && \
      deny "$(jstr 'gate: 원장의 기록자는 게이트뿐입니다 — 행을 남기려면 gate.sh act 또는 gate.sh exec 를 쓰세요')"
    [ -n "$GRANT" ] && [ "$p" = "$GRANT" ] && \
      deny "$(jstr 'gate: 인가 기록은 킥오프만 씁니다 — 런 중에는 읽기 전용입니다')"
    # THE USER-SCOPE CONFIG DIRECTORY IS RESOLVED, NOT ASSUMED. The literal
    # `*/.claude/...` arms below cover a default installation and the
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
    # Checked before the case rather than as more arms in it, because an arm
    # built from an empty variable would degrade into a pattern that matches
    # something else (`/settings.json`) instead of matching nothing.
    cfg="${CLAUDE_CONFIG_DIR:-}"
    [ -n "$cfg" ] || cfg="${HOME:-}${HOME:+/.claude}"
    cfg="${cfg%/}"
    if [ -n "$cfg" ]; then
      case "$p" in
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
    fi
    case "$p" in
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
        deny "$(jstr "gate: CLAUDE.md 는 git 이 추적하지 않는 라이브 프리픽스라, Write/Edit 로 고치면 원장에 아무 행도 남지 않습니다. 적용은 게이트를 거쳐야 합니다 — ${GATE} exec --manifest \"\$CC_PIPELINE_MANIFEST\" --target \"\$CC_PIPELINE_TARGET\" --segment \"\$CC_PIPELINE_SEGMENT\" --cutpoint 커밋 --surface 트리밖쓰기 --snapshot-digest <스냅숏 해시> --emit-digest-to ${RUN_DIR}/gate-digest-\$CC_PIPELINE_STAGE_ID.json --rationale '리뷰 채택본 적용' -- cp <제안본> ${p} — <스냅숏 해시> 는 직전 게이트 호출이 ${RUN_DIR}/gate-digest-\$CC_PIPELINE_STAGE_ID.json 에 방출한 H 필드이고(Read 도구로 열면 됩니다), 그 파일이 없으면 ${GATE} snapshot --manifest \"\$CC_PIPELINE_MANIFEST\" | jq -r .H 로 받습니다. --emit-digest-to 가 '알 수 없는 인자' 로 거부되면 그 플래그만 빼고 다시 실행하세요")" ;;
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
# SEPARATE COMMANDS WHEN THERE ARE TWO, and each one's first token is the gate
# path, which is the single shape this allow-list has. The alternative —
# teaching the matcher to see through a leading assignment and a command
# substitution — would put a second, weaker shell parser in the allow-list, and
# an escaping bug in an allow-list fails OPEN. A pipe is fine and the fallback
# line uses one: what is matched is the first token, and `jq` sits on the right
# of it.
#
# ORDINARILY THERE IS ONLY ONE COMMAND NOW. The snapshot hash still cannot be
# baked in — it moves on every ledger write — but it no longer has to be fetched
# with a shell: an acting call carrying `--emit-digest-to` leaves the value the
# NEXT call needs in a file, and a file is readable with the Read tool, which
# this hook never sees. So the round trip this message used to prescribe becomes
# a file read, and the second command survives only as the fallback.
#
# THE FALLBACK IS LOAD-BEARING AND NOT PADDING. The hook receives the gate as a
# runtime parameter, so the hook copy and the gate copy can be different
# deployments; a gate predating `--emit-digest-to` exits 2 on the unknown
# argument, which would refuse an act over a flag that is only ever an
# optimization. The message therefore names the flag AND names what to do when
# it comes back rejected — and names the two-command form for the first call of
# a run, where no earlier call has written the file yet.
#
# THE PRESCRIBED LINE STILL CARRIES THE FLAG, deliberately. The file exists only
# because some earlier call asked for it, so a prescription that reads the file
# without ever writing it describes a mechanism that never starts.
deny "$(jstr "gate: 이 런의 배시는 게이트를 거쳐야 원장에 남습니다. --snapshot-digest 값은 직전 게이트 호출이 방출해 둔 파일에서 가져오세요 — Read 도구로 ${RUN_DIR}/gate-digest-\$CC_PIPELINE_STAGE_ID.json 을 열어 H 필드를 그대로 적습니다(Read 는 배시가 아니라 이 훅에 걸리지 않습니다). 실행할 형태는 이것 하나입니다: ${GATE} exec --manifest \"\$CC_PIPELINE_MANIFEST\" --target \"\$CC_PIPELINE_TARGET\" --segment \"\$CC_PIPELINE_SEGMENT\" --cutpoint 커밋 --surface <읽기|워크트리쓰기|트리밖쓰기|외부상태변경> --snapshot-digest <방출 파일의 H> --emit-digest-to ${RUN_DIR}/gate-digest-\$CC_PIPELINE_STAGE_ID.json --rationale <왜 이 명령이 필요한가> -- ${cmd} . 방출 파일이 없으면(이 런의 첫 호출이거나 방출이 실패한 경우) 먼저 이 명령을 따로 실행해 값을 받으세요 — 한 줄로 합치거나 \$( ) 로 감싸면 첫 토큰이 게이트 경로가 아니게 되어 이 훅이 다시 거부합니다: ${GATE} snapshot --manifest \"\$CC_PIPELINE_MANIFEST\" | jq -r .H . 그리고 --emit-digest-to 가 '알 수 없는 인자' 로 거부되면 게이트 사본이 이 플래그보다 낡은 것이므로, 그 플래그만 빼고 다시 실행하고 이후로는 계속 snapshot 명령으로 값을 받으세요")"
