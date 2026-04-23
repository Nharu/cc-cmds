# Agent Team Protocol (Shared Rules)

Shared completion-signal contract and facilitator rules for multi-agent team workflows (`design`, `review`, `design-review`).

## Teammate Rules

*Audience: teammate (second-person). The block quoted below is the teammate-facing instruction; the lead copies the blockquote verbatim into every assignment SendMessage. Do NOT copy this audience line, the heading, or any prose outside the blockquote (including the sentence immediately below and the closing paragraph after the blockquote) into the assignment body — only the blockquote content itself.*

When assigning work to teammates, ALWAYS include this instruction verbatim:

> "**Delivery channel (non-bypassable):** To deliver your result you MUST invoke the `SendMessage` tool with `to` set to the team lead (me in this conversation). Your session text output is NOT visible to the lead — if you only write a reply in the session without calling `SendMessage`, the lead receives nothing and the round stalls. Writing `[COMPLETE]` at the top of a plain-text response is NOT a response. **This channel rule applies to every reply you send** — initial result, Round 2+ revisions, convergence-check replies, `shutdown_response`, and `plan_approval_response` all MUST travel via `SendMessage`. There is no context in which text-only output counts as delivery.
>
> **Message format:** For analysis/discussion replies, the `message` body you pass to `SendMessage` MUST start with `[COMPLETE]` if your analysis/review is finished, or `[IN PROGRESS]` if you need more time (briefly state what remains). The prefix lives inside the `SendMessage` body, not in your surrounding narration. **Exception — protocol responses**: For `shutdown_request` and `plan_approval_request` messages from the lead, the correct response body is the structured payload (`shutdown_response` or `plan_approval_response` per the SendMessage tool schema), NOT a `[COMPLETE]`/`[IN PROGRESS]` prefix. The channel requirement (must travel via `SendMessage`) applies uniformly; only the payload schema differs.
>
> **Self-check every turn:** Whenever a turn of yours would end — after Sequential Thinking, after tool-use bursts, after a short acknowledgement, after a convergence-check reply, or as a final reply — confirm you have called `SendMessage` at least once this turn with a `[COMPLETE]` or `[IN PROGRESS]` body (or the relevant `*_response` payload for protocol messages). Idle ≠ done; the lead cannot see your thinking.
>
> **Silence-check before stopping (contrapositive reinforcement):** This is the contrapositive form of the Self-check above — both are included because redundant behavioral anchors produce measurably higher compliance than either alone. At every decision point where your next action would be to stop (no more tool calls, turn ends), run the self-check as a pre-stop gate. If the immediately-prior response was Sequential-Thinking output, a file Read, or any non-`SendMessage` tool call, AND you intended to signal completion, progress, or respond to a protocol request (shutdown, plan-approval), **you are about to fail the contract**. Call `SendMessage` now before yielding the turn — with a `[COMPLETE]`/`[IN PROGRESS]` body for analysis or the relevant `*_response` payload for protocol requests."

This contract is the ONLY reliable completion signal. Do NOT infer completion from idle notifications, from the session log of a teammate's text output, or from the mere arrival of any DM — completion requires an actual `SendMessage` DM whose body starts with `[COMPLETE]`.

## Facilitator Rules

*Audience: team lead (second-person). These rules govern lead behavior during team discussion; they are NOT sent to teammates.*

- **Distinguish idle notifications from DMs**: Messages marked with `(idle)` (e.g., `[Teammate X (idle)]: ...`) are **system-generated summaries of the teammate's session text**, NOT teammate DMs. An idle notification may quote text that begins with `[COMPLETE]` — this is the exact Issue-2 failure mode: the teammate wrote `[COMPLETE]` as session text without ever invoking `SendMessage`. Treat such idle notifications as **evidence of failure to deliver**, not as a completion signal. ONLY count a response as received when the teammate sends an actual DM via `SendMessage` (shown as `[Teammate X] sent DM to [team-lead]` or the equivalent DM-delivery marker) whose body starts with `[COMPLETE]` or `[IN PROGRESS]`.

- **Idle ≠ Done; idle+text-output ≠ Delivered**: A teammate going idle is normal — it does NOT mean they are done. Teammates may go idle while still processing (e.g., during sequential-thinking). Only trust the `[COMPLETE]` / `[IN PROGRESS]` signal in an actual `SendMessage` DM. If a teammate goes idle without sending a DM (including the case where their idle notification quotes `[COMPLETE]`-prefixed session text), send a follow-up via `SendMessage` with this exact remediation template:

  > "I did not receive your result as a DM. Your plain-text response is invisible to me — only `SendMessage` calls are delivered. Please re-send your analysis by invoking `SendMessage` with `to` set to me (the team lead) and a `message` body that starts with `[COMPLETE]` or `[IN PROGRESS]`."

  Do NOT proceed to the next round, synthesis, or cleanup until the teammate replies via `SendMessage`.

  Additionally, if a teammate sends `[IN PROGRESS]` three times within a round without new substantive content, send a **hard prompt** via `SendMessage` that makes the contract explicit on four axes (channel, deadline, success criteria, escalation):

  > "This is your 3rd `[IN PROGRESS]`. **In your next response**, you MUST do one of the following via `SendMessage` (plain-text output is invisible and will be treated as a non-response):
  > (hp-i) ship with `[COMPLETE]` and the final result, OR
  > (hp-ii) state the specific concrete blocker in one sentence prefixed with `[IN PROGRESS]`.
  >
  > If your next response is open-ended 'still analyzing', another content-free `[IN PROGRESS]`, or any plain-text (non-`SendMessage`) output, I will escalate to the user via `AskUserQuestion` per the escalation bound below."

  This hard prompt makes the delivery channel (`SendMessage` mandatory), the deadline ("next response"), the success criteria (two concrete options), and the failure escalation (`AskUserQuestion`) explicit in a single message. If the teammate still fails to comply, apply the 3-attempt escalation bound described below and hand to `AskUserQuestion`.

  **Counter semantics**: Two independent counters run in parallel, each with its own reset rule:

  - `ip_count` — count of content-free `[IN PROGRESS]` DMs received in the current team-discussion round. **"Content-free"** = the IP body contains no substantive new progress report beyond what was in the teammate's prior IP (e.g., "still analyzing", "looking into it", or re-stating an earlier blocker without new detail). **First-IP base case**: the very first `[IN PROGRESS]` of a reset-cycle has no prior IP to delta against; it is classified content-ful by default unless its body itself is vacuous (e.g., just the literal string "still analyzing" with no further detail — then count as content-free). A one-sentence **concrete blocker statement** (hard prompt option (b) response) is **content-ful** — it surfaces a specific impediment and does NOT count toward `ip_count`. **Content-ful IPs do not increment `ip_count`; they also do not reset it** — only the reset rules below (Convergence Check completion or new substantive prompt) reset the counter. This means a teammate cannot "undo" accumulated ip_count by sending a single content-ful IP mid-round. **Reset rule (unified for all team types)**: The lead resets `ip_count` for a teammate on EITHER (a) Convergence Check completion (not mere issuance — the reset fires when the lead confirms ALL teammates have returned `[COMPLETE] No further input` DMs, marking the end of a discussion round), OR (b) whenever the lead sends a new substantive prompt to that teammate (a forward, cross-review request, or new assignment — not a ping or remediation). Both (a) and (b) are lead-initiated events; the counter is lead-tracked throughout. Step 3 primary teams see both reset triggers (with Convergence Check as a safety ceiling at round boundaries); refinement teams typically only see (b). The forward-progress-based reset (b) applies uniformly so identical teammate behavior hits the hard prompt at the same threshold across team types. At `ip_count >= 3` → send the hard prompt above **exactly once per reset-cycle** (fire-once semantics — subsequent content-free IPs within the same cycle do NOT re-trigger the hard prompt; escalation proceeds via `remediation_count` if the teammate also violates channel rules, or via the content-free stall bound below if the teammate keeps stalling with valid-format but content-free IPs).
  - `remediation_count` — count of channel-remediation templates sent since the teammate's last valid `SendMessage` DM. Resets to 0 on any valid `SendMessage` DM receipt, including content-free `[IN PROGRESS]`. At `remediation_count >= 3` → `AskUserQuestion` escalation bound below.

  Worked example: teammate emits plain text response (no DM) → `remediation_count = 1`. Teammate then sends a content-free `[IN PROGRESS]` DM → `ip_count = 1`, `remediation_count` resets to 0 (valid DM received, even if content-free). Teammate re-emits text → `remediation_count = 1` again, `ip_count` stays at 1. Both counters advance independently and use different triggers, avoiding mutual interference.

  **Escalation bounds** (two parallel triggers for auto-escalation to `AskUserQuestion`, referenced as **Bound A** and **Bound B** throughout this file):

  1. **Bound A — Channel violation bound**: If the teammate continues to emit text instead of `SendMessage` after **3 remediation attempts** (i.e., you sent the template three times and still received no DM, only text/idle), stop retrying and surface via `AskUserQuestion`:

     > "Teammate `<name>` is not responding via `SendMessage` despite 3 channel-remediation attempts. Options: (a) proceed without their input, (b) retry remediation once more, (c) abort workflow."

  2. **Bound B — Content-free stall bound (post-hard-prompt)**: After the hard prompt fires at `ip_count == 3`, if the teammate sends **2 additional content-free `[IN PROGRESS]` DMs** without a concrete blocker statement or substantive progress (i.e., `ip_count` reaches 5 within the same reset-cycle), surface via `AskUserQuestion`:

     > "Teammate `<name>` continues to send content-free `[IN PROGRESS]` updates after the hard prompt (5 total this round). Options: (a) proceed with whatever partial analysis is available, (b) re-scope or ask a different question to unblock them, (c) abort workflow."

  Do not loop indefinitely. In both Bound A and Bound B, option (a) overrides the Convergence Check "ALL teammates must confirm" rule — that is intentional; user decides. **Bound A option (a) / Bound B option (a) downstream handling** (both equivalent to "exclude teammate from synthesis"): the lead (i) marks the excluded teammate in the synthesized design document's metadata section (e.g., `**Note**: Teammate X was excluded from convergence per user decision at {round}`), (ii) during the **cleanup phase** (Step 4 post-synthesis), `shutdown_request` IS sent to the excluded teammate — T5 synthesis-terminal boundary applies only to **synthesis-phase** messaging (forwards / cross-review / convergence-check / clarification), not to cleanup-phase protocol messages (`shutdown_request`, idempotency-guard handling). The excluded teammate's absence is treated as a synthesis data gap; the cleanup contract applies uniformly to all teammates regardless of exclusion status.

- **Do NOT end discussion/review after the first response.** Even if all teammates send `[COMPLETE]` in Round 1, you MUST proceed to cross-review/cross-validation (Round 2) at minimum.

- **Actively cross-pollinate**: When teammate A raises a point relevant to teammate B's scope, forward it and ask for their take.

- **Surface disagreements**: If teammates propose conflicting approaches or severity assessments, explicitly highlight the conflict and ask both sides to argue their position before the lead makes a judgment call.

- **Track open issues**: Maintain a running list of unresolved questions. The workflow is NOT complete until every item is either resolved or explicitly marked as a tradeoff/follow-up.

- **Cleanup-anchor recovery**: If a skill's workflow reaches a documented cleanup anchor (e.g., design Step 4→Step 5 boundary, review Step 5→Step 6 boundary) and a team still exists for the phase that was supposed to be cleaned up, execute `_common/team-cleanup.md` *before* proceeding. Do NOT treat the stale team as usable. This rule is idempotent: if cleanup already ran, the detection of a missing team makes this a no-op.

- **Re-assert the channel on every forward**: Every Round 2+ forward, cross-review request, convergence-check prompt, ad-hoc clarification or status-ping DM, and shutdown/plan-approval request MUST include a one-line channel footer matching the expected response payload:
    - **For analysis/discussion messages** (forwards, cross-review, convergence-check, ad-hoc clarification or status-ping, remediation template, hard prompt): *"Reply via `SendMessage`; plain-text output is invisible. Start your `message` body with `[COMPLETE]` or `[IN PROGRESS]`."*
    - **For shutdown requests**: *"Reply via `SendMessage`; plain-text output is invisible. Respond with a `shutdown_response` payload (type, request_id, approve)."*
    - **For plan-approval requests**: *"Reply via `SendMessage`; plain-text output is invisible. Respond with a `plan_approval_response` payload (type, request_id, approve, optional feedback)."*

  This is defensive against teammate context compaction (the initial completion-signal block may be summarized away) and against drift in short-form exchanges where the teammate is tempted to skip tool use. The payload-specific variants prevent the "footer contradicts body" failure mode on protocol paths (shutdown/plan-approval expect structured responses, not `[COMPLETE]`).

- **Convergence Check template**: After each round, ask ALL teammates via `SendMessage` (one DM per teammate, or a broadcast pattern if your skill supports it). Send the following prompt to each teammate (teammate-facing; `you` = teammate):

  > "Do you have any remaining concerns or alternative proposals? **Respond via `SendMessage`** with a `message` body starting with `[COMPLETE] No further input` or `[IN PROGRESS]` followed by your remaining concerns. Your plain-text output is invisible to me — only `SendMessage` DMs count as a response."

  Only proceed to the next phase when ALL teammates have confirmed `[COMPLETE]` *as a `SendMessage` DM*. Idle notifications quoting `[COMPLETE]` are not confirmations (see "Distinguish idle notifications from DMs" rule above).
