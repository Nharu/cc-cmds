# Agent Team Protocol (Shared Rules)

Shared orchestration contract for multi-agent team workflows (`design`, `design-lite`, `design-analyze`, `design-apply`, `review`, `review-lite`). A team member is a **nameless background task**: the lead spawns it with `Agent` (`subagent_type: "claude"`, **no `name`**, `run_in_background: true`), resumes it across rounds by its `agentId`, and the task **self-terminates** when it returns.

A returning task delivers its round product two ways at once: a **durable witness file** the member writes before returning, and the **ephemeral return text / background completion notification**. The witness is the **authoritative source of truth**; the notification and return text are demoted to **early-wake hints**. This split is load-bearing: the completion notification is a push channel empirically dropped / duplicated / mis-routed by upstream harness bugs, and the returned `agentId` cannot be status-polled (`TaskGet` on a returned background `agentId` answers "Task not found"). If the lead trusted the dropped channel it would either park forever waiting for a finish notice that never arrives, or — worse — synthesize a round product it never observed (fabrication). The witness closes both holes: the lead reconciles against on-disk bytes the member alone wrote, never against a notification.

## Spawn

Spawn each member as a nameless background task: `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. A task does **not** share the lead's conversation — embed everything load-bearing into the prompt (role, round, all inputs the member must act on, plus the witness parameters below). Record the returned `agentId` **and the member's `scratchDir`** in the ledger immediately, with the same immediacy (see **Role↔agentId ledger v2**). Spawns are synchronous calls: a spawn error is returned inline and handled inline (no dispatch-failure bound needed).

Before spawning the first member of a team, the lead creates one team witness directory **out-of-tree**:

```
WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-<slug>.XXXXXX")
```

Out-of-tree placement makes the two-command boundary gate (`verification.md` §6: main `git status --porcelain` == baseline ∧ `git worktree list --porcelain` == baseline) self-evidently satisfied — even in a user project where `docs/` is tracked, the witness adds **0 surface** to `git status`. Each **fresh** team (the `design` Step-5 walkthrough team, the Step-6 refinement team) gets its **own** nested `mktemp -d` directory, anchored per-row in the ledger (see **Role↔agentId ledger v2**) so it survives compaction.

## Witness file (member-written, durable, atomic publish)

- **Layout — per-member-per-round separate files.** `${scratchDir}/{role-slug}.round-N.md` for discussion rounds; `${scratchDir}/{role-slug}.{phase}.md` for phase work (fidelity / walkthrough / refinement). A shared single append log is **FORBIDDEN** — parallel members appending to one file in the same round interleave and corrupt it. Separate files shrink the racing-writer surface to a single `(role, round)` path (torn writes are confined to the same-member zombie-vs-respawn axis; cross-member and cross-round collisions are eliminated).
- **Write discipline (MUST).** Build the full round product **plus the trailing sentinel** in a **single hidden per-attempt temp**:

  ```
  T=$(mktemp "${scratchDir}/.{role-slug}.{round/phase}.XXXXXX")
  ```

  (same directory → same-filesystem rename atomicity; the temp has no `.md` suffix and a leading dot, so it is hidden from the default glob and never appears in the `*.round-N.md` key list). Then, as the **final action before return**, publish atomically:

  ```
  mv -n "$T" "${scratchDir}/{role-slug}.{round/phase}.md"
  ```

  `mv -n` (no-clobber) gives **first-COMPLETE-wins**, but its safety is **not** from atomic no-clobber — `mv -n` is stat-then-rename on both BSD and GNU, so a same-round zombie-vs-respawn pair can race the same target and the later `rename(2)` may replace the earlier one. The 2-part guarantee is instead: (1) whichever rename lands, the published file is a **same-nonce completed** product (both contenders share the per-(member, round) nonce and a sentinel-terminated temp), so the reader always observes a valid completed witness for that `(member, round)` — never a torn or stale one; and (2) **no temp is ever self-deleted** — on a name collision `mv -n` skips the rename and leaves the **losing** temp in place, and a member `TaskStop`-ed mid-write likewise leaves its in-progress temp behind; both kinds of leftover temp are swept by teardown. Such an orphan `.{role-slug}.{round/phase}.*` temp in an abort-preserved `scratchDir` is harmless — floor-read and recovery only ever look at the non-temp key path (`{role-slug}.{round/phase}.md`).
- **Sentinel + nonce.** The last line of the published file is the sentinel carrying the lead-injected per-round nonce:

  ```
  <!-- cc-witness: {role-slug} {round/phase} complete {nonce} -->
  ```

  The lead generates `{WITNESS_NONCE}` per **(member, round)** with a Bash CSPRNG — `openssl rand -hex 8` (or `head -c8 /dev/urandom | xxd -p`) — and injects it into the task-assignment header alongside `{WITNESS_PATH}`. **LLM self-generation of the nonce is forbidden** (low-entropy / predictable defeats forgery defense; unlike the `mktemp`-derived `{WITNESS_PATH}`, the nonce needs a separate real-entropy call). The member echoes the injected nonce verbatim into the sentinel. Because the nonce is per-(member, round) and unforgeable, a member that quotes a generic sentinel literal in its body cannot produce a body line that false-passes the completion predicate.
- **No same-round rewrite.** A published witness is **never** overwritten by the contract: a revision is a new round (a new file). The only writers that can ever target an already-published path are a same-round zombie + its respawn, and both emit the **same-nonce completed** product — so even if a late `rename(2)` lands, the bytes the lead synthesizes from remain a valid completed witness for that `(member, round)` until audit time. (The path is not byte-immutable; the _completeness and nonce-validity_ of whatever bytes are there is the invariant.)

## Completion predicate `witness_present(member, N)`

Holds **iff all three conjuncts hold**:

1. `test -f {WITNESS_PATH}` — the non-temp `(role, {round/phase})` key file exists (fast pre-gate).
2. The file's **last non-empty line** (strip trailing blank lines / newlines before comparing) == `<!-- cc-witness: {role-slug} {round/phase} complete <nonce> -->`. This catches an **incomplete-tail** write (a torn or sentinel-less file lacks this line and fails). It does **not** distinguish a discipline-compliant atomic publish from a completed direct-write ending in the same sentinel — the on-disk bytes are identical — so fail-closure against a _completed_ direct-write rests on the member's temp+`mv -n` discipline (the header MUST), not on this conjunct; the lead cannot verify that discipline from the published bytes. (Trailing-blank tolerance avoids a false-negative respawn from a stray final newline.)
3. The filename's `{round/phase}` key == the sentinel's `{round/phase}` key (key consistency — `round-N` matches `round N`, a phase name matches itself) **AND** the sentinel's nonce == the lead-injected per-(member, round/phase) `{WITNESS_NONCE}`.

Existence alone is necessary but **not** sufficient — the sentinel makes the predicate **fail-CLOSED on a write-discipline slip** (existence-only would read a torn direct-write as complete → fabrication, i.e. fail-OPEN). The gate reads **only** this specific key path and its last line; it **never** references the notification, the return text, or `agentId` identity.

## Completion signal (hints only)

The background completion notification and the resume tool result are **early-wake hints** — they tell the lead *when to go look*, never *what was produced* and never *that a round is done*. Do not look for `[COMPLETE]`/`[IN PROGRESS]` prefixes or session-text echoes — they do not exist in this model. Round completion is established **only** by `witness_present(member, N)`.

## Multi-round (resume + context re-injection)

A one-shot isolated `Agent()` per round is forbidden — the retained-context, multi-round cross-review/convergence loop is what makes this a *team*. Drive at least **2 rounds** (Round 1 = produce; Round 2+ = cross-review with peer findings). Resume a member by sending to its `agentId` (`SendMessage` to the agentId continues the task with its context intact). On every resume, the lead **re-injects the load-bearing context** — do not trust retained context for load-bearing data; quote peer findings **verbatim**. Re-injection is belt-and-suspenders: resume reliably recalls prior rounds, but a verbatim re-inject keeps the round robust against drift.

## Convergence

Convergence is by **witness collection**, not live polling. After cross-review, resume each member once with a convergence prompt (re-inject current consensus + open conflicts); a member's round is converged-and-collected only when its round witness is `witness_present`. Batch the resumes; keep one large resume per member per round and cap rounds to the minimum the discussion needs.

## Reconcile ladder (witness-absent re-entry)

- **Disk-first check before respawn.** On entering a round-N reconcile (and on every cross-session re-entry / `state=running` residual scan), the **first** action is a floor-read of that member's witness. If it is already `witness_present`, treat it as done and consume it — **no respawn, no re-entry count** (this absorbs a notification that landed between the member's return and the ledger flip across a compaction).
- **3-conjunct death predicate.** A member is declared dead **iff**: `reentry_count ≥ K (=3)` ∧ `witness_present` still false ∧ (`output_file` absent **OR** `current_bytes == last_output_bytes` (where `current_bytes` is the `output_file` byte-count read on this re-entry and `last_output_bytes` the count from the previous one), the two most recent transcript byte-counts unchanged). The liveness conjunct reads the member's harness **`output_file` byte-count**, NOT the witness bytes — the witness appears in one atomic rename and has no growth curve, so it cannot be a liveness signal. **All three conjuncts are required**; dropping byte-stability would kill a member still writing. `reentry_count` and `last_output_bytes` are **lead-LOCAL ephemeral** liveness-tracking state — **not** ledger v2 columns (the Role↔agentId ledger v2 schema deliberately omits counters; they are not durable state). They re-zero after a compaction, but the disk-first check (witness floor-read precedes the count) is the durable completion check, so re-zeroing only *delays* a death declaration (bounded extra wait), never makes it wrong.
- **Death → same-round respawn.** `TaskStop(agentId)` → respawn into the **same round** (round counter NOT incremented; same `{WITNESS_PATH}`, same `{WITNESS_NONCE}`, inputs re-injected — the nonce is per-(member, round) so the respawn reuses the same value, and a surviving zombie + the respawn racing the same no-clobber target with the same nonce both pass conjunct 3 whichever wins → first-complete-wins determinism). A respawn is a **new** background agent with a new `agentId` and a new `output_file`, so on respawn **update the ledger row's `agentId`** and **reset `reentry_count` to 0 and `last_output_bytes` to ∅**. Failing to update would make the liveness conjunct read the dead agent's stale `output_file` (fixed byte-count → stability sub-conjunct immediately re-satisfied), instantly false-killing the healthy respawn — or, conversely, miss a wedge. The respawn's `output_file` is tracked thereafter, with `reentry_count` re-armed so a wedged respawn can again accumulate to K. Soft signals (`output_file` growth, early-wake) are acceleration hints, not the gate.
- **Respawn also dies → Case 2 (never-returns).** `AskUserQuestion` menu = {① respawn again / ② annotate the missing member explicitly and partial-synthesize from the remaining witnesses (the omission is an explicit absence record, not fabrication) / ③ abort the workflow}. Per the happens-before gate, ①/③ or ②'s explicit choice gates round N+1: ② closes round N as partial and proceeds to N+1, but the missing member's ledger row is set to `aborted` (it was `TaskStop`-ed), **not** `done`, and its last-return records the explicit absence annotation (a witness-less `done` violates the anti-fabrication rule and is forbidden). An `aborted` row does **not** re-enter the `state=running` residual scan, so a witness this member publishes _after_ the abort is intentionally never consumed — the partial close is final, and the N+1 absence annotation is authoritative even if a late witness later appears on disk (this is a conservative under-claim, never a fabrication).

## Cross-round happens-before hard gate (no look-ahead)

A multi-round team injects the prior round's peer findings **verbatim** into the next round's prompt → a dropped round-N witness is a concrete fabrication channel. The order is a **MUST** (no boundary batching):

1. **확인** — `witness_present` for **every** round-N member;
2. **기록** — read each witness and record `state=done` + last-return in the ledger;
3. **only then** resume round N+1.

If round N was closed as partial via Case-2 option ②, the missing member's round-N+1 verbatim-injection slot **carries the explicit absence annotation** (no empty slot, no silent omission) — so the N+1 peers see that slot as "no report (missing due to respawn failure)" and avoid a soft-fabrication that assumes a complete peer that never existed.

This rule lives as **hard-MUST protocol prose**, not a lint-enforced `## Control-Flow Invariants` block: `agent-team-protocol.md` is a shared `_common` document Read by all six skills (not a SKILL.md), so a per-skill CFI copy would drift six ways.

## Anti-fabrication (disk is the SOT)

- **Sole-authorship anchor.** The lead **never** writes a member's witness — the whole guarantee rests on this one fact.
- **Fail-closed hard gate.** The lead **never** extracts round content from the return text or the notification. A round-N witness that is absent or partial (no trailing sentinel) → **same-round respawn** (cheap-safe); never fall back to a hint. Synthesizing, judging convergence for, or recording ledger content for a member whose witness was not observed is **fabrication and is forbidden**.
- **Universal witness.** This is not limited to "discussion rounds" — **every** member resume whose output the lead consumes is a witness target. This includes `design`'s Step-4 fidelity pass (`{role-slug}.fidelity.md`), the Step-5 walkthrough team, and the Step-6 refinement team (each fresh team in its own nested `mktemp` dir). Only phases that are **entirely lead-LOCAL** are exempt, and the exemption must be explicit.

## Teardown & abort

Teardown is **automatic** — a returned task has self-terminated, so there is nothing to shut down (no `shutdown_request`, no `TeamDelete`, no `ps aux`). **Abort** = `TaskStop` on a *running* `agentId`. Witness-directory cleanup and per-row `scratchDir` strip are in `_common/team-cleanup.md`.

## Escalation (failure phenotypes)

Two cases (counters) plus one routing rule:

- **Case 1 — Thin-return stall** (counter): a task publishes an empty or substanceless witness. 1st → re-scope + resume once (hard prompt: "no empty witness — deliver the result or name a concrete blocker in one line"); 2nd consecutive → `AskUserQuestion` (proceed without this member / re-scope once more / abort). If excluded, mark the exclusion in the synthesized document's metadata.
- **Case 2 — Never-returns** (binary, not a counter): the death predicate of the reconcile ladder holds (no witness after `K` re-entries with a stalled `output_file`). The recovery is `TaskStop` + same-round respawn; a respawn that also dies routes to the `AskUserQuestion` menu above.
- **Case 3 — Non-conforming witness** (routing rule, not a bound): the witness is present but off-contract (spec-violating / malformed content above the sentinel). It is not caught by a counter (the witness published) — cross-review and the Step-4 fidelity pass catch it. The lead re-assigns once; a recurrence feeds the Case 1 counter.

"Reasonable bound" for never-returns is the `K`-plus-byte-stability death predicate — no wall-clock constant (a long-running scope, e.g. a deep audit, is legitimate, and a growing `output_file` keeps the member alive). Surface to the user (`AskUserQuestion`) only on a Case-1/Case-2 threshold or explicit user instruction — never on wall-clock time, lead confidence, or lead opinion alone.

## Role↔agentId ledger v2

The model is roster-less, so an in-context list of agentIds evaporates on compaction with no fallback. Persist a **durable ledger** co-located with each skill's existing artifact:

- **design / design-apply / review / review-lite**: an HTML-comment block at the top of the output document (right after the H1, before the first `##`): `<!-- cc-design-ledger v2 … -->`. A visible `##` section is forbidden (it would collide with walkthrough/implement/design-review heading parsers and would leak opaque agentIds into the user-facing doc). The doc is created as an **early stub** (title + ledger block) at spawn time, before Step-4 save.
- **design-analyze**: a `"ledger"` key in the existing `.{slug}.work.json` (already machine-only) holding the same per-row data.

Each ledger entry is **behavior-bearing**, with a **per-row `scratchDir`** added to v2:

```
agentId | state | round/phase | role/scope (1 line) | thinReturns | last-return summary | scratchDir
```

where `state ∈ {running, done, aborted}`. Update it on every state change.

- **Immediate record.** `scratchDir` is written into the row at spawn time with the **same immediacy as `agentId`** (the recording window is the existing agentId-recording window — no new exposure window).
- **Derive-from-ledger, never re-`mktemp`.** Every resume and every post-compaction re-entry derives `WITNESS_DIR` from the row's `scratchDir`. Re-running `mktemp` would create an empty directory, orphan the in-progress witness, and reopen the fabrication hole. **Re-read the ledger from disk on entering any phase that resumes a task** (Step-4 fidelity pass, Step-5, Step-6) — do not trust in-context copies. If the block is missing/unparseable, or a `state=running` row has no `scratchDir` or one whose path is not on disk, **fail closed via `AskUserQuestion`** (never silent-skip). A residual `state=running` row is also the leftover-detection signal (it replaces the removed `teams/` filesystem scan).
- **Transient.** `scratchDir` is meaningful **only** while a row is `state=running` (the compaction / workflow-abort recovery window). On **normal workflow completion** it is **per-row stripped from every terminal row** (`done` and `aborted` alike), together with the directory `rm -rf` (see `_common/team-cleanup.md`). The cleanup axis is the **workflow result**: preservation applies only to a **workflow-level abort**; an individual `aborted` row is still stripped if the workflow completes normally. A committed document from a normally-completed workflow therefore carries `scratchDir` on **0** rows → no macOS TMPDIR-hash (UID-derived) leak into version control, no staleness.

## Witness vs ledger (two artifacts, clean separation)

| Artifact | Records | Author | Location | Lifetime |
| --- | --- | --- | --- | --- |
| **Ledger** (`cc-design-ledger v2` / work.json `"ledger"`) | STATE + per-row transient `scratchDir` | **lead** | in-tree | whole workflow |
| **Witness** (`${scratchDir}/{role-slug}.{round/phase}.md`) | CONTENT (full product, sentinel-terminated) | **member** (sole, atomic rename) | `${TMPDIR:-/tmp}` (system temp dir), out-of-tree | deleted on normal workflow completion (all terminal rows); retained on workflow-level abort |

Order (MUST, = the happens-before gate): `witness_present` → lead READs the content → lead fills the ledger row `done` + last-return **from the witness content**. The ledger holds no content; the witness holds no `agentId`/state.

## Task-assignment header (embed verbatim)

When spawning or resuming a member, embed this self-contained header at the top of the prompt (it replaces the old "Teammate Rules" block; the lead substitutes `{WITNESS_PATH}`, `{WITNESS_NONCE}`, `{role-slug}`, and `{round/phase}` (the concrete round number `N` or phase name) per (member, round/phase) — `{role-slug}` and `{round/phase}` appear in the sentinel and the temp-file template below, not only `{WITNESS_PATH}`/`{WITNESS_NONCE}`):

> "**Role**: <your role/scope>. **Round**: <N> (Round 1 = draft; Round 2+ includes peer findings, quoted below). **Inputs** (load-bearing — act only on what is supplied here; you do not share the lead's conversation): <inputs>. **Witness (MUST)**: your result is delivered by a durable witness file, not by your return text. Build your **entire** round product followed by the exact last line `<!-- cc-witness: {role-slug} {round/phase} complete {WITNESS_NONCE} -->` in a single hidden temp `T=$(mktemp \"$(dirname {WITNESS_PATH})/.{role-slug}.{round/phase}.XXXXXX\")`, then as your **final action before returning** publish it atomically with `mv -n \"$T\" {WITNESS_PATH}`. Echo `{WITNESS_NONCE}` verbatim; never overwrite an already-published witness. **Return contract**: your return text is only an early-wake hint — begin it with your role and round; the witness is the result. Never return without publishing the witness; if you cannot proceed, publish a witness containing your partial result plus a one-line concrete blocker (still sentinel-terminated)."

## Per-skill parameter seam

The contract above is defined **once** here. Each SKILL.md supplies only its **parameters**: the `cc-team-witness-<slug>` scratch-dir `mktemp` invocation and which rounds / phases are witnessed (e.g. `design` marks its fidelity / walkthrough / refinement phases witnessed; `design-analyze` carries `scratchDir` in its `work.json` `"ledger"` rows). No skill inlines or paraphrases the contract — all six Read this file, so there is no duplicated copy to drift (and no new lint phrase / PAIR is introduced).
