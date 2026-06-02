# Analyst Context Package

When assigning each analyst (Step 4), include the following in the initial message. All analysis is **read-only** — analysts never modify the source document or source repo (CFI-1).

## Context Package

1. **Completion signal instruction**: Use the `[COMPLETE]` / `[IN PROGRESS]` contract from `_common/agent-team-protocol.md`. Include the **full** instruction block from that file verbatim (delivery channel + message format + self-check every turn + silence-check before stopping) — do NOT paraphrase to a one-liner. The block already uses self-referential "me (the team lead)" phrasing and needs no lead-name substitution.
2. **The source document**: full text of `<design-doc-path>` (or, for very large docs, the analyst's assigned section range + a TOC of the rest, pointing the analyst to ask for more).
3. **Assigned lens**: the analyst's role from the Step 3 lens pool + its 범위 (see lens table in SKILL.md Step 3).
4. **Lens-specific checklist** (see "Lens checklists" below), with MCP `search_code` guidance when grounded.
5. **Analysis mode**: `grounding ON (CODE_ROOT=<abs path>)` or `doc-only`. In doc-only mode the analyst MUST NOT fabricate code citations and must scope claims to the document only (CFI-3, CFI-4).
6. **Read-only mandate**: *"You are analyzing a third-party design document. NEVER edit the source document or anything in its source repo. Report findings only."*
7. **Finding reporting format** (UPSTREAM fields of the canonical schema — see `02-analysis-report-template.md`):
   ```
   [severity-hint] [category] §doc-anchor "heading" — <title>
     code_citations: [path:line, ...]    # grounded only; [] otherwise
     evidence: why it matters / why this severity
     suggested_direction: a proposed direction (NOT a forced fix)
   ```
   Severity is a *hint*; the lead finalizes severity, `[foundational]`, and verdict in Step 5.
8. **Category tag list**: `architecture`, `feasibility`, `impl-cost`, `migration-safety`, `completeness`, `consistency`, `alternatives`, `doc-code-gap`, `scalability`, `security-design`, `data-integrity`, `api-contract`.
9. **Positive findings**: *"If the design makes a notably sound or well-justified choice, note it with a `[POSITIVE]` tag briefly."*
10. **(Optional) Lead's grounding exploration summary** from Step 2 — key modules the doc references, related code, conventions. Include within context-size limits.

## Lens checklists

**architecture-soundness (구조 건전성):** layering/module boundaries, coupling & cohesion, does the proposed structure actually hold together, hidden circular dependencies, responsibility placement.

**feasibility & impl-cost (실현가능성·구현비용):** can it be built as written, difficulty, hidden cost, unstated prerequisites, sequencing risk, effort vs. stated scope.

**migration-safety (마이그레이션안전):** data loss risk, rollback path, staged transition safety, backward compatibility, dual-write/read windows, irreversible steps. **Required lens for refactoring/migration docs.**

**completeness/gaps (완전성·누락):** missing interfaces, unhandled cases, undefined errors/edges, unspecified contracts, gaps between stated goals and the design.

**internal-consistency (내부일관성):** contradictions between sections, naming/contract mismatches, a decision in §X violated in §Y.

**alternatives-evaluation (대안평가):** were options considered, is the selection rationale justified, unexamined alternatives, false dichotomies.

**doc-vs-code grounding (문서-코드정합성, grounding ON only):** does the document's stated premise about the existing code match reality. 3 sub-modes of `doc-code-gap`: **직접 모순** (doc claims X, code shows not-X), **오독** (doc misreads existing code/behavior), **stale 가정** (doc's premise was true once but the code has since changed). Always cite both sides: the doc claim (`§anchor`) + the actual code (`path:line`).

## Analysis Protocol (read-only, single pass)

1. **Round 1 — Independent analysis**: each analyst analyzes from their lens. Wait for ALL to submit `[COMPLETE]`. On `[IN PROGRESS]`, reply "Take your time and send your complete analysis when ready" — do NOT move on.
2. **Quality Gate**: before cross-validation, verify each analysis has: specific doc anchors (`§x.y "heading"`) for every finding; when grounded, `path:line` for code claims; severity rationale; checklist coverage (judge by whether items were actually checked, not by finding count — "checked, no issue" is valid). Re-request until QG passes (within the round safety limit).
3. **Cross-validation**: send each analyst's findings to the others. Request: validate severity hints, identify gaps in overlapping areas, flag false positives, note findings that interact.
4. **Convergence Check**: use the convergence template from `_common/agent-team-protocol.md`. Only proceed to Step 5 when ALL analysts confirm `[COMPLETE]`. This is a **single pass** — no external/internal convergence loop, no termination math.

## Analysis-specific Facilitator Additions

Beyond the shared facilitator rules in `_common/agent-team-protocol.md`:
- **Resolve severity disputes**: if analysts disagree, ask each to justify before the lead's Step 5 final call ("higher severity wins" unless resolved).
- **Premise focus**: for refactoring docs, push analysts to test the document's *premise about the existing code* — that is the highest-value `doc-code-gap` signal.
- **Round safety limit**: the Step 4 protocol is capped at **10 rounds**. On reaching the limit, report state to the user and ask whether to extend by 10 more.

**When an Analysis Coordinator exists (large/multi-domain doc):**
- **Round 0**: classify document sections by risk and assign analyst focus areas; included in Round 1 packages.
- **After Quality Gate**: coverage audit — identify high-risk sections not yet analyzed, request additional analysis.
- **During cross-validation**: synthesize cross-section issues (inter-module/contract interactions individual analysts miss).
- Uses the same `[COMPLETE]`/`[IN PROGRESS]` signals; included in Convergence Checks.
