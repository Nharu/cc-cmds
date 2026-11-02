#!/usr/bin/env bash
# Verify: when the rewritten command fails the syntax check of the shell
# $SHELL names — or that shell cannot be used — the hook drops every prefix,
# removes the ticket it issued, and allows the call unchanged.
#   (h) an unterminated double quote, under the driver's SHELL=/bin/bash;
#   (i) SHELL empty, a missing path, and an executable named neither zsh nor
#       bash (/bin/sh), each with a well-formed command.
set -euo pipefail

sid="test-syntax-fail"
good='bash /abs/active-notify/scripts/notify.sh fire-now "build" "done"'
bad='bash /abs/active-notify/scripts/notify.sh fire-now "x'

check_plain() {
  local label="$1"
  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
    || { echo "FAIL ($label): decision is not allow" >&2; cat "$HOOK_STDOUT" >&2; exit 1; }
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL ($label): updatedInput present" >&2; cat "$HOOK_STDOUT" >&2; exit 1
  fi
  if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL ($label): applyPermissionRules present" >&2; exit 1
  fi
  if [[ -d "$PRETOOL_SEAT_DIR" ]] && [[ -n "$(ls -A "$PRETOOL_SEAT_DIR")" ]]; then
    echo "FAIL ($label): a ticket was left" >&2; ls -A "$PRETOOL_SEAT_DIR" >&2; exit 1
  fi
}

run_hook() {
  local c="$1" json
  json=$(jq -nc --arg c "$c" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
  printf '%s' "$json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
}

# (h)
run_hook "$bad"
check_plain "unterminated quote"

# (i)
SHELL='' run_hook "$good"
check_plain "SHELL empty"
SHELL='/nonexistent/bin/zsh' run_hook "$good"
check_plain "SHELL missing"
SHELL='/bin/sh' run_hook "$good"
check_plain "SHELL /bin/sh"

exit 0
