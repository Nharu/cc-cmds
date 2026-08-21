# Reconciliation Pass (fixture)

## Non-recursion rules (hard)

- **No `Agent()` call.** Spawning anything here is the first step back toward the loop this command replaced.
- **No re-opening a dispositioned finding.**
- **The pass edits are never treated as new input.**

Record the pass timestamps as its first and last acts.

## Dedup and reinforcement

Identical findings from different readers collapse to one.

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

**A deterministic finding of the absent coherence-pass stamp routes to `## 미해결 이슈`, never to `기각`, and the reason is arithmetic rather than taste.** A known residual that recurs on every run of a documented call shape is exactly what that owner is for. Sending it to `기각` instead would put a **permanent floor of one** under the rejection count — and the pass leans on a zero rejection count beside a large applied count as its triage-collapse signal, so a floor of one is a detector that can no longer reach its own alarm state. The routing lines are fixed-arity precisely so that collapse shows up without extra instrumentation; a finding that fills one of them unconditionally spends that instrumentation on itself.
