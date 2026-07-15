---
name: design-review
description: T-PARITY-OK-1 fixture — base
---

# Test Fixture (base)

    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to (a)–(j). An already-finished async costs 2 reads, 0 yield.
  a. The agent published this round's proposals by atomic rename to `$INNER_TEMP_DIR/review_proposals.r$inner_round.md`.
  b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round's proposals.

async_observed_return: N is `inner_round`, injected into the agent's spawn prompt as {round} by the main session (the agent does not derive it).

K65 recovery cap: if `lostwrite_respawn_count >= K65`, do NOT respawn; the reason line renders {K65} as the actual observed respawn count.

## Outer Iteration N

- Inner exit reason: {clean-convergence | safety-limit-fresh-outer | safety-limit-outer-terminate | user-abort}
- Inner exit trigger: {inner-limit | async-slow | lostwrite | n/a}   ← restore from `$INNER_TEMP_DIR/review_log.md` (last-match)
