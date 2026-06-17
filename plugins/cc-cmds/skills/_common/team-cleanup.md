# Team Cleanup (Shared Procedure)

In the nameless-background-task model (`_common/agent-team-protocol.md`), a member **self-terminates the moment it returns** — there is nothing to shut down. The old `shutdown_request` → `TeamDelete` → `ps aux` procedure is gone. Cleanup is now just two checks; it is inherently idempotent (re-running is a no-op), so a skill's cleanup-anchor may invoke it at any phase boundary without guards.

- **Normal completion** → **no-op**. Every member that returned has already self-terminated. There is no team directory, no orphan process, nothing to delete.
- **Abort** → call `TaskStop` on every `agentId` whose ledger `state` is still `running` (a wedged/never-returned task per Case 2). `TaskStop` on an already-returned task is a harmless no-op.
- **Ledger hygiene** → update the ledger so no `state=running` row survives the workflow: set returned members to `done` and any `TaskStop`-ed member to `aborted`. A residual `state=running` row is the only leftover signal, so leaving one stale would produce a false leftover detection.

NEVER use `rm -rf` or `kill` on agent processes.
