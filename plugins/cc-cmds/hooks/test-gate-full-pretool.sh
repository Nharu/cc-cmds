#!/usr/bin/env bash
# test-gate full-run PreToolUse hook — asks a person before a Bash command runs
# the whole test-gate suite with `--full`, which runs every section serially
# and takes hours.
#
# The command is split into words on whitespace and on `( ) { } ; & | < >` and
# the backtick, with quote characters removed. When a word ending in
# `test-gate.sh` is later followed by the word `--full`, the hook prints one
# line of JSON with `permissionDecision: "ask"`; otherwise it prints nothing.
# So `make check GATE_SUITE_CMD='bash scripts/test-gate.sh --full'` and
# `(bash scripts/test-gate.sh --full)` ask, while
# `grep -n -- '--full' scripts/test-gate.sh` (the flag before the script path)
# does not. A path or flag hidden behind a variable or a glob, or a renamed copy
# of the script, is not seen: this hook asks about the plain spelling of a full
# run in an interactive session, it does not stop a call written to go around
# it. A commit message or heredoc that names the two words in that order, or a
# `--full` of a command after a pipe, also asks; that false ask is accepted.
#
# In an unattended pipeline stage (`CC_PIPELINE_RUN_ID` non-empty) the hook
# steps aside before reading the command: there test-gate itself refuses
# `--full`, and an `ask` with no person to answer it would only stop the stage.
#
# jq missing, or no `tool_input.command` on standard input, prints nothing.
# Every path exits 0.
set -uo pipefail

[ -z "${CC_PIPELINE_RUN_ID:-}" ] || exit 0

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

hit=$(printf '%s\n' "$cmd" | tr -d "\"'" | tr ';|&(){}<>`' '\n' | awk '
  { for (i = 1; i <= NF; i++) {
      if (seen && $i == "--full") { print "1"; exit }
      if ($i ~ /test-gate\.sh$/) seen = 1
  } }')

[ "$hit" = 1 ] || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"전량 test-gate 는 직렬로 수 시간 걸립니다 — 사람 승인이 필요합니다"}}\n'
exit 0
