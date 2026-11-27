# 대책 기록 등록부

반복 실수를 막으려고 넣은 대책(린트·훅·게이트 룰·프롬프트 조항)마다 막을 사례, 이웃 사례, 우회 경로, 운영 비용, 규칙 상태, 판정을 한 블록으로 적는 곳이다. 쓰는 법과 각 칸의 뜻은 `scripts/countermeasure-protocol.md` 에 있고, `scripts/lint-countermeasure-records.sh` 가 이 파일을 트리와 대조한다.

- `## 기록` 의 `### <이름>` 블록 하나가 대책 하나다.
- `## 대책 아닌 감지 파일` 은 린트가 감지하지만 실패를 막지 않는 파일의 면제 목록이다. 줄마다 `` - `<경로>` — <사유> `` 꼴로 적는다.
- 규약보다 먼저 트리에 있던 대책은 `scripts/lint-countermeasure-records.baseline` 에 있다. 그 대책에 기록을 쓰면 기준선의 줄을 지운다.

## 기록

### 알림 환경 변수 이름 린트
**종류**: 린트
**위치**: `scripts/lint-notify-env-name.sh`
**막을 사례**: `tests/fixtures/lint-notify-env-name/FAIL-name-drift/` — 알림 스위치 변수 이름이 정본과 어긋난 경우; `tests/fixtures/lint-notify-env-name/FAIL-unregistered-switch/` — 등록되지 않은 스위치 변수를 읽는 경우
**이웃 사례**: `tests/fixtures/lint-notify-env-name/OK-match/` — 이름이 정본과 같은 경우는 통과시킨다
**우회 경로**: 알려진 것 없음 — 대책 기록 규약을 들일 때 린트 본문과 픽스처만 읽었고 다른 진입 경로는 찾아보지 않았다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### 스테이지 규칙 편집 훅
**종류**: 훅
**위치**: `plugins/cc-cmds/hooks/stage-rules-edit.sh`
**막을 사례**: `scripts/test-stage-rules-edit-hook.sh#spoke "앵커 고치기"` — 고친 지침 파일의 `강제:` 표지 앵커가 죽으면 훅이 고치라고 말한다
**이웃 사례**: `scripts/test-stage-rules-edit-hook.sh#silent "다른 CLAUDE.md"` — 사용자 지침 파일이 아닌 CLAUDE.md 편집에는 말하지 않는다
**우회 경로**: Edit·Write·MultiEdit 밖의 길(셸 리다이렉션, sed 따위)로 지침 파일을 고치면 PostToolUse 훅이 불리지 않는다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### 절단점 준수 게이트 룰
**종류**: 게이트 룰
**위치**: `plugins/cc-cmds/orchestrator/rules/절단점-준수.rule`
**막을 사례**: `scripts/test-gate.sh#ok "거부 사유가 절단점으로 보고된다 (가장 근본적인 이유가 이긴다)"` — 인가된 절단점을 넘는 행위를 거부하고 사유를 절단점으로 댄다
**이웃 사례**: `scripts/test-gate.sh#check "절단점 이하의 행위는 통과한다"` — 인가된 절단점 이하의 행위는 통과시킨다
**우회 경로**: 게이트를 거치지 않는 셸 호출은 이 룰이 보지 못한다; 룰별 끔 설정으로 끄면 로드되지 않는다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### 지운 코드 자리 주석 금지 조항
**종류**: 프롬프트 조항
**위치**: `plugins/cc-cmds/orchestrator/stage-policy.md#No code or test comment marks where removed code was`
**막을 사례**: 코드를 지우거나 옮기면서 그 자리에 「여기 있던 함수는 옮겼다」 꼴의 주석을 남기는 변경
**이웃 사례**: 지금 코드가 하는 일을 설명하는 주석은 그대로 둔다
**우회 경로**: 조항을 읽은 모델이 따르지 않아도 막는 기계 검사가 없다; 무인 스테이지 밖의 대화형 세션은 이 정책 파일을 싣지 않는다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**상태 근거**: 2026-11-23 — 게이트가 스테이지를 띄울 때 `plugins/cc-cmds/orchestrator/gate.sh` 의 `policy="$GATE_DIR/stage-policy.md"` 줄(47936행)로 이 파일을 읽어 스테이지 지시에 싣는다
**판정**: 미판정

### 대책 기록 린트
**종류**: 린트
**위치**: `scripts/lint-countermeasure-records.sh`
**막을 사례**: `tests/fixtures/lint-countermeasure-records/FAIL-new-lint-unrecorded/` — 기록 없이 새 린트를 들이면 실패한다
**이웃 사례**: `tests/fixtures/lint-countermeasure-records/OK-new-lint-recorded/` — 같은 새 린트에 기록이 있으면 통과한다
**우회 경로**: 기준선 파일에 경로를 손으로 더하면 통과한다; 면제 목록에 대책을 대책 아님으로 적으면 통과한다; hooks.json 밖에서 설치되는 훅(게이트가 런 설정으로 거는 훅 등)은 감지되지 않는다; 프롬프트 조항은 감지되지 않는다; hooks.json 의 `modules` 항목(지금 `./autopilot-status.tsx`)은 command 가 아니어서 훅 갈래에 걸리지 않으므로 감지되지 않는다; 게이트 룰의 끔 설정은 「세션에 로드됨」 측정에 반영되지 않는다; 운영 비용 갱신 시점 (1) — 오차단이나 재시도 때문에 대책을 고치는 변경이 같은 변경에서 칸을 갱신하는지 — 은 검사되지 않는다; 기준선 대책 하나를 지우고 새 대책을 그 줄 자리에 넣으면 이름 바꿈과 가려지지 않아 통과한다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### test-gate 전량 승인 훅
**종류**: 훅
**위치**: `plugins/cc-cmds/hooks/test-gate-full-pretool.sh`
**막을 사례**: `scripts/test-test-gate-full-pretool-hook.sh#run_case "make 로 감싼 --full 은 묻는다"` — 대화형 세션에서 직렬로 수 시간 걸리는 test-gate 전량 실행을 사람에게 묻지 않고 띄우는 경우에 승인을 묻는다
**이웃 사례**: `scripts/test-test-gate-full-pretool-hook.sh#run_case "--full 이 경로보다 앞인 읽기는 묻지 않는다"` — `--full` 을 스크립트 경로보다 앞에 둔 읽기 명령과 좁힌 실행에는 묻지 않는다
**우회 경로**: 변수나 글롭으로 스크립트 경로나 `--full` 을 가린 호출, 다른 이름으로 복사한 스크립트는 걸리지 않는다; 사람이 터미널에서 직접 친 명령에는 훅이 없다; 무인 스테이지(`CC_PIPELINE_RUN_ID` 가 있는 환경)에서는 훅이 비키고 test-gate 자신의 거절이 막는다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

### 시나리오 발동 경계 린트
**종류**: 린트
**위치**: `scripts/lint-skill-trigger-scenarios.sh`
**막을 사례**: `tests/fixtures/lint-skill-trigger-scenarios/FAIL-missing-file/` — 모델 발동 스킬에 시나리오 파일이 없는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-extra-file/` — 모델 발동 집합 밖 이름의 시나리오 파일이 있는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-version-token/` — 첫 줄 판 토큰이 틀린 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-header/` — 열 머리 줄이 틀린 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-field-count/` — 데이터 줄의 칸 수가 넷이 아닌 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-empty-field/` — 빈 칸이 있는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-whitespace/` — 칸 앞뒤에 공백이 있는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-id-grammar/` — id 문법 위반; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-id-duplicate/` — 파일 안 id 중복; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-utterance-duplicate/` — 집합 전체에서 같은 발화가 두 번 나오는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-unknown-cc-name/` — 모델 발동 집합에 없는 `cc-cmds:` 이름을 기대하는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-external-grammar/` — 외부 스킬 이름 문법 위반; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-trigger-floor/` — 발동 발화가 셋보다 적은 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-neighbor-floor/` — 이웃 발화가 셋보다 적은 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-no-external/` — 집합 전체에 외부 스킬을 기대하는 줄이 없는 경우; `tests/fixtures/lint-skill-trigger-scenarios/FAIL-missing-key-counted/` — `disable-model-invocation` 키가 없는 스킬을 모델 발동으로 세어 시나리오 파일을 요구하는 경우
**이웃 사례**: `tests/fixtures/lint-skill-trigger-scenarios/base/` — 형식과 완결성을 갖춘 시나리오 집합은 통과시킨다
**우회 경로**: 형식은 맞지만 기대값이 실제 경계와 다른 발화는 통과한다(경계가 맞는지는 측정 하네스만 잰다); `SCENARIO_ROOT`·`SKILLS_ROOT` 를 덮어써 부르면 다른 트리를 검사한다; 설명문(description·when_to_use)을 고치고 측정 하네스로 다시 재지 않아도 린트는 통과한다; 모델 발동 집합은 `plugins/cc-cmds/skills/*/SKILL.md` 만 보므로 다른 플러그인이나 사용자 스킬은 감지되지 않는다 — 린트 본문, 시험과 픽스처, Makefile 의 등록만 찾아보았다
**오차단**: 미측정
**재시도**: 미측정
**사람 개입**: 미측정
**유지 보수**: 미측정
**상태**: 세션에 로드됨
**판정**: 미판정

## 대책 아닌 감지 파일

- `plugins/cc-cmds/hooks/active-notify-pretool.sh` — 알림 헬퍼의 디스패처 호출을 스스로 승인할 뿐 어떤 행위도 막지 않는다
- `plugins/cc-cmds/hooks/session-ask-notify.sh` — 질문 도구가 뜰 때 데스크탑 알림을 보낼 뿐이다
- `plugins/cc-cmds/hooks/session-status-snapshot.sh` — 세션 상태를 표시용으로 적어 둘 뿐이다
- `plugins/cc-cmds/hooks/session-return-dismiss.sh` — 사용자가 돌아오면 떠 있는 알림을 걷을 뿐이다
- `plugins/cc-cmds/hooks/session-permission-notify.sh` — 권한 요청과 에이전트 시작·끝을 알림으로 알릴 뿐이다
- `plugins/cc-cmds/hooks/session-turn-notify.sh` — 턴이 끝났음을 알림으로 알릴 뿐이다
- `plugins/cc-cmds/hooks/session-title.sh` — 세션 제목을 정할 뿐이다
- `plugins/cc-cmds/hooks/statusline-sessionstart.sh` — 상태 줄을 설치하는 표시 장치일 뿐이다
- `plugins/cc-cmds/hooks/remote-reply/posttool.sh` — 원격 텍스트 답의 표지 줄을 추가 맥락으로 낼 뿐 어떤 행위도 막지 않는다
- `plugins/cc-cmds/hooks/witness-write-pretool.sh` — 런 밖 증인 디렉터리의 구성원 초안·체크포인트 Write 를 스스로 승인할 뿐 어떤 행위도 막지 않는다
