#!/usr/bin/env bash
# ARM(single, --count=1) + fire-now → notifier 1 line with -group, flag consumed.
# armCount=1 single path preserves v1 1-shot UX (banner replace via -group).
set -euo pipefail

bash "$NOTIFY_SH" arm "build done" "build" "single" --count=1
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "arm_count not 1" >&2; exit 1; }

bash "$NOTIFY_SH" fire-now "build" "성공"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-now: flag should be consumed (final fire)" >&2; exit 1; }
[[ -f "$NOTIFIER_LOG" ]] || { echo "fire-now: notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "expected 1 notifier call, got $lines" >&2; exit 1; }
grep -q -- '-group cc-cmds-active-notify' "$NOTIFIER_LOG" || { echo "single armCount=1 must use -group" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
grep -q -- '-title \[cc-cmds\] build' "$NOTIFIER_LOG" || { echo "title missing" >&2; exit 1; }
grep -q -- '-message 성공' "$NOTIFIER_LOG" || { echo "summary missing" >&2; exit 1; }
grep -q -- '-execute :' "$NOTIFIER_LOG" || { echo "-execute ':' no-op missing" >&2; exit 1; }
