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
<!-- /cc-design-audit-disclosure v1 end -->
```

Rules (this is check (iv)):

- The two HTML-comment fences are **byte-exact literals**, appear **exactly once each**, in this order, with **exactly 14 slot lines** strictly between them — in exactly this order, one per line, no blank lines, no extra keys, no missing keys.
- Every slot line matches `^\*\*[^*]+\*\*: .+$` — the canonical field rendering of the shared verification contract: bold key, no leading bullet, exactly one ASCII space after the colon.
- Value shapes: sha256 `^[0-9a-f]{64}$`; timestamps `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$`; counts `^[0-9]+$`.
- The five routing lines are **fixed arity** — one line per named owner, always present, `0` when empty. Fixed arity is what makes per-owner routing machine-checkable instead of a free-form list, and it is also what makes triage collapse self-reporting: a `기각` of 0 beside a large `적용` is the signature of the failure mode this command was built to remove.

**하류 흡수 가정** must be non-empty and must name the two downstream absorbers and the fact that the rate is unmeasured. The reason it is a slot rather than prose elsewhere: this whole design assumes downstream absorbs a substantial share of the standalone-detectable residuals, and an assumption recorded as prose fails exactly at the moment it is relied upon. As a slot it is re-stated on every single run.

## The four anti-vacuity checks

**(i) Hash binding.** `동결 문서 sha256` matches `^[0-9a-f]{64}$`, is byte-equal to the `frozen-sha256` recorded in the same report's `## 감사 개시` block (written before the first reader spawned and never rewritten), and the report's header `owner-doc=` equals the **document key** of the document under audit. *Blocks a block copied from another document's audit* — the copy carries the wrong document key and the wrong hash pair.

**(ii) Execution evidence.** The number of in-tree reader reports equals the `리뷰어 수` slot, and that equals the `READER_COUNT` read **from SKILL.md's CFI-0 constants block** — never from this block and never from a spawn prompt. Every reader file carries the matching `owner-doc=` and a non-empty anchor table with at least one row. *Blocks a pre-written block with no readers actually run.*

**(iii) Arithmetic invariants.**

- `원시 ≥ 고유 ≥ 미보강 ≥ 0`
- `원시 ≥ 리뷰어 수`
- `고유 ≥ 1` whenever `원시 ≥ 1`
- the five routing lines sum to `고유 결함 수` — every unique defect routed exactly once
- `동결 시각 ≤ 조정 패스 시작 ≤ 조정 패스 종료`

*Blocks an all-zeros block.* **Known conservative bias, stated rather than hidden**: a run in which a reader genuinely found nothing trips `원시 ≥ 리뷰어 수`. The disposition is to **fail loud and surface**, not to relax the invariant — a run where a reader found nothing is precisely the run a human should look at, and weakening a pinned invariant to accommodate it re-opens the all-zeros hole.

**(iv) Slot grammar.** As specified above: fences, count, order, key set, per-key value shape.

## Honest limit

The four checks fence the block's **structure**. The **truth** of the recorded integers cannot be checked: a lead that runs the readers and then writes plausible-but-wrong numbers passes all four. This is the deliberate split — garbage output is fenced structurally, interpretable misjudgment is left to prose. Do not add a fifth check that pretends otherwise, and do not delete this paragraph to make the mechanism look stronger than it is.

## Korean echo

After writing the block, echo it to the user in Korean with the routing lines rendered as a short list and the two timestamps rendered as an elapsed duration, followed by the next-step line and the terminal statement of Step 7.
