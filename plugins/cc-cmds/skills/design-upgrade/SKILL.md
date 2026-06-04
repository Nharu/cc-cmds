---
name: design-upgrade
description: 팀 구성 강화 분석 (모델·역할 축)
when_to_use: 직전 `/design` 팀 구성 제안에서 opus 승격이 유의미한 역할이 있는지, 또는 누락 도메인을 메울 신규 역할·과부하 역할 분할이 필요한지 second-opinion으로 검토할 때
disable-model-invocation: true
usage: "/cc-cmds:design-upgrade"
options: []
notes: |
    이 커맨드는 별도 인자를 받지 않으며, 직전 `/design` 팀 구성 제안이 현재 대화 컨텍스트에 있어야 동작한다. 모델 승격과 역할 추가·분할은 강화가 유의미할 때만 제안하며, 그 외에는 유지 사유를 제시한다. 독립 실행 시 결과가 불정확할 수 있다.
---

Analyze the team composition proposed in the preceding `/design` Step 2 output and produce a second opinion along **two axes** — model and role — recommending only *reinforcing* changes. Restraint is the default: `역할 변경 불필요` / `모델 변경 불필요` (no change needed) is a valid and expected outcome on either axis.

## Scope

Two analysis axes, reinforcement-direction only:

- **Model axis** (existing behavior): among teammates assigned `haiku`/`sonnet`, identify those where opus's strengths — complex reasoning, cross-domain analysis, deep code analysis — would make a meaningful difference, and propose promotion to opus.
- **Role axis** (new): (a) **ADD** a new role for an in-design-scope domain that no current teammate owns, or (b) **SPLIT-REPLACE** one overloaded broad role into two.

**Out of scope — never propose**: role removal, role merge, model downgrade.

**Restraint principle (most important)**: just as model promotion is proposed only when it makes a meaningful difference, role ADD/SPLIT is proposed only when needed — not always. "변경 불필요" is the default and a normal output on both axes; mirror the existing retain-rationale symmetry onto the role axis.

## Evaluation criteria

### Role-gap detection (single pass)

Four-step coverage diff: enumerate domains → build a coverage map → flag uncovered domains → apply the restraint gate (most candidates drop here). This is a **single pass** — no iterate-until loop and no termination contract.

Lightweight re-exploration (read-only; no team, no writes, no test/build, no MCP): grep/ls limited to surfaces the proposal/interview already named and their adjacent sibling directories, plus single-file Read ≤200 lines.

**HARD LIMIT**:

1. ≤12 total read-only operations/calls; on exhaustion, stop (uncharacterized domains default to no change).
2. A single grep with >50 hits is inconclusive for ADD — treat it as an already-central domain, not gap evidence (bias to no change). This bias applies **only to new-domain discovery (ADD)**; the same large hit can serve as overload input for a SPLIT candidate under the split gate, so do NOT silence SPLIT reasoning at the grep step.
3. make/test/build, team spawn, MCP, and writes are fully prohibited.
4. Re-exploration is confirmatory — confirm only gaps the interview/task already implied; do not fish for new out-of-scope domains. Inconclusive → bias to "no change".

### Restraint gate (new role — ALL required)

1. A specific uncovered domain that no role owns (cite path / requirement).
2. ≥1 consequential, non-mechanical design decision living in that domain.
3. Distinct expertise an existing role would not naturally produce within its scope.

If any fails → no new role. Expanding an existing role's scope (absorption) is out of scope, so a confirmed gap is handled as a **new role**, not a scope edit.

### Split gate (ALL required)

1. The scope spans two separable domain clusters, each with independent decisions (aligned with the 1→2 partition contract below — if 3+ distinct domains, split only the single strongest cleavage this round and defer the residual overload to the next re-proposal round).
2. Depth contention — one teammate would starve one side.
3. Clean cleavage — no shared core forcing constant cross-talk.
4. Cross-axis reconciliation — explicitly compare SPLIT (two sonnets, parallel focus, +coordination cost, +1 headcount) vs UPGRADE (one opus spanning both, single synthesis preserved), then pick one.

## Output format

Every recommendation carries an explicit OPERATION tag so the user or the next-turn model can re-feed it into `/design` Step 2 re-proposal without ambiguity (there is no ingestion path that auto-applies these tags). Field labels are Korean — `역할` / `탐색 범위` / `모델` — conceptually aligned with Step 2's English-prose fields (role / exploration scope / model); only the model-value aliases `"opus"` / `"sonnet"` / `"haiku"` are tokens shared verbatim across both sides.

### `UPGRADE` (existing teammate, model axis)

- `역할` — must match an existing roster role name (lookup key). Comparison is exact string match after trimming leading/trailing whitespace; any other drift (case, parenthetical-note differences, etc.) is malformed → re-confirm with the user. Never silently create a new entry.
- `현재 모델 → 권장 모델`
- 변경 사유
- 기대 효과

Omit `탐색 범위` — only the model cell changes, so restating the unchanged scope is noise and a stale-copy risk.

### `ADD` (new role)

- Full `역할 / 탐색 범위 / 모델` for one item
- 근거 (the uncovered domain)
- 기대 효과

The new `역할` name must not collide with any existing roster role name — a collision means this is a scope-expansion attempt on an existing role, which is out of scope (fails the restraint gate). Symmetric with UPGRADE's lookup-key integrity.

### `SPLIT-REPLACE` (overloaded parent role → two children, parent removed)

- Each of the two children: `역할 / 탐색 범위 / 모델`
- `PARTITION: childA.탐색 범위 ⊎ childB.탐색 범위 = parent.탐색 범위 (no overlap, no loss)`
- 근거 (overload evidence)
- 기대 효과

A SPLIT-REPLACE making the parent role name disappear is NOT the forbidden "removal" — it is a reinforcing 1→2 split. Tag it `SPLIT-REPLACE`, not `REMOVE`, so the re-proposal does not misread it as a downgrade.

### Invariant — at most one OPERATION per existing role

A single parent role must not carry both `UPGRADE` and `SPLIT-REPLACE`. If both seem valid, pick the stronger one and state the tradeoff. `ADD` does not touch existing roles, so it combines freely.

## Cross-axis synthesis

Weigh both axes together. When the same weakness is targeted by both a model promotion and a role change, choose only the stronger side and state the tradeoff explicitly (e.g., "promote teammate X to opus" vs "add a new opus role dedicated to domain Y").

## Precondition

This skill requires the preceding `/design` Step 2 team composition to be in context. It is a `disable-model-invocation: true` second-opinion skill and does NOT auto-chain `/design`.

**design-lite conflict guard**: if the in-context proposal looks like a `/design-lite` composition (fixed 2×sonnet, opus excluded), both reinforcement axes conflict with the lite contract — UPGRADE→opus violates the sonnet pin, and ADD/SPLIT mutate the fixed roster. Emit the caveat and proceed only on explicit user confirmation. (Consistent with the cross-reference in `design-lite/SKILL.md`.)

**Schema-drift sync note**: the source of truth is `design/SKILL.md` Step 2's team-composition field set (role / exploration scope / model, plus the model-alias set — English prose). If Step 2 changes that field set, manually sync this skill's OPERATION Korean labels and model aliases (the Korean labels are this skill's emit surface, conceptually corresponding to Step 2's English fields). Do NOT touch `design/SKILL.md`. The residual risk of a missed sync is accepted without a lint.

## Fallback

When the precondition is not met, follow a 3-path fallback:

- **Path 1 — session roster paste**: the user pastes the Step 2 composition → full two-axis analysis.
- **Path 2 — reverse-engineer from a saved design doc (degraded — role axis only)**: `docs/<slug>.md` captures architecture/scope but does NOT save the Step 2 roster (Step 4 saves only architecture / decisions / issues / order). Role-gap detection is possible from the doc's scope, but the model axis is not (no current model assignments). State this limitation when taking this path. Because the model axis is impossible at the source, the split gate's cross-axis reconciliation and the Cross-axis synthesis treat the UPGRADE comparison term as N/A and proceed on the role axis alone (skip the SPLIT-vs-UPGRADE tradeoff weighing). Also, since no interview is in session, the lightweight re-exploration anchor is the saved doc's architecture/scope narrative instead of the interview — limit to surfaces the doc cites/names and their adjacent siblings under the same HARD LIMIT.
- **Path 3 — start a new `/design`**: when neither is available, two-axis analysis is impossible — emit a Korean notice (e.g., *"분석할 팀 구성이 없습니다. 먼저 `/cc-cmds:design`을 실행해 팀 구성을 받은 뒤 다시 호출하세요."*) and stop.
