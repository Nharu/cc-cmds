# Reviewer Context Package

When assigning each reviewer (Step 4), include the following in the initial message.

## 17-item Context Package

Item 18 below is conditional on delta mode and is not counted in the heading.

1. **Return contract instruction**: Embed the **task-assignment header** from `_common/agent-team-protocol.md` verbatim at the top of the reviewer's prompt (role / round / load-bearing inputs / witness contract). The reviewer is a nameless background task: it delivers its findings as its **durable witness file** (sentinel/nonce-terminated per the protocol) — the return text is only an early-wake hint, with no completion prefix and no messaging tool to call. It begins its return with its role and round, and never returns without publishing its witness (if it cannot proceed, it publishes a partial result plus a one-line concrete blocker).
2. **Review scope diff**: The diff under review, taken from the run's **shared snapshot** when one exists — `${CC_PIPELINE_RUN_DIR}/shared/<gen>/diff/<target>.patch`, with the file bytes it cites in `blob/<id>` and their provenance in `manifest.tsv`. Outside a pipeline run, or before any generation exists, this is the full or role-filtered diff collected directly and nothing else about this item changes.
    - **The manifest has exactly six columns and no seventh**: entry-id, absolute path, `sha256`, byte range, collection time, HEAD sha. It records where bytes came from and never what they mean — no severity, no risk score, no summary. A seventh column would make the package an opinion the reviewers inherit before they have read anything, which is the one thing a shared input must not be.
    - **A blob is verbatim bytes, and you verify before you use it.** On every read, hash `blob/<id>` and compare it against that entry's `sha256`. A mismatch is a **refusal, not a warning**: behave exactly as if the shared snapshot were absent and collect directly. Do not read the blob anyway, and do not file the mismatch as a review finding — it is a defect in the package, not in the code under review.
    - **Scope is the union of the cycle's reviewers, not this role's slice.** One generation serves every reviewer, so a reviewer reads its own slice out of a package collected for all of them. That is what makes the package shareable at all; narrowing what is *sent* to a given reviewer is item 9's job and is unaffected.
    - **A generation is immutable.** Invalidation mints a new `<gen>` and leaves existing ones untouched, so a reviewer mid-round keeps reading a stable package.
    - **The router shard cannot read this tree** — the gate refuses a `shift`-kind act whose argument resolves under `shared/`. A shard that needs a byte from it gets it through the seat.
3. **Role-relevant changed file list**: Filtered by the lead based on Step 3 assigned scope + Round 0 results (if a reviewer carries the scope-coordination role).
4. **Role-specific review checklist** (with grep/Read search guidance — see "Role-specific checklists" below).
5. **Existing PR comments/review summary** + dedup instruction: *"Do not report already-raised issues as new findings. If you confirm an existing issue, reference it as 'confirms existing review by @author' and add only additional analysis."*
6. **PR metadata** (CI status, draft status, linked issues) — omit for non-PR reviews.
    - The unattended review leaves out of this item's CI failure priority check area every failing check that the manifest's `라벨 인정` row for the pull request's target names.
    - **A public-surface change that goes beyond the intent its slice declared is an ordinary finding grounded in the code.** A failing surface guard is not the evidence for it: the reviewer reads the changed surface itself and grades what it finds there like any other finding.
7. **Fix suggestion rules**: critical/high = mandatory, medium = include when non-obvious, low = include only for non-obvious tech debt, nitpick = omit.
8. **Search guidance**: Reference the role-specific checklist's grep/Read search items.
9. **Context size management**: For large diffs, filter to role-relevant file diffs only. Include change stats summary + high-risk file diffs in initial message; point reviewers to `grep`/`Read` — or, under a shared snapshot, to the `blob/<id>` entries of item 2 — for the rest. For many existing PR comments, send summary only.
    - **What the shared snapshot saves is re-collection, not grounding.** The review skill's grounding rule is untouched by it: a finding still cites `파일:라인` in the tree and still stands or falls on those bytes. A blob is a cheaper way to read them, never a different class of evidence, and "the manifest says so" is not a rationale.
    - **The union manifest is a starting set, not a boundary on the read set.** A file the package does not hold is read directly, and a finding grounded that way is worth exactly as much as one grounded on a blob. A reviewer that confines itself to the package because the package was provided is the failure mode this line exists to name.
10. **Severity system definition**: Reviewers use 5 levels:
    - `critical`: the finding meets the P0 criterion (→ P0)
    - `high`: the finding meets the P1 criterion (→ P1)
    - `medium`: the criterion gives P2 (→ P2)
    - `low`: minor code smell, future tech debt, style inconsistency (→ P3)
    - `nitpick`: pure cosmetic or marginal optimization (→ P3)
    - **The criterion is not restated here.** It is written once, in the `## Severity System (P0~P3)` section of `02-review-report-template.md` — the file beside this one in the same `references/` directory, located from where this file was read and never from the reviewed repository's working directory — and the unattended and interactive reviews share it. Copy that section verbatim into each reviewer's package, and again on every dispatch and resume, so the reviewer grades against the criterion itself rather than against these one-line labels; a copy made at dispatch is not a second source. If the lead cannot read that section, it does not dispatch reviewers with the labels alone.
    - **Every `high` finding also carries a P1 classification.** The reviewer marks it `차단` or `이월 가능` and gives a one-line `분류 근거`. The standard is the `### P1 분류 기준` subsection of the same template, copied into the package beside the severity criterion and not restated here: `이월 가능` only when all three of its criteria hold, `차단` when any fails, and `차단` whenever reviewers disagree. The classification never moves a finding between severities — it splits findings already graded P1.
    - **An `이월 가능` finding also carries an `이월 제목` and an `이월 본문`** in the spellings of the template's `P1 Classification Grammar` section. The body states the problem, its location as a repository path and line, the evidence and the impact. It never carries a fix suggestion; a design-document path, heading, section number or document-local label; a report path; the substring `docs/`; or a credential value. In the unattended pipeline the body becomes the text of a follow-up issue.
    - **(Unattended slice-scoped review only) Other-slice share.** When `review-unattended` dispatches with a slice scope applied, it hands each reviewer the current slice's block and the lines of the other declared slices. A finding is another slice's share only when its remedy is work the design assigns to a declared slice other than the current one, that slice has not merged, and the finding is not a defect in a line this slice changed — a defect in a line this slice changed is never another slice's share. The reviewer names the slice and quotes the verbatim line of that slice's block the finding belongs to. Omit this bullet for every interactive review and for an unattended review whose slice scope fell back to `적용 안 됨`.
11. **(Large PR, with scope-coordination role)** **Round 0 analysis results**: This reviewer's focus areas, high-risk file list, priority check areas.
12. **Positive findings**: *"If you find well-implemented patterns or noteworthy positive aspects, include them with a `[POSITIVE]` tag briefly."*
13. **(Optional) Lead's codebase exploration summary** from Step 2b — key dependencies, related test files, existing pattern summary. Include within context size limits.
14. **Category tag list**: Choose from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`, `design-conformance`.
    - **`design-conformance` is gated on item 17.** It is usable **only** when the design document of item 17 was actually supplied. Its grounding standard is a comparison against that document — with no document there is nothing to compare against, so the tag would be an unfounded label rather than a finding. When item 17 is omitted, drop `design-conformance` from the list handed to the reviewer; the other ten are unconditional.
    - **Field scope.** What a review looks at is split into fields. The technical field is always open; two fields leave the default and are opened only on request. The field rules live here and nowhere else — every review skill reads this item.

      | Field | Default | How it opens | Tag of its findings when open |
      | --- | --- | --- | --- |
      | Technical — security, performance, logic, error handling, types, tests, API contract, concurrency, data integrity, conformance to written behaviour, awkward wording / typos / tone of on-screen and guidance text, UX and accessibility, a document stating a fact that disagrees with the code, defects in the text of SKILL.md / prompts / schemas | open | (always open) | unchanged |
      | Spec conformance — comparison against the whole binding text of a document handed to the review | open when a document is supplied | interactively a directive such as `설계는 <경로>` or `기획서는 <경로>`; in the pipeline the run's design document (item 17) | `design-conformance` |
      | `요구` — a product or planning requirement the reviewer inferred with no written source | closed | `--expand 요구` | `logic`, or `design-conformance` when item 17 is supplied |
      | `문서표현` — polishing sentences, structure, added explanation or a meaning-preserving typo in a human-read document (`docs/`, README, CHANGELOG, code comments) | closed | `--expand 문서표현` | `code-quality` |

      - The lead writes, in every reviewer's package, one line naming the fields open for this review and whether a spec document (item 17) was supplied.
      - An observation that belongs to a field not open for this review is not a finding: report it as an out-of-scope observation (item 15). It is never dropped.
      - Awkward wording, typos and tone of on-screen and guidance text, and UX and accessibility, are the technical field.
      - A document whose statement of fact disagrees with the code — an option or flag that does not exist, a changed default, command or path, an example that behaves otherwise, a name or command spelled wrong — is the technical field, graded by the severity criterion's downgrade table as before.
      - The text of SKILL.md, `_common`, prompts and schemas is an instruction the model executes, not a document, so it is always the technical field.
      - Written behaviour — the baseline of conformance to written behaviour — comes from these sources only: comments, doc comments and types in the code; tests; the PR, commit or issue text describing the change; and the spec document handed to the review (item 17). An input→output, a branch or a boundary value written in one of them that the code does not honour is a technical (`logic`) finding. An expectation with no such source belongs to the `요구` field.
      - Fields do not change the severity criterion: a finding of an open field is graded by the same criterion as any other. A `요구` finding made with no spec document states in its body that the requirement is inferred, not written.
15. **Reporting format**: Findings must follow this structure:
    ```
    [severity] [category] file:line (or module/pattern) — issue description
      Rationale: severity justification
      Fix suggestion: fix direction (when applicable)
    [POSITIVE] file:line — positive aspect (when applicable)
    [범위 밖:<분야>] file:line — observation (when applicable)
    ```
    - **An out-of-scope observation** (item 14's Field scope) takes the last form, with `<분야>` the closed field it belongs to (`요구` or `문서표현`). It carries no severity and no fix suggestion, and the Quality Gate's demands for a severity rationale and a fix suggestion do not apply to it.
    - The lead carries each such line into the report's `## 범위 밖 관찰` section as `` - [<분야>] `파일:라인` <관찰 한 줄> — <리뷰어> ``. Lines from several reviewers stating the same observation at the same `파일:라인` merge into one line naming the reviewers side by side.
16. **Skip-glob list (search hygiene)**: when grep-searching the codebase, skip `node_modules, .next, build, dist, __pycache__, .git, coverage, .turbo, .cache, out, .vercel, .output, vendor, target` to avoid spending token budget on vendored/generated trees.
17. **(Conditional) Design document + drift sidecar** — include only when the user supplied a design-document path as a review directive; **omit entirely otherwise**, and omit `design-conformance` from item 14 with it. Absence is the normal case, not a defect: a design document is user-local and typically untracked, so it does not exist in a clone. The channel this item opens therefore works when reviewing **your own** work and is structurally unavailable when reviewing someone else's PR — do not construct a fallback that guesses at a document.
    - **Spec conformance happens only through this item.** A review compares against a spec only when this item is present, and a requirement judgement has no other source: without this item, an expectation no written source states belongs to the closed `요구` field (item 14's Field scope).
    - **Which directive supplies it.** The interactive /review uses a document as this item when its directive points at a planning or design document by path, in the form `설계는 <경로>` or `기획서는 <경로>`.
    - **A document without section names is a baseline as a whole.** A spec written elsewhere, carrying none of the cc-cmds design-document section names below, is compared against in its entirety.
    - **An anchor brief is not a spec.** The unattended review does not take a document whose first line is `# 앵커 브리프 — 설계 문서 없는 런` as this item; it hands it to the reviewers as context of the same standing as the PR body, and leaves `design-conformance` out of item 14. The intent sentence the brief carries is read only as a source of written behaviour, and neither it nor the brief's `## 실행 계획` block (its `review_expand` included) opens a field — a field opens only through the `--expand` the review received.
    - **What binds.** The **binding tier** is the conformance baseline: `## 합의된 아키텍처`, the decision sentences of `## 주요 결정사항과 근거`, entries of `## 미해결 이슈 / 트레이드오프` whose `상태` is `해결`, `## 구현 시 검증 항목`, and a `## 재현·근본원인` whose `근거 등급` is `확인됨(재현·관측)`. A `design-conformance` finding is a divergence from **that** material.
    - **`## 미해결 이슈` is NOT a baseline** — it is a list of known residuals, and it has two uses. Read it to **suppress duplicates**: an item already recorded there is known, so re-reporting it as a new finding is noise. Never raise the non-implementation of an unresolved item as a conformance violation; it is unresolved by design. And read it as a **pointer to where to look**: an entry saying two files carry copies of one rule with nothing coupling them is, for a reviewer, an instruction to diff those two files. Without this second use that check has to be carried in by hand every time, which is precisely the class of obligation that fails at the moment it is needed.
    - **`## 권장 구현 순서` is for scope**, not conformance — use it to judge which stage the change under review belongs to, so a later stage's absence is not reported as a gap.
    - **The drift sidecar** `docs/design-drift/{slug}.md`, when present, records divergences the implementer already declared. Read it under the `## 1` read guard of `_common/sidecar.md` (an `owner-doc=` mismatch or absence means the file belongs to another document — do not apply it). A divergence recorded there is **disclosed, not thereby justified**: judge it on the merits, and note that a `참고`-tier divergence needed no approval while a `구속`-tier one should carry `승인: 사용자 승인`. An undisclosed binding-tier divergence — one you find in the code with no matching block — is itself a finding.
18. **(Conditional, delta mode only) Basis findings for re-adjudication** — include only when every eligibility check of `review-unattended` Step 1b′ passed this cycle; omit entirely otherwise, including for every interactive `review` invocation, which never supplies the three flags that trigger delta mode.
    - Include the full text of **every** P0/P1 finding from the basis report (category, description, rationale, cited `파일:라인`) — not filtered to this reviewer's assigned file scope, and not filtered to the delta file set — and assign each one to whichever composed reviewer's role/category tag is the closest match; if none matches, the smallest-scoped reviewer takes the remainder.
    - Number the findings `basis-1`, `basis-2`, … in the order they appear in the basis report, and give each reviewer the identifiers it was assigned alongside the text. The reviewer's witness carries **exactly one verdict per assigned identifier**; a witness that omits one is non-conforming however well-formed the rest of it is. The identifiers are what let the lead count the verdicts against the basis instead of trusting that none was skipped.
    - Instruction to the reviewer: *"For each of these prior findings, determine whether it is now fixed. The fix may be at the cited location or anywhere else in the codebase — a caller, a config, a different file entirely. Read whatever you need to reach a verdict; the cited file, if not already in your assigned scope, joins your read set for this finding only. Cite the current evidence either way — the fix's location and content, or its confirmed absence. If unfixed, restate why in one sentence; do not merely echo the original finding."*
    - There is no git-only carry-forward for P0/P1: every one gets an evidence-backed verdict every cycle, whether or not its cited file lies inside the delta file set. The cost is bounded by the number of basis P0/P1 findings. Basis P2/P3 findings are not sent through this item; the lead carries them into the current report as inherited.

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
- Logic reviewer: business logic correctness, branch condition completeness, edge case coverage, written behaviour vs. code — an input→output, a branch or a boundary value written in a source item 14's Field scope names that the code does not honour

## Review Protocol (rounds per the shared Round budget)

Each round is a fresh dispatch of the reviewer's role — one dispatch per `(role, round/phase)` key — and a re-request inside one round (a send-back, Case 1, Case 3, a nudge) resumes that round's task by its `agentId`; each round's result is the reviewer's **durable witness file**, confirmed via `witness_present` and read directly — the background completion notification and the dispatch or resume tool result are only early-wake hints (the very drop-prone channel this model refuses to trust), not the result, and not a DM. On every boundary dispatch the lead re-injects the load-bearing context **by path**, naming the reviewer's own past witnesses and each peer witness for the reviewer to Read whole (`_common/agent-team-protocol.md` `## Multi-round`).

1. **Round 1 — Independent Review**: Spawn each reviewer as a nameless background task with its context package. Each reviews independently from its own perspective and publishes its findings as its witness. Confirm every reviewer's round witness via `witness_present`, then read the witness — never the return — before moving on. A reviewer that publishes an empty or substanceless witness is re-scoped and resumed once (per the protocol's Escalation rules), not skipped.

2. **Quality Gate**: Before cross-validation, verify each returned review meets minimum quality:
    - Specific location references: `file:line` or `module/pattern` for architecture/pattern-level issues (no vague descriptions). A `design-conformance` finding carries **two** anchors — the source location as usual, **and** the design-document section it diverges from — because its claim is a mismatch between the two and a single anchor cannot state one.
    - Severity rationale included for each finding
    - No duplication with existing PR comments
    - Fix suggestions included where appropriate
    - The severity-rationale and fix-suggestion demands above apply to findings only; an out-of-scope observation (`[범위 밖:<분야>]`, item 15) carries neither and is not sent back for lacking them
    - **Checklist coverage check**: Judge by whether the reviewer actually checked checklist items, not by finding count. "Checked but no issues found" is normal (clean code). If findings are listed without any mention of checklist items, judge as insufficient and send the reviewer back inside its round to re-check. Re-request (by same-key resume) until QG passes (within the round budget — see **Round budget** below).

3. **Cross-validation**: Dispatch each reviewer's role afresh, naming its own past witness and the other reviewers' witnesses **by path** (`_common/agent-team-protocol.md` `## Multi-round`). Explicitly request: validate severity assessments, identify missed issues in overlapping areas, flag false positives, and note findings that interact with their own. The reviewer publishes its cross-validation pass as its witness.

4. **Round 2+ — Refinement**: Dispatch the original authors' roles afresh with the cross-validation witnesses named **by path** (`_common/agent-team-protocol.md` `## Multi-round`). Request severity revision, missed issue additions, and challenge responses. Each round's result is the reviewer's witness, confirmed via `witness_present`. Repeat until convergence.

5. **Convergence**: Convergence is by **witness collection** — see the **Convergence** section of `_common/agent-team-protocol.md`. Dispatch each reviewer's role once afresh with a convergence prompt (current consensus + open conflicts, peer witnesses by path); when every reviewer's round witness is `witness_present` and its witness body says "no further input", the review has converged. Only then proceed to Step 5.

**When a reviewer carries the scope-coordination role (large PR):**

One reviewer may carry a "scope-coordination" role in its task-assignment header (its scope = coordinating the others' coverage). It is still a nameless background task and still delivers via its witness — no named-team primitives, no DM channel, no completion prefix.
- **Round 0 (pre-analysis)**: the coordinating reviewer classifies changed files by risk and assigns reviewer focus areas; its Round-0 witness is folded into the other reviewers' context packages alongside Round 1 assignment.
- **After Quality Gate**: send the coordinating reviewer back inside round 1 (a same-key send-back, resumed by `agentId`) for a coverage audit — it identifies high-risk areas not yet reviewed; the lead then sends the relevant reviewers back the same way for additional review.
- **During cross-validation**: the coordinating reviewer's cross-validation dispatch also synthesizes findings across reviewers and identifies cross-cutting issues (inter-module interaction problems).
- The coordinating reviewer is dispatched each round and converged by witness collection like any other reviewer.

## Review-specific Facilitator Additions

Beyond the shared facilitator rules in `_common/agent-team-protocol.md`, review workflows add:

- **Resolve severity disputes**: If reviewers disagree on severity, ask both to justify their rating before the lead makes a final call.
- **Resolve field disputes**: If reviewers disagree on whether an observation falls in a field open for this review, the lead decides by item 14's Field scope. An observation decided to belong to a closed field moves to the out-of-scope observations (item 15); it is not dropped.
- **Ensure completeness**: If a reviewer's findings seem unusually sparse for their scope, ask them to double-check specific areas before accepting.
- **PR comment dedup (2-layer check)**: Reviewers receive existing PR comments as context for 1st-layer filtering. The lead performs 2nd-layer verification during cross-validation to catch missed duplicates. Both reviewers and lead share responsibility to minimize duplication.
- **Round budget**: how many rounds this protocol drives is defined once in `_common/agent-team-protocol.md`'s `### Round budget` — the default, the ceiling, and the two entry paths that open a third round. There is no extension path: reaching the ceiling surfaces the impasse to the user rather than buying more rounds.
