# Changelog

All notable changes to cc-cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.9.0] - 2026-06-03

타인이 작성한 설계/리팩토링 문서를 원본 수정 없이 다관점으로 분석하는 새 스킬 `design-analyze`를 추가한다. `review`의 에이전트 팀 다관점 엔진을 베이스로 하되 입력이 코드 diff가 아니라 산문 설계 문서이며, `design-review`식 외부/내부 수렴 루프 없이 **단일 패스**로 동작한다. 분석 결과는 사용자가 고른 산출물(분석 보고서·인라인 주석 사본·저자 피드백)로 cwd `docs/analysis/`에 생성되며, 원본 문서와 그 소스 repo 전체는 절대 수정하지 않는다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **`design-analyze` 스킬** (`/cc-cmds:design-analyze <design-doc-path> [--no-codebase] [--report-only]`): 9단계 워크플로우(Step 0–8) — 소스 감지·scope 확인 → 소스 repo grounding 셋업 → 분석 팀 동적 구성 → 병렬 다관점 분석(에이전트 팀) → 합성·분류 → 읽기 전용 발견 워크스루 → 산출물 선택·렌더 → 후속 토론. 발견은 공유 ID `A-NN`(단조·속성 무관) 정본 스키마로 관리되고, 설계 전용 severity(critical/major/minor)·`[foundational]` 플래그·premise-contradiction severity floor·verdict 래더(채택/조건부/보류/재설계)로 분류된다.
- **읽기 전용 안전 불변(CFI 5종)**: 원본 문서·소스 repo는 어떤 Edit/Write의 대상도 되지 않으며(hard fail-closed), 모든 출력은 cwd `docs/analysis/`의 새 파일이다. 워크스루→산출물 귀결 순서·anti-fabrication·grounding 정직성·team-cleanup 앵커를 `## Control-Flow Invariants` 최상단에 인라인 배치해 압축 소실로 인한 silent corruption을 차단한다.
- **코드베이스 grounding**: grounding ON이면 cwd가 아닌 **문서가 속한 소스 repo**(`git rev-parse --show-toplevel`)를 Claude Context MCP로 인덱싱하고, `review`와 동일한 재인덱싱 정책(상태 확인 후 missing/outdated만 재인덱싱)을 따른다. repo 부재·인덱싱 실패·`--no-codebase` 시 doc-only 모드로 graceful degrade하며 `doc-code-gap`·`path:line` 인용을 suppress하고 보고서 헤더에 `분석 모드: 문서 단독`을 스탬프한다.
- **references/**: 분석가 컨텍스트 패키지(렌즈 풀·체크리스트·읽기 전용 프로토콜), 분석 보고서 템플릿(finding 정본 스키마·severity/카테고리/verdict gloss), 인라인 콜아웃 렌더 스펙, 저자 피드백 템플릿.
- **lint**: `scripts/lint-skill-invariants.sh`의 EXEMPT 설명 주석에 design-analyze 비-exempt 근거(read-only는 control-flow가 아닌 safety 불변이나 동일 요약-소실 위험으로 first-5K position 보호를 차용; review는 mutation이 없어 면제되지만 design-analyze는 파일 생성+소스 미접촉이라 비면제)를 enumeration과 함께 반영했다. 실행 로직(EXEMPT_SKILLS 배열)은 불변이다.

## [1.8.5] - 2026-06-01

`design-review`와 `design-review-lite`의 inner review loop는 라운드 N+1의 입력이 라운드 N의 적용 출력인 직렬 의존 사슬을 갖는다. 그러나 실행 모델이 한 turn에서 여러 라운드·이터레이션의 리뷰 에이전트를 동시에 spawn하고, **아직 반환되지 않은** 에이전트 결과에 대해 disposition 로그·수렴 판정·`COUNT_APPLIED` 집계를 미리 날조하는 오작동이 관측됐다. 특히 날조된 `clean-convergence` + `COUNT_APPLIED == 0`은 outer 종료 판정에서 도달하지 않은 fixpoint로 전체 리뷰 사이클을 silent early-exit시킨다. 두 스킬의 `## Control-Flow Invariants` 최상단에 advance-ordering(직렬화)·observed-result(anti-fabrication, fail-closed) 불변식 2개를 추가해 하드닝한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `design-review`/`design-review-lite` SKILL.md의 `## Control-Flow Invariants` intro 직후에 두 불변식 하위 섹션을 추가한다. (1) **Round/iteration advance ordering** — 라운드 경계에서는 라운드 N의 Edit가 디스크에 반영되기 전에 라운드 N+1의 review `Agent()`를 spawn하지 않으며, 이터레이션 경계에서는 iter K의 per-iteration summary가 끝나기 전에 iter K+1의 `INNER_TEMP_DIR`를 초기화하지 않는다(no look-ahead spawn). intra-round 활동(self-triage·batched Edits·AUQ fan-out 등)은 제약하지 않는다. (2) **Observed-result precondition** — 어떤 round-N audit 기록(disposition tag·`COUNT_APPLIED`·convergence verdict·outer_log)도 해당 라운드의 review Agent()가 실제로 반환·관측된 경우에만 작성 가능하며, 불확실하면 fail-closed로 re-spawn 후 작성한다. lite는 auto-decide 미보유라 `[AUTO-DECIDED]`·`escalate_applied`를 제외한 단순화 사본을 inline한다.
- `scripts/lint-skill-invariants.sh`의 `REQUIRED_PHRASES`에 두 canonical 앵커(`no look-ahead spawn`, `Agent() actually returned`)를 추가해 base↔lite 양쪽 불변식 prose의 존재·동기화를 CI에서 강제한다. 회귀 fixture(`T-INV-OK-1`)에도 동일 앵커를 반영했다.

## [1.8.4] - 2026-06-01

여러 스킬에서 `AskUserQuestion`(AUQ) 호출 시 `InputValidationError`가 반복 발생하던 문제를 하드닝한다. 레포에서 AUQ를 호출하는 스킬 10개 중 `design`만 AUQ 하드 스키마(12자 header, 옵션 `description` 필수, 옵션 2~4개)에 하드닝돼 있었고, 나머지 스킬과 `design-review` 계열 reference는 옵션을 **bare label 문자열**로 제시하는 템플릿이 모델을 malformed 호출로 직접 유도했다. 근본 원인이 런타임이 아니라 작성된 템플릿(upstream)이므로, 공통 스펙 + 런타임 Read 참조 + 템플릿 in-place 교정 + lint 게이트의 4단 통제를 함께 적용한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `plugins/cc-cmds/skills/_common/askuserquestion.md` 신설 — AUQ 구성 규약의 단일 진실원. 하드 스키마 제약, "질문 ≤4" vs "옵션 2~4"의 두 독립 축 구분, 툴이 자동 제공하는 "Other"로 인한 수동 `직접 지정`/`기타`/`직접 입력`/`Other` 옵션 금지, header ≤12 codepoint(NFC, 공백·`← 추천` 포함, NFD silent-overflow 함정) 규칙, 추천 표기 컨벤션(position 1 + label suffix `← [에이전트 ]추천`, 근거는 `description`에), bare-label DON'T→DO worked example(`# INVALID — do not copy` 마커로 구분), pre-call checklist, authoring rule을 담는다.
- `scripts/lint-skill-auq-spec.sh` 신설 — 2-rule 구조. Rule 1(presence-check)은 `select:AskUserQuestion`을 로드하는 SKILL.md가 공통 스펙도 참조하는지 검증한다(naive `AskUserQuestion` grep이 아닌 `select:` 토큰 기준이라 opt-out 스킬 false positive 회피). Rule 2(denylist)는 SKILL.md·`references/*.md`에서 따옴표로 감싼 수동 Other-equivalent 옵션 라벨을 검출하며, `# lint-skill-auq-spec: disable=other-option` suppress 탈출구와 공통 스펙 파일 whole-file 제외를 둔다. `make lint`에 편입.
- `scripts/test-lint-skill-auq-spec.sh` + `tests/fixtures/lint-skill-auq-spec/` 신설 — 두 규칙의 통과/실패 시나리오(R1-1~R1-4, R2-1~R2-6)를 `SKILLS_ROOT` override fixture로 회귀 검증한다. `make test`에 편입.

### Changed

- AUQ를 사용하는 10개 스킬(`implement`/`review`/`review-lite`/`design`/`design-lite`/`design-apply`/`design-ingest`/`design-system`/`design-review`/`design-review-lite`)의 deferred-tool 로딩 지점에 매 호출 전 공통 스펙 Read 참조를 co-locate한다. `design-review`는 `## Constraints` 섹션이 부재해 `## Begin` 앞에 새 섹션을 신설하고 canonical `ToolSearch("select:AskUserQuestion")` 로드를 추가한다(lint Rule 1 게이트 편입).
- `design-review`·`design-review-lite`의 reference 템플릿과 inline 옵션 메뉴(안전 한계 프롬프트, inner-limit, ack-100 처리, decision-type)를 `label`+`description` 형태로 교정하고 고정 header chip(≤12 codepoint)을 명시한다. `review`의 Large PR gate inline 메뉴도 동형 교정한다.
- 추천 표기를 화살표 패턴(`← [에이전트 ]추천`)으로 통일하되 출처 구분은 보존한다 — 리드/스킬 발 추천은 `← 추천`, 에이전트 발 추천은 `← 에이전트 추천`. `design`의 'native recommendation contract' 표현을 '문서화된 컨벤션'으로 정정해 교정된 reference와의 모순을 없앤다.

### Removed

- `design-review`의 reversion UI(2-step reversion, revert-failed 프롬프트)에서 수동 `직접 지정`·`직접 명세` 옵션을 제거한다. 툴이 자동 제공하는 "Other" free-text 채널이 동일 기능(사용자 free-text 입력 → `[USER-DIRECTED]` 기록)을 제공하므로 중복이며, 제거 시 옵션 수가 ≤4로 복귀한다.

### Why

#1(header overflow)과 #2(bare-label 옵션)는 의미론적 제약이라 brittle한 AUQ-block parser 없이는 grep-detectable하지 않다. 따라서 자동 회귀 가드는 grep-detectable한 수동 Other-equivalent denylist(#4)에만 두고, header≤12·description 존재는 공통 스펙의 authoring rule(문서화된 통제)과 template in-place 교정으로 다룬다 — 해석 가능한 판단에 brittle structural fence를 retrofit하지 않는 레포 자세와 일치하며, 남는 잔여 리스크는 의식적으로 수용한다. 1인 dogfood 단계에서 각 템플릿을 실제 invoke해 검증하는 test fixture는 비례 원칙상 과도하여 현 시점 비도입하고, 재발 빈도가 의미 있게 오르면 재검토한다.

## [1.8.3] - 2026-05-31

동일 세션에서 `design` 스킬을 먼저 실행한 뒤 `design-review` 스킬을 실행하면 `design-review`의 `AskUserQuestion` 프롬프트에 `팀 토론 진행`·`보류` 같은 외래 옵션이 등장하는 버그를 수정한다. 이 옵션 어휘는 `design` 스킬 Step 5(Unresolved Issue Walkthrough)의 카테고리별 메뉴에만 존재하는데, `design-review`의 Decision 옵션 구성이 "agent Options 필드에서 동적 구성"으로 *열려* 있어 폐쇄 집합 선언이 없었던 것이 원인이다. 같은 세션의 `design` Step 5 처방이 컨텍스트에 잔류한 상태에서 그 열린 구성 지점에 외래 어휘가 유입됐다. 본 릴리스는 소비측(`design-review`) 단일 지점에 옵션 집합을 폐쇄하는 prose 펜스를 추가한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `design-review/SKILL.md` `## Approval UX` 섹션 도입부에 **Closed option set** 펜스 문단을 추가한다. 옵션 집합은 닫혀 있으며 "For Proposal type"(`승인`/`거부 (현재 유지)` 정확히 2개)와 "For Decision type"(agent `Options` 필드 파생 + 선택적 `(에이전트 추천)` 태그)이 전부임을 명문화하고, 두 출처에서 파생되지 않은 상시 옵션(특히 `design` 워크스루의 `팀 토론 진행`·`보류`)의 유입을 금지한다. `design-review`는 팀을 만들지 않으므로(fresh 격리 `Agent` 서브에이전트 사용) `팀 토론 진행`은 범주적으로 무효이며, 보류·추가 논의는 Processing Protocol의 free-form Other-input + 대화 루프로 처리한다.
- `design-review/SKILL.md` "For Proposal type"/"For Decision type" 두 하위 섹션을 "exhaustive — exactly these two" / "solely from the agent's Options field" 표현으로 못박아 열린 동적 구성 표면을 제거한다.

### Why

끌려온 `팀 토론`/`보류`는 plausible-but-wrong, 즉 위임된 판단의 interpretable 오판이므로 prose 펜스로 교정하고 hook/구조 강제는 두지 않는다(잔여 실패 모드 수용 원칙). 오염이 실제 관측된 곳은 `design-review` 단 하나이므로 모든 AskUserQuestion 스킬로 일반화하지 않고 소비측 단일 지점만 폐쇄한다 — `design-review`가 옵션 집합을 닫으면 이전에 무엇이 실행됐든 무관하게 면역이 되어 가장 robust한 단일 지점이며, 트리거인 `design` Step 5 어휘는 자기 맥락에서는 정상이고 CFI 불변식이 밀집한 민감 영역이라 비건드림이 안전하다. 다른 스킬 쌍에서 동일 오염이 재발하면 그때를 일반화 신호로 삼는다.

## [1.8.2] - 2026-05-31

`design` 스킬에서 간헐적으로 발생하는 두 가지 제어 흐름 버그를 수정한다. (1) Step 4(synthesize → save → cleanup → present)가 끝난 뒤 같은 턴에서 Step 5(Unresolved Issue Walkthrough)로 자동 진입해야 하는데 간헐적으로 결과만 발표하고 멈추는 버그, (2) Step 6(Plan Refinement) 진입 시 간헐적으로 `AskUserQuestion`("무엇을 다듬을까요?")을 발화하는 버그 — 올바른 동작은 짧은 한국어 안내 후 턴을 양보하고 사용자 발화를 기다리는 것이다. 두 버그는 서로 다른 원인을 가져(이슈 1은 전환 규칙이 source가 아닌 destination에 위치 + "결과 발표"의 강한 턴-종료 prior, 이슈 2는 ~8,900 토큰 위치라 post-compaction 우선창 밖) 단일 처방으로 부족하므로, 상단 `## Control-Flow Invariants` 섹션 hoist(durable backstop) + 종료/진입 seam의 국소 강화(seam co-location)를 함께 적용한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `design/SKILL.md` frontmatter 직후에 `## Control-Flow Invariants` 섹션을 신설하고 CFI-1(Step 4 → Step 5 자동 진입: 양보·프롬프트 없음)·CFI-2(Step 6 진입: 자동 도달 후 안내-후-양보, ENTRY 시점 `AskUserQuestion` 금지 + SCOPE 한정) 두 불변식을 정규화한다. 정규 텍스트는 이 섹션에만 두고, 본문 언급은 모두 `(CFI-1)`/`(CFI-2)` 태그가 붙은 비정규 echo로 정리한다(정규 정의 단일화).
- `design/SKILL.md` Step 4 종료 seam에 (E) 명령형을 co-locate한다 — "Present the results"가 턴-종료 동작이 아니며 같은 턴에서 Step 5로 즉시 이어짐을 발표 지점에서 능동적으로 못 박는다. Step 6 진입 seam은 안내+양보+ENTRY `AskUserQuestion` 금지("무엇을 다듬을까요?" 예시 포함)로 교체한다. Step 5 trigger 문단은 정규 위임 형태로 축약하고 중복 echo 1건을 제거한다. Step 5 → Step 6 무양보 전환을 단언하는 echo 4곳을 `(CFI-2)`로 태깅한다.
- `design/SKILL.md` Step 6 state-check의 "before any Step 5 activity" 오타를 "before any Step 6 activity"로 바로잡는다 (cleanup은 refinement 활동 전에 끝나야 함).
- `scripts/lint-skill-invariants.sh` `EXEMPT_SKILLS` 배열에서 `design`을 제거한다. 향후 CFI 헤딩이 4000 토큰 밖으로 밀리는 회귀를 `make lint`가 즉시 차단한다. 동반 주석(면제 목록·"only non-exempt member" 단언·rationale preamble)을 함께 갱신해 in-session 카운터가 없어도 phase-transition/turn-yield 불변식이 compaction에 취약한 스킬은 rule A 대상임을 반영한다.

### Why

이슈 1은 compaction이 주원인이 아니라(~1,147 토큰으로 우선창 안) 전환 규칙이 destination(Step 5 헤더)에 살고 "결과 발표"가 강한 턴-종료 prior라는 구조적 문제이므로, 명령형이 물리적으로 종료 seam에 co-locate되어야 양보 전에 발화된다. 이슈 2는 Step 6 규칙(~8,900 토큰)이 post-compaction 우선창 밖이라 압축 소실에 취약하므로 상단 정규 섹션이 durable backstop으로 필요하다. 따라서 상단 CFI 섹션 + seam 국소 강화를 함께 둔다. 기존 `design` exemption 근거는 termination 계약에는 타당했으나 이번 두 버그는 phase-transition/turn-yield 부류로 그 가정이 design에도 깨짐을 실증하므로 exemption을 제거한다.

## [1.8.1] - 2026-05-31

`design` 스킬 Step 5 (Unresolved Issue Walkthrough)에서 미해결 이슈를 `AskUserQuestion`으로 surface할 때 한 호출에 여러 이슈가 묶여 나오는 동작이 관찰되어 이를 차단한다. `AskUserQuestion`은 호출당 최대 4개 질문과 질문당 최대 4개 옵션이라는 두 개의 독립적 4-slot 용량을 갖는데, Step 5는 후자(이슈 1건의 옵션 메뉴)만 사용하도록 설계되어 있었으나 이를 명시하는 fence가 없었다. Cap-handling 절의 "4-option cap" 서술이 두 축을 혼동시키는 원인으로 작용했다. 본 릴리스는 Per-issue Processing Flow 도입부에 "한 surface = 정확히 1이슈" 불변식을 명시하는 인라인 fence를 추가한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `design/SKILL.md` Step 5 Per-issue Processing Flow 도입부에 one-issue-per-surface 불변식 인라인 fence 추가. 각 `AskUserQuestion` 호출이 정확히 1이슈(1질문)만 담으며, 최대 4질문 용량을 여러 이슈 묶음에 쓰지 않고 유일한 4-slot 예산은 이슈별 옵션 메뉴(concrete picks + `보류` + `팀 토론 진행`)임을 명시한다. *질문/호출* 축과 *옵션/질문* 축을 명시적으로 분리하고, 이슈를 묶으면 단일 loopable surface를 전제하는 per-issue 메커니즘(auto-investigation / `← 추천` recommendation / UC `더 논의` follow-up 루프 / dropped-confirm separate prompt / mid-flight reclassification)이 모두 깨짐을 근거로 기술한다. Cap-handling의 `4-option cap`이 이슈 수가 아니라 한 이슈 메뉴 내 옵션 수임을 못 박는다.

### Why

one-issue-per-surface는 Step 5 per-issue 상태머신의 load-bearing 불변식이지만 `For each issue:` 루프와 단수형 "Surface to the user (`AskUserQuestion`)"로만 암묵 표현되어 있었다. 모델이 `AskUserQuestion`의 4-질문 용량과 4-옵션 용량을 혼동해 이슈를 묶을 여지가 있었고, 이는 상태머신 전제를 깨는 구조적 위반이므로 명시 fence로 차단한다. design 스킬은 lint `EXEMPT_SKILLS` 멤버라 Control-Flow Invariants 섹션 신설 없이 point-of-use 인라인 fence로 처리한다.

## [1.8.0] - 2026-05-29

claude.ai/design (Claude Design) 외부 도구를 활용한 프론트엔드 작업을 위해 4개 신규 슬래시 스킬과 공유 prose 2종을 도입한다. 기존 `design → design-review → implement → review` 파이프라인은 markdown 설계 문서 기반 백엔드 흐름에는 완벽하지만, claude.ai/design은 cc-cmds가 직접 호출할 수 없는 외부 수동 도구이고 산출물(HTML 핸드오프 번들 + `:root` CSS 토큰)을 사람이 가져와 다음 단계로 넘겨야 하기 때문에 단절이 있었다. 본 릴리스는 `design-system`(DS 워크스페이스 2-phase + 가변 Q&A 페어 사전답변 + relay 루프), `design-prompt`(base 설계 문서 stable-anchor CD 프롬프트 섹션 in-place authoring + HANDOFF CONTRACT 포함 붙여넣기 블록 emit), `design-ingest`(균일 출력 레코드 기반 단일 에이전트 리뷰 + DS 동봉/var() 두 패턴 분기 + ACCEPT/REFINE 파일 복구 루프 + ITER_CAP), `design-apply`(agent-team 적용 설계 sibling, slug 복구로 cleanup-anchor 보장) 4개 스킬과 6개 실측으로 확정된 3-rung 하이브리드 파싱 계약을 구현한 `_common/handoff-contract.md`(emitter+parser 공유 frontmatter 스키마) + `_common/parse-handoff.md`(CONTRACT/BEST-EFFORT/AGENT 직독 3-rung 추출 메커니즘)를 도입한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `plugins/cc-cmds/skills/_common/handoff-contract.md` — emitter(`design-prompt` / `design-system` phase1)와 parser(`parse-handoff.md` Rung1) 공유 frontmatter 스키마 단일 정의 (`handoff_schema: 1`). `kind`/`primary`/`pages`/`tokens_file`/`theme_mode`/`stack` 필드를 정의하고 inner README discovery 규칙 + non-load-bearing cross-check doctrine을 prose로 못 박는다.
- `plugins/cc-cmds/skills/_common/parse-handoff.md` — 3-rung 저하(Rung1 CONTRACT / Rung2 BEST-EFFORT / Rung3 AGENT 직독) 추출 메커니즘을 정의한다. MALFORMED는 구조 게이트만(README/HTML 부재) caller-agnostic으로 한정하고, 토큰 부재는 레코드의 `tokens_absent: true`로 caller가 의미 결정한다. 출력 레코드는 happy-path와 fallback이 동형이라 호출자가 rung 분기 없이 record content로 분기한다. token value 추출은 cross-cutting이라 항상 `:root` 블록의 wrapper-inclusive raw bytes로 수집된다.
- `plugins/cc-cmds/skills/design-system/SKILL.md` — DS 워크스페이스 2-phase 스킬. phase1은 base 설계+코드베이스에서 DS 방향성 정보를 **가변 Q&A 페어(개수·순서 가변, 고정 카테고리 enumerate 금지)**로 추출해 사전답변에 포함하고 HANDOFF CONTRACT 블록을 quote하며 relay 루프 안내를 emit한다. phase2는 incoming/ 번들을 파서로 ingest해 `tokens.css`(authored-css 블록만 + wrapper 보존 + provenance 헤더 + theme 정렬 + dedup)·`tokens.md`·`components.md`·`manifest.json`을 생성한다. `tokens_absent` 또는 divergent 동일-theme 블록은 caller-level 차단으로 escalate.
- `plugins/cc-cmds/skills/design-prompt/SKILL.md` — base 설계 문서 `docs/{slug}.md`에 `## Claude Design 프롬프트 + 컨텍스트` 섹션을 stable anchor로 in-place authoring(append·중복 금지)하고 파생 붙여넣기 블록 `docs/{slug}-fe/cd-prompt.paste.md`를 조립한다. 붙여넣기 블록은 HANDOFF CONTRACT + `tokens.css` byte-verbatim 인용 + 기능 의도 + 산출물 가이드라인 5블록 구조다. 재실행 시 DS manifest version 비교로 drift 경고를 emit한다.
- `plugins/cc-cmds/skills/design-ingest/SKILL.md` — 번들 파싱 + 단일 에이전트 리뷰(5축: 토큰-vs-DS / a11y 대비비 / 반응형·터치 / base 의도 충실도 / 시각 품질) + ACCEPT/REFINE 파일 복구 루프. 균일 레코드 기반 (a) DS 동봉 drift-diff / (b) `var()` 참조-only 누락 검증 두 패턴 분기를 본문 앞부분 prose로 prominent하게 기술한다. 루프 상태는 `iter-NNN/review.md`의 `## Verdict:` 첫 줄 헤더 + 디렉토리 열거로 매 호출 fresh-context 복구. `ITER_CAP=3`은 soft cap으로 4회차 진입 시 `AskUserQuestion`으로 사용자에게 계속/강제-ACCEPT/중단 분기.
- `plugins/cc-cmds/skills/design-apply/SKILL.md` — `design-lite` 패턴 모사 agent-team sibling. 입력 경로 `docs/{slug}-fe/handoff-extract.md`에서 `{slug}`를 파싱해 팀명 `design-apply-{slug}` 조립 + cleanup 복구 키로 사용한다. `_common/agent-team-protocol.md` + `_common/team-cleanup.md` 재사용. concrete-input bootstrap이라 greenfield 인터뷰 생략, 모호점만 narrow `AskUserQuestion`으로 보강.

### Changed

- `scripts/lint-skill-invariants.sh` — `EXEMPT_SKILLS` 배열에 신규 4스킬(`design-system`/`design-prompt`/`design-ingest`/`design-apply`) 추가. 33-34행 주석을 현재 멤버 전부 포괄하도록 재서술 (멀티라운드 agent-team / 단일-패스 verdict-emit / 선형 authoring / IO 오케스트레이터 모두 EXEMPT인 이유 명시; 실질적으로 non-exempt는 `design-review ↔ design-review-lite` 쌍뿐).
- `README.md` — `make readme` 자동 재생성으로 신규 4스킬의 `## Commands` 표 행과 `## Options` 섹션이 frontmatter 기반으로 추가됨. `## Prerequisites`에 `### Claude Design 핸드오프 품질 리뷰 (선택)` 서브섹션 수동 추가 — `web-design-guidelines`가 vercel-labs `agent-skills` 리포의 skills-CLI 개별 스킬(CC 마켓플레이스 플러그인 아님)이라 `plugin.json` `dependencies`로 표현이 불가능함을 명시하고 정확한 설치 명령(`npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines`)을 제공한다.

### Why

claude.ai/design을 활용한 FE 작업을 cc-cmds 정규 파이프라인과 끊김 없이 연결한다. 6개 실측(원본 1 + 검증 5)으로 번들이 자유 형식임을 확인한 뒤 3-rung 하이브리드 파싱 계약을 도입했다 — 옵션 D frontmatter는 작동(4/4 확인)하지만 비-load-bearing(stale-safe cross-check), SAFE 앵커는 6/6 관찰됨(outer README + "Read X in full" + `project/` + HTML ≥1), 토큰 진실값은 항상 `:root`(주로 공유 `.css`)다. 단일 관찰을 frozen 계약으로 박지 않는 doctrine은 CD 방향성 폼 사전답변에도 적용해 가변 Q&A 페어로 추출한다. `web-design-guidelines`는 skills-CLI 개별 스킬이라 hard-dependency 표현이 불가능해 graceful degradation + README 권장-설치-명령으로 처리한다 (terminal-notifier 선례와 동일 doctrine).

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- `design-ingest`는 외부 `web-design-guidelines` 스킬이 있으면 리뷰 5축 평가를 그 스킬로 보강하고, 없으면 자체 5축 기준으로 fallback한다(graceful degradation, 리뷰 중단 없음). README "Prerequisites"에 정확한 설치 명령(`npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines`)을 명시한다.
- DS 워크스페이스는 프로젝트 전역 `docs/design-system/` 단일이며 여러 기능에서 재사용한다.
- `design-system` phase1은 base 설계 + 코드베이스에서 방향성 정보를 가변 Q&A 페어로 추출해 사전답변에 포함하고(고정 카테고리 enumerate 금지 — CD 폼 카테고리는 시간에 따라 변할 수 있음), CD가 사전답변 밖의 추가 질문을 던지면 사용자가 cc-cmds 세션에 그대로 전달해 답안을 받는 relay 루프를 안내한다.
- `design-ingest`는 모든 외부 라운드를 별도 호출로 처리한다(suspend-resume). 외부 단계에서 세션이 끊겨도 디스크 아티팩트(`iter-NNN/`)만으로 재개 가능.
- 신규 FE 스킬은 hook을 동반하지 않아 macOS-CI scope 확장 트리거(active-notify `.github/workflows/notify-macos.yml`)에 해당하지 않는다.

## [1.7.0] - 2026-05-28

`design` 스킬 Step 5 (Unresolved Issue Walkthrough)의 카테고리별 옵션 메뉴에 lead recommendation 메커니즘을 도입한다. 기존에는 각 미해결 이슈를 `AskUserQuestion`으로 surface할 때 카테고리별 옵션을 그대로 늘어놓아 사용자가 어느 옵션이 lead의 best-fit인지 알 수 없었고, 결정 부담만 떠안은 채 walkthrough가 "선택지를 나열하는 단계"로 퇴화했다. 본 릴리스는 `AskUserQuestion`의 네이티브 추천 contract와 design-review subfamily에 이미 정착된 한국어 `← 추천` convention을 통합하여, auto-investigation이 confident일 때만 추천 옵션을 position 1로 이동 + `← 추천` suffix 부착 + 근거를 옵션 `description`에 cite한다. 모든 카테고리(UD/UC/UA/UR)·모든 옵션(`보류`·`팀 토론 진행` 포함)이 추천 후보가 되며, UD/UA가 4-option cap을 초과하는 케이스(`K_pick ≥ 3`)는 conditional inclusion으로 branch (a) pin + worst-cascade drop / branch (b) hide + Other 채널 reachability로 분기 처리한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `design/SKILL.md`의 Step 5 walkthrough에 **Lead recommendation policy** 절(7개 sub-paragraph) 신설. 카테고리별 confident criterion(UC: grep 3–50 hits + ≥80% alignment + canonical-surface counter-example 부재 / UA: cost delta ≥2× + affected-file 단조성 OR hard blocker OR frozen-path overlap / UD: parallel-decision anchor + offered option alignment + "different case" rationale 부재 / UR: blast-radius·critical-path·cross-team-coupling 기반 4-way 분기) + NONE-good case forced `팀 토론 진행 ← 추천` + recommendation contract + description format (`<semantics> — 추천 근거: <evidence>` ≤140 chars ≤2 sentences with citation-token allowlist + opinion-phrase denylist) + UC sub-loop default SUPPRESS + dropped-confirm prompt structural carve-out (`확인` 라벨에 `← 추천` 미적용) + cap-handling conditional inclusion (branch a/b + worst-cascade + hide vs collapse fence + multi-session stateless) + mid-flight reclassification fallback (i)/(ii) + team-spawn two-layer approval 보존 + state-machine 무영향 fence를 포함한다.
- 옵션 메뉴의 모든 옵션에 1-line `description` 부착. 추천 옵션은 `<semantics> — 추천 근거: <evidence>` 형식의 rationale, 비추천 옵션은 라벨별 static text를 사용한다.
- 신규 normative subsection **Description requirements** 추가. 11-row 라벨별 static description 표(`수용`/`재설계`/`보류`/`팀 토론 진행`/`맞음`/`다르게 수정`/`더 논의`/`확인`/`그래도 유지`/UD concrete picks/UA option picks)를 single source of truth로 명시한다. 메뉴 decision branch 변경 시 본 표도 atomic 갱신 의무를 prose로 못 박았다. UD/UA concrete pick이 추천 옵션인 경우의 verb-stem 변환 규칙(`...합니다.` → `...확정` / `...구현`) 및 dropped-confirm prompt의 hybrid `근거:` prefix 형식(`<static semantics> — 근거: <false-positive evidence> (<path:line>)`)도 본 subsection에 포함된다.

### Changed

- `design/SKILL.md` L198 default ordering 규칙을 split-clause로 재작성. (i) escalation gradient(`direct-resolution → 보류 → 팀 토론 진행`)을 명시적으로 보존하고, (ii) recommendation override 조건을 같은 위치에 co-locate하며, (iii) UD/UA `K_pick ≥ 3` conditional inclusion exception을 cross-reference한다. UC initial menu / UR menu / UC sub-loop / UC dropped-confirm dialog의 escalation-gradient 적용 경계도 prose로 명시했다.
- 기존 `Bias-toward-lead framing` paragraph(`lead never proactively recommends a team` 제약 포함)를 `Lead recommendation policy` 7-paragraph block으로 전면 재작성. 단일 ~800-word block의 scannability 문제를 해소하여 lead가 자신의 case에 해당하는 paragraph만 빠르게 locate 가능하게 한다.
- L191 dropped-confirm prompt 라벨의 paren-내 설명(`확인 (entry REMOVED)`, `그래도 유지 (정상 UC 메뉴로 복귀)`)을 제거하고 description 형식(`근거:` prefix hybrid form)으로 이전한다. 라벨은 짧게 유지되고 의미는 description에서 명확하게 전달된다.
- L187 surface step에 recommendation rendering check 한 줄 추가. `AskUserQuestion` 옵션 구성 시점에 `Lead recommendation policy` 적용을 명시했다.

### Why

사용자가 walkthrough 옵션 메뉴에서 어느 옵션이 lead의 best-fit인지 알 수 없어 결정 부담이 컸음. `AskUserQuestion`의 네이티브 추천 contract와 design-review subfamily에 이미 정착된 `← 추천` convention을 활용해 confident 시에만 명확한 추천 신호를 제공한다. confidence 기준을 데이터·사실 판별성으로 정의(lead 취향·의견 금지)하고 description에 citation token 의무화로 lead-taste recommendation을 차단. `K_pick ≥ 3` UD/UA 메뉴는 4-option cap 충돌을 conditional inclusion으로 해소하여 `보류`/`팀 토론 진행` collapse 없이 Other 채널 reachability를 보존한다.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- frontmatter 미수정 → README diff 0, lint 회귀 없음. `make check` lint + readme parity 통과.
- 코드·hook·script·fixture 미변경 — `design/SKILL.md` prose만 수정.
- `design-lite/SKILL.md`에서 walkthrough explicitly disabled이므로 design-lite는 영향 없음.
- cross-skill propagation 없음 — `← 추천` form은 design-review subfamily에 이미 정착되어 있어 design family 합류만으로 충분.
- state machine·doc encoding·checkpoint format·team-spawn flow는 변경 없음. 추천은 `awaiting-decision` 시점의 display-layer concern으로 격리된다.

## [1.6.0] - 2026-05-23

`design` 스킬에 Step 4 직후 자동 진입하는 정식 Step 5 "Unresolved Issue Walkthrough"를 신설한다. 기존에는 Step 4(합의 종합·문서 저장·결과 발표) 종료 후 워크플로우가 사용자 응답을 기다리며 stale 상태가 되어, 사용자가 매번 *"확인할 미해결 이슈가 있나? 하나씩 보자"* 패턴을 수동 트리거해야 했다. 이 패턴을 정식 단계로 승격하여 저장된 설계 문서의 미해결 이슈를 사용자 입력 없이도 결정까지 진행한다. walkthrough의 책임은 후속 `/cc-cmds:design-review` 사이클(false-positive 제거·mechanical gap 검출·auto-decide)과 분리되어 *사용자 입력 없이는 해결 불가능한 항목* 에 한정된다. 기존 Step 5(Plan Refinement)는 Step 6으로 renumber되며, `design-lite`에서는 walkthrough가 비활성화되어 fast direction-setting 목적을 유지한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `design/SKILL.md`에 Step 5 Unresolved Issue Walkthrough 신설. 미해결 이슈를 4개 카테고리(UD Decision-needed / UC Clarification-needed / UA Alternative-to-evaluate / UR Risk-acknowledgment)로 분류하고, read-only + reproducible 자동 조사 후 `AskUserQuestion`으로 사용자 결정을 받는 하이브리드 처리 흐름을 정의한다. surface 여부는 *"fresh `/design-review`가 사용자 입력 없이 해결 가능한가"* 단일 필터 테스트로 design-review와 책임을 분리한다.
- 5+1 상태 머신(대기/조사중/결정대기/해결/보류/제외)을 저장 문서의 인라인 `상태` 마커로 영속화. table form·sub-section form 양쪽 인코딩을 tolerate하며, ephemeral 상태(조사중/결정대기)는 turn 종료 시 checkpoint write로 다음 세션 복구를 보장한다.
- `(깊이: N)` marker로 재귀 surface를 제한(깊이 3 구조적 불가), abort 시맨틱(full abort / single-issue skip), user-initiated 팀 spawn 흐름(`design-<slug>-refine-N` 공유 counter, Step 5·6 동일 시퀀스)을 포함한다.
- `_common/agent-team-protocol.md` cleanup-anchor recovery 예시 목록에 design Step 5 진입·이슈 간 경계·Step 6 진입 3개 anchor 반영.

### Changed

- `design/SKILL.md` 기존 Step 5(Plan Refinement)를 Step 6으로 renumber. synthesis terminal 문구를 Step 5·6 편집 단계가 lead-driven Edit을 허용함을 명시하도록 확장하고, Step 6 state-check enumeration·refine-N 시작값 문구를 walkthrough-spawned team을 포함하도록 갱신.
- `design-lite/SKILL.md` Step 4 끝에 walkthrough 비활성화 addendum 한 줄 추가 — lite는 미해결 이슈를 plan refinement에서 ad-hoc 처리하며 fast direction-setting 목적을 유지한다.

### Why

Step 4 종료 후 워크플로우가 stale 상태가 되어 사용자가 매번 walkthrough를 수동 트리거하던 마찰을 정식 단계로 구조화. design-review와 책임을 분리한 이유는, 사용자 가치 판단이 필요한 항목을 미해소로 남기면 design-review의 auto-decide가 사용자 의도와 다른 default를 silent하게 commit할 위험이 있기 때문이다.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- frontmatter 미수정 → README diff 0, lint 회귀 없음. `make check` lint 5종 + readme parity 통과.
- 코드·hook·script·fixture 미변경 — SKILL.md / `_common` prose만 수정.

## [1.5.1] - 2026-05-21

`active-notify` v1.5.0이 ARM 후 background task 완료를 처리하는 turn에서 dispatch 순서를 강제하지 않아, 모델이 결과 검증(`find`/`grep` over logs 등)을 `fire-now`보다 먼저 호출하면 사용자 allowlist에 없는 명령이 권한 다이얼로그를 띄워 turn이 정지하고 알림이 미발송되던 결함을 수정한다. 사용자는 키보드 앞을 떠나 알림을 기다리던 중이라 알림도 chat 응답도 없는 무한 hang으로 인식한다. 본 릴리스는 SKILL.md / `_common/notify.md` 프로즈만 보강(코드·hook·frontmatter 미수정)하여 task 완료를 인지한 turn에서 `fire-now`를 첫 도구 호출로 의무화한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `active-notify` SKILL.md에 "Fire-now ordering within the turn (fire-first mandate)" 절 신설. 활성 ARM이 대상으로 하는 milestone 완료를 관찰한 직후 모델의 다음 도구 호출은 무조건 `notify.sh fire-now`여야 한다. fire-now는 plugin의 PreToolUse hook이 자동 승인하므로 권한 다이얼로그를 일으키지 않는 유일한 호출이며, 모델은 사용자 allowlist를 예측할 수 없으므로 "권한 게이트 호출보다 먼저"가 아니라 "어떤 호출보다도 먼저"여야 실행 가능한 규칙이 된다. observation이 turn 시작 시점에 이미 context에 있는 경우(background task 완료로 인한 re-invoke)와 mid-turn에 드러나는 경우(foreground Bash inline 종료, BashOutput poll) 모두 적용된다. 실패한 task에서도 동일 순서 — 조사 욕구가 강한 함정 지점이지만 fire-now 먼저, 조사는 뒤.
- "Defensive fire-now (when an ARM may be live)" 절 신설. long task 끝에 ARM 발화 기억이 context에서 사라졌더라도 ARM이 placed되지 않았다고 확실히 배제할 수 없다면 fire-now 먼저 호출한다. flag가 ground truth이며 dispatcher는 flag 부재 시 silent no-op이라 잘못된 호출은 무해하다. flag 파일을 Read해서 의문을 해소하지 말 것 — 그 Read 자체가 권한 게이트 호출이라 turn을 정지시킬 수 있다.
- 새 worked example "Background-task completion — fire-first ordering" 추가. 안드로이드 빌드 background → 완료 → fire-now 첫 호출 → 그 다음 검증 패턴 시연. failed-build + mid-turn-observation variant 포함.
- fire-now anti-pattern 정밀화 — "fire-now without ARM"을 "positively know no ARM was ever placed"로 재작성. ARM 기억 부재(uncertainty)와 ARM 부재 확실성(knowledge)을 구분하여, 전자는 defensive fire-now로 라우팅되고 후자만 금지된다. 추가 항목 "fire-now deferred behind another tool call" 신설 — 검증·점검 호출을 fire-now보다 앞 순서에 놓으면 권한 다이얼로그가 turn을 정지시켜 알림이 strand된다는 사례를 본문에 명시.
- `_common/notify.md` "Notification fire" 절에 fire-first 문단 + copy 합성 보강. 검증 호출로 summary를 만들지 않고 이미 context에 있는 완료 신호(exit code, output tail)로 합성한다.

### Why

prose-only 보강만 적용한 이유: hook 기반 구조적 안전망(harness-driven turn-end fire 또는 권한 다이얼로그 이벤트를 정조준한 backstop)도 검토했으나, 모든 게이팅 옵션이 소음 대 복잡도 trade-off에서 만족스럽지 않았고 명시적으로 모델 판단에 위임된 결정에는 prose-only fence가 적절한 수단이라는 기존 방침을 따랐다. dogfood로 hang 재발 여부를 관찰한 뒤 hook 기반 backstop 도입 여부를 재검토할 예정. 환원 불가능한 잔여는 "모델이 task 완료를 처리하면서 fire-first/defensive-fire 규칙을 아예 떠올리지 않는 경우" — prose는 규칙을 명시할 수 있어도 모델이 그 규칙을 참조하도록 보장할 수 없는 갭이다.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- frontmatter 미수정 → README diff 0, lint 회귀 없음. `make check` lint 5종 + readme parity 통과.
- 코드(`notify.sh`)·hook(`active-notify-pretool.sh`)·flag schema 미변경. v1.5.0과 wire 호환 (기존 ARM flag 그대로 동작).

## [1.5.0] - 2026-05-21

cc-cmds의 첫 model-invocable helper skill `active-notify`를 도입한다. 사용자가 자연어로 알림 발동을 요청하면 (`"끝나면 알려줘"`, `"매 작업마다 알려줘"`, `"시작할때랑 끝날때 알려줘"`) 모델이 ARM 상태를 TMPDIR JSON flag로 등록하고, 후속 sub-event 시점마다 모델이 직접 `notify.sh fire-now <workflow> <summary>`를 호출해 macOS `terminal-notifier`로 데스크탑 banner를 발화한다. plugin-level PreToolUse hook이 dispatcher Bash 호출을 session-persistent `applyPermissionRules`로 자동 승인하여 권한 다이얼로그 0건 불변식을 유지하며, ARM JSON schema:3 + `--count=N` flag로 single 모드 multi-sub-event 발화(`"시작할 때랑 끝날 때"` → `--count=2`)를 자연어 그대로 인코딩한다. macOS Notification Center가 banner에 자동 부착하던 "보기" 버튼이 click 시 부모 subshell focus를 가로채던 결함도 `-execute ':'` no-op click-target으로 차단한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `plugins/cc-cmds/skills/active-notify/` — `disable-model-invocation: false` model-invocable skill. 7-section SKILL.md (canonical lexicon, 단발/반복 분기, worked example, fire-now anti-pattern, PERMISSION TEST bypass + 3-clause 제외 절). `notify.sh arm/fire-now/cancel` 3-subcommand dispatcher: arm은 `--mode=single|repeat` + `--count=N` parse-anywhere flag로 ARM intent encode (default 1, 비정수·≤0·>16 → 1로 normalize). fire-now는 ARM 존재 + schema:3 strict-equality + mode/field-shape 가드 + mkdir lockdir 원자 mutation으로 banner 발화 (single armCount-aware: fire_count+1 < arm_count면 intermediate `sed -E` in-place 증가, == arm_count면 final `mv -n` consume; repeat는 temp→mv rename으로 fire_count 누적).
- `plugins/cc-cmds/skills/_common/notify.md` — 4-section shared procedure (preconditions, fire copy synthesis, failure handling, control-flow invariants). SKILL.md가 normative reference로 가져와 단일 정의 보장.
- `plugins/cc-cmds/hooks/hooks.json` + `active-notify-pretool.sh` — plugin-level PreToolUse hook. 모델의 `notify.sh arm/fire-now/cancel` Bash 호출 + `terminal-notifier -group cc-cmds-active-notify` bypass 호출을 `permissionDecision: "allow"` + `applyPermissionRules`로 session-persistent silent 승인. 권한 다이얼로그 0건 불변식.
- `.github/workflows/notify-macos.yml` — macos-latest 러너 + brew yq + brew terminal-notifier로 active-notify 회귀 검증. path-filtered (active-notify 경로 변경 시에만 실행). escape-hatch `CC_CMDS_NOTIFY_SKIP_DARWIN_CHECK=1`로 Linux CI에서도 lifecycle/pretool fixture 실행 가능.
- `scripts/lint-bash-portability.sh` + 8 fixture — BSD/GNU divergent idiom denylist (`date -j`, `tac`, `grep -P`, `sed -i` BSD form, `awk gensub` 등). `# lint-bash-portability: disable=<idiom>` 행-끝 주석으로 의도적 사용 suppress.
- `scripts/lint-skill-description-budget.sh` — model-invocable skill frontmatter `description` + `when_to_use` combined char count 검증 (HARD ≤1536 = Claude Code listing truncation cap, WARN >1350, description 단독 ≤1024 = Agent Skills hard limit). Unicode codepoint 측정.
- `scripts/test-active-notify-lifecycle.sh` + `scripts/test-active-notify-pretool-hook.sh` — 격리 TMPDIR + 결정적 CLAUDE_CODE_SESSION_ID + stub terminal-notifier 주입 driver. lifecycle 25 fixture + pretool 10 fixture (arm 분기, fire-now 5가지 — `count=1`/N-partial/N-N-completes-cycle/overflow-rejection/parallel-race + schema 마이그레이션 거부 + cancel + corrupt-mode/fields silent cleanup + no-flag silent no-op + repeat increment/multi + PERMISSION TEST bypass match 등).
- `README.md` Prerequisites → "완료 알림 (선택)" — 1단계 `brew install terminal-notifier jq` → 2단계 자연어 발화 예시 (단발/반복) → 3단계 PreToolUse 권한 승인 안내.

### Changed

- `scripts/generate-readme.sh` — frontmatter `disable-model-invocation: false` skill을 README SKILLS_TABLE / SKILLS_OPTIONS에서 yq bracket notation + literal-`false` match로 자동 제외. model-invocable helper는 슬래시 커맨드로 직접 호출 surface가 아니므로 user-facing 목록에서 제거. yq `//` alternative operator는 `false` 값도 fallback으로 처리하므로 회피.
- `scripts/lint-skill-invariants.sh` — `EXEMPT_SKILLS`에 `active-notify` 추가. model-invocable helper는 orchestration-only가 아니므로 Control-Flow Invariants 섹션 위치 규칙 면제.
- `Makefile` `lint` / `test` 타겟 — lint-bash-portability + lint-skill-description-budget + test-active-notify-lifecycle + test-active-notify-pretool-hook wiring.

### Fixed

- macOS Notification Center가 terminal-notifier banner에 자동 부착하는 "보기" 액션 버튼이 click 시 부모 subshell focus를 가로채던 결함 — terminal-notifier 2.0.0 CLI가 버튼 자체 제거 기능을 노출하지 않으므로 `-execute ':'` (shell true-builtin no-op)를 click-action으로 지정해 functionless 통과시킨다. 버튼의 시각 잔존은 환경 제약이나 click-action 부재라는 의도된 contract 달성.
- PERMISSION TEST 1순위 분기의 lexical 과적합 — "테스트/test + 알림 동사" 결합 발화에서 별도 작업 컨텍스트의 "테스트"(예: Android instrumentation test 진행 중 사용자의 알림 요청 발화)가 PERMISSION TEST bypass로 잘못 라우팅되던 gap을 3-clause 제외 절(별도 작업 컨텍스트 / noun-form "테스트" / ARM-eligible companion 발화 — ANY ONE 발현 시 bypass 금지)로 차단. "테스트 시작할때랑 끝날때 알림 줘" 같은 ambiguous 발화에서 ARM 라우팅 보존.

### Why

`/cc-cmds:design` 및 일반 long-running 작업 (Android instrumentation test, 배터리 polling, build 등) 도중 사용자가 1인칭 발화로 알림을 요청해도 모델이 일관되게 응답할 surface가 없어 매번 ad-hoc dispatch하던 결함을 구조화. 단일 dispatch surface로 단순화한 이유는 PR 작업 중 시도된 hybrid 메커니즘(Stop hook turn-end FIRE + marker scrape + Rule 2·3 bypass)이 (a) sub-turn semantic timing을 정확히 표현하기 어렵고 (turn 경계 이전 단계별 milestone 표현 불가), (b) marker emit 누락 시 fail-closed silent miss 회복 경로가 모델 자기-judgment에 의존하여 불안정, (c) Stop hook의 work-call counting + AskUserQuestion regex bypass가 모델 발화 패턴 변화에 brittle 했기 때문. 모델이 명시 sub-event 시점에 직접 fire-now subcommand를 호출하는 단순 모델이 동일 표현력을 더 적은 attack surface로 제공한다.

### Post-install notes

- 외부 사용자 조치 — macOS 사용자만: `brew install terminal-notifier jq` 1회 + Notification Center 권한 1회 승인. 그 외 platform은 silent no-op (notify.sh가 비-Darwin 호스트에서 dispatch 자체를 skip).
- 첫 정식 release이므로 외부 사용자 ARM flag 잔류 0건 — schema migration 회로(`schema != "3"` strict-equality)는 dogfood 단계 잔여 flag 보호용 안전망.
- `/plugin update cc-cmds`로 plugin-level hook(`hooks/hooks.json` + `active-notify-pretool.sh`) 자동 반영. Manual install 경로는 plugin-level hook과 비호환이라 README에서 안내 제거.
- README diff 23 lines (Prerequisites 신규 subsection). `make check` lint 5종 + readme parity 통과.

## [1.4.2] - 2026-05-06

`CLAUDE_CONFIG_DIR` 환경변수로 default가 아닌 디렉토리(예: `~/.claude-foo`)에서 Claude Code를 운영할 때 발생하던 silent failure 3건을 수정한다. `/cc-cmds:design` Step 5 entry state-check가 `ls ~/.claude/teams/`로 활성 팀을 enumerate하여 false-negative로 cleanup이 누락되거나, `_common/team-cleanup.md`의 S1 directory presence check가 잘못된 경로에서 분기하거나, TeamDelete 실패 시 AskUserQuestion fallback 메시지가 잘못된 cleanup 경로를 안내해 사용자가 실제 디렉토리를 정리하지 못하던 결함을 모두 환경변수 인지 형태(`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`)로 교체한다. 회귀 방지를 위해 신규 lint script(`lint-skill-paths.sh`) + 13개 fixture + test runner를 함께 추가하여 SKILL.md / `_common/*.md` / `<skill>/references/*.md` 전 영역에서 하드코딩 경로를 차단한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `/cc-cmds:design` Step 5 entry state-check — `~/.claude/teams/` 두 위치(prose noun-phrase + `ls` 실제 명령)를 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/`로 교체하고 path를 double-quoting하여 `$HOME`이나 `$CLAUDE_CONFIG_DIR`에 공백이 있어도 word splitting을 차단. 이전에는 `CLAUDE_CONFIG_DIR=~/.claude-foo` 환경에서 활성 팀을 검출하지 못해 cleanup이 누락됐다.
- `_common/team-cleanup.md` S1 — `test -d ~/.claude/teams/{team-name}`을 `test -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"`로 교체. 이전에는 directory presence 분기가 default 디렉토리만 검사해 non-default 환경에서 잘못된 분기로 진행됐다.
- `_common/team-cleanup.md` shutdown failure fallback — 단일 prose 문장을 multi-line 형식으로 교체. Claude가 `echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"` / `tasks/{team-name}` 두 명령을 먼저 실행해 fully-resolved absolute path를 stdout으로 받은 뒤, 그 출력 문자열을 AskUserQuestion 메시지 본문에 verbatim으로 삽입한다. 이전에는 추상 표기(`~/.claude/...`)를 그대로 안내해 non-default 환경 사용자가 실제 디렉토리 위치를 모른 채 잘못된 경로를 정리하려 했다.

### Added

- `scripts/lint-skill-paths.sh` — runtime SKILL.md / `_common/*.md` / `<skill>/references/*.md`에서 하드코딩 `.claude` 경로(5-alternation BANNED_RE: `~/`, `$HOME/`, `${HOME}/`, `/Users/<name>/`, `/home/<name>/`)를 차단하는 신규 lint. canonical `${CLAUDE_CONFIG_DIR:-$HOME/.claude...}` 및 braced `${CLAUDE_CONFIG_DIR:-${HOME}/.claude...}` 두 형식만 strip-pass로 whitelist하며, 단일 dash form(`${CLAUDE_CONFIG_DIR-...}`)과 tilde-fallback(`${CLAUDE_CONFIG_DIR:-~/.claude}`)은 emergent behavior로 자연스럽게 reject된다 (parameter substitution 내부에서 tilde expansion이 fire하지 않는 silent runtime bug 형태이므로 lint가 정책을 행동으로 강제).
- `scripts/test-lint-skill-paths.sh` + `tests/fixtures/lint-skill-paths/` 13개 fixture (T-PATH-OK-{1,2,3} + T-PATH-FAIL-{1..10}). canonical / braced / multi-line code-fence pass anchor + tilde / `$HOME` / `${HOME}` / macOS / Linux / mixed-line / SKILL.md location / references-depth / tilde-fallback / single-dash 회귀 anchor를 각각 커버.
- `Makefile` `lint:` 타겟에 `lint-skill-paths.sh` 추가 (`make check`에 transitively 포함). `test:` 타겟에 `test-lint-skill-paths.sh` 추가.

### Why

silent fallback의 3 hit는 모두 `~/.claude/...` 형태가 default 환경에서는 정상 동작하다 보니 dogfooding 단계에서 검출이 어려운 결함이었다. 사용자 인터뷰로 확정한 path-substitution 범위(runtime SKILL.md + `_common/`)에 한정해 패치했으며 README/CHANGELOG/`docs/`/기존 `tests/fixtures/`의 본문은 historical record / 사용자 대면 가이드 성격이라 의도적으로 제외했다. 신규 lint는 향후 동종 결함이 SKILL/references 안에서 silent하게 들어오는 path를 활성 차단한다.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- `CLAUDE_CONFIG_DIR`을 default(`~/.claude`)로 사용하는 환경에서는 동작 변화 없음. non-default 환경 사용자는 본 패치 이후 `/cc-cmds:design` 워크플로의 cleanup 분기와 `_common/team-cleanup.md`의 S1/shutdown-fallback이 올바른 디렉토리에서 동작한다.
- README diff 0 (frontmatter 변경 없음). `make check`는 lint 3종 + readme parity 모두 통과.

## [1.4.1] - 2026-04-30

`/review`·`/review-lite` skill의 Step 1b PR context-collection 코드 블록에 잠복하던 `gh` CLI v2.91.0 spec drift 3건을 수정한다. 결함의 영향은 두 갈래로 나뉘었다 — (i) **hard fail + cascading 취소**: `gh pr view --json reviewers` (필드 부재) / `gh pr diff --stat` (플래그 부재) 두 명령이 비-0 종료하면 같은 묶음 병렬 호출이 `Cancelled: parallel tool call errored`로 일괄 취소되어 PR 컨텍스트 수집 전체가 무너졌다. (ii) **silent fallback absorption**: `gh pr checks --json status,conclusion` (필드 부재) 호출은 기존 `2>/dev/null || echo "[]"` fallback이 에러를 흡수해 CI 체크 데이터가 항상 빈 배열로 반환됐고, 그 결과 Step 1c "highlight failed checks if any" 기능이 운영 시작 시점부터 비활성 상태로 잠복해 왔다. 본 패치로 세 명령을 현행 spec(`reviewRequests` + `latestReviews`, `gh pr view --json files`, `name,state,bucket`)에 맞게 교체하며, Step 1c CI 실패 highlight 기능을 운영 시작 이후 처음으로 활성화한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- `/review` & `/review-lite` Step 1b — `gh pr view --json reviewers` (존재하지 않는 필드)를 `reviewRequests,latestReviews`로 교체. `reviewRequests` = 리뷰 요청자 목록(User/Team 응답을 `__typename` 분기로 모두 노출 필요), `latestReviews` = reviewer별 최신 review state 1건 스냅샷. 풀 review 히스토리는 동일 Step 1b의 `gh api --paginate ".../reviews"` 호출이 이미 수집 중이라 use-case로 분리(코멘트 인라인 힌트 추가).
- `/review` & `/review-lite` Step 1b — `gh pr diff $PR_NUMBER --stat` (지원하지 않는 플래그)을 제거하고, 동일 endpoint를 두 번 호출하던 path-only(`gh pr view --json files --jq '[.files[].path]'`)와 함께 단일 호출 `gh pr view --json files --jq '[.files[] | {path,additions,deletions}]'`로 통합. 다운스트림 consumer는 `.[] | .path`로 경로 추출 가능 — 동작 동등 + API 호출 1회 절감.
- `/review` & `/review-lite` Step 1b — `gh pr checks --json name,status,conclusion` (`status`/`conclusion` 필드 부재)을 `name,state,bucket`으로 교체. `bucket == "fail"`은 FAILURE/TIMED_OUT/ACTION_REQUIRED/STARTUP_FAILURE를 한 번에 잡는 빠른 필터, `state`는 Step 4 reviewer context package의 CI failure routing(security vs logic vs build)에 필요한 granularity 제공. 0-checks 케이스의 fallback 트리거 의미는 동일 유지.
- `/review` SKILL.md Step 1c — large PR gate 본문에서 "or `--stat` output" 잔여 참조 제거 (`changedFiles` 메타데이터로 단일화). 인접 코멘트 `# Full diff (after large PR gate passes)` → `# Full diff`로 단순화하여 양 SKILL.md 자연 정렬.

### Why

silent fallback absorption은 `gh pr checks` 명령이 시작 시점부터 잘못된 필드로 호출되었음에도 fallback이 에러를 흡수해 **운영 시작 이후 한 번도 CI 체크 highlight가 동작한 적이 없었다**. 본 fix는 단순한 spec 교정이지만 결과적으로 Step 1c의 CI 실패 highlight 기능을 처음으로 활성화하는 효과를 가진다. 두 호출 통합(D5)은 사용자 결정으로 spec drift 픽스에 함께 묶었으며, 양 파일 동일 코멘트로 drift 위험을 추가 제거한다.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영.
- `references/01~03`은 의미 기반 표기/git 명령이라 무영향, `make readme`도 frontmatter 기반이라 README diff 0.
- 회귀 방지 가드는 사용자 결정에 따라 추가 안 함 (동종 결함 재발 시 별도 검토).

## [1.4.0] - 2026-04-30

`/cc-cmds:design` 토론에서 발견된 surface-discipline escape path를 차단한다. lead가 Bound A/B/C 임계 미도달 상태에서 일부 unconverged 항목을 임의 surface, surface + 내부 결정의 split-surface 패턴, _"인터뷰 잠금 결정과 충돌"_ 같은 protocol 미정의 ad-hoc trigger 사용 — 세 escape를 binary Bound gate + same-path 룰로 구조적으로 차단한다. `_common/agent-team-protocol.md`를 Read하는 4개 TeamCreate 기반 스킬(`design`, `design-lite`, `review`, `review-lite`)에 자동 전파 (`/plugin update cc-cmds`로 자동 반영).

### Added

- `_common/agent-team-protocol.md`: Facilitator Rules 섹션에 새 top-level bullet **Surface discipline — gate, priority, and split prohibition** 신설. (i) "Surfacing" 정의 명문화 — `AskUserQuestion` 호출 + decision-soliciting narration 양쪽 포함, file write / structured log / progress-only status는 surface 아님. (ii) Bound A/B/C 임계 도달 또는 explicit user instruction(직전·현재 turn + named target)만 escalation 허용. (iii) wall-clock elapsed time / lead confidence / lead opinion strength는 surface 시그널이 NEVER. 3 sub-clauses 동봉:
    - **Stall priority before surface**: content-ful DM 부재 시 escalation 전 4 priority action(forward / re-scope / cross-validation / status-ping). `ip_count == 1` vacuous → "Take your time" passive (single courtesy pass), `ip_count >= 2` → active stall-handling. Stall-context forward / re-scope / cross-validation은 round당 teammate별 cap 3, round boundary에서 reset. Status-ping과 hard prompt는 cap-exempt.
    - **No early surface on interview-locked conflicts**: unresponded item과 interview-locked decision 충돌은 정의된 escalation trigger가 아니며 Bound 임계 전 surface 불허. Bound 임계 도달 시 lock-conflict context를 `AskUserQuestion` body에 포함해 informed user override / reconfirmation 가능. explicit user instruction bypass는 lock-reopen instruction 없으면 locked-conflict item에 적용 안 됨.
    - **Split-surface prohibition**: "single turn" = "single assistant response block." 한 turn은 (i) 내부 action만 또는 (ii) ALL unconverged items를 cover하는 단일 unified `AskUserQuestion` 둘 중 하나. 일부 surface + 일부 내부 결정 절대 금지 — unsurfaced item framing(decided / deferred / dropped / 'will handle later')도 영향 없음. 한 unconverged item이 Bound 임계 도달 시 모든 unconverged item이 same path. Multi-item batching은 single `AskUserQuestion` 내에서 허용·선호.

### Changed

- `_common/agent-team-protocol.md` `Surface disagreements` bullet: judgment-call authority 좁힘. 기존 단일 문장(2 sides argue → lead judgment call)을 two-clause로 교체 — (i) judgment-call은 동일 topic에 substantively conflicting position의 teammate 최소 2명이 substantive DM으로 응답해 conflict가 fully voiced일 때만 행사 가능 (응답 채널 명시: `via SendMessage`), (ii) fully voiced 안 된 항목에는 권한 미적용; additional rounds + stall-handling으로 처리 후 Bound 임계로 escalation.
- `plugin.json`: `version: 1.4.0`.

### Why

원 incident 회고: lead의 _"인터뷰 잠금 결정과 충돌"_ 정당화는 protocol 미정의 ad-hoc escalation trigger였으며, soft-form lead-judgment("obvious", "wall-clock 길어졌으니")와 verbal split-surface escape("내부 결정해서 마무리하겠습니다") 양쪽이 wording-level rationalization으로 활용됨. binary Bound gate(structural) + same-path 룰이 핵심 차단을 제공하고, 추가 prose-level 봉쇄(wall-clock NEVER, framing enumeration, named-target bypass)로 verbal escape 차단. design 문서 §D7 결정에 따라 R4-R10 누적 wording 정밀화 12개 항목은 운영 텍스트 외(D8)에 보관 — 사용자 결정 #2(약한 정형화) + #8(compact-doc) 의도 회복 우선.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds`로 자동 반영. 4-skill TeamCreate 기반 (`design`, `design-lite`, `review`, `review-lite`)에 자동 전파.
- `design-review` / `design-review-lite`는 `Agent()` 기반이라 본 보강의 직접 대상 아님 — 두 스킬은 GR#6/#7 + auto-decide protocol(`design-review` only)이 _"Never decide for the user"_ 핵심 원칙 인코딩 중. 동등 surface discipline 적용은 별도 GR amendment 필요 (본 보강 범위 외).

## [1.3.0] - 2026-04-27

3개 lite 스킬을 추가하여 Pro 사용자가 토큰 한도 안에서 다관점 사이클을 돌릴 수 있도록 한다. 기존 5개 base 스킬은 byte-identical 유지(zero impact for OFF users) — Pro 사용자는 명시적으로 `-lite` 변형을 호출해 절감을 선택한다. 순수 additive 변경이며 호출 인터페이스는 그대로 유지된다 (`/plugin update cc-cmds`로 자동 적용).

### Added

- `design-lite/SKILL.md`: 2-member 고정 sonnet 팀 + Round 1 + Round 2 cross-review 기본(hard cap 3 rounds). 4-section doc structure(합의 아키텍처 / 주요 결정사항과 근거 / 미해결 이슈 / 권장 구현 순서) 강제, doc 길이 cap 없음. refinement team spawn 비활성 — deeper 요청 시 `/cc-cmds:design`로 redirect. Sequential Thinking MCP / Claude Context MCP 사용 안 함.
- `design-review-lite/SKILL.md`: outer cap 2 (vs base 5), inner cap 6 (vs base 20), 모든 review agent 모델 sonnet 고정. Decision Auto-Select Protocol(§8) 전체 drop — 모든 decision-type 제안이 사용자에게 escalate. base의 `references/` 6개 Read 모두 0회로 감소(필수 콘텐츠 SKILL.md 인라인). Phase 3 cleanup 직전 single-line footer로 base 권장.
- `review-lite/SKILL.md`: 2-member 고정 sonnet split 팀 (보안 전담 + 코드 품질·로직). 단일 announce → Y/N. Round 1(initial) + Round 2(cross-validation) 고정, follow-up team 비활성. Step 1c large PR gate 제거 + Step 5 report에 "리뷰 범위" 섹션(미커버 영역 explicit disclose) 강제. base review의 `references/`는 그대로 재사용. `<directive>` 토큰은 1줄 warning 후 폐기.
- `scripts/lint-skill-invariants.sh`: phrase-presence sync rule 추가. `(design-review, design-review-lite)` 페어의 `## Control-Flow Invariants` 본문에 6개 termination contract phrase가 verbatim 존재해야 통과 (`consecutive_no_major >= 2`, `inner_converged_cleanly()`, `severity (post-upgrade) ∈ {critical, major}`, `INNER_EXIT_REASON == "clean-convergence"` 등). lite 파일이 없으면 silent skip하므로 점진적 롤아웃 친화적. SKILLS_ROOT 환경변수 override로 테스트 픽스처가 plugin 스킬 root를 대체 가능.
- `scripts/test-lint-skill-invariants.sh` + `tests/fixtures/lint-skill-invariants/{T-INV-OK-1,T-INV-FAIL-1,T-INV-FAIL-2}/`: phrase-presence rule 회귀 테스트. Makefile `test` 타겟에 등록.

### Changed

- `lint-skill-invariants.sh` `EXEMPT_SKILLS`: `design-lite`, `review-lite` 추가 (termination loop 없음). `design-review-lite`는 미면제 — Control-Flow Invariants 섹션 위치 + phrase sync 모두 강제.
- `README.md`: SKILLS_TABLE / SKILLS_OPTIONS 자동 생성 영역에 3개 lite 스킬이 alphabetical로 자연 진입. `## Usage` 섹션에 3줄 수동 추가(`design-lite`, `design-review-lite`, `review-lite`).
- `plugin.json`: `version: 1.3.0`.

### Why (PRO 사용자 가치)

Smoke test (단일 카운트다운 타이머 design + design-review-lite 사이클) 기준 메인 세션을 sonnet으로 둘 때 5h 한도 점유율 ~20% — base 사이클은 60~100%로 추정되어 Pro에서 안정적으로 못 도는 수준. lite는 같은 한도 안에서 4~5번 도는 빈도를 만든다. lite의 sonnet pin이 sub-agent(팀원/review agents) 비용을 12% 미만으로 억제함이 측정으로 확인됨.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds` 로 자동 반영. 기존 5개 base 스킬은 v1.2.0과 byte-identical이므로 기존 호출 패턴은 그대로 동작.
- lite 권장 사용 시점: 2~3 라운드 안에 자연 수렴할 작은 설계, Pro 한도 안에서 다관점 검토를 한 번 더 굴리고 싶을 때. critical 설계나 미묘한 termination invariant·동시성 검출이 필요한 경우 base 스킬을 사용. 각 lite의 `when_to_use`(README 표)와 Phase 3 footer가 base redirect 시그널을 양 채널로 제공.

## [1.1.0] - 2026-04-21

Progressive-disclosure 구조로 5개 스킬을 재구조화하여 post-compaction 토큰 효율을 개선하고, 공유 자료 중복을 제거했다. 순수 additive 변경이며 호출 인터페이스는 그대로 유지된다 (BREAKING 아님 — `/plugin update cc-cmds` 로 자동 적용).

### Added

- `_common/` 공유 디렉토리 신설: `team-cleanup.md` (5-step shutdown 절차), `agent-team-protocol.md` (`[COMPLETE]/[IN PROGRESS]` 시그널 + 파실리테이터 5대 규칙). 3개 스킬(`design`, `review`, `design-review`)이 `${CLAUDE_SKILL_DIR}/../_common/` 경로로 참조.
- `design-review/references/` 6개 파일: `01-auto-decide-protocol.md`, `02-processing-protocol-detail.md`, `03-severity-exit-policy.md`, `04-file-schemas.md`, `05-korean-ux-templates.md`, `06-review-agent-prompt.md`. 조건부 Read gate 로 로드.
- `review/references/` 3개 파일: `01-reviewer-context-package.md`, `02-review-report-template.md`, `03-non-pr-mode.md`.
- `design-review/SKILL.md` 상단에 Control-Flow Invariants 섹션 신설. Convergence predicate, `consecutive_no_major` 공식, `COUNT_APPLIED`/`escalate_applied` 공식, disposition tag 표, decision-type classifier, Processing Protocol trigger regex 를 첫 ~4K 토큰 내 inline 배치. Post-compaction 5K 재첨부 특권으로 종료 조건이 요약되지 않도록 보장.
- `scripts/lint-skill-invariants.sh`: SKILL.md 상단 4K 토큰 내 `## Control-Flow Invariants` 헤딩 존재 여부 검증 (macOS bash 3.2 호환).
- `scripts/generate-readme.sh`: 각 `SKILL.md` frontmatter(`name`/`description`/`when_to_use`)에서 README 커맨드 표 자동 생성. `<!-- SKILLS_TABLE_START -->` ~ `<!-- SKILLS_TABLE_END -->` 마커 사이 재작성, 멱등성 보장.
- `Makefile`: `lint`, `readme`, `check` (drift 검증) 타겟.
- `.github/workflows/lint.yml`: PR 트리거 — `make lint` + README drift 검증.
- `when_to_use` frontmatter 필드를 5개 스킬 모두에 추가. 자연어 질의에 스킬이 retrieval 되도록 개선.
- `docs/skill-restructure-design.md`, `docs/skill-restructure-test-scenarios.md`: 재구조화 설계 문서 및 L0~L6 통합 테스트 시나리오.

### Changed

- `design-review/SKILL.md`: 1385줄 → 615줄. §8 auto-decide 상세 알고리즘, file schemas, Korean UX 템플릿, agent prompt 를 `references/` 로 이관. Read gate 를 unconditional 로 명시 (소비 지점마다 무조건 Read).
- `review/SKILL.md`: 596줄 → 317줄. 15-item context package, severity system/merge rules, document template, 비-PR 모드 어댑테이션을 `references/` 로 이관.
- `design/SKILL.md`: 91줄 → 76줄. teammate instructions + facilitator rules + team cleanup 5-step 절차를 `_common/` Read gate 로 교체.
- `README.md`: 커맨드 표를 `<!-- SKILLS_TABLE_START/END -->` 마커로 감싸 자동 생성 대상으로 변경. `When to use` 컬럼 추가.

### Fixed

- Severity ↔ disposition orthogonality 모호성 해소. `(post-triage)` 용어를 `(post-upgrade)` 로 정정하고, SKILL.md Invariants 섹션에 "Disposition is IRRELEVANT" 공식 주석 추가. `references/03-severity-exit-policy.md` 에 "Severity ↔ disposition orthogonality (CRITICAL, frequently misapplied)" 섹션 신설 — Round 1~4 worked example 로 "resolved major 가 있어도 `consecutive_no_major` 는 reset" 시각화.
- Approval UX 의 내부 툴 제약 노출 방지. AskUserQuestion 4-option 제한으로 인한 배치 분할을 사용자에게 Korean template 으로 안내하도록 SKILL.md Approval UX 섹션 보강. "batch", "call", "분할", "4개 한계" 등 구현 용어 노출 금지 명시.

### Post-install notes

- 외부 사용자 조치 불필요. `/plugin update cc-cmds` 로 자동 반영.
- 과거 `~/.claude/commands/` 에 cc-cmds 파일을 수동 복사한 경우 해당 파일 삭제 권장 (스킬이 커맨드보다 우선 resolve 되나 중복 등록으로 혼동 여지).

## [1.0.0] - 2026-03-12

- Initial release.
