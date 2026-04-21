# Agent Team Protocol (Shared Rules)

Shared completion-signal contract and facilitator rules for multi-agent team workflows (`design`, `review`, `design-review`).

## Completion Signal Instruction (include in every teammate assignment)

When assigning work to teammates, ALWAYS include this instruction:

> "When you send your result, start the message with `[COMPLETE]` if your analysis/review is finished, or `[IN PROGRESS]` if you need more time. If `[IN PROGRESS]`, briefly state what remains."

This signal is the ONLY reliable way to know if a teammate has finished. Do NOT infer completion from idle notifications or the mere arrival of a DM.

## Facilitator Rules

- **Distinguish idle notifications from DMs**: Messages marked with `(idle)` (e.g., `[Teammate X (idle)]: ...`) are **system-generated summaries**, NOT teammate DMs. Even if an idle notification contains words like "completed" or "finished", it is NOT a `[COMPLETE]` signal. ONLY count a response as received when the teammate sends an actual DM via `SendMessage` (shown as `[Teammate X] sent DM to [team-lead]` or similar) that starts with `[COMPLETE]` or `[IN PROGRESS]`.

- **Idle ≠ Done**: A teammate going idle is normal — it does NOT mean they are done. Teammates may go idle while still processing (e.g., during sequential-thinking). Only trust the `[COMPLETE]` / `[IN PROGRESS]` signal in an actual DM. If a teammate goes idle without sending a DM, send a follow-up asking for their status.

- **Do NOT end discussion/review after the first response.** Even if all teammates send `[COMPLETE]` in Round 1, you MUST proceed to cross-review/cross-validation (Round 2) at minimum.

- **Actively cross-pollinate**: When teammate A raises a point relevant to teammate B's scope, forward it and ask for their take.

- **Surface disagreements**: If teammates propose conflicting approaches or severity assessments, explicitly highlight the conflict and ask both sides to argue their position before the lead makes a judgment call.

- **Track open issues**: Maintain a running list of unresolved questions. The workflow is NOT complete until every item is either resolved or explicitly marked as a tradeoff/follow-up.

- **Convergence Check template**: After each round, ask ALL teammates explicitly: "Do you have any remaining concerns or alternative proposals? Reply with `[COMPLETE] No further input` or `[IN PROGRESS]` with your remaining concerns." Only proceed to the next phase when ALL teammates confirm `[COMPLETE]`.
