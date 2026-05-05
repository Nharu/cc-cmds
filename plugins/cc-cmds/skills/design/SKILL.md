---
name: design
description: 에이전트 팀을 활용한 기능 설계 토론 진행
when_to_use: 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때
disable-model-invocation: true
usage: "/cc-cmds:design <task>"
options:
    - name: "<task>"
      kind: positional
      required: true
      summary: "설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트)."
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

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step. When you assign work to each teammate via SendMessage, include the Teammate Rules block from `_common/agent-team-protocol.md` **verbatim in the assignment body** (the block-quoted teammate-facing instruction under the `## Teammate Rules` heading) — do NOT paraphrase to a one-liner. The short form is the documented cause of teammates emitting `[COMPLETE]` as text instead of via SendMessage.

- Create the team with the approved composition. Name it `design-{topic-slug}` (e.g., `design-auth-flow`, `design-payment-system`).
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
- **Synthesis terminal**: All teammate clarifications must be completed before saving the design document. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. Do NOT save a partial document, send a teammate message, then save again; clarify before the first save. The sequence save → cleanup → presentation is atomic.
- Save the design document to the project's `docs/` directory. **File naming convention**: use `docs/{topic-slug}.md` where `{topic-slug}` matches the Step 3 team's topic slug exactly (e.g., Step 3 team `design-auth-flow` → saved doc `docs/auth-flow.md`). This filename-to-slug binding is the local state used by Step 5's entry state-check to recover the slug without relying on lead memory. **Interrupted-save case**: if the save itself was interrupted (partial write, permission error, etc.), the state-check cannot recover the slug from the filename. In this case the lead must either (a) recover the slug from the original task input or interview output that started the workflow (from in-session conversation history, including slash-command `$ARGUMENTS` if invoked that way), or (b) treat the workflow as ambiguous and prompt the user via `AskUserQuestion` before any cleanup action.
- Notify the user in Korean: *"설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure to clean up the design team.
- Present the results to the user in Korean.

### Step 5: Plan Refinement with User

**State check on entry**: If any team associated with this design workflow is still active (Step 3 original team or any prior Step 5 refinement team), notify the user in Korean (*"이전 단계의 팀이 아직 살아있어 정리 후 리파인먼트를 시작하겠습니다."*), then execute cleanup now (Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and follow the 5-step shutdown procedure) before any Step 5 activity. Detect active teams by enumerating `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/` via Bash with a slug-specific regex: `ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null | grep -E "^design-<slug>(-refine-[0-9]+)?$"`, where `<slug>` is recovered from the saved design document filename in `docs/` (the filename encodes the topic slug per Step 4's save convention — local file-system state, not memory). **Preferred slug recovery**: the lead remembers the exact filename it saved in Step 4 (not mere "most recent .md file" — that may be unrelated to the design workflow if the project is actively edited elsewhere). If the lead cannot recall the exact filename, fall back to matching against `docs/` modification times within a narrow window after Step 4, and if still ambiguous (multiple candidates), prompt the user via `AskUserQuestion` to confirm the target document. Never assume the most recently modified `docs/*.md` is the design doc without validation. This matches only the Step 3 original team name (`design-<slug>`) and all refinement teams (`design-<slug>-refine-N`) for the current workflow's topic, **without** cross-matching unrelated prior-session teams on other topics. Any matching directory that corresponds to a team created in this session is treated as active and requires cleanup. Under normal flow, all prior teams are already dead and this step proceeds with the lead only.

- Discuss the design document with the user in Korean and refine the plan together.
- Lead-only by default: doc edits, user Q&A, and codebase re-exploration require no team.
- If the user raises questions requiring deeper investigation that exceed lead-only capacity, verify no prior workflow team is still active (if one remains, notify in Korean: *"새 리파인먼트 팀을 만들기 전에 기존 팀을 먼저 정리하겠습니다."* and execute cleanup), then propose composing a **new** team for that specific investigation — mirror Step 2 (role/scope/model proposal → user approval → spawn). **Never reuse or restart any prior design team.**
- Only create a new team if the user approves. Otherwise, continue refining in the current session.
- If a new team is created, name it `<original-team-name>-refine-N` where N starts at 1 (e.g., `design-auth-flow-refine-1`, `design-auth-flow-refine-2`). Conduct internal discussion in English. After discussion converges and results are synthesized, update the saved document in `docs/`. Then notify the user in Korean: *"리파인먼트 팀을 정리한 뒤 후속 논의를 이어가겠습니다."* **Before creating the next refinement team or returning to user discussion, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure for that team. Present the updated results to the user in Korean.
- Repeat until the user is satisfied with the plan.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Agent Team required**: Steps that involve team creation and inter-agent discussion MUST use TeamCreate and SendMessage tools. Do NOT substitute with Agent tool sub-agents. The team discussion requires real-time inter-agent communication (debate, challenge, cross-validation) which is only possible through Agent Teams, not isolated sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (user interview).

Task: $ARGUMENTS
