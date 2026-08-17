# Residual Disclosure Block

Consumed by Step 7. Composing this block and passing its four checks is the **only** way out of the invocation (CFI-5).

**Why a fixed budget plus disclosure, instead of a coverage target.** A coverage target derived from a per-reader detection probability was tried and failed: the detection model is statistically rejected for this population, and the defect-pool profile likelihood is unbounded above, so whether a coverage target was met is not decidable even with unbounded budget. That is not a specification. A fixed budget with mandatory disclosure is decidable — it hands each residual to a **named downstream owner** instead of hiding it behind a number, adds **zero** raw items to the single-pass reconciliation load, and costs a constant few minutes regardless of `READER_COUNT`.

## Grammar

Written into the audit report as a `## 잔여 공개` section.

```markdown
## 잔여 공개

<!-- cc-design-audit-disclosure v1 begin -->
**동결 문서 sha256**: <64 hex>
**동결 시각**: <ISO 8601 with offset>
**리뷰어 수**: <n>
**원시 발견 수**: <n>
**고유 결함 수**: <n>
**미보강 잔여 수**: <n>
**라우팅 — 조정 패스 적용**: <n>
**라우팅 — 미해결 이슈**: <n>
**라우팅 — implement 사전 게이트**: <n>
**라우팅 — design-conformance**: <n>
**라우팅 — 기각**: <n>
**하류 흡수 가정**: <one line — see below>
**조정 패스 시작**: <ISO 8601 with offset>
**조정 패스 종료**: <ISO 8601 with offset>
**결손 수**: <n>
<!-- /cc-design-audit-disclosure v1 end -->
```

Rules (this is check (iv)):

- The two HTML-comment fences are **byte-exact literals**, appear **exactly once each**, in this order, with **exactly 15 slot lines** strictly between them — in exactly this order, one per line, no blank lines, no extra keys, no missing keys.
- Every slot line matches `^\*\*[^*]+\*\*: .+$` — the canonical field rendering of the shared verification contract: bold key, no leading bullet, exactly one ASCII space after the colon.
- Value shapes: sha256 `^[0-9a-f]{64}$`; timestamps `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$`; counts `^[0-9]+$`.
- The five routing lines are **fixed arity** — one line per named owner, always present, `0` when empty. Fixed arity is what makes per-owner routing machine-checkable instead of a free-form list, and it is also what makes triage collapse self-reporting: a `기각` of 0 beside a large `적용` is the signature of the failure mode this command was built to remove.

**하류 흡수 가정** must be non-empty and must name the two downstream absorbers and the fact that the rate is unmeasured. The reason it is a slot rather than prose elsewhere: this whole design assumes downstream absorbs a substantial share of the standalone-detectable residuals, and an assumption recorded as prose fails exactly at the moment it is relied upon. As a slot it is re-stated on every single run.

## The four anti-vacuity checks

**(i) Hash binding.** `동결 문서 sha256` matches `^[0-9a-f]{64}$`, is byte-equal to the `frozen-sha256` recorded in the same report's `## 감사 개시` block (written before the first reader spawned and never rewritten), and the report's header `owner-doc=` equals the **document key** of the document under audit. *Blocks a block copied from another document's audit* — the copy carries the wrong document key and the wrong hash pair.

**(ii) Execution evidence.** The number of in-tree reader reports equals the `리뷰어 수` slot **minus** the `결손 수` slot, and `리뷰어 수` equals the `READER_COUNT` read **from SKILL.md's CFI-0 constants block** — never from this block and never from a spawn prompt. Every reader file carries the matching `owner-doc=` and a non-empty anchor table with at least one row. *Blocks a pre-written block with no readers actually run.*

**`결손 수` is bounded here, in the same check that reads it.** Two constraints, and they ship together with the rescale in (iii):

- `0 ≤ 결손 수 < 리뷰어 수` — **strict**, and the strictness is the whole of the total-shortfall exit below
- `결손 수 > 0` implies the declared-shortfall line described in (ii-b) exists

Without them the rescale is a **relaxation handle**: `결손 수` appears in no other check, so a value invented to make the arithmetic work would satisfy every invariant it touches. The bound belongs in this check rather than in (iii) because this is where `리뷰어 수` is bound to `READER_COUNT`; a copy of that binding in (iii) would be a second place to keep in sync.

**(ii-c) Total shortfall is not a shortfall — it is an audit that did not happen.** `결손 수 == 리뷰어 수` means **no reader produced a usable witness**. Measured on the pre-fix text: a block reading `리뷰어 수 = 결손 수 = 3` with every other integer 0 satisfied **all four** anti-vacuity checks — the rescaled floor `원시 ≥ 리뷰어 수 − 결손 수` collapses to `원시 ≥ 0`, `고유 ≥ 1 whenever 원시 ≥ 1` is vacuous, the routing lines sum to 0 = `고유`, and the timestamps order fine. The block then asserts, structurally validly, that nothing was audited.

So this state has **no valid block**. It is not written, not declared, and not passed: the run **aborts and reports**, and the disclosure block is not the exit. The reason it needs saying rather than following from (ii-b) is that (ii-b) reads as a general licence to declare any shortfall, and a total one is the single value where declaring it produces an artifact that certifies its own emptiness. The upper bound above is strict for exactly this reason — the invariant and this paragraph are one rule stated twice, and the bound is what a checker evaluates.

**(ii-b) Declared shortfall.** Where a reader produced no usable witness and the Case-1 recovery did not close the gap, the count of in-tree reader reports is legitimately **below** `READER_COUNT`. That case is declared, never absorbed: the `결손 수` slot carries the shortfall and the line immediately after the block states **결손 사유** in one sentence. A shortfall reported this way satisfies (ii); a shortfall that merely lowers `리뷰어 수` to match the reports does not, because it makes an audit run by fewer readers indistinguishable from one that was budgeted for fewer. **The arithmetic that bounds `결손 수` lives in (ii)**, next to the `READER_COUNT` binding it depends on; the defect this arm had was never that no fail-loud exit existed, but that the arm (ii-b) added was self-invalidated by (iii)'s unrescaled floor. **The slot count is itself the fence**: the block declares exactly 15 slot lines, so removing this arm's slot cannot be done quietly — the count assertion sees it. Without a pin, a relaxation and a deletion are textually indistinguishable a few months later.

**(iii) Arithmetic invariants.**

- `원시 ≥ 고유 ≥ 미보강 ≥ 0`
- `원시 ≥ 리뷰어 수 − 결손 수` — the readers that actually ran. Unrescaled, this line and (ii-b) contradicted each other: (ii-b) forbids lowering `리뷰어 수` to match a short run, and this floor grows with `리뷰어 수` regardless of how many readers produced a witness, so a declared shortfall could reach a state with no exit — the block is the only way out of the audit and this invariant admits no relaxation. Reachable rather than universal: it needs a nearly clean document and a shortfall in the same run.
- `고유 ≥ 1` whenever `원시 ≥ 1`
- the five routing lines sum to `고유 결함 수` — every unique defect routed exactly once
- `동결 시각 ≤ 조정 패스 시작 ≤ 조정 패스 종료`

*Blocks an all-zeros block* — **but only together with (ii)'s bound.** This paragraph is written against the RESCALED floor and must be re-read whenever that floor changes: it previously quoted `원시 ≥ 리뷰어 수`, the pre-rescale form, and in that state it was the only text standing between the reader and a fully vacuous block. A stale rationale beside a live invariant is worse than no rationale, because it reads as confirmation.

**Known conservative bias, stated rather than hidden**: a run in which every reader that ran genuinely found nothing trips `원시 ≥ 리뷰어 수 − 결손 수`. The disposition is to **fail loud and surface**, not to relax the invariant — a run where a reader found nothing is precisely the run a human should look at, and weakening a pinned invariant to accommodate it re-opens the all-zeros hole. **The bias is bounded by (ii)'s strict upper bound**: it can only ever fire on a run that had at least one reader, because a run with none is not a block to check but an abort.

**(iv) Slot grammar.** As specified above: fences, count, order, key set, per-key value shape — **and the one content requirement the grammar carries**: `하류 흡수 가정` must be non-empty, must name the two downstream absorbers, and must state that the rate is unmeasured. That requirement is enumerated here rather than left upstream because **this definition is what a runner applies**: with only the shape rules restated, the block's single prose slot passed the anti-vacuity checks on an arbitrary single character, and the one slot that exists to keep a load-bearing assumption re-stated on every run was the one slot nothing checked.

## Honest limit

The four checks fence the block's **structure**. The **truth** of the recorded integers cannot be checked: a lead that runs the readers and then writes plausible-but-wrong numbers passes all four. This is the deliberate split — garbage output is fenced structurally, interpretable misjudgment is left to prose. Do not add a fifth check that pretends otherwise, and do not delete this paragraph to make the mechanism look stronger than it is.

## Writing the block

The block is written into the audit report, so this write carries the report's terminator duty — **by reference**: SKILL.md fixes the sentinel and requires every write to the report to re-emit it as the last non-empty line. Restating the sentinel here would create a second place to keep in sync, and the block already has enough byte-exact literals to keep.

## Korean echo

After writing the block, echo it to the user in Korean with the routing lines rendered as a short list and the two timestamps rendered as an elapsed duration, followed by the next-step line and the terminal statement of Step 7.
