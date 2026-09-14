# review-unattended (fixture — every pinned clause wrapped across lines)

## Recovery arm (`--recover`)

4. **Ladder.**

    **Round first, tier second.** The role's
    **resolution round** is the round the ladder actually resolves it at:
    start at the highest round at which that role
    left anything at all — witness or checkpoint, the tiers do not compete
    for it — and read the tier **at that round**.

8. **Interlock.** Emit the findings-summary line verbatim in the
    template's position **only when every role resolved to `witness`, no
    role's resolution round is below the last round the ledger block's
    `round/phase` column records, and no role's resolution round is
    below the highest round at which that role left anything at all**.
    If any role came back `checkpoint` or `absent`, **or if every role
    resolved to `witness` but any of them did so at a round below that
    last recorded round**, **or if
    the roster could not be obtained** (item 4), **or if any role's
    resolution round is below the highest round at which that role left
    anything at all**, emit the
    partial-recovery line the template defines instead.

    **What the ledger-round term catches is bounded by
    its comparand, and the bound has to be written down because it is
    not the bound a reader assumes.** A crash landing before the round-2
    flip leaves every row at `round-1`, so the comparand falls with the
    work.

9. **`## 복구 프로버넌스`.** Emit this section in the report — one row per
    role carrying role / tier / resolution round /
    **reached round** / file / `seq` / whether `nonce 미검증` applies.

## Constraints

- Review only.
