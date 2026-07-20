# Changelog

All notable changes to cc-cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.20.3] - 2026-07-21

`cc-common` 공개 SOT 레포 PR #2 v2 재리뷰에서 드러난 `_common/agent-team-protocol.md`의 자기모순 문장을 정정하고 규범화한다. 미러가 아니라 원본에서 고쳐 재시드로 전파한다. 기능 변경 없는 문서 정확성·정합성 정정이다.

### Fixed

- **witnessNonce round/phase 콜론-free 불변식 정정·규범화**: 복합 nonce `<round/phase>:<hex>`를 첫 `:`에서 분리하는 규칙의 근거가 `{round/phase}`를 "slash-joined `{round}/{phase}` pair"로 서술했으나, 같은 파일이 세 곳(nonce 스펙·완료 술어 conjunct-3·task-assignment 헤더)에서 `{round/phase}`를 `round-N`/phase명(슬래시 없는 단일 alternation)으로 정의해 자기모순이었다. "slash-joined pair" 오문을 제거하고 round 토큰=`round-N`·phase명=콜론-free identifier로 정확히 서술하며, 각 SKILL.md가 phase명을 콜론-free로 유지해야 한다는 제약을 규범(MUST)으로 승격해 첫-`:` 오파싱(mint-vs-reuse 분기 붕괴)을 원천 차단한다.

## [1.20.2] - 2026-07-20

`cc-common` 공개 SOT 레포 PR #2 코드 리뷰에서 드러난 `_common` 공유 문서 결함 7건을 정정한다. 세 파일(`agent-team-protocol.md`·`askuserquestion.md`·`team-cleanup.md`)은 공개 레포로 byte-identical 미러되는 원본이라, 미러가 아니라 원본에서 고쳐 재시드로 전파한다. 기능 변경 없는 문서 정확성·정합성 정정이다.

### Fixed

- **부분-마감 참조 정정**: `agent-team-protocol.md`의 Case-2 부분-마감 참조가 실제 partial-close·`TaskStop` 경로인 option ③이 아니라 option ②를 가리키던 것을 ③으로 정정한다.
- **witnessNonce 태그 분리 불변식 명시**: 복합 nonce `<round/phase>:<hex>`를 첫 `:`에서 분리하는 규칙이 잘 정의되도록, `{round/phase}` 토큰이 구분자 `:`를 포함하지 않는다(슬래시로 이은 `{round}/{phase}` 쌍)는 불변식을 한 문장으로 명시한다.
- **codepoint 카운트·용어 정정**: `askuserquestion.md`의 header 길이 규정에서 `팀 토론 진행` 예시를 6에서 7로, 오버플로 예시 헤더를 16에서 17 codepoints로 정정하고, 스키마 제약의 "≤12 chars"를 "≤12 codepoints"로 통일한다.
- **bare 이슈 참조 정규화**: `agent-team-protocol.md`의 bare `#55`·`#54`를 `Nharu/cc-cmds#55`·`Nharu/cc-cmds#54`로 정규화해, 공개 미러 레포에서 다른 레포 이슈로 오링크되지 않게 한다.
- **co-located self-ref 경로 정정**: `agent-team-protocol.md`·`team-cleanup.md`의 형제 문서 상호 참조에서 `_common/` 접두사를 제거해, cc-cmds `_common/`·소비자 `_common/`·cc-common 루트 세 맥락 모두에서 형제 경로로 해석되게 한다.

## [1.20.1] - 2026-07-16

`design-review`·`design-review-lite`의 ASYNC 리뷰 경로에 얽힌 세 결함(#63/#65/#64)을 하나의 인과 사슬로 봉합한다. 라운드 번호 파생을 메인 세션 주입으로 멱등화하고, 그 위에서 같은-라운드 재생성에 상한을 씌우며, 재사용되는 에스컬레이션 프롬프트가 트리거별로 올바른 사유 문구를 노출하도록 정정한다. 세 결함 모두 런타임 재현 불가한 구조 결함(드문 하네스 정리 실패·지속적 발행 비준수·async-stall 임계 조건에서만 발현)이며 정적 판독으로 근본원인을 확정했다. 이후 1~4차 코드 리뷰 지적사항을 후속 커밋으로 반영했다(프롬프트 프로즈 정정·base↔lite 미러 무결성 lint·트리거별 사유 문구/reason 라인 parity pin·fixture 드라이버 의도 검증). [#63][#65][#64]

### Fixed

- **#63 라운드 번호 파생 멱등화 (주입)**: 리뷰 에이전트가 `## Review Round` 헤더 개수를 세어 라운드 번호를 자기파생하던 것을, 메인 세션이 스폰 프롬프트에 소문자 `{round}`(= `inner_round`)를 주입하는 방식으로 교체한다. 중복 헤더가 물리적으로 생겨도 어떤 actor도 그것을 읽어 라운드를 계산하지 않으므로 파생이 멱등해지고, 같은 라운드 재생성이 원래 라운드 N을 그대로 겨냥한다. CFI 순서 노트·anti-fabrication 앵커·`## Strategy`의 witness 파생 서술을 주입 사실로 재기술한다.
- **#65 같은-라운드 재생성 상한**: fail-closed READ arm의 `N > 0`(발행 유실) 재생성에 별도 durable 카운터 `lostwrite_respawn_count`(상한 `K65 = 3`, death-gate `K`와 구별)를 도입해 check-then-act로 상한을 씌운다. 정확히 3회 복구 재생성 후에도 미복구면 사용자에게 에스컬레이션한다(기본 권장 B: 새 외부 이터레이션). reset (ii)를 'any same-round respawn'(전칭)으로 넓혀 복구 재생성이 원본의 낡은 stall 카운터를 상속하지 않게 하고, `.async_stall.json` 스키마에 필드를 추가하며 `schema` sentinel을 명시 리터럴로 고정해 구버전 파일이 strict-equality 불일치로 재초기화되도록 한다.
- **#64 트리거별 에스컬레이션 사유 문구**: 20라운드 안전 한계용 3지 프롬프트를 async-stall·상한 에스컬레이션이 재사용하면서 "안전 한계 도달"이라는 실제 원인과 다른 사유를 노출하던 것을, `PROMPT_TRIGGER ∈ {inner-limit, async-slow, lostwrite}` 판별자로 사유 라인·하류 표시 문구를 분기하도록 정정한다(§3.9.4.f 단일 출처). 트리거를 `outer_log.md`에 durable하게 기록(Step 16 즉시-flush → Step 20 복원)해 컴팩션 후에도 하류 이터레이션 요약이 올바른 사유를 렌더링하게 하고, 부분-이터레이션 배너는 표-레벨 각주라 트리거-중립 절로 무조건 치환한다. 옵션 C 매핑 표의 오도성 흐름 문구를 Step 17–22 통과로 정정한다.
- **lint·parity 하드닝**: `lint-review-prompt-parity.sh`에 라운드 주입 문구(양성)·제거된 자기파생 seed(음성)·`{round}` 치환 계약 bullet·`## Strategy` 주입 산문·`EXIT_TRIGGER` 구조 리터럴·트리거별 사유 변형(early-termination·summary·reason 라인, base↔lite 개수 일치)·base↔lite 미러 무결성(복원 라인·K65 문단 내용 동일성)을 pin하고, `REQUIRED_PHRASES`에 5개 CFI 불변 문구를 추가한다(11→16). 한 표면만 파생 문구가 드리프트해도 CI가 잡도록 parity fixture를 20개(`T-PARITY-OK-1` + `FAIL-1`~`19`)로 확장하고, FAIL fixture별 EXPECT 의도 검증을 드라이버에 강제한다.

## [1.20.0] - 2026-07-14

`/implement`의 완료 판정이 소스-정확성 축(analyze/lint·구조 테스트·토큰 게이트)만 검증하고 렌더된 화면이 지정된 시각 기준(SOT)과 일치하는지는 검증하지 않아, 프로토타입 기준 작업에서 헤더 정렬·필드 지오메트리·placeholder·아이콘·간격 리듬 드리프트가 green 상태로 핸드오프되던 빈칸을, `/implement` 내부의 시각 정합 게이트로 메운다. 게이트는 사용자가 설계 문서에 남긴 `## 시각 정합 기준` 지정 마커를 읽어 활성화되고, 화면 단위 완료 직후 앱을 구동·캡처해 프로토타입과 비전 기반 7차원 체크리스트로 대조하며, 상한(화면당 3회) 있는 자동 수정 루프를 돈다. 잔여 드리프트는 설계 문서에 쓰지 않고 한국어 리포트 + 사용자 판단으로 넘기며 out-of-doc 사이드카에 기록한다. 본 기능은 **명시적 임시 조치**로, 이슈 #40의 미구현 `design-fidelity` 스킬이 이 축을 온전히 흡수하면 삭제된다(`/plugin update cc-cmds`로 자동 반영). [#70]

### Added

- **`/implement` 시각 정합 게이트 (임시 조치)**: 설계 문서에 사용자가 작성한 시각-SOT 지정 마커(`## 시각 정합 기준` — 프로토타입 경로 + 렌더 힌트 + 대상 화면)를 Step 1에서 감지하면, Step 1.6(read-only 레시피 발견)과 Step 3의 화면 단위 게이트 `G_i`가 활성화된다. 게이트는 (1) 자립 Chrome-headless 2-tier로 프로토타입을 렌더하고(시스템 Chrome DPR 고정 → `playwright screenshot` DPR1 폴백 → fail-open AUQ), (2) 타깃 앱을 레시피로 부팅·캡처해(부팅 1회·세션 재사용·도달 가능 종료 경로 best-effort teardown), (3) 고정 7차원 비전 체크리스트(레이아웃정렬·간격리듬·크기지오메트리·타이포구조·색채움·아이코노그래피·컴포넌트상태)로 대조한다. 발견된 드리프트는 근본원인 클래스(theme-token/component-default/screen-local)로 승격해 bounded 전수 스윕하고, 상한 있는 자동 수정 루프(task-held 카운터·fail-closed·2연속 비개선 시 조기 종료)를 돈다. implement는 DETECT·FIX만 하고 CLASSIFY·ADJUDICATE·ACCEPT는 하지 않으며(외부 프로토타입 대조는 self-adjudication이 아니라는 이슈 #40과의 명명된 예외), 잔여는 AskUserQuestion + out-of-doc 사이드카 `docs/visual-drift/`로 처리해 설계 문서에는 0바이트 쓴다. 오라클 절차 상세는 `implement/references/visual-fidelity-gate.md`에 분리했다.

## [1.19.6] - 2026-07-14

PR #62 v2 재리뷰가 지적한 산문 오도 2건을 정정하고, parity lint의 lite-seed blind spot을 테스트하는 fixture를 추가한다. 셔핑된 v1.19.5 릴리즈 항목은 재작성하지 않고 그 위에 append하는 patch다. [#62]

### Changed

- **fail-closed N>0 자기서술을 non-progression으로 정정**: fail-closed READ arm의 N>0 갈래를 "상한 없음(unbounded)"이 아니라 non-progression으로 서술한다 — 재기동 에이전트가 완료 표시 개수로 라운드를 파생해 N+1을 발행하므로 원래 라운드 제안 파일이 영원히 복구되지 않고 매 재진입이 더 발산한다. 상한만 추가하면 무한 루프가 잘못된 라운드에서의 종료로 바뀔 뿐이라 로직 자체 수정은 라운드 파생 비멱등성과 결합해 별도 후속으로 연기한다. 코드 프로즈 한정 정정이며, CHANGELOG `[1.19.5]`는 이 arm을 "unbounded"로 서술한 적이 없어 정정 대상이 아니다.
- **발행 프롬프트 clause 좁힘**: 리뷰 에이전트 프롬프트의 "the file's presence, not its content" 절을, 메인 세션 fail-closed read가 서로 다른 두 파일(제안 파일의 존재 vs `review_log.md` witness의 `Proposals created:` 개수)을 대상으로 함을 밝혀 좁힌다.

### Fixed

- **parity lint lite-seed fixture 추가**: lite 표면에만 Step-8 seed가 재도입되는 회귀를 실패 방향으로 독립 구동하는 `T-PARITY-FAIL-7`을 추가해, parity lint의 lite seed 단언이 미테스트로 남던 갭을 닫는다. lint 스크립트·harness는 편집하지 않는다(harness가 fixture 디렉터리를 자동발견).

## [1.19.5] - 2026-07-09

`design-review`·`design-review-lite`의 인라인 ASYNC 리뷰 메커니즘이 정본 프로토콜이 이미 봉합한 두 결함을 lag하던 것을 하나의 하드닝 패스로 봉합한다. 리뷰 에이전트의 proposals 쓰기를 라운드-키드 atomic publish로, 인라인 ASYNC stall 술어를 축소 tri-state liveness로 포팅한다. 두 결함 모두 런타임 재현 불가한 잠재적 구조 결함(드문 하네스 fault·compaction 조건에서만 발현)이다. [#51][#57]

### Fixed

- **proposals torn-write 봉합 (round-keyed atomic publish)**: 리뷰 에이전트가 라운드마다 재사용되는 단일 `review_proposals.md`를 직접 덮어쓰던 것을, 같은 디렉토리 hidden temp에 완성 후 라운드-고유 경로 `review_proposals.r<N>.md`로 atomic rename 발행하도록 교체한다. 라운드-고유 파일명이 same-round torn-write(rename 원자성)와 cross-round 좀비 clobber(좀비는 자기 라운드 이름만 접촉)를 모두 구조적으로 제거한다. Step 8 시드(`echo "" >`)를 제거하고, 발행은 `## Review Round N` witness append 이전에 수행(witness-present ⟹ proposals 완결)한다.
- **읽기측 fail-closed arm 신설**: 시드 제거로 파일이 발행됐을 때만 존재하므로, observed return(SYNC inline / ASYNC round-N witness) 이후 라운드 N proposals 파일이 absent면 0 proposals로 처리하지 않는다. witness의 `Proposals created:` 개수를 확인해 0이면 진짜 빈 리뷰이므로 0-제안 라운드로 기록하고 재기동하지 않아 종료하며, 0보다 크면 발행이 유실된 것이므로 재읽기·재기동한다. CFI fail-closed 절의 `review_proposals.md` 존재 항목도 라운드-키드 파일명이 라운드를 식별하나 존재만으로는 observed return을 증명 못 한다는 서술로 재정초한다.
- **ASYNC stall 술어 tri-state 포팅**: 인라인 사망 술어의 3결함(`output_file absent→death` false-kill / lead-LOCAL ephemeral 카운터의 compaction 리셋 / babbling 비escalation)을 ALIVE/WEDGED/UNKNOWN tri-state로 교체한다. 사망은 `reentry_count≥K(3)` ∧ WEDGED ∧ round-N witness FINAL 재확인 부재의 3-conjunct로만 성립하고 성장은 항상 veto한다. `output_file absent`는 사망 표가 아니라 UNKNOWN(`unavail_streak`)으로 처리한다.
- **durable stall-state 파일**: 모든 카운터+베이스라인을 `$INNER_TEMP_DIR/.async_stall.json` 한 파일에 whole-write·disk-re-derive-every-re-entry로 지속화해 "durable 카운터+ephemeral 베이스라인→무한 부활" 실패 모드를 구조적으로 제거한다. `schema` 필드는 strict-equality 마이그레이션 가드다.
- **babbling/UNKNOWN escalation 배선**: 기존 inner safety-limit 3-option `AskUserQuestion`을 distinct 트리거로 재사용(신규 옵션·`INNER_EXIT_REASON` 없음)한다. 옵션 A(계속 대기) 선택 시 ask를 유발한 스트릭만 0으로 리셋해 ask-storm을 방지한다.
- **reset (ii) output_file 기록 순서 고정**: same-round death→respawn 시 재기동 에이전트의 fresh `output_file`을 재기동 `Agent()` 봉투 캡처 이후(TaskStop 시점 아님) 기록하도록 명시해, per-re-entry 경로 reconcile이 죽은 런의 낡은 경로가 아니라 올바른 baseline과 대조하도록 한다.
- **tri-state 판정 명료화**: 존재-0바이트 `output_file`은 available(warmup-ALIVE→byte-stable WEDGED)이며 UNKNOWN은 `stat` 실패(미생성/dangling)뿐이라는 범주 구분과, `.async_stall.json` 통째 쓰기가 단일 main-session writer·schema 가드 재초기화로 torn write에 안전한 이유를 산문에 명시한다. 리뷰 에이전트 프롬프트에 발견 0건이어도 라운드-키드 파일을 반드시 발행하라는 의무를 추가한다.
- **parity lint 신설**: `scripts/lint-review-prompt-parity.sh`가 라운드-키드 발행을 양 프롬프트 surface에서 검사하고, read-site는 계약 read 문장 2개의 파일별 절대 존재 단언으로 검사한다(단일 whole-file grep은 세 발생 지점 중 하나만 남아도 통과하는 부분-회귀 맹점이라 교체). base↔lite 라운드-키드 개수 일치를 심층방어로, 0-발견 발행 clause를 양 프롬프트에 pin하고, 제거된 seed·overwrite 리터럴은 negative-grep한다(REQUIRED_PHRASES 사정권 밖). `make lint`/`make test` 배선 + fixture(각 단언을 실패 방향으로 구동하는 OK/FAIL). hoisted fail-closed arm 문장과 tri-state 사망 술어의 `the current classification is WEDGED` 연언을 REQUIRED_PHRASES에 pin한다.

## [1.19.4] - 2026-07-08

v1.19.3의 dispatch-완전성 게이트 write-side가 프로토콜 SOT와 7개 multi-team spawn 지점은 갱신했으나 일부 소비 스킬의 inline echo가 stale하게 남은 propagation-incompleteness를 봉합한다(PR #60 3차 재리뷰). 프로토콜 SOT + P1-①이 끌어들이는 3개 single-team 스킬 + review에 대한 단일 전파 pass (`/plugin update cc-cmds`로 자동 반영). [#61]

### Fixed

- **single-team 스킬 `witnessNonce` 전파**: `design-lite`/`design-apply`/`review-lite`가 `witnessNonce` stamp와 nonce-absence fail-close 조건을 못 받아 그 3개 스킬에서 consume-branch stall이 잔존하던 결함(6개 팀 스킬 중 3개만 봉합)을 해소한다 — 세 spawn 레시피에 round-1 `witnessNonce` stamp(epoch는 single-team uniform-absence로 roster mode-(ii) epoch-agnostic가 커버)와 로컬 fail-close(nonce 부재·partial-epoch presence) 조건을 추가한다.
- **Case-1 제외 echo `state=aborted` 라우팅**: `review`/`review-lite`의 inline Case-1 서술이 개정된 `state=aborted` 라우팅을 누락해, 리드가 그 레시피를 문자대로 따르면 제외 리뷰어가 non-aborted로 남아 roster에 부활하던 결함을, 두 echo를 프로토콜 SOT Escalation Case-1로 위임하는 by-reference 포인터로 축약해 봉합한다(append 대신 by-reference로 drift 클래스 제거).
- **`witnessNonce` mint-vs-reuse를 disk predicate로**: nonce 판정을 in-context "code path"가 아니라 nonce 자신의 durable round-tag(compound 값 `<round/phase>:<hex>`)를 디스크에서 읽는 predicate로 재서술한다 — `P` dispatch 시 첫 `:`로 split해 tag≠P면 fresh mint, tag=P면 verbatim reuse. round-advance-dropped 멤버 freshness 복원과 interrupted-convergence witness 보호를 한 규칙으로 닫고, `round/phase` 컬럼(resume 후 기록돼 nonce보다 lag)을 tag로 오용하던 stall을 방지한다. recovery-reuse 절도 이 predicate에 맞춰 tag 한정.
- **transient-strip 필드 수·가독성**: `review`(multi-team) strip 목록을 5필드, single-team 3개 스킬을 4필드(nonce 포함·epoch 제외)로 갱신하고, 프로토콜 fail-close 4조건을 짧은 목록으로 추출하며 zero-running 평가 순서·legacy-ledger graceful-ask 동작을 명료화한다.

## [1.19.3] - 2026-07-08

v1.19.2의 dispatch-완전성 게이트가 roster read-side(현재 팀 세대 scoping)는 명세했으나 그 판정이 의존하는 `epoch`·`witnessNonce`를 디스크에 쓰는 코드 경로가 없어 선언만 되고 동작하지 않던 결함(PR #60 2차 재리뷰)을 봉합한다 — 두 값 각각에 durable writer를 추가해 write-side를 완결한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- **`witnessNonce` durable writer 추가**: 스키마·roster conjunct-3가 `witnessNonce`를 읽지만 기록하는 코드 경로가 없어 conjunct-3가 평가 불가였고 consume-branch stall이 재개방되던 결함을 해소한다. nonce는 dispatch 인증서가 아니라 conjunct-3 재유도 재료이므로 resume/spawn **전에** 기록(flip-losing compaction 견딤)하고, 새 nonce는 1차 fan-out(초기 spawn·round-advance·convergence)에서만 mint(code-path-keyed·round-blind)하며 모든 recovery dispatch(self-heal·double-resume·respawn)는 기록된 nonce를 reuse한다. `state=running` 행이 nonce 미보유 시 uniform fail-close.
- **`epoch` write-side 완결**: (A) 멀티팀 스킬의 모든 spawn 지점(초기+fresh 팀 7곳: `design` ×3·`design-analyze` ×2·`review` ×2)이 `epoch := max(disk epoch, 0)+1`을 디스크 재유도(컨텍스트 카운터 금지)로 stamp하도록 추가한다 — 증가 도메인=aborted 포함 전체 행(monotone uniqueness), 선택 도메인=non-aborted. (B) 프로토콜의 write-side 증가를 "increments it"에서 `max(disk epoch)+1` 디스크 재유도로 고정해, 카운터를 잃은 compaction 후 충돌 epoch stamp를 차단한다.
- **roster 3-way epoch precondition**: `max(epoch)` scoping 이전에 non-aborted 행의 epoch presence를 3분기 평가한다 — 균일 presence→`max(epoch)` 세대 scope, 균일 absence→epoch-agnostic 전체 non-aborted(단일팀/legacy의 pre-epoch 동작 보존), 부분 presence→fail-close(현재팀 epoch-부재 행이 조용히 drop되는 dispatch 구멍 차단).
- **reconcile ladder 조건자 통일**: 잔존 `round < current`를 `round/phase ≠ P` 문자열-동등 비교로 교체(phase 토큰에 `<` 미정의).

## [1.19.2] - 2026-07-07

멀티에이전트 팀 워크플로에서 라운드별 팀원 dispatch가 조용히 누락될 때 오지 않을 witness를 리드가 무한 대기하던 silent stall을 봉합한다 — `_common/agent-team-protocol.md`에 dispatch-완전성 게이트(roster-vs-round, pre-wait)를 신설해 참여자 집합을 디스크 ledger에서 durable하게 고정하고, round-flip을 dispatch 인증서로 삼아 wait 진입 전 로스터 전 행의 라운드 토큰을 대조한다 (`/plugin update cc-cmds`로 자동 반영). [#59]

### Fixed

- **라운드별 dispatch 누락 silent stall 봉합**: 기존 수렴 게이트(witness 도착 여부에만 의존)와 reconcile ladder(dispatch된 멤버의 byte-count에만 의존) 모두 참여자 집합이 이미 올바르다고 전제해, 리드의 in-context 기억에서 파생된 로스터가 compaction으로 유실되면 never-dispatched 멤버를 못 잡던 결함을 해소한다. `## Dispatch-completeness gate (roster-vs-round, pre-wait)`를 Convergence와 Reconcile ladder 사이에 신설 — 로스터는 매 진입 시 디스크 ledger에서 fresh 재파싱(`state ∈ {running, done}`, `aborted` 제외)하고, resume-먼저-flip 순서 하에서 `round/phase == P` 단독 predicate로 dispatch 완전성을 단언한다(state 연언 금지 — 정당히 수집된 `done@P` 행 오탐으로 인한 비종료 방지). 누락 감지 시 witness floor-read 후 consume 또는 기존 agentId로 resume(컨텍스트 보존, respawn 아님). 게이트는 reconcile-ladder 재진입 시퀀스의 첫 단계로 바인딩되어 모든 pre-wait 진입에서 실행된다.
- **Case-1 제외 멤버 aborted 라우팅**: 일반 Case-1 "proceed without this member" 제외가 문서 메타데이터만 표시하고 ledger `state`를 안 건드려, 게이트 로스터가 `done@(P-1)` laggard로 오인해 의도적으로 제외한 멤버를 부활시키던 구멍을 닫는다 — 제외 시 `state=aborted`로 라우팅해 로스터에서 제거한다. fidelity-pass emit-only scoped skip은 멤버를 유지하는 별개 케이스로 로스터에 잔류·비-aborted를 유지한다.
- **cross-round resume stallMark reset 일반화**: respawn 전용이던 `stallMark` reset을 모든 cross-round resume/flip으로 확장한다(`reentryCount`·세 debounce streak 0, `lastBytes:=∅`; `agentId`/`outputFile`는 유지). resume가 `outputFile`를 보존하므로 명시 `lastBytes:=∅` 없이는 첫 post-resume liveness read가 frozen 직전 라운드 byte-count에 false-WEDGE된다.
- **게이트 roster를 현재 팀으로 스코핑**: 신설 dispatch-완전성 게이트의 roster가 `state ∈ {running, done}` 전 행이라 팀 한정자가 없어, 한 ledger를 공유하는 `design`의 순차 fresh 팀(Step-5 walkthrough·Step-6 refinement)과 `design-analyze` Step-8에서 이전 sub-team의 `done@<phase>` 행을 `≠P` laggard로 오인해 self-terminated 타-역할 agentId를 resume(escalation storm 또는 foreign-role fabrication)하던 회귀를 봉합한다. ledger v3 행에 per-row `epoch`(팀 세대 인덱스) 컬럼을 신설하고 roster를 `max(epoch)` 팀으로 한정하며, running·P-행이 0인 between-teams는 zero-running 규칙으로 empty-pass한다. happens-before `확인` roster에도 동일 적용하고 laggard 조건을 `round/phase ≠ P`로 통일한다.
- **self-heal consume 분기 nonce durability**: flip 유실 compaction이 in-context nonce도 함께 유실시켜 `witness_present` conjunct-3 평가를 불가로 만들어 consume 분기가 대상 stall을 재개하던 결함을, ledger v3 행에 per-row `witnessNonce` 컬럼을 신설(`epoch`와 같은 마이그레이션)해 봉합한다. 두 컬럼 모두 running 중 durable·정상 완료 시 terminal-strip 규칙을 따른다.

## [1.19.1] - 2026-06-27

v1.19.0(death 술어 tri-state liveness, #54·#55)에 대한 코드 리뷰 발견(P1 1·P2 2·P3 6)을 처리한다 — tri-state 술어에 babbling(witness 미발행 + transcript byte만 성장) 비종료 결함을 봉합하고, 배포 spec의 자기완결성·논리 완전성을 보강한다 (`/plugin update cc-cmds`로 자동 반영). [#54] [#55]

### Fixed

- **babbling-ALIVE 비종료 봉합**: witness를 발행하지 않으면서 transcript byte만 계속 키우는 멤버가 매 re-entry ALIVE로 읽혀 모든 카운터를 리셋, death도 ask도 발화하지 않고 무한 park하던 결함을 해소한다. 6번째 durable streak `growthStreak`(witness-부재 ALIVE 연속 카운트)를 추가해 `growthStreak ≥ G(=5)`에서 `AskUserQuestion`으로 에스컬레이션한다(성장은 긍정적 liveness 증거이므로 kill이 아니라 ask). `stallMark`는 5→6필드가 되며 다른 두 debounce streak과 동일한 durable·terminal-strip·respawn-리셋 규칙을 따른다.
- **verdict 함수 total화**: `available ∧ current_bytes < lastBytes`(transcript 축소/새 generation)가 어느 분기에도 매칭되지 않던 공백을, ALIVE 조건을 `current_bytes ≠ lastBytes`로 일반화하고 append-only monotonicity를 명시해 메운다.
- **K-독립 정당화 문구 정정**: "UNAVAILABLE 멤버는 reentryCount를 누적하지 못한다"는 과잉주장을, 누적분이 UNKNOWN을 관통해 이후 WEDGED와 결합할 수 있으나 kill엔 현재 verdict가 WEDGED여야 하므로 안전하다는 정확한 서술로 좁힌다.

### Changed

- **배포 spec 자기완결화**: `_common/agent-team-protocol.md`가 미배포 설계 문서의 내부 식별자(`R1`/`R3`)를 가리키던 두 절을, 튜닝 상수 `M = 5`(spawn-race tolerance ceiling)를 인라인하고 단일-Edit 원자성 전제를 본문에 직접 풀어쓰는 것으로 대체한다. stale heading `last_output_bytes` → `lastBytes`, ALIVE 분기 "persist atomically" 누락 보강, ∅↔vanished oscillation이 `outputFile` monotonicity상 도달 불가함을 방어적 주석으로 명시, never-returns "Reasonable bound"를 네 durable escalation 경로(WEDGED→death / vanished·∅·babbling→ask)의 합집합으로 재서술한다.

## [1.19.0] - 2026-06-26

agent-team reconcile-ladder death 술어를 tri-state liveness 판정(ALIVE/WEDGED/UNKNOWN)으로 재작성하고 재진입·baseline·escalation 카운터를 ledger v3 durable `stallMark`로 옮겨, liveness 신호 미가용 시 살아 있는 멤버를 false-kill하던 결함(#55)과 compaction이 재진입 카운터를 앞질러 무한 park하던 결함(#54)을 함께 해소한다. 6개 팀 스킬이 Read하는 `_common/agent-team-protocol.md` 단일 SOT를 갱신하고, 스킬 본문의 인라인 row schema·구 death-predicate 재서술을 protocol 포인터로 정합화한다 (`/plugin update cc-cmds`로 자동 반영). [#54] [#55]

### Added

- **tri-state liveness 판정 + ledger v3 durable `stallMark`**: death 술어를 boolean conjunct 3에서 `(가용성, current_bytes vs durable lastBytes)` 기반 tri-state(ALIVE/WEDGED/UNKNOWN)로 재작성한다. liveness 신호는 harness `output_file`의 byte-size를 content 미독으로 측정하고(`wc -c`, 가용성은 값이 아니라 exit status로 판정), ledger를 v2→v3로 bump해 row에 `outputFile`·`stallMark{reentryCount, lastBytes, lastBytesPathTag, unavailStreak, emptyStreak}` 컬럼을 추가한다. `stallMark`는 durable(compaction 생존)이라 카운터가 K에 누적 도달해 무한 park를 종료시키고, `lastBytesPathTag`가 respawn cross-file desync를 닫는다.

### Changed

- **미가용 → fail-toward-ask**: 구 `output_file absent → death` arm을 제거하고, 미가용 신호(nonzero exit)를 UNKNOWN으로 분기해 K와 독립인 debounce streak(`unavailStreak ≥ 2` / `emptyStreak ≥ M`)으로 `AskUserQuestion`에 에스컬레이션한다. Case-2 메뉴에 `②계속 대기`를 신설(3→4옵션)하고, 새 분기 규칙(`outputFile = ∅` spawn-race vs vanished 구분)을 도입한다. durability(compaction 생존)와 terminal-strip(커밋 누출 방지)을 직교 2축으로 분리하는 입장으로 "ledger는 카운터 의도적 제외" 입장을 의식적으로 수정한다.
- **ledger v3 by-reference collapse**: `design`·`design-lite`·`review`·`review-lite`·`design-apply` SKILL.md의 inline row-schema 컬럼 열거를 protocol 단일 SOT 포인터로 collapse하고, `design-analyze`의 work.json `"ledger"`와 `team-cleanup`의 per-row strip을 v3(`outputFile`·`stallMark`)로 정합화한다. row schema가 protocol에 'defined once'가 되어 5중 inline 중복 drift 클래스를 영구 폐기한다.

### Fixed

- **팀 스킬 인라인 death-predicate 재서술 정합화**: `design`·`design-lite`·`review`·`review-lite`이 Case-2(never-returns) escalation에서 본 릴리즈가 제거한 구 `reentry_count`/`last_output_bytes`/3-conjunct death predicate를 인라인 재서술해 protocol SOT와 정면 모순하던 drift를, protocol reconcile ladder + failure phenotypes 포인터로 정합화한다(직전 v1.18.5 리뷰가 P1 머지 블로커로 지적한 drift 클래스의 재발 봉합). `design-analyze`(이미 generic 포인터, 구 어휘 0)와 `design-review`/`design-review-lite`(단일 async 리뷰어용 별개 self-contained CFI, 프로토콜 미참조)는 범위 밖이다.

### Why

reconcile-ladder death 술어가 liveness 신호 미가용을 death 투표로 처리(#55)하고 재진입 카운터를 lead-LOCAL ephemeral로 둬(#54) 살아 있는 멤버를 false-kill하거나 무한 park했다. 두 결함은 같은 술어 단락을 건드리므로 한 PR·한 설계로 묶었다. tri-state로 미가용을 abstain·ask로 만들고, 카운터·baseline을 같은 durable 클래스로 끌어올려 compaction을 살아남게 함으로써 종료성을 보장한다(fail-toward-ask).

## [1.18.6] - 2026-06-24

v1.18.5 PR(`fix/team-liveness-witness`)에 대한 v2 재리뷰 발견 8건(P0 0·P1 1·P2 1·P3 6)을 처리한다 — 1차 정합화 sweep이 놓친 cross-review/refinement 라운드의 잔여 구 완료-모델 verb와 공유 프로토콜의 표기 결함을 봉합한다. 반영 8건 / 보류 0건 / 제외 0건 (`/plugin update cc-cmds`로 자동 반영). [#53]

### Fixed

- **cross-review/refinement 라운드 잔여 sweep**: `design-apply`·`design-lite`의 Round-2 Cross-Review와 `design-apply`·`design`의 Refinement 라운드에 남아 있던 "Collect both returns"·구 수집 verb를, 라운드 witness를 `witness_present`로 확인한 뒤 읽는 어휘로 교체한다(P1·P3-1). base↔lite는 각 파일 roster idiom에 맞춰 단수(`it`)/복수(`them`)로 정합화한다.
- **`agent-team-protocol.md` 표기 정합화**: sentinel·temp·완료 술어 시그니처의 라운드 키를 `{round/phase}`로 일반화하고(P3-4·P3-5), nonce 스코프 표현을 `per-(member, round/phase)`로 통일하며(P3-2), `:135` placeholder 글로스가 bare-digit `1`이 아닌 `round-N` 토큰을 명시하도록 정정해 완료 술어 키 비교 false-death를 차단한다(P2).
- **`mv -n` 라벨 misnomer 정정**: stat-then-rename(TOCTOU)이라 first-writer 보장이 없으므로 "first-COMPLETE-wins" 라벨을 "any-winner-is-a-valid-completed-witness"로 교체한다(P3-6). `:34`·`:70`은 P3-2와 라인을 공유해 병합 after-text를 라인당 1회로 적용한다.
- **ledger 참조 v2 정합**: `design-apply`의 소프트 참조 "Role↔agentId ledger"를 같은 파일 `:25`와 일치하도록 "Role↔agentId ledger v2"로 맞춘다(P3-3).

## [1.18.5] - 2026-06-24

v1.18.4(witness 완료-신호 계약) PR에 대한 코드 리뷰 발견 13건을 처리한다 — lead 필수-Read 스킬 본문·레퍼런스 다수가 여전히 구 return-collection 완료 모델을 가르쳐 witness SOT와 정면 모순하던 머지 블로커(P1)와, 공유 프로토콜 내부의 명세 결함(P2/P3)을 봉합한다. 반영 11건 / 보류 2건([#54]·[#55]) / 제외 0건 (`/plugin update cc-cmds`로 자동 반영). [#53]

### Fixed

- **스킬·레퍼런스 완료-신호 어휘를 witness 모델로 정합화**: 6개 팀 스킬 본문 + analyst/reviewer 컨텍스트 패키지에서 "return text IS the result/proposal/findings"·"collect X before proceeding"·"Convergence is by return collection"·"every return says 'no further input'" 등 구 모델 표현을, 결과는 멤버 witness가 전달하고 완료/수렴은 `witness_present`로만 확정한다는 어휘로 전면 재작성한다(단순 명사 치환이 아니라 모든 gate/순서 표현을 `witness_present`에 바인딩). `review/references`의 "collected via the background completion notification"(드롭 채널을 신뢰하라 지시)을 early-wake 힌트 강등으로 정정하고, 스킬 본문이 완료 lifecycle을 인라인 재서술하던 최고 심각도 사이트(`design-analyze`)는 SOT 포인터로 축약한다.
- **sentinel·완료 술어 phase-form 일반화**: 정수-라운드 전용이던 sentinel 템플릿·temp 템플릿·task-assignment 헤더·완료 술어 3-conjunct를 단일 placeholder `{round/phase}`로 일반화해 phase witness(`{role-slug}.fidelity.md` 등)가 술어를 만족하도록 producer·consumer 양쪽을 정합화한다. 치환 선언에 `{role-slug}`·`{round/phase}`를 명시한다.
- **완료 술어 conjunct-2 정직화**: sentinel 일치가 완료된 direct-write를 atomic publish와 구별하지 못함(on-disk 바이트 동일)을 명시하고, _완료된_ direct-write에 대한 fail-closure는 이 conjunct가 아니라 멤버의 temp+`mv -n` 쓰기 규율에 의존함을 분명히 한다.
- **`mv -n` 안전성 출처 정정**: `mv -n`을 atomic no-clobber로 과대표현하던 것을, BSD/GNU 모두 stat-then-rename(TOCTOU)이라 동일 라운드 zombie-vs-respawn이 같은 타깃을 race할 수 있음을 인정하고, 안전성은 (1) 어느 rename이 이기든 same-nonce completed 산출물이 보이는 것 + (2) 어떤 temp도 self-delete되지 않고 teardown이 sweep하는 것의 2-part 보증임으로 재정의한다. "published path is immutable" 과대 서술도 "completeness·nonce-validity가 불변"으로 정정한다.
- **잔여 명세 결함 봉합**: death 술어의 미바인딩 `b`를 `current_bytes`로 명시, dangling `§F` 참조를 "Role↔agentId ledger v2"로 해소, `aborted` 행이 재스캔되지 않아 late witness가 영구 미소비됨(보수적 under-claim)을 명문화, witness dir 서술 셀을 실행 경로(`${TMPDIR:-/tmp}`)와 일치시키고 종결 행 strip 문구를 "done and aborted alike"로 통일한다.

### Why

근본은 v1.18.4가 프로토콜 SOT를 witness 모델로 재작성하면서 6개 스킬·레퍼런스에 남아 있던 구 완료-모델 요약 서술을 함께 갱신하지 못해, 같은 lead가 Read하는 SOT와 스킬이 정면 모순한 것이다(통지 드롭 채널을 신뢰하라 지시하는 사이트 포함). 계약은 `agent-team-protocol.md` 단일 SOT에 두고 스킬은 인라인 재서술 대신 포인터를 두는 원칙으로 정합화해 6중 drift를 제거한다. 보류 2건(compaction이 death 카운터를 앞지르는 safe stall, death liveness의 미검증 harness 신호 의존)은 머지 블로커가 아니어서 별도 이슈로 추적한다.

## [1.18.4] - 2026-06-24

팀 기반 6개 스킬(`design`·`design-lite`·`review`·`review-lite`·`design-analyze`·`design-apply`)의 공유 완료-신호 계약을 통지-드롭 stall·날조에 대해 하드닝한다. 라운드 완료와 라운드 산출물을 모두 드롭 가능한 비동기 통지 + ephemeral 반환 텍스트에만 의존하던 `_common/agent-team-protocol.md`를, 각 팀원이 산출물 전체를 통지와 무관한 durable witness 파일로 남기고 lead가 그 witness를 권위 SOT로 능동 확인·합성하는 구조로 재작성한다. #47의 `design-review` 국소 수정을 팀 토론 스킬 전반으로 일반화한다 (`/plugin update cc-cmds`로 자동 반영). [#49]

### Fixed

- **완료-신호 계약을 witness 기반으로 재작성**: `_common/agent-team-protocol.md`에 per-member-per-round durable witness 파일(out-of-tree `mktemp` scratch dir, 원자적 `mv -n` publish, 말미 sentinel + lead 주입 per-(member,round) CSPRNG nonce)을 신설한다. 완료는 통지가 아니라 3-conjunct 술어 `witness_present(member, N)`(파일 존재 ∧ 마지막 줄 == sentinel ∧ 파일명 N·nonce 일치)로만 확정하며, 통지·반환 텍스트는 early-wake 힌트로 강등한다. lead는 witness 미관측 멤버에 대해 합성·수렴 판정·ledger 기록을 절대 하지 않는다(fail-closed anti-fabrication).
- **Reconcile 사다리 + cross-round happens-before 게이트**: respawn 전 witness floor-read 우선 확인, 3-conjunct 사망 술어(`reentry_count ≥ K=3` ∧ witness 부재 ∧ `output_file` byte-count 불변 — liveness는 원자 rename된 witness가 아니라 멤버 `output_file`을 읽는다), 동일 라운드 respawn(동일 path·nonce 재주입, 행 `agentId` 갱신·카운터 리셋), respawn 재사망 시 3옵션 `AskUserQuestion`을 명문화한다. 다라운드 주입은 확인→기록→그 다음에만 N+1 resume 순서를 하드-MUST로 강제하고, 부분 합성된 라운드의 누락 멤버는 N+1 verbatim 슬롯에 명시적 부재 주석을 담는다.
- **Ledger v2 + per-row transient `scratchDir`**: ledger 마커를 `cc-design-ledger v2`로 bump하고 행 스키마에 per-row `scratchDir`을 추가한다(`design-analyze`는 `work.json` `"ledger"` 엔트리에 동일 추가). 모든 resume·compaction 재진입은 행의 `scratchDir`에서 witness dir을 유도하며(re-`mktemp` 금지, 부재 시 fail-closed), 정상 워크플로우 완료 시 종결 행(`done`·`aborted`) 전부에서 strip한다(`_common/team-cleanup.md`에 path-guarded `rm -rf` + per-row strip 추가). out-of-tree 배치로 two-command 경계 게이트를 자명하게 만족한다.
- **6개 스킬 per-skill 파라미터**: 각 스킬 팀-spawn 지점에 `cc-team-witness-<slug>` witness dir `mktemp`·witnessed 라운드/단계를 명시한다. `design`은 fidelity(`{role-slug}.fidelity.md`)·walkthrough·refinement fresh-팀 단계를 명시적으로 witnessed로 지정하고, `design-analyze`는 in-tree `work.json`과 out-of-tree witness dir의 직교성을 명시한다. 계약은 `agent-team-protocol.md` 단일 SOT에 두고 6개 스킬은 파라미터만 공급하므로 신규 lint phrase·PAIR가 없다.

### Why

근본 원인은 6개 팀 기반 스킬이 공유하는 완료-신호 계약이 드롭 가능한 통지 + ephemeral 반환에만 의존하는 것이다. 통지가 드롭되면 lead가 무한 park 하거나 미관측 산출물을 합성(날조)한다. `design-review`는 durable on-disk floor(`review_log.md` per-round witness)를 이미 보유해 #47에서 국소 수정됐으나, 팀 토론 스킬은 팀원 라운드 산출물이 ephemeral 반환 텍스트뿐이라 per-round on-disk floor가 부재했다. universal witness가 그 floor를 모든 팀 스킬에 일반화한다.

## [1.18.3] - 2026-06-22

`design-review`·`design-review-lite`의 detect-branch ASYNC 경로에 대한 코드 리뷰 v2 잔여 발견 4건을 반영한다. prose under-specification을 봉합하는 터치업으로 동작 의미는 불변이며, base↔lite 편집 라인은 character-identical을 유지한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- **witness-absent respawn 절 self-contained화**: ASYNC stall death predicate의 respawn 절이 `reentry_count` 리셋만 명시하던 것을, `last_output_bytes`도 ∅로 리셋함을 명시해 죽은 spawn의 byte-count가 새 spawn으로 이월되는 여지를 제거한다.
- **"Soft liveness signals" dangling term 봉합**: witness-absent bullet의 "Soft liveness signals"가 정의 없이 쓰이던 것을 정의 구절(`output_file` growth · early-wake notification)로 보강한다.
- **ASYNC envelope 위치 힌트 보강**: ASYNC 마커 envelope 기술에 비-바인딩 "typically leading" 위치 힌트를 추가해 SYNC envelope-tail 앵커와의 대칭을 명확히 한다. 분류 게이트는 envelope containment 그대로이며 위치는 매치 조건이 아니다.
- **malformed-async 종단 dead-end 봉합**: 마커는 emit됐으나 agentId·output_file 양쪽이 파싱 불가한 극히 드문 손상 케이스가 에이전트를 미정리·라운드 미기록으로 남기던 liveness dead-end를, 동일 `inner_round` respawn(stop할 agentId 없음 → failed spawn 취급)으로 봉합한다. 기존 first-round-N-witness-wins dedup이 untracked-zombie 이중 append를 처리하므로 안전하며, Neither 분기에는 일반화하지 않는다.

## [1.18.2] - 2026-06-21

`design-review`·`design-review-lite`의 detect-branch 구현에 대한 코드 리뷰 발견 항목을 처리해 ASYNC 경로의 안전 임계 술어를 정량화·하드닝한다. 안전 임계 불변식의 정본 1부를 컴팩션 재부착 우선순위가 높은 Control-Flow Invariants 섹션에 두고 Step 12.detect는 정본을 가리키는 pointer만 유지하는 단일권위 원칙으로 정리한다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- **witness-absent 사망 판정 정량화**: ASYNC 라운드 에이전트의 사망 선언을 `reentry_count`(K=3) AND `## Review Round N` witness 부재 AND output_file byte-count 불변(또는 부재) 3개 conjunct로 확정하고, re-entry 단위(한 turn yield-and-return 사이클)와 byte-count 판정 절차를 명문화한다. byte-stability conjunct 누락 금지 fence를 추가해 active-writer를 죽이는 경로(`review_proposals.md` torn-write)를 차단한다.
- **분류기 envelope-anchoring + overlap 우선순위**: SYNC/ASYNC 마커(`<usage>…</usage>`·`output_file:`·`Async agent launched successfully.`)를 tool-result envelope 위치에서만 매칭하도록 강화해 에이전트 본문 토큰이 분류를 오염시키지 못하게 하고, 두 시그니처가 함께 나타나면 ASYNC 우선을 명시한다. CFI SYNC 정의에도 envelope-scoped AND-NOT 배제조건을 추가해 컴팩션 후 오분류를 차단한다.
- **Neither 모순 제거 + malformed-async 분리**: Neither 분기(async 마커 부재)가 배제된 필드를 복구한다던 내부 모순을 제거(소비 불가 → 에러 표면화)하고, envelope 마커는 있으나 agentId/output_file 파싱이 불가한 경우를 별도 malformed-async 분기로 분리해 ASYNC floor 경로로 라우팅한다.
- **단일권위-in-CFI 정리**: referent 없는 역사적 서술(TaskGet status-query·handle-binding mis-route) 제거, fail-closed 제목의 모호성 제거, N 자가도출 불변식과 라운드 경계 ordering을 CFI 단일권위로 통합하고 Step 12.detect는 cross-ref로 축소한다. `run_in_background: false` 문구를 hint 의미로 명확화한다(base 전용).
- **CI 실패 해소**: `scripts/lint-skill-invariants.sh`의 `REQUIRED_PHRASES` 9번째 phrase에 대응하는 문장이 `T-INV-OK-1` 픽스처에 누락돼 `make test`가 실패하던 것을, 양 픽스처에 문장을 추가해 해소한다. phrase 추가 시 픽스처 동반 갱신 의무를 lint 주석으로 문서화한다.

## [1.18.1] - 2026-06-21

`design-review`·`design-review-lite`의 inner 루프(Step 12)가 라운드 리뷰 에이전트의 완료를 비동기 통지(push)에만 의존해 대기하다가, 통지가 중복·누락·오라우팅될 때(다수 upstream 하네스 버그로 실증) 메인 세션이 완료를 관측하지 못한 채 무한 park 하는 liveness stall을 제거한다. 커밋된 Step 12는 spawn 방식(foreground/background)을 강제하지 않아, 실행 모델이 백그라운드로 처리하면 라운드 완료의 유일한 관측 채널이 드롭 가능한 통지가 됐다. detect-branch hybrid로 두 환경을 모두 커버한다 — 동기 반환이면 inline 소비, 비동기 launch면 통지를 무시하고 온디스크 witness로 능동 확인 (`/plugin update cc-cmds`로 자동 반영). [#47]

### Fixed

- **`design-review`·`design-review-lite` inner 루프 통지-드롭 stall**: Step 12에 detect-branch 분류를 추가한다. spawn tool result를 SYNC(`<usage>…duration_ms…</usage>` tail)·ASYNC(`output_file:`/`Async agent launched successfully.`)·Neither(소비 불가)로 양면 positive 분류해, SYNC는 inline 결과를 그대로 소비(비용 0)하고 ASYNC는 통지 대신 `review_log.md`의 `## Review Round N` 온디스크 witness로 완료를 능동 확인한다. witness 부재 시 기본 대기 유지 → bounded 소진 후 `TaskStop` + 동일 `inner_round` respawn, first-round-N-witness-wins dedup으로 좀비 중복 witness를 무해화한다. `run_in_background: false`는 요청으로만 전달하고 통지 채널 부재를 단정하지 않는다.
- **anti-fabrication precondition 양 분기 재근거화**: Observed-result precondition을 SYNC(구조적 inline 관측)·ASYNC(에이전트 단독 작성 `## Review Round N` witness — 유일 anti-fab anchor)로 확장하고, fail-closed 사다리(통지 도착·`review_proposals.md` 존재·witness 부재 불인정)와 ASYNC no-look-ahead ordering을 명시한다. `scripts/lint-skill-invariants.sh`의 `REQUIRED_PHRASES`에 `round-N summary line in review_log.md`를 추가(8→9)해 base↔lite witness-gate 절 sync를 강제한다.

### Why

근본은 공유 채널(`agent-team-protocol`의 드롭 가능한 완료 통지)이고 6개 팀 기반 스킬이 모두 노출되나, `design-review`/-lite는 durable 온디스크 floor(`review_log.md` per-round witness)와 저렴한 stateless respawn을 보유해 국소 fix가 가능하다. 통지를 아예 조회하지 않으므로 드롭·중복·오라우팅이 구조적으로 무의미해진다. 나머지 팀 스킬 전반의 일반화는 별도 추적한다. [#49]

## [1.18.0] - 2026-06-19

`claude-context`·`sequential-thinking` 두 MCP가 사용자 도메인의 코드 검색/추론에서 grep/native 대비 효용이 없음이 선행 검증에서 확정되어(중형 레포 2.47×·초대형 3.85× 토큰 손해, recall uplift 0, sequential은 Opus native 추론으로 redundant), 두 MCP를 모든 스킬 surface에서 제거한다. `review`·`design-analyze`의 코드 grounding은 기능(팀원이 소스를 직접 탐색해 주장을 grounding)을 보존한 채 도구만 claude-context 인덱싱(index→poll lifecycle)에서 grep/Glob/Read 직접 탐색으로 교체한다. `context7`·`figma` MCP는 유지하며, 슬래시 커맨드 시그니처는 불변이다 (`/plugin update cc-cmds`로 자동 반영).

### Changed

- **`review`**: Step 2a를 "Source tree survey"로 재작성한다 — Claude Context MCP 인덱싱·`get_indexing_status`·`index_codebase`·poll lifecycle을 제거하고 `ls`/CLAUDE.md/.gitignore 확인 + skip-dir 목록 + `Glob`/`Read` 오리엔테이션으로 대체한다. 코드 재확인·grounding mandate·역할별 체크리스트의 검색 가이드를 grep/Read verb로 전환한다.
- **`design-analyze`**: Step 2를 "Grounding Setup"으로 재작성하고(인덱싱·poll 제거, `grep`/`Glob`/`Read` 직접 grounding), CFI-4 degrade의 indexing-error arm을 inaccessible CODE_ROOT로 일반화한다. grounding ON/OFF 게이트(`--no-codebase`)·doc-only 동작은 불변이다.
- **컨텍스트 패키지**: reviewer 패키지(15→16-item)와 analyst 패키지에 skip-glob 목록(`node_modules`·`.next`·`dist` 등)을 주입한다 — 팀원이 직접 grep할 때 vendored/generated 트리로 토큰 예산을 소진하는 것을 방지한다.
- **lite 3종(`review-lite`·`design-lite`·`design-review-lite`)**: 두 MCP를 명시하던 죽은 금지문구(서버 제거 후 moot)를 제거한다. `_common/team-upgrade-analysis.md`의 generic "no MCP" fence는 특정 서버를 명명하지 않으므로(context7·figma 포함) 유지한다.
- **`design-apply`**: Sequential Thinking·Claude Context MCP 허용 문구를 제거한다(context7 MCP 문구는 유지).

### Removed

- **`claude-context`·`sequential-thinking` MCP**: 두 MCP 서버를 모든 스킬 surface에서 제거한다.

## [1.17.1] - 2026-06-17

검증 V/R 항목 필드 라인의 markdown 렌더링(선행 불릿 `- ` 유무, `**…**` bold 유무)이 `_common/verification.md` 스키마에 미고정이어서, 손으로 작성된 설계 문서가 `**검증 등급**: …`·`- 검증 등급: …`·`- **잔여 사유**: …` 등 3가지 비호환 형태로 발산했다. 반면 `implement`의 W1 flip·snapshot-diff gate와 탐지 문법은 단일 형태(`**key**: value`)만 가정해, `design-review`가 well-formed로 판정한 잔여 항목이 `implement`에서 flip 불가가 되는 비호환이 있었다(#41에서 관측). 정규 형식 `**key**: value`(bold·비불릿·콜론 뒤 공백 1)를 SOT에 고정하고, 탐지·읽기는 4변형을 모두 흡수하는 관용 ERE로, `implement` flip gate는 비대칭(removed tolerant / added strict-canonical)으로 하드닝한다 (`/plugin update cc-cmds`로 자동 반영). [#44]

### Fixed

- **`implement` 잔여 항목 flip 비호환**: W1 flip의 lookup과 snapshot-diff gate의 removed-side regex가 bold·비불릿 단일 형태만 매치해, 불릿/bold없음으로 렌더된 legacy 잔여 항목을 flip하지 못하거나 gate가 false-fail했다. lookup·removed-side gate를 4변형을 모두 흡수하는 관용 balanced-bold ERE로 교체한다. added-side gate는 strict-canonical을 유지해 `implement`은 항상 정규 형식만 출력하며, 닿은 legacy 라인은 한 줄씩 정규 형식으로 수렴한다(미접촉 라인은 마이그레이션하지 않음).

### Changed

- **`_common/verification.md` (SOT)**: 정규 라인 형식 `**key**: value`(bold key·선행 불릿 없음·콜론 뒤 ASCII 공백 1)를 명문화하고, V/R 블록에 byte-for-byte 복제용 렌더링 예시 블록을 추가한다. 탐지 문법을 관용 balanced-bold ERE(`^(- )?(\*\*<key>\*\*|<key>): <value>$`, `grep -E`)로 교체하고 탐지=관용 / flip-gate=strict 비대칭을 명시한다. "enumeration ≠ rendering" 주석을 추가하고, well-formedness 술어에 "line 렌더링은 malformedness 축이 아님"을 명시한다.
- **`implement`**: per-flagged-item non-empty-diff assertion을 추가해 조용한 no-op flip(빈 diff vacuous-pass)을 구조적으로 차단하고, 1.5a idempotency skip을 관용 idiom으로 교체하며, flip·gate에 perl 금지 및 `grep -E`/`sed -E` 사용을 명시한다.
- **emitter (`design`·`design-lite`)**: V/R 필드 라인을 SOT의 CANON 예시에서 byte-for-byte 복제하도록 지시한다(자체 불릿/bold 스타일 선택 금지).
- **checker (`design-review`·`design-review-lite`)**: fix를 Edit로 적용할 때 V/R 필드 라인의 정규 형식을 보존하는 form-preservation fence를 추가하고, 리뷰 criterion에 비정규 렌더링 경고(severity trivial, 이번 라운드 편집 라인 한정)를 추가한다.

## [1.17.0] - 2026-06-17

CC 2.1.178이 `TeamCreate`/`TeamDelete`를 제거하고 세션당 단일 암묵 팀으로 전환하면서 동작 불가가 된 에이전트 팀 스킬군(`design`·`design-lite`·`design-analyze`·`design-apply`·`review`·`review-lite`)을 **Model B(nameless background task)**로 재작성한다. 팀원은 `Agent`(`subagent_type:"claude"`, name 없음) 백그라운드 task로 spawn되어 lead가 agentId로 라운드마다 resume 구동하고, 작업 완료 시 task가 자기-종료한다(정리 절차 불필요). task의 return text가 곧 결과 전달 채널이라, 기존 named 팀원의 `[COMPLETE]`/idle 완료신호 모호성과 종료 핸드셰이크가 구조적으로 소멸한다 (`/plugin update cc-cmds`로 자동 반영). [#41]

### Why

CC 2.1.178+에서 모델이 spawn할 수 있는 것은 background subagent뿐이고, named 팀원은 구조화 shutdown 프로토콜을 보낼 수 없어 **프로그램적으로 종료 불가** — 매 spawn마다 un-killable 좀비가 누적되고 사용자가 수동으로 정리해야 했다. 깨진 기능 복구(hotfix)지만 단순 패치가 아니라 새 메커니즘(컨텍스트 재주입·role↔agentId 원장·per-task 알림)을 도입하므로 MINOR로 bump한다. 슬래시 시그니처·옵션은 불변이다.

### Changed

- **`_common/agent-team-protocol.md` 재작성** (96→~55줄): named-teammate 완료신호/방어 머신(`[COMPLETE]`/`[IN PROGRESS]` 프리픽스·idle-vs-DM·hard prompt·`ip_count`/`remediation_count`·Bound A/B/C)을 들어내고 nameless task lifecycle + 라운드 오케스트레이션으로 교체한다. spawn(nameless `Agent`)·완료신호(return text)·다라운드(resume + 컨텍스트 재주입)·convergence(return 수집)·teardown(자기-종료, abort=`TaskStop`)·escalation·role↔agentId 원장·task-assignment 헤더로 구성.
- **`_common/team-cleanup.md` → stub** (57→~10줄, 동일 경로): `shutdown_request`→`TeamDelete`→`ps aux` 절차 전체가 non-functional fiction이므로 stub으로 축소한다. 정상완료=무동작 / abort=running agentId `TaskStop` / 원장 hygiene.
- **6개 SKILL.md Step 0 도구 로딩**: `TeamCreate`/`TeamDelete` 로드 제거 → Model B 도구셋(`AskUserQuestion`·`SendMessage`(agentId resume)·`TaskStop`(abort); `Agent`는 빌트인이라 로드 불요).
- **escalation 재설계**: named A/B/C 레터링을 Model B 실패 표현형으로 교체 — Case 1 thin-return stall(카운터, 2연속→`AskUserQuestion`) / Case 2 never-returns(`TaskStop`+재spawn) / Case 3 non-conforming return(1회 재배정). 채널 위반(Bound A)·dispatch 실패(Bound C) bound는 트리거 불가능해 구조적 삭제.
- **reference 패키지 2종**: `review/references/01-reviewer-context-package.md`·`design-analyze/references/01-analyst-context-package.md`의 `[COMPLETE]` 컨버전스·named coordinator를 return-text 기반으로 재작성.
- **README Prerequisites**: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 환경변수 요구를 제거하고 "Claude Code 2.1.178+ 필요"를 명시한다(Model B는 일반 `Agent` 도구만 사용하므로 실험 플래그 불요).
- **`scripts/lint-skill-invariants.sh` EXEMPT rationale**: agent-team 스킬 면제 근거를 "termination contract in `team-cleanup.md`"에서 "자기-종료 + 디스크 복구 원장" 근거로 갱신(로직·`EXEMPT_SKILLS` 배열 불변).

### Added

- **role↔agentId 원장(durable ledger)**: roster-less 모델에서 compaction으로 agentId가 증발하는 것을 막기 위해 스킬별 기존 아티팩트에 co-locate한다 — design-family는 `docs/{slug}.md` 상단 HTML-comment 블록(`<!-- cc-design-ledger v1 ... -->`), design-analyze는 `.{slug}.work.json`의 `"ledger"` 키. behavior-bearing 스키마(agentId + 역할/스코프 + state + round + 최근 return 요약), resume phase 진입 시 디스크 재독, 누락·파싱불가 시 fail-closed `AskUserQuestion`. 잔존 `state=running` 행이 곧 leftover 감지 신호(삭제된 `teams/` scan 대체)다.
- **컨텍스트 재주입**: resume 시 lead가 load-bearing 컨텍스트를 매번 재주입하고 peer 발견을 verbatim 인용한다(retained context를 load-bearing 데이터에 신뢰하지 않음).

### Post-install notes

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 환경변수는 더 이상 필요 없습니다(설정해 두어도 무해). Claude Code 2.1.178 이상에서 동작하며 구버전은 지원하지 않습니다.

## [1.16.1] - 2026-06-09

`design-review`가 inner-loop 리뷰 에이전트를 spawn할 때 리뷰 모델이 실행마다 비결정적으로 선택되던 문제를 고친다. 근본 원인은 상속 실패가 아니라 Step 12 spawn 지시가 underspecified라는 것 — `Agent()`에 `model`을 비우면 하네스 부모 상속이 건전하게 작동하지만, 스킬이 아무 지시도 없어 오케스트레이팅 메인루프가 일부 spawn에 `model` override를 임의 주입한다. 리뷰 모델을 **세션 모델 상속(inherit)**으로 고정해, 리뷰 깊이·비용이 사용자의 세션(=비용) 선택을 결정적으로 추적하도록 한다 (저비용 플랜 사용자에게 opus 하드핀은 매 실행 큰 초과비용이었다). 범위는 `design-review`만이며 `design-review-lite`(sonnet 하드핀)는 불변이다 (`/plugin update cc-cmds`로 자동 반영).

### Fixed

- **`design-review` Step 12 리뷰 에이전트 모델 비결정성**: 리뷰 에이전트 `Agent()` 호출이 `model` 파라미터를 **반드시 생략**하도록 omit+bind 지시를 추가한다. 생략 시 하네스 부모 상속이 세션 모델을 그대로 물려받아 세션 내 결정적이며, 세션 모델을 명시적 리터럴로 주입하는 것을 금지해(sonnet/haiku 메인루프가 자기 티어를 명시 주입하는) 역방향 drift를 차단한다. 이 bind는 prose로만 강제하며, 향후 리터럴 주입 재개 잔여 drift 리스크는 위임-판단-잔여 norm에 따라 명시 수용한다(상시 모니터링 hook 미설치).

### Changed

- **haiku 가시성 best-effort notice**: 세션 첫 리뷰 에이전트 spawn 직전, 메인 세션이 자기 세션 모델을 haiku로 판단하면 세션당 1회 한국어 prose 1줄을 emit해 "터미널 설계 게이트가 haiku로 실행 중 — 발견이 얕을 수 있음(sonnet/opus 세션 재실행 권장)"을 알린다. floor(동작 변경)가 아니라 정보 제공이며 self-ID 의존 best-effort라 미발화는 현상유지(benign)다. haiku는 명시 선택으로만 도달하므로 대상은 항상 cheapest를 의도 선택한 사용자다.
- **`## Constraints` 상속 정책 1줄**: 리뷰 에이전트가 세션 모델을 상속한다는 정책을 Constraints에 재기술한다(`design-review-lite`의 sonnet 하드핀 constraint와 대칭 — full은 티어를 고정하지 않고 상속).

## [1.16.0] - 2026-06-08

`design` 스킬 Step 4에 **synthesis fidelity pass(충실도 점검)**를 도입한다. 리드가 모든 토론을 압축해 문서를 작성하는 과정에서 발생하는 누락·왜곡·약화는 원본 컨텍스트 보유자(팀원)만 잡을 수 있고, 저장 직후 team-cleanup으로 컨텍스트가 소실되면 다운스트림 `design-review`가 원리적으로 감지하지 못한다. 따라서 cleanup 이전·pre-save sweep 직전의 살아있는 Step 3 팀으로만 가능한 고유 검사를 추가해 합성 충실도 결함 클래스를 메운다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **`design` Step 4 synthesis fidelity pass**: 전체 초안 합성 직후·pre-save sweep 직전, 살아있는 Step 3 팀(전문 에이전트 포함)에게 전체 초안을 전달해 각자 **자기 기여만** 충실도 점검한다. 충실도는 2개 클래스 — 해석적(accounted-for: 채택 또는 근거있는 기각) / 전사적(`근거 등급`·`검증 등급` verdict의 byte-identical 또는 flag, grade/verdict one-way 전파를 처음으로 실제 강제). discrepancy는 `[COMPLETE]` body의 block(`omission`/`distortion`/`grade-distortion`/`decision-reopen`)으로 회신하고, 리드는 "수렴된 결정과 모순되는가" 단일 테스트로 라우팅한다 — NO는 즉시 Edit으로 canonical SOT에 복원, YES는 기존 1-cycle re-convergence 재사용. restore-never-re-grade(broadcast에 있는 값만 복원, read-only 점검은 새 grade earn 불가)로 전문가의 의견 laundering을 차단한다.
- **무응답·가시성·제외 처리**: 무응답은 기존 `_common/agent-team-protocol.md`의 채널-liveness 머신(remediation_count/Bound A·ip_count/Bound B)을 재사용하되 H1/H2 가드(단일 정적 구간 no-delivery 추론 금지, 유효 DM 도착 시 Bound-A escalation 자동 취소)와 fidelity-scope Bound A/B 프롬프트 재서술을 더한다. clean pass는 문서·사용자 채널 모두 무흔적(on-entry 통지 제외)이며, Bound 옵션-(a) 제외는 문서 metadata 표기 대신 기여자당 1회 ephemeral emit으로만 공개("no silent caps"). 새 카운터·새 control-flow·새 `##` 헤딩 없음.
- **`design-lite`**: fidelity pass는 lite에서 비활성(예산 모드) — disabled-note 한 줄 추가.

## [1.15.0] - 2026-06-08

`design` 패밀리 산출물에 산재하던 **"구현 시 검증 필요" 이연(deferral)을 제거하는 세션 내 검증(in-session verification) 매커니즘**을 도입한다. 핵심 원칙은 — 검증 실패는 곧 설계 변경을 의미하므로, 세션 안에서 검증 가능한 클레임은 설계 세션에서 검증하고(검증 ledger에 기록), 진짜 구현 시점에만 판정 가능한 잔여 클레임만 구조화 인코딩으로 남겨 `implement`가 구현 시작 시점에 fail-fast로 소비한다. 검증 가능한 클레임을 구현까지 미루면 잘못된 설계 위에 구현이 쌓이는 문제를 차단하기 위함이다. 어휘·스키마·실행 메커니즘의 단일 SOT로 `_common/verification.md`를 신설하고, 방출자(`design`·`design-lite`)·검사자(`design-review`·`design-review-lite`)·소비자(`implement`)가 이를 인용한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **`_common/verification.md` 단일 SOT**: 5범주 클레임 분류 체계(정적 사실/실행 측정/외부 환경/행동 가설/미니 구현)와 (e) 라우팅의 α∧β 진입 조건, 중대성 사전 필터 + 단일 필터 테스트, 동결 검증 어휘(등급 5토큰·`잔여 사유` 4값·`실행 주의` 4클래스·`분류` 5범주·`검증 시점` enum), key-anchored 풀라인 탐지 문법(`미검증` 부재증명 예외 포함), 검증 ledger(`### V<n>`)·잔여 항목(`### R<n>`) 스키마, 격리 워크트리 메커니즘(`mktemp` + `--detach`, in-worktree 금지 잠금, final-run 규칙, 분리불가 리셋 라인), well-formedness predicate, 3-rung 드리프트 래더, 변환 무브를 contracts-only로 담는 어휘·계약의 단일 출처다.
- **검증 ledger + 잔여 섹션** (`design`·`design-lite` 산출물): 수행된 검증을 `## 검증 기록`(`### V<n>`)에, 진짜 구현 시점 전용 잔여 클레임을 `## 구현 시 검증 항목`(`### R<n>`)에 기록한다. 두 섹션 모두 무번호 heading이라 미해결-이슈 walkthrough 파스 regex에 비매칭이고, 비어있으면 생략된다. 본문 클레임은 토큰 없는 anchor(`(§검증 기록 V<n>)` 등)로만 마킹해 재검증 시 stale-태그 발산을 차단한다.
- **`implement` Step 1.5 write-deferred 검증 게이트**: 구현 시작 전 잔여 항목을 발견·분류(read-only, 터미널 토큰 멱등 스킵)하고, (c) 외부 probe·(e) 워크트리·예외 클래스 항목은 일괄 동의 게이트 후 실행하며, verdict는 메모리에 보유했다가 plan 승인 후 Step 3에서 정확히 2개 쓰기 표면(W1 등급 플립 + W2 기록 라인)을 스냅샷-diff 게이트로 일괄 기록한다. 반증/드리프트 verdict는 STOP + 한국어 보고 + 3옵션 AUQ로 surface하며 implement는 재설계하지 않고 사용자가 라우팅한다.
- **`design-review` 검증 차원(criterion #7)**: 리뷰 에이전트가 검증 북키핑을 읽기만으로 검사(CHECK)하고 실행(RUN)은 메인 세션이 수행하는 구조. cat-1 자유 self-run / cat 2–4 폐쇄 3옵션 메뉴(`지금 검증 실행`/`잔여 항목으로 기록`/`거부 (현재 유지)`) / cat-5(워크트리) 재실행 금지로 라우팅하며, `## Verification Runs` 실행 메모로 (anchor, hash) 중복 제안을 차단한다. cat-1 self-run은 독립 카운터 `[VERIFY-RAN]`로 집계되어 외부 종료 술어에 한 항을 더해 fresh-agent ripple-verify를 보장한다(`escalate_applied` 합·itemize 렌더 무영향).
- **검증 동결 리터럴 일관성 lint** (`scripts/lint-verification-literals.sh`): SOT의 동결 검증 어휘가 두 리뷰 사본(`references/06`·`design-review-lite`)으로 발췌·인라인되며 토큰 rename이 한쪽에만 반영되는 drift를 CI에서 차단한다. SOT 완전성(whole-file presence) + 공유 리터럴의 리뷰 에이전트 프롬프트 블록 영역 한정 검사(`lint-skill-invariants.sh` rule B 패턴 차용) + fixtures·test로 구성되며 `make lint`/`make test`에 배선된다.

### Changed

- **`design`/`design-lite` 방출자 확장**: Step 1 검증-우선 노트(싼 (a)/(b) 인라인 검증·검증 프로파일 플래그), Step 2 선택 검증 에이전트 역할(base), Step 3 Verification discipline 단락 + Quality Gate Verification addendum, Step 4 pre-save sweep(`미검증` 0건·anchor 미참조 검증가능 클레임 0건·2-커맨드 워크트리 게이트). `design-lite`는 cat 1–4 생존(cat-4 one-shot)·cat-5 드롭(`/cc-cmds:design` 리다이렉트)·실행 예산 6유닛(2/2/2, ≤2분/유닛, ≤12분 상한)으로 비용을 한정한다.
- **재현 carve-out → 관측·검증 carve-out 일반화** (`design` Constraints): 기존 재현 carve-out을 "Observation & verification carve-out"으로 병합·일반화하고 "modification" 정의를 **세션 메인 워킹 트리에 지속되는 변경**으로 rescope한다. 단일 `git status --porcelain` 불변식을 **2-커맨드 경계 게이트**(porcelain + `git worktree list --porcelain` + `cc-design-exp-` prefix 0건)로 대체해, 격리 워크트리가 메인 porcelain에 비가시인 블라인드 스팟을 닫는다. 표면1(메인 트리: 재현 + 범주 a/b/c/d)·표면2(격리 워크트리 (e) 전용)로 스코프를 분리하며 기존 두 "NO code modifications" 리터럴은 그대로 보존한다.
- **`implement` no-modify 규칙 정밀화**: "설계 문서 수정 금지" 리터럴을 유지하면서 W1/W2를 문서가 implement에 예약한 정확히 2개의 쓰기 표면으로 열거하고, 스냅샷-diff 게이트로 그 외 변경을 fail-loud 차단한다(`git diff` 금지 — untracked·dirty 문서에서의 오판·파괴 방지).
- **`design-review`/`design-review-lite` 검사자 동기화**: 리뷰 criterion을 6→7로, PROP `Type`/`Category` enum에 `verification`/`verification-bookkeeping`을 추가하고, Self-Triage에 `Type: verification` 전용 분기·closed option set 제3 source·Disposition 처분 매핑을 넣는다. lite는 0-Read 아키텍처를 보존하며 문법을 인라인하고 재실행 예산 6을 `## Verification Runs` 라인 수에서 파일-복원한다. `references/04`에 `## Verification Runs` 스키마, `references/06`에 criterion #7 발췌(SOT provenance 포함)를 추가한다.

## [1.14.0] - 2026-06-05

`/cc-cmds:design` 스킬에 **재현 우선(reproduction-first) 매커니즘**을 얹는다. 이슈·버그 수정을 설계할 때 팀이 실제 현상을 재현해 확인하지 않고 코드만 읽어 근본 원인을 추측하는 경향을 막기 위해, 재현 가능한 이슈는 **먼저 재현 → 근본 원인 확정 → 그 위에서 수정 방향 토론**하도록 유도하는 위임된 판단 기반 품질 레이어다. 경직된 상태기계가 아니라 prose 가이드로 추가되며(CFI 아님), "재현할지·누가 할지"는 리드/에이전트 자율 판단에 맡긴다. 적용 범위는 `design` 단독이며 `design-lite`·나머지 패밀리는 범위 밖이다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **재현 우선 매커니즘** (`design` 한정): (1) 두 개의 재현 위치 — 리드 주도 Step 1 "execution by reproduction" 모드와 에이전트 주도 Step 3 Round 0(재현 그라운딩 패스, 최소 2라운드 미산입); (2) 단일 필터 테스트("과제가 기존 코드 오동작을 주장하며 그 오동작이 기존 앱/테스트 실행으로 관측 가능한가?")로 재현 시도 여부 게이팅; (3) 재현 시 4 데이터 포인트(`재현 절차`/`관측된 증상`/`근본 원인`/`재현 차단요인`) + 이진 `근거 등급`(`확인됨(재현·관측)`|`가설(추측)`) 방출; (4) 이슈·버그 과제 한정 문서 최상단 `## 재현·근본원인` 섹션(재실행 가능 recipe, `근거 등급` SOT); (5) 2단 폴백(Tier-1 사용자 협조 → Tier-2 가설 명시 + Step 4 UR 포인터 생성)으로 재현 실패를 Step 5 워크스루에서 의식적으로 surface.
- **재현 카브아웃 (running ≠ modifying)** (`design` Constraints): "modification" = 워킹트리에 persist된 변경으로 정의해 수정 없는 앱/테스트 실행은 금지 대상이 아님을 명시(예외가 아니라 정의 — 기존 두 리터럴 "NO code modifications" 문자열은 그대로 보존). 모든 재현 아티팩트·로깅은 out-of-tree(`/tmp` sink·기존 verbosity)로 라우팅하고, 모든 팀-토론 경계에서 `git status --porcelain` == pre-workflow baseline을 단일 검증 게이트로 두며, findings가 producer를 떠나기 전 정리·검증을 강제하는 cleanup 경계와 env-vs-tree/lockfile 체크리스트를 포함한다.

### Why

재현 규칙을 CFI(turn-yield/auto-advance 전이 규칙)가 아니라 품질 규칙(body prose)으로 둔 것은, summarize away되더라도 silent mis-transition이 아니라 "추측으로 회귀"하는 품질 저하로만 나타나는 성격 때문이다. `근거 등급`을 `## 재현·근본원인` 섹션 한 곳에서만 계산(SOT)하고 다른 위치는 참조만 하게 한 것, UR 포인터가 `근거 등급`을 보유하지 않게 한 것은 Step 5 워크스루의 파싱·상태기계와의 충돌 및 등급 divergence를 막기 위함이다.

## [1.13.0] - 2026-06-04

`/cc-cmds:review` Step 3 리뷰어 구성을 분석하는 **모델·역할 두 축 second-opinion 스킬 `review-upgrade`를 신설**한다. `design-upgrade`가 `/design` Step 2를 분석하는 것과 정확히 대칭으로, 직전 `/review` Step 3 구성에서 (a) opus 강점이 유의미한 리뷰어의 opus 승격, (b) 누락된 리뷰 관점을 메우는 신규 리뷰어 추가, (c) 과부하 리뷰어 분할을 짚어준다. 이를 위해 `design-upgrade`가 인라인으로 보유하던 두 축 강화 로직을 repo 최초의 **파라미터화된 `_common` 코어**(`_common/team-upgrade-analysis.md`)로 추출하고, `design-upgrade`를 그 소비자로 리팩터(동작 동등)한 뒤 `review-upgrade`를 두 번째 소비자로 얹는다. 이름·zero-arg·`disable-model-invocation: true`·"직전 제안이 컨텍스트에 있어야 동작"하는 성격과 "강화가 유의미할 때만 제안, 그 외엔 유지 사유"라는 절제 원칙을 `design-upgrade`와 대칭으로 보존한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **`review-upgrade` 신규 스킬**: `/review` Step 3 리뷰어 구성을 모델·역할 두 축으로 분석하는 `disable-model-invocation: true` zero-arg second-opinion. 역할 축은 미커버 **리뷰 관점**(security/performance/code-quality/logic/error-handling/type-safety/testing/api-contract/concurrency/data-integrity)을 대상으로 하며, Step 3의 risk-indicator→reviewer 매핑(auth→security, DB→perf/DB, public-API→API-contract, external→security+integration, async→concurrency)을 커버리지 계약으로 화해해 ADD를 4조건 ALL 충족 시에만 발화한다(diff 신호 + 누구도 미소유 + 발화된 indicator로 미라우팅 + 기존 체크리스트 미흡수). 과부하 리뷰어 SPLIT은 정량 증거(파일수·diff 크기)로 게이팅하며 `PARTITION` 무손실·무중복 계약을 둔다. OPERATION 태그(UPGRADE/ADD/SPLIT-REPLACE[/ADD-Coordinator])는 `역할 | 모델 | 담당 범위` 순서로 emit해 `/review` 재제안 입력으로 모호함 없이 paste-back된다. precondition 부재 시 3-path fallback: (1) 세션 로스터 붙여넣기→완전 두 축(재투입=Step 3 재제안), (2) 저장 리뷰 리포트 역산→모델 UPGRADE·관점 ADD 복원하되 정량 SPLIT·ADD-Coordinator는 suppress(재투입=Step 6 팀 재생성, augmented 필드로 매핑), (3) 둘 다 없으면 한국어 안내 후 종료.
- **`_common/team-upgrade-analysis.md` 파라미터화된 코어**: repo 최초의 파라미터화된 `_common` 파일. 축-불문 두 축 알고리즘(Scope·절제 원칙·4단계 역할-갭 탐지·HARD LIMIT·절제 게이트·분할 게이트·OPERATION 구조·기존-역할당 OPERATION 1개 불변식·교차축 synthesis·degraded-axis 처리)을 리터럴 `{PLACEHOLDER}` + 3-채널 주입 인터페이스(`## Bindings` 값 치환 / `## Operations Layer` 규칙 append seam / 주입 prose)로 담는다. 기존 self-contained `_common`과 달리 소비 스킬의 `## Bindings`로 placeholder를 resolve해야 구체 계약이 된다.

### Changed

- **`design-upgrade/SKILL.md` 코어 소비로 리팩터**: 인라인 두 축 로직을 코어 self-read + `## Bindings`(design 값)로 치환하고, 주입 prose(Precondition/design-lite 가드/sync-note/3-path Fallback)는 유지한다. frontmatter 불변(README row byte-동일) + 8개 결정 동작 동등. Path 2의 모델축 N/A 처리는 `{MODEL_AXIS_DEGRADES_UNDER}` 바인딩 경유로 코어 split gate·Cross-axis synthesis가 인지한다.
- **`review-lite/SKILL.md` reciprocal 상호참조**: sonnet-pin Constraints bullet에 review-upgrade의 두 축이 review-lite에서 out of scope이며 base `/cc-cmds:review`에 대해 `/cc-cmds:review-upgrade`를 쓰라는 out-of-scope 명확화 1줄을 추가(redirect 아님, design-lite의 design-upgrade 상호참조 미러). frontmatter 불변→README row 불변.
- **`scripts/lint-skill-invariants.sh` EXEMPT 확장**: `EXEMPT_SKILLS` 배열에 `review-upgrade`를 추가(single-pass·무팀·무카운터 second-opinion, design-upgrade와 동일 근거)하고 근거 doc-comment 인벤토리도 갱신한다(behavioral 무영향).

## [1.12.0] - 2026-06-04

`/cc-cmds:review` 리포트가 각 발견 항목 아래에 **GitHub에 그대로 붙여넣을 수 있는 정중체 코멘트를 기본 산출**하도록 확장한다. 지금까지는 발견 항목을 단정체 분석(근거/제안)으로만 기술해, 사용자가 PR에 코멘트를 달려면 매번 손으로 정중체로 옮겨 적어야 했다. 이제 P0~P2 항목은 분석 바로 아래에 `💬 붙여넣기용 코멘트` 블록쿼트를, P3 항목은 항목 한 줄 자체를 정중체·자기완결로 작성해 복사-붙여넣기만으로 인라인 코멘트를 게시할 수 있다. 코멘트는 Step 5에서 리드가 단독 작성하며(리뷰어 산출 포맷·컨텍스트 패키지는 무변경), 적용 범위는 `review` 한정(`review-lite` 제외) (`/plugin update cc-cmds`로 자동 반영).

### Added

- **붙여넣기용 코멘트 기본 출력** (`review` Step 5): P0~P2 발견 항목마다 분석(근거/💡 수정 제안) 아래에 `💬 붙여넣기용 코멘트` 블록쿼트를 둔다. 라벨은 블록쿼트 밖 평문, 블록쿼트(`>`)에는 붙여넣을 본문(`> **P{N}: 재진술.**` + `> **[근거]**` + `> **[제안]**`)만 담아 사용자가 블록쿼트만 복사하면 메타 라벨 오염 없이 그대로 게시할 수 있다. 제목은 산문만, 이슈 위치(`파일:라인`)는 `[근거]` 첫 언급에 두어 인라인·일반 PR 코멘트 양쪽에서 자기완결이다. 심각도별로 P0/P1은 근거·제안 필수, P2는 근거 필수에 `[제안]`은 분석에 `💡 수정 제안`이 있을 때만(분석에 없는 제안을 코멘트가 창작하지 않도록 게이팅), P3는 블록쿼트 없이 항목 한 줄이 곧 코멘트(줄 끝 `— 리뷰어명` attribution은 복사 시 제외)다. 기존 PR 코멘트를 확인만 하는 항목(`📎 관련 PR 코멘트` 보유)은 중복 코멘트 대신 한 줄 평문 노트만 두며, 블록쿼트 부재가 "새로 게시할 코멘트 없음" 신호가 된다. 비-PR 모드(로컬 diff/파일 경로)에서도 코멘트는 그대로 생성되어 PR 개설·커밋 메시지·이슈 등 어디든 이식 가능하다.

### Changed

- **`review` 리포트 템플릿·Step 5 갱신**: `references/02-review-report-template.md`에 신규 "Paste-Ready Comment Blockquote" 섹션(골격·톤 이중성·심각도 표·dedup 예외)을 추가하고, Document Structure 코드블록의 P0/P1/P2 항목에 `💬 붙여넣기용 코멘트` 앵커, P3 예시를 정중체·자기완결로, 개요 `발견 요약` 아래에 코멘트 관례 설명 1줄을 고정한다. `SKILL.md` Step 5에는 코멘트 생성·톤 이중성(분석=단정체/코멘트=정중체)·dedup 예외·P3 한 줄 정중체 규칙 문단과 신규 섹션을 지목하는 템플릿 Read 라인을 추가한다. `references/03-non-pr-mode.md`에는 비-PR 모드의 이식형 코멘트 생성을 1줄 명시한다. 리뷰어 컨텍스트 패키지(`01-reviewer-context-package.md`)는 lead-only 작성 결정에 따라 무변경이다.

## [1.11.0] - 2026-06-04

`/cc-cmds:design-upgrade`를 "모델 상향 단일 축" second-opinion에서 **모델·역할 두 축을 함께 추론하는 팀 구성 강화 분석**으로 확장한다. 기존 모델 승격(haiku/sonnet → opus)에 더해, 직전 `/design` 팀 구성에서 (a) 어떤 팀원도 소유하지 않은 누락 도메인을 메우는 신규 역할 추가, (b) 과부하된 광범위 역할 하나를 둘로 쪼개는 분할을 함께 짚어준다. 이름·zero-arg·`disable-model-invocation: true`·"직전 제안이 컨텍스트에 있어야 동작"하는 성격은 모두 보존하며, "강화가 유의미할 때만 제안, 그 외엔 유지 사유"라는 절제 원칙을 역할 축까지 대칭 확장한다 (`/plugin update cc-cmds`로 자동 반영).

### Changed

- **`design-upgrade` 두 축 확장**: SKILL.md 본문을 영문 프로즈·영문 헤딩(`Scope`/`Evaluation criteria`/`Output format`/`Cross-axis synthesis`/`Precondition`/`Fallback`)으로 재작성하고 frontmatter `description`·`when_to_use`·`notes`를 두 축 분석에 맞게 재프레이밍한다(사용자 대면 한국어 어휘 `현재 모델 → 권장 모델`·`변경 사유`/`유지 사유`·`기대 효과`·`역할 변경 불필요`·필드 라벨 `역할`/`탐색 범위`/`모델`은 유지). 모든 권장은 명시적 OPERATION 태그(`UPGRADE`/`ADD`/`SPLIT-REPLACE`)를 달아 `/design` Step 2 재제안 입력으로 모호함 없이 해석되게 한다 — `UPGRADE`는 기존 로스터 역할명을 lookup key(공백 제거 후 정확 일치, 흔들림은 malformed→재확인)로 쓰고 미변경 `탐색 범위`는 생략, `ADD`는 기존 로스터와 충돌하지 않는 신규 역할 1건, `SPLIT-REPLACE`는 부모→자식 둘 + `PARTITION` 무손실·무중복 계약. 기존 역할당 OPERATION 최대 1개 불변식과, 두 축이 같은 약점을 겨냥하면 더 강한 한쪽만 택하는 교차축 통합 추론을 포함한다.
- **역할 갭 탐지 + HARD LIMIT**: 4단계 coverage diff(도메인 열거 → 커버리지 맵 → 미커버 플래그 → 절제 게이트)를 **단일 패스**로 수행하며 iterate-until 루프·종료 계약이 없어 invariants lint exemption을 유지한다. 경량 재탐색은 read-only(팀·쓰기·test/build·MCP 금지)로 제안/인터뷰가 언급한 surface와 인접 sibling에 한정하고, ≤12 read-only 연산·단일 grep >50 hit는 ADD엔 inconclusive(SPLIT 후보의 과부하 입력으로는 유효)·확증 전용(fishing 금지)의 HARD LIMIT를 둔다. 절제 게이트·분할 게이트는 각각 ALL 충족 조건으로 "변경 없음"을 기본값으로 bias한다.
- **precondition 부재 시 3-path fallback 인코딩**: (1) 세션 로스터 붙여넣기 → 완전한 두 축 분석, (2) 저장된 설계 문서에서 역산 → 모델 배정 부재로 역할 축만 가능한 degraded 모드(교차축 화해를 N/A 처리), (3) 둘 다 없으면 한국어 안내 emit 후 종료(자동 `/design` 체이닝 안 함). 현재 커맨드가 이미 즉흥 제시하던 emergent 동작을 SKILL에 인코딩한다.
- **design-lite 충돌 가드 + 단방향 sync-note**: `design-lite` 구성(고정 2×sonnet, opus 제외)으로 보이면 두 강화 축이 lite 계약과 충돌하므로 caveat 후 명시 확인에만 진행하며, `design-lite/SKILL.md`의 상호 참조 문구도 두 축 반영으로 갱신해 양방향 정합을 맞춘다. OPERATION 라벨·모델 별칭의 source-of-truth가 `design/SKILL.md` Step 2 필드 세트임을 명시하는 단방향 sync-note를 `design-upgrade`에만 추가한다(`design/SKILL.md` 미접촉).

### Why

확장의 핵심은 "이름·호출 방식·second-opinion 성격은 그대로 두고 분석 축만 하나 더 얹는다"이다. 역할 축을 강화 방향(추가·분할)으로만 한정하고 제거·병합·모델 하향을 범위 밖으로 둔 것은 `upgrade` 의미를 깨지 않기 위함이며, 절제 게이트를 통과 못 하면 "변경 불필요"가 정상 출력이 되도록 한 것은 기존 모델 축의 유지 사유 대칭을 그대로 잇기 위함이다. OPERATION 태그는 재제안 루프(분석을 컨텍스트에 되먹여 다시 팀 구성)의 입력을 기계적으로 재구성 가능하게 만드는 계약이지 자동 ingestion 경로가 아니다 — 적용은 사람/다음 turn 모델이 수행한다.

## [1.10.1] - 2026-06-04

`AskUserQuestion`(AUQ) 호출이 간헐적으로 일으키는 "Invalid tool parameters" 에러의 96%는 모델이 도구 호출을 확정해 놓고 중첩 인자를 emit할 때 통째로 비워버리는 *빈-input 붕괴*(`tool_input == {}`, `questions` 누락)다. 1,544개 세션 로그 조사로 이 실패 모드를 확인하고, 공유 construction spec(`_common/askuserquestion.md`)에 짧은 authoring 가이드를 추가해 완화한다. 모든 스킬이 "every AUQ call"에 이 spec을 적용하므로 신규 단락이 자연히 전파된다 (`/plugin update cc-cmds`로 자동 반영).

당초 PreToolUse 훅으로 빈 호출을 검증 전에 가로채 교정하려 했으나, 라이브 테스트에서 AUQ 스키마 검증이 어떤 훅 디스패치보다 먼저 실행되어 스키마-거부 호출은 훅에 도달하지 못함이 확인되었다. 호출-시점 인터셉트가 구조적으로 불가능하므로 반응형 훅 레버를 폐기하고 prose 단일 레버로 출하한다.

### Changed

- **`_common/askuserquestion.md` authoring 가이드 추가**: (a) intro의 scope 문장을 "construction-validity only"에서 "constructing and reliably emitting valid calls"로 넓혀 생성 slip로 호출이 비워지는 것을 피하는 것까지 포함한다. (b) `Two Axes` 섹션 끝에 단락 하나를 fold-in해 — 결정에 필요한 것 이상으로 호출을 키우지 말 것(옵션 padding 금지, 턴 절약 목적의 독립 질문 묶음 금지)과, 같은 호출이 3회 이상 재emit에도 계속 붕괴하면 그 질문을 번호 매긴 평문으로 전환해 자유 응답을 받는 best-effort 폴백을 안내한다. 크기-붕괴 인과는 측정되지 않은 가설이라 hedge로 명시하고, 폴백은 강제 수단이 없는(non-deterministic) 지시임을 caveat로 남긴다. 새 동작을 강제하지 않는 prompt/wording 조정이라 patch bump.

## [1.10.0] - 2026-06-04

`design-review`와 `design-review-lite`에 "이미 리뷰된 문서에 수정이 발생했을 때 그 수정 사항의 정합성을 검증"하는 사용 패턴을 옵션화한 `--changes` 플래그를 추가한다. 지금까지는 매번 `design-review <doc> 수정 사항 관련 정합성 검증`처럼 자연어 의도를 덧붙여 호출해야 했던 흐름을 재현 가능한 플래그로 만든다. `--changes`는 기존 `--base`와 구조적으로 완전히 동형인 **프롬프트 주입 플래그**다 — git diff·스냅샷 같은 기계적 변경 식별 메커니즘은 도입하지 않고, 플래그가 켜지면 리뷰 에이전트 프롬프트에 `CHANGES MODE CONSTRAINT` 블록을 주입해 에이전트가 능동적으로 무엇이 바뀌었는지 판단한다 (`/plugin update cc-cmds`로 자동 반영).

### Added

- **`--changes` 플래그** (`design-review`·`design-review-lite` 양쪽): 리뷰 초점을 변경분 + 그 파급 반경으로 좁히는 리다이렉트. 두 갈래로 검증한다 — (a) 파급 정합성(각 변경이 데이터 모델·API 계약·시퀀스 흐름·요구사항 추적·구현 순서 등 문서 나머지와 여전히 일치하는지), (b) 변경 자체의 재질의(변경됐다는 이유로 옳다고 가정하지 않고 타당성·완결성·실현가능성을 신규 설계 결정처럼 재검토). `--base`와 직교하며 조합 가능(`--base --changes`) — `--base`는 *허용되는 제안의 종류*를 제약하는 필터, `--changes`는 *리뷰의 초점/대상*을 바꾸는 리다이렉트다. 조합 시 reconcile 불릿이 `"If a BASE MODE CONSTRAINT also appears above…"` 문장으로 자체 활성화되어 base의 제안-종류 제약을 준수하므로 4-way 분기 로직이 불필요하다.
- **사용자 참고 노트(범용 위치 인자)**: doc-path 뒤 trailing 자유텍스트를 `{USER_NOTE}` 블록으로 주입한다. `--changes` 유무와 무관하게 비어있지 않으면 항상 주입되며, `--changes`가 켜지면 "무엇이 바뀌었는지"의 권위 있는 변경 초점이 되고, 꺼져 있으면 일반 리뷰 참고/초점 컨텍스트로 전달된다. 추출은 `ARGS_CLEAN`에서 토큰 1(doc-path)을 비우고 나머지를 출력하는 무조건 실행으로, 노트가 없으면 빈 문자열이다.
- **단일-레벨 치환 계약**: `{USER_NOTE}`/`{BASE_MODE_CONSTRAINT}`/`{CHANGES_MODE_CONSTRAINT}` 세 플레이스홀더를 각각 독립적으로 단일 레벨 치환한다(중첩 토큰 없음 — 모델이 2차 해소를 잊어 리터럴 토큰을 누출하는 drift 실패 모드 차단). 프롬프트 본문 배치 순서는 위에서부터 `{USER_NOTE}` → `{BASE_MODE_CONSTRAINT}` → `{CHANGES_MODE_CONSTRAINT}`(각 사이 빈 줄 1개)로, CHANGES 블록의 "if a user-provided note appears above"가 성립하도록 노트가 위에 온다. `outer_log.md` 헤더에 `CHANGES_MODE`·`USER_NOTE`를 무조건 기록해 `BASE_MODE`와 audit provenance 패리티를 맞춘다.

### Why

`--changes`는 신규 disposition 태그를 도입하지 않으므로 종료 수학(`COUNT_APPLIED`/`escalate_applied`/`inner_converged_cleanly()`)·Self-Triage·severity·auto-decide 펜스에 변경이 없다. auto-decide는 main-session 전용이고 리뷰 에이전트에 전파되지 않으므로 에이전트-프롬프트 주입인 `--changes`와 동일 레이어를 건드리지 않는다. inferred 모드(자유텍스트 노트 없이 `--changes`만)의 변경 탐지는 diff·스냅샷 없이 문서만 보고 휴리스틱하게 재구성하므로 본질적으로 부분적이며, 이는 수용된 설계 트레이드오프다 — 완화책은 자유텍스트 설명을 넘겨 hard focus signal로 격상하는 것이다.

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
