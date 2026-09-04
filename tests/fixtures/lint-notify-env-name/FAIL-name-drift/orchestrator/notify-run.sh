#!/usr/bin/env bash
# Fixture emitter — identical to the OK case. The drift is on the prose side.

cc_notify_enabled() {
  local v="${CC_CMDS_AUTOPILOT_NOTIFY:-}"
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
