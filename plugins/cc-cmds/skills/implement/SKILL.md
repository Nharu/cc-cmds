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

Execute the workflow strictly in this order: **Step 0 → Step 1 → Step 1.5 → Step 2 → Step 3**.

You MUST NOT skip Step 2, including when: the doc looks small, the input has prepended headers, extra scope args are passed, or you feel ready to implement. Step 1.5 (the write-deferred verification gate) is conditional — it runs only when the document carries a `## 구현 시 검증 항목` section; its absence means no gate, but its presence makes it non-skippable before Step 2.

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

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints from that file to every AskUserQuestion call in this skill.

---

### Step 1: Read Design Document

- Read the design document at the path parsed in "Input Parsing" thoroughly.
- Identify all requirements, architecture decisions, file changes, and implementation steps defined in the document.
- Note whether the document contains a `## 구현 시 검증 항목` section (the residual verification items). Its presence triggers Step 1.5; its absence means there is no verification gate.

---

### Step 1.5: Write-Deferred Verification Gate

This gate runs BEFORE Step 2 (plan mode). It settles the design's residual verification items at the start of implementation, fail-fast, so implementation never builds on a refuted design. Its writes are **deferred to Step 3** (plan mode blocks Edits; see Step 2) — Step 1.5 executes recipes and holds verdicts in memory; the document flip happens only after plan approval. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the `## Residual-item contract`, the drift ladder §7, and the carve-out §6) before this step. If Step 1 found no `## 구현 시 검증 항목` section, skip directly to Step 2.

- **1.5a — Discovery & classification (read-only)**: search for the `## 구현 시 검증 항목` heading. Absent → no gate; skip to Step 2. Enumerate `### R<n>` items; **skip any item already carrying a terminal token** (`검증됨(통과)`/`반증됨(실패)`/`검증불가(드리프트)`), detected with the tolerant `검증 등급` lookup `^(- )?(\*\*검증 등급\*\*|검증 등급): (검증됨\(통과\)|반증됨\(실패\)|검증불가\(드리프트\))$` (`grep -E`, never perl — the balanced-bold idiom of `_common/verification.md` §3.4 with the value arm pinned to the terminal-token set, so a legacy bullet/no-bold flipped item is still recognized as terminal) — idempotency on re-invocation. Partition by `검증 시점` (`구현 전` vs `구현 중(<phase>)`); collect each item's `분류` and `실행 주의` flags. **Scope-directive interaction**: `구현 전` items are gated unconditionally regardless of scope (design validity is global — even a partial implementation rests on a refuted design); a `구현 중` item whose phase is outside the scope is disclosed in the consent batch as "이번 범위 밖 — 미실행" with no `TaskCreate`, leaving its `구현 시 검증` token in place for a later invocation's idempotent 1.5a re-discovery.
- **1.5b — Consent gate (layered; plan-mode semantics "research yes, side effects no" — the design session's consent does NOT carry into implement's pre-approval phase)**: (a)/(b)/(d) read-only-local recipes run without consent. **If any (c) external probe, (e) worktree, or `실행 주의`-flagged item is present, issue ONE batched `AskUserQuestion` before executing** — body *"구현 전 검증 N건 실행 — 외부 probe X건, 워크트리 재현 Y건[, 예외 클래스: …], 예상 소요 …"*, options `실행 / 해당 항목 건너뛰고 위험 수용 / 중단`. An exception-class recipe (flagged, or recognized during read) is **never auto-run**. The consent batch covers **all residual items** regardless of `검증 시점` (a `구현 중` item is disclosed as "phase <p>에서 실행 예정" — closing the gap where a mid-implementation (c)/(e)/execution-caution recipe would otherwise run un-consented); a recipe implement belatedly recognizes as exception-class mid-run gets its own AUQ **immediately before that recipe runs** (for a `구현 중` item, phase arrival is that moment — the recognition fallback). An unflagged recipe is killed at 10 min (or 3× the declared `예상 소요`, whichever is larger; a declared >10 min mandates the execution-caution flag → asked up front).
- **1.5c — Execute, zero document writes**: run per the drift ladder; hold verdicts in memory; write nothing to the document. Capture **both baselines** (`git status --porcelain` + `git worktree list --porcelain`) on entering 1.5c, and gate after each worktree recipe + on exiting 1.5c (the implement-time tree may legitimately be dirty — the gate is "no new change vs. entry", not "clean").
- **1.5d — Failure branch (pre-plan)**: a `반증됨(실패)` / `검증불가(드리프트)` verdict → STOP, report in Korean (주장 / 기대 vs 관측 / the flipped decision from `실패 시 영향`), then `AskUserQuestion` `설계 재수렴 ← 추천 / 위험 수용하고 계속 / 중단` (one surface per issue). On re-converge / abort, **no document write at all** — the verdict moves only as report text (loss-tolerant: the recipe re-runs, so a later session re-derives cheaply; writing a refutation token without approval is the forbidden side effect). implement NEVER redesigns — it only surfaces, and the user routes.

---

### Step 2: Plan Mode (MANDATORY GATE)

"Your first action in this step MUST be to call `EnterPlanMode(plan=…)`. Describing a plan in prose without calling the tool is a violation of this step. Do NOT proceed to Step 3 until the user has approved via `ExitPlanMode`."

> "Plan mode is required even when the design doc lists implementation steps. Its purpose is to obtain explicit user approval of the edit-scoped plan before any code is modified — Step 2 converts the doc's 'recommended order' into a user-approved commitment."

- Every requirement, decision, and file change in the design document must be covered in the plan. Do NOT omit or skip any item.
- Cross-check the plan against the design document to ensure nothing is missing before presenting.
- If a scope directive was parsed from `$ARGUMENTS`, include it as the first line of the plan: `Scope: <directive>` (verbatim, per the quoting rule in Input Parsing).
- **Verdict table in the plan** (the checkpoint of the in-memory verdict window from Step 1.5): include the verbatim verdict table — R-id / current token / verdict-to-record / 1-line observation / waiver marker. Because plan mode blocks Edits, a pre-approval flip is mechanically impossible — this sequencing (execute in 1.5 → table in the plan → batched flip after approval, in Step 3) is the only working form.

---

### Step 3: Implementation (requires plan approval)

"Before taking any action in Step 3, reverse-scan this `/implement` invocation's scope (defined below) and answer these three questions based on what you actually observe in the transcript (not what you remember): (1) Does an `EnterPlanMode` tool-call message exist within this invocation's scope? (2) Was the resulting plan visible to the user? (3) Did a user approval event via `ExitPlanMode` follow it within this invocation's scope? If any answer is 'no' — or if the scan is inconclusive — STOP and return to Step 2. Do not rely on memory alone; base each answer on observable evidence. **This invocation's scope** means the range from the user message that triggered this `/implement` slash-command through the current assistant turn, including all intervening user/assistant/tool messages; evidence from prior `/implement` invocations earlier in the conversation does NOT count."

- **Step 3's first document-write action (after the reverse-scan guard passes, before any other edit): the batched flip write + diff gate.** (The reverse-scan guard retains its literal-first-action status; the flip is the first *edit* after the guard passes.) The write surface is **exactly 2 byte-enumerated forms**, both inside a `### R<n>` of `## 구현 시 검증 항목`:
    - **W1**: locate the R-item's verification-grade line with the tolerant lookup `^(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$` (`grep -E`/`sed -E` only — never perl; the balanced-bold idiom of `_common/verification.md` §3.4 absorbs all four legacy renderings, and being key-anchored to `검증 등급` it does not collide with a `잔여 사유: 구현 시 검증` value line), then rewrite the whole line to the canonical `**검증 등급**: <terminal token>` (bold key, no leading bullet — a legacy bullet/no-bold line converges to CANON on flip; no line creation/deletion).
    - **W2**: append exactly 1 line right after the verification-grade line: `**구현 시 검증 기록**: <YYYY-MM-DD> — <관측>[; 치환: <old>→<new>[, …]][; 사용자 위험 수용]`.
    - **diff gate** (snapshot-based, once after the batch): copy the pre-flip document to a temp snapshot (`SNAP=$(mktemp)` + `cp <doc> "$SNAP"`) → apply the batched W1/W2 → every content line (`±`; excluding the file headers `---`/`+++`) of `diff -U0 "$SNAP" <doc>` must match one of (`grep -E`, never perl): `^-(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$` (removed side **tolerant** — diff dash-doubling `(- )?` plus all four legacy renderings, so flipping a legacy bullet/no-bold line is not a false-fail) / `^\+\*\*검증 등급\*\*: (검증됨\(통과\)|반증됨\(실패\)|검증불가\(드리프트\))$` (added grade, **strict-canonical** — bold·non-bullet enforced; the 3 legacy renderings, `미검증`, and the un-flipped value are all rejected) / `^\+\*\*구현 시 검증 기록\*\*: .*$` (added note, strict-canonical). Any other changed line → revert **only this batch's non-matching changes** against the snapshot + fail-loud. **Per-flagged-item non-empty-diff assertion**: for every R-item the verdict table marked as a flip target, that item's `검증 등급` line MUST appear as a changed line in the diff — a silent no-op flip (empty diff) on a flagged item is a fail-loud, structurally blocking the vacuous pass (a 1.5a-skipped already-terminal item is not a flip target, so an idempotent re-run with an empty target set and empty diff passes). A `git diff` against HEAD is FORBIDDEN — it vacuous-passes on an untracked document and risks false-failing / destroying the user's uncommitted edits on a dirty document (the implement-time tree may legitimately be dirty — same premise as 1.5c).
- **Drift ladder (3-rung + flake pre-classification)** (the contract is `_common/verification.md` §7): Rung 1 — verbatim execution; **an observation contradicting the expectation is a FAIL, not drift**. An external-category recipe's transient failure gets one retry, then Rung 3 (synthesize the `관측 시점` timestamp + `유효 조건`). Rung 2 — bounded re-derivation: **location identifiers only** (file path / line number / directory name), each substitution requiring mechanical evidence (a verbatim hit at the new location, or a rename visible via `git log --follow`); any change to claim text / predicate / expected result → Rung 3; **one adaptation pass only** (an adapted recipe that then fails to run → Rung 3). The substitution map (old→new) is recorded on the W2 line; the full adapted recipe stays in implement's plan/log (outside the document). Rung 3 — report-never-skip: `검증불가(드리프트)` + cause, the same failure surface as a refutation.
- **`구현 중` items**: an explicit line in the Step 2 plan (at that phase's head) + a `TaskCreate` in Step 3 with `addBlocks` on every task that builds on the claim — the dependency graph is the enforcement of mid-implementation fail-fast. A mid-implementation flip write (W1/W2) passes the same snapshot-diff gate per-write (snapshot just before the flip → flip → check — time-invariant, identical application). **Mid-implementation failure semantics** (1.5d's pre-plan premise does not apply — this is post-approval, so write-deferral is unnecessary): record the flip (W1/W2 + gate) immediately, report in Korean + the same 3-option AUQ. On `설계 재수렴`, the dependent blocked tasks stay blocked while completed work is preserved and the design is routed to refinement; completed tasks are structurally claim-independent (the addBlocks graph blocks any claim-dependent task from running first) — state this in the report.
- **No new deferred tools** (Bash + the AskUserQuestion already loaded in Step 0).
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
- Do NOT modify the design document. **Exception — the verification write surface**: the document reserves exactly two write forms for implement, both inside a `### R<n>` of `## 구현 시 검증 항목` — W1 (flip `**검증 등급**: 구현 시 검증` to a terminal token) and W2 (append one `**구현 시 검증 기록**:` line) — applied via the Step 3 batched flip + snapshot-diff gate. No other byte of the document may change. This keeps the literal "do not modify" rule and enumerates W1/W2 as the document's implement-reserved surface (sweep-proof by pattern, not trust).
