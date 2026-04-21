---
name: design
description: 에이전트 팀을 활용한 기능 설계 토론 진행
when_to_use: 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때
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

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step.

- Create the team with the approved composition.
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
- **The lead acts as a facilitator**, actively driving multi-round discussion. Do NOT passively wait for results and move on.

#### Discussion Protocol (minimum 2 full rounds)

1. **Round 1 — Initial Proposals**: Assign each teammate their design scope. Wait for ALL teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, reply with "Take your time and send your complete analysis when ready" — do NOT move on.
2. **Quality Gate**: Before proceeding to cross-review, verify each proposal meets minimum depth:
   - References specific files, modules, or patterns from the actual codebase (not generic advice)
   - Includes concrete design decisions with rationale (not just listing options)
   - If a proposal is too shallow or generic, send it back with specific questions asking for deeper analysis
3. **Cross-Review**: Send each teammate's proposal to the other teammates for review. Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches.
4. **Round 2+ — Refinement**: Collect cross-review feedback and send it back to the original authors. Ask them to address the feedback, revise their proposals, and respond to challenges. Repeat this cycle until convergence.
5. **Convergence Check**: Use the convergence-check template from `_common/agent-team-protocol.md`. Only proceed to Step 4 when ALL teammates confirm `[COMPLETE]`.

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

**Before cleaning up any team, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure. When multiple teams are created during refinement, clean up each team before creating the next one.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Agent Team required**: Steps that involve team creation and inter-agent discussion MUST use TeamCreate and SendMessage tools. Do NOT substitute with Agent tool sub-agents. The team discussion requires real-time inter-agent communication (debate, challenge, cross-validation) which is only possible through Agent Teams, not isolated sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (user interview).

Task: $ARGUMENTS
