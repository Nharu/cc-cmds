---
name: review-upgrade
description: 리뷰어 구성 강화 분석 (모델·역할 축)
when_to_use: 직전 `/review` Step 3 리뷰어 구성 제안에서 opus 승격이 유의미한 역할이 있는지, 누락된 리뷰 관점을 메울 신규 리뷰어 추가가 필요한지, 또는 과부하 리뷰어 분할이 필요한지 second-opinion으로 검토할 때
disable-model-invocation: true
usage: "/cc-cmds:review-upgrade"
options: []
notes: |
    이 커맨드는 별도 인자를 받지 않으며, 직전 `/review` Step 3 리뷰어 구성 제안이 현재 대화 컨텍스트에 있어야 동작한다. opus 승격, 누락 리뷰 관점 추가, 과부하 리뷰어 분할은 강화가 유의미할 때만 제안하며, 그 외에는 유지 사유를 제시한다. 독립 실행 시 결과가 불정확할 수 있다.
---

Analyze the reviewer team composition proposed in the preceding `/review` Step 3 output and produce a second opinion along **two axes** — model and role — recommending only *reinforcing* changes.

**Read `${CLAUDE_SKILL_DIR}/../_common/team-upgrade-analysis.md`** for the axis-agnostic engine: the two-axis Scope, restraint principle, role-gap detection + HARD LIMIT, restraint/split gates, OPERATION output format and integrity rules, the per-existing-role invariant, the degraded-axis handling, and the Cross-axis synthesis. Resolve every `{PLACEHOLDER}` in that core against the `## Bindings` below. The `## Operations Layer`, role-axis mapping, SPLIT-axis degradation, Precondition, review-lite conflict guard, schema-drift sync-note, and 3-path Fallback that follow are this skill's injected layers.

## Bindings

| Placeholder | Value |
| --- | --- |
| `{SCOPE_LABEL}` | `담당 범위` |
| `{FIELD_ORDER}` | `역할 / 모델 / 담당 범위` |
| `{SOURCE_STEP}` | `/review` Step 3 |
| `{ROSTER_SOT}` | `/review` Step 3 (Korean table: `역할 | 모델 | 담당 범위`) |
| `{LABEL_RELATION}` | verbatim-equal (the OPERATION Korean labels equal the Step 3 table headers verbatim) |
| `{ROLE_GAP_ANCHOR}` | A gap is a review perspective the Step 3 risk-indicator table missed — see Role-axis mapping below. |
| `{RE_EXPLORATION_ANCHOR}` | the PR diff + changed-file set + risk-indicator table |
| `{LITE_GUARD_TARGET}` | review-lite (sonnet pin) |
| `{PRECONDITION}` | the preceding `/review` Step 3 reviewer composition is in context |
| `{MODEL_AXIS_DEGRADES_UNDER}` | never (the saved report preserves each reviewer's model) |
| `{SAVED_DOC_LOCATION}` | `docs/reviews/<report>.md` |
| `{REFEED_TARGET}` | live / Path-1 → `/review` Step 3 re-proposal (prospective); Path-2 → `/review` Step 6 team re-creation (retrospective) |

Note the column order differs from design-upgrade: Step 3's schema places **모델 before 담당 범위**. `역할` / `모델` are shared tokens; `담당 범위` substitutes design's `탐색 범위`. The full-triple OPERATIONs (ADD, SPLIT-REPLACE) emit in `역할 / 모델 / 담당 범위` order for paste-back parity; UPGRADE omits scope, so order is unaffected.

## Operations Layer

This skill extends the core with one additional OPERATION class and one forbidden-set entry.

### `ADD-Coordinator` (review-only OPERATION)

The `/review` Scope Coordinator (a >50-file PR meta/orchestration role: Round 0 file-risk classification + per-round coverage audit + cross-cutting issue synthesis) is **not a domain perspective**, so it cannot pass the core's 3-condition restraint gate. It is therefore declared here, outside the core, as a reinforcement-direction OPERATION with its own gate.

**2-condition structural gate (bypasses the restraint gate)** — BOTH required:

1. The confirmed scope exceeds 50 files — measured against the **Step 1c-narrowed** scope (if the user chose "특정 경로만" / "리뷰 분할", the effective scope may be ≤50, in which case this fails).
2. No Step 3 role performs the coordinator function.

**Invariant interaction**: ADD-Coordinator mints a brand-new role → exempt from the per-existing-role invariant, combines freely. Carryover guard: (a) the new coordinator name must not collide with any existing roster role, (b) gate condition (2) already enforces at most one coordinator per proposal.

**Coordinator-targeting OPERATION rules**: `UPGRADE`-Coordinator is **valid** (an existing sonnet coordinator → opus; cross-cutting synthesis is exactly an opus strength) — this needs no separate op, the shared `UPGRADE` targets the coordinator role. ADD-Coordinator (when absent) and UPGRADE-Coordinator (when present) are mutually exclusive by precondition, so the per-existing-role invariant stays cleanly satisfied.

**Path-2 suppress**: gate condition (1)'s Step 1c-narrowed effective scope is not preserved in the saved report (the report `## 개요` holds only the raw `변경 규모: 파일 X개`, not the post-1c effective scope). Therefore **ADD-Coordinator is not emitted on Path-2 (suppressed)** — same Path-2 quantitative-signal absence as the SPLIT degradation below. Falling back to raw `변경 규모` risks misjudging the effective scope, so it is not adopted (honesty first; state the caveat).

### Forbidden-set append

- `SPLIT-REPLACE`-Coordinator is **forbidden** (splitting a unified cross-cutting synthesis role constructively violates clean cleavage). This appends to the core's forbidden-set (role removal / merge / model downgrade).

## Role-axis mapping (review)

The core's role axis here means **uncovered review perspective**, drawn from: security / performance / code-quality / logic / error-handling / type-safety / testing / api-contract / concurrency / data-integrity.

**Risk-indicator reconciliation rule (the heart of the restraint)**: Step 3's risk-indicator → reviewer mapping (auth→security, DB→perf/DB, public-API→API-contract, external→security+integration, async→concurrency) is Step 3's own coverage contract. An `ADD` fires only when ALL hold:

- (a) the diff shows a signal for that perspective,
- (b) none of the Step 3 proposal's `담당 범위` owns that perspective,
- (c) it is not already routed by a *fired* risk-indicator mapping,
- (d) it is not already absorbed into an existing reviewer's role-specific checklist.

Because those checklists are broad, the restraint gate's distinct-expertise bar (condition 3) is high and most candidates drop at (c)/(d). The canonical valid `ADD`: Step 3 misclassified the PR type so an indicator that *should* have fired did not, leaving a perspective (e.g. DB migration → data-integrity) genuinely uncovered.

**SPLIT-over-`담당 범위`**: fires when a single `담당 범위` spans two separable perspectives and this PR's volume would starve one side. The overload evidence here is **quantitative** (file count + diff size of the parent perspective's slice, from the in-context per-file statistics) — this is where the core HARD LIMIT item 2 ("a large hit is SPLIT input") applies. PARTITION: `childA.담당 범위 ⊎ childB.담당 범위 = parent.담당 범위 (no overlap, no loss)`. The split gate's step-4 cross-axis reconciliation chooses between SPLIT (two sonnets, parallel focus, +coordination, +1 headcount) and UPGRADE (promote the parent to opus, single synthesis preserved).

## SPLIT-axis degradation (review Path-2)

The SPLIT overload evidence (quantitative per-file statistics) is in context only on live / Path-1. **On Path-2 (saved-report reverse-engineering), per-file diff statistics are absent → quantitative SPLIT gating degrades to N/A (suppressed)** — the mirror image of design's model-axis N/A. Concretely, this is the core's "consuming skill MAY declare the SPLIT comparison term N/A" hook: on Path-2 the core split gate's step 4 and the Cross-axis synthesis treat the **SPLIT comparison term** as N/A and fall through to the UPGRADE-parent alone (exactly symmetric to proceeding on the role axis alone when the model term is N/A). So on Path-2 only `ADD` (perspective gap) + `UPGRADE` (model) fire; `SPLIT-REPLACE` and `ADD-Coordinator` are not emitted, and the caveat is stated. (Model-axis N/A is the core binding `{MODEL_AXIS_DEGRADES_UNDER}` — `never` for review; SPLIT-axis N/A is this injected instruction — both availability degradations reach the same core gate/synthesis sites through their own channel.)

## Precondition

This skill requires the preceding `/review` Step 3 reviewer composition to be in context. It is a `disable-model-invocation: true` second-opinion skill and does NOT auto-chain `/review`.

**review-lite conflict guard**: if the in-context proposal looks like a `/review-lite` composition (fixed 2×sonnet — a dedicated security reviewer + a code-quality/logic reviewer; opus excluded; no Scope Coordinator; a single Y/N gate), both reinforcement axes conflict with the lite contract — UPGRADE→opus violates the sonnet pin, and ADD/SPLIT/ADD-Coordinator mutate the fixed 2-member roster (ADD-Coordinator also contradicts "no Scope Coordinator"). Emit a Korean caveat and proceed only on explicit user confirmation; otherwise recommend `/cc-cmds:review`. (Consistent with the cross-reference in `review-lite/SKILL.md`.)

**Schema-drift sync note**: the source of truth is `/review` Step 3's reviewer-composition field set (`역할 | 모델 | 담당 범위` — Korean table). If Step 3 changes that field set, manually sync this skill's OPERATION Korean labels and model aliases. Because this skill's labels are **verbatim-equal** to the Step 3 table headers (design-upgrade's are a conceptual translation of English prose), the drift coupling is tighter — a header rename in Step 3 breaks the verbatim match directly. Do NOT touch `review/SKILL.md`. The residual risk of a missed sync is accepted without a lint (single-direction, one (consumer, source-step) pair).

## Fallback

When the precondition is not met, follow a 3-path fallback. The re-feed target is path-conditional — emit a per-path "재투입 대상" note so the user does not paste back into the wrong slot.

- **Path 1 — session roster paste** (full two-axis): the user pastes the Step 3 `역할 | 모델 | 담당 범위` table → full two-axis analysis. This path uniquely still holds Step 3's `위험 신호` directly, the freshest reconciliation input. **재투입 대상**: `/review` Step 3 re-proposal (prospective).

- **Path 2 — reverse-engineer from a saved review report** (model + perspective-ADD axes complete; quantitative SPLIT / Coordinator degraded): unlike design, `docs/reviews/<report>.md` `## 개요`'s `리뷰 팀 구성` preserves all three axes as `역할 ([모델]): [담당 범위]` → the **model axis (UPGRADE) is fully restored**, and the perspective-gap `ADD` is restorable subject to the caveats below. But **the per-file quantitative signal is absent, so quantitative SPLIT and ADD-Coordinator gating degrade to N/A / suppressed** (see SPLIT-axis degradation above; symmetric to design Path-2's model-axis N/A). Caveats to state:
    - (i) This is an AS-RUN roster (generated from the approved Step 3, possibly modified at Step 6 — retrospective), so it is followup-team information, not a live proposal.
    - (ii) Step 3's `위험 신호` is not preserved → reconcile `ADD` from the report's `## 미검토 영역` (direct ADD input, but a **conditional section — may be omitted when not applicable**) + finding `[category]` tags + bounded diff re-read. When `## 미검토 영역` is absent, re-derive ADD from the secondary inputs (`[category]` tags + bounded re-read) alone; ADD input confidence is lower in that case, so "fully restored" holds **only when `## 미검토 영역` exists**.
    - (iii) On multiple report versions, use the highest version.
    - (iv) **Quantitative SPLIT and ADD-Coordinator suppressed** — Path-2 output is limited to UPGRADE + ADD (perspective gap).
  - **재투입 대상**: `/review` Step 6 team re-creation (retrospective). Step 6 requires augmented fields (Re-creation reason / Previous review coverage / Additional analysis scope) + an approval cycle, not the Step 3 form, so there is no slot a `역할 | 모델 | 담당 범위` OPERATION drops into verbatim. Map the Path-2 output instead: the OPERATION roster delta (UPGRADE / ADD [/ ADD-Coordinator and SPLIT-REPLACE are suppressed on Path-2]) → Step 6 **Additional analysis scope** (plus the re-created roster); each ADD's rationale → Step 6 **Previous review coverage** (covered vs uncovered, citing the report's `## 미검토 영역`); **Re-creation reason** is supplied separately by the user / next-turn model (the emit does not force it). This keeps "paste back without ambiguity" aligned with Step 6's input schema.

- **Path 3 — start a new `/review`**: when neither is available, two-axis analysis is impossible — emit a Korean notice (e.g., *"분석할 리뷰어 구성이 없습니다. 먼저 `/cc-cmds:review`를 실행해 Step 3 리뷰어 구성을 받은 뒤 다시 호출하세요."*) and stop.

## OPERATION worked example

Emit full-triple OPERATIONs in `역할 / 모델 / 담당 범위` order (paste-back parity with Step 3):

```
[ADD]
- 역할 / 모델 / 담당 범위: 데이터 정합성 리뷰어 / sonnet / DB 마이그레이션·스키마 변경·트랜잭션 경계·정합성 제약
- 근거: PR이 마이그레이션을 포함하나 Step 3가 PR 타입을 일반 기능으로 분류해 data-integrity indicator 미발화 → 어느 리뷰어의 담당 범위도 미커버
- 기대 효과: 마이그레이션 정합성 회귀를 전담 관점으로 포착

[UPGRADE]
- 역할: 보안 전담 리뷰어
- 현재 모델 → 권장 모델: sonnet → opus
- 변경 사유: 멀티 서비스 인증 위임 경로의 크로스 도메인 추론이 opus 강점에 정합
- 기대 효과: 미묘한 authn bypass 검출률 향상

역할/모델 변경 불필요 (해당 시): 나머지 리뷰어는 현재 구성 유지 — 근거: ...
```
