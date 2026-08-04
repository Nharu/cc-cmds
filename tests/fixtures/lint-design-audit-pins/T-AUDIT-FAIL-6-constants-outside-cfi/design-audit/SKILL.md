---
name: design-audit
---

Audit a FROZEN design document. Single pass, hard stop.

## Control-Flow Invariants

### CFI-0 — Fixed constants

### CFI-6 — Forbidden imports

None of the following may appear anywhere under this skill: `consecutive_no_major`, `COUNT_APPLIED`, `escalate_applied`, `INNER_EXIT_REASON`, `inner_round`, `outer_iter`, `outer_log.md`, `ack_items.md`, `pending_applies.md`, `INNER_TEMP_DIR`.

## Workflow

```
READER_COUNT = 3
ROUNDS_PER_READER = 1
OUTER_ITERATIONS = 0
ADJUSTMENT_PASSES = 1
ROUND_TOKEN = 1
PASS_TOKEN = fanout
```

Step 0 through Step 7, then stop.
