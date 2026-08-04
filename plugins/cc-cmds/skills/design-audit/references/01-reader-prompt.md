# Reader Prompt

Agent prompt template for an independent audit reader. Consumed by Step 3 before spawning each reader. Before calling `Agent()`, substitute `{round}` with `ROUND_TOKEN` and `{pass}` with `PASS_TOKEN` (both from the SKILL.md `## Control-Flow Invariants` CFI-0 constants block), `{NOTE}` with the trailing user note (or an empty line when none), `{BASE_MODE_CONSTRAINT}` with the `--base` block (or an empty line), and the path/witness tokens per the substitution contract below — each substituted independently at a single level.

**MUST — the rendered prompts are byte-identical across readers** except for `{WITNESS_PATH}`, `{WITNESS_NONCE}`, and `{role-slug}`. Giving readers different lenses destroys the reinforcement multiplicity the disclosure block reports: with disjoint lenses every finding is trivially unreinforced.

## Prompt body

```
You are an independent auditor of a FROZEN design document. Perform ONE independent pass.

This review is Round {round} of pass {pass}. Both values are supplied by the main session and injected verbatim — do NOT derive, increment, or re-count either from disk, from your own history, or from any file in the repo.

FREEZE NOTICE: the document is frozen for the duration of this pass. You are read-only against the document AND against the entire repository. Publish nothing except your witness file. Do not edit, create, move, or delete any file other than your own witness temp.

REPO GROUND-TRUTH MEASUREMENT (MANDATORY — reading the document is not sufficient):
You MUST NOT report only on the document's internal coherence.
(a) For every file path, path:line anchor, symbol, command, count, or numeric claim the document cites, open the cited target read-only (Read / Grep / Glob / ls / git log) and record one row of your "## 앵커 대조표" with a verdict of MATCH, MISMATCH, or ABSENT plus the observed value. Report the anchor rows EVEN WHEN EVERY ANCHOR MATCHES — the table is evidence that measurement happened, not a finding list.
(b) For every artifact the document's own architecture REQUIRES to exist — a command, a file, a hook, a gate predicate, a convention or config file, a script — verify that some step of the document actually creates it and that it is reachable. Report every "required but created by no step" as a finding.
(c) Reading a recipe or a command is REQUIRED. RUNNING a verification recipe, or any command that mutates state, is FORBIDDEN. Read-only inspection commands are how you satisfy (a) and (b).

Then audit the document against ALL of the following criteria:

1. Repo ground truth — the clause above. This is the primary criterion, not an addendum.
2. Internal coherence — data models, contracts, sequence flows, and component responsibilities must be mutually consistent. A field or rule added in one section must appear correctly in all related sections.
3. Implementation order — the proposed sequence must respect dependencies. No step may consume an artifact a later step creates. This is now checkable against the repo, not only against the prose.
4. Missing items — gaps: error handling unspecified, edge cases uncovered, security considerations absent, migration or rollback undefined.
5. Feasibility, grounded in repo reality — does the cited API, script, flag, or capability actually exist in this tree and behave as the document assumes?
6. Stated-requirement traceability — trace each design decision to a requirement recorded in an artifact ON DISK that the document cites as its source (a handoff bundle, a base design document, an issue). This is explicitly NOT consistency against an unrecorded discussion: your sensitivity to that class is structurally zero because the evidence is not in the artifact, and it is owned by a different pass. Do not attempt it.
7. Verification bookkeeping — the SEMANTIC REMAINDER ONLY: a claim that could be settled today but carries no anchor reference (§검증 기록 V<n> or §구현 시 검증 항목 R<n>), and a residual whose "실패 시 영향" points at a decision the document does not contain. The mechanical half — token vocabulary, required-field presence, absence proofs — has ALREADY been run once by the main session and handed to you as DETERMINISTIC_FINDINGS. Do not duplicate it.

{NOTE}

{BASE_MODE_CONSTRAINT}

IMPORTANT: Do NOT modify the design document. Report findings only.

Your witness has two required parts, in this order.

PART 1 — the anchor ledger:

## 앵커 대조표
| 앵커 | 문서 주장 | 실측 | 판정 |
| --- | --- | --- | --- |
| <cited path / path:line / symbol / number> | <what the document says> | <what you observed> | MATCH \ MISMATCH \ ABSENT |

PART 2 — the findings, each in this format:

### F-{role-slug}-<n>
- **Location**: <section or anchor in the document>
- **Issue**: <what is wrong>
- **Evidence**: <path:line, or the command you ran and the bytes/values you observed>
- **Concept**: <what should change and why>
- **영향**: <one line — what breaks downstream if this is not fixed>

Do NOT assign a severity tier. The reconciling session assigns severity as a single labeller; per-reader severity labels are not comparable across readers and are never aggregated. The "영향" line gives the labeller everything it needs.

If you found nothing, publish a witness containing the anchor table and an explicit "발견 0건" line. Never publish an empty witness.
```

## Substitution contract

Each placeholder is substituted **independently at a single level** — there are no nested tokens. Body placement order is `{NOTE}` → `{BASE_MODE_CONSTRAINT}`, with one readability blank line between them.

- `{round}`: replace with `ROUND_TOKEN` from the SKILL.md CFI-0 constants block. Inline scalar. Never a counter, never reset, never derived from disk.
- `{pass}`: replace with `PASS_TOKEN` from the same block. It doubles as the protocol's witnessed `{round/phase}` key, so the two consumers are served by two constants with no derivation.
- `{NOTE}`: when the user supplied no note, substitute a single empty line; when non-empty, substitute the single line `USER-PROVIDED NOTE (focus/context for this audit): <note>` — identical bytes for every reader.
- `{BASE_MODE_CONSTRAINT}`: when `--base` is present, substitute the BASE MODE CONSTRAINT block from the SKILL.md `## Options` section; otherwise substitute a single empty line so the prompt structure stays stable.
- `{role-slug}`: `reader-<k>`. `{WITNESS_PATH}`, `{WITNESS_NONCE}`: per the task-assignment header of the shared team protocol.
- `{DOC_PATH}`, `{CODE_ROOT}`, `{DETERMINISTIC_FINDINGS}`: per the path context prepend below.

**Only `{WITNESS_PATH}`, `{WITNESS_NONCE}`, and `{role-slug}` may differ between the rendered prompts.**

## Path context prepend

Before the prompt body above, prepend the task-assignment header from `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md` verbatim, then this path context block:

```
This reader's working paths:
- DOC_PATH={absolute path of the frozen design document}
- CODE_ROOT={absolute repo root resolved from the document's own directory, or the document's directory when no repo root resolves}
- DETERMINISTIC_FINDINGS={absolute path of the audit report's ## 결정론적 검사 section}
IMPORTANT: measure against CODE_ROOT. Read DETERMINISTIC_FINDINGS first so you do not re-report what has already been found mechanically.
```

## Why the repo-measurement clause exists

The first real fan-out run of this shape produced its heaviest findings as a set, and **every one of them was a thing that did not exist** — a command the architecture required that no step created, a gate predicate an overhaul deleted, and a convention file that was never tracked and so never shipped. A reader that checks only the document's internal coherence passes all of them. In the same run every reader independently caught the same citation-anchor error and the remaining twenty-two citations were verified correct, so the anchor table is cheap as well as load-bearing.

The clause is also a deliberate repair. The predecessor prompt attached an unqualified prohibition on running recipes or commands to its verification criterion, which read literally forbade repo *inspection* on the one criterion sitting squarely inside the class a fresh reader is supposed to be good at. The split here is exact: read-only inspection REQUIRED, execution FORBIDDEN.
