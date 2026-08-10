#!/usr/bin/env bash
# Verify: nothing but a lone plain invocation matches.
#
# The hook's allow decision covers the entire command line the Bash tool runs,
# so any shape that can smuggle a second command past the matched substring is
# a privilege escalation with the session as its blast radius. Each case below
# is a shape that was auto-approved before the matcher was anchored.
#
# The two multi-line cases are load-bearing and not redundant with each other.
# The one WITHOUT a metacharacter is what separates the correct fix from the
# wrong one: a pattern that anchors the whole line but keeps `[[:space:]]` as
# its separator still matches it, because `[[:space:]]` includes the newline in
# bash's ERE. Only `[[:blank:]]` excludes it. Delete that case and a regression
# to the wrong separator ships green.
set -euo pipefail

base='bash /abs/active-notify/scripts/notify.sh cancel'

cases=(
  "${base}; touch /tmp/cc-should-never-run"
  "${base} && echo chained"
  "${base} | tee /tmp/cc-should-never-run"
  "\$(${base})"
  "${base} > /tmp/cc-should-never-run"
  "echo prefix && ${base}"
  "(${base})"
  "${base}
touch /tmp/cc-should-never-run"
  "${base}
echo second-line"
  'bash /abs/active-notify/scripts/notify.sh arm-bogus'
  'bash /abs/active-notify/scripts/notify.sh fire-now-bogus'
)

labels=(
  'semicolon suffix'
  'and-chained suffix'
  'piped suffix'
  'command substitution'
  'redirected suffix'
  'and-chained prefix'
  'subshell wrapper'
  'multi-line, second line has a metacharacter'
  'multi-line, second line is plain (pins the blank-vs-space separator)'
  'unknown subcommand arm-bogus'
  'unknown subcommand fire-now-bogus'
)

failures=0
for i in "${!cases[@]}"; do
  jq -nc --arg c "${cases[$i]}" --arg sid "test-suffix-injection" \
    '{tool_input:{command:$c}, session_id:$sid}' \
    | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

  if [[ -s "$HOOK_STDOUT" ]]; then
    echo "FAIL: case $((i + 1)) (${labels[$i]}) was not rejected" >&2
    echo "  command: ${cases[$i]}" >&2
    cat "$HOOK_STDOUT" >&2
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "FAIL: $failures of ${#cases[@]} injection shapes still match" >&2
  exit 1
fi

exit 0
