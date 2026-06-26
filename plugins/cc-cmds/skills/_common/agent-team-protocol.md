# Agent Team Protocol (Shared Rules)

Shared orchestration contract for multi-agent team workflows (`design`, `design-lite`, `design-analyze`, `design-apply`, `review`, `review-lite`). A team member is a **nameless background task**: the lead spawns it with `Agent` (`subagent_type: "claude"`, **no `name`**, `run_in_background: true`), resumes it across rounds by its `agentId`, and the task **self-terminates** when it returns.

A returning task delivers its round product two ways at once: a **durable witness file** the member writes before returning, and the **ephemeral return text / background completion notification**. The witness is the **authoritative source of truth**; the notification and return text are demoted to **early-wake hints**. This split is load-bearing: the completion notification is a push channel empirically dropped / duplicated / mis-routed by upstream harness bugs, and the returned `agentId` cannot be status-polled (`TaskGet` on a returned background `agentId` answers "Task not found"). If the lead trusted the dropped channel it would either park forever waiting for a finish notice that never arrives, or — worse — synthesize a round product it never observed (fabrication). The witness closes both holes: the lead reconciles against on-disk bytes the member alone wrote, never against a notification.

## Spawn

Spawn each member as a nameless background task: `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. A task does **not** share the lead's conversation — embed everything load-bearing into the prompt (role, round, all inputs the member must act on, plus the witness parameters below). Record the returned `agentId`, the member's `scratchDir`, **and its `outputFile`** (the `output_file` path the spawn envelope exposes) in the ledger immediately, with the same immediacy (see **Role↔agentId ledger v3**). Spawns are synchronous calls: a spawn error is returned inline and handled inline (no dispatch-failure bound needed).

Before spawning the first member of a team, the lead creates one team witness directory **out-of-tree**:

```
WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-<slug>.XXXXXX")
```

Out-of-tree placement makes the two-command boundary gate (`verification.md` §6: main `git status --porcelain` == baseline ∧ `git worktree list --porcelain` == baseline) self-evidently satisfied — even in a user project where `docs/` is tracked, the witness adds **0 surface** to `git status`. Each **fresh** team (the `design` Step-5 walkthrough team, the Step-6 refinement team) gets its **own** nested `mktemp -d` directory, anchored per-row in the ledger (see **Role↔agentId ledger v3**) so it survives compaction.

## Witness file (member-written, durable, atomic publish)

- **Layout — per-member-per-round separate files.** `${scratchDir}/{role-slug}.round-N.md` for discussion rounds; `${scratchDir}/{role-slug}.{phase}.md` for phase work (fidelity / walkthrough / refinement). A shared single append log is **FORBIDDEN** — parallel members appending to one file in the same round interleave and corrupt it. Separate files shrink the racing-writer surface to a single `(role, round)` path (torn writes are confined to the same-member zombie-vs-respawn axis; cross-member and cross-round collisions are eliminated).
- **Write discipline (MUST).** Build the full round product **plus the trailing sentinel** in a **single hidden per-attempt temp**:

  ```
  T=$(mktemp "${scratchDir}/.{role-slug}.{round/phase}.XXXXXX")
  ```

  (same directory → same-filesystem rename atomicity; the temp has no `.md` suffix and a leading dot, so it is hidden from the default glob and never appears in the `{role-slug}.{round/phase}.md` key list). Then, as the **final action before return**, publish atomically:

  ```
  mv -n "$T" "${scratchDir}/{role-slug}.{round/phase}.md"
  ```

  `mv -n` (no-clobber) gives **any-winner-is-a-valid-completed-witness**, but its safety is **not** from atomic no-clobber — `mv -n` is stat-then-rename on both BSD and GNU, so a same-round zombie-vs-respawn pair can race the same target and the later `rename(2)` may replace the earlier one. The 2-part guarantee is instead: (1) whichever rename lands, the published file is a **same-nonce completed** product (both contenders share the per-(member, round/phase) nonce and a sentinel-terminated temp), so the reader always observes a valid completed witness for that `(member, round/phase)` — never a torn or stale one; and (2) **no temp is ever self-deleted** — on a name collision `mv -n` skips the rename and leaves the **losing** temp in place, and a member `TaskStop`-ed mid-write likewise leaves its in-progress temp behind; both kinds of leftover temp are swept by teardown. Such an orphan `.{role-slug}.{round/phase}.*` temp in an abort-preserved `scratchDir` is harmless — floor-read and recovery only ever look at the non-temp key path (`{role-slug}.{round/phase}.md`).
- **Sentinel + nonce.** The last line of the published file is the sentinel carrying the lead-injected per-(member, round/phase) nonce:

  ```
  <!-- cc-witness: {role-slug} {round/phase} complete {nonce} -->
  ```

  The lead generates `{WITNESS_NONCE}` per **(member, round/phase)** with a Bash CSPRNG — `openssl rand -hex 8` (or `head -c8 /dev/urandom | xxd -p`) — and injects it into the task-assignment header alongside `{WITNESS_PATH}`. **LLM self-generation of the nonce is forbidden** (low-entropy / predictable defeats forgery defense; unlike the `mktemp`-derived `{WITNESS_PATH}`, the nonce needs a separate real-entropy call). The member echoes the injected nonce verbatim into the sentinel. Because the nonce is per-(member, round/phase) and unforgeable, a member that quotes a generic sentinel literal in its body cannot produce a body line that false-passes the completion predicate.
- **No same-round rewrite.** A published witness is **never** overwritten by the contract: a revision is a new round (a new file). The only writers that can ever target an already-published path are a same-round zombie + its respawn, and both emit the **same-nonce completed** product — so even if a late `rename(2)` lands, the bytes the lead synthesizes from remain a valid completed witness for that `(member, round)` until audit time. (The path is not byte-immutable; the _completeness and nonce-validity_ of whatever bytes are there is the invariant.)

## Completion predicate `witness_present(member, round/phase)`

Holds **iff all three conjuncts hold**:

1. `test -f {WITNESS_PATH}` — the non-temp `(role, {round/phase})` key file exists (fast pre-gate).
2. The file's **last non-empty line** (strip trailing blank lines / newlines before comparing) == `<!-- cc-witness: {role-slug} {round/phase} complete <nonce> -->`. This catches an **incomplete-tail** write (a torn or sentinel-less file lacks this line and fails). It does **not** distinguish a discipline-compliant atomic publish from a completed direct-write ending in the same sentinel — the on-disk bytes are identical — so fail-closure against a _completed_ direct-write rests on the member's temp+`mv -n` discipline (the header MUST), not on this conjunct; the lead cannot verify that discipline from the published bytes. (Trailing-blank tolerance avoids a false-negative respawn from a stray final newline.)
3. The filename's `{round/phase}` key == the sentinel's `{round/phase}` key (key consistency — `round-N` matches `round N`, a phase name matches itself) **AND** the sentinel's nonce == the lead-injected per-(member, round/phase) `{WITNESS_NONCE}`.

Existence alone is necessary but **not** sufficient — the sentinel makes the predicate **fail-CLOSED on a write-discipline slip** (existence-only would read a torn direct-write as complete → fabrication, i.e. fail-OPEN). The gate reads **only** this specific key path and its last line; it **never** references the notification, the return text, or `agentId` identity.

## Completion signal (hints only)

The background completion notification and the resume tool result are **early-wake hints** — they tell the lead *when to go look*, never *what was produced* and never *that a round is done*. Do not look for `[COMPLETE]`/`[IN PROGRESS]` prefixes or session-text echoes — they do not exist in this model. Round completion is established **only** by `witness_present(member, round/phase)`.

## Multi-round (resume + context re-injection)

A one-shot isolated `Agent()` per round is forbidden — the retained-context, multi-round cross-review/convergence loop is what makes this a *team*. Drive at least **2 rounds** (Round 1 = produce; Round 2+ = cross-review with peer findings). Resume a member by sending to its `agentId` (`SendMessage` to the agentId continues the task with its context intact). On every resume, the lead **re-injects the load-bearing context** — do not trust retained context for load-bearing data; quote peer findings **verbatim**. Re-injection is belt-and-suspenders: resume reliably recalls prior rounds, but a verbatim re-inject keeps the round robust against drift.

## Convergence

Convergence is by **witness collection**, not live polling. After cross-review, resume each member once with a convergence prompt (re-inject current consensus + open conflicts); a member's round is converged-and-collected only when its round witness is `witness_present`. Batch the resumes; keep one large resume per member per round and cap rounds to the minimum the discussion needs.

## Reconcile ladder (witness-absent re-entry)

- **Disk-first check before respawn.** On entering a round-N reconcile (and on every cross-session re-entry / `state=running` residual scan), the **first** action is a floor-read of that member's witness. If it is already `witness_present`, treat it as done and consume it — **no respawn, no re-entry count** (this absorbs a notification that landed between the member's return and the ledger flip across a compaction).
- **Liveness acquisition (byte-count only, never content).** A member's liveness signal is the byte-size of its harness `output_file` — the path is the durable `outputFile` ledger column recorded at spawn (a symlink to the member's JSONL transcript). Read the **size only**, never the content:

  ```
  current_bytes=$(wc -c < "$OUTPUT_FILE" 2>/dev/null) || current_bytes=UNAVAILABLE
  ```

  Availability is judged by **exit status, not by the value**: exit 0 + integer = available; nonzero exit (path absent / dangling symlink / EACCES) = `UNAVAILABLE`. The lead **never** `cat`s or Reads `$OUTPUT_FILE` (that would overflow context). `wc -c` is the normative portable form; `stat -L -f '%z'` (BSD) / `stat -L -c '%s'` (GNU) are `lint-bash-portability`-divergent idioms and, if used, require a same-line `# lint-bash-portability: disable=…` suppression.
- **Tri-state liveness verdict (ALIVE / WEDGED / UNKNOWN).** After the disk-first witness floor-read fails, compute the verdict from `(availability, current_bytes vs durable lastBytes)`. The durable `stallMark` block holds `{reentryCount, lastBytes, lastBytesPathTag, unavailStreak, emptyStreak}`; `lastBytes` is read against `lastBytesPathTag` (the `outputFile` path the baseline was read from) — on every read, `lastBytesPathTag ≠ current outputFile` ⇒ `lastBytes := ∅` (this cycle is un-baselined: a respawn's new path self-invalidates the baseline; a same-path compaction preserves it).
    - **ALIVE** — available ∧ (`current_bytes > lastBytes`, or `lastBytes = ∅` warmup): progress. Reset `reentryCount = 0`, `unavailStreak = 0`, `emptyStreak = 0` (reaching available clears the ∅/vanished conditions), set `lastBytes = current_bytes`. **Death cannot fire.**
    - **WEDGED** — available ∧ `current_bytes == lastBytes`: no progress. `reentryCount += 1` (monotone, persist-before-next-read), `unavailStreak = 0`, `emptyStreak = 0`. Persist the row atomically.
    - **UNKNOWN** — `UNAVAILABLE`: liveness indeterminate. Do **not** touch `reentryCount`. **Precedence: #55 wins — unavailable ≠ wedged ⇒ ask, never auto-kill.** **K (the `reentryCount` threshold) is a WEDGED-death-only gate; UNKNOWN escalation is K-independent** — an UNAVAILABLE member can never reach WEDGED and so never accumulates `reentryCount` (in particular an ALIVE→vanish trajectory resets `reentryCount` to 0 before vanishing, so it never reaches K), and K-gating UNKNOWN would deadlock. UNKNOWN splits (per the S8 rule below) into `non-∅ + stat-fail` (vanished) and `∅`, each escalating on its own debounce streak independently of K.
- **Death verdict** = all three: (i) durable `reentryCount ≥ K (=3)` — _a floor on attempts, not a sufficient condition on its own_; (ii) the **current** verdict is WEDGED (available + byte-stable — a past K accumulated under a signal since lost does not count); (iii) a FINAL `witness_present` re-check, **atomically adjacent to the `TaskStop`**, is still absent. **Growth always holds a veto**: any ALIVE read resets `reentryCount` to 0. The old `output_file absent → death` arm is **removed** — an absent/dangling signal is UNKNOWN, never a death vote.
- **last_output_bytes is durable + path-tagged.** `lastBytes` and its companion `lastBytesPathTag` are durable and written **together** in the atomic `stallMark` block. A torn `{tag←new, lastBytes←old}` would manufacture a one-shot cross-file false WEDGED; its indivisibility rests on the lead being single-threaded between tool calls, so no compaction interleaves a single-Edit row write (the design's residual item R3 tracks this execution-model premise). The baseline thus self-invalidates against respawn (new path → tag mismatch → ∅, no cross-file comparison) and survives a same-path compaction (WEDGED stays observable → K stays reachable).
- **Field durability classification.** Durable `stallMark = {reentryCount, lastBytes, lastBytesPathTag, unavailStreak, emptyStreak}` (5 fields) lives in the ledger row; only `current_bytes` is **lead-LOCAL ephemeral** (recomputed from `outputFile` each re-entry, never stored in `stallMark`). **Both escalation debounce counters (`unavailStreak`, `emptyStreak`) are durable** for the same reason as `reentryCount`: if ephemeral, a persistent `UNAVAILABLE`/`∅` under frequent compaction would re-zero them every cycle and the threshold (2 / M) would never be reached — escalation (ask) would never fire and the member would park forever; durable, the threshold accumulates across compactions and always terminates in an ask (fail-toward-ask). **Why an ephemeral baseline fails (infinite resurrection):** with a durable counter but an ephemeral baseline, a compaction wipes `lastBytes` to ∅ while `reentryCount` survives; the next re-entry then sees `lastBytes = ∅` → ALIVE-by-default warmup → resets `reentryCount` to 0. If compaction outpaces K accumulation, every cycle re-zeros and a wedged member never reaches K — #54's infinite park recurs as infinite resurrection. The counter and the baseline must therefore share one durability class.
- **Death → same-round respawn.** `TaskStop(agentId)` → respawn into the **same round** (round counter NOT incremented; same `{WITNESS_PATH}`, same `{WITNESS_NONCE}`, inputs re-injected — the nonce is per-(member, round/phase) so the respawn reuses the same value, and a surviving zombie + the respawn racing the same no-clobber target with the same nonce both yield a same-nonce completed witness whichever wins → any-winner-is-a-valid-completed-witness determinism). A respawn is a **new** background agent with a new `agentId` and a new `output_file`, so on respawn **update the ledger row's `agentId` and `outputFile`** and **reset the whole `stallMark`** (`reentryCount = 0`, `lastBytes = ∅`, `lastBytesPathTag = ∅`, `unavailStreak = 0`, `emptyStreak = 0`). `lastBytes = ∅` forces the first post-respawn read to ALIVE-or-UNKNOWN (never WEDGED), so the dead agent's frozen final byte-count cannot false-kill the healthy respawn. Soft signals (`output_file` growth, early-wake) are acceleration hints, not the gate.
- **S8 — `outputFile = ∅` spawn-race distinction.** An `outputFile` still `∅` (the harness has not populated the path yet) differs from "a path that existed and vanished" (both `stat`-fail). UNKNOWN splits accordingly: **`∅` ⇒ abstain + a separate ∅-tolerance ceiling** — increment durable `emptyStreak += 1` (and set `unavailStreak = 0`, ending any vanished run); at `emptyStreak ≥ M` escalate via `AskUserQuestion` (preventing infinite park on a host whose `output_file` is never populated — fail-toward-ask). **`non-∅ + stat-fail` (vanished) ⇒ durable `unavailStreak += 1`** (and set `emptyStreak = 0`, ending any ∅ run); at `unavailStreak ≥ 2` (consecutive debounce) escalate, K-independently (an ALIVE→vanish trajectory resets `reentryCount` before vanishing, so K is unreachable and would otherwise park). Both streaks are **strict-consecutive** (entering one sub-state zeros the other), so an ∅↔vanished oscillation cannot over-accumulate. M is the R1 tuning constant of the design's residual items.
- **Respawn also dies → Case 2 (never-returns).** `AskUserQuestion` menu = {① respawn into the same round again / ② **keep waiting** — re-enter after an additional grace period (always floor-read the witness first); added because UNKNOWN is positive evidence the member is alive, so a human may reasonably choose to wait / ③ annotate the missing member explicitly and partial-synthesize from the remaining witnesses (an explicit absence record, not fabrication) / ④ abort the workflow}. Per the happens-before gate, the chosen option gates round N+1: ③ closes round N as partial and proceeds to N+1, but the missing member's ledger row is set to `aborted` (it was `TaskStop`-ed), **not** `done`, and its last-return records the explicit absence annotation (a witness-less `done` violates the anti-fabrication rule and is forbidden). An `aborted` row does **not** re-enter the `state=running` residual scan, so a witness this member publishes _after_ the abort is intentionally never consumed — the partial close is final, and the N+1 absence annotation is authoritative even if a late witness later appears on disk (this is a conservative under-claim, never a fabrication).

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
- **Case 2 — Never-returns** (binary, not a counter): the death verdict of the reconcile ladder holds (a WEDGED verdict — available + byte-stable `output_file` — sustained to `reentryCount ≥ K` with the FINAL adjacent `witness_present` re-check still absent). An `UNAVAILABLE` `output_file` **never** votes for death; it routes to the K-independent debounced-ask escalation (`unavailStreak ≥ 2` / `emptyStreak ≥ M`) instead. The recovery is `TaskStop` + same-round respawn; a respawn that also dies routes to the single 4-option `AskUserQuestion` menu in the reconcile ladder above (no separate menu is defined here).
- **Case 3 — Non-conforming witness** (routing rule, not a bound): the witness is present but off-contract (spec-violating / malformed content above the sentinel). It is not caught by a counter (the witness published) — cross-review and the Step-4 fidelity pass catch it. The lead re-assigns once; a recurrence feeds the Case 1 counter.

"Reasonable bound" for never-returns is the durable-`reentryCount`-plus-WEDGED-verdict death predicate — no wall-clock constant (a long-running scope, e.g. a deep audit, is legitimate, and a growing `output_file` reads ALIVE and resets the counter). The durable `stallMark` makes the bound survive compaction (the count is never silently re-zeroed), while an `UNAVAILABLE` signal escalates to a K-independent debounced ask rather than a kill. Surface to the user (`AskUserQuestion`) only on a Case-1/Case-2 threshold or explicit user instruction — never on wall-clock time, lead confidence, or lead opinion alone.

## Role↔agentId ledger v3

The model is roster-less, so an in-context list of agentIds evaporates on compaction with no fallback. Persist a **durable ledger** co-located with each skill's existing artifact:

- **design / design-apply / review / review-lite**: an HTML-comment block at the top of the output document (right after the H1, before the first `##`): `<!-- cc-design-ledger v3 … -->`. A visible `##` section is forbidden (it would collide with walkthrough/implement/design-review heading parsers and would leak opaque agentIds into the user-facing doc). The doc is created as an **early stub** (title + ledger block) at spawn time, before Step-4 save.
- **design-analyze**: a `"ledger"` key in the existing `.{slug}.work.json` (already machine-only) holding the same per-row data.

Each ledger entry is **behavior-bearing**, with a **per-row `outputFile`** and **`stallMark`** added in v3 (on top of v2's `scratchDir`):

```
agentId | state | round/phase | role/scope (1 line) | thinReturns | last-return summary | scratchDir | outputFile | stallMark
```

where `state ∈ {running, done, aborted}`, `outputFile` is the member's harness `output_file` path (the liveness-signal source), and `stallMark = {reentryCount, lastBytes, lastBytesPathTag, unavailStreak, emptyStreak}` is the durable death-predicate state (see the reconcile ladder). Update it on every state change.

- **Immediate record.** `scratchDir` is written into the row at spawn time with the **same immediacy as `agentId`** (the recording window is the existing agentId-recording window — no new exposure window).
- **Derive-from-ledger, never re-`mktemp`.** Every resume and every post-compaction re-entry derives `WITNESS_DIR` from the row's `scratchDir`. Re-running `mktemp` would create an empty directory, orphan the in-progress witness, and reopen the fabrication hole. **Re-read the ledger from disk on entering any phase that resumes a task** (Step-4 fidelity pass, Step-5, Step-6) — do not trust in-context copies. If the block is missing/unparseable, or a `state=running` row has no `scratchDir` or one whose path is not on disk, **fail closed via `AskUserQuestion`** (never silent-skip). A residual `state=running` row is also the leftover-detection signal (it replaces the removed `teams/` filesystem scan).
- **Transient.** `scratchDir`, `outputFile`, and `stallMark` are meaningful **only** while a row is `state=running` (the compaction / workflow-abort recovery window). On **normal workflow completion** all three are **per-row stripped from every terminal row** (`done` and `aborted` alike), together with the directory `rm -rf` (see `_common/team-cleanup.md`). The cleanup axis is the **workflow result**: preservation applies only to a **workflow-level abort**; an individual `aborted` row is still stripped if the workflow completes normally. A committed document from a normally-completed workflow therefore carries these three on **0** rows → no macOS TMPDIR-hash (UID-derived) / session-path / stale-counter leak into version control, no staleness.
- **Durability vs terminal-strip are orthogonal axes.** A field is **durable** (compaction-surviving mid-workflow) iff its loss would make a decision _unbounded_ (infinite park / resurrection) or _unsafe_ (false-kill / fabrication) — so the whole `stallMark` (`reentryCount` and the two debounce streaks included) is durable, reversing v2's "the ledger deliberately omits counters" stance, which conflated durability with strip. A field is **terminal-stripped** iff retaining it in a committed document would leak (TMPDIR-hash / session path / stale counter). The two are independent: `stallMark` is **both** durable (survives compaction while running) **and** stripped (removed from terminal rows on normal completion).

## Witness vs ledger (two artifacts, clean separation)

| Artifact | Records | Author | Location | Lifetime |
| --- | --- | --- | --- | --- |
| **Ledger** (`cc-design-ledger v3` / work.json `"ledger"`) | STATE + per-row transient `scratchDir`, `outputFile`, `stallMark` | **lead** | in-tree | whole workflow |
| **Witness** (`${scratchDir}/{role-slug}.{round/phase}.md`) | CONTENT (full product, sentinel-terminated) | **member** (sole, atomic rename) | `${TMPDIR:-/tmp}` (system temp dir), out-of-tree | deleted on normal workflow completion (all terminal rows); retained on workflow-level abort |

Order (MUST, = the happens-before gate): `witness_present` → lead READs the content → lead fills the ledger row `done` + last-return **from the witness content**. The ledger holds no content; the witness holds no `agentId`/state.

## Task-assignment header (embed verbatim)

When spawning or resuming a member, embed this self-contained header at the top of the prompt (it replaces the old "Teammate Rules" block; the lead substitutes `{WITNESS_PATH}`, `{WITNESS_NONCE}`, `{role-slug}`, and `{round/phase}` (the concrete round token `round-N` (e.g. `round-1`) or phase name (e.g. `fidelity`)) per (member, round/phase) — `{role-slug}` and `{round/phase}` appear in the sentinel and the temp-file template below, not only `{WITNESS_PATH}`/`{WITNESS_NONCE}`):

> "**Role**: <your role/scope>. **Round**: <N> (Round 1 = draft; Round 2+ includes peer findings, quoted below). **Inputs** (load-bearing — act only on what is supplied here; you do not share the lead's conversation): <inputs>. **Witness (MUST)**: your result is delivered by a durable witness file, not by your return text. Build your **entire** round product followed by the exact last line `<!-- cc-witness: {role-slug} {round/phase} complete {WITNESS_NONCE} -->` in a single hidden temp `T=$(mktemp \"$(dirname {WITNESS_PATH})/.{role-slug}.{round/phase}.XXXXXX\")`, then as your **final action before returning** publish it atomically with `mv -n \"$T\" {WITNESS_PATH}`. Echo `{WITNESS_NONCE}` verbatim; never overwrite an already-published witness. **Return contract**: your return text is only an early-wake hint — begin it with your role and round; the witness is the result. Never return without publishing the witness; if you cannot proceed, publish a witness containing your partial result plus a one-line concrete blocker (still sentinel-terminated)."

## Per-skill parameter seam

The contract above is defined **once** here — including the full ledger v3 row schema, of which `outputFile` and `stallMark` are **protocol-owned columns**, not per-skill parameters. Each SKILL.md supplies only its **parameters**: the `cc-team-witness-<slug>` scratch-dir `mktemp` invocation and which rounds / phases are witnessed (e.g. `design` marks its fidelity / walkthrough / refinement phases witnessed; `design-analyze` carries the ledger in its `work.json` `"ledger"` rows). The five document-ledger skills now **point to this row schema** rather than re-typing the column list (the by-reference collapse), so the schema is genuinely 'defined once' and cannot drift. No skill inlines or paraphrases the contract — all six Read this file, so there is no duplicated copy to drift (and no new lint phrase / PAIR is introduced).
