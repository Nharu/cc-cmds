# implement (fixture consumer — 1.5a reverted to a two-way partition)
#
# The regression: the 1.5a bullet has lost the third bucket from its
# enumeration and the value arm that detects it, while the enum value
# survives in the 1.5b prose below. A whole-file presence check stays green
# on this tree; a check region-scoped to the 1.5a bullet must fail on the
# enumeration form and on the 구현 후 arm — and on nothing else.

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: gate entry is a **positive selector** — an item is a gate item only when its `검증 등급` is `구현 시 검증`, matched with `^(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$`; every other state is a document defect. Partition by `검증 시점` into **two** buckets — `구현 전` | `구현 중(<phase>)` — with a two-step lookup: **Step 1 (presence)** `^(- )?(\*\*검증 시점\*\*|검증 시점): (.+)$`, then **Step 2 (value)** with the arm pinned per bucket — `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 전$` | `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 중\(.+\)$`.
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
