# Reconciliation Pass (single, non-recursive)

Consumed by Step 6. Runs exactly `ADJUSTMENT_PASSES` time over the collected report set.

## Non-recursion rules (hard)

- **No `Agent()` call.** This pass is lead-only. Spawning anything here is the first step back toward the loop this command replaced.
- **No re-opening a dispositioned finding.**
- **The pass's own edits are never treated as new input.** It consumes a fixed, finite set — the collected reader findings plus the deterministic findings — exactly once.

Record the `조정 시작` timestamp as the **first** act of the pass and `조정 종료` as the last. Those two integers are the entire measurement path for the open question of where the single-pass reconciliation limit actually sits: adjustment minutes against raw finding count accumulates as a byproduct of normal operation, and a step change in that curve is the limit that fixes `READER_COUNT`. A cheap measurement replaces an expensive argument, so do not skip the timestamps because the pass felt short.

## Dedup and reinforcement

Two findings are the **same unique defect** when they share an anchor or section AND a root cause. Record each unique defect's **reinforcement multiplicity** — how many readers independently raised it, between 1 and `READER_COUNT`. Multiplicity 1 means unreinforced; those are what the `미보강 잔여 수` slot counts. Deterministic findings carry no multiplicity and are excluded from that count.

## Severity re-assignment (single labeller, one pass)

The lead assigns severity to each unique defect. Readers supply an impact line, not a tier.

- **critical** — semantic violation, silent termination or correctness risk, structural invariant breakage.
- **major** — implementation misbehavior, clear structural mismatch, incorrect cross-section specification, a required artifact that no step creates.
- **minor** — readability, document quality, audit convenience, summary-section synchronization.
- **trivial** — typos, case differences, trivial word choice.

**Never take a maximum across readers.** Per-reader severity labels are not comparable — on one measured document the share of findings a reader called major-or-above varied better than twofold between readers — so a maximum is a ratchet, not a measurement. Since readers emit no tier at all, there is nothing to aggregate; this rule exists so a later edit cannot reintroduce one.

## Routing — five named owners, exactly one each

Every unique defect goes to exactly one owner. The five counts must sum to the unique-defect count, which is what the disclosure block's arithmetic check verifies.

| Owner | What goes here | Carrier |
| --- | --- | --- |
| 조정 패스 적용 | The fix is clear and lands now | The document itself, edited in this pass |
| `## 미해결 이슈` | A real residual the design will not resolve now | An entry in that section with 상태 / Category / Surfaced-at / 소유자 |
| `implement` 사전 게이트 | Only settleable once implementation artifacts exist | A residual item per the shared residual-item contract |
| `design-conformance` | Only answerable after code exists — "did the code match the design?" | Left in place for the post-implementation review to tag |
| 기각 | Not a defect: false positive, out of scope, or hypothetical | A one-line written rationale, recorded |

**기각 requires a written rationale.** That requirement is what makes triage collapse visible: a run whose rejection count is zero beside a large applied count is the exact signature of the failure that killed this command's predecessor, and the fixed-arity routing lines surface it without any extra instrumentation.

### Decision-shaped defects

A **decision-shaped defect** is one whose fix needs a behaviour the binding tier does not fix — a value, a branch, an order, a format, a fallback. Left alone, the implementation would choose it.

- A decision-shaped defect is never routed to `기각`, to the `implement` pre-gate or to `design-conformance`. It has two owners only: `조정 패스 적용`, which writes the decision into the binding tier, or `## 미해결 이슈`, as an entry carrying `**구현 처분**` and its companion field besides the fields above. That holds for a finding outside a re-audit's scope too.
- Rejecting a defect that may be decision-shaped requires the rationale to quote, verbatim, the binding-tier sentence that already fixes the behaviour. A rejection without that quotation breaks this rule.
- Every entry the pass routes to `## 미해결 이슈` carries `**구현 처분**`, chosen by the criteria of `_common/unresolved-closure.md` (`## 값 고르는 기준`) and written in its `## 작성자 꼴`. A defect whose skeleton grade is `예` is written `구현 전 결정`, and so is the unattended audit's synthesis item.
- The interactive audit, too, writes `사유: 감사 합성 요구 — 사람 판단` on a synthesis item the person answered to record as open, so the reader reads it `구현 전 결정` whatever else the entry says.

### Downstream class

Every unique defect not routed to `기각` gets a **downstream class**: the answer to "where would this defect first surface if left unfixed?" The four tags are closed and written byte for byte; their order is the downstream order.

1. `결과물 동일` — it surfaces nowhere. The implementation comes out the same whether or not it is fixed: document wording, a citation, a line number.
2. `구현자 자가 수정` — it surfaces inside the implementation stage and the implementer fixes it there: a failing test, a function or path that does not exist, a contradiction inside the document that the implementer runs into at once.
3. `리뷰 포착` — the implementation passes and the code review catches it.
4. `운영 노출` — the review is unlikely to catch it either; it surfaces only in operation.

- **One labeller.** The lead assigns the class in the same pass that re-assigns severity, from the reader's `**영향**` line and the defect itself; for a deterministic finding the input is what the check found. Readers emit no class.
- **Scope.** Every unique defect except a `기각` one gets exactly one class, deterministic and decision-shaped defects included: a decision-shaped defect is classed for the measurement and leaves only the light path below.
- **When torn between two classes, write the further downstream one.** A wrong class then errs away from the light path, and every audit version leans the same way.
- **Independent of severity.** The class is not derived from the severity, and the severity is not derived from the class.
- **It is the lead's prediction at audit time.** Nothing compares it with the review results of the same run.

**The light path.** A defect takes the light path only when all five hold:

- (a) its class is `결과물 동일` or `구현자 자가 수정`;
- (b) it is not a decision-shaped defect of `### Decision-shaped defects` — a defect that may be decision-shaped counts as one;
- (c) its final owner is `조정 패스 적용`. A `골격급` defect leaves by this condition, because its owner is `## 미해결 이슈`. A defect that would reverse a decision sentence does not take the light path in the interactive audit either, which grades no `골격급`: the value after the reversal is behaviour the binding tier does not fix yet, so it is decision-shaped under (b), and (b)'s rule for a doubtful case leans the boundary the same way. No condition names an arm;
- (d) the fix is already written in full in the reader's `Concept` line (for a deterministic finding, in the check's output), so composing it needs no new read of the repository;
- (e) the evidence floor: the `Evidence` line of a reader that raised the defect states the measured value the defect turns on — a line number, whether a name exists, a count, a string — directly as measured, and that reader's `## 앵커 대조표` row for the anchor carries both a `판정` and an `실측` value. One such reader is enough; the reinforcement multiplicity is not a condition. A defect on no cited anchor, which therefore has no anchor row, and a defect only a deterministic check raised do not meet (e). A defect that does not meet (e) is handled at the current weight whatever its class, and its line reads `일반`.

A decision-shaped defect never takes the light path, whatever its downstream class.

The light path opens no file of CODE_ROOT to check its defect; the design document itself is read and edited as rules 1–4 say.

What the light path does:

1. It opens no repository file for that defect — no `Read`, no `grep`, no `ls`. The reader's `Evidence` line and anchor-table row are the observation.
2. The fix lands by rules 1–4 of `## Applying the pass`, in the same single batch of Edits as every other fix; in the unattended audit, in the working copy's Edit step.
3. The report's adjustment content gives it the one disposition line below with `경량` and no rationale paragraph.

Every other defect is handled exactly as before. The light path changes no owner, and neither the five owners' meaning nor their fixed arity. Whether a defect took the light path is input to no other defect's disposition and to no counter: `경량 처리 수` enters only arithmetic check (iii) of `04-disclosure-block.md`, the structural self-check Step 7 already runs on the routing counts, and it neither adds nor ends a round, so it is not a termination input of the kind CFI-6 forbids.

**Per-defect disposition lines.** Number the unique defects `D1`, `D2`, … in dedup order; the number is used inside this report only. Every unique defect opens with one line:

```
<결함 id> · <제목> · <심각도> · <부류> · <경량|일반> · <처분처>
```

- `<제목>` names the defect in one phrase and never contains ` · `.
- `<부류>` is one of the four tags; a `기각` line writes `-` there.
- `<경량|일반>` is `경량` for a light-path defect and `일반` for every other one, `기각` included.
- `<처분처>` is one of the five owner names of the table above, byte for byte: `조정 패스 적용`, `## 미해결 이슈`, `implement` 사전 게이트, `design-conformance`, `기각`.
- A `경량` line ends there. A `일반` line may carry a rationale after it and needs none, except that a `기각` line carries its written rationale.

Both arms write these lines in the report's `## 조정 패스` section. They replace the severity re-assignments and the routing per owner among the adjustment content of rule 5. The unattended audit's `## 조정 처분` block carries the same lines, copied. The five counts of the downstream fence of `04-disclosure-block.md` are counted from these lines.

## Applying the pass — compose everything, then land it in one batch

Every request re-reads the whole context, so the pass lands its work in as few responses as it can. The owners above and what each one means are unchanged; this section governs only how their results are written.

1. **Disposition first, then compose.** Decide every unique defect's owner before writing anything — its final owner (after a `골격급` grade has moved it), then its downstream class, then whether it takes the light path, by `### Downstream class` — then compose the `old_string` and `new_string` of everything this pass writes to the document. That is four kinds: the fixes routed to `조정 패스 적용`, the entries of the defects routed to `## 미해결 이슈` (every `골격급` defect among them), the residual items of the defects routed to the `implement` pre-gate, and the `## 미해결 이슈` entry a synthesis answer records for a composed requirement. The unattended audit asks and answers the synthesis question in writing, so it composes that entry now too; the interactive audit writes it after the person answers.
2. **One response, several Edits.** Writes that do not depend on one another land together, as several Edit calls in one response, each anchored on text unique in the document. Only a write anchored where another write rewrites waits for the next response.
3. **Compose from what was already read.** Build each `old_string` from the document body already read; do not Read a section again right before its Edit. Only an Edit refused because its `old_string` is not unique sends you to `grep -n` for its location and a Read of that range to widen it.
4. **An accepted fix rewrites the sentence it fixes, in place.** Take the sentence being fixed itself as the `old_string` and write the corrected sentence as the `new_string`; never leave the old sentence standing and append a correction paragraph after it. A new paragraph is written only for a fact no existing sentence carries. The unattended audit's `**미리뷰(스톱 이후 추가)**` marker goes once, in front of the rewritten sentence, and never again in front of a sentence that already carries it. When the rewrite changes a heading, leave the old heading line directly under the new one, as the citation rule for a changed heading already requires. Both audit arms read this file, so the interactive audit follows the same rule.
5. **The report's adjustment content is written once.** The per-defect disposition lines of `### Downstream class` (they carry the severity re-assignments and the routing per owner), the rejection rationales, the synthesis question and its answer, and the `조정 시작` timestamp are composed in full and written in one batch after the document's batch of edits has landed — never per finding. `조정 시작` and `조정 종료` are the values `date` measured, in the same slots and on the same measurement path: `조정 시작` is still measured as the pass's first act, and only its value waits for this batched write. A halt before the batched write carries the value in the report write made before the halt. The interactive audit does the same with no working copy: it lands the batch of Edits on the document, then writes the report's adjustment content.

## Synthesis question (mandatory terminal act)

The pass may NOT close by dispositioning items one at a time. Its final act is to ask, once, in writing, and answer in the report:

> 이 발견들이 **함께** 함의하는 요구사항이 있는가?

The synthesis question's own answer is never adopted as a routing decision on its own authority: composing findings into a new requirement changes what the run is trying to do, which is `등급 2` under `_common/judgment-grade.md` and therefore escalated rather than adopted.

Different readers' items are individually local fixes but can compose into a new requirement that appears in **no single report** — only the reconciling side sees the composition. If the answer yields a candidate requirement, surface it with at most **one** `AskUserQuestion` (adopt as a requirement / record in the unresolved-issues section / reject). If it yields more than one, the candidates are questions ready together, so per the criterion in `_common/askuserquestion.md` they go on at most **one** `mcp__cc-cmds__question_form` form, one question per candidate with the same three options — `AskUserQuestion` stays the surface when the form is unavailable. Without this step that class of finding arrives after the hard stop, which is to say it arrives unowned.
