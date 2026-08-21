# Team-Upgrade Analysis (Shared Parameterized Core)

Axis-agnostic engine for a **two-axis** (model + role) second-opinion on a team composition proposed by an upstream skill step. A consuming skill (`design-upgrade`, `review-upgrade`) reads this file and specializes it through three injection channels (see **Injection Interface** below). Restraint is the default: `역할 변경 불필요` / `모델 변경 불필요` (no change needed) is a valid and expected outcome on either axis.

This file is **parameterized** — it contains literal `{PLACEHOLDER}` tokens that the consuming skill resolves via its own `## Bindings` section. Unlike the self-contained `_common` files (e.g. `agent-team-protocol.md`) that are read wholesale, a reader of this core must resolve the placeholders against the consuming skill's `## Bindings` to obtain the concrete contract.

## Injection Interface

A consuming skill specializes this core through exactly three channels:

1. **`## Bindings`** (value substitution) — the consuming skill resolves every `{PLACEHOLDER}` token below to a concrete *value* (labels, field order, anchor objects, source-step, model-axis availability flag, re-feed target, etc.). Pure value resolution, no rule changes.
2. **`## Operations Layer`** (rule append seam) — the consuming skill MAY (a) declare additional OPERATION classes that carry their own gate, and (b) append to this core's forbidden-set. This is prose-rule append, not token substitution. **Open for extension**: a consuming skill may define an additional OPERATION class provided it **declares its own gate**, respects the per-existing-role invariant below, and does not weaken this core's forbidden-set; and it may append entries to that forbidden-set. Restraint is carried by the gate, not by the direction of the change — a class that shrinks a roster is admissible on exactly the same terms as one that grows it.
3. **Injected prose sections** — `frontmatter`, the Fallback section, the lite-guard paragraph, and the schema-drift sync-note are authored entirely per-skill in the consuming SKILL.md and are NOT part of this core.

## Placeholders (resolved by the consuming skill's `## Bindings`)

- `{SCOPE_LABEL}` — the Korean label for a role's coverage/exploration scope field.
- `{FIELD_ORDER}` — the emit order of the role triple's Korean fields.
- `{SOURCE_STEP}` — the upstream step that produced the team composition under analysis.
- `{ROSTER_SOT}` — where the roster source-of-truth lives (and its language/format).
- `{LABEL_RELATION}` — how the OPERATION Korean labels relate to the source roster (conceptual translation vs verbatim-equal).
- `{ROLE_GAP_ANCHOR}` — a skill-specific anchor describing what counts as an uncovered gap (may be empty).
- `{RE_EXPLORATION_ANCHOR}` — the in-context objects the lightweight re-exploration anchors on.
- `{LITE_GUARD_TARGET}` — the sibling lite skill whose fixed roster the lite-guard protects.
- `{PRECONDITION}` — the precondition that the source-step composition is in context.
- `{MODEL_AXIS_DEGRADES_UNDER}` — the active input path under which the model axis becomes unavailable (or `never`).
- `{SAVED_DOC_LOCATION}` — the saved-document path used by the reverse-engineer fallback path.
- `{REFEED_TARGET}` — where an emitted OPERATION set is re-fed (may be path-conditional).

---

Analyze the team composition proposed in the preceding `{SOURCE_STEP}` output and produce a second opinion along **two axes** — model and role — recommending only changes that pass an explicit gate. Restraint is the default on both axes.

## Scope

Two analysis axes. Every OPERATION earns its place by clearing its own gate; **which direction it moves the roster in is not what makes it admissible**, because a ratchet that can only grow a team cannot enforce a ceiling and cannot undo an over-staffing that a later reading makes obvious.

- **Model axis**: among teammates assigned `haiku`/`sonnet`, identify those where opus's strengths — complex reasoning, cross-domain analysis, deep code analysis — would make a meaningful difference, and propose promotion to opus.
- **Role axis**: (a) **ADD** a new role for an in-scope domain that no current teammate owns, (b) **SPLIT-REPLACE** one overloaded broad role into two, (c) **REMOVE** a role whose domain no longer needs a dedicated seat, or (d) **MERGE** two roles whose domains are not separable enough to justify two seats.

**Out of scope — never propose**: model downgrade; any OPERATION that leaves a domain in scope with no owner; and any `REMOVE` / `MERGE` argued from cost, token budget, or headcount alone. (A consuming skill's `## Operations Layer` may append further forbidden entries.)

**The cost-reason ban is the load-bearing half of the reversal.** `REMOVE` and `MERGE` exist so a roster can come back down when a seat is genuinely not doing work, not so a caller can buy a cheaper run. A proposal whose stated rationale is the budget, the token spend, or the headcount itself is rejected on that ground alone, however plausible its arithmetic — this is what keeps a savings pass from eating review quality.

**`REMOVE` / `MERGE` are pre-spawn only.** Both operate on a *proposed* composition, before any member is spawned. After spawn there is no ledger state that means "this member's findings live on inside another row": `state ∈ {running, done, aborted}` and reusing `aborted` would emit a false absence annotation for work that really happened. A post-spawn reduction is therefore not available here.

**Restraint principle (most important)**: just as model promotion is proposed only when it makes a meaningful difference, a role OPERATION — in either direction — is proposed only when its gate is met, not by default. "변경 불필요" is the normal output on both axes; mirror the model-axis retain-rationale symmetry onto the role axis.

## Evaluation criteria

### Role-gap detection (single pass)

Four-step coverage diff: enumerate domains → build a coverage map → flag uncovered domains → apply the restraint gate (most candidates drop here). This is a **single pass** — no iterate-until loop and no termination contract. {ROLE_GAP_ANCHOR}

Lightweight re-exploration (read-only; no team, no writes, no test/build, no MCP): grep/ls limited to surfaces the proposal already named — anchored on {RE_EXPLORATION_ANCHOR} — and their adjacent sibling directories, plus single-file Read ≤200 lines.

**HARD LIMIT**:

1. ≤12 total read-only operations/calls; on exhaustion, stop (uncharacterized domains default to no change).
2. A single grep with >50 hits is inconclusive for ADD — treat it as an already-central domain, not gap evidence (bias to no change). This bias applies **only to new-domain discovery (ADD)**; the same large hit can serve as overload input for a SPLIT candidate under the split gate, so do NOT silence SPLIT reasoning at the grep step.
3. make/test/build, team spawn, MCP, and writes are fully prohibited.
4. Re-exploration is confirmatory — confirm only gaps the proposal already implied; do not fish for new out-of-scope domains. Inconclusive → bias to "no change".

### Restraint gate (new role — ALL required)

1. A specific uncovered domain that no role owns (cite path / requirement).
2. ≥1 consequential, non-mechanical decision living in that domain.
3. Distinct expertise an existing role would not naturally produce within its scope.
4. **Budget pairing** — if the `ADD` would push the roster past the ceiling in `agent-team-protocol.md`'s `### Team size budget`, it must ship paired with a `REMOVE` or a `MERGE` in the same emit. Without this the ceiling and the new operations stay unrelated edits: the roster becomes reversible in principle and never actually reverses. The condition is scoped to **domain-perspective** roles, matching the budget's own count — a role the budget does not count cannot exceed it and so has nothing to pair with.

If any fails → no new role. A confirmed gap is handled as a **new role**, not by widening an existing role's scope: widening is an ungated `ADD` wearing a scope edit's clothes. (`MERGE` also collapses scopes, but it is a separate OPERATION with its own gate below and is never a route to covering a gap.)

### Split gate (ALL required)

1. The scope spans two separable domain clusters, each with independent decisions (aligned with the 1→2 partition contract below — if 3+ distinct domains, split only the single strongest cleavage this round and defer the residual overload to the next re-proposal round).
2. Depth contention — one teammate would starve one side.
3. Clean cleavage — no shared core forcing constant cross-talk.
4. Cross-axis reconciliation — explicitly compare SPLIT (two sonnets, parallel focus, +coordination cost, +1 headcount) vs UPGRADE (one opus spanning both, single synthesis preserved), then pick one.

### Remove gate (ALL required)

1. The role's domain is **in scope but demonstrably thin** for this particular unit of work — cite what the domain amounts to here (files touched, requirement text), not a general impression.
2. **Coverage is preserved**: after the removal, every in-scope domain still has an owner. A `REMOVE` that orphans a domain is the forbidden case, not a restrained one.
3. The rationale stands **without** appealing to cost, token budget, or headcount (the ban above).

If any fails → no removal. Silence is the default: an unnecessary seat costs a run's tokens and is recovered next session, while a missing seat costs a missed defect and is not recovered — so the gate is deliberately harder to pass in this direction than the reading of a roster usually suggests.

### Merge gate (ALL required)

1. Two roles whose `{SCOPE_LABEL}`s are **not separably deep** for this unit of work — the inverse of the split gate's cleavage condition, argued on the same evidence.
2. `PARTITION` holds in reverse: the merged role's scope is exactly the union of the two, with nothing dropped.
3. One teammate can carry the union without starving either side (the inverse of split's depth contention).
4. The rationale stands **without** appealing to cost, token budget, or headcount.

If any fails → no merge. A `MERGE` and a `SPLIT-REPLACE` must never target the same roles in one emit; if both read as valid, the evidence is ambiguous and the answer is "변경 불필요".

### Degraded-axis handling

If the model axis is unavailable on the active input path — see `{MODEL_AXIS_DEGRADES_UNDER}` — the split gate's cross-axis reconciliation (step 4) and the Cross-axis synthesis below treat the UPGRADE comparison term as N/A and proceed on the role axis alone (skip the SPLIT-vs-UPGRADE weighing). When `{MODEL_AXIS_DEGRADES_UNDER}` is `never`, this is dead code.

Symmetrically, a consuming skill's injected prose MAY declare that the **SPLIT comparison term** is N/A on some active path (e.g. when quantitative overload signal is absent). In that case the split gate's step 4 and the Cross-axis synthesis treat the SPLIT term as N/A and fall through to the UPGRADE-parent alone. Either axis's degradation is routed into the same two gate/synthesis sites so neither is left undefined when one comparison term drops out.

## Output format

Every recommendation carries an explicit OPERATION tag so the user or the next-turn model can re-feed it into {REFEED_TARGET} without ambiguity (there is no ingestion path that auto-applies these tags). Field labels are Korean — `역할` / `{SCOPE_LABEL}` / `모델` — and their relation to the source roster ({ROSTER_SOT}) is {LABEL_RELATION}; only the model-value aliases `"opus"` / `"sonnet"` / `"haiku"` are tokens shared verbatim across both sides. OPERATIONs that emit a full role triple do so in the order `{FIELD_ORDER}`.

### `UPGRADE` (existing teammate, model axis)

- `역할` — must match an existing roster role name (lookup key). Comparison is exact string match after trimming leading/trailing whitespace; any other drift (case, parenthetical-note differences, etc.) is malformed → re-confirm with the user. Never silently create a new entry.
- `현재 모델 → 권장 모델`
- 변경 사유
- 기대 효과

Omit `{SCOPE_LABEL}` — only the model cell changes, so restating the unchanged scope is noise and a stale-copy risk. (Scope is omitted, so the field-order rule does not apply to UPGRADE.)

### `ADD` (new role)

- Full role triple in the order `{FIELD_ORDER}`
- 근거 (the uncovered domain)
- 기대 효과

The new `역할` name must not collide with any existing roster role name — a collision means this is not a new role at all but a scope edit on an existing one, which the restraint gate rejects. If the intent really was to reshape existing scopes, say so with `MERGE` or `SPLIT-REPLACE` and clear that operation's gate. Symmetric with UPGRADE's lookup-key integrity.

### `SPLIT-REPLACE` (overloaded parent role → two children, parent removed)

- Each of the two children: a full role triple in the order `{FIELD_ORDER}`
- `PARTITION: childA.{SCOPE_LABEL} ⊎ childB.{SCOPE_LABEL} = parent.{SCOPE_LABEL} (no overlap, no loss)`
- 근거 (overload evidence)
- 기대 효과

A SPLIT-REPLACE making the parent role name disappear is NOT a `REMOVE` — the parent's whole scope stays covered by the two children. The two operations now coexist and the re-proposal reads them differently (`REMOVE` gives up a seat and its rationale must show coverage survives elsewhere; `SPLIT-REPLACE` preserves coverage by construction), so tag it `SPLIT-REPLACE`.

### `REMOVE` (drop a role whose domain no longer needs its own seat)

- `역할` — must match an existing roster role name (lookup key), compared exactly after trimming leading/trailing whitespace; any other drift is malformed → re-confirm with the user.
- `커버리지 승계` — which remaining role(s) own that domain after the removal. This field is mandatory and is where remove-gate condition 2 is discharged; an emit without it is malformed.
- 근거 (why the domain is thin for this unit of work — never cost, tokens, or headcount)
- 기대 효과

Omit `{SCOPE_LABEL}` — the role is leaving, so restating its scope is noise. (Scope is omitted, so the field-order rule does not apply to REMOVE.)

### `MERGE` (two roles → one, both parents replaced)

- The merged role: a full role triple in the order `{FIELD_ORDER}`
- `PARTITION: parentA.{SCOPE_LABEL} ⊎ parentB.{SCOPE_LABEL} = merged.{SCOPE_LABEL} (no overlap, no loss)` — the split gate's partition contract read in reverse
- 근거 (why the two domains are not separably deep here — never cost, tokens, or headcount)
- 기대 효과

The merged `역할` name may reuse one parent's name or introduce a new one; if it introduces a new one it must not collide with a third existing role.

### Invariant — at most one OPERATION per existing role

A single existing role must not carry more than one of `UPGRADE` / `SPLIT-REPLACE` / `REMOVE` / `MERGE`. If two seem valid, pick the stronger one and state the tradeoff — and note that some pairs are not a judgment call but a contradiction (`REMOVE` with `UPGRADE` on the same role; `MERGE` with `SPLIT-REPLACE` on the same role), which means the evidence is ambiguous and the answer is "변경 불필요". `ADD` does not touch existing roles, so it combines freely — including with the `REMOVE` / `MERGE` it may be required to pair with under restraint-gate condition 4. (A consuming skill's `## Operations Layer` OPERATION class that mints a brand-new role is likewise exempt from this per-existing-role invariant.)

### Shared Korean emit vocabulary

`현재 모델 → 권장 모델` · `변경 사유` / `유지 사유` · `기대 효과` · `역할 변경 불필요` / `모델 변경 불필요` · `근거` · `커버리지 승계` (REMOVE only). Model-value aliases `opus` / `sonnet` / `haiku` are shared verbatim. The skill body text and headings are English; only these emit fields and user-facing notices are Korean.

## Cross-axis synthesis

Weigh both axes together. When the same weakness is targeted by both a model promotion and a role change, choose only the stronger side and state the tradeoff explicitly (e.g., "promote teammate X to opus" vs "add a new opus role dedicated to domain Y"). Honor the Degraded-axis handling above when either comparison term is N/A on the active path.

## Schema-drift sync-note template (one-directional, per consuming skill)

Each consuming skill injects its own sync-note of the form: the source of truth is `{ROSTER_SOT}`'s team-composition field set; if that field set changes, manually sync this skill's OPERATION Korean labels and model aliases (the Korean labels are this skill's emit surface, related to the source fields as {LABEL_RELATION}). Do NOT touch the source skill. The residual risk of a missed sync is accepted without a lint. Each sync-note is single-direction (one per (consumer, source-step) pair) with no cross-coupling.
