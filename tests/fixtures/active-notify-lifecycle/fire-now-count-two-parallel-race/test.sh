#!/usr/bin/env bash
# ARM(single, --count=2) + 2 fire-now in parallel → lockdir serializes the
# read-modify-write, terminal state is deterministic (2 notifier lines, flag
# consumed, lockdir not leaked). Individual completion order is nondeterministic.
set -euo pipefail

bash "$NOTIFY_SH" arm "race" "race" "single" --count=2

bash "$NOTIFY_SH" fire-now "race" "p1" &
bash "$NOTIFY_SH" fire-now "race" "p2" &
wait

[[ ! -f "$FLAG_FILE" ]] || { echo "flag should be consumed after both fires" >&2; cat "$FLAG_FILE" >&2; exit 1; }
[[ -f "$NOTIFIER_LOG" ]] || { echo "notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "2" ]] || { echo "expected 2 notifier lines, got $lines" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
[[ ! -d "${FLAG_FILE}.lockdir" ]] || { echo "lockdir leak" >&2; exit 1; }
# Both are sub-events of armCount=2, so each carries a pile-up group — and the
# lock must hand them DIFFERENT numbers, or one banner would replace the other.
groups=$(grep -oE -- '-group cc-cmds-active-notify-[^ ]+@[0-9]+\.[0-9]+' "$NOTIFIER_LOG" | sort -u)
n_groups=$(printf '%s\n' "$groups" | grep -c . || true)
[[ "$n_groups" == "2" ]] || {
  echo "armCount=2 fires must use two different pile-up groups (got $n_groups)" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
}
