#!/usr/bin/env bash
# The count is pinned from below as well as from above. An emitter that lost its
# removal arm still launches a notifier, so a check that only asked "are all
# launches inside the emitter" would pass while the banner clear was gone — and a
# banner nobody can take off the screen is the state the address exists to end.
cc_notify_fire() {
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -title "$title" -message "$body" -sound "$sound" -execute ':' >/dev/null 2>&1 & } || true
  return 0
}
