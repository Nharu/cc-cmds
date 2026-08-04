# implement (fixture consumer — gate-entry positive selector dropped)
#
# The regression: gate entry has gone back to "everything the skip rule did
# not remove", so an unhandled 검증 등급 state reaches the gate by default.
# The 검증 시점 partition is untouched, so exactly one literal may fail.

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: skip any item already carrying a terminal token; everything else is a gate item. Partition by `검증 시점` into **three** buckets — `구현 전` | `구현 중(<phase>)` | `구현 후` — with a two-step lookup: **Step 1 (presence)** `^(- )?(\*\*검증 시점\*\*|검증 시점): (.+)$`, then **Step 2 (value)** with the arm pinned per bucket — `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 전$` | `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 중\(.+\)$` | `^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 후$`.
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
