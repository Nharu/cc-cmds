---
name: design-review-lite
description: 설계 문서 경량 사이클 리뷰
when_to_use: 설계 문서를 간결한 반복 사이클로 빠르게 검증하고 싶을 때 (미묘한 termination invariant·동시성 검출률 약화 가능)
disable-model-invocation: true
usage: "/cc-cmds:design-review-lite <design-doc-path> [--base] [--changes]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "리뷰 대상 설계 문서 경로 (`.md`)"
    - name: "--base"
      kind: flag
      default: "off"
      summary: "기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT)"
    - name: "--changes"
      kind: flag
      default: "off"
      summary: "이미 리뷰된 문서의 수정 사항으로 리뷰 초점 이동: 파급 정합성 + 변경 자체 재질의 (CHANGES MODE CONSTRAINT). `--base`와 직교·조합 가능"
---

<!--
Drift contract — INLINED CONTENT MAINTENANCE NOTE
This SKILL.md inlines content that lives as separate files under the base
`design-review/references/` directory. When the base updates one of those
files (semantic intent only, not minor wording), update the inline copy here
in the same change. Sync responsibility:
  - file-schemas (outer_log / ack_items / convergence_table)  → Phase 1 init blocks
  - review-agent prompt                                       → Phase 2 Step 12 prompt
  - severity exit policy / 4-tier note                        → Phase 2 Step 14 note
  - Korean UX templates (§3.9.4.a/b/c, §3.9.2, §3.9.4.e)      → Phase 2 Step 16 / Step 24 / Step 25 / Phase 3
  - CFI advance-ordering + observed-result invariants         → Control-Flow Invariants top subsections
  - Options blocks (### --base / ### --changes mode-constraint text) → ## Options section
The phrase-presence rule in `scripts/lint-skill-invariants.sh` enforces sync
on termination-contract phrases only (CI fail-fast). Other inlined content
relies on human review.
-->

Perform a lightweight final review of the design document using a two-tier cycle (outer + inner) with sonnet-only review agents.

All analysis work and inter-agent communication should be in English to optimize token usage.
User-facing communication (summaries, questions, status updates) should be in Korean.

This skill is the lightweight sibling of `design-review`. It trades depth for predictable token cost: outer cap = 2 (vs base 5), inner cap = 6 (vs base 20), every review agent is sonnet (no haiku, no opus), the auto-decide protocol is fully dropped (every `decision`-type proposal escalates to the user), and the `references/` files are inlined so no extra Read call fires per round. Use `design-review` when subtle invariants — concurrency, termination math, or auto-decide ripple verification — matter more than speed.

## Overview

This command wraps an inner severity-saturation review loop in an outer cycle. Each outer iteration spawns a **completely fresh** inner loop against the current document state with a cleared `INNER_TEMP_DIR`, preserving only the user-persistent `ack_items.md` and the design document itself. This prevents the "context poisoning" where long inner loops drift from re-confirmation toward rebuttal, while still letting ack items ratchet across iterations.

The outer cycle exits when an inner iteration reaches `clean-convergence` (severity + saturation rule below) AND no escalation was actually applied during that iteration (`COUNT_APPLIED == 0`).

## Review Criteria

Requirement consistency, internal coherence, feasibility, implementation order, missing items, and any other perspective important in the context of this specific design.

---

## Control-Flow Invariants

These formulas govern termination and classification. They MUST remain inline (not in a separate file) because SKILL.md has post-compaction re-attachment priority (first ~5K tokens) while a separate file's read may be summarized away. A summarized invariant yields silent mis-termination.

#### Round/iteration advance ordering (no look-ahead spawn)

The inner loop's correctness rests on a happens-before ordering between adjacent rounds and adjacent outer iterations — NOT on any turn count. It binds at exactly two boundaries and nowhere else:

- **Round boundary**: the main session MUST NOT spawn round N+1's review `Agent()` until round N's resulting Edits are on disk. A review agent reads the document on spawn; if round N+1's agent spawns before round N's edits have landed, it reviews stale text and every proposal it returns is grounded in a document state that no longer exists. **ASYNC enforcement**: a synchronous round blocks this structurally, but an async spawn returns its envelope immediately, so the ordering is prose-enforced in the async case — confirm round N's witness → record round N → round N's Edits land on disk → only then `inner_round += 1` and spawn round N+1; never batch round N+1's spawn with round N's recording. Do NOT relax this ordering or recompute the round number at write-time — the round number is pinned by the main session at spawn as {round} = inner_round (unchanged on a same-round respawn), so a respawn re-runs the SAME N by injection, not by agent-side derivation; relaxing the ordering silently breaks both the round-N witness gate in Step 12.detect AND the first-round-N-witness-wins dedup, which both assume a same-round respawn lands on the SAME N.
- **Iteration boundary**: the main session MUST NOT initialize iter K+1's `INNER_TEMP_DIR` (Step 7) until iter K's per-iteration summary work (Steps 17–21 — `COUNT_APPLIED`, ack extraction, table/log rows, and the `INNER_TEMP_DIR` wipe) has completed against the agent results actually observed in iter K.

This ordering is scoped to the spawn/init boundary ONLY. It deliberately does NOT constrain intra-round activity: one round may issue many tool calls in a single turn (self-triage, reference Reads, batched auto-approve Edits, AskUserQuestion fan-out), and one round may span multiple turns (the dialogue loop on an escalated proposal runs across several turns, all still inside round N). The "batch independent edits in one message" practice stays fully valid for those intra-round Edits — but it does NOT apply across a round/iteration boundary, because round N+1's input IS round N's applied output and the rounds are therefore not independent units of work. The one forbidden move is forward progress across a boundary on unobserved upstream work: there is no look-ahead spawn — never spawn the next round's agent before this round's edits are on disk, and never open the next iteration before this iteration's summary work is done.

#### Observed-result precondition (anti-fabrication — hard fail-closed gate)

This precondition is independent of the ordering rule above and is NOT waivable under any time, batching, or economy pressure. The main session MUST NOT write any round-N record — disposition tag (`[APPROVED]` / `[MODIFIED]` / `[USER-DIRECTED]` / `[AUTO-APPROVED]` / `[AUTO-REJECTED]` / `[REJECTED]`), `COUNT_APPLIED` input, `INNER_EXIT_REASON == "clean-convergence"` (or any convergence verdict), convergence-table row, ack delta, or `## Outer Iteration N` outer_log entry — unless round N's review Agent() actually returned and that return was observed at some point during round N. The on-disk round-N proposals and round summary are the persisted PRODUCT of that observed return (carrying grounding across turns for deferred dispositions); they are NOT themselves the grounding, and neither may be authored by the main session to manufacture grounding.

Decision procedure before writing any round-N record: "Did I actually spawn round N's agent and observe its return at some point during this round?" If you cannot affirm a real observed return — or you are uncertain — **fail closed**: do not record, do not count, do not declare convergence; instead spawn (or re-spawn) the agent, wait for its real return, then write. Re-spawn is the cheap safe direction (a redundant fresh review only costs tokens; a fabricated record corrupts termination). A convergence verdict or `COUNT_APPLIED` tally is a factual claim that specific agent work happened; writing one for a round whose agent never spawned or never returned is fabrication and is absolutely forbidden. (The deferred-disposition case is explicitly fine: round N's agent really returned and its proposals are on disk; finalizing those dispositions turns later after the user decides is grounded, not fabricated.)

**Branch-specific grounding of "observed" (detect-branch hybrid).** "returned" in this gate means an *inline return* (SYNC) or a *confirmed round-N witness* (ASYNC), and the evidence differs per branch:

- **SYNC** — an inline tool result carrying a `<usage>…duration_ms…</usage>` envelope-tail signature AND no `output_file:` / `Async agent launched successfully.` marker **in the envelope** (the header/marker lines, never agent body text — the same tokens appearing in body prose never count). Both halves are envelope-anchored, symmetric with the ASYNC marker match. Structural observation: the recording block is unreachable without the inline return.
- **ASYNC** — the agent-authored, round-N-keyed `## Review Round N` round-summary witness in `review_log.md` — written by the spawned agent, NOT by the main session and NOT a drop-prone notification. The single trustworthy completion primitive is this **round-N summary line in review_log.md**; in-file round-N keying is the sole completion check — no external status-query mechanism substitutes for it.

**ASYNC stall liveness (witness-absent respawn — tri-state).** Per ASYNC spawn, the witness-absent control point in Step 12.detect maintains a **durable** stall-state file `$INNER_TEMP_DIR/.async_stall.json` (leading dot = machine-internal; wiped wholesale by the Step 21 `INNER_TEMP_DIR` teardown, so it never touches VCS and needs no terminal strip). Schema: `{schema, inner_round, output_file, last_output_bytes, reentry_count, growth_streak, unavail_streak, lostwrite_respawn_count}` — `schema` is a strict-equality migration guard pinned to the literal `2` (any value other than `2` ⇒ discard and re-initialize; adding `lostwrite_respawn_count` bumped the pinned value to `2`, so a pre-bump file re-initializes with `lostwrite_respawn_count` born at 0; active-notify v1.5.0 helper precedent). **One durability class**: every counter AND the byte baseline live in this one file, whole-written each re-entry and re-derived from disk on the next — no counter is context-local, so the "durable counter + ephemeral baseline ⇒ infinite resurrection" failure mode is structurally impossible across compaction. The whole-file write is torn-write-safe under this threat model: `.async_stall.json` has a single main-session writer with no concurrent peer (unlike the review agents' proposals file), so a partial write can arise only from a main-session crash mid-write, and the next re-entry's `schema`-guarded re-read discards any malformed content and re-initializes — no reader ever consumes a torn state.

**Initialization / reset (three points).** (i) On each spawn and each round-advance: if the file is absent OR its `inner_round` ≠ the current round, re-initialize — `reentry_count=0`, `growth_streak=0`, `unavail_streak=0`, `lostwrite_respawn_count=0`, `last_output_bytes=∅`, `output_file=<fresh>`, `inner_round=<current>` (a prior round's stall observations are discarded at the round boundary). (ii) On any same-round respawn (the file exists and `inner_round` already matches, so (i) does not fire) — every point that spawns a fresh agent in the same round: the death-gate respawn, the lostwrite recovery respawn (fail-closed READ arm), and the `malformed-async-suspected` respawn (the head is universal — an open list, so any newly-added same-round respawn point is covered automatically): explicitly zero the three stall counters (`reentry_count`/`growth_streak`/`unavail_streak`) and PRESERVE `lostwrite_respawn_count` (it is not a stall counter — only reset (i) zeroes it, at the round boundary), set `last_output_bytes=∅`, and record the respawned agent's fresh `output_file` — that `output_file` write happens AFTER Step 12.detect captures the respawn's `Agent()` envelope (the same post-capture point at which reset (i) learns the path), NOT at `TaskStop` time when the new path is not yet known (writing it earlier would store an as-yet-unknown path — a no-op that leaves reset (iii)'s reconcile comparing against the dead run's stale path). The fresh agent must inherit neither the dead run's stall counters nor its `output_file` baseline. (iii) Per re-entry path reconcile: if a freshly-captured `output_file` path differs from the stored `output_file` field, set `last_output_bytes := ∅` (a path change self-invalidates the baseline); the `output_file` field folds the path-tag role, so no separate field is needed. A pure post-compaction re-entry with no fresh path keeps the stored path as authoritative.

**Per re-entry, in order.** One re-entry = exactly one turn-yield-and-return cycle back to the witness-absent control point, regardless of trigger (notification early-wake, `output_file` mtime/size check, any later turn). (1) floor-read review_log.md — if the round-N witness is now present ⇒ observed-return, stop. (2) determine `output_file` availability and, if available, its byte-count `b` (apply the path reconcile above). (3) **classify tri-state** `(availability, b vs last_output_bytes)`:
- **ALIVE** — available ∧ (`b ≠ last_output_bytes` OR `last_output_bytes = ∅` warmup): `reentry_count = 0`, `unavail_streak = 0`, `growth_streak += 1`, `last_output_bytes = b`. Growth is an unconditional death veto.
- **WEDGED** — available ∧ `b == last_output_bytes`: `reentry_count += 1`, `unavail_streak = 0`, `growth_streak = 0`.
- **UNKNOWN** — `output_file` UNAVAILABLE (path absent / dangling): `reentry_count` unchanged, `unavail_streak += 1`, `growth_streak = 0`. **There is no `output_file absent ⇒ death` arm** — unavailability is not a death tally; a slow-but-live reviewer whose path is momentarily unreadable must not be killed. (An existing 0-byte `output_file` is *available*, NOT UNKNOWN — `stat` succeeds, so it classifies ALIVE on the warmup re-entry then byte-stable WEDGED thereafter, deliberately; UNKNOWN is `stat` failure only — a path never created or dangling — a categorically different signal from a 0-byte file.)
(4) whole-write `.async_stall.json`. (5) evaluate death; if not dead, yield (emit one Korean line).

**Declare the agent dead ⟺ ALL THREE conjuncts hold: `reentry_count ≥ K` (K=3) AND the current classification is WEDGED AND a FINAL re-confirmation (adjacent to `TaskStop`) finds the round-N witness still absent.** Growth always vetoes (an ALIVE classification zeroes `reentry_count`). On death → `TaskStop(agentId)` → respawn in the SAME inner_round (`inner_round` is NOT incremented, the round is re-run) with reset (ii) applied. **Never declare death on `reentry_count ≥ K` alone, and never restate this predicate in any form that omits the WEDGED conjunct** — dropping the byte-stability conjunct would let an actively-writing original be killed. That byte-stability conjunct now rests on a **single** ground — **(a) do not kill an active writer** — which holds regardless of how `review_proposals.md` is published; round-keyed atomic publish dissolved the former second ground (torn-write reopening), because a round-unique filename makes same-round and cross-round corruption structurally impossible.

**Escalation (never a kill; death stays gated by `reentry_count ≥ K`).** Two liveness anomalies escalate to the user instead of killing: **babbling** (`growth_streak ≥ G`, G=5 — the reviewer keeps writing but never publishes the witness) and **persistent UNKNOWN** (`unavail_streak ≥ U`, U=3 — the signal path stays unreadable). Both raise the existing inner safety-limit 3-option `AskUserQuestion` as a distinct trigger (Step 16) — no new option, no new `INNER_EXIT_REASON`; default recommendation **A: keep waiting** (growth and UNKNOWN are positive evidence of a live-but-slow agent). On option A, reset ONLY the triggering streak to 0 (`growth_streak := 0` for babbling / `unavail_streak := 0` for UNKNOWN) before returning to the wait loop — otherwise the durable streak stays at threshold and re-fires every re-entry (ask-storm); the death gate `reentry_count` is orthogonal and untouched. The reset reuses existing schema fields (no dynamic-threshold field), and the streak must re-accumulate to threshold before re-asking, giving a debounce equivalent to the canonical grace period.

**fail-closed (hard gate — both SYNC and ASYNC branches)** — never counted as observation: (1) a notification arrival (may drop / duplicate / mis-route; it never enters the predicate), (2) the existence of a round-keyed `review_proposals.r<N>.md` file — the filename identifies the round, but existence alone cannot prove an observed return (a partial write or a zombie write can create it); completion is proved solely by the round-N witness in `review_log.md`, (3) any record written while the round-N witness is absent. Conversely — a fail-closed READ arm, branch-neutral — **after an observed return** (a SYNC inline return OR the ASYNC round-N witness), if the round-N proposals file is absent, do NOT immediately treat it as a review of zero proposals: first consult the round-N witness's `Proposals created:` summary line (call its count N). If **N == 0**, this is a genuinely empty review — record a zero-proposal round and do NOT respawn (this branch terminates precisely because it does not respawn). If **N > 0**, the published proposals were lost — fail closed, re-read, and respawn in the SAME inner_round if still absent. This recovery respawn is itself a same-round respawn, so it applies the broadened reset (ii): zero `reentry_count`/`growth_streak`/`unavail_streak` and `last_output_bytes := ∅` for the fresh recovery agent (so an inherited `growth_streak` cannot prematurely trip babbling escalation), while preserving `lostwrite_respawn_count`. Because the respawn is injected `{round}` = `inner_round` (unchanged on a same-round respawn = N), it re-publishes `review_proposals.r<N>.md` and re-writes `## Review Round N` — restoring the lost round-N file rather than diverging to N+1. Non-progression is thereby resolved by the round-derivation injection, not by an upper bound. A bounded same-round respawn count then caps how many recovery attempts are made before escalating: maintain a durable `lostwrite_respawn_count` in `.async_stall.json` (reset to 0 at each round boundary via reset (i); it is NOT the Loop-1 `reentry_count`, which reset (ii) zeroes on every same-round respawn and which the growth veto would keep zeroing — so it could never accumulate). Guard each such respawn with a check-then-act predicate — the same form as the death gate's `reentry_count ≥ K`: if `lostwrite_respawn_count >= K65` (K65=3, a distinct constant from the death-gate `K`), do NOT respawn — escalate to the user via the Step 16 3-option prompt under its `lostwrite` reason variant, default recommendation **B** (start a fresh outer iteration — the lost round is not restorable in place, so further retry is likely futile); otherwise increment `lostwrite_respawn_count` and respawn. At most `K65` recovery respawns occur, and the escalation fires only once the budget is spent — and the reason line renders `{K65}` as the actual observed respawn count, so its retry-count claim stays honest without relying on the respawn total exactly equaling `K65`. On the user choosing retry (option A), reset `lostwrite_respawn_count := 0` for a fresh K65 budget (ask-storm debounce); option B → `INNER_EXIT_REASON = safety-limit-fresh-outer`, option C → `safety-limit-outer-terminate` (mapping unchanged, option count 3). Because the Step 8 seed is gone, the round-keyed file exists only when the agent actually published it, so an absent file after an observed return is always a lost write, never an empty review. On-disk artifacts are the persisted PRODUCT of an observed return, never authored by the main session to manufacture grounding. **Re-spawn is the cheap safe direction** holds in both branches.

**Sole anti-fabrication anchor (ASYNC).** There is no external completion cross-check, so the entire async anti-fabrication guarantee rests on one fact — **the `## Review Round N` round-summary header is authored ONLY by the spawned review agent** (it appends the header after completing its review). The main session injects `{round}` = `inner_round` into the spawn prompt but still does NOT author the header line itself, so supplying the round value does not make the witness forgeable. The main session's own `review_log.md` writes are disposition tags / informational markers (including the Step 16 escalation's `- Inner exit trigger:` flush line) and the `## Outer Iteration N` block — it never authors a `## Review Round N` header. If that sole-authorship breaks, the witness becomes forgeable.

### Inner convergence predicate

```
inner_converged_cleanly() =
    (consecutive_no_major >= 2)
    AND (pending_applies.md is empty — no ### PEND- headers between --- and EOF)
    AND (no [IN PROGRESS] dialogues)
```

Severity aggregation for `consecutive_no_major`:

```
# Count proposals emitted this round, using their FINAL severity
# (= initial agent severity + any [SEVERITY-UPGRADED] in this round).
# Disposition is IRRELEVANT: [APPROVED], [MODIFIED], [USER-DIRECTED],
# [AUTO-APPROVED], [REJECTED], [AUTO-REJECTED] all count if the proposal's
# severity is critical/major. (Note: severity is a property of the proposal
# itself, not its outcome.)
final_critical_or_major = |{p : p.severity (post-upgrade) ∈ {critical, major}}|

if final_critical_or_major == 0:
  consecutive_no_major += 1
else:
  consecutive_no_major = 0   # even a single approved major resets
```

**Critical rule**: severity is a property of the **proposal itself**, not its outcome. A `[APPROVED]` major proposal still counts toward `final_critical_or_major`. `consecutive_no_major` increments only when the round produces **zero** critical/major proposals — regardless of how many were resolved.

### Outer termination judgment (Step 22)

```
if INNER_EXIT_REASON == "safety-limit-outer-terminate":
    break outer loop → Phase 3                      # user explicitly aborted
elif INNER_EXIT_REASON == "safety-limit-fresh-outer":
    outer_done = false                              # bypass convergence judgment
elif INNER_EXIT_REASON == "clean-convergence" and COUNT_APPLIED == 0 and this_iter_verify_ran == 0:
    outer_done = true                               # fixpoint reached
else:
    outer_done = false                              # COUNT_APPLIED > 0 → another iter
```

**MIN_OUTER = 1**: even the first iteration may terminate if the fixpoint rule fires.

**`this_iter_verify_ran` (criterion #7)**: the count of `[VERIFY-RAN]` cat-1 verification self-runs that mutated the ledger this iteration — an **independent counter** kept OUT of `COUNT_APPLIED` and every itemize render. It adds one term to the predicate so a cat-1 self-run iteration forces one more outer iteration (a fresh-agent ripple-verify). Sourced from the `- [VERIFY-RAN] (별도 카운터, escalate 합 밖): {count}` line in this iteration's `## Outer Iteration N` block (computed from `review_log.md` before the Step 21 wipe; mandatory every iter — 0 when none). See "## Verification dimension (criterion #7)".

### `COUNT_APPLIED` aggregation (lite simplified — auto-decide not present)

```
(a) Collect all lines in $INNER_TEMP_DIR/review_log.md tagged
    [APPROVED], [MODIFIED], [USER-DIRECTED].
(b) Group by PROP-ID (e.g., PROP-R2-3).
(c) For each group: 1 per group (partial_apply markers at multiple locations
    count 1 per group).
(d) COUNT_APPLIED = sum of group counts.
```

### `escalate_applied` formula (reference-only — NOT used in lite)

The lite skill drops auto-decide entirely, so the outer-loop termination decision uses `COUNT_APPLIED` only. The formula below is preserved for contract parity with base and as a forward reference in case auto-decide is reintroduced. **Do NOT call it from the outer-loop logic in this skill.**

```
escalate_applied = count([APPROVED]) + count([MODIFIED]) + count([USER-DIRECTED])
                 − |partial_apply duplicates within group|
```

### Disposition tag set

| Tag             | 문서 변경 | escalate_applied (참조 전용) | Ack set |
| --------------- | --------- | ---------------------------- | ------- |
| `[AUTO-APPROVED]` | ✓         | ✗                            | ✗       |
| `[AUTO-REJECTED]` | ✗         | ✗                            | ✓       |
| `[APPROVED]`      | ✓         | ✓                            | ✗       |
| `[REJECTED]`      | ✗         | ✗                            | ✓       |
| `[MODIFIED]`      | ✓         | ✓                            | ✗       |
| `[USER-DIRECTED]` | ✓         | ✓                            | ✗       |

The `escalate_applied` column is reference-only (lite does not use this aggregation — see note above).

**Informational marker** (not a disposition tag; never counted; may appear alongside a disposition tag): `[SEVERITY-UPGRADED]`.

**Independent counter** (criterion #7; NOT a disposition tag, NOT in `COUNT_APPLIED`, NOT in any itemize render): `[VERIFY-RAN]` (Category `verification-bookkeeping`) — a cat-1 verification self-run that mutated the ledger. doc-change ✓ / escalate_applied ✗ / ack ✗ / outer-termination-guard ✓ (it adds the `this_iter_verify_ran == 0` term to the Step 22 predicate). The `지금 검증 실행` / `잔여 항목으로 기록` menu dispositions ARE `[APPROVED]`-class; `거부 (현재 유지)` is `[REJECTED]`-class. See "## Verification dimension (criterion #7)".

---

## Strategy

### Phase 1: Outer Session Setup

1. Read the full design document to verify existence and parseability.

2. Parse `$ARGUMENTS` to detect and strip `--base`. Create the outer-session directory and initialize files:

```bash
# --- Outer Session Isolation ---
COMMAND_NAME="design-review-lite-outer"

# Strip --base from arguments
ARGS_CLEAN=$(echo "$ARGUMENTS" | awk '{
  for(i=1;i<=NF;i++) if($i!="--base" && $i!="--changes") printf "%s%s", $i, (i<NF?" ":"")
}')

# Detect --base / --changes
BASE_MODE=false
CHANGES_MODE=false
for arg in $ARGUMENTS; do
  [ "$arg" = "--base" ] && BASE_MODE=true
  [ "$arg" = "--changes" ] && CHANGES_MODE=true
done

# USER_NOTE extraction (trailing free-text after doc-path token 1; positional, not a flag).
# Blank token 1 (doc-path) and print the rest. Always run; empty when no trailing note.
# Injected as {USER_NOTE} regardless of --changes: change focus when --changes, general review context otherwise.
USER_NOTE=$(echo "$ARGS_CLEAN" | awk '{$1=""; sub(/^ +/,""); print}')

# REPO_NAME extraction (document stem → repo basename → cwd basename)
REPO_NAME=$(echo "$ARGS_CLEAN" | awk '{print $1}' | xargs basename 2>/dev/null)
REPO_NAME="${REPO_NAME%.md}"
[ -z "$REPO_NAME" ] && REPO_NAME=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename)
[ -z "$REPO_NAME" ] && REPO_NAME=$(basename "$(pwd)")
[ -z "$REPO_NAME" ] && REPO_NAME="unknown"
REPO_NAME=$(echo "$REPO_NAME" | tr -cs 'a-zA-Z0-9_-' '_' | sed 's/^_//;s/_$//' | cut -c1-30)
REPO_NAME="${REPO_NAME%_}"

# Outer session ID & directory
OUTER_TS=$(date +%Y%m%d_%H%M%S)
OUTER_SESSION_ID="${COMMAND_NAME}_${REPO_NAME}_${OUTER_TS}"
OUTER_DIR="docs/_temp/${OUTER_SESSION_ID}"
mkdir -p "$OUTER_DIR"
```

3. Initialize the three outer-persistent files. Schemas are inlined here (canonical for this skill):

```bash
# outer_log.md header
cat > "$OUTER_DIR/outer_log.md" <<EOF
# Outer Cycle Audit Log

<!--
Session: ${OUTER_SESSION_ID}
Document: $(echo "$ARGS_CLEAN" | awk '{print $1}')
Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
BASE_MODE: ${BASE_MODE}
CHANGES_MODE: ${CHANGES_MODE}
USER_NOTE: ${USER_NOTE}
-->
EOF

# ack_items.md header
cat > "$OUTER_DIR/ack_items.md" <<'EOF'
# Acknowledged Items

_Items decided to keep as-is during this design-review-lite session. Do NOT re-propose._

---
EOF

# convergence_table.md headers (two tables — auto-decide column dropped)
cat > "$OUTER_DIR/convergence_table.md" <<'EOF'
# Convergence Tables

## 처리 결과 현황표

| 이터 | 라운드 | 자동승인 | 자동거부 | 에스적용 | 에스거부 |
| :--: | :----: | :------: | :------: | :------: | :------: |

## 수렴 진단표

| 이터 | 적용실패 | 부분종료 | ack수 |  종료사유  |
| :--: | :------: | :------: | :---: | :--------: |
EOF
```

Schema reference for ack_items.md (8-field record, dedup rule applied at Step 18):

```markdown
### From Iteration N

#### ACK-001

- **Source**: PROP-R3-2 (outer iter 1, inner round 3)
- **Disposition**: [REJECTED]
- **Category**: missing-items
- **Location**: Section 4.2 — Error Handling
- **Issue**: No retry policy specified for transient DB errors.
- **Reference text**: "On connection failure, return 500 to the client."
- **User rationale**: "..."
- **Recorded**: ISO8601
```

Use `User rationale` for `[REJECTED]` and `Auto-reject rationale` for `[AUTO-REJECTED]`.

Schema reference for pending_applies.md (initialized empty per inner iter):

```markdown
### PEND-001

- **Proposal**: PROP-R2-3
- **Intended disposition**: [APPROVED]
- **Target locations**: [section 4.1, line anchor "..."]
- **Change summary**: ...
- **Failure**: Edit old_string not unique — same phrase appears in 4.1 and 6.2
- **Attempts**: 1
- **Deferred at**: round 2, ISO8601
- **Next action**: Re-scope with disambiguating context in round 3
```

4. Initialize outer loop state: `outer_iter = 0`, `outer_done = false`. Proceed to Phase 2.

### Phase 2: Outer Iteration Loop

Loop while `outer_done == false`:

**Step 6 — Advance outer iteration**: `outer_iter += 1`

**Step 7 — INNER_TEMP_DIR**:

```bash
INNER_TEMP_DIR="${OUTER_DIR}/iter-$(printf '%03d' $outer_iter)"
mkdir -p "$INNER_TEMP_DIR"
```

**Step 8–9 — Empty inner files**:

```bash
cat > "$INNER_TEMP_DIR/pending_applies.md" <<'EOF'
# Pending Applies

_Edit operations deferred from their originating round. Must be empty for inner convergence._

---
EOF
```

**Step 10 — Initialize `review_log.md` with ack seed**:

```bash
{
  echo "# Design Review Log"
  echo ""
  echo "<!-- Outer session: ${OUTER_SESSION_ID}, outer iter: ${outer_iter} -->"
  echo ""
  echo "## Acknowledged Items"
  echo ""
  # Copy the body of ack_items.md (after the "---" separator) into this section
  awk '/^---$/{found=1; next} found' "$OUTER_DIR/ack_items.md"
  echo ""
} > "$INNER_TEMP_DIR/review_log.md"
```

The review agent prompt instructs it to read the `## Acknowledged Items` section and skip duplicates — no agent-prompt change is required for ack injection.

**Step 11 — Reset inner state**: `inner_round = 0`, `consecutive_no_major = 0`, `INNER_EXIT_REASON = null`.

---

#### INNER PHASE 2 LOOP

Perform agent-based iterative review until severity saturation. Each round spawns a **fresh** review agent that independently reviews the document from scratch.

**Step 12** — `inner_round += 1`. Spawn a review agent **with model `"sonnet"`** (lite contract — no haiku, no opus). **Pass `run_in_background: false` as a request** (a session that honors it reaches the SYNC branch; a host that ignores it lands in the ASYNC branch — see Step 12.detect after the prompt), keeping the `sonnet` model parameter.

**Substitution contract** (each placeholder substituted independently at a single level — no nested tokens; body order top-to-bottom is `{USER_NOTE}` → `{BASE_MODE_CONSTRAINT}` → `{CHANGES_MODE_CONSTRAINT}` so the CHANGES block's "note appears above" holds):
- `{TEMP_DIR}` → actual `INNER_TEMP_DIR` value.
- `{round}` → the current `inner_round` value (spawn-time round counter; unchanged on same-round respawn); inline scalar. (`{number}` and `{N}` are NOT substituted — `{number}` is agent-filled per proposal; `{N}` is a doc metavariable.)
- `{USER_NOTE}` → when `USER_NOTE` is non-empty, the single line `USER-PROVIDED NOTE (focus/context for this review): <USER_NOTE>`; when empty, a single empty line. (Mode-independent, always evaluated.)
- `{BASE_MODE_CONSTRAINT}` → the `--base` BASE MODE CONSTRAINT block (when `BASE_MODE=true`) or a single empty line (when `BASE_MODE=false`).
- `{CHANGES_MODE_CONSTRAINT}` → the `--changes` CHANGES MODE CONSTRAINT block (when `CHANGES_MODE=true`, static — no nested token) or a single empty line (when `CHANGES_MODE=false`).

Prepend this path-context block before the prompt body:

```
This agent's working paths:
- TEMP_DIR={actual INNER_TEMP_DIR value}
IMPORTANT: Use the above path for ALL file operations. Using any other path will break session isolation.
All occurrences of {TEMP_DIR} in this prompt refer to the TEMP_DIR value above.
```

Agent prompt body (sonnet model):

```
You are a design document reviewer. Perform ONE independent round of review.

This review is Round {round}. Use {round} as the round number everywhere below — the PROP-ID prefix, the published proposals filename, and the round-summary header. The round number is supplied to you; do NOT derive it by reading or counting "## Review Round" entries in {TEMP_DIR}/review_log.md.

IMPORTANT — Acknowledged Items contract: Check for an "## Acknowledged Items" section in {TEMP_DIR}/review_log.md. These are items the user has already decided to keep as-is. Before reporting any proposal, read this section and treat a proposal as a duplicate (and therefore MUST NOT report it) when ALL of the following hold:
  (a) the Category matches exactly (from the 7 review categories),
  (b) the Location overlaps (same document section),
  (c) the Issue is semantically equivalent (same root cause).
When uncertain, report the proposal — the main session will self-triage it as [AUTO-REJECTED] with a duplicate rationale and it will not reach the user.

Then read the design document and review it against ALL of the following criteria:

1. Requirement consistency — Verify all requirements mentioned in the spec are reflected in the design, and all design decisions trace back to a requirement. Check for requirements that are partially addressed or contradicted.
2. Internal coherence — Check that data models, API contracts, sequence flows, and component responsibilities are mutually consistent. A field added in one section must appear correctly in all related sections.
3. Feasibility — Verify that proposed solutions are technically feasible with the stated tech stack. Flag any design that assumes capabilities not available in the chosen technologies.
4. Implementation order — Check that the proposed implementation sequence respects dependencies. No step should reference artifacts from a later step.
5. Missing items — Look for gaps: error handling not specified, edge cases not covered, security considerations absent, migration plans missing, rollback strategies undefined.
6. Contextual review — Based on the specific domain and nature of this design, check for additional concerns that matter in this context but are not covered by the above categories.
7. In-session verification — Check the design's verification bookkeeping against the contract in `_common/verification.md` (the SOT this prompt cites). Flag (Type `verification`, Category `verification-bookkeeping`): (a) a claim settleable in-session but with no corresponding V/R item — neither an anchor reference (`§검증 기록 V<n>` / `§구현 시 검증 항목 R<n>`) nor a matching claim (a hedge-phrase tripwire — "should exist" / "presumably" / "구현 시 확인/검증 필요" — counts); (b) a verification marking with no recipe; (c) a residual marking that fails the well-formedness predicate (a required field missing / a `/tmp` literal / an unresolved `실패 시 영향` anchor / a token or enum value outside the frozen vocabulary); (d) the saved document containing `**검증 등급**: 미검증` (full-line) or `[검증 등급: 미검증]` (inline tag); (e) a V/R verification field line edited **in the current review round** whose rendering is non-canonical — a leading bullet `- ` or missing/half `**…**` bold instead of the CANON `**key**: value` form (severity **trivial**; scope is the current round's edited lines ONLY — do NOT retro-flag pre-existing untouched lines, and do NOT route this through the §5.2 malformedness predicate, of which line rendering is explicitly not an axis). **Do NOT run any recipe or command — inspect the bookkeeping by reading only.** Detection is key-anchored full-line, tolerant to the bullet/bold axes (`_common/verification.md` §3.4); the `미검증` absence proof is the single document-wide exception (both literal forms must be 0).

{USER_NOTE}

{BASE_MODE_CONSTRAINT}

{CHANGES_MODE_CONSTRAINT}

IMPORTANT: Do NOT modify the design document directly. For every issue found, create a proposal in the following format:

### PROP-R{round}-{number}
- **Type**: [proposal | decision | verification]
- **Severity**: [critical | major | minor | trivial]
- **Category**: [requirement-consistency | internal-coherence | feasibility | implementation-order | missing-items | contextual | verification-bookkeeping]
- **Location**: [section name or location in the design document]
- **Issue**: [problem description]
- **Concept**: [fix concept — what to change and why]
- **Severity rationale**: [one-line — why this tier was chosen]
- **Options**: [decision type only: list up to 4 options with descriptions. Include recommendation if any.]
- **Reference text**: [relevant excerpt from the original text, as a hint for scope analysis]
- **Agent note**: [optional: additional context, alternatives, or extra options beyond 4]

Severity assignment rules:
- critical — semantic violation, silent termination / correctness risk, structural invariant breakage.
- major — implementation misbehavior / clear structural mismatch / incorrect cross-section spec.
- minor — readability / doc quality / audit convenience / summary-section sync.
- trivial — typos, case differences, trivial word choice.
- Assign exactly one severity per proposal.
- "When in doubt, assign one tier higher" — conservative bias, consistent with triage bias toward escalation.
- decision type is by default at least major (user judgment needed = correctness-relevant).
- doc-hygiene issues are minor or trivial.
- verification-type (criterion 7) findings: recipe-absent / out-of-vocabulary token / criterion-7 (a) / (d) = major; other malformed residual fields = minor; criterion-7 (e) (non-canonical V/R line rendering, current-round edits only) = trivial.

Type guidance:
- proposal: The fix direction is clear. Describe what should change and why.
- decision: Multiple valid approaches exist and user judgment is needed. List up to 4 options with descriptions. If more alternatives exist, note them in Agent note.
- verification: A verification-bookkeeping finding (criterion 7) — the main session checks and records it; the agent only flags it by reading. Never run a recipe or command.

Write this round's proposals to a hidden temp file co-located in the SAME directory as the publish target — `mktemp "{TEMP_DIR}/.review_proposals.XXXXXX"` — and, once the full round's content is written, atomically publish it by renaming to {TEMP_DIR}/review_proposals.r{round}.md (`mv -n`; the round-unique filename makes the flag immaterial — any single winner is complete). Publish this round-keyed file unconditionally — including when this round has zero proposals (in that case publish a valid file whose body records zero proposals); the main-session fail-closed read keys on this file's *presence* (that the round-keyed proposals file exists), while the proposal count it acts on is read from a *different* file — the `Proposals created:` line of the `review_log.md` witness — so an empty review must still publish this file even though its own content is not what the read gates on. The temp MUST be inside {TEMP_DIR} so the rename stays on one filesystem and remains atomic (a cross-device rename degrades to copy+unlink and loses atomicity). Publish (rename) BEFORE appending the round summary to review_log.md below, so a present `## Review Round N` witness implies this round's proposals are already complete on disk. Do NOT write directly to the published path, and do NOT add any sentinel or nonce to the proposals file.

After completing the review, append a round summary to {TEMP_DIR}/review_log.md:
  ## Review Round {round}
  - Proposals created: X (categorized by criteria and severity)
  - Proposal details: [list each PROP-ID with Type, Severity, Category, and brief description]

Return a structured summary:
- Round number
- Total proposals created
- Severity breakdown (critical/major/minor/trivial counts)
- Category breakdown
- Brief description of each proposal
```

**Step 12.detect — Classify the spawn result (detect-branch hybrid).** Immediately after `Agent()` returns, classify its tool result with a two-sided positive signature *before recording anything* — the harness may launch the round agent asynchronously on some session hosts regardless of the `run_in_background: false` request, so the spawn cannot be assumed synchronous:

- **SYNC** ⟺ tool result carries a `<usage>…duration_ms…</usage>` tail — e.g. `<usage>input_tokens: 1200, duration_ms: 3450</usage>` — (positive evidence: `duration_ms` key present inside the `<usage>` block) AND has no `output_file:` / `Async agent launched successfully.` marker in the envelope. The inline result IS the observed return — proceed directly to (a)–(i) below with no agentId tracking, no on-disk read, no yield (reconcile 0, wait 0). This is identical to the committed synchronous behavior.
- **ASYNC** ⟺ the tool-result ENVELOPE (its header/marker lines, typically the leading lines ahead of the agent body, NOT agent body text) contains `output_file:` or `Async agent launched successfully.`. Match these tokens in envelope position only — the same tokens inside agent body prose (this design corpus discusses them) never trigger classification, symmetric with SYNC's envelope-tail `<usage>` anchor. Capture agentId + output_file, confirm from on-disk witness:
    - async_observed_return(round N) ≡ agent-authored `## Review Round N` header in $INNER_TEMP_DIR/review_log.md (round-N keyed; M≠N never satisfies). N is `inner_round`, injected into the agent's spawn prompt as {round} by the main session (the agent does not derive it) — see the CFI ASYNC-enforcement ordering; do not duplicate that invariant here.
    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to (a)–(i). An already-finished async costs 2 reads, 0 yield.
    - **witness absent** → default to waiting (NOT respawn). Apply the **ASYNC stall liveness predicate** defined in the Control-Flow Invariants section: maintain the durable `.async_stall.json` stall-state (tri-state ALIVE/WEDGED/UNKNOWN), floor-read review_log.md once per re-entry, emit one Korean line per witness-absent yield, respawn in the SAME inner_round only when all three CFI death conjuncts hold, and escalate (not kill) on the babbling / persistent-UNKNOWN streak triggers. Do NOT inline a second copy of the predicate here — CFI is the single authority (this block may be compacted; CFI is not). Soft liveness signals (`output_file` growth · early-wake notification) are acceleration hints, never a gate.
    - **first-round-N-witness-wins dedup**: if a respawned agent and a merely-slow original both append `## Review Round N`, the convergence parser adopts only the FIRST round-N witness and ignores later duplicate `## Review Round N` blocks (a double-count/correctness concern, not anti-fabrication — it keeps the predicate deterministic even when `TaskStop` fails to kill the zombie). The same-N premise these duplicates share is now structurally guaranteed: the round number is injected as {round} = inner_round, so a respawn cannot diverge to N+1.
    - **malformed-async-suspected** (an envelope async marker IS present but agentId or output_file cannot be cleanly parsed) → still classify ASYNC: recover whatever agentId / output_file fragment is parseable and take the ASYNC floor path; if neither field is recoverable, surface the error, then respawn in the SAME inner_round (no agentId to stop — treat as a failed spawn).
- **Neither** (no `<usage>` tail AND no envelope async marker) → NOT consumable. Write no record; surface the error. By this branch's own predicate no async marker exists, hence no agentId/output_file to recover — there is no ASYNC fallback from here.

Overlap/priority: SYNC's negative half is scoped to the envelope — SYNC requires no async marker _in the envelope_. If BOTH a `<usage>…duration_ms…</usage>` tail AND an envelope async marker appear, classify ASYNC and confirm via witness (the async marker dominates). The SYNC and ASYNC predicates are mutually exclusive by construction; Neither is reached only when the envelope has neither signal.

- No look-ahead across the round boundary (ASYNC) — governed by the ASYNC-enforcement ordering in the Control-Flow Invariants section; do not restate or relax it here.

After the agent returns:

  a. The agent published this round's proposals by atomic rename to `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` (no seed file — the round-keyed file exists only if the agent wrote it), appended a round summary to `$INNER_TEMP_DIR/review_log.md`, and returned a structured summary including proposal count.
  b. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` to get the current round's proposals.
  c. **For each proposal**, analyze its concept:
     - **Proposal type**: Use the Reference text as a hint to identify all affected locations. Concretize the fix (what exactly will change, where).
     - **Decision type**: Analyze the impact of each option so the user can make an informed choice.
  d. **Self-Triage** (main session): Classify each proposal into `auto-approve`, `auto-reject`, or `escalate` per the Self-Triage Protocol below.
  e. Apply auto-approved proposals directly via Edit. Log auto-rejected proposals to `## Acknowledged Items` (inline copy — the real outer-persistent extraction happens at Step 18). Both are recorded in `review_log.md` with `[AUTO-APPROVED]` / `[AUTO-REJECTED]` tags and a one-line rationale.
  f. **If escalated proposals remain**: Present only those to the user via AskUserQuestion (in Korean). See "Approval UX" below.
  g. Process user choices according to the "Processing Protocol" below. **Dialogue loop per Ground Rule #6**: if the user's response is a follow-up question or discussion rather than an explicit decision, continue the dialogue via AskUserQuestion until an explicit decision is given.
  h. Update the round entry in `$INNER_TEMP_DIR/review_log.md` with disposition tags.
  i. Briefly summarize this round's auto-handled items to the user in Korean (count + one-line per item) so they have visibility into self-triage decisions.

**Step 13 — Edit failure handling**: If an Edit fails (e.g., `old_string` not unique, target text changed):
  - Immediately notify the user: "제안 #N 적용 중 일부 위치에서 실패: [원인]"
  - Re-analyze the failed location and propose an alternative.
  - **Option A (apply after user confirmation)**: re-attempt with disambiguated context. On success, log disposition tag to `review_log.md`.
  - **Option B (defer to next round)**: append a `PEND-NNN` block to `$INNER_TEMP_DIR/pending_applies.md` per the schema in Phase 1.
  - **Partial success**: log the proposal with a `partial_apply=true` marker and record the failed locations in `pending_applies.md`.
  - Any `PEND-NNN` must later be resolved (success → remove block + log disposition; or user abandon → `[REJECTED]` + ack + remove block) before inner convergence is allowed.

**Step 14 — Severity aggregation** (post-upgrade final values — disposition irrelevant): see Control-Flow Invariants above for the `consecutive_no_major` formula.

Severity tier note (4-tier taxonomy):

- **critical** — semantic violation, silent termination / correctness risk, structural invariant breakage (e.g., termination formula error, missing dedup, F5-class gaps).
- **major** — implementation misbehavior / clear structural mismatch / incorrect cross-section spec (e.g., canonical section inconsistencies, lifecycle step missing, feasibility gap, wrong algorithmic order).
- **minor** — readability / doc quality / audit convenience / summary-section sync (e.g., stale consensus lists, outdated quick-ref formulas).
- **trivial** — typos, case differences, trivial word choice.

The saturation rule is a *fresh-agent ripple verifier*. If this round mutated the document based on critical/major findings (even approved ones), the next round must run a fresh agent to verify ripple effects. Severity is a property of the proposal itself — disposition (`[APPROVED]`, `[MODIFIED]`, `[REJECTED]`, etc.) is irrelevant to the count. Main session may upgrade severity unidirectionally during triage when hidden risk is discovered (record as `[SEVERITY-UPGRADED]` informational marker); downgrades are forbidden.

**Step 15 — Inner convergence guard**: see Control-Flow Invariants (`inner_converged_cleanly()`). If true, set `INNER_EXIT_REASON = "clean-convergence"` and break out of the inner loop.

**Step 16 — Inner safety limit (6 rounds)**:

If `inner_round >= 6`, present 3 options via AskUserQuestion. This raise is the `inner-limit` trigger (`PROMPT_TRIGGER = inner-limit`); the ASYNC-stall and `lostwrite` escalations reuse this same prompt with `PROMPT_TRIGGER = async-slow` / `lostwrite` selecting the matching reason variant defined below, while the A/B/C → `INNER_EXIT_REASON` mapping is shared and invariant. Dynamic recommendation:

- `pending_dialogue > 0` → recommend **A: 3 라운드 추가 진행** (finish open dialogues)
- `pending_dialogue == 0` → recommend **B: 이번 이터레이션 종료 후 새 이터레이션 시작** (escape stuck inner, preserve outer progress)

Korean prompt template (when `pending_dialogue > 0`):

```
이터레이션 {N}의 내부 라운드가 안전 한계(6회)에 도달했습니다.

현재 대화 중인 제안이 {pending}건 남아 있습니다.
지금 종료하면 해당 제안들이 미처리 상태로 넘어갑니다.

어떻게 진행하시겠습니까?
```

Options (header chip `처리 방식`; each option carries a `description`; the recommended option is marked with a `← 추천` label suffix):
- label `"A: 3 라운드 추가 진행 ← 추천"` — description: 미완료 대화를 마저 처리한 뒤 계속 진행합니다.
- label `"B: 이번 이터레이션 종료 후 새 이터레이션 시작"` — description: 현재 이터레이션을 닫고 새 이터레이션을 시작합니다.
- label `"C: 외부 이터레이션 전체 종료"` — description: 외부 루프 전체를 종료하고 리뷰를 마칩니다.

Korean prompt template (when `pending_dialogue == 0`):

```
이터레이션 {N}의 내부 라운드가 안전 한계(6회)에 도달했습니다.

미완료 대화는 없습니다. 이번 이터레이션의 에스컬레이션 적용: {esc_applied}건.

어떻게 진행하시겠습니까?
```

Options (header chip `처리 방식`; each option carries a `description`; the recommended option is marked with a `← 추천` label suffix):
- label `"A: 3 라운드 추가 진행"` — description: 미완료 대화는 없으나 추가 라운드로 이번 이터레이션을 더 진행합니다.
- label `"B: 이번 이터레이션 종료 후 새 이터레이션 시작 ← 추천"` — description: 미완료 대화가 없어 현재 이터레이션을 닫고 새 이터레이션으로 넘어갑니다.
- label `"C: 외부 이터레이션 전체 종료"` — description: 외부 루프 전체를 종료하고 리뷰를 마칩니다.

**Reused-prompt reason variants + downstream clause source (all four EXIT_TRIGGER values: inner-limit / async-slow / lostwrite / trigger-neutral)** — the same 3-option prompt is reused for two further triggers beyond `inner-limit` (`async-slow` and `lostwrite`; of the four EXIT_TRIGGER values only these three raise the prompt — the `trigger-neutral` fallback names no prompt and is a downstream-clause source only); only the reason line, context, option descriptions, and `← 추천` position change (the `"어떻게 진행하시겠습니까?"` tail, option count 3, the A/B/C → `INNER_EXIT_REASON` mapping below, and the header chip `처리 방식` are invariant). The `inner-limit` variant above keeps `안전 한계(6회)`; the `async-slow` and `lostwrite` variants do NOT mention `6회` (they are round-scope-independent):

- **`async-slow`** (babbling `growth_streak ≥ G` OR persistent-UNKNOWN `unavail_streak ≥ U`): reason line `이터레이션 {N}의 비동기 리뷰어가 아직 완료 witness를 발행하지 못했습니다.`; recommendation **A: 계속 대기** (live-but-slow evidence; on A reset ONLY the triggering streak to 0 and return to the wait loop, the death gate `reentry_count` untouched); downstream early-termination clause `비동기 리뷰어가 완료 witness를 발행하지 못해 조기 종료됨`, summary clause `비동기 리뷰어 미완료로 미해소`.
- **`lostwrite`** (`lostwrite_respawn_count ≥ K65` in the fail-closed READ arm): reason line `이터레이션 {N}의 라운드 결과 파일이 완료 표시 후에도 반복 유실되었습니다 — 같은 라운드 재시도 {K65}회로도 복구되지 않았습니다.` (`{K65}` renders the actual retry count); recommendation **B: 새 외부 이터레이션 시작** (lost round not restorable in place; on A reset `lostwrite_respawn_count := 0`), A label `같은 라운드 재시도` (NOT the native `3 라운드 추가 진행`); downstream early-termination clause `라운드 결과 파일이 반복 유실되어 조기 종료됨`, summary clause `라운드 결과 파일 반복 유실로 미해소`.
- **`inner-limit`** (native 6-round inner safety limit; the reason line / recommendation are in the native prompt block above — this bullet is the downstream-clause source only): downstream early-termination clause `내부 라운드가 안전 한계로 조기 종료됨`, summary clause `내부 안전 한계 도달 시점에 미해소`.
- **trigger-neutral fallback** (`EXIT_TRIGGER == n/a` or absent — a `user-abort` / clean iteration, or a pre-bump `outer_log.md`): downstream early-termination clause `내부 라운드가 조기 종료됨`, summary clause `이터레이션 조기 종료 시점에 미해소`.

Option mapping to `INNER_EXIT_REASON`:

| Option | Action | INNER_EXIT_REASON |
|---|---|---|
| A: 3 라운드 추가 진행 | extend inner loop by 3 rounds (repeatable) | (not set, continue) |
| B: 이번 이터레이션 종료 후 새 이터레이션 시작 | break inner loop; next outer iter re-reviews from doc state | `safety-limit-fresh-outer` |
| C: 외부 이터레이션 전체 종료 | break inner loop; pass through Step 17–22, then break the outer loop at Step 22 → Phase 3 | `safety-limit-outer-terminate` |

**Option B invariant**: A stuck inner loop must never block outer progress. Ack + document state are preserved, so the next fresh agent can re-review. Outer exit check (Step 22) bypasses convergence judgment when `INNER_EXIT_REASON == "safety-limit-fresh-outer"` — always continue.

**EXIT_TRIGGER immediate-flush**: at the moment this escalation prompt is raised (so `PROMPT_TRIGGER` is known), immediately append one line — `- Inner exit trigger: {inner-limit | async-slow | lostwrite}` — to `$INNER_TEMP_DIR/review_log.md` (this is before the Step 21 wipe, so the value lands durably; Step 20 restores it into the `## Outer Iteration N` block). This is a main-session informational marker and does NOT author a `## Review Round N` header, so the anti-fabrication anchor is unaffected. `n/a` never appears on this flush line — it is written only at an escalation, which always carries a concrete trigger.

**ASYNC-stall reuse trigger**: this same 3-option prompt is also raised — as a *distinct trigger*, with no new option and no new `INNER_EXIT_REASON` — when the CFI ASYNC-stall escalation fires (babbling `growth_streak ≥ G` or persistent-UNKNOWN `unavail_streak ≥ U`; see Control-Flow Invariants). For that trigger the default recommendation is **A: keep waiting / retry** (growth and UNKNOWN are positive evidence of a live-but-slow reviewer), the A/B/C → `INNER_EXIT_REASON` mapping is unchanged, and on A the triggering streak is reset to 0 before returning to the Step 12.detect wait loop (ask-storm debounce; the death gate `reentry_count` is untouched). The canonical 4-option Case-2 menu is deliberately NOT imported — its partial-synthesize option is structurally void for a single reviewer (no peer witness to synthesize). For this trigger `PROMPT_TRIGGER = async-slow` (the `async-slow` reason variant above), so the Step 16 EXIT_TRIGGER flush records `async-slow`.
If exit condition not met and not at safety limit → return to Step 12 with a new agent.

---

#### INNER LOOP COMPLETE — Per-iteration summary work (Step 17–21)

**Step 17 — Compute `COUNT_APPLIED`**: use the formula in Control-Flow Invariants. Feeds Step 22.

**Step 18 — Extract new ack items**:

Parse `$INNER_TEMP_DIR/review_log.md` for `[REJECTED]` and `[AUTO-REJECTED]` lines. For each, compose an `ACK-NNN` record with the 8 fields (Source, Disposition, Category, Location, Issue, Reference text, User/Auto-reject rationale, Recorded) per the schema in Phase 1.

**Dedup rule**: an ack is a duplicate of an existing entry in `$OUTER_DIR/ack_items.md` iff ALL three conditions hold:

1. `Category` matches exactly (controlled vocabulary: one of the 7 review categories)
2. `Location` refers to the same section (case-insensitive, "Section 4.3" ≈ "4.3 Auth Flow")
3. `Issue` describes the same root cause (main session semantic judgment)

Append only non-duplicate records to `$OUTER_DIR/ack_items.md` under a new `### From Iteration N` heading. **If zero new items are extracted for this iteration, do not append the `### From Iteration N` block at all.** Use monotonic zero-padded IDs (`ACK-001`, `ACK-002`, …).

**Step 19 — Append convergence table rows**:

Append one row to each of the two tables in `$OUTER_DIR/convergence_table.md` (auto-decide column dropped):

```markdown
| {iter} | {rounds} | {auto_approved} | {auto_rejected} | {escalate_applied} | {escalate_rejected} |
| {iter} | {max_pending_applies} | {아니오|예} | {ack_size_after} | {exit_reason_ko} |
```

Where:
- Mark the iter column with ` ⚠️` suffix if `INNER_EXIT_REASON != "clean-convergence"` (partial iteration). Mark `escalate_applied` with `**0** ✓` bold-tick if the final value is 0 on a clean iteration.
- `max_pending_applies` is the maximum size `pending_applies.md` reached during the iteration (not the final value).
- `partial_flag` = `예` if `INNER_EXIT_REASON != "clean-convergence"`, else `아니오`
- `exit_reason_ko` ∈ {`정상수렴`, `내부한계`, `사용자중단`}
- **Invariant**: `exit_reason_ko == "정상수렴"` ⇒ `partial_flag == "아니오"`.

Note on `escalate_applied` value: lite uses `COUNT_APPLIED` (= count of [APPROVED]+[MODIFIED]+[USER-DIRECTED] groups, partial-apply dedup). The reference-only `escalate_applied` formula in Control-Flow Invariants is identical here since auto-decide is absent.

**Step 20 — Append outer_log.md iteration entry**:

Append to `$OUTER_DIR/outer_log.md`:

```markdown
## Outer Iteration {outer_iter}

- Started: {ISO8601}
- Ended: {ISO8601}
- Inner TEMP_DIR: {INNER_TEMP_DIR}
- Inner rounds run: {n}
- Inner exit reason: {clean-convergence | safety-limit-fresh-outer | safety-limit-outer-terminate | user-abort}
- Inner exit trigger: {inner-limit | async-slow | lostwrite | n/a}   ← restore from `$INNER_TEMP_DIR/review_log.md` via `grep '^- Inner exit trigger:' | tail -1` ONLY when `INNER_EXIT_REASON ∈ {safety-limit-fresh-outer, safety-limit-outer-terminate}` (these two reasons arise solely from options B/C per the Step 16 mapping, and the escalation the user answered B/C on is the loop-terminating one, so its flush is genuinely the final flush — hence tail -1 last-match is correct); otherwise (`clean-convergence` / `user-abort`) write `n/a`, because a continue-then-abort or clean iteration leaves only stale non-terminal flushes (e.g. async-slow's default option-A continue) that do NOT describe this iteration's termination. Do this BEFORE the Step 21 wipe; mandatory every iter (same convention as [VERIFY-RAN])
- Partial iteration: {true|false}
- [VERIFY-RAN] (별도 카운터, escalate 합 밖): {count}   ← computed from review_log.md BEFORE the Step 21 wipe; mandatory every iter (write 0 when none); Step 22's `this_iter_verify_ran` source

### Escalate Counter Breakdown

- [APPROVED]: {count} "proposal IDs: ..."
- [MODIFIED]: {count} "proposal IDs: ..."
- [USER-DIRECTED]: {count} "proposal IDs: ..."
- escalate_applied: {COUNT_APPLIED}  ← termination input
- [REJECTED]: {count} ← NOT counted; added to ack set
- [AUTO-APPROVED]: {count} ← NOT counted
- [AUTO-REJECTED]: {count} ← NOT counted; added to ack set
- pending_applies_at_end: {"(none)" | PEND-NNN list}

### Ack Set Delta

- Before: {size_before}
- Added: {list of new ACK-NNN IDs}
- After: {size_after}

### Document Mutations Summary

- Files touched: {list}
- Total Edit ops: {n} (success: {s}, failed initially: {f}, eventually resolved: {r})

### Termination Decision

- outer_should_terminate: {true|false}
- Rule fired: {fixpoint | outer-limit-reached | safety-limit-outer-terminate | continue}
- Next action: {continue to iter i+1 | ask user to extend | Phase 3}
```

**Step 21 — Delete `INNER_TEMP_DIR`** (path guarded):

```bash
[[ "$INNER_TEMP_DIR" == "${OUTER_DIR}"/* ]] && rm -rf "$INNER_TEMP_DIR"
```

This deliberate wipe prevents "context poisoning" — the next iteration's fresh agent starts with only the ack seed and the document itself.

---

#### Outer Exit Check (Step 22–25)

**Step 22 — Outer termination judgment**: see Control-Flow Invariants for the decision tree.

**Step 23 — Ack soft-limit check** (only if `outer_done == false`):

Count entries in `$OUTER_DIR/ack_items.md` (lines starting with `#### ACK-`):

- **50 items**: advisory — append a one-line warning to the next iteration-transition summary: `⚠️ 인지됨 항목 {n}건 (50건 권고치 초과)`
- **100 items**: hard — ask the user via AskUserQuestion (header chip `인지 항목`; each option carries a `description`):
  - label `"A: 요약"` — description: Compress old ack entries into one-line-per-category summaries.
  - label `"B: 보관"` — description: Move entries from previous iterations to `$OUTER_DIR/ack_archive.md`, keeping only the current iter active.
  - label `"C: 현재 유지"` — description: Accept the prompt-length cost and do nothing.

Only run this check when `outer_done == false` — when `outer_done == true`, cleanup is imminent so ack size no longer matters.

**Step 24 — Outer safety limit (default 2 iterations)**:

If `outer_iter >= 2 AND outer_done == false`, present the extension/terminate prompt in Korean:

```
외부 이터레이션 안전 한계(2회)에 도달했습니다.

[convergence table inline]

아직 수렴이 완료되지 않았습니다 (에스컬레이션 적용 합계 > 0).
계속 진행하시겠습니까?
```

AskUserQuestion (header chip `안전 한계`; each option carries a `description`): label `"2회 추가 진행"` (description: 외부 이터레이션을 최대 2회 더 진행해 수렴을 시도합니다.) / label `"현재 상태로 종료"` (description: 추가 진행 없이 현재 상태로 리뷰를 종료합니다.). If the user chooses to terminate, break outer loop → Phase 3. If extended, raise the outer cap by 2 and continue.

**Step 25 — Iteration transition summary + auto-advance** (only if `outer_done == false`):

Emit the Korean iteration-transition summary block, then auto-advance immediately to the next outer iteration. No countdown or confirmation.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 이터레이션 {N} 완료 요약  ({N} / 최대 2회)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

내부 라운드: {rounds}회 진행

처리 결과:
  자동 승인         {auto_approved}건  → 문서에 즉시 적용됨
  자동 거부         {auto_rejected}건  → 인지됨 (재보고 안 함)
  에스컬레이션 승인 {approved}건  → 문서에 적용됨
  에스컬레이션 거부 {rejected}건
  수정 적용         {modified}건  → 사용자 수정 후 적용됨
  사용자 지시       {directed}건
  (대기 중 적용      {pending}건  ⚠️ {EXIT_TRIGGER별 미해소 사유 · Step 16 변형})  ← count>0 AND non clean-convergence 일 때만 노출; 미해소 사유는 EXIT_TRIGGER로 Step 16 per-trigger 변형에서 선택(n/a·부재 시 트리거-중립)
  ─────────────────────────────────────
  에스컬레이션 적용 합계: {sum}건  [승인 {approved} + 수정 {modified} + 사용자지시 {directed}]

자동 처리 내역:
  • [자동승인] PROP-Rx-y: <one-line>
  • [자동거부] PROP-Rx-y: <one-line>

판정: 계속 진행 → 이터레이션 {N+1} 시작
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Verdict line variants (always emitted):

- Clean convergence / outer termination: `판정: ✅ 외부 수렴 완료 — 에스컬레이션 적용 0건 · 정상 수렴 확인 / 문서가 안정 상태에 도달했습니다.`
- Escalate-zero but partial iteration (safety-limit-fresh-outer): `판정: ⚠️ 에스컬레이션 적용 0건이나 부분 이터레이션으로 수렴 미확인 / {early-termination clause} — 이터레이션 {N+1}에서 재검증합니다.` — `{early-termination clause}` is selected by `EXIT_TRIGGER` per the Step 16 per-trigger variants (trigger-neutral fallback when `n/a` / absent).
- Continue: `판정: 계속 진행 → 이터레이션 {N+1} 시작 / (에스컬레이션 적용 {k}건 — 문서 변경 발생)`

User intervention only occurs at (1) outer safety limit prompt, (2) inner safety limit prompt, (3) escalated AskUserQuestion for individual proposals.

### Phase 3: Outer Cleanup

1. Emit the Korean final completion summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 설계 리뷰 완료
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

총 {N}회 이터레이션, {total_rounds}회 라운드를 거쳐 문서가 안정화되었습니다.

[최종 수렴 현황표]

전체 처리 요약:
  자동 승인 (즉시 적용):          {sum_auto_approved}건
  에스컬레이션 적용 (합계):        {sum_escalate_applied}건
    — 사용자 승인:  {sum_approved}건
    — 수정 후 적용: {sum_modified}건
    — 사용자 지시:  {sum_directed}건
  자동 거부 (인지됨):              {sum_auto_rejected}건
  에스컬레이션 거부 (인지됨):      {sum_rejected}건

문서 상태: 설계 완료 ✓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

2. Emit the lite-redirect footer (single line, every invocation):

```
ℹ️ 미묘한 invariant 검증이 필요한 critical 설계라면 /cc-cmds:design-review 로 더 깊은 다중 사이클 검증을 고려하세요.
```

3. Delete the outer directory (path guarded):

```bash
[[ "$OUTER_DIR" == docs/_temp/* ]] && rm -rf "$OUTER_DIR"
```

## Self-Triage Protocol

The main session must self-judge each proposal before bothering the user. Default toward escalation only when judgment is genuinely needed; reduce user fatigue by handling unambiguous items directly.

**auto-approve** — apply without asking. Use when ALL of the following hold:
- Type is `proposal` (never auto-approve `decision` type).
- The fix is mechanical or clearly correct: typo, naming consistency, missing field obviously required by an already-agreed contract, internal-coherence sync, trivially missing standard error handling, dependency-order swap that doesn't change scope.
- Affected locations are fully concretized and the change is local (no cascading rewrites of unrelated sections).
- No business logic, no API surface decision, no security/compliance trade-off, no UX choice, no tech-stack swap.
- A reasonable senior engineer would not pause on this.

**auto-reject** — log as Acknowledged without asking. Use when ANY of the following hold:
- The proposal is a false positive: the concern is already addressed elsewhere in the document (cite the section).
- Out of scope for the current document's stated purpose.
- Contradicts an explicit decision already recorded in the document.
- Duplicate of an item already in `## Acknowledged Items`.

**escalate** — forward to user via AskUserQuestion. Use when:
- Type is `decision` (auto-decide is not used in lite — every decision-type proposal escalates).
- Type is `proposal` but the fix involves business judgment, API/data contract change, security/compliance trade-off, UX choice, or non-trivial scope.
- You are uncertain — when in doubt, escalate. Self-triage should err on the side of escalation, never on the side of silently dropping a real concern.

**`Type: verification` (criterion #7) — its own branch** (not proposal/decision): route by category per `_common/verification.md`. cat-1 (read-only) → **self-run + record** (no user prompt), counted by the independent `[VERIFY-RAN]` counter. cat 2–4 → **escalate to the closed 3-option verification menu** (`지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)`), subject to the lite re-run budget of 6 → on exhaustion a 2-option degrade. cat-5 (worktree) → 2-option menu (`잔여 항목으로 기록` / `거부 (현재 유지)`), never re-run. The main session never runs a recipe the agent reported running, and discards agent-reported execution results unconditionally. Full rules: "## Verification dimension (criterion #7)".

**Severity upgrade authority**: during self-triage, if the main session discovers hidden risk, it MAY upgrade severity **unidirectionally** (trivial → minor → major → critical). Downgrades are forbidden. When upgrading, append an informational marker to `review_log.md`:

```
- PROP-R{round}-{N} [SEVERITY-UPGRADED] minor → major: {reason}
```

**Logging requirement**: For every auto-handled item, write a one-line rationale in `review_log.md`:

```
- PROP-R{round}-{N} [AUTO-APPROVED|AUTO-REJECTED]: {one-line rationale}
```

## Approval UX

Present escalated proposals item-by-item via AskUserQuestion, batched up to 4 at a time. No "approve all" option — every escalated proposal requires individual review.

### Batch announcement (Korean, required when >4 items)

When more than 4 escalated proposals exist in a single round, split across multiple AskUserQuestion calls. **Before the first call**, emit a Korean batch announcement to the user. **Do NOT mention internal tool constraints** (e.g., "AskUserQuestion 4개 한계", "tool limit", "call 분할"); frame it as UX pacing.

Template:

```
에스컬레이션 항목 {N}건을 {K}차에 걸쳐 나누어 질문드립니다 (1차 {n1}건, 2차 {n2}건, ...).
순서대로 답변해 주세요. 중간에 "그만" 또는 "잠깐" 입력하면 남은 항목은 보류됩니다.
```

Before each subsequent call:

```
{k}차 질문 ({nk}건) — 남은 {remaining}건:
```

Do not mention "batch" / "call" / "분할" / "AskUserQuestion" / "4개 한계" in user-visible text.

### For Proposal type

- Present the agent's concept together with the main session's concretized scope (affected locations and specific changes).
- Options: "승인" (with description of what will be applied) and "거부 (현재 유지)" (with note that the item won't be re-reported).

### For Decision type

- Dynamically construct AskUserQuestion options from the agent's Options field (up to 4 options per question).
- Every option MUST carry a `description` (one line summarizing what selecting it does); never present bare-label options.
- Include the agent recommendation if present: per the documented recommendation convention, append `← 에이전트 추천` to the recommended option's label, place it at position 1, and put the rationale in that option's `description`.
- If the proposal has more than 4 options, present the first 4 in the primary question and mention additional alternatives in the question text from the Agent note field — do NOT split one proposal's options across two questions.

### For Verification type (criterion #7)

- The closed menu is `지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)` for cat 2–4 (subject to the lite re-run budget of 6). For cat-5 (worktree), exception-class (`실행 주의`) recipes, or budget exhaustion, drop `지금 검증 실행` (2-option degrade) + a one-line Korean disclosure; when `예상 소요` >2 min, disclose the cost in the option `description`.
- Every option carries a `description`; no manual Other/기타. cat-1 (read-only) findings are NOT menued — the main session self-runs and records them, counted via `[VERIFY-RAN]`.

### Other input

The user may type free-form text instead of selecting an option. This is handled by the Processing Protocol below.

## Processing Protocol

For each user response to a proposal prompt:

### Disposition handling (normal path)

- **"승인" selected** (or a Decision option selected): Apply the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Verification menu (criterion #7)**: `지금 검증 실행` → execute per "## Verification dimension" + record (run-now write surface + `## Verification Runs` line), logged `[APPROVED]`-class (counted in `COUNT_APPLIED`); `잔여 항목으로 기록` → create an R-item (`잔여 사유: 검증 차단`, blocked reason `리뷰 시점 사용자 이연 — <YYYY-MM-DD>`), also `[APPROVED]`-class; `거부 (현재 유지)` → `[REJECTED]`-class. A cat-1 self-run (no menu) is logged via the independent `[VERIFY-RAN]` counter.
- **Other input**: Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestion, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.

## Application Mechanism

The main session applies approved changes (auto-approved and user-approved) directly using the Edit tool. The agent never modifies the design document. Since concepts may affect multiple locations, the main session identifies all affected locations during scope analysis and applies changes in batch.

**V/R field-line form-preservation fence**: when an Edit touches a V/R verification field line (`_common/verification.md` §4/§5), preserve its canonical rendering — do NOT convert the line to a leading bullet (`- `) and do NOT add or remove the `**…**` bold; emit the CANON `**key**: value` form (bold key, no bullet, one space after the colon). This directly blocks the observed bulletization; criterion #7(e) is the defense-in-depth detection when the fence is missed.

If an Edit fails, follow the Step 13 Edit-failure handling procedure (retry within round or defer to `pending_applies.md`).

## Verification dimension (criterion #7)

Detection has **full parity** with base (`design-review`); re-execution is **reduced**. The contract SOT is `${CLAUDE_SKILL_DIR}/../_common/verification.md` (this section and the inline grammar in the Step 12 prompt cite it).

**CHECK is the review, RUN is the main session** (same structure as base): agents flag verification bookkeeping by reading only; the agent prompt forbids running any recipe, and the main session **unconditionally discards** any execution result an agent reports.

**Main-session execution (reduced)**:

- **cat-1 (read-only)**: self-run freely (per-attempt limits: `grep` >50 hits → inconclusive; named-file `Read` only); record the verdict; counted by the independent `[VERIFY-RAN]` counter.
- **cat 2–4**: the same closed 3-option menu as base (`지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)`), subject to the **lite outer-session re-run budget of 6** (the unified lite constant). On budget exhaustion → 2-option degrade (`잔여 항목으로 기록` / `거부 (현재 유지)`) + a one-line Korean disclosure. per-run cap 2 min (lite-owned constant). An exception-class (`실행 주의`) recipe also degrades to 2 options.
- **cat-5 (worktree)**: bookkeeping inspection only — never re-run.

**Execution memo parity**: log each run to `$OUTER_DIR/outer_log.md`'s `## Verification Runs` section — `- <V anchor> | <recipe hash> | <verdict> | <ISO8601>` (V anchor = `### V<n>.` heading; recipe hash = `shasum` of the full `검증 절차` field; verdict = a terminal token) — with the same `(anchor, hash)` dedup as base (lite is also a fresh-agent structure, so it carries the same re-proposal fatigue vector; an existing `(anchor, hash)` → cite the recorded verdict + drop `지금 검증 실행`). **The re-run budget of 6 is file-restored from the `## Verification Runs` line count** (bash variables are volatile — the same restore doctrine as `AUTO_DECIDE_ENABLED`; the budget never depends on lead memory).

**run-now / dirty-tree / drift ladder / pre-registration**: identical to base's "## Verification dimension" — the SOT's drift ladder and flake pre-classification are used verbatim (no review-local adaptation); run-now checks 0 new changes vs. a pre-execution `git status --porcelain` snapshot (verdict not recorded + fail-loud Korean on violation); a dirty tree gets a one-line disclosure + a `유효성 노트` on the ledger entry. An unmarked claim creates a new `### V<n>` (creating `## 검증 기록` at the canonical position if absent); R-flips are implement-only.

**termination machine**: Type `verification` bypasses any decision classifier (execution is a real-world side effect). The `[VERIFY-RAN]` counter is kept out of `COUNT_APPLIED` and every itemize render and adds the `this_iter_verify_ran == 0` term to the Step 22 predicate (one more outer iteration for a fresh-agent ripple-verify). A cat-1 `반증됨(실패)` verdict is surfaced in Korean, never silently recorded. `잔여 항목으로 기록` lands as `잔여 사유: 검증 차단` + `리뷰 시점 사용자 이연 — <YYYY-MM-DD>`. **BASE MODE**: verification-bookkeeping fixes are in-scope even under `--base`; using a verification *result* as a vector for a new task-level design-substance proposal within the same finding remains forbidden.

## Ground Rules

1. **Propose first, then triage.** All issues are generated as concept proposals. The agent never modifies the design document directly. The main session self-triages each proposal: unambiguous fixes are auto-approved and applied, false positives are auto-rejected, and only items requiring judgment are escalated to the user.
2. **Agent Loop required.** Phase 2 iterative inner review must use the agent-based loop. Exit requires either severity saturation (`consecutive_no_major >= 2` + empty pending + no in-progress dialogues) or the user's explicit 3-option choice at inner safety limit.
3. **Agent independence.** Each review agent reviews the document from scratch. Previous round results are only accessed via `$INNER_TEMP_DIR/review_log.md`, which is seeded with the outer-persistent ack set at the start of each outer iteration.
4. **Review log required.** Every round's results must be recorded in `$INNER_TEMP_DIR/review_log.md` with disposition tags: `[AUTO-APPROVED]`, `[AUTO-REJECTED]`, `[APPROVED]`, `[REJECTED]`, `[MODIFIED]`, `[USER-DIRECTED]`. Informational marker `[SEVERITY-UPGRADED]` is appended as needed but never counts toward any metric.
5. **Respect acknowledged items.** Items decided to keep as-is (rejected and auto-rejected proposals) must not be re-reported in subsequent rounds or iterations. The outer-persistent `ack_items.md` enforces this across the whole outer session.
6. **Triage bias toward escalation.** When the main session is uncertain whether a proposal is unambiguous, it MUST escalate. Self-triage exists to reduce trivial questions, never to silently override user authority on judgment calls.
7. **Never decide for the user.** When the user responds to a pending decision with a follow-up question, a request for more context, or a discussion point, this is NOT a decision. Continue the conversation via AskUserQuestion until the user states an explicit decision. A decision is only confirmed when the user clearly says what to do (e.g., "A로 가자", "현재 유지", "변경해줘"). Questions like "그러면 ~는 어떻게 되나요?" or "~에 대해 좀 더 설명해줘" are continuation signals, not decisions.

## Options

> _Consistency Note: README의 user-facing 옵션 표는 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent가 읽는 작동 규약(예: `{BASE_MODE_CONSTRAINT}` 치환 블록)이며, frontmatter 변경 시 함께 갱신._

### --base

Base design review mode. When `$ARGUMENTS` contains `--base`, add the following constraint block to the review agent prompt in place of `{BASE_MODE_CONSTRAINT}`:

```
BASE MODE CONSTRAINT:
Verify consistency and completeness of the existing design content. Do NOT propose adding new implementation details.
- DO propose: inconsistencies, contradictions, or missing interface definitions between existing sections.
- DO propose: essential supplements to existing content that are clearly needed for consistency (will be confirmed with user).
- DON'T propose: adding new implementation details that don't currently exist (these belong to task-level design).
- DON'T propose: removing or reducing existing detailed design content.
```

When `--base` is not present, remove the `{BASE_MODE_CONSTRAINT}` placeholder line from the agent prompt. (LLM-equivalent to substituting a single empty line, as the Step 12 substitution contract phrases it.)

### --changes

Changes-consistency review mode. Orthogonal to `--base` and combinable with it (`--base --changes`): `--base` constrains the KIND of proposals allowed, `--changes` redirects the FOCUS/target of the review onto the modified material and its blast radius. When `$ARGUMENTS` contains `--changes`, substitute the following block for `{CHANGES_MODE_CONSTRAINT}` in the review agent prompt:

```
CHANGES MODE CONSTRAINT:
This design document was already reviewed once; your job this round is to review the MODIFICATIONS made to it since then — for consistency with the rest of the document and for soundness in their own right. Actively judge what changed.
- DO identify the changed material yourself: if a user-provided note appears above, treat it as the authoritative focus for what changed; otherwise infer the recently-modified or suspect sections from the document itself (newer or out-of-place phrasing, additions the surrounding sections have not caught up to, passages that now sit inconsistently against the rest).
- DO verify ripple consistency: for each change, check that the rest of the document still agrees with it — data models, API contracts, sequence flows, requirement traces, and implementation order that reference or depend on the changed material must remain mutually consistent. Flag any section the change has left stale or contradictory.
- DO re-question the changes themselves: do not assume a change is correct merely because it was made. Re-examine each change for soundness, completeness, and feasibility on its own terms, exactly as you would scrutinize a fresh design decision.
- DON'T expend the round re-reviewing unchanged material the changes neither touch nor affect; concentrate effort on the changed material and its blast radius.
- If a BASE MODE CONSTRAINT also appears above, it remains authoritative on the KIND of proposals you may emit: re-questioning a change must still respect it — surface inconsistencies, contradictions, and essential consistency supplements, but do NOT treat "re-questioning" as license to propose new task-level implementation detail or to remove/reduce existing detailed content. --base governs what kinds of findings are allowed; this block governs where you focus.
```

When `--changes` is not present, substitute the `{CHANGES_MODE_CONSTRAINT}` placeholder with a single empty line. The reconcile bullet self-activates via its `"If a BASE MODE CONSTRAINT also appears above…"` wording, so no 4-way branch logic is needed — it is naturally inert when no BASE block precedes it.

## Constraints

- All review agents use model `"sonnet"` (haiku and opus forbidden — lite quality floor).
- **Auto-decide protocol is fully disabled**: every `decision`-type proposal escalates to the user. There is no `--auto-decide-dominant` / `--no-auto-decide-dominant` flag.
- **Deferred tool loading**: Before using AskUserQuestion (or any other deferred tool used by Agent infrastructure for review-agent spawning), you MUST first load it via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion" before any user prompt step. Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md` and apply its hard constraints to every AskUserQuestion call in this skill.

## Begin

$ARGUMENTS
