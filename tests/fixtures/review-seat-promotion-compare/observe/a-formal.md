# 코드 리뷰 보고서 — 정식 좌석 필드

## 개요

- **리뷰 날짜**: 2026-10-20
- **리뷰 대상**: 브랜치 `seg/fx-a`, 커밋 범위 `1111111...2222222`
- **리뷰 모드**: 전체
- **리뷰 HEAD**: `2222222222222222222222222222222222222222`
- **모델 티어**:
    - logic-shell | 부류=logic | 모델=opus | 출처=승격 | 지표=authz,shared-contract | 재기동=-
    - code-quality | 부류=quality | 모델=sonnet | 출처=표 | 지표=- | 재기동=-
- **발견 요약**: 🔴 P0 1건 | 🟠 P1 5건 | 🟡 P2 0건 | 🟢 P3 0건

## 🔴 P0 — 즉시 수정

- **[logic]** `a.sh:1` 승격 좌석만 낸 항목 — logic-shell
    - **좌석**: 낸=logic-shell | 동의=-
    - **근거**: 픽스처

## 🟠 P1 — 머지 전 수정

- **[차단]** **[logic]** `a.sh:2` 둘이 함께 낸 항목 — logic-shell · code-quality
    - **좌석**: 낸=logic-shell,code-quality | 동의=-
- **[이월 가능]** **[code-quality]** `a.sh:3` 표 좌석이 내고 승격 좌석이 동의 — code-quality
    - **좌석**: 낸=code-quality | 동의=logic-shell
- **[차단]** **[logic]** `a.sh:4` 승격 좌석이 내고 표 좌석이 동의 — logic-shell
    - **좌석**: 낸=logic-shell | 동의=code-quality
- **[차단]** **[code-quality]** `a.sh:5` 표 좌석만 — code-quality
    - **좌석**: 낸=code-quality | 동의=-
- **[차단]** **[logic]** `a.sh:6` 철자가 틀린 좌석 줄 — logic-shell
    - **좌석**: 낸=Logic-Shell | 동의=-

## 🟡 P2 — 개선 권장

- **[logic]** `a.sh:7` P2 는 세지 않는다 — logic-shell
