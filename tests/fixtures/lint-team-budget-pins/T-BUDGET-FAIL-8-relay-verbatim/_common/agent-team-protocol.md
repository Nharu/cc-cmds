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

On every resume that hands a member its peers' work the lead **re-injects the load-bearing context by path**.

Round 2+ names your peers' witnesses by path below; above your sentinel put one line `peer-read: <role-slug> <round/phase> <nonce>` per named witness.

### Round budget

- **Default = 2 rounds.**
- **Hard cap = 3 rounds.**
- Two entry paths:
    1. **A member names a concrete, actionable measurement it has not yet run** that would settle a peer claim.
    2. **The lead's pre-save sweep produced a refuting verdict.**

### Resume latency

A member's cache entry lives five minutes from the start of its last request, so every second between a member's last request and its resume can turn that resume into a full rewrite of the member's context. Inside the happens-before gate below, at a round-advance or convergence boundary, the lead keeps the resume sends ahead of everything that does not have to precede them:

- As each completion notification arrives, the lead runs 확인, 기록 and the skill's per-witness quality check, where the skill defines one, for that member alone. A send-back that check requires (a deepening resume, a coverage audit) is an in-round resume of that member and stays ahead of the boundary. This is per-member processing inside the gate's order, not boundary batching: no member is resumed into the next round or the convergence phase until every roster member has passed 확인 and 기록.
- 기록 does not touch `witnessNonce`; the row keeps the nonce of the round just collected. The response that runs a member's 기록 also mints that member's next-round nonce with `openssl rand`, so minting adds no request of its own; a minted nonce that is lost before it is written is minted again.
- After the last 기록, one response writes each row's next-round `witnessNonce` (one single-row Edit per row) and sends nothing; the next response, issued once every one of those Edits has returned without error, sends every resume. A nonce Edit that returns an error is repeated with the same nonce before any resume is sent.
- Each row's `round/phase` flip follows its resume, as a single-row Edit.
- Synthesis, drafting and any other lead work come after the sends. Only what a send itself carries may come before them: the consensus and open-conflict text of a convergence resume, a re-scope decision for a thin return, and a Case 3 re-assignment.

### Resume kinds and witness keys

Every resume the lead sends is one row of this table. An in-round resume uses a revision token `P-rev<k>`: the witness is the new file `{role-slug}.P-rev<k>.md`, and the nonce is `P-rev<k>:<hex>`.

**A nonce Edit's result is seen before its send.** No resume goes out in the response that writes its nonce.

**A revision supersedes `P` whole.** A revision witness is the member's complete product for `P`, never a supplement to it.

**Re-entry at a boundary.** A re-entry that finds a row tagged `Q` goes to the dispatch-completeness gate for `Q` and does not run 확인 for `P` again. The gate's zero-running rule does not empty-pass that entry.

## Convergence

Convergence prose.
