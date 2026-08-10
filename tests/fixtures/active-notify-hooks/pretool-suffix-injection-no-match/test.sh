#!/usr/bin/env bash
# Verify: nothing but a lone plain invocation matches.
#
# The hook's allow decision covers the entire command line the Bash tool runs,
# so any shape that can smuggle a second command past the matched substring is
# a privilege escalation with the session as its blast radius. Each case below
# is a shape that was auto-approved before the matcher was anchored.
#
# Two axes are pinned here and they are killed by different characters in the
# pattern, so neither group of cases substitutes for the other.
#
# SEPARATOR axis — the tail separator must be `[[:blank:]]`, not `[[:space:]]`,
# or a second line is read as more arguments. Both "injection on the second
# line" cases exercise it; they are duplicates of each other, and the file used
# to claim otherwise.
#
# PATH-SEGMENT axis — the path segment's negation class must be `[:space:]`,
# not `[:blank:]`, or the segment swallows a newline and the FIRST line becomes
# an approved command word. This is the axis nothing pinned before. It needs the
# injected word on the first line AND no whitespace on it: swapping the class
# leaves every other case in this file green.
#
# CONTENT axis — the command word must be the installed dispatcher, so a
# relative path, a `..` climb, a tilde or a glob is rejected even though each
# ends in the literal the pattern looks for.
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
  "bash /tmp/cc-should-never-run
/abs/active-notify/scripts/notify.sh cancel"
  'bash /abs/active-notify/scripts/notify.sh arm-bogus'
  'bash /abs/active-notify/scripts/notify.sh fire-now-bogus'
  'bash ../../../active-notify/scripts/notify.sh cancel'
  'bash /abs/../../etc/active-notify/scripts/notify.sh cancel'
  'bash /tmp/*/active-notify/scripts/notify.sh cancel'
  'bash ~/x/active-notify/scripts/notify.sh cancel'
)

labels=(
  'semicolon suffix'
  'and-chained suffix'
  'piped suffix'
  'command substitution'
  'redirected suffix'
  'and-chained prefix'
  'subshell wrapper'
  'multi-line, injection on the second line (separator axis)'
  'multi-line, injection on the second line, no metacharacter (separator axis)'
  'multi-line, injection on the FIRST line, no whitespace (pins the path-segment negation class)'
  'unknown subcommand arm-bogus'
  'unknown subcommand fire-now-bogus'
  'relative command word'
  'absolute command word that climbs out with ..'
  'command word containing a glob the shell would expand'
  'tilde-prefixed command word'
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
