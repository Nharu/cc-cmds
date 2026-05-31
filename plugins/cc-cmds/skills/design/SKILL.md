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
- Iterate between interviewing and codebase exploration until all critical aspects are sufficiently covered, then confirm with the user before proceeding.

### Step 2: Team Composition Proposal (Korean)

- Based on interview results and codebase exploration, propose a team composition to the user.
- Specify each teammate's role, exploration scope, and model (use short aliases: `"opus"`, `"sonnet"`, `"haiku"`).
- Only create the team after the user approves the composition.

### Step 3: Design Discussion (English, internal only)

**Before assigning any team work, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`.** Apply the completion-signal instruction and facilitator rules from that file throughout this step. When you assign work to each teammate via SendMessage, include the Teammate Rules block from `_common/agent-team-protocol.md` **verbatim in the assignment body** (the block-quoted teammate-facing instruction under the `## Teammate Rules` heading) — do NOT paraphrase to a one-liner. The short form is the documented cause of teammates emitting `[COMPLETE]` as text instead of via SendMessage.

- Create the team with the approved composition. Name it `design-{topic-slug}` (e.g., `design-auth-flow`, `design-payment-system`).
- All inter-agent discussion and reasoning should be conducted in English.
- NO code modifications allowed. Design discussion only.
- **The lead acts as a facilitator**, actively driving multi-round discussion. Do NOT passively wait for results and move on.

#### Discussion Protocol (minimum 2 full rounds)

1. **Round 1 — Initial Proposals**: Assign each teammate their design scope. Wait for ALL teammates to submit `[COMPLETE]` proposals before proceeding. If a teammate sends `[IN PROGRESS]`, reply with "Take your time and send your complete analysis when ready" — do NOT move on.
2. **Quality Gate**: Before proceeding to cross-review, verify each proposal meets minimum depth:
   - References specific files, modules, or patterns from the actual codebase (not generic advice)
   - Includes concrete design decisions with rationale (not just listing options)
   - If a proposal is too shallow or generic, send it back with specific questions asking for deeper analysis
3. **Cross-Review**: Send each teammate's proposal to the other teammates for review. Explicitly ask them to identify gaps, risks, contradictions, and alternative approaches.
4. **Round 2+ — Refinement**: Collect cross-review feedback and send it back to the original authors. Ask them to address the feedback, revise their proposals, and respond to challenges. Repeat this cycle until convergence.
5. **Convergence Check**: Use the convergence-check template from `_common/agent-team-protocol.md`. Only proceed to Step 4 when ALL teammates confirm `[COMPLETE]`.

### Step 4: Result Synthesis & Documentation (Korean)

- The lead synthesizes all discussion results into a structured Korean document:
    - 합의된 아키텍처
    - 주요 결정사항과 근거
    - 미해결 이슈 / 트레이드오프
    - 권장 구현 순서
- **Synthesis terminal**: All teammate clarifications must be completed before saving the design document. Once the file is saved, the synthesis phase is over — no further teammate messages are permitted. Do NOT save a partial document, send a teammate message, then save again; clarify before the first save. The sequence save → cleanup → presentation is atomic. Step 5 (walkthrough) and Step 6 (refinement) are new editing phases governed by their own state-check + cleanup rules. The synthesis-terminal rule bars further Step 3 team messages but does NOT bar lead-driven Edits to the saved doc.
- Save the design document to the project's `docs/` directory. **File naming convention**: use `docs/{topic-slug}.md` where `{topic-slug}` matches the Step 3 team's topic slug exactly (e.g., Step 3 team `design-auth-flow` → saved doc `docs/auth-flow.md`). This filename-to-slug binding is the local state used by Step 5's entry state-check to recover the slug without relying on lead memory. **Interrupted-save case**: if the save itself was interrupted (partial write, permission error, etc.), the state-check cannot recover the slug from the filename. In this case the lead must either (a) recover the slug from the original task input or interview output that started the workflow (from in-session conversation history, including slash-command `$ARGUMENTS` if invoked that way), or (b) treat the workflow as ambiguous and prompt the user via `AskUserQuestion` before any cleanup action.
- Notify the user in Korean: *"설계 문서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Before presenting results to the user, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure to clean up the design team.
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
    - UR: Read the tradeoff framing only.
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

**Recommendation contract**: the lead applies `AskUserQuestion`'s native recommendation contract — append `← 추천` to the recommended option's label, force it to position 1, and place the rationale in that option's `description` field. The description follows the format `<semantics> — 추천 근거: <evidence>` where `<semantics>` is a brief (≤10 Korean syllable) action/result summary (긴 UD/UA pick label로 인해 ≤10 음절을 약간 초과해야 의미 보존이 가능한 경우 soft over-flow 허용 — semantic clarity가 우선) and `<evidence>` carries the rationale. The description MUST be ≤2 sentences, ≤140 chars, and `<evidence>` MUST carry at least one citation token (code path `:line`, `§<anchor>`, a quantitative measurement such as `affected files: 4` / `~4×` / `12/12 hits`, or a blocker fact `requires X, absent in <evidence path>`). Opinion phrases (`cleaner`, `simpler`, `idiomatic`, `common practice`, `I think`, `feels like`) are forbidden unless paired with a citation token in the same sentence; this citation/denylist rule applies only to descriptions of options carrying `← 추천` — static descriptions on non-recommended options are display-only and exempt. All four options are eligible candidates — including `팀 토론 진행` and `보류` — provided their confidence criterion is met. When the criterion fails (grep results split outside 80/20, cost delta within 1.5×, no parallel anchor for UD, mixed UR impact, NONE-good without a gap citation, any auto-investigation hard limit tripped), the lead refuses to recommend: Why-it-matters surfaces *"조사 inconclusive — 사용자 판단 필요"* and the menu renders in default order with no `← 추천` suffix. Why-it-matters never duplicates the rationale (that lives only in the recommended option's `description`); when confident it is framed as *"결정만 내리면 적용 가능"*.

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

**State check on entry**: If any team associated with this design workflow is still active (Step 3 original team, any prior walkthrough-spawned team (from Step 5), or any prior Step 6 refinement team), notify the user in Korean (*"이전 단계의 팀이 아직 살아있어 정리 후 리파인먼트를 시작하겠습니다."*), then execute cleanup now (Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and follow the 5-step shutdown procedure) before any Step 6 activity. Detect active teams by enumerating `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/` via Bash with a slug-specific regex: `ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null | grep -E "^design-<slug>(-refine-[0-9]+)?$"`, where `<slug>` is recovered from the saved design document filename in `docs/` (the filename encodes the topic slug per Step 4's save convention — local file-system state, not memory). **Preferred slug recovery**: the lead remembers the exact filename it saved in Step 4 (not mere "most recent .md file" — that may be unrelated to the design workflow if the project is actively edited elsewhere). If the lead cannot recall the exact filename, fall back to matching against `docs/` modification times within a narrow window after Step 4, and if still ambiguous (multiple candidates), prompt the user via `AskUserQuestion` to confirm the target document. Never assume the most recently modified `docs/*.md` is the design doc without validation. This matches only the Step 3 original team name (`design-<slug>`) and all refinement teams (`design-<slug>-refine-N`) for the current workflow's topic, **without** cross-matching unrelated prior-session teams on other topics. Any matching directory that corresponds to a team created in this session is treated as active and requires cleanup. Under normal flow, all prior teams are already dead and this step proceeds with the lead only.

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
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (user interview).

Task: $ARGUMENTS
