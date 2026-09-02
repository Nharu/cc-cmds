#!/usr/bin/env bash
# apply-statusline.sh — install the status line into the user's settings, and
# the probe that decides whether to.
#
# ONE FILE, TWO MODES, ON PURPOSE. If the probe and the apply were separate
# scripts their normalisation would drift, and the post-probe would then never
# agree with what the apply had just written — every apply would end as "적용
# 불명", a terminal class that forbids retry. The single function
# `sl_desired_command` is what makes the two modes answer about the same string.
#
# WHAT GETS WRITTEN IS ONE KEY. No copy of anything is installed anywhere:
# `statusLine.command` becomes a defensive pointer at the plugin checkout, so a
# branch without the script degrades to whatever the user had before instead of
# breaking. That is what makes a fourth copy of the liveness predicate
# unnecessary, and the absence of that copy is the point.
#
# THE TREE THAT RUNS THE APPLY IS NOT THE TREE THE INSTALLED COMMAND MUST POINT
# AT. The apply runs inside a throwaway worktree pinned to the merge commit and
# that worktree is removed the moment the apply converges — so resolving the
# path from `$BASH_SOURCE` would bake in an absolute path that exists for a few
# more seconds. `--plugin-dir` must name the long-lived checkout the user's
# session actually loads, and a value that fails to name one parks BEFORE any
# write: whenever the installed guard is permanently false, the verify run
# exercises only the fallback branch and passes all five conditions, and the
# pipeline records a dead status line as a success.
#
# WELL-FORMED IS NOT THE SAME AS ALIVE, and the difference is the whole reason
# the checks below are four and not one. Empty and relative are the shapes a
# typo makes. The shapes that actually reached a green apply were all
# well-formed absolute paths: a directory that does not exist, a partial
# checkout without this file, a file shipped without its executable bit, a
# throwaway worktree, and a path holding a space that the installed `[` then
# choked on. Every one of them ends as `rc=0` twice over, because nothing
# downstream can tell the guard's two branches apart.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.
#
# Usage:
#   apply-statusline.sh --probe --settings <path> --plugin-dir <dir> --expect <sha256>
#   apply-statusline.sh --apply --settings <path> --plugin-dir <dir> --expect <sha256>
#
# Probe exit codes — the driver's contract:
#   0  already converged; nothing to do
#   2  the current value is the expected old one; proceed
#   1  anything else; a third party changed it, park

set -uo pipefail

MODE=""
SETTINGS=""
PLUGIN_DIR=""
EXPECT=""

die() { printf 'apply-statusline: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --probe)       MODE=probe; shift ;;
    --apply)       MODE=apply; shift ;;
    --settings)    SETTINGS="${2:-}"; shift 2 ;;
    --plugin-dir)  PLUGIN_DIR="${2:-}"; shift 2 ;;
    --expect)      EXPECT="${2:-}"; shift 2 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
done

[ -n "$MODE" ]     || die "--probe 또는 --apply 중 하나가 필요합니다"
[ -n "$SETTINGS" ] || die "--settings 가 필요합니다"

# `--expect` CANNOT BE DEFAULTED, and the reason is that both ways of defaulting
# it are fatal. Folded to "assume the known old value", the user's rule — park
# when it is not what we expected — silently disappears and the apply overwrites
# whatever is there. Folded to "assume a third value", the first run parks and
# the status line is never installed at all.
[ -n "$EXPECT" ]   || die "--expect 가 필요합니다 (생략하면 park 규율이 사라집니다)"

# The park that has to happen before anything is written, not after.
case "$PLUGIN_DIR" in
  /*) ;;
  "") die "--plugin-dir 이 비어 있습니다 — 설치되는 가드가 영구히 거짓이 되고 검증은 폴백만 태웁니다" ;;
  *)  die "--plugin-dir 이 절대경로가 아닙니다: $PLUGIN_DIR" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq 가 없습니다 — 아무것도 쓰지 않고 멈춥니다"

SL_PATH="$PLUGIN_DIR/orchestrator/statusline.sh"

# The same test the installed command will make, made HERE where failing it can
# still stop the write. Downstream nothing can: the verify run feeds a session
# id with no index, so the script answers "no run" and the fallback answers the
# same bytes, and the five conditions pass either way.
[ -x "$SL_PATH" ] \
  || die "$SL_PATH 이 실행 가능한 파일이 아닙니다 — 설치되는 가드가 영구히 거짓이 됩니다"

# AND THE SAME TEST AGAIN, THROUGH THE SHELL THAT WILL RE-EVALUATE IT. What gets
# written is a string, and the harness hands that string to `sh -c` on every
# render — so the double quotes around the path stop a space and nothing else. A
# `$`, a backtick or a `"` inside the path is expanded at that second evaluation,
# the guard is false forever, and the apply still lands rc=0 because the verify
# run cannot tell the guard's two branches apart.
#
# The question asked here is not "which characters are dangerous" but "is the
# guard that is about to be installed actually true", which is the same question
# the render will ask and therefore covers the shapes nobody has enumerated yet.
sh -c "[ -x \"$SL_PATH\" ]" 2>/dev/null \
  || die "설치될 가드가 그대로 평가되지 않습니다 ($SL_PATH) — 경로의 문자가 재평가에서 해석되어 가드가 영구히 거짓이 됩니다"

# THE ONE BAD PATH THAT PASSES EVERY OTHER CHECK is the tree the apply is
# running in. It exists, it holds the script, the bit is set — and it is removed
# the moment the apply converges, so the guard is true exactly once and false
# for the rest of the machine's life. A linked worktree is what a `--git-dir`
# differing from its `--git-common-dir` means.
#
# BOTH ARE RESOLVED TO A PHYSICAL ABSOLUTE PATH FIRST. Measured: from a
# subdirectory of an ordinary checkout git answers `--git-dir` absolute and
# `--git-common-dir` relative to the current directory, and `--plugin-dir` names
# a subdirectory by construction — so a plain string compare calls every
# ordinary checkout a worktree and parks every legitimate apply.
#
# PHYSICAL, and that is the second half of the same defect. Git's absolute
# answer is the one `getcwd` gives, with every symlink already resolved, while a
# logical `pwd` keeps whatever symlink the caller walked in through — so one
# directory comes back as two strings and the compare parks again. On this
# platform `/tmp` and `/var` are exactly that symlink, which makes an ordinary
# checkout under either of them park for a reason that has nothing to do with
# worktrees.
#
# Not being a git repository is the normal case for an installed plugin and is
# allowed; so is having no `git` at all. This check exists to reject one
# specific known-doomed tree, not to demand provenance.
SL_WT=$( cd "$PLUGIN_DIR" 2>/dev/null || exit 0
         gd=$(git rev-parse --git-dir 2>/dev/null) || exit 0
         cm=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
         gd=$(cd "$gd" 2>/dev/null && pwd -P) || exit 0
         cm=$(cd "$cm" 2>/dev/null && pwd -P) || exit 0
         [ "$gd" = "$cm" ] || printf '%s' "$gd" )
[ -z "$SL_WT" ] \
  || die "--plugin-dir 이 임시 워크트리를 가리킵니다 ($SL_WT) — 이 트리는 곧 사라지고 설치되는 가드는 그때부터 영구히 거짓입니다"

sl_desired_command() {
  # sl_desired_command <current-command> — the command line to install.
  #
  # IDEMPOTENT BY CONSTRUCTION. Applying twice must not nest the wrapper inside
  # itself, so when the current value already carries this exact prefix the
  # fallback is recovered from it rather than re-wrapped. That also means a
  # changed plugin path re-points the guard while keeping the user's original
  # command as the fallback, instead of demoting the previous wrapper to it.
  #
  # `exec bash <path>`, never `exec <path>`: the latter depends on the shebang,
  # and a script whose shebang is broken then produces neither output nor
  # fallback — the exact shape this whole defensive form exists to prevent.
  #
  # THE PATH IS QUOTED INSIDE THE INSTALLED STRING. Unquoted, a plugin directory
  # holding a space makes `[` see too many arguments and fail, which is
  # indistinguishable from "the script is not there": every render silently
  # takes the fallback and the apply still lands as a success. The quotes are
  # part of `prefix`, so the `case` below keeps matching what is actually
  # installed and the double apply stays idempotent — a settings file carrying
  # the older unquoted wrapper matches neither this prefix nor `--expect`, so
  # the probe parks on it instead of nesting a second wrapper inside the first.
  local cur="$1" prefix fallback
  prefix="[ -x \"$SL_PATH\" ] && exec bash \"$SL_PATH\" || "
  case "$cur" in
    "$prefix"*) fallback=${cur#"$prefix"} ;;
    *)          fallback=$cur ;;
  esac
  # AN EMPTY FALLBACK IS A SYNTAX ERROR, not an empty output — `cmd || ` does
  # not parse, so the whole line would fail rather than degrade. That case is
  # reachable on the path this design chose for a machine with no status line
  # at all: there is no prior command to fall back to. `true` is what "print
  # nothing, successfully" spells, which is precisely no worse than the nothing
  # that was there before.
  [ -n "$fallback" ] || fallback="true"
  printf '%s%s' "$prefix" "$fallback"
}

sl_subdigest() {
  # sl_subdigest <settings-file> — sha256 over the `.statusLine` subobject.
  #
  # THE SUBOBJECT, NOT THE FILE. The whole-file hash is disqualified: the
  # surrounding keys drift on their own — 17 of them at last count, 9 having
  # moved since May, with the key set itself changing — so a file digest would
  # park on somebody else's unrelated edit.
  #
  # The normalisation is part of the contract and not an implementation detail:
  # `jq -S -c` and the trailing newline `jq` prints are both inside the hashed
  # bytes. Trimming that newline yields a different, equally plausible constant,
  # which is how the pinned `--expect` was first misread as stale.
  jq -S -c '.statusLine' "$1" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

sl_full_digest() {
  # sl_full_digest <file> — whole-file sha256, for CHANGE DETECTION only.
  # Two digests over one file doing two different jobs: this one is printed so a
  # person can see that something moved, `sl_subdigest` is the one that decides.
  [ -f "$1" ] || { printf '(없음)'; return 0; }
  shasum -a 256 "$1" | cut -d' ' -f1
}

sl_render_desired() {
  # sl_render_desired <settings-file> <out-file> — write the settings as they
  # would be after the apply. Used by BOTH modes, which is what lets the probe
  # recognise convergence without guessing at the apply's output.
  local src="$1" out="$2" cur cmd
  if [ -f "$src" ]; then
    cur=$(jq -r '.statusLine.command // ""' "$src" 2>/dev/null) || return 1
  else
    # ABSENT FILE MEANS CREATE, and the entry state of the probe is 2. A new
    # machine turns the status line on by itself; what an unattended run creates
    # in that case is a file holding the single key this design declares.
    cur=""
    printf '{}\n' > "$out.src" || return 1
    src="$out.src"
  fi
  cmd=$(sl_desired_command "$cur")
  jq --arg c "$cmd" \
     '.statusLine = ((.statusLine // {}) + {type: "command", command: $c})' \
     "$src" > "$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  return 0
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-apply-statusline.XXXXXX") || die "임시 디렉터리 생성 실패"
trap 'rm -rf "$WORK"' EXIT

sl_probe() {
  # The three-way state machine. A single fixed `--expect` cannot answer both
  # the pre- and the post-question — before the apply the current value matches
  # it, after the apply it does not — so the two are not opposite verdicts on
  # one comparison but two states of one machine, and the second compares
  # against a value COMPUTED HERE from the same function the apply writes with.
  local cur want
  [ -f "$SETTINGS" ] || return 2
  sl_render_desired "$SETTINGS" "$WORK/desired.json" || return 1
  cur=$(sl_subdigest "$SETTINGS")
  want=$(sl_subdigest "$WORK/desired.json")
  [ -n "$cur" ] && [ -n "$want" ] || return 1
  [ "$cur" = "$want" ]   && return 0
  [ "$cur" = "$EXPECT" ] && return 2
  return 1
}

sl_verify() {
  # sl_verify <command> — run the installed command once and judge it.
  #
  # Five conditions, all of them: exit 0, non-empty, exactly one line, at most
  # 512 bytes, within 3 seconds. This is what a status line failing looks like
  # from the outside, and any one of them alone would let a broken shape land.
  local cmd="$1" out rc n_nl bytes p i=0
  out="$WORK/verify.out"
  : > "$out"
  printf '%s' '{"session_id":"cc-apply-verify","transcript_path":"/dev/null","cwd":"'"$PWD"'","workspace":{"current_dir":"'"$PWD"'","project_dir":"'"$PWD"'"},"model":{"id":"probe","display_name":"probe"}}' \
    | sh -c "$cmd" > "$out" 2>/dev/null &
  p=$!
  # No `timeout`: the binary is GNU-only and absent on the platform this runs
  # on. Polling a recorded pid with `kill -0` is the portable shape, and it is
  # the same one the liveness predicate uses for the same reason.
  while [ "$i" -lt 30 ]; do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    printf '검증 실패: 3초를 넘겼습니다\n' >&2
    return 1
  fi
  wait "$p"; rc=$?
  [ "$rc" -eq 0 ] || { printf '검증 실패: 종료 코드 %s\n' "$rc" >&2; return 1; }
  [ -s "$out" ]   || { printf '검증 실패: 출력이 비어 있습니다\n' >&2; return 1; }
  bytes=$(wc -c < "$out" | tr -d ' ')
  [ "$bytes" -le 512 ] || { printf '검증 실패: %s바이트\n' "$bytes" >&2; return 1; }
  # "EXACTLY ONE LINE" COUNTS LINES, NOT NEWLINES. The command this replaces
  # ends its format string at `%s` and so emits none, and the fallback branch
  # has to reproduce that output byte for byte — so a rule spelled "must end in
  # a newline" would fail every apply that lands on the fallback. One optional
  # trailing newline is stripped; what remains may hold none.
  n_nl=$(tr -dc '\n' < "$out" | wc -c | tr -d ' ')
  [ "$n_nl" -le 1 ] || { printf '검증 실패: %s줄입니다\n' "$((n_nl + 1))" >&2; return 1; }
  return 0
}

case "$MODE" in
  probe)
    sl_probe
    exit $?
    ;;
  apply)
    pre_full=$(sl_full_digest "$SETTINGS")
    sl_render_desired "$SETTINGS" "$WORK/desired.json" \
      || die "설정 JSON 을 읽을 수 없습니다 — 쓰기 전에 멈춥니다"

    backup=""
    if [ -f "$SETTINGS" ]; then
      backup="$SETTINGS.pre-statusline-$(date -u +%s)"
      cp "$SETTINGS" "$backup" || die "백업 생성 실패"
    else
      mkdir -p "$(dirname "$SETTINGS")" || die "설정 디렉터리 생성 실패"
    fi

    cp "$WORK/desired.json" "$SETTINGS" || die "설정 쓰기 실패"

    cmd=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)
    if ! sl_verify "$cmd"; then
      if [ -n "$backup" ]; then
        cp "$backup" "$SETTINGS" 2>/dev/null
        if cmp -s "$backup" "$SETTINGS"; then
          die "검증 실패 — 백업으로 롤백했습니다: $backup"
        fi
        die "검증 실패 후 롤백도 실패했습니다 (적용 불명): $backup"
      fi
      rm -f "$SETTINGS"
      die "검증 실패 — 이 실행이 만든 파일을 지웠습니다"
    fi

    # The backup lives beside its target, following the naming convention this
    # machine already carries. The run directory is not an option: `$RUN_DIR`
    # expands empty inside the apply command, so a path built from it would
    # write to the filesystem root. What goes back to the run is this pointer on
    # stdout, which the driver captures into the stage's log.
    printf '백업: %s\n' "${backup:-(신규 생성 — 백업 없음)}"
    printf '적용 전 전체 sha256: %s\n' "$pre_full"
    printf '적용 후 전체 sha256: %s\n' "$(sl_full_digest "$SETTINGS")"
    printf '설치된 명령: %s\n' "$cmd"
    exit 0
    ;;
esac
