---
name: design-apply
description: Claude Design (claude.ai/design) 산출물을 타깃 코드베이스에 통합하는 구현 상세 설계를 agent team으로 작성
when_to_use: design-ingest가 ACCEPT한 핸드오프 추출본을 기반으로 실제 코드베이스에 적용할 구현 상세 설계(impl-design.md)가 필요할 때
disable-model-invocation: true
usage: "/cc-cmds:design-apply <handoff-extract-path>"
options:
    - name: "<handoff-extract-path>"
      kind: positional
      required: true
      summary: "design-ingest가 확정한 안정 사본 (`docs/{slug}-fe/handoff-extract.md`); 본 스킬이 slug 파싱·팀명 조립·cleanup 복구의 단일 앵커"
---

Author the implementation-detail design document `docs/{slug}-fe/impl-design.md` that bridges Claude Design's HTML prototype to actual code in the target stack. This is a **lightweight sibling of `/cc-cmds:design`** — it reuses the same agent-team protocol (`_common/agent-team-protocol.md`) and cleanup machinery (`_common/team-cleanup.md`) but skips the Step 1 greenfield interview because its inputs are concrete (the design-ingest extract + base design document + DS workspace + codebase).

The decisions in scope are component mapping (HTML prototype → codebase components), state management, routing, file layout, token/component usage rules (DS-copy vs `var()`-reference based on the pattern design-ingest detected), and test strategy. These are design judgments the downstream `/cc-cmds:implement` would refuse to make ("don't deviate from the design document") — so they belong here, in a markdown design output that `/cc-cmds:design-review` can then audit.

All team discussion and inter-agent communication is in English to optimize token usage. User-facing communication (proposal, presentation) and the saved `impl-design.md` are in Korean.

## Input parsing and slug recovery

- Extract `{slug}` from `<handoff-extract-path>`. The path must match `docs/{slug}-fe/handoff-extract.md` exactly. On any other shape emit Korean error: *"입력 경로는 `docs/<slug>-fe/handoff-extract.md` 형식이어야 합니다."* and end.
- The `{slug}` is the recovery anchor for two purposes:
    - **Team naming**: the agent team is created as `design-apply-{slug}` (e.g., `design-apply-profile-settings`). This name is reconstructable from the input path on every invocation without any in-session memory — required by `_common/team-cleanup.md`'s lead-memory-free cleanup contract.
    - **Output path**: `docs/{slug}-fe/impl-design.md` (fixed name; cleanup recovery uses the input-path slug, not this output, since the output may not exist yet on first invocation).

## Step 1: Concrete-input context gathering (Korean)

Unlike `/cc-cmds:design`, **do NOT run a greenfield requirements interview**. The inputs are concrete:

- Read `<handoff-extract-path>` (the design-ingest stable extract).
- Read `docs/{slug}.md` (the base design document — both the original base sections and the "Claude Design 프롬프트 + 컨텍스트" section authored by `/cc-cmds:design-prompt`).
- Read `docs/design-system/{tokens.md, components.md, manifest.json}` (DS reference). Token semantics, component contracts, current DS version.
- Read the archived bundle at `docs/{slug}-fe/handoff/iter-<latest>/bundle/` if needed for primary HTML + component JSX details — the parser-extracted summary is in `handoff-extract.md`, but the bundle is authoritative for visual/structural fidelity questions.
- Explore the target codebase with `find` / `grep` (and Read) to identify existing component patterns, stack (React/Vue/web-components/etc.), routing approach, state management, file layout conventions, and test setup. Use Claude Context MCP for broad searches if the codebase is indexed; otherwise raw grep/find.

If ambiguous points remain after this concrete-input gathering, use `AskUserQuestion` for **narrow, targeted interviews** — one or two questions per topic only. Do not enumerate categories or open the interview wide. The discriminator vs `/cc-cmds:design`: the input alone resolves most questions; only edge cases need user input.

When the context is sufficient, confirm with the user briefly before proceeding to team composition.

## Step 2: Team composition proposal (Korean)

Propose a 2-teammate team to the user, both `opus`. Typical roles:

- **FE Integration Architect** (opus): owns codebase integration — component mapping, state management, routing, file layout. Reads existing components to find reuse opportunities.
- **DS Fidelity Reviewer** (opus): owns token/component fidelity — verifies the impl-design respects the DS-copy vs `var()`-reference pattern detected by design-ingest, calls out divergence risk, audits state coverage and accessibility-from-DS-semantics carrying through.

Adjust roles based on the feature's character (e.g., if the feature is data-heavy, replace one role with a Data Flow specialist). Only create the team after the user approves the composition.

## Step 3: Implementation-design discussion (English, internal)

**Before assigning any team work, `Read ${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step. When you assign work to each teammate via `SendMessage`, include the Teammate Rules block from `_common/agent-team-protocol.md` **verbatim in the assignment body** (the block-quoted teammate-facing instruction under the `## Teammate Rules` heading) — do NOT paraphrase to a one-liner.

- Create the team with the approved composition. Team name: **`design-apply-{slug}`** (e.g., `design-apply-profile-settings`).
- All inter-agent discussion in English.
- **NO code modifications.** This is a design step that produces `impl-design.md` only.
- Lead acts as facilitator, driving multi-round discussion.

### Discussion protocol (minimum 2 full rounds)

1. **Round 1 — Initial Proposals**: Assign each teammate their scope (FE Integration Architect → component mapping + state + routing + file layout proposal; DS Fidelity Reviewer → token/component usage rules + accessibility-preservation strategy + test strategy proposal). Wait for ALL teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, apply the facilitator counter / hard prompt rules from `_common/agent-team-protocol.md`.
2. **Quality gate**: Verify each proposal references specific files/modules/patterns from the actual codebase (not generic advice) and includes concrete design decisions with rationale. Send shallow proposals back with specific deepening questions.
3. **Round 2 — Cross-Review**: Send each teammate's proposal to the other for review. Identify gaps, risks, contradictions, and alternative approaches. Wait for `[COMPLETE]` from both.
4. **Round 3+ — Refinement (as needed)**: Collect cross-review feedback and forward to the original authors. Repeat until convergence.
5. **Convergence Check**: Use the convergence-check template from `_common/agent-team-protocol.md`. Only proceed to Step 4 when BOTH teammates confirm `[COMPLETE] No further input` via `SendMessage`.

### Decisions in scope

- **Component mapping**: which Claude Design prototype components map to which codebase components (existing or new); when to extract a new shared component vs inline; how to translate JSX from the bundle into the target stack's idiom.
- **State management**: where each component's state lives (local / context / global store / URL); data flow for forms and interactions in the prototype.
- **Routing**: how the bundle's `pages[]` (with their `route` fields) integrate into the codebase's routing approach.
- **File layout**: where new files land (component directories, hooks, utils, styles); naming conventions; the boundary between feature-local and shared code.
- **Token / component usage rules**:
    - **Case (a) DS-copy-bundled**: do we vendor the DS `.css` into the codebase per-feature, or reference the canonical `docs/design-system/tokens.css` from a central place? How do we propagate DS version updates?
    - **Case (b) `var()`-reference-only**: how is the DS CSS loaded in the codebase to make `var(--name)` references resolvable? Is it a global stylesheet, a token-only module, or a CSS-in-JS provider?
    - Either case: how do we prevent feature code from re-declaring `:root` blocks (the contract from the paste prompt — `var()`-only).
- **Test strategy**: if the project has Jest / Vitest / Playwright / RTL, propose specific test files and scenarios (unit tests for new components, integration tests for flows, accessibility snapshots if applicable). If the project has no test setup, note the absence and propose a scoped addition only if the user signals it's wanted (do NOT push a test framework on a project that lacks one).
- **Color-space normalization** (deferred from `design-ingest`): if `tokens.css` carries `oklch(...)` values and the target stack's tooling doesn't support oklch, propose the conversion approach (browser support fallback, build-time conversion, hex/rgb fallback values).

### MCP usage

- **Sequential Thinking MCP** is permitted but not required for this skill.
- **Claude Context MCP** for broad codebase queries is permitted; lite-tier MCP restrictions do not apply (this skill is in the heavy-tier alongside `/design`).
- **context7 MCP** for target-stack documentation lookups is appropriate when the team is making decisions about specific library APIs (e.g., React Router patterns, Zustand store shape).

## Step 4: Synthesis and documentation (Korean)

- Lead synthesizes the discussion results into `docs/{slug}-fe/impl-design.md`. The document follows the standard 4-section Korean structure:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 미해결 이슈 / 트레이드오프
    - 권장 구현 순서
- Pin the DS manifest version at the top of the file via HTML comment: `<!-- DS manifest version (consumed by design-apply): <version> -->`. This is the version used during this design synthesis; `/cc-cmds:implement` reads it on next invocation to detect drift between design and implementation.
- **Synthesis terminal**: All teammate clarifications must be completed before saving `impl-design.md`. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. The sequence **save → cleanup → presentation** is atomic. Do NOT save a partial document, send a teammate message, then save again; clarify before the first save.
- Notify the user in Korean: *"적용 설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, `Read ${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure to clean up the `design-apply-{slug}` team. The cleanup recovery anchor is the `{slug}` parsed from the input path in "Input parsing and slug recovery" above — `_common/team-cleanup.md`'s idempotency guards use this to safely no-op if cleanup already ran.
- Present the results to the user in Korean.

## Step 5: Korean next-step emit

> "적용 설계 작성 완료: `docs/{slug}-fe/impl-design.md` (기준 DS 버전: `<version>`).
>
> 다음 단계: `/cc-cmds:design-review docs/{slug}-fe/impl-design.md`로 구현 세부 사항을 검증한 뒤, `/cc-cmds:implement docs/{slug}-fe/impl-design.md`로 구현을 시작하세요."

Substitute `{slug}` and `<version>` with actual values.

## DS drift detection

At Step 1, after Reading `manifest.json`, compare the live `manifest.json.version` with the version pinned in `<handoff-extract-path>` (the design-ingest extract carries a `<!-- DS manifest version (live at ingest): <X> -->` comment). If they differ, emit a Korean warning in Step 1's confirmation message:

> "⚠️ DS 버전 변경 감지: design-ingest 시점 `<old>` → 현재 `<new>`. 적용 설계는 현재 DS를 기준으로 합니다. 이전 DS와의 차이가 클 경우 design-ingest 재실행을 고려하세요."

Do not block; the user decides. The team in Step 3 makes integration decisions against the current DS regardless.

## Lightweight-sibling rationale (no `## Control-Flow Invariants` heading needed)

This skill is an agent-team workflow (like `/cc-cmds:design` and `/cc-cmds:review`). Its termination contract lives in `_common/team-cleanup.md` — the 5-step shutdown procedure with idempotency guards. There is no in-session bash-variable termination formula at the SKILL.md level, so the skill is EXEMPT from `lint-skill-invariants.sh` rule (A) on the same grounds as `design`, `design-lite`, `review`, and `review-lite` (all currently exempt). The slug-from-input-path recovery key makes this exemption safe across interrupted runs.

## Constraints

- NO code modifications outside the saved `docs/{slug}-fe/impl-design.md`. The team discusses and the lead writes the design document; no source code is touched.
- Inter-agent communication must be in English.
- User-facing communication and the saved document in Korean.
- Agent Team required: `TeamCreate` + `SendMessage` only. Do NOT substitute with isolated `Agent()` sub-agents for the discussion. (The Step 1 codebase exploration can use `Agent()` for parallel searches; only the Step 3 design discussion is constrained to TeamCreate.)
- **Deferred tool loading**: Before using `AskUserQuestion`, `TeamCreate`, `SendMessage`, or `TeamDelete`, you MUST load them via `ToolSearch`. Run `ToolSearch` with queries `select:AskUserQuestion`, `select:TeamCreate`, `select:SendMessage`, and `select:TeamDelete` to load each tool. `AskUserQuestion` MUST be loaded before Step 1 (the optional narrow interview). Before calling `AskUserQuestion`, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

Handoff extract path: $ARGUMENTS
