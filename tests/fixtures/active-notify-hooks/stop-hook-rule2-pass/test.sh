#!/usr/bin/env bash
# Verify: flag alive + ≥1 user-task Bash (non-notify) → Stop hook fires.
set -euo pipefail

# Pre-create ARM flag for this session
flag_file="$FLAG_DIR/pending-test-rule2-pass.flag"
printf '{"schema":2,"armed_at":1700000000,"session_id":"test-rule2-pass","request_text":"빌드 끝나면 알려줘","context_hint":"build","mode":"single","fire_count":0,"last_fire_at":null}\n' > "$flag_file"

"$STOP_HOOK_SH" < "$HOOK_INPUT" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

# Terminal-notifier should be invoked exactly once
if [[ ! -s "$NOTIFIER_LOG" ]]; then
  echo "FAIL: terminal-notifier was NOT invoked (Rule 2 should pass)" >&2
  echo "--- hook stderr ---" >&2
  cat "$HOOK_STDERR" >&2 || true
  exit 1
fi

# Banner workflow should be 'npm' (first non-cd token from `npm run build`)
if ! grep -q -- '-title \[cc-cmds\] npm' "$NOTIFIER_LOG"; then
  echo "FAIL: banner workflow != 'npm'" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

# Banner summary should be '성공' (is_error=false)
if ! grep -q -- '-message 성공' "$NOTIFIER_LOG"; then
  echo "FAIL: banner summary != '성공'" >&2
  cat "$NOTIFIER_LOG" >&2
  exit 1
fi

exit 0
