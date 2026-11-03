#!/usr/bin/env bash
# Verify: a fire-now call that goes through the PreToolUse hook the way the
# harness runs it — the hook issues a seat ticket and prefixes the command, and
# the prefixed command is what runs — leaves exactly one active-notify event per
# fire in the attention spool:
#   (a) single with arm_count 1, single with --count=2 (two fires) and repeat;
#   (b) each event's slot is byte-equal to the -group the stub was called with,
#       and kind, token, title and body are the fire's;
#   (c) origin.session_id is the dispatcher's own session id and origin.run_id
#       and origin.repo are null, even when the caller's environment carries
#       RUN_ID, CC_NOTIFY_REPO and a different CC_NOTIFY_SESSION_ID;
#   (d) no ticket is left behind after any fire.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook and the attention tap both need it"
  exit 0
fi

root="$CC_CMDS_ATTENTION_ROOT"
seat_dir="$HOME/.local/state/cc-cmds/active-notify-seat"
sid="$CLAUDE_CODE_SESSION_ID"
slot="cc-cmds-active-notify-${sid}"
nsh=$(printf '%q' "$NOTIFY_SH")
seen="$FIXTURE_TMPDIR/seen-events"
: > "$seen"

# fire_via_hook <summary> — the hook sees the Bash tool input of a main-session
# fire-now call and its rewritten command is run as the tool would run it.
fire_via_hook() {
  local cmd json out updated
  cmd="bash $nsh fire-now 'build' '$1'"
  json=$(jq -nc --arg c "$cmd" --arg sid "$sid" \
    '{tool_input:{command:$c}, session_id:$sid, agent_id:""}')
  out=$(printf '%s' "$json" | "$PRETOOL_HOOK_SH")
  updated=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty')
  [[ "$updated" == CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=* ]] \
    || fail "the hook gave no seat prefix: $out"
  bash -c "$updated"
}

event_files() {
  { find "$root/events" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true; } | sort
}

# take_new — the path of the one event this fire added; fails on zero or more.
take_new() {
  local new n
  event_files > "$seen.now"
  new=$(comm -13 "$seen" "$seen.now")
  n=$(printf '%s' "$new" | grep -c . || true)
  [[ "$n" == "1" ]] || fail "expected one new event, got $n: $new"
  mv "$seen.now" "$seen"
  printf '%s' "$new"
}

last_group() {
  local line
  line=$(tail -n 1 "$NOTIFIER_LOG")
  [[ "$line" == *" -group "* ]] || fail "the stub log has no -group: $line"
  printf '%s' "${line##* -group }"
}

# check_event <label> <summary> — the newest event against the newest banner.
check_event() {
  local label="$1" summary="$2" ev group
  ev=$(take_new)
  group=$(last_group)
  [[ "$(jq -r '.slot' "$ev")" == "$group" ]] \
    || fail "$label: slot $(jq -r '.slot' "$ev") != group $group"
  [[ "$(jq -r '.kind' "$ev")" == "active-notify" ]] || fail "$label: kind"
  [[ "$(jq -r '.token' "$ev")" == "active-notify" ]] || fail "$label: token"
  [[ "$(jq -r '.title' "$ev")" == "cc-cmds build" ]] || fail "$label: title"
  [[ "$(jq -r '.body' "$ev")" == "$summary" ]] || fail "$label: body"
  [[ "$(jq -r '.origin.session_id' "$ev")" == "$sid" ]] \
    || fail "$label: origin.session_id $(jq -r '.origin.session_id' "$ev")"
  [[ "$(jq -c '.origin.run_id' "$ev")" == "null" ]] || fail "$label: origin.run_id not null"
  [[ "$(jq -c '.origin.repo' "$ev")" == "null" ]] || fail "$label: origin.repo not null"
  if [[ -d "$seat_dir" ]] && [[ -n "$(ls -A "$seat_dir")" ]]; then
    fail "$label: a ticket was left: $(ls -A "$seat_dir")"
  fi
  printf '%s' "$group"
}

armed_at() { grep -oE '"armed_at":[0-9]+' "$FLAG_FILE" | head -1 | cut -d: -f2; }

# (a) single, arm_count 1 — the per-session slot.
bash "$NOTIFY_SH" arm "끝나면 알려줘" "build" single
fire_via_hook "single done"
g=$(check_event "single" "single done")
[[ "$g" == "$slot" ]] || fail "single: group $g != $slot"

# single, --count=2 — two fires, two pile-up groups.
bash "$NOTIFY_SH" arm "두 번 알려줘" "build" single --count=2
a=$(armed_at)
fire_via_hook "step one"
g=$(check_event "count 1/2" "step one")
[[ "$g" == "${slot}@${a}.1" ]] || fail "count 1/2: group $g"
fire_via_hook "step two"
g=$(check_event "count 2/2" "step two")
[[ "$g" == "${slot}@${a}.2" ]] || fail "count 2/2: group $g"
[[ ! -f "$FLAG_FILE" ]] || fail "count 2/2: the final fire did not consume the flag"

# repeat
bash "$NOTIFY_SH" arm "매번 알려줘" "build" repeat
a=$(armed_at)
fire_via_hook "turn one"
g=$(check_event "repeat 1" "turn one")
[[ "$g" == "${slot}@${a}.1" ]] || fail "repeat 1: group $g"

# (c) the caller's run, repo and session values do not reach the event.
export RUN_ID="run-attention-1" CC_NOTIFY_REPO="o/r" CC_NOTIFY_SESSION_ID="some-other-session"
fire_via_hook "turn two"
g=$(check_event "repeat 2 with caller origin" "turn two")
[[ "$g" == "${slot}@${a}.2" ]] || fail "repeat 2: group $g"
unset RUN_ID CC_NOTIFY_REPO CC_NOTIFY_SESSION_ID

n=$(event_files | grep -c . || true)
[[ "$n" == "5" ]] || fail "expected 5 events in all, got $n"

exit 0
