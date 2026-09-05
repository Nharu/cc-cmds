#!/usr/bin/env bash
# The count is pinned from below as well as from above. An emitter that lost one
# of its two arms still launches a notifier, so a check that only asked "are all
# launches inside the emitter" would pass while the sound-carrying path was gone.
cc_notify_fire() {
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -title "$title" -message "$body" -execute ':' >/dev/null 2>&1 & } || true
  return 0
}
