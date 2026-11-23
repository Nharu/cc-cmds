# 대책 기록 등록부 — 픽스처

OK-new-lint-recorded 와 같고 데모 린트의 기록만 없다.

## 기록

### 데모 게이트 룰
**종류**: 게이트 룰
**위치**: `plugins/cc-cmds/orchestrator/rules/demo.rule#거부 조건`
**막을 사례**: `tests/fixtures/demo/cases.txt#룰이 거부하는 경우`
**이웃 사례**: `tests/fixtures/demo/cases.txt#룰이 통과시키는 경우`
**우회 경로**: 알려진 것 없음 — 픽스처라 찾아보지 않았다
**오차단**: 미측정
**재시도**: 2 — 2026-11-23 기준, 픽스처의 예시 값
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### 데모 훅
**종류**: 훅
**위치**: `plugins/cc-cmds/hooks/demo-guard.sh`
**막을 사례**: `tests/fixtures/demo/FAIL-hook/` — 훅이 막는 입력
**이웃 사례**: `tests/fixtures/demo/OK-hook/`; 다른 도구 호출은 그대로 둔다
**우회 경로**: hooks.json 밖에서 같은 명령을 부르면 훅이 보지 못한다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

## 대책 아닌 감지 파일
