# implement (fixture consumer — 1.5a three-way partition intact)

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: partition by `검증 시점` into **three** buckets — `구현 전` | `구현 중(<phase>)` | `구현 후` — with the value arm pinned per bucket (`^(- )?(\*\*검증 시점\*\*|검증 시점): 구현 후$` for the third).
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
