# Changelog

All notable changes to cc-cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
