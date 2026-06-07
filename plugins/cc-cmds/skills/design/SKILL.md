---
name: design
description: 에이전트 팀을 활용한 기능 설계 토론 진행
when_to_use: 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때
disable-model-invocation: true
usage: "/cc-cmds:design <task>"
options:
    - name: "<task>"
      kind: positional
      required: true
      summary: "설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트)."
---

Conduct a design discussion using an agent team for the given task.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication (interviews, final presentation) and saved documentation should be in Korean.

## Control-Flow Invariants

These phase-transition rules govern turn-yielding and MUST stay near the top of
this file. Post-compaction reattaches only the first ~5K tokens with priority;
a summarized-away transition rule causes silent mis-transition — waiting for the
user where the skill must auto-advance, or prompting where it must yield.

### CFI-1 — Step 4 → Step 5 is automatic (no wait, no prompt)
Whenever a design doc was saved, the lead MUST continue from Step 4's
`synthesize → save → cleanup → present results` straight into Step 5 (Unresolved
Issue Walkthrough) in the same turn, without yielding and without any user
prompt. "Present the results" is NOT a turn-ending action: do not stop, do not
wait for the user to ask. Step 5 entry is mandatory and unconditional.

### CFI-2 — Step 6 entry: automatic arrival, then notice-and-yield
(a) ARRIVAL (transition): reaching Step 6 (Plan Refinement) is automatic —
    Step 5 → Step 6 needs no user prompt. Do not stop on the way in.
(b) FIRST ACTION: once at Step 6, the lead emits ONE short Korean notice that
    refinement is starting (inviting the user's input), then YIELDS the turn and
    waits for the user to speak first. At Step 6 ENTRY do NOT call
    AskUserQuestion to open the discussion or manufacture a refinement question
    — no question tool, no options menu, no "무엇을 다듬을까요?" prompt; Step 6
    opens as a plain yield.
(c) SCOPE: this prohibition is the ENTRY moment ONLY; it does NOT restrict
    AskUserQuestion elsewhere — the Step 6 state-check's slug-ambiguity prompt
    (fires before the entry notice, during pre-entry cleanup) and Step 6's later
    "propose a new team" approval path remain valid, as do all Step 4/Step 5
    AskUserQuestion uses.

## Workflow

### Step 1: Requirements Interview & Codebase Exploration (Korean)

- Do NOT create a team yet. First, interview the user to understand requirements.
- Ask deep, non-obvious questions covering all aspects of the task, including but not limited to: technical implementation, UI/UX, concerns, tradeoffs, scale, constraints, and integration points.
- Avoid generic or superficial questions. Dig into specifics.
- Explore the existing codebase as needed during the interview to inform better questions and identify related patterns, modules, and conventions.
- **Reproduction-first (execution by reproduction)** — a third mode of the interview↔exploration loop, for issue/bug tasks. Reproducing the actual symptom *before* team composition keeps the interview questions sharp and anchors the Step 2 team on the real root cause instead of a code-reading guess.
    - **Single filter test**: *"Does the task claim that existing code currently misbehaves, and is that misbehavior observable by running the existing app or test suite?"* NO (new feature / greenfield / pure architecture choice — nothing to misbehave yet) → skip reproduction. YES → attempt reproduction before composing the team. Whether to reproduce, and whether the lead does it directly here vs. delegating to a Step 3 reproduction agent, is the lead's delegated judgment.
    - Reproduction runs only the unmodified app/tests and routes all artifacts/logging out of tree — see `## Constraints` → "Observation & verification carve-out" (do not restate it here).
    - **On a reproduction attempt, emit four data points** (same labels as the `## 재현·근본원인` section schema in Step 4, so Step 4 can fill that section verbatim): `재현 절차` / `관측된 증상` ("미관측" if only hypothesized) / `근본 원인` / (only on failure) `재현 차단요인`. The confirmed-vs-hypothesis distinction is carried solely by `근거 등급` (token `확인됨(재현·관측)` when the recipe was actually run and the symptom observed; otherwise `가설(추측)`), not by the field names.
    - **Two-tier fallback when reproduction fails**: Tier-1 — ask the user for the gap (env / exact steps / logs) during the interview, then retry. Tier-2 — if it still fails, or the lead judges user help futile (inaccessible failure env/data, non-determinism with no capture, an external dependency the user can't exercise), proceed with the root cause marked `가설(추측)` and `재현 차단요인` filled. The user-can't-help call is the lead's delegated judgment. Tier-2 (and only Tier-2) triggers the lead to create an unresolved-issue pointer during Step 4 synthesis (see Step 4).
- **Verification-first (settling claims in-session)** — a companion to reproduction-first, generalized from bug symptoms to any load-bearing assumption the design will rest on. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the in-session verification SOT: claim taxonomy, severity→filter tests, carve-out surfaces) and apply it as assumptions surface. Settle the cheap (a)/(b) claims inline here (a `grep`, a `--version`, a single unmodified tool run) so the Step 2 team composes on observed facts; note any verifiable claim that cannot be settled now for residual encoding at synthesis. If Step 1 reveals a verification-heavy profile (multiple (c) external facts, expected (d)/(e) experiments, feasibility questions already visible), flag it so Step 2 can seed a dedicated verification agent.
- Iterate between interviewing and codebase exploration until all critical aspects are sufficiently covered, then confirm with the user before proceeding.

### Step 2: Team Composition Proposal (Korean)

- Based on interview results and codebase exploration, propose a team composition to the user.
- Specify each teammate's role, exploration scope, and model (use short aliases: `"opus"`, `"sonnet"`, `"haiku"`).
- **Reproduction agent role (optional, issue/bug tasks)**: if the reproduction-first filter test (Step 1) is YES and the lead judges a dedicated reproducer is better than reproducing inline, propose a **reproduction agent** as one of the roles. Its scope is: reproduce the symptom, emit the same four data points + `근거 등급` as Step 1, and — as a precondition of broadcasting — clean up and verify the tree (revert instrumentation, delete out-of-tree artifacts, confirm `git status --porcelain` == baseline) *before* findings leave it. This agent drives Step 3's Round 0 (below).
- **Verification agent role (optional, parallel to the reproduction agent)**: if Step 1 anticipated a verification-heavy profile (multiple (c), expected (d)/(e), feasibility questions already visible), the lead may propose a **verification agent** as one of the roles. Its scope is: settle assigned verifiable claims per `_common/verification.md`, pre-register each claim's `주장` + `기대 결과` before running, and — as a precondition of broadcasting a verdict — clean up and verify the tree (the two-command boundary gate; for (e), `git worktree remove --force` + `git worktree prune` + list-vs-baseline) *before* the verdict leaves it. The Quality Gate can hold a gated proposal and route its claims to this agent. Same cleanup-before-findings-leave precondition + worktree-teardown duty as the reproduction agent.
- Only create the team after the user approves the composition.

### Step 3: Design Discussion (English, internal only)

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step. When you assign work to each teammate via SendMessage, include the Teammate Rules block from `_common/agent-team-protocol.md` **verbatim in the assignment body** (the block-quoted teammate-facing instruction under the `## Teammate Rules` heading) — do NOT paraphrase to a one-liner. The short form is the documented cause of teammates emitting `[COMPLETE]` as text instead of via SendMessage.

- Create the team with the approved composition. Name it `design-{topic-slug}` (e.g., `design-auth-flow`, `design-payment-system`).
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
  - (observation & verification carve-out: running the unmodified app/tests, and out-of-tree / isolated-worktree experiments, are not modifications — see `## Constraints` → "Observation & verification carve-out".)
- **The lead acts as a facilitator**, actively driving multi-round discussion. Do NOT passively wait for results and move on.

#### Discussion Protocol (minimum 2 full rounds)

0. **Round 0 — Reproduction grounding pass** (only when a reproduction agent is on the team): the reproduction agent reproduces the symptom (with artifacts present), captures the observation in its report text, then **reverts/deletes the artifacts → verifies `git status` is pristine → and only then broadcasts** the grounding report to the whole team. Cleanup-and-verify is a *precondition* of the broadcast (findings must be clean before they leave the producer). Round 0 is a grounding pass and **does NOT count toward the minimum 2 rounds**. The reproduction agent stays active through Cross-Review, challenging whether each proposal actually addresses the reproduced cause, and converges with `[COMPLETE]` like any teammate.
   - **Round 0 failure path**: if the reproduction agent fails to reproduce, it broadcasts a `가설(추측)` grounding report with `재현 차단요인` filled. Tier-1/Tier-2 escalation is owned by the **lead** (the agent cannot call AskUserQuestion — it only surfaces the blocker; the lead decides whether to ask the user for help and, on Tier-2, creates the Step 4 unresolved-issue pointer). The Quality Gate's "hypothesis + blocker → proceed" branch (below) is exactly this failure-acceptance path.
1. **Round 1 — Initial Proposals**: Assign each teammate their design scope. Wait for ALL teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, reply with "Take your time and send your complete analysis when ready" — do NOT move on.
2. **Quality Gate**: Before proceeding to cross-review, verify each proposal meets minimum depth:
   - References specific files, modules, or patterns from the actual codebase (not generic advice)
   - Includes concrete design decisions with rationale (not just listing options)
   - If a proposal is too shallow or generic, send it back with specific questions asking for deeper analysis
   - **Reproduction addendum** (when a reproduction agent is present): Round 1 proceeds only after the Round 0 grounding report carries a `근거 등급` (either `확인됨(재현·관측)` with observed evidence, OR `가설(추측)` with `재현 차단요인`) **and** the tree is pristine-verified. Reject a grounding report that is a code-reading guess with no attempt-to-run, or one that left artifacts in the tree.
   - **Verification addendum** (sister to the Reproduction addendum; applies on Round 1 and every Round 2+ revision forward). Reject (send back) on ANY of: (1) a load-bearing claim passes the filter test but carries no `검증 등급` tag (a tripwire-phrase hit counts); (2) a `미검증`-tagged claim reaching cross-review (disposition: send back "verify or re-justify the reclassification", or hold + route to the verification agent); (3) a `검증됨(통과)`/`반증됨(실패)` tag with no recipe + observed value — a verification claim without evidence (isomorphic to the existing "code-reading guess with no attempt-to-run" rejection); (4) a clearly-filter-passing claim tagged `구현 시 검증` — the misclassification escape hatch (audit: `잔여 사유` token present + `차단 사유` specificity ("ran out of time" inadmissible) + on `구현 필요`, re-apply the filter test).
3. **Cross-Review**: Send each teammate's proposal to the other teammates for review. Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches.
4. **Round 2+ — Refinement**: Collect cross-review feedback and send it back to the original authors. Ask them to address the feedback, revise their proposals, and respond to challenges. Repeat this cycle until convergence.
5. **Convergence Check**: Use the convergence-check template from `_common/agent-team-protocol.md`. Only proceed to Step 4 when ALL teammates confirm `[COMPLETE]`.

**Evidence-grade label (`근거 등급`)**: for reproducible issue/bug tasks, the root cause carries a binary evidence grade — `확인됨(재현·관측)` (the recipe was actually run and the symptom observed) or `가설(추측)` (anything unrun/unattempted/blocked). The field key is `근거 등급`, deliberately distinct from `상태` (the walkthrough's state field). The single source of truth is the `근거 등급` field of the saved doc's `## 재현·근본원인` section, **computed once at the reproduction discovery point** (Step 1 lead-driven OR Round 0 agent-driven — whichever path reproduced); every other location only *references* it. When a teammate's proposal builds on the reproduced cause, it carries a `[근거 등급: …]` prefix — this is label-only (it travels with the proposal as context), NOT a hard gate: a `가설(추측)` proposal is still discussable.

**Verification discipline (`검증 등급`)**: parallel to the evidence grade, applied to any load-bearing claim the design rests on (the contract is `_common/verification.md`). The authoring teammate runs the severity pre-filter, then the single filter test, on each dependent assertion and attaches an inline `[검증 등급: …]` tag (same pattern as `[근거 등급: …]`; **inter-agent messages only** — saved-document marking uses the token-free anchor-reference convention `(§검증 기록 V<n>)`). A verifiable claim must reach `검증됨(통과)`/`반증됨(실패)`, backed by a re-runnable recipe + an observed value, before it is carried into synthesis; a genuinely implementation-time-only claim is encoded as a residual item (`잔여 사유: 구현 필요`). **Linguistic tripwire**: a hedge on a decidable fact ("should exist", "presumably", "구현 시 확인/검증 필요") is a confessed-unverified claim. **Routing (lead's delegated judgment, not a fence)**: the author verifies cheap one-command (a)/(b) at proposal time; the Step 2 verification agent takes (c)-heavy / expected (d)/(e) / feasibility questions; **all *failing* verifications and expensive (c)/(d)/(e) go back through re-convergence, never lead-solo** (a refutation changes the design after convergence). Claims discovered *mid-experiment* are recorded only (tagged `미검증` in discussion, routed at the next Quality Gate) — never auto-verified inline; the lead may allow one in-session re-entry per discovered claim, and a claim discovered while verifying a re-entered claim is residual-only (`잔여 사유: 검증 차단`, blocked reason "recursion depth").

### Step 4: Result Synthesis & Documentation (Korean)

- The lead synthesizes all discussion results into a structured Korean document:
    - 재현·근본원인 (이슈·버그 수정 과제에 한해 최상단에 포함; 기능 설계 과제에서는 생략)
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 검증 기록 (세션 내 검증을 수행한 경우에 한해 포함; 수행이 없으면 생략)
    - 미해결 이슈 / 트레이드오프
    - 구현 시 검증 항목 (잔여 검증 클레임이 있는 경우에 한해 포함; 없으면 생략)
    - 권장 구현 순서
- **`## 재현·근본원인` section** (issue/bug tasks only — omitted for feature-design tasks). The section records the reproduction findings produced in Step 1 or Round 0 so the design rests on an observed cause, not a guess.
    - **Placement & heading**: at the **very top** of the document, before 합의된 아키텍처 (for a bug fix the root cause is upstream of architecture and decisions). The heading is exactly `## 재현·근본원인` with **no leading section number** — `## 0.` / `## 1.` etc. is forbidden because the fixed anchor `§재현·근본원인` (used by the Tier-2 pointer below) would dangle.
    - **Fields**: `재현 절차` (a re-runnable recipe — literal commands or an inline fenced script, **no `/tmp` paths** since those are deleted, plus a `tracked-source 무변경 확인` note; if the observation depended on an out-of-tree driver/instrumentation, write that logic *inline as a fenced script* so the recorded recipe is self-contained and re-runnable) / `관측된 증상` ("미관측" when only hypothesized) / `근본 원인` (grade-neutral field name — whether it is confirmed lives in `근거 등급`, not here) / `근거 등급` / `재현 차단요인` (only when the hypothesis is due to a reproduction failure; carries `차단 사유` + `필요한 것`).
    - **Grade acquisition**: `확인됨(재현·관측)` is earned ONLY when the recipe was actually run and `관측된 증상` observed; unrun/unattempted/blocked is `가설(추측)`.
    - **Multi-claim & mixed tasks**: if one section holds more than one reproduction claim, repeat each claim as a self-contained `### ` sub-block (each with its own `재현 절차`/`관측된 증상`/`근본 원인`/`근거 등급` — the source of truth is per-claim), and a Tier-2 pointer targets that claim's sub-block anchor. A mixed task (bug fix + new feature) includes the section per-reproducible-claim: if any part of the task is a reproducible existing-misbehavior claim, the section is included (scoped to that part).
    - **Grade propagation (one-way)**: the reproduction discovery point is the origin; Step 3 proposals carry a `[근거 등급: …]` prefix (label-only); `주요 결정사항과 근거` points at the grade by **referencing `§재현·근본원인`** (do NOT restate the literal grade token — no stored copy, prevents divergence); the grade is written once, in `## 재현·근본원인`.
- **Tier-2 → unresolved-issue pointer**: only when reproduction hit Tier-2 (proceeding on a `가설(추측)` root cause) does the lead create an unresolved-issue pointer in the `## 미해결 이슈 / 트레이드오프` section during this synthesis (the synthesis-terminal rule permits lead-driven Edits). Encode it to match that section's existing form (mixed-form prohibited; fresh-section default = sub-section). Sub-section example: `### N.x 재현 미확인 — 가설 근본원인 채택 여부` + `**상태**: 대기` + `**Category**: UR` + `**Surfaced-at**: Step 4 synthesis` + a body line referencing the `§재현·근본원인` anchor. The pointer holds its own `상태` (default `대기`) and the anchor, but **does NOT hold `근거 등급`** (that lives only in the canonical section, to avoid duplication/divergence). This makes Step 5's walkthrough consciously ask the user whether to accept the hypothesized cause.
- **`## 검증 기록` section** (verification ledger; unnumbered heading) — placed after `## 주요 결정사항과 근거`, before `## 미해결 이슈 / 트레이드오프`. Holds `### V<n>.` sub-blocks per the V-ledger schema in `_common/verification.md` (the SOT — do NOT restate the field list here). The ledger accepts only performed verifications (`검증됨(통과)`/`반증됨(실패)`, every entry carrying an observation). If no verification was performed, omit the whole section (the pre-save sweep makes the absence meaningful). Body claims reference an entry by the token-free anchor `(§검증 기록 V<n>)`; the ledger is the single SOT and `주요 결정사항과 근거` does not restate tokens.
- **`## 구현 시 검증 항목` section** (residual items; unnumbered heading) — placed after `## 미해결 이슈 / 트레이드오프`, before `## 권장 구현 순서`. The two new sections straddle the unresolved-issues section without touching its parse region; neither new heading contains `미해결`/`이슈`, so neither can match the walkthrough parse regex. Holds `### R<n>.` sub-blocks per the Residual-item contract in `_common/verification.md`. The lead performs the **transformation move** (that file) to convert each in-session-unsettleable claim into an R-item; a residual item is born by exactly the three paths of the contract (filter NO → `구현 필요`; verification-attempt exit → `검증 차단`; review deferral). 0 items → omit the section.
- **UR escalation pointer (lead's delegated judgment, Tier-2 isomorphic)**: if a residual claim is load-bearing enough that the user should consciously accept building on it, the lead creates a UR pointer in `## 미해결 이슈 / 트레이드오프` — `상태`/`Category`/`Surfaced-at` + a `§구현 시 검증 항목 R<n>` body reference only; it **never** includes the `검증 등급` key, token, or recipe (predicate check). Per-item mandatory pointers are rejected (the dual backstop already validated the deferral; N pointers = N friction prompts).
- **Pre-save sweep (lead backstop, inside the synthesis-terminal window, before the first save — so re-convergence is always still possible)**: scope is the entire synthesis **draft**, decisively including assertions the lead introduced during synthesis (the only class that never passed the Quality Gate — the sweep's unique coverage). Pass conditions: `**검증 등급**: 미검증` (full-line) + `[검증 등급: 미검증]` (inline tag) document-wide 0 (the absence-proof exception of the detection grammar), AND 0 verifiable load-bearing claims without a V/R anchor reference, AND every `구현 시 검증` item present in the residual encoding, AND the two-command boundary gate (`_common/verification.md` §6): main `git status --porcelain` == the pre-workflow baseline and `git worktree list --porcelain` shows 0 `cc-design-exp-` entries. **Late finds**: cheap (a)/(b) → the lead verifies immediately and records it in the ledger; expensive/failing → **re-convergence** (SendMessage the affected author → focused verify/fix exchange → mini cross-review if cross-cutting → update draft → re-sweep the changed part → save). This rides on the existing "clarify before the first save" sentence — no new turn-yield semantics, **not a CFI** (a missed sweep degrades to today's quality baseline, not a mis-transition). **Re-convergence limit**: at most 1 cycle per failing claim; a second failure of the same claim → `AskUserQuestion` (accept residual with refutation evidence / route to Step 6 redesign / abort) rather than a silent round. **Visibility tripwire**: at ~5 in-session worktree experiments the lead emits a status note (visibility, not a gate).
- **Synthesis terminal**: All teammate clarifications must be completed before saving the design document. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. Do NOT save a partial document, send a teammate message, then save again; clarify before the first save. The sequence save → cleanup → presentation is atomic. Step 5 (walkthrough) and Step 6 (refinement) are new editing phases governed by their own state-check + cleanup rules. The synthesis-terminal rule bars further Step 3 team messages but does NOT bar lead-driven Edits to the saved doc.
- Save the design document to the project's `docs/` directory. **File naming convention**: use `docs/{topic-slug}.md` where `{topic-slug}` matches the Step 3 team's topic slug exactly (e.g., Step 3 team `design-auth-flow` → saved doc `docs/auth-flow.md`). This filename-to-slug binding is the local state used by Step 5's entry state-check to recover the slug without relying on lead memory. **Interrupted-save case**: if the save itself was interrupted (partial write, permission error, etc.), the state-check cannot recover the slug from the filename. In this case the lead must either (a) recover the slug from the original task input or interview output that started the workflow (from in-session conversation history, including slash-command `$ARGUMENTS` if invoked that way), or (b) treat the workflow as ambiguous and prompt the user via `AskUserQuestion` before any cleanup action.
- Notify the user in Korean: *"설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure to clean up the design team.
- **Verification aggregate line**: if the `## 구현 시 검증 항목` section is non-empty, include in the Step 4 presentation one Korean line — *"구현 시 검증 항목 N건이 기록되었습니다 — /implement 시작 시 우선 검증됩니다."* (queue impact 0).
- Present the results to the user in Korean. Do NOT yield the turn here — the presentation and Step 5's entry are one continuous turn. Immediately continue into Step 5 below in this SAME turn, with no stop, no wait, and no user prompt. (CFI-1)

### Step 5: Unresolved Issue Walkthrough

This step runs automatically right after Step 4 (CFI-1). Its purpose is to drive every unresolved issue in the saved design document to a decision **without waiting for an unprompted user request**, scoped strictly to *issues that cannot be resolved without user input*. Mechanical gaps, false positives, and auto-decidable items are NOT this step's responsibility — they belong to a subsequent `/cc-cmds:design-review` cycle. User-facing communication in this step is Korean; the normative prose below is English.

> "Walkthrough-spawned teams (Step 5) and refinement teams (Step 6) share the `design-<slug>-refine-N` namespace and the monotonic N counter, but differ in scope and lifetime: a walkthrough-spawned team is bounded to a single unresolved issue's decision debate (user-initiated when auto-investigation findings alone don't yield a clear decision) and dies at that issue's resolution; a refinement team handles a user-initiated multi-turn refinement and lives until the user is satisfied. They are not competing entry points — they are the same entry point (user-confirmed `TeamCreate` for a single bounded scope) invoked at two different lifecycle moments. The lead never extends a walkthrough-spawned team into a refinement team or vice versa — the `Cleanup → next spawn` contract is enforced unchanged."

Terminology: throughout this skill use **"walkthrough-spawned team"** (not "walkthrough investigation team"). "Investigation" refers strictly to the lead-only, read-only activity defined below.

#### Trigger & Queue Initialization

- Parse the saved doc's `## 미해결 이슈 / 트레이드오프` section to initialize the issue queue. **Parse contract**: match the heading with the regex `^##\s+(?:[0-9]+\.\s+)?미해결\s+이슈(?:\s*/\s*트레이드오프)?\s*$` — an optional leading section number (`6. `, `10. `, any digit count) and an optional `/ 트레이드오프` suffix are both allowed. On **multi-match**, use the LAST match (synthesis is written top-down, so the deepest occurrence is canonical).
- On **0-match**, surface via `AskUserQuestion` with three options: (a) **add the section and proceed** — the lead creates a `## 미해결 이슈` heading via doc Edit (sub-section form by default, per the encoding rules below), re-parses the doc to rebuild the queue; entries the user pre-added are processed as-is, and 0 entries cascade naturally into the 0-issue path; (b) **skip the walkthrough** and proceed to Step 6; (c) **abort** — the entire design workflow terminates and Step 6 is NOT entered.
- **0 issues**: emit the Korean notice *"미해결 이슈가 없어 곧바로 플랜 리파인먼트 단계로 이동합니다."* and proceed directly to Step 6. (CFI-2)
- **1+ issues**: emit *"설계 문서에 미해결 이슈 N건이 확인되었습니다. 하나씩 검토하며 정리하겠습니다."* and enter the walkthrough proper.
- **Depth-2 promotion on queue init**: any entry carrying both `상태: 보류` and a `(깊이: 2)` marker is auto-promoted to depth-1 — the lead Edits the doc to change `상태: 보류 → 상태: 대기` and `(깊이: 2) → (깊이: 1)` together (the `Parent` field is preserved as historical metadata), then appends it to the queue. Plain `상태: 보류` entries (no depth marker, or `(깊이: 1)`) are NOT promoted — those are deliberate user deferrals.
- **Drop-uncertain promotion on queue init**: any `상태: 보류` entry whose `사유:` text contains the substring `drop 미확정` (produced by the abort-during-drop-prompt path below) is also promoted — change to `상태: 대기`, clear the `사유` field, append to the queue. This applies regardless of any depth marker, and re-surfaces issues whose drop confirmation was never completed.
- **Queue order**: doc-order, top-to-bottom. Depth-1 items that surface mid-pass are appended to the *end* of the queue (not inserted right after the current issue) and are reached only after all pre-existing items are processed. No per-category priority ordering.
- After the walkthrough finishes, emit *"미해결 이슈 워크스루를 종료했습니다. 이어서 플랜 리파인먼트를 시작하겠습니다."* and enter Step 6 automatically. (CFI-2)
- If the user aborts mid-walkthrough, batch-mark the remaining items `상태: 보류` (see Abort Semantics below) and move to Step 6. (CFI-2)

#### Issue Sources & Categories

The issue queue has two sources:

1. The saved doc's `## 미해결 이슈 / 트레이드오프` section (the Step 4 output).
2. Items the lead surfaces while re-reviewing the doc — but these must be **doc-first**: record the item in that section via Edit *before* appending it to the in-memory queue (idempotency). Items found during the bulk re-review at walkthrough entry are queued as `(깊이: 1)`; items found incidentally during a depth-1 issue's auto-investigation or team discussion are recorded doc-only as `(깊이: 2)` and do NOT enter the queue (see Depth Management below).

Each issue is classified into one of four categories:

| Category | Code | Definition | Auto-investigation default |
| --- | --- | --- | --- |
| Decision-needed | UD | A value/choice the synthesis left undecided or set to a default | None — user value judgment |
| Clarification-needed | UC | Whether an assumption the synthesis adopted matches user intent | `grep` the codebase convention first |
| Alternative-to-evaluate | UA | The doc presents multiple paths and the user must pick | Read each option's affected files + cost estimate |
| Risk-acknowledgment | UR | A deliberate tradeoff the user must consciously accept | None — surface the tradeoff framing only |

#### Surface Depth (single filter test)

While re-reviewing the doc, the lead decides whether to surface a candidate issue with a single test:

> **_"Can a fresh `/design-review` pass resolve this without user input?"_**
>
> - YES → defer to `/design-review` (the walkthrough does NOT surface it).
> - NO → the walkthrough surfaces it.

This is the responsibility boundary between the walkthrough and design-review. Items the walkthrough explicitly does NOT surface:

- spelling, formatting, cross-section field/contract mismatch (design-review's `internal-coherence` area);
- missing standard error handling (design-review's `missing-items` area);
- items already resolved in the doc body (false positives);
- hypothetical items unrelated to real risk;
- items outside the design scope;
- items the lead's own auto-investigation alone can resolve. **Pre-queue filter**: this happens *before* queue initialization — while the lead re-reviews the doc, any candidate it judges a false positive gets only a short lead note in the doc body (e.g., *"lead 자동 조사 결과: 코드베이스 컨벤션 X와 일치 — false positive"*) and does NOT enter the queue. No state-machine transition occurs, so this is unrelated to the state machine; it is *triage*, not a *decision*, and does not conflict with the user-confirmation rule for decisions. It applies to all four categories.

#### State Machine (5 + 1, doc-anchored)

Each issue follows this state machine (5 non-terminal + 1 transient-remove):

```
pending → investigating → awaiting-decision → resolved
                                           ↘ deferred
                                           ↘ dropped

UD/UR shortcut: pending → awaiting-decision (skips investigating)
```

- `investigating` / `awaiting-decision` are **ephemeral by default** (lead memory). If a transition is mid-flight when a turn ends, checkpoint-write it to the doc so the next session can recover. The checkpoint format is the encoding convention below — sub-section form prepends a `**상태**: 조사중` or `**상태**: 결정대기` line; table form updates the `상태` column value.
- **Per-category transition shortcut**: UD (user value judgment) and UR (tradeoff acknowledgment) have no auto-investigation, so they go `pending → awaiting-decision`, skipping `investigating`. UC/UA follow the full transition.
- **Checkpoint recovery**: when a new walkthrough invocation parses the doc and finds a `상태: 조사중` or `상태: 결정대기` entry, the prior session's transient memory is lost, so the lead (i) **Edits the doc to overwrite the marker with `상태: 대기`**, then (ii) appends it to the in-memory queue as `대기` so it is re-investigated in natural doc-order. The doc marker and queue state must always agree, so an in-memory reset alone is not sufficient. The checkpoint only guards against doc-state loss; it does not recover in-memory investigation findings.
- `resolved` / `deferred` are **terminal** — written to the doc immediately.
- `dropped` is **terminal-remove** — right after user confirmation the entry itself is deleted from the doc (the doc reflection is an entry removal, not an annotation write; see the dropped branch below).

#### Doc Encoding (tolerate both forms + 상태 marker)

Existing design docs use two encodings: **table form** (columns `항목 | 내용 | 우선순위 | 비고`) and **sub-section form** (`### N.x <항목명>` headings + prose body). The walkthrough tolerates both and adds an inline `상태` marker.

- **Table form**: append a `상태` column to the right of the existing columns. Additional fields (Category, Reason, 자동조사 요약, Surfaced-at, Parent) attach as extra columns. **Field definitions**: `Surfaced-at` = the walkthrough invocation that surfaced the entry (format `walkthrough pass <N>`, or `Step 4 synthesis` meaning an original design output item). **N counter**: a monotonic walkthrough-invocation counter starting at 1, +1 each invocation; not stored separately but derived as `max(existing Surfaced-at entries) + 1` (the same doc-anchored, no-lead-memory doctrine as file-system enumeration); if the doc has no entries on the first call, N=1. `Parent` = a depth-2 entry's parent depth-1 issue (format `"issue title (§anchor)"`). The other fields are defined elsewhere in this step. **Last-row removal edge case**: if a `dropped` removal leaves the table with 0 data rows (only header + alignment), the lead removes the entire table and replaces it with the one-line note *"이번 walkthrough에서 모든 미해결 이슈가 해소되었습니다."* The `## 미해결 이슈` heading itself is kept (needed by the parse contract and future walkthrough invocations).
- **Sub-section form**: prepend `**상태**: <value>` to the first line of each sub-section body. Additional fields are added as prose lines: `**Category**: <value>`, `**Surfaced-at**: walkthrough pass <N>`, `**Parent**: <issue title> (§<anchor>)`, `**Reason**: <text>`, `**자동조사 요약**: <text>`. **Field definitions are form-agnostic**: the table-form definitions above (N counter derived as max+1, etc.) apply identically — the forms differ only in notation, the field semantics are single. **Last-entry removal edge case**: if a `dropped` removal deletes the last `### N.x` sub-section, leaving 0 entries under `## 미해결 이슈`, the lead inserts the one-line note *"이번 walkthrough에서 모든 미해결 이슈가 해소되었습니다."* as prose right after the heading. The heading itself is kept.

`상태` values (5+1 states → 6-value Korean vocabulary):

| Internal state | Korean value | Meaning |
| --- | --- | --- |
| pending | `대기` | discovered, unprocessed |
| investigating | `조사중` | auto-investigation in progress (ephemeral) |
| awaiting-decision | `결정대기` | investigation done, awaiting user input (ephemeral) |
| resolved | `해결` | decision applied, reflected in the doc body |
| deferred | `보류` | deferred via per-issue defer or abort |
| dropped | `제외` | judged a non-issue by auto-investigation — **transient classification only** (the `제외` judgment exists in lead memory only; right after user confirmation the entry is deleted from the doc, and no `상태: 제외` annotation remains) |

Additional invariants:

- **Mixed-form prohibition**: within a single doc's `## 미해결 이슈` section, do not mix table form and sub-section form. The doc keeps whatever form Step 4 chose; the walkthrough never converts forms.
- **Fresh section default**: if the Step 4 output has no `## 미해결 이슈` section (synthesis judged 0 issues), the walkthrough uses **sub-section form** by default when creating the section (avoids table layout overhead at 0 rows).
- **Marker absence → `상태: 대기`**: if an entry exists but has no `상태` marker, the walkthrough interprets it implicitly as `상태: 대기`. A marker is written to the doc only at the moment of a user decision; there is no retroactive bulk-write. This is the migration policy for pre-existing docs written without markers.

#### Depth Management (single section + inline marker)

Re-review and auto-investigation can surface new issues. Depth markers prevent infinite recursion:

- **`(깊이: 1)`** — an item the lead surfaced independently during walkthrough re-review. doc-first Edit → queue-append → handled in the current walkthrough pass.
- **`(깊이: 2)`** — an item surfaced during a depth-1 issue's **auto-investigation or team discussion**. doc-first Edit (default `상태: 보류` + `사유: depth-2 follow-up (parent <issue title> §<anchor>)` + a `Parent: <issue title> (§<anchor>)` field — `사유` is the short citation, `Parent` is the structured follow-up field; both render the parent as "issue title + §anchor") → NOT queue-appended → re-enters as `(깊이: 1)` on the next walkthrough invocation.
- **`(깊이: 3)` and beyond is structurally impossible** — a `(깊이: 2)` item never enters the current queue, so nothing can surface during its investigation.
- **Marker conversion on re-entry**: when a depth-2 item enters as depth-1 on the next walkthrough invocation, the doc's `(깊이: 2)` marker becomes `(깊이: 1)` and `상태: 보류` becomes `상태: 대기` together (keeping doc state and queue state in agreement). The `Parent` field is preserved as historical metadata so a later user can trace the discovery context. **Original Step 4 output items (no depth marker) are treated as implicit depth-1** — no marker need be attached.

Do **not** create a separate sub-section (`## 워크스루 후속 항목`). All items stay integrated in the existing `## 미해결 이슈 / 트레이드오프` section as a single source of truth; design-review and other downstream tools parse just that one section.

**Announce timing**: right after a parent depth-1 issue enters a terminal state (resolved/deferred/dropped), announce in Korean — in **one combined message** — all depth-2 items identified while processing that issue (both lead auto-investigation and team discussion sources). Example form: `📌 parent <issue title> 처리 중 depth-2 N건 식별 — 다음 walkthrough에서 자동 표면화: [<title>, <title>, ...]`. depth-2 items are default-deferred, so no user decision input is required (announce only). If there are 0 depth-2 items, skip the announce.

#### Per-issue Processing Flow (hybrid)

> **One issue per surface (invariant)**: each `AskUserQuestion` call in this step carries **exactly one issue** (one question). The tool's up-to-4-questions capacity is NEVER used to bundle multiple issues into a single call — the only 4-slot budget in play is the per-issue **option** menu (concrete picks + `보류` + `팀 토론 진행`). These are two distinct axes: *4 questions per call* vs. *4 options per question*; this step uses only the latter. Bundling multiple issues breaks every per-issue mechanism that assumes a single, loopable surface — auto-investigation, the `← 추천` recommendation, the UC `더 논의` follow-up loop, the dropped-confirm separate prompt, and mid-flight reclassification. The `4-option cap` discussed in **Cap-handling** below refers to options within one issue's menu, never to a count of issues.

For each issue:

1. **Auto-investigation (lead-only, read-only + reproducible)**:
    - UD: Read doc context only.
    - UC: `grep` for the assumed convention in the project's primary source tree (e.g. `src/**`, `plugins/**`, `app/**` — the lead adapts to the project's convention); optional `make test`.
    - UA: Read each option's affected files + cost estimate (line-count delta, etc.).
    - UR: Read the tradeoff framing only. **Reproduction pointer (Surfaced-at: Step 4 synthesis, body references `§재현·근본원인`)**: when surfacing it, the Why-it-matters / framing text must **quote** the canonical section's `근거 등급: 가설(추측)` value (read-only reference, not a stored copy) so the user sees the hypothesis grade at decision time without manually following the anchor.
    - Hard limits: stop as inconclusive if `grep` returns >50 hits; stop if `make test` exceeds 2 min. If the result is inconclusive, surface it as *"조사 inconclusive — 사용자 판단 필요"*.
2. **Surface to the user (`AskUserQuestion`, Korean)** with: a one-line Title; a Category tag (UD/UC/UA/UR — fits the 12-char `header` chip limit); Why-it-matters (1-2 lines); the auto-investigation summary (the findings, or *"조사 불필요"*); Options (the per-category menu below — also apply the recommendation rendering check from the **Lead recommendation policy** paragraph: when auto-investigation is confident, move the recommended option to position 1 with `← 추천` and place the rationale in its `description`); and a Doc reference (`§ anchor`).
3. **Apply the user's decision**:
    - Direct resolution → mark `상태: 해결` + reflect the decision in the doc body. A UC "다르게 수정" response also maps here (the lead Edits the doc body per the user's correction + `상태: 해결`).
    - Defer → `상태: 보류` + record a reason (format `사유: 사용자 결정 보류 (<date YYYY-MM-DD>)`).
    - Drop (the dropped branch, UC only) → after user confirmation the entry is REMOVED from the doc. **Trigger condition**: branches only in the UC category when the lead's auto-investigation finds the issue is a false positive (already resolved in the doc body / codebase convention matches the assumption). **User-confirmation mechanism**: instead of the normal UC menu, surface the false-positive finding via a **separate `AskUserQuestion`** — body *"이 항목은 §X에서 이미 다뤄지고 있어 미해결 이슈에서 제거하려 합니다."*, options *"확인 / 그래도 유지 / 보류"* (each option carries a 1-line `description` per the **Description requirements** subsection below — `확인` uses the hybrid `<static semantics> — 근거: <false-positive evidence> (<path:line>)` form, `그래도 유지` and `보류` use static descriptions). On user confirm, Edit the doc to delete the entry — removed immediately, no `상태: 제외` annotation. On "그래도 유지", enter the normal UC menu (맞음 / 다르게 수정 / 더 논의 / 팀 토론 진행). UD/UA/UR have no dropped branch — they require user value judgment, so a false-positive verdict is impossible.
    - Redesign (a UR option) → `상태: 보류` + `사유: 재설계 필요 — Step 6 refinement에서 처리`. The walkthrough does not redesign directly; it defers.
    - Discuss further (a UC option) → an `AskUserQuestion` follow-up loop; the lead continues the dialogue until the user picks one terminal option among "맞음" / "다르게 수정" / "보류" / "팀 토론 진행". It has no terminal state of its own.
    - Run a team discussion → the spawn flow below.

#### Per-category Option Menu + Team Spawn

Every option in a per-category menu carries a 1-line `description` field. For options recommended via `← 추천`, the description follows the format `<semantics> — 추천 근거: <evidence>` with citation tokens per the **Lead recommendation policy** paragraph; otherwise it is the per-label static text tabulated in the **Description requirements** subsection.

Each category's user-facing options (Korean). **Default ordering**: direct-resolution options first, then `보류`, then `팀 토론 진행` (escalation gradient). **Recommendation override**: when the auto-investigation is confident, the recommended option moves to position 1 with `← 추천` appended; the remaining options preserve their relative ordering. **Conditional inclusion exception**: for UD/UA menus with `K_pick ≥ 3`, structural-slot visibility (`보류`·`팀 토론 진행`) follows the branch (a)/(b) layout in the **Lead recommendation policy** paragraph — both may be pinned (branch a) or hidden from the visible options array (branch b), with hidden items reachable via the AskUserQuestion `Other` channel. Default ordering applies only when conditional inclusion does **not** fire (UC/UR menus, or UD/UA with `K_pick ≤ 2`). Note the structural slots appear *where present, in the order `보류` → `팀 토론 진행`* — not every in-scope menu has both: the UC initial menu (`맞음 / 다르게 수정 / 더 논의 / 팀 토론 진행`) has no `보류` slot and places `더 논의` before `팀 토론 진행`; the UR menu (`수용 / 재설계 / 보류 / 팀 토론 진행`) and UC sub-loop (`맞음 / 다르게 수정 / 보류 / 팀 토론 진행`) have both. The UC dropped-confirm confirmation dialog (`확인 / 그래도 유지 / 보류`, no `팀 토론 진행`) is **not** an escalation-gradient menu — it follows its own carve-out ordering and is excluded from this default-ordering rule. See the **Lead recommendation policy** paragraph below for the confidence criterion + cap-handling rules.

| Category | Options |
| --- | --- |
| UD | (1-4 issue-specific concrete picks) + "보류" + "팀 토론 진행". A single concrete pick (binary confirm-only scenario) is also allowed — present the lone option as "이대로 적용 / 보류 / 팀 토론 진행". Picking a concrete pick maps to the "direct resolution" branch above. |
| UA | (option A / option B / ...) + "보류" + "팀 토론 진행". The user's option choice maps to "direct resolution"; the lead records an alternatives-considered note when Editing the doc. |
| UC | "맞음 / 다르게 수정 / 더 논의 / 팀 토론 진행" (initial). **Mapping**: "맞음" → the "direct resolution" branch (the user confirms the lead's assumption interpretation; mark `상태: 해결` but do NOT add a `사유` field — `사유` is reserved for the `보류` state in this spec; instead add the inline note *"사용자 confirm: 가정 정확."* at the end of the doc entry, with the body unchanged). "다르게 수정" → the same "direct resolution" branch. **UC's initial menu deliberately omits "보류"** — to prevent the user from skipping the issue without reviewing the auto-investigation summary; "보류" is reachable only inside the sub-loop after the user explicitly enters dialogue via "더 논의". On "더 논의" the sub-loop is entered, and its terminal option set is "맞음 / 다르게 수정 / 보류 / 팀 토론 진행" — "더 논의" is replaced by "보류" to prevent infinite dialogue. |
| UR | "수용 / 재설계 / 보류 / 팀 토론 진행". Picking "수용" maps to the "direct resolution" branch (`상태: 해결` + a tradeoff-acceptance note in the doc body — `사용자 acknowledged tradeoff: <original tradeoff framing>`). |

See the **Description requirements** subsection below for per-option description format (recommended-option rationale form + per-label static descriptions).

**Lead recommendation policy**: when the auto-investigation meets the per-category confident criterion — **UC**: grep returns 3–50 hits with ≥80% alignment to one verdict and no canonical-surface counter-example; **UA** (ANY of): cost delta ≥2× on line-count with affected-file count not inverted, OR one option has a hard blocker the other lacks, OR one option touches a doc-marked frozen/no-touch path the other doesn't; **UD** (ALL of): a parallel decision already committed elsewhere in this saved doc anchors the pick (cited as `§<anchor>`) AND one of the offered options aligns with that committed pattern AND the doc records no "this case is different" rationale — never on lead taste; **UR**: blast radius scoped to ≤1 module with no concrete lower-cost alternative cited (→ `수용`), or ((blast radius ≥2 modules) OR (critical path: auth/payment/data integrity/persistence schema/public API contract)) AND (a concrete cited alternative without prior rejection rationale) (→ `재설계`), or the tradeoff explicitly references cross-team coupling / out-of-scope expertise AND ≥2 distinct expert roles would weigh in differently (→ `팀 토론 진행`), or the issue is downstream of a depth-1 parent currently in `상태: 대기` or `상태: 결정대기` (→ `보류`); **NONE-good case**: when the lead is confident no listed option fits because of a doc-cited gap (`§<anchor>` constraint that all options miss, or a blocker absent in `<evidence path>` that all options require), force `팀 토론 진행 ← 추천` with the gap citation in the rationale — without a specific gap citation this case degrades to inconclusive.

**Recommendation contract**: the lead applies the documented `AskUserQuestion` recommendation convention — append `← 추천` to the recommended option's label, force it to position 1, and place the rationale in that option's `description` field. The description follows the format `<semantics> — 추천 근거: <evidence>` where `<semantics>` is a brief (≤10 Korean syllable) action/result summary (긴 UD/UA pick label로 인해 ≤10 음절을 약간 초과해야 의미 보존이 가능한 경우 soft over-flow 허용 — semantic clarity가 우선) and `<evidence>` carries the rationale. The description MUST be ≤2 sentences, ≤140 chars, and `<evidence>` MUST carry at least one citation token (code path `:line`, `§<anchor>`, a quantitative measurement such as `affected files: 4` / `~4×` / `12/12 hits`, or a blocker fact `requires X, absent in <evidence path>`). Opinion phrases (`cleaner`, `simpler`, `idiomatic`, `common practice`, `I think`, `feels like`) are forbidden unless paired with a citation token in the same sentence; this citation/denylist rule applies only to descriptions of options carrying `← 추천` — static descriptions on non-recommended options are display-only and exempt. All four options are eligible candidates — including `팀 토론 진행` and `보류` — provided their confidence criterion is met. When the criterion fails (grep results split outside 80/20, cost delta within 1.5×, no parallel anchor for UD, mixed UR impact, NONE-good without a gap citation, any auto-investigation hard limit tripped), the lead refuses to recommend: Why-it-matters surfaces *"조사 inconclusive — 사용자 판단 필요"* and the menu renders in default order with no `← 추천` suffix. Why-it-matters never duplicates the rationale (that lives only in the recommended option's `description`); when confident it is framed as *"결정만 내리면 적용 가능"*.

**UC sub-loop interaction**: the prior recommendation is suppressed by default on first sub-loop entry — re-computation is permitted only if (a) a new auto-investigation pass with materially different inputs still meets the confident criterion, or (b) the dialogue surfaces a previously-unrecorded fact that flips the alignment ratio; in both cases the description must cite the new evidence. "Previously-unrecorded" means the fact is absent from the original `AskUserQuestion` surface's auto-investigation summary text — the lead's in-session memory of earlier turns does NOT qualify.

**Dropped-confirm prompt carve-out**: the UC false-positive prompt (body: *"이 항목은 §X에서 이미 다뤄지고 있어…"*) is structurally a confirmation dialog (binary accept / override / punt), not a pick-one-among-equals menu — `← 추천` is **NOT** applied to its `확인` option (the prompt body already asserts the lead's verdict; adding the suffix would double-signal and friction `그래도 유지`). Its `확인` option uses a hybrid description form `<static semantics> — 근거: <false-positive evidence> (<path:line>)` (with `근거:` prefix, NOT `추천 근거:` — the segment is a fact statement, not a recommendation rationale); the citation/denylist rules of this paragraph do NOT apply to that hybrid form. The hybrid form still respects the recommended-option ≤140 chars / ≤2 sentences hard limits.

**Cap-handling — conditional inclusion (category-agnostic)**: when concrete picks plus structural slots `보류`/`팀 토론 진행` would exceed AskUserQuestion's 4-option cap (i.e., K_pick ≥ 3 in UD/UA), the menu undergoes **conditional inclusion** rather than blanket collapse. **Branch (a) — when the recommended option is `보류` or `팀 토론 진행`**: both structural slots are pinned (recommended at position 1; the non-recommended structural is placed at the position it would occupy in the canonical order `[picks..., 보류, 팀 토론 진행]` after removing the recommended item and shifting remaining items up — typically position 4 since `팀 토론 진행` is canonical-last, and `보류` lands at position 4 when `팀 토론 진행` is recommended), and the `K_pick − 2` lowest-priority concrete picks are dropped per a worst-cascade rule (hard blocker → deprecated-path overlap → frozen-path overlap → largest line-count delta ≥1.5× → doc-order LAST tiebreaker; continue-on-tie within tied subset). The 2 surviving picks fill the visible pick slots in canonical relative order. **Branch (b) — when the recommended option is a concrete pick OR the result is inconclusive**: both structural slots are **hidden** from the options array but remain reachable via the AskUserQuestion `Other` channel — the user types `보류` or `팀 토론 진행` (NFC-normalized + whitespace-normalized including U+3000 → U+0020, exact-match against canonical Korean tokens) and the lead processes the input identically to a menu selection. Hide ≠ collapse: the decision path remains open via `Other`, so the *"`보류`/`팀 토론 진행` never collapse"* commitment is preserved; only the visible slot is reassigned under cap pressure when no recommendation endorses them. K_pick ≤ 2 (option count ≤ 4) skips conditional inclusion entirely — both structural slots are always shown. **Disclosure**: when conditional inclusion fires, the Why-it-matters companion text discloses the dropped picks (branch a, format `옵션 캡(4)으로 <K_pick>개 픽 중 <X>건 생략 — 생략 픽: <label1>, <label2>, ...`) or the Other-channel reachability of `보류`/`팀 토론 진행` (branch b, format `보류·팀 토론 진행은 Other 채널에 '보류' 또는 '팀 토론 진행' 입력 시 동일 처리.`) so the user audits the option-set difference. Branch (b) carries the Other-channel disclosure whenever conditional inclusion fires (`K_pick ≥ 3`), and additionally appends the dropped-picks disclosure when `K_pick > 4`. **Multi-session consistency**: the cascade is stateless — re-computed from scratch on each AskUserQuestion call, no drop-state persistence in the doc.

**Mid-flight reclassification**: if auto-investigation reveals a category change (UC→UD/UR, UA→UD), the lead Edits the doc's `Category` field, surfaces with the new menu, and re-applies the new category's confident criterion. **Investigation-time only**: once `AskUserQuestion` has entered `awaiting-decision`, the prompt is immutable; if reclassification surfaces late, the lead applies one of two fallbacks. **(i) Apply-then-defer** (when the user response is `보류` only): apply the user's 보류 as the resolution, Editing `Category` field first, then `상태: 보류 + 사유` where `사유` is always lead-generated in the canonical defer-branch form `사유: 사용자 결정 보류 (<date YYYY-MM-DD>) (재분류됨: <old-cat> → <new-cat>)` (no user-reason-collection branch — there is no free-text input channel; the `<date>` stamp + `사용자 결정 보류` prefix are mandatory per the cross-issue defer convention). **(ii) Immediate-defer** (default for any other response, including `팀 토론 진행`): `상태: 보류` + `사유: 재분류 필요 — 다음 walkthrough에서 처리`; the user's response is discarded because original-category interpretation can be invalid under the new category (team-spawn flow especially is category-coupled and would synthesize under wrong category if (i) were used). The lead's text response discloses the reclassification to avoid silent doc mutation, with distinct messages per case — case (i): *"방금 보류 결정을 적용했습니다. 참고로 이 이슈의 Category가 <old> → <new>로 재분류되었습니다."*; case (ii) (the consequential one — a discarded user selection must be explained): *"재분류(<old> → <new>)이 발견되어 이 이슈는 다음 walkthrough에서 새 카테고리로 다시 surface됩니다. 방금 선택하신 응답은 새 카테고리의 메뉴 의미가 다를 수 있어 적용하지 않았습니다."*

**Team-spawn coupling**: recommending `팀 토론 진행` does NOT preload the team composition into this `AskUserQuestion` prompt — the role/scope/model proposal remains the separate downstream step described in the Team Spawn Flow below, preserving the two-layer approval (entry into the team flow vs. composition approval). **Display-layer fence**: the entire recommendation mechanism is a display-layer concern on `awaiting-decision`: no new states, no doc markers, no transition edges, no checkpoint format changes.

#### Description requirements

Every option in a per-category `AskUserQuestion` menu carries a 1-line `description`. For the recommended option (when present), the description follows the format `<semantics> — 추천 근거: <evidence with ≥1 citation token>` and must satisfy the citation-token allowlist + denylist rule defined in the **Lead recommendation policy** paragraph above. For all other options (non-recommended in a recommended menu, and all options in an inconclusive menu), the description is a static 1-line semantics text fixed per label as tabulated below. **This table is the single source of truth for static option semantics** — when the per-category option menu's decision branches (the menu table preceding this subsection) are amended, the static description for the affected label MUST be updated atomically in the same edit.

| Label | Static description |
| --- | --- |
| 수용 | 현재 트레이드오프를 인정하고 해결됨으로 표시합니다. |
| 재설계 | 보류 처리 후 Step 6 refinement에서 재설계합니다. |
| 보류 | 지금 결정을 미루고 나중에 처리합니다. |
| 팀 토론 진행 | 전문 팀을 구성해 이 이슈를 심층 논의합니다. |
| 맞음 | 가정이 정확합니다. 해결됨으로 표시합니다. |
| 다르게 수정 | 가정 내용을 직접 수정합니다. |
| 더 논의 | 리드와 추가 대화를 진행한 뒤 결정합니다. |
| 확인 | 이 항목을 문서에서 즉시 삭제합니다. |
| 그래도 유지 | 이 항목을 유지하고 정상 UC 메뉴로 진행합니다. |
| UD concrete picks | `<해당 값>으로 확정합니다.` (dynamic — `<해당 값>`은 이슈가 surface한 개별 pick 라벨) |
| UA option picks | `<option name>으로 구현합니다.` (dynamic — `<option name>`은 이슈가 surface한 개별 alternative 라벨) |

**Dynamic pick recommendation form** (UD/UA concrete pick이 추천 옵션일 때): 위 dynamic static template (`...합니다.`)을 그대로 description에 쓰지 않고, `<semantics>` slot에 verb-stem 형태 (trailing `합니다.` 제거) 로 변환한 뒤 recommended-option format 적용한다. UD 예: `<해당 값>으로 확정 — 추천 근거: <evidence>`. UA 예: `<option name>으로 구현 — 추천 근거: <evidence>`. trailing 마침표 제거는 em-dash separator의 명확성을 보존하기 위함이며, `<semantics>` slot의 ≤10 음절 budget 적용 (긴 `<해당 값>` / `<option name>` 라벨의 경우 ≤10 약간 초과 가능; 의미 명확성 우선).

**Dropped-confirm prompt exception** (third description type): the UC false-positive prompt's `확인` option uses a hybrid format — `<static semantics> — 근거: <false-positive evidence> (<path:line>)` — with the `근거:` prefix (not `추천 근거:`) signaling fact statement rather than recommendation. The citation/denylist rules of the **Lead recommendation policy** paragraph do NOT apply (the `확인` label has no `← 추천` suffix per the dropped-confirm carve-out); the evidence segment is descriptive rather than rationale. The hybrid form inherits the recommended-option ≤140 chars / ≤2 sentences hard limits; if the evidence path exceeds budget, prefer a shorter `§<anchor>` citation or relative path over the absolute path.

**Team spawn flow** (when the user picks "팀 토론 진행"):

1. The lead proposes a role/scope/model composition for that issue in Korean → user approval. If the user rejects or asks to revise the composition, the lead either (i) re-proposes a revised composition (repeatable), or (ii) if the user withdraws "팀 토론 진행", returns to that category's normal terminal option menu (direct resolution / defer / (UC only) drop branch / (UR only) redesign / (UC only) discuss-further, per category). **UC exposes "보류" directly in this fallback**: the user already engaged the issue actively via the team-spawn proposal, so UC's initial-menu gate (forcing auto-investigation review) no longer applies — the fallback's "보류" is deliberately directly reachable.
2. Spawn a `design-<slug>-refine-N` team (N = `max + 1` per file-system enumeration).
3. English discussion → synthesis → the lead Edits the doc to reflect the decision. **Team result → state mapping**: (a) team agrees on a single resolution → `상태: 해결` + decision reflected in the doc body; (b) team agrees on "recommend deferral" → `상태: 보류` + reason `팀 토론 결과 추가 검토 필요`; (c) team finds depth-2 items → the doc-first handling above (recorded as separate entries + accumulated in the parent's announce); (d) team agrees a UC issue is a false positive → route to the dropped-confirm prompt above (entry REMOVED after user confirmation). In all cases the doc Edit completes before the team-cleanup in step 4.
4. **Before entering the next issue or ending the walkthrough**: Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and perform the 5-step shutdown.
5. Proceed to the next queue item.

#### refine-N Counter (shared)

- N increases monotonically by file-system enumeration:

  ```bash
  LATEST=$(ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null \
    | grep -E "^design-<slug>-refine-([0-9]+)$" \
    | sed -E 's/.*refine-([0-9]+)$/\1/' \
    | sort -n | tail -1)
  N=$(( ${LATEST:-0} + 1 ))   # ${LATEST:-0} fallback: N=1 on first spawn (no match)
  ```

- Step 5 (walkthrough) and Step 6 (refinement) share the same counter.
- A gap in N after cleanup is fine — only uniqueness matters.
- Step 6's existing entry state-check regex (`^design-<slug>(-refine-[0-9]+)?$`) matches both walkthrough-spawned teams and refinement teams unchanged.

#### Abort Semantics

- Abort is detected by lead judgment (no regex matching). Examples:
    - Full abort: "그만", "중단", "이만 됐어", "리파인먼트로 넘어가자", "skip rest".
    - Single-issue skip: "이건 패스", "다음 이슈", "이건 나중에". On a skip, mark only the current issue `상태: 보류` + `사유: 사용자 per-issue skip, <skip date YYYY-MM-DD>` (distinguishable from the full-abort reason) and proceed to the next queue item. **Active team handling**: if a walkthrough-spawned team is active at skip time, perform the `_common/team-cleanup.md` 5-step shutdown before entering the next queue item — the same cleanup obligation as the full-abort path (cleanup-anchor doctrine).
- On full abort, in ONE batched Edit mark all remaining `대기` / `조사중` / `결정대기` items `상태: 보류` + `사유: 사용자 조기 종료, <abort date YYYY-MM-DD, runtime-generated>`, then enter Step 6. (CFI-2)
- If a walkthrough-spawned team is active (spawned, cleanup not yet done) at abort time, clean it up via the `_common/team-cleanup.md` 5-step shutdown *before* the batch `보류` Edit. The issue in progress is included in the batch and marked `상태: 보류`.
- If the user is viewing a UC dropped-confirmation prompt at abort time, the drop is auto-cancelled and that issue is kept in the doc, included in the batch as `상태: 보류` + `사유: 사용자 조기 종료 (drop 미확정, 재호출 시 재표면)`. No item is ever silently deleted without the user's explicit drop confirmation.

### Step 6: Plan Refinement with User

**State check on entry**: If any team associated with this design workflow is still active (Step 3 original team, any prior walkthrough-spawned team (from Step 5), or any prior Step 6 refinement team), notify the user in Korean (*"이전 단계의 팀이 아직 살아있어 정리 후 리파인먼트를 시작하겠습니다."*), then execute cleanup now (Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and follow the 5-step shutdown procedure) before any Step 6 activity. Detect active teams by enumerating `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/` via Bash with a slug-specific regex: `ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null | grep -E "^design-<slug>(-refine-[0-9]+)?$"`, where `<slug>` is recovered from the saved design document filename in `docs/` (the filename encodes the topic slug per Step 4's save convention — local file-system state, not memory). **Preferred slug recovery**: the lead remembers the exact filename it saved in Step 4 (not mere "most recent .md file" — that may be unrelated to the design workflow if the project is actively edited elsewhere). If the lead cannot recall the exact filename, fall back to matching against `docs/` modification times within a narrow window after Step 4, and if still ambiguous (multiple candidates), prompt the user via `AskUserQuestion` to confirm the target document. Never assume the most recently modified `docs/*.md` is the design doc without validation. This matches only the Step 3 original team name (`design-<slug>`) and all refinement teams (`design-<slug>-refine-N`) for the current workflow's topic, **without** cross-matching unrelated prior-session teams on other topics. Any matching directory that corresponds to a team created in this session is treated as active and requires cleanup. Under normal flow, all prior teams are already dead and this step proceeds with the lead only. **Worktree gate (in-session verification cleanup)**: also run the two-command boundary gate (`_common/verification.md` §6) on entry — main `git status --porcelain` == baseline and `git worktree list --porcelain` shows 0 `cc-design-exp-` entries; force-remove (`git worktree remove --force`) + `git worktree prune` any mechanism-owned worktree that leaked from a prior step before proceeding.

- On entering Step 6, emit ONE short Korean notice that the design document is ready for refinement and invite the user's input, then YIELD the turn and wait for the user's reply. At Step 6 ENTRY do NOT call `AskUserQuestion` to open the discussion or manufacture a refinement question (e.g. '무엇을 다듬을까요?'). Once the user replies, discuss the design document with them in Korean and refine the plan together. (CFI-2)
- Lead-only by default: doc edits, user Q&A, and codebase re-exploration require no team.
- If the user raises questions requiring deeper investigation that exceed lead-only capacity, verify no prior workflow team is still active (if one remains, notify in Korean: *"새 리파인먼트 팀을 만들기 전에 기존 팀을 먼저 정리하겠습니다."* and execute cleanup), then propose composing a **new** team for that specific investigation — mirror Step 2 (role/scope/model proposal → user approval → spawn). **Never reuse or restart any prior design team.**
- Only create a new team if the user approves. Otherwise, continue refining in the current session.
- If a new team is created, name it `<original-team-name>-refine-N` where N continues the sequence from any walkthrough-spawned teams (if none were spawned, N starts at 1) (e.g., `design-auth-flow-refine-1`, `design-auth-flow-refine-2`). Conduct internal discussion in English. After discussion converges and results are synthesized, update the saved document in `docs/`. Then notify the user in Korean: *"리파인먼트 팀을 정리한 뒤 후속 논의를 이어가겠습니다."* **Before creating the next refinement team or returning to user discussion, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure for that team. Present the updated results to the user in Korean.
- Repeat until the user is satisfied with the plan.

## Constraints

- NO code modifications. Design discussion only.
- Inter-agent communication must be in English.
- **Agent Team required**: Steps that involve team creation and inter-agent discussion MUST use TeamCreate and SendMessage tools. Do NOT substitute with Agent tool sub-agents. The team discussion requires real-time inter-agent communication (debate, challenge, cross-validation) which is only possible through Agent Teams, not isolated sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (user interview). Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

### Observation & verification carve-out (running + experimenting ≠ modifying)

The "NO code modifications" rule above and in Step 3 is **absolute and unweakened** — but "modification" has a precise definition that makes both reproduction (running the unmodified app/test suite) and in-session verification (out-of-tree experiments and isolated-worktree mini-implementations) fully compatible with it. This carve-out is a *definition*, not an exception: the two literal "NO code modifications" strings stay literally true everywhere. The full operating mechanics live in `${CLAUDE_SKILL_DIR}/../_common/verification.md` §6 (Read it); the compression-critical core is restated here.

- **What "modification" means**: a change that **persists in the session's main working tree**. (In git vocabulary an experiment worktree is also a "working tree", so the scope is the *main* tree specifically.) Running the app/test suite as-is, an out-of-tree driver, or an isolated-worktree experiment that is torn down — none persists a change to the main tree, so none is a modification.
- **FORBIDDEN**: editing any tracked source file **in the main working tree** — even transiently, even "I'll revert it after." There is no in-tree print-logging exception.
- **Two-command boundary gate** (this replaces the old single-invariant advertisement — scope is per-surface): at every team-discussion boundary check, in order, (1) main tree `git status --porcelain` == the pre-workflow baseline, and (2) `git worktree list --porcelain` == the pre-workflow baseline — porcelain does not see records inside `.git/worktrees/` (the F1 blind spot), so the worktree list is a separate gate — plus a belt-and-braces assertion of 0 `cc-design-exp-` prefixed entries (proves mechanism-owned cleanup even if a baseline string is lost to compaction, and never condemns the user's own pre-existing worktrees). Step 4's design-document save (`docs/{slug}.md`) is the skill's normal sanctioned tracked-file write and is NOT subject to this gate.

**Surface 1 — main working tree** (reproduction + categories a/b/c/d): today's rules, unweakened.

- **ALLOWED**: executing the unmodified app, running the existing test suite, attaching a debugger, raising verbosity via existing flags/log levels, importing project modules from an out-of-tree driver, and (for category (c)) WebFetch / WebSearch / external CLI. All artifacts, drivers, and logging route to a `/tmp` sink or existing verbosity/CLI flags — strictly outside the working tree.
- **Cleanup boundary — "before findings leave their producer"**: whoever produces a finding or a verification verdict (the lead, the reproduction agent, or the verification agent) must, *before* it leaves in any form (whichever comes first: a broadcast, a verdict-citing SendMessage, a `[COMPLETE]` return, or a doc Edit), revert all instrumentation, delete every out-of-tree artifact, and verify the two-command gate == baseline. There is no window in which the tree is dirty while a finding/verdict is visible to another agent. The lead is the backstop: re-verify before the Step 4 save (the pre-save sweep).
- **Environment vs. working tree (lockfile checklist)**: the gate is scoped to tracked source only. Verification/reproduction may install dependencies and produce build output: (1) gitignored build output (`node_modules`/`dist`/`.next`/`build`) is out of scope — never appears in porcelain; (2) an install that rewrites a **tracked lockfile** (`package-lock.json`/`poetry.lock`) or tracked codegen path must NOT persist — use a non-rewrite form (`npm ci`, `npm install --no-save`, venv) or revert before the boundary; (3) the pass/fail gate at every boundary is the two-command gate == baseline.

**Surface 2 — isolated worktree (category (e) only)**: for a mini-implementation whose observation unavoidably requires changing tracked content *and* repo-faithful context (the α∧β condition in `_common/verification.md`). Compression-critical locks (full mechanics in `_common/verification.md` §6.2):

- **Create** with `WT=$(mktemp -d "${TMPDIR:-/tmp}/cc-design-exp-<slug>.XXXXXX")` then `git worktree add --detach "$WT" HEAD`. `mktemp` + `--detach` are MUST. **EnterWorktree is forbidden** (its only-if-unchanged auto-cleanup guarantees a leak for a changed worktree); the Agent-tool isolation form is forbidden.
- **In-worktree FORBIDDEN**: no commit / branch / push / tag / `git config` write / hook install / gc·maintenance / **stash** (`refs/stash` is a shared namespace — an in-worktree stash survives worktree removal in the main repo's `git stash list`, a porcelain-invisible leak).
- **Lifetime**: from claim pre-registration to that claim's verdict broadcast; no persistence across re-convergence (regenerate from the recipe — deterministic since the main tree is frozen). One experiment = one worktree, never shared across agents.
- **Final-run rule**: a verdict is backed only when the recorded recipe's patch, applied on a clean reset (`cd "$WT" && git checkout -- . && git clean -fd` — the single inseparable line; run from the wrong cwd it destroys the user's main-tree untracked files), is observed to match the recorded `관측 결과`.
- **Cleanup**: `git worktree remove --force "$WT"` + `git worktree prune` + list-vs-baseline, before the verdict ships. Lead backstop: the pre-save sweep and the Step 6 entry state-check add the two-command gate.

- **CFI impact: none** — quality tier (a missed application is quality degradation, not a mis-transition). Nothing is added above the `## Control-Flow Invariants` heading.

Task: $ARGUMENTS
