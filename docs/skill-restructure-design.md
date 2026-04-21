# cc-cmds 스킬 재구조화 설계

## 개요

cc-cmds 플러그인이 관리하는 5개 스킬(`design`, `design-review`, `design-upgrade`, `implement`, `review`)을
**progressive disclosure 원칙**에 맞게 재구조화한다. 현재 모든 스킬이 단일 `SKILL.md` 하나에
모든 내용을 담고 있어 Claude Code의 공식 500줄 가이드라인을 초과하고, post-compaction 토큰 절감 효과를
전혀 활용하지 못하고 있다. 본 설계는 SKILL.md(핵심 orchestration) + `references/`(세부 참조 자료)로
분리하고, 로컬 개발 ↔ 플러그인 배포 워크플로우를 함께 정립한다.

**범위 제한**: 이번 설계는 **cc-cmds가 관리하는 5개 스킬에 한정**한다.
`~/.claude/commands/`에 있는 나머지 8개 커맨드(`ask`, `explore-site`, `feature-spec`, `portfolio`,
`proposal-cleanup`, `proposal`, `repo-health`, `wishket`)는 이번 범위 밖이며 그대로 유지한다.

**강제 마이그레이션 아님**: Claude Code 공식 문서에 따르면 커맨드는 deprecate되지 않았고,
스킬은 "merged" 되어 공존한다. 본 설계는 cc-cmds의 5개 스킬이 스킬 포맷의 이점(progressive disclosure,
post-compaction 5K 토큰 재첨부 특권)을 **실제로 활용**하기 위한 내부 재구조화이다.

---

## 1. 합의된 아키텍처

### 1.1 파일 구조

각 스킬은 다음 구조를 가진다.

```
plugins/cc-cmds/skills/<skill-name>/
├── SKILL.md                          # 핵심 orchestration + Control-Flow Invariants
├── references/                       # 조건부 로드되는 참조 파일
│   ├── 01-<topic-a>.md
│   ├── 02-<topic-b>.md
│   └── ...
└── (선택) rules/                     # 정규 체크리스트 (필요시)
```

추가로 여러 스킬이 공유하는 공통 자료는:

```
plugins/cc-cmds/skills/_common/
├── team-cleanup.md                   # 팀 graceful shutdown 5단계
└── agent-team-protocol.md            # [COMPLETE]/[IN PROGRESS] 신호, 파실리테이터 규칙
```

SKILL.md에서 참조할 때는 공식 substitution을 사용한다:
`${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`

**`${CLAUDE_SKILL_DIR}` 선택 이유 및 동작 확인**:

- `${CLAUDE_PLUGIN_ROOT}`는 플러그인 설치된 스킬에만 resolve가 보장되며, 본 프로젝트의 dev-symlink 모드(personal skill로 로드)에서는 부적합
- `${CLAUDE_SKILL_DIR}`는 personal/project/plugin 모든 스킬 유형에서 동작 (공식 skills 문서 명시)
- **실측 확인 (dev-symlink 모드)**: `${CLAUDE_SKILL_DIR}`는 logical path(심볼릭 링크 경로 그대로)로 치환됨.
  즉 `~/.claude/skills/design` 심볼릭 링크가 있을 때 `${CLAUDE_SKILL_DIR}`는 `~/.claude/skills/design`으로 치환되고, physical target(`~/dev/cc-cmds/...`)으로 resolve되지 않는다.
  → `~/.claude/skills/_common/` 심볼릭 링크 필수 (1.7 참조).
- **실측 확인 (plugin-install 모드)** (2026-04-21, marketplace add from local path): `/plugin install cc-cmds@cc-cmds` 후 `/cc-cmds:plugin-probe` 호출 결과, `${CLAUDE_SKILL_DIR}` = `/Users/ian/dev/cc-cmds/plugins/cc-cmds/skills/plugin-probe` (source path로 resolve). 이는 로컬 marketplace install이 source를 심볼릭 링크로 연결함을 시사.
  `${CLAUDE_SKILL_DIR}/../_common-probe/probe-content.md` Read가 성공했고 파일 내용이 정상 반환되었으므로 **plugin-install 모드에서도 sibling `_common/` resolve가 동작**함을 확인.
- 두 모드 모두에서 **`${CLAUDE_SKILL_DIR}/../_common/` 패턴이 유효**함이 실증됨.

### 1.2 SKILL.md 구성 원칙

모든 SKILL.md는 다음 순서를 따른다.

**핵심 제약**: post-compaction 재첨부 예산은 **5K 토큰**(cc-platform-expert 확인)이지만, Frontmatter + Overview + 코드블록 오버헤드 등의 여유를 고려해 **린트 임계값은 4K 토큰**으로 설정한다. 즉 control-flow invariants는 **첫 4K 토큰 안에** 완결되어야 한다 (5K 예산 대비 약 20% 안전 마진).

1. **Frontmatter** (`name`, `description`, `disable-model-invocation: true` 유지)
2. **개요 (Overview)** — 목적, 실행 단계, 언어 정책 3-5줄
3. **Control-Flow Invariants** — 모든 제어 흐름 공식과 종료 조건을 inline으로 고정
   (post-compaction 5K 재첨부 예산 안에 반드시 포함되어야 하므로 SKILL.md 상단 필수)
4. **Phase/Step 절차** — 각 단계의 실행 흐름
5. **Constraints / Ground Rules** — 하단에 배치

### 1.3 Read Gate 원칙 (매우 중요)

Read gate는 2가지 역할로 구분되며, 각각 다른 조건성 정책을 가진다.

#### (a) 소비 지점(consumption point) Read gate — **무조건 실행**

참조 파일이 실제로 사용되는 지점(= 소비 지점)의 Read는 **항상 무조건적인 `Read()` 호출**이다. 표준 문구 (substitution으로 절대 경로 사용, cwd 변동에 무관):

> **Before {action}, Read `${CLAUDE_SKILL_DIR}/references/{file}.md`.**

예: `Before spawning the review agent, Read ${CLAUDE_SKILL_DIR}/references/review-agent-prompt.md. Substitute {INNER_TEMP_DIR} and {BASE_MODE_CONSTRAINT} into the template before calling Agent().`

"이미 세션 중에 로드했다면 건너뛰어라" 같은 조건부 분기는 소비 지점 Read gate에서 **금지**한다. 이유:

- Post-compaction 시 Claude의 "읽은 적이 있다"는 기억 자체가 요약되어 사라질 수 있음
- Read tool은 idempotent하고 비용이 낮음
- 약간의 중복 읽기를 감수하더라도 결정적(deterministic) 복구가 안전성에서 우선

#### (b) 선행 로드(eager-load) — **조건부 허용, 단 recovery gate와 반드시 병행**

실행 플래그에 따라 조건부로 미리 로드해 놓는 "eager-load"는 허용된다. 예: `AUTO_DECIDE_INITIAL=true`인 경우에만 Phase 1 Step 4에서 `references/01-auto-decide-protocol.md`를 선행 로드.

**필수 조건**: eager-load가 조건부인 경우 반드시 뒷단의 실제 소비 지점(Step 12.f 등)에 **무조건 실행되는 recovery gate(위 (a))**를 병행 배치해야 한다. Post-compaction 시 eager-load된 내용이 요약되어 사라질 수 있으므로, recovery gate가 없으면 압축 이후 조용한 오작동을 유발한다.

즉 두 정책은 상호 배제가 아닌 **이중 구조** — eager-load는 pre-compaction 최적화, recovery gate는 post-compaction 안전망.

### 1.4 Control-Flow Invariants 원칙

다음 유형의 내용은 **반드시 SKILL.md 본문(references가 아닌)에 inline으로** 배치한다:

- 종료 조건 공식 (예: design-review의 §3.11 convergence predicate, §3.3 Step 17 termination)
- 핵심 카운팅/집계 공식 (예: §8.8 `COUNT_APPLIED`)
- 분류자 기준 (예: §8 decision-type classifier — references/ 로드 여부를 판단하는 근거)
- 트리거 정규식 (예: §8.11, §8.12 Korean-phrase 매칭 패턴)
- Disposition 태그 표

이유: SKILL.md는 post-compaction 시 **첫 5K 토큰이 재첨부**되는 특권을 가지지만,
참조 파일의 read 결과는 이 특권이 없어 요약되어 사라질 수 있다.
제어 흐름이 참조 파일 안에 있으면 압축 후 skill이 조용히 오작동한다.

### 1.5 스킬별 분할 계획

| 스킬             | 현재           | 재구조화 후 SKILL.md | references/     | 감소율 |
| ---------------- | -------------- | -------------------- | --------------- | ------ |
| `design-review`  | 1385줄 / 76 KB | ~400줄 / ~22 KB      | 6개 파일        | ~71%   |
| `review`         | 596줄 / 33 KB  | ~220줄 / ~12 KB      | 3개 파일        | ~63%   |
| `design`         | 91줄 / 9 KB    | ~60줄 / ~6 KB        | `_common/` 참조 | ~33%   |
| `implement`      | 81줄 / 7 KB    | 변경 없음            | 없음            | 0%     |
| `design-upgrade` | 18줄 / 0.5 KB  | 변경 없음            | 없음            | 0%     |

**집계 초기 로드 감소: ~62%** (특히 design-review의 §8 auto-decide 블록이 조건부 로드로 이동).

**산출 근거** (5개 스킬 합산, 바이트 기준 가중 평균):

- 현재 총합: 76 + 33 + 9 + 7 + 0.5 = **~125.5 KB**
- 재구조화 후 SKILL.md 총합: 22 + 12 + 6 + 7 + 0.5 = **~47.5 KB**
- 절대 감소: ~78 KB → 감소율 **62.2%**

분모에 `implement`/`design-upgrade`의 0% 항목을 포함한 "초기 로드" 감소율이며, 조건부 로드로 이동한 references/ 파일은 호출 시점에만 로드되므로 기본 경로 감소 효과는 이보다 더 크다(design-review의 §8을 default-ON으로 간주해도 eager-load 시점은 세션당 1회).

#### design-review 상세 분할 (최우선)

**SKILL.md 유지 (~400줄)**: Phase 1/2/3 orchestration (Step 1-25), Self-Triage + Approval UX + Disposition handling normal path, Application Mechanism, Flag parsing bash block(`--base`, `--auto-decide-dominant`), `$ARGUMENTS` 처리, Ground Rules, Control-Flow Invariants 섹션(§3.11, §8.8, §3.3 Step 17, §8 classifier, §8.11/§8.12 트리거 regex, disposition 태그 표)

**references/**:

- `01-auto-decide-protocol.md` (~200줄) — §8 상세 알고리즘: `re_evaluate_decision`, blackout B1-B10, risk-analyst safety envelope, budget caps, failure mode matrix
- `02-processing-protocol-detail.md` (~110줄) — §8.11 revert, §8.12 opt-out 상세 처리
- `03-severity-exit-policy.md` (~45줄) — §3.11 severity 할당 설명(공식은 SKILL.md, 배경 설명만)
- `04-file-schemas.md` (~110줄) — `pending_applies.md`, `ack_items.md`, `outer_log.md`, `convergence_table.md` 스키마
- `05-korean-ux-templates.md` (~225줄) — 용어집, 반복 전이 요약 블록, 프롬프트 템플릿 a-e, 상태줄 규칙. **세분화하지 않는 근거**: "각 iteration 종료 요약 발행" + "safety-limit 프롬프트 직전"에서 모두 함께 사용되므로 쪼갤 경우 Read가 2~3회로 늘어나 토큰 효율이 악화됨. 225줄은 references/ 중 최대이지만 조건부 로드(iter 종료 시점 1회)이므로 초기 SKILL.md 로드 효율에는 영향 없음.
- `06-review-agent-prompt.md` (~70줄) — Review agent 프롬프트 본문 + severity 기준 + proposal format

**각 참조 파일에 대한 Read gate 위치**:

- `01`: Phase 1 Step 4 (eager-load, if `AUTO_DECIDE_INITIAL=true`) + Step 12.f (unconditional re-read before `re_evaluate_decision`)
- `02`: §8.11/§8.12 트리거 regex 매칭 시
- `03`: Step 14-15 convergence 평가 시
- `04`: 모든 persistent 파일 write 직전
- `05`: 각 iteration 종료 요약 발행 + safety-limit 프롬프트 직전
- `06`: Step 12 agent spawn 직전

#### review 상세 분할

**SKILL.md 유지 (~220줄)**: Step 0 Tool Loading, Step 1 PR 감지, Step 2 인덱싱, Step 3 팀 구성 제안, Step 4/5 orchestration skeleton, Step 6 follow-up, Constraints

**references/**:

- `01-reviewer-context-package.md` (~115줄) — 15-item context package, 4 role checklists, review protocol rounds, facilitator rules
- `02-review-report-template.md` (~95줄) — severity system, merge rules, 문서 구조 템플릿, 파일 네이밍
- `03-non-pr-mode.md` (~30줄) — 비-PR 타겟 적응 표

#### design / implement / design-upgrade

- `design`: 91줄로 작으나 `_common/team-cleanup.md`, `_common/agent-team-protocol.md` 참조로 중복 제거.
- `implement`: 전체 내용이 orchestration/guard. 분할 시 약해지므로 **현행 유지**.
- `design-upgrade`: 18줄. 분할 불필요.

### 1.6 공유 자료(`_common/`)

다음 내용이 3개 이상 스킬에서 중복:

- Team cleanup 5단계 shutdown 절차
- `[COMPLETE]`/`[IN PROGRESS]` 신호 + idle ≠ done facilitator 규칙
- ToolSearch 선행 로딩 지시

공유 위치: `plugins/cc-cmds/skills/_common/`
참조 방식: `${CLAUDE_SKILL_DIR}/../_common/<file>.md`

**`${CLAUDE_SKILL_DIR}` 선택 이유 + resolve 동작**:

- `${CLAUDE_SKILL_DIR}`는 skill-doc에 명시된 표준 substitution으로 personal/project/plugin 모든 유형에서 동작. `${CLAUDE_PLUGIN_ROOT}`는 플러그인 설치 환경에서만 resolve가 보장되므로 dev-symlink 모드에는 부적합.
- **실측 확인**: `${CLAUDE_SKILL_DIR}`는 **logical path**로 치환됨. 즉 `~/.claude/skills/design` 심볼릭 링크가 있을 때 `${CLAUDE_SKILL_DIR}` = `~/.claude/skills/design` (physical target이 아님).
- 따라서 `../_common/`은 `~/.claude/skills/_common/`을 찾게 되므로, cc-cmds의 `_common/`을 반드시 `~/.claude/skills/_common/`에도 심볼릭 링크로 두어야 한다. (1.7 참조)

**참고**: `_common/` 자체는 SKILL.md가 없으므로 스킬 레지스트리에 등록되지 않는다(`.md` 파일은
`SKILL.md`라는 이름이 아니면 스캔 대상 아님 — cc-platform-expert Q3 확인).

**명명 규칙**: `_common/` 내부 파일은 `references/`의 숫자 prefix 컨벤션을 쓰지 않고 **topic-kebab-case**(예: `team-cleanup.md`, `agent-team-protocol.md`). 파일 수가 늘어나 카테고리 분리가 필요해지면 하위 디렉토리(`_common/protocols/`, `_common/templates/`) 도입을 허용.

### 1.7 개발 ↔ 배포 워크플로우

**Single Source of Truth**: `~/dev/cc-cmds/plugins/cc-cmds/skills/`가 유일한 편집 지점.

**로컬 사용 방식** (개발 중): **per-skill 심볼릭 링크** (디렉토리 단위 링크 금지 — `~/.claude/skills/`에 있는 기존 스킬들을 덮어써버리게 됨).

```bash
# 충돌 가드: 같은 이름이 이미 non-symlink(개인 커스터마이징일 수 있음)로 존재하면 중단.
# 기존 cc-cmds 심볼릭 링크는 덮어쓰기 허용(재셋업 경로).
SKILLS_DIR=~/.claude/skills
SRC=~/dev/cc-cmds/plugins/cc-cmds/skills
for s in design design-review design-upgrade implement review _common; do
  target="$SKILLS_DIR/$s"
  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "ERROR: $target exists as non-symlink. Back up or remove manually before re-running." >&2
    exit 1
  fi
  if [[ -L "$target" ]]; then
    cur=$(readlink "$target")
    if [[ "$cur" != "$SRC/$s" ]]; then
      echo "ERROR: $target is a symlink pointing elsewhere ($cur). Resolve manually." >&2
      exit 1
    fi
  fi
done

# 검증 통과 후 링크 생성
for s in design design-review design-upgrade implement review; do
  ln -sfn "$SRC/$s" "$SKILLS_DIR/$s"
done

# _common/도 필수 — ${CLAUDE_SKILL_DIR}가 logical path로 치환되므로
# ~/.claude/skills/_common/ 에 물리적으로 존재해야 ../\_common/ 참조가 성립
ln -sfn "$SRC/_common" "$SKILLS_DIR/_common"
```

편집 즉시 로컬에 반영(플러그인 재설치 불필요). 기존 스킬(`playwright-cli`, `vercel-react-best-practices`, `web-design-guidelines`, `supabase-postgres-best-practices`, `report` 등)은 그대로 유지된다. `supabase-postgres-best-practices`가 이미 per-skill 심볼릭 링크 방식을 쓰고 있어 컨벤션도 일관된다.

**`_common/`이 스킬로 잘못 등록될 우려 없음**: SKILL.md가 없으므로 스킬 레지스트리가 스캔하지 않음 (cc-platform-expert Q3 확인).


**호출 규약 (로컬)**: `/design-review` 형태로 user-scope 스킬로 호출. `/cc-cmds:design-review`(플러그인 네임스페이스) 형태는 외부 사용자만 사용.

**주의**: 로컬 머신에서 심볼릭 링크와 `/plugin install cc-cmds`를 **동시 사용 금지**. 동일 이름 스킬이 두 번 등록되어 모호성 발생.

**기존 `~/.claude/commands/` 정리**:

- cc-cmds가 관리하는 5개(`design.md`, `design-review.md`, `design-upgrade.md`, `implement.md`, `review.md`) → **삭제** (심볼릭 링크 셋업 후 중복 제거)
- 나머지 8개 파일(`ask`, `explore-site`, `feature-spec`, `portfolio`, `proposal-cleanup`, `proposal`, `repo-health`, `wishket`) → **그대로 유지** (이번 범위 밖)

**에디터 UX**:

```bash
# 심볼릭 링크를 물리 경로로 강제 resolve — VS Code가 ~/.claude/skills/ 경로로 열어 git CWD가 혼동되는 것을 차단
sk() { code $(readlink -f ~/.claude/skills/$1 2>/dev/null || echo ~/dev/cc-cmds/plugins/cc-cmds/skills/$1); }
# 사용: sk design-review
```

디렉토리를 VS Code 워크스페이스로 열어 7개 파일을 사이드바에 노출. `readlink -f`는 심볼릭 링크(`~/.claude/skills/<name>`)를 물리 경로(`~/dev/cc-cmds/plugins/cc-cmds/skills/<name>`)로 resolve하므로 git이 올바른 working tree에서 동작함.

`references/` 파일명에 **숫자 prefix** 사용(`01-*.md`, `02-*.md`)하여 호출 순서를 반영 → 탐색 예측성 향상.

**README 자동 생성**: `cc-cmds/README.md`의 스킬 표를 각 `SKILL.md`의 frontmatter(`name`, `description`, `when_to_use` 필드)에서 자동 생성. CI에서 `make readme && git diff --exit-code README.md`로 drift 방지.

**외부 사용자 업그레이드**: 이번 변경은 **순수 additive**(기존 SKILL.md 본문을 줄이고 `references/`, `_common/` 하위 디렉토리를 추가)이므로 구조 전환이 아니다. `/plugin update cc-cmds` 하나로 새 버전이 별도 캐시 디렉토리로 설치되고 새 파일이 그 안에 포함된다. 이전 버전 캐시는 orphan 처리되어 7일 후 자동 제거. **Phase 7 실측 시나리오에서 update 경로 정상 동작이 확인되면 사용자 재설치 불필요, BREAKING CHANGE 아님**(실측 실패 시 fallback 지침은 Phase 7 시나리오 step 5 참조).

**플랫폼 근거**: Claude Code 공식 플러그인 문서 참조 — `https://code.claude.com/docs/en/plugins` (plugin install/update 시 별도 버전 디렉토리, orphan 정책). 배포 전 Phase 7 단계에서 v1 설치 상태 → v2 업데이트 실측 시나리오를 다음 순서로 검증:

1. 현재 v1 cc-cmds 설치 상태에서 릴리즈 전 tag를 체크아웃하여 임시 설치 (`/plugin install cc-cmds@cc-cmds` — marketplace는 재구조화 전 버전)
2. 재구조화 후 main 브랜치를 v2로 tag한 후 `/plugin update cc-cmds` 실행
3. `~/.claude/plugins/cache/.../cc-cmds/plugins/cc-cmds/skills/design-review/references/*.md`, `.../skills/_common/*.md` 존재 확인
4. 새 세션에서 `/cc-cmds:design-review` 호출 → 정상 작동 확인
5. 실패 시 릴리즈 보류 및 CHANGELOG에 사용자 수동 재설치(`remove && install`) 안내 추가

---

## 2. 주요 결정사항과 근거

### D1. §8 Auto-Decide Protocol의 하이브리드 배치

**결정**: §8의 상세 알고리즘은 `references/01-auto-decide-protocol.md`로 분리하되,
**핵심 제어 흐름 원소는 SKILL.md의 Control-Flow Invariants 섹션에 inline**으로 유지.
eager-load 게이트(Phase 1 Step 4) + 복구 게이트(Step 12.f, unconditional Read) 이중 구조.

**근거**:

- §8은 design-review의 default-ON 경로이므로 완전히 lazy-load하면 조용한 실패 위험 (migration-risk-manager R2)
- Post-compaction 시 SKILL.md만 5K 토큰 재첨부 특권이 있고 참조 파일은 요약 가능 (cc-platform-expert Q4/Q5)
- 카운팅 공식(§8.8)과 종료 조건(§3.3 Step 17)은 outer loop 종결을 지배 → SKILL.md 필수
- §8 상세 알고리즘(~200줄)은 조건부로만 실행 → references/로 이동하여 SKILL.md 500줄 가이드라인 준수

### D2. Read Gate는 무조건 실행

**결정**: "이미 로드했다면 건너뛰기" 같은 조건부 분기 금지. 소비 지점마다 무조건 `Read()`.

**근거**:

- Compaction 후 Claude의 read-state 기억 자체가 요약 가능 (cc-platform-expert 지적)
- Read tool은 idempotent + 비용 낮음
- 결정적 복구 > 약간의 중복 비용

### D3. 플랫 `~/.claude/commands/` 미러 포기

**결정**: cc-cmds가 관리하는 5개 스킬의 플랫 `.md` 사본 삭제. 심볼릭 링크로 단일 소스 유지.

**근거**:

- 다중 파일 스킬 구조에서는 단일 `.md` 미러와 diff가 구조적으로 불가능 (migration-risk-manager R6)
- Git 브랜치로 실험용 분기 가능 → "개발 사본" 개념 불필요 (workflow-ux-designer)
- 심볼릭 링크는 편집 즉시 로컬 반영, `/reload-plugins` 불필요

### D4. `_common/` 공유 디렉토리 사용 + `${CLAUDE_SKILL_DIR}` 치환

**결정**: 중복되는 shutdown/protocol/tool-loading 자료를 `plugins/cc-cmds/skills/_common/`로 이전.
참조 경로: `${CLAUDE_SKILL_DIR}/../_common/<file>.md`.

**근거**:

- `${CLAUDE_SKILL_DIR}`는 공식 skills 문서에 명시된 표준 substitution으로 personal/project/plugin 모든 스킬 유형에서 동작 (cc-platform-expert 최종 확인)
- `${CLAUDE_PLUGIN_ROOT}`는 플러그인 설치된 스킬에만 resolve 보장되므로 본 프로젝트의 dev-symlink 모드(personal skill로 로드)에서는 부적합
- 심볼릭 링크는 sibling 디렉토리 구조를 보존하므로 `../_common/` 상대 경로가 dev-symlink와 플러그인 설치 양쪽에서 동일하게 플러그인 루트 내부를 가리킴
- 단일 substitution으로 모드별 분기 불필요 → 유지보수성 향상
- 3개 스킬(design, review, design-review)에서 8-12줄씩 중복 제거

### D5. 로컬 심볼릭 링크 + 플러그인 설치 동시 사용 금지

**결정**: 개발 머신에서는 심볼릭 링크 한 방식만 사용. 플러그인 설치는 외부 사용자 전용.

**근거**:

- 동일 이름 스킬이 user-scope와 plugin-scope에 동시 등록되면 호출 모호성 발생 (workflow-ux-designer)
- cc-platform-expert 확인: 플러그인 스킬은 `/cc-cmds:name`, 유저 스킬은 `/name`으로 별도 invocation

---

## 3. 미해결 이슈 / 트레이드오프

### T1. SKILL.md 크기 vs post-compaction 특권

design-review SKILL.md가 ~400줄에 도달. 500줄 guideline은 만족하지만,
Control-Flow Invariants를 포함한 상단 ~4K 토큰에 핵심이 모두 들어가야 하는 제약이 있다.
편집 시 상단 구조를 흐트러뜨리면 post-compaction 재첨부 시 핵심 invariant가 truncate될 수 있음.

**완화**: 린트 규칙 추가 — SKILL.md 첫 4000 토큰 안에 `Control-Flow Invariants` 섹션이 존재해야 함.

**린트 스크립트 사양**: `scripts/lint-skill-invariants.sh`
- 입력: `SKILL.md` 파일 경로 목록 (또는 `plugins/cc-cmds/skills/*/SKILL.md` 전체)
- 토크나이저: 근사치 — `wc -c` 또는 공백 기준 단어 수 × 1.3 (Claude의 tiktoken을 정확히 쓰기 어려우므로 안전 마진 포함 근사)
- 검사 규칙: 파일 상단에서 처음 4000 토큰(근사) 내에 `^## Control-Flow Invariants` heading regex가 존재해야 함
- 종료 코드: 미포함 시 non-zero, 로그에 파일별 위치 출력
- CI 통합: GitHub Actions PR check (`.github/workflows/lint.yml`) + 선택적 pre-commit hook

**README 자동생성 사양**: `scripts/generate-readme.sh` (bash 고정)
- 입력: `plugins/cc-cmds/skills/*/SKILL.md` (단 `_common/` 하위는 제외 — SKILL.md 없음)
- 동작: 각 SKILL.md의 YAML frontmatter 파싱(`yq` 또는 `awk` 기반) → `name`, `description`, `when_to_use` 필드 추출
- 출력: README의 `<!-- SKILLS_TABLE_START -->` ~ `<!-- SKILLS_TABLE_END -->` 마커 사이를 3-column 표로 재생성
- Makefile 타겟: `readme: ; bash scripts/generate-readme.sh`
- CI 통합: `make readme && git diff --exit-code README.md`으로 drift 방지

### T2. `_common/` 재사용 한계

현재 3개 스킬에서 중복되는 내용이 많지 않음(shutdown 5단계, 파실리테이터 규칙 등 ~25줄 수준).
공유 파일화로 인한 유지보수 이점(일관성) vs 추가 파일 하나 증가의 비용(간접화)이
borderline임. 소수 공통만 `_common/`에 두고 나머지는 per-skill 반복 허용.

**폴백**: cc-platform-expert가 `${CLAUDE_SKILL_DIR}` substitution 신뢰도를 높게 평가하고 logical-path resolve도 실측 확인되었으므로 `_common/` 적용. 향후 운영 중 문제 발생 시 per-skill 사본 + "keep in sync" 주석으로 회귀.

### T3. Agent prompt Read gate의 runtime substitution 비용

Review agent prompt(~70줄)를 references/로 이동하면 Agent spawn 시마다 Read + 변수 치환이 필요.
inline 유지 대비 1회 Read 추가 비용. 그러나 compaction 보호 측면에서 references/가 더 안전.

**결정**: references/로 이동. Step 12 직전에 unconditional Read + 변수 치환 + Agent() 호출의 3-스텝 패턴 명시.

### T4. 외부 사용자 마이그레이션 (해소)

초기 설계에서는 "flat-file → 디렉토리 구조 전환"으로 오인하여 `remove && install` 수동 실행을 요구했으나, 실제로 cc-cmds는 이미 skills 구조이고 이번 변경은 **순수 additive**(SKILL.md 축소 + 하위 디렉토리 추가)이다. `/plugin update cc-cmds`로 자동 처리되며 BREAKING CHANGE 아님.

---

## 4. 권장 구현 순서

단계별로 각 단계가 끝나면 로컬 테스트 후 다음 단계로.

### Phase 0 — 준비 (블로킹)

- [ ] cc-cmds 플러그인이 로컬 설치되어 있다면 `/plugin uninstall cc-cmds` (중복 등록 방지)
- [ ] `~/.claude/skills/`의 기존 스킬 목록 확인 (`playwright-cli`, `vercel-react-best-practices`, `web-design-guidelines`, `supabase-postgres-best-practices`, `report` 등) — 이 디렉토리는 **덮어쓰지 말고 per-skill 심볼릭 링크만 추가**
- [ ] cc-cmds 5개 스킬명(`design`, `design-review`, `design-upgrade`, `implement`, `review`)과 `_common`이 `~/.claude/skills/` 에 non-symlink로 이미 존재하는지 확인. 존재하면 백업 또는 제거 후 진행 (셋업 스크립트의 충돌 가드가 중단시킴)
- [ ] **§1.7의 충돌 가드 포함 셋업 스크립트 실행** (Phase 0은 참조만 — raw `ln -sfn` 루프 사용 금지). `~/.claude/skills/<name>`이 non-symlink로 존재하거나 다른 경로를 가리키는 심볼릭 링크면 스크립트가 자동 중단
- [ ] 로컬에서 `/design`, `/design-review` 등 기존 호출이 여전히 작동하는지 검증 (변경 전 baseline)
- [ ] 심볼릭 링크 자체가 올바로 걸렸는지 `readlink -f ~/.claude/skills/_common`로 확인 (cc-cmds 레포 경로로 resolve되어야 함). 실제 파일 resolve(`team-cleanup.md` 등)는 파일이 생성되는 Phase 1 Resolve 검증에서 수행

### Phase 1 — `_common/` 구축

- [ ] `plugins/cc-cmds/skills/_common/team-cleanup.md` 작성 (기존 5-step shutdown 절차)
- [ ] `plugins/cc-cmds/skills/_common/agent-team-protocol.md` 작성 ([COMPLETE]/[IN PROGRESS] 신호, 파실리테이터 규칙)
- [ ] 스킬이 참조하지 않는 상태로 파일만 먼저 배치 (이후 단계에서 참조 추가)
- [ ] **Resolve 검증** (Phase 2 진입 전 필수): `readlink -f ~/.claude/skills/_common/team-cleanup.md`로 심볼릭 링크가 실파일(`~/dev/cc-cmds/plugins/cc-cmds/skills/_common/team-cleanup.md`)로 정상 resolve되는지 확인. 더 강하게 검증하려면 §1.1 실측 때 사용했던 plugin-probe 패턴을 임시 재현 — 임시 스킬 SKILL.md에서 `Read ${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` 수행 후 결과 확인 (검증 후 임시 스킬 제거)

### Phase 2 — 작은 스킬부터 분할 (`design`)

- [ ] `design/SKILL.md`에서 shutdown 5단계 섹션 제거 후 `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` Read gate로 교체
- [ ] agent-team-protocol 섹션도 동일 방식으로 교체
- [ ] 로컬 `/design` 실행 테스트 — Read gate 동작 확인

### Phase 3 — `review` 분할

- [ ] `references/01-reviewer-context-package.md` 생성 및 해당 섹션 이동
- [ ] `references/02-review-report-template.md` 생성 및 이동
- [ ] `references/03-non-pr-mode.md` 생성 및 이동
- [ ] SKILL.md에 unconditional Read gate 추가 (각 소비 지점)
- [ ] SKILL.md 크기 확인 (~220줄 목표)
- [ ] `/review` 실행 테스트

### Phase 4 — `design-review` 분할 (최대 작업)

- [ ] **Control-Flow Invariants 섹션을 SKILL.md 상단에 작성** (§3.11 predicate, §8.8 formula, §3.3 Step 17, §8 classifier, §8.11/§8.12 triggers, disposition table) — post-compaction 생존이 이 섹션의 배치에 달려 있음
- [ ] `references/01-auto-decide-protocol.md` 생성 (§8 상세 알고리즘 ~200줄)
- [ ] `references/02-processing-protocol-detail.md` (§8.11, §8.12 상세)
- [ ] `references/03-severity-exit-policy.md`
- [ ] `references/04-file-schemas.md`
- [ ] `references/05-korean-ux-templates.md`
- [ ] `references/06-review-agent-prompt.md`
- [ ] SKILL.md 본문에서 이동된 섹션 삭제, 각 소비 지점에 unconditional Read gate 삽입
- [ ] Phase 1 Step 4에 eager-load gate 추가 (if `AUTO_DECIDE_INITIAL=true`)
- [ ] Step 12.f에 복구 gate 추가 (unconditional Read before `re_evaluate_decision`)
- [ ] SKILL.md 크기 확인 (~400줄 목표)
- [ ] 린트: 첫 4000 토큰 안에 Control-Flow Invariants 섹션 포함 여부 검사
- [ ] `/design-review` 실행 테스트 — 특히 `--auto-decide-dominant` 경로와 default 경로 모두 검증
- [ ] **Acceptance Criteria 4종 검증** (단일 커밋 머지 기준 — 모두 블로킹):
  - (a) `/design` / `/design-review` default 경로가 정상 완료하고 iter-001 산출물이 기대 스키마와 일치
  - (b) `--auto-decide-dominant` 경로에서 `re_evaluate_decision` 관련 로그(`[AUTO-DECIDED]` 엔트리) 확인
  - (c) 린트 통과 — Control-Flow Invariants가 첫 4K 토큰 안에 존재
  - (d) Post-compaction 생존: 장시간 세션에서 `/design-review` 실행 후 `/compact` 수동 트리거 → 재첨부 후에도 §3.11, §8.8, §3.3 Step 17, §8 classifier가 여전히 접근 가능한지 육안/코드 확인. 실패 시 Control-Flow Invariants 섹션을 SKILL.md 더 앞쪽(frontmatter 직후)으로 이동하는 re-tune 단계 수행 후 재검증. 실측 결과를 CHANGELOG 또는 본 설계 문서 appendix에 기록

### Phase 5 — 로컬 `~/.claude/commands/` 정리

- [ ] cc-cmds 관리 5개 파일 삭제: `design.md`, `design-review.md`, `design-upgrade.md`, `implement.md`, `review.md`
- [ ] 나머지 8개 파일은 그대로 유지
- [ ] 심볼릭 링크를 통한 스킬 호출이 정상 작동하는지 재검증

### Phase 6 — README 자동 생성 및 린트 스크립트 작성

- [ ] `scripts/lint-skill-invariants.sh` 작성 (T1 사양에 따라 bash) — 첫 4K 토큰 근사 내에 Control-Flow Invariants 섹션 존재 여부 검사. Phase 4 Acceptance Criteria (c) 선행 조건
- [ ] `scripts/generate-readme.sh` 작성 (T1 사양에 따라 bash 고정) — 모든 `skills/*/SKILL.md`에서 frontmatter 추출, README 표 재생성
- [ ] `Makefile`에 `lint: ; bash scripts/lint-skill-invariants.sh` 및 `readme: ; bash scripts/generate-readme.sh` 타겟 추가
- [ ] `.github/workflows/lint.yml` 작성 — PR 트리거로 `make lint && make readme && git diff --exit-code README.md` 실행
- [ ] CI 또는 pre-commit hook 적용 검증

**참고**: Phase 4 Acceptance Criteria (c) "린트 통과"가 이 스크립트의 존재를 전제로 하므로 Phase 6을 Phase 4와 **병행 또는 선행** 가능. 단일 커밋 워크플로우에서는 Phase 6 스크립트가 이미 작성되어 있어야 Phase 4 린트 검증이 수행된다. 각 `SKILL.md`의 frontmatter에 `when_to_use` 필드는 Phase 2/3/4 SKILL.md 작성 시점에 이미 포함되어야 함.

**참고**: 각 `SKILL.md`의 frontmatter에 `when_to_use` 필드는 Phase 2/3/4 SKILL.md 작성/재작성 시점에 이미 추가되어 있어야 함 (재작업 방지). 누락 시 Phase 6 스크립트 실행 전 일괄 보강.

### Phase 7 — 배포 및 사용자 안내

- [ ] cc-cmds 버전 업 (Minor bump — additive change, BREAKING 아님)
- [ ] CHANGELOG 작성 — SKILL.md 재구조화 요지 + 기대 효과(초기 로드 ~62% 감소) 기술. 사용자 조치는 불필요하고 `/plugin update cc-cmds`로 자동 적용됨을 명시. **경고 1줄 포함**: "과거에 `~/.claude/commands/`에 cc-cmds 파일을 수동 복사한 경우 해당 파일을 삭제하세요 — 스킬이 커맨드보다 우선 resolve되지만 혼동을 줄이기 위해 정리 권장"
- [ ] 태그 + 단일 커밋 + 마켓플레이스 반영 (모든 Phase 변경사항은 하나의 커밋으로 묶어 배포 — 롤백은 `git revert HEAD`로 단일 스텝)
- [ ] **Marketplace rollback 경로**: 배포 후 외부 사용자 이슈 발견 시 cc-cmds 레포의 main 브랜치를 이전 안정 버전 상태로 되돌린다. **권장 경로(non-destructive)**: `git revert <bad-commit>` 후 main에 push — 이력 보존. **최후 수단(destructive)**: `git reset --hard <stable-tag>` + `git push --force` — history 재작성으로 기존 clone과 충돌 가능, 긴급 상황에만 사용. 두 경로 모두 사용자는 평소대로 `/plugin update cc-cmds` 실행 시 롤백된 내용을 받음. 이 절차를 릴리즈 노트에 사전 기재 (CLI 플래그 기반 version pin은 미검증 → 레포 tag 롤백이 검증된 경로)
- [ ] **Dogfooding**: 배포 후 재구조화된 `/design-review` 또는 `/review`를 cc-cmds 자체 또는 새로운 설계 문서에 1회 이상 적용. 이상 없으면 안정화로 판정. 이상 발견 시 hotfix 릴리즈

---

## 5. 팀 구성 및 기여

본 설계는 다음 4인 팀의 2라운드 토론으로 도출됨:

- **cc-platform-expert** (opus): Claude Code 스킬 플랫폼 메커니즘 권위 판정
  (progressive disclosure, frontmatter 규칙, `${CLAUDE_PLUGIN_ROOT}` substitution, post-compaction 5K 재첨부 예산, 심볼릭 링크 cache 보존 등)
- **content-architect** (opus): 5개 스킬 본문을 의미 단위로 분해, 분할 경계 + 감소율 정량 제시. 리스크 이슈 제기에 대한 구조적 재작성(§8 hybrid, 유니폼 Read-gate 제안)
- **migration-risk-manager** (sonnet): 11개 risk(R1~R11) 식별, 이후 R12(post-compaction monolith truncation) 추가. M1(mandatory Read gate), M2(inline control-flow formulas), M3(platform confirmation) 미티게이션 제안
- **workflow-ux-designer** (sonnet): 단일 소스 + 심볼릭 링크 전략, `sk()` 쉘 함수, README 자동 생성, 호출 네임스페이스 분리 원칙

판정이 필요했던 주요 충돌:

- §8 Auto-Decide 배치 → 하이브리드(D1)로 합의
- Read gate 조건성 → 무조건 실행(D2)로 합의
- `_common/` 실현 가능성 → `${CLAUDE_SKILL_DIR}/../_common/...` 사용으로 해결 (dev-symlink 환경에서 logical-path resolve 실측 확인)
