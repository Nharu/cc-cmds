#!/usr/bin/env bash
# Verify: a fire that cannot raise a banner — a non-macOS host, or macOS without
# terminal-notifier — still leaves exactly one active-notify event when it holds
# a seat ticket, in single and in repeat mode:
#   (a) the single slot is the group the banner would have carried;
#   (b) the repeat slot is "<slot>@<armed_at>.<fire_count + 1>", the group of the
#       next raised fire, and the flag is left as it was;
#   (c) stderr and the exit status are the same as the same call without a
#       ticket (each run starts with no hint file, so the install hint shows in
#       both or in neither);
#   (d) a repeat flag whose fire_count is unreadable gives no event and is left
#       byte for byte as it was.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook and the attention tap both need it"
  exit 0
fi
if command -v terminal-notifier >/dev/null 2>&1; then
  fail "terminal-notifier is reachable on this fixture's PATH: $(command -v terminal-notifier)"
fi

root="$CC_CMDS_ATTENTION_ROOT"
seat_dir="$HOME/.local/state/cc-cmds/active-notify-seat"
sid="$CLAUDE_CODE_SESSION_ID"
slot="cc-cmds-active-notify-${sid}"
nsh=$(printf '%q' "$NOTIFY_SH")
cmd="bash $nsh fire-now 'build' 'done'"
err="$FIXTURE_TMPDIR/run.err"

event_files() {
  { find "$root/events" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true; } | sort
}
event_count() { event_files | grep -c . || true; }
armed_at() { grep -oE '"armed_at":[0-9]+' "$FLAG_FILE" | head -1 | cut -d: -f2; }

# with_ticket — the hook's rewritten command for $cmd.
with_ticket() {
  local json out updated
  json=$(jq -nc --arg c "$cmd" --arg sid "$sid" \
    '{tool_input:{command:$c}, session_id:$sid, agent_id:""}')
  out=$(printf '%s' "$json" | "$PRETOOL_HOOK_SH")
  updated=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command // empty')
  [[ "$updated" == CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=* ]] \
    || fail "the hook gave no seat prefix: $out"
  printf '%s' "$updated"
}

# run_cmd <command> — run it with no hint file; prints "<rc>|<stderr>".
run_cmd() {
  local rc=0
  rm -f "$NOTIFIER_HINT"
  bash -c "$1" 2> "$err" || rc=$?
  printf '%s|%s' "$rc" "$(cat "$err")"
}

# case_run <label> <host> <mode> — a ticketless run, then a ticketed run from
# the same starting flag; checks (a)-(c).
case_run() {
  local label="$1" host="$2" mode="$3" base got before a expect ev flag_before
  export CC_CMDS_NOTIFY_HOST_OS="$host"

  bash "$NOTIFY_SH" arm "알려줘" "build" "$mode"
  before=$(event_count)
  base=$(run_cmd "$cmd")
  [[ "$(event_count)" == "$before" ]] || fail "$label: a ticketless run left an event"

  bash "$NOTIFY_SH" arm "알려줘" "build" "$mode"
  a=$(armed_at)
  flag_before=$(cksum < "$FLAG_FILE")
  event_files > "$FIXTURE_TMPDIR/events-before"
  got=$(run_cmd "$(with_ticket)")
  [[ "$got" == "$base" ]] || fail "$label: rc|stderr '$got' != ticketless '$base'"
  [[ "$(event_count)" == "$((before + 1))" ]] || fail "$label: expected one event"

  event_files > "$FIXTURE_TMPDIR/events-after"
  ev=$(comm -13 "$FIXTURE_TMPDIR/events-before" "$FIXTURE_TMPDIR/events-after")
  [[ -f "$ev" ]] || fail "$label: the new event cannot be told apart: $ev"
  if [[ "$mode" == "single" ]]; then
    expect="$slot"
  else
    expect="${slot}@${a}.1"
    [[ "$(cksum < "$FLAG_FILE")" == "$flag_before" ]] || fail "$label: the repeat flag changed"
  fi
  [[ "$(jq -r '.slot' "$ev")" == "$expect" ]] \
    || fail "$label: slot $(jq -r '.slot' "$ev") != $expect"
  [[ "$(jq -r '.kind' "$ev")" == "active-notify" ]] || fail "$label: kind"
  [[ "$(jq -r '.origin.session_id' "$ev")" == "$sid" ]] || fail "$label: origin.session_id"
  if [[ -d "$seat_dir" ]] && [[ -n "$(ls -A "$seat_dir")" ]]; then
    fail "$label: a ticket was left"
  fi
  bash "$NOTIFY_SH" cancel
}

case_run "linux single" Linux single
case_run "linux repeat" Linux repeat
case_run "no-tool single" Darwin single
case_run "no-tool repeat" Darwin repeat

# The no-tool cases printed the install hint in both runs; the Linux ones in
# neither. Spot-check the first so (c) is not met by two empty strings alone.
export CC_CMDS_NOTIFY_HOST_OS=Darwin
bash "$NOTIFY_SH" arm "알려줘" "build" single
got=$(run_cmd "$(with_ticket)")
[[ "$got" == "0|[cc-cmds] install terminal-notifier for desktop notifications" ]] \
  || fail "no-tool single: unexpected rc|stderr '$got'"

# (d) an unreadable fire_count in a repeat flag, on both unraised paths.
for host in Linux Darwin; do
  export CC_CMDS_NOTIFY_HOST_OS="$host"
  mkdir -p "$FLAG_DIR"
  printf '{"schema":3,"armed_at":1000,"session_id":"%s","request_text":"r","context_hint":"c","mode":"repeat","arm_count":1,"fire_count":"x","last_fire_at":null}\n' \
    "$sid" > "$FLAG_FILE"
  flag_before=$(cksum < "$FLAG_FILE")
  before=$(event_count)
  run_cmd "$(with_ticket)" >/dev/null
  [[ "$(event_count)" == "$before" ]] || fail "corrupt fire_count ($host): an event was left"
  [[ "$(cksum < "$FLAG_FILE")" == "$flag_before" ]] || fail "corrupt fire_count ($host): the flag changed"
  if [[ -d "$seat_dir" ]] && [[ -n "$(ls -A "$seat_dir")" ]]; then
    fail "corrupt fire_count ($host): a ticket was left"
  fi
done

exit 0
