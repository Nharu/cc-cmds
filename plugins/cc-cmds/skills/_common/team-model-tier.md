# Team model tier

**What binds.** This file binds any step that chooses the model of a reviewer seat or a design-audit reader. A skill that writes a literal model (`review-lite`, `design-lite`) chooses nothing and is outside it. The lead assigns each seat exactly one class id from the table at composition time and passes that seat's model as the `Agent()` call's `model`. A seat spanning several classes takes the highest model among them. A seat that fits no class is `opus` and is recorded as class `unclassified`.

Not knowing which class a seat belongs to is not a licence to run it cheaper — that is why the unclassified fallback is the higher model and not the lower one.

## Class table

| class id | covers | model |
| --- | --- | --- |
| `security` | security, authentication and authorization review | opus |
| `contract` | public API, shared schema, a contract another skill, driver or repository consumes | opus |
| `data` | DB schema, migrations, queries, transactions | opus |
| `concurrency` | async, concurrency, locking, ordering | opus |
| `integration` | external service integration | opus |
| `coordinator` | Scope Coordinator | opus |
| `logic` | control flow and correctness, including shell semantics | sonnet |
| `performance` | performance | sonnet |
| `tests` | test quality and coverage | sonnet |
| `conformance` | conformance to a design document | sonnet |
| `quality` | code quality, documentation, style, release hygiene, lint tooling | sonnet |
| `portability` | shell and platform portability | sonnet |
| `audit-reader` | every design-audit reader, identically | opus |

The `opus` classes are the ones where a miss is a P0 no later layer catches and where the finding needs multi-file causal reasoning. The `sonnet` classes check against a stated standard — a design document, a test oracle, a portability list — or are the code-quality perspective a lighter roster already delegates. `logic` is the class most often promoted: where the logic under review *is* the authorization machine, the triggers below keep its seat on `opus`.

## Promotion triggers (closed set)

Indicator ids: `authz` (auth/authorization), `db-schema` (DB schema or query), `public-api` (public API surface), `external-integration` (external service integration), `concurrency` (async/concurrency), `shared-contract` (a public contract or shared schema change). Non-indicator triggers: `basis-finding` (in delta mode, the seat is assigned a basis P0 or P1) and `directive` (the user directive names a risk kind).

Nothing outside this set promotes a seat. A promoted seat runs `opus`.

**Who and when.** The lead evaluates the triggers once per seat in Step 3, from what Steps 1–2 already collected: the narrowed per-file diff array (or `--numstat` rows, or the delta file set), PR title, body and labels, the Step 2 exploration, and the design document when one is supplied. No new judge, hook or driver classifier is introduced. An indicator that fires on a file set promotes every `sonnet` seat whose assigned scope intersects that file set; `basis-finding` and `directive` promote the seat they name. Promotion is per seat, never per team — an indicator firing on files a `tests` seat never opens does not raise that seat.

**Demotion is the table's alone.** No seat runs below its class model for reasons of size, apparent simplicity or budget. Change size is not an input to this table. A respawn keeps the seat's model.

**A person's explicit instruction is the one exception.** In the interactive arm, when the user lowers a seat's model at approval time — including to `haiku` — the lead follows and records that seat with `출처=사용자`. The table is the default, not a constraint on the person choosing to override it. There is no such override unattended, because there is nobody present to give one.

**Limit-error exception.** Only for a review seat whose class model is `opus`: if the dead member's output or return shows an API usage-limit or rate-limit error before it published a witness, its same-round respawn may use `sonnet`, and the report records it. Never for an audit reader. Any other death respawns at the same model.

**Audit readers.** Every reader of one audit uses the `audit-reader` model; readers differ only in the three prompt parameters their skill names, and never in `model`. Mixing models across readers of one audit breaks the reinforcement statistic for the same reason differentiating them by lens does: the `미보강` count means something only while the readers are interchangeable.

## Record syntax — review report

The seat's model is recorded so that the requested model can be compared against the model actually served, after the fact. This file defines the syntax; the skills decide nothing about it.

```
- **리뷰 팀 구성**:
    - [role] ([opus|sonnet]): [scope]
- **모델 티어**:
    - <role-slug> | 부류=<class id> | 모델=<opus|sonnet> | 출처=<표|승격|사용자> | 지표=<trigger id[,trigger id]|-> | 재기동=<-|sonnet (한도 오류)>
```

- `<role-slug>` is the ledger row's leading slug and the same slug the witness filenames use.
- `출처=승격` requires `지표≠-`.
- `재기동` is other than `-` only when the limit-error exception fired.
- The parenthesis in `리뷰 팀 구성` and `모델=` carry the **requested** model the table (promotion included) chose. A model a limit-error respawn actually used belongs in `재기동=` and nowhere else.

The `리뷰 팀 구성` parenthesis holds one bare lowercase alias and nothing else, so that a later pass can read it mechanically.

## Record syntax — audit report

One key in `## 감사 개시`, directly after `reader-count`:

```
reader-model: opus
```
