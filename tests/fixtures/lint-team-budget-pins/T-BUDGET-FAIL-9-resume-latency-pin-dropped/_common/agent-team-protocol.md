# Agent Team Protocol (fixture)

## Spawn

Spawn prose.

### Team size budget

- **Up to 4 roles** — no justification needed.
- **5 roles** — name the domain the fifth role covers.
- **6 or more** — not available.

**Coordinator-class carve-out — meta/coordination roles are not counted.** Orchestration is not a domain perspective.

## Multi-round

Multi-round prose.

On every dispatch that hands a member its peers' work the lead **re-injects the load-bearing context by path**.

Round 2+ names your peers' witnesses by path below; above your sentinel put one line `peer-read: <role-slug> <round/phase> <nonce>` per named witness.

### Round budget

- **Default = 2 rounds.**
- **Hard cap = 3 rounds.**
- Two entry paths:
    1. **A member names a concrete, actionable measurement it has not yet run** that would settle a peer claim.
    2. **The lead's pre-save sweep produced a refuting verdict.**

### Dispatch latency

A same-key resume can find the member's cache expired; a boundary dispatch starts a fresh agent, so there the order only shortens the wall-clock wait. Inside the happens-before gate below, at a round-advance or convergence boundary, the lead keeps the sends ahead of everything that does not have to precede them:

- As each completion notification arrives, the lead runs 확인, 기록 and the skill's per-witness quality check, where the skill defines one, for that member alone. A send-back that check requires is an in-round resume of that member and stays ahead of the boundary. This is per-member processing inside the gate's order.
- 기록 does not touch `witnessNonce`; the row keeps the nonce of the round just collected.
- After the last 기록, one response writes each row's next-round `witnessNonce` and sends nothing; the next response sends every dispatch. A nonce Edit that returns an error is repeated with the same nonce before any dispatch is sent.
- Each row's `round/phase` flip follows its dispatch, as a single-row Edit.
- Synthesis, drafting and any other lead work come after the sends.

### Dispatch kinds and witness keys

Every dispatch or resume the lead sends is one row of this table. An in-round resume uses a revision token `P-rev<k>`: the witness is the new file `{role-slug}.P-rev<k>.md`, and the nonce is `P-rev<k>:<hex>`.

**A nonce Edit's result is seen before its send.** No dispatch goes out in the response that writes its nonce.

**A revision supersedes `P` whole.** A revision witness is the member's complete product for `P`, never a supplement to it.

**Re-entry at a boundary.** A re-entry that finds a row tagged `Q` goes to the dispatch-completeness gate for `Q` and does not run 확인 for `P` again. The gate's zero-running rule does not empty-pass that entry.

## Convergence

Convergence prose.
