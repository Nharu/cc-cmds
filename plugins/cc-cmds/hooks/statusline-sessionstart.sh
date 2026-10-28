#!/usr/bin/env bash
# statusline-sessionstart.sh — the deciding half of the automatic status line
# install. It classifies, it remembers, and it never writes the settings file.
#
# THE SPLIT IS NOT COSMETIC. This hook runs on every `startup` session on every
# machine, so the overwhelmingly common case has to cost nothing: the front gate
# below answers "already converged" without a single fork and leaves. Everything
# expensive — sourcing the shared grammar, running `jq`, taking a lock, writing
# the file — happens only after that gate has said no.
#
# ITS STDOUT IS A CONTROL CHANNEL. `SessionStart` injects a child's stdout into
# the session context, and a payload that parses as JSON is read as a control
# message. So every path here writes ZERO bytes to stdout except the one that
# actually installed a status line for the first time, which writes a single
# fixed literal with no interpolation slot in it at all. Diagnostics go to
# stderr, which the harness only surfaces under `--debug`.
#
# EVERY EXIT IS `exit 0`, WITHOUT EXCEPTION. A hook that fails a session start is
# worse than a status line that never installs, so `set -e` is not used and the
# front gate is a function that returns rather than a block that exits. The one
# way this script could end non-zero is an unset variable under `set -u`, which
# is why the prologue initialises every variable it later expands.
#
# WHAT IT DERIVES AND WHAT IT IS HANDED. The plugin root arrives on argv and is
# never read from the environment — the harness substitutes it into the hook
# registration, and a hook that also consulted the environment would have two
# sources for one value, which is the shape a structural check in the suite
# forbids by name. The target settings path is derived HERE and passed on
# to the installer, which re-derives nothing. Everything else — marker, ownership
# bit, lock, backups — is a pure function of that one path, so a single
# derivation site makes all of them single-derivation too.
#
# Usage (as registered in `hooks.json`, never typed by hand):
#   bash <plugin root>/hooks/statusline-sessionstart.sh --plugin-dir <plugin root>
#
# Compatibility: bash 3.2 — no associative arrays, no `mapfile`, no `wait -n`.

# THE TWO GUARDS COME FIRST because both are one string comparison and both mean
# "do not run at all". `0` is the ONLY value that disables the install; unset,
# empty, `1`, `false` and everything else leave it on. The vocabulary is one
# token on purpose — the effect is immediately observable (a status line either
# appears or does not), and this hook has no channel on which to warn about a
# misspelling.
[ "${CC_CMDS_STATUSLINE_AUTOINSTALL:-}" = "0" ] && exit 0
# A pipeline stage session loads this plugin too. Without this guard several
# stages of one unattended run would race each other, and the run's own
# pipeline, over the same settings key.
[ -n "${CC_PIPELINE_STAGE_ID:-}" ] && exit 0

# >>> cc-statusline gate region begin
# THE PROLOGUE AND THE GATE ARE ONE FORK-FREE BLOCK, and the suite extracts this
# region and sources it on its own to prove it. Nothing between the two markers
# may use a command substitution or a backtick — including in a comment, because
# the check that holds the property reads the region as bytes — and every word it
# runs has to be a builtin, a reserved word, or a function defined in here.
export LC_ALL=C
set -uo pipefail

# Initialised before use because set -u is on and a redirection that fails
# leaves the read variable UNSET. Expanding its length would then abort the hook,
# which is the one way the unconditional exit 0 above can be broken.
PLUGIN_DIR=""; SETTINGS=""; SL_PATH=""; LEN='-'
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-dir) PLUGIN_DIR="${2:-}"; shift 2 ;;
    *)            shift ;;
  esac
done

# EVERY TRAILING SLASH COMES OFF, HERE AND ONLY HERE. The installer refuses a
# value that still carries one rather than normalising it, because the string
# assembled from this directory is written into the user's settings and compared
# byte for byte by the gate below — two spellings of one directory would mean a
# mismatch on every startup with a re-point write behind it.
while [ "${PLUGIN_DIR%/}" != "$PLUGIN_DIR" ]; do
  PLUGIN_DIR="${PLUGIN_DIR%/}"
done
case "$PLUGIN_DIR" in /?*) ;; *) exit 0 ;; esac
SL_PATH="$PLUGIN_DIR/orchestrator/statusline.sh"

sl_settings_path() {
  # TWO STEPS, NOT ONE. A single-step default of the form CONFIG-or-HOME/.claude
  # yields /.claude/settings.json when HOME is empty, and this design CREATES the
  # parent directory of what it is handed — an empty home would have it try to
  # make a directory at the filesystem root on every session. The answer is
  # assigned to a global rather than printed, because a command substitution is a
  # fork and this line runs on the converged path too.
  local cfg="${CLAUDE_CONFIG_DIR:-}"
  [ -n "$cfg" ] || cfg="${HOME:-}${HOME:+/.claude}"
  cfg="${cfg%/}"
  [ -n "$cfg" ] || return 1
  SETTINGS="$cfg/settings.json"
}
sl_settings_path || exit 0

MARKER="$SETTINGS.cc-statusline"
OWNED="$SETTINGS.cc-statusline-owned"
# Derived here for the same reason the two above are — a pure function of the
# target. The hook never acquires it; the installer is the lock's only holder.
LOCK="$SETTINGS.cc-statusline.lock"

sl_read_len() {
  # sl_read_len — set LEN to the byte count of the settings file, or to the
  # literal dash when it is absent or unreadable.
  #
  # THE READING METHOD IS PART OF THE CONTRACT, not an implementation detail. A
  # substitution that reads a file strips its trailing newline and read -d does
  # not, so a writer and a reader that chose differently disagree by one byte on
  # every file ending in a newline — and the gate then never skips again,
  # silently. read -d returns 1 at EOF on a file holding no NUL while still
  # having filled the variable, which is what the trailing true is for.
  #
  # ABSENCE IS NOT LENGTH ZERO. An absent file is never newer than a present one,
  # so condition 2 cannot see a settings file the user deleted outright; folding
  # absence into a length of zero would hide that deletion from condition 4 too.
  #
  # This is the one condition that is not constant time — its cost grows with
  # the size of the settings file.
  local buf=''
  LEN='-'
  if [ -e "$SETTINGS" ] && [ -r "$SETTINGS" ]; then
    IFS= read -r -d '' buf 2>/dev/null < "$SETTINGS" || true
    LEN=${#buf}
  fi
}

sl_gate_converged() {
  # rc 0 = converged, skip everything. rc 1 = take the slow path.
  #
  # IT DOES NOT ASK "IS OUR WRAPPER SOMEWHERE IN THIS FILE". A substring gate
  # reports convergence on a file whose status line key was renamed away, and on
  # one where our wrapper sits under the subagent key while the main one holds a
  # third party's value — and that false positive is permanent, because its
  # condition is a stable property of the file. It asks instead: is this the
  # exact byte string I last confirmed, and is the plugin still where it was.
  #
  # CONDITION 3 IS WHAT MAKES THE DESIGN WORK AT ALL. A plugin version update
  # does not touch the settings file, so marker-and-mtime alone would skip
  # forever with the status line aimed at a cache directory that no longer
  # exists. It doubles as the drift detector.
  #
  # CONDITION 4 COVERS THE BLIND SPOT OF CONDITION 2. The newer-than test has
  # one-second resolution on bash 3.2, so two writes inside one second are
  # indistinguishable to it.
  local mk=''
  [ -f "$MARKER" ] || return 1
  [ "$SETTINGS" -nt "$MARKER" ] && return 1
  IFS= read -r -d '' mk 2>/dev/null < "$MARKER" || true
  sl_read_len
  case "$mk" in *"|path=$SL_PATH|"*) ;; *) return 1 ;; esac
  case "$mk" in *"|len=$LEN|"*)      ;; *) return 1 ;; esac
  return 0
}
# <<< cc-statusline gate region end

sl_gate_converged && exit 0

# >>> cc-statusline verdict region begin
verdict_name() {
  # verdict_name <installer rc> <ownership bit before the call: y or n> — print
  # the verdict and the reason separated by a bar, or return 1 when the code is
  # outside the verdict band.
  #
  # THE NAME IS A PRODUCT OF TWO THINGS AND THE INSTALLER ONLY KNOWS ONE. Its
  # exit code reports what happened to the settings file; whether this machine
  # had ever owned that value is history, and history is the hook's to read. So
  # rc 0 and rc 11 each split in two here, and no exit code has to be invented
  # for an adoption.
  #
  # THE BAND IS WHAT GETS REMEMBERED. Codes outside it — 1, 30, 31 — mean the
  # run never reached a verdict, so no marker is written and the next session
  # retries. Codes inside it are recorded, so the gate skips from then on. An
  # error retries; a park is remembered. That asymmetry is deliberate.
  case "$1" in
    0)  if [ "$2" = y ]; then printf 'converged|'; else printf 'adopted|'; fi ;;
    10) printf 'installed|' ;;
    11) if [ "$2" = y ]; then printf 'drift-repair|'; else printf 'adopt-repoint|'; fi ;;
    20) printf 'park|foreign' ;;
    21) printf 'park|require-state' ;;
    23) printf 'park|worktree' ;;
    24) printf 'park|sl-missing' ;;
    25) printf 'park|guard-reeval' ;;
    26) printf 'park|plugin-dir' ;;
    27) printf 'park|linked' ;;
    40) printf 'verify-failed|verify' ;;
    *)  return 1 ;;
  esac
  return 0
}
# <<< cc-statusline verdict region end

# `jq` IS LOOKED UP AFTER THE PREPEND, AND MISSING IT FAILS OPEN. Homebrew's
# directory is not on a login shell's PATH in every session, and without the
# prepend this feature would die on those machines leaving no trace whatsoever —
# every exit is 0 and every stdout is empty. The disable switch exists so the
# missing-tool branch is reachable in a test; NOTE THAT THE TWO SWITCHES IN THIS
# FILE HAVE OPPOSITE VOCABULARIES — this one disables on any non-empty value.
if [ -z "${CC_CMDS_STATUSLINE_PATH_DISABLE_PREPEND:-}" ]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi
command -v jq >/dev/null 2>&1 || exit 0

# THE GRAMMAR IS SOURCED, NEVER RESTATED. The installer sources the same file,
# so the two processes cannot disagree about what counts as our own wrapper —
# and a partial checkout that lost it stops here rather than falling back on a
# second recogniser. Sourced AFTER the gate, because the converged path must not
# pay for it.
. "$PLUGIN_DIR/orchestrator/statusline-command.sh" 2>/dev/null || exit 0

# READ BEFORE THE CALL. The installer creates the ownership bit while it runs, so
# an observation taken afterwards would report "had history" for the very run
# that established it and turn every adoption into a convergence.
HAD_BIT=n
[ -e "$OWNED" ] && HAD_BIT=y

# The spelling that crosses to the installer is never typed on either side: this
# is what the classifier returned, passed through unchanged, and the installer
# compares it against what the same function returns for its own snapshot.
CLS=$(sl_classify "$SETTINGS") || exit 0

VERDICT=""
REASON=""
if [ "$CLS" = foreign ]; then
  # Somebody else's status line. The installer is not called at all.
  VERDICT=park
  REASON=foreign
elif [ "$HAD_BIT" = y ] && [ "$CLS" = "$(sl_classify /dev/null/absent)" ]; then
  # Owned once, empty now: the user deleted it. This branch is what makes "a
  # status line you removed does not come back" true, and it is also why the bit
  # lives in its own file — nothing here clears it. "Empty" is asked of the
  # classifier, about a path nothing can sit at, rather than spelled here.
  VERDICT=deleted
else
  bash "$PLUGIN_DIR/orchestrator/apply-statusline.sh" --apply \
    --settings "$SETTINGS" --plugin-dir "$PLUGIN_DIR" --require-state "$CLS" >/dev/null
  APPLY_RC=$?
  NAMED=$(verdict_name "$APPLY_RC" "$HAD_BIT") || exit 0
  VERDICT="${NAMED%%|*}"
  REASON="${NAMED##*|}"
fi

# THE MARKER IS WRITTEN WHOLE AND ATOMICALLY, AND WITHOUT A LOCK. Every field on
# the line is this session's own observation — nothing is carried over from the
# previous line — so two sessions writing at once cannot lose each other's data,
# and the rename keeps the gate from ever reading half a line. The temporary name
# carries the same prefix as every other sibling this design creates, so the one
# published cleanup instruction covers it if a kill leaves it behind.
#
# `len=` IS TAKEN AT VERDICT TIME, with the same builtin read the gate uses. A
# writer using `wc -c` and a reader using a builtin length would disagree on any
# file ending in a newline, and the gate would then never skip again.
sl_read_len
MK_TMP=$(mktemp "$SETTINGS.cc-statusline.mk-tmp.XXXXXX" 2>/dev/null) || exit 0
if printf 'schema=1|path=%s|len=%s|lastAt=%s|verdict=%s|reason=%s|\n' \
     "$SL_PATH" "$LEN" "$(date +%s)" "$VERDICT" "$REASON" > "$MK_TMP" 2>/dev/null \
   && mv "$MK_TMP" "$MARKER" 2>/dev/null; then
  :
else
  rm -f "$MK_TMP" 2>/dev/null
fi

# THE ONE LINE THIS HOOK IS EVER ALLOWED TO PRINT, and only for the verdict that
# actually put a status line on a screen that had none. That is the moment the
# bottom keyboard hints disappear, and it is the only moment a user needs telling.
# The literal carries no interpolation slot of any kind: a path, a command string
# or a digest here would be injected into the model's context on every install.
# It also does not point at the two snapshot slots — restoring one of those
# rewinds the whole settings file, not the status line.
if [ "$VERDICT" = installed ]; then
  printf '{"systemMessage":"cc-cmds 가 상태줄을 설치했습니다. 상태줄이 있으면 화면 하단의 키보드 힌트가 대부분 가려집니다. 다음부터 자동 설치를 원치 않으면 CC_CMDS_STATUSLINE_AUTOINSTALL=0 을 설정하세요. 지금 설치된 상태줄을 없애는 방법은 README 의 Uninstall 절에 있습니다."}\n'
fi

exit 0
