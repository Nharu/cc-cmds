---
name: design-review-lite
description: T-PARITY-FAIL-1 fixture — lite (regressed to bare overwrite path)
---

# Test Fixture (lite)

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

Write all proposals to {TEMP_DIR}/review_proposals.md (overwrite the file at the start of the round).
```

  a. The agent wrote proposals to `$INNER_TEMP_DIR/review_proposals.md` (overwriting at round start).
  b. Read `$INNER_TEMP_DIR/review_proposals.md` to get the current round's proposals.
