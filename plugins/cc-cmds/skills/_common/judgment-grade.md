# Judgment grades — may this answer be chosen without asking?

The act side of the boundary was already settled: an act escalates when it is
outside pre-authorization and irreversible. The judgment side answers a
different question. Not *"may the run do this?"* but **"may the run choose this
answer without asking?"**

Those are not the same question and a single mechanism cannot answer both. An
act's escalation record is act-shaped — its binding tuple holds a branch, a
head sha, an argv digest, and its staleness check watches the tree move.
*"Should this run adopt a design re-convergence?"* has no argv and no head sha.

This file owns the three grades, the closed token set, and the marking
convention. `lint-judgment-grade.sh` counts the marks; it does not judge them.

## The three grades

### Grade 0 — mechanical

An already-written rule fully determines the answer. This is not a decision, so
it needs no record. A row here would bury the real decisions under bookkeeping.

Token: `등급 0`.

### Grade 1 — adoptable

Adopt automatically, record it, continue. **All four conditions must hold**, and
the conjunction is the point — each one alone is satisfiable by a decision that
should have been asked about.

1. **Reversible within the run.** Not "reversible in principle" — the record
   carries the concrete command or edit that undoes it (`되돌리는 법`), and a
   choice for which none can be produced fails this condition by construction.
   This is deliberate: a false undo command is a lie someone catches in the
   morning, and a false reversibility judgment leaves no trace at all.
2. **A standard authored BEFORE the run says which option.** Not "the model is
   confident" — a predicate a later reader can check. The record names it
   (`기준`).
3. **A later step can observe the wrong choice.** If nobody would notice, that
   run has no error correction on this axis, and however confident the choice
   looks it is not adoptable.
4. **The decision belongs to the run.** A decision that is the user's does not
   become the run's by being inconvenient to ask about.

Token: `등급 1`.

### Grade 2 — escalate

**Any one** of these is enough.

- An act above the cutpoint, or outside pre-authorization.
- A choice that changes **what the run is trying to do** — the termination
  point, the binding surface, a converged decision, the target set.
- **No standard was authored at that point.** The absence of a standard is an
  escalation, not a licence to improvise. This is the arm that catches the
  cases nobody anticipated, which is most of them.
- The recommended option is `팀 토론 진행` or `재설계`.
- The question asks the user to **accept risk that is theirs** — the
  `위험 수용` / `게이트 비활성` / `그대로 진행` / `범위 축소` shapes.

Token: `등급 2`.

That last clause is what keeps *"leave most of it to the orchestrator"* from
quietly becoming *"the orchestrator waived the check you asked for"*. The
request was **unresolved items and plan refinement**, never **risk acceptance**.

## Two rules that are not corollaries

**`팀 토론 진행` and `재설계` are never adoptable as recommendations.** They are
**routing output**: whether to convene a team or re-converge is the router's
call, not a stage's. This one sentence reconciles three rules that would
otherwise conflict.

**`design`'s own confidence criterion is not reused as an adoption signal.**
That skill fences its whole recommendation mechanism as display-layer with no
transition edge, and automatic adoption is a transition edge by definition.
Worse, its NONE-good case *mandates* recommending `팀 토론 진행`, so reusing it
would convene a team without approval at exactly the point the lead is least
certain — violating a shipped prohibition. And the criterion exists in one of
the five skills, so it could not carry the others anyway.

## Marking convention

An ask point in an **attended** skill carries exactly one grade token, inline,
on or adjacent to the line that raises the question:

```
- **AskUserQuestion** (header chip `절단점`) — `등급 2` — 어느 단까지 자율로 갈지
```

The corresponding **unattended** branch carries a disposition sentence per grade
it can meet. The lint asserts that the disposition exists; it does **not**
assert that the grade is correct — a wrong grade is interpretable misjudgment,
and the fence for that is prose, not structure.

## What the lint does not check

It counts marks and matches dispositions. It cannot tell a `등급 1` that should
have been `등급 2`. Stating this is the point: a counting lint that is read as a
correctness lint is worse than no lint, because it retires the attention that
would otherwise go to the grades themselves.
