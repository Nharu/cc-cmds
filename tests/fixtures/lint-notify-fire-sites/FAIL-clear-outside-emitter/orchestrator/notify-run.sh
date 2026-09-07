#!/usr/bin/env bash
# Only the fire arm here, so the tree-wide count is two and rule 1 is satisfied.
# What is wrong is WHERE the second launch lives, which is the whole point of
# this fixture: it isolates the location rule from the count rule.
cc_notify_fire() {
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  { terminal-notifier -title "$title" -message "$body" -sound "$sound" -execute ':' >/dev/null 2>&1 & } || true
  return 0
}
