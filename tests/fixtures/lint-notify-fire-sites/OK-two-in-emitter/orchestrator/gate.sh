#!/usr/bin/env bash
# A caller reaches the banner through the emitter, never through the binary, so
# the router guard it carries is the only place the decision to fire is made.
if cc_caller_is_router; then
  cc_notify_fire hands "스테이지가 멈췄습니다" "park-S1" || true
fi
