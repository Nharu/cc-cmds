#!/usr/bin/env bash
# Verify: v1-style `notify.sh fire <workflow> <summary>` Bash command no longer
# matches the v2 notify_re alternation — hook MUST emit empty stdout (defer
# to default permission gate, NOT auto-approve). Negative regression that
# stops v1 fire callers from silently bypassing the permission dialog.
set -euo pipefail

fire_cmd='bash /abs/active-notify/scripts/notify.sh fire "build" "should defer"'
session_id="test-pretool-fire-no-match"

stdin_json=$(jq -nc \
  --arg c "$fire_cmd" \
  --arg sid "$session_id" \
  '{tool_input:{command:$c}, session_id:$sid}')

printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

# Hook must produce NO output (exit 0 with empty stdout — default-gate handover).
if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL: v1 fire argv must defer to default gate (got non-empty stdout)" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
