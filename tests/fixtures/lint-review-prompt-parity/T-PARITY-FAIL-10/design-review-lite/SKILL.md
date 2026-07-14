---
name: design-review-lite
description: T-PARITY-OK-1 fixture — lite
---

# Test Fixture (lite)

## Substitution contract

- `{round}` → the current `inner_round` value (spawn-time round counter).

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

This review is Round {round}. Use {round} as the round number everywhere below — the PROP-ID prefix, the published proposals filename, and the round-summary header.

Write this round's proposals to a hidden temp file co-located in {TEMP_DIR} — `mktemp "{TEMP_DIR}/.review_proposals.XXXXXX"` — then atomically publish by renaming to {TEMP_DIR}/review_proposals.r{round}.md (`mv -n`). Publish this round-keyed file unconditionally — including when this round has zero proposals.
```

    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to (a)–(i). An already-finished async costs 2 reads, 0 yield.
  a. The agent published this round's proposals by atomic rename to `$INNER_TEMP_DIR/review_proposals.r$inner_round.md`.
  b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round's proposals.

async_observed_return: N is `inner_round`, injected into the agent's spawn prompt as {round} by the main session (the agent does not derive it).

## Outer Iteration N

- Inner exit reason: {clean-convergence | safety-limit-fresh-outer | safety-limit-outer-terminate | user-abort}
- Inner exit trigger: {inner-limit | async-slow | lostwrite | n/a}

Reused-prompt variants (lite): `async-slow` → downstream early-termination clause `비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨`. (The `lostwrite` variant clause is intentionally omitted on this surface — parity drift.)
