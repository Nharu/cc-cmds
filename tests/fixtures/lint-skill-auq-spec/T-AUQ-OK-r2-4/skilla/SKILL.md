---
name: r24
description: fixture — clean label+description option menu, no banned tokens
---

## Workflow

### Step 0: Tool Loading
- `ToolSearch("select:AskUserQuestion")`

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints.

Options:
- label "승인" — description: apply the proposal to the current scope.
- label "거부 (현재 유지)" — description: do not apply; the item is not re-reported.
