---
name: design-audit
---

Audit a FROZEN design document. Single pass, hard stop.

## Control-Flow Invariants

### CFI-0 — Fixed constants

```
READER_COUNT = 3
ROUNDS_PER_READER = 1
OUTER_ITERATIONS = 0
ADJUSTMENT_PASSES = 1
ROUND_TOKEN = 1
PASS_TOKEN = fanout
```

### CFI-6 — Forbidden imports

None of the following may appear anywhere under this skill: `consecutive_no_major`, `COUNT_APPLIED`, `escalate_applied`, `INNER_EXIT_REASON`, `inner_round`, `outer_iter`, `outer_log.md`, `ack_items.md`, `pending_applies.md`, `INNER_TEMP_DIR`.

## Workflow

Step 0 through Step 7, then stop.

Skeleton-grade fence, after the disclosure v1 block:

```text
<!-- cc-design-audit-skeletal v1 begin -->
**골격급 수**: <n>
**합성 요구 후보 수**: <n>
**합성 요구 골격급 수**: <n>
**회차**: <최초|재감사>
**문서 sha256**: <64 hex>
<!-- /cc-design-audit-skeletal v1 end -->
```

