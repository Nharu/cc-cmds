#!/usr/bin/env bash
# Verify: a fire-now call with an empty agent_id (field absent, and field "")
# gets a seat ticket — a file under the seat directory holding the issue time,
# whose name is the seat prefix's value — and the ticket directory is private.
set -euo pipefail

fire_cmd='bash /abs/active-notify/scripts/notify.sh fire-now "build" "done"'
sid="test-seat-issue"
inject_sid="${CC_CMDS_NOTIFY_INJECT_SID:-0}"

for input_shape in absent empty; do
  rm -rf "$PRETOOL_SEAT_DIR"
  if [[ "$input_shape" == "absent" ]]; then
    stdin_json=$(jq -nc --arg c "$fire_cmd" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid}')
  else
    stdin_json=$(jq -nc --arg c "$fire_cmd" --arg sid "$sid" '{tool_input:{command:$c}, session_id:$sid, agent_id:""}')
  fi
  before=$(date +%s)
  printf '%s' "$stdin_json" | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"
  after=$(date +%s)

  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' "$HOOK_STDOUT")" == "allow" ]] \
    || { echo "FAIL ($input_shape): decision is not allow" >&2; exit 1; }

  updated=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' "$HOOK_STDOUT")
  name=$(printf '%s' "$updated" | sed -n 's/^CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=\([0-9a-f]\{32\}\) .*/\1/p')
  [[ -n "$name" ]] || { echo "FAIL ($input_shape): no seat prefix with a 32-hex value: $updated" >&2; exit 1; }

  if [[ "$inject_sid" == "1" ]]; then
    want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${name} CLAUDE_CODE_SESSION_ID=${sid} ${fire_cmd}"
  else
    want="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=${name} ${fire_cmd}"
  fi
  [[ "$updated" == "$want" ]] || { echo "FAIL ($input_shape): command" >&2; echo "  want: $want" >&2; echo "  got:  $updated" >&2; exit 1; }

  listing=$(ls -A "$PRETOOL_SEAT_DIR")
  [[ "$listing" == "$name" ]] || { echo "FAIL ($input_shape): seat dir holds '$listing', want '$name'" >&2; exit 1; }
  [[ -f "$PRETOOL_SEAT_DIR/$name" && ! -L "$PRETOOL_SEAT_DIR/$name" ]] \
    || { echo "FAIL ($input_shape): ticket is not a regular file" >&2; exit 1; }
  issued=$(cat "$PRETOOL_SEAT_DIR/$name")
  [[ "$issued" =~ ^[0-9]+$ ]] && (( issued >= before && issued <= after )) \
    || { echo "FAIL ($input_shape): ticket content '$issued' is not the issue time [$before,$after]" >&2; exit 1; }
  mode=$(ls -ld "$PRETOOL_SEAT_DIR" | cut -c1-10)
  [[ "$mode" == "drwx------" ]] || { echo "FAIL ($input_shape): seat dir mode $mode" >&2; exit 1; }
done

exit 0
