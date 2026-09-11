# Review Report Template (fixture — the reached-round suppression clause dropped here only)

## Recovery report — the termination-predicate interlock

**The suppression target is the shape, not the position.** A recovery report in
which **any** role resolved to the `checkpoint` or `absent` tier — **or in which
every role resolved to `witness` but any of them did so at a round below the last
round the ledger block records** — **or in which
the roster could not be obtained at all** — puts a line of the shape above
**nowhere in the file**.

**A recovery in which every role resolved to `witness`, no role's resolution
round is below the last round the ledger block records, and no role's resolution
round is below the highest round at which that role left anything at all emits
the line normally.** **That case takes the partial-recovery line with
`최저 계층 라운드 미달` where the ledger block records a round of 2 or higher, and
also where any seat resolved at a round below the one it reached**.

**Where the ledger block records only round 1 and no seat reached a higher round,
neither condition fires on that corpus, and that is a hole rather than a
design.** The first comparand is the ledger's own round column and it falls with
the work.

## Document Structure

### Recovery-report variant

A recovery report follows the same skeleton with two changes. The `발견 요약`
line follows the interlock above — the ordinary line when every role resolved to
`witness`, no role's resolution round is below the last round the ledger
block records, and no role's resolution round is below the highest round at
which that role left anything at all, the partial-recovery line otherwise — and
one extra section is added directly after `## 개요`:

| 역할 | 계층 | 해소 라운드 | 도달 라운드 | 파일 | seq | nonce 미검증 |
| --- | --- | --- | --- | --- | --- | --- |
| [role] | witness / checkpoint / absent | [N] | [N] | [path read] | [N] | 예 / 아니오 |

The partial-recovery line's `최저 라운드` is the **minimum** of this table's
`해소 라운드` column, so the two are read together.
