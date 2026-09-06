#!/usr/bin/env bash
cc_notify_fire() {
  if ! command -v terminal-notifier >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$sound" ]; then
    { terminal-notifier -title "$title" -message "$body" -sound "$sound" -execute ':' >/dev/null 2>&1 & } || true
  else
    { terminal-notifier -title "$title" -message "$body" -execute ':' >/dev/null 2>&1 & } || true
  fi
  return 0
}
