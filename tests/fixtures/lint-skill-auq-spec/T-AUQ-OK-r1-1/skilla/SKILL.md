---
name: r11
description: fixture — loads AUQ and references the construction spec
---

## Workflow

### Step 0: Tool Loading
- `ToolSearch("select:AskUserQuestion")`

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints from that file to every AskUserQuestion call in this skill.
