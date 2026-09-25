# Team Cleanup (Shared Procedure)

In the nameless-background-task model (`agent-team-protocol.md`), a member **self-terminates the moment it returns** — there is nothing to shut down.

## When each part runs — this file decides, not the caller

**A skill's cleanup-anchor may invoke this file at any phase boundary, and the anchor is not asked to judge whether the workflow is over.**

- **Process and ledger hygiene** (the first three bullets) run at **every** invocation. They are genuinely idempotent — re-running is a no-op.
- **Teardown** (the fourth bullet: the witness-directory `rm -rf` and the four-field strip) runs **only when the workflow itself is over** — no phase remains that will spawn or resume a team. It is **not** idempotent mid-workflow and it is not a no-op: it removes the anchor a later phase reads.

**"The workflow is over" means: no later step of the calling skill spawns a team or resumes one.** A step that re-convenes an earlier team for a later witnessed phase is a later step. When it is not certain, teardown is **skipped**: an early teardown erases the only anchor a resumed phase can read, and nothing else sweeps these roots.

## The checks

- **Normal completion** → **no process teardown**. Every member that returned has already self-terminated: there is no team directory in the discarded sense, and no orphan process to kill. This bullet is about PROCESSES only — the witness scratch dir below is removed on exactly this path.
- **Abort** → call `TaskStop` on every `agentId` whose ledger `state` is still `running` (a wedged/never-returned task per Case 2). `TaskStop` on an already-returned task is a harmless no-op.
- **Ledger hygiene** → update the ledger so no `state=running` row survives the workflow: set returned members to `done` and any `TaskStop`-ed member to `aborted`. A residual `state=running` row is the only leftover signal, so leaving one stale would produce a false leftover detection.
- **Witness scratch dir** → on **normal workflow completion**, `rm -rf` each team's witness directory (path-guarded to the recorded `scratchDir` — the `cc-team-witness-<slug>[.<stage-id>]` directory minted at spawn — never a bare or computed path) and **only then**, per-row, strip `scratchDir`, `outputFile`, `stallMark`, and `witnessNonce` from **every** terminal ledger row (`done` and `aborted` alike — including a member left `aborted` by a Case-2 partial synthesis). Stripping these four keeps the committed document free of the scratch-path / session-path / stale-counter / random-nonce leak (per the ledger v3 transient-field classification). **`epoch` is deliberately NOT stripped** — it is the only durable source the next `max(disk epoch, 0) + 1` re-derivation and the roster's `max(epoch)` scoping can read, and it leaks nothing. On a **workflow-level abort**, the witness directories and the rows' `scratchDir`, `outputFile`, `stallMark`, and `witnessNonce` fields are **retained** for audit/recovery (`epoch` is retained on every path, so it has no abort-specific arm). The cleanup axis is the workflow result, not the per-row state. The witness dir is out-of-tree under either root it can take (the driver run dir, else `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design` — see `agent-team-protocol.md`'s Spawn section), so neither retaining nor removing it touches the two-command boundary gate.

**Teardown carries weight where the directory endures**: under the state directory and the run directory nothing collects it, so teardown has to be reachable on the completion path and unreachable at a mid-workflow anchor.

**The order in that last bullet is load-bearing**: removal precedes the strip, so a cut between them fails in the recoverable direction.

NEVER use `rm -rf` or `kill` on agent processes. The witness-dir `rm -rf` above is the sole exception and is path-guarded to the recorded `scratchDir`.
