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

## Synthesis question (mandatory terminal act)

The pass may NOT close by dispositioning items one at a time. Its final act is to ask, once, in writing, and answer in the report:

> 이 발견들이 **함께** 함의하는 요구사항이 있는가?

The synthesis question's own answer is never adopted as a routing decision on its own authority: composing findings into a new requirement changes what the run is trying to do, which is `등급 2` under `_common/judgment-grade.md` and therefore escalated rather than adopted.

Different readers' items are individually local fixes but can compose into a new requirement that appears in **no single report** — only the reconciling side sees the composition. If the answer yields a candidate requirement, surface it with at most **one** `AskUserQuestion` (adopt as a requirement / record in the unresolved-issues section / reject). Without this step that class of finding arrives after the hard stop, which is to say it arrives unowned.
