# 변이 코퍼스 매니페스트 — 라이프사이클 디스패처

**조항·읽기 규칙·스키마 검사는 여기 없다.** 그것들은 코퍼스 불변이므로
`tests/mutation-harness/`가 갖는다. 이 파일은 이 코퍼스에만 해당하는 것 —
공시, 측정, 행 목록 — 만 갖고 조항을 다시 쓰지 않는다. 다시 쓰는 순간
그 사본이 원본과 조용히 갈라지고, 그것이 그 거처가 존재하는 이유다.

- **변이 대상**: `plugins/cc-cmds/skills/active-notify/scripts/notify.sh`
- **픽스처 집합**: `tests/fixtures/active-notify-lifecycle` (8개 행이 이 집합에 대해 선언된다)
- **하네스**: `scripts/test-active-notify-lifecycle-mutations.sh`
- **사전 측정 블록**: `PRE-MEASUREMENT` (픽스처 집합의 **내용** 해시. 리비전이 아니다 — 리비전 비교는 그것이 무효화할 바로 그 더러운 트리에서 통과한다)

## 공시 — 이 코퍼스가 잡지 않는 것

**양쪽 퇴화 끝은 잡히지 않는다.** 전부를 붉히거나 아무것도 붉히지 않으면서
정직하게 선언하는 유효한 변이체는 어떤 비교로도 기형 변이체와 구별되지 않는다.
대역 안에 적색 비율 임계값을 두는 안은 실측에서 분리 불가로 기각됐고(사고로 만든
기형 변이체가 15중 4, 정당한 사전 등록 행이 35중 10 — 1.9포인트 차이),
끝에 두는 안은 측정된 두 사례를 둘 다 놓친다. **공시가 처분이다.**

**행이 통과한다는 것은 그 픽스처가 그 성질을 고정한다는 뜻이고, 그 이상이 아니다.**
어떤 성질이 어느 행에도 없다는 것은 「고정되지 않았다」가 아니라 「아무도 그것을
행으로 적지 않았다」이다.

## 측정 (2026-08-17, 이 커밋의 트리에서)

`test-active-notify-lifecycle-mutations.sh --self-check` → **10 passed, 0 failed**
(행 8 + 자기 점검 통제군 2), 추적 디스패처 sha256 `398fc8b62740` 전후 동일.

**이 하네스는 단독 사살 수치를 발행하지 않는다.** 형제 코퍼스 셋은 그 수치를 찍는데
이쪽은 찍지 않으며, 그 차이는 이 코퍼스의 판별력이 낮다는 뜻이 아니라 **아무도 그
수치를 계산하는 코드를 이 파일에 넣지 않았다**는 뜻이다. 없는 수치를 형제에서
유추해 적지 않는다.

## 행 목록

| 행 | 이 행이 되돌리는 성질 | 기대 적색 집합 |
| --- | --- | --- |
| `M1-revert-atomic-write` | (설명 없음) | arm-cleans-staging-file-on-failure, arm-write-is-atomic |
| `M2-drop-trap-tmp-cleanup` | (설명 없음) | arm-cleans-staging-file-on-failure |
| `M3-drop-trap-lock-held-gate` | (설명 없음) | arm-fail-open-keeps-holders-lock |
| `M4a-restore-shared-cycle-sentinel` | (설명 없음) | fire-oneshot-tick-sentinel-is-separate |
| `M4b-restore-own-tick-sentinel` | (설명 없음) | fire-oneshot-tick-sentinel-is-separate |
| `M5-remove-budget-guard` | (설명 없음) | lock-budget-derivation-guarded |
| `M6-remove-budget-fallback-diagnostic` | the budget fallback repairs the value without saying so | lock-budget-derivation-guarded |
| `M7-blur-silent-failure-conditions` | the corrected three-condition mechanism blurred back to the wrong one | **퇴화 — 아무것도 붉히지 않는다고 선언** |
