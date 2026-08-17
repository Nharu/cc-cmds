#!/usr/bin/env bash
# A large multi-line bypass command must still be recognized.
#
# This is the case an earlier round recorded as impossible to construct. It is
# constructible: put the match on the FIRST line and a large tail after it. Then
# `grep -q` exits as soon as it matches, and a form that feeds grep through a
# pipeline has its producer killed by SIGPIPE — under `pipefail` the pipeline
# fails, the bypass goes unrecognized, and a documented permission-test form
# falls to a dialog nobody is present to answer.
#
# Measured when this fixture was written: at 8 KB both forms allow; at 70 KB and
# 96 KB the here-string form allows and the pipeline form does not, ten runs
# each. The boundary brackets the 64 KB pipe buffer, so the size below is chosen
# past it rather than at it.
#
# The axis this fixture varies is INPUT SIZE IN BYTES. Every other fixture beside
# it varies the SHAPE of a short command, and no amount of reasoning about shape
# reaches a defect whose trigger is length: the two forms of the matcher accept
# exactly the same language and differ only in what happens to a producer that is
# still writing when the consumer leaves. This directory has one fixture on that
# axis — that is the whole of its coverage, and the reason the earlier round
# reported the case as unconstructible is that it searched the other axis.
set -euo pipefail

head="terminal-notifier -message 'cc-cmds permission test' -group 'cc-cmds-active-notify'"
tail=$(python3 -c "print('\n'.join(['y'*79 for _ in range(1200)]), end='')")
cmd="${head}
${tail}"

if (( ${#cmd} < 70000 )); then
  echo "FAIL: the constructed command is ${#cmd} bytes — below the pipe-buffer boundary this fixture exists to cross" >&2
  exit 1
fi

jq -nc --arg c "$cmd" --arg sid "test-large-input" \
  '{tool_input:{command:$c}, session_id:$sid}' \
  | "$PRETOOL_HOOK_SH" > "$HOOK_STDOUT" 2> "$HOOK_STDERR"

decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$HOOK_STDOUT")
if [[ "$decision" != "allow" ]]; then
  echo "FAIL: a ${#cmd}-byte bypass command was not recognized (got: ${decision:-DEFER})" >&2
  exit 1
fi
