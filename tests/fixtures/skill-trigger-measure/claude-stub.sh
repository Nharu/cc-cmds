#!/usr/bin/env bash
# A stand-in for `claude` in scripts/test-skill-trigger-measure.sh. It calls no
# model: it records what it was given and prints stream-json chosen by markers
# in the prompt.
#
#   --version             prints a version line and nothing is recorded
#   -p <prompt>           one session:
#     STUB_CLI_LOG        gets `call <argv>` and `cwd <physical cwd>`
#     STUB_ENV_LOG        gets `env <name>` for every SKILL_TRIGGER_*,
#                         CC_PIPELINE_*, SKILLS_ROOT and SCENARIO_ROOT variable
#                         it inherited, and `switch <name>=<value>` for the
#                         three plugin switches
#   Prompt markers:
#     [발동:<name>]       the session calls Skill with that name
#     [둘째만 비발동]     ...except on the second session with this prompt
#     [셋째 오류]         the third session with this prompt exits 1 without
#                         a result event
#   STUB_NO_CC=1          the init skill list holds no cc-cmds skill
#   STUB_COST             the result's total_cost_usd (default 0.1)
#   STUB_STATE            directory for the per-prompt session counters

set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  echo "9.9.9 (stub)"
  exit 0
fi

prompt=""
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "-p" ]]; then
    prompt="${args[$((i + 1))]}"
  fi
done

printf 'call %s\n' "$*" >> "$STUB_CLI_LOG"
printf 'cwd %s\n' "$(pwd -P)" >> "$STUB_CLI_LOG"
for v in $(compgen -e); do
  case "$v" in
    SKILL_TRIGGER_*|CC_PIPELINE_*|SKILLS_ROOT|SCENARIO_ROOT) printf 'env %s\n' "$v" >> "$STUB_ENV_LOG" ;;
  esac
done
for v in CC_CMDS_SESSION_NOTIFY CC_CMDS_SESSION_DISMISS CC_CMDS_STATUSLINE_AUTOINSTALL; do
  printf 'switch %s=%s\n' "$v" "${!v:-<unset>}" >> "$STUB_ENV_LOG"
done

# The how-many-th session with this prompt.
key=$(printf '%s' "$prompt" | cksum | cut -d' ' -f1)
counter="$STUB_STATE/$key"
n=0
[[ -f "$counter" ]] && n=$(cat "$counter")
n=$((n + 1))
printf '%s\n' "$n" > "$counter"

if [[ "${STUB_NO_CC:-0}" == "1" ]]; then
  skills='["playwright-cli","other:tool"]'
else
  skills='["cc-cmds:alpha","cc-cmds:beta","playwright-cli"]'
fi
printf '{"type":"system","subtype":"init","tools":["Skill"],"skills":%s}\n' "$skills"

if [[ "$prompt" == *"[셋째 오류]"* ]] && (( n == 3 )); then
  echo "stub: session failed" >&2
  exit 1
fi

skill=""
if [[ "$prompt" =~ \[발동:([^]]+)\] ]]; then
  skill="${BASH_REMATCH[1]}"
fi
if [[ "$prompt" == *"[둘째만 비발동]"* ]] && (( n == 2 )); then
  skill=""
fi
if [[ -n "$skill" ]]; then
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$skill"
fi
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":%s}\n' "${STUB_COST:-0.1}"
