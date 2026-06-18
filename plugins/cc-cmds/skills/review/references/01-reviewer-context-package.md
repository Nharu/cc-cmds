# Reviewer Context Package

When assigning each reviewer (Step 4), include the following in the initial message.

## 16-item Context Package

1. **Return contract instruction**: Embed the **task-assignment header** from `_common/agent-team-protocol.md` verbatim at the top of the reviewer's prompt (role / round / load-bearing inputs / return contract). The reviewer is a nameless background task: it delivers its findings as its **final return text** — there is no separate delivery channel, no completion prefix, no messaging tool to call. It begins its return with its role and round, and never returns empty (if it cannot proceed, it returns its partial result plus a one-line concrete blocker).
2. **Review scope diff**: Full diff or role-filtered diff.
3. **Role-relevant changed file list**: Filtered by the lead based on Step 3 assigned scope + Round 0 results (if a reviewer carries the scope-coordination role).
4. **Role-specific review checklist** (with grep/Read search guidance — see "Role-specific checklists" below).
5. **Existing PR comments/review summary** + dedup instruction: *"Do not report already-raised issues as new findings. If you confirm an existing issue, reference it as 'confirms existing review by @author' and add only additional analysis."*
6. **PR metadata** (CI status, draft status, linked issues) — omit for non-PR reviews.
7. **Fix suggestion rules**: critical/high = mandatory, medium = include when non-obvious, low = include only for non-obvious tech debt, nitpick = omit.
8. **Search guidance**: Reference the role-specific checklist's grep/Read search items.
9. **Context size management**: For large diffs, filter to role-relevant file diffs only. Include change stats summary + high-risk file diffs in initial message; point reviewers to `grep`/`Read` for the rest. For many existing PR comments, send summary only.
10. **Severity system definition**: Reviewers use 5 levels:
    - `critical`: Immediately exploitable security vulnerability in production, data loss/leakage, complete core functionality block
    - `high`: High probability of production incident or security issue, merge block recommended
    - `medium`: Quality/performance degradation under real load, fix recommended before or after merge
    - `low`: Minor code smell, future tech debt, style inconsistency
    - `nitpick`: Pure cosmetic or marginal optimization
11. **(Large PR, with scope-coordination role)** **Round 0 analysis results**: This reviewer's focus areas, high-risk file list, priority check areas.
12. **Positive findings**: *"If you find well-implemented patterns or noteworthy positive aspects, include them with a `[POSITIVE]` tag briefly."*
13. **(Optional) Lead's codebase exploration summary** from Step 2b — key dependencies, related test files, existing pattern summary. Include within context size limits.
14. **Category tag list**: Choose from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`.
15. **Reporting format**: Findings must follow this structure:
    ```
    [severity] [category] file:line (or module/pattern) — issue description
      Rationale: severity justification
      Fix suggestion: fix direction (when applicable)
    [POSITIVE] file:line — positive aspect (when applicable)
    ```
16. **Skip-glob list (search hygiene)**: when grep-searching the codebase, skip `node_modules, .next, build, dist, __pycache__, .git, coverage, .turbo, .cache, out, .vercel, .output, vendor, target` to avoid spending token budget on vendored/generated trees.

## Role-specific Review Checklists

**Security reviewer:**
- Authentication/authorization: JWT validation, per-route auth guards, privilege escalation, IDOR
- Input validation: SQL/NoSQL injection, XSS, path traversal, SSRF, command injection
- Sensitive data: hardcoded secrets, PII logging, excessive API response fields
- Cryptography: weak hashing, hardcoded IV/salt, insecure random
- Search (grep/Read): search with role-relevant keywords focused on changed files and related modules. Narrow scope by changed file paths if results are too broad.

**Performance reviewer:**
- DB/ORM: N+1 queries, unused eager loading, missing pagination, full table scans, missing transactions
- Memory/resources: event listener leaks, unreleased timers, unclosed streams/connections, unbounded caches
- Computation: O(n^2)+, unnecessary computation in hot paths, missing memoization
- Concurrency/IO: sequential await (where `Promise.all` is possible), main thread blocking, missing connection pooling
- Search (grep/Read): search for DB call patterns, query builders, pagination keywords focused on changed areas. Narrow by file paths if too broad.

**Code quality reviewer:**
- Design: SRP, DRY violations, inappropriate coupling, over/under-abstraction
- Error handling: swallowed exceptions, generic catch, unhandled async errors, inconsistent error formats
- Readability: magic numbers/strings, complex conditionals, misleading names, long functions
- Type safety (TypeScript): `any` types, unsafe type assertions, missing return types, unhandled nullable
- Testing: missing test coverage for new logic, implementation-coupled tests, missing edge cases
- Search (grep/Read): search for usages of changed functions/classes, similar patterns, error formats focused on changed areas. Narrow if too broad.

**Dynamic roles (applied as needed):**
- DB/query expert: migration rollback safety, index impact, query plans
- API contract reviewer: backward compatibility, breaking changes, versioning
- Concurrency reviewer: race conditions, lock usage, idempotency
- Logic reviewer: business logic correctness, branch condition completeness, edge case coverage, requirements-implementation alignment

## Review Protocol (minimum 2 rounds)

Each round is a resume of the reviewer task by its `agentId`; each round's result is the reviewer's **return text** (collected via the background completion notification or as the resume tool result), not a DM. On every resume the lead re-injects the load-bearing context, quoting peer findings **verbatim**.

1. **Round 1 — Independent Review**: Spawn each reviewer as a nameless background task with its context package. Each reviews independently from its own perspective and delivers its findings as its return text. Collect every reviewer's return before moving on. A reviewer that returns an empty or substanceless result is re-scoped and resumed once (per the protocol's Escalation rules), not skipped.

2. **Quality Gate**: Before cross-validation, verify each returned review meets minimum quality:
    - Specific location references: `file:line` or `module/pattern` for architecture/pattern-level issues (no vague descriptions)
    - Severity rationale included for each finding
    - No duplication with existing PR comments
    - Fix suggestions included where appropriate
    - **Checklist coverage check**: Judge by whether the reviewer actually checked checklist items, not by finding count. "Checked but no issues found" is normal (clean code). If findings are listed without any mention of checklist items, judge as insufficient and resume the reviewer to re-check. Re-request (by resume) until QG passes (within total round safety limit).

3. **Cross-validation**: Resume each reviewer by its `agentId`, re-injecting the other reviewers' findings verbatim. Explicitly request: validate severity assessments, identify missed issues in overlapping areas, flag false positives, and note findings that interact with their own. The reviewer delivers its cross-validation pass as its return text.

4. **Round 2+ — Refinement**: Resume original authors with cross-validation feedback (quoted verbatim). Request severity revision, missed issue additions, and challenge responses. Each round's result is the reviewer's return text. Repeat until convergence.

5. **Convergence**: Convergence is by **return collection** — see the **Convergence** section of `_common/agent-team-protocol.md`. Resume each reviewer once with a convergence prompt (re-inject current consensus + open conflicts); when every reviewer's return says "no further input", the review has converged. Only then proceed to Step 5.

**When a reviewer carries the scope-coordination role (large PR):**

One reviewer may carry a "scope-coordination" role in its task-assignment header (its scope = coordinating the others' coverage). It is still a nameless background task and still delivers via return text — no named-team primitives, no DM channel, no completion prefix.
- **Round 0 (pre-analysis)**: the coordinating reviewer classifies changed files by risk and assigns reviewer focus areas; its return is folded into the other reviewers' context packages alongside Round 1 assignment.
- **After Quality Gate**: resume the coordinating reviewer for a coverage audit — it identifies high-risk areas not yet reviewed; the lead then resumes the relevant reviewers for additional review.
- **During cross-validation**: resume the coordinating reviewer to synthesize findings across reviewers and identify cross-cutting issues (inter-module interaction problems).
- The coordinating reviewer is resumed and converged by return collection like any other reviewer.

## Review-specific Facilitator Additions

Beyond the shared facilitator rules in `_common/agent-team-protocol.md`, review workflows add:

- **Resolve severity disputes**: If reviewers disagree on severity, ask both to justify their rating before the lead makes a final call.
- **Ensure completeness**: If a reviewer's findings seem unusually sparse for their scope, ask them to double-check specific areas before accepting.
- **PR comment dedup (2-layer check)**: Reviewers receive existing PR comments as context for 1st-layer filtering. The lead performs 2nd-layer verification during cross-validation to catch missed duplicates. Both reviewers and lead share responsibility to minimize duplication.
- **Round safety limit**: Step 4 review protocol is capped at **10 rounds maximum**. Upon reaching the limit, report current state to the user and ask whether to extend by 10 more rounds. Extensions can repeat indefinitely.
