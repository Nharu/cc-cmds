#!/usr/bin/env bash
# Verify: a compound command line no longer matches, and the plain call it
# contains still does.
#
# This fixture used to assert the opposite. The hook emits its allow decision
# for the WHOLE command line, not for the substring it matched, so a line that
# merely contains a good call was handing auto-approval to everything else on
# it. The matcher is now anchored to the entire line, so the compound form
# defers to the permission dialog.
#
# The control case is the point of the pair: anchoring must not cost the plain
# invocation its approval. A fixture that only asserted the negative would stay
# green if the pattern stopped matching anything at all.
set -euo pipefail

first='bash /abs/active-notify/scripts/notify.sh fire-now "build" "성공"'
compound="${first} && echo done"
session_id="test-pretool-compound"

emit() {
  jq -nc --arg c "$1" --arg sid "$session_id" \
    '{tool_input:{command:$c}, session_id:$sid}' \
    | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
}

# --- the compound line must defer ---
emit "$compound"
if [[ -s "$HOOK_STDOUT" ]]; then
  echo "FAIL: compound line must defer to the default gate (got non-empty stdout)" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

# --- control: the same call, unchained, is still approved ---
emit "$first"
decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: the unchained call must still be approved, got: ${decision:-<empty>}" >&2
  cat "$HOOK_STDOUT" >&2
  exit 1
fi

exit 0
