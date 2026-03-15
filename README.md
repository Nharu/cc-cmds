# cc-cmds

Engineering workflow commands for Claude Code.

## Commands

| Command | Description |
|---------|-------------|
| `/design` | 에이전트 팀을 활용한 기능 설계 토론 |
| `/design:review` | 설계 문서 최종 리뷰 |
| `/design:upgrade` | 팀원 모델 업그레이드 분석 |
| `/implement` | 설계 문서 기반 구현 |

## Prerequisites

`/design`, `/design:review` 등 에이전트 팀 기반 커맨드를 사용하려면 아래 환경변수가 필요합니다.

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
/cc-cmds:design:review <design-doc-path>
/cc-cmds:design:upgrade
/cc-cmds:implement <design-doc-path>
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

## License

MIT
