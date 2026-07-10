---
name: design-review-lite
description: T-PARITY-OK-1 fixture — lite
---

# Test Fixture (lite)

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

Write this round's proposals to a hidden temp file co-located in {TEMP_DIR} — `mktemp "{TEMP_DIR}/.review_proposals.XXXXXX"` — then atomically publish by renaming to {TEMP_DIR}/review_proposals.r{round}.md (`mv -n`).
```

    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to (a)–(i). An already-finished async costs 2 reads, 0 yield.
  a. The agent published this round's proposals by atomic rename to `$INNER_TEMP_DIR/review_proposals.r$inner_round.md`.
  b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round's proposals.
