---
name: design-audit
---

Audit a FROZEN design document. Single pass, hard stop.

## Input

A frozen design document path.

## Control-Flow Invariants

### CFI-0 — Fixed constants

```
READER_COUNT = 4
ROUNDS_PER_READER = 1
OUTER_ITERATIONS = 0
ADJUSTMENT_PASSES = 1
ROUND_TOKEN = 1
PASS_TOKEN = fanout
```

These six lines are the only place any of these values appears in this skill.

### CFI-3 — Hard stop

One pass over the frozen document, then stop. There is no path back.

### CFI-6 — Forbidden imports (loop-resurrection denylist)

None of the following may appear anywhere under this skill: `consecutive_no_major`, `COUNT_APPLIED`, `escalate_applied`, `INNER_EXIT_REASON`, `inner_round`, `outer_iter`, `outer_log.md`, `ack_items.md`, `pending_applies.md`, `INNER_TEMP_DIR`, `convergence_table.md`.

## Workflow

Step 0 through Step 7, then stop.
