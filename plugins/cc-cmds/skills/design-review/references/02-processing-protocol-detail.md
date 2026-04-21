# Processing Protocol Detail (§8.11 + §8.12)

Detailed handling for the two Processing Protocol pre-checks: auto-decide opt-out (§8.12) and reversion (§8.11). The SKILL.md keeps only the trigger regex and high-level disposition table — this file contains the full action sequences.

Read this file when a user response matches either of the pre-check regex patterns during Step 12.h Processing Protocol.

## Pre-check 1: Opt-out action (§8.12)

Match regex: `(자동결정|자동 선택|auto.decide)` + `(중단|끄|해제|그만|비활성|수동|직접)`.

Known phrases:

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

## Pre-check 2: Reversion action (§8.11)

Match regex: `(PROP-ID|AUTO-NNN|방금|전부) + (취소|되돌리|번복|롤백|revert|undo)`. Both `PROP-Rx-y` and `AUTO-NNN` are accepted as user-facing IDs. On ID conflict, **AUTO-NNN takes precedence** (it's session-unique, whereas PROP-IDs can collide across outer iterations).

Known phrase patterns:

```
PROP-R1-4 자동결정 취소해줘
PROP-R2-1 되돌려줘 — 내가 직접 선택할게
자동결정 PROP-R3-2 번복
방금 자동 선택 되돌려          ← interprets as "most recent non-reverted auto-decide"
자동 선택 전부 되돌려          ← interprets as "all non-reverted auto-decides in the current outer iter"
AUTO-002 롤백
```

### Reversion action sequence

1. Read the `Change applied` field from the matching `AUTO-NNN` entry in `$OUTER_DIR/outer_log.md` (or, for the current iter before Step 20, from the in-memory audit buffer + `[AUTO-DECIDED]` line in `review_log.md`).
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

## Disposition handling (normal path)

When the response does NOT match pre-check 1 or pre-check 2, fall through to normal disposition handling:

- **"승인" selected** (or a Decision option selected): Apply the change to the design document using the concretized scope. Log as `[APPROVED]` in `review_log.md`.
- **"거부 (현재 유지)" selected**: Record the item under `## Acknowledged Items` in `review_log.md`. Log as `[REJECTED]`. Future agents will skip this item.
- **Other input** (not matching any pre-check above): Main session interprets the input in context:
  - **Modification request** (e.g., "statusCode 말고 status_code로", "섹션 5.2는 빼줘"): Re-scope with the user's modification, apply the change. Log as `[MODIFIED]`.
  - **Question or discussion** (e.g., "기존 클라이언트 호환성은?"): Answer the question via AskUserQuestion, then re-ask the same proposal. Continue this dialogue loop until the user gives an explicit decision (Ground Rule #6).
  - **New direction** (e.g., "인증을 아예 refresh token 방식으로 바꾸자"): Apply the new direction with appropriate scope analysis. Log as `[USER-DIRECTED]`.
