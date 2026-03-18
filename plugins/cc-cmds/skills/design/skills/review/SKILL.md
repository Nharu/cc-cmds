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

### Phase 1: Setup

1. Read the full design document to verify existence and parseability.
2. Create the temp directory and initialize files:
```bash
mkdir -p docs/_temp
```
3. Initialize `docs/_temp/review_log.md` with a header and set round counter to 0.
4. Initialize `docs/_temp/review_proposals.md` as an empty file.
5. Immediately proceed to Phase 2.

### Phase 2: Iterative Review via Agent Loop

Perform agent-based iterative review until no proposals remain across two consecutive rounds.
Each round spawns a fresh review agent that independently reviews the document from scratch.

**State:** `consecutive_clean = 0, round = 0`

**Loop procedure:**
1. `round += 1`. Create a review agent (Agent tool) with the review agent prompt below.
2. The agent reviews the document, writes proposals to `docs/_temp/review_proposals.md` (overwriting at round start), appends a round summary to `docs/_temp/review_log.md`, and returns a structured summary including proposal count.
3. Read `docs/_temp/review_proposals.md` to get the current round's proposals.
4. **If proposals exist:**
   a. For each proposal, analyze its concept:
      - **Proposal type**: Use the Reference text as a hint to identify all affected locations in the design document. Concretize the fix (what exactly will change, where).
      - **Decision type**: Analyze the impact of each option so the user can make an informed choice.
   b. Present proposals to the user via AskUserQuestionTool (in Korean). See "Approval UX" below.
   c. Process user choices according to the "Processing Protocol" below.
   d. Update the round entry in `docs/_temp/review_log.md` with disposition tags.
   e. `consecutive_clean = 0`
5. **If no proposals:** `consecutive_clean += 1`
6. **Exit condition:** `consecutive_clean == 2` → proceed to Phase 3.
7. **Safety limit:** Default 20 rounds. On reaching the limit, report current status to user in Korean and ask whether to extend by 10 rounds. If approved, extend. If declined, stop. Extensions are repeatable.
8. If exit condition not met → go back to step 1 with a new agent.

#### Approval UX

Present proposals item-by-item via AskUserQuestionTool, batched up to 4 at a time. No "approve all" option — every proposal requires individual review.

**For Proposal type** (fix proposals):
- Present the agent's concept together with the main session's concretized scope (affected locations and specific changes).
- Options: "승인" (with description of what will be applied) and "거부 (현재 유지)" (with note that the item won't be re-reported).

**For Decision type** (judgment calls):
- Dynamically construct AskUserQuestionTool options from the agent's Options field (up to 4 options, AskUserQuestionTool constraint).
- Include agent recommendation if present (append "(에이전트 추천)" to the label).
- Additional alternatives beyond 4 are noted in the question text from the Agent note field.

**Other input**: The user may type free-form text instead of selecting an option. This is handled by the Processing Protocol below.

#### Processing Protocol

For each user response to a proposal:

- **"승인" selected** (or a Decision option selected): Main session applies the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Other input**: Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestionTool, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.

#### Application mechanism

The main session applies approved changes directly using Edit tool (or equivalent). The agent never modifies the design document. Since concepts may affect multiple locations, the main session identifies all affected locations during scope analysis and applies changes in batch.

If an Edit fails:
- Immediately notify the user: "제안 #N 적용 중 일부 위치에서 실패: [원인]"
- Re-analyze the failed location and propose an alternative.
- Apply after user confirmation, or defer to the next round.
- Record the outcome in `review_log.md`.

**Review agent prompt:**

```
You are a design document reviewer. Perform ONE independent round of review.

First, read docs/_temp/review_log.md to determine the current round number.
IMPORTANT: Check for an "Acknowledged Items" section in review_log.md. These are items the user has already reviewed and decided to keep as-is. Do NOT report these items as proposals again.

Then read the design document and review it against ALL of the following criteria:

1. Requirement consistency — Verify all requirements mentioned in the spec are reflected in the design, and all design decisions trace back to a requirement. Check for requirements that are partially addressed or contradicted.
2. Internal coherence — Check that data models, API contracts, sequence flows, and component responsibilities are mutually consistent. A field added in one section must appear correctly in all related sections.
3. Feasibility — Verify that proposed solutions are technically feasible with the stated tech stack. Flag any design that assumes capabilities not available in the chosen technologies.
4. Implementation order — Check that the proposed implementation sequence respects dependencies. No step should reference artifacts from a later step.
5. Missing items — Look for gaps: error handling not specified, edge cases not covered, security considerations absent, migration plans missing, rollback strategies undefined.
6. Contextual review — Based on the specific domain and nature of this design, check for additional concerns that matter in this context but are not covered by the above categories.

{BASE_MODE_CONSTRAINT}

IMPORTANT: Do NOT modify the design document directly. For every issue found, create a proposal in the following format:

### PROP-R{round}-{number}
- **Type**: [proposal | decision]
- **Category**: [requirement-consistency | internal-coherence | feasibility | implementation-order | missing-items | contextual]
- **Location**: [section name or location in the design document]
- **Issue**: [problem description]
- **Concept**: [fix concept — what to change and why]
- **Options**: [decision type only: list up to 4 options with descriptions. Include recommendation if any.]
- **Reference text**: [relevant excerpt from the original text, as a hint for scope analysis]
- **Agent note**: [optional: additional context, alternatives, or extra options beyond 4]

Type guidance:
- proposal: The fix direction is clear. Describe what should change and why.
- decision: Multiple valid approaches exist and user judgment is needed. List up to 4 options with descriptions (AskUserQuestionTool constraint). If more alternatives exist, note them in Agent note.

Write all proposals to docs/_temp/review_proposals.md (overwrite the file at the start of the round).

After completing the review, append a round summary to docs/_temp/review_log.md:
  ## Review Round N
  - Proposals created: X (categorized by criteria)
  - Proposal details: [list each PROP-ID with Type, Category, and brief description]

Return a structured summary:
- Round number
- Total proposals created
- Proposal categories breakdown
- Brief description of each proposal
```

**On loop exit:**
After confirming 2 consecutive rounds with 0 proposals, mark the document status as "설계 완료" and present a summary of all changes across all rounds to the user in Korean.

### Phase 3: Cleanup

1. Present the full review summary to the user in Korean.
2. Delete the `docs/_temp/` directory:
```bash
rm -rf docs/_temp/
```

## Ground Rules

1. **Propose first, user decides.** All issues are generated as concept proposals. The agent never modifies the design document directly. Changes are applied only after user approval.
2. **Agent Loop required.** Phase 2 iterative review must use the agent-based loop. Exit requires 2 consecutive rounds with 0 proposals generated.
3. **Agent independence.** Each review agent reviews the document from scratch. Previous round results are only accessed via `review_log.md`.
4. **Review log required.** Every round's results must be recorded in `docs/_temp/review_log.md` with disposition tags: `[APPROVED]`, `[REJECTED]`, `[MODIFIED]`, `[USER-DIRECTED]`.
5. **Respect acknowledged items.** Items the user has decided to keep as-is (rejected proposals) must not be re-reported in subsequent rounds.
6. **Never decide for the user.** When the user responds to a pending decision with a follow-up question, a request for more context, or a discussion point, this is NOT a decision. Continue the conversation via AskUserQuestionTool until the user states an explicit decision. A decision is only confirmed when the user clearly says what to do (e.g., "A로 가자", "현재 유지", "변경해줘"). Questions like "그러면 ~는 어떻게 되나요?" or "~에 대해 좀 더 설명해줘" are continuation signals, not decisions. This rule applies equally to Other input handling in the Processing Protocol.

## Options

### --base

Base design review mode. When `$ARGUMENTS` contains `--base`, add the following constraint block to the review agent prompt in place of `{BASE_MODE_CONSTRAINT}`:

```
BASE MODE CONSTRAINT:
Verify consistency and completeness of the existing design content. Do NOT propose adding new implementation details.
- DO propose: inconsistencies, contradictions, or missing interface definitions between existing sections.
- DO propose: essential supplements to existing content that are clearly needed for consistency (will be confirmed with user).
- DON'T propose: adding new implementation details that don't currently exist (these belong to task-level design).
- DON'T propose: removing or reducing existing detailed design content.
```

When `--base` is not present, remove the `{BASE_MODE_CONSTRAINT}` placeholder line from the agent prompt.

Parse `$ARGUMENTS` to detect and strip the `--base` flag. Pass the remaining arguments (the design document path) to the workflow.

## Begin

$ARGUMENTS
