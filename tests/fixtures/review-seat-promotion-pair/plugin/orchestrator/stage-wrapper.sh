#!/usr/bin/env bash
# Fixture stage wrapper: the environment and flags a stage is launched with.

export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
export CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1

exec claude --settings "$1" --plugin-dir "$2" --strict-mcp-config \
  --append-system-prompt-file "$3" --append-subagent-system-prompt-file "$4" \
  --exclude-dynamic-system-prompt-sections "$@"
