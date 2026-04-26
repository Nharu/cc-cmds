# cc-cmds

Engineering workflow commands for Claude Code.

## Commands

<!-- SKILLS_TABLE_START -->

| Command | Description | When to use |
|---------|-------------|-------------|
| `/cc-cmds:design` | 에이전트 팀을 활용한 기능 설계 토론 진행 | 사용자가 새 기능 설계/아키텍처 결정/다관점 검토가 필요한 설계 논의를 요청할 때 |
| `/cc-cmds:design-review` | 설계 문서 최종 리뷰 | 작성된 설계 문서를 다중 반복 에이전트 리뷰(외부/내부 사이클)로 최종 검증·수렴시키고자 할 때 |
| `/cc-cmds:design-upgrade` | 팀원 모델 업그레이드 분석 | design 스킬의 팀 구성 제안에서 haiku/sonnet으로 배정된 팀원 중 opus로 승격이 유의미한 역할이 있는지 검토할 때 |
| `/cc-cmds:implement` | 설계 문서 기반 구현 | 사용자가 작성된 설계 문서를 바탕으로 단계적 계획을 세우고 실제 구현을 수행하기를 원할 때 |
| `/cc-cmds:review` | 에이전트 팀을 활용한 다관점 코드 리뷰 | 사용자가 PR/로컬 diff/파일 경로에 대한 다관점 코드 리뷰(보안/성능/품질 등)를 요청할 때 |

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
/cc-cmds:review [PR URL | PR number | branch | file path]
```

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

## License

MIT
