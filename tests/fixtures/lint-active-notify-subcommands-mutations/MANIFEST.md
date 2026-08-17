# 변이 코퍼스 매니페스트 — 서브커맨드 린트

**조항·읽기 규칙·스키마 검사는 여기 없다.** 그것들은 코퍼스 불변이므로
`tests/mutation-harness/`가 갖는다. 이 파일은 이 코퍼스에만 해당하는 것 —
공시, 측정, 행 목록 — 만 갖고 조항을 다시 쓰지 않는다. 다시 쓰는 순간
그 사본이 원본과 조용히 갈라지고, 그것이 그 거처가 존재하는 이유다.

- **변이 대상**: `scripts/lint-active-notify-subcommands.sh`
- **픽스처 집합**: `tests/fixtures/lint-active-notify-subcommands` (6개 행이 이 집합에 대해 선언된다)
- **하네스**: `scripts/test-lint-active-notify-subcommands-mutations.sh`
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

`test-lint-active-notify-subcommands-mutations.sh --self-check` → **7 passed, 0 failed**
(행 6 + 자기 점검 통제군 **1**), 추적 린트 sha256 `5eaada590f83` 전후 동일.
**픽스처 15개 중 4개가 적어도 한 행의 단독 사살자다.**

**통제군 둘 중 하나만 돌았다.** 과소 선언은 픽스처 둘 이상을 선언하는 행에서만
표현 가능한데 이 코퍼스에는 그런 행이 없다(유효 행 넷이 전부 단원소, 나머지 둘은
퇴화). 하네스는 그 사실을 `NOTE`로 찍는다 — 침묵하면 돌지 않은 통제군이 돈 것으로
읽히기 때문이다.

## 행 목록

| 행 | 이 행이 되돌리는 성질 | 기대 적색 집합 |
| --- | --- | --- |
| `S1-extractor-back-to-allowlist` | the positional reader falls back to an allowlist of recognized spellings | ERR-2-unrecognized-arm |
| `S2-rule1-boundary-to-word-boundary` | rule 1 boundary becomes a word boundary, so a trailing segment counts as coverage | FAIL-8-trailing-segment-not-coverage |
| `S3-rule3-tolower-dropped` | rule 3 stops folding the cardinality word before mapping it | OK-3-capitalized-cardinality |
| `S4-rule1-case-fold-dropped` | rule 1 stops folding case, so a phase-register surface is flagged | OK-2-uppercase-only-surface |
| `S5-normalizer-stops-stripping-asterisk` | the alternation normalizer stops stripping the asterisk | **퇴화 — 아무것도 붉히지 않는다고 선언** |
| `S6-normalizer-also-strips-underscore` | the normalizer also strips the underscore, which it deliberately does not | **퇴화 — 아무것도 붉히지 않는다고 선언** |
