#!/usr/bin/env bash
# Verify: PreToolUse hook on a non-matching command (e.g., `npm test`)
# exits 0 with empty stdout → defers to default permission gate.
set -euo pipefail

stdin_json=$(jq -nc '{tool_input:{command:"npm test"}, session_id:"test-pretool-no-match"}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL: hook emitted stdout for non-matching command (must be empty to defer to default gate)" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
