# File Schemas

Schemas for the four persistent files touched by the outer/inner loops. Read before writing or modifying any of these files.

## `pending_applies.md` (§3.6)

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

### Read/write contract

- **Writer**: main session only. Append on Edit failure + user "defer" choice.
- **Remover**: main session only. On retry success → log disposition tag + delete block. On user abandon → `[REJECTED]` + ack + delete block.
- **Convergence reader**: non-empty iff any `### PEND-` header exists between `---` and EOF.
- **Audit reader**: at outer iter end, outer_log snapshot records final state.

## `ack_items.md` (§3.7)

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

### Field requirements

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

### Dedup rule

A new ack is a duplicate iff Category matches exactly AND Location refers to the same section AND Issue is semantically the same root cause (see Step 18). Append only non-duplicates under `### From Iteration N`. If N has zero new items, do not append the block.

## `outer_log.md` (§3.10 + §8.14)

Location: `${OUTER_DIR}/outer_log.md` — outer-persistent audit trail. See SKILL.md Step 20 for the per-iteration entry template, including `### Escalate Counter Breakdown`, `### Auto-Decides`, `### Ack Set Delta`, `### Document Mutations Summary`, `### Termination Decision`. Also hosts `### Auto-Decide Opt-Out` (one-time, §8.12).

### `### Auto-Decides` subsection canonical schema (§8.14)

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

## `convergence_table.md` (§3.9.3 + §8.13.4)

Location: `${OUTER_DIR}/convergence_table.md` — two tables, header rows only at init; rows appended per iter at Step 19.

Headers written at Phase 1 step 3:

```markdown
# Convergence Tables

## 처리 결과 현황표

| 이터 | 라운드 | 자동승인 | 자동거부 | 자동결정 | 에스적용 | 에스거부 |
| :--: | :----: | :------: | :------: | :------: | :------: | :------: |

## 수렴 진단표

| 이터 | 적용실패 | 부분종료 | ack수 |  종료사유  |
| :--: | :------: | :------: | :---: | :--------: |
```

See `05-korean-ux-templates.md` for the user-facing rendering with ⚠️ markers and `**0** ✓` bold-ticks (rendered at iteration-transition summary and final completion summary).
