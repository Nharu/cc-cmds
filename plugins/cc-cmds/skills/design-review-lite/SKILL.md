---
name: design-review-lite
description: 설계 문서 경량 사이클 리뷰
when_to_use: 설계 문서를 간결한 반복 사이클로 빠르게 검증하고 싶을 때 (미묘한 termination invariant·동시성 검출률 약화 가능)
disable-model-invocation: true
usage: "/cc-cmds:design-review-lite <design-doc-path> [--base]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "리뷰 대상 설계 문서 경로 (`.md`)"
    - name: "--base"
      kind: flag
      default: "off"
      summary: "기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT)"
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
elif INNER_EXIT_REASON == "clean-convergence" and COUNT_APPLIED == 0:
    outer_done = true                               # fixpoint reached
else:
    outer_done = false                              # COUNT_APPLIED > 0 → another iter
```

**MIN_OUTER = 1**: even the first iteration may terminate if the fixpoint rule fires.

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
  for(i=1;i<=NF;i++) if($i!="--base") printf "%s%s", $i, (i<NF?" ":"")
}')

# Detect --base
BASE_MODE=false
for arg in $ARGUMENTS; do
  [ "$arg" = "--base" ] && BASE_MODE=true
done

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
echo "" > "$INNER_TEMP_DIR/review_proposals.md"
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

**Step 12** — `inner_round += 1`. Spawn a review agent **with model `"sonnet"`** (lite contract — no haiku, no opus).

**Substitution contract**: `{TEMP_DIR}` → actual `INNER_TEMP_DIR` value; `{BASE_MODE_CONSTRAINT}` → the `--base` BASE MODE CONSTRAINT block (when `BASE_MODE=true`) or a single empty line (when `BASE_MODE=false`).

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

First, read {TEMP_DIR}/review_log.md to determine the current round number.
If no "## Review Round" entries exist in the log, this is Round 1.

IMPORTANT — Acknowledged Items contract: Check for an "## Acknowledged Items" section in {TEMP_DIR}/review_log.md. These are items the user has already decided to keep as-is. Before reporting any proposal, read this section and treat a proposal as a duplicate (and therefore MUST NOT report it) when ALL of the following hold:
  (a) the Category matches exactly (from the 6 review categories),
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

{BASE_MODE_CONSTRAINT}

IMPORTANT: Do NOT modify the design document directly. For every issue found, create a proposal in the following format:

### PROP-R{round}-{number}
- **Type**: [proposal | decision]
- **Severity**: [critical | major | minor | trivial]
- **Category**: [requirement-consistency | internal-coherence | feasibility | implementation-order | missing-items | contextual]
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

Type guidance:
- proposal: The fix direction is clear. Describe what should change and why.
- decision: Multiple valid approaches exist and user judgment is needed. List up to 4 options with descriptions. If more alternatives exist, note them in Agent note.

Write all proposals to {TEMP_DIR}/review_proposals.md (overwrite the file at the start of the round).

After completing the review, append a round summary to {TEMP_DIR}/review_log.md:
  ## Review Round N
  - Proposals created: X (categorized by criteria and severity)
  - Proposal details: [list each PROP-ID with Type, Severity, Category, and brief description]

Return a structured summary:
- Round number
- Total proposals created
- Severity breakdown (critical/major/minor/trivial counts)
- Category breakdown
- Brief description of each proposal
```

After the agent returns:

  a. The agent wrote proposals to `$INNER_TEMP_DIR/review_proposals.md` (overwriting at round start), appended a round summary to `$INNER_TEMP_DIR/review_log.md`, and returned a structured summary including proposal count.
  b. Read `$INNER_TEMP_DIR/review_proposals.md` to get the current round's proposals.
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

If `inner_round >= 6`, present 3 options via AskUserQuestion. Dynamic recommendation:

- `pending_dialogue > 0` → recommend **A: 3 라운드 추가 진행** (finish open dialogues)
- `pending_dialogue == 0` → recommend **B: 이번 이터레이션 종료 후 새 이터레이션 시작** (escape stuck inner, preserve outer progress)

Korean prompt template (when `pending_dialogue > 0`):

```
이터레이션 {N}의 내부 라운드가 안전 한계(6회)에 도달했습니다.

현재 대화 중인 제안이 {pending}건 남아 있습니다.
지금 종료하면 해당 제안들이 미처리 상태로 넘어갑니다.

어떻게 진행하시겠습니까?
```

Options: `"A: 3 라운드 추가 진행 ← 추천"` / `"B: 이번 이터레이션 종료 후 새 이터레이션 시작"` / `"C: 외부 이터레이션 전체 종료"`.

Korean prompt template (when `pending_dialogue == 0`):

```
이터레이션 {N}의 내부 라운드가 안전 한계(6회)에 도달했습니다.

미완료 대화는 없습니다. 이번 이터레이션의 에스컬레이션 적용: {esc_applied}건.

어떻게 진행하시겠습니까?
```

Options: `"A: 3 라운드 추가 진행"` / `"B: 이번 이터레이션 종료 후 새 이터레이션 시작 ← 추천"` / `"C: 외부 이터레이션 전체 종료"`.

Option mapping to `INNER_EXIT_REASON`:

| Option | Action | INNER_EXIT_REASON |
|---|---|---|
| A: 3 라운드 추가 진행 | extend inner loop by 3 rounds (repeatable) | (not set, continue) |
| B: 이번 이터레이션 종료 후 새 이터레이션 시작 | break inner loop; next outer iter re-reviews from doc state | `safety-limit-fresh-outer` |
| C: 외부 이터레이션 전체 종료 | break inner loop; skip directly to Phase 3 cleanup | `safety-limit-outer-terminate` |

**Option B invariant**: A stuck inner loop must never block outer progress. Ack + document state are preserved, so the next fresh agent can re-review. Outer exit check (Step 22) bypasses convergence judgment when `INNER_EXIT_REASON == "safety-limit-fresh-outer"` — always continue.

If exit condition not met and not at safety limit → return to Step 12 with a new agent.

---

#### INNER LOOP COMPLETE — Per-iteration summary work (Step 17–21)

**Step 17 — Compute `COUNT_APPLIED`**: use the formula in Control-Flow Invariants. Feeds Step 22.

**Step 18 — Extract new ack items**:

Parse `$INNER_TEMP_DIR/review_log.md` for `[REJECTED]` and `[AUTO-REJECTED]` lines. For each, compose an `ACK-NNN` record with the 8 fields (Source, Disposition, Category, Location, Issue, Reference text, User/Auto-reject rationale, Recorded) per the schema in Phase 1.

**Dedup rule**: an ack is a duplicate of an existing entry in `$OUTER_DIR/ack_items.md` iff ALL three conditions hold:

1. `Category` matches exactly (controlled vocabulary: one of the 6 review categories)
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
- Partial iteration: {true|false}

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
- **100 items**: hard — ask the user via AskUserQuestion with three options:

| Label | Action |
|---|---|
| A: 요약 | Compress old ack entries into one-line-per-category summaries |
| B: 보관 | Move entries from previous iterations to `$OUTER_DIR/ack_archive.md`, keep only current iter active |
| C: 현재 유지 | Accept the prompt-length cost and do nothing |

Only run this check when `outer_done == false` — when `outer_done == true`, cleanup is imminent so ack size no longer matters.

**Step 24 — Outer safety limit (default 2 iterations)**:

If `outer_iter >= 2 AND outer_done == false`, present the extension/terminate prompt in Korean:

```
외부 이터레이션 안전 한계(2회)에 도달했습니다.

[convergence table inline]

아직 수렴이 완료되지 않았습니다 (에스컬레이션 적용 합계 > 0).
계속 진행하시겠습니까?
```

AskUserQuestion options: `"2회 추가 진행"` / `"현재 상태로 종료"`. If the user chooses to terminate, break outer loop → Phase 3. If extended, raise the outer cap by 2 and continue.

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
  (대기 중 적용      {pending}건  ⚠️ 내부 안전 한계 도달 시점에 미해소)  ← count>0 AND non clean-convergence 일 때만 노출
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
- Escalate-zero but partial iteration (safety-limit-fresh-outer): `판정: ⚠️ 에스컬레이션 적용 0건이나 부분 이터레이션으로 수렴 미확인 / 내부 라운드가 안전 한계로 조기 종료됨 — 이터레이션 {N+1}에서 재검증합니다.`
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
- Include agent recommendation if present (append "(에이전트 추천)" to the label).
- If the proposal has more than 4 options, present the first 4 in the primary question and mention additional alternatives in the question text from the Agent note field — do NOT split one proposal's options across two questions.

### Other input

The user may type free-form text instead of selecting an option. This is handled by the Processing Protocol below.

## Processing Protocol

For each user response to a proposal prompt:

### Disposition handling (normal path)

- **"승인" selected** (or a Decision option selected): Apply the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Other input**: Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestion, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.

## Application Mechanism

The main session applies approved changes (auto-approved and user-approved) directly using the Edit tool. The agent never modifies the design document. Since concepts may affect multiple locations, the main session identifies all affected locations during scope analysis and applies changes in batch.

If an Edit fails, follow the Step 13 Edit-failure handling procedure (retry within round or defer to `pending_applies.md`).

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

When `--base` is not present, remove the `{BASE_MODE_CONSTRAINT}` placeholder line from the agent prompt.

## Constraints

- All review agents use model `"sonnet"` (haiku and opus forbidden — lite quality floor).
- **No Sequential Thinking MCP, no Claude Context MCP**: predictable token cost.
- **Auto-decide protocol is fully disabled**: every `decision`-type proposal escalates to the user. There is no `--auto-decide-dominant` / `--no-auto-decide-dominant` flag.
- **Deferred tool loading**: Before using AskUserQuestion (or any other deferred tool used by Agent infrastructure for review-agent spawning), you MUST first load it via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion" before any user prompt step.

## Begin

$ARGUMENTS
