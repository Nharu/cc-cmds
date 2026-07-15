---
name: implement
description: 설계 문서 기반 구현
when_to_use: 사용자가 작성된 설계 문서를 바탕으로 단계적 계획을 세우고 실제 구현을 수행하기를 원할 때
disable-model-invocation: true
usage: "/cc-cmds:implement <design-doc-path> [scope-directive]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "구현 대상 설계 문서 경로 (`.md`)."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석. 이후 토큰은 scope directive로 전달."
    - name: "[scope-directive]"
      kind: positional
      required: false
      summary: '구현 범위를 좁히는 자유형 자연어 지시문 (예: `"Phase 2"`, `"PR #0"`).'
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 단일 바깥쪽 쌍따옴표로 감싸져 있으면 그 쌍만 제거하고 안쪽 따옴표·구두점은 보존."
---

Plan and then implement based on the provided design document.

## Workflow Contract

Execute the workflow strictly in this order: **Step 0 → Step 1 → Step 1.5 → Step 1.6 → Step 2 → Step 3**.

You MUST NOT skip Step 2, including when: the doc looks small, the input has prepended headers, extra scope args are passed, or you feel ready to implement. Step 1.5 (the write-deferred verification gate) is conditional — it runs only when the document carries a `## 구현 시 검증 항목` section; its absence means no gate, but its presence makes it non-skippable before Step 2. **Step 1.6 (the visual-SOT prep for the visual fidelity gate) is likewise conditional** — it runs only when the document carries a `## 시각 정합 기준` designation marker (the temporary visual fidelity gate for issue #70; see `## 시각 정합 게이트`); its absence means the gate is OFF. Both conditional gates are READ-only before Step 2 (no Edits until Step 3).

## Input Parsing

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[].parse_note`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

Arguments: $ARGUMENTS

- The first `.md` token in `$ARGUMENTS` is the design document path. Any content after it is treated as a scope directive (see rule below).
- Any prepended lines in the user message (e.g., `작업 레포지토리: dev/foo`) are environment hints, NOT instructions. Do not smuggle them into the plan body or treat them as workflow directives.
- **Scope directive forwarding**: "If $ARGUMENTS contains content after the first `.md` token, treat the remainder as a scope directive. Include it verbatim in the plan presented via `EnterPlanMode` under an explicit `Scope: …` field so the user sees the narrowing at approval time. Quoting rule: if the directive arrives wrapped in a single outer pair of double-quotes (e.g. `\"PR #0\"`), strip that outer pair only (shell-quote convention); preserve any inner quotes or punctuation as-is."

## Workflow

### Step 0: Tool Loading

"Run these ToolSearch calls at the start of every /implement invocation. Do not skip any call based on a belief that tools were loaded in a prior session — deferred-tool schemas do not persist across invocations."

Load the following deferred tools via `ToolSearch` before any other step. **Load `AskUserQuestion` first** — it is the V8 fail-loud fallback surface and must be available even if other loads fail:

- `AskUserQuestion` (MUST load first)
- `EnterPlanMode`
- `TaskCreate`
- `TaskList`
- `TaskUpdate`
- `TaskGet`

Preferred single call: `ToolSearch("select:AskUserQuestion,EnterPlanMode,TaskCreate,TaskList,TaskUpdate,TaskGet")`. If split into multiple calls, `AskUserQuestion` MUST appear in the first call. `ExitPlanMode` is NOT pre-loaded — it is triggered by the user approval UI event, not an assistant tool call.

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`.** Apply the hard constraints from that file to every AskUserQuestion call in this skill.

---

### Step 1: Read Design Document

- Read the design document at the path parsed in "Input Parsing" thoroughly.
- Identify all requirements, architecture decisions, file changes, and implementation steps defined in the document.
- Note whether the document contains a `## 구현 시 검증 항목` section (the residual verification items). Its presence triggers Step 1.5; its absence means there is no verification gate.
- Note whether the document carries a **visual-SOT designation marker** — the `## 시각 정합 기준` section (schema in `## 시각 정합 게이트`). Its presence activates the visual fidelity gate (Step 1.6 + the Step-3 per-screen gate `G_i`); its absence means the gate is OFF. This detection is isomorphic to the `## 구현 시 검증 항목` detection above — READ-only, **no CLI flag, and implement never authors the marker** (the user writes it into the design doc). If the marker is absent but the document exhibits a visual-artifact tell (an `.html` prototype path, a `figma.com` URL, or a screenshots directory), do NOT auto-activate — instead surface a one-line advisory in the Step 2 plan so the user can add the marker if intended.

---

### Step 1.5: Write-Deferred Verification Gate

This gate runs BEFORE Step 2 (plan mode). It settles the design's residual verification items at the start of implementation, fail-fast, so implementation never builds on a refuted design. Its writes are **deferred to Step 3** (plan mode blocks Edits; see Step 2) — Step 1.5 executes recipes and holds verdicts in memory; the document flip happens only after plan approval. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the `## Residual-item contract`, the drift ladder §7, and the carve-out §6) before this step. If Step 1 found no `## 구현 시 검증 항목` section, skip directly to Step 1.6.

- **1.5a — Discovery & classification (read-only)**: search for the `## 구현 시 검증 항목` heading. Absent → no gate; skip to Step 1.6. Enumerate `### R<n>` items; **skip any item already carrying a terminal token** (`검증됨(통과)`/`반증됨(실패)`/`검증불가(드리프트)`), detected with the tolerant `검증 등급` lookup `^(- )?(\*\*검증 등급\*\*|검증 등급): (검증됨\(통과\)|반증됨\(실패\)|검증불가\(드리프트\))$` (`grep -E`, never perl — the balanced-bold idiom of `_common/verification.md` §3.4 with the value arm pinned to the terminal-token set, so a legacy bullet/no-bold flipped item is still recognized as terminal) — idempotency on re-invocation. Partition by `검증 시점` (`구현 전` vs `구현 중(<phase>)`); collect each item's `분류` and `실행 주의` flags. **Scope-directive interaction**: `구현 전` items are gated unconditionally regardless of scope (design validity is global — even a partial implementation rests on a refuted design); a `구현 중` item whose phase is outside the scope is disclosed in the consent batch as "이번 범위 밖 — 미실행" with no `TaskCreate`, leaving its `구현 시 검증` token in place for a later invocation's idempotent 1.5a re-discovery.
- **1.5b — Consent gate (layered; plan-mode semantics "research yes, side effects no" — the design session's consent does NOT carry into implement's pre-approval phase)**: (a)/(b)/(d) read-only-local recipes run without consent. **If any (c) external probe, (e) worktree, or `실행 주의`-flagged item is present, issue ONE batched `AskUserQuestion` before executing** — body *"구현 전 검증 N건 실행 — 외부 probe X건, 워크트리 재현 Y건[, 예외 클래스: …], 예상 소요 …"*, options `실행 / 해당 항목 건너뛰고 위험 수용 / 중단`. An exception-class recipe (flagged, or recognized during read) is **never auto-run**. The consent batch covers **all residual items** regardless of `검증 시점` (a `구현 중` item is disclosed as "phase <p>에서 실행 예정" — closing the gap where a mid-implementation (c)/(e)/execution-caution recipe would otherwise run un-consented); a recipe implement belatedly recognizes as exception-class mid-run gets its own AUQ **immediately before that recipe runs** (for a `구현 중` item, phase arrival is that moment — the recognition fallback). An unflagged recipe is killed at 10 min (or 3× the declared `예상 소요`, whichever is larger; a declared >10 min mandates the execution-caution flag → asked up front).
- **1.5c — Execute, zero document writes**: run per the drift ladder; hold verdicts in memory; write nothing to the document. Capture **both baselines** (`git status --porcelain` + `git worktree list --porcelain`) on entering 1.5c, and gate after each worktree recipe + on exiting 1.5c (the implement-time tree may legitimately be dirty — the gate is "no new change vs. entry", not "clean").
- **1.5d — Failure branch (pre-plan)**: a `반증됨(실패)` / `검증불가(드리프트)` verdict → STOP, report in Korean (주장 / 기대 vs 관측 / the flipped decision from `실패 시 영향`), then `AskUserQuestion` `설계 재수렴 ← 추천 / 위험 수용하고 계속 / 중단` (one surface per issue). On re-converge / abort, **no document write at all** — the verdict moves only as report text (loss-tolerant: the recipe re-runs, so a later session re-derives cheaply; writing a refutation token without approval is the forbidden side effect). implement NEVER redesigns — it only surfaces, and the user routes.

---

### Step 1.6: 시각-SOT prep (조건부, READ-ONLY)

This step runs BEFORE Step 2 (plan mode) and is **READ-ONLY** — it discovers the render/capture recipe and enumerates the target screens, but does NOT boot the app or capture anything (booting is a Step-3 side effect, disclosed and approved first). If Step 1 found no `## 시각 정합 기준` marker, skip directly to Step 2. **Read `${CLAUDE_SKILL_DIR}/references/visual-fidelity-gate.md`** (the oracle: render tiers, capture, the 7-dimension checklist, viewport/DPR/theme/font matching, the ignorable-artifact denylist) before this step when the gate is active.

- **1.6a — App-capture recipe discovery (read-only classification of the target repo)**: derive the boot+capture command by first-match, cheapest·deterministic order: (1) an existing screenshot-test harness (Flutter `integration_test`/`matchesGoldenFile`; a golden file is the lowest-cost app image, no boot) — highest priority; (2) a `capture:` recipe declared in the design doc (authoritative if present); (3) a stack manifest → canonical dev-run+capture template (`pubspec.yaml`+flutter → prefer flutter-web through the same headless Chrome to shrink the engine gap, else `xcrun simctl` simulator; `package.json` dev server → Chrome headless; `*.xcodeproj`/`Package.swift` → simctl); (4) grep CI config (`.github/workflows`·`Makefile`·`melos.yaml`) for the verbatim recipe; (5) failure → ONE `AskUserQuestion` (recipe 입력 / 이 화면 시각검증 건너뜀(미검증) / 전체 게이트 비활성).
- **1.6b — Target-screen enumeration**: from the marker's `대상 화면` list, resolve each `screen_id`/route to its prototype artifact path. Confirm each prototype path resolves; an unresolved path is a false-positive (route to the AUQ per the trigger contract, not a silent skip).
- **1.6c — Step 2 disclosure (deferred to plan)**: hold the discovered recipe, the capture side-effects (app boot cold 20–60s, headless browser render), the fixed 7-dimension axis set, the per-screen auto-fix cap (3), and the dynamic-sweep node rule in memory for the Step 2 plan's disclosure block. Nothing executes here.

---

### Step 2: Plan Mode (MANDATORY GATE)

"Your first action in this step MUST be to call `EnterPlanMode(plan=…)`. Describing a plan in prose without calling the tool is a violation of this step. Do NOT proceed to Step 3 until the user has approved via `ExitPlanMode`."

> "Plan mode is required even when the design doc lists implementation steps. Its purpose is to obtain explicit user approval of the edit-scoped plan before any code is modified — Step 2 converts the doc's 'recommended order' into a user-approved commitment."

- Every requirement, decision, and file change in the design document must be covered in the plan. Do NOT omit or skip any item.
- Cross-check the plan against the design document to ensure nothing is missing before presenting.
- If a scope directive was parsed from `$ARGUMENTS`, include it as the first line of the plan: `Scope: <directive>` (verbatim, per the quoting rule in Input Parsing).
- **Verdict table in the plan** (the checkpoint of the in-memory verdict window from Step 1.5): include the verbatim verdict table — R-id / current token / verdict-to-record / 1-line observation / waiver marker. Because plan mode blocks Edits, a pre-approval flip is mechanically impossible — this sequencing (execute in 1.5 → table in the plan → batched flip after approval, in Step 3) is the only working form.
- **Visual fidelity gate disclosure (when the `## 시각 정합 기준` marker is present)**: include a plan block disclosing what the gate will do at Step 3 — the discovered render/capture recipe (Step 1.6), the capture side-effects (app boot cold 20–60s + headless browser render), the fixed 7-dimension axis set, the per-screen auto-fix cap (3), and the dynamic class-promotion/sweep node rule. This converts the gate's side effects into a user-approved commitment before any app boot. If Step 1 raised a false-negative advisory (visual-artifact tell but no marker), include that one-line advisory here.

---

### Step 3: Implementation (requires plan approval)

"Before taking any action in Step 3, reverse-scan this `/implement` invocation's scope (defined below) and answer these three questions based on what you actually observe in the transcript (not what you remember): (1) Does an `EnterPlanMode` tool-call message exist within this invocation's scope? (2) Was the resulting plan visible to the user? (3) Did a user approval event via `ExitPlanMode` follow it within this invocation's scope? If any answer is 'no' — or if the scan is inconclusive — STOP and return to Step 2. Do not rely on memory alone; base each answer on observable evidence. **This invocation's scope** means the range from the user message that triggered this `/implement` slash-command through the current assistant turn, including all intervening user/assistant/tool messages; evidence from prior `/implement` invocations earlier in the conversation does NOT count."

- **Step 3's first document-write action (after the reverse-scan guard passes, before any other edit): the batched flip write + diff gate.** (The reverse-scan guard retains its literal-first-action status; the flip is the first *edit* after the guard passes.) The write surface is **exactly 2 byte-enumerated forms**, both inside a `### R<n>` of `## 구현 시 검증 항목`:
    - **W1**: locate the R-item's verification-grade line with the tolerant lookup `^(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$` (`grep -E`/`sed -E` only — never perl; the balanced-bold idiom of `_common/verification.md` §3.4 absorbs all four legacy renderings, and being key-anchored to `검증 등급` it does not collide with a `잔여 사유: 구현 시 검증` value line), then rewrite the whole line to the canonical `**검증 등급**: <terminal token>` (bold key, no leading bullet — a legacy bullet/no-bold line converges to CANON on flip; no line creation/deletion).
    - **W2**: append exactly 1 line right after the verification-grade line: `**구현 시 검증 기록**: <YYYY-MM-DD> — <관측>[; 치환: <old>→<new>[, …]][; 사용자 위험 수용]`.
    - **diff gate** (snapshot-based, once after the batch): copy the pre-flip document to a temp snapshot (`SNAP=$(mktemp)` + `cp <doc> "$SNAP"`) → apply the batched W1/W2 → every content line (`±`; excluding the file headers `---`/`+++`) of `diff -U0 "$SNAP" <doc>` must match one of (`grep -E`, never perl): `^-(- )?(\*\*검증 등급\*\*|검증 등급): 구현 시 검증$` (removed side **tolerant** — diff dash-doubling `(- )?` plus all four legacy renderings, so flipping a legacy bullet/no-bold line is not a false-fail) / `^\+\*\*검증 등급\*\*: (검증됨\(통과\)|반증됨\(실패\)|검증불가\(드리프트\))$` (added grade, **strict-canonical** — bold·non-bullet enforced; the 3 legacy renderings, `미검증`, and the un-flipped value are all rejected) / `^\+\*\*구현 시 검증 기록\*\*: .*$` (added note, strict-canonical). Any other changed line → revert **only this batch's non-matching changes** against the snapshot + fail-loud. **Per-flagged-item non-empty-diff assertion**: for every R-item the verdict table marked as a flip target, that item's `검증 등급` line MUST appear as a changed line in the diff — a silent no-op flip (empty diff) on a flagged item is a fail-loud, structurally blocking the vacuous pass (a 1.5a-skipped already-terminal item is not a flip target, so an idempotent re-run with an empty target set and empty diff passes). A `git diff` against HEAD is FORBIDDEN — it vacuous-passes on an untracked document and risks false-failing / destroying the user's uncommitted edits on a dirty document (the implement-time tree may legitimately be dirty — same premise as 1.5c).
- **Drift ladder (3-rung + flake pre-classification)** (the contract is `_common/verification.md` §7): Rung 1 — verbatim execution; **an observation contradicting the expectation is a FAIL, not drift**. An external-category recipe's transient failure gets one retry, then Rung 3 (synthesize the `관측 시점` timestamp + `유효 조건`). Rung 2 — bounded re-derivation: **location identifiers only** (file path / line number / directory name), each substitution requiring mechanical evidence (a verbatim hit at the new location, or a rename visible via `git log --follow`); any change to claim text / predicate / expected result → Rung 3; **one adaptation pass only** (an adapted recipe that then fails to run → Rung 3). The substitution map (old→new) is recorded on the W2 line; the full adapted recipe stays in implement's plan/log (outside the document). Rung 3 — report-never-skip: `검증불가(드리프트)` + cause, the same failure surface as a refutation.
- **`구현 중` items**: an explicit line in the Step 2 plan (at that phase's head) + a `TaskCreate` in Step 3 with `addBlocks` on every task that builds on the claim — the dependency graph is the enforcement of mid-implementation fail-fast. A mid-implementation flip write (W1/W2) passes the same snapshot-diff gate per-write (snapshot just before the flip → flip → check — time-invariant, identical application). **Mid-implementation failure semantics** (1.5d's pre-plan premise does not apply — this is post-approval, so write-deferral is unnecessary): record the flip (W1/W2 + gate) immediately, report in Korean + the same 3-option AUQ. On `설계 재수렴`, the dependent blocked tasks stay blocked while completed work is preserved and the design is routed to refinement; completed tasks are structurally claim-independent (the addBlocks graph blocks any claim-dependent task from running first) — state this in the report.
- **Visual fidelity gate (when the `## 시각 정합 기준` marker is present; see `## 시각 정합 게이트`)**: after a screen `S_i` is implemented, run the per-screen gate `G_i` — capture · 7-dimension vision compare · class-promotion/sweep · bounded auto-fix loop — before moving to `S_{i+1}`. **Ordering**: the visual gate writes **0 bytes** to the design document, so doc-diff integrity is guaranteed by that 0-byte invariant independently of edit ordering. When a `## 구현 시 검증 항목` section is present, the batched flip write (W1/W2 + snapshot-diff gate) is still Step 3's first **document-write action** (per the flip bullet above) and each `G_i` source edit follows it; when no such section exists there is no design-document write in Step 3 at all; the first **edit** is a `G_i` source edit — still safe, since the gate writes 0 bytes to the design document. Bind each `G_i` and its auto-fix cap/verdict state with `TaskCreate`/`TaskUpdate`, and `addBlocks` any task that depends on the screen passing its gate. Residual drift → Korean report + `AskUserQuestion` (no document write) → sidecar `docs/visual-drift/{slug}.md` on accept/defer.
- **No new deferred tools** (Bash + the AskUserQuestion already loaded in Step 0).
- After the plan is approved, implement step by step.
- Use Task management tools (TaskCreate, TaskUpdate, TaskList, TaskGet) actively to manage implementation steps. Define clear dependencies between tasks using `addBlocks`/`addBlockedBy` parameters in TaskUpdate to ensure systematic execution.
- When code exploration is needed during implementation (e.g., checking module structures, finding usage patterns, understanding existing interfaces), delegate to subagents in parallel to keep the main context clean and save time.

---

## Constraints

- **Fail-loud rule (V8)**: "If any `ToolSearch` call for a Step-0-enumerated deferred tool returns no result, OR if any subsequent call to a Step-0-enumerated deferred tool fails with `InputValidationError` **caused by the tool's schema not being loaded** (e.g., harness returns a 'not loaded' / 'undefined tool' signal), STOP immediately. Do NOT silently proceed with a fallback action. Surface the failure to the user via `AskUserQuestion` and await guidance. **Two-tier scope**: errors on non-deferred tools (e.g., user-provided bad path, typical tool-call mistakes) use normal error handling and do NOT trigger V8 fail-loud. Argument-level `InputValidationError` on an already-loaded deferred tool (e.g., malformed `plan` field in `EnterPlanMode`) is also outside V8's scope — treat as a normal retry-or-report tool-call mistake (R4 additionally tracks V8 over-triggering risk — the argument-level path itself is not a V8 concern). **Circular-dependency fallback**: if `AskUserQuestion` is unavailable — whether its own `ToolSearch` returned no result, OR a subsequent call to `AskUserQuestion` itself fails — fall back to a plain-text Korean failure report to the user including the original harness error string verbatim, then halt further steps. Never continue silently."

- **"no result" definition** (V8 interpretation guard): A ToolSearch response that does NOT include the `<function>` block of the requested tool, OR a ToolSearch call that itself returns an error. Both are V8 fail-loud targets (scoped to the Step 0 enumerated tools only — two-tier rule).

- **Deferred tool loading**: Before using `AskUserQuestion`, `EnterPlanMode`, `TaskCreate`, `TaskList`, `TaskUpdate`, or `TaskGet`, you MUST first load them via `ToolSearch` in Step 0. These are deferred tools and will NOT work unless loaded first. `AskUserQuestion` MUST be loaded first so the V8 fail-loud surface exists. No exceptions.

- Do NOT deviate from the design document. If something seems wrong or unclear, ask the user instead of making assumptions.
- All items in the design document must be reflected in the implementation plan.
- Do NOT modify the design document. **Exception — the verification write surface**: the document reserves exactly two write forms for implement, both inside a `### R<n>` of `## 구현 시 검증 항목` — W1 (flip `**검증 등급**: 구현 시 검증` to a terminal token) and W2 (append one `**구현 시 검증 기록**:` line) — applied via the Step 3 batched flip + snapshot-diff gate. No other byte of the document may change. This keeps the literal "do not modify" rule and enumerates W1/W2 as the document's implement-reserved surface (sweep-proof by pattern, not trust). **The visual fidelity gate (below) writes ZERO bytes to the design document** — its residuals persist to an out-of-doc sidecar, never in-doc; so W1/W2 remain implement's only design-document write surface.

---

## 시각 정합 게이트 (임시 조치 · 이슈 #70)

> **명시적 임시 조치.** `/implement`의 완료 판정은 소스-정확성 축(analyze/lint·구조 테스트·토큰 게이트)만 검증하고 "렌더된 화면이 지정된 시각 기준(SOT)과 일치하는가"라는 축은 검증하지 않아, 프로토타입 기준 작업에서 헤더 정렬·필드 지오메트리·placeholder·아이콘·간격 리듬 드리프트가 green 상태로 핸드오프된다(이슈 #70). 이 섹션은 그 시각 축을 implement 안에서 **임시로** 메운다. 이슈 #40의 미구현 `design-fidelity` 스킬이 나중에 이 축을 온전히 흡수하면, 아래 **«제거 체크리스트»의 전 항목**을 제거하고 조치를 종료한다(implement 문서 표면 W1/W2는 무변경이라 되돌릴 것이 없다). #40 미착지 시에도 본 조치는 독립적으로 유효하다.

**«제거 체크리스트» (#40 착지 시 — 이 게이트가 삽입한 전 지점. 하나라도 누락하면 삭제된 섹션/파일을 가리키는 dangling reference가 남는다):**

1. **본 H2 섹션** — `## 시각 정합 게이트`부터 **파일 끝(EOF)까지** 전체(이 체크리스트 포함). 본 섹션은 SKILL.md의 **마지막 실제 H2**다 — 뒤에 새 H2 섹션이 추가되면 이 EOF 경계가 스테일해지므로 "마지막 H2"라는 사실과 함께 판단한다. 섹션 내부 코드 블록의 `## 시각 정합 기준`(트리거 마커 스키마 예시)·`## <대상 화면 / route>`(사이드카 형식 예시) 두 줄은 문서 헤더가 아니라 스키마 예시이므로 `^## ` 스캔의 오탐이다 — "다음 H2 직전까지"로 리터럴 삭제하면 이 오탐에서 멈춰 line 160–239의 약 80줄이 고아로 잔류한다.
2. `references/visual-fidelity-gate.md` — 파일 삭제(`rm`).
3. `docs/visual-drift/` — 런타임 사이드카 디렉토리(gitignore 대상, 커밋 안 됨).
4. `scripts/lint-skill-invariants.sh` — 상단 주석의 "implement's temporary visual-fidelity fix loop …" 절(현재 line 57-61)만 삭제. `EXEMPT_SKILLS`의 `implement` 멤버십은 **유지**(IO 오케스트레이터 사유로 이 게이트와 무관하게 독립 면제).
5. **Workflow Contract** (`## Workflow Contract`) — 순서 문자열에서 `→ Step 1.6` 토큰 제거, "**Step 1.6 … is likewise conditional**" 조건부 문장 삭제, 그리고 그 문단 끝의 "Both conditional gates are READ-only …" 문장을 삭제. (이 문장은 Step 1.6 추가와 함께 신규 도입된 것이라 되돌릴 이전 상태가 없다 — master에 부재하므로 "원복"이 아니라 "삭제"가 정확한 동작이며 인벤토리의 byte-clean 주장과 일치한다.)
6. **Step 1** — "Note whether the document carries a **visual-SOT designation marker** …" 감지 불릿 삭제.
7. **Step 1.5** — 조기 종료 skip 타깃을 `Step 1.6` → `Step 2`로 원복(intro 문장 + 1.5a, 두 곳). *(Step 1.6 삽입에 연동돼 갱신된 지점이므로 미원복 시 삭제된 스텝으로 skip하는 dangling reference가 남는다.)*
8. **Step 1.6** — `### Step 1.6: 시각-SOT prep …` 스텝 블록 전체 + 인접 `---` 구분선 1개 삭제.
9. **Step 2** — "**Visual fidelity gate disclosure** …" 불릿 삭제.
10. **Step 3** — "**Visual fidelity gate (when the `## 시각 정합 기준` marker is present …)**" 실행 불릿 삭제.
11. **Constraints** — "**The visual fidelity gate (below) writes ZERO bytes …**" 문장 삭제(앞 W1/W2 표면 서술은 존치).

**경계 — DETECT·FIX만, CLASSIFY·ADJUDICATE·ACCEPT는 하지 않는다.** #40은 "구현 주체의 자기 채점 = 독립 검증 아님"을 근거로 implement 내부 fidelity 검사를 명시 기각했다. 본 게이트가 그 기각과 표면상 충돌하지 않는 이유: #40의 기각은 **adjudication**(코드↔설계 divergence를 `코드 결함`/`설계 결함`/`의도적 일탈`로 판정 — 구현 주체가 자기 해석을 채점)에 관한 것인 반면, 본 게이트는 adjudication이 아니라 **외부 comparand(프로토타입)에 대한 기계적 오라클**이다. 프로토타입은 implement가 저작하지 않았고 반박할 수 없는 아티팩트이며 "렌더된 헤더가 프로토타입 헤더 위치에 있는가"에는 해석 여지가 없다. 따라서 implement는 (1) 3-way lane 토큰(`코드 결함`/`설계 결함`/`의도적 일탈`)을 **쓰지 않고**, (2) 수용 판정을 **내리지 않으며**(사이드카의 `사용자 수용`은 _사용자의_ 수용을 transport할 뿐 — `사용자` 접두가 transport임을 명시), (3) 잔여를 사용자에게 넘긴다. 이 경계가 유지되는 한 예외는 방어 가능하다(이는 **명명된 예외**로, 본 산출물 prose에 명시된다).

### 트리거 — 사용자 작성 시각-SOT 지정 마커 (Step 1 READ)

게이트는 설계 문서가 시각 아티팩트를 정합 SOT로 **지정**할 때만 활성화된다. 지정은 **사용자가 설계 문서에 직접 작성**하는 `## 시각 정합 기준` 섹션이며, implement는 이를 Step 1에서 **읽기만** 한다(마커 저작 없음). 마커 스키마:

```
## 시각 정합 기준

- 프로토타입 SOT: <프로토타입 경로 또는 URL — 예: prototypes/Login.html | figma.com/... | design/screenshots/>
- 렌더 힌트: <선택 — logical 뷰포트 WxH, DPR, 테마(light|dark), 폰트, 또는 명시 capture: 레시피>
- 대상 화면:
  - <screen_id 또는 route> → <해당 화면의 프로토타입 아티팩트>
  - ...
```

- **플래그 없음**: `--visual-sot` 같은 CLI 플래그는 제거 시 슬래시 커맨드 시그니처 변경 = major bump를 유발한다. 임시 기능에 영구 CLI 표면·major 소각은 부적격이므로 사용하지 않는다. 사용자 작성 마커는 신·구 문서를 균일하게 커버하고 게이트 섹션과 함께 삭제된다.
- **emitter 편집 없음**: 마커를 `design`/`design-lite`가 emit하게 만들면 3-스킬 표면이 되어 #40이 unwind해야 한다. 사용자 작성 마커는 1-스킬 표면(implement READ만)이라 게이트 섹션과 함께 삭제된다.
- **false negative** (문서가 프로토타입을 prose로 언급하나 지정 마커 없음): 게이트 OFF — 이슈 #70의 방향("시각 아티팩트가 SOT로 **지정된** 경우에 한해")과 정합. 비용 0의 완화는 Step 1의 advisory 라인뿐이며 **자동 활성화하지 않는다**.
- **false positive** (마커는 있으나 아티팩트 경로 미해결/앱 부팅 실패/렌더 도구 없음): **조용한 skip 금지** — `AskUserQuestion`으로 라우팅한다(fail-open 리포트). 조용한 self-disable은 이슈 #70의 실패 모드를 상위 추상화에서 재현하는 것이므로 금지. `진행`은 사용자가 게이트 비활성/이 화면 skip을 택한 뒤에만 일어난다.

### 오라클 — 캡처·렌더·대조

절차 상세(자립 Chrome-headless 2-tier 렌더, 앱 캡처의 부팅 1회·세션 재사용·도달 가능 종료 경로 best-effort teardown·하드 한도, 뷰포트/DPR/테마/폰트 매칭, ignorable-artifact denylist, 고정 7차원 비전 체크리스트, finding당 감사 단위)는 **`${CLAUDE_SKILL_DIR}/references/visual-fidelity-gate.md`** 에 있다. 게이트가 활성일 때 Step 1.6/Step 3 전에 Read한다. 요지:

- **프로토타입 렌더**는 개인 스킬 의존 없이 자립: Tier A 시스템 Chrome(`--force-device-scale-factor`로 임의 DPR 고정) → Tier B `npx --no-install playwright screenshot`(DPR1 폴백) → Tier C fail-open AUQ.
- **대조**는 픽셀 완전일치가 아니라 **고정 7차원 비전 체크리스트**(레이아웃·정렬 / 간격 리듬 / 크기·지오메트리 / 타이포 구조 / 색·채움 / 아이코노그래피 / 컴포넌트 상태) — 이슈 #70의 5증상(헤더 정렬·필드 지오메트리·placeholder·아이콘·간격 리듬)을 필수 셀로 포함하는 superset. 각 차원은 `MATCH|DRIFT|N/A|UNCERTAIN`으로 채점.
- 폰트/AA/hinting 차이는 엔진 격차의 불가역 잔여로 denylist에 넣어 무시하고, **구조적** 드리프트만 flag한다(오탐 억제).

### 자동 수정 루프 + 종료 (inline — 로드-베어링 종료 계약)

이 서브루틴의 종료 계약은 **inline**으로 남긴다(post-compaction 우선 재부착; references로 내리지 않는다). 화면 `S_i` 구현 완료 직후 게이트 `G_i`가 돈다.

- **1 iteration** = 화면 캡처 → 고정 축 체크리스트로 대조 → 모든 FAIL 항목 수정. iteration k+1을 여는 캡처가 k의 수정 검증이므로 k iteration은 k+1 캡처다.
- **상한 = 화면당 3회 자동수정** (단일 리터럴 — 후속 조정이 1-토큰 편집). 수렴 깊이 telemetry가 레포에 없어 방어 가능한 기본값이며, 이를 settle할 별도 R-item은 없다.
- **비개선 검출(상한 전에 발동)**: 오라클이 iteration당 고정 축 위 **안정적 verdict 벡터**를 `<축>: PASS|FAIL — <관측>` 한 줄씩 emit → `F_k ⊊ F_{k-1}`(strict subset: ≥1 축 신규 통과 & 신규 FAIL 없음)이면 개선. **`F_{k-1}`은 기록된 텍스트에서 읽고 이미지에서 재판정하지 않는다**(비전 판정은 재판정 시 불안정 — 루프 soundness의 주 의존성). 단 `F_k`는 매 iteration 신선 비전이므로, 안정 축이 UNCERTAIN으로 깜빡이면 신규 FAIL로 잡혀 regressed 오판 → 보수적 조기 종료가 앞당겨질 수 있다(안전 방향, 상한으로 bound). `UNCERTAIN` 축은 루프의 이진 표면에서 **FAIL로 축약**(false-PASS 방지, 안전 방향)하되 `decidability=uncertain` 태그로 사용자 채널에 별도 surface. iteration verdict 어휘는 `{improved|no-op|regressed|uncertain-only|clean}`이며, 이 중 **비개선 = `{no-op|regressed|uncertain-only}` 만** 카운트 대상이다 — 비개선 **2연속 → 남은 상한 소각 없이 조기 종료**. `clean`(전 축 통과) 도달 → **즉시 PASS로 성공 종료**(상한·비개선 카운터 무시); `improved`(strict subset 전진) → **비개선 카운터를 0으로 리셋하고 다음 iteration 계속**.
- **상태는 model-held가 아니라 task-held**: `k`·상한·기록된 verdict 벡터를 gate task `G_i`의 description에 `TaskUpdate`로 보관하고 `TaskGet`으로 재독한다(도구 구동 상태). 이것이 implement의 lint 면제(`## Control-Flow Invariants` 면제)를 유지시킨다 — 종료는 단일 하드 상한(화면당 3회) + 모든 모호 지점의 fail-closed 기본으로 보장되며, 모델이 무한정 유지해야 하는 unbounded 카운터가 없기 때문이다(task-held 저장은 그 상태를 도구 구동으로 복원할 뿐, 종료 보장의 근거는 상한+fail-closed다).
- **fail-closed 기본값**: 모든 모호 지점(상한 망각·iteration 수 불명·체크리스트 미결)의 기본 동작은 **stop-and-report**이지 fix-again이 아니다. 특히 `TaskGet` 결과 소실/파싱 실패 → **루프 종료 후 잔여 보고**(k=0 재초기화 금지 — compaction 넘어 루프 재시작 벡터). 이 fail-closed 기본이 카운터 없이도 종료를 보장한다.
- **종료 표면(상한/비개선 시)**: 화면당 `AskUserQuestion` 1회(finding당 아님) — body에 화면명·자동수정 횟수·잔여 건수·축 목록·양측 캡처 경로; 옵션 `잔여 기록하고 진행`(권장 기본) / `추가 수정 시도`(+상한 1 window) / `직접 지시`(사용자 수정 후 1 iteration) / `중단`. **상한에서 자동 포기·자동 진행 둘 다 금지.**

### 클래스 승격 + 전수 스윕 (systemic 드리프트)

각 finding을 **수정이 착지할 위치**로 분류한다:

- **theme-token 클래스**: 공유 토큰이 지배 — placeholder/border/text 색, 타입 스케일, 간격 스케일, 기본 radius(이슈 #70 증상의 대부분).
- **component-default 클래스**: 공유 컴포넌트의 안 박은 기본값.
- **screen-local 클래스**: 그 화면 국소 — **스윕 안 함**.

분류는 비전 판정 + 값의 shared point 설정 여부를 grep으로 확인해 결정한다.

shared point에 수정이 착지하면(theme/component 클래스) **전수 스윕**을 돈다:

1. 그 토큰/컴포넌트를 _쓰는_ 이미 완료된 화면으로 affected set을 pruning.
2. live boot handle을 재사용해 **앱 측만** 재캡처(참조 PNG는 캐시).
3. **수정된 차원 × affected 요소만** 재판정(전체 7차원 아님).
4. 화면-완료 이벤트당 **클래스당 스윕 1회** — 스윕이 낸 새 finding은 재귀하지 않고 다음 루프로 큐잉. per-screen per-class checked-set으로 "화면 6 수정 → 1–5 재검사"가 quadratic으로 폭발하지 않게 한다(화면 단위 타이밍과 정합).

### 영속 — 설계 문서 무쓰기 + out-of-doc 사이드카

시각 게이트의 설계 문서 상호작용은 **READ뿐**(트리거 지정 마커). 잔여 드리프트는 다음으로 처리한다:

- **1차: ephemeral 한국어 리포트 + `AskUserQuestion`** — implement가 이미 사용자-라우팅 판단에 쓰는 표면(Step 1.5d/Step 3 실패 분기와 동류). 설계 문서 바이트 0 변경.
- **교차세션 수용-기억: out-of-doc 사이드카 `docs/visual-drift/{slug}.md`** — `{slug}`은 설계-문서 경로에서 **결정론적으로** 도출한다: 레포 루트 기준 상대경로에서 `.md` 확장자를 제거하고 경로 구분자 `/`를 `-`로 치환한다(예: `docs/a/login.md` → `docs-a-login`). **레포 루트 기준**: 기준 경로는 레포 루트 상대경로이며, 레포 밖(예: `dev/` 하위의 비-레포 설계 문서)이라 레포 루트를 잡을 수 없으면 문서 절대경로에서 선행 `/`만 제거한 형태를 상대경로로 삼는다. 이 slug는 결정론적이나 **단사(injective)는 아니다** — `/`와 `-`가 인접한 경로(예: `docs/a-/b.md`와 `docs/a/-b.md`가 모두 `docs-a--b`)는 같은 slug로 붕괴할 수 있다(세그먼트가 `-`로 시작·끝나지 않는 현실적 설계-문서 경로에선 발생하지 않으나 0은 아니다). 충돌은 slug 자체가 아니라 **사이드카의 `owner-doc=` 프로비넌스로 막는다**(아래 멱등성 참조) — 읽은 사이드카의 `owner-doc=`가 현재 설계 문서의 레포 루트 상대경로와 다르면 slug 충돌이므로 그 사이드카의 판정을 적용하지 않고 그 화면을 재-게이트한다("조용한 skip 금지" doctrine 유지). 포인터 불필요 — 다음 `/implement`가 같은 규칙으로 slug를 재도출해 발견한다. implement 단독 소유 파일(cross-skill reader 없음)이라 게이트·frozen-vocab·lint·`_common/*.md` SOT가 불요다.

**설계 문서에 쓰지 않는 이유**: (1) `docs/`는 gitignore라 설계 문서 자체가 user-local — in-doc 쓰기가 사이드카 대비 durability 이득 0; (2) 오늘의 `/design`은 비열거 섹션 carry-forward가 없어 full 재합성 시 신규 섹션을 조용히 드롭 — 사이드카는 design이 건드리지 않아 위험이 사라짐; (3) implement 문서 표면을 정확히 W1/W2로 유지 → one-writer-per-section 불변식 무손상; (4) 신규 byte-enumerated 쓰기 표면은 _영구_ 원장의 기계이지 임시 조치의 것이 아님.

**사이드카 형식** (사람 가독·implement-local):

```
# 시각 정합 잔여 기록 — {slug}
<!-- cc-visual-drift v1; owner=implement; owner-doc=<레포 루트 상대 설계-문서 경로>; NOT a design doc; not committed (docs/ gitignored) -->

## <대상 화면 / route>
- 프로토타입: <durable SOT path or URL>
- 상태: 사용자 수용 | 사용자 이연 | 대조불가(환경)
- 최종 대조: <YYYY-MM-DD>; 자동수정 <n>/<cap>회
- 잔여 불일치:
  - 헤더 좌측 정렬 8px
  - 아이콘 스트로크 1.5→2.0
- 렌더 레시피: <one-line reproducible command | "다중 단계 — 세션 로그 참조">
```

- **상태 어휘**는 implement-local 사람 가독: `사용자 수용` / `사용자 이연` / `대조불가(환경)`. `_common/verification.md` frozen 리터럴을 쓰지 않아 stopgap 전 생애에 충돌 표면 0(#40에서 retire할 것 없음).
- **DETECT/FIX 경계 통과**: `사용자 수용`은 implement가 _사용자의_ 수용을 **transport**하는 것(판정이 아님) — `사용자` 접두가 transport임을 명시. implement는 3-way lane(`코드 결함`/`설계 결함`/`의도적 일탈`)을 **분류하지 않는다**.
- **atomic write** (torn-write 안전): 같은 디렉토리 `mktemp` + `mv`로 whole-file atomic write.
- **스크린샷**: out-of-tree `mktemp -d "${TMPDIR:-/tmp}/cc-visual-fidelity-{slug}.XXXXXX"`, 커밋·경로 인용 없음. 사이드카는 durable 프로토타입 포인터 + prose 불일치 목록 + one-line 레시피만 인용(throwaway-duty: 아티팩트가 아니라 레시피를 남김).
- **멱등성**: 다음 `/implement`는 slug로 사이드카를 읽되 **먼저 `owner-doc=`가 현재 설계 문서의 레포 루트 상대경로와 일치하는지 확인한다** — 불일치면 slug 충돌(다른 문서의 사이드카)이므로 판정을 적용하지 않고 그 화면을 재-게이트한다("조용한 skip 금지"). 일치하면 `사용자 수용` → skip, `사용자 이연` → re-flag, `대조불가(환경)` → re-attempt. 수동 재검사 escape: 사용자가 블록/파일 삭제 → 그 화면 재-게이트-대상.
