# 변이 코퍼스 매니페스트 — PreToolUse 훅

**조항·읽기 규칙·스키마 검사는 여기 없다.** 그것들은 코퍼스 불변이므로
`tests/mutation-harness/`가 갖는다. 이 파일은 이 코퍼스에만 해당하는 것 —
공시, 측정, 행 목록 — 만 갖고 조항을 다시 쓰지 않는다. 다시 쓰는 순간
그 사본이 원본과 조용히 갈라지고, 그것이 그 거처가 존재하는 이유다.

- **변이 대상**: `plugins/cc-cmds/hooks/active-notify-pretool.sh`
- **픽스처 집합**: `tests/fixtures/active-notify-hooks` (10개 행이 이 집합에 대해 선언된다)
- **하네스**: `scripts/test-active-notify-hooks-mutations.sh`
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

`test-active-notify-hooks-mutations.sh --self-check` → **12 passed, 0 failed**
(행 10 + 자기 점검 통제군 2), 추적 훅 sha256 `24c6c4aead25` 전후 동일.
**픽스처 12개 중 6개가 적어도 한 행의 단독 사살자다.**

**이 드라이버는 픽스처마다 두 레그(`inject_sid` 0과 1)를 돈다.** 하네스의 적색
집합은 픽스처 단위이고 드라이버의 계수는 레그 단위이므로, 어느 한 레그라도 실패하면
그 픽스처가 붉은 것으로 읽고 정합성 대조는 레그 단위로 한다 — 두 단위를 섞으면
반쪽만 붉은 픽스처가 없을 때만 우연히 맞는 비교가 된다.

## 행 목록

| 행 | 이 행이 되돌리는 성질 | 기대 적색 집합 |
| --- | --- | --- |
| `H1-separator-loosened` | the separator between the path and the subcommand becomes optional | separator-required |
| `H10-bypass-matcher-anchored` | the bypass matcher is anchored, rejecting the documented multi-line form | bypass-skill-block-verbatim |
| `H2-bypass-matcher-to-pipeline` | the bypass matcher feeds grep through a pipeline again | large-input-bypass |
| `H3-bypass-matcher-to-bash-ere` | the bypass matcher goes back to bash ERE, whose dot crosses a newline | bypass-match |
| `H4-absolute-path-guard-dropped` | the absolute-path guard is removed | suffix-injection-no-match |
| `H5-traversal-glob-guard-dropped` | the traversal and glob guards are removed | suffix-injection-no-match |
| `H6-session-id-tostring-reverted` | the session id is no longer reduced to one shell word | sid-metachar-quoting |
| `H7-notify-leg-rule-restored` | the notify leg emits a session-persistent rule again — this row's expected red set is the three fixtures whose headers describe that leg, so whoever restores the rule is the one who reads this line and the prose above those assertions | notify-match, fire-now-match, fire-oneshot-match |
| `H8-bypass-leg-rule-dropped` | the bypass leg stops emitting its rule | bypass-match |
| `H9-path-segment-class-to-blank` | the path segment's negation class becomes [:blank:], swallowing a newline | suffix-injection-no-match |
