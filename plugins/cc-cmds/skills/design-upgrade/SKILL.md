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

Analyze the team composition proposed in the preceding `/design` Step 2 output and produce a second opinion along **two axes** — model and role — recommending only *reinforcing* changes.

**Read `${CLAUDE_SKILL_DIR}/../_common/team-upgrade-analysis.md`** for the axis-agnostic engine: the two-axis Scope, restraint principle, role-gap detection + HARD LIMIT, restraint/split gates, OPERATION output format and integrity rules, the per-existing-role invariant, the degraded-axis handling, and the Cross-axis synthesis. Resolve every `{PLACEHOLDER}` in that core against the `## Bindings` below. The Precondition, design-lite conflict guard, schema-drift sync-note, and 3-path Fallback that follow are this skill's injected prose.

## Bindings

| Placeholder | Value |
| --- | --- |
| `{SCOPE_LABEL}` | `탐색 범위` |
| `{FIELD_ORDER}` | `역할 / 탐색 범위 / 모델` |
| `{SOURCE_STEP}` | `/design` Step 2 |
| `{ROSTER_SOT}` | `design/SKILL.md` Step 2 (English prose: role / exploration scope / model, plus the model-alias set) |
| `{LABEL_RELATION}` | conceptual translation (the Korean OPERATION labels conceptually correspond to Step 2's English-prose fields) |
| `{ROLE_GAP_ANCHOR}` | *(empty — no skill-specific gap anchor)* |
| `{RE_EXPLORATION_ANCHOR}` | the interview / task narrative |
| `{LITE_GUARD_TARGET}` | design-lite |
| `{PRECONDITION}` | the preceding `/design` Step 2 team composition is in context |
| `{MODEL_AXIS_DEGRADES_UNDER}` | Fallback Path 2 |
| `{SAVED_DOC_LOCATION}` | `docs/<slug>.md` |
| `{REFEED_TARGET}` | `/design` Step 2 re-proposal (same target on every path) |

This skill declares no `## Operations Layer` — it uses the core's OPERATION set (UPGRADE / ADD / SPLIT-REPLACE) and forbidden-set unchanged.

## Precondition

This skill requires the preceding `/design` Step 2 team composition to be in context. It is a `disable-model-invocation: true` second-opinion skill and does NOT auto-chain `/design`.

**design-lite conflict guard**: if the in-context proposal looks like a `/design-lite` composition (fixed 2×sonnet, opus excluded), both reinforcement axes conflict with the lite contract — UPGRADE→opus violates the sonnet pin, and ADD/SPLIT mutate the fixed roster. Emit the caveat and proceed only on explicit user confirmation. (Consistent with the cross-reference in `design-lite/SKILL.md`.)

**Schema-drift sync note**: the source of truth is `design/SKILL.md` Step 2's team-composition field set (role / exploration scope / model, plus the model-alias set — English prose). If Step 2 changes that field set, manually sync this skill's OPERATION Korean labels and model aliases (the Korean labels are this skill's emit surface, conceptually corresponding to Step 2's English fields). Do NOT touch `design/SKILL.md`. The residual risk of a missed sync is accepted without a lint.

## Fallback

When the precondition is not met, follow a 3-path fallback:

- **Path 1 — session roster paste**: the user pastes the Step 2 composition → full two-axis analysis.
- **Path 2 — reverse-engineer from a saved design doc (degraded — role axis only)**: `docs/<slug>.md` captures architecture/scope but does NOT save the Step 2 roster (Step 4 saves only architecture / decisions / issues / order). Role-gap detection is possible from the doc's scope, but the model axis is not (no current model assignments). State this limitation when taking this path. Because the model axis is impossible at the source, the core's degraded-axis handling fires here (`{MODEL_AXIS_DEGRADES_UNDER}` = Fallback Path 2): the split gate's cross-axis reconciliation and the Cross-axis synthesis treat the UPGRADE comparison term as N/A and proceed on the role axis alone (skip the SPLIT-vs-UPGRADE tradeoff weighing). Also, since no interview is in session, the lightweight re-exploration anchor is the saved doc's architecture/scope narrative instead of the interview — limit to surfaces the doc cites/names and their adjacent siblings under the same HARD LIMIT.
- **Path 3 — start a new `/design`**: when neither is available, two-axis analysis is impossible — emit a Korean notice (e.g., *"분석할 팀 구성이 없습니다. 먼저 `/cc-cmds:design`을 실행해 팀 구성을 받은 뒤 다시 호출하세요."*) and stop.
