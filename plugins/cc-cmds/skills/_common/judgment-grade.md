# Judgment grades — may this answer be chosen without asking?

The act side of the boundary was already settled: an act escalates when it is
outside pre-authorization and irreversible. The judgment side answers a
different question. Not *"may the run do this?"* but **"may the run choose this
answer without asking?"** — a question with no argv and no head sha for an
act-shaped record to bind.

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
  escalation, not a licence to improvise.
- The recommended option is `팀 토론 진행` or `재설계`.
- The question asks the user to **accept risk that is theirs** — the
  `위험 수용` / `게이트 비활성` / `그대로 진행` / `범위 축소` shapes.

Token: `등급 2`.

That last clause holds because risk acceptance is never delegated.

## Two rules that are not corollaries

**`팀 토론 진행` and `재설계` are never adoptable as recommendations.** They are
**routing output**: whether to convene a team or re-converge is the router's
call, not a stage's.

**`design`'s own confidence criterion is not reused as an adoption signal.**
It is display-layer with no transition edge, and automatic adoption is a
transition edge by definition.

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

### Emission form — how a stage hands a judgment to the gate

This one is what a **running stage** writes: a stage holds no gate verb and
writes no sidecar, so its only channel for a decision it made is its terminal
message. The gate parses five markers out of that message and absorbs the
judgment through the same auto-adoption floor an `act --kind judgment` goes
through. The five spellings are defined here once so they do not drift.

Each marker is a **line of its own** in the terminal message, spelled exactly:

| marker | required | value |
| --- | --- | --- |
| `**판단 부류**:` | always | one token from the `판단 부류` vocabulary, no spaces |
| `**판단 등급**:` | always | `0`, `1` or `2` |
| `**판단 기준**:` | always | the authored standard that chose the option |
| `**판단 되돌리는 법**:` | at grade 1 | the concrete command or edit that undoes it |
| `**판단 근거**:` | always | what was observed, and why this option |

Two dispositions are worth stating because they are not symmetric. **Grade 0
emits nothing** — an already-written rule determined the answer, so there was no
decision. And a judgment emitted with **no `판단 부류` at all** is not treated as
"no judgment": it raises an approval rather than vanishing, because such a stage made a
decision and acted on it inside its own turn.

Two further markers are **optional**, and they are not part of the five: the
auto-adoption floor reads neither, and their presence or absence changes nothing
about whether a judgment is adopted. They are the decision aid a person reads in
the morning report when the judgment becomes an approval instead of a row.

| marker | required | value |
| --- | --- | --- |
| `**판단 추천**:` | optional | one sentence `` `<승인|거부|무효>` — <추천 근거> ``: the menu label this judgment recommends, and after the dash what settles it |
| `**판단 선택지 리스크**:` | optional | the halt record's risk-line grammar: `` `<라벨>` — <risk> / `<라벨>` — <risk> ``, one part per menu label, no ` / ` inside a risk sentence |

The gate reads every marker from its own line up to the next `**판단 ` marker,
so the two may stand before, between or after the five. An `act --kind judgment`
submission carries the same two values as the keys `추천=` and `선택지 리스크=`;
the gate takes them out of the arguments before it assembles the row, so neither
reaches a `자율 승인` row and a long risk sentence does not push the row past its
size limit. When the judgment raises an approval, the gate writes both values
into that approval's `결정 보조` region in the approval sidecar; a value that was
not given is shown as `미기재` in the morning report.

**Writing the question a person will answer.** Whoever raises a judgment that
may reach a person writes it so the person can answer from the question alone:

- The question says what is being decided and the facts already known. A
  question that can be answered only by re-reading the ledger, a report or the
  tree is not raised; the facts the answer needs go into the question itself.
- Each option's description says what the run does next when that answer
  arrives.
- An option answered with content — a measurement, a command's output, an
  instruction longer than a label — says `첨부: <what is attached>` in its
  description.
- The `선택지 리스크` part of each label says what can go wrong, or what is given
  up, by choosing it. With no risk at all it reads `알려진 위험 없음 — <why>`;
  it is never left blank.
- When the fact the decision needs is held only by a person, the recommendation
  reads `(없음) — <that fact>`, naming the fact; an empty phrase such as "a
  person decides" is not written.

`scripts/lint-autoadopt-vocabulary.sh` asserts that every marker the gate's
parser reads, the two optional ones included, is defined in at least one
`_common/` document and the other way round. It checks existence and nothing
more.

## What the lint does not check

It counts marks and matches dispositions. It cannot tell a `등급 1` that should
have been `등급 2`, so do not read it as a correctness lint.
