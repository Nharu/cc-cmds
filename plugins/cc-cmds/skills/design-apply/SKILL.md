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
      summary: "design-ingest가 확정한 안정 사본 (`docs/{slug}-fe/handoff-extract.md`); 본 스킬이 slug 파싱·출력 경로·원장 키의 단일 앵커"
---

Author the implementation-detail design document `docs/{slug}-fe/impl-design.md` that bridges Claude Design's HTML prototype to actual code in the target stack. This is a **lightweight sibling of `/cc-cmds:design`** — it reuses the same agent-team protocol (`_common/agent-team-protocol.md`) and cleanup machinery (`_common/team-cleanup.md`) but skips the Step 1 greenfield interview because its inputs are concrete (the design-ingest extract + base design document + DS workspace + codebase).

The decisions in scope are component mapping (HTML prototype → codebase components), state management, routing, file layout, token/component usage rules (DS-copy vs `var()`-reference based on the pattern design-ingest detected), and test strategy. These are design judgments the downstream `/cc-cmds:implement` would refuse to make ("don't deviate from the design document") — so they belong here, in a markdown design output that `/cc-cmds:design-review` can then audit.

All team discussion and inter-agent communication is in English to optimize token usage. User-facing communication (proposal, presentation) and the saved `impl-design.md` are in Korean.

## Input parsing and slug recovery

- Extract `{slug}` from `<handoff-extract-path>`. The path must match `docs/{slug}-fe/handoff-extract.md` exactly. On any other shape emit Korean error: *"입력 경로는 `docs/<slug>-fe/handoff-extract.md` 형식이어야 합니다."* and end.
- The `{slug}` serves two single-purpose roles, both reconstructable from the input path on every invocation without any in-session memory:
    - **Output path**: `docs/{slug}-fe/impl-design.md` (fixed name).
    - **Ledger key**: the slug locates that output doc, whose HTML-comment ledger holds the agentId roster used for resume and cleanup recovery (see `_common/agent-team-protocol.md`'s Role↔agentId ledger v3). agentId recovery comes from the ledger — there is no harness team name in this model.

## Step 1: Concrete-input context gathering (Korean)

Unlike `/cc-cmds:design`, **do NOT run a greenfield requirements interview**. The inputs are concrete:

- Read `<handoff-extract-path>` (the design-ingest stable extract).
- Read `docs/{slug}.md` (the base design document — both the original base sections and the "Claude Design 프롬프트 + 컨텍스트" section authored by `/cc-cmds:design-prompt`).
- Read `docs/design-system/{tokens.md, components.md, manifest.json}` (DS reference). Token semantics, component contracts, current DS version.
- Read the archived bundle at `docs/{slug}-fe/handoff/iter-<latest>/bundle/` if needed for primary HTML + component JSX details — the parser-extracted summary is in `handoff-extract.md`, but the bundle is authoritative for visual/structural fidelity questions.
- Explore the target codebase with `find` / `grep` (and Read) to identify existing component patterns, stack (React/Vue/web-components/etc.), routing approach, state management, file layout conventions, and test setup.

If ambiguous points remain after this concrete-input gathering, use `AskUserQuestion` for **narrow, targeted interviews** — one or two questions per topic only. Do not enumerate categories or open the interview wide. The discriminator vs `/cc-cmds:design`: the input alone resolves most questions; only edge cases need user input.

When the context is sufficient, confirm with the user briefly before proceeding to team composition.

## Step 2: Team composition proposal (Korean)

Propose a 2-teammate team to the user, both `opus`. Typical roles:

- **FE Integration Architect** (opus): owns codebase integration — component mapping, state management, routing, file layout. Reads existing components to find reuse opportunities.
- **DS Fidelity Reviewer** (opus): owns token/component fidelity — verifies the impl-design respects the DS-copy vs `var()`-reference pattern detected by design-ingest, calls out divergence risk, audits state coverage and accessibility-from-DS-semantics carrying through.

Adjust roles based on the feature's character (e.g., if the feature is data-heavy, replace one role with a Data Flow specialist). Only spawn the team after the user approves the composition.

## Step 3: Implementation-design discussion (English, internal)

**Before assigning any team work, `Read ${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply its spawn / completion-signal / resume / convergence / escalation rules throughout this step. When you spawn or resume a member, embed the **task-assignment header** from that file **verbatim at the top of the prompt** (the block-quoted self-contained header under the `## Task-assignment header` heading) — do NOT paraphrase to a one-liner.

- **Early ledger stub**: before the first spawn, create the output doc `docs/{slug}-fe/impl-design.md` as a stub — its H1 title plus the ledger HTML-comment block `<!-- cc-design-ledger v3 … -->` placed right after the H1 and before the first `##`, per `_common/agent-team-protocol.md`'s Role↔agentId ledger v3. Entry schema is defined once in that ledger v3 (`state ∈ {running, done, aborted}`; the transient per-row `scratchDir` / `outputFile` / `stallMark` / `witnessNonce` are stripped from terminal rows on normal completion, **done and aborted alike**; `scratchDir` = the member's out-of-tree witness dir, recorded at spawn). This ledger comment CO-EXISTS with the DS-manifest-version HTML comment added at Step 4 (both are HTML comments near the doc top; they do not conflict — keep both). Update the ledger on every state change; re-read it from disk before any resume; if it is missing or unparseable — **or a `state=running` row carries no `witnessNonce`, or the non-aborted rows are in partial `epoch` presence** — fail closed via `AskUserQuestion` (never silent-skip; the nonce-absence and partial-`epoch` conditions mirror the protocol's derive-from-ledger fail-close so a legacy pre-v3 ledger has a local safety net — uniform `epoch` absence is **not** a fail-close, it is this skill's normal single-team shape routed to the epoch-agnostic roster).
- Spawn each approved member as a nameless background task: `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. Record each returned `agentId` in the ledger immediately. **Stamp the round-1 `witnessNonce`** on every one of its rows in the same at-spawn recording window as `agentId`/`scratchDir`, per the protocol Spawn section — no `epoch` stamp, since a single-team skill is uniform-`epoch`-absence handled by the roster's mode-(ii) epoch-agnostic path. The slug names the output path and ledger key only — there is no harness team name.
- **Witness scratch dir (parameters for `_common/agent-team-protocol.md`)**: before the first spawn, create `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{slug}.XXXXXX")` and record it as each member's `scratchDir` (same immediacy as `agentId`). Every Step-3 discussion round is witnessed (`{role-slug}.round-N.md`, sentinel/nonce per the protocol). The witness dir is out-of-tree, leaving the boundary gate untouched.
- All inter-agent discussion in English.
- **NO code modifications.** This is a design step that produces `impl-design.md` only.
- Lead acts as facilitator, driving the multi-round resume-based discussion.

### Discussion protocol (minimum 2 full rounds)

1. **Round 1 — Initial Proposals**: Spawn each member with their scope (FE Integration Architect → component mapping + state + routing + file layout proposal; DS Fidelity Reviewer → token/component usage rules + accessibility-preservation strategy + test strategy proposal). Each member's proposal is delivered by its **witness**, not its return text — confirm each member's round-1 witness via `witness_present`, then read the witness (never the return), before proceeding. If a witness is empty or substanceless, apply Case 1 (thin/empty witness) escalation from `_common/agent-team-protocol.md`; if a member never returns, apply Case 2 (per the reconcile ladder).
2. **Quality gate**: Verify each proposal references specific files/modules/patterns from the actual codebase (not generic advice) and includes concrete design decisions with rationale. Resume any member whose proposal is shallow or off-contract (Case 3 re-assign once) with specific deepening questions.
3. **Round 2 — Cross-Review**: Resume each member by `agentId`, re-injecting the peer's proposal **verbatim**. Identify gaps, risks, contradictions, and alternative approaches. Confirm each member's round-2 witness via `witness_present`, then read it (never the return) before assembling the cross-review consensus.
4. **Round 3+ — Refinement (as needed)**: Resume the original authors with the cross-review feedback re-injected verbatim. Confirm each member's refinement witness via `witness_present`, then read it (never the return) before assessing convergence. Repeat until convergence.
5. **Convergence Check**: Resume each member once with a convergence prompt (re-inject current consensus + open conflicts). When every member's round witness is `witness_present` and its witness body says "no further input", the team has converged — proceed to Step 4.

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

- **context7 MCP** for target-stack documentation lookups is appropriate when the team is making decisions about specific library APIs (e.g., React Router patterns, Zustand store shape).

## Step 4: Synthesis and documentation (Korean)

- Lead synthesizes the discussion results into `docs/{slug}-fe/impl-design.md`. The document follows the standard 4-section Korean structure:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 미해결 이슈 / 트레이드오프
    - 권장 구현 순서
- Pin the DS manifest version at the top of the file via HTML comment: `<!-- DS manifest version (consumed by design-apply): <version> -->`. This is the version used during this design synthesis; `/cc-cmds:implement` reads it on next invocation to detect drift between design and implementation. This DS-version comment co-exists with the `cc-design-ledger` HTML comment created at Step 3 — both sit near the doc top and do not conflict; keep both.
- **Synthesis terminal**: All teammate clarifications must be completed before saving `impl-design.md`. Once the file is saved, the synthesis phase is over — no further teammate resumes are permitted. The sequence **save → cleanup → presentation** is atomic. Do NOT save a partial document, resume a member, then save again; clarify before the first save.
- Notify the user in Korean: *"적용 설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, `Read ${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and apply it. In Model B cleanup is inherently idempotent: normal completion is a **no-op** (every returned member has already self-terminated), abort calls `TaskStop` on any ledger `state=running` agentId, and **ledger hygiene** updates rows to `done`/`aborted` so no `state=running` row survives. Recover agentIds by re-reading the output doc's HTML-comment ledger from disk — not from any harness team name.
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

This skill is an agent-team workflow (like `/cc-cmds:design` and `/cc-cmds:review`). Its termination contract lives in `_common/team-cleanup.md` — members self-terminate on return, so cleanup is an idempotent no-op / `TaskStop` / ledger-hygiene check (no shutdown handshake). There is no in-session bash-variable termination formula at the SKILL.md level, so the skill is EXEMPT from `lint-skill-invariants.sh` rule (A) on the same grounds as `design`, `design-lite`, `review`, and `review-lite` (all currently exempt). The output doc's HTML-comment ledger (re-read from disk) provides agentId recovery across interrupted runs.

## Constraints

- NO code modifications outside the saved `docs/{slug}-fe/impl-design.md`. The team discusses and the lead writes the design document; no source code is touched.
- Inter-agent communication must be in English.
- User-facing communication and the saved document in Korean.
- **Nameless background-task team**: the Step 3 design discussion members ARE nameless `Agent` background sub-agents (`subagent_type: "claude"`, no `name`, `run_in_background: true`), resumed across rounds by `agentId`. The retained-context, multi-round cross-review/convergence resume loop is required — do NOT collapse it into one-shot isolated `Agent()` calls per round. (The Step 1 codebase exploration may also use `Agent()` for parallel searches.)
- **Deferred tool loading**: Before using `AskUserQuestion`, `SendMessage`, or `TaskStop`, you MUST load them via `ToolSearch`. Run `ToolSearch` with queries `select:AskUserQuestion`, `select:SendMessage`, and `select:TaskStop` to load each tool. `Agent` is a built-in tool and needs no loading. `AskUserQuestion` MUST be loaded before Step 1 (the optional narrow interview). Before calling `AskUserQuestion`, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

Handoff extract path: $ARGUMENTS
