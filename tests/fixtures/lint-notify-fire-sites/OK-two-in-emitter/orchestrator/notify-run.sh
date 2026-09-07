#!/usr/bin/env bash
# The shape the lint pins: the notifier is launched from two lines — one raising
# a banner, one removing it — and both are inside the emitter, in the two
# functions that carry the seat guard. The existence probe launches nothing and
# is excluded.
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
