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

K65 recovery cap: if `lostwrite_respawn_count >= K65`, do NOT respawn; the reason line renders {K65} as the actual observed respawn count.

## Outer Iteration N

- Inner exit reason: {clean-convergence | safety-limit-fresh-outer | safety-limit-outer-terminate | user-abort}
- Inner exit trigger: {inner-limit | async-slow | lostwrite | n/a}   ← restore from `$INNER_TEMP_DIR/review_log.md` (last-match)

## Reused-prompt reason variants (all four EXIT_TRIGGER values)

- `inner-limit`: downstream early-termination clause `내부 라운드가 안전 한계로 조기 종료됨`, summary clause `내부 안전 한계 도달 시점에 미해소`.
- `async-slow`: reason line `비동기 리뷰어가 아직 완료 witness를 발행하지 못했습니다.`, downstream early-termination clause `비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨`, summary clause `비동기 리뷰어 미완료로 미해소`.
- `lostwrite`: reason line `라운드 결과 파일이 완료 표시 후에도 반복 유실되었습니다 — 같은 라운드 재시도 {K65}회로도 복구되지 않았습니다.`, downstream early-termination clause `라운드 결과 파일이 반복 유실되어 조기 종료됨`, summary clause `라운드 결과 파일 반복 유실로 미해소`.
- trigger-neutral fallback: downstream early-termination clause `내부 라운드가 조기 종료됨`, summary clause `이터레이션 조기 종료 시점에 미해소`.
