---
name: design-review
description: T-PARITY-OK-1 fixture — base
---

# Test Fixture (base)

    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.md` and proceed to (a)–(j). An already-finished async costs 2 reads, 0 yield.
  a. The agent published this round's proposals by atomic rename to `$INNER_TEMP_DIR/review_proposals.r$inner_round.md`.
  b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round's proposals.
