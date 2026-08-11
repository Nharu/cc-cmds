# Reconciliation Pass (fixture)

## Non-recursion rules (hard)

- **No `Agent()` call.** Spawning anything here is the first step back toward the loop this command replaced.
- **No re-opening a dispositioned finding.**
- **The pass edits are never treated as new input.**

Record the pass timestamps as its first and last acts.

## Dedup and reinforcement

Identical findings from different readers collapse to one.

## Severity re-assignment (single labeller, one pass)

One labeller re-assigns severity across the merged set. Never take a maximum across readers.

## Routing — five named owners, exactly one each

Every unique defect goes to exactly one owner. The five counts must sum to the unique-defect count.

| Owner | What goes here |
| --- | --- |
| 조정 패스 적용 | The fix is clear and lands now |
| `## 미해결 이슈` | A real residual |
| `implement` 사전 게이트 | Settleable once artifacts exist |
| `design-conformance` | Answerable after code exists |
| 기각 | Not a defect |

**기각 requires a written rationale.**

## Synthesis question (mandatory terminal act)

Its final act is to ask, once, in writing.

<!-- cc-design-audit-reference: end -->
