# In-Session Verification Contract (Shared SOT)

Single source of truth for the in-session verification mechanism: the claim taxonomy, the frozen verdict/residual vocabulary, the verification ledger and residual-item schemas, recipe self-containment rules, the isolated-worktree mechanics, the well-formedness predicate, the drift ladder, and the transformation move. Both **emitters** (`design`, `design-lite`), the **consumer** (`implement`), and the **checker** (`design-audit`) cite this file.

**Posture.** Verification failure means the design must change. So a claim that can be settled *today* — against the current repo or environment, by reading, running unmodified tooling, or a throwaway experiment, with no production implementation present — is settled inside the design session and recorded in the verification ledger. Only claims that genuinely cannot be settled until implementation artifacts exist are encoded as residual items for the consumer to settle, fail-fast, at the start of implementation.

**What this file owns vs. what each SKILL.md owns.** This file is *contracts-only*: vocabulary, schemas, predicates, and execution mechanics. It deliberately excludes *workflow prose* — the Quality-Gate procedure, the pre-save sweep's **trigger point, scope and failure paths**, the consumer's gate flow and failure menus, and the lite budget / split / menu — each of which lives in the owning SKILL.md. The sweep's **pass predicate** is the single carve-out and lives here as §10: it is a predicate rather than a procedure, and it had drifted into two inline copies — exactly the shape this file exists to collapse. Every excerpt or inline copy of this contract elsewhere MUST carry a provenance line naming this file; the frozen-literal lists are defined ONLY here and copies cite, never re-author, them.

**Consumption matrix.** `design` Reads this file in full. `design-lite` Reads it in full (its fourth `_common` Read). `design-audit` Reads §3.4 and §5.2 by reference from its deterministic-checks step and deliberately keeps no excerpt — an excerpt is a copy, and a copy is a parity obligation. `implement` Reads it and uses the `## Residual-item contract` section. `review` and `review-lite` Read **§11 only** — the citation convention — because they publish reports whose citations point into documents they do not own.

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

**An out-of-band settlement is recorded through this same surface.** Where a residual is settled outside an implement run — a `구현 후` item whose observation window has opened, an external fact that became checkable — the record is still made **by `implement`, at its next invocation, through W1/W2**, and never by another writer editing the R-section directly. That is what keeps the provenance guarantee structural rather than conventional: the guarantee is that the R-section has exactly one writer, so widening who may settle an item would spend the very property this subsection rests on.

### 3.4 Detection grammar (the only sanctioned idiom)

All token detection is key-anchored full-line, **tolerant to the bullet and bold axes**, performed within the enumerated range of the owning section. The sanctioned idiom is the `grep -E` ERE `^(- )?(\*\*<key>\*\*|<key>): <value>$` — `(- )?` absorbs an optional leading bullet, and the balanced alternation `(\*\*<key>\*\*|<key>)` absorbs bold-vs-no-bold while **rejecting a half-bold impossible line** (`**검증 등급:`; a naive `(\*\*)?<key>(\*\*)?` would widen to match those). `grep -E` is POSIX ERE (BSD/GNU-portable, not on the `lint-bash-portability` denylist). The key stays anchored as a full line, so a bare-token document-wide grep is still forbidden (the heading substring `구현 시 검증` ⊂ `## 구현 시 검증 항목`, note-line key substrings, `분류 제외` ⊃ `제외` near-collisions, and prose mentions of a token would all defeat a single bare-token rule). Keys instantiated: `검증 등급`, `잔여 사유`, and the note-line key **`구현 시 검증 기록`** (the §3.3 adjacency check rides this grammar, so the note-line key MUST be a member — otherwise a legacy bullet/no-bold note line on a correctly-flipped item reads as false-malformed).

**`<value>` binding**: (i) section-internal key-presence detection uses the generic `<value>` arm, and **that arm is `(.+)` — it does not match an empty value**; (ii) the `미검증` document-wide absence proof pins `<value>` to the literal `미검증` (a generic arm would over-match arbitrary `검증 등급` lines and break the absence semantics). The W1 lookup / flip-gate value arms are pinned separately by `implement` (the un-flipped `구현 시 검증` value / the terminal-token set).

**Pinning the generic arm is not cosmetic.** Realized as `.*` it matches a line whose value is empty — `**주장**: ` with nothing after the space — so a required field emitted half-written reads as **present** and passes straight through the *required field missing* axis of §5.2. That puts a half-writing emitter in a worse state than one that omits the line outright: the omission is caught and the empty value evades the catch. `(.+)` is what makes the two agree.

**The mandatory ASCII space is load-bearing, and it is stated here rather than left implicit in the arm.** The idiom's `: ` is exactly one ASCII space, and **it — not the `<value>` arm — is what excludes the bare-colon key line** a payload-bearing field uses (`**<key>**:`, nothing after the colon). The two exclusions are separable, which is why this needs saying: a later edit that relaxes the space while leaving the arm at `(.+)` breaks the exclusion and leaves every argument resting on it true but no longer applicable.

**A key whose producer authorizes a table rendering needs two arms, and this grammar supplies only one.** `상태` is that case in the tree today: its producer authorizes both a sub-section rendering (`**상태**: <value>`, which this idiom matches) and a table rendering (a `상태` **column** whose value is a cell, which it cannot match — the value is not the remainder of the line). A consumer keyed on this idiom alone therefore sees sub-section documents only, and a consumer that loosens to a bare `상태.*해결` over-matches prose and rationale text. **Every consumer of such a key states which renderings it reads**, and none of them may convert a non-match into a value: an absent or unmatched `상태` is **undetermined**, never a default. Defaulting it silently is deciding, on the user's behalf, a question the document did not answer — and where the key gates a binding-vs-reference tier, the lenient direction of that default is the one that removes an approval requirement.

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
    - `검증 시점` = `구현 전` (default) | `구현 중(<phase>)` | `구현 후`. The first two are the consumer's gate partitions. **`구현 후`** marks a residual whose observation is obtainable only **after the design has landed and been used** — a usage-data recipe whose inputs are N real invocations or accumulated downstream artifacts, none of which exist while the design is being implemented. It is therefore **not a consumer gate**: the consumer discloses the item, leaves it at `구현 시 검증` for a later invocation to re-discover, and does **not** read the missing verdict as a drift (nothing failed — the observation window has not opened). Author it only when the recipe's inputs are genuinely post-landing; a claim settleable at implementation time is `구현 전` or `구현 중(<phase>)`. **The exit transition is named here, because without one the item is re-disclosed on every invocation forever**: the 1.5a partition is invocation-invariant, `design-audit` flips nothing, and the R-flip belongs to `implement` alone, so nothing in the machinery ever retires it. The item leaves this state only when its **author** acts — either the window opens and the author lowers `검증 시점` to `구현 전` or `구현 중(<phase>)`, at which point the ordinary consumer gate takes over and settles it, or the settlement happens out of band and is recorded per §3.3. Until one of those, repeated disclosure is the intended behavior rather than a defect to route around.
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
3. **`design-audit` reconciliation routing to the `implement` pre-gate** → `잔여 사유: 검증 차단` with the standard blocked-reason prose `감사 시점 라우팅 — <YYYY-MM-DD>`. The audit's single reconciliation pass routes each unique defect to exactly one named owner, and this is the arm that lands in the residual encoding. **The literal says routing rather than deferral by the user, because no user chooses this**: the lead assigns the owner, the pass's only user-facing call is reserved for its synthesis question, and that call's destinations do not include the implement pre-gate. The predecessor flow's wording was accurate for the predecessor — there the value came from a three-option prompt — and carrying it across asserted a user decision that never happens on this path.

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
    1. main tree **capture format** == the pre-workflow baseline;

    **THE CAPTURE FORMAT IS DEFINED HERE, ONCE, AND NOWHERE ELSE RESTATES IT.**

    ```
    git status --porcelain --untracked-files=all
    ```

    `--untracked-files=all` is not a refinement, it is what makes the gate's own obligations satisfiable. The bare `git status --porcelain` **folds an untracked directory into a single entry**: creating `docs/auth-flow.md` in a repo that does not track `docs/` emits `?? docs/`, and creating a second file inside emits **nothing new at all**. Two consequences, and each on its own would be enough:
    - The §6.3 (v) bracket requires asserting that *every path in the observed delta is one this act just wrote*. Under the folded form the delta names `docs/`, a directory the act did not write, so the assertion is **unsatisfiable in principle** the moment an exempt act creates a directory.
    - A foreign write into a directory that is already folded produces **delta 0**, so the plain equality gate passes over it. The gate is blind to exactly the writes it exists to catch.

    **Every other site refers to "the capture format" and does not respell it.** A format spelled in fifteen places is a format that gets updated in nine of them; the one measurement that matters here is that a partial update be *detectable*, and it is detectable only while there is one spelling to compare against. `scripts/lint-capture-format.sh` enforces that. The one admitted exception is a sentence that contrasts the two forms, which necessarily contains both;
    2. `git worktree list --porcelain` == the pre-workflow baseline (porcelain does not see records inside `.git/worktrees/` — the F1 blind spot), plus a belt-and-braces assertion of 0 entries with the `cc-design-exp-` prefix (proves mechanism-owned cleanup even when a baseline string is lost to compaction, and **never condemns the user's own pre-existing worktrees**).

### 6.1 Surface 1 — main working tree (reproduction + categories a/b/c/d)

Today's rules, unweakened. ALLOWED additionally includes (c)'s WebFetch / external CLI (output lands out-of-tree). The cleanup boundary "before findings leave their producer" generalizes from reproduction findings to the **verification verdict** (the earliest of: broadcast / verdict-citing SendMessage / `[COMPLETE]` return / a document Edit).

### 6.2 Surface 2 — isolated worktree ((e) only)

- **Mechanism (normative)**: `WT=$(mktemp -d "${TMPDIR:-/tmp}/cc-design-exp-<slug>.XXXXXX")` then `git worktree add --detach "$WT" HEAD`. `mktemp` is a MUST (uniqueness = concurrency safety; TMPDIR root; the prefix is the cleanup sweep's ownership marker). **EnterWorktree is forbidden** (its only-if-unchanged auto-cleanup guarantees a leak for a changed mini-implementation worktree); the Agent-tool isolation form is forbidden (unavailable to teammates; it fragments the cleanup inventory). `--detach` is mandatory (no branch-namespace pollution; safe under concurrent creation). A teammate may create a worktree under the same `mktemp` + `--detach` duty.
- **In-worktree FORBIDDEN (lock)**: no commit creation / no branch / no push / no tag / no `git config` write / no hook install / no gc·maintenance / **no stash** (`refs/stash` is a shared namespace — the per-worktree refs are only HEAD, bisect, worktree, rewritten — so an in-worktree stash survives worktree removal in the main repo's `git stash list`, a porcelain-invisible leak). Commit-creation exception: only if a tool *must* create a commit and cannot be turned off (a requirement for committed *state* is already met by the detached HEAD — HEAD is a commit); when invoked, use inline `git -c user.name=… -c user.email=…` (the config-write ban holds), detached-HEAD only, and unreachable objects are explicitly accepted garbage (a failure tolerance, not a license — do NOT try to gc them away).
- **Lifetime**: exists only between claim pre-registration and that claim's **verdict broadcast**. A mid-experiment `[IN PROGRESS]` observation share is not a kill event (avoids the pathological per-message teardown-rebuild). Hard kill-points (list == baseline required): verdict broadcast / Quality Gate / producer `[COMPLETE]` / pre-save sweep / abort / Step 6 entry. **No persistence across re-convergence** — a re-convergence experiment is regenerated from the recipe (which already exists as a broadcast precondition; regeneration is deterministic because the main tree is frozen for the whole session). One experiment = one worktree, never shared across agents.
- **Final-run rule** (the mechanization of recipe-completeness): iteration within the lifetime is free, but a verdict broadcast is backed only when the **recorded recipe's patch, applied on a clean in-worktree reset, is observed in a final confirming run that matches the recorded `관측 결과`**. A clean run that observes something different is a FAILED confirmation (correct the recipe / `관측 결과` and re-broadcast, or re-grade `반증됨(실패)`). The reset is one inseparable fenced line: `cd "$WT" && git checkout -- . && git clean -fd` (omitting `git clean -fd` lets a prior run's untracked residue contaminate the final confirmation; run from the wrong cwd this reset destroys the user's untracked files in the main tree, so no form other than this single cd-embedded line is allowed — it is the most destructive command this mechanism emits).
- **cwd-pinning principle**: every command that reads or mutates tree state names its own tree explicitly — gate commands `cd` to the main tree's absolute path (subshell form; honoring the no-`git -C` rule), the destructive reset embeds `cd "$WT"`. Running a gate check after `cd "$WT"` is a false pass that inspects the worktree's status.
- **Cleanup**: the producer runs `git worktree remove --force "$WT"` + `git worktree prune` + a list-vs-baseline check before the verdict ships. Lead backstop: the pre-save sweep and the Step-6-entry state-check add the two-command gate. `prune`'s incidental cleanup of a user's stale worktree is accepted residual (the prefix naming mitigates; remove-own-paths takes priority).

### 6.3 Exempt acts — in-tree writes the gate cannot be routed around

The gate of §6 compares the **capture format** against a baseline, so **every** in-tree write a mechanism performs inside a gate window fails it. Some of those writes cannot be placed outside a window at all: `design` creates its ledger stub at spawn time and updates it on **every** state change, while the gate fires at **every** team-discussion boundary — there is no window-free placement, so avoidance is unavailable and the exemption is *forced* rather than merely convenient. This subsection enumerates what is exempt.

**The enumeration is by act, not by path.** A path list exempts whatever happens to land at the named path and goes stale the instant a slug rule changes; an act is owned by the mechanism that performs it and cannot be inherited by a file that merely shares a directory. Nothing here weakens §6's FORBIDDEN: every exempt act writes a **mechanism-owned artifact**, never a tracked source file.

1. **Writing the ledger of the document this invocation is itself authoring** — the at-spawn stub and every subsequent state-change update. **"Itself authoring" is bound by derivation**: the document whose path this invocation *derives* from its own inputs by its own path rule, never a document that merely carries a ledger block. Without that binding this clause absorbs clause 3 — whose target is a document *supplied to* the invocation rather than derived by it — and the enumeration silently degrades back into the path form the paragraph above rejects.

2. **Writing a sidecar under `<base>/docs/<kind>/` through the Tier-1 atomic write of `_common/sidecar.md` §1.3 — together with the same-directory `$T` that write creates.** §1.3 places `$T` in the target's own directory by requirement, so where the owning repo tracks `docs/` an orphan `$T` from an interrupted attempt is an untracked entry under `<base>/docs/` exactly as the sidecar itself is, and the **capture format** is this gate's first command. Exempting the sidecar without its `$T` would leave the gate failing on the debris of the write it just permitted. `$SNAP` is out of tree by §1.3 and needs no exemption.

    **The act named here is Tier-1, and naming Tier-2 was the defect.** This clause used to key on §1.3's compare-and-swap. That is a **Tier-2** obligation, owed only where the writer and the reader are different skills or concurrent writers are possible. **The keying is wrong regardless of which tier any given writer owes, and the reason is narrower than the one first written here: Tier-1 is the act that produces the delta.** Creating the in-tree `$T` and renaming it onto the target is what a `git status` sees; the swap decides only *whether* to commit, never what becomes visible. A gate that exempts the swap therefore exempts nothing the gate can see. Keying on it left every such write unexempted while the enumeration read as though it were covered, and this subsection's own opening rule — *the enumeration is by act, not by path* — is what makes that fatal rather than pedantic.

    **The premise this paragraph used to rest on is retracted, not narrowed.** It read that §1.3 states plainly that the one landed consumer performing an in-tree sidecar write is its own writer and reader. §1.3 states no such thing — it states the split and its condition, and says nothing about how many consumers exist — and the claim is false on this tree: `implement` performs a second landed in-tree sidecar write whose reader is a different skill, so that writer owes Tier-2. **No universal replaces it in either direction.** The boundary is enumerated instead, and the enumeration above is the whole of it: whichever tier a writer owes, the exemption keys on Tier-1 because that is the act with a visible delta. How many landed writers there are is not a load this clause carries. The retracted sentence is quoted here rather than deleted so that a reader who meets the old wording elsewhere can tell which half died.

3. **Carrying an entry into the `## 미해결 이슈 / 트레이드오프` section of a design document supplied to this invocation.** The target here is *arbitrary* — it is whatever document the caller handed in, not one this invocation derived — which is why clause 1 must be derivation-bound and why this clause cannot be folded into it. The exemption covers the carry itself and nothing else in that document: a write to any other section is outside this clause and the gate sees it.

4. **`design-audit`'s own report writes** — the early report stub, the `## 결정론적 검사` write that opens the freeze window, and the in-tree copies of the reader reports. All three target the audit report the skill derives for the document under audit; none touches the audited document.

**(v) The exempting mechanism brackets its own act and corrects the baseline.** An exempt act is **not** invisible to this gate. The **capture format** emits (state, path) pairs and carries no information about which act produced them, so **the gate cannot classify a delta as exempt even in principle** — and measurement bears this out: in a repo that tracks `docs/`, writing a ledger stub moves the baseline from `[]` to `[?? docs/topic.md]`, while an ordinary edit to a tracked source file produces the same shape of entry. An act-scoped exemption and a gate that cannot see acts are not reconcilable by asserting invisibility.

**They are reconcilable by moving the work to the party that does know.** The mechanism performing an exempt act **brackets it**: capture the **capture format** immediately **before** the write, perform the act, capture immediately **after**, and **advance the baseline by exactly the observed delta** — asserting that every path in that delta is one this act itself just wrote. The gate stays a plain string comparison and never classifies anything; the enumeration above stays act-scoped because the party doing the correcting is the mechanism that owns the act and can name only the paths it just created.

**Three states, and the third is why the format is fixed rather than left to the caller.** Read the delta as follows, and read the predicate as *"the act yields an entry **under the capture format**"* — not the bare *"the act yields an entry"*, which is **true under both spellings** and therefore restores exactly the ambiguity this branch removes.

1. **The delta names the paths the act wrote** — advance the baseline by it. This is the normal case.
2. **The delta is larger** — a foreign write landed inside the bracket. Gate failure, below.
3. **The act wrote into a directory the baseline already folds, or created one.** Under bare `git status --porcelain` this yields either *nothing* (the directory was already listed, so the second file inside it changes no line) or `?? <dir>/` — a path the act did not write. Neither can satisfy the assertion in (1): the first has no delta to advance by while a write demonstrably happened, and the second names a directory. **Under the capture format both collapse into case 1 — for a target the repository's index can see.** That qualifier is the whole of the claim, and an earlier form of this sentence omitted it and generalized past its own enumeration. Two cases fall outside, and the boundary is stated here rather than left for a reader to rediscover:

  - **The target is gitignored.** No untracked-files setting makes an ignored path appear, so the act produces no entry at all and there is no delta to advance by. **This repository is that case**: its `.gitignore` lists `docs/`, so an exempt act writing under `docs/` here is invisible to the bracket. **Re-derive this rather than trust a count**: `grep -n '^docs/' .gitignore` at the repository root settles it in one command. An earlier form of this sentence closed with *measured three times independently*; the substance holds, but that provenance is not recoverable from any artifact, so a rule anyone can re-run replaces it.
  - **The target is inside a nested repository.** The outer `git status` reports the nested repository as one entry, or nothing, regardless of how many files the act wrote inside it.

  In both, the bracket cannot assert that the delta names the paths the act wrote, because there is no delta. The disposition is to say so rather than to treat silence as case 1: a mechanism whose exempt writes land in either place records that its bracket is inoperative there, and does not report the assertion as satisfied. This state is not an edge — creating `<base>/docs/<kind>/` on a first run is every mechanism's first run — but the collapse it relies on holds only where the entry can appear.

**A delta larger than the act's own writes is not a correction — it is a gate failure.** That single assertion is the whole of the safety argument: a foreign write landing between the two captures is precisely what it refuses to absorb.

**Scope: inside a gate window only.** An unbounded obligation would tax exempt acts at call sites that have no gate at all. A mechanism whose exempt writes all fall outside every gate window owes nothing here and brackets nothing.

**This does not restore order-independence, and callers must not read it that way.** With only exempt acts in play the two capture orders do agree — but a foreign tracked-file edit landing between them separates them, since the earlier capture sees it and the later one has already folded it into a new baseline. A caller therefore does not get to place its capture freely: it names that point **once**, in its own control-flow invariants, and does not name it twice.

**Two alternatives are rejected, and the reasons are structural.** *Subtracting exempt items from the baseline* requires the gate to know which paths are exempt — that is the path list this subsection opens by rejecting. *Unconditionally re-capturing after every write* absorbs any other party's forbidden write that landed in between, converting the gate into a rubber stamp for whatever happened during the window.

**On the second copy of this subsection.** A copy exists in a design document, and it is **not** byte-identical — it has diverged, and the divergence is the point rather than an aside: the copy still spells the retired bare `git status --porcelain` and its `(v)` states a contract this file reversed. An earlier form of this paragraph asserted byte-identity, and a form before that asserted the copy did not exist at all; both were wrong, and the second was wrong in the more dangerous direction, since a copy that is absent needs no reconciling while a copy that has drifted into a withdrawn contract does. **The conclusion survives the correction, and it survives for the reason that was always doing the work**: `docs/` is gitignored here and `git ls-files docs/` returns nothing, so this subsection ships in exactly one **tracked** file and a coupling lint over the two is not merely empty but **unconstructible** — CI cannot read a file that is not in the repository. Divergence therefore changes what a reader must do (read this file, never that copy) without changing what CI can do. §10's prohibition on adding a coupling lint holds here for the same underlying reason it holds there.

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
4. **Two-command boundary gate == baseline** (§6) — main **capture format** == the pre-workflow baseline, and `git worktree list --porcelain` shows 0 `cc-design-exp-` entries.

Any condition failing makes the sweep **FAIL**, and the owning SKILL.md's failure path takes over from there — `design` allows at most one re-convergence cycle per failing claim before escalating; `design-lite` routes to its Round 3 and then to a 3-option escalation. Those paths are economically divergent by design and are **not** unified here.

**Why this is the one carve-out from the file's contracts-only posture.** A pass predicate is a predicate, not a procedure: it is exactly the kind of thing this file exists to hold. It had drifted into two inline copies, which is the same structure this repo treats as a maintenance tax everywhere else — so collapsing it by reference removes the copy rather than adding a lint to keep two copies honest. **Do not add a coupling lint for this section**: with no second copy there is nothing to synchronize, and registering a new parity pair would reinstate the tax the collapse just removed.

---

## 11. Citation convention (reports and witnesses included)

A tree that carries several documents on one subject — a design document, a pass plan, a review report — has **one label namespace per document and no coordination between them**. A bare `D4` or `R7` or `V9` is therefore not a reference; it is a reference *within a document the reader has to guess*. Measured across two documents in this tree: **38 decision labels in common**, and of the twelve bare `D<n>` citations, **eight resolve to a real but unrelated decision in the wrong document**.

**That failure mode is worse than a dangling reference, and the difference is what this section is for.** A dangling anchor is caught the first time someone follows it. A bare number that lands on a real-but-wrong item is **indistinguishable from a correct citation**: grep finds it, the reader opens it, the text is a genuine decision, and the reader then fixes the wrong thing and reports success. Nothing in the process notices.

**A citation has three parts, all required.**

1. **A document qualifier.** The path of the document being cited, never omitted and never abbreviated to a single letter. A one-letter shorthand is itself a per-document namespace, so it recreates the collision one level up.
2. **The verbatim heading.** The label alone does not carry the citation — the heading does. A wrong number under the right heading is caught on sight; a wrong number alone is not.
3. **A line anchor with its observation date**, written `(:<n>, <YYYY-MM-DD> observed)`. **A line number is a coordinate, not an identifier.** Documents shift non-uniformly, so a stale line number is expected and is not a defect; what makes it usable is the date that says when it was true.

**Two obligations that apply to the citing party rather than the cited text.**

- **Resolve before propagating.** A citation received from a review, a witness, or another agent is not repeated until its existence **and uniqueness** have been checked in the target document. Passing one along unchecked is how a wrong anchor reaches an agent prompt, and an agent cannot check what it was told is already checked.
- **When the verbatim text is not unique, say so.** If the same wording appears at several lines, the citation cannot be re-anchored by wording later — record that fact in the citation itself rather than leaving the next reader to discover it.

**Scope: this section covers report and witness citations too, and that is the half that is easy to skip.** A witness is read by exactly one party and then discarded, which makes its citations feel private — but a finding lifted out of a witness carries its citation with it into a report that outlives the witness by months. Of the citation failures measured in one round of this repo's own use, **six of nine were on report surfaces**, which is why the two report-publishing skills read this section.
