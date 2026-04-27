---
name: design-review-lite
description: T-INV-OK-1 fixture — lite
---

# Test Fixture (lite)

## Control-Flow Invariants

These formulas govern termination and classification for the lite skill.

```
inner_converged_cleanly() =
    (consecutive_no_major >= 2)
    AND (pending_applies.md is empty)
    AND (no [IN PROGRESS] dialogues)
```

`final_critical_or_major = |{p : p.severity (post-upgrade) ∈ {critical, major}}|`

```
if INNER_EXIT_REASON == "safety-limit-outer-terminate": break
elif INNER_EXIT_REASON == "safety-limit-fresh-outer": outer_done = false
elif INNER_EXIT_REASON == "clean-convergence" and COUNT_APPLIED == 0: outer_done = true
```

## Begin

(end of fixture)
