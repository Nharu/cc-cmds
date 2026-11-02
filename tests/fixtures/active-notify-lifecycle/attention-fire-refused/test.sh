#!/usr/bin/env bash
# Verify: a fire-now call leaves an attention event only for a live seat ticket
# from the router seat, and nothing about the local fire changes either way.
#   (a) control: a ticket the hook issued gives one event;
#   (b) no event for: no marker; a malformed name (a path, uppercase hex, 31
#       digits); a well-formed name with no file; a ticket 61 seconds old; a
#       symbolic link; a directory; empty content; non-numeric content; a live
#       ticket with any one of the four pipeline markers set; the same ticket
#       used a second time;
#   (c) in every run, (a) included, the stub log, stdout, stderr and the exit
#       status are byte-equal to a baseline run with no marker.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook and the attention tap both need it"
  exit 0
fi

root="$CC_CMDS_ATTENTION_ROOT"
seat_dir="$HOME/.local/state/cc-cmds/active-notify-seat"
sid="$CLAUDE_CODE_SESSION_ID"
nsh=$(printf '%q' "$NOTIFY_SH")
cmd="bash $nsh fire-now 'build' 'done'"
out="$FIXTURE_TMPDIR/run.out"
err="$FIXTURE_TMPDIR/run.err"

event_count() {
  { find "$root/events" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true; } | grep -c . || true
}
fresh_name() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
mk_ticket() {  # mk_ticket <name> <content>
  (umask 077 && mkdir -p "$seat_dir")
  printf '%s' "$2" > "$seat_dir/$1"
}

# hook_ticket — the name of a ticket the hook issues for $cmd.
hook_ticket() {
  local json o updated
  json=$(jq -nc --arg c "$cmd" --arg sid "$sid" \
    '{tool_input:{command:$c}, session_id:$sid, agent_id:""}')
  o=$(printf '%s' "$json" | "$PRETOOL_HOOK_SH")
  updated=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.updatedInput.command // empty')
  [[ "$updated" == CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=* ]] || fail "the hook gave no seat prefix: $o"
  updated="${updated%% *}"
  printf '%s' "${updated#*=}"
}

# fire <ticket-or-empty> [VAR=value]... — arm single, fire once, and print the
# local outcome: exit status, stdout, stderr and the stub log.
fire() {
  local t="$1" c rc=0; shift
  bash "$NOTIFY_SH" arm "알려줘" "build" single
  : > "$NOTIFIER_LOG"
  rm -f "$NOTIFIER_HINT"
  if [[ -n "$t" ]]; then c="CC_CMDS_ACTIVE_NOTIFY_SEAT_TICKET=$t $cmd"; else c="$cmd"; fi
  env "$@" bash -c "$c" > "$out" 2> "$err" || rc=$?
  printf 'rc=%s\nout=%s\nerr=%s\nlog=%s' "$rc" "$(cat "$out")" "$(cat "$err")" "$(cat "$NOTIFIER_LOG")"
}

baseline=$(fire "")
[[ "$baseline" == *"-group cc-cmds-active-notify-${sid}"* ]] || fail "baseline raised no banner: $baseline"
[[ "$(event_count)" == "0" ]] || fail "baseline left an event"

# expect <label> <want-events> <ticket> [VAR=value]...
expect() {
  local label="$1" want="$2" got; shift 2
  got=$(fire "$@")
  [[ "$got" == "$baseline" ]] || fail "$label: local outcome differs from the baseline
--- baseline
$baseline
--- got
$got"
  [[ "$(event_count)" == "$want" ]] || fail "$label: events $(event_count), want $want"
}

# (a) control
t=$(hook_ticket)
expect "live ticket" 1 "$t"
[[ ! -e "$seat_dir/$t" ]] || fail "live ticket: the ticket was left"

# (b)
expect "no marker" 1 ""
expect "a path for a name" 1 "../../x"
n=$(fresh_name | tr 'abcdef' 'ABCDEF'); mk_ticket "$n" "$(date +%s)"
expect "uppercase name" 1 "$n"
n=$(fresh_name); n="${n:1}"; mk_ticket "$n" "$(date +%s)"
expect "31-digit name" 1 "$n"
expect "no file" 1 "$(fresh_name)"
n=$(fresh_name); mk_ticket "$n" "$(( $(date +%s) - 61 ))"
expect "61 seconds old" 1 "$n"
n=$(fresh_name); printf '%s' "$(date +%s)" > "$FIXTURE_TMPDIR/link-target"
(umask 077 && mkdir -p "$seat_dir"); ln -s "$FIXTURE_TMPDIR/link-target" "$seat_dir/$n"
expect "symbolic link" 1 "$n"
n=$(fresh_name); mkdir -p "$seat_dir/$n"
expect "directory" 1 "$n"
n=$(fresh_name); mk_ticket "$n" ""
expect "empty content" 1 "$n"
n=$(fresh_name); mk_ticket "$n" "abc"
expect "non-numeric content" 1 "$n"

for v in CC_PIPELINE_SEGMENT CC_PIPELINE_STAGE_ID CC_PIPELINE_SHIFT_ID CC_PIPELINE_REENTRY; do
  t=$(hook_ticket)
  expect "live ticket with $v" 1 "$t" "$v=x"
  [[ ! -e "$seat_dir/$t" ]] || fail "live ticket with $v: the ticket was left"
done

t=$(hook_ticket)
expect "reuse, first use" 2 "$t"
expect "reuse, second use" 2 "$t"

exit 0
