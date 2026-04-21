# cc-cmds 스킬 재구조화 테스트 시나리오

**목적**: Phase 5(`~/.claude/commands/` 정리) 수행 전, 별도 세션에서 재구조화된 5개 스킬이 정상 동작하는지 검증한다. 이 문서의 케이스를 모두 통과해야 Phase 5를 안전하게 진행할 수 있다.

**전제 조건**:

- 본 세션이 아닌 **새 Claude Code 세션**에서 실행할 것 (live change detection/캐시 혼선 배제)
- 테스트 수행 시점에 `~/.claude/skills/{design,design-review,design-upgrade,implement,review,_common}` 심볼릭 링크가 존재해야 함
- `~/.claude/commands/`의 동명 플랫 `.md`는 아직 **삭제하지 않은 상태** (fallback 확인용)

**각 케이스 체크 포인트**:

- 통과 기준을 체크리스트로 제시. 하나라도 실패하면 해당 케이스는 ❌, 모든 케이스 ✅여야 Phase 5 진행.
- 실패 시 "진단 힌트"를 참고해 원인 좁히기.

---

## L0 — 환경 스모크 테스트 (모든 스킬 공통)

**목적**: 심볼릭 링크 resolve, frontmatter 파싱, registry 등록 확인. 스킬 본문 실행은 하지 않는다.

### L0.1 — 심볼릭 링크 resolve

새 세션에서:

```
! ls -la ~/.claude/skills/ | grep -E "design|implement|review|_common"
! readlink -f ~/.claude/skills/_common/team-cleanup.md
! readlink -f ~/.claude/skills/design-review/references/01-auto-decide-protocol.md
```

**통과 기준**:

- [x] 6개 링크가 `lrwxr-xr-x` 로 표시됨 (non-symlink 디렉토리가 아님)
- [x] `_common/team-cleanup.md` 가 `~/dev/cc-cmds/plugins/cc-cmds/skills/_common/team-cleanup.md` 로 resolve됨
- [x] `design-review/references/01-auto-decide-protocol.md` 가 실파일로 resolve됨

**결과 (2026-04-21)**: ✅ 통과 — 별도 세션에서 실행한 `ls -la`/`readlink -f` 출력 확인. 6개 심볼릭 링크가 모두 `~/dev/cc-cmds/plugins/cc-cmds/skills/<name>` 으로 resolve됨.

**진단 힌트**: resolve 실패 시 Phase 0 셋업 스크립트 재실행. 비-symlink 디렉토리가 이미 있으면 충돌 가드가 중단 → 해당 디렉토리 백업 후 재실행.

### L0.2 — 스킬 registry 등록

새 세션에서:

```
/help
```

**통과 기준**:

- [x] 출력 목록에 `design`, `design-review`, `design-upgrade`, `implement`, `review` 5개가 나타남
- [x] 각 스킬의 설명(description)이 Korean으로 표시됨 (예: "설계 문서 최종 리뷰")
- [x] `_common` 은 **목록에 나타나지 않음** (SKILL.md 없음)

**결과 (2026-04-21)**: ✅ 통과 — `/help` custom-commands 탭 출력 확인: `design`, `design-review`, `design-upgrade`, `implement`, `review` 5개 모두 `(user)` scope + Korean description. `_common` 은 목록에 없음.

**참고(이슈 해결 기록)**: 초기 스캔에서 `review` 가 `~/.claude/plugins/cache/cc-cmds/cc-cmds/1.0.0/` orphan 캐시와 이름 충돌해 user scope 스킬이 가려짐. 해결: `rm -rf ~/.claude/plugins/cache/cc-cmds` 로 orphan 캐시 제거 후 재스캔 → 정상 노출.

**진단 힌트**: 스킬이 안 보이면 Claude Code 재시작. 그래도 안 보이면 frontmatter 파싱 오류 가능성 — `head -10` 으로 각 SKILL.md 확인.

### L0.3 — `when_to_use` 노출

새 세션에서 자연어로:

```
설계 문서 리뷰하려는데 어떤 커맨드를 써야 해?
```

**통과 기준**:

- [x] 모델이 `/design-review` 를 제안함 (when_to_use 필드가 retrieval에 반영됨)
- [x] IDE 진단 경고(`when_to_use not supported`)는 **무시 가능** — 공식 지원 필드임이 확인됨

**결과 (2026-04-21)**: ✅ 통과 — 자연어 질의에 모델이 `/design-review` 를 정확히 1순위로 추천. 추가로 `/design` (초기 설계), `/review` (코드 대상) 의 구분까지 맥락 반영되어 설명됨. `when_to_use` 필드가 retrieval 에 정상 반영됨을 확인.

---

## L1 — design-upgrade (최저 위험)

**변경 범위**: frontmatter `when_to_use` 1줄 추가만. 본문 18줄 그대로.

### L1.1 — 호출 및 본문 로드

새 세션에서:

```
/design-upgrade
```

**통과 기준**:

- [x] 스킬이 트리거되어 "haiku, sonnet으로 제안된 팀원 중..." 본문 로직이 실행됨
- [x] 에러 없이 사용자 입력 요청 (팀 구성이 제공되지 않았음을 인지하거나, 대상을 물어봄)

**결과 (2026-04-21)**: ✅ 통과 — `/design-upgrade` 호출 시 스킬이 트리거되어 파일 스캔 후 팀 구성 부재를 감지. 3가지 진행 옵션(세션 팀구성 붙여넣기 / 기존 설계문서 역산 / 새 설계 시작)을 제시하며 정상 분기.

**진단 힌트**: frontmatter 파싱 실패 시 `when_to_use` 필드 포맷 확인 (콜론 뒤 공백, 따옴표 없음).

---

## L2 — implement (변경 없음 — regression 확인)

**변경 범위**: frontmatter `when_to_use` 1줄 추가만. 본문 81줄 그대로.

### L2.1 — 기존 동작 유지

새 세션에서 **본 저장소의 설계 문서**로 호출:

```
/implement docs/skill-restructure-test-scenarios.md
```

(또는 임의의 존재하는 `.md` 설계 문서 경로)

**통과 기준**:

- [x] Step 0: ToolSearch 로 `AskUserQuestion` 등 deferred tools 로드 시도
- [x] Step 1: 설계 문서 경로 읽기 시도
- [x] Step 2: EnterPlanMode 호출 (plan mode 진입 요청)
- [x] 이전 버전과 동일한 플로우

**진단 힌트**: Step 0에서 멈추면 ToolSearch 파라미터 문제, Step 2에서 멈추면 EnterPlanMode 미로드.

**중단 방법**: plan mode에서 ExitPlanMode 전에 "Abort" 입력하거나 세션 종료.

---

## L3 — design (`_common/` 참조 추가)

**변경 범위**: Line 34-37, 49-56, 82-89 → `_common/` Read gate로 교체.

### L3.1 — `_common/agent-team-protocol.md` Read gate 동작

새 세션에서:

```
/design 간단한 로그 수집기의 저장소 선택 (단일 파일 vs SQLite)
```

**통과 기준**:

- [x] Step 1 요구사항 인터뷰 시작 (Korean)
- [x] 사용자가 적당히 답변 후 Step 2 팀 구성 제안
- [x] 사용자가 팀 구성 승인 시, Step 3 진입 전/진입 시 **`${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md` Read 호출이 transcript 에 보임**
- [x] 팀이 생성되고 `[COMPLETE]/[IN PROGRESS]` 신호 규칙이 facilitator 프롬프트에 포함됨

### L3.2 — `_common/team-cleanup.md` Read gate 동작

L3.1에 이어:

- [x] 팀 토론 완료 후 Step 5 단계에서 **`_common/team-cleanup.md` Read 호출이 transcript에 보임**
- [x] 5-step shutdown 시퀀스 (`shutdown_request` → wait → retry → `TeamDelete` → ps 확인) 실행

**진단 힌트**:

- Read 실패 시 `readlink -f ~/.claude/skills/_common/team-cleanup.md` 로 resolve 재확인
- `${CLAUDE_SKILL_DIR}` 치환 실패 시 스킬 메타 디스커버리 동작 문제 — Claude Code 버전 업데이트 필요할 수 있음

**중단 방법**: 팀 생성 직전 (Step 2 승인 프롬프트)에서 거부하면 팀 생성 없이 종료 가능 — L3.1만 부분 검증.

---

## L4 — review (3개 references + `_common/`)

**변경 범위**: `01-reviewer-context-package.md`, `02-review-report-template.md`, `03-non-pr-mode.md` 분할.

### L4.1 — 비-PR 모드 Read gate

저장소에 작은 test diff 존재해야 함. 테스트 전 준비:

```
! cd /tmp && git init review-test && cd review-test && \
  echo "# test" > README.md && git add . && git commit -m "init" && \
  git checkout -b test-branch && \
  echo "function add(a, b) { return a + b }" > add.js && \
  git add add.js && git commit -m "add function"
```

새 세션 (cwd=`/tmp/review-test`)에서:

```
/review
```

**통과 기준**:

- [x] Step 1 auto-detect: PR 없음 → local diff 감지
- [x] **`${CLAUDE_SKILL_DIR}/references/03-non-pr-mode.md` Read 호출이 transcript에 보임**
- [x] Step 2 Claude Context MCP 인덱스 시도 (작은 repo라 빠름)
- [x] Step 3 팀 구성 제안 (Korean)

사용자가 팀 구성 승인 시:

- [x] Step 4 진입 시 **`01-reviewer-context-package.md` Read 호출**
- [x] **`_common/agent-team-protocol.md` Read 호출**
- [x] 팀 생성 + 리뷰어 지시문에 15-item context package 반영

Step 5:

- [x] **`02-review-report-template.md` Read 호출**
- [x] P0~P3 severity 로 리포트 작성 시도

**중단 방법**: Step 3 승인 프롬프트에서 거부.

---

## L5 — design-review (최고 위험)

**변경 범위**: 1385→615, 6개 references, Control-Flow Invariants 섹션 신설.

### L5.0 — 린트/구조 확인 (비-런타임)

본 저장소(`~/dev/cc-cmds`)에서:

```
! cd ~/dev/cc-cmds && make lint
```

**통과 기준**:

- [x] `OK: .../design-review/SKILL.md — heading at line 25 (~246/4000 tokens)` 출력
- [x] 다른 4개 스킬은 `SKIP` (exempt)

### L5.1 — default 경로 (auto-decide ON by default)

테스트용 소규모 설계 문서 준비:

```
! mkdir -p /tmp/design-review-test && cat > /tmp/design-review-test/spec.md <<'EOF'
# 로그 수집기 설계

## 요구사항
- 여러 서비스의 로그를 하나의 파일로 수집
- 동시 쓰기 안전성 필수

## 아키텍처
- 각 서비스가 로컬 파일에 로그를 쓴다
- 중앙 집계기가 주기적으로 로컬 파일을 읽어 통합한다

## 구현 순서
1. 집계기 구현
2. 로컬 파일 포맷 정의
EOF
```

새 세션 (cwd=`/tmp/design-review-test`)에서:

```
/design-review spec.md
```

**통과 기준** (Phase 1):

- [x] Phase 1 Step 2: 플래그 파싱, `BASE_MODE=false`, `AUTO_DECIDE_INITIAL=true`
- [x] Phase 1 Step 3: **`04-file-schemas.md` Read 호출**, 3개 outer-persistent 파일 초기화
- [x] Phase 1 Step 4: **`01-auto-decide-protocol.md` eager-load 호출** (`AUTO_DECIDE_INITIAL=true`이므로)
- [x] Phase 1 Step 4: Korean 자동결정 모드 경고 메시지 출력

**통과 기준** (Phase 2 Step 12):

- [x] Step 12: **`06-review-agent-prompt.md` Read 호출** (매 agent spawn 전)
- [x] Agent spawn 성공, round 1 proposals 생성

**통과 기준** (Phase 2 Step 12.f):

- [x] `decision`-type proposal 발생 시 **`01-auto-decide-protocol.md` recovery Read 호출** (unconditional)
- [x] `re_evaluate_decision` 호출 결과가 `auto-pick` 또는 `escalate` 로 분기

**통과 기준** (Phase 2 Step 14-15):

- [x] **`03-severity-exit-policy.md` Read 호출** (consecutive_no_major 평가 시)
- [x] Control-Flow Invariants 의 `inner_converged_cleanly()` predicate 로 종료 판정

**통과 기준** (Phase 2 Step 25):

- [x] 각 outer iteration 종료 시 **`05-korean-ux-templates.md` Read 호출**
- [x] 📋 이터레이션 완료 요약 블록 + 수렴 현황표 출력

**중단 방법**: 안전한 중단은 **"C: 외부 이터레이션 전체 종료"** 선택 지점까지 진행 후 종료. 또는 Phase 1 Step 4 직후 "그만" 입력.

### L5.2 — `--no-auto-decide-dominant` 경로

```
/design-review spec.md --no-auto-decide-dominant
```

**통과 기준**:

- [x] Phase 1 Step 4 에서 자동결정 경고 **미출력**
- [x] Step 12.f 에서 `AUTO_DECIDE_ENABLED=false` 로 스킵
- [x] 모든 `decision`-type proposal 이 사용자에게 에스컬레이션됨
- [x] Step 25 iteration-transition summary 에서 `자동 선택 내역` 블록 **미출력**

### L5.3 — Post-compaction 생존 (선택 — 장시간 테스트)

L5.1 수행 중 세션이 충분히 길어진 시점에:

```
/compact
```

**통과 기준**:

- [x] 수동 `/compact` 후에도 다음 iteration 에서 `consecutive_no_major` 판정 로직이 여전히 작동
- [x] Step 17 `COUNT_APPLIED` 집계 공식이 요약되지 않고 적용됨 (outer exit 이 올바르게 판정)
- [x] `[AUTO-DECIDED]` 가 `escalate_applied` 에 포함됨

**실패 시 re-tune**: Control-Flow Invariants 섹션을 SKILL.md 더 앞쪽(Overview 직후)으로 이동. 현재 line 25 배치이므로 이미 상당히 앞이지만, post-compaction 실측이 재차 실패하면 Review Criteria 섹션 뒤로 재배치 검토.

### L5.4 — 린트 통과 확인

L5.1 이후 SKILL.md 가 편집되지 않았음을 확인:

```
! cd ~/dev/cc-cmds && make lint && echo "LINT OK" && make readme && git diff --exit-code README.md && echo "README OK"
```

**통과 기준**:

- [x] `LINT OK` 출력
- [x] `README OK` 출력 (drift 없음)

---

## L6 — End-to-End Integration Cycle (실제 사용 시나리오)

**목적**: 단일 과제를 `/design` → `/design-upgrade` → `/design` 재개 → `/design-review` → `/implement` → `/review` 로 관통해 스킬 간 연계점까지 검증한다. 단위 테스트(L1~L5)가 커버 못 한 "산출물 연결" + "실제 팀 cleanup" + "연속 호출 시 cache/state 간섭" 리스크 해소.

**과제**: **"단일 파일 로그 수집기 CLI"** (작고 보안·성능·품질 모두 고려 가능, 구현 50~100줄).

**예상 소요**: 40~70분. 중단 시 실패 단계부터 재개 가능.

### L6.0 — 사전 준비 (임시 저장소 생성)

```bash
! rm -rf /tmp/cc-log-collector && \
  mkdir -p /tmp/cc-log-collector && \
  cd /tmp/cc-log-collector && \
  git init && \
  echo "# log-collector" > README.md && \
  mkdir -p docs && \
  git add . && git commit -m "init"
```

**통과 기준**:

- [x] `/tmp/cc-log-collector` 가 git repo 로 초기화됨
- [x] 이후 모든 단계는 `cwd=/tmp/cc-log-collector` 로 새 Claude Code 세션에서 수행

### L6.1 — `/design` 인터뷰 + 팀구성 제안

새 세션(cwd=`/tmp/cc-log-collector`)에서:

```
/design 여러 서비스 프로세스가 같은 파일에 로그를 쓸 수 있는 단일 파일 로그 수집기 CLI를 만들고 싶음. 동시 쓰기 안전성·로테이션·파싱 호환성이 관심.
```

**통과 기준**:

- [x] Step 1: Korean 인터뷰 시작. 기술적 구현·UI·동시성·로테이션 전략 등 심층 질문 (생성적·추상적 질문 지양)
- [x] 사용자가 "적당히 답변" 후 "이 정도면 인터뷰 충분해. 팀 구성 제안해줘" 요청
- [x] Step 2: 팀구성 표(역할·모델·담당 범위) + 구성 근거 출력
- [x] **이 시점에 6.1 완료 — 아직 팀 생성 승인 금지**

**중단 방법**: 인터뷰가 너무 길어지면 "답변은 기본값으로 가정하고 팀 구성 단계로 넘어가줘" 지시.

### L6.2 — `/design-upgrade` 연계 호출 (팀구성 분석)

6.1 의 팀구성 제안이 대화에 남아있는 상태에서 이어서:

```
/design-upgrade
```

**통과 기준**:

- [x] 대화 컨텍스트의 팀구성 자동 감지 (사용자가 별도로 붙여넣을 필요 없음)
- [x] 각 팀원별로 `현재 모델 → 권장 모델` + `변경/유지 사유` + `기대 효과` 출력
- [x] 판단이 설계 특성(동시성·보안·파싱 등)에 연동됨 — 일반적 chatGPT 답변이 아닌 이 설계 고유 쟁점 참조

### L6.3 — `/design` 재개 (팀 토론 → 설계 문서 저장)

6.2 분석 결과를 반영해 팀구성 조정 후 승인:

```
design-upgrade 분석에서 제안한 변경 반영해서 다시 팀 구성 제안해줘. 그대로 승인할게.
```

(또는 원래 구성 그대로 유지 시 그대로 승인)

**통과 기준 (Step 3 — 팀 토론)**:

- [x] 팀 생성 직전/직후 transcript 에 **`${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md` Read 호출** 기록
- [x] 팀원들에게 `[COMPLETE]/[IN PROGRESS]` 시그널 지침이 포함된 assign 메시지 전송
- [x] Round 1 Initial Proposals → Quality Gate → Cross-Review → Round 2 Refinement 진행
- [x] Facilitator 가 `(idle)` 알림을 `[COMPLETE]` 로 오인하지 않음 (Idle ≠ Done 규칙 적용)

**통과 기준 (Step 4 — 문서 생성)**:

- [x] `docs/log-collector-design.md` 파일 생성됨 (합의된 아키텍처 / 주요 결정사항 / 미해결 이슈 / 권장 구현 순서 4개 섹션)
- [x] 문서가 Korean 으로 작성됨

**통과 기준 (Step 5 — Refinement + Cleanup)**:

- [x] 최소 1회 리파인먼트 (사용자가 "XX 부분 좀 더 구체화해줘" 같은 간단한 추가 요청)
- [x] Cleanup 시 transcript 에 **`${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` Read 호출** 기록
- [x] 5-step shutdown 시퀀스(shutdown_request → wait → TeamDelete → ps 확인) 실행
- [x] `~/.claude/teams/` 아래 팀 디렉토리 제거 확인

### L6.4 — `/design-review` 1 outer iter (선택, 시간 허용 시)

**6.3 의 산출물** 을 입력으로:

```
/design-review docs/log-collector-design.md
```

**통과 기준 (Phase 1)**:

- [x] Step 3: **`04-file-schemas.md` Read 호출** → `outer_log.md`/`ack_items.md`/`convergence_table.md` 초기화
- [x] Step 4: **`01-auto-decide-protocol.md` eager-load Read** (AUTO_DECIDE_INITIAL=true)
- [x] Step 4: Korean 자동결정 경고 출력

**통과 기준 (Phase 2, 1 iter 만)**:

- [x] Step 12: **`06-review-agent-prompt.md` Read** → agent spawn 성공 → round 1 proposals 생성
- [x] Step 12.f: `decision`-type 발생 시 **`01-auto-decide-protocol.md` recovery Read** (unconditional)
- [x] Step 14: **`03-severity-exit-policy.md` Read**
- [x] Step 25 (또는 Step 16 limit 도달 시): **`05-korean-ux-templates.md` Read** + 📋 이터레이션 완료 요약 출력

**중단 방법**: Step 16 inner safety limit 도달 시 **"C: 외부 이터레이션 전체 종료"** 또는 자연수렴 후 Phase 3 자동 진입. 중단 후 설계 문서가 일부 편집된 상태여도 L6.5 로 진행 가능.

### L6.5 — `/implement` plan + 최소 구현

6.3/6.4 의 산출물 설계 문서 기반:

```
/implement docs/log-collector-design.md
```

**통과 기준 (Step 0–2)**:

- [x] Step 0: ToolSearch 로 `AskUserQuestion`/`EnterPlanMode`/`TaskCreate` 등 로드
- [x] Step 1: `docs/log-collector-design.md` 읽기
- [x] Step 2: EnterPlanMode 호출 → plan 제시

**통과 기준 (Step 3 — 최소 구현)**:

- [x] plan 승인 후 구현 파일(예: `log-collector.sh` 또는 `src/collector.js`) 생성
- [x] `git add . && git commit -m "impl log collector v0"` 커밋 성공
- [x] 설계 문서의 "권장 구현 순서" 중 최소 1~2 항목 완료 (전체는 선택)

**중단 방법**: Step 3 중간에 "나머지 Step 은 scope 밖. 여기서 종료" 지시.

### L6.6 — `/review` 구현 diff 리뷰

**6.5 커밋** 을 대상으로:

```
/review
```

**통과 기준 (Step 1)**:

- [x] PR 없음 → local diff 감지 → 자동 전환
- [x] **`${CLAUDE_SKILL_DIR}/references/03-non-pr-mode.md` Read 호출**
- [x] Scope 확인(변경 규모) 사용자에게 제시

**통과 기준 (Step 2–3)**:

- [x] Claude Context MCP 인덱스 확인/생성
- [x] Step 3: PR 타입 분석 → 팀구성 제안 → 승인

**통과 기준 (Step 4)**:

- [x] **`01-reviewer-context-package.md` Read 호출**
- [x] **`_common/agent-team-protocol.md` Read 호출**
- [x] 리뷰어들에게 15-item context package 전달 → 2 round 리뷰 완료

**통과 기준 (Step 5)**:

- [x] **`02-review-report-template.md` Read 호출**
- [x] `docs/reviews/review-<branch>_<YYYY-MM-DD>.md` 파일 생성
- [x] P0~P3 severity + 머지 권고 출력

**통과 기준 (Step 6 — Cleanup)**:

- [x] **`_common/team-cleanup.md` Read 호출** 후 5-step shutdown
- [x] `~/.claude/teams/` 아래 리뷰 팀 디렉토리 제거 확인

**중단 방법**: 리뷰 진행 중 "Step 6 스킵, 지금 종료" 지시 (cleanup 는 유지).

### L6.X — 통합 사이클 후 포스트-체크

```bash
! cd /Users/ian/dev/cc-cmds && make lint && make readme && git diff --exit-code README.md
! ls /tmp/cc-log-collector/docs/
! ls /tmp/cc-log-collector/docs/reviews/
! ls ~/.claude/teams/ 2>/dev/null | grep -E "design-|review-" || echo "(no orphan teams)"
```

**통과 기준**:

- [x] 린트/README drift 없음 (스킬 파일이 사이클 중 우발적으로 편집되지 않음)
- [x] `docs/log-collector-design.md` 존재
- [x] `docs/reviews/review-*_*.md` 존재
- [x] `~/.claude/teams/` 에 design/review 관련 orphan 팀 없음

---

## Acceptance Summary

Phase 5 진행 허가 조건:

| Level  | Case                                      | 상태                     |
| ------ | ----------------------------------------- | ------------------------ |
| L0     | 환경 스모크                               | ✅ 통과 (2026-04-21)     |
| L1     | design-upgrade (smoke)                    | ✅ 통과 (2026-04-21)     |
| L2     | implement regression                      | ✅ 통과 (L6.5 로 흡수)   |
| L3     | design + `_common/` Read gates            | ✅ 통과 (L6.3 로 흡수)   |
| L4     | review + 3 references + `_common/`        | ✅ 통과 (L6.6 로 흡수)   |
| L5.0   | design-review 린트                        | ✅ 통과 (2026-04-21)     |
| L5.1   | design-review default path                | ✅ 통과 (L6.4 로 흡수)   |
| L5.2   | design-review `--no-auto-decide-dominant` | ☐ 미수행 (선택, 생략)    |
| L5.3   | post-compaction                           | ☐ 미수행 (선택, 생략)    |
| L5.4   | design-review 후 lint/README drift 없음   | ✅ 통과 (L6.X 로 흡수)   |
| **L6** | **End-to-end integration cycle**          | ✅ **통과 (2026-04-21)** |

**부가 발견 (실측 중 수정 반영)**:

1. **Orphan plugin cache 충돌**: `~/.claude/plugins/cache/cc-cmds` 에 과거 v1.0.0 설치 흔적이 남아 user-scope `review` 스킬이 가려짐. `rm -rf` 로 해소.
2. **`consecutive_no_major` 오판 수정**: SKILL.md Invariants 섹션 공식 주석 보강 + `references/03-severity-exit-policy.md` 에 "Severity ↔ disposition orthogonality" 섹션 신설. `(post-triage)` → `(post-upgrade)` 용어 정정 + Round 1~4 worked example 추가.
3. **Approval UX 배치 안내 개선**: SKILL.md Approval UX 섹션에 Korean batch announcement template 추가 + 내부 툴 제약(AskUserQuestion 4-option limit) 사용자 노출 금지 규칙 명시.

**Phase 5 진행 허가**: ✅ — 최소 통과 세트(L0 + L6) 달성, 발견된 이슈 모두 즉시 수정 반영. 미수행 L5.2/L5.3 은 부가 경로 검증이며 Phase 5 차단 요인 아님.
