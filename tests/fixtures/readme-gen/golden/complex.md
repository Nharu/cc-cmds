# Test

## Commands

<!-- SKILLS_TABLE_START -->

| Command | Description | When to use |
|---------|-------------|-------------|
| `/cc-cmds:alpha` | alpha command with variants | when input shape varies |
| `/cc-cmds:beta` | beta command with safety | when behavior auto-changes are involved |

<!-- SKILLS_TABLE_END -->

## Options

<!-- SKILLS_OPTIONS_START -->

- [/cc-cmds:alpha](#cc-cmdsalpha)
- [/cc-cmds:beta](#cc-cmdsbeta)

### /cc-cmds:alpha

**Usage**: `/cc-cmds:alpha [<target>]`

| Option | Default | Summary |
| --- | --- | --- |
| `<target>` | _(optional)_ | 리뷰 대상. 입력 형태에 따라 자동 분기. |

**`<target>` 입력 형태별 처리:**

- **PR 번호** — `42` → 숫자만일 때 PR 번호로 해석
- **파일 경로** — `src/auth/` → 파일 리뷰 모드
- **(생략)** — 현재 브랜치 자동 감지

> _Parsing (`<target>`): 숫자만 포함된 토큰은 PR 번호로 해석._

### /cc-cmds:beta

**Usage**: `/cc-cmds:beta <doc> [--no-auto]`

| Option | Default | Summary |
| --- | --- | --- |
| `<doc>` | (required) | 대상 문서 경로 |
| `--auto` | _(no-op alias — auto는 기본 ON)_ | 명시적 opt-in 별칭 |
| `--no-auto` | off (즉, auto 활성) | Auto 모드를 세션 전체에서 비활성화 |

**Safety** — Auto 모드를 세션 전체에서 비활성화 (`--no-auto`):

- **기본 동작** — auto는 ON. 도미넌트 옵션을 자동 선택.
- **Blackout** — 파괴적 작업은 항상 사용자에게 escalate.
- **Revert** — 자동 결정은 참조 ID로 되돌릴 수 있음.
- **Opt-out** — `--no-auto` 지정 시 전체 세션에서 비활성화.

<!-- SKILLS_OPTIONS_END -->

## License

MIT
