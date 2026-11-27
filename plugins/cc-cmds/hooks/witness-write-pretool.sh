#!/usr/bin/env bash
# witness-write PreToolUse hook — self-approves the Write calls an agent-team
# member makes for its own witness draft and its progress checkpoints, outside a
# pipeline run, so a member's round does not stop on a permission dialog.
#
# A Write is allowed only when every condition below holds; otherwise the hook
# prints nothing and exits 0, which leaves the call to the default permission
# gate. It never exits 2, so it never blocks a call.
#   - CC_PIPELINE_RUN_DIR is unset. Inside a run the gate decides every act,
#     and a decision here would sit beside it.
#   - XDG_STATE_HOME, when set, is an absolute path.
#   - file_path is absolute and has no `..` component.
#   - The target's parent, resolved to its physical path, is a witness
#     directory `<root>/cc-team-witness-<id>` (the name the witness init helper
#     mints, `<id>` in `A-Za-z0-9._-`) or its `partial` directory, where
#     <root> is `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design` resolved
#     the same way.
#   - The leaf name is a draft `.{role}.{round}.<16 hex>` in the witness
#     directory, or a checkpoint `{role}.{round}.seq-<n>.<16 hex>.md` in
#     `partial`. Role and round tokens use only `A-Za-z0-9_-`.
#   - Neither the witness directory nor `partial`, as written in file_path, is
#     a symbolic link, and the leaf is not one.
#   - An existing leaf is a regular file with link count 1.
# The role brief `prompt/{role-slug}.md` is never allowed.
export LC_ALL=C
unset CDPATH
if [[ -z "${CC_CMDS_WITNESS_HOOK_PATH_DISABLE_PREPEND:-}" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
fi

ww_main() {
  local input fp state root proot parent pparent leaf wd base
  [[ -z "${CC_PIPELINE_RUN_DIR:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  input=$(cat) || return 0
  fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || return 0
  [[ -n "$fp" ]] || return 0
  case "$fp" in
    /*) ;;
    *) return 0 ;;
  esac
  case "$fp/" in
    */../*) return 0 ;;
  esac

  state="${XDG_STATE_HOME:-}"
  if [[ -n "$state" ]]; then
    case "$state" in
      /*) ;;
      *) return 0 ;;
    esac
  else
    [[ -n "${HOME:-}" ]] || return 0
    state="$HOME/.local/state"
  fi
  root="$state/cc-cmds/design"
  proot=$(cd -P -- "$root" 2>/dev/null && pwd -P) || return 0
  [[ -n "$proot" ]] || return 0

  leaf="${fp##*/}"
  parent="${fp%/*}"
  [[ -n "$leaf" && -n "$parent" ]] || return 0
  pparent=$(cd -P -- "$parent" 2>/dev/null && pwd -P) || return 0

  base="${parent##*/}"
  if [[ "$base" == partial ]]; then
    [[ ! -L "$parent" ]] || return 0
    wd="${parent%/*}"
    [[ ! -L "$wd" ]] || return 0
    [[ "$pparent" == "$proot/${wd##*/}/partial" ]] || return 0
    [[ "${wd##*/}" =~ ^cc-team-witness-[A-Za-z0-9._-]+$ ]] || return 0
    [[ "$leaf" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.seq-[0-9]+\.[0-9a-f]{16}\.md$ ]] || return 0
  else
    [[ ! -L "$parent" ]] || return 0
    [[ "$pparent" == "$proot/$base" ]] || return 0
    [[ "$base" =~ ^cc-team-witness-[A-Za-z0-9._-]+$ ]] || return 0
    [[ "$leaf" =~ ^\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[0-9a-f]{16}$ ]] || return 0
  fi

  [[ ! -L "$fp" ]] || return 0
  if [[ -e "$fp" ]]; then
    [[ -f "$fp" ]] || return 0
    [[ -n "$(find "$fp" -maxdepth 0 -type f -links 1 2>/dev/null)" ]] || return 0
  fi

  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "agent-team witness draft self-approve"
    }
  }'
}

ww_main || true
exit 0
