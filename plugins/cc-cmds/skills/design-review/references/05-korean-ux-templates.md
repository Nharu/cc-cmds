# Korean User-Facing UX Templates

Glossary, iteration-transition summary block, convergence table rendering, prompt templates (§3.9.4.a~e), and status-line emission rules. Read this file at each iteration-transition summary emission (Step 25) and immediately before each safety-limit prompt (Step 16, Step 24).

## Glossary (§3.9.1 + §8.13.1)

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

## Iteration-transition summary (§3.9.2 + §8.13.3)

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

### Block visibility rules

- `처리 결과 / 자동 결정` line: **omit entirely** when auto-decide is disabled for the session (via `--no-auto-decide-dominant` or mid-session opt-out).
- `대기 중 적용` line: only when count > 0 AND the iteration is non-clean-convergence.
- `자동 처리 내역`: always emitted (may have 0 items).
- `자동 선택 내역`: only when auto-decide count > 0 this iter.

### Verdict line variants (always emitted)

- Clean convergence / outer termination: `판정: ✅ 외부 수렴 완료 — 에스컬레이션 적용 0건 · 정상 수렴 확인 / 문서가 안정 상태에 도달했습니다.`
- Escalate-zero but partial iteration (safety-limit-fresh-outer): `판정: ⚠️ 에스컬레이션 적용 0건이나 부분 이터레이션으로 수렴 미확인 / 내부 라운드가 안전 한계로 조기 종료됨 — 이터레이션 {N+1}에서 재검증합니다.`
- Continue: `판정: 계속 진행 → 이터레이션 {N+1} 시작 / (에스컬레이션 적용 {k}건 — 문서 변경 발생)`

### Header variant for opt-out active iterations

```
📋 이터레이션 3 완료 요약  (3 / 최대 5회)  [자동결정 비활성 — 사용자 중단]
```

## Convergence tables (§3.9.3 + §8.13.4)

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

## Prompt templates

### §3.9.4.a — Outer safety limit reached (5회)

```
외부 이터레이션 안전 한계(5회)에 도달했습니다.

[convergence table inline]

아직 수렴이 완료되지 않았습니다 (에스컬레이션 적용 합계 > 0).
계속 진행하시겠습니까?
```

AskUserQuestion: `"5회 추가 진행"` / `"현재 상태로 종료"`

### §3.9.4.b — Inner safety limit reached, `pending_dialogue > 0` (A recommended)

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

### §3.9.4.c — Inner safety limit, `pending_dialogue == 0` (B recommended)

```
이터레이션 {N}의 내부 라운드가 안전 한계({inner_limit}회)에 도달했습니다.

미완료 대화는 없습니다. 이번 이터레이션의 에스컬레이션 적용: {esc_applied}건.

어떻게 진행하시겠습니까?
```

Options:
- `"A: 10회 추가 진행"`
- `"B: 이번 이터레이션 종료 후 새 이터레이션 시작 ← 추천"`
- `"C: 외부 이터레이션 전체 종료"`

### §3.9.4.d — Free-form abort request ("그만" etc.)

```
진행을 중단하시겠습니까?

현재 상태:
  • 이터레이션 {N} 진행 중 (라운드 {M}/{inner_limit})
  • 이번 이터레이션에서 에스컬레이션 적용: {k}건
  • 이미 적용된 변경사항은 문서에 유지됩니다.
```

Options: `"지금 즉시 종료"` / `"현재 라운드 완료 후 종료"` / `"계속 진행"`

### §3.9.4.e — Final completion summary

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

## Auto-advance / Status line rules (§3.9.5)

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
