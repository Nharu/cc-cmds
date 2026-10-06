#!/usr/bin/env bash
# ARM(single, --count=1) + fire-now inside a tmux pane → the banner's `-execute`
# value is the focus command for that pane, verbatim, naming the handler by its
# canonical path.
set -euo pipefail

handler="$(cd "$(dirname "$NOTIFY_SH")/../../../orchestrator" && pwd -P)/notify-focus.sh"
want="-execute /bin/bash '$handler' focus '/tmp/tmux-fx,a/default' '4242' '%48'"

bash "$NOTIFY_SH" arm "build done" "build" "single" --count=1
bash "$NOTIFY_SH" fire-now "build" "성공"

[[ -f "$NOTIFIER_LOG" ]] || { echo "fire-now: notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "expected 1 notifier call, got $lines" >&2; exit 1; }
grep -qF -- "$want" "$NOTIFIER_LOG" || {
  echo "focus value missing — want: $want" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}
# The argument order of the dispatcher is unchanged: `-group` still follows.
grep -q -- '-group cc-cmds-active-notify' "$NOTIFIER_LOG" || { echo "single armCount=1 must use -group" >&2; exit 1; }
