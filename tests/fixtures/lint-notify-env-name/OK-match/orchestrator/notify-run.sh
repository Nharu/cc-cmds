#!/usr/bin/env bash
# Fixture emitter — the name pairing agrees with the kickoff prose beside it.
#
# It carries both test seams on purpose: the extraction rule has to drop the
# `CC_CMDS_NOTIFY_` family and leave exactly one survivor, and a fixture with no
# seams in it would pass a lint that had no exclusion rule at all.

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
