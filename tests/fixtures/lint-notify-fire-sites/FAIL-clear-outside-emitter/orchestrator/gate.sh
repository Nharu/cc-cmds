#!/usr/bin/env bash
# The path the lint exists to refuse: a third launch, outside the emitter, with
# no seat guard on it. Clearing a banner changes what is on a person's screen
# right now, which is exactly the act the guard is a precondition for.
terminal-notifier -remove "cc-cmds-autopilot-$RUN_ID-$id" >/dev/null 2>&1 || true
