---
name: design
description: 에이전트 팀을 활용한 기능 설계 토론 진행
disable-model-invocation: true
---

Conduct a design discussion using an agent team for the given task.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication (interviews, final presentation) and saved documentation should be in Korean.

## Workflow

### Step 1: Requirements Interview & Codebase Exploration (Korean)

- Do NOT create a team yet. First, interview the user to understand requirements.
- Ask deep, non-obvious questions covering all aspects of the task, including but not limited to: technical implementation, UI/UX, concerns, tradeoffs, scale, constraints, and integration points.
- Avoid generic or superficial questions. Dig into specifics.
- Explore the existing codebase as needed during the interview to inform better questions and identify related patterns, modules, and conventions.
- Iterate between interviewing and codebase exploration until all critical aspects are sufficiently covered, then confirm with the user before proceeding.

### Step 2: Team Composition Proposal (Korean)

- Based on interview results and codebase exploration, propose a team composition to the user.
- Specify each teammate's role, exploration scope, and model (use short aliases: `"opus"`, `"sonnet"`, `"haiku"`).
- Only create the team after the user approves the composition.

### Step 3: Design Discussion (English, internal only)

- Create the team with the approved composition.
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
- **The lead acts as a facilitator**, actively driving multi-round discussion. Do NOT passively wait for results and move on.

#### Teammate Instructions:
- When assigning work to teammates, ALWAYS include this instruction: **"When you send your result, start the message with `[COMPLETE]` if your analysis is finished, or `[IN PROGRESS]` if you need more time to explore. If `[IN PROGRESS]`, briefly state what remains to be done."**
- This signal is the ONLY reliable way to know if a teammate has finished. Do NOT infer completion from idle notifications or the mere arrival of a DM.

#### Discussion Protocol (minimum 2 full rounds):

1. **Round 1 — Initial Proposals**: Assign each teammate their design scope. Wait for ALL teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, reply with "Take your time and send your complete analysis when ready" — do NOT move on.
2. **Quality Gate**: Before proceeding to cross-review, verify each proposal meets minimum depth:
   - References specific files, modules, or patterns from the actual codebase (not generic advice)
   - Includes concrete design decisions with rationale (not just listing options)
   - If a proposal is too shallow or generic, send it back with specific questions asking for deeper analysis
3. **Cross-Review**: Send each teammate's proposal to the other teammates for review. Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches.
4. **Round 2+ — Refinement**: Collect cross-review feedback and send it back to the original authors. Ask them to address the feedback, revise their proposals, and respond to challenges. Repeat this cycle until convergence.
5. **Convergence Check**: After each round, the lead must assess whether open issues remain. Ask ALL teammates explicitly: "Do you have any remaining concerns or alternative proposals? Reply with `[COMPLETE] No further input` or `[IN PROGRESS]` with your remaining concerns." Only proceed to Step 4 when ALL teammates confirm `[COMPLETE]`.

#### Facilitator Rules:
- **Distinguish idle notifications from DMs**: Messages marked with `(idle)` (e.g., `[Teammate X (idle)]: ...`) are **system-generated summaries**, NOT teammate DMs. Even if an idle notification contains words like "completed" or "finished", it is NOT a `[COMPLETE]` signal. ONLY count a response as received when the teammate sends an actual DM via SendMessage (shown as `[Teammate X] sent DM to [team-lead]` or similar) that starts with `[COMPLETE]` or `[IN PROGRESS]`.
- **Idle ≠ Done**: A teammate going idle is normal — it does NOT mean they are done. Teammates may go idle while still processing (e.g., during sequential-thinking). Only trust the `[COMPLETE]` / `[IN PROGRESS]` signal in an actual DM. If a teammate goes idle without sending a DM, send them a follow-up asking for their status.
- **Do NOT end discussion after the first response.** Even if all teammates send `[COMPLETE]` in Round 1, you MUST proceed to cross-review (Round 2) at minimum.
- **Actively cross-pollinate**: When teammate A raises a point relevant to teammate B's scope, forward it and ask for their take.
- **Surface disagreements**: If teammates propose conflicting approaches, explicitly highlight the conflict and ask both sides to argue their position before the lead makes a judgment call.
- **Track open issues**: Maintain a running list of unresolved questions. The discussion is NOT complete until every item is either resolved or explicitly marked as a tradeoff to document.

### Step 4: Result Synthesis & Documentation (Korean)

- The lead synthesizes all discussion results into a structured Korean document:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 미해결 이슈 / 트레이드오프
    - 권장 구현 순서
- Save the design document to the project's `docs/` directory.
- Present the results to the user in Korean.

### Step 5: Plan Refinement with User

- Discuss the design document with the user in Korean and refine the plan together.
- If the user raises questions that require deeper exploration, alternative comparison, or additional analysis, propose spinning up an agent team for that specific investigation.
- Only create a team if the user approves. Otherwise, continue refining in the current session.
- If a team is created, internal discussion should be conducted in English. Present the results to the user in Korean.
- After each round of refinement, update the saved document in `docs/` to reflect the latest decisions.
- Repeat until the user is satisfied with the plan.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Agent Team required**: Steps that involve team creation and inter-agent discussion MUST use TeamCreate and SendMessage tools. Do NOT substitute with Agent tool sub-agents. The team discussion requires real-time inter-agent communication (debate, challenge, cross-validation) which is only possible through Agent Teams, not isolated sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (user interview).
- **Team cleanup required**: After all team discussion is complete and results are synthesized, you MUST gracefully shut down the team. Follow these steps IN ORDER — do NOT skip ahead:
  1. Send `shutdown_request` to each teammate via `SendMessage` (type: "shutdown_request").
  2. **WAIT for ALL teammates to confirm shutdown** (they respond with `shutdown_response` approve: true). Do NOT proceed to step 3 until every teammate has responded. If a teammate does not respond, retry the `shutdown_request` — **repeat up to 10 times** with a brief pause between attempts. **NEVER forcefully kill (`kill`) agent processes.**
  3. **If a teammate still has not responded after 10 retries**, use `AskUserQuestion` to inform the user which teammate(s) failed to shut down and ask them to handle it manually. Do NOT proceed to TeamDelete until resolved.
  4. Call `TeamDelete` to remove the team files and clean up resources. Only call this AFTER all teammates have confirmed shutdown or the user has handled unresponsive teammates.
  5. **Verify process cleanup**: Run `ps aux | grep "team-name" | grep -v grep` to check for orphan agent processes. If any remain, **do NOT kill them** — use `AskUserQuestion` to inform the user of the remaining PIDs and ask them to terminate the processes.
  - **Shutdown failure fallback**: If `TeamDelete` fails due to active teammates, **do NOT use `rm -rf` or `kill`**. Instead, use `AskUserQuestion` to inform the user of the failure and ask them to manually clean up (`~/.claude/teams/{team-name}` and `~/.claude/tasks/{team-name}`).
  - If multiple teams are created during the workflow (e.g., in Step 5 refinement), clean up each team before creating the next one.

Task: $ARGUMENTS
