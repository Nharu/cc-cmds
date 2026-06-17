# In-Session Verification Contract (Shared SOT)

Single source of truth for the in-session verification mechanism: the claim taxonomy, the frozen verdict/residual vocabulary, the verification ledger and residual-item schemas, recipe self-containment rules, the isolated-worktree mechanics, the well-formedness predicate, the drift ladder, and the transformation move. Both **emitters** (`design`, `design-lite`) and the **consumer** (`implement`) and the **checkers** (`design-review`, `design-review-lite`) cite this file.

**Posture.** Verification failure means the design must change. So a claim that can be settled *today* — against the current repo or environment, by reading, running unmodified tooling, or a throwaway experiment, with no production implementation present — is settled inside the design session and recorded in the verification ledger. Only claims that genuinely cannot be settled until implementation artifacts exist are encoded as residual items for the consumer to settle, fail-fast, at the start of implementation.

**What this file owns vs. what each SKILL.md owns.** This file is *contracts-only*: vocabulary, schemas, predicates, and execution mechanics. It deliberately excludes *workflow prose* — the Quality-Gate / pre-save-sweep procedures, the consumer's gate flow and failure menus, and the lite budget / split / menu — each of which lives in the owning SKILL.md. Every excerpt or inline copy of this contract elsewhere MUST carry a provenance line naming this file; the frozen-literal lists are defined ONLY here and copies cite, never re-author, them.

**Consumption matrix.** `design` Reads this file in full. `design-lite` Reads it in full (its fourth `_common` Read). `design-review` excerpts the detection grammar into `references/06-review-agent-prompt.md`. `design-review-lite` inlines the detection grammar (0-Read architecture). `implement` Reads it and uses the `## Residual-item contract` section.

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

An implement flip reuses the ledger terminals (`검증됨(통과)` / `반증됨(실패)`) verbatim. Provenance is guaranteed structurally — not by a token variant — by **section + mandatory note line**: implement's only write surface is the R-section, so an R-item's terminal token can only have been written by implement. **If an R-item carries a terminal token but the adjacent `**구현 시 검증 기록**:` line is absent, it is MALFORMED** (well-formedness predicate, enforced by design-review). This adjacency check carries no detection logic of its own — it rides the §3.4 grammar, so the note-line key `구현 시 검증 기록` is a member of that grammar's instantiated key set (a legacy bullet/no-bold note line therefore still satisfies adjacency and is not false-flagged).

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

An unnumbered heading, placed after `## 미해결 이슈 / 트레이드오프` and before `## 권장 구현 순서` (the two new sections straddle the unresolved-issues section without touching its parse region). `implement` Reads this contract section wholesale, so it is self-contained here.

- `### R<n>. <claim title>` sub-blocks only. Fields are the required + optional set of token #4. Optional-field definitions:
    - `검증 시점` = `구현 전` (default) | `구현 중(<phase>)`.
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
3. **design-review `잔여 항목으로 기록` disposition** → `잔여 사유: 검증 차단` with the standard blocked-reason prose `리뷰 시점 사용자 이연 — <YYYY-MM-DD>`.

The ledger holds only performed-and-completed entries; a blocked attempt lives in an R-item's `차단 사유`.

### 5.2 Well-formedness predicate

An R-item is MALFORMED if any of: a required field is missing / it contains a `/tmp` literal / `실패 시 영향` is an unresolved anchor / it uses a token or enum value outside this vocabulary / it carries a terminal token (`검증됨(통과)`/`반증됨(실패)`/`검증불가(드리프트)`) without an adjacent `**구현 시 검증 기록**:` line (per §3.3).

**Line rendering (the bullet/bold axes) is NOT a malformedness axis.** A non-canonical field-line rendering is a §3.4-tolerant-readable form, not a malformed item — the detection grammar reads all four renderings and the consumer's tolerant W1 lookup flips a legacy rendering, so a bullet/no-bold line is cosmetic drift, not a flip-breaker. It is surfaced only as a design-review criterion #7(e) **trivial** style warning, scoped to the current review round's edited lines, never via this predicate.

---

## 6. Observation & verification carve-out (running + experimenting ≠ modifying)

A single, generalized definition (it subsumes and replaces the earlier reproduction-only carve-out; two parallel carve-outs would leave the FORBIDDEN-sentence contradiction unowned). A carve-out is a *definition*, not an exception — the "NO code modifications" literals stay literally true.

- **Definition rescope**: a *modification* is a change that persists in the **session's main working tree** (in git vocabulary an experiment worktree is also a "working tree", so a merge without rescoping would self-contradict).
- **FORBIDDEN rescope**: editing a tracked source file **in the main working tree** — forbidden even transiently, even if it will be reverted.
- **Two-command boundary gate** (the "single verifiable invariant" advertisement is retired — scope is per-surface). At every team-discussion boundary check both, in this order:
    1. main tree `git status --porcelain` == the pre-workflow baseline;
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

---

## 7. Drift ladder (3-rung + flake pre-classification)

Consumed by `implement` (verbatim) and by `design-review` run-now (verbatim — no review-local adaptation).

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
