# implement (fixture consumer — 1.5a value arm dropped, enum value kept)
#
# The regression this fixture encodes: the 1.5a bullet still names the third
# bucket, so the enum-value literal stays satisfied, but the pinned value arm
# that detects it has been deleted. Only the second pinned literal can fail
# here — this isolates that arm from the first one.

### Step 1.5: Write-Deferred Verification Gate

- **1.5a — Discovery & classification (read-only)**: partition by `검증 시점` into **three** buckets — `구현 전` | `구현 중(<phase>)` | `구현 후` — with the value arm pinned per bucket.
- **1.5b — Consent gate**: a `구현 후` item is disclosed as "관측 창 미개시 — 미실행".
