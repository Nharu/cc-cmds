---
name: implement
description: 설계 문서 기반 구현
disable-model-invocation: true
---

Implement based on the provided design document.

## Workflow

### Step 1: Read Design Document

- Read the design document at the given path thoroughly.
- Identify all requirements, architecture decisions, file changes, and implementation steps defined in the document.

### Step 2: Create Implementation Plan (Plan Mode)

- Before switching to plan mode, load the tool via ToolSearch with query "select:EnterPlanMode". Then switch to plan mode and create a concrete implementation plan based on the design document.
- Every requirement, decision, and file change in the design document must be covered in the plan. Do NOT omit or skip any item.
- Cross-check the plan against the design document to ensure nothing is missing before presenting.

### Step 3: Implementation

- After the plan is approved, implement step by step.
- Before using Task management tools or AskUserQuestion, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:TaskCreate", "select:TaskList", "select:TaskUpdate", "select:TaskGet", and "select:AskUserQuestion" to load each tool. These are deferred tools and will NOT work unless loaded first.
- Use Task management tools (TaskCreate, TaskUpdate, TaskList, TaskGet) actively to manage implementation steps. Define clear dependencies between tasks using `addBlocks`/`addBlockedBy` parameters in TaskUpdate to ensure systematic execution.
- When code exploration is needed during implementation (e.g., checking module structures, finding usage patterns, understanding existing interfaces), delegate to subagents in parallel to keep the main context clean and save time.

## Constraints

- Do NOT deviate from the design document. If something seems wrong or unclear, ask the user instead of making assumptions.
- All items in the design document must be reflected in the implementation plan.
- Do NOT modify the design document.

Design document: $ARGUMENTS
