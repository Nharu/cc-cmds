# cc-cmds

Engineering workflow commands for Claude Code.

## Commands

<!-- SKILLS_TABLE_START -->

| Command | Description | When to use |
|---------|-------------|-------------|
| `/cc-cmds:design` | 에이전트 팀을 활용한 기능 설계 토론 진행 | 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때 |
| `/cc-cmds:design-lite` | 2인 팀을 활용한 경량 설계 토론 | 깊은 다관점 분석보다 빠른 방향 설정이 우선될 때 (sonnet 단독 합성으로 미묘한 invariant 누락 가능) |
| `/cc-cmds:design-review` | 설계 문서 최종 리뷰 | 작성된 설계 문서를 다중 반복 에이전트 리뷰(외부/내부 사이클)로 최종 검증·수렴시키고자 할 때 |
| `/cc-cmds:design-review-lite` | 설계 문서 경량 사이클 리뷰 | 설계 문서를 간결한 반복 사이클로 빠르게 검증하고 싶을 때 (미묘한 termination invariant·동시성 검출률 약화 가능) |
| `/cc-cmds:design-upgrade` | 팀원 모델 업그레이드 분석 | design 스킬의 팀 구성 제안에서 haiku/sonnet으로 배정된 팀원 중 opus로 승격이 유의미한 역할이 있는지 검토할 때 |
| `/cc-cmds:implement` | 설계 문서 기반 구현 | 사용자가 작성된 설계 문서를 바탕으로 단계적 계획을 세우고 실제 구현을 수행하기를 원할 때 |
| `/cc-cmds:review` | 에이전트 팀을 활용한 다관점 코드 리뷰 | 사용자가 PR/로컬 diff/파일 경로에 대한 다관점 코드 리뷰(보안/성능/품질 등)를 요청할 때 |
| `/cc-cmds:review-lite` | 2인 팀을 활용한 경량 코드 리뷰 | 빠른 코드 리뷰가 목적이고 다관점 심층 분석이 불필요할 때 (큰 PR coverage gap, 미묘한 race condition·authn bypass 검출률 약화 가능) |

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
/cc-cmds:design-review <design-doc-path>
/cc-cmds:design-upgrade
/cc-cmds:implement <design-doc-path>
/cc-cmds:review [<target>] [<directive>]
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

## Manual Install

플러그인을 사용할 수 없는 환경에서는 직접 복사하여 사용할 수 있습니다.

```bash
git clone https://github.com/Nharu/cc-cmds.git
cp -r cc-cmds/plugins/cc-cmds/skills/* ~/.claude/skills/
```

**참고**: 이전 버전에서 업그레이드하는 경우, 위 명령어를 다시 실행하여 모든 skills가 올바르게 등록되도록 하세요.

## Options

<!-- SKILLS_OPTIONS_START -->

- [/cc-cmds:design](#cc-cmdsdesign)
- [/cc-cmds:design-lite](#cc-cmdsdesign-lite)
- [/cc-cmds:design-review](#cc-cmdsdesign-review)
- [/cc-cmds:design-review-lite](#cc-cmdsdesign-review-lite)
- [/cc-cmds:design-upgrade](#cc-cmdsdesign-upgrade)
- [/cc-cmds:implement](#cc-cmdsimplement)
- [/cc-cmds:review](#cc-cmdsreview)
- [/cc-cmds:review-lite](#cc-cmdsreview-lite)

### /cc-cmds:design

**Usage**: `/cc-cmds:design <task>`

| Option | Default | Summary |
| --- | --- | --- |
| `<task>` | (required) | 설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트). |

### /cc-cmds:design-lite

**Usage**: `/cc-cmds:design-lite <task>`

| Option | Default | Summary |
| --- | --- | --- |
| `<task>` | (required) | 설계 토론을 진행할 작업 주제 (자유형 한국어/영문 텍스트). |

### /cc-cmds:design-review

**Usage**: `/cc-cmds:design-review <design-doc-path> [--base] [--no-auto-decide-dominant]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 리뷰 대상 설계 문서 경로 (`.md`) |
| `--base` | off | 기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT) |
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

**Usage**: `/cc-cmds:design-review-lite <design-doc-path> [--base]`

| Option | Default | Summary |
| --- | --- | --- |
| `<design-doc-path>` | (required) | 리뷰 대상 설계 문서 경로 (`.md`) |
| `--base` | off | 기존 내용 일관성만 검증; 신규 구현 세부 제안 금지 (BASE MODE CONSTRAINT) |

### /cc-cmds:design-upgrade

**Usage**: `/cc-cmds:design-upgrade`

_이 커맨드는 별도 인자를 받지 않으며, 직전 `/design` 팀 제안이 현재 대화 컨텍스트에 있어야 동작한다. 독립 실행 시 결과가 불정확할 수 있다._

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

<!-- SKILLS_OPTIONS_END -->

## License

MIT
