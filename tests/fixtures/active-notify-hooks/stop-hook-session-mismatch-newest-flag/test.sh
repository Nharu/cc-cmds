#!/usr/bin/env bash
# Verify: hook stdin session_id ≠ any flag's session_id, but a foreign-session
# flag exists → β safety-net selects newest, env-prefixes fire with the flag's
# own session_id, audit.log gets one line.
set -euo pipefail

# Pre-create two foreign-session flags with different mtimes
older="$FLAG_DIR/pending-sid-older.flag"
newer="$FLAG_DIR/pending-sid-newer.flag"
printf '{"schema":2,"armed_at":1699000000,"session_id":"sid-older","request_text":"older","context_hint":"old","mode":"single","fire_count":0,"last_fire_at":null}\n' > "$older"
# Force older mtime
touch -t 202405010000 "$older"
printf '{"schema":2,"armed_at":1700000000,"session_id":"sid-newer","request_text":"newer","context_hint":"new","mode":"single","fire_count":0,"last_fire_at":null}\n' > "$newer"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

# β fallback should fire (work_calls=1: ls call)
if [[ ! -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was NOT invoked under β fallback" >&2
  cat "$HOOK_STDERR" >&2 || true
  exit 1
fi

# Audit log should have exactly 1 line referencing the newer flag
if [[ ! -f "$FLAG_DIR/audit.log" ]]; then
  echo "FAIL: audit.log not created" >&2
  exit 1
fi
audit_lines=$(wc -l < "$FLAG_DIR/audit.log" | tr -d ' ')
if [[ "$audit_lines" != "1" ]]; then
  echo "FAIL: audit.log expected 1 line, got $audit_lines" >&2
  cat "$FLAG_DIR/audit.log" >&2
  exit 1
fi
if ! grep -q 'pending-sid-newer.flag' "$FLAG_DIR/audit.log"; then
  echo "FAIL: audit.log did not record newest flag" >&2
  cat "$FLAG_DIR/audit.log" >&2
  exit 1
fi

# Newer (matched) flag should be consumed (single-mode mv -n inside fire branch)
if [[ -f "$newer" ]]; then
  echo "FAIL: matched newest flag was not consumed" >&2
  exit 1
fi

# Older flag should remain untouched (β consumed only the newest)
if [[ ! -f "$older" ]]; then
  echo "FAIL: older flag was unexpectedly consumed" >&2
  exit 1
fi

exit 0
