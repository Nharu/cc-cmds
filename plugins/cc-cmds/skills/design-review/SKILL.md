---
name: design-review
description: 설계 문서 최종 리뷰
disable-model-invocation: true
---

Perform a final review of the design document using a two-tier cycle (outer + inner).

All analysis work and inter-agent communication should be in English to optimize token usage.
User-facing communication (summaries, questions, status updates) should be in Korean.

## Overview

This command wraps `design-review`'s inner loop in an outer cycle. Each outer iteration spawns a **completely fresh** inner loop against the current document state with a cleared `INNER_TEMP_DIR`, preserving only the user-persistent `ack_items.md` and the design document itself. This prevents the "context poisoning" where long inner loops drift from re-confirmation toward rebuttal, while still letting ack items ratchet across iterations.

The outer cycle exits when an inner iteration reaches `clean-convergence` (§3.11 severity + saturation rule) AND no escalation was actually applied during that iteration (`COUNT_APPLIED == 0`, §3.3 step 17 / §8.8 formula).

## Review Criteria

Requirement consistency, internal coherence, feasibility, implementation order, missing items, and any other perspective important in the context of this specific design.

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
  for(i=1;i<=NF;i++) if($i!="--base" && $i!="--auto-decide-dominant" && $i!="--no-auto-decide-dominant") printf "%s%s", $i, (i<NF?" ":"")
}')

# 3. Detect flags
# Auto-decide-dominant is ON BY DEFAULT. Pass --no-auto-decide-dominant to disable.
# --auto-decide-dominant remains accepted as an explicit opt-in (no-op when default is true)
# for backward-compatible invocations and documentation clarity.
BASE_MODE=false
AUTO_DECIDE_INITIAL=true
for arg in $ARGUMENTS; do
  [ "$arg" = "--base" ] && BASE_MODE=true
  [ "$arg" = "--auto-decide-dominant" ] && AUTO_DECIDE_INITIAL=true
  [ "$arg" = "--no-auto-decide-dominant" ] && AUTO_DECIDE_INITIAL=false
done

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

3. Initialize the three outer-persistent files (`outer_log.md`, `ack_items.md`, `convergence_table.md`):

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
-->
EOF

# ack_items.md header
cat > "$OUTER_DIR/ack_items.md" <<'EOF'
# Acknowledged Items

_Items decided to keep as-is during this design-review session. Do NOT re-propose._

---
EOF

# convergence_table.md headers (two tables)
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

4. **First-time auto-decide warning** (§8.9): Auto-decide-dominant is **ON by default**. If `AUTO_DECIDE_INITIAL=true` (i.e., the user did not pass `--no-auto-decide-dominant`), emit this Korean warning to the user exactly once at session start:

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

The inner review agent's prompt (line ~150 below) instructs it to read the `## Acknowledged Items` section and skip duplicates — no agent-prompt change is required for ack injection.

**Step 11 — Reset inner state**: `inner_round = 0`, `consecutive_no_major = 0`, `INNER_EXIT_REASON = null`.

---

#### INNER PHASE 2 LOOP

Perform agent-based iterative review until severity saturation (§3.11). Each round spawns a **fresh** review agent that independently reviews the document from scratch.

**Agent prompt path substitution:** When constructing the agent prompt, prepend the following context block at the top so the agent knows the session-specific paths:

```
This agent's working paths:
- TEMP_DIR={actual INNER_TEMP_DIR value from step 7}
IMPORTANT: Use the above path for ALL file operations. Using any other path will break session isolation.
All occurrences of {TEMP_DIR} in this prompt refer to the TEMP_DIR value above.
```

**Loop procedure:**

**Step 12** — `inner_round += 1`. Create a review agent with the review agent prompt below (with path context prepended).
  a. The agent reviews the document, writes proposals to `$INNER_TEMP_DIR/review_proposals.md` (overwriting at round start), appends a round summary to `$INNER_TEMP_DIR/review_log.md`, and returns a structured summary including proposal count.
  b. Read `$INNER_TEMP_DIR/review_proposals.md` to get the current round's proposals.
  c. **For each proposal**, analyze its concept:
     - **Proposal type**: Use the Reference text as a hint to identify all affected locations. Concretize the fix (what exactly will change, where).
     - **Decision type**: Analyze the impact of each option so the user can make an informed choice.
  d. **Self-Triage** (main session): Classify each proposal into `auto-approve`, `auto-reject`, or `escalate` per the Self-Triage Protocol below.
  e. Apply auto-approved proposals directly via Edit. Log auto-rejected proposals to `## Acknowledged Items` (inline copy — the real outer-persistent extraction happens at Step 18). Both are recorded in `review_log.md` with `[AUTO-APPROVED]` / `[AUTO-REJECTED]` tags and a one-line rationale.
  f. **Auto-decide integration** (§8, conditional on `AUTO_DECIDE_ENABLED=true`): for each `decision`-type proposal, after self-triage decides "escalate", call `re_evaluate_decision` (§8.4). If the verdict is `auto-pick`, record `[AUTO-DECIDED]` to `review_log.md`, apply the chosen option via Edit, and append an `AUTO-NNN` entry to the in-memory audit buffer for Step 20. If the verdict is `escalate`, fall through to the ask-user step. If `AUTO_DECIDE_ENABLED=false`, skip this hook entirely.
  g. **If escalated proposals remain**: Present only those to the user via AskUserQuestion (in Korean). See "Approval UX" below.
  h. Process user choices according to the "Processing Protocol" below. **Dialogue loop per Ground Rule #6**: if the user's response is a follow-up question or discussion rather than an explicit decision, continue the dialogue via AskUserQuestion until an explicit decision is given.
  i. Update the round entry in `$INNER_TEMP_DIR/review_log.md` with disposition tags.
  j. Briefly summarize this round's auto-handled items to the user in Korean (count + one-line per item) so they have visibility into self-triage decisions.

**Step 13 — Edit failure handling**: If an Edit fails (e.g., `old_string` not unique, target text changed):
  - Immediately notify the user: "제안 #N 적용 중 일부 위치에서 실패: [원인]"
  - Re-analyze the failed location and propose an alternative.
  - **Option A (apply after user confirmation)**: re-attempt with disambiguated context. On success, log disposition tag to `review_log.md`.
  - **Option B (defer to next round)**: append a `PEND-NNN` block to `$INNER_TEMP_DIR/pending_applies.md` per the schema in §"File: pending_applies.md" below.
  - **Partial success**: log the proposal with a `partial_apply=true` marker and record the failed locations in `pending_applies.md`.
  - Any `PEND-NNN` must later be resolved (success → remove block + log disposition; or user abandon → `[REJECTED]` + ack + remove block) before inner convergence is allowed.

**Step 14 — Severity aggregation (post-triage final values)**:

After all proposals in the current round have been processed (triage + Edit + escalate + auto-decide), aggregate **final** severity values — not agent-initial severity, since main session upgrades may have raised tier per §3.11:

```
final_critical_or_major = count of post-triage proposals whose final severity ∈ {critical, major}

if final_critical_or_major == 0:
  consecutive_no_major += 1
else:
  consecutive_no_major = 0
```

**Step 15 — Inner convergence guard**:

```
inner_converged_cleanly() =
    (consecutive_no_major >= 2)
    AND (pending_applies.md is empty — no ### PEND- headers between --- and EOF)
    AND (no [IN PROGRESS] dialogues)
```

If `inner_converged_cleanly()` is true, set `INNER_EXIT_REASON = "clean-convergence"` and break out of the inner loop.

**Step 16 — Inner safety limit (20 rounds)**:

If `inner_round >= 20`, present 3 options via AskUserQuestion per §3.9.4.b/c. Dynamic recommendation:

- `pending_dialogue > 0` → recommend **A: 10회 추가 진행** (finish open dialogues)
- `pending_dialogue == 0` → recommend **B: 이번 이터레이션 종료 후 새 이터레이션 시작** (escape stuck inner, preserve outer progress)

Option mapping to `INNER_EXIT_REASON`:

| Option | Action | INNER_EXIT_REASON |
|---|---|---|
| A: 10 라운드 추가 진행 | extend inner loop by 10 rounds (repeatable) | (not set, continue) |
| B: 이번 이터레이션 종료 후 새 이터레이션 시작 | break inner loop; next outer iter re-reviews from doc state | `safety-limit-fresh-outer` |
| C: 외부 이터레이션 전체 종료 | break inner loop; skip directly to Phase 3 cleanup | `safety-limit-outer-terminate` |

**Option B invariant**: A stuck inner loop must never block outer progress. Ack + document state are preserved, so the next fresh agent can re-review. Outer exit check (Step 22) bypasses convergence judgment when `INNER_EXIT_REASON == "safety-limit-fresh-outer"` — always continue.

If not exit condition not met and not at safety limit → return to Step 12 with a new agent.

---

#### INNER LOOP COMPLETE — Per-iteration summary work (Step 17–21)

**Step 17 — Compute `COUNT_APPLIED`** (§3.3 step 17 / §8.8 dedup correction):

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

This value feeds the outer exit decision at Step 22.

**Step 18 — Extract new ack items**:

Parse `$INNER_TEMP_DIR/review_log.md` for `[REJECTED]` and `[AUTO-REJECTED]` lines. For each, compose an `ACK-NNN` record with the 8 fields (Source, Disposition, Category, Location, Issue, Reference text, User/Auto-reject rationale, Recorded).

**Dedup rule** (§3.7): an ack is a duplicate of an existing entry in `$OUTER_DIR/ack_items.md` iff ALL three conditions hold:

1. `Category` matches exactly (controlled vocabulary: one of the 6 review categories)
2. `Location` refers to the same section (case-insensitive, "Section 4.3" ≈ "4.3 Auth Flow")
3. `Issue` describes the same root cause (main session semantic judgment)

Append only non-duplicate records to `$OUTER_DIR/ack_items.md` under a new `### From Iteration N` heading. **If zero new items are extracted for this iteration, do not append the `### From Iteration N` block at all.** Use monotonic zero-padded IDs (`ACK-001`, `ACK-002`, …).

**Step 19 — Append convergence table rows**:

Append one row to each of the two tables in `$OUTER_DIR/convergence_table.md`:

**처리 결과 현황표** (§8.13.4):

```markdown
| {iter} | {rounds} | {auto_approved} | {auto_rejected} | {auto_decided} | {escalate_applied} | {escalate_rejected} |
```

Mark the iter column with ` ⚠️` suffix if `INNER_EXIT_REASON != "clean-convergence"` (partial iteration). Mark `escalate_applied` with `**0** ✓` bold-tick if the final value is 0 on a clean iteration.

**수렴 진단표**:

```markdown
| {iter} | {max_pending_applies} | {아니오|예} | {ack_size_after} | {exit_reason_ko} |
```

Where:
- `max_pending_applies` is the maximum size `pending_applies.md` reached during the iteration (not the final value — may be nonzero even if cleaned up by end)
- `partial_flag` = `예` if `INNER_EXIT_REASON != "clean-convergence"`, else `아니오`
- `exit_reason_ko` ∈ {`정상수렴`, `내부한계`, `사용자중단`}
- **Invariant**: `exit_reason_ko == "정상수렴"` ⇒ `partial_flag == "아니오"` (enforced by the inner convergence guard)

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
- [AUTO-DECIDED]: {count} "proposal IDs: ..."
- escalate_applied: {COUNT_APPLIED}  ← termination input (raw_count − dedup correction per §8.8)
- [REJECTED]: {count} ← NOT counted; added to ack set
- [AUTO-APPROVED]: {count} ← NOT counted
- [AUTO-REJECTED]: {count} ← NOT counted; added to ack set
- pending_applies_at_end: {"(none)" | PEND-NNN list}
- auto_decide_opt_out: {false | "true (triggered at round r, phrase: '...')"}

### Auto-Decides

(Emit this subsection only if at least one [AUTO-DECIDED] occurred this iteration.)

- AUTO-NNN: PROP-Rx-y → 옵션 {label} 선택 (섹션 ...)
    - trigger: {T1-A | T1-B | T1-C | T2-AB}
    - options_available: [A — ..., B — ..., ...]
    - dominant_signal: {one-line rationale}
    - reverted: {false | "이터레이션 N에서 사용자 번복 → {replacement disposition}"}

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

**Step 22 — Outer termination judgment**:

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

**MIN_OUTER = 1**: even the very first iteration may terminate the outer loop if the fixpoint rule fires. (§3.11 rationale: iter-1 `consecutive_no_major == 2` already required fresh-agent re-review twice, so a forced iter-2 would only be triple redundancy at extra token cost.)

**Step 23 — Ack soft-limit check** (§3.7, only if `outer_done == false`):

Count entries in `$OUTER_DIR/ack_items.md` (lines starting with `#### ACK-`):

- **50 items**: advisory — append a one-line warning to the next iteration-transition summary: `⚠️ 인지됨 항목 {n}건 (50건 권고치 초과)`
- **100 items**: hard — ask the user via AskUserQuestion with three options:

| Label | Action |
|---|---|
| A: 요약 | Compress old ack entries into one-line-per-category summaries |
| B: 보관 | Move entries from previous iterations to `$OUTER_DIR/ack_archive.md`, keep only current iter active |
| C: 현재 유지 | Accept the prompt-length cost and do nothing |

Only run this check when `outer_done == false` — when `outer_done == true`, cleanup is imminent so ack size no longer matters.

**Step 24 — Outer safety limit (default 5 iterations)**:

If `outer_iter >= 5 AND outer_done == false`, present the extension/terminate prompt per §3.9.4.a:

```
외부 이터레이션 안전 한계(5회)에 도달했습니다.

[convergence table inline]

아직 수렴이 완료되지 않았습니다 (에스컬레이션 적용 합계 > 0).
계속 진행하시겠습니까?
```

AskUserQuestion options: "5회 추가 진행" / "현재 상태로 종료". If the user chooses to terminate, break outer loop → Phase 3. If extended, raise the outer cap by 5 and continue.

**Step 25 — Iteration transition summary + auto-advance** (only if `outer_done == false`):

Emit the Korean iteration-transition summary block (§3.9.2 / §8.13.3 expanded format — see "Korean UX" section below) followed by the split convergence table (§3.9.3 / §8.13.4). No countdown or confirmation — auto-advance immediately to the next outer iteration.

User intervention only occurs at (1) outer safety limit prompt, (2) inner safety limit prompt, (3) escalated AskUserQuestion for individual proposals.

### Phase 3: Outer Cleanup

1. Emit the final completion summary in Korean (§3.9.4.e — includes the `자동 결정` sub-line per §8.8/§8.13.3 supersession).
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

**Severity upgrade authority** (§3.11): during self-triage, if the main session discovers hidden risk, it MAY upgrade severity **unidirectionally** (trivial → minor → major → critical). Downgrades are forbidden — agent's conservative assignment is preserved. When upgrading, append an informational marker to `review_log.md`:

```
- PROP-R{round}-{N} [SEVERITY-UPGRADED] minor → major: {reason}
```

**Logging requirement**: For every auto-handled item, write a one-line rationale in `review_log.md`:

```
- PROP-R{round}-{N} [AUTO-APPROVED|AUTO-REJECTED]: {one-line rationale}
```

## Approval UX

Present escalated proposals item-by-item via AskUserQuestion, batched up to 4 at a time. No "approve all" option — every escalated proposal requires individual review.

**For Proposal type**:
- Present the agent's concept together with the main session's concretized scope (affected locations and specific changes).
- Options: "승인" (with description of what will be applied) and "거부 (현재 유지)" (with note that the item won't be re-reported).

**For Decision type**:
- Dynamically construct AskUserQuestion options from the agent's Options field (up to 4 options, AskUserQuestion constraint).
- Include agent recommendation if present (append "(에이전트 추천)" to the label).
- Additional alternatives beyond 4 are noted in the question text from the Agent note field.

**Other input**: The user may type free-form text instead of selecting an option. This is handled by the Processing Protocol below — including reversion intent (§8.11) and auto-decide opt-out (§8.12).

## Processing Protocol

For each user response to a proposal prompt, the main session must first pre-check for **opt-out trigger** (§8.12) and **reversion trigger** (§8.11), then proceed with normal disposition handling.

### Pre-check 1: Opt-out trigger (§8.12)

Match against `(자동결정|자동 선택|auto.decide)` + `(중단|끄|해제|그만|비활성|수동|직접)`. Known phrases:

```
자동 선택 중단
자동결정 중단
자동결정 꺼줘
자동결정 끄기
자동 선택 비활성화
수동 모드로 전환
이제부터 결정은 내가 할게
이제부터 직접 선택할게
auto-decide 중단
--auto-decide-dominant 해제
자동 선택 그만
결정은 내가 할게
```

On match:
- Set `AUTO_DECIDE_ENABLED = false`.
- Append to `$OUTER_DIR/outer_log.md`:

```markdown
### Auto-Decide Opt-Out

- Triggered at: outer iter {i}, inner round {r}, {ISO8601}
- User phrase: "{exact phrase}"
- Auto-decides applied before opt-out: {count}
```

- Emit Korean acknowledgment:

```
자동 결정을 중단합니다.

이후 모든 결정형 제안은 사용자에게 에스컬레이션됩니다.
이미 적용된 자동 결정은 문서에 그대로 유지됩니다.
되돌리고 싶은 항목이 있으면 "PROP-Rx-y 자동결정 취소해줘"로 언제든지 번복할 수 있습니다.
```

- **Mid-session re-activation is forbidden**. Once opt-out is active, it persists for the remainder of the outer session (even across outer iterations, via the Step 6.5 file-based restore).
- After acknowledging, re-present the original proposal (the opt-out was meta, not a disposition).

### Pre-check 2: Reversion trigger (§8.11)

Match against `(PROP-ID|AUTO-NNN|방금|전부) + (취소|되돌리|번복|롤백|revert|undo)`. Both `PROP-Rx-y` and `AUTO-NNN` are accepted as user-facing IDs. On ID conflict, **AUTO-NNN takes precedence** (it's session-unique, whereas PROP-IDs can collide across outer iterations).

Known phrase patterns:

```
PROP-R1-4 자동결정 취소해줘
PROP-R2-1 되돌려줘 — 내가 직접 선택할게
자동결정 PROP-R3-2 번복
방금 자동 선택 되돌려          ← interprets as "most recent non-reverted auto-decide"
자동 선택 전부 되돌려          ← interprets as "all non-reverted auto-decides in the current outer iter"
AUTO-002 롤백
```

**Reversion action**:

1. Read the `Change applied` field from the matching `AUTO-NNN` entry in `$OUTER_DIR/outer_log.md` (or, for the current iter before step 20, from the in-memory audit buffer + `[AUTO-DECIDED]` line in `review_log.md`).
2. Compute and apply the **inverse Edit** to the design document.
3. **If inverse Edit fails** (transitively built-upon by subsequent edits in the same iter), attempt **semantic patching**:
    - Parse the surrounding text to identify the auto-decided semantic change.
    - Construct a context-aware replacement that covers all downstream references introduced by subsequent edits.
    - Example: if `[자동결정] AUTO-002: "JWT" → "session"` was later referenced in another section by adding `JWT`, the semantic patch rewrites those added references to `session` as well.
    - On success, proceed to step 4 below.
    - **On semantic patching failure**, append `- PROP-R{x}-{y} [REVERT-FAILED]: {reason}` (informational marker, no counts) to `review_log.md`, then offer a 3-option AskUserQuestion:
      - **(i) 그대로 유지** — keep the auto-decide result and its downstream. `[AUTO-DECIDED]` remains in the escalate_applied count.
      - **(ii) 사용자가 직접 명세** — user provides the desired final state as free text. Record as `[USER-DIRECTED]`. Per per-PROP-ID dedup, the original `[AUTO-DECIDED]` collapses out of the count.
      - **(iii) 롤백 범위 확장** — cascade rollback including subsequent edits. List affected PROP-IDs for user confirmation. On execution, mark the original with `[REVERTED-BY-USER] cascade=true` and each cascade-affected PROP-ID with `[REVERTED-BY-USER] cascade-from=PROP-Rx-y`. All markers are informational (no counts changed) — the original `[AUTO-DECIDED]` count is preserved under per-PROP-ID dedup rules, yielding a false-high bias that is audit-friendly.

4. **On successful inverse Edit or semantic patch**: present a 2-step reversion UI:

```
PROP-R2-1 자동결정을 되돌립니다.

  이전 적용: A — {original option label}
  (위 내용이 문서에서 제거됩니다.)

대신 어떤 옵션을 적용하시겠습니까?
```

   AskUserQuestion with the original option set (all options including the one just removed), plus a "직접 지정" free-form fallback. The user's choice is recorded as a subsequent `[USER-DIRECTED]` line (escalate_applied gets +1 naturally).

5. Append the 2-line (or 3-line with USER-DIRECTED) marker block to `review_log.md`:

```
- PROP-R2-1 [AUTO-DECIDED] T1-B "옵션 A 선택" (섹션 3.1 인증 방식): direct requirement match
- PROP-R2-1 [REVERTED-BY-USER]: 이터레이션 4에서 사용자 번복 — 옵션 A 취소; 후속 [USER-DIRECTED] 참조
- PROP-R2-1 [USER-DIRECTED]: 사용자 직접 선택 — 옵션 B (세션 쿠키 기반) 적용
```

6. Update the `reverted:` field in the matching `AUTO-NNN` entry of `$OUTER_DIR/outer_log.md`. If semantic patching was used, also set `semantic_patch: true`.

### Disposition handling (normal path)

- **"승인" selected** (or a Decision option selected): Apply the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Other input** (not matching any pre-check above): Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestion, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.

## Application Mechanism

The main session applies approved changes (auto-approved, auto-decided, and user-approved) directly using the Edit tool. The agent never modifies the design document. Since concepts may affect multiple locations, the main session identifies all affected locations during scope analysis and applies changes in batch.

If an Edit fails, follow the Step 13 Edit-failure handling procedure (retry within round or defer to `pending_applies.md`).

## Review Agent Prompt

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
- **critical** — semantic violation, silent termination / correctness risk, structural invariant breakage (e.g., termination formula error, missing dedup, F5-class gaps).
- **major** — implementation misbehavior / clear structural mismatch / incorrect cross-section spec (e.g., canonical section inconsistencies, lifecycle step missing, feasibility gap, wrong algorithmic order).
- **minor** — readability / doc quality / audit convenience / summary-section sync (e.g., stale consensus lists, outdated quick-ref formulas).
- **trivial** — typos, case differences, trivial word choice.
- Assign exactly one severity per proposal.
- "When in doubt, assign one tier higher" — conservative bias, consistent with triage bias toward escalation.
- `decision` type is by default at least **major** (user judgment needed = correctness-relevant).
- doc-hygiene issues are **minor** or **trivial**.

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

## Severity + Saturation Exit Policy (§3.11)

**Background**: the old `consecutive_clean == 2` zero-proposal rule forced fresh-agent ripple verification but in practice triggered endless tail-end rounds of trivial doc-hygiene findings. This policy only requires ripple verification for **critical/major** severities, letting `minor/trivial` die out naturally.

**4-tier severity taxonomy**:

| Tier | Meaning | Examples |
|---|---|---|
| **critical** | Semantic violation, silent termination / correctness risk, structural invariant breakage | termination formula error, missing dedup rule, escalate-counter formula missing, F5-class gaps |
| **major** | Implementation misbehavior / clear structural mismatch / incorrect cross-section spec | canonical-section inconsistencies, lifecycle step missing, feasibility gap, wrong algorithmic order |
| **minor** | Readability / doc quality / audit convenience / summary-section sync | stale consensus lists, outdated quick-ref formulas, cross-reference number drift |
| **trivial** | Typos, case/word choices, minor whitespace | "respponse" → "response", extra whitespace |

**Main session severity rules**:

1. **Trust agent's initial severity** as the default.
2. **Upgrade-only authority**: if the main session discovers hidden risk during triage, it MAY upgrade severity **unidirectionally** (critical ← major ← minor ← trivial). Downgrades are forbidden.
3. Upgrade is recorded as `[SEVERITY-UPGRADED]` informational marker in `review_log.md` (§3.11).
4. Self-triage protocol (auto-approve / auto-reject / escalate) is **orthogonal** to severity — severity primarily drives exit judgment.

**Exit judgment order per round** (Step 14 detail):

```
1. Agent emits proposals (each with severity).
2. Main session processes all proposals via self-triage, applying Edit / ack / escalate.
   - Upgrades may occur during this phase.
3. After all proposals processed, aggregate FINAL severity (post-upgrade):
     final_critical_or_major = |{p : p.severity ∈ {critical, major}}|
4. Update saturation counter:
     if final_critical_or_major == 0:
         consecutive_no_major += 1
     else:
         consecutive_no_major = 0
5. Check exit guard:
     if consecutive_no_major >= 2
        AND pending_applies.md is empty
        AND no [IN PROGRESS] dialogues:
         INNER_EXIT_REASON = "clean-convergence"
         break inner loop
```

**Auto-decide ↔ severity interaction**: `[AUTO-DECIDED]` items are treated as `decision`-type mutations, which are `major` by default. They affect `escalate_applied` counting (§8.8) but only affect the saturation counter via the "final_critical_or_major" aggregation — i.e., an auto-decide in a round does not by itself reset saturation unless a separate critical/major proposal appears.

**Adversarial safety**: an agent that keeps finding only trivial tails exits after 2 saturation rounds. A repeated same-trivial proposal is blocked by ack. A main session over-upgrading to disguise critical/major would only delay exit in the safe direction (acceptable bias).

## Decision Auto-Select Protocol (§8)

This protocol governs auto-decide behavior, which is **ON by default**. Pass `--no-auto-decide-dominant` to opt out for the entire session, in which case all `decision`-type proposals escalate to the user as in the pre-refinement behavior.

### Top-level structure (§8.2)

```
auto-decide fires iff ALL of the following hold:
  PRE-CHECK 0: blackout guard passes
  AND PRE-CHECK A: single-option guard passes
  AND (T1-A OR T1-B OR T1-C OR T2-AB)                         # dominance tier
  AND signal #3: order-invariance
  AND signal #4: dimension totality (embedded inside T1-C)
  AND signal #5: no prior [AUTO-DECIDED] premises (via extract_prior_signals filter)
  AND signal #7: counterfactual self-test (post-tier; T2 uses stricter bar)
```

**Rule of thumb**: "When in doubt, escalate." If any gate is uncertain, return `escalate`.

### Dominant Option Tiers (§8.3)

**Tier-1** (single criterion suffices):

- **T1-A — Contradiction Elimination**: all other options directly contradict document-locked decisions/constraints. Exactly one option survives.
- **T1-B — Direct Requirement Match**: exactly one option verbatim/semantically satisfies a stated must/shall/required requirement.
- **T1-C — Single-Dimension Winner**: options differ in exactly **one non-equivalent dimension** and the winner on that dimension is clear. Multi-dimension advantages → escalate (signal #4).

**Tier-2** (both parts required):

- **T2-AB — Context Implication + Partial T1**:
    - **T2-A**: prior decisions / architecture / ack items provide at least 2 independent signals pointing to the same option (`extract_prior_signals` **excludes** `[AUTO-DECIDED]`; **allows** `[APPROVED]/[MODIFIED]/[USER-DIRECTED]/[AUTO-APPROVED]`).
    - **T2-B**: at least one Tier-1 criterion directionally (not necessarily fully firing) points to the same option.

**Near-dominant** (one option slightly better but not clearly): always escalate. Industry-standard defaults alone are insufficient.

### Re-evaluation Algorithm (§8.4)

```
function re_evaluate_decision(proposal, document, review_log, ack_items) -> Result:

  ── PRE-CHECK 0: Blackout Guard (Signal #1) ─────────────────
  if is_blackout(proposal.category, proposal.location, proposal.concept):
    return escalate("blackout category: <name>")

  ── PRE-CHECK A: Single-Option Guard ─────────────────────────
  if len(proposal.options) == 1:
    return escalate("single-option decision — agent may have failed to enumerate alternatives")

  ── STEP 1: T1-A — Contradiction Elimination ────────────────
  surviving = [O for O in proposal.options
               if find_contradictions(O, document, review_log,
                                      allowed_tags=["APPROVED","MODIFIED","USER-DIRECTED","AUTO-APPROVED"])
                  is empty]
  if len(surviving) == 0:
    return escalate("all options contradict locked decisions — user must resolve")
  if len(surviving) == 1:
    candidate = surviving[0]
    if not order_invariance_check(t1a, proposal.options, candidate):
      return escalate("T1-A order-variance")
    if not all_counterfactuals_implausible(proposal.options, candidate, document, ack_items, strict=False):
      return escalate("T1-A counterfactual self-test failed")
    return auto_pick(candidate, "T1-A", "all other options contradict locked decisions")

  ── STEP 2: T1-B — Direct Requirement Match ─────────────────
  requirements = extract_requirements(document)   # only "must/shall/required" text
  matching = [(O, find_requirement_match(O, requirements)) for O in surviving if matches]
  if len(matching) == 1:
    (candidate, req) = matching[0]
    if not order_invariance_check(t1b, surviving, candidate):
      return escalate("T1-B order-variance")
    if not all_counterfactuals_implausible(surviving, candidate, document, ack_items, strict=False):
      return escalate("T1-B counterfactual self-test failed")
    return auto_pick(candidate, "T1-B", f"direct requirement match at {req.location}")

  ── STEP 3: T1-C — Single-Dimension Winner (Signal #4) ──────
  non_equiv_dims = [d for d in extract_dimensions(surviving)
                    if not all_options_equivalent_on(d, surviving, document)]
  if len(non_equiv_dims) == 1:
    winner = find_dimension_winner(non_equiv_dims[0], surviving, document)
    if winner is not None:
      if not order_invariance_check(t1c, surviving, winner):
        return escalate("T1-C order-variance")
      if not all_counterfactuals_implausible(surviving, winner, document, ack_items, strict=False):
        return escalate("T1-C counterfactual self-test failed")
      return auto_pick(winner, "T1-C", f"wins on single non-equivalent dimension: {non_equiv_dims[0]}")
  # 0 non-equiv dims → options effectively equivalent (escalate for user taste)
  # 2+ non-equiv dims → multi-dim comparison is suspect (escalate)

  ── STEP 4: T2-AB — Context Implication (Signal #5 active) ──
  prior_signals = extract_prior_signals(
    review_log, ack_items, document,
    allowed_tags=["APPROVED","MODIFIED","USER-DIRECTED","AUTO-APPROVED"]
    # [AUTO-DECIDED] explicitly excluded — anti-ratchet (F4)
  )
  implied = [(O, sigs) for O in surviving
             if (sigs := get_context_signals_for(O, prior_signals))
             and len(deduplicate_by_source(sigs)) >= 2]
  if len(implied) == 1:
    (candidate, sigs) = implied[0]
    t2b_ok = (any_soft_contradiction_for_others(candidate, surviving, document)
              OR any_partial_requirement_match(candidate, document))
    if t2b_ok:
      if not order_invariance_check(t2, surviving, candidate):
        return escalate("T2 order-variance")
      # T2 strict counterfactual bar
      if not all_counterfactuals_implausible(surviving, candidate, document, ack_items, strict=True):
        return escalate("T2 strict counterfactual test failed")
      return auto_pick(candidate, "T2-AB", f"{len(sigs)} context signals + partial T1 corroboration")

  ── STEP 5: Fallback ────────────────────────────────────────
  return escalate("no dominant option identified — escalating per Ground Rule #6")
```

**Helper — `all_counterfactuals_implausible(options, candidate, document, ack_items, strict)`**:

```
for N in options where N.id != candidate.id:
  if strict:
    # T2 bar: each non-candidate must be ACTIVELY CONTRADICTED by specific
    # text already in the document (not just implausible).
    citation = find_active_contradiction_in_document(N, document)
    if citation is None: return False
  else:
    # T1 bar: counterfactual is implausible
    arg = articulate_why_wrong(N, document, ack_items)
    if arg.confidence < THRESHOLD_IMPLAUSIBLE: return False
return True
```

### Blackout Categories (§8.5)

Main session MUST classify any decision matching these categories as blackout → always escalate regardless of dominance analysis.

| Code | Category | Rule |
|---|---|---|
| **B1** | API contract / data schema / wire format | **Absolute** — externally observable to clients |
| **B2** | Authentication / authorization / security / compliance | **Absolute** — threat model lives outside the doc |
| **B3** | DB schema / migration / data lifecycle | **Absolute** — ops coordination / backfill windows |
| **B4** | User-facing UX / product flow / copy | **Absolute** — subjectivity is intrinsic |
| **B5** | Licensing / legal / data residency / PII | **Absolute** — compliance constraints outside the doc |
| **B6** | Breaking dependency / framework swap / runtime upgrade | **Absolute** — org-level consequences |
| **B7** | Performance SLO trade-off | **Conditional** — internal utility code-level perf fine; SLO/p99/throughput commitments blocked |
| **B8** | Cost-impacting infrastructure choices | **Conditional** — cost-neutral non-trade-off fine; tier/region/managed vs self-hosted blocked |
| **B9** | Observability / metric taxonomy / log schema | **Conditional** — strict internal rename fine; dashboards/alerts/SIEM exposed names blocked |
| **B10** | Concurrency / consistency / isolation level | **Absolute** — correctness-critical |

**Meta-rule**: unknown or uncertain → **blackout** (safe default).

#### Conditional checklists (B7/B8/B9 — §8.5.1)

`is_blackout()` returns boolean, but B7/B8/B9 "conditional" judgments require checklist evaluation. Return `false` (auto-decide allowed) only when **all** checklist items pass clearly. Any uncertainty → `true`.

**B7 allow-conditions (Performance SLO)**:
- [ ] Change is O-notation equivalent or improved (e.g., O(n²) → O(n log n))
- [ ] No p50/p99/p999/throughput/latency-budget/SLO numbers stated in the doc, OR if stated, are unaffected by the change
- [ ] Change scope is confined to a single function/module (not on a shared path)
- [ ] No observable impact on external API response time
- [ ] Change is not of a magnitude that requires capacity-planning re-calculation

**B8 allow-conditions (Cost / infrastructure)**:
- [ ] Change is cost-neutral or cost-reducing
- [ ] No change to resource tier / region / managed-vs-self-hosted choice
- [ ] No capability trade-off (no memory/storage/CPU capacity reduction)
- [ ] Change is at the level of "remove unused config" or "more efficient isomorphic pattern"
- [ ] Not at a billing-line-item scale

**B9 allow-conditions (Observability / log schema)**:
- [ ] Target is a strict internal field name with no doc-evidence of external exposure
- [ ] Target is already marked debug-only (or equivalent) in the doc
- [ ] Change is not a metric taxonomy / event name / log field rename/add/remove
- [ ] No doc references to downstream consumers (log aggregator / SIEM / dashboards)

**Common failure (immediate blackout regardless of checklist)**:
- Main session uncertain on any item
- Change may potentially affect external consumer / contract / SLO
- Checklist feels like it may not fully cover the boundary case

**Evaluation unit**: `is_blackout()` is called per proposal, not per option. If proposal options have different risk profiles (e.g., option A passes B7 but option B blocks it), evaluate the checklist against the **most risky option**. If any option fails any checklist item, the whole proposal is blackout=true. This false-positive bias is intentional.

### Risk-Analyst Safety Envelope (§8.6 — 7 signals)

| # | Signal | Location in algorithm |
|---|---|---|
| 1 | Blackout filter passed | PRE-CHECK 0 |
| 2 | Tier fired (T1-A ∨ T1-B ∨ T1-C ∨ T2-AB) | STEP 1–4 |
| 3 | Order-invariance: same verdict when re-evaluated with options in reverse order | per-tier post-check |
| 4 | Dimension totality: options differ in ≤1 non-equivalent dimension | embedded in T1-C |
| 5 | Transitive-premise freedom: no prior `[AUTO-DECIDED]` cited in dominance reasoning | `extract_prior_signals` filter |
| 7 | Counterfactual self-test: non-chosen options all implausible; T2 requires document citation | per-tier post-check |

> **Note**: Signal #6 (budget caps) was removed in a later refinement — F4 adversarial drift is already structurally blocked by Signal #5 (transitive-premise freedom) plus outer-cycle fresh-agent re-review, making explicit rate limiting unnecessary. Signal numbering retains the gap (1, 2, 3, 4, 5, 7) for historical traceability.

### Budget Caps (§8.7) — REMOVED

Previously INNER_CAP=2 and OUTER_CAP=5 enforced a hard rate limit on auto-decide firings. **Removed in a later refinement.** Rationale: F4 adversarial drift is already structurally blocked by Signal #5 (transitive-premise freedom), and outer-cycle fresh-agent re-review catches any auto-decided ripple. Explicit rate limiting added complexity without meaningful marginal safety. Main session performs no budget counting, no PRE-CHECK B, and does not emit `[BUDGET-DEMOTED]` markers.

### Disposition Tag Set (§3.5 + §8.8 supersession)

| Tag | 문서 변경 | escalate_applied | Ack set |
|---|---|---|---|
| `[AUTO-APPROVED]` | ✓ | ✗ | ✗ |
| `[AUTO-REJECTED]` | ✗ | ✗ | ✓ |
| `[AUTO-DECIDED]` | ✓ | **✓** | ✗ |
| `[APPROVED]` | ✓ | ✓ | ✗ |
| `[REJECTED]` | ✗ | ✗ | ✓ |
| `[MODIFIED]` | ✓ | ✓ | ✗ |
| `[USER-DIRECTED]` | ✓ | ✓ | ✗ |

**Informational markers** (not disposition tags; never counted; may appear alongside a disposition tag):

- `[SEVERITY-UPGRADED]` — severity upgrade audit (§3.11)
- `[REVERTED-BY-USER]` — reversion audit (§8.11); supports `cascade=true` and `cascade-from=PROP-Rx-y` variants
- `[REVERT-FAILED]` — semantic patching also failed (§8.11)

**`escalate_applied` formula** (§8.8 — includes §3.3 step 17 / §8.11 dedup correction):

```
# naïve formula
raw_count = count([APPROVED]) + count([MODIFIED]) + count([USER-DIRECTED]) + count([AUTO-DECIDED])

# dedup correction (per-PROP-ID group by; §3.3 step 17 / §8.11 revert dedup)
escalate_applied = raw_count
                 − |{PROP-ID groups where [AUTO-DECIDED] AND [USER-DIRECTED] co-exist}|
                 − |partial_apply duplicates within group|
```

`[AUTO-DECIDED]` is counted because it mutates the document at judgment level, so outer fresh-agent re-review must verify ripple effects. Uncounted would risk silent termination (F5).

**Inner review_log.md line format for `[AUTO-DECIDED]`**:

```
- PROP-R{round}-{N} [AUTO-DECIDED] {tier_hit} "{chosen_option_label}": {one-line rationale}
```

Example:

```
- PROP-R2-3 [AUTO-DECIDED] T1-B "로컬 파일 저장": direct requirement match at §2.3 "오프라인 우선 동기화 필수"
```

### Ground Rule #6 Amendment (§8.10)

GR#6 governs items **already in the dialogue loop**. Auto-decide governs a disjoint subset: items that never enter the dialogue loop. The two scopes are non-overlapping.

Amendment (addition, not rewrite):

> When invoked with `--auto-decide-dominant`, the main session MAY bypass user presentation for `decision`-type proposals that satisfy the Dominance Threshold (§8). This exception is narrowly scoped: it applies only to items that have never entered the dialogue loop. Any item the user has seen, is currently seeing, or has asked a follow-up about remains fully governed by GR#6. Auto-decided items MUST be logged per the Auto-Decide Audit Schema (§3.10 / §8.14) and are subject to user revert per §8.11.

Auto-decide is ON by default for this command. The user can opt out at invocation time via `--no-auto-decide-dominant`, or mid-session via the phrases in §8.12. The first-time notice in Phase 1 step 4 ensures the user is always informed that auto-decide is active before any decision is processed, preserving informed consent.

### Failure Mode Matrix (§8.15 — reference)

| Code | Failure | Mitigation |
|---|---|---|
| F1 | False positive (anchoring bias) | Signal #3 order-invariance |
| F2 | Context ignorance | Blackout list (§8.5) |
| F3 | Hidden-dimension dominance | Signal #4 dimension totality (T1-C) |
| F4 | Adversarial drift / silent ratchet | Signal #5 (transitive-premise freedom) + outer cycle re-iteration forced by [AUTO-DECIDED] counting in escalate_applied + fresh-agent re-review + mandatory 자동 선택 내역 visibility |
| F5 | Termination interaction | `[AUTO-DECIDED]` counts toward escalate_applied |
| F6 | Dialogue-loop bypass | GR#6 amendment + CLI opt-in |
| F7 | Algorithm drift across fresh agents | 7-signal reproducibility |
| F8 | Partial-apply interaction | Partial auto-decide forbidden — abort & escalate if not fully appliable |
| F9 | Malicious/bugged proposal | Blackout list blocks dangerous classes |
| F10 | User revocation of consent | Mid-session opt-out (§8.12) |

## File Schemas

### `pending_applies.md` (§3.6)

Location: `${INNER_TEMP_DIR}/pending_applies.md` — per inner iteration only. Starts empty at every outer iter. Does NOT persist across outer iters (next iter's fresh agent re-detects from doc state).

```markdown
# Pending Applies

_Edit operations deferred from their originating round. Must be empty for inner convergence._

---

### PEND-001

- **Proposal**: PROP-R2-3
- **Intended disposition**: [APPROVED]
- **Target locations**: [section 4.1, line anchor "On connection failure"]
- **Change summary**: Replace "return 500" with "return 503 with Retry-After header"
- **Failure**: Edit old_string not unique — same phrase appears in sections 4.1 and 6.2
- **Attempts**: 1
- **Deferred at**: round 2, 2026-04-13T10:15:22Z
- **Next action**: Re-scope with disambiguating context in round 3
```

**Required fields**: Proposal (original PROP-ID), Intended disposition (tag the log will get on success), Target locations, Change summary, Failure, Attempts, Deferred at (round + ISO), Next action.

**Read/write contract**:

- **Writer**: main session only. Append on Edit failure + user "defer" choice.
- **Remover**: main session only. On retry success → log disposition tag + delete block. On user abandon → `[REJECTED]` + ack + delete block.
- **Convergence reader**: non-empty iff any `### PEND-` header exists between `---` and EOF.
- **Audit reader**: at outer iter end, outer_log snapshot records final state.

### `ack_items.md` (§3.7)

Location: `${OUTER_DIR}/ack_items.md` — outer-persistent, monotone union across iterations.

```markdown
# Acknowledged Items

_Items decided to keep as-is during this design-review session. Do NOT re-propose._

---

### From Iteration 1

#### ACK-001

- **Source**: PROP-R3-2 (outer iter 1, inner round 3)
- **Disposition**: [REJECTED]
- **Category**: missing-items
- **Location**: Section 4.2 — Error Handling
- **Issue**: No retry policy specified for transient DB errors.
- **Reference text**: "On connection failure, return 500 to the client."
- **User rationale**: "클라이언트에서 재시도 처리하기로 결정. 서버는 멱등만 보장."
- **Recorded**: 2026-04-13T10:23:44Z
```

**Field requirements**:

| Field | Required | Source |
|---|---|---|
| Source | yes | outer command |
| Disposition | yes | `[REJECTED]` or `[AUTO-REJECTED]` |
| Category | yes | inner proposal |
| Location | yes | inner proposal |
| Issue | yes | inner proposal |
| Reference text | yes | inner proposal |
| User rationale | only when `[REJECTED]` | user response |
| Auto-reject rationale | only when `[AUTO-REJECTED]` | outer command |
| Recorded | yes | outer command |

**Dedup rule**: a new ack is a duplicate iff Category matches exactly AND Location refers to the same section AND Issue is semantically the same root cause (see Step 18). Append only non-duplicates under `### From Iteration N`. If N has zero new items, do not append the block.

### `outer_log.md` (§3.10 + §8.14)

Location: `${OUTER_DIR}/outer_log.md` — outer-persistent audit trail. See Step 20 above for per-iteration entry template, including `### Escalate Counter Breakdown`, `### Auto-Decides`, `### Ack Set Delta`, `### Document Mutations Summary`, `### Termination Decision`. Also hosts `### Auto-Decide Opt-Out` (one-time, §8.12).

**`### Auto-Decides` subsection (§8.14) — canonical schema**:

```markdown
### Auto-Decides

- AUTO-001: PROP-R1-4 → 옵션 B 선택 (섹션 4.2 재시도 정책)
    - trigger: T1-C
    - options_available: [A — 즉시 실패 반환, B — 지수 백오프 3회, C — 무한 재시도]
    - dominant_signal: 다른 옵션 대비 파레토 우위; 업계 표준 + 멱등 보장 호환
    - reverted: false

- AUTO-002: PROP-R2-1 → 옵션 A 선택 (섹션 3.1 인증 방식)
    - trigger: T1-B
    - options_available: [A — JWT+Refresh, B — 세션 쿠키, C — API Key, D — OAuth2 위임]
    - dominant_signal: §1 보안 요구사항(토큰 노출 최소화) 충족하는 유일한 옵션
    - reverted: "이터레이션 4에서 사용자 번복 → [USER-DIRECTED] 옵션 B 적용"
```

- `AUTO-NNN`: outer-session monotone audit ID (also exposed user-facing via 자동 선택 내역).
- `trigger`: one of `T1-A | T1-B | T1-C | T2-AB`.
- `options_available`: single-line description per option.
- `dominant_signal`: one-line rationale.
- `reverted`: `false` or `"이터레이션 N에서 사용자 번복 → {replacement disposition}"`; append `semantic_patch: true` when semantic patching was used.

### `convergence_table.md` (§3.9.3 + §8.13.4)

Location: `${OUTER_DIR}/convergence_table.md` — two tables, header rows only at init; rows appended per iter at Step 19.

See Korean UX section below for the user-facing rendering with ⚠️ markers and `**0** ✓` bold-ticks.

## Korean User-Facing UX

### Glossary (§3.9.1 + §8.13.1)

| English | Korean (full) | Korean (short) |
|---|---|---|
| outer iteration | 외부 이터레이션 | 이터레이션 |
| inner round | 내부 라운드 | 라운드 |
| escalate applied | 에스컬레이션 적용 | 에스적용 |
| auto-approved | 자동 승인 | 자동승인 |
| auto-rejected | 자동 거부 | 자동거부 |
| auto-decide / auto-decided | 자동 결정 | 자동결정 |
| convergence table | 수렴 현황표 | — |
| clean-convergence | 정상수렴 | — |
| inner-safety-hit | 내부한계 | — |
| user-abort | 사용자중단 | — |
| ack set size | 인지됨 항목 수 | ack수 |
| pending applies | 대기 중 적용 | — |
| partial iteration | 부분 이터레이션 | — |
| dominant option | 지배적 선택지 | — |
| blackout category | 블랙아웃 카테고리 | — |
| reversion / rollback | 되돌리기 / 롤백 | — |
| auto-decide revert | 자동결정 번복 | — |

**Tier ID Korean rendering** (used in 자동 선택 내역 `근거` line):

| Tier ID | Korean label |
|---|---|
| T1-A | [모순 제거] |
| T1-B | [요구사항 일치] |
| T1-C | [파레토 우위] |
| T2-AB | [맥락 함의] |

### Iteration-transition summary (§3.9.2 + §8.13.3)

Emit at end of each inner iteration (before auto-advance). Budget line appears only when `--auto-decide-dominant` is active.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 이터레이션 2 완료 요약  (2 / 최대 5회)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

내부 라운드: 4회 진행

처리 결과:
  자동 승인         2건  → 문서에 즉시 적용됨
  자동 거부         1건  → 인지됨 (재보고 안 함)
  자동 결정         2건  → 문서에 자동 선택 적용됨
  에스컬레이션 승인 3건  → 문서에 적용됨
  에스컬레이션 거부 0건
  수정 적용         1건  → 사용자 수정 후 적용됨
  사용자 지시       0건
  (대기 중 적용      2건  ⚠️ 내부 안전 한계 도달 시점에 미해소)  ← count>0 AND non clean-convergence 일 때만 노출
  ─────────────────────────────────────
  에스컬레이션 적용 합계: 6건  [승인 3 + 수정 1 + 자동결정 2]

자동 처리 내역:
  • [자동승인] PROP-R2-1: 필드명 일관성 — userId → user_id로 통일
  • [자동승인] PROP-R3-2: 오타 수정 — "respponse" → "response"
  • [자동거부] PROP-R2-3: 이미 섹션 4.1에서 다룬 내용 (중복)

자동 선택 내역:  (에이전트가 결정형 제안을 독립 판단으로 선택 — 이의 있으면 PROP-ID 또는 AUTO-NNN 언급)
  • [자동결정] PROP-R1-4 (AUTO-001) (섹션 4.2 — 재시도 정책)
    선택됨: B — 지수 백오프 + 최대 3회 재시도
    근거: [파레토 우위] 다른 옵션 대비 모든 축에서 동등 이상 — 업계 표준이며 기존 설계의 멱등 보장과 호환됨
    미선택 옵션:
      A — 즉시 실패 반환  (클라이언트 재시도 부담 과중)
      C — 무한 재시도     (리소스 고갈 위험; 안전 한계 없음)

판정: 계속 진행 → 이터레이션 3 시작
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Block visibility rules**:

- `처리 결과 / 자동 결정` line: **omit entirely** when auto-decide is disabled for the session (via `--no-auto-decide-dominant` or mid-session opt-out).
- `대기 중 적용` line: only when count > 0 AND the iteration is non-clean-convergence.
- `자동 처리 내역`: always emitted (may have 0 items).
- `자동 선택 내역`: only when auto-decide count > 0 this iter.

**Verdict line variants** (always emitted):

- Clean convergence / outer termination: `판정: ✅ 외부 수렴 완료 — 에스컬레이션 적용 0건 · 정상 수렴 확인 / 문서가 안정 상태에 도달했습니다.`
- Escalate-zero but partial iteration (safety-limit-fresh-outer): `판정: ⚠️ 에스컬레이션 적용 0건이나 부분 이터레이션으로 수렴 미확인 / 내부 라운드가 안전 한계로 조기 종료됨 — 이터레이션 {N+1}에서 재검증합니다.`
- Continue: `판정: 계속 진행 → 이터레이션 {N+1} 시작 / (에스컬레이션 적용 {k}건 — 문서 변경 발생)`

**Header variant for opt-out active iterations**:

```
📋 이터레이션 3 완료 요약  (3 / 최대 5회)  [자동결정 비활성 — 사용자 중단]
```

### Convergence tables (§3.9.3 + §8.13.4)

```markdown
## 수렴 현황

### 처리 결과 현황표

| 이터 | 라운드 | 자동승인 | 자동거부 | 자동결정 | 에스적용 | 에스거부 |
| :--: | :----: | :------: | :------: | :------: | :------: | :------: |
|  1   |   5    |    4     |    2     |    1     |    4     |    1     |
| 2 ⚠️ |   20   |    2     |    1     |    3     |    2     |    0     |
|  3   |   2    |    1     |    0     |    0     | **0** ✓  |    0     |

⚠️ 부분 이터레이션 — 내부 안전 한계 도달로 조기 종료됨.
에스적용 수치가 실제보다 낮을 수 있습니다.

### 수렴 진단표

| 이터 | 적용실패 | 부분종료 | ack수 |  종료사유  |
| :--: | :------: | :------: | :---: | :--------: |
|  1   |    0     |  아니오  |   3   |  정상수렴  |
| 2 ⚠️ | **2** ⚠️ |    예    |   4   |  내부한계  |
|  3   |    0     |  아니오  |   4   | 정상수렴 ✓ |
```

- `종료사유` values: `정상수렴` / `내부한계` / `사용자중단`
- `적용실패` = maximum size `pending_applies.md` reached during the iter (not final value).
- **Invariant**: `종료사유 == 정상수렴` ⇒ `부분종료 == 아니오`.

### Prompt templates

**§3.9.4.a — Outer safety limit reached (5회)**:

```
외부 이터레이션 안전 한계(5회)에 도달했습니다.

[convergence table inline]

아직 수렴이 완료되지 않았습니다 (에스컬레이션 적용 합계 > 0).
계속 진행하시겠습니까?
```

AskUserQuestion: `"5회 추가 진행"` / `"현재 상태로 종료"`

**§3.9.4.b — Inner safety limit reached, `pending_dialogue > 0` (A recommended)**:

```
이터레이션 {N}의 내부 라운드가 안전 한계({inner_limit}회)에 도달했습니다.

현재 대화 중인 제안이 {pending}건 남아 있습니다.
지금 종료하면 해당 제안들이 미처리 상태로 넘어갑니다.

어떻게 진행하시겠습니까?
```

Options:
- `"A: 10회 추가 진행 ← 추천 (미완료 대화 처리 후 계속)"`
- `"B: 이번 이터레이션 종료 후 새 이터레이션 시작"`
- `"C: 외부 이터레이션 전체 종료"`

**§3.9.4.c — Inner safety limit, `pending_dialogue == 0` (B recommended)**:

```
이터레이션 {N}의 내부 라운드가 안전 한계({inner_limit}회)에 도달했습니다.

미완료 대화는 없습니다. 이번 이터레이션의 에스컬레이션 적용: {esc_applied}건.

어떻게 진행하시겠습니까?
```

Options:
- `"A: 10회 추가 진행"`
- `"B: 이번 이터레이션 종료 후 새 이터레이션 시작 ← 추천"`
- `"C: 외부 이터레이션 전체 종료"`

**§3.9.4.d — Free-form abort request ("그만" etc.)**:

```
진행을 중단하시겠습니까?

현재 상태:
  • 이터레이션 {N} 진행 중 (라운드 {M}/{inner_limit})
  • 이번 이터레이션에서 에스컬레이션 적용: {k}건
  • 이미 적용된 변경사항은 문서에 유지됩니다.
```

Options: `"지금 즉시 종료"` / `"현재 라운드 완료 후 종료"` / `"계속 진행"`

**§3.9.4.e — Final completion summary**:

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
    — 자동 결정:    {sum_auto_decided}건
  자동 거부 (인지됨):              {sum_auto_rejected}건
  에스컬레이션 거부 (인지됨):      {sum_rejected}건

문서 상태: 설계 완료 ✓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Where `sum_escalate_applied = sum_approved + sum_modified + sum_directed + sum_auto_decided` (after per-PROP-ID dedup — reversion collapses `[AUTO-DECIDED]` into the subsequent `[USER-DIRECTED]`).

### Auto-advance / Status line rules (§3.9.5)

**Auto-advance**: after emitting the iteration-transition summary, start the next iteration immediately. No countdown. User intervention only occurs at (1) outer safety prompt, (2) inner safety prompt, (3) escalated AskUserQuestion, (4) free-form input during those prompts.

**Status line emission**:

```
emit if: round_number == 1
       OR round_number % 5 == 0
       OR round_number == inner_limit
```

Formats:

- Normal: `[이터레이션 2/5 · 라운드 5] 설계 검토 중...`
- Inner safety limit hit: `[이터레이션 2/5 · 라운드 20] 내부 안전 한계 도달`
- Outer iter start: `━━━ 이터레이션 3 시작 ━━━`

A full 5×20 maximal run compresses to roughly 25 status lines — readable rather than spammy.

## Ground Rules

1. **Propose first, then triage.** All issues are generated as concept proposals. The agent never modifies the design document directly. The main session self-triages each proposal: unambiguous fixes are auto-approved and applied, false positives are auto-rejected, and only items requiring judgment are escalated to the user.
2. **Agent Loop required.** Phase 2 iterative inner review must use the agent-based loop. Exit requires either severity saturation (`consecutive_no_major >= 2` + empty pending + no in-progress dialogues) or the user's explicit 3-option choice at inner safety limit.
3. **Agent independence.** Each review agent reviews the document from scratch. Previous round results are only accessed via `$INNER_TEMP_DIR/review_log.md`, which is seeded with the outer-persistent ack set at the start of each outer iteration.
4. **Review log required.** Every round's results must be recorded in `$INNER_TEMP_DIR/review_log.md` with disposition tags: `[AUTO-APPROVED]`, `[AUTO-REJECTED]`, `[AUTO-DECIDED]`, `[APPROVED]`, `[REJECTED]`, `[MODIFIED]`, `[USER-DIRECTED]`. Informational markers (`[SEVERITY-UPGRADED]`, `[REVERTED-BY-USER]`, `[REVERT-FAILED]`) are appended as needed but never count toward any metric.
5. **Respect acknowledged items.** Items decided to keep as-is (rejected and auto-rejected proposals) must not be re-reported in subsequent rounds or iterations. The outer-persistent `ack_items.md` enforces this across the whole outer session.
6. **Triage bias toward escalation.** When the main session is uncertain whether a proposal is unambiguous, it MUST escalate. Self-triage exists to reduce trivial questions, never to silently override user authority on judgment calls.
7. **Never decide for the user.** When the user responds to a pending decision with a follow-up question, a request for more context, or a discussion point, this is NOT a decision. Continue the conversation via AskUserQuestion until the user states an explicit decision. A decision is only confirmed when the user clearly says what to do (e.g., "A로 가자", "현재 유지", "변경해줘"). Questions like "그러면 ~는 어떻게 되나요?" or "~에 대해 좀 더 설명해줘" are continuation signals, not decisions. This rule applies equally to Other input handling in the Processing Protocol.

   **GR#7 Amendment (§8.10)** — When invoked with `--auto-decide-dominant`, the main session MAY bypass user presentation for `decision`-type proposals that satisfy the Dominance Threshold (§8). This exception is narrowly scoped: it applies only to items that have never entered the dialogue loop. Any item the user has seen, is currently seeing, or has asked a follow-up about remains fully governed by the paragraph above. Auto-decided items MUST be logged per the Auto-Decide Audit Schema (§3.10 / §8.14) and are subject to user revert per §8.11.

## Options

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

### --auto-decide-dominant / --no-auto-decide-dominant

Decision Auto-Select Protocol (§8) is **ON BY DEFAULT**. When the main session's independent re-evaluation identifies a dominant option for a `decision`-type proposal, it is auto-picked and recorded as `[AUTO-DECIDED]`. This minimizes user fatigue while preserving safety via the §8 guards.

**Flag semantics**:

- **(default, no flag)**: auto-decide enabled. Equivalent to passing `--auto-decide-dominant` explicitly.
- **`--auto-decide-dominant`**: explicit opt-in (no-op when default is enabled — kept for backward-compatible documentation and explicit invocations).
- **`--no-auto-decide-dominant`**: opt-out. Disables auto-decide for the entire session. All `decision`-type proposals escalate to the user as in pre-refinement behavior.

When auto-decide is active:

- `re_evaluate_decision` is called for each `decision`-type proposal after self-triage and before user escalation (Phase 2 Step 12.f).
- Blackout categories (B1–B10 with B7/B8/B9 conditional checklists) are always escalated regardless of dominance analysis.
- `AUTO_DECIDE_ENABLED` flag is restored from `outer_log.md` at the start of every outer iter (§8.12 persistence) — Claude Code bash vars are volatile across turns.
- First-time Korean notice is emitted once at session start (§8.9, in Phase 1 step 4).
- Mid-session opt-out is accepted at any dialogue-loop prompt via the phrase patterns in §8.12 Pre-check 1. Once opted out, re-activation is forbidden for the remainder of the session.
- User may revert any auto-decision via PROP-Rx-y or AUTO-NNN reference at any dialogue-loop prompt (§8.11).
- **Outer cycle continuation guarantee**: any iteration that produces ≥1 `[AUTO-DECIDED]` item naturally satisfies `COUNT_APPLIED > 0` (since `[AUTO-DECIDED]` is included in the COUNT_APPLIED formula per §8.8 / Step 17), forcing the outer loop to run another iteration and re-verify the auto-decision's ripple effects with a fresh agent group. No special-case logic needed — this falls out of the existing termination predicate.

Flag parsing is done together with `--base` in Phase 1 step 2 (all three flags `--base`, `--auto-decide-dominant`, `--no-auto-decide-dominant` are stripped from `ARGS_CLEAN`; presence is detected into `BASE_MODE` and `AUTO_DECIDE_INITIAL` booleans). `AUTO_DECIDE_INITIAL` defaults to `true`; `--no-auto-decide-dominant` flips it to `false`.

**The flag is NOT propagated to review agents** — auto-decide is a main-session-only mechanism.

## Begin

$ARGUMENTS
