#!/usr/bin/env bash
# The emitter is clean; the violation is the TypeScript mod beside it.
cc_notify_fire() {
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -title "$title" -message "$body" -sound "$sound" -execute ':' >/dev/null 2>&1 & } || true
  return 0
}

cc_notify_clear() {
  if ! cc_caller_is_router; then return 0; fi
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -remove "$group" >/dev/null 2>&1 & } || true
  return 0
}
