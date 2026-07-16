---
name: design-review
description: T-INV-OK-1 fixture — base
---

# Test Fixture (base)

## Control-Flow Invariants

These formulas govern termination and classification for the base skill.

```
inner_converged_cleanly() =
    (consecutive_no_major >= 2)
    AND (pending_applies.md is empty)
    AND (no [IN PROGRESS] dialogues)
```

`final_critical_or_major = |{p : p.severity (post-upgrade) ∈ {critical, major}}|`

Advance ordering: there is no look-ahead spawn. Anti-fabrication: write a record only if round N's review Agent() actually returned.

- The agent appends a round-N summary line in review_log.md at the close of each review cycle.

Fail-closed read arm: after an observed return, if the round-N proposals file is absent, re-read and respawn — never record zero proposals.

Death predicate: declare the agent dead only when the current classification is WEDGED and the reentry count has reached its limit.

Round injection: the round number is pinned by the main session at spawn as {round} = inner_round, so a same-round respawn re-publishes the same round — restoring the lost round-N file rather than diverging to N+1. A durable `lostwrite_respawn_count` bounds recovery: when it reaches `K65`, do NOT respawn — instead escalate to the user via the Step 16 3-option prompt under its lostwrite reason variant.

```
if INNER_EXIT_REASON == "safety-limit-outer-terminate": break
elif INNER_EXIT_REASON == "safety-limit-fresh-outer": outer_done = false
elif INNER_EXIT_REASON == "clean-convergence" and COUNT_APPLIED == 0: outer_done = true
```

## Begin

(end of fixture)
