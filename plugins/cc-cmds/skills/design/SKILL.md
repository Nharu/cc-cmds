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
- Present the results to the user in Korean.

### Step 5: Unresolved Issue Walkthrough

This step runs automatically and immediately after Step 4's atomic `save → cleanup → present` sequence completes. It is **mandatory** — there is no user prompt to enter it. Its purpose is to drive every unresolved issue in the saved design document to a decision **without waiting for an unprompted user request**, scoped strictly to *issues that cannot be resolved without user input*. Mechanical gaps, false positives, and auto-decidable items are NOT this step's responsibility — they belong to a subsequent `/cc-cmds:design-review` cycle. User-facing communication in this step is Korean; the normative prose below is English.

> "Walkthrough-spawned teams (Step 5) and refinement teams (Step 6) share the `design-<slug>-refine-N` namespace and the monotonic N counter, but differ in scope and lifetime: a walkthrough-spawned team is bounded to a single unresolved issue's decision debate (user-initiated when auto-investigation findings alone don't yield a clear decision) and dies at that issue's resolution; a refinement team handles a user-initiated multi-turn refinement and lives until the user is satisfied. They are not competing entry points — they are the same entry point (user-confirmed `TeamCreate` for a single bounded scope) invoked at two different lifecycle moments. The lead never extends a walkthrough-spawned team into a refinement team or vice versa — the `Cleanup → next spawn` contract is enforced unchanged."

Terminology: throughout this skill use **"walkthrough-spawned team"** (not "walkthrough investigation team"). "Investigation" refers strictly to the lead-only, read-only activity defined below.

#### Trigger & Queue Initialization

- Step 5 begins automatically the instant Step 4's `save → cleanup → present` sequence ends.
- Parse the saved doc's `## 미해결 이슈 / 트레이드오프` section to initialize the issue queue. **Parse contract**: match the heading with the regex `^##\s+(?:[0-9]+\.\s+)?미해결\s+이슈(?:\s*/\s*트레이드오프)?\s*$` — an optional leading section number (`6. `, `10. `, any digit count) and an optional `/ 트레이드오프` suffix are both allowed. On **multi-match**, use the LAST match (synthesis is written top-down, so the deepest occurrence is canonical).
- On **0-match**, surface via `AskUserQuestion` with three options: (a) **add the section and proceed** — the lead creates a `## 미해결 이슈` heading via doc Edit (sub-section form by default, per the encoding rules below), re-parses the doc to rebuild the queue; entries the user pre-added are processed as-is, and 0 entries cascade naturally into the 0-issue path; (b) **skip the walkthrough** and proceed to Step 6; (c) **abort** — the entire design workflow terminates and Step 6 is NOT entered.
- **0 issues**: emit the Korean notice *"미해결 이슈가 없어 곧바로 플랜 리파인먼트 단계로 이동합니다."* and proceed directly to Step 6.
- **1+ issues**: emit *"설계 문서에 미해결 이슈 N건이 확인되었습니다. 하나씩 검토하며 정리하겠습니다."* and enter the walkthrough proper.
- **Depth-2 promotion on queue init**: any entry carrying both `상태: 보류` and a `(깊이: 2)` marker is auto-promoted to depth-1 — the lead Edits the doc to change `상태: 보류 → 상태: 대기` and `(깊이: 2) → (깊이: 1)` together (the `Parent` field is preserved as historical metadata), then appends it to the queue. Plain `상태: 보류` entries (no depth marker, or `(깊이: 1)`) are NOT promoted — those are deliberate user deferrals.
- **Drop-uncertain promotion on queue init**: any `상태: 보류` entry whose `사유:` text contains the substring `drop 미확정` (produced by the abort-during-drop-prompt path below) is also promoted — change to `상태: 대기`, clear the `사유` field, append to the queue. This applies regardless of any depth marker, and re-surfaces issues whose drop confirmation was never completed.
- **Queue order**: doc-order, top-to-bottom. Depth-1 items that surface mid-pass are appended to the *end* of the queue (not inserted right after the current issue) and are reached only after all pre-existing items are processed. No per-category priority ordering.
- After the walkthrough finishes, emit *"미해결 이슈 워크스루를 종료했습니다. 이어서 플랜 리파인먼트를 시작하겠습니다."* and enter Step 6 automatically.
- If the user aborts mid-walkthrough, batch-mark the remaining items `상태: 보류` (see Abort Semantics below) and move to Step 6.

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

For each issue:

1. **Auto-investigation (lead-only, read-only + reproducible)**:
    - UD: Read doc context only.
    - UC: `grep` for the assumed convention in the project's primary source tree (e.g. `src/**`, `plugins/**`, `app/**` — the lead adapts to the project's convention); optional `make test`.
    - UA: Read each option's affected files + cost estimate (line-count delta, etc.).
    - UR: Read the tradeoff framing only.
    - Hard limits: stop as inconclusive if `grep` returns >50 hits; stop if `make test` exceeds 2 min. If the result is inconclusive, surface it as *"조사 inconclusive — 사용자 판단 필요"*.
2. **Surface to the user (`AskUserQuestion`, Korean)** with: a one-line Title; a Category tag (UD/UC/UA/UR — fits the 12-char `header` chip limit); Why-it-matters (1-2 lines); the auto-investigation summary (the findings, or *"조사 불필요"*); Options (the per-category menu below); and a Doc reference (`§ anchor`).
3. **Apply the user's decision**:
    - Direct resolution → mark `상태: 해결` + reflect the decision in the doc body. A UC "다르게 수정" response also maps here (the lead Edits the doc body per the user's correction + `상태: 해결`).
    - Defer → `상태: 보류` + record a reason (format `사유: 사용자 결정 보류 (<date YYYY-MM-DD>)`).
    - Drop (the dropped branch, UC only) → after user confirmation the entry is REMOVED from the doc. **Trigger condition**: branches only in the UC category when the lead's auto-investigation finds the issue is a false positive (already resolved in the doc body / codebase convention matches the assumption). **User-confirmation mechanism**: instead of the normal UC menu, surface the false-positive finding via a **separate `AskUserQuestion`** — body *"이 항목은 §X에서 이미 다뤄지고 있어 미해결 이슈에서 제거하려 합니다."*, options *"확인 (entry REMOVED) / 그래도 유지 (정상 UC 메뉴로 복귀) / 보류"*. On user confirm, Edit the doc to delete the entry — removed immediately, no `상태: 제외` annotation. On "그래도 유지", enter the normal UC menu (맞음 / 다르게 수정 / 더 논의 / 팀 토론 진행). UD/UA/UR have no dropped branch — they require user value judgment, so a false-positive verdict is impossible.
    - Redesign (a UR option) → `상태: 보류` + `사유: 재설계 필요 — Step 6 refinement에서 처리`. The walkthrough does not redesign directly; it defers.
    - Discuss further (a UC option) → an `AskUserQuestion` follow-up loop; the lead continues the dialogue until the user picks one terminal option among "맞음" / "다르게 수정" / "보류" / "팀 토론 진행". It has no terminal state of its own.
    - Run a team discussion → the spawn flow below.

#### Per-category Option Menu + Team Spawn

Each category's user-facing options (Korean; `"팀 토론 진행"` is always last):

| Category | Options |
| --- | --- |
| UD | (1-4 issue-specific concrete picks) + "보류" + "팀 토론 진행". A single concrete pick (binary confirm-only scenario) is also allowed — present the lone option as "이대로 적용 / 보류 / 팀 토론 진행". Picking a concrete pick maps to the "direct resolution" branch above. |
| UA | (option A / option B / ...) + "보류" + "팀 토론 진행". The user's option choice maps to "direct resolution"; the lead records an alternatives-considered note when Editing the doc. |
| UC | "맞음 / 다르게 수정 / 더 논의 / 팀 토론 진행" (initial). **Mapping**: "맞음" → the "direct resolution" branch (the user confirms the lead's assumption interpretation; mark `상태: 해결` but do NOT add a `사유` field — `사유` is reserved for the `보류` state in this spec; instead add the inline note *"사용자 confirm: 가정 정확."* at the end of the doc entry, with the body unchanged). "다르게 수정" → the same "direct resolution" branch. **UC's initial menu deliberately omits "보류"** — to prevent the user from skipping the issue without reviewing the auto-investigation summary; "보류" is reachable only inside the sub-loop after the user explicitly enters dialogue via "더 논의". On "더 논의" the sub-loop is entered, and its terminal option set is "맞음 / 다르게 수정 / 보류 / 팀 토론 진행" — "더 논의" is replaced by "보류" to prevent infinite dialogue. |
| UR | "수용 / 재설계 / 보류 / 팀 토론 진행". Picking "수용" maps to the "direct resolution" branch (`상태: 해결` + a tradeoff-acceptance note in the doc body — `사용자 acknowledged tradeoff: <original tradeoff framing>`). |

**Bias-toward-lead framing**: if the auto-investigation is confident, frame Why-it-matters as *"결정만 내리면 적용 가능"*. If inconclusive, surface the inconclusiveness so the user perceives the value of the team option. The lead **never proactively recommends** a team — a team is spawned only when the user explicitly chooses "팀 토론 진행".

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
- On full abort, in ONE batched Edit mark all remaining `대기` / `조사중` / `결정대기` items `상태: 보류` + `사유: 사용자 조기 종료, <abort date YYYY-MM-DD, runtime-generated>`, then enter Step 6.
- If a walkthrough-spawned team is active (spawned, cleanup not yet done) at abort time, clean it up via the `_common/team-cleanup.md` 5-step shutdown *before* the batch `보류` Edit. The issue in progress is included in the batch and marked `상태: 보류`.
- If the user is viewing a UC dropped-confirmation prompt at abort time, the drop is auto-cancelled and that issue is kept in the doc, included in the batch as `상태: 보류` + `사유: 사용자 조기 종료 (drop 미확정, 재호출 시 재표면)`. No item is ever silently deleted without the user's explicit drop confirmation.

### Step 6: Plan Refinement with User

**State check on entry**: If any team associated with this design workflow is still active (Step 3 original team, any prior walkthrough-spawned team (from Step 5), or any prior Step 6 refinement team), notify the user in Korean (*"이전 단계의 팀이 아직 살아있어 정리 후 리파인먼트를 시작하겠습니다."*), then execute cleanup now (Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and follow the 5-step shutdown procedure) before any Step 5 activity. Detect active teams by enumerating `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/` via Bash with a slug-specific regex: `ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null | grep -E "^design-<slug>(-refine-[0-9]+)?$"`, where `<slug>` is recovered from the saved design document filename in `docs/` (the filename encodes the topic slug per Step 4's save convention — local file-system state, not memory). **Preferred slug recovery**: the lead remembers the exact filename it saved in Step 4 (not mere "most recent .md file" — that may be unrelated to the design workflow if the project is actively edited elsewhere). If the lead cannot recall the exact filename, fall back to matching against `docs/` modification times within a narrow window after Step 4, and if still ambiguous (multiple candidates), prompt the user via `AskUserQuestion` to confirm the target document. Never assume the most recently modified `docs/*.md` is the design doc without validation. This matches only the Step 3 original team name (`design-<slug>`) and all refinement teams (`design-<slug>-refine-N`) for the current workflow's topic, **without** cross-matching unrelated prior-session teams on other topics. Any matching directory that corresponds to a team created in this session is treated as active and requires cleanup. Under normal flow, all prior teams are already dead and this step proceeds with the lead only.

- Discuss the design document with the user in Korean and refine the plan together.
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
