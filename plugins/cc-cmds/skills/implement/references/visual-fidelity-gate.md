# Visual Oracle — 캡처·렌더·대조 (이슈 #70 게이트 상세)

`implement/SKILL.md`의 `## 시각 정합 게이트` 섹션이 참조하는 오라클 상세. 임시 조치의 일부이며 #40 `design-fidelity` 착지 시 게이트 섹션과 함께 삭제된다(`rm` 1회). 게이트의 **로드-베어링 종료/루프-상한 계약은 SKILL.md에 inline**으로 남고, 본 파일은 캡처·렌더·대조의 절차 상세만 담는다.

모든 inline Bash는 `scripts/lint-bash-portability.sh` denylist를 컨벤션상 준수한다(SKILL.md·references는 CI 스캔 대상 아니나 동일 규율 적용) — 플랫폼별로 갈리는 해시·파일 크기 조회·날짜 파싱·PCRE grep·in-place 편집·경로 정규화·역순 출력 관용구를 피한다. 이미지 dims 확인은 **macOS 한정 best-effort**다: `command -v sips`가 있으면 `sips -g pixelWidth -g pixelHeight`로 읽고, 없으면(비-macOS) 이 확인만 skip한다 — dims 확인은 로드-베어링이 아니므로 게이트는 그대로 진행한다(픽셀-diff 대리 해시는 사용자가 배제).

## 1. 프로토타입 렌더 — 자립 Chrome-headless 2-tier

플러그인 외부 스킬(개인 스킬 `playwright-cli` 등)에 의존하지 않고 자립적으로 렌더한다.

- **Tier A (선호) — 시스템 Chrome/Chromium headless**: 임의 DPR을 고정하는 유일한 tier. DPR은 오탐 억제의 1순위 레버다.

  ```
  "$CHROME" --headless --hide-scrollbars \
    --force-device-scale-factor=<dpr> --window-size=<w>,<h> \
    --screenshot="<out.png>" "file://<abs>/page.html"
  ```

  Chrome 발견 순서: `$CHROME_PATH` → `command -v chromium chromium-browser google-chrome google-chrome-stable` → macOS 앱 번들(`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` 등) → playwright 캐시의 `chrome-headless-shell`.

- **Tier B (폴백) — `npx --no-install playwright screenshot`**: Chrome 바이너리 미발견·playwright 캐시만 있을 때. `playwright screenshot` 서브커맨드에는 device-scale-factor 플래그가 없어 DPR은 1로 고정된다 — 앱 측도 DPR1로 캡처해 commensurate를 유지한다.

  ```
  npx --no-install playwright screenshot \
    --viewport-size=<w>,<h> [--color-scheme=dark] \
    "file://<abs>/page.html" "<out.png>"
  ```

- **Tier C — graceful degrade**: 둘 다 없으면 조용히 통과하지 않고 `AskUserQuestion`으로 라우팅한다(fail-open: 레시피 제공 / 이 화면 skip / 게이트 비활성). 조용한 self-disable 금지.

렌더 후 `command -v sips`가 있으면 `sips -g pixelWidth -g pixelHeight "<out.png>"`로 픽셀 dims를 확인해 의도한 뷰포트·DPR과 일치하는지 검증한다(macOS 한정 best-effort — `sips` 부재 시 이 dims 검증은 skip하고 렌더 결과를 그대로 수용하며, command-not-found로 멈추지 않는다).

## 2. 앱 캡처 — 부팅 1회·세션 재사용

레시피 발견은 SKILL.md Step 1.6a의 5-신호 알고리즘. 여기서는 부팅·재사용·teardown 규율만 상술한다.

- **부팅 1회**: 앱 부팅(cold 20–60s)은 게이트 최초 활성화(Step 3의 첫 `G_1`) 시 1회. 이후 화면·스윕은 live 앱에 navigate + screenshot만 한다. boot handle(pid/port/udid)은 out-of-tree 임시 디렉토리에 기록한다:

  ```
  BOOTDIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-visual-fidelity-{slug}.XXXXXX")
  ```

- **teardown — 가능한 종료 경로에서 best-effort**: 정상 종료·fail-closed 조기 종료·사용자 `중단`·abort 등 도달 가능한 종료 지점에서 boot handle로 앱·헤드리스 브라우저 프로세스를 종료한다(cold-boot 20–60s 프로세스가 orphan되지 않도록). fail-closed 기본 동작은 "teardown 후 보고"를 포함한다. prose-driven bash에서 trap이 커버하지 못하는 경로(compaction·프로세스 급사 등)의 orphan은 아래 하드 한도로 bound된 **수용 잔여**다. compaction으로 boot handle의 랜덤 경로가 유실되면 재사용·teardown 모두 handle 재획득에 의존하며, 재획득 실패 시 fail-closed — 기록된 pid가 있으면 teardown을 시도한 뒤 stop-and-report하고, 두 번째 인스턴스를 무턱대고 cold-boot하지 않는다.
- **하드 한도**: cold-boot 90s, 화면당 캡처 15s. 초과 시 실패로 간주(드리프트 아님) → fail-open AUQ.

## 3. 뷰포트/DPR/테마/폰트 매칭 (오탐 억제의 1순위 레버)

양측(앱·프로토타입)을 **동일 logical 뷰포트·동일 DPR·동일 테마**로 렌더/정규화한다. 폰트/AA(안티앨리어싱)/hinting 차이는 엔진 격차의 불가역 잔여로 **선언**하고 아래 denylist에 넣어, 비전 판정이 순수 antialiasing/hinting 차이는 무시하고 **구조적** 타이포 드리프트(잘못된 size step·weight·line-height·정렬)만 flag하게 한다.

**ignorable-artifact denylist** (비전 판정이 무시할 차이):

- 서브픽셀 antialiasing·글리프 hinting 차이(글자 형태 자체).
- 엔진 간 폰트 rasterization 미세 차(같은 폰트·같은 size일 때의 픽셀 단위 fringe).
- 1px 이하의 비구조적 오프셋(반올림 잔차).

이 밴드를 벗어나는 것(정렬 축 이동, size step 변경, weight/line-height 변경, radius·높이 등 지오메트리 차이)은 **구조적 드리프트**로 flag한다.

## 4. 비전 구조화 체크리스트 — 고정 7차원 스파인 + 화면별 파생 행

항상 평가되는 **고정 7차원 스파인**(이슈 #70의 5개 명명 증상을 모두 필수 셀로 포함하는 superset):

| # | 차원 | 포함 (예) | #70 증상 매핑 |
| --- | --- | --- | --- |
| 1 | 레이아웃·정렬 | 요소 위치·정렬 축 | 헤더 정렬 |
| 2 | 간격 리듬 | 요소 간 spacing·리듬 | 간격 리듬 |
| 3 | 크기·지오메트리 | 입력 필드 높이·radius·컴포넌트 치수 | 필드 지오메트리 |
| 4 | 타이포 구조 | label/helper/counter 배치(글리프 형태 아님) | — |
| 5 | 색·채움 | placeholder 색·border·text·배경 | placeholder |
| 6 | 아이코노그래피 | 스타일·stroke/fill·굵기 | 아이콘 |
| 7 | 컴포넌트 상태 완결성 | enabled/focus/error 등 상태 커버 | — |

- 각 차원은 화면당 `MATCH | DRIFT | N/A | UNCERTAIN`으로 채점한다.
- 참조에서 열거한 구체 요소(이메일 필드·비밀번호 토글 등)를 **파생 행**으로 같은 차원에 평가한다.
- **루프의 이진 표면에서는 `UNCERTAIN`을 `FAIL`로 축약**(false-PASS 방지, 안전 방향)하되 `decidability=uncertain` 태그로 사용자 채널에 별도 surface한다.

## 5. 감사 단위 (finding당)

각 finding은 다음 스키마로 기록한다(R-item이 아니라 AUQ 리포트/사이드카 payload로 전달):

- `screen_id`
- 차원 (7차원 중 하나) / 요소
- 앱·참조 이미지 경로(out-of-tree) + crop bbox
- 한 문장의 falsifiable 관측 (예: "앱 이메일 필드 높이 ≈64px, 프로토타입 ≈48px, helper 아래")
- expected vs actual
- severity (`major` | `minor`)
- decidability (`decided` | `uncertain`)
- suspected_class (theme-token | component-default | screen-local — 클래스 승격용)

## 6. flutter-web 캡처 주의 (R1 관련)

Flutter를 flutter-web으로 같은 headless Chrome를 통해 캡처하면 엔진 격차가 축소되나, CanvasKit는 텍스트를 canvas에 rasterize하므로 web 빌드도 DOM 텍스트 metric과 diverge할 수 있다. 헤더·필드 지오메트리가 ignorable-artifact 밴드 내인지는 실제 타깃 프로젝트에서 육안으로 결정한다(설계 문서 `## 구현 시 검증 항목` R1의 `구현 중` 검증 항목). 밴드를 벗어나면 simulator 캡처로 폴백하거나 denylist를 넓힌다(오탐 증가 감수).
