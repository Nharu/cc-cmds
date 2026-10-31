# 시각 디자인 연결 파일 계약

`visual`·`visual-unattended`·`visual-publish-unattended` 세 스킬, 구현 쌍(`implement`·`implement-unattended`), 킥오프와 오케스트레이터가 함께 읽는 연결 파일의 문법이다. 연결 파일은 둘이다 — 설계 문서 하나에 하나인 사이드카(종류 `visual`)와 레포에 하나인 디자인 시스템 연결 파일(종류 `visual-system`). 두 파일의 머리·필드·쓰기 규칙은 이 파일이 소유하고, 다른 파일은 이 문면을 읽는다. 계약의 공통 규칙(문서 키·슬러그 유도, 원자 쓰기, 비우거나 자르지 않기)은 `../../_common/sidecar.md` 를 따른다.

필드를 파싱하는 코드는 `plugins/cc-cmds/orchestrator/visual-check.sh` 하나이고, `scripts/test-visual-check.sh` 가 아래 두 예시(`### 사이드카 예시`, `### 금지 해제 예시`)를 직접 읽어 그 도우미에 돌린다. 예시를 고치면 그 시험이 함께 돈다.

## 1. 자리

```
<base>/docs/visual/<slug>.md                 # 사이드카, 종류 visual
<base>/docs/visual/<slug>.<화면 id>.html      # 화면 사본
<base>/docs/visual/support.js                # 캔버스 런타임, 모든 사이드카가 함께 쓴다
<base>/docs/visual-system/system.md          # 디자인 시스템 연결 파일, 종류 visual-system
<base>/docs/visual-system/{system.html, tokens.css, tokens.md}
```

- `<base>` 는 설계 문서가 있는 레포의 메인 워크트리 루트다 — 문서 자리에서 `git rev-parse --path-format=absolute --git-common-dir` 의 디렉터리. 세그먼트 워크트리에는 추적되지 않는 `docs/` 파일이 없으므로, 읽는 쪽은 언제나 `<base>` 로 풀어 절대 경로로 읽는다.
- 문서 키는 `git rev-parse --show-toplevel` 아래 문서의 상대 경로이고, `<slug>` 는 키에서 `.md` 를 떼고 `/` 를 `-` 로 바꾼 것이다(`docs/feature.md` → `docs-feature`).
- 화면 사본·`support.js`·토큰 파일은 정본 아티팩트의 **추출본**이라 머리가 없다. 그 소유는 파일 머리가 아니라 그것을 `**대상 경로**`·`**런타임**` 으로 고정한 사이드카와 `system.md` 가 증명한다. 추출본을 통째로 바꾸는 것은 발행·동기(대화형 국면과, 런 안에서 같은 국면을 따르는 발행 스테이지 `visual-publish-unattended`)와 무인 생성뿐이고, 언제나 같은 디렉터리 임시 파일 → rename 의 원자 교체다.
- 화면 사본은 종류 디렉터리 안에 평면으로 둔다. 하위 디렉터리를 만들지 않는다.
- 킥오프가 가져온 비공개 레퍼런스는 `<base>/docs/visual/<slug>.ref-<n>.<확장자>` 다. 무인 팔은 쓰지 않는다.

## 2. 사이드카 (종류 `visual`)

1행은 사람이 읽는 H1, 2행이 기계 머리 주석이다. 문서 수준 필드가 그 아래에 오고, 화면마다 `### 화면 <id>` 블록이 하나씩 온다.

```
# 시각 디자인 연결 — <설계 문서 키>
<!-- cc-visual v1; writer=visual|visual-unattended|visual-publish-unattended; reader=visual,visual-unattended,visual-publish-unattended,implement,implement-unattended,autopilot,orchestrator; owner-doc=<문서 키>; origin-worktree=<루트>; NOT a design doc; mechanism-local, never staged by a skill -->
**상태**: 로컬 초안 | 검토 통과 | 발행됨
**검토**: <회차>회, 마지막 판정 <ACCEPT|REJECT> (<YYYY-MM-DD>)
**검토 렌더**: 가능 | 불가(환경)
**도구**: claude-design
**기록**: <docs/pipeline-run/<run-id>.interview.md> (sha256 <값>) | (없음)
**설계 문서 구속 다이제스트**: <§4 의 정의로 잰 값>
**디자인 시스템 sha256**: <system.md sha256 | (없음)>
**스냅숏 형태**: 원본 | 보내기 | 초안
**런타임**: <docs/visual/support.js sha256> (타입 릴리스 <id>) | (없음)
**채택**: <채택한 것> — 기준 <미리 쓰인 기준> — 되돌리는 법 <명령·편집>
**다듬기**: <회차>회 — 수정 목록 <n>건 — <건너뜀 | 기계 치환 | opus | <설정 모델>>
**구현 승인**: <ISO8601> — 입력 묶음 <sha256> — 금지 목록 <sha256> — 기계 검사 수용 <규칙 id, … | 없음>[ — 사람 답 <중단 기록 파일 이름>]

### 화면 <id>
**대상 경로**: docs/visual/<slug>.<id>.html
**스냅숏**: 원본 | 보내기 | 초안
**아티팩트**: <URL | (미발행)>
**버전**: <n | (미발행)>
**sha256**: <화면 파일 sha256>
**동기 시각**: <ISO8601 | (미발행)>

### 금지 후보
- `<후보 id>` | <종류> | <설명> | <패턴 또는 -> — <회차>회 <화면 id>
```

필드 규칙:

- **`owner-doc=`** 는 문서 키 전체다. 읽는 쪽은 키 전체를 비교한다 — 접힌 슬러그가 겹치는 두 문서(`docs/visual-drift.md` 와 `docs/visual/drift.md`)는 이 비교로 갈린다.
- **`**상태**`** 는 셋뿐이다. 넷째 상태(`승인됨` 같은)는 두지 않는다 — 승인은 `발행됨` 의 속성이고 `**구현 승인**` 줄이 진다.
- **`**기록**`** 은 무인 팔이 쓴 인터뷰 기록의 `<base>` 기준 경로와 sha256 이다. 대화형 좌석은 기록을 이 필드로만 찾는다. 해시가 파일과 다르거나 판 토큰을 모르면 그 기록을 쓰지 않는다.
- **`**채택**`** 은 0줄 이상이고, 무인 팔의 `등급 1` 처분이 한 줄씩 남긴다.
- **`**다듬기**`** 는 무인·대화형 검토 루프의 회차마다 한 줄이다. 넷째 칸은 `contract.md` §7 의 강등표가 고른 처리다.
- **`**구현 승인**`** 은 0줄 또는 1줄이고, `**상태**: 발행됨` 에서만 선다. 쓰는 쪽은 둘이다 — 대화형 `visual` 의 `구현 승인` 국면, 그리고 런 안의 발행 스테이지 `visual-publish-unattended` 가 사람이 `시각-판정` 중단 기록에 `승인` 으로 답한 뒤. 동기와 다시 발행이 지운다. 둘째 칸은 §5 의 입력 묶음, 셋째 칸은 그때 읽은 호스트 금지 목록 파일 바이트의 sha256(기록만 하고 술어가 묶지 않는다), 넷째 칸은 사람이 수용한 규칙 id 의 쉼표 + 공백 목록이거나 `없음` 이다. 두 줄 이상이거나 모양이 틀린 줄은 무효다.
- **출처 꼬리 ` — 사람 답 <파일 이름>`** 은 선택이다. `<파일 이름>` 은 런 디렉터리 `halt/` 아래 중단 기록의 파일 이름 하나(`[A-Za-z0-9._#-]+\.md`, 예: `S2P#3.md`)이고 경로를 담지 않는다. 발행 스테이지는 이 꼬리를 늘 붙이고, 그 줄의 근거가 된 `시각-판정` 기록을 가리킨다. 대화형 국면은 붙이지 않는다. 계획에 그 문서를 맡은 `S2P` 단계가 있는 런에서는 꼬리가 가리키는 기록이 그 런의 가장 마지막 `시각-판정` 기록(`halt/S2P#<n>.md` 가운데 `**스텝**` 이 그 자리인 것의 실행 판 번호 최대값)이고 그 기록에 사람(`답한 주체=사람`)의 `승인` 답 행이 있을 때만 게이트가 그 줄을 채택한다. 꼬리 없는 줄은 그런 런에서 채택되지 않으므로, 그 런의 승인은 `S2P` 의 `시각-판정` 으로 받는다. `S2P` 가 없는 런과 런 밖에서는 꼬리 없는 줄이 지금처럼 다뤄진다.
- **`### 금지 후보`** 아래 줄은 검토자가 찾은 새 패턴이다. 앞부분 `<후보 id> | <종류> | <설명> | <패턴 또는 ->` 는 `contract.md` §5 의 금지 목록 한 줄 문법 그대로이고, 꼬리 ` — <회차>회 <화면 id>` 가 출처다. 대화형 `visual` 이 항목별 승인 뒤, 또는 발행 스테이지가 그 후보의 `금지-후보` 중단 기록에 사람이 `승인` 으로 답한 뒤 그 줄을 그대로 `visual-config.sh append` 에 넘기면 도우미가 꼬리와 따옴표를 떼고 덧붙인다. 승인되거나 거절된 후보 줄은 사이드카에서 지운다.
- 계정에 관한 것은 사이드카에 아무것도 남기지 않는다.

### 사이드카 예시

```
# 시각 디자인 연결 — docs/feature-checkout.md
<!-- cc-visual v1; writer=visual|visual-unattended|visual-publish-unattended; reader=visual,visual-unattended,visual-publish-unattended,implement,implement-unattended,autopilot,orchestrator; owner-doc=docs/feature-checkout.md; origin-worktree=/srv/repo; NOT a design doc; mechanism-local, never staged by a skill -->
**상태**: 발행됨
**검토**: 2회, 마지막 판정 ACCEPT (2026-10-12)
**검토 렌더**: 가능
**도구**: claude-design
**기록**: docs/pipeline-run/20261011-0a1b2c3d.interview.md (sha256 4f2a6c0d9e8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a29)
**설계 문서 구속 다이제스트**: 9c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d
**디자인 시스템 sha256**: 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b
**스냅숏 형태**: 원본
**런타임**: 7e6d5c4b3a2918f7e6d5c4b3a2918f7e6d5c4b3a2918f7e6d5c4b3a2918f7e6d (타입 릴리스 dc-2026-10-01)
**다듬기**: 1회 — 수정 목록 3건 — opus
**다듬기**: 2회 — 수정 목록 0건 — 건너뜀
**구현 승인**: 2026-10-12T09:30:00Z — 입력 묶음 0000000000000000000000000000000000000000000000000000000000000000 — 금지 목록 5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c — 기계 검사 수용 token-space

### 화면 cart
**대상 경로**: docs/visual/docs-feature-checkout.cart.html
**스냅숏**: 원본
**아티팩트**: https://claude.ai/design/p/0000-cart
**버전**: 3
**sha256**: 2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c
**동기 시각**: 2026-10-12T09:10:00Z

### 화면 pay
**대상 경로**: docs/visual/docs-feature-checkout.pay.html
**스냅숏**: 원본
**아티팩트**: https://claude.ai/design/p/0000-pay
**버전**: 2
**sha256**: 3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d
**동기 시각**: 2026-10-12T09:10:00Z

### 금지 후보
- `stat-hero-number` | 판단 | 히어로 자리에 맥락 없는 큰 숫자 하나를 둔다 | - — 1회 cart
```

예시의 해시 값은 자리 표시다. 입력 묶음 칸의 0 은 실제 파일로 다시 재면 언제나 어긋나는 값이라, 이 예시를 그대로 둔 사이드카는 `승인 무효 — 입력 묶음이 달라졌다` 로 읽힌다.

## 3. 디자인 시스템 연결 파일 (종류 `visual-system`)

주체가 문서가 아니라 레포이므로 파일 이름은 `{slug}.md` 유도가 아니라 고정 이름 `system.md` 다. 1행은 H1, 2행이 머리다.

```
# 디자인 시스템 연결 — <메인 워크트리 루트>
<!-- cc-visual-system v1; writer=autopilot|visual|visual-unattended|visual-publish-unattended; reader=visual,visual-unattended,visual-publish-unattended,implement,implement-unattended; owner-doc=(없음); owner-repo=<메인 워크트리 루트>; NOT a design doc; mechanism-local, never staged by a skill -->
**아티팩트**: <Design System 아티팩트 URL | (미발행)>
**출처**: 신규 | 레포 기존 | claude.ai 기존
**tokens.css sha256**: <값>
**금지 해제**: <id> — <사유>
```

- **`owner-doc=(없음)`** 은 명시 부재 표시다. 소유 증명은 **`owner-repo=`** 가 진다.
- **`owner-repo=` 비교 규칙**: 읽는 쪽은 그 값과 자기가 푼 메인 워크트리 루트를 둘 다 실경로(`cd … && pwd -P`)로 풀어 바이트로 비교한다. 같을 때만 그 레포의 디자인 시스템이다.
- **부재 규칙(fail-closed)**: `owner-repo=` 가 없거나, 비었거나, 실경로로 풀리지 않거나, 머리 줄의 판 토큰이 `cc-visual-system v1` 이 아니면 그 파일은 이 레포의 것이 아니라고 읽는다. 추측해 받아들이지 않는다.
- **`**금지 해제**`** 는 0줄 이상이다. 한 줄이 금지 목록 항목 하나를 끈다 — 기계 검사와 검토 루브릭이 그 id 를 건너뛰고, 보고에 건너뛴 id 를 적는다. 승인 뒤에 해제를 더해도 발견이 줄 뿐이므로 `**구현 승인**` 을 무효로 하지 않는다. `visual-check.sh scan --lifts <system.md>` 가 이 줄을 읽는다.
- `tokens.css` 는 사용자 정의 속성의 값을 바이트 그대로 담고, 테마 래퍼(`[data-theme]`, `@media (prefers-color-scheme: …)`)를 축자로 남긴다(`contract.md` §1).

### 금지 해제 예시

```
# 디자인 시스템 연결 — /srv/repo
<!-- cc-visual-system v1; writer=autopilot|visual|visual-unattended|visual-publish-unattended; reader=visual,visual-unattended,visual-publish-unattended,implement,implement-unattended; owner-doc=(없음); owner-repo=/srv/repo; NOT a design doc; mechanism-local, never staged by a skill -->
**아티팩트**: https://claude.ai/design/p/0000-ds
**출처**: 신규
**tokens.css sha256**: 6f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a3928170
**금지 해제**: gradient-text — 이 제품의 로고 글자는 브랜드 지침이 정한 그라디언트다
```

## 4. 설계 문서 구속 다이제스트

`**설계 문서 구속 다이제스트**` 는 문서 전체 sha256 이 아니다. 전체 해시는 동결 뒤에도 정상 경로에서 움직인다 — 사람이 `## 시각 정합 기준` 블록을 붙이고, 구현 팔이 검증 등급·기록 줄을 쓴다. 그래서 드라이버 `binding_digest`(`plugins/cc-cmds/orchestrator/run.sh`)의 필터에 `## 시각 정합 기준` 절 전체 제외를 더해 잰다.

1. `## 구현 시 검증 항목` 절 안의 `검증 등급:`·`구현 시 검증 기록:` 줄(불릿·굵게 모두)을 뺀다.
2. `## 시각 정합 기준` 표제부터 다음 `## ` 표제 앞까지를 뺀다.
3. 줄 끝 `\r` 과 공백을 지우고, 연속 빈 줄을 하나로, 앞머리 빈 줄을 없앤다.
4. 남은 문면의 sha256.

계산 도우미는 `visual-check.sh binding <설계 문서>` 하나이고, 무인 팔은 사이드카에 쓸 값을 이 부명령으로 잰다.
무인 팔의 재사용 판정(`visual-check.sh reuse <설계 문서> --record <기록>`)은 `**기록**` 을 경로가 아니라 sha256 으로만 대조한다 — 재킥오프된 런의 기록은 원천 기록의 바이트 복사라 해시가 같고, 경로 칸은 원천 런의 것으로 남는다.

무인 팔이 사이드카에 쓸 때와 구현 쌍이 대조할 때 이 정의 하나를 읽는다. 대조가 어긋나면 구현 쌍은 보고하고 멈추지 않는다 — 다이제스트는 승인 술어에 들지 않는다(§5).

## 5. 입력 묶음과 승인 술어

입력 묶음은 다음 줄들을 이은 문면의 sha256 이다.

```
<화면 id> <화면 파일 sha256>      # 사이드카의 화면 id 를 LC_ALL=C 정렬한 순서로 한 줄씩
runtime <support.js sha256>
tokens <tokens.css sha256>
```

없는 파일의 자리는 `(없음)` 이다. 정의와 계산은 `visual-check.sh bundle <설계 문서>` 한 곳에 있고(`--lines` 는 문면 자체), 대화형 `visual` 과 발행 스테이지가 `**구현 승인**` 을 쓸 때도 이 부명령으로 잰다. 설계 문서의 구속 다이제스트와 `system.md` 는 묶지 않는다 — 의도된 정리 편집이나 해제 추가가 승인을 지우지 않게 하려는 것이다.

술어는 `visual-check.sh approval <설계 문서>` 하나다. 사이드카가 이 문서의 것이고(`owner-doc=`), `**상태**: 발행됨` 이며, `**구현 승인**` 줄이 정확히 하나이고 모양이 맞으며, 사이드카의 화면 파일이 모두 있고, 지금 파일로 다시 잰 입력 묶음이 줄의 값과 같을 때만 `승인 유효 <hex 앞 12자>` 와 종료 0 이다. 그 밖은 `승인 없음 — <사유>` 나 `승인 무효 — <사유>` 와 종료 1 이다. 유효한 줄에 출처 꼬리가 있으면 둘째 줄 `출처 사람 답 <파일 이름>` 을 더 찍는다. 이 부명령은 꼬리의 모양만 보고, 그 기록이 `S2P` 의 가장 마지막 `시각-판정` 이고 사람의 `승인` 답이 있는지는 게이트의 승인 술어가 이 둘째 줄을 읽어 원장에서 확인한다(§2 의 출처 꼬리). 게이트의 파견 거절, 자동 해소의 갈래, `gate_close`, 구현 쌍의 Step 1, 드라이버의 브랜치 전 검사, 라우터 교대의 차례 판정이 모두 이 술어를 부르고, 저마다 다시 구현하지 않는다.

## 6. 기록 `## 시각 방향` 의 두 하위 블록

킥오프는 계획에 시각 단계가 있으면 인터뷰 기록의 `## 시각 방향` 절 안에 두 하위 블록을 쓴다. 생성 무인 팔(`visual-unattended`)은 이 사본만 읽고 호스트 설정 디렉터리를 읽지 않는다. 발행 스테이지는 모델값을 이 사본에서 읽고, 승인 줄에 sha256 을 싣는 금지 목록은 대화형과 같이 호스트 파일을 읽는다. `visual-config.sh snapshot` 이 받는 모양은 이렇다.

````
## 시각 방향
…(방향 필드)…

### 모델값
```
ds-generate = fable | 기본값
screen-generate = opus | 기본값
polish = fable | 호스트 설정
implement-large = fable | 기본값
implement-large-threshold = 300 | 기본값
```

### 금지 목록
```
# 출처: 호스트 파일
cream-background | 판단 | 크림·베이지·미색 바탕을 화면 전체 배경으로 쓴다 | -
…
```
````

- 각 하위 블록은 `## 시각 방향` 절 안의 `### 모델값`·`### 금지 목록` 표제 바로 다음의 첫 펜스 블록이다. 펜스 안의 표제는 표제가 아니다.
- `### 모델값` 블록은 `visual-config.sh models` 의 출력 그대로다 — 키마다 `<키> = <값> | <기본값|호스트 설정>`.
- `### 금지 목록` 블록은 `visual-config.sh bans` 의 출력 그대로다 — 첫 줄이 출처 주석(`# 출처: 호스트 파일` 또는 `# 호스트 파일 없음 — 씨앗 사용`)이고 나머지는 금지 목록 줄이다. `#` 줄은 주석이라 블록 전체가 그대로 금지 목록 파일로 읽힌다.
- `snapshot` 은 기록을 경로 관례 `$(dirname "$CC_PIPELINE_MANIFEST")/${CC_PIPELINE_RUN_ID}.interview.md` 로 찾고, 매니페스트 `사전 인가` 행의 `인터뷰 기록=` 이 같은 파일을 가리키는지와 `sha256=` 이 파일 해시와 같은지를 둘 다 본 뒤에만 두 블록을 낸다. 어긋나면 `시각 설정 사본 불일치 — <사유>` 와 종료 1 이다.

이 하위 블록 문법을 어느 자리가 소유할지는 아직 정해지지 않았다. 킥오프 지시문과 기록 린트가 이 모양을 쓰고 검사하게 되는 편집은 이 문단 뒤의 일이다. 그때 소유 자리가 다른 파일로 정해지면 이 절은 그 자리로 옮기고 여기에는 가리키는 줄만 남긴다. 그때까지는 이 절이 `snapshot` 이 받는 모양의 진술이다.
