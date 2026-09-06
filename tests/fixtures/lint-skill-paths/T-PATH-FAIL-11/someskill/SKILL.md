# Skill with the retired witness-directory spelling

- **Witness scratch dir**: before the first spawn, `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{slug}.XXXXXX")`, recorded as each member's `scratchDir` — must fail on both halves at once: the basename still carries the `cc-` prefix the cleanup guard does not know, and the root is `${TMPDIR}`, which is collected long before the witness stops being the anti-fabrication anchor.
