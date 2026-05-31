---
name: r23
description: fixture — banned token quoted in prose, suppressed on the same line
---

## Workflow

### Step 0: Tool Loading
- `ToolSearch("select:AskUserQuestion")`

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints.

Note: never add a manual "직접 지정" option. <!-- lint-skill-auq-spec: disable=other-option -->
