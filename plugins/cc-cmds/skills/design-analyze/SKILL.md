---
name: design-analyze
description: 에이전트 팀을 활용한 제3자 설계 문서 다관점 분석 (읽기 전용)
when_to_use: 타인이 작성한 설계/리팩토링 문서를 원본 수정 없이 다관점으로 분석하고 분석 산출물(보고서/주석본/피드백)을 생성하고자 할 때
disable-model-invocation: true
usage: "/cc-cmds:design-analyze <design-doc-path> [--no-codebase] [--report-only]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "분석 대상 제3자 설계 문서 경로 (`.md`). 원본은 절대 수정하지 않음."
    - name: "--no-codebase"
      kind: flag
      default: "off (코드베이스 grounding 활성)"
      summary: "코드베이스 교차검증 비활성화 — 문서 자체만으로 분석 (doc-only 모드)."
    - name: "--report-only"
      kind: flag
      default: "off (산출물 대화형 선택)"
      summary: "Step 7 산출물 선택 대화만 건너뛰고 보고서만 생성. Step 6 워크스루(발견별 검토)는 그대로 유지 — 완전 비대화 아님(산출물 범위 한정 플래그)."
---

Analyze a third-party software design/refactoring document with a multi-perspective agent team, then render the analysis into user-selected artifacts.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication and rendered artifacts should be in Korean.

This is a **single-pass** analysis (the `review` agent-team engine adapted to prose design docs), NOT a `design-review`-style external/internal convergence loop. The source document and its entire source repo are **read-only** — every output is a new file under cwd `docs/analysis/`.

## Input

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

`$ARGUMENTS` is the path to a third-party design/refactoring document (`.md`), optionally followed by flags `--no-codebase` (doc-only mode) and/or `--report-only` (skip Step 7 artifact selection, force report-only). The first `.md` token is the document path. See Step 1 for parsing.

## Control-Flow Invariants

These rules govern the read-only safety contract and the walkthrough→artifact ordering, and MUST stay near the top of this file. Post-compaction reattaches only the first ~5K tokens with priority; a summarized-away rule here is a **silent corruption vector** — a later "helpful" turn could Edit the source document or its repo, which this skill must NEVER do. This section borrows rule-(A) position protection (first-5K placement) for a **safety** invariant rather than a control-flow/termination contract; the asymmetry with the EXEMPT sibling `review` is justified because `review` mutates nothing it could corrupt, while `design-analyze` creates files and must leave the source repo untouched.

### CFI-1 — Read-only source (hard fail-closed)
No `Edit`/`Write` may ever target `<design-doc-path>` or any path inside its source repo directory — **no exceptions**. Every output is a NEW file under cwd `docs/analysis/` (the inline annotated artifact is a *copy*; callouts are written only onto the copy). If a desired action would touch the source, it is forbidden — fail closed, do not "helpfully" edit the original.

### CFI-2 — Walkthrough → artifact ordering (no look-ahead render)
Findings resolve ONLY into artifact content (confirmed/excluded/amended/미검토), never back into the source. Step 7 selection and rendering MUST NOT begin before the Step 6 walkthrough completes or the user aborts. On abort, unprocessed findings are tagged `미검토(사용자 조기 종료)` and rendered into the artifacts with that flag (transparent, retained) — never silently dropped and never written to the source. No look-ahead rendering before the walkthrough resolves.

### CFI-3 — Observed-result precondition (anti-fabrication)
Only findings, severities, and grounding claims that an analysis agent **actually returned** may be recorded into artifacts. If a result is uncertain or unobserved, fail closed and re-verify — never fabricate a finding, a `path:line` citation, or a verdict.

### CFI-4 — Grounding honesty
In doc-only mode (source repo absent / inaccessible / `--no-codebase`), every artifact must state its doc-only scope, and doc-only inferences must NOT be presented as code-verified. `doc-code-gap` findings and `path:line` citations are suppressed in doc-only mode.

### CFI-5 — Self-terminate hygiene before re-composition
There is no shutdown to run — analysts that returned have already self-terminated. Before any Step 8 follow-up and before any team re-composition, the lead MUST (a) ensure no ledger `state=running` row survives (`TaskStop` any straggler, then ledger hygiene) and (b) re-read the ledger from disk before resuming. See `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`.

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:
- `ToolSearch("select:AskUserQuestion")` — MUST load before Step 1
- `ToolSearch("select:SendMessage")`
- `ToolSearch("select:TaskStop")`

(`Agent` is a built-in tool — no ToolSearch load needed.)

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints from that file (header ≤12 codepoints, no manual Other option, `preview` single-select only) to every AskUserQuestion call in this skill.

---

### Step 1: Source Detection & Scope Confirmation (Korean)

#### 1a: Argument parsing & source validation

Parse `$ARGUMENTS`:
- The first `.md` token is `<design-doc-path>`.
- `--no-codebase` → grounding OFF (doc-only mode).
- `--report-only` → Step 7 artifact-selection dialog skipped, report forced (Step 6 walkthrough still runs).

Validate the source document:
1. Path exists and is readable. If not, report the error in Korean and stop (normal error handling — not a CFI concern).
2. Extension is `.md`. If not, ask the user via AskUserQuestion whether to proceed treating it as markdown, or abort.
3. **Read the entire document** (parseability gate). If it is unreadable/binary/empty, surface and stop.

#### 1b: Source repo detection

Detect the git repo that **owns the source document** (NOT cwd — usually a different repo, e.g. `~/Documents/orderbook/`):

```bash
# Never use `git -C`. cd into the document's directory first, then run git.
DOC_DIR=$(dirname "<design-doc-path>")
cd "$DOC_DIR"
CODE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
```

- If `CODE_ROOT` resolves and grounding is ON → Step 2 grounds against it.
- If `CODE_ROOT` is empty (not a repo) → AskUserQuestion fallback: (a) specify a code root path directly via the `Other` channel, (b) doc-only analysis, (c) abort.

#### 1c: Scope confirmation (read-only assurance + artifact-timing pre-notice)

Present to the user (in Korean):
- Document title, section count, size
- Detected source repo (`CODE_ROOT` absolute path) or "감지된 repo 없음 → 문서 단독 분석"
- grounding ON/OFF (and reason: `--no-codebase` / repo 부재 / etc.)
- **Read-only assurance**: 원본 문서와 소스 repo는 절대 수정하지 않으며, 모든 산출물은 cwd `docs/analysis/`에 새 파일로 생성됨을 고지.
- **Artifact-timing pre-notice**: "산출물(보고서/주석본/피드백) 선택은 분석·검토 *후* 진행합니다" — do NOT present an artifact-selection prompt here.

**초대형 문서 게이트** (e.g. very long doc / many sections): inform the user of the scale and offer (via AskUserQuestion, header chip `분석 범위`) to limit analysis to a section range vs. analyze the whole document.

Proceed after user confirmation.

---

### Step 2: Grounding Setup

Skip entirely (→ doc-only mode) when grounding is OFF (`--no-codebase`, repo absent, or user chose doc-only).

When grounding is ON and `CODE_ROOT` exists, ground against the **source repo** (`CODE_ROOT`, not cwd) directly with `grep`/`Glob`/`Read`:

1. Survey `CODE_ROOT` structure (`ls`), read `CODE_ROOT`'s CLAUDE.md and .gitignore.
2. Note directories to skip when searching: `node_modules, .next, build, dist, __pycache__, .git, coverage, .turbo, .cache, out, .vercel, .output, vendor, target`.

Analysts ground claims with `grep`/`Read` directly during Step 4.

**Graceful degrade (CFI-4)**: repo absent / inaccessible `CODE_ROOT` / user rejection → doc-only mode. Suppress `doc-code-gap` findings and `path:line` citations, emit a Korean notice, and stamp the report header `분석 모드: 문서 단독`. Propagate the doc-only marker to Step 4 analyst packages and Step 5 synthesis.

---

### Step 3: Analysis Team Composition Proposal (Korean)

Propose a team based on two composition signals: (i) the document's own structure (TOC/heading + keyword scan) and (ii) grounding code exploration.

**Default lens pool** (design-doc analog of security/perf/quality):

| Lens | 한글 | 범위 |
| --- | --- | --- |
| architecture-soundness | 구조 건전성 | 레이어링·모듈 경계·결합도; 제안 구조가 성립하는가 |
| feasibility & impl-cost | 실현가능성·구현비용 | 작성된 대로 구현 가능한가; 난이도·숨은 비용 |
| migration-safety | 마이그레이션안전 | (리팩토링/마이그레이션) 데이터 손실·롤백·단계적 전환·하위호환 |
| completeness/gaps | 완전성·누락 | 누락 인터페이스·미처리 케이스·미정의 에러/엣지 |
| internal-consistency | 내부일관성 | 섹션 간 모순·명명/계약 불일치 |
| alternatives-evaluation | 대안평가 | 옵션 검토 여부·선택 근거 정당성 |
| doc-vs-code grounding | 문서-코드정합성 | (grounding ON) 문서의 코드 전제가 실제 코드와 일치하는가 |

**Document-characteristic → role triggers** (analog of review's "auth change → security reviewer"):
- 리팩토링/재작성 → migration-safety (필수) + architecture
- 신규 레이어링·모듈 → architecture
- ≥2 옵션·trade-off → alternatives
- 스키마·데이터모델 → +data-integrity
- auth·권한 → +security-design
- API·계약 → +api-contract
- 성능·스케일 주장 → +scalability
- 코드 다수 인용 (grounding ON) → doc-vs-code grounding (필수)
- 대형·다중도메인 (>~15 섹션) → +Analysis Coordinator (persistent, analog of review's Scope Coordinator)

**Model**: not fixed — propose per run with rationale (review Step 3 convention). opus → architecture/alternatives (multi-step reasoning); sonnet → feasibility/migration/consistency/grounding; haiku → mechanical completeness sweep of short docs. Bump one tier up for large/foundational docs.

**Proposal format** (Korean):

```
**문서 특성 분석:**
- 문서 유형: [리팩토링/신규 설계/마이그레이션 등]
- 섹션 수·규모: [N개 섹션, 크기]
- 핵심 신호: [감지된 특성 — 스키마 변경, auth, 코드 인용 다수 등]
- 분석 모드: 코드 grounding ON (CODE_ROOT) / 문서 단독

**제안 팀 구성:**
| 역할(렌즈) | 모델 | 담당 범위 |
|------------|------|-----------|
| ... | ... | ... |

**팀 구성 근거:**
[1-2 문장: 왜 이 구성이 이 문서 특성에 맞는가]

이 팀 구성으로 진행할까요?
```

Branch on user response: **Approve** → Step 4 / **Modification** → re-propose / **Reject** → end.

---

### Step 4: Parallel Multi-Perspective Analysis (English, team internal)

**Before assigning analysts, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the completion-signal contract, the Role↔agentId ledger schema, and shared facilitator rules. Embed the **task-assignment header** from that file verbatim at the top of each spawn/resume prompt (do NOT paraphrase — it is the self-contained contract that tells the task to deliver its result as its final return text, with no separate channel or completion prefix).

**Before building each analyst's context package, Read `${CLAUDE_SKILL_DIR}/references/01-analyst-context-package.md`** for the context package contents, lens-specific checklists, and the read-only analysis protocol (rounds, quality gate, cross-validation, convergence).

- Spawn each analyst as a **nameless background task** with the approved composition: `Agent({ subagent_type: "claude", run_in_background: true, prompt: <self-contained assignment> })`. The members ARE nameless `Agent` background sub-agents — but a one-shot isolated spawn per round is forbidden; the retained-context resume loop (resume by `agentId`, re-injecting load-bearing context each round) is what makes this a team. Record each returned `agentId` in the `"ledger"` key of `docs/analysis/.{doc-slug}.work.json` immediately (see the protocol's Role↔agentId ledger). The `{doc-slug}` still names the work.json.
- Each analyst analyzes the prose document from their lens, cross-checks against the source code (or operates doc-only), and participates in cross-validation/debate. Analysts are read-only single-pass, but still resumed across rounds for cross-review convergence.
- All team-internal discussion in English.
- **NO modifications to the source document or source repo (CFI-1). Read-only analysis only.**
- **The lead acts as facilitator**, actively driving the multi-round analysis. Completion is by **return collection** (the return text IS the result): after cross-review, resume each analyst once with a convergence prompt (re-injecting current consensus + open conflicts) until every return says "no further input". Escalation per the protocol's failure phenotypes: Case 1 (thin-return — 1st re-scope+resume, 2nd consecutive → `AskUserQuestion`), Case 2 (never-returns → `TaskStop` + fresh re-spawn, new `agentId` to the ledger), Case 3 (non-conforming return → re-assign once, recurrence feeds Case 1). This is a single pass — no external/internal convergence loop.

---

### Step 5: Synthesis & Classification (Korean)

**Before synthesizing, Read `${CLAUDE_SKILL_DIR}/references/02-analysis-report-template.md`** for the finding canonical schema, the design-specific severity/category/verdict system, and the report structure template.

The lead synthesizes all analyst results into the canonical finding set. In this step the lead (and ONLY the lead) assigns the DOWNSTREAM fields:
- **severity** (critical/major/minor) + **category** taxonomy tag
- **`[foundational]`** flag — on critical findings only, when the finding topples the document's *core approach* (local fix impossible) → splits 보류 vs 재설계
- **premise-contradiction severity floor** (doc-code-gap, monotone 3-step): 주변부 모순 → impact 기준(minor 가능) / 리팩토링 *전제* 접촉 → **major floor**(minor 금지) / 핵심 전제·접근 *무효화* → **critical + `[foundational]`** → 재설계. Floor and flag are two thresholds on the same axis (premise proximity); both applied here ("higher severity wins" per review convention).
- **verdict ladder** (replaces merge recommendation): critical==0 ∧ major==0 → **채택 권고** / critical==0 ∧ major≥1 → **조건부 채택** / critical≥1 ∧ no foundational → **보류** / foundational critical ≥1 → **재설계 권고**.

Anti-fabrication (CFI-3): only record findings the analysts actually returned.

---

### Step 6: Findings Walkthrough (read-only)

Surface findings one at a time to the user and drive each to a disposition that lands in the **확정 발견 집합** (confirmed finding set). The source document and source repo are NEVER modified (CFI-1). The menu has NO team-discussion option — the engine already ran a multi-perspective team; deep re-analysis is Step 8.

#### Walkthrough state (in-memory + scratch persist)

Since the source is untouched, there is no doc-anchored state machine. State = the lead's in-memory **확정 발견 집합**. Working state persists to cwd `docs/analysis/.<slug>.work.json` (NEVER the source). This scratch file is deleted on normal completion (path-guarded `rm` restricted to `docs/analysis/.<slug>.work.json`) and survives ONLY on user abort (audit / manual reference — NOT an auto-resume mechanism; a re-invocation re-runs analysis from scratch). If cwd is a git repo, recommend gitignoring at least `.<slug>.work.json` (or `docs/analysis/`); the report/copy artifacts may be intended commit targets.

The work.json also carries the durable Role↔agentId **`"ledger"`** key (created/updated alongside the work-state writes): an array of behavior-bearing entries `{ agentId, state, round, role, thinReturns, lastReturn }`, where `state ∈ {running, done, aborted}`. Re-read the ledger from disk before any resume phase (Step 8 follow-up); if the `"ledger"` key is missing or unparseable, **fail closed via `AskUserQuestion`** (never silent-skip). A residual `state: "running"` entry is the leftover-detection signal.

**State machine** (2 non-terminal + 4 terminal, memory-anchored):
```
pending → presented → { confirmed | excluded | amended }
            (abort)  → 미검토            # pending|presented → 미검토 on abort
추가조사: presented → presented            # loop-back, no terminal of its own
```
The terminal set {confirmed, excluded, amended, 미검토} equals the §finding-schema `walkthrough_status` enum.

#### 1 finding per AUQ (invariant)

Each `AskUserQuestion` call carries **exactly one finding** (one question). The tool's up-to-4-questions capacity is NEVER used to bundle findings — the only 4-slot budget is the per-finding **option** menu. Each surface includes:
- a Category/severity chip (e.g. `심각·문서모순`, ≤12 codepoints)
- Why-it-matters (1–2 lines)
- 근거 (doc `§anchor` + when grounded `path:line`)
- the option menu below

#### Menu → 확정집합 effect

| Option | 효과 |
| --- | --- |
| 유효(포함) | → `confirmed` |
| 무효(제외) | → `excluded` (보고서 "검토 후 제외/철회된 항목"에 투명 기록) |
| 추가조사 | lead read-only 재확인 후 동일 발견 재surface (자체 terminal 없음) |
| 수정후포함 | → `amended` (보고서 `사용자 수정` 플래그 + `amendment_note`) |

When grounded with strong doc-code-gap evidence, apply `← 추천` to `유효(포함)` (position 1, rationale in its `description` per `_common/askuserquestion.md`).

#### Abort (CFI-2)

The source cannot be batch-marked (it is untouched). On abort, remaining findings are tagged `미검토(사용자 조기 종료)` and kept in the 확정집합 (transparent, non-verified flag) — no silent deletion. Record the abort point in the work-file for audit.

---

### Step 7: Artifact Selection + Rendering

Runs after the walkthrough (the 3 artifacts are variant renders of the same 확정집합 → selection is render-time). Skip the selection AUQ when `--report-only` (force report only; the walkthrough already ran).

**Selection AUQ** (multiSelect): `question: "분석 결과를 어떤 산출물로 생성할까요? (복수 선택 가능)"`, `header: "산출물"`, options:
- `분석 보고서 ← 추천` (필수 베이스) — description: 모든 발견의 단일 source-of-truth 보고서.
- `인라인 주석 사본` — description: 원본 복사본에 발견을 콜아웃으로 주석.
- `저자 피드백 문서` — description: 저자 대상 간결 피드백 목록.

No manual Other (auto-provided). No `preview` (multiSelect).

**report = 필수 베이스 (항상 생성)**: inline/feedback are additive opt-in. 빈 선택 → 보고서; 인라인/피드백 선택 → 보고서 + 해당. report-as-dependency + 빈-선택 가드가 단일 invariant("report always present")로 통합 → `→ 보고서 §… A-NN` ref가 dangling될 수 없음.

**Rendering** — all artifacts under cwd `docs/analysis/`:
- **Read `${CLAUDE_SKILL_DIR}/references/02-analysis-report-template.md`** → `docs/analysis/<slug>.md` (always).
- **(if inline) Read `${CLAUDE_SKILL_DIR}/references/03-inline-callout-spec.md`** → `docs/analysis/<slug>.annotated.md` (byte-copy of source + banner + blockquote callouts; source untouched — CFI-1).
- **(if feedback) Read `${CLAUDE_SKILL_DIR}/references/04-feedback-template.md`** → `docs/analysis/<slug>.feedback.md`.

**Render rule (all artifacts)**: render only `confirmed`/`amended` findings; `excluded` appears ONLY in the report's "철회된 항목" (transparent); `amended` shows its `amendment_note`; `미검토` (abort) is included with its flag. After successful render, delete `.<slug>.work.json` (path-guarded).

---

### Step 8: Discussion & Follow-up (Korean)

After presenting the rendered artifacts, discuss with the user.

- **Lead direct handling** (no team): explain specific findings, re-check code via `grep`/`Read`, re-assess severity on new user context, explain exclusions.
- **Deep re-analysis** (team re-composition): when the user needs perspectives not covered, propose a fresh analyst team (Step 3 format + re-creation reason + previous coverage + additional scope), require approval, include prior findings in the new package. On approval, spawn fresh nameless background tasks (`Agent`, `subagent_type: "claude"`, `run_in_background: true`) and record their new `agentId`s in the work.json ledger.
- **`추가조사`** during the walkthrough is lead read-only — it does NOT spawn a team (that would re-introduce a heavy lifecycle); deep work is this step only.

**Before Step 8 follow-up handling AND before any team re-composition, Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** (CFI-5). There is no shutdown to run — returned analysts already self-terminated; cleanup is no-op (normal) / `TaskStop` on any `state=running` straggler (abort) / ledger hygiene. Then re-read the ledger from disk before resuming. When follow-up triggers team re-composition, ensure no `state=running` row survives the previous round before spawning the next.

Repeat until the user is satisfied.

---

## Constraints

- **Read-only source (CFI-1).** No Edit/Write ever targets `<design-doc-path>` or its source repo. All outputs are new files under cwd `docs/analysis/`.
- **Inter-agent communication in English.** User-facing communication and rendered artifacts in Korean.
- **Nameless background-task team**: Step 4 multi-perspective analysis members ARE nameless `Agent` background sub-agents (`subagent_type: "claude"`, no `name`, `run_in_background: true`). Do NOT collapse this into one-shot isolated `Agent()` calls per round — the retained-context resume loop (`SendMessage` to each `agentId`, re-injecting load-bearing context) drives the cross-validation/debate. A task self-terminates when it returns; its return text IS the result.
- **Deferred tool loading**: Before using AskUserQuestion, SendMessage, or TaskStop, load them via ToolSearch in Step 0 (`Agent` is built-in). AskUserQuestion MUST be loaded before Step 1.
- **Codebase grounding**: When grounding is ON, ground against `CODE_ROOT` (the source repo, not cwd) with `grep`/`Glob`/`Read` in Step 2 before team creation. Analysts ground claims directly. doc-only mode skips grounding and suppresses code citations (CFI-4).
- **Single pass**: no `design-review`-style external/internal convergence loop; no termination/COUNT_APPLIED math.

Task: $ARGUMENTS
