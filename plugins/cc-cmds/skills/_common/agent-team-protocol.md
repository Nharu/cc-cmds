# Agent Team Protocol (Shared Rules)

Shared orchestration contract for multi-agent team workflows (`design`, `design-lite`, `design-analyze`, `design-apply`, `review`, `review-lite`). A team member is a **nameless background task**: the lead spawns it with `Agent` (`subagent_type: "claude"`, **no `name`**, `run_in_background: true`), resumes it across rounds by its `agentId`, and the task **self-terminates** when it returns. A task's **return text IS its result** — there is no separate delivery channel, no completion prefix, no idle-vs-DM ambiguity. The single failure mode the old named-teammate machinery defended against ("plain-text/idle output instead of a delivered DM") is structurally absent here.

## Spawn

Spawn each member as a nameless background task: `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. A task does **not** share the lead's conversation — embed everything load-bearing into the prompt (role, round, all inputs the member must act on). Record the returned `agentId` in the ledger immediately (see **Role↔agentId ledger**). Spawns are synchronous calls: a spawn error is returned inline and handled inline (no dispatch-failure bound needed).

## Completion signal

The task's **return text is the result** — collected via the background completion notification or as the resume tool result. An `agentId` is either *running* or *returned*; a returned task has already self-terminated. Do not look for `[COMPLETE]`/`[IN PROGRESS]` prefixes or session-text echoes — they do not exist in this model.

## Multi-round (resume + context re-injection)

A one-shot isolated `Agent()` per round is forbidden — the retained-context, multi-round cross-review/convergence loop is what makes this a *team*. Drive at least **2 rounds** (Round 1 = produce; Round 2+ = cross-review with peer findings). Resume a member by sending to its `agentId` (`SendMessage` to the agentId continues the task with its context intact). On every resume, the lead **re-injects the load-bearing context** — do not trust retained context for load-bearing data; quote peer findings **verbatim**. Re-injection is belt-and-suspenders: resume reliably recalls prior rounds, but a verbatim re-inject keeps the round robust against drift.

## Convergence

Convergence is by **return collection**, not live polling. After cross-review, resume each member once with a convergence prompt (re-inject current consensus + open conflicts); when every return says "no further input", the team has converged. Batch the resumes; keep one large resume per member per round and cap rounds to the minimum the discussion needs.

## Teardown & abort

Teardown is **automatic** — a returned task has self-terminated, so there is nothing to shut down (no `shutdown_request`, no `TeamDelete`, no `ps aux`). **Abort** = `TaskStop` on a *running* `agentId`. See `_common/team-cleanup.md`.

## Escalation (failure phenotypes)

Two cases (counters) plus one routing rule:

- **Case 1 — Thin-return stall** (counter): a task returns an empty or substanceless result. 1st → re-scope + resume once (hard prompt: "no empty return — deliver the result or name a concrete blocker in one line"); 2nd consecutive → `AskUserQuestion` (proceed without this member / re-scope once more / abort). If excluded, mark the exclusion in the synthesized document's metadata.
- **Case 2 — Never-returns** (binary, not a counter): the start notice fired but no finish notice arrives (runaway/wedge). A wedged task resumes to the same state, so the correct recovery is `TaskStop` + a **fresh re-spawn** (new `agentId`, update the ledger). If the re-spawn also never returns → `AskUserQuestion`.
- **Case 3 — Non-conforming return** (routing rule, not a bound): the task returned but off-contract (spec-violating / malformed). It is not caught by a counter (the return succeeded) — cross-review + the Step-4 fidelity pass catch it. The lead re-assigns once; a recurrence feeds into the Case 1 counter.

"Reasonable bound" for never-returns is a lead judgment call — no wall-clock constant (a long-running scope, e.g. a deep audit, is legitimate). Surface to the user (`AskUserQuestion`) only on a Case-1/Case-2 threshold or explicit user instruction — never on wall-clock time, lead confidence, or lead opinion alone.

## Role↔agentId ledger

The model is roster-less, so an in-context list of agentIds evaporates on compaction with no fallback. Persist a **durable ledger** co-located with each skill's existing artifact:

- **design / design-apply / review / review-lite**: an HTML-comment block at the top of the output document (right after the H1, before the first `##`): `<!-- cc-design-ledger v1 … -->`. A visible `##` section is forbidden (it would collide with walkthrough/implement/design-review heading parsers and would leak opaque agentIds into the user-facing doc). The doc is created as an **early stub** (title + ledger block) at spawn time, before Step-4 save.
- **design-analyze**: a `"ledger"` key in the existing `.{slug}.work.json` (already machine-only).

Each ledger entry is **behavior-bearing**, not id-only: `agentId | state | round | role/scope (1 line) | thinReturns | last-return summary`, where `state ∈ {running, done, aborted}`. Update it on every state change. **Re-read the ledger from disk on entering any phase that resumes a task** (Step-4 fidelity pass, Step-5, Step-6) — do not trust in-context copies. If the block is missing or unparseable, **fail closed via `AskUserQuestion`** (never silent-skip). A residual `state=running` row is also the leftover-detection signal (it replaces the removed `teams/` filesystem scan).

## Task-assignment header (embed verbatim)

When spawning or resuming a member, embed this self-contained header at the top of the prompt (it replaces the old "Teammate Rules" block):

> "**Role**: <your role/scope>. **Round**: <N> (Round 1 = draft; Round 2+ includes peer findings, quoted below). **Inputs** (load-bearing — act only on what is supplied here; you do not share the lead's conversation): <inputs>. **Return contract**: deliver your result as your final return text — there is no separate channel, no completion prefix, no messaging tool to call. Begin your return with your role and round. Never return empty; if you cannot proceed, return your partial result plus a one-line concrete blocker."
