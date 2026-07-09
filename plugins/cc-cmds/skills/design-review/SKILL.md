---
name: design-review
description: 설계 문서 최종 리뷰
when_to_use: 작성된 설계 문서를 다중 반복 에이전트 리뷰(외부/내부 사이클)로 최종 검증·수렴시키고자 할 때
disable-model-invocation: true
usage: "/cc-cmds:design-review <design-doc-path> [--base] [--changes] [--no-auto-decide-dominant]"
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
    - name: "--auto-decide-dominant"
      kind: flag
      noop: true
      default: "(no-op alias — auto-decide는 기본 ON)"
      summary: "명시적 opt-in 별칭. 현재 기본값이 이미 ON이라 실질 no-op; 역호환·명시성 목적으로 허용."
    - name: "--no-auto-decide-dominant"
      kind: flag
      default: "off (즉, auto-decide 활성)"
      safety: true
      summary: "Decision Auto-Select Protocol(§8)을 세션 전체에서 비활성화"
      safety_summary:
          - "**기본 동작** — 별도 플래그 없이 auto-decide ON. Dominance Threshold(§8) 충족 시 `decision`-type 제안을 자동 선택하고 `[AUTO-DECIDED]`로 기록."
          - "**Blackout** — B1–B10 카테고리(파괴적 작업, 사용자 특화 결정, B7/B8/B9 조건부 체크리스트 포함)는 항상 사용자에게 escalate."
          - "**Revert** — 자동 결정된 항목은 `AUTO-NNN` 또는 `PROP-Rx-y` 참조로 언제든 되돌릴 수 있음 (§8.11)."
          - "**Opt-out (invocation)** — `--no-auto-decide-dominant` 지정 시 전체 세션에서 비활성화, 세션 중간 재활성화는 불가."
          - '**Opt-out (mid-session)** — 다이얼로그 프롬프트에서 "자동 선택 중단" 같은 자연어 트리거로도 비활성화 가능 (§8.10 regex, 이후 재활성 불가).'
          - '**Outer-cycle continuation** — 자동 결정이 한 건이라도 발생한 outer iter는 ripple 검증을 위해 한 iter 더 실행됨. 사용자 체감: "왜 리뷰가 더 오래 걸리지?"'
          - "**Persistence** — `AUTO_DECIDE_ENABLED`는 outer iter 간 `outer_log.md`로 복원(§8.12) — bash 변수 휘발성 대응."
---

Perform a final review of the design document using a two-tier cycle (outer + inner).

All analysis work and inter-agent communication should be in English to optimize token usage.
User-facing communication (summaries, questions, status updates) should be in Korean.

## Overview

This command wraps `design-review`'s inner loop in an outer cycle. Each outer iteration spawns a **completely fresh** inner loop against the current document state with a cleared `INNER_TEMP_DIR`, preserving only the user-persistent `ack_items.md` and the design document itself. This prevents the "context poisoning" where long inner loops drift from re-confirmation toward rebuttal, while still letting ack items ratchet across iterations.

The outer cycle exits when an inner iteration reaches `clean-convergence` (§3.11 severity + saturation rule) AND no escalation was actually applied during that iteration (`COUNT_APPLIED == 0`, §3.3 step 17 / §8.8 formula).

## Review Criteria

Requirement consistency, internal coherence, feasibility, implementation order, missing items, and any other perspective important in the context of this specific design.

---

## Control-Flow Invariants

These formulas govern termination and classification. They MUST remain inline (not in `references/`) because SKILL.md has post-compaction re-attachment priority (first ~5K tokens) while `references/` reads may be summarized away. A summarized invariant yields silent mis-termination.

#### Round/iteration advance ordering (no look-ahead spawn)

The inner loop's correctness rests on a happens-before ordering between adjacent rounds and adjacent outer iterations — NOT on any turn count. It binds at exactly two boundaries and nowhere else:

- **Round boundary**: the main session MUST NOT spawn round N+1's review `Agent()` until round N's resulting Edits are on disk. A review agent reads the document on spawn; if round N+1's agent spawns before round N's edits have landed, it reviews stale text and every proposal it returns is grounded in a document state that no longer exists. **ASYNC enforcement**: a synchronous round blocks this structurally, but an async spawn returns its envelope immediately, so the ordering is prose-enforced in the async case — confirm round N's witness → record round N → round N's Edits land on disk → only then `inner_round += 1` and spawn round N+1; never batch round N+1's spawn with round N's recording. Do NOT move round-number derivation to write-time or relax this ordering — either silently breaks both the round-N witness gate in Step 12.detect AND the first-round-N-witness-wins dedup, which both assume a respawn self-derives the SAME N.
- **Iteration boundary**: the main session MUST NOT initialize iter K+1's `INNER_TEMP_DIR` (Step 7) until iter K's per-iteration summary work (Steps 17–21 — `COUNT_APPLIED`, ack extraction, table/log rows, and the `INNER_TEMP_DIR` wipe) has completed against the agent results actually observed in iter K.

This ordering is scoped to the spawn/init boundary ONLY. It deliberately does NOT constrain intra-round activity: one round may issue many tool calls in a single turn (self-triage, reference Reads, batched auto-approve Edits, auto-decide, AskUserQuestion fan-out), and one round may span multiple turns (the dialogue loop on an escalated proposal runs across several turns, all still inside round N). The "batch independent edits in one message" practice stays fully valid for those intra-round Edits — but it does NOT apply across a round/iteration boundary, because round N+1's input IS round N's applied output and the rounds are therefore not independent units of work. The one forbidden move is forward progress across a boundary on unobserved upstream work: there is no look-ahead spawn — never spawn the next round's agent before this round's edits are on disk, and never open the next iteration before this iteration's summary work is done.

#### Observed-result precondition (anti-fabrication — hard fail-closed gate)

This precondition is independent of the ordering rule above and is NOT waivable under any time, batching, or economy pressure. The main session MUST NOT write any round-N record — disposition tag (`[APPROVED]` / `[MODIFIED]` / `[USER-DIRECTED]` / `[AUTO-DECIDED]` / `[AUTO-APPROVED]` / `[AUTO-REJECTED]` / `[REJECTED]`), `COUNT_APPLIED` / `escalate_applied` input, `INNER_EXIT_REASON == "clean-convergence"` (or any convergence verdict), convergence-table row, ack delta, or `## Outer Iteration N` outer_log entry — unless round N's review Agent() actually returned and that return was observed at some point during round N. The on-disk round-N proposals and round summary are the persisted PRODUCT of that observed return (carrying grounding across turns for deferred dispositions); they are NOT themselves the grounding, and neither may be authored by the main session to manufacture grounding.

Decision procedure before writing any round-N record: "Did I actually spawn round N's agent and observe its return at some point during this round?" If you cannot affirm a real observed return — or you are uncertain — **fail closed**: do not record, do not count, do not declare convergence; instead spawn (or re-spawn) the agent, wait for its real return, then write. Re-spawn is the cheap safe direction (a redundant fresh review only costs tokens; a fabricated record corrupts termination). A convergence verdict or `COUNT_APPLIED` tally is a factual claim that specific agent work happened; writing one for a round whose agent never spawned or never returned is fabrication and is absolutely forbidden. (The deferred-disposition case is explicitly fine: round N's agent really returned and its proposals are on disk; finalizing those dispositions turns later after the user decides is grounded, not fabricated.)

**Branch-specific grounding of "observed" (detect-branch hybrid).** "returned" in this gate means an *inline return* (SYNC) or a *confirmed round-N witness* (ASYNC), and the evidence differs per branch:

- **SYNC** — an inline tool result carrying a `<usage>…duration_ms…</usage>` envelope-tail signature AND no `output_file:` / `Async agent launched successfully.` marker **in the envelope** (the header/marker lines, never agent body text — the same tokens appearing in body prose never count). Both halves are envelope-anchored, symmetric with the ASYNC marker match. Structural observation: the recording block is unreachable without the inline return.
- **ASYNC** — the agent-authored, round-N-keyed `## Review Round N` round-summary witness in `review_log.md` — written by the spawned agent, NOT by the main session and NOT a drop-prone notification. The single trustworthy completion primitive is this **round-N summary line in review_log.md**; in-file round-N keying is the sole completion check — no external status-query mechanism substitutes for it.

**ASYNC stall liveness (witness-absent respawn — tri-state).** Per ASYNC spawn, the witness-absent control point in Step 12.detect maintains a **durable** stall-state file `$INNER_TEMP_DIR/.async_stall.json` (leading dot = machine-internal; wiped wholesale by the Step 21 `INNER_TEMP_DIR` teardown, so it never touches VCS and needs no terminal strip). Schema: `{schema, inner_round, output_file, last_output_bytes, reentry_count, growth_streak, unavail_streak}` — `schema` is a strict-equality migration guard (a mismatched value ⇒ discard and re-initialize; active-notify v1.5.0 helper precedent). **One durability class**: every counter AND the byte baseline live in this one file, whole-written each re-entry and re-derived from disk on the next — no counter is context-local, so the "durable counter + ephemeral baseline ⇒ infinite resurrection" failure mode is structurally impossible across compaction.

**Initialization / reset (three points).** (i) On each spawn and each round-advance: if the file is absent OR its `inner_round` ≠ the current round, re-initialize — `reentry_count=0`, `growth_streak=0`, `unavail_streak=0`, `last_output_bytes=∅`, `output_file=<fresh>`, `inner_round=<current>` (a prior round's stall observations are discarded at the round boundary). (ii) On same-round death→respawn (the file exists and `inner_round` already matches, so (i) does not fire): explicitly zero all three counters and set `last_output_bytes=∅` at the respawn point — the fresh agent must not inherit the dead run's stall observations. (iii) Per re-entry path reconcile: if a freshly-captured `output_file` path differs from the stored `output_file` field, set `last_output_bytes := ∅` (a path change self-invalidates the baseline); the `output_file` field folds the path-tag role, so no separate field is needed. A pure post-compaction re-entry with no fresh path keeps the stored path as authoritative.

**Per re-entry, in order.** One re-entry = exactly one turn-yield-and-return cycle back to the witness-absent control point, regardless of trigger (notification early-wake, `output_file` mtime/size check, any later turn). (1) floor-read review_log.md — if the round-N witness is now present ⇒ observed-return, stop. (2) determine `output_file` availability and, if available, its byte-count `b` (apply the path reconcile above). (3) **classify tri-state** `(availability, b vs last_output_bytes)`:
- **ALIVE** — available ∧ (`b ≠ last_output_bytes` OR `last_output_bytes = ∅` warmup): `reentry_count = 0`, `unavail_streak = 0`, `growth_streak += 1`, `last_output_bytes = b`. Growth is an unconditional death veto.
- **WEDGED** — available ∧ `b == last_output_bytes`: `reentry_count += 1`, `unavail_streak = 0`, `growth_streak = 0`.
- **UNKNOWN** — `output_file` UNAVAILABLE (path absent / dangling): `reentry_count` unchanged, `unavail_streak += 1`, `growth_streak = 0`. **There is no `output_file absent ⇒ death` arm** — unavailability is not a death tally; a slow-but-live reviewer whose path is momentarily unreadable must not be killed.
(4) whole-write `.async_stall.json`. (5) evaluate death; if not dead, yield (emit one Korean line).

**Declare the agent dead ⟺ ALL THREE conjuncts hold: `reentry_count ≥ K` (K=3) AND the current classification is WEDGED AND a FINAL re-confirmation (adjacent to `TaskStop`) finds the round-N witness still absent.** Growth always vetoes (an ALIVE classification zeroes `reentry_count`). On death → `TaskStop(agentId)` → respawn in the SAME inner_round (`inner_round` is NOT incremented, the round is re-run) with reset (ii) applied. **Never declare death on `reentry_count ≥ K` alone, and never restate this predicate in any form that omits the WEDGED conjunct** — dropping the byte-stability conjunct would let an actively-writing original be killed. That byte-stability conjunct now rests on a **single** ground — **(a) do not kill an active writer** — which holds regardless of how `review_proposals.md` is published; round-keyed atomic publish dissolved the former second ground (torn-write reopening), because a round-unique filename makes same-round and cross-round corruption structurally impossible.

**Escalation (never a kill; death stays gated by `reentry_count ≥ K`).** Two liveness anomalies escalate to the user instead of killing: **babbling** (`growth_streak ≥ G`, G=5 — the reviewer keeps writing but never publishes the witness) and **persistent UNKNOWN** (`unavail_streak ≥ U`, U=3 — the signal path stays unreadable). Both raise the existing inner safety-limit 3-option `AskUserQuestion` as a distinct trigger (Step 16) — no new option, no new `INNER_EXIT_REASON`; default recommendation **A: keep waiting** (growth and UNKNOWN are positive evidence of a live-but-slow agent). On option A, reset ONLY the triggering streak to 0 (`growth_streak := 0` for babbling / `unavail_streak := 0` for UNKNOWN) before returning to the wait loop — otherwise the durable streak stays at threshold and re-fires every re-entry (ask-storm); the death gate `reentry_count` is orthogonal and untouched. The reset reuses existing schema fields (no dynamic-threshold field), and the streak must re-accumulate to threshold before re-asking, giving a debounce equivalent to the canonical grace period.

**fail-closed (hard gate — both SYNC and ASYNC branches)** — never counted as observation: (1) a notification arrival (may drop / duplicate / mis-route; it never enters the predicate), (2) the existence of a round-keyed `review_proposals.r<N>.md` file — the filename identifies the round, but existence alone cannot prove an observed return (a partial write or a zombie write can create it); completion is proved solely by the round-N witness in `review_log.md`, (3) any record written while the round-N witness is absent. Conversely — a fail-closed READ arm, branch-neutral — **after an observed return** (a SYNC inline return OR the ASYNC round-N witness), if the round-N proposals file is absent, do NOT treat it as a review of zero proposals: fail closed (re-read, and respawn in the SAME inner_round if still absent). Because the Step 8 seed is gone, the round-keyed file exists only when the agent actually published it, so an absent file after an observed return is always a lost write, never an empty review. On-disk artifacts are the persisted PRODUCT of an observed return, never authored by the main session to manufacture grounding. **Re-spawn is the cheap safe direction** holds in both branches.

**Sole anti-fabrication anchor (ASYNC).** There is no external completion cross-check, so the entire async anti-fabrication guarantee rests on one fact — **the `## Review Round N` round-summary header is authored ONLY by the spawned review agent** (it appends the header after completing its review). The main session's own `review_log.md` writes are disposition tags / informational markers and the `## Outer Iteration N` block — it never authors a `## Review Round N` header. If that sole-authorship breaks, the witness becomes forgeable.

### Inner convergence predicate (§3.11)

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
# [AUTO-DECIDED], [AUTO-APPROVED], [REJECTED], [AUTO-REJECTED] all count
# if the proposal's severity is critical/major.
final_critical_or_major = |{p : p.severity (post-upgrade) ∈ {critical, major}}|

if final_critical_or_major == 0:
  consecutive_no_major += 1
else:
  consecutive_no_major = 0   # even a single approved major resets
```

**Critical rule**: severity is a property of the **proposal itself**, not its outcome. A `[APPROVED]` major proposal still counts toward `final_critical_or_major`. `consecutive_no_major` increments only when the round produces **zero** critical/major proposals — regardless of how many were resolved. Background/rationale → see `references/03-severity-exit-policy.md`.

### Outer termination judgment (§3.3 Step 22)

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

**`this_iter_verify_ran` (criterion #7, F5 silent-termination guard)**: the count of `[VERIFY-RAN]` cat-1 self-runs that mutated the ledger **this iteration**. It is an **independent counter**, kept OUT of `COUNT_APPLIED` / `escalate_applied` and every itemize render — it adds exactly one term to the predicate above so an iteration that ran a cat-1 self-run forces one more outer iteration (a fresh-agent ripple-verify of the just-recorded verdict). Sourced from the dedicated `- [VERIFY-RAN] (별도 카운터, escalate 합 밖): {count}` line in this iteration's `## Outer Iteration N` block (computed from `review_log.md` before the Step 21 wipe; mandatory every iter — 0 is written when none, so Step 22 reads a value and never infers absence as 0). See "## Verification dimension (criterion #7)".

### `COUNT_APPLIED` aggregation (§3.3 Step 17 / §8.8 dedup)

```
(a) Collect all lines in $INNER_TEMP_DIR/review_log.md tagged
    [APPROVED], [MODIFIED], [USER-DIRECTED], [AUTO-DECIDED].
(b) Group by PROP-ID (e.g., PROP-R2-3).
(c) For each group:
    - If both [AUTO-DECIDED] and [USER-DIRECTED] appear (revert scenario, §8.11),
      count only [USER-DIRECTED] (the [AUTO-DECIDED] is collapsed out).
    - If partial_apply=true markers exist for the proposal at multiple locations,
      count 1 per group (not per location).
    - Otherwise, 1 per group.
(d) COUNT_APPLIED = sum of group counts.
```

### `escalate_applied` formula (§8.8)

```
raw_count = count([APPROVED]) + count([MODIFIED]) + count([USER-DIRECTED]) + count([AUTO-DECIDED])

escalate_applied = raw_count
                 − |{PROP-ID groups where [AUTO-DECIDED] AND [USER-DIRECTED] co-exist}|
                 − |partial_apply duplicates within group|
```

`[AUTO-DECIDED]` is counted — otherwise silent termination risk (F5). Uncounted tags: `[AUTO-APPROVED]`, `[AUTO-REJECTED]`, `[REJECTED]`.

### Disposition tag set (§3.5 + §8.8)

| Tag | 문서 변경 | escalate_applied | Ack set |
|---|---|---|---|
| `[AUTO-APPROVED]` | ✓ | ✗ | ✗ |
| `[AUTO-REJECTED]` | ✗ | ✗ | ✓ |
| `[AUTO-DECIDED]` | ✓ | **✓** | ✗ |
| `[APPROVED]` | ✓ | ✓ | ✗ |
| `[REJECTED]` | ✗ | ✗ | ✓ |
| `[MODIFIED]` | ✓ | ✓ | ✗ |
| `[USER-DIRECTED]` | ✓ | ✓ | ✗ |

**Informational markers** (not disposition tags; never counted; may appear alongside a disposition tag): `[SEVERITY-UPGRADED]` (§3.11), `[REVERTED-BY-USER]` (§8.11; supports `cascade=true` and `cascade-from=PROP-Rx-y`), `[REVERT-FAILED]` (§8.11).

**Independent counter** (criterion #7; NOT a disposition tag, NOT in `escalate_applied`/`COUNT_APPLIED`, NOT in any itemize render): `[VERIFY-RAN]` (Category `verification-bookkeeping`) — a cat-1 verification self-run that mutated the ledger. doc-change ✓ / escalate_applied ✗ / ack ✗ / outer-termination-guard ✓ (it adds the `this_iter_verify_ran == 0` term to the Step 22 predicate). The `지금 검증 실행` and `잔여 항목으로 기록` menu dispositions ARE `[APPROVED]`-class (counted in `COUNT_APPLIED`); `거부 (현재 유지)` is `[REJECTED]`-class (ack). See "## Verification dimension (criterion #7)".

### Decision-type classifier (§8 top-level gate)

Only `decision`-type proposals are candidates for auto-decide. `verification`-type proposals (criterion #7) bypass this classifier **structurally** — Type ≠ `decision`, so `re_evaluate_decision` is never called (auto-decide must never choose run-vs-defer; execution is a real-world side effect). For each decision-type proposal after self-triage returns `escalate`, call `re_evaluate_decision` (details in `references/01-auto-decide-protocol.md`):

```
auto-decide fires iff ALL of the following hold:
  PRE-CHECK 0: blackout guard passes
  AND PRE-CHECK A: single-option guard passes
  AND (T1-A OR T1-B OR T1-C OR T2-AB)                         # dominance tier
  AND signal #3: order-invariance
  AND signal #4: dimension totality (embedded inside T1-C)
  AND signal #5: no prior [AUTO-DECIDED] premises
  AND signal #7: counterfactual self-test (T2 uses stricter bar)
```

**Rule of thumb**: "When in doubt, escalate."

### Processing Protocol trigger regex (§8.11, §8.12)

On every user response to a proposal prompt, match these patterns BEFORE normal disposition handling:

- **§8.12 Opt-out trigger**: `(자동결정|자동 선택|auto.decide)` + `(중단|끄|해제|그만|비활성|수동|직접)`
- **§8.11 Reversion trigger**: `(PROP-Rx-y|AUTO-NNN|방금|전부)` + `(취소|되돌리|번복|롤백|revert|undo)` — AUTO-NNN precedes PROP-ID on ID conflict.

On match, Read `references/02-processing-protocol-detail.md` and execute the full action sequence. Otherwise fall through to the "Disposition handling (normal path)" below.

---

## Strategy

### Phase 1: Outer Session Setup

1. Read the full design document to verify existence and parseability.
2. Parse `$ARGUMENTS` to detect and strip `--base`, `--auto-decide-dominant`, and `--no-auto-decide-dominant`. Auto-decide-dominant defaults ON; `--no-auto-decide-dominant` opts out. Create the outer-session directory and initialize files:

```bash
# --- Outer Session Isolation ---
# 1. Command name
COMMAND_NAME="design-review-outer"

# 2. Strip flags from arguments
ARGS_CLEAN=$(echo "$ARGUMENTS" | awk '{
  for(i=1;i<=NF;i++) if($i!="--base" && $i!="--changes" && $i!="--auto-decide-dominant" && $i!="--no-auto-decide-dominant") printf "%s%s", $i, (i<NF?" ":"")
}')

# 3. Detect flags
# Auto-decide-dominant is ON BY DEFAULT. Pass --no-auto-decide-dominant to disable.
# --auto-decide-dominant remains accepted as an explicit opt-in (no-op when default is true)
# for backward-compatible invocations and documentation clarity.
BASE_MODE=false
CHANGES_MODE=false
AUTO_DECIDE_INITIAL=true
for arg in $ARGUMENTS; do
  [ "$arg" = "--base" ] && BASE_MODE=true
  [ "$arg" = "--changes" ] && CHANGES_MODE=true
  [ "$arg" = "--auto-decide-dominant" ] && AUTO_DECIDE_INITIAL=true
  [ "$arg" = "--no-auto-decide-dominant" ] && AUTO_DECIDE_INITIAL=false
done

# 3.5. USER_NOTE extraction (trailing free-text after doc-path token 1; positional, not a flag)
# Blank token 1 (doc-path) and print the rest. Always run; empty when no trailing note.
# Injected as {USER_NOTE} regardless of --changes: change focus when --changes, general review context otherwise.
USER_NOTE=$(echo "$ARGS_CLEAN" | awk '{$1=""; sub(/^ +/,""); print}')

# 4. REPO_NAME extraction (document stem → repo basename → cwd basename)
REPO_NAME=$(echo "$ARGS_CLEAN" | awk '{print $1}' | xargs basename 2>/dev/null)
REPO_NAME="${REPO_NAME%.md}"
[ -z "$REPO_NAME" ] && REPO_NAME=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename)
[ -z "$REPO_NAME" ] && REPO_NAME=$(basename "$(pwd)")
[ -z "$REPO_NAME" ] && REPO_NAME="unknown"
REPO_NAME=$(echo "$REPO_NAME" | tr -cs 'a-zA-Z0-9_-' '_' | sed 's/^_//;s/_$//' | cut -c1-30)
REPO_NAME="${REPO_NAME%_}"

# 5. Outer session ID & directory
OUTER_TS=$(date +%Y%m%d_%H%M%S)
OUTER_SESSION_ID="${COMMAND_NAME}_${REPO_NAME}_${OUTER_TS}"
OUTER_DIR="docs/_temp/${OUTER_SESSION_ID}"
mkdir -p "$OUTER_DIR"
```

3. **Before initializing the three outer-persistent files, Read `${CLAUDE_SKILL_DIR}/references/04-file-schemas.md`** for the canonical schemas of `outer_log.md`, `ack_items.md`, and `convergence_table.md`. Then initialize:

```bash
# outer_log.md header
cat > "$OUTER_DIR/outer_log.md" <<EOF
# Outer Cycle Audit Log

<!--
Session: ${OUTER_SESSION_ID}
Document: $(echo "$ARGS_CLEAN" | awk '{print $1}')
Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
AUTO_DECIDE_INITIAL: ${AUTO_DECIDE_INITIAL}
BASE_MODE: ${BASE_MODE}
CHANGES_MODE: ${CHANGES_MODE}
USER_NOTE: ${USER_NOTE}
-->
EOF

# ack_items.md header
cat > "$OUTER_DIR/ack_items.md" <<'EOF'
# Acknowledged Items

_Items decided to keep as-is during this design-review session. Do NOT re-propose._

---
EOF

# convergence_table.md headers (two tables — see references/04-file-schemas.md)
cat > "$OUTER_DIR/convergence_table.md" <<'EOF'
# Convergence Tables

## 처리 결과 현황표

| 이터 | 라운드 | 자동승인 | 자동거부 | 자동결정 | 에스적용 | 에스거부 |
| :--: | :----: | :------: | :------: | :------: | :------: | :------: |

## 수렴 진단표

| 이터 | 적용실패 | 부분종료 | ack수 |  종료사유  |
| :--: | :------: | :------: | :---: | :--------: |
EOF
```

4. **First-time auto-decide warning** (§8.9): Auto-decide-dominant is **ON by default**. If `AUTO_DECIDE_INITIAL=true` (i.e., the user did not pass `--no-auto-decide-dominant`), **eager-load `${CLAUDE_SKILL_DIR}/references/01-auto-decide-protocol.md`** (this is the §8 algorithm). Then emit this Korean warning to the user exactly once at session start:

```
ℹ️ 자동결정 모드가 활성화되어 있습니다 (기본값).

일부 결정형 제안이 사용자 확인 없이 자동 선택될 수 있습니다.
자동결정이 발생한 이터레이션은 외부 사이클이 한 번 더 진행되어 fresh agent 그룹이 ripple 효과를 독립 검증합니다.

자동 선택 내역은 매 이터레이션 요약의 '자동 선택 내역' 섹션에서 확인할 수 있습니다.
되돌리려면 다음 에스컬레이션 프롬프트에 "PROP-Rx-y 자동결정 취소해줘" 또는
"AUTO-NNN 롤백"을 입력하세요 (대화 프롬프트 시점에만 입력 가능).
자동 결정을 즉시 중단하려면 "자동 선택 중단"이라고 입력하세요.
이번 세션 전체에서 비활성화하려면 다음 호출 시 "--no-auto-decide-dominant" 플래그를 추가하세요.
```

5. Initialize outer loop state: `outer_iter = 0`, `outer_done = false`. Proceed to Phase 2.

### Phase 2: Outer Iteration Loop

Loop while `outer_done == false`:

**Step 6 — Advance outer iteration**: `outer_iter += 1`

**Step 6.5 — Restore `AUTO_DECIDE_ENABLED` from file** (§8.12 persistence):

Claude Code bash variables are volatile across turns, so the runtime flag must be restored from `outer_log.md` at the start of every outer iteration:

```bash
# If ### Auto-Decide Opt-Out section exists in outer_log.md, opt-out is active
if grep -q '^### Auto-Decide Opt-Out$' "$OUTER_DIR/outer_log.md" 2>/dev/null; then
  AUTO_DECIDE_ENABLED=false
else
  AUTO_DECIDE_ENABLED=${AUTO_DECIDE_INITIAL}
fi
```

**Step 7 — INNER_TEMP_DIR**:

```bash
INNER_TEMP_DIR="${OUTER_DIR}/iter-$(printf '%03d' $outer_iter)"
mkdir -p "$INNER_TEMP_DIR"
```

**Step 8–9 — Empty inner files** (schemas in `references/04-file-schemas.md`):

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

Perform agent-based iterative review until severity saturation (§3.11). Each round spawns a **fresh** review agent that independently reviews the document from scratch.

**Step 12** — `inner_round += 1`. Spawn a review agent. **The review agent's `Agent()` call MUST omit the `model` parameter** — the harness's parent inheritance then passes the orchestrating session model straight through, so the review model is deterministic within a session and tracks the user's cost choice. Do NOT inject the session model as an explicit literal: a sonnet/haiku main loop helpfully naming its own tier would create reverse drift. This bind is prose-enforced only; the residual drift risk of a future orchestrator resuming literal injection is an interpretable model misjudgment, explicitly accepted per the repo's delegated-judgment-residual norm (no always-on monitoring hook).

**haiku 가시성 notice (best-effort, 세션당 1회)**: 세션의 첫 리뷰 에이전트 spawn 직전(즉 `outer_iter == 1` 그리고 `inner_round == 1`인 시점)에, 메인 세션이 자기 세션 모델을 haiku로 판단하면 한국어 prose 1줄을 emit한다 — 예: "⚠️ 터미널 설계 게이트가 haiku 모델로 실행 중입니다 — 발견이 얕을 수 있습니다. 더 깊은 리뷰가 필요하면 sonnet/opus 세션에서 재실행하세요." 이는 floor(동작 변경)가 아니라 정보 제공이며 모델 self-ID에 의존하는 best-effort다: 미발화는 현상유지(benign — 다운그레이드 경로 없음)다. haiku는 명시적 `/model haiku`·`--model haiku`·`ANTHROPIC_MODEL=haiku`로만 도달하므로, notice의 대상은 항상 세션 전체를 cheapest로 의도 선택한 사용자다.

**Before spawning the review agent, Read `${CLAUDE_SKILL_DIR}/references/06-review-agent-prompt.md`** and substitute `{TEMP_DIR}` (= actual `INNER_TEMP_DIR`), `{USER_NOTE}` (the trailing note when non-empty, else empty), `{BASE_MODE_CONSTRAINT}` (the `--base` block when `BASE_MODE=true`, else empty), and `{CHANGES_MODE_CONSTRAINT}` (the `--changes` block when `CHANGES_MODE=true`, else empty) per the file's substitution contract, then prepend the path context block before calling `Agent()`. Pass `run_in_background: false` as a hint — but do not infer from this that async delivery is impossible; a host that ignores the hint routes the result through the notification channel, placing this round in the ASYNC branch.

**Step 12.detect — Classify the spawn result (detect-branch hybrid).** Immediately after `Agent()` returns, classify its tool result with a two-sided positive signature *before recording anything* — the harness may launch the round agent asynchronously on some session hosts regardless of the `run_in_background: false` request, so the spawn cannot be assumed synchronous:

- **SYNC** ⟺ tool result carries a `<usage>…duration_ms…</usage>` tail — e.g. `<usage>input_tokens: 1200, duration_ms: 3450</usage>` — (positive evidence: `duration_ms` key present inside the `<usage>` block) AND has no `output_file:` / `Async agent launched successfully.` marker in the envelope. The inline result IS the observed return — proceed directly to (a)–(j) below with no agentId tracking, no on-disk read, no yield (reconcile 0, wait 0). This is identical to the committed synchronous behavior.
- **ASYNC** ⟺ the tool-result ENVELOPE (its header/marker lines, typically the leading lines ahead of the agent body, NOT agent body text) contains `output_file:` or `Async agent launched successfully.`. Match these tokens in envelope position only — the same tokens inside agent body prose (this design corpus discusses them) never trigger classification, symmetric with SYNC's envelope-tail `<usage>` anchor. Capture agentId + output_file, confirm from on-disk witness:
    - async_observed_return(round N) ≡ agent-authored `## Review Round N` header in $INNER_TEMP_DIR/review_log.md (round-N keyed; M≠N never satisfies). N is the round index the review agent derives at spawn time by counting existing `## Review Round` headers (count + 1), equal to `inner_round` per the CFI ASYNC-enforcement ordering — see CFI; do not duplicate that invariant here.
    - **witness present** → observed return. Read `$INNER_TEMP_DIR/review_proposals.r$inner_round.md` and proceed to (a)–(j). An already-finished async costs 2 reads, 0 yield.
    - **witness absent** → default to waiting (NOT respawn). Apply the **ASYNC stall liveness predicate** defined in the Control-Flow Invariants section: maintain the durable `.async_stall.json` stall-state (tri-state ALIVE/WEDGED/UNKNOWN), floor-read review_log.md once per re-entry, emit one Korean line per witness-absent yield, respawn in the SAME inner_round only when all three CFI death conjuncts hold, and escalate (not kill) on the babbling / persistent-UNKNOWN streak triggers. Do NOT inline a second copy of the predicate here — CFI is the single authority (this block may be compacted; CFI is not). Soft liveness signals (`output_file` growth · early-wake notification) are acceleration hints, never a gate.
    - **first-round-N-witness-wins dedup**: if a respawned agent and a merely-slow original both append `## Review Round N`, the convergence parser adopts only the FIRST round-N witness and ignores later duplicate `## Review Round N` blocks (a double-count/correctness concern, not anti-fabrication — it keeps the predicate deterministic even when `TaskStop` fails to kill the zombie).
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
  f. **Auto-decide integration** (§8, conditional on `AUTO_DECIDE_ENABLED=true`): for each `decision`-type proposal, after self-triage decides "escalate", **Read `${CLAUDE_SKILL_DIR}/references/01-auto-decide-protocol.md` unconditionally** (recovery gate — post-compaction may have summarized away the eager-load), then call `re_evaluate_decision` (§8.4). If the verdict is `auto-pick`, record `[AUTO-DECIDED]` to `review_log.md`, apply the chosen option via Edit, and append an `AUTO-NNN` entry to the in-memory audit buffer for Step 20. If the verdict is `escalate`, fall through to the ask-user step. If `AUTO_DECIDE_ENABLED=false`, skip this hook entirely.
  f-v. **Verification findings (criterion #7, Type `verification`)**: never auto-decided (the §8 classifier is bypassed structurally — Type ≠ `decision`). Route per the Self-Triage `Type: verification` branch — cat-1 (read-only) self-run + record (no user prompt, counted by the independent `[VERIFY-RAN]` counter); cat 2–4 → the closed 3-option verification menu; cat-5 (worktree) → 2-option degrade, never re-run. Executions are logged to `## Verification Runs`. **Never run a recipe an agent reported executing; discard agent-reported execution results unconditionally.** Full rules: "## Verification dimension (criterion #7)".
  g. **If escalated proposals remain**: Present only those to the user via AskUserQuestion (in Korean). See "Approval UX" below.
  h. Process user choices according to the "Processing Protocol" below. **Dialogue loop per Ground Rule #6**: if the user's response is a follow-up question or discussion rather than an explicit decision, continue the dialogue via AskUserQuestion until an explicit decision is given.
  i. Update the round entry in `$INNER_TEMP_DIR/review_log.md` with disposition tags.
  j. Briefly summarize this round's auto-handled items to the user in Korean (count + one-line per item) so they have visibility into self-triage decisions.

**Step 13 — Edit failure handling**: If an Edit fails (e.g., `old_string` not unique, target text changed):
  - Immediately notify the user: "제안 #N 적용 중 일부 위치에서 실패: [원인]"
  - Re-analyze the failed location and propose an alternative.
  - **Option A (apply after user confirmation)**: re-attempt with disambiguated context. On success, log disposition tag to `review_log.md`.
  - **Option B (defer to next round)**: append a `PEND-NNN` block to `$INNER_TEMP_DIR/pending_applies.md` per the schema in `references/04-file-schemas.md`.
  - **Partial success**: log the proposal with a `partial_apply=true` marker and record the failed locations in `pending_applies.md`.
  - Any `PEND-NNN` must later be resolved (success → remove block + log disposition; or user abandon → `[REJECTED]` + ack + remove block) before inner convergence is allowed.

**Step 14 — Severity aggregation** (post-upgrade final values — disposition irrelevant): See Control-Flow Invariants above for the `consecutive_no_major` formula. **Before evaluating, Read `${CLAUDE_SKILL_DIR}/references/03-severity-exit-policy.md`** for the tier taxonomy + main-session severity rules + the severity-vs-disposition orthogonality example.

**Step 15 — Inner convergence guard**: See Control-Flow Invariants (`inner_converged_cleanly()`). If true, set `INNER_EXIT_REASON = "clean-convergence"` and break out of the inner loop.

**Step 16 — Inner safety limit (20 rounds)**:

If `inner_round >= 20`, **Read `${CLAUDE_SKILL_DIR}/references/05-korean-ux-templates.md`** for the §3.9.4.b / §3.9.4.c prompt templates, then present 3 options via AskUserQuestion. Dynamic recommendation:

- `pending_dialogue > 0` → recommend **A: 10회 추가 진행** (finish open dialogues)
- `pending_dialogue == 0` → recommend **B: 이번 이터레이션 종료 후 새 이터레이션 시작** (escape stuck inner, preserve outer progress)

Option mapping to `INNER_EXIT_REASON`:

| Option | Action | INNER_EXIT_REASON |
|---|---|---|
| A: 10 라운드 추가 진행 | extend inner loop by 10 rounds (repeatable) | (not set, continue) |
| B: 이번 이터레이션 종료 후 새 이터레이션 시작 | break inner loop; next outer iter re-reviews from doc state | `safety-limit-fresh-outer` |
| C: 외부 이터레이션 전체 종료 | break inner loop; skip directly to Phase 3 cleanup | `safety-limit-outer-terminate` |

**Option B invariant**: A stuck inner loop must never block outer progress. Ack + document state are preserved, so the next fresh agent can re-review. Outer exit check (Step 22) bypasses convergence judgment when `INNER_EXIT_REASON == "safety-limit-fresh-outer"` — always continue.

**ASYNC-stall reuse trigger**: this same 3-option prompt is also raised — as a *distinct trigger*, with no new option and no new `INNER_EXIT_REASON` — when the CFI ASYNC-stall escalation fires (babbling `growth_streak ≥ G` or persistent-UNKNOWN `unavail_streak ≥ U`; see Control-Flow Invariants). For that trigger the default recommendation is **A: keep waiting / retry** (growth and UNKNOWN are positive evidence of a live-but-slow reviewer), the A/B/C → `INNER_EXIT_REASON` mapping is unchanged, and on A the triggering streak is reset to 0 before returning to the Step 12.detect wait loop (ask-storm debounce; the death gate `reentry_count` is untouched). The canonical 4-option Case-2 menu is deliberately NOT imported — its partial-synthesize option is structurally void for a single reviewer (no peer witness to synthesize).
If exit condition not met and not at safety limit → return to Step 12 with a new agent.

---

#### INNER LOOP COMPLETE — Per-iteration summary work (Step 17–21)

**Step 17 — Compute `COUNT_APPLIED`**: Use the formula in Control-Flow Invariants. Feeds Step 22.

**Step 18 — Extract new ack items**:

**Before writing, Read `${CLAUDE_SKILL_DIR}/references/04-file-schemas.md`** for the `ack_items.md` schema (8-field record, dedup rule).

Parse `$INNER_TEMP_DIR/review_log.md` for `[REJECTED]` and `[AUTO-REJECTED]` lines. For each, compose an `ACK-NNN` record with the 8 fields (Source, Disposition, Category, Location, Issue, Reference text, User/Auto-reject rationale, Recorded).

**Dedup rule** (§3.7): an ack is a duplicate of an existing entry in `$OUTER_DIR/ack_items.md` iff ALL three conditions hold:

1. `Category` matches exactly (controlled vocabulary: one of the 7 review categories)
2. `Location` refers to the same section (case-insensitive, "Section 4.3" ≈ "4.3 Auth Flow")
3. `Issue` describes the same root cause (main session semantic judgment)

Append only non-duplicate records to `$OUTER_DIR/ack_items.md` under a new `### From Iteration N` heading. **If zero new items are extracted for this iteration, do not append the `### From Iteration N` block at all.** Use monotonic zero-padded IDs (`ACK-001`, `ACK-002`, …).

**Step 19 — Append convergence table rows**:

**Before writing, Read `${CLAUDE_SKILL_DIR}/references/04-file-schemas.md`** for the `convergence_table.md` row format, then append one row to each of the two tables in `$OUTER_DIR/convergence_table.md` (§8.13.4):

```markdown
| {iter} | {rounds} | {auto_approved} | {auto_rejected} | {auto_decided} | {escalate_applied} | {escalate_rejected} |
| {iter} | {max_pending_applies} | {아니오|예} | {ack_size_after} | {exit_reason_ko} |
```

Where:
- Mark the iter column with ` ⚠️` suffix if `INNER_EXIT_REASON != "clean-convergence"` (partial iteration). Mark `escalate_applied` with `**0** ✓` bold-tick if the final value is 0 on a clean iteration.
- `max_pending_applies` is the maximum size `pending_applies.md` reached during the iteration (not the final value).
- `partial_flag` = `예` if `INNER_EXIT_REASON != "clean-convergence"`, else `아니오`
- `exit_reason_ko` ∈ {`정상수렴`, `내부한계`, `사용자중단`}
- **Invariant**: `exit_reason_ko == "정상수렴"` ⇒ `partial_flag == "아니오"`.

**Step 20 — Append outer_log.md iteration entry**:

**Before writing, Read `${CLAUDE_SKILL_DIR}/references/04-file-schemas.md`** for the `outer_log.md` Auto-Decides canonical schema. Append to `$OUTER_DIR/outer_log.md`:

```markdown
## Outer Iteration {outer_iter}

- Started: {ISO8601}
- Ended: {ISO8601}
- Inner TEMP_DIR: {INNER_TEMP_DIR}
- Inner rounds run: {n}
- Inner exit reason: {clean-convergence | safety-limit-fresh-outer | safety-limit-outer-terminate | user-abort}
- Partial iteration: {true|false}
- [VERIFY-RAN] (별도 카운터, escalate 합 밖): {count}   ← computed from review_log.md BEFORE the Step 21 wipe; mandatory every iter (write 0 when none); Step 22's `this_iter_verify_ran` source

### Escalate Counter Breakdown

- [APPROVED]: {count} "proposal IDs: ..."
- [MODIFIED]: {count} "proposal IDs: ..."
- [USER-DIRECTED]: {count} "proposal IDs: ..."
- [AUTO-DECIDED]: {count} "proposal IDs: ..."
- escalate_applied: {COUNT_APPLIED}  ← termination input (raw_count − dedup correction per §8.8)
- [REJECTED]: {count} ← NOT counted; added to ack set
- [AUTO-APPROVED]: {count} ← NOT counted
- [AUTO-REJECTED]: {count} ← NOT counted; added to ack set
- pending_applies_at_end: {"(none)" | PEND-NNN list}
- auto_decide_opt_out: {false | "true (triggered at round r, phrase: '...')"}

### Auto-Decides

(Emit this subsection only if at least one [AUTO-DECIDED] occurred this iteration — canonical schema in references/04-file-schemas.md)

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

**AUTO-NNN** is a session-monotone audit ID — allocate the next free number across all `### Auto-Decides` subsections in `outer_log.md` (start from `AUTO-001`). Claude Code bash variables are volatile; source the next free number by grepping existing entries: `grep -c '^- AUTO-' "$OUTER_DIR/outer_log.md" 2>/dev/null || echo 0`.

**Step 21 — Delete `INNER_TEMP_DIR`** (path guarded):

```bash
[[ "$INNER_TEMP_DIR" == "${OUTER_DIR}"/* ]] && rm -rf "$INNER_TEMP_DIR"
```

This deliberate wipe prevents "context poisoning" — the next iteration's fresh agent starts with only the ack seed and the document itself.

---

#### Outer Exit Check (Step 22–25)

**Step 22 — Outer termination judgment**: See Control-Flow Invariants for the decision tree. The predicate's `this_iter_verify_ran` term is read from the `- [VERIFY-RAN] …` line written into this iteration's `## Outer Iteration N` block at Step 20 (the count is computed from `review_log.md` before the Step 21 wipe). A cat-1 self-run iteration thus forces one more outer iteration for a fresh-agent ripple-verify; `escalate_applied` itemize renders are unchanged.

**Step 23 — Ack soft-limit check** (§3.7, only if `outer_done == false`):

Count entries in `$OUTER_DIR/ack_items.md` (lines starting with `#### ACK-`):

- **50 items**: advisory — append a one-line warning to the next iteration-transition summary: `⚠️ 인지됨 항목 {n}건 (50건 권고치 초과)`
- **100 items**: hard — ask the user via AskUserQuestion (header chip `인지 항목`; each option carries a `description`):
  - label `"A: 요약"` — description: Compress old ack entries into one-line-per-category summaries.
  - label `"B: 보관"` — description: Move entries from previous iterations to `$OUTER_DIR/ack_archive.md`, keeping only the current iter active.
  - label `"C: 현재 유지"` — description: Accept the prompt-length cost and do nothing.

Only run this check when `outer_done == false` — when `outer_done == true`, cleanup is imminent so ack size no longer matters.

**Step 24 — Outer safety limit (default 5 iterations)**:

If `outer_iter >= 5 AND outer_done == false`, **Read `${CLAUDE_SKILL_DIR}/references/05-korean-ux-templates.md`** for the §3.9.4.a prompt template, then present the extension/terminate prompt:

AskUserQuestion (header chip `안전 한계`; each option carries a `description`): label `"5회 추가 진행"` (description: 외부 이터레이션을 최대 5회 더 진행해 수렴을 시도합니다.) / label `"현재 상태로 종료"` (description: 추가 진행 없이 현재 상태로 리뷰를 종료합니다.). If the user chooses to terminate, break outer loop → Phase 3. If extended, raise the outer cap by 5 and continue.

**Step 25 — Iteration transition summary + auto-advance** (only if `outer_done == false`):

**Read `${CLAUDE_SKILL_DIR}/references/05-korean-ux-templates.md`** for the iteration-transition summary block (§3.9.2 / §8.13.3) and the split convergence table (§3.9.3 / §8.13.4). Emit them in Korean. No countdown or confirmation — auto-advance immediately to the next outer iteration.

User intervention only occurs at (1) outer safety limit prompt, (2) inner safety limit prompt, (3) escalated AskUserQuestion for individual proposals.

### Phase 3: Outer Cleanup

1. **Read `${CLAUDE_SKILL_DIR}/references/05-korean-ux-templates.md`** for the §3.9.4.e final completion summary template, then emit it in Korean (includes the `자동 결정` sub-line per §8.8/§8.13.3 supersession).
2. Delete the outer directory (path guarded):

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
- Type is `decision` (subject to the §8 auto-decide refinement — may be intercepted by `re_evaluate_decision` if `AUTO_DECIDE_ENABLED=true`).
- Type is `proposal` but the fix involves business judgment, API/data contract change, security/compliance trade-off, UX choice, or non-trivial scope.
- You are uncertain — when in doubt, escalate. Self-triage should err on the side of escalation, never on the side of silently dropping a real concern.

**`Type: verification` (criterion #7) — its own branch** (not proposal/decision, so the existing three branches do not condition it): route by category per `_common/verification.md`. cat-1 (read-only) → **self-run + record** (no user prompt), counted by the independent `[VERIFY-RAN]` counter. cat 2–4 → **escalate to the closed 3-option verification menu** (`지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)`). cat-5 (worktree) → escalate to a 2-option menu (`잔여 항목으로 기록` / `거부 (현재 유지)`), `지금 검증 실행` omitted + a Korean reason line (worktree recipes are never re-run in review). The main session NEVER runs a recipe an agent reported running, and discards agent-reported execution results unconditionally. Full rules: "## Verification dimension (criterion #7)".

**Severity upgrade authority** (§3.11): during self-triage, if the main session discovers hidden risk, it MAY upgrade severity **unidirectionally** (trivial → minor → major → critical). Downgrades are forbidden — agent's conservative assignment is preserved. When upgrading, append an informational marker to `review_log.md`:

```
- PROP-R{round}-{N} [SEVERITY-UPGRADED] minor → major: {reason}
```

**Logging requirement**: For every auto-handled item, write a one-line rationale in `review_log.md`:

```
- PROP-R{round}-{N} [AUTO-APPROVED|AUTO-REJECTED]: {one-line rationale}
```

## Approval UX

**Closed option set (do not import options from other skills).** The `AskUserQuestion` option set in this skill is *closed* and exhaustively defined by the "For Proposal type", "For Decision type", and "For Verification type" subsections below: Proposal type → exactly `승인` / `거부 (현재 유지)`; Decision type → exactly the options derived from the agent's `Options` field (plus an optional `← 에이전트 추천` label suffix); Verification type (criterion #7) → exactly `지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)` for cat 2–4, degrading to `잔여 항목으로 기록` / `거부 (현재 유지)` for cat-5 and exception-class recipes (`지금 검증 실행` omitted). This is the third sanctioned option source. No other standing option may be added under any circumstance. In particular, when `design-review` runs in the same session after the `design` skill, that skill's walkthrough per-category structural slots — `팀 토론 진행`, `보류`, and any other option not derived from the two sources above — MUST NOT appear in any `design-review` prompt. `design-review` never spawns agent teams (review uses fresh isolated `Agent` sub-agents per the Constraints), so a `팀 토론 진행` option is categorically invalid here; deferral and further discussion are handled by the Processing Protocol's free-form Other-input + dialogue loop (Ground Rule #6/#7), never by a standing menu option.

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
- Options (exhaustive — exactly these two, no others): "승인" (with description of what will be applied) and "거부 (현재 유지)" (with note that the item won't be re-reported).

### For Decision type

- Construct AskUserQuestion options *solely* from the agent's Options field (up to 4 options per question) — do NOT add any standing option not present in that field.
- Every option MUST carry a `description` (one line summarizing what selecting it does); never present bare-label options.
- Include the agent recommendation if present: per the documented recommendation convention, append `← 에이전트 추천` to the recommended option's label, place it at position 1, and put the rationale in that option's `description`.
- If the proposal has more than 4 options, present the first 4 in the primary question and mention additional alternatives in the question text from the Agent note field — do NOT split one proposal's options across two questions.

### For Verification type (criterion #7)

- Present the claim, its `분류` (category), and what running the recipe would observe. The menu is closed: `지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)` for cat 2–4. For cat-5 (worktree) and exception-class (`실행 주의`) recipes, drop `지금 검증 실행` (2-option degrade) and add a one-line Korean reason; when `예상 소요` >2 min, disclose the cost in the option `description`.
- Every option carries a `description`; no manual Other/기타 (the auto-provided Other channel suffices — AUQ spec). cat-1 (read-only) findings are NOT menued — the main session self-runs and records them, counted via `[VERIFY-RAN]`.

### Other input

The user may type free-form text instead of selecting an option. This is handled by the Processing Protocol below — including reversion intent (§8.11) and auto-decide opt-out (§8.12).

## Processing Protocol

For each user response to a proposal prompt, the main session must first pre-check for **opt-out trigger** (§8.12) and **reversion trigger** (§8.11) using the regex patterns in Control-Flow Invariants above.

**If either pre-check matches, Read `${CLAUDE_SKILL_DIR}/references/02-processing-protocol-detail.md`** and execute the full action sequence. Otherwise, proceed with normal disposition handling below.

### Disposition handling (normal path)

- **"승인" selected** (or a Decision option selected): Apply the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Verification menu (criterion #7)**: `지금 검증 실행` → execute per "## Verification dimension" + record (run-now write surface + `## Verification Runs` line), logged `[APPROVED]`-class (counted in `COUNT_APPLIED`); `잔여 항목으로 기록` → create an R-item (`잔여 사유: 검증 차단`, blocked reason `리뷰 시점 사용자 이연 — <YYYY-MM-DD>`), also `[APPROVED]`-class; `거부 (현재 유지)` → `[REJECTED]`-class (ack). A cat-1 self-run (no menu) is logged via the independent `[VERIFY-RAN]` counter, never `[APPROVED]`.
- **Other input** (not matching any pre-check above): Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestion, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.

## Application Mechanism

The main session applies approved changes (auto-approved, auto-decided, and user-approved) directly using the Edit tool. The agent never modifies the design document. Since concepts may affect multiple locations, the main session identifies all affected locations during scope analysis and applies changes in batch.

**V/R field-line form-preservation fence**: when an Edit touches a V/R verification field line (`_common/verification.md` §4/§5), preserve its canonical rendering — do NOT convert the line to a leading bullet (`- `) and do NOT add or remove the `**…**` bold; emit the CANON `**key**: value` form (bold key, no bullet, one space after the colon). This directly blocks the observed bulletization; criterion #7(e) is the defense-in-depth detection when the fence is missed.

If an Edit fails, follow the Step 13 Edit-failure handling procedure (retry within round or defer to `pending_applies.md`).

## Verification dimension (criterion #7)

**CHECK is the review, RUN is the main session.** Agents read→propose and may not Edit; execution is the same kind of side effect, and each round is a fresh agent (no execution dedup is possible — an agent allowed to run would re-run the same recipe up to 20× per outer loop). So agents flag verification bookkeeping by reading only; the **main session** runs anything that gets run. Two-sided no-execute: the agent prompt forbids running recipes/commands, AND the main session **unconditionally discards** any execution result an agent reports (anti-fabrication extension).

**Main-session execution rules** (Type `verification`, Category `verification-bookkeeping`):

- **cat-1 (read-only)**: self-run freely (same status as the walkthrough's auto-investigation), no user prompt; record the verdict.
- **cat 2–4**: the closed 3-option menu (`지금 검증 실행` / `잔여 항목으로 기록` / `거부 (현재 유지)`) for user approval — the first two are `[APPROVED]`-class. An exception-class (`실행 주의`) recipe drops `지금 검증 실행` (2-option degrade + a Korean reason line); a `예상 소요` >2 min discloses the cost in the option `description`.
- **cat-5 (worktree)**: NEVER re-run in review (base + lite); bookkeeping inspection only.
- **per-run cap**: 2 min (this skill's owned constant — `_common` holds no budget/cap). Use the flake pre-classification + drift ladder of `_common/verification.md` verbatim (no review-local adaptation).

**run-now write surface**: an unmarked claim → create a new `### V<n>` (+ attach the V-anchor reference to the body claim); re-verifying an existing V → update that V entry. Neither touches the R-section (R-flips are implement-only). A document with no `## 검증 기록` heading (all-residual / pre-mechanism docs) gets the section created at the canonical position (after `## 주요 결정사항과 근거`, before `## 미해결 이슈 / 트레이드오프`) before recording. For a criterion-(a) claim, the main session writes `검증 절차` + `기대 결과` per the pre-registration rule *before* executing. Run-now checks 0 new changes vs. a pre-execution `git status --porcelain` snapshot — on violation, the verdict is NOT recorded + a fail-loud Korean report (the abbreviated transplant of implement's 1.5c gate; cat-5 is forbidden and exception-class omitted, so the high-risk class is pre-blocked).

**dirty-tree validity**: before re-running, `git status --porcelain`; if dirty, the menu body carries one Korean disclosure line (dirty file count + that a measurement-type result may reflect the uncommitted state), and a dirty-run verdict carries a `유효성 노트` on the ledger entry. No silent dirty run (disclose, don't downgrade — dirty is the normal review-time situation, so a blanket downgrade would gut re-verification).

**session execution memo**: log each run to `$OUTER_DIR/outer_log.md`'s `## Verification Runs` section (schema: `references/04-file-schemas.md`) — `- <V anchor> | <recipe hash> | <verdict> | <ISO8601>`. When `(anchor, hash)` already exists, cite the recorded verdict and drop `지금 검증 실행` from the menu (cuts the outer loop's 20× re-proposal fatigue); a modified recipe changes the hash → a legitimate re-proposal.

**termination machine**: Type `verification` bypasses §8 auto-decide structurally (execution is a real-world side effect, never auto-decided). A cat-1 self-run mutates the ledger without a user prompt, so it is counted by the **independent `[VERIFY-RAN]` counter** kept OUT of `escalate_applied` / `COUNT_APPLIED` and every itemize render (Step 20 breakdown / convergence_table columns / `references/05` summary are unmodified). It feeds one term to the Step 22 predicate (`this_iter_verify_ran == 0`), excluded from `extract_prior_signals` (anti-ratchet), is not an ack-extraction target, and emits no `### Auto-Decides` audit. A cat-1 `반증됨(실패)` verdict (a refuted design claim) is NEVER silently recorded — surface it in Korean (refutation evidence + the `영향 결정` flip); the next round's fresh agent then emits a normal decision-type finding.

**`잔여 항목으로 기록`** lands as `잔여 사유: 검증 차단` + blocked reason `리뷰 시점 사용자 이연 — <YYYY-MM-DD>` (the third birth path in `_common/verification.md` §5.1) and creates an R-item — never an R-flip (those are implement-only).

## Ground Rules

1. **Propose first, then triage.** All issues are generated as concept proposals. The agent never modifies the design document directly. The main session self-triages each proposal: unambiguous fixes are auto-approved and applied, false positives are auto-rejected, and only items requiring judgment are escalated to the user.
2. **Agent Loop required.** Phase 2 iterative inner review must use the agent-based loop. Exit requires either severity saturation (`consecutive_no_major >= 2` + empty pending + no in-progress dialogues) or the user's explicit 3-option choice at inner safety limit.
3. **Agent independence.** Each review agent reviews the document from scratch. Previous round results are only accessed via `$INNER_TEMP_DIR/review_log.md`, which is seeded with the outer-persistent ack set at the start of each outer iteration.
4. **Review log required.** Every round's results must be recorded in `$INNER_TEMP_DIR/review_log.md` with disposition tags: `[AUTO-APPROVED]`, `[AUTO-REJECTED]`, `[AUTO-DECIDED]`, `[APPROVED]`, `[REJECTED]`, `[MODIFIED]`, `[USER-DIRECTED]`. Informational markers (`[SEVERITY-UPGRADED]`, `[REVERTED-BY-USER]`, `[REVERT-FAILED]`) are appended as needed but never count toward any metric.
5. **Respect acknowledged items.** Items decided to keep as-is (rejected and auto-rejected proposals) must not be re-reported in subsequent rounds or iterations. The outer-persistent `ack_items.md` enforces this across the whole outer session.
6. **Triage bias toward escalation.** When the main session is uncertain whether a proposal is unambiguous, it MUST escalate. Self-triage exists to reduce trivial questions, never to silently override user authority on judgment calls.
7. **Never decide for the user.** When the user responds to a pending decision with a follow-up question, a request for more context, or a discussion point, this is NOT a decision. Continue the conversation via AskUserQuestion until the user states an explicit decision. A decision is only confirmed when the user clearly says what to do (e.g., "A로 가자", "현재 유지", "변경해줘"). Questions like "그러면 ~는 어떻게 되나요?" or "~에 대해 좀 더 설명해줘" are continuation signals, not decisions. This rule applies equally to Other input handling in the Processing Protocol.

   **GR#7 Amendment (§8.10)** — When invoked with `--auto-decide-dominant`, the main session MAY bypass user presentation for `decision`-type proposals that satisfy the Dominance Threshold (§8). This exception is narrowly scoped: it applies only to items that have never entered the dialogue loop. Any item the user has seen, is currently seeing, or has asked a follow-up about remains fully governed by the paragraph above. Auto-decided items MUST be logged per the Auto-Decide Audit Schema (see `references/04-file-schemas.md` + `references/01-auto-decide-protocol.md`) and are subject to user revert per §8.11.

## Options

> _Consistency Note: README의 user-facing 옵션 표와 Safety 블록은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent가 읽는 작동 규약(예: `{BASE_MODE_CONSTRAINT}` 치환 블록)이며, frontmatter 변경 시 함께 갱신._

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

**Verification carve-out (BASE MODE)**: verification-bookkeeping fixes (criterion #7) are in-scope even under `--base`; using a verification *result* as a vector for a new task-level design-substance proposal within the same finding remains forbidden.

When `--base` is not present, remove the `{BASE_MODE_CONSTRAINT}` placeholder line from the agent prompt. (LLM-equivalent to substituting a single empty line, as `06-review-agent-prompt.md`'s substitution contract phrases it; left unchanged as out of scope here.)

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

When `--changes` is not present, substitute the `{CHANGES_MODE_CONSTRAINT}` placeholder with a single empty line (per `06-review-agent-prompt.md`'s substitution contract). The reconcile bullet self-activates via its `"If a BASE MODE CONSTRAINT also appears above…"` wording, so no 4-way branch logic is needed — it is naturally inert when no BASE block precedes it.

### --auto-decide-dominant / --no-auto-decide-dominant

Decision Auto-Select Protocol (§8) is **ON BY DEFAULT**. When the main session's independent re-evaluation identifies a dominant option for a `decision`-type proposal, it is auto-picked and recorded as `[AUTO-DECIDED]`. This minimizes user fatigue while preserving safety via the §8 guards.

**Flag semantics**:

- **(default, no flag)**: auto-decide enabled. Equivalent to passing `--auto-decide-dominant` explicitly.
- **`--auto-decide-dominant`**: explicit opt-in (no-op when default is enabled — kept for backward-compatible documentation and explicit invocations).
- **`--no-auto-decide-dominant`**: opt-out. Disables auto-decide for the entire session. All `decision`-type proposals escalate to the user as in pre-refinement behavior.

When auto-decide is active:

- `re_evaluate_decision` is called for each `decision`-type proposal after self-triage and before user escalation (Phase 2 Step 12.f).
- Blackout categories (B1–B10 with B7/B8/B9 conditional checklists — see `references/01-auto-decide-protocol.md`) are always escalated regardless of dominance analysis.
- `AUTO_DECIDE_ENABLED` flag is restored from `outer_log.md` at the start of every outer iter (§8.12 persistence) — Claude Code bash vars are volatile across turns.
- First-time Korean notice is emitted once at session start (§8.9, in Phase 1 step 4).
- Mid-session opt-out is accepted at any dialogue-loop prompt via the phrase patterns in the Control-Flow Invariants regex (details in `references/02-processing-protocol-detail.md`). Once opted out, re-activation is forbidden for the remainder of the session.
- User may revert any auto-decision via PROP-Rx-y or AUTO-NNN reference at any dialogue-loop prompt (§8.11; details in `references/02-processing-protocol-detail.md`).
- **Outer cycle continuation guarantee**: any iteration that produces ≥1 `[AUTO-DECIDED]` item naturally satisfies `COUNT_APPLIED > 0` (since `[AUTO-DECIDED]` is included in the COUNT_APPLIED formula — see Control-Flow Invariants), forcing the outer loop to run another iteration and re-verify the auto-decision's ripple effects with a fresh agent group. No special-case logic needed — this falls out of the existing termination predicate.

Flag parsing is done together with `--base` in Phase 1 step 2 (all three flags are stripped from `ARGS_CLEAN`; presence is detected into `BASE_MODE` and `AUTO_DECIDE_INITIAL` booleans). `AUTO_DECIDE_INITIAL` defaults to `true`; `--no-auto-decide-dominant` flips it to `false`.

**The flag is NOT propagated to review agents** — auto-decide is a main-session-only mechanism.

## Constraints

- **Deferred tool loading**: Before using AskUserQuestion, you MUST first load it via `ToolSearch("select:AskUserQuestion")` before any user prompt step. **Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints from that file to every AskUserQuestion call in this skill.

- **Review agent model (session inheritance)**: every inner-loop review agent inherits the orchestrating session model — the `Agent()` call omits the `model` parameter and never injects an explicit literal (see Step 12). This keeps the review model deterministic within a session and tracks the user's cost choice. It is the inverse of `design-review-lite`, which hard-pins `sonnet`: full design-review inherits the tier instead of fixing one.

## Begin

$ARGUMENTS
