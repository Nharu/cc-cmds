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
# Neither fire uses -group (both are sub-events of armCount=2).
if grep -q -- '-group' "$NOTIFIER_LOG"; then
  echo "armCount=2 fires must NOT use -group" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi
