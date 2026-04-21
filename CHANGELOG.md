# Changelog

All notable changes to cc-cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
