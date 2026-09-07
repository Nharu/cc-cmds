# In-Session Verification Contract (Shared SOT)

Single source of truth for the in-session verification mechanism: the claim taxonomy, the frozen verdict/residual vocabulary, the verification ledger and residual-item schemas, recipe self-containment rules, the isolated-worktree mechanics, the well-formedness predicate, the drift ladder, and the transformation move. Both **emitters** (`design`, `design-lite`), the **consumer** (`implement`), and the **checker** (`design-audit`) cite this file.

**Posture.** Verification failure means the design must change. So a claim that can be settled *today* — against the current repo or environment, by reading, running unmodified tooling, or a throwaway experiment, with no production implementation present — is settled inside the design session and recorded in the verification ledger. Only claims that genuinely cannot be settled until implementation artifacts exist are encoded as residual items for the consumer to settle, fail-fast, at the start of implementation.

**What this file owns vs. what each SKILL.md owns.** This file is *contracts-only*: vocabulary, schemas, predicates, and execution mechanics. It deliberately excludes *workflow prose* — the Quality-Gate procedure, the pre-save sweep's **trigger point, scope and failure paths**, the consumer's gate flow and failure menus, and the lite budget / split / menu — each of which lives in the owning SKILL.md. The sweep's **pass predicate** is the single carve-out and lives here as §10: it is a predicate rather than a procedure, and it had drifted into two inline copies — exactly the shape this file exists to collapse. Every excerpt or inline copy of this contract elsewhere MUST carry a provenance line naming this file; the frozen-literal lists are defined ONLY here and copies cite, never re-author, them.

**Consumption matrix.** `design` Reads this file in full. `design-lite` Reads it in full (its fourth `_common` Read). `design-audit` Reads §3.4 and §5.2 by reference from its deterministic-checks step and deliberately keeps no excerpt — an excerpt is a copy, and a copy is a parity obligation. `implement` Reads it and uses the `## Residual-item contract` section.

---

## 1. Claim taxonomy (5 categories)

A *load-bearing claim* is an assertion such that, if it turned out false, some design decision would change. Every load-bearing claim falls into exactly one category:

| Cat | Token (`분류`) | Definition | Settling act | Execution surface |
| --- | --- | --- | --- | --- |
| (a) | `정적 사실` | A fact about the current repo/doc state (file/anchor/key existence, grep conventions, line/token counts). | read-only command (grep / ls / Read) | main tree, read-only |
| (b) | `실행 측정` | A value obtained by running existing repo tooling **unmodified** (lint output, test results, budget numbers). | run the tool as-is | main tree, execute-only |
| (c) | `외부 환경` | A fact about the world outside the repo (IDE setting keys, external CLI flags/behavior, documented API behavior). | WebFetch / WebSearch / external CLI | tree untouched (output lands out-of-tree) |
| (d) | `행동 가설` | "Driving the existing system with X yields Y" — decidable via an out-of-tree driver with NO tracked edits. | throwaway out-of-tree script | main-tree execution + /tmp driver |
| (e) | `미니 구현` | The feasibility of a proposed change, where settling it unavoidably requires changing tracked content itself. | throwaway prototype edit + run tooling | **isolated worktree only** |

### 1.1 Routing into (e) — the α∧β entry condition

Route to (e) **iff** both hold:

- **(α)** the observation requires changing tracked content, AND
- **(β)** the observation requires repo-faithful context (path-relative resolution, the build graph, git metadata) that an out-of-tree `/tmp` copy of the relevant subtree cannot preserve.

Therefore:

- **¬α** → categories (a)–(d).
- **α ∧ ¬β** → copy-based (d): copy the relevant subtree out-of-tree, edit the copy, run tooling on the copy. (The (d) definition admits this copy form.)
- **α ∧ β** → (e).

"A worktree is more convenient" NEVER justifies (e).

---

## 2. The two tests: severity pre-filter, then filter test

Composed — severity first, filter second.

- **Severity pre-filter (scope guard on the tagging duty)**: *"If this assertion turned out false, which design decision changes?"* If NONE → no tag needed (prevents per-sentence tag spam). The tagging duty applies to **load-bearing claims only**.
- **Single filter test**: *"Can this claim be settled today — against the current repo or environment, by reading, running unmodified tooling, or a throwaway experiment — with no production implementation present?"*
    - YES → verifiable claim: it carries a `검증 등급` and MUST reach `검증됨(통과)` / `반증됨(실패)` before the document is saved.
    - NO → genuinely implementation-time-only → residual encoding (`잔여 사유: 구현 필요`).

**Linguistic tripwire.** A hedge attached to a *decidable fact* — "should exist", "presumably", "needs to be checked/verified at implementation time" — is a confessed-unverified claim. Checkers explicitly search for these phrasings.

---

## 3. Frozen vocabulary (the verdict/residual token table)

The field key is the single literal **`검증 등급`** everywhere (no `상태` substring — this prevents key collisions with the walkthrough state machine; it parallels `근거 등급`). All literals are NFC byte-exact and carry no dates.

| # | Token (exact bytes) | Where it appears | Written by | Required companion fields |
| --- | --- | --- | --- | --- |
| 1 | `검증됨(통과)` | ledger `### V<n>` | design-session verifier / review main session (run-now) | `주장` `분류` `검증 절차` `기대 결과` `관측 결과` `관측 일시` `영향 결정` (all required) + tree-hygiene note (cat = 외부 환경: optional `유효 조건`; dirty-run: mandatory `유효성 노트`) |
| 1′ | `검증됨(통과)` | residual `### R<n>` flip | implement only (W1) | mandatory W2 note line `**구현 시 검증 기록**: <YYYY-MM-DD> — <observation>[; 치환: <old>→<new>[, …]][; 사용자 위험 수용]` |
| 2 | `반증됨(실패)` | ledger `### V<n>` | design-session verifier / review main session (run-now) | same as #1; `영향 결정` cites the decision **changed** by the refutation (preserved as refutation evidence) |
| 2′ | `반증됨(실패)` | residual `### R<n>` flip | implement only (W1) | W2 note line + failure-surface utterance |
| 3 | `미검증` | Step-3 inter-agent messages only | teammate / lead | none — **MUST NOT appear in a saved document** (sweep pass condition: both the full-line and inline-tag literal forms are document-wide grep 0; the absence-proof exception of the detection grammar in §3.4) |
| 4 | `구현 시 검증` | at `### R<n>` creation (the only save-time residual token) | design/design-lite lead (via the transformation move) / review main session (`잔여 항목으로 기록` disposition) | `주장` `분류` `잔여 사유` `차단 사유` `검증 레시피` `기대 결과` `실패 시 영향`; optional: `필요한 것` `검증 시점` `실행 주의` `예상 소요` `관측 시점` |
| 5 | `검증불가(드리프트)` | residual `### R<n>` flip | implement only (Rung 3) | W2 note line (drift cause) + failure-surface utterance |

> **Enumeration ≠ rendering.** This table (and the §4/§5 field lists, and bulleted field/value enumerations such as §3.1) fixes *which* fields exist and *what bytes* each token is; it does NOT prescribe the markdown *line rendering*. The one normative line rendering is the CANON form **`**key**: value`** — bold key, no leading bullet `- `, exactly one ASCII space after the colon — shown as a verbatim example block in §4 and §5. A markdown bullet used to enumerate a field/value in this contract's prose is a documentation device, not a rendering template; do not copy the bullet (or drop the bold) into an emitted V/R field line.

### 3.1 `잔여 사유` — closed set of 4 values

(These four are token *values*, enumerated as bullets for readability — not a line-rendering template; see the Enumeration ≠ rendering note in §3. The emitted field line is `**잔여 사유**: <value>` in CANON form.)

- `구현 필요` — filter test NO; cannot be settled until an implementation artifact exists.
- `검증 차단` — was executable but could not proceed for a concrete reason (environment access, credentials, external dependency, recursion depth, lost recipe, one-shot inconclusive, review-time user deferral).
- `예산 소진` — lite budget exhausted (count or time; the `차단 사유` prose distinguishes "execution-count budget" vs "time cap N min exceeded").
- `분류 제외` — a category dropped by lite.

The free-prose `차단 사유` is ALWAYS mandatory alongside — it is the audit surface of the dual backstop.

### 3.2 `실행 주의` — closed class of 4 values

`유료/외부 변이` / `머신 상태 변이` / `장시간(>10분)` / `파괴적`. Marks a recipe that requires prior user consent even under an unbounded budget — the recipe outlives the session, so the flag travels with the recipe.

### 3.3 Terminal-token reuse

An implement flip reuses the ledger terminals (`검증됨(통과)` / `반증됨(실패)`) verbatim. Provenance is guaranteed structurally — not by a token variant — by **section + mandatory note line**: implement's only write surface is the R-section, so an R-item's terminal token can only have been written by implement. **If an R-item carries a terminal token but the adjacent `**구현 시 검증 기록**:` line is absent, it is MALFORMED** (well-formedness predicate; enforced at save time by the emitters' pre-save sweep and afterwards by `design-audit`'s deterministic checks, which apply §5.2 by reference). This adjacency check carries no detection logic of its own — it rides the §3.4 grammar, so the note-line key `구현 시 검증 기록` is a member of that grammar's instantiated key set (a legacy bullet/no-bold note line therefore still satisfies adjacency and is not false-flagged).

### 3.4 Detection grammar (the only sanctioned idiom)

All token detection is key-anchored full-line, **tolerant to the bullet and bold axes**, performed within the enumerated range of the owning section. The sanctioned idiom is the `grep -E` ERE `^(- )?(\*\*<key>\*\*|<key>): <value>$` — `(- )?` absorbs an optional leading bullet, and the balanced alternation `(\*\*<key>\*\*|<key>)` absorbs bold-vs-no-bold while **rejecting a half-bold impossible line** (`**검증 등급:`; a naive `(\*\*)?<key>(\*\*)?` would widen to match those). `grep -E` is POSIX ERE (BSD/GNU-portable, not on the `lint-bash-portability` denylist). The key stays anchored as a full line, so a bare-token document-wide grep is still forbidden (the heading substring `구현 시 검증` ⊂ `## 구현 시 검증 항목`, note-line key substrings, `분류 제외` ⊃ `제외` near-collisions, and prose mentions of a token would all defeat a single bare-token rule). Keys instantiated: `검증 등급`, `잔여 사유`, and the note-line key **`구현 시 검증 기록`** (the §3.3 adjacency check rides this grammar, so the note-line key MUST be a member — otherwise a legacy bullet/no-bold note line on a correctly-flipped item reads as false-malformed).

**`<value>` binding**: (i) section-internal key-presence detection uses the generic `<value>` arm as-is; (ii) the `미검증` document-wide absence proof pins `<value>` to the literal `미검증` (a generic arm would over-match arbitrary `검증 등급` lines and break the absence semantics). The W1 lookup / flip-gate value arms are pinned separately by `implement` (the un-flipped `구현 시 검증` value / the terminal-token set).

**Detection-vs-flip-gate asymmetry**: detection/reading is tolerant (above) so legacy documents keep being detected and consumed; `implement`'s **added-side** flip gate is strict-canonical, emitting only `**key**: value`. The tolerant reader and the strict writer are deliberately asymmetric — reading admits all four renderings, writing produces exactly one (a touched legacy line converges to CANON on flip; untouched lines are never migrated).

**Single exception — absence proof of the save-forbidden token (`미검증`)**: it has no owning section, so its absence is proven with a key-anchored **document-wide** match, and **both literal forms** must be 0: the full-line field form (the ERE above with `<value>`=`미검증`) and the inline-tag form `[검증 등급: 미검증]` (kept on `grep -F` — the bracket literal has no bullet/bold axis). (Key-anchoring already blocks substring collisions, so document-wide is safe here; the inline form is the most probable leak path — a Step-3 proposal quotation bleeding into the body.)

V/R sections are **sub-section form only** (`### V<n>.` / `### R<n>.`).

### 3.5 Spelling lock

`검증불가(드리프트)` has no internal space — `검증불가(` is the drift-inventory-only head literal. A save-time token deliberately avoids this head.

### 3.6 Relationship to `근거 등급`

Parallel sibling vocabulary, NOT unified. Reproduction is the prior specialization of verification over already-misbehaving claims: a reproduction finding carries `근거 등급` + the `## 재현·근본원인` section only, and MUST NOT be double-tagged with `검증 등급`. (No single literal collides across grade tokens × the 6 walkthrough states × `근거 등급` tokens × `분류` tokens × `잔여 사유` tokens.)

---

## 4. Verification ledger schema — `## 검증 기록`

An unnumbered heading, placed after `## 주요 결정사항과 근거` and before `## 미해결 이슈 / 트레이드오프`.

- `### V<n>. <claim title>` sub-blocks only. Fields:
    - `주장` — one falsifiable sentence.
    - `분류` — a 5-category token.
    - `검증 절차` — a re-runnable recipe: literal commands or an inline fenced script. **No session-specific tmp path; parametric `mktemp` is the sanctioned form.** For (c): cite the source URL + date + optional `유효 조건`. For (e): reconstructible from a clean checkout — inline the experimental edit as a fenced diff/patch plus worktree setup/teardown; do NOT record a worktree path.
    - `기대 결과` — the pre-registered predicate.
    - `관측 결과` — the actual value / output excerpt.
    - `관측 일시` — required on every entry; ISO date; the reference point for staleness/flake judgments of external-environment entries.
    - `검증 등급` — `검증됨(통과)` | `반증됨(실패)` only. **The ledger accepts only verifications that were performed** — every entry has an observation.
    - `영향 결정` — `§anchor`; on a refutation, the decision it changed.
    - tree-hygiene note — `tracked-source 무변경 확인` or `워크트리 격리 확인`.
    - optional: `유효 조건` (cat = 외부 환경), `유효성 노트` (mandatory on a dirty-tree re-run verdict; see §7).
- If no verification was performed, omit the whole section (parallel to the reproduction section's omission for feature tasks — the sweep guarantees "there were no verifiable claims", so absence is meaningful).
- Propagation is one-way: the SOT is the ledger entry. `주요 결정사항과 근거` references it by anchor and does not restate tokens (no copy, no divergence).

**CANON rendering — copy this byte-for-byte** (bold key, no leading bullet `- `, one ASCII space after the colon):

```
### V1. <claim title>
**주장**: <one falsifiable sentence>
**분류**: <5-category token>
**검증 절차**: <inline commands or fenced script>
**기대 결과**: <pre-registered predicate>
**관측 결과**: <actual value / output excerpt>
**관측 일시**: <YYYY-MM-DD>
**검증 등급**: 검증됨(통과)
**영향 결정**: §<anchor>
tracked-source 무변경 확인
```

(Optional fields — `유효 조건` for cat = 외부 환경, `유효성 노트` on a dirty-tree re-run — render with the same `**key**: value` form.)

### 4.1 In-document claim marking convention (single definition)

Body marking is a **token-free anchor reference** only — at the end of the claim sentence, `(§검증 기록 V<n>)` or `(§구현 시 검증 항목 R<n>)`. The inline `[검증 등급: …]` tag is **Step-3 inter-agent messages only** (a direct transplant of the `근거 등급` propagation pattern; forbidding a body token copy eliminates stale-tag divergence at re-verification time). Every "marking" predicate (sweep, QG, checker criterion, run-now) refers to the presence of this anchor reference.

---

## 5. Residual-item contract — `## 구현 시 검증 항목`

An unnumbered heading, placed after `## 미해결 이슈 / 트레이드오프` and before `## 권장 구현 순서` (the two new sections straddle the unresolved-issues section without touching its parse region). `implement` Reads this contract section wholesale, so it is self-contained here. **A consumer never narrows an enum by omission**: a value its own routing prose does not name is an **unhandled** value, not an excluded one, and reaching one is a defect to surface — never a silent default into another bucket.

- `### R<n>. <claim title>` sub-blocks only. Fields are the required + optional set of token #4. Optional-field definitions:
    - `검증 시점` = `구현 전` (default) | `구현 중(<phase>)` | `구현 후`. The first two are the consumer's gate partitions. **`구현 후`** marks a residual whose observation is obtainable only **after the design has landed and been used** — a usage-data recipe whose inputs are N real invocations or accumulated downstream artifacts, none of which exist while the design is being implemented. It is therefore **not a consumer gate**: the consumer discloses the item, leaves it at `구현 시 검증` for a later invocation to re-discover, and does **not** read the missing verdict as a drift (nothing failed — the observation window has not opened). Author it only when the recipe's inputs are genuinely post-landing; a claim settleable at implementation time is `구현 전` or `구현 중(<phase>)`.
    - `필요한 것` = the environment / credentials / data needed to clear the block (same meaning as the reproduction blocker field of the same name).
    - `관측 시점` = external-environment residuals only — the date of the external observation referenced when the recipe was authored (distinct from the ledger's `관측 일시`, which is the date a verification was performed); an input to implement's drift-ladder staleness/flake judgment.
    - `실행 주의` / `예상 소요` = per §3.2 / free-form duration estimate.
- 0 items → omit the section; the consumer treats absence as "no gate".
- The heading contains neither `미해결` nor `이슈`, so it can NEVER match the walkthrough parse regex (which requires the literal `미해결\s+이슈`) — under the LAST-match doctrine a non-matching heading is inert. `## 검증 기록` proves the same.

**CANON rendering — copy this byte-for-byte** (bold key, no leading bullet `- `, one ASCII space after the colon). The save-time residual token `구현 시 검증` is the value of the `검증 등급` line — the line `implement`'s W1 flips:

```
### R1. <claim title>
**주장**: <one falsifiable sentence>
**분류**: <5-category token>
**잔여 사유**: 구현 필요
**차단 사유**: <free prose — always mandatory>
**검증 레시피**: <inline commands or fenced script>
**기대 결과**: <pre-registered predicate>
**실패 시 영향**: <the decision that changes if this is refuted>
**검증 등급**: 구현 시 검증
```

(Optional fields — `필요한 것` / `검증 시점` / `실행 주의` / `예상 소요` / `관측 시점` — render with the same `**key**: value` form. On flip, `implement` rewrites the `검증 등급` line to a terminal token and appends `**구현 시 검증 기록**: …` directly after it.)

### 5.1 The three birth paths of a residual item

Exactly three:

1. **filter NO** (never attempted) → `잔여 사유: 구현 필요`.
2. **verification-attempt exit** → `잔여 사유: 검증 차단` (or a lite budget reason). The attempt is recorded in `차단 사유` as `attempted: <what ran>, blocked at: <where>`; it does NOT become a V-entry.
3. **`design-audit` reconciliation routing to the `implement` pre-gate** → `잔여 사유: 검증 차단` with the standard blocked-reason prose `감사 시점 사용자 이연 — <YYYY-MM-DD>`. The audit's single reconciliation pass routes each unique defect to exactly one named owner, and this is the arm that lands in the residual encoding.

The ledger holds only performed-and-completed entries; a blocked attempt lives in an R-item's `차단 사유`.

### 5.2 Well-formedness predicate

An R-item is MALFORMED if any of: a required field is missing / it contains a `/tmp` literal / `실패 시 영향` is an unresolved anchor / it uses a token or enum value outside this vocabulary / it carries a terminal token (`검증됨(통과)`/`반증됨(실패)`/`검증불가(드리프트)`) without an adjacent `**구현 시 검증 기록**:` line (per §3.3).

**Line rendering (the bullet/bold axes) is NOT a malformedness axis.** A non-canonical field-line rendering is a §3.4-tolerant-readable form, not a malformed item — the detection grammar reads all four renderings and the consumer's tolerant W1 lookup flips a legacy rendering, so a bullet/no-bold line is cosmetic drift, not a flip-breaker. It is surfaced only as a **trivial** style note by whatever pass is reading the document, scoped to lines that pass actually edited, never via this predicate and never as a retro-flag of untouched lines.

---

## 6. Observation & verification carve-out (running + experimenting ≠ modifying)

A single, generalized definition (it subsumes and replaces the earlier reproduction-only carve-out; two parallel carve-outs would leave the FORBIDDEN-sentence contradiction unowned). A carve-out is a *definition*, not an exception — the "NO code modifications" literals stay literally true.

- **Definition rescope**: a *modification* is a change that persists in the **session's main working tree** (in git vocabulary an experiment worktree is also a "working tree", so a merge without rescoping would self-contradict).
- **FORBIDDEN rescope**: editing a tracked source file **in the main working tree** — forbidden even transiently, even if it will be reverted.
- **Two-command boundary gate** (the "single verifiable invariant" advertisement is retired — scope is per-surface). At every team-discussion boundary check both, in this order:
    1. main tree `git status --porcelain` == the pre-workflow baseline, **within the caller's declared measurement surface** (§6.0);
    2. the worktree baseline, compared as the **three scoped assertions** below (porcelain does not see records inside `.git/worktrees/` — the F1 blind spot — so the worktree list is a separate gate from assertion 1).

**Assertion 2 is scoped, never a whole-output equality.** `git worktree list --porcelain` is a **repository-global** command: run from any worktree it emits every worktree of the shared repository, each with its own `HEAD <sha>` line. Comparing that output wholesale fails the gate whenever an unrelated sibling worktree commits — a tree no caller of this gate measured, and one whose movement changes no byte of anything the caller did measure. All three of these must hold, and they are what assertion 2 means everywhere in this repository:

- **2a — owned path set.** The set of worktree paths (`git worktree list --porcelain | grep '^worktree '`) whose final path component begins with one of the caller's **declared ownership prefixes** equals the baseline set taken the same way. Catches an *owned* worktree created or removed inside the window.
- **2b — own entry.** This caller's own worktree entry — its `worktree` / `HEAD` / `branch` lines — equals the baseline. Catches a HEAD move under the tree the work actually measured.
- **2c — mechanism-owned leak.** The count of entries carrying the `cc-design-exp-` prefix is **0**. A belt-and-braces assertion that proves mechanism-owned cleanup even when a baseline string is lost to compaction, and **never condemns the user's own pre-existing worktrees**.

**2a and 2c are not the same assertion, and the axis that separates them is baseline dependency.** 2a is *relative*: it reads a baseline, so what it catches is an owned worktree that appeared or vanished **inside the window**, and it deliberately passes a leak that was already there when the window opened. 2c is *absolute*: its predicate reads no baseline at all, which is why it still holds when compaction has lost the baseline string — and it fails exactly the case 2a passes. The input that separates them: one inherited `cc-design-exp-` worktree, present at open and still present at close — **2a passes, 2c fails**.

**A sibling worktree's `HEAD` moving is deliberately not a mismatch.** It changes no byte of the caller's own tree and no byte of any reviewed text, so whatever the gate protects — an induced-defect rate, a frozen document, a claim's measurement root — is untouched, and the callers that hash their input hash it directly. This was a measured false positive rather than a hypothetical: an audit halted at `freeze-mismatch` because a sibling worktree of the same repository committed inside the window, while the document hash, every `git status --porcelain` baseline, and every measurement root were unchanged.

**The declared ownership prefixes of assertion 2a.** A caller declares, **before the window opens**, the path prefixes of the worktrees **it owns**; 2a measures those and nothing else. **The default is no prefix**, under which the measured set is empty on both sides and 2a holds trivially — a caller that declares nothing has 2a measure nothing. That default reverses the earlier whole-set equality, and the reason is that the earlier form's polarity could not be made to work: it tried to *exempt other runs' worktrees by name*, so it failed the moment a name it had not anticipated appeared, and no caller can enumerate the names of runs it does not own. Naming one's own worktrees is something a caller can always do. A caller that creates isolated worktrees per §6.2 declares `cc-design-exp-`, the prefix that mechanism already stamps.

**What 2a stops catching, and what covers each piece.** It no longer catches a third party creating or removing a worktree. Tree contents remain assertion 1's; the caller's own HEAD remains 2b's; a mechanism-owned leak, inherited or fresh, remains 2c's; and a caller that hashes its reviewed input covers those bytes with that hash directly.

**Two things are genuinely given up, not one, and the second has no owner at all.** The first is notice that the repository gained an unrelated worktree — which no caller of this gate measures, and which was the sole source of the false halts this scoping removes. The second is a worktree **the caller creates itself, outside every prefix it declared**: 2a does not measure it, because the prefix does not match, and neither does 2c, because 2c counts `cc-design-exp-` entries and nothing else. The whole-set equality this scoping replaces did catch it. Nothing among these three assertions takes it over — a caller that creates worktrees under names it has not declared accounts for them by its own teardown record, and this gate will not notice if it does not.

The declaration is bounded by three things, and it is not safe without all three:

- **It is declared, not inferred.** A prefix chosen after an unexpected worktree appears would shape the measured set around the very change the gate exists to catch.
- **It reaches 2a and nothing else.** Tree contents still have to match (assertion 1), the caller's own entry still has to be where it was (2b), and the mechanism-owned prefix still has to be absent (2c). Those are different failure modes with different owners.
- **The declaring caller owes a teardown guard**, and that guard — not the prefix — is what keeps ownership from being a hole. Matching a declared prefix must never by itself authorize removing a worktree; the caller removes a path only when its own durable record shows that path was created *by this run*, with the prefix as a second, independent condition. A prefix alone would let a hand-made lookalike be torn down.

This parameterization is what lets the gate's own promise — that it **never condemns the user's own pre-existing worktrees** — extend to a caller whose normal operation transforms the worktree set, without weakening it for anyone else.

### 6.0 Assertion 1's declared measurement surface

**This narrowing has not been observed to fire in a shipped run, and the rate belongs at the head of the section rather than in the reader's assumptions.** Measured on this repository's audit corpus on 2026-09-07 — 61 reader witnesses grouped into the 15 complete runs they belong to — it fired in **0 of 15 runs**, both under the predicate defined below and under the predicate that one replaced. Every one of the fifteen retained at least one token forcing the whole-tree fallback. **The token-level reduction reported further down is a different quantity and does not imply this one**: the fallback is an existential quantifier over a run's tokens, so that count can fall by an order of magnitude while the run-level result does not move at all. What holds the rate at zero is the residual classes this section ends with, and **one of them is produced by the audit's primary duty rather than by a misspelling**, so no production-side spelling rule closes it. Until a measurement shows the rate moving, a caller should expect assertion 1 to be whole-tree equality in practice and should treat a narrowed surface as the exception.

**A change to a path outside the caller's declared measurement surface is not a mismatch.** Assertion 1 is equality *within* that surface. When the closing observation differs from the baseline, take the set of paths that difference points at — every path named on an entry present in one observation and absent from the other — and intersect it with the measurement surface. An **empty intersection is not a mismatch** and the window stays open; a non-empty one is a mismatch exactly as before, and the failure report names the intersecting paths, because that line is the only thing telling a later reader what ended the window.

**The comparison is pinned to a canonical form, because prose cannot execute it.** Left as "the paths the difference points at" over git's default output, three ordinary output shapes fall on the missed-mismatch side of the intersection. So:

- **Take both observations with `git status --porcelain -z`.** Default porcelain C-quotes any path `core.quotePath` treats as non-ASCII, and that fires routinely rather than exotically — this repository tracks twelve such paths in one directory — so a quoted entry compares unequal to the same path held unquoted in the surface, and the intersection comes back empty. `-z` emits raw path bytes NUL-separated with no quoting, and it also splits a rename's two paths into separate fields instead of one arrow-joined string.
- **A rename entry names two paths, and both enter the difference set.** Taking only one of them exempts the other.
- **An entry whose path ends in `/`** is git's abbreviation for an untracked directory and stands for everything beneath it: it intersects **every surface path carrying that prefix**, not a path spelled with the trailing slash.
- **Both sides speak one path vocabulary, and the caller checks that they do.** What the intersection needs is that the surface's paths and the observation's paths are **repository-relative paths of the same repository** — the surface's against the tree the records they derive from were measured against (for the design-audit callers, the `CODE_ROOT` handed to their readers), the observation's against the tree the `-z` observation is taken in. Taking both in the same tree guarantees that, but it is a **sufficient condition and not a necessary one**: two linked worktrees of one repository speak the same vocabulary. So the fallback is triggered by the vocabulary rather than by the tree — **if a path on the surface does not resolve as a repository-relative path of the observation's repository, the surface is the whole tree** and no path-wise intersection is attempted. Stated as a bare identity this measured nothing: a difference and a surface whose paths cannot be resolved against it are not comparable at all, so every porcelain entry simply fails to match, the derivation still completes, the intersection comes back empty, and assertion 1 passes for free. In this repository the design-audit callers take the closing observation in the main root — the driver dispatches the audit stage there, and the document, and with it `CODE_ROOT`, sits in that same tree — so on a normal run the two sides already speak one vocabulary and the fallback does not fire. The fallback is for a caller whose stage runs elsewhere, and this contract cannot check that premise on the caller's behalf.

**The default is the whole tree**, so a caller that declares nothing gets today's whole-porcelain equality byte for byte. This default runs opposite to 2a's, deliberately: what 2a stops measuring is another run's worktree, while what assertion 1 would stop measuring is a file in this very tree. Empty that one by default and the gate stops measuring the thing it exists for.

**Where the surface comes from — it is derived, never composed by hand.** From records the caller already writes before it compares anything:

- every repository-relative path in a collected witness's anchor comparison table (that table's anchor column carries the cited path or `path:line`);
- every repository-relative path in a `path:line` citation inside those witnesses' findings;
- every repository-relative path the deterministic checks the caller ran itself cited (those checks land in the report as `## 결정론적 검사` before the boundary baselines are captured, so this source has a producer and its record is sealed ahead of the closing observation).

An anchor entry that is a symbol, a count, or a numeric claim rather than a path contributes nothing. The caller's own output paths and the frozen document need no entry: a caller that hashes its input covers those bytes with that hash directly, so this scoping loses nothing there.

**What this yields is the set of paths the caller CITED, which is strictly narrower than the set it read** — and the contract claims the narrower one, because that is what the three sources above can actually produce. All three key on citation: a check that reads a file and finds nothing wrong leaves no record when only negatives become findings, and a tree-wide search for a cited symbol puts that symbol in the anchor column, which by the rule above contributes no path at all — so every file the search swept stays outside the surface. A caller restating this scoping in its own words restates it this way — **and restates the caveat with it**: on a run where the totality check below put the surface at the whole tree, this narrowing does not hold at all and every porcelain change is inside the surface. A restatement that drops the caveat asserts the narrow scoping unconditionally, which is what this paragraph would otherwise instruct its callers to do. A caller wanting the wider set has to record the wider set first.

**The after-the-fact narrowing hazard, and what closes it.** 2a's prefixes must be declared *before* the window opens because a declaration made after an unexpected worktree appears would shape the measurement around the change. The matching hazard here is shrinking the measurement surface after reading the diff. What closes it is that the surface is **derived rather than selected**, and derived from witnesses that are out-of-tree files sealed with a phase nonce and fixed before the caller observes the closing porcelain at all. **That ordering is a requirement, not a description**: a surface derived after the closing observation is not a surface, and a caller that finds itself deriving one then must treat it as absent.

**Fail closed unless the derivation is total.** The trigger is a predicate on the **derivation**, not on the witness files, and it ranges over the tokens in the **quantified domain** defined below and over nothing else. The unit is the token the derivation actually extracts, not the typeset cell, and this contract defines the extraction rather than leaving it to the reader: from each source line, (i) the **content** of every markdown code span is one token, (ii) every maximal whitespace-separated run of the text outside those code spans is one token, and (iii) when a code span's content holds whitespace, every maximal whitespace-separated run inside that content is a token as well. **A backtick is not part of a token; it is a token boundary** — a code-span anchor and a bare anchor yield the same token, so the span markup never has to be stripped and never has to be tolerated. (iii) is there because a span holding a command and a path together resolves nothing as a whole while the path inside it is real: without splitting the span, that path is extracted by nothing and contributes zero in silence. **The quantified domain is the union of two limbs, and they ask different questions.** The **resolution limb**: drop a trailing `:<line>` or `:<line>:<col>` suffix, and if what remains does not resolve, drop the trailing punctuation `.,;:)]}"'?!` as well; if either spelling resolves as a repository-relative path of the repository the closing observation is taken in, the token is in the domain and the surface carries that spelling. **This limb does not ask what characters the token is made of** — a path carrying non-ASCII bytes, a path with no extension at all, and a path a sentence has put a comma after all enter here. The **shape limb**: the same suffix-dropped text is composed only of the characters `[A-Za-z0-9._/-]`, **holds a `/` separator**, and **either ends in a dot followed by one to five ASCII letters or carries an explicit `:<line>` suffix**. `.` and `..` name no path for this purpose and are in neither limb. **A leading `/` is not a disqualifier on this limb, and an earlier form of it made one.** An absolute path carries a separator and an extension, so it enters the domain here and resolves against nothing — the resolution limb asks for a repository-relative path — and therefore forces the fallback, which is what lets the sentence below name it as an example of that. Disqualifying it removed the only consumption-side detection of a class the production side explicitly forbids, and removed it silently: a witness set spelled in absolute paths derives a surface that intersects no porcelain entry, and one mixing absolute with relative spellings under-derives rather than empties, so the empty-set fallback does not catch that case either. The bare `/` token the conjunct was aimed at needs no exclusion of its own — it carries neither an extension nor a line suffix, so the requirement above already drops it, along with 651 further `/`-leading tokens in the measured corpus. The conjunct was redundant for the case it was written for and load-bearing only for the case it should not have covered. One cell may yield several tokens and each contributes on its own — a cell naming two paths, or a path beside a command, is not lost to the quantified domain the way a cell-level unit loses it. **An earlier form of this paragraph asserted that a token naming a symbol, a command, a count, a number, a ratio or a diff statistic carries a character outside the class and is therefore already given a contribution of zero by the source rules. That assertion was false in both directions, and the two limbs replace it.** It was false on the surface side, because a real repository-relative path can carry a character outside that class, or no extension at all, or a comma the prose appended, and such a path was then neither checked nor counted — it contributed zero in silence, under-deriving the surface and letting assertion 1 pass for free. It was false on the trigger side, because `gate.sh`, `/`, `2/2`, `paid/unpaid` and `owner/name` all pass the character test and resolve to nothing, and **they are not paths at all, so no production-side rule about how a path is to be spelled removes them** — a reader obeying that rule perfectly still calls a file `gate.sh` in a sentence. Measured on 2026-09-07 over 71 witness and report files: the single-character-class predicate fired the fallback on 3,788 token occurrences in 70 of the 71 files, while 370 occurrences of real repository-relative paths fell outside its domain and contributed zero in silence; the two limbs bring those to 391 occurrences in 52 files and to 0 respectively, and the derived surface from 128 paths to 146. **Those movements have opposite signs and are not one reduction**, so this contract reports them apart. A token stops firing the fallback in two ways: it is **resolved and taken onto the surface**, which means the instrument gained a path and is the improvement, or it is **excluded from the quantified domain**, which means the instrument stopped looking at it and is an improvement only where the token was never a path. A token's disposition can also *start* firing the fallback: tokenization rule (iii) extracts tokens the replaced form never produced, so the two totals are taken over different token universes and their difference is not the reduction reported below. Of the 3,416 occurrences that stopped firing, **none stopped by resolving**; all 3,416 left the domain, and that exclusion splits into **1,158 (33.9%) non-path tokens**, the noise the shape limb exists to remove, and **2,258 (66.1%) tokens naming a real file**, where an alarm became silence. The resolution limb contributes nothing to that reduction: its effect is the 370 → 0 and the 128 → 146, both of which only add to the surface. **The two limbs are therefore orthogonal and must not be read as one reduction rate** — one only adds to the surface and the other only subtracts from the domain, so a combined percentage hides the sign of each. The shape limb's separator requirement is what removes the largest of those non-path classes, and **it loses no path**: a repository-relative path with no `/` in it is a root file, and a root file resolves, so the resolution limb is already holding it. **The surface is the derived path set only when all three sources above were enumerated from a durable record sealed before the closing porcelain observation and every token in the domain those sources carry resolves, with nothing rewritten beyond the suffix and trailing-punctuation dropping the resolution limb defines, as a repository-relative path of the repository the closing observation is taken in. Every other case is the fallback: if any such token fails to resolve that way for any reason whatever, or the derived set comes back empty, the measurement surface is the whole tree, not the empty set.** An absolute path, a well-formed relative path naming a location outside `CODE_ROOT`, and a well-formed relative path naming something that is not there are **examples and not the extension** — the extension is the complement of the positive condition, and no enumeration narrows it. Enumerating the ways to fail is what previously left a zone neither form spoke for, so that widening the positive form changed which tokens were covered without shrinking that zone; a complement leaves no zone to shrink. **The residuals are enumerated by behaviour, not by discovery order.** An ordinal list — a first residual, a second residual — closes, and a class nobody has named yet then has nowhere to stand; that is the same failure this paragraph diagnosed above for the negative form, arriving by another route. The two axes below are what a token *does*, and a relaxation argued on one of them does not carry to the other. **Axis 1 — in the domain, resolving against nothing, so the fallback is forced.** The classes named so far on this axis are a partial path citation and an absence-confirming citation. A **partial path citation** is a token such as `autopilot/SKILL.md`, naming a real file by the tail of its path: it satisfies the shape limb, resolves against nothing, and unlike the classes above it *is* a path spelled wrong, which is the thing a production-side rule can close. An **absence-confirming citation** is not, and it is named here for the first time: a reader that spells a path exactly right and judges it absent leaves an anchor that resolves against nothing **because the file is not there**, which is an observation and not a defect in the record. The reader contract requires a `MATCH` / `MISMATCH` / `ABSENT` verdict on every anchor and makes finding absent anchors a primary duty, so this class grows as the audit does its job better; a spelling rule governs how a path is written and not what a reader finds, so no production-side rule closes it. Independently reproduced at 11 of 63 witnesses and 5 of 6 runs, on an instrument other than the one the figures above come from. **This contract names that class and does not close it** — what it would take on the predicate side is not defined here, and nothing in this section should be read as claiming the class is handled. A branch or lock name spelled with a `/` reaches neither class: it carries no extension and no line suffix, so the shape limb excludes it. **Axis 2 — outside the domain and silent, so nothing forces the fallback and nothing is checked.** The class measured here is a **citation of a real file by its basename alone**, and it is one member of this axis rather than its extent — `SaleManagement.tsx:28` where the file is `src/components/pages/store/sale/SaleManagement.tsx`. It holds no separator, so the shape limb misses it; it resolves against nothing, so the resolution limb misses it too; it contributes zero in silence, and that file's path never reaches the surface. An earlier form of this paragraph named this class **a broken citation of a root file** — `Makefile:57` once `Makefile` is gone — which is one member of it and not the class. Measured over the separator requirement's whole exclusion set in this repository's audit corpus: 2,373 occurrences, of which **2,258 (95.2%) are basenames of nested tracked files** and 115 name nothing the tracked tree answers to. The old name can only ever have pointed inside that 115, because a root file that still exists resolves and is therefore never in this set at all. **The bound is withdrawn.** Any file whatever can be cited by its basename, so the exposure is bounded by the number of files in the repository rather than by the number of root files, and "a caller can enumerate them" does not survive that restatement. The trade itself still stands — dropping the separator requirement readmits the non-path class that requirement exists to remove and kills the narrowing again — but it costs more than the old name implied, and the cost is recorded here rather than argued away. Calling this class back into the domain would take a new decision rule, and this contract does not make one. Neither axis is a hole in any of the three assertions. **The resolution limb also admits a prose word that happens to coincide with a repository path**, which widens the surface rather than narrowing it and is accepted for that reason. That is the correct direction — the fallback widens the surface, so a token this contract cannot classify costs a wider equality check and never a narrower one. That is the clock the paragraph above already fixed, and it is the only one a caller can meet: the reader witnesses are written by readers spawned after the window opens, so a record required to predate the opening cannot exist for sources 1 and 2 whichever candidate opening point is taken, the trigger would hold on every run, and the scoping this section defines would never fire in a shipped run. Sealing before the closing observation is **necessary**, and it is the half of the hazard this trigger can check: the diff cannot be read and the surface then shrunk, because every record the surface derives from is already fixed when that diff is taken. It is not sufficient, and it does not stand in for the ordering the paragraph above fixed as a requirement — that the surface is **derived rather than selected**, and that a surface derived after the closing observation is not a surface at all. That requirement is owned there and this sentence does not weaken it. **A partial derivation is not a smaller surface**: with no rule saying otherwise the natural handling is the union of whatever happened to resolve, and that union is a surface small enough to let assertion 1 pass for free. An empty or under-derived surface makes assertion 1 pass unconditionally, which is an unchecked field wearing the shape of a check.

**"Does not parse" needs its own predicate, because the witness-existence check is not one.** The only structural check the witness mechanism owns is existence — the file is present, its last non-empty line is a nonce-carrying sentinel, and the key matches — and none of that inspects the body. A witness whose anchor comparison section is missing outright therefore exists, parses by that check, contributes zero paths, and shrinks the surface silently. For this derivation a witness **parses** when its anchor comparison table's heading is present **and** the table's header row follows it; a witness failing that check takes the same whole-tree fallback as a missing one.

**A caller whose records carry no such paths cannot declare a surface.** Declaring one requires accumulating the paths measured *at the moment they were cited*, in a record that outlives the citing agent. A caller that keeps no such record gets the default, and assertion 1 stays whole-tree equality for it.

### 6.1 Surface 1 — main working tree (reproduction + categories a/b/c/d)

Today's rules, unweakened. ALLOWED additionally includes (c)'s WebFetch / external CLI (output lands out-of-tree). The cleanup boundary "before findings leave their producer" generalizes from reproduction findings to the **verification verdict** (the earliest of: broadcast / verdict-citing SendMessage / `[COMPLETE]` return / a document Edit).

### 6.2 Surface 2 — isolated worktree ((e) only)

- **Mechanism (normative)**: `WT=$(mktemp -d "${TMPDIR:-/tmp}/cc-design-exp-<slug>.XXXXXX")` then `git worktree add --detach "$WT" HEAD`. `mktemp` is a MUST (uniqueness = concurrency safety; TMPDIR root; the prefix is the cleanup sweep's ownership marker). **EnterWorktree is forbidden** (its only-if-unchanged auto-cleanup guarantees a leak for a changed mini-implementation worktree); the Agent-tool isolation form is forbidden (unavailable to teammates; it fragments the cleanup inventory). `--detach` is mandatory (no branch-namespace pollution; safe under concurrent creation). A teammate may create a worktree under the same `mktemp` + `--detach` duty.
- **In-worktree FORBIDDEN (lock)**: no commit creation / no branch / no push / no tag / no `git config` write / no hook install / no gc·maintenance / **no stash** (`refs/stash` is a shared namespace — the per-worktree refs are only HEAD, bisect, worktree, rewritten — so an in-worktree stash survives worktree removal in the main repo's `git stash list`, a porcelain-invisible leak). Commit-creation exception: only if a tool *must* create a commit and cannot be turned off (a requirement for committed *state* is already met by the detached HEAD — HEAD is a commit); when invoked, use inline `git -c user.name=… -c user.email=…` (the config-write ban holds), detached-HEAD only, and unreachable objects are explicitly accepted garbage (a failure tolerance, not a license — do NOT try to gc them away).
- **Lifetime**: exists only between claim pre-registration and that claim's **verdict broadcast**. A mid-experiment `[IN PROGRESS]` observation share is not a kill event (avoids the pathological per-message teardown-rebuild). Hard kill-points (list == baseline required): verdict broadcast / Quality Gate / producer `[COMPLETE]` / pre-save sweep / abort / Step 6 entry. **No persistence across re-convergence** — a re-convergence experiment is regenerated from the recipe (which already exists as a broadcast precondition; regeneration is deterministic because the main tree is frozen for the whole session). One experiment = one worktree, never shared across agents.
- **Final-run rule** (the mechanization of recipe-completeness): iteration within the lifetime is free, but a verdict broadcast is backed only when the **recorded recipe's patch, applied on a clean in-worktree reset, is observed in a final confirming run that matches the recorded `관측 결과`**. A clean run that observes something different is a FAILED confirmation (correct the recipe / `관측 결과` and re-broadcast, or re-grade `반증됨(실패)`). The reset is one inseparable fenced line: `cd "$WT" && git checkout -- . && git clean -fd` (omitting `git clean -fd` lets a prior run's untracked residue contaminate the final confirmation; run from the wrong cwd this reset destroys the user's untracked files in the main tree, so no form other than this single cd-embedded line is allowed — it is the most destructive command this mechanism emits).
- **cwd-pinning principle**: every command that reads or mutates tree state names its own tree explicitly — gate commands `cd` to the main tree's absolute path (subshell form; honoring the no-`git -C` rule), the destructive reset embeds `cd "$WT"`. Running a gate check after `cd "$WT"` is a false pass that inspects the worktree's status.
- **Cleanup**: the producer runs `git worktree remove --force "$WT"` + `git worktree prune` + a list-vs-baseline check before the verdict ships. Lead backstop: the pre-save sweep and the Step-6-entry state-check add the two-command gate. `prune`'s incidental cleanup of a user's stale worktree is accepted residual (the prefix naming mitigates; remove-own-paths takes priority).

---

## 7. Drift ladder (3-rung + flake pre-classification)

Consumed by `implement` (verbatim). Any other pass that re-runs a recorded recipe consumes it verbatim too — no pass-local adaptation.

- **Rung 1 — verbatim execution**: run the recipe as recorded. **An observation that contradicts the expectation is NOT drift — it is a FAIL** (an environment change breaking an assumption is exactly the gate's reason to exist). A transient failure of an external-category recipe gets one retry, then Rung 3 (synthesize the `관측 시점` timestamp + `유효 조건`).
- **Rung 2 — bounded re-derivation**: **location identifiers only** (file paths, line numbers, directory names) may be substituted, and each substitution needs mechanical evidence (a verbatim hit at the new location, or a rename visible via `git log --follow`). Any change to claim text / predicate / expected result → Rung 3. **One adaptation pass only** (an adapted recipe that then fails to run → Rung 3 — repeated adaptation is experiment re-derivation). The substitution map (old→new) is recorded on the W2 line; the full adapted recipe text stays in implement's plan/log (outside the document).
- **Rung 3 — report-never-skip**: `검증불가(드리프트)` + cause, with the same failure surface as a refutation.

---

## 8. Transformation move (in-session-unverifiable → R-item)

Input = a blocked-exit record (or a never-attempted filter-NO claim). Output = an R-item per the §5 schema, inheriting fields and assigned a `잔여 사유`. `design` and `design-lite` perform the identical move; the *trigger point* is owned by each SKILL.md's gate prose (it is economically divergent). The three birth paths of §5.1 are the only ways an R-item comes into being.

---

## 9. Recipe self-containment rules (manual discipline)

A recipe must be recordable as a self-contained inline recipe; if it cannot (too large), split the claim or make it residual. Disciplines:

- Parametric `mktemp` only; no session-specific tmp path.
- Inline the patch (fenced diff/patch); never cherry-pick, never ship code.
- cwd-pinning per §6.2 (every tree-touching command names its tree).
- The (e) reset is the single inseparable fenced line of §6.2.
- Avoid BSD/GNU-divergent idioms (the `lint-bash-portability` denylist) so the recipe re-runs across hosts.
- **throwaway duty**: ship the recipe, not the code — `implement` re-derives from the recipe. The anti-creep tell "oh and here's the code, just use it" is implementation, not verification.
- **pre-registration**: record a falsifiable `주장` + a pass/fail `기대 결과` **before** running — the artifact is verdict+evidence, not an artifact.
- **verified ≠ correct**: a verdict is scoped to the claim's *exact wording*; cross-review challenges experiment representativeness.

---

## 10. Pre-save sweep pass conditions (shared predicate)

The sweep *procedure* — when it fires, what it scopes over, and what happens on failure — lives in each owning SKILL.md, and the failure paths are deliberately divergent. What is **shared** is the pass predicate, defined once here so no copy can drift. `design` and `design-lite` both cite this section and neither restates the conditions.

A sweep **PASSES** iff all four hold over the synthesis draft:

1. **Save-forbidden token absent** — both literal forms of `미검증` are document-wide 0: the full-line field form (the §3.4 ERE with `<value>` pinned to the literal `미검증`) and the inline-tag form `[검증 등급: 미검증]` (`grep -F`). This is the absence-proof exception of §3.4.
2. **Every verifiable load-bearing claim is anchored** — 0 verifiable load-bearing claims without a `(§검증 기록 V<n>)` or `(§구현 시 검증 항목 R<n>)` anchor reference (§4.1).
3. **Residual encoding complete** — every `구현 시 검증` item is present in the `## 구현 시 검증 항목` residual encoding (§5).
4. **Two-command boundary gate == baseline** (§6) — assertion 1 and all three of assertions 2a/2b/2c, as §6 defines them. Do not restate a partial form of either half here: a sweep that checked only the `cc-design-exp-` count would pass a leaked user-visible worktree, and one that compared the whole `git worktree list --porcelain` output — or ran assertion 1 outside the caller's measurement surface — would fail on a change no caller of this gate ever measured.

Any condition failing makes the sweep **FAIL**, and the owning SKILL.md's failure path takes over from there — `design` allows at most one re-convergence cycle per failing claim before escalating; `design-lite` routes to its Round 3 and then to a 3-option escalation. Those paths are economically divergent by design and are **not** unified here.

**Why this is the one carve-out from the file's contracts-only posture.** A pass predicate is a predicate, not a procedure: it is exactly the kind of thing this file exists to hold. It had drifted into two inline copies, which is the same structure this repo treats as a maintenance tax everywhere else — so collapsing it by reference removes the copy rather than adding a lint to keep two copies honest. **Do not add a coupling lint for this section**: with no second copy there is nothing to synchronize, and registering a new parity pair would reinstate the tax the collapse just removed.
