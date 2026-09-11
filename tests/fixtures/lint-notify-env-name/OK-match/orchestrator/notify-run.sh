#!/usr/bin/env bash
# Fixture emitter — the registered set is exactly what this file reads, and both
# guidance sentences beside it name their own switch.
#
# It carries both test seams on purpose: the extraction rule has to drop the
# `CC_CMDS_NOTIFY_` family and leave exactly the registered set, and a fixture
# with no seams in it would pass a lint that had no exclusion rule at all.
#
# It carries BOTH switches on purpose too: with one switch a fixture cannot tell
# "the registered set" apart from "exactly one", so it would go on passing a rule
# that had silently collapsed back into a count.

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

cc_notify_host_os() {
  if [ -n "${CC_CMDS_NOTIFY_HOST_OS:-}" ]; then printf '%s' "$CC_CMDS_NOTIFY_HOST_OS"; return 0; fi
  uname -s 2>/dev/null || printf 'unknown'
}

cc_notify_path() {
  if [ -z "${CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND:-}" ]; then
    PATH="/opt/homebrew/bin:$PATH"
  fi
}
