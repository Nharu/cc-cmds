# Analyst Context Package

When assigning each analyst (Step 4), include the following in the initial message. All analysis is **read-only** — analysts never modify the source document or source repo (CFI-1).

## Context Package

1. **Return contract instruction**: embed the **task-assignment header** from `_common/agent-team-protocol.md` verbatim at the top of the prompt. An analyst's result is delivered by its **durable witness file** (sentinel/nonce-terminated per the protocol); the return text is only an early-wake hint, and there is no `[COMPLETE]`/`[IN PROGRESS]` prefix. The header tells the analyst to publish its analysis as its witness before returning, begin its return with its role and round, and never return without publishing the witness (publish a partial result plus a one-line concrete blocker if it cannot proceed).
2. **The source document**: full text of `<design-doc-path>` (or, for very large docs, the analyst's assigned section range + a TOC of the rest, pointing the analyst to ask for more).
3. **Assigned lens**: the analyst's role from the Step 3 lens pool + its 범위 (see lens table in SKILL.md Step 3).
4. **Lens-specific checklist** (see "Lens checklists" below), with `grep`/`Read` guidance when grounded.
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
11. **(grounding ON only) Skip-glob list**: when grep-searching `CODE_ROOT`, skip `node_modules, .next, build, dist, __pycache__, .git, coverage, .turbo, .cache, out, .vercel, .output, vendor, target` to avoid spending token budget on vendored/generated trees.

## Lens checklists

**architecture-soundness (구조 건전성):** layering/module boundaries, coupling & cohesion, does the proposed structure actually hold together, hidden circular dependencies, responsibility placement.

**feasibility & impl-cost (실현가능성·구현비용):** can it be built as written, difficulty, hidden cost, unstated prerequisites, sequencing risk, effort vs. stated scope.

**migration-safety (마이그레이션안전):** data loss risk, rollback path, staged transition safety, backward compatibility, dual-write/read windows, irreversible steps. **Required lens for refactoring/migration docs.**

**completeness/gaps (완전성·누락):** missing interfaces, unhandled cases, undefined errors/edges, unspecified contracts, gaps between stated goals and the design.

**internal-consistency (내부일관성):** contradictions between sections, naming/contract mismatches, a decision in §X violated in §Y.

**alternatives-evaluation (대안평가):** were options considered, is the selection rationale justified, unexamined alternatives, false dichotomies.

**doc-vs-code grounding (문서-코드정합성, grounding ON only):** does the document's stated premise about the existing code match reality. 3 sub-modes of `doc-code-gap`: **직접 모순** (doc claims X, code shows not-X), **오독** (doc misreads existing code/behavior), **stale 가정** (doc's premise was true once but the code has since changed). Always cite both sides: the doc claim (`§anchor`) + the actual code (`path:line`).

## Analysis Protocol (read-only, resumed across rounds)

Each analyst is a nameless background task; the lead drives it across rounds by resuming its `agentId` and collecting its round witness via `witness_present` — never its return text (see `_common/agent-team-protocol.md`).

1. **Round 1 — Independent analysis**: each analyst analyzes from its lens and publishes the analysis as its witness. A returned analyst has self-terminated; confirm its round witness via `witness_present` and read the witness (never the return) — there is no `[COMPLETE]`/`[IN PROGRESS]` prefix to wait on.
2. **Quality Gate**: before cross-validation, verify each returned analysis has: specific doc anchors (`§x.y "heading"`) for every finding; when grounded, `path:line` for code claims; severity rationale; checklist coverage (judge by whether items were actually checked, not by finding count — "checked, no issue" is valid). On a miss, resume that analyst (by `agentId`, re-injecting the gap) until QG passes (within the round safety limit).
3. **Cross-validation**: resume each analyst, re-injecting the other analysts' findings **verbatim**. Request: validate severity hints, identify gaps in overlapping areas, flag false positives, note findings that interact.
4. **Convergence Check**: convergence is by **witness collection** (see `_common/agent-team-protocol.md`). Resume each analyst once with a convergence prompt (re-inject current consensus + open conflicts); the analysis has converged when every analyst's round witness is `witness_present` and its witness body says "no further input". Only then proceed to Step 5. Analysts are read-only single-pass per lens, but are still resumed for cross-review convergence — no termination math.

## Analysis-specific Facilitator Additions

Beyond the shared facilitator rules in `_common/agent-team-protocol.md`:
- **Resolve severity disputes**: if analysts disagree, ask each to justify before the lead's Step 5 final call ("higher severity wins" unless resolved).
- **Premise focus**: for refactoring docs, push analysts to test the document's *premise about the existing code* — that is the highest-value `doc-code-gap` signal.
- **Round safety limit**: the Step 4 protocol is capped at **10 rounds**. On reaching the limit, report state to the user and ask whether to extend by 10 more.

**Analysis Coordinator scope (large/multi-domain doc):**
For a large or multi-domain doc, the lead may give one analyst an added coordinator scope in its task-assignment header (no named role, no separate channel — it is still a nameless background task delivering via its witness):
- **Round 0**: classify document sections by risk and assign analyst focus areas; included in Round 1 packages.
- **After Quality Gate**: coverage audit — identify high-risk sections not yet analyzed, request additional analysis.
- **During cross-validation**: synthesize cross-section issues (inter-module/contract interactions individual analysts miss).
- This analyst is resumed and its witness collected like any other; included in the witness-collection Convergence Check.
