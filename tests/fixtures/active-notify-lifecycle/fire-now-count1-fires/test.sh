#!/usr/bin/env bash
# ARM(single, --count=1) + fire-now → notifier 1 line with -group, flag consumed.
# armCount=1 single path preserves v1 1-shot UX (banner replace via -group),
# in the per-session slot `cc-cmds-active-notify-<sid>`.
set -euo pipefail

bash "$NOTIFY_SH" arm "build done" "build" "single" --count=1
[[ -f "$FLAG_FILE" ]] || { echo "ARM: flag missing" >&2; exit 1; }
grep -q '"arm_count":1' "$FLAG_FILE" || { echo "arm_count not 1" >&2; exit 1; }

bash "$NOTIFY_SH" fire-now "build" "성공"

[[ ! -f "$FLAG_FILE" ]] || { echo "fire-now: flag should be consumed (final fire)" >&2; exit 1; }
[[ -f "$NOTIFIER_LOG" ]] || { echo "fire-now: notifier not called" >&2; exit 1; }
lines=$(wc -l < "$NOTIFIER_LOG" | tr -d ' ')
[[ "$lines" == "1" ]] || { echo "expected 1 notifier call, got $lines" >&2; exit 1; }
safe_sid="${CLAUDE_CODE_SESSION_ID//[^A-Za-z0-9_.-]/_}"
want_group="-group cc-cmds-active-notify-${safe_sid}"
got=$(head -1 "$NOTIFIER_LOG")
[[ "$got" == *"$want_group" ]] || { echo "single armCount=1 must use exactly '$want_group'" >&2; cat "$NOTIFIER_LOG" >&2; exit 1; }
# The source marker carries no brackets. terminal-notifier swallows a title
# whose first character is one of `[ ( { < " -`, replacing it with the
# application's own name — so the bracketed form erased the very marker it was
# there to provide.
grep -q -- '-title cc-cmds build' "$NOTIFIER_LOG" || { echo "title missing" >&2; exit 1; }
grep -q -- '-message 성공' "$NOTIFIER_LOG" || { echo "summary missing" >&2; exit 1; }
# The case of a banner raised outside tmux: the driver clears TMUX and
# TMUX_PANE, so there is no pane to go to and the click value falls back to `:`.
# `-execute` itself is never dropped.
grep -q -- '-execute :' "$NOTIFIER_LOG" || { echo "-execute ':' no-op missing" >&2; exit 1; }
