# In-Session Verification Contract (fixture SOT)

Structural copy: it carries the sections the pins are scoped to, not a flat list
of every frozen byte. A flat list cannot express a region-scoping defect.

## 1. Claim taxonomy (5 categories)

classification tokens: 정적 사실 / 실행 측정 / 외부 환경 / 행동 가설 / 미니 구현

## 3. Frozen vocabulary (the verdict/residual token table)

| 축 | 값 |
| --- | --- |
| 원장 종단자 | `검증됨(통과) · 반증됨(실패)` |
| 저장 금지 | `미검증` |
| 저장 시 잔여 | `(see below)` |
| 구현 시 플립 전용 | `검증불가(드리프트)` |

### 3.1 `잔여 사유` — closed set of 4 values

구현 필요 / 검증 차단 / 예산 소진 / 분류 제외

### 3.2 `실행 주의` — closed class of 4 values

유료/외부 변이 / 머신 상태 변이 / 장시간(>10분) / 파괴적

### 3.5 Spelling lock

The head literal carries no internal space.

## 4. Verification ledger schema — ## 검증 기록

Field key: 검증 등급.

## 5. Residual-item contract — ## 구현 시 검증 항목

timing enum: 구현 전 / 구현 중(<phase>) / 구현 후

note-line key: **구현 시 검증 기록**

저장 시 잔여 등급은 구현 시 검증 이다.
