# Reconciliation Pass (fixture)

The section formerly titled ## Non-recursion rules (hard) was folded into the routing table.

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

The pass may NOT close by dispositioning items one at a time. Its final act is to ask, once, in writing, and answer in the report:

> 이 발견들이 **함께** 함의하는 요구사항이 있는가?

Different readers' items can compose into a new requirement that appears in no single report.

## Total-shortfall abort (evaluated at the end of this pass, before the block is composed)

`결손 수 == 리뷰어 수` means no reader produced a usable witness. Evaluate it as the last act of
this pass: abort and report, and do not compose the disclosure block.

The condition is stated where the checks are defined; nothing evaluated it, because the step that
would is this one and this file is what this step reads.

This adds a second terminal exit to a pass whose invariant was that it had one: it is not a routing outcome, it is a refusal to produce the artifact.

<!-- cc-design-audit-reference: end -->
