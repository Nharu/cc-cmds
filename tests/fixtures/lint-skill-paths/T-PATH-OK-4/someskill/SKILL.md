# Skill with the protocol's two-branch witness dir

- **Witness scratch dir**: before the first spawn, create it by the protocol's two-branch form under **Spawn** with slug `{slug}` — `WITNESS_DIR="${CC_PIPELINE_RUN_DIR}/team-witness-{slug}"` when `CC_PIPELINE_RUN_DIR` is set, otherwise `WITNESS_DIR=$(mktemp -d "${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/team-witness-{slug}.XXXXXX")` — recorded as each member's `scratchDir`.

Naming the variable without rooting a path at it is prose, not a path: `${TMPDIR}` cannot hold the witness, and saying so must not be a violation.

Team config still reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/`, which the first rule permits.
