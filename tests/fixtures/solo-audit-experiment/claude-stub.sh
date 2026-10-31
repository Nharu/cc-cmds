#!/usr/bin/env bash
# Stub CLI for scripts/test-solo-audit-experiment.sh — stands in for `claude`
# behind SOLO_EXP_CLAUDE_BIN in the classification call.
#
# Appends its flags (not the prompt) to $STUB_CLI_LOG and, with STUB_ENV_LOG
# set, the names of its environment variables to that file, then answers from
# the input itself: every `| <id> | <routing> | <class> |` row after the
# `--- INPUT ---` line becomes one classified defect. STUB_CLI_DROP=1 drops the
# last one, so the id count no longer matches the disclosure block.

set -euo pipefail

prompt=""
flags=""
while (( $# > 0 )); do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --json-schema) flags="$flags --json-schema"; shift 2 ;;
    *) flags="$flags $1"; shift ;;
  esac
done
printf 'call%s\n' "$flags" >> "${STUB_CLI_LOG:?}"
[[ -z "${STUB_ENV_LOG:-}" ]] || compgen -e >> "$STUB_ENV_LOG"

printf '%s\n' "$prompt" | awk -v drop="${STUB_CLI_DROP:-0}" '
  /^--- INPUT ---$/ { on = 1; next }
  on && /^\| D[0-9]+ \|/ {
    n = split($0, c, "|")
    for (i = 2; i <= 4; i++) { gsub(/^ +| +$/, "", c[i]) }
    id[++k] = c[2]; rt[k] = c[3]; cl[k] = c[4]
  }
  END {
    if (drop == 1) k--
    printf "{\"type\":\"result\",\"subtype\":\"success\",\"total_cost_usd\":0.25,\"structured_output\":{\"defects\":["
    for (i = 1; i <= k; i++) printf "%s{\"id\":\"%s\",\"routing\":\"%s\",\"class\":\"%s\",\"reason\":\"스텁\"}", (i > 1 ? "," : ""), id[i], rt[i], cl[i]
    printf "]}}\n"
  }'
