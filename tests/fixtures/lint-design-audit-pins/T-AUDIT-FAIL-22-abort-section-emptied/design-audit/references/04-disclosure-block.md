# Residual Disclosure Block

## Grammar

The two fences are byte-exact literals appearing exactly once each, in this order,
with exactly 15 slot lines strictly between them.

## 잔여 공개

<!-- cc-design-audit-disclosure v1 begin -->
**동결 문서 sha256**: <64 hex>
**동결 시각**: <ISO 8601>
**리뷰어 수**: <n>
**원시 발견 수**: <n>
**고유 결함 수**: <n>
**미보강 잔여 수**: <n>
**라우팅 — 조정 패스 적용**: <n>
**라우팅 — 미해결 이슈**: <n>
**라우팅 — implement 사전 게이트**: <n>
**라우팅 — design-conformance**: <n>
**라우팅 — 기각**: <n>
**하류 흡수 가정**: <one line>
**조정 패스 시작**: <ISO 8601>
**조정 패스 종료**: <ISO 8601>
**결손 수**: <n>
<!-- /cc-design-audit-disclosure v1 end -->

## The four anti-vacuity checks

**(ii) Execution evidence.** The number of in-tree reader reports equals the `리뷰어 수` slot.

**(ii-b) Declared shortfall.** A run short of readers is declared through the `결손 수`
slot and the line after the block stating **결손 사유**, never absorbed by lowering the
reviewer count to match.

**`결손 수` is bounded in the same check that reads it**: `0 ≤ 결손 수 < 리뷰어 수` — strict,
and the strictness is the whole of the total-shortfall exit below.

**(ii-c) Total shortfall is not a shortfall — it is an audit that did not happen.**
`결손 수 == 리뷰어 수` means no reader produced a usable witness. This state has no valid
block. It is not written, not declared and not passed:
the run **aborts and reports**, and the disclosure block is not the exit.

**(iii) Arithmetic invariants.**

- `원시 ≥ 리뷰어 수 − 결손 수` — the readers that actually ran.

## Honest limit

The checks above bound vacuity, not correctness.
