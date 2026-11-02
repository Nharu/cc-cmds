#!/usr/bin/env bash
# Verify: a fire-now command that does not start with a simple command able to
# take an assignment prefix is allowed unchanged in both modes — no
# updatedInput, no rule, no ticket. A prefix in front of these shapes would be
# a syntax error that stops the whole command, local banner included.
set -euo pipefail

d='/abs/active-notify/scripts/notify.sh'
sid="test-unprefixable"
cases=(
  "( cd /tmp && bash $d fire-now \"b\" \"s\" )"
  "{ bash $d fire-now \"b\" \"s\"; }"
  "if true; then bash $d fire-now \"b\" \"s\"; fi"
  "for((i=0;i<1;i++)); do bash $d fire-now \"b\" \"s\"; done"
  "if(true); then bash $d fire-now \"b\" \"s\"; fi"
  "run() { bash $d fire-now \"b\" \"s\"; }; run"
  "run () { bash $d fire-now \"b\" \"s\"; }; run"
  "! bash $d fire-now \"b\" \"s\""
  "while false; do :; done; bash $d fire-now \"b\" \"s\""
)

for c in "${cases[@]}"; do
  stdin_json=$(jq -nc --arg c "$c" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
  printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
    || { echo "FAIL ($c): decision is not allow" >&2; cat "$HOOK_STDOUT" >&2; exit 1; }
  if jq -e '.hookSpecificOutput.updatedInput' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL ($c): updatedInput present" >&2; cat "$HOOK_STDOUT" >&2; exit 1
  fi
  if jq -e '.hookSpecificOutput.applyPermissionRules' "$HOOK_STDOUT" >/dev/null 2>&1; then
    echo "FAIL ($c): applyPermissionRules present" >&2; exit 1
  fi
  if [[ -d "$PRETOOL_SEAT_DIR" ]] && [[ -n "$(ls -A "$PRETOOL_SEAT_DIR")" ]]; then
    echo "FAIL ($c): a ticket was left" >&2; ls -A "$PRETOOL_SEAT_DIR" >&2; exit 1
  fi
done

exit 0
