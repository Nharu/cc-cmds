# implement (fixture consumer — the two sibling value arms dropped)
#
# The regression: the 구현 후 arm this PR added survives while the two
# pre-existing sibling arms have been deleted, so the bucket the newest
# literal guards is the only one still detected. Exactly two literals fail.

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: gate entry is a **positive selector** — an item is a gate item only when its `검증 등급` is `구현 시 검증`, matched with `^(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$`; every other state is a document defect. Partition by `검증 시점` into **three** buckets — `구현 전` | `구현 중(<phase>)` | `구현 후` — with a two-step lookup: **Step 1 (presence)** `^(- )?(\*\*검증 시점\*\*|검증 시점): (.+)$`, then **Step 2 (value)** — `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 후$` for the third bucket, the other two by prose.
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
