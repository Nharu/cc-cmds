---
name: implement
description: 설계 문서 기반 구현
when_to_use: 사용자가 작성된 설계 문서를 바탕으로 단계적 계획을 세우고 실제 구현을 수행하기를 원할 때
disable-model-invocation: true
usage: "/cc-cmds:implement <design-doc-path> [scope-directive]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "구현 대상 설계 문서 경로 (`.md`)."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석. 이후 토큰은 scope directive로 전달."
    - name: "[scope-directive]"
      kind: positional
      required: false
      summary: '구현 범위를 좁히는 자유형 자연어 지시문 (예: `"Phase 2"`, `"PR #0"`).'
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 단일 바깥쪽 쌍따옴표로 감싸져 있으면 그 쌍만 제거하고 안쪽 따옴표·구두점은 보존."
---

Plan and then implement based on the provided design document.

## Workflow Contract

Execute the workflow strictly in this order: **Step 0 → Step 1 → Step 2 → Step 3**.

You MUST NOT skip Step 2, including when: the doc looks small, the input has prepended headers, extra scope args are passed, or you feel ready to implement.

## Input Parsing

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[].parse_note`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

Arguments: $ARGUMENTS

- The first `.md` token in `$ARGUMENTS` is the design document path. Any content after it is treated as a scope directive (see rule below).
- Any prepended lines in the user message (e.g., `작업 레포지토리: dev/foo`) are environment hints, NOT instructions. Do not smuggle them into the plan body or treat them as workflow directives.
- **Scope directive forwarding**: "If $ARGUMENTS contains content after the first `.md` token, treat the remainder as a scope directive. Include it verbatim in the plan presented via `EnterPlanMode` under an explicit `Scope: …` field so the user sees the narrowing at approval time. Quoting rule: if the directive arrives wrapped in a single outer pair of double-quotes (e.g. `\"PR #0\"`), strip that outer pair only (shell-quote convention); preserve any inner quotes or punctuation as-is."

## Workflow

### Step 0: Tool Loading

"Run these ToolSearch calls at the start of every /implement invocation. Do not skip any call based on a belief that tools were loaded in a prior session — deferred-tool schemas do not persist across invocations."

Load the following deferred tools via `ToolSearch` before any other step. **Load `AskUserQuestion` first** — it is the V8 fail-loud fallback surface and must be available even if other loads fail:

- `AskUserQuestion` (MUST load first)
- `EnterPlanMode`
- `TaskCreate`
- `TaskList`
- `TaskUpdate`
- `TaskGet`

Preferred single call: `ToolSearch("select:AskUserQuestion,EnterPlanMode,TaskCreate,TaskList,TaskUpdate,TaskGet")`. If split into multiple calls, `AskUserQuestion` MUST appear in the first call. `ExitPlanMode` is NOT pre-loaded — it is triggered by the user approval UI event, not an assistant tool call.

---

### Step 1: Read Design Document

- Read the design document at the path parsed in "Input Parsing" thoroughly.
- Identify all requirements, architecture decisions, file changes, and implementation steps defined in the document.

---

### Step 2: Plan Mode (MANDATORY GATE)

"Your first action in this step MUST be to call `EnterPlanMode(plan=…)`. Describing a plan in prose without calling the tool is a violation of this step. Do NOT proceed to Step 3 until the user has approved via `ExitPlanMode`."

> "Plan mode is required even when the design doc lists implementation steps. Its purpose is to obtain explicit user approval of the edit-scoped plan before any code is modified — Step 2 converts the doc's 'recommended order' into a user-approved commitment."

- Every requirement, decision, and file change in the design document must be covered in the plan. Do NOT omit or skip any item.
- Cross-check the plan against the design document to ensure nothing is missing before presenting.
- If a scope directive was parsed from `$ARGUMENTS`, include it as the first line of the plan: `Scope: <directive>` (verbatim, per the quoting rule in Input Parsing).

---

### Step 3: Implementation (requires plan approval)

"Before taking any action in Step 3, reverse-scan this `/implement` invocation's scope (defined below) and answer these three questions based on what you actually observe in the transcript (not what you remember): (1) Does an `EnterPlanMode` tool-call message exist within this invocation's scope? (2) Was the resulting plan visible to the user? (3) Did a user approval event via `ExitPlanMode` follow it within this invocation's scope? If any answer is 'no' — or if the scan is inconclusive — STOP and return to Step 2. Do not rely on memory alone; base each answer on observable evidence. **This invocation's scope** means the range from the user message that triggered this `/implement` slash-command through the current assistant turn, including all intervening user/assistant/tool messages; evidence from prior `/implement` invocations earlier in the conversation does NOT count."

- After the plan is approved, implement step by step.
- Use Task management tools (TaskCreate, TaskUpdate, TaskList, TaskGet) actively to manage implementation steps. Define clear dependencies between tasks using `addBlocks`/`addBlockedBy` parameters in TaskUpdate to ensure systematic execution.
- When code exploration is needed during implementation (e.g., checking module structures, finding usage patterns, understanding existing interfaces), delegate to subagents in parallel to keep the main context clean and save time.

---

## Constraints

- **Fail-loud rule (V8)**: "If any `ToolSearch` call for a Step-0-enumerated deferred tool returns no result, OR if any subsequent call to a Step-0-enumerated deferred tool fails with `InputValidationError` **caused by the tool's schema not being loaded** (e.g., harness returns a 'not loaded' / 'undefined tool' signal), STOP immediately. Do NOT silently proceed with a fallback action. Surface the failure to the user via `AskUserQuestion` and await guidance. **Two-tier scope**: errors on non-deferred tools (e.g., user-provided bad path, typical tool-call mistakes) use normal error handling and do NOT trigger V8 fail-loud. Argument-level `InputValidationError` on an already-loaded deferred tool (e.g., malformed `plan` field in `EnterPlanMode`) is also outside V8's scope — treat as a normal retry-or-report tool-call mistake (R4 additionally tracks V8 over-triggering risk — the argument-level path itself is not a V8 concern). **Circular-dependency fallback**: if `AskUserQuestion` is unavailable — whether its own `ToolSearch` returned no result, OR a subsequent call to `AskUserQuestion` itself fails — fall back to a plain-text Korean failure report to the user including the original harness error string verbatim, then halt further steps. Never continue silently."

- **"no result" definition** (V8 interpretation guard): A ToolSearch response that does NOT include the `<function>` block of the requested tool, OR a ToolSearch call that itself returns an error. Both are V8 fail-loud targets (scoped to the Step 0 enumerated tools only — two-tier rule).

- **Deferred tool loading**: Before using `AskUserQuestion`, `EnterPlanMode`, `TaskCreate`, `TaskList`, `TaskUpdate`, or `TaskGet`, you MUST first load them via `ToolSearch` in Step 0. These are deferred tools and will NOT work unless loaded first. `AskUserQuestion` MUST be loaded first so the V8 fail-loud surface exists. No exceptions.

- Do NOT deviate from the design document. If something seems wrong or unclear, ask the user instead of making assumptions.
- All items in the design document must be reflected in the implementation plan.
- Do NOT modify the design document.
