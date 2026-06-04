# Team-Upgrade Analysis (Shared Parameterized Core)

Axis-agnostic engine for a **two-axis** (model + role) second-opinion on a team composition proposed by an upstream skill step. A consuming skill (`design-upgrade`, `review-upgrade`) reads this file and specializes it through three injection channels (see **Injection Interface** below). Restraint is the default: `역할 변경 불필요` / `모델 변경 불필요` (no change needed) is a valid and expected outcome on either axis.

This file is **parameterized** — it contains literal `{PLACEHOLDER}` tokens that the consuming skill resolves via its own `## Bindings` section. Unlike the self-contained `_common` files (e.g. `agent-team-protocol.md`) that are read wholesale, a reader of this core must resolve the placeholders against the consuming skill's `## Bindings` to obtain the concrete contract.

## Injection Interface

A consuming skill specializes this core through exactly three channels:

1. **`## Bindings`** (value substitution) — the consuming skill resolves every `{PLACEHOLDER}` token below to a concrete *value* (labels, field order, anchor objects, source-step, model-axis availability flag, re-feed target, etc.). Pure value resolution, no rule changes.
2. **`## Operations Layer`** (rule append seam) — the consuming skill MAY (a) declare additional OPERATION classes that carry their own gate, and (b) append to this core's forbidden-set. This is prose-rule append, not token substitution. **Open for extension**: a consuming skill may define an additional OPERATION class provided it is reinforcement-direction, declares its own gate, and respects the per-existing-role invariant below; and it may append entries to this core's forbidden-set.
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

Analyze the team composition proposed in the preceding `{SOURCE_STEP}` output and produce a second opinion along **two axes** — model and role — recommending only *reinforcing* changes. Restraint is the default on both axes.

## Scope

Two analysis axes, reinforcement-direction only:

- **Model axis**: among teammates assigned `haiku`/`sonnet`, identify those where opus's strengths — complex reasoning, cross-domain analysis, deep code analysis — would make a meaningful difference, and propose promotion to opus.
- **Role axis**: (a) **ADD** a new role for an in-scope domain that no current teammate owns, or (b) **SPLIT-REPLACE** one overloaded broad role into two.

**Out of scope — never propose**: role removal, role merge, model downgrade. (A consuming skill's `## Operations Layer` may append further forbidden entries.)

**Restraint principle (most important)**: just as model promotion is proposed only when it makes a meaningful difference, role ADD/SPLIT is proposed only when needed — not always. "변경 불필요" is the default and a normal output on both axes; mirror the model-axis retain-rationale symmetry onto the role axis.

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

If any fails → no new role. Expanding an existing role's scope (absorption) is out of scope, so a confirmed gap is handled as a **new role**, not a scope edit.

### Split gate (ALL required)

1. The scope spans two separable domain clusters, each with independent decisions (aligned with the 1→2 partition contract below — if 3+ distinct domains, split only the single strongest cleavage this round and defer the residual overload to the next re-proposal round).
2. Depth contention — one teammate would starve one side.
3. Clean cleavage — no shared core forcing constant cross-talk.
4. Cross-axis reconciliation — explicitly compare SPLIT (two sonnets, parallel focus, +coordination cost, +1 headcount) vs UPGRADE (one opus spanning both, single synthesis preserved), then pick one.

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

The new `역할` name must not collide with any existing roster role name — a collision means this is a scope-expansion attempt on an existing role, which is out of scope (fails the restraint gate). Symmetric with UPGRADE's lookup-key integrity.

### `SPLIT-REPLACE` (overloaded parent role → two children, parent removed)

- Each of the two children: a full role triple in the order `{FIELD_ORDER}`
- `PARTITION: childA.{SCOPE_LABEL} ⊎ childB.{SCOPE_LABEL} = parent.{SCOPE_LABEL} (no overlap, no loss)`
- 근거 (overload evidence)
- 기대 효과

A SPLIT-REPLACE making the parent role name disappear is NOT the forbidden "removal" — it is a reinforcing 1→2 split. Tag it `SPLIT-REPLACE`, not `REMOVE`, so the re-proposal does not misread it as a downgrade.

### Invariant — at most one OPERATION per existing role

A single parent role must not carry both `UPGRADE` and `SPLIT-REPLACE`. If both seem valid, pick the stronger one and state the tradeoff. `ADD` does not touch existing roles, so it combines freely. (A consuming skill's `## Operations Layer` OPERATION class that mints a brand-new role is likewise exempt from this per-existing-role invariant.)

### Shared Korean emit vocabulary

`현재 모델 → 권장 모델` · `변경 사유` / `유지 사유` · `기대 효과` · `역할 변경 불필요` / `모델 변경 불필요` · `근거`. Model-value aliases `opus` / `sonnet` / `haiku` are shared verbatim. The skill body text and headings are English; only these emit fields and user-facing notices are Korean.

## Cross-axis synthesis

Weigh both axes together. When the same weakness is targeted by both a model promotion and a role change, choose only the stronger side and state the tradeoff explicitly (e.g., "promote teammate X to opus" vs "add a new opus role dedicated to domain Y"). Honor the Degraded-axis handling above when either comparison term is N/A on the active path.

## Schema-drift sync-note template (one-directional, per consuming skill)

Each consuming skill injects its own sync-note of the form: the source of truth is `{ROSTER_SOT}`'s team-composition field set; if that field set changes, manually sync this skill's OPERATION Korean labels and model aliases (the Korean labels are this skill's emit surface, related to the source fields as {LABEL_RELATION}). Do NOT touch the source skill. The residual risk of a missed sync is accepted without a lint. Each sync-note is single-direction (one per (consumer, source-step) pair) with no cross-coupling.
