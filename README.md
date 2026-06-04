# cc-cmds

Engineering workflow commands for Claude Code.

## Commands

<!-- SKILLS_TABLE_START -->

| Command | Description | When to use |
|---------|-------------|-------------|
| `/cc-cmds:design` | 에이전트 팀을 활용한 기능 설계 토론 진행 | 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때 |
| `/cc-cmds:design-analyze` | 에이전트 팀을 활용한 제3자 설계 문서 다관점 분석 (읽기 전용) | 타인이 작성한 설계/리팩토링 문서를 원본 수정 없이 다관점으로 분석하고 분석 산출물(보고서/주석본/피드백)을 생성하고자 할 때 |
| `/cc-cmds:design-apply` | Claude Design (claude.ai/design) 산출물을 타깃 코드베이스에 통합하는 구현 상세 설계를 agent team으로 작성 | design-ingest가 ACCEPT한 핸드오프 추출본을 기반으로 실제 코드베이스에 적용할 구현 상세 설계(impl-design.md)가 필요할 때 |
| `/cc-cmds:design-ingest` | Claude Design (claude.ai/design) 핸드오프 번들을 파싱·리뷰하고 ACCEPT/REFINE 판정으로 개선 루프 진행 | claude.ai/design 에서 받은 HTML 핸드오프 번들을 검토·수용·재프롬프트할 때 (단일 호출 또는 외부 재실행 사이 반복) |
| `/cc-cmds:design-lite` | 2인 팀을 활용한 경량 설계 토론 | 깊은 다관점 분석보다 빠른 방향 설정이 우선될 때 (sonnet 단독 합성으로 미묘한 invariant 누락 가능) |
| `/cc-cmds:design-prompt` | Claude Design (claude.ai/design) 실행용 프롬프트+컨텍스트를 base 설계 문서에 authoring하고 붙여넣기 블록 emit (standalone + idempotent, HANDOFF CONTRACT 포함) | base 설계 작성 후, claude.ai/design 에 보낼 의도 중심 프롬프트와 DS 참조를 base 설계 문서에 추가하거나 리뷰 반영본으로 붙여넣기 블록을 재조립할 때 |
| `/cc-cmds:design-review` | 설계 문서 최종 리뷰 | 작성된 설계 문서를 다중 반복 에이전트 리뷰(외부/내부 사이클)로 최종 검증·수렴시키고자 할 때 |
| `/cc-cmds:design-review-lite` | 설계 문서 경량 사이클 리뷰 | 설계 문서를 간결한 반복 사이클로 빠르게 검증하고 싶을 때 (미묘한 termination invariant·동시성 검출률 약화 가능) |
| `/cc-cmds:design-system` | Claude Design (claude.ai/design) DS 생성 프롬프트 emit + DS 번들 ingest로 docs/design-system/ 워크스페이스 구축 (2-phase) | FE 파이프라인 시작 전 프로젝트 전역 design system을 claude.ai/design으로 생성·도입할 때 (1회성 또는 재ingest) |
| `/cc-cmds:design-upgrade` | 팀 구성 강화 분석 (모델·역할 축) | 직전 `/design` 팀 구성 제안에서 opus 승격이 유의미한 역할이 있는지, 또는 누락 도메인을 메울 신규 역할·과부하 역할 분할이 필요한지 second-opinion으로 검토할 때 |
| `/cc-cmds:implement` | 설계 문서 기반 구현 | 사용자가 작성된 설계 문서를 바탕으로 단계적 계획을 세우고 실제 구현을 수행하기를 원할 때 |
| `/cc-cmds:review` | 에이전트 팀을 활용한 다관점 코드 리뷰 | 사용자가 PR/로컬 diff/파일 경로에 대한 다관점 코드 리뷰(보안/성능/품질 등)를 요청할 때 |
| `/cc-cmds:review-lite` | 2인 팀을 활용한 경량 코드 리뷰 | 빠른 코드 리뷰가 목적이고 다관점 심층 분석이 불필요할 때 (큰 PR coverage gap, 미묘한 race condition·authn bypass 검출률 약화 가능) |
| `/cc-cmds:review-upgrade` | 리뷰어 구성 강화 분석 (모델·역할 축) | 직전 `/review` Step 3 리뷰어 구성 제안에서 opus 승격이 유의미한 역할이 있는지, 누락된 리뷰 관점을 메울 신규 리뷰어 추가가 필요한지, 또는 과부하 리뷰어 분할이 필요한지 second-opinion으로 검토할 때 |

<!-- SKILLS_TABLE_END -->

## Prerequisites

`/cc-cmds:design`, `/cc-cmds:design-review` 등 에이전트 팀 기반 커맨드를 사용하려면 아래 환경변수가 필요합니다.

```json
// ~/.claude/settings.json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### 완료 알림 (선택)

**1단계 — 설치** (필수 선결 조건):

```bash
brew install terminal-notifier
brew install jq   # PreToolUse hook 의존성
```

**2단계 — 자연어 요청**:

- **단발 알림** — 사용자가 지정한 시점(작업 완료 등)에 모델이 알림을 1회 발송합니다. 여러 시점을 함께 지정하면 각 시점마다 발송합니다.
- **반복 알림** — 모델이 작업이 진행된 매 turn 종료 직전 자체적으로 알림을 발송합니다 (취소할 때까지). hook이 아닌 모델 판단 기반이라, 모델이 turn 끝의 호출을 놓치면 해당 turn 알림이 누락될 수 있습니다.

**사용 예시** (대화 중 이렇게 말하면 됩니다):

| 이렇게 말하세요 | 동작 |
| --- | --- |
| `"npm run build 끝나면 알림 줘"` | 단발 — 완료 시 1회 |
| `"배포 완료되면 알려줘"` | 단발 — 완료 시 1회 |
| `"PR 리뷰 시작할 때랑 끝날 때 알림 줘"` | 단발 (2회) — 각 시점 발송 |
| `"lint 끝날 때, 빌드 끝날 때, 배포 완료 시 알림 줘"` | 단발 (3회) — 각 시점 발송 |
| `"작업이 70% 정도 끝나면 알림 줘"` | 단발 — 모델 추정 시점 1회 (근사값) |
| `"매 단계마다 알림 줘"` | 반복 — 매 turn 발송; `"알림 취소"`로 중단 |
| `"알림 취소"` | 반복·단발 모두 취소 |

※ **진행률·중간 지점 표현 주의** — `"70% 정도 끝나면"`, `"중간쯤 되면"`처럼 백분율이나 중간 지점을 지정하면, 모델이 작업을 진행하며 **스스로 추정한** 시점에 알림을 1회 보냅니다. 진행률 측정기나 타이머가 따로 동작하는 것이 아니므로 실제 발송 시점은 모델의 주관적 판단에 따른 근사값입니다.

**3단계 — 최초 macOS 권한 승인** (1단계 완료 후): 첫 알림 시 macOS 권한 다이얼로그가 표시됩니다. 미리 트리거하려면 `"알림 테스트 한 번 해줘"`로 발화하여 테스트 알림을 받고 **허용**을 클릭하세요. (Claude Code의 Bash 권한 다이얼로그는 플러그인의 PreToolUse hook이 자동 승인하므로 표시되지 않습니다 — macOS 알림 권한 다이얼로그만 1회 응답하면 됩니다.) 다이얼로그를 놓쳤다면 시스템 설정 → 알림 → terminal-notifier에서 수동 활성화. 권한 거부 후 복구는 셸에서 `terminal-notifier -message 'cc-cmds permission test' -title '[cc-cmds] test' -group cc-cmds-active-notify -execute ':'` 직접 실행으로 재트리거 (스킬 bypass와 동일 형식이라 banner 외관이 일치).

terminal-notifier가 없거나 macOS가 아니면 알림은 오류 없이 비활성화됩니다.

### Claude Design 핸드오프 품질 리뷰 (선택)

`/cc-cmds:design-ingest`의 단일 에이전트 리뷰 단계는 환경에 `web-design-guidelines` 스킬이 설치되어 있으면 UI/접근성/반응형 평가를 그 스킬로 보강합니다. 이 스킬은 vercel-labs `agent-skills` 리포의 **skills-CLI 개별 스킬**이며 Claude Code 마켓플레이스 플러그인이 아닙니다 — 따라서 cc-cmds `plugin.json`의 `dependencies`로는 표현이 불가능하고, 다음 명령으로 `~/.claude/skills/`에 직접 설치합니다.

```bash
npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines
```

부재 시 design-ingest는 자체 5축 기준(토큰-vs-DS 일치도, a11y 대비비 산술, 반응형/터치 영역 44px+, base 의도 충실도, 시각 품질)으로 fallback하며 리뷰는 중단되지 않습니다. terminal-notifier와 동일 doctrine — `plugin.json` `dependencies`로 표현 불가한 선택적 외부 의존성(skills-CLI 개별 스킬·brew 도구 등)은 graceful degradation + README 권장-설치-명령 패턴을 따릅니다.

## Install

```bash
# 1. 마켓플레이스 등록
/plugin marketplace add Nharu/cc-cmds

# 2. 플러그인 설치
/plugin install cc-cmds@cc-cmds
```

## Usage

```
/cc-cmds:design <task>
/cc-cmds:design-lite <task>
/cc-cmds:design-review <design-doc-path>
/cc-cmds:design-review-lite <design-doc-path>
/cc-cmds:design-upgrade
/cc-cmds:implement <design-doc-path>
/cc-cmds:review [<target>] [<directive>]
/cc-cmds:review-lite [<target>]
```

각 커맨드의 옵션·입력 형태 세부는 아래 [Options](#options) 섹션 참조.

## Update

```
/plugin update cc-cmds
```

## Uninstall

```
/plugin uninstall cc-cmds
```

## Options

<!-- SKILLS_OPTIONS_START -->

- [/cc-cmds:design](#cc-cmdsdesign)
- [/cc-cmds:design-analyze](#cc-cmdsdesign-analyze)
- [/cc-cmds:design-apply](#cc-cmdsdesign-apply)
- [/cc-cmds:design-ingest](#cc-cmdsdesign-ingest)
- [/cc-cmds:design-lite](#cc-cmdsdesign-lite)
- [/cc-cmds:design-prompt](#cc-cmdsdesign-prompt)
- [/cc-cmds:design-review](#cc-cmdsdesign-review)
- [/cc-cmds:design-review-lite](#cc-cmdsdesign-review-lite)
- [/cc-cmds:design-system](#cc-cmdsdesign-system)
- [/cc-cmds:design-upgrade](#cc-cmdsdesign-upgrade)
- [/cc-cmds:implement](#cc-cmdsimplement)
- [/cc-cmds:review](#cc-cmdsreview)
- [/cc-cmds:review-lite](#cc-cmdsreview-lite)
- [/cc-cmds:review-upgrade](#cc-cmdsreview-upgrade)

### /cc-cmds:design

**Usage**: `/cc-cmds:design <task>`

| Option | Default | Summary |
| --- | --- | --- |
| `<task>` | (required) | 설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트). |

### /cc-cmds:design-analyze

**Usage**: `/cc-cmds:design-analyze <design-doc-path> [--no-codebase] [--report-only]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 분석 대상 제3자 설계 문서 경로 (`.md`). 원본은 절대 수정하지 않음. |
| `--no-codebase` | off (코드베이스 grounding 활성) | 코드베이스 교차검증 비활성화 — 문서 자체만으로 분석 (doc-only 모드). |
| `--report-only` | off (산출물 대화형 선택) | Step 7 산출물 선택 대화만 건너뛰고 보고서만 생성. Step 6 워크스루(발견별 검토)는 그대로 유지 — 완전 비대화 아님(산출물 범위 한정 플래그). |

### /cc-cmds:design-apply

**Usage**: `/cc-cmds:design-apply <handoff-extract-path>`

| Option | Default | Summary |
| --- | --- | --- |
| `<handoff-extract-path>` | (required) | design-ingest가 확정한 안정 사본 (`docs/{slug}-fe/handoff-extract.md`); 본 스킬이 slug 파싱·팀명 조립·cleanup 복구의 단일 앵커 |

### /cc-cmds:design-ingest

**Usage**: `/cc-cmds:design-ingest <handoff-dir-path>`

| Option | Default | Summary |
| --- | --- | --- |
| `<handoff-dir-path>` | (required) | 기능 핸드오프 디렉토리 (`docs/{slug}-fe/handoff`); incoming/ 하위 번들을 소비 |

### /cc-cmds:design-lite

**Usage**: `/cc-cmds:design-lite <task>`

| Option | Default | Summary |
| --- | --- | --- |
| `<task>` | (required) | 설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트). |

### /cc-cmds:design-prompt

**Usage**: `/cc-cmds:design-prompt <base-doc-path>`

| Option | Default | Summary |
| --- | --- | --- |
| `<base-doc-path>` | (required) | base 설계 문서 경로 (`docs/{slug}.md`); 본 스킬이 그 안에 CD 프롬프트 섹션을 in-place authoring |

### /cc-cmds:design-review

**Usage**: `/cc-cmds:design-review <design-doc-path> [--base] [--changes] [--no-auto-decide-dominant]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 리뷰 대상 설계 문서 경로 (`.md`) |
| `--base` | off | 기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT) |
| `--changes` | off | 이미 리뷰된 문서의 수정 사항으로 리뷰 초점 이동: 파급 정합성 + 변경 자체 재질의 (CHANGES MODE CONSTRAINT). `--base`와 직교·조합 가능 |
| `--auto-decide-dominant` | _(no-op alias — auto-decide는 기본 ON)_ | 명시적 opt-in 별칭. 현재 기본값이 이미 ON이라 실질 no-op; 역호환·명시성 목적으로 허용. |
| `--no-auto-decide-dominant` | off (즉, auto-decide 활성) | Decision Auto-Select Protocol(§8)을 세션 전체에서 비활성화 |

**Safety** — Decision Auto-Select Protocol(§8)을 세션 전체에서 비활성화 (`--no-auto-decide-dominant`):

- **기본 동작** — 별도 플래그 없이 auto-decide ON. Dominance Threshold(§8) 충족 시 `decision`-type 제안을 자동 선택하고 `[AUTO-DECIDED]`로 기록.
- **Blackout** — B1–B10 카테고리(파괴적 작업, 사용자 특화 결정, B7/B8/B9 조건부 체크리스트 포함)는 항상 사용자에게 escalate.
- **Revert** — 자동 결정된 항목은 `AUTO-NNN` 또는 `PROP-Rx-y` 참조로 언제든 되돌릴 수 있음 (§8.11).
- **Opt-out (invocation)** — `--no-auto-decide-dominant` 지정 시 전체 세션에서 비활성화, 세션 중간 재활성화는 불가.
- **Opt-out (mid-session)** — 다이얼로그 프롬프트에서 "자동 선택 중단" 같은 자연어 트리거로도 비활성화 가능 (§8.10 regex, 이후 재활성 불가).
- **Outer-cycle continuation** — 자동 결정이 한 건이라도 발생한 outer iter는 ripple 검증을 위해 한 iter 더 실행됨. 사용자 체감: "왜 리뷰가 더 오래 걸리지?"
- **Persistence** — `AUTO_DECIDE_ENABLED`는 outer iter 간 `outer_log.md`로 복원(§8.12) — bash 변수 휘발성 대응.

### /cc-cmds:design-review-lite

**Usage**: `/cc-cmds:design-review-lite <design-doc-path> [--base] [--changes]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 리뷰 대상 설계 문서 경로 (`.md`) |
| `--base` | off | 기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT) |
| `--changes` | off | 이미 리뷰된 문서의 수정 사항으로 리뷰 초점 이동: 파급 정합성 + 변경 자체 재질의 (CHANGES MODE CONSTRAINT). `--base`와 직교·조합 가능 |

### /cc-cmds:design-system

**Usage**: `/cc-cmds:design-system [<intent>]`

| Option | Default | Summary |
| --- | --- | --- |
| `[<intent>]` | _(optional)_ | DS 생성 의도/스코프 서술용 자유형 토큰 (생략 시 base 설계·코드베이스에서 추론) |

### /cc-cmds:design-upgrade

**Usage**: `/cc-cmds:design-upgrade`

_이 커맨드는 별도 인자를 받지 않으며, 직전 `/design` 팀 구성 제안이 현재 대화 컨텍스트에 있어야 동작한다. 모델 승격과 역할 추가·분할은 강화가 유의미할 때만 제안하며, 그 외에는 유지 사유를 제시한다. 독립 실행 시 결과가 불정확할 수 있다._

### /cc-cmds:implement

**Usage**: `/cc-cmds:implement <design-doc-path> [scope-directive]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 구현 대상 설계 문서 경로 (`.md`). |
| `[scope-directive]` | _(optional)_ | 구현 범위를 좁히는 자유형 자연어 지시문 (예: `"Phase 2"`, `"PR #0"`). |

> _Parsing (`<design-doc-path>`): `$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석. 이후 토큰은 scope directive로 전달._

> _Parsing (`[scope-directive]`): 첫 `.md` 토큰 이후의 모든 내용. 단일 바깥쪽 쌍따옴표로 감싸져 있으면 그 쌍만 제거하고 안쪽 따옴표·구두점은 보존._

### /cc-cmds:review

**Usage**: `/cc-cmds:review [<target>] [<directive>]`

| Option | Default | Summary |
| --- | --- | --- |
| `<target>` | _(optional)_ | 리뷰 대상. 입력 형태에 따라 PR/브랜치/파일 모드로 자동 분기. |
| `<directive>` | _(optional)_ | 리뷰 관점 지시문. `<target>` 뒤에 자연어로 부가 (예: "보안 중심으로"). |

**`<target>` 입력 형태별 처리:**

- **PR URL** — `https://github.com/owner/repo/pull/42` → PR 번호 추출 후 `gh pr view`로 메타데이터 수집
- **PR 번호** — `42` → 숫자만일 때 PR 번호로 해석
- **브랜치 이름** — `feat/auth-flow` → 하이픈·영문 포함 시 브랜치로 해석, `gh pr list --head`로 연관 PR 조회
- **파일/디렉토리 경로** — `src/auth/` → 파일 리뷰 모드; `gh` 명령 사용 안 함
- **혼합 (타겟 + 지시문)** — `PR #42 보안 중심으로` → 타겟 추출 후 지시문을 팀 구성·컨텍스트 패키지·보고서에 전파. **지시문은 깊이/커버리지에만 영향**; severity는 기술 기준으로 독립 평가.
- **(생략)** — 빈 입력 시 현재 브랜치/PR 자동 감지 체인 실행

> _Parsing (`<target>`): 숫자만 포함된 토큰(`42`)은 PR 번호, 하이픈·영문 포함 토큰(`42-fix-bug`)은 브랜치로 해석. 순수 숫자 + 브랜치 동시 존재 시 PR 번호 우선. 어느 형태에도 해당되지 않으면 `AskUserQuestion`으로 명확화._

> _Parsing (`<directive>`): 지시문은 severity 기준을 변경하지 않음 — 리뷰 팀 구성과 컨텍스트 가중치에만 영향._

### /cc-cmds:review-lite

**Usage**: `/cc-cmds:review-lite [<target>]`

| Option | Default | Summary |
| --- | --- | --- |
| `<target>` | _(optional)_ | 리뷰 대상 (PR 번호/URL, 브랜치, 파일/디렉토리, 또는 생략 시 현재 브랜치 자동 감지). PR 크기 무관 — 큰 PR 은 report 의 *리뷰 범위* 섹션에 미커버 영역 명시. |

### /cc-cmds:review-upgrade

**Usage**: `/cc-cmds:review-upgrade`

_이 커맨드는 별도 인자를 받지 않으며, 직전 `/review` Step 3 리뷰어 구성 제안이 현재 대화 컨텍스트에 있어야 동작한다. opus 승격, 누락 리뷰 관점 추가, 과부하 리뷰어 분할은 강화가 유의미할 때만 제안하며, 그 외에는 유지 사유를 제시한다. 독립 실행 시 결과가 불정확할 수 있다._

<!-- SKILLS_OPTIONS_END -->

## License

MIT
