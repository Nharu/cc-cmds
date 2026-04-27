---
name: design-review
description: T-INV-FAIL-2 fixture — base missing `inner_converged_cleanly()`
---

# Test Fixture (base — missing one phrase)

## Control-Flow Invariants

```
saturation_predicate() =
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
