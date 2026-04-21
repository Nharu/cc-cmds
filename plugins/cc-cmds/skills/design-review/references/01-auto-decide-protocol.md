# Decision Auto-Select Protocol Detail (§8)

Detailed algorithm for auto-decide behavior. The SKILL.md Control-Flow Invariants section keeps the decision-type classifier header and the top-level structure summary — this file contains the full algorithm (`re_evaluate_decision`), blackout categories (B1–B10 with B7/B8/B9 conditional checklists), the risk-analyst safety envelope, and failure-mode matrix.

**Eager-load**: Phase 1 Step 4 when `AUTO_DECIDE_INITIAL=true`.
**Recovery Read**: Step 12.f, unconditionally before every `re_evaluate_decision` call — post-compaction may collapse an earlier eager-load summary, so this unconditional Read is the reliability guarantee.

## Top-level structure (§8.2)

```
auto-decide fires iff ALL of the following hold:
  PRE-CHECK 0: blackout guard passes
  AND PRE-CHECK A: single-option guard passes
  AND (T1-A OR T1-B OR T1-C OR T2-AB)                         # dominance tier
  AND signal #3: order-invariance
  AND signal #4: dimension totality (embedded inside T1-C)
  AND signal #5: no prior [AUTO-DECIDED] premises (via extract_prior_signals filter)
  AND signal #7: counterfactual self-test (post-tier; T2 uses stricter bar)
```

**Rule of thumb**: "When in doubt, escalate." If any gate is uncertain, return `escalate`.

## Dominant Option Tiers (§8.3)

**Tier-1** (single criterion suffices):

- **T1-A — Contradiction Elimination**: all other options directly contradict document-locked decisions/constraints. Exactly one option survives.
- **T1-B — Direct Requirement Match**: exactly one option verbatim/semantically satisfies a stated must/shall/required requirement.
- **T1-C — Single-Dimension Winner**: options differ in exactly **one non-equivalent dimension** and the winner on that dimension is clear. Multi-dimension advantages → escalate (signal #4).

**Tier-2** (both parts required):

- **T2-AB — Context Implication + Partial T1**:
    - **T2-A**: prior decisions / architecture / ack items provide at least 2 independent signals pointing to the same option (`extract_prior_signals` **excludes** `[AUTO-DECIDED]`; **allows** `[APPROVED]/[MODIFIED]/[USER-DIRECTED]/[AUTO-APPROVED]`).
    - **T2-B**: at least one Tier-1 criterion directionally (not necessarily fully firing) points to the same option.

**Near-dominant** (one option slightly better but not clearly): always escalate. Industry-standard defaults alone are insufficient.

## Re-evaluation Algorithm (§8.4)

```
function re_evaluate_decision(proposal, document, review_log, ack_items) -> Result:

  ── PRE-CHECK 0: Blackout Guard (Signal #1) ─────────────────
  if is_blackout(proposal.category, proposal.location, proposal.concept):
    return escalate("blackout category: <name>")

  ── PRE-CHECK A: Single-Option Guard ─────────────────────────
  if len(proposal.options) == 1:
    return escalate("single-option decision — agent may have failed to enumerate alternatives")

  ── STEP 1: T1-A — Contradiction Elimination ────────────────
  surviving = [O for O in proposal.options
               if find_contradictions(O, document, review_log,
                                      allowed_tags=["APPROVED","MODIFIED","USER-DIRECTED","AUTO-APPROVED"])
                  is empty]
  if len(surviving) == 0:
    return escalate("all options contradict locked decisions — user must resolve")
  if len(surviving) == 1:
    candidate = surviving[0]
    if not order_invariance_check(t1a, proposal.options, candidate):
      return escalate("T1-A order-variance")
    if not all_counterfactuals_implausible(proposal.options, candidate, document, ack_items, strict=False):
      return escalate("T1-A counterfactual self-test failed")
    return auto_pick(candidate, "T1-A", "all other options contradict locked decisions")

  ── STEP 2: T1-B — Direct Requirement Match ─────────────────
  requirements = extract_requirements(document)   # only "must/shall/required" text
  matching = [(O, find_requirement_match(O, requirements)) for O in surviving if matches]
  if len(matching) == 1:
    (candidate, req) = matching[0]
    if not order_invariance_check(t1b, surviving, candidate):
      return escalate("T1-B order-variance")
    if not all_counterfactuals_implausible(surviving, candidate, document, ack_items, strict=False):
      return escalate("T1-B counterfactual self-test failed")
    return auto_pick(candidate, "T1-B", f"direct requirement match at {req.location}")

  ── STEP 3: T1-C — Single-Dimension Winner (Signal #4) ──────
  non_equiv_dims = [d for d in extract_dimensions(surviving)
                    if not all_options_equivalent_on(d, surviving, document)]
  if len(non_equiv_dims) == 1:
    winner = find_dimension_winner(non_equiv_dims[0], surviving, document)
    if winner is not None:
      if not order_invariance_check(t1c, surviving, winner):
        return escalate("T1-C order-variance")
      if not all_counterfactuals_implausible(surviving, winner, document, ack_items, strict=False):
        return escalate("T1-C counterfactual self-test failed")
      return auto_pick(winner, "T1-C", f"wins on single non-equivalent dimension: {non_equiv_dims[0]}")
  # 0 non-equiv dims → options effectively equivalent (escalate for user taste)
  # 2+ non-equiv dims → multi-dim comparison is suspect (escalate)

  ── STEP 4: T2-AB — Context Implication (Signal #5 active) ──
  prior_signals = extract_prior_signals(
    review_log, ack_items, document,
    allowed_tags=["APPROVED","MODIFIED","USER-DIRECTED","AUTO-APPROVED"]
    # [AUTO-DECIDED] explicitly excluded — anti-ratchet (F4)
  )
  implied = [(O, sigs) for O in surviving
             if (sigs := get_context_signals_for(O, prior_signals))
             and len(deduplicate_by_source(sigs)) >= 2]
  if len(implied) == 1:
    (candidate, sigs) = implied[0]
    t2b_ok = (any_soft_contradiction_for_others(candidate, surviving, document)
              OR any_partial_requirement_match(candidate, document))
    if t2b_ok:
      if not order_invariance_check(t2, surviving, candidate):
        return escalate("T2 order-variance")
      # T2 strict counterfactual bar
      if not all_counterfactuals_implausible(surviving, candidate, document, ack_items, strict=True):
        return escalate("T2 strict counterfactual test failed")
      return auto_pick(candidate, "T2-AB", f"{len(sigs)} context signals + partial T1 corroboration")

  ── STEP 5: Fallback ────────────────────────────────────────
  return escalate("no dominant option identified — escalating per Ground Rule #6")
```

### Helper — `all_counterfactuals_implausible(options, candidate, document, ack_items, strict)`

```
for N in options where N.id != candidate.id:
  if strict:
    # T2 bar: each non-candidate must be ACTIVELY CONTRADICTED by specific
    # text already in the document (not just implausible).
    citation = find_active_contradiction_in_document(N, document)
    if citation is None: return False
  else:
    # T1 bar: counterfactual is implausible
    arg = articulate_why_wrong(N, document, ack_items)
    if arg.confidence < THRESHOLD_IMPLAUSIBLE: return False
return True
```

## Blackout Categories (§8.5)

Main session MUST classify any decision matching these categories as blackout → always escalate regardless of dominance analysis.

| Code | Category | Rule |
|---|---|---|
| **B1** | API contract / data schema / wire format | **Absolute** — externally observable to clients |
| **B2** | Authentication / authorization / security / compliance | **Absolute** — threat model lives outside the doc |
| **B3** | DB schema / migration / data lifecycle | **Absolute** — ops coordination / backfill windows |
| **B4** | User-facing UX / product flow / copy | **Absolute** — subjectivity is intrinsic |
| **B5** | Licensing / legal / data residency / PII | **Absolute** — compliance constraints outside the doc |
| **B6** | Breaking dependency / framework swap / runtime upgrade | **Absolute** — org-level consequences |
| **B7** | Performance SLO trade-off | **Conditional** — internal utility code-level perf fine; SLO/p99/throughput commitments blocked |
| **B8** | Cost-impacting infrastructure choices | **Conditional** — cost-neutral non-trade-off fine; tier/region/managed vs self-hosted blocked |
| **B9** | Observability / metric taxonomy / log schema | **Conditional** — strict internal rename fine; dashboards/alerts/SIEM exposed names blocked |
| **B10** | Concurrency / consistency / isolation level | **Absolute** — correctness-critical |

**Meta-rule**: unknown or uncertain → **blackout** (safe default).

### Conditional checklists (B7/B8/B9 — §8.5.1)

`is_blackout()` returns boolean, but B7/B8/B9 "conditional" judgments require checklist evaluation. Return `false` (auto-decide allowed) only when **all** checklist items pass clearly. Any uncertainty → `true`.

**B7 allow-conditions (Performance SLO)**:
- [ ] Change is O-notation equivalent or improved (e.g., O(n²) → O(n log n))
- [ ] No p50/p99/p999/throughput/latency-budget/SLO numbers stated in the doc, OR if stated, are unaffected by the change
- [ ] Change scope is confined to a single function/module (not on a shared path)
- [ ] No observable impact on external API response time
- [ ] Change is not of a magnitude that requires capacity-planning re-calculation

**B8 allow-conditions (Cost / infrastructure)**:
- [ ] Change is cost-neutral or cost-reducing
- [ ] No change to resource tier / region / managed-vs-self-hosted choice
- [ ] No capability trade-off (no memory/storage/CPU capacity reduction)
- [ ] Change is at the level of "remove unused config" or "more efficient isomorphic pattern"
- [ ] Not at a billing-line-item scale

**B9 allow-conditions (Observability / log schema)**:
- [ ] Target is a strict internal field name with no doc-evidence of external exposure
- [ ] Target is already marked debug-only (or equivalent) in the doc
- [ ] Change is not a metric taxonomy / event name / log field rename/add/remove
- [ ] No doc references to downstream consumers (log aggregator / SIEM / dashboards)

**Common failure (immediate blackout regardless of checklist)**:
- Main session uncertain on any item
- Change may potentially affect external consumer / contract / SLO
- Checklist feels like it may not fully cover the boundary case

**Evaluation unit**: `is_blackout()` is called per proposal, not per option. If proposal options have different risk profiles (e.g., option A passes B7 but option B blocks it), evaluate the checklist against the **most risky option**. If any option fails any checklist item, the whole proposal is blackout=true. This false-positive bias is intentional.

## Risk-Analyst Safety Envelope (§8.6 — 7 signals)

| # | Signal | Location in algorithm |
|---|---|---|
| 1 | Blackout filter passed | PRE-CHECK 0 |
| 2 | Tier fired (T1-A ∨ T1-B ∨ T1-C ∨ T2-AB) | STEP 1–4 |
| 3 | Order-invariance: same verdict when re-evaluated with options in reverse order | per-tier post-check |
| 4 | Dimension totality: options differ in ≤1 non-equivalent dimension | embedded in T1-C |
| 5 | Transitive-premise freedom: no prior `[AUTO-DECIDED]` cited in dominance reasoning | `extract_prior_signals` filter |
| 7 | Counterfactual self-test: non-chosen options all implausible; T2 requires document citation | per-tier post-check |

> **Note**: Signal #6 (budget caps) was removed in a later refinement — F4 adversarial drift is already structurally blocked by Signal #5 (transitive-premise freedom) plus outer-cycle fresh-agent re-review, making explicit rate limiting unnecessary. Signal numbering retains the gap (1, 2, 3, 4, 5, 7) for historical traceability.

## Budget Caps (§8.7) — REMOVED

Previously INNER_CAP=2 and OUTER_CAP=5 enforced a hard rate limit on auto-decide firings. **Removed in a later refinement.** Rationale: F4 adversarial drift is already structurally blocked by Signal #5 (transitive-premise freedom), and outer-cycle fresh-agent re-review catches any auto-decided ripple. Explicit rate limiting added complexity without meaningful marginal safety. Main session performs no budget counting, no PRE-CHECK B, and does not emit `[BUDGET-DEMOTED]` markers.

## Ground Rule #6 Amendment (§8.10)

GR#6 governs items **already in the dialogue loop**. Auto-decide governs a disjoint subset: items that never enter the dialogue loop. The two scopes are non-overlapping.

Amendment (addition, not rewrite):

> When invoked with `--auto-decide-dominant`, the main session MAY bypass user presentation for `decision`-type proposals that satisfy the Dominance Threshold (§8). This exception is narrowly scoped: it applies only to items that have never entered the dialogue loop. Any item the user has seen, is currently seeing, or has asked a follow-up about remains fully governed by GR#6. Auto-decided items MUST be logged per the Auto-Decide Audit Schema (§3.10 / §8.14) and are subject to user revert per §8.11.

Auto-decide is ON by default for this command. The user can opt out at invocation time via `--no-auto-decide-dominant`, or mid-session via the phrases in §8.12. The first-time notice in Phase 1 step 4 ensures the user is always informed that auto-decide is active before any decision is processed, preserving informed consent.

## Failure Mode Matrix (§8.15)

| Code | Failure | Mitigation |
|---|---|---|
| F1 | False positive (anchoring bias) | Signal #3 order-invariance |
| F2 | Context ignorance | Blackout list (§8.5) |
| F3 | Hidden-dimension dominance | Signal #4 dimension totality (T1-C) |
| F4 | Adversarial drift / silent ratchet | Signal #5 (transitive-premise freedom) + outer cycle re-iteration forced by [AUTO-DECIDED] counting in escalate_applied + fresh-agent re-review + mandatory 자동 선택 내역 visibility |
| F5 | Termination interaction | `[AUTO-DECIDED]` counts toward escalate_applied |
| F6 | Dialogue-loop bypass | GR#6 amendment + CLI opt-in |
| F7 | Algorithm drift across fresh agents | 7-signal reproducibility |
| F8 | Partial-apply interaction | Partial auto-decide forbidden — abort & escalate if not fully appliable |
| F9 | Malicious/bugged proposal | Blackout list blocks dangerous classes |
| F10 | User revocation of consent | Mid-session opt-out (§8.12) |

## Inner review_log.md line format for `[AUTO-DECIDED]`

```
- PROP-R{round}-{N} [AUTO-DECIDED] {tier_hit} "{chosen_option_label}": {one-line rationale}
```

Example:

```
- PROP-R2-3 [AUTO-DECIDED] T1-B "로컬 파일 저장": direct requirement match at §2.3 "오프라인 우선 동기화 필수"
```
