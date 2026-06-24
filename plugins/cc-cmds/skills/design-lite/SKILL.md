---
name: design-lite
description: 2인 팀을 활용한 경량 설계 토론
when_to_use: 깊은 다관점 분석보다 빠른 방향 설정이 우선될 때 (sonnet 단독 합성으로 미묘한 invariant 누락 가능)
disable-model-invocation: true
usage: "/cc-cmds:design-lite <task>"
options:
    - name: "<task>"
      kind: positional
      required: true
      summary: "설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트)."
---

Conduct a lightweight design discussion using a fixed 2-member sonnet agent team for the given task.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication (interviews, final presentation) and saved documentation should be in Korean.

This skill is the lightweight sibling of `design`. It trades depth for predictable token cost: a fixed 2-member sonnet team replaces the dynamic composition, the discussion runs a 2-round default cap, and refinement-team spawning is disabled. Use `design` when subtle invariants or multi-perspective depth matter more than speed.

## Workflow

### Step 1: Requirements Interview & Codebase Exploration (Korean)

- Do NOT create a team yet. First, interview the user to understand requirements.
- Ask deep, non-obvious questions covering all aspects of the task, including but not limited to: technical implementation, UI/UX, concerns, tradeoffs, scale, constraints, and integration points.
- Avoid generic or superficial questions. Dig into specifics. **Interview length cap: none** — the interview is a 1:1 user↔lead text exchange, not a token-saving axis. Continue until critical aspects are sufficiently covered (matches base `design` behavior).
- Explore the existing codebase as needed during the interview using `grep` and `Read` directly.
- **Verification-first (lite)**: as load-bearing assumptions surface, settle the cheap ones in-session. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the SOT) for the claim taxonomy and the severity/filter tests. Lite scope: categories 1–4 survive (category 4 — behavioral hypothesis — is **one-shot**: a single `/tmp` script, ≤2 attempts per claim, no debugging → inconclusive → residual `검증 차단`); category 3 splits (local probes `--version`/`command -v`/env survive; network facts → residual with a recipe); **category 5 (mini-implementation) is dropped** — emit *"더 깊은 검증이 필요하면 `/cc-cmds:design`을 사용해주세요."* and encode it as a residual item (lossless deferral).
- Iterate between interviewing and codebase exploration until coverage is sufficient, then confirm with the user before proceeding.

### Step 2: Team Composition Proposal (Korean)

- Based on interview results and codebase exploration, propose a **fixed 2-member sonnet team** to the user. Both teammates use model `"sonnet"`. Do NOT propose haiku or opus — sonnet pin is part of the lite contract (quality floor + predictable cost).
- Specify each teammate's role and exploration scope. Common pattern: one teammate covers architecture/data flow and the other covers implementation/testing concerns, but adjust to the task.
- Only create the team after the user approves the composition (single Y/N gate — no iterative re-proposal cycle).

### Step 3: Design Discussion (English, internal only)

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply its spawn, completion-signal, convergence, escalation, and ledger rules throughout this step. When you spawn or resume a member (via `Agent` / `SendMessage` to its `agentId`), embed the **task-assignment header** from `_common/agent-team-protocol.md` **verbatim at the top of the prompt** (the block-quoted instruction under the `## Task-assignment header` heading) — do NOT paraphrase to a one-liner.

- Spawn the approved 2-member team as **nameless background tasks**: for each member call `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. Both members are pinned to model `"sonnet"`. Each prompt must be self-contained (task-assignment header + role/scope + every load-bearing input) — a task does not share the lead's conversation. Derive a `{topic-slug}` for the run (e.g., `auth-flow`, `payment-system`); it is the ledger key and the `docs/{topic-slug}.md` filename.
- **Early ledger stub**: before (or at) the first spawn, create `docs/{topic-slug}.md` as an early stub = an H1 title plus the durable ledger HTML-comment block (`<!-- cc-design-ledger v2 … -->`) placed right after the H1, before the first `##`. Record each member's returned `agentId` in the ledger immediately. Entry schema (per `_common/agent-team-protocol.md`): `agentId | state | round | role/scope | thinReturns | last-return summary | scratchDir`, `state ∈ {running, done, aborted}` (`scratchDir` = the member's out-of-tree witness dir, recorded at spawn, transient — stripped from terminal rows on normal completion, **done and aborted alike**). Before the first spawn also create `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{topic-slug}.XXXXXX")` and record it as each member's `scratchDir`; every Step-3 discussion round is witnessed (`{role-slug}.round-N.md`, sentinel/nonce per the protocol). Refinement is disabled, so there are no later witnessed phases. Update on every state change; **re-read the ledger from disk before any resume**; if the block is missing or unparseable, **fail closed via `AskUserQuestion`** (never silent-skip).
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
- **The lead acts as a facilitator**, actively driving discussion within the round cap.
- **Verification execution budget (categories 2–4)**: **6 units, static 2/2/2 split** (teammate 2 + teammate 2 + lead pre-save sweep 2; self-tracked, reported in the member's return text). 1 unit = one recipe (≤2 attempts included), ≤2 min per unit; on exceed → kill + residual (`잔여 사유: 예산 소진`, the `차단 사유` distinguishing `예산 소진(시간)` from `예산 소진(횟수)`). A timed-out attempt still consumes an attempt. Worst case ≤6 units × 2 min = ≤12 min execution wall-clock. Category 1 (static facts) and local-probe category 3 are read-only, outside the budget (per-attempt limits only: `grep` >50 hits → inconclusive; named-file `Read` only). The `실행 주의` exception classes are structurally excluded in lite even within budget. No dedicated verification agent (the 2×sonnet roster is fixed) — the authors execute + the lead sweeps; "lite does not debug a verification."

#### Discussion Protocol (2 rounds default; hard cap 3)

1. **Round 1 — Initial Proposals**: Spawn each member with its design scope (self-contained prompt). A member's proposal is delivered by its **witness** (`{role-slug}.round-1.md`), not its return text — confirm both members' round-1 witnesses via `witness_present`, then read them (never the return), before proceeding. If a witness is empty or substanceless, apply the protocol's **Case 1** (thin/empty witness: re-scope + resume once; 2nd consecutive → `AskUserQuestion`). If a member never returns, apply **Case 2** (death predicate → `TaskStop` + same-round respawn, new `agentId`, reset `reentry_count`→0/`last_output_bytes`→∅, update ledger).
2. **Quality Gate**: Before cross-review, verify each proposal references concrete files/modules/patterns from the actual codebase and includes design decisions with rationale. If a proposal is too shallow, **resume that member by its `agentId`** with specific deepening questions; an off-contract / malformed return is a **Case 3** non-conforming return (re-assign once, a recurrence feeds the Case 1 counter). **Verification check**: a load-bearing claim must be either verification-recipe-accompanied (settled, with recipe + observed value) or residual-marked; otherwise resume it with the deepening request (the existing send-back path).
3. **Round 2 — Cross-Review**: Resume each member by its `agentId` (re-inject the task-assignment header + **quote the peer's proposal verbatim** as Round-2 input). Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches. Collect both returns.
4. **Convergence Check** (after Round 2): Convergence is by **witness collection** (per `_common/agent-team-protocol.md`) — a member's round is converged-and-collected only when its witness is `witness_present`. Resume each member once with a convergence prompt (re-inject current consensus + open conflicts). If **every member's round witness is `witness_present` and its body says "no further input"**, proceed to Step 4. If a witness names a substantive blocker (concrete unresolved concern, not vacuous), the lead MAY run **one additional round (Round 3)** addressing the named blocker. After Round 3 the team MUST converge regardless — there is no Round 4. **Hard cap = 3 rounds** (each round = at most one resume per member; the resume is the unit of lite's predictable cost — a resume-budget soft-cap under the round hard-cap).

### Step 4: Result Synthesis & Documentation (Korean)

- The lead synthesizes all discussion results into a Korean document. **The 4-section structure is the mandatory floor** (length is unconstrained); two verification sections are added conditionally when present:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 검증 기록 (세션 내 검증을 수행한 경우에 한해 포함; 없으면 생략)
    - 미해결 이슈 / 트레이드오프
    - 구현 시 검증 항목 (잔여 검증 클레임이 있는 경우에 한해 포함; 없으면 생략)
    - 권장 구현 순서
- **`## 검증 기록` / `## 구현 시 검증 항목` sections**: same schema as base `design` (see `_common/verification.md` — the V-ledger and Residual-item contracts). Placement: `## 검증 기록` after `## 주요 결정사항과 근거`, before `## 미해결 이슈 / 트레이드오프`; `## 구현 시 검증 항목` after `## 미해결 이슈 / 트레이드오프`, before `## 권장 구현 순서`. Each is omitted when empty. **Residual markers use the same schema as base** (implement does not know the emitting skill); lite-origin reasons `예산 소진` / `분류 제외` are accepted enum values with no schema extension — a designed cost-contract citation is not lazy deferral. **Field-line rendering** follows base `design`: copy the CANON rendering example in `_common/verification.md` §4/§5 byte-for-byte (bold key `**…**:`, no leading bullet `- `, one ASCII space after the colon) — no self-chosen bullet/bold style.
- **Synthesis terminal**: All teammate clarifications must be completed before saving the design document. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. The sequence save → cleanup → presentation is atomic.
- **Synthesis fidelity pass (base `design` Step 4) is disabled in lite.** The lead proceeds directly from synthesis draft to the pre-save sweep.
- **Lead pre-save sweep (lite)**: before the first save, the lead sweeps the synthesis draft (its 2 budget units) — `**검증 등급**: 미검증` (full-line) + `[검증 등급: 미검증]` (inline tag) document-wide 0, 0 verifiable load-bearing claims without a V/R anchor reference, every `구현 시 검증` item present in the residual encoding, and the two-command boundary gate (`_common/verification.md` §6: main `git status --porcelain` == baseline + `git worktree list --porcelain` 0 `cc-design-exp-` entries). **Sweep-failure path**: a refutation verdict from the sweep is a substantive blocker → route to the existing **Round 3** (blocker-only, within hard cap 3) — no new machinery; the base "failures are never lead-solo" principle is preserved. If Round 3 is already spent, fall back to `AskUserQuestion` with 3 options (accept residual with refutation evidence / redirect to `/cc-cmds:design` / abort).
- Save the design document to the project's `docs/` directory. **File naming convention**: use `docs/{topic-slug}.md` where `{topic-slug}` matches the Step 3 team's topic slug exactly (e.g., team `design-lite-auth-flow` → `docs/auth-flow.md`). The slug-binding follows base `design`'s convention so the filename remains a stable local-state recovery hint.
- Notify the user in Korean: *"설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow it. In the normal path cleanup is a **no-op** (every member self-terminated the moment it returned); on abort, call `TaskStop` on any ledger row still `state=running`; then apply ledger hygiene so no `state=running` row survives (returned → `done`, `TaskStop`-ed → `aborted`).
- **Verification aggregate line**: if the `## 구현 시 검증 항목` section is non-empty, include one Korean line in the presentation — *"구현 시 검증 항목 N건이 기록되었습니다 — /implement 시작 시 우선 검증됩니다."* (same trigger and wording as base; 잔여 0건 → no line).
- Present the results to the user in Korean.
- **Unresolved Issue Walkthrough (base `design` Step 5) is disabled in lite.** Issues in the saved doc transfer directly to Step 5 (refinement) without per-issue walkthrough.

### Step 5: Plan Refinement with User (lead-only)

- Discuss the design document with the user in Korean and refine the plan together.
- Lead-only: doc edits, user Q&A, and codebase re-exploration require no team. **Refinement team spawn is disabled in lite.**
- If the user requests deeper investigation that would normally trigger a refinement team, do NOT spawn one. Instead emit in Korean: *"더 깊은 검토가 필요하면 `/cc-cmds:design`을 사용해주세요."* and continue lead-only refinement on the existing document.
- Repeat until the user is satisfied with the plan.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Sonnet pin**: every teammate uses model `"sonnet"`. Haiku is forbidden; both of `/cc-cmds:design-upgrade`'s reinforcement axes are out of scope here — opus upgrade violates the sonnet pin, and role add/split mutates the fixed 2-member roster (run `/cc-cmds:design-upgrade` against a base `/cc-cmds:design` run instead).
- **In-session verification (lite scope)**: categories 1–4 only (category 4 one-shot; category 5 dropped → residual + `/cc-cmds:design` redirect); execution budget 6 units (2/2/2), ≤2 min/unit, ≤12 min cap; the `실행 주의` exception classes are structurally excluded. Read `${CLAUDE_SKILL_DIR}/../_common/verification.md` for the contract (the fourth `_common` Read).
- **Nameless background sub-agents**: team members ARE `Agent({ subagent_type: "claude", run_in_background: true })` sub-agents, resumed across rounds by `agentId` (`SendMessage` to the agentId). The **retained-context resume loop is required** — do NOT degrade to an isolated one-shot `Agent()` per round (a one-shot per round is not a team).
- **Deferred tool loading**: Before using AskUserQuestion, SendMessage, or TaskStop, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:SendMessage", and "select:TaskStop" to load each tool (`Agent` is built-in — do not load it). AskUserQuestion MUST be loaded before Step 1 (user interview). Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

Task: $ARGUMENTS
