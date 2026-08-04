# implement (fixture consumer — 1.5a reverted to a two-way partition)
#
# The regression this fixture encodes: the 1.5a bullet has lost the third
# bucket and its pinned value arm, while the enum value survives in the 1.5b
# prose below. A whole-file presence check stays green on this tree; a check
# region-scoped to the 1.5a bullet must fail.

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: partition by `검증 시점` into **two** buckets — `구현 전` | `구현 중(<phase>)` — with the value arm pinned per bucket.
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
