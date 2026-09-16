# Skill rooting the witness directory where the protocol puts it

- **Witness scratch dir**: before the first spawn, run the protocol's `## Spawn` command — `<plugin root>/orchestrator/cc-team-witness-init.sh {slug}` — and record the **printed path, literally** as each member's `scratchDir`. That script is the only sanctioned way to mint the directory; the two roots it chooses between are `${CC_PIPELINE_RUN_DIR}` when set and `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design` otherwise, and the name it mints carries the `cc-team-witness-` prefix the cleanup guard sweeps.

Naming the variable without rooting a path at it is prose, not a path: `${TMPDIR}` cannot hold the witness, and saying so must not be a violation.

Team config still reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/`, which the first rule permits.
