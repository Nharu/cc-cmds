# Severity + Saturation Exit Policy Background (§3.11)

The **exit condition formula** (convergence predicate + `consecutive_no_major` aggregation) lives in the Control-Flow Invariants section of `SKILL.md`. This file provides the background, severity taxonomy, and rationale — read it when evaluating convergence decisions (Step 14-15).

## Background

The old `consecutive_clean == 2` zero-proposal rule forced fresh-agent ripple verification but in practice triggered endless tail-end rounds of trivial doc-hygiene findings. This policy only requires ripple verification for **critical/major** severities, letting `minor/trivial` die out naturally.

## 4-tier severity taxonomy

| Tier | Meaning | Examples |
|---|---|---|
| **critical** | Semantic violation, silent termination / correctness risk, structural invariant breakage | termination formula error, missing dedup rule, escalate-counter formula missing, F5-class gaps |
| **major** | Implementation misbehavior / clear structural mismatch / incorrect cross-section spec | canonical-section inconsistencies, lifecycle step missing, feasibility gap, wrong algorithmic order |
| **minor** | Readability / doc quality / audit convenience / summary-section sync | stale consensus lists, outdated quick-ref formulas, cross-reference number drift |
| **trivial** | Typos, case/word choices, minor whitespace | "respponse" → "response", extra whitespace |

## Main session severity rules

1. **Trust agent's initial severity** as the default.
2. **Upgrade-only authority**: if the main session discovers hidden risk during triage, it MAY upgrade severity **unidirectionally** (critical ← major ← minor ← trivial). Downgrades are forbidden.
3. Upgrade is recorded as `[SEVERITY-UPGRADED]` informational marker in `review_log.md`.
4. Self-triage protocol (auto-approve / auto-reject / escalate) is **orthogonal** to severity — severity primarily drives exit judgment.

## Severity ↔ disposition orthogonality (CRITICAL, frequently misapplied)

**Severity is a property of the proposal, not of its outcome.** The saturation counter `consecutive_no_major` looks at *how many* critical/major proposals were emitted this round — **not** how many remain unresolved.

### Rule

```
final_critical_or_major counts a proposal if
  proposal.severity (post-[SEVERITY-UPGRADED]) ∈ {critical, major}

regardless of disposition:
  [APPROVED]       — counts
  [MODIFIED]       — counts
  [USER-DIRECTED]  — counts
  [AUTO-DECIDED]   — counts
  [AUTO-APPROVED]  — counts   (major auto-approved still counts; rare but possible)
  [REJECTED]       — counts
  [AUTO-REJECTED]  — counts
```

### Why

The saturation rule is a **fresh-agent ripple verifier**. If this round mutated the document based on critical/major findings (even approved ones), the next round must run a fresh agent to verify the ripple effects. A resolved major was a *non-trivial change*, so the next round cannot be trusted until a fresh agent re-reads the post-edit document and produces zero new critical/major findings.

### Common mistake

> "Round 2 had 7 major proposals but all were approved, so there are no unresolved major issues → `consecutive_no_major += 1`."

**Wrong.** 7 major proposals → `final_critical_or_major = 7` → `consecutive_no_major = 0`. This is independent of whether they were approved, modified, rejected, or auto-decided.

### Worked example

```
Round 1: emits [major ×8, minor ×3, trivial ×2]
  disposition: all 8 major APPROVED, all minor/trivial AUTO-REJECTED
  final_critical_or_major = 8  → consecutive_no_major = 0

Round 2: emits [major ×2, minor ×5]
  disposition: 2 major MODIFIED (applied with user tweaks), 5 minor AUTO-REJECTED
  final_critical_or_major = 2  → consecutive_no_major = 0

Round 3: emits [minor ×3, trivial ×1]
  disposition: minor AUTO-REJECTED (dup of ack), trivial AUTO-APPROVED
  final_critical_or_major = 0  → consecutive_no_major = 1

Round 4: emits [trivial ×1]
  final_critical_or_major = 0  → consecutive_no_major = 2 ✓
  → inner_converged_cleanly() may fire (also need empty pending + no [IN PROGRESS])
```

Round 1+2 each had resolved majors but saturation only started counting at Round 3 when **zero** critical/major emerged.

## Auto-decide ↔ severity interaction

`[AUTO-DECIDED]` items are treated as `decision`-type mutations, which are `major` by default. They affect `escalate_applied` counting (§8.8) but only affect the saturation counter via the `final_critical_or_major` aggregation — i.e., an auto-decide in a round does not by itself reset saturation unless a separate critical/major proposal appears.

## Adversarial safety

An agent that keeps finding only trivial tails exits after 2 saturation rounds. A repeated same-trivial proposal is blocked by ack. A main session over-upgrading to disguise critical/major would only delay exit in the safe direction (acceptable bias).
