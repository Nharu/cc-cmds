#!/usr/bin/env bash
# apply-statusline.sh — install the status line into the user's settings, and
# the probe that decides whether to.
#
# ONE FILE, TWO MODES, ON PURPOSE. If the probe and the apply were separate
# scripts their normalisation would drift, and the post-probe would then never
# agree with what the apply had just written. The grammar both modes answer with
# is not even in this file — it is sourced from `statusline-command.sh`, because
# the SessionStart hook has to reach the same answer about the same string and a
# second copy of a recogniser is a second answer waiting to happen.
#
# WHAT GETS WRITTEN IS ONE KEY. No copy of anything is installed anywhere:
# `statusLine.command` becomes a defensive pointer at the plugin checkout, so a
# branch without the script degrades to whatever the user had before instead of
# breaking. That is what makes a fourth copy of the liveness predicate
# unnecessary, and the absence of that copy is the point.
#
# THE NORMAL CALLER IS A HOOK, AND IT HANDS OVER EVERYTHING THIS SCRIPT NEEDS.
# `--settings` and `--plugin-dir` are derived by the hook and passed in; nothing
# here re-derives either one, and no environment variable is consulted for
# either. A single derivation site is what keeps the two processes from holding
# two different strings while believing they hold one.
#
# THE TARGET PLUGIN DIRECTORY IS NOT NECESSARILY THE TREE THIS SCRIPT LIVES IN.
# Resolving it from `$BASH_SOURCE` would bake in whatever tree happened to run
# the apply, and a linked worktree is exactly the tree that is gone minutes
# later. `--plugin-dir` must name the long-lived checkout the user's session
# actually loads, and a value that fails to name one parks BEFORE any write.
#
# WELL-FORMED IS NOT THE SAME AS ALIVE, and the difference is the whole reason
# the pre-write checks below are four and not one. Empty and relative are the
# shapes a typo makes. The shapes that actually reached a green apply were all
# well-formed absolute paths: a directory that does not exist, a partial
# checkout without this file, a file shipped without its executable bit, a
# throwaway worktree, and a path holding a space that the installed `[` then
# choked on.
#
# THE VERIFY RUN CANNOT SEPARATE THE INSTALLED GUARD'S TWO BRANCHES ON A MACHINE
# THAT ALREADY HAD A STATUS LINE, and that is why it is not the defence here.
# When the previous command is itself a fallback the two branches emit the same
# bytes, so the five conditions pass either way. What the verify run does decide
# is the FIRST install, where the fallback is `true` and emits nothing: there
# "non-empty" separates the branches, and that is the one path it still runs on.
# It runs BEFORE the commit, so a failure leaves nothing written and nothing to
# undo. There is no restore path anywhere below, and that is not an omission —
# a check placed ahead of the only write has nothing to restore from.
#
# STDOUT IS EMPTY ON EVERY PATH, WITHOUT EXCEPTION. The hook that calls this runs
# at `SessionStart`, where a child's stdout is injected into the session context
# and, if it parses as JSON, read as a control channel. The verdict travels on
# the exit code instead. Diagnostics go to stderr, which is where the two
# callers — the hook and the test suite — both read park reasons from.
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.
#
# Usage:
#   apply-statusline.sh --probe --settings <abs path> --plugin-dir <abs dir>
#   apply-statusline.sh --apply --settings <abs path> --plugin-dir <abs dir> \
#                       --require-state <empty|ours>
#
# The argument set is closed at those four. `--require-state` is REQUIRED by
# `--apply` and REJECTED by `--probe`; its value vocabulary is exactly the two
# tokens `empty` and `ours`, and a token outside it is a contract violation
# (rc 1), not a mismatch (rc 21).
#
# Probe exit codes — ITS OWN NAMESPACE, not the one below:
#   0  CONVERGED  the rendered `.statusLine` is byte-identical to the current one
#   2  WRITABLE   the current value is empty or ours, and the four pre-write
#                 checks and the target shape check all passed
#   1  PARKED     anything else
#
# Apply exit codes — A DIFFERENT NAMESPACE, sharing small integers with the
# probe's. Anyone wiring a branch off one of these must say which mode it came
# from. Success is 10 or 11, NOT 0; 0 means "already correct, nothing written".
#   0   CONVERGED           rendered value equals the current one; not written
#   10  INSTALLED           previous value was empty; committed
#   11  REPOINTED           previous value was already ours; committed
#   20  PARK_FOREIGN        the snapshot reclassified as somebody else's value
#   21  PARK_REQUIRE_STATE  --require-state is a known token, but not the one
#                           the snapshot reclassified to
#   23  PARK_WORKTREE       --plugin-dir names a linked worktree
#   24  PARK_SL_MISSING     the status line script is not an executable file
#   25  PARK_GUARD_REEVAL   the guard about to be installed is false when the
#                           shell re-evaluates it
#   26  PARK_PLUGIN_DIR     --plugin-dir missing, relative, or trailing-slashed
#   27  PARK_LINKED         the settings file is a symbolic link (dangling
#                           included) or has a hard-link count of two or more;
#                           checked before the lock
#   30  LOCK_BUSY           another process holds the lock; gave up immediately
#   31  CAS_LOST            the file changed under us; nothing written
#   40  VERIFY_FAILED       the pre-commit verify run failed; nothing written
#   1   ERROR               every other `die` — argument contract, jq missing,
#                           settings directory creation, read/write failure
#   22 is deliberately unused.

set -uo pipefail

MODE=""
SETTINGS=""
PLUGIN_DIR=""
REQUIRE_STATE=""
SL_PATH=""
LOCK=""
LOCK_HELD=""
WORK=""
T=""
TB=""

die() { printf 'apply-statusline: %s\n' "$1" >&2; exit 1; }

park_pre() {
  # park_pre <apply-rc> <message> — a park decided before anything is written.
  #
  # The reason travels on the exit code, which needs neither a temporary
  # directory nor a lock nor a file, so it survives a `die` that has allocated
  # nothing. In `--probe` there are only the three codes of that mode's own
  # namespace, so every pre-write park folds into PARKED there.
  printf 'apply-statusline: %s\n' "$2" >&2
  [ "$MODE" = probe ] && exit 1
  exit "$1"
}

# ---------------------------------------------------------------------------
# 0. The argument contract. Everything here is a pure predicate over argv, so it
#    runs before a lock, a temporary directory or a settings directory exists —
#    a misspelled call must not pay for a lock pair, and it must not be
#    REMEMBERED either: rc 1 is outside the verdict band, so the hook writes no
#    marker and the next session tries again.
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --probe)         MODE=probe; shift ;;
    --apply)         MODE=apply; shift ;;
    --settings)      SETTINGS="${2:-}"; shift 2 ;;
    --plugin-dir)    PLUGIN_DIR="${2:-}"; shift 2 ;;
    --require-state) REQUIRE_STATE="${2:-}"; shift 2 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
done

[ -n "$MODE" ] || die "--probe 또는 --apply 중 하나가 필요합니다"

# `--settings` HAS NO DEFAULT AND MUST BE ABSOLUTE, and the two requirements
# defend different things. Without the first, a run aimed at a fixture quietly
# aims at the user's real settings. Without the second, a relative path resolves
# against whatever directory the process happens to be in, which reopens the
# same hole from the other side.
[ -n "$SETTINGS" ] || die "--settings 가 필요합니다"
case "$SETTINGS" in
  /*) ;;
  *)  die "--settings 가 절대경로가 아닙니다: $SETTINGS" ;;
esac

# THE STATE VOCABULARY IS CHECKED HERE, AND AN UNKNOWN TOKEN IS rc 1, NOT rc 21.
# rc 21 is inside the verdict band: the hook records it, the front gate skips
# from the next startup on, and stdout is empty — so a spelling drift sent there
# would kill automatic installation on every machine, permanently, and be
# indistinguishable from a park working correctly.
#
# AND THE VOCABULARY IS NOT SPELLED HERE. Its one source is `sl_classify`, so the
# two tokens this accepts are asked of that function — once for an absent file,
# once for a file holding the command the producer would install — and the value
# is compared against those answers. A copy typed into this file is a second
# spelling waiting to drift from the one the hook sends.
#
# THE GRAMMAR IS SOURCED HERE FOR THAT, BUT A FAILURE TO SOURCE IS NOT FATAL YET.
# A `--plugin-dir` naming a directory that does not exist has no sibling to
# source, and dying here would answer rc 1 where the shape of the failure is
# exactly what the missing-script park below is for — the reason would leave the
# verdict band and the park would stop being remembered. Without the grammar the
# membership test cannot run, so it waits for the four checks to decide; a tree
# that passes them and still lacks the grammar stops with rc 1 there.
command -v jq >/dev/null 2>&1 || die "jq 가 없습니다 — 아무것도 쓰지 않고 멈춥니다"

SL_CMD_LIB="$PLUGIN_DIR/orchestrator/statusline-command.sh"
SL_LIB_LOADED=""
SL_TOK_EMPTY=""
SL_TOK_OURS=""
case "$PLUGIN_DIR" in
  /?*)
    # shellcheck source=./statusline-command.sh
    [ -r "$SL_CMD_LIB" ] && . "$SL_CMD_LIB" 2>/dev/null && SL_LIB_LOADED=1 ;;
esac

# The empty token is what the classifier says about a file that cannot exist —
# nothing can sit below `/dev/null`. Every later test of "was the previous state
# empty" compares against this answer rather than against a spelling.
if [ -n "$SL_LIB_LOADED" ]; then
  SL_TOK_EMPTY=$(sl_classify /dev/null/absent) || SL_TOK_EMPTY=""
fi

if [ "$MODE" = apply ]; then
  [ -n "$REQUIRE_STATE" ] \
    || die "--require-state 가 필요합니다 — --apply 전용 필수 인자입니다"
  if [ -n "$SL_LIB_LOADED" ]; then
    # The ours token needs a file to classify. It is gone before anything else
    # happens, and its name is not one the settings directory or the run's
    # temporary directory counts.
    SL_VOCAB_FILE=$(mktemp "${TMPDIR:-/tmp}/cc-statusline-vocab.XXXXXX") \
      || die "어휘 확인용 임시 파일을 만들 수 없습니다"
    jq -n --arg c "$(SL_PATH=/orchestrator/statusline.sh sl_desired_command "")" \
      '{statusLine: {type: "command", command: $c}}' > "$SL_VOCAB_FILE" 2>/dev/null
    SL_TOK_OURS=$(sl_classify "$SL_VOCAB_FILE") || SL_TOK_OURS=""
    rm -f "$SL_VOCAB_FILE"
    { [ -n "$SL_TOK_EMPTY" ] && [ "$REQUIRE_STATE" = "$SL_TOK_EMPTY" ]; } \
      || { [ -n "$SL_TOK_OURS" ] && [ "$REQUIRE_STATE" = "$SL_TOK_OURS" ]; } \
      || die "--require-state 의 값이 어휘 밖입니다: $REQUIRE_STATE (${SL_TOK_EMPTY:-?} 또는 ${SL_TOK_OURS:-?} 여야 합니다)"
  fi
else
  [ -z "$REQUIRE_STATE" ] \
    || die "--require-state 는 --apply 전용입니다 — --probe 에 동반할 수 없습니다"
fi

# A RUN'S PINNED COPY IS THE OTHER TREE THAT PASSES EVERY CHECK BELOW AND STILL
# DISAPPEARS. It exists, it holds the script, the bit is set — and the reaper
# collects the whole run directory on its own schedule, so the guard this apply
# installs is true now and false for the rest of the machine's life. A pinned
# run's apply stage derives its `--plugin-dir` from `GATE_DIR`, which after the
# hop is inside the copy, so this is reachable by ordinary means rather than by
# a mistake nobody makes. The refusal is here, before anything is written.
SL_STATE_ROOT=$( cd "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds" 2>/dev/null && pwd -P )
SL_PD_PHYS=$( cd "$PLUGIN_DIR" 2>/dev/null && pwd -P )
if [ -n "$SL_STATE_ROOT" ] && [ -n "$SL_PD_PHYS" ]; then
  case "$SL_PD_PHYS" in
    "$SL_STATE_ROOT"|"$SL_STATE_ROOT"/*)
      die "--plugin-dir 이 상태 루트 아래(런의 플러그인 사본)를 가리킵니다: $PLUGIN_DIR — 리퍼가 걷어 가는 트리라 설치되는 가드가 곧 영구히 거짓이 됩니다" ;;
  esac
fi

# ---------------------------------------------------------------------------
# The four checks that stop before anything is written. All of them are pure
# predicates over argv and the filesystem, so they sit ahead of the lock: a park
# here does not pay for an acquire/release pair. Being in the same place does
# not make their disposition the same as the argument contract's — these are
# inside the verdict band, so they are remembered.
# ---------------------------------------------------------------------------

# THE SHAPE CHECK IS FIRST BECAUSE EVERY OTHER CHECK IS DOWNSTREAM OF IT. A
# trailing slash still resolves to the same directory, so `[ -x ]` and the
# re-evaluation would both pass and the park would never happen — while the
# string that reaches the marker and the installed command differs byte for byte
# from the one the next startup computes, and the front gate then reports a
# mismatch on every startup with a re-point write behind it. This script does not
# normalise it away: normalising here would give `$SL_PATH` a second derivation
# site, and silently accepting both spellings erases the fact that there were two.
case "$PLUGIN_DIR" in
  "")   park_pre 26 "--plugin-dir 이 비어 있습니다 — 설치되는 가드가 영구히 거짓이 됩니다" ;;
  */)   park_pre 26 "--plugin-dir 에 후행 슬래시가 남아 있습니다 ($PLUGIN_DIR) — 호출자가 정규화해서 넘겨야 합니다" ;;
  /?*)  ;;
  *)    park_pre 26 "--plugin-dir 이 절대경로가 아닙니다: $PLUGIN_DIR" ;;
esac

SL_PATH="$PLUGIN_DIR/orchestrator/statusline.sh"

# The same test the installed command will make, made HERE where failing it can
# still stop the write.
[ -x "$SL_PATH" ] \
  || park_pre 24 "$SL_PATH 이 실행 가능한 파일이 아닙니다 — 설치되는 가드가 영구히 거짓이 됩니다"

# AND THE SAME TEST AGAIN, THROUGH THE SHELL THAT WILL RE-EVALUATE IT. What gets
# written is a string, and the harness hands that string to `sh -c` on every
# render — so the double quotes around the path stop a space and nothing else. A
# `$`, a backtick or a `"` inside the path is expanded at that second
# evaluation and the guard is false forever.
#
# THIS CHECK GOT STRONGER WHEN THE CALLER BECAME A HOOK. Nobody types the plugin
# path any more; it is assembled from a configuration directory that is derived
# from `$HOME`, so a `$` or a backtick in a username reaches the installed
# string without passing through anyone's hands.
#
# The question asked here is not "which characters are dangerous" but "is the
# guard that is about to be installed actually true", which is the same question
# the render will ask and therefore covers the shapes nobody has enumerated yet.
sh -c "[ -x \"$SL_PATH\" ]" 2>/dev/null \
  || park_pre 25 "설치될 가드가 그대로 평가되지 않습니다 ($SL_PATH) — 경로의 문자가 재평가에서 해석되어 가드가 영구히 거짓이 됩니다"

# THE ONE BAD PATH THAT PASSES EVERY OTHER CHECK is a linked worktree. It exists,
# it holds the script, the bit is set — and it is removed the moment the work in
# it lands, so the guard is true exactly once and false for the rest of the
# machine's life. A linked worktree is what a `--git-dir` differing from its
# `--git-common-dir` means.
#
# THIS IS A MAIN DEFENCE NOW, NOT A LEGACY CHECK. Before the hook, reaching a
# doomed `--plugin-dir` took somebody typing one. Starting a session inside a
# slice worktree is now enough on its own, and on a machine whose only checkouts
# are worktrees that is an ordinary thing to do several times a night. A park
# here is a normal, quiet result and not a fault.
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
#
# THE ANSWER TRAVELS ON THE SUBSHELL'S EXIT STATUS, not on its stdout. Every
# other way of writing this puts an unredirected emission in a file whose one
# invariant is that it has none, and the structural check that keeps that
# invariant honest cannot afford an exception it has to be told about.
if ( cd "$PLUGIN_DIR" 2>/dev/null || exit 1
     gd=$(git rev-parse --git-dir 2>/dev/null) || exit 1
     cm=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
     gd=$(cd "$gd" 2>/dev/null && pwd -P) || exit 1
     cm=$(cd "$cm" 2>/dev/null && pwd -P) || exit 1
     [ "$gd" != "$cm" ] ); then
  park_pre 23 "--plugin-dir 이 임시 워크트리를 가리킵니다 ($PLUGIN_DIR) — 이 트리는 곧 사라지고 설치되는 가드는 그때부터 영구히 거짓입니다"
fi

# THE GRAMMAR IS SOURCED, NOT RESTATED. A partial checkout that lost this
# sibling must stop rather than fall back on a second recogniser — and only
# here, after the four checks, is a failure to have sourced it a fault of its
# own rather than the shadow of one of them.
[ -n "$SL_LIB_LOADED" ] || die "$SL_CMD_LIB 을 소스할 수 없습니다"

# ---------------------------------------------------------------------------
# Installer-only helpers. The hook computes no digest and runs no verify, so
# there is no second derivation of either that could drift.
# ---------------------------------------------------------------------------

sl_subdigest() {
  # sl_subdigest <settings-file> — sha256 over the `.statusLine` subobject.
  #
  # THE SUBOBJECT, NOT THE FILE, and this is a convergence test rather than the
  # compare-and-swap. The surrounding keys drift on their own, and `jq`
  # reformats the whole file on the way out, so a whole-file comparison here
  # would report a difference that is only indentation.
  #
  # The normalisation is part of the contract and not an implementation detail:
  # `jq -S -c` and the trailing newline `jq` prints are both inside the hashed
  # bytes.
  jq -S -c '.statusLine' "$1" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

sl_probe() {
  # The three-way state machine of `--probe`'s own namespace. The pre-write
  # checks and the target shape check have already run and already folded their
  # failures into PARKED, so reaching here means all of them passed and WRITABLE
  # only has the value question left to answer.
  local cls cur want
  cls=$(sl_classify "$SETTINGS") || return 1
  [ "$cls" = foreign ] && return 1
  # Nothing to compare against: an absent file is always writable.
  [ -f "$SETTINGS" ] || return 2
  sl_render_desired "$SETTINGS" "$WORK/desired.json" || return 1
  cur=$(sl_subdigest "$SETTINGS")
  want=$(sl_subdigest "$WORK/desired.json")
  [ -n "$cur" ] && [ -n "$want" ] || return 1
  [ "$cur" = "$want" ] && return 0
  return 2
}

sl_verify() {
  # sl_verify <command> — run the command about to be installed, once, and judge
  # it. Five conditions, all of them: exit 0, non-empty, at most one line, at
  # most 512 bytes, finished within one second. This is what a status line
  # failing looks like from the outside, and any one of them alone would let a
  # broken shape land.
  #
  # ONE SECOND, NOT THREE. A status line that takes longer than a second to
  # render has already failed, and the whole poll sits in front of the commit on
  # the session-startup path.
  #
  # THE COMMAND COMES FROM THE RENDERED FILE, NOT FROM THE SETTINGS FILE.
  # Nothing has been committed yet, so there is nothing to read there — and this
  # function never consults the settings file anyway, which is what makes its
  # verdict the same before and after a write.
  local cmd="$1" out rc n_nl bytes p i=0 payload
  out="$WORK/verify.out"
  : > "$out"
  payload='{"session_id":"cc-apply-verify","transcript_path":"/dev/null","cwd":"'"$PWD"'","workspace":{"current_dir":"'"$PWD"'","project_dir":"'"$PWD"'"},"model":{"id":"probe","display_name":"probe"}}'
  sh -c "$cmd" <<<"$payload" > "$out" 2>/dev/null &
  p=$!
  # No `timeout`: the binary is GNU-only and absent on the platform this runs
  # on. Polling a recorded pid with `kill -0` is the portable shape, and it is
  # the same one the liveness predicate uses for the same reason.
  while [ "$i" -lt 10 ]; do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    printf '검증 실패: 1초를 넘겼습니다\n' >&2
    return 1
  fi
  wait "$p"; rc=$?
  [ "$rc" -eq 0 ] || { printf '검증 실패: 종료 코드 %s\n' "$rc" >&2; return 1; }
  [ -s "$out" ]   || { printf '검증 실패: 출력이 비어 있습니다\n' >&2; return 1; }
  bytes=$(wc -c < "$out" | tr -d ' ')
  [ "$bytes" -le 512 ] || { printf '검증 실패: %s바이트\n' "$bytes" >&2; return 1; }
  # "AT MOST ONE LINE" COUNTS LINES, NOT NEWLINES. The command this replaces
  # ends its format string at `%s` and so emits none, and the fallback branch
  # has to reproduce that output byte for byte — so a rule spelled "must end in
  # a newline" would fail every apply that lands on the fallback. One optional
  # trailing newline is stripped; what remains may hold none.
  n_nl=$(tr -dc '\n' < "$out" | wc -c | tr -d ' ')
  [ "$n_nl" -le 1 ] || { printf '검증 실패: %s줄입니다\n' "$((n_nl + 1))" >&2; return 1; }
  return 0
}

publish_backup() {
  # publish_backup <slot> — put `$WORK/pre` into a backup slot atomically.
  #
  # BOTH SLOTS GO THROUGH A NAMED TEMPORARY IN THE SETTINGS DIRECTORY, and the
  # three lines are fixed. `rename(2)` cannot cross a filesystem, and the source
  # here lives under `$TMPDIR` while the slot lives beside the settings file —
  # a `mv` across that boundary degrades to copy-and-delete, and the degraded
  # form is observable: a truncated mode-000 file at the destination if the
  # process dies mid-copy, and no destination at all if the copy runs out of
  # space. For `.prev` that is an unreadable backup; for `.orig`, whose rule is
  # write-once, a truncated file is accepted by `[ -e ]` forever after.
  #
  # `cp`, NOT `cp -p`. `-p` would WIDEN the temporary file's 0600 to the source's
  # mode — the exact opposite of what `$T` needs. The result is that both slots
  # are 0600 regardless of the settings file's own mode, which is the direction
  # this design wants for a verbatim copy of a file that can hold API keys.
  local slot="$1"
  TB=$(mktemp "$SETTINGS.cc-statusline.bak-tmp.XXXXXX") || return 1
  cp "$WORK/pre" "$TB" || return 1
  mv "$TB" "$slot" || return 1
  TB=""
  return 0
}

set_owned_bit() {
  # THE INSTALL HISTORY IS A FILE WHOSE EXISTENCE IS THE BIT, and the only
  # operation defined on it is creation. Monotonicity is then a structural
  # property rather than a rule somebody has to keep: with no update there is no
  # update to lose, and the two processes that race over it cannot disagree.
  #
  # The installer owns it rather than the hook because of the machines that
  # already had a status line before this file existed: they are "ours with no
  # history" by definition, and creating the bit right after a commit closes
  # that hole unconditionally instead of only if another session runs in between.
  [ -e "$SETTINGS.cc-statusline-owned" ] || : > "$SETTINGS.cc-statusline-owned"
}

settings_is_linked() {
  # settings_is_linked — true when the settings file is a symbolic link (a
  # dangling one included) or a regular file with two or more hard links.
  #
  # THE ORDER IS FIXED. `find` does not follow an operand symlink, so on a live
  # link it sees the link's own count of one; and a dangling link fails `[ -e ]`,
  # so only `[ -L ]` catches it. An absent file is neither, which is how the
  # create path passes straight through.
  #
  # ONLY THE LAST COMPONENT IS LOOKED AT. A linked settings DIRECTORY resolves
  # `$T` and the settings file into the same real directory, so the rename there
  # replaces an ordinary file and nothing the user manages changes identity.
  [ -L "$SETTINGS" ] && return 0
  [ -n "$(find "$SETTINGS" -maxdepth 0 -links +1 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# The settings directory, then the target shape check, then the lock, then the
# work directory.
#
# THE DIRECTORY IS CREATED AFTER THE PRE-WRITE CHECKS AND BEFORE THE LOCK, and
# that is the only place it fits. Ahead of the checks it would leave an empty
# directory of our making on a machine that parks. Behind the lock it cannot go
# at all, because the lock lives inside it.
# ---------------------------------------------------------------------------
if [ "$MODE" = apply ]; then
  # `${SETTINGS%/*}` RATHER THAN `dirname`, BUT NEVER WITHOUT THE GUARD. On an
  # argument holding no slash the expansion yields the argument itself, and
  # `mkdir -p` then creates a DIRECTORY where the settings file was supposed to
  # go and exits 0 — after which `[ -f ]` is false forever, every run takes the
  # create path, and nothing reports any of it. The absolute-path requirement
  # above already makes that input unreachable; the two defend different things,
  # and this one is what keeps a later relaxation of that requirement from
  # turning into this accident.
  DIR="${SETTINGS%/*}"
  if [ -n "$DIR" ] && [ "$DIR" != "$SETTINGS" ]; then
    mkdir -p "$DIR" || die "설정 디렉터리 생성 실패: $DIR"
  fi
fi

# THE TARGET SHAPE CHECK: A SETTINGS FILE MANAGED THROUGH A LINK IS NOT WRITTEN.
# The commit below is a rename, and a rename replaces the NAME, not the file the
# name points at — a symbolic link would become a plain file while its source
# kept the old bytes, and a hard link would split into two inodes. Nothing is
# lost, but the file a dotfiles manager owns and the file the harness reads
# would silently part ways from then on.
#
# FOLLOWING THE LINK INSTEAD IS NOT AN OPTION. No rename preserves a hard link,
# so following it means writing in place, and that brings back the partial file
# a concurrent reader can observe — the reason the commit is a rename at all.
#
# A REMEMBERED PARK, NOT AN rc 1. Being a link does not change between sessions,
# so an error outside the verdict band would send that machine down the slow
# path on every startup; inside the band the front gate skips until the user's
# own write to the file reopens the decision. It sits after the settings
# directory and before the lock: a pure filesystem predicate like the four
# above, and a link that exists has a parent that exists, so the hook's marker
# always lands. In `--probe` it folds into PARKED, as the four do.
if settings_is_linked; then
  park_pre 27 "설정 파일이 심볼릭 링크이거나 하드 링크입니다 ($SETTINGS) — 링크로 관리되는 파일은 쓰지 않습니다. 상태줄 값은 링크 원본에 손으로 넣어 주세요"
fi

if [ "$MODE" = apply ]; then
  # THE LOCK IS AN OPTIMISATION AND CARRIES NO CORRECTNESS. Every way it can
  # fail — one attempt then give up, a racy stale reclaim, a non-atomic
  # re-acquire — degrades to "another process did useless work", and the
  # whole-file compare-and-swap turns that into a no-op. So there is no retry
  # here and no `rm -rf` escape hatch: the path is assembled from an argument,
  # and this script runs unattended on every session start.
  #
  # NOTHING IS EVER WRITTEN INSIDE THE LOCK DIRECTORY. `rmdir` refuses a
  # non-empty directory, so a holder pid file inside it could not be released by
  # the `trap 'rmdir' EXIT` idiom this tree already uses — and a lock left behind
  # by the first session then blocks four out of five of the next ones. Its own
  # mtime is the acquisition time, which is what makes the stale check possible
  # without writing anything.
  #
  # RECLAIMING IS NOT ACQUIRING. Giving up anyway is what keeps "one attempt,
  # then give up" literally true and bounds the cost of a stale lock at exactly
  # one session startup.
  LOCK="$SETTINGS.cc-statusline.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null || :
    fi
    # Nothing has been allocated yet, so there is nothing to clean up — a
    # stronger guarantee than a trap gives, and one that holds under SIGKILL.
    exit 30
  fi
  LOCK_HELD=1
fi

# `$WORK` IS CREATED ONLY AFTER THE LOCK ATTEMPT HAS RESOLVED, and the single
# EXIT trap goes on the very next line. Losing the lock is a normal outcome here
# and the hook runs on every session start, so a temporary directory made before
# that branch would accumulate on the most common path of all.
#
# THE TRAP'S `rmdir` IS GUARDED BY `LOCK_HELD`. Unguarded, a process that never
# held the lock deletes the current holder's — and `--probe` is exactly such a
# process, since it needs `$WORK` and never takes the lock.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cc-apply-statusline.XXXXXX") || die "임시 디렉터리 생성 실패"
trap 'rm -rf "${WORK:-}"; rm -f "${T:-}" "${TB:-}" 2>/dev/null || :; [ -n "${LOCK_HELD:-}" ] && rmdir "${LOCK:-}" 2>/dev/null; :' EXIT

if [ "$MODE" = probe ]; then
  sl_probe
  exit $?
fi

# ---------------------------------------------------------------------------
# 1. The snapshot, and the ONLY read of the settings file.
#
#    Its success or failure IS the path selection: a copy that worked means the
#    replace path, and a target that is not there means the create path. An
#    existing file that cannot be read is neither — folding it into "empty"
#    would make an unreadable settings file an install target.
# ---------------------------------------------------------------------------
if cp "$SETTINGS" "$WORK/pre" 2>/dev/null; then
  MODE_PATH=replace
elif [ -e "$SETTINGS" ]; then
  die "설정 파일을 읽을 수 없습니다: $SETTINGS"
else
  MODE_PATH=create
fi

# 1a. Re-derive the classification FROM THE SNAPSHOT. The hook's verdict is not
#     trusted, and the settings file is not read a second time — classifying one
#     file and committing against another is the shape the compare-and-swap
#     exists to prevent. On the create path the classification is a derivation
#     rather than an assumption: the snapshot failed because the file is absent,
#     and an absent file is the first item in the definition of empty.
if [ "$MODE_PATH" = replace ]; then
  CLS=$(sl_classify "$WORK/pre") || die "설정 JSON 을 읽을 수 없습니다 — 쓰기 전에 멈춥니다"
else
  CLS="$SL_TOK_EMPTY"
fi

if [ "$CLS" = foreign ]; then
  printf 'apply-statusline: 현재 상태줄이 제삼자의 값입니다 — 아무것도 쓰지 않습니다\n' >&2
  exit 20
fi

# 1b. The state gate. The vocabulary was checked back at argv, so what is left
#     here is only a RECOGNISED token that disagrees with the snapshot — the
#     window between the hook's read and this one. On the create path it is the
#     branch that stops a settings file the user has just deleted wholesale from
#     being recreated with our status line in it.
if [ "$REQUIRE_STATE" != "$CLS" ]; then
  printf 'apply-statusline: 호출자가 넘긴 상태(%s)가 스냅숏의 분류(%s)와 다릅니다 — 아무것도 쓰지 않습니다\n' "$REQUIRE_STATE" "$CLS" >&2
  exit 21
fi

# 2. Render. Reads the snapshot, never the settings file.
sl_render_desired "$WORK/pre" "$WORK/desired.json" \
  || die "설정 JSON 을 렌더할 수 없습니다 — 쓰기 전에 멈춥니다"

# CONVERGENCE IS DECIDED BEFORE ANYTHING ELSE HAPPENS, and the test is the one
# the probe's rc 0 uses: is the rendered `.statusLine` byte-identical to the one
# already there. Path equality is NOT the test — a stale path is only one of the
# reasons a write is owed, `refreshInterval` being absent is another, and a
# guardless call being present is a third. Writing anyway on a converged machine
# would publish a backup and touch `.prev` on every session for no change at all.
if [ "$MODE_PATH" = replace ] \
   && [ "$(sl_subdigest "$WORK/pre")" = "$(sl_subdigest "$WORK/desired.json")" ]; then
  set_owned_bit
  exit 0
fi

# 3. Verify — the first install only, and BEFORE the commit.
#
#    Skipped when the previous value was already ours because that machine
#    ALREADY HAS a status line: the bottom keyboard hints are already gone, so a
#    broken render is no worse than what was on screen a moment ago. On a first
#    install the fallback is `true` and emits nothing, the hints disappear, and
#    the failure state is strictly worse than having no status line at all.
#    Nothing has been written when this fails, so there is nothing to undo.
if [ "$CLS" = "$SL_TOK_EMPTY" ]; then
  VERIFY_CMD=$(jq -r '.statusLine.command // ""' "$WORK/desired.json" 2>/dev/null)
  sl_verify "$VERIFY_CMD" || exit 40
fi

if [ "$MODE_PATH" = replace ]; then
  # 4. Seed the temporary file from the target so it inherits the target's mode,
  #    then overwrite its content. `rename(2)` replaces the inode, so without
  #    this the settings file would silently acquire `mktemp`'s 0600. There is
  #    no portable `stat` and no `chmod --reference`, so `cp -p` is how the mode
  #    is obtained. This copy is outside the exposure window.
  T=$(mktemp "$SETTINGS.cc-statusline.tmp.XXXXXX") || die "임시 파일 생성 실패"
  cp -p "$SETTINGS" "$T" || die "임시 파일 준비 실패"
  cat "$WORK/desired.json" > "$T" || die "임시 파일 쓰기 실패"

  # 5. The compare-and-swap, over the WHOLE FILE. `jq` re-emits every key, so
  #    the bytes we put at risk are all of them; a subobject comparison would
  #    miss the harness editing `theme` and the rename would silently revert it.
  if ! cmp -s "$WORK/pre" "$SETTINGS"; then
    printf 'apply-statusline: 설정 파일이 그사이 바뀌었습니다 — 아무것도 쓰지 않습니다\n' >&2
    exit 31
  fi

  # 6. Commit. NOTHING GOES BETWEEN 5 AND 6. The name being replaced is a
  #    regular file with a single link — the target shape check before the lock
  #    guarantees it, so this rename cannot turn a managed link into a copy.
  mv "$T" "$SETTINGS" || die "설정 쓰기 실패"
  T=""

  # 7. The backups, AFTER the commit. Before it, a compare-and-swap that loses
  #    would leave the backup of a write that never happened, and the window
  #    between the compare and the rename would widen several-fold.
  [ -e "$SETTINGS.orig" ] || publish_backup "$SETTINGS.orig" || die "백업 발행 실패 (.orig)"
  publish_backup "$SETTINGS.prev" || die "백업 발행 실패 (.prev)"
else
  # 3'. No snapshot, no `cp -p` and no `cmp` on this path — there is no previous
  #     content to preserve, so `mktemp`'s 0600 is the final mode, and that is
  #     the right default for a file that can carry API keys.
  T=$(mktemp "$SETTINGS.cc-statusline.tmp.XXXXXX") || die "임시 파일 생성 실패"
  cp "$WORK/desired.json" "$T" || die "임시 파일 쓰기 실패"

  # 4'. `ln`, NOT `mv -n`. The compare-and-swap on this path is "the file is
  #     still absent", and BSD `mv -n` answers rc 0 whether it moved or refused,
  #     which loses the distinction entirely. `ln` fails on an existing target.
  if ! ln "$T" "$SETTINGS" 2>/dev/null; then
    printf 'apply-statusline: 설정 파일이 그사이 생겼습니다 — 아무것도 쓰지 않습니다\n' >&2
    exit 31
  fi

  # 5'. No backup on this path: there is no previous state to copy.
  rm -f "$T"
  T=""
fi

# 8. The ownership bit, only once the value is known to be ours — after a
#    successful commit here, or after the byte-identity check above. A park, a
#    lost compare-and-swap, a failed verify and an error never reach this line;
#    claiming ownership of a value we did not write is what that would be.
set_owned_bit

[ "$CLS" = "$SL_TOK_EMPTY" ] && exit 10
exit 11
