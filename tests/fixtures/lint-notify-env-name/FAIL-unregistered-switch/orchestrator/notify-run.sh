#!/usr/bin/env bash
# Fixture emitter — reads a THIRD `CC_CMDS_` name that no document announces and
# that is not on the registered list.
#
# THIS IS THE FIXTURE THE SET RULE EARNS ITS KEEP ON. The old "exactly one" form
# could not be given a second switch at all, so the failure it could never
# express is precisely this one: a switch has been added to the code and nobody
# was told to type it. Nothing fails at runtime — the variable simply does what
# its author meant, unannounced — and the prose side stays perfectly consistent,
# so rules 2 and 3 both pass while the tree carries an undocumented switch.

cc_notify_enabled() {
  local v="${CC_CMDS_AUTOPILOT_NOTIFY:-}"
  case "$v" in
    0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;;
  esac
  return 0
}

cc_notify_session_enabled() {
  local v="${CC_CMDS_SESSION_NOTIFY:-}"
  case "$v" in
    0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;;
  esac
  return 0
}

cc_notify_team_enabled() {
  local v="${CC_CMDS_TEAM_NOTIFY:-}"
  case "$v" in
    0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;;
  esac
  return 0
}

cc_notify_host_os() {
  if [ -n "${CC_CMDS_NOTIFY_HOST_OS:-}" ]; then printf '%s' "$CC_CMDS_NOTIFY_HOST_OS"; return 0; fi
  uname -s 2>/dev/null || printf 'unknown'
}

cc_notify_path() {
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:$PATH"
  fi
}
