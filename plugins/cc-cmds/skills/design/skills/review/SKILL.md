---
name: design-review
description: 설계 문서 최종 리뷰
disable-model-invocation: true
---

Perform a final review of the design document.

All analysis work and inter-agent communication should be in English to optimize token usage.
User-facing communication (summaries, questions, status updates) should be in Korean.

## Review Criteria

Requirement consistency, internal coherence, feasibility, implementation order, missing items, and any other perspective important in the context of this specific design.

## Strategy

### Phase 1: Initial Review

1. Read the full design document and perform Round 1 review against the criteria above.
2. Fix issues directly where the fix is unambiguous.
3. For items requiring user judgment, ask via AskUserQuestionTool (in Korean).
4. Log review results to `docs/_temp/review_log.md`:
```bash
mkdir -p docs/_temp
```

### Phase 2: Iterative Review via Agent Loop

After the initial review, perform agent-based iterative review until zero issues remain.
Each round spawns a fresh review agent that independently reviews the document from scratch.

**Loop procedure:**
1. Create a review agent (Agent tool) with the review agent prompt below.
2. The agent completes one review round and returns a summary including issue count and pending decisions.
3. Read `docs/_temp/review_log.md` to cross-check the agent's report.
4. **Pending decisions handling**: If the agent returned pending decisions, ask the user via AskUserQuestionTool (in Korean). Based on the user's answer:
   - If the user makes a clear decision (change or keep as-is): apply the decision immediately.
     - Change needed → apply the fix to the design document directly.
     - Keep as-is → record the item and rationale under the `## Acknowledged Items` section in `docs/_temp/review_log.md`. Future agents will read this section and skip these items.
   - **If the user asks follow-up questions, requests clarification, or wants deeper discussion**: Do NOT treat this as a decision. Answer the user's question thoroughly via AskUserQuestionTool, then ask again for their decision on the same pending item. Continue this dialogue loop until the user gives an explicit, unambiguous decision. Never infer or assume a decision from a question or discussion.
5. Exit condition: **2 consecutive rounds** with 0 issues found → proceed to Phase 3. "0 issues found" means the reviewer discovered NO issues at all during the round — not that all found issues were auto-fixed. A round that finds 3 issues and fixes all 3 counts as "3 issues found", NOT "0 issues found". Auto-fixes must be verified by a subsequent clean round.
6. If not met → go back to step 1 with a new agent.
7. Safety limit: maximum 20 rounds. If reached, stop and report current status to the user in Korean.

**Review agent prompt:**

```
You are a design document reviewer. Perform ONE independent round of review.

First, read docs/_temp/review_log.md to determine the current round number.
IMPORTANT: Check for an "Acknowledged Items" section in review_log.md. These are items the user has already reviewed and decided to keep as-is. Do NOT report these items as issues again.

Then read the design document and review it against ALL of the following criteria:

1. Requirement consistency — Verify all requirements mentioned in the spec are reflected in the design, and all design decisions trace back to a requirement. Check for requirements that are partially addressed or contradicted.
2. Internal coherence — Check that data models, API contracts, sequence flows, and component responsibilities are mutually consistent. A field added in one section must appear correctly in all related sections.
3. Feasibility — Verify that proposed solutions are technically feasible with the stated tech stack. Flag any design that assumes capabilities not available in the chosen technologies.
4. Implementation order — Check that the proposed implementation sequence respects dependencies. No step should reference artifacts from a later step.
5. Missing items — Look for gaps: error handling not specified, edge cases not covered, security considerations absent, migration plans missing, rollback strategies undefined.
6. Contextual review — Based on the specific domain and nature of this design, check for additional concerns that matter in this context but are not covered by the above categories.

For each issue found:
- Fix it directly in the document if the fix is unambiguous.
- If the fix requires a judgment call (tradeoffs, ambiguous requirements, multiple valid approaches), do NOT fix it. Instead, add it to the "pending decisions" list with: the issue description, the options available, and your recommendation.

After completing the review, append results to docs/_temp/review_log.md:
  ## Review Round N
  - Issues found: X (categorized by criteria)
  - Issues fixed: X
  - Pending decisions: X
  - Details: [list each issue and resolution]
  - Pending decision details: [list each pending decision with options and recommendation]

Return a structured summary:
- Round number
- Total issues found (count ALL issues discovered, including those you auto-fixed)
- Total issues fixed
- Pending decisions (with full details for each)
- Issue categories breakdown

IMPORTANT: "Total issues found" must count every issue you discovered during review, regardless of whether you fixed it. Do NOT report 0 issues found just because all found issues were auto-fixed.
```

**On loop exit:**
After confirming zero issues, mark the document status as "설계 완료" and present a summary of all changes across all rounds to the user in Korean.

### Phase 3: Cleanup

1. Delete the `docs/_temp/` directory:
```bash
rm -rf docs/_temp/
```

## Ground Rules

1. **Fix first, ask second.** Fix unambiguous errors without asking. Use AskUserQuestionTool only for tradeoffs or ambiguous requirements.
2. **Agent Loop required.** Phase 2 iterative review must use the agent-based loop. Minimum 2 rounds.
3. **Agent independence.** Each review agent reviews the document from scratch. Previous round results are only accessed via review_log.md.
4. **Review log required.** Every round's results must be recorded in `docs/_temp/review_log.md`.
5. **Respect acknowledged items.** Items the user has decided to keep as-is must not be re-reported in subsequent rounds.
6. **Never decide for the user.** When the user responds to a pending decision with a follow-up question, a request for more context, or a discussion point, this is NOT a decision. Continue the conversation via AskUserQuestionTool until the user states an explicit decision. A decision is only confirmed when the user clearly says what to do (e.g., "A로 가자", "현재 유지", "변경해줘"). Questions like "그러면 ~는 어떻게 되나요?" or "~에 대해 좀 더 설명해줘" are continuation signals, not decisions.

## Begin

$ARGUMENTS
