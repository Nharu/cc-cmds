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
- Explore the existing codebase as needed during the interview using `grep` and `Read` directly. **Do NOT use Claude Context MCP** (`index_codebase` / `search_code`) — lite skills avoid heavy MCP calls for predictable cost.
- **Verification-first (lite)**: as load-bearing assumptions surface, settle the cheap ones in-session. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the SOT) for the claim taxonomy and the severity/filter tests. Lite scope: categories 1–4 survive (category 4 — behavioral hypothesis — is **one-shot**: a single `/tmp` script, ≤2 attempts per claim, no debugging → inconclusive → residual `검증 차단`); category 3 splits (local probes `--version`/`command -v`/env survive; network facts → residual with a recipe); **category 5 (mini-implementation) is dropped** — emit *"더 깊은 검증이 필요하면 `/cc-cmds:design`을 사용해주세요."* and encode it as a residual item (lossless deferral).
- Iterate between interviewing and codebase exploration until coverage is sufficient, then confirm with the user before proceeding.

### Step 2: Team Composition Proposal (Korean)

- Based on interview results and codebase exploration, propose a **fixed 2-member sonnet team** to the user. Both teammates use model `"sonnet"`. Do NOT propose haiku or opus — sonnet pin is part of the lite contract (quality floor + predictable cost).
- Specify each teammate's role and exploration scope. Common pattern: one teammate covers architecture/data flow and the other covers implementation/testing concerns, but adjust to the task.
- Only create the team after the user approves the composition (single Y/N gate — no iterative re-proposal cycle).

### Step 3: Design Discussion (English, internal only)

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step. When you assign work to each teammate via SendMessage, include the Teammate Rules block from `_common/agent-team-protocol.md` **verbatim in the assignment body** (the block-quoted teammate-facing instruction under the `## Teammate Rules` heading) — do NOT paraphrase to a one-liner.

- Create the team with the approved 2-member composition. Name it `design-lite-{topic-slug}` (e.g., `design-lite-auth-flow`, `design-lite-payment-system`).
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
- **The lead acts as a facilitator**, actively driving discussion within the round cap.
- **Sequential Thinking MCP**: do NOT use. The lite skill avoids it for predictable cost.
- **Claude Context MCP**: do NOT use (`search_code` is unavailable to teammates in this workflow). Teammates rely on `grep` + `Read` only.
- **Verification execution budget (categories 2–4)**: **6 units, static 2/2/2 split** (teammate 2 + teammate 2 + lead pre-save sweep 2; self-tracked, reported in `[COMPLETE]`). 1 unit = one recipe (≤2 attempts included), ≤2 min per unit; on exceed → kill + residual (`잔여 사유: 예산 소진`, the `차단 사유` distinguishing `예산 소진(시간)` from `예산 소진(횟수)`). A timed-out attempt still consumes an attempt. Worst case ≤6 units × 2 min = ≤12 min execution wall-clock. Category 1 (static facts) and local-probe category 3 are read-only, outside the budget (per-attempt limits only: `grep` >50 hits → inconclusive; named-file `Read` only). The `실행 주의` exception classes are structurally excluded in lite even within budget. No dedicated verification agent (the 2×sonnet roster is fixed) — the authors execute + the lead sweeps; "lite does not debug a verification."

#### Discussion Protocol (2 rounds default; hard cap 3)

1. **Round 1 — Initial Proposals**: Assign each teammate their design scope. Wait for BOTH teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, follow the facilitator counter / hard prompt rules from `_common/agent-team-protocol.md`.
2. **Quality Gate**: Before cross-review, verify each proposal references concrete files/modules/patterns from the actual codebase and includes design decisions with rationale. If a proposal is too shallow, send it back with specific deepening questions. **Verification check**: a load-bearing claim must be either verification-recipe-accompanied (settled, with recipe + observed value) or residual-marked; otherwise send it back (the existing send-back path).
3. **Round 2 — Cross-Review**: Send each teammate's proposal to the other for review. Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches. Wait for `[COMPLETE]` from both.
4. **Convergence Check** (after Round 2): Use the convergence-check template from `_common/agent-team-protocol.md`. If BOTH teammates respond `[COMPLETE] No further input` via SendMessage, proceed to Step 4. If one or both return `[IN PROGRESS]` with a substantive blocker (concrete unresolved concern, not vacuous), the lead MAY run **one additional round (Round 3)** addressing the named blocker. After Round 3 the team MUST converge to `[COMPLETE]` regardless — there is no Round 4. **Hard cap = 3 rounds.**

### Step 4: Result Synthesis & Documentation (Korean)

- The lead synthesizes all discussion results into a Korean document. **The 4-section structure is the mandatory floor** (length is unconstrained); two verification sections are added conditionally when present:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 검증 기록 (세션 내 검증을 수행한 경우에 한해 포함; 없으면 생략)
    - 미해결 이슈 / 트레이드오프
    - 구현 시 검증 항목 (잔여 검증 클레임이 있는 경우에 한해 포함; 없으면 생략)
    - 권장 구현 순서
- **`## 검증 기록` / `## 구현 시 검증 항목` sections**: same schema as base `design` (see `_common/verification.md` — the V-ledger and Residual-item contracts). Placement: `## 검증 기록` after `## 주요 결정사항과 근거`, before `## 미해결 이슈 / 트레이드오프`; `## 구현 시 검증 항목` after `## 미해결 이슈 / 트레이드오프`, before `## 권장 구현 순서`. Each is omitted when empty. **Residual markers use the same schema as base** (implement does not know the emitting skill); lite-origin reasons `예산 소진` / `분류 제외` are accepted enum values with no schema extension — a designed cost-contract citation is not lazy deferral.
- **Synthesis terminal**: All teammate clarifications must be completed before saving the design document. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. The sequence save → cleanup → presentation is atomic.
- **Lead pre-save sweep (lite)**: before the first save, the lead sweeps the synthesis draft (its 2 budget units) — `**검증 등급**: 미검증` (full-line) + `[검증 등급: 미검증]` (inline tag) document-wide 0, 0 verifiable load-bearing claims without a V/R anchor reference, every `구현 시 검증` item present in the residual encoding, and the two-command boundary gate (`_common/verification.md` §6: main `git status --porcelain` == baseline + `git worktree list --porcelain` 0 `cc-design-exp-` entries). **Sweep-failure path**: a refutation verdict from the sweep is a substantive blocker → route to the existing **Round 3** (blocker-only, within hard cap 3) — no new machinery; the base "failures are never lead-solo" principle is preserved. If Round 3 is already spent, fall back to `AskUserQuestion` with 3 options (accept residual with refutation evidence / redirect to `/cc-cmds:design` / abort).
- Save the design document to the project's `docs/` directory. **File naming convention**: use `docs/{topic-slug}.md` where `{topic-slug}` matches the Step 3 team's topic slug exactly (e.g., team `design-lite-auth-flow` → `docs/auth-flow.md`). The slug-binding follows base `design`'s convention so the filename remains a stable local-state recovery hint.
- Notify the user in Korean: *"설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure to clean up the design team.
- **Verification aggregate line**: if the `## 구현 시 검증 항목` section is non-empty, include one Korean line in the presentation — *"구현 시 검증 항목 N건이 기록되었습니다 — /implement 시작 시 우선 검증됩니다."* (same trigger and wording as base; 잔여 0건 → no line).
- Present the results to the user in Korean.
- **Unresolved Issue Walkthrough (base `design` Step 5) is disabled in lite.** Issues in the saved doc transfer directly to Step 5 (refinement) without per-issue walkthrough.

### Step 5: Plan Refinement with User (lead-only)

- Discuss the design document with the user in Korean and refine the plan together.
- Lead-only: doc edits, user Q&A, and codebase re-exploration require no team. **Refinement team spawn (`-refine-N`) is disabled in lite.**
- If the user requests deeper investigation that would normally trigger a refinement team, do NOT spawn one. Instead emit in Korean: *"더 깊은 검토가 필요하면 `/cc-cmds:design`을 사용해주세요."* and continue lead-only refinement on the existing document.
- Repeat until the user is satisfied with the plan.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Sonnet pin**: every teammate uses model `"sonnet"`. Haiku is forbidden; both of `/cc-cmds:design-upgrade`'s reinforcement axes are out of scope here — opus upgrade violates the sonnet pin, and role add/split mutates the fixed 2-member roster (run `/cc-cmds:design-upgrade` against a base `/cc-cmds:design` run instead).
- **No Sequential Thinking MCP, no Claude Context MCP**: lite contract — predictable token cost.
- **In-session verification (lite scope)**: categories 1–4 only (category 4 one-shot; category 5 dropped → residual + `/cc-cmds:design` redirect); execution budget 6 units (2/2/2), ≤2 min/unit, ≤12 min cap; the `실행 주의` exception classes are structurally excluded. Read `${CLAUDE_SKILL_DIR}/../_common/verification.md` for the contract (the fourth `_common` Read).
- **Agent Team required**: TeamCreate + SendMessage only. Do NOT substitute with isolated Agent sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. AskUserQuestion MUST be loaded before Step 1 (user interview). Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

Task: $ARGUMENTS
