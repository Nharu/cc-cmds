---
name: design-reconverge
description: 반증된 검증 항목이나 설계 결함 발견 하나에 스코프된 재수렴 — 설계를 고치고 두 값 판정 후 정지 (무인)
when_to_use: 자율 파이프라인 드라이버가 사다리 R2(재설계) 레인에 진입할 때, 라우터 교대가 구현 단계의 잔여 항목 반증(implement-unattended Step 1.5d 또는 Step 3 구현 중 반증 중단)을 재수렴으로 파견할 때, 사람이 감사 종합 질문의 후보 요구를 채택해 라우터 교대가 재수렴으로 넘길 때, 또는 구현 단계의 구속 티어 이탈 중단(implement-unattended CFI-U3)에 사람이 `재수렴` 을 골라(또는 매니페스트의 `구속-이탈` 자동 채택 행으로) 라우터 교대가 넘길 때, 또는 확인 리뷰 상한의 P0 잔존으로 끝난 런의 후속 런이 첫 단계에서 재수렴을 골랐을 때, 또는 무인 설계 사다리 정지에 사람이 `골격 재검토` 를 골라 라우터 교대가 `잔여 동결 재검토` 범위로 넘길 때(사람 답이 재부착이 아니라 재수렴으로 가는 예외), 또는 무인 감사가 상한 안의 회차에서 골격급 결함을 내고 게이트가 그 감사 키에 자동 재수렴을 열어 라우터 교대나 구동기가 `감사 골격급` 범위로 넘길 때. 사람이 참여하는 재설계는 `/cc-cmds:design`으로 처음부터 다시 수렴할 것
disable-model-invocation: true
usage: "/cc-cmds:design-reconverge <design-doc-path> <scope>"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "재수렴 대상 설계 문서 경로 (`.md`). 드라이버와 라우터 교대가 메인 워크트리 절대 경로로 넘긴다."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석."
    - name: "<scope>"
      kind: positional
      required: true
      summary: "재수렴 스코프. `R<n>` 형태의 잔여 검증 항목 식별자, `(정규화 파일 경로, 카테고리 태그)` 형태의 문제 동일성, `감사 종합 요구 <중단 기록 절대 경로>` 형태의 채택된 감사 종합 요구, `구속 티어 이탈 <중단 기록 절대 경로>` 형태의 사람이 재수렴을 고른 구속 티어 이탈, `설계 수준 잔여 <리뷰 리포트 절대 경로>` 형태의 확인 리뷰가 설계 수준으로 분류한 잔여 발견, `상한 P0 잔여 <리뷰 리포트 절대 경로>` 형태의 앞 런이 확인 리뷰 상한에서 남긴 P0 발견, 또는 `잔여 동결 재검토 <중단 기록 절대 경로>` 형태의 사람이 `골격 재검토` 를 고른 사다리 정지, 또는 경로 없는 문구 `감사 골격급` 형태의 무인 감사가 상한 안의 회차에서 낸 골격급 결함(보고서는 설계 문서에서 유도한다)."
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 비어 있으면 중단 기록을 남기고 정지 — 스코프 없는 재설계는 이 스킬이 하는 일이 아니다."
notes: "전면 재수렴이 아니다. 넘겨받은 스코프 하나만 고치고, 두 값 판정과 고정 리터럴을 남기고 정지한다. 팀 라운드는 사다리 R3에서만 열린다."
---

Re-converge a design document against **one** scoped defect, then stop — **without ever asking a human**.
Internal agent communication is in English to optimize token usage. Saved documentation is in Korean.

This is a **scoped repair, not a re-run of design.** It is entered from the escalation ladder's redesign rung, from the routing shift when an implement stage refuted a residual item, before implementing (its Step 1.5d) or during it (its Step 3), from the routing shift when a person adopted the composed requirement an audit's synthesis question asked about, from the routing shift when a person answered an implement stage's binding-tier stop with `재수렴`, from the first step of a successor run whose predecessor ended with P0 left at the re-check cap, or from the routing shift when a person answered an unattended design stage's residual-ladder halt with `골격 재검토` — the one person's answer to a design stage that comes back as this pass rather than as a re-attachment — or, up to the audit key's re-convergence cap, from the routing shift or the driver when an unattended audit's pass found skeleton-grade defects; it touches only what the scope names, and its terminal verdict routes the run back to segment planning — inside the same run.

## What this skill is, and what it is not

The pipeline's slow lane needs a redesign that runs unattended. Putting a mode branch inside `/cc-cmds:design` would fork exactly the region its own control-flow invariants protect, so this is a **separate command** — the same shape this repo already used when a command with a different termination contract replaced its predecessor rather than growing a flag.

It also gives the re-convergence carrier a reader. `_common/sidecar.md` `## 2` has defined `docs/design-reconverge/{slug}.md` — nineteen fields, two write forms, a frozen tail, a terminator — with **nobody referencing it**. This skill is its reader.

**What this skill never does**: propose a design of its own beyond the scope it was handed, run a full team discussion (that budget belongs to the ladder's next rung), or ask a human anything.

## Halt record — the disposition for every point that would have asked

Read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4 for the schema. Path: `${RUN_DIR}/halt/<stage-id>.md`, `RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`. `<run-id>` is re-derived from `<base>/docs/pipeline-grant/{slug}.md`. **Prefer the driver-exported `CC_PIPELINE_RUN_ID`** (with `RUN_DIR` from `CC_PIPELINE_RUN_DIR`); the re-derivation below is the fallback for a driver older than those variables, and it resolves only for a run started from a document — a manifest run keys its grant on the run id instead. `<stage-id>` comes from the driver-exported `CC_PIPELINE_STAGE_ID`, defaulting to this skill's name. Write it atomically (`sidecar.md` §1.3), record the question and every option **verbatim**, each option on its own `- \`<label>\` — <description>` line under `**선택지**:`, then take no further step and end the turn. **Never write a pipeline sidecar** — the driver is their sole writer.

**A halt with options carries a recommendation.** Every S1, S3 and S4 halt of Step 3 that offers options puts a `**추천**` line and a `**추천 근거**` line after the option lines and before `**하네스 오류**`, by the writer rules of `_common/pipeline-sidecar.md` §4 (the bullet on `**추천**`). The seat answers such a halt with the recommended label and no person, so the label is the option this pass would have chosen from the interview record, the manifest's authorization, a fact of this machine or a standing instruction — never one no stage of the run can carry out, never one whose description carries `위험 수용`, `게이트 비활성`, `그대로 진행` or `범위 축소`, and `(없음) — <what only a person knows>` when those four do not settle it. **A team round is an option no stage of the run carries out**: the ladder's second and third rungs both dispatch this skill, which holds no team rounds, so an S4 halt offering `escalate to team round` beside `record in the unresolved-issues section` recommends the latter, and the requirement left unmet is written into the document's unresolved issues where the morning report shows it. A halt whose answer needs a change to an enforcement surface outside the declared files recommends `(없음)`. **An option whose resumed work relaxes a check on an act that reaches prod** — a bundle that retries a prod apply under a looser condition, for instance — is recommended only when all three hold: the manifest's `적용 주체` is the pipeline, not a person; the manifest carries a `사전 인가` row for the request the resumed work sends to prod; and the run's `종료 지점` reaches prod. When any one fails, recommend another option or `(없음)`. **Every such S1, S3 and S4 halt also carries a `**선택지 리스크**` line** after `**추천 근거**`, by the bullet on `**선택지 리스크**` in the same section: one risk per option from that halt's facts, an option no stage carries out included — the risk of `escalate to team round` is that no in-run route assembles the team, so the answer stops the run on a person again.

### Per-grade disposition

The base skill marks each of its ask points with a judgment grade
(`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`). This arm's disposition is
per grade, not one blanket rule — a blanket rule is what made the inversion
undecidable, because "it would have asked" says nothing about whether an answer
was choosable.

- **`등급 0`** — no disposition is needed. An already-written rule fully
  determines the answer, so there was never a question at this point.
- **`등급 1`** — adopt the recommended option, write a `자율 승인` row carrying
  `등급`, `기준` (the authored standard that chose it) and `되돌리는 법` (the
  concrete command or edit that undoes it), and continue. A choice for which no
  `되돌리는 법` can be produced is **not** grade 1 whatever its mark says: the
  field is a condition, not documentation of one.
- **`등급 2`** — write the halt record above and stop. This is the branch that
  keeps "leave most of it to the orchestrator" from becoming "the orchestrator
  waived the check you asked for".

The grades are a marking, not a proof. Nothing here checks that a point marked
`등급 1` deserved it; `scripts/lint-judgment-grade.sh` counts marks and matches
dispositions, and says so.

### A halt carries the scope and the Step 1 baselines

Every halt record this skill writes after Step 1 carries, in its `**관측 상세**`, the scope it was handed and the baselines Step 1 took — the record is what a fresh session given a person's answer starts from, and it cannot recompute them once this attempt has edited the document:

- `범위=<the scope as handed>` — for an `R<n>` scope exactly `범위=R<n>`. The gate compares a carried answer's `R<n>` with this value and hands the answer on only when they are equal.
- `사전 sha256=<64 hex>` — Step 1's `사전 sha256`.
- `사전 구속 표면 다이제스트=<64 hex>` — Step 1's `사전 구속 표면 다이제스트`: the gate's `binding-digest` output over the document as Step 1 read it.
- `지금 sha256=<64 hex>` — when this attempt already wrote to the document before halting, the document's `shasum -a 256` after that write.

A record without both baselines is one the gate does not hand to a fresh session: the answer then goes back only to this attempt's own session.

### An option whose outcome is already fixed carries the machine settlement line

Sometimes this pass stops with its edit already written and its verdict already known, only to ask a person how that edit is to land. Once a person answers with that option, what a resumed session would do is hash the document and end with the verdict it already had — so the gate settles such an answer by itself, without a session, when the option says exactly what the outcome is. Write an option's description in the machine settlement grammar of `_common/pipeline-sidecar.md` (the paragraph on settling a halted re-convergence), as the whole line,

```
- `<label>` — 검사 sha256 <document>=<64 hex> → 종단 재설계 필요
```

or `… → 종단 불필요`, with nothing after the verdict, **only when all of these hold**:

- the scope is `감사 종합 요구 <record>` or `구속 티어 이탈 <record>`. Never for an `R<n>` scope — its carrier block is closed only by a session — and never for any other scope;
- the edit that option leads to is already on disk, so the answer adds no write to the document;
- the verdict is computed now, the way Step 4 computes it: Step 1's `사전 구속 표면 다이제스트` against what `<gate absolute path> binding-digest --manifest "$CC_PIPELINE_MANIFEST" -- <document path>` prints over the document as it stands.

`<document>` is the main-worktree absolute path the scope was dispatched with, and `<64 hex>` the document's `shasum -a 256` as it stands — the value the record's `지금 sha256` carries. The gate settles the answer only while the document still hashes to that value; any other answer, and a settlement the gate refuses, is handed on to a session as before. Every other option keeps its ordinary description.

### Re-entered with a carried answer

A fresh session can be handed a person's answer to an earlier attempt's halt: the routing shift's carry act writes an answer card and the stage starts with `CC_PIPELINE_HALT_ANSWER` set to its path. When it is set, at Step 1:

1. **Read the card and check the digest.** Its `**중단 기록**` is the earlier attempt's halt record and `**기록 다이제스트**` that record's sha256. Compute `shasum -a 256` of the record and compare; a difference is a halt with `분류: precondition-failed` naming both values — the answer was given to other bytes.
2. **Take the baselines from the record, never from the disk.** `사전 sha256` and `사전 구속 표면 다이제스트` in the record's `관측 상세` are this pass's Step 1 baselines, and the verdict compares against them: the earlier attempt may already have edited the document, and a hash taken now would measure that edit as the starting point. The record's digest came from the gate's `binding-digest`, and Step 4 computes the after side with the same command, so the two compare like for like. Then compare the document's `shasum -a 256` now with the record's `지금 sha256`, or with its `사전 sha256` when the record carries no `지금 sha256`. A difference means the document moved after the halt: do not apply the answer — write a new halt record naming both values, with the card's path in its `관측 상세`.
3. **Enter at the step the record names**, from what is on disk, and apply the card's option there as the answer to the record's `**질문 문면**`. Do not ask that question again.
4. **If the question computed there is not the record's**, do not apply the answer: write a new halt record for the question computed now, with the card's path in its `관측 상세`.
5. **Never rewrite the carried record** — the card's `**중단 기록**` belongs to the earlier attempt, and the answer is bound to its digest.

## Control-Flow Invariants

These rules govern termination and MUST stay near the top of this file. Post-compaction reattaches only the first ~5K tokens with priority, and the model's default behaviour when handed a design defect is to keep improving the design — so a summarized-away rule here does not degrade quality, it **removes the stop**.

### CFI-0 — Fixed constants (single source of truth)

```
SCOPES_PER_INVOCATION = 1
TEAM_ROUNDS = 0
ADJUSTMENT_PASSES = 1
VERDICT_VALUES = 2
```

These four lines are the **only** place any of these values appears in this skill. Every other mention refers to them by name.

### CFI-1 — One scope, and it is given, never chosen

Exactly `SCOPES_PER_INVOCATION` scope per invocation, taken verbatim from `$ARGUMENTS`. A defect noticed while working that lies **outside** the scope is recorded in the verdict's residual list and **not fixed** — fixing it would make this command's blast radius unbounded and would silently widen a change the run's permission cutpoint authorized against a narrower description. An empty or unparseable scope is a **halt**, not a licence to redesign broadly.

### CFI-2 — No team round

`TEAM_ROUNDS = 0`. This command does not call `Agent()` for a discussion round. The ladder opens exactly one place for a team round — its deepest rung — and this is not it; spending one here would consume that budget one rung early and, worse, would do it inside the rung that is supposed to be the cheap one. Read-only exploration subagents are permitted and are not a round.

### CFI-3 — One adjustment pass, then HARD STOP

`ADJUSTMENT_PASSES = 1`. The pass consumes the scope exactly once, edits the design document once, writes the verdict, and exits. It **MUST NOT** re-open its own edit as new input, and it **MUST NOT** iterate toward a better design. There is no second pass and no "one more look": a further re-convergence is a **new invocation** driven by a new observation, which is what keeps the ladder's rung count the bound it claims to be.

### CFI-4 — The verdict has exactly `VERDICT_VALUES` values

`재설계 필요` or `불필요`. There is no third value and no "partially". The verdict answers one question — *does the segment plan have to be rebuilt?* — and the driver's only use for it is unconditional: **a terminal verdict returns the run to segment planning either way.** The value tells the planner whether the binding surface moved, not whether to re-plan. The `상한 P0 잔여` shape is the one exception to where that return lands: it is dispatched before the run has a segment plan, so its terminal verdict returns the run to the driver's ordinary graph — the audit and segment planning that follow — rather than to a plan it would rebuild. The `감사 골격급` shape is the other: it is dispatched after an audit pass under the key's re-convergence cap and before that audit key has concluded, when no segment plan exists yet, so its terminal verdict returns the run to a re-audit of the same audit key, and the segment plan follows only once that re-audit concludes the key.

### CFI-5 — There is no human-question surface

`AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This covers the shared team protocol too: wherever `_common/agent-team-protocol.md` terminates an escalation in `AskUserQuestion`, **this skill resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule. Because this file is a **single arm**, the absence is checkable as a whole-file predicate (`scripts/lint-unattended-surfaces.sh`) — the check whose weaker two-arm cousin was refuted.

### CFI-6 — The document write is bounded by the scope

This skill edits the design document — that is its job, and it is the one stage other than the audit's reconciliation pass that legitimately does. But it edits **only** the sections the scope reaches, it takes the document lock, and it re-hashes before and after so the change is measurable rather than asserted.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step (`Agent` is built-in — do not load it):

- `ToolSearch("select:TaskCreate,TaskList,TaskUpdate,TaskGet")`

**`AskUserQuestion` is deliberately NOT loaded** — it is absent from every headless process anyway, so enumerating it would make this skill fail-loud at Step 0 forever; removing it narrows the fail-loud trigger without carving an exception into the rule, which is scoped to the tools this step enumerates. **`SendMessage` is deliberately NOT loaded** — CFI-2 permits no round to resume.

**Fail-loud, durably.** If a `ToolSearch` for a Step-0-enumerated tool returns no result, or a later call to one fails because its schema was never loaded, **halt** with `분류: tool-unavailable`, carrying the harness error string verbatim.

### Step 1: Resolve, read, hash

1. **Parse** `$ARGUMENTS`: the first `.md` token is the document path (used as given — the driver and the routing shift pass a main-worktree absolute path because `docs/` may be untracked and absent from a segment worktree, which is where a shift-dispatched stage runs); the remainder is the scope. A missing document, a non-`.md` target, an unreadable or empty document, or an empty scope is a **halt** with `분류: precondition-failed`.
2. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `## 2`** — `## 1` for path/slug derivation, the provenance guard, and the atomic compare-and-swap; `## 2` for the carrier's block grammar, its nineteen fields, its frozen tail, its two write forms and their diff gates, and its file terminator. Derive `{slug}` and the document key **from the document's own directory**, never the cwd.
3. **Read the whole design document** and record `사전 sha256` (`shasum -a 256`) and `사전 구속 표면 다이제스트` — the one line `<gate absolute path> binding-digest --manifest "$CC_PIPELINE_MANIFEST" -- <document path>` prints, run as a command of its own with the document path as Step 1.1 parsed it. Take both before any write to the document: Step 4's verdict and every halt record's baselines stand on these two values, and no later step can recompute them.
4. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** for the binding-tier partition and the frozen verification vocabulary — this skill rewrites binding-tier material, so it must know exactly which sections that is.

### Step 2: Locate the scope, and take the carrier's request block if there is one

Eight entry shapes, and the difference decides whether the carrier has a block to close:

- **`R<n>` — a refuted or drift-graded verification item.** Read `<base>/docs/design-reconverge/{slug}.md` (`<base>` and `{slug}` per `sidecar.md` §1.1 — from the document's own directory, never the cwd) after the `sidecar.md` §1.2 read guard passes. Apply §2.5's **truncation check** first: a file whose last non-empty line outside an open fence is not `<!-- cc-design-reconverge: end -->` is truncated — fail closed, surface it, **do not write to it**, and halt. Then find the `## 회차 <N>` block whose `대상 항목` names this `R<n>` and whose `상태` is `대기`. Its frozen tail (fields 3–19) is the evidence: `주장`, `기대 결과`, `관측 요지`, `관측 결과`, `실행된 레시피`, `치환 맵`, `실패 시 영향`. **Use those bytes rather than re-running anything** — the block exists precisely so the observation survives the process that made it.
- **A problem identity `(정규화 파일 경로, 카테고리 태그)` — a review finding routed to the redesign rung.** There is no carrier block, because the carrier's append form belongs to the implementation arm and its field set is shaped for a refuted verification item. Work from the review report the driver names in the scope. **The carrier is not written on this path**, and the terminal predicate rests on the fixed literal of Step 5 plus this skill's structured verdict.
- **`설계 수준 잔여 <review report absolute path>` — a segment's re-check left findings its reviewers classed as design-level.** There is no carrier block, for the same reason as the shape above. Read the report: **the scope is the findings whose `결함 수준` sub-line reads `설계`, and nothing wider** — a `구현` finding beside them is the segment's next fix, never this pass's edit. Work each one directly from its entry (its location, its evidence, and the binding-tier sentence it says the fix would have to move); there is no carrier to read, and the report is never edited. Decide the binding-tier material those findings collide with under Step 3's adoption criteria. A report with no `설계` sub-line, or one that cannot be read, is a halt with `분류: precondition-failed`. The pass is still one pass, the verdict still one of `VERDICT_VALUES`, and the terminal literal unchanged: on this shape alone the driver does not send every verdict back to segment planning — while the segment's declaration did not move it re-implements the segment from the adjusted document, on `불필요` and on `재설계 필요` alike, and it re-plans only on a moved declaration or on `재설계 필요` while another segment of the run has not ended and already holds a plan (an implement row carrying `plan_sha256` above this pass's re-convergence row) — the plan a `재설계 필요` voids is a sibling's, never this segment's own, and a sibling not yet started has none. **The carrier is not written on this path**, and the terminal predicate is the second shape's.
- **`감사 종합 요구 <halt record absolute path>` — a composed requirement an audit's synthesis question asked about, which a person adopted.** There is no carrier block, for the same reason as the shape above. Read the halt record: its `질문 문면` carries the candidate requirement verbatim and its `관측 상세` names the audit report; read the report's findings the requirement composes. **The scope is that requirement and nothing wider** — find the binding-tier material it changes or adds, and decide it in the document under Step 3's adoption criteria. A decision S1–S4 do not let this skill adopt is a halt with `분류: gate-unanswerable` naming the decision, never a narrower edit that leaves the requirement unmet while reading as done. **The carrier is not written on this path**, and the terminal predicate is the second shape's.
- **`구속 티어 이탈 <halt record absolute path>` — an implement stage stopped before leaving the design's binding tier (its CFI-U3), and a person chose `재수렴` — or the manifest pre-adopted that answer with a `자동 채택` row of class `구속-이탈`, and the routing shift carried it.** There is no carrier block: a binding-tier stop writes none. Read the halt record: its `질문 문면` quotes the binding-tier text and names what collides with it — a review finding, a requirement, a measured behaviour — and its `재수렴` option says which way the person wants the binding tier to move. **The scope is that collision and nothing wider** — decide the quoted binding-tier material under Step 3's adoption criteria so the collision is resolved, and where the document carries an unresolved issue describing the same gap, settle it in the same pass. A decision S1–S4 do not let this skill adopt is a halt with `분류: gate-unanswerable` naming the decision, never a narrower edit that leaves the collision standing while reading as done. **The carrier is not written on this path**, and the terminal predicate is the second shape's.
  - **Sub-case: the record's `**스텝**` is exactly `Step 1 CFI-U3 BT-STOP — 미결 결정`.** The implement stage stopped before planning over open decisions (`${CLAUDE_SKILL_DIR}/../_common/unresolved-closure.md`, `## 읽는 쪽`), and a person answered with the decisions. **The scope is the headings of the record's `**미결 결정 항목**` line**, not a colliding binding-tier sentence. Do not read the ledger, and never take a decision from the answer's `근거`: derive the attachment as `<the record's directory>/<the record's file name without .md>.answer.md` and read the decisions there. The attachment names each entry by a sub-heading equal, verbatim, to the entry's heading in the document (`### 미결 N. …` as written there), with the decision under it.
    - For each heading in scope that the attachment names verbatim, write the decision into the binding tier — a decision sentence of `## 합의된 아키텍처` or `## 주요 결정사항과 근거` — and rewrite the entry's `상태` line to the bare `**상태**: 해결`, any note on a line of its own (`${CLAUDE_SKILL_DIR}/../_common/unresolved-closure.md`, `## 작성자 꼴`). An answer `구현 재량 — <기준>` instead rewrites the entry's `**구현 처분**` to `구현 재량` with `**재량 기준**: <기준>`; that, too, is the person's decision.
    - A heading in scope with no verbatim sub-heading in the attachment is left byte for byte; the next process A stops on it again.
    - The person chose these decisions, so S1–S4 do not apply to them, and neither the re-convergence cap nor the automatic-answer cap applies to this answer.
    - An entry whose `사유` starts with `베이스 계약 변경 필요` is never rewritten to `해결`: end in a halt with `분류: gate-unanswerable` whose `**질문 문면**` names the entry and says 「베이스를 개정한 뒤 런을 새로 연다」.
    - An attachment that is absent or cannot be read ends in a halt with `분류: gate-unanswerable`, as the rule above for this scope. These two are the only halts of this sub-case.
- **`상한 P0 잔여 <review report absolute path>` — an earlier run ended with this segment parked at the re-check review cap and P0 left, and its successor's first step chose to re-converge the document on them.** There is no carrier block, for the same reason as the second shape. Read the report: **the scope is every bullet under its P0 heading, whatever its `결함 수준` sub-line says or whether it has one** — nothing under another heading. A design-level P0 is fixed in the design under Step 3's adoption criteria. An implementation-level P0 is written into the design section of the slice it sits in, as the defect and the invariant the next implementation must keep, so the slice implemented again from scratch cannot repeat it — or, when the design already states that invariant in words the implementation simply broke, it leaves the document as it is and counts toward `불필요`. A report that is absent or cannot be read, or whose P0 heading has no bullet, is a halt with `분류: precondition-failed`. **The carrier is not written on this path**, and the terminal predicate is the second shape's; its verdict returns the run to the driver's ordinary graph (CFI-4).
- **`잔여 동결 재검토 <halt record absolute path>` — an unattended design stage froze its document over residual items its ladder could not settle, and a person answered that `/ ladder-unsettled` halt with `골격 재검토`.** The scope string is the one `_common/pipeline-sidecar.md` §3.2 defines. There is no carrier block. Read the halt record's `**잔여 판정**` line and the document's `**잔여 동결**` line: **the scope is the R-items they name and the skeleton those items rest on, and nothing wider** — decide under Step 3's adoption criteria whether each item's premise and blocker still hold, and change the binding-tier material an item can no longer carry. An R-item this pass adds, or whose `**차단 부류**` it sets to `사람-환경` or `외부-준비`, gets `**검증 시점**: 구현 전` and never `구현 후`: the person asked for the skeleton to be looked at again, so this pass does not hand the item past the merge on their behalf. Leave the `**잔여 동결**` line as history. **The carrier is not written on this path**, and the terminal predicate is the second shape's.
- **`감사 골격급` — an unattended audit's pass found skeleton-grade defects, and the gate opened one of the automatic re-convergences that audit key gets under its cap.** The scope is the fixed phrase `감사 골격급` and carries no path: derive the report as `<base>/docs/design-audit/{slug}.md`, with `<base>` and `{slug}` per `sidecar.md` §1.1 — from the document's own directory, the same fold as the driver's `DOC_SLUG` — never from the cwd and never from the scope string. There is no carrier block. Read only the `### K<n>` entries under the report's `## 골격급 결함` heading: each entry's `**뒤집히는 결정**` (a decision sentence verbatim, then the heading it sits under, verbatim) and its `**대안**` are the evidence, and **the scope is those entries and nothing wider** — the report's other findings, its disclosure blocks and the counts in its separate fence are not the scope, and the report is never edited. Decide each entry under Step 3's adoption criteria; its heading is the citation S2 resolves, and a heading that is not unique, or a decision sentence not found under it, leaves S2 unmet. An entry whose `**출처**` is `합성 요구` may settle, in the same pass, the document's `## 미해결 이슈 / 트레이드오프` entry carrying `사유: 감사 합성 요구 — 사람 판단` and the same candidate text; a `보류` entry no `### K<n>` names is left byte for byte. For each entry decided, find the `## 미해결 이슈 / 트레이드오프` item its `**미해결 항목**` line names by heading, rewrite that item's `상태` line to the bare `**상태**: 해결` and put one line of its own inside the item saying how this pass settled it — never a note on the `상태` line (`${CLAUDE_SKILL_DIR}/../_common/unresolved-closure.md`, `## 작성자 꼴`); an entry with no `**미해결 항목**` line (a report an earlier version wrote) leaves the items as before. Step 3's rule to rewrite a decision sentence and record the superseded one in the same place does not apply on this scope: no segment plan exists yet, so no implementation or review artifact quotes the old wording. The old wording survives in the `**뒤집히는 결정**` of the report's K entry only until the next audit's Step 1 writes the report afresh; after that a citation aimed at the old wording, from another section of the document included, has nothing to land on. A report that is absent or cannot be read, or that has no `### K<n>` entry, is a halt with `분류: precondition-failed` and no terminal literal — the routing reads that end as `blocked` for the key. A decision S1–S4 do not let this skill adopt is a halt with `분류: gate-unanswerable` naming the decision, never a narrower edit that leaves the defect standing while reading as done. **The carrier is not written on this path**, and the terminal predicate is the second shape's; its verdict returns the run to a re-audit of the same key (CFI-4).

Either way, **read the design document sections the scope reaches** and identify which binding-tier material the defect actually falsifies. If nothing in the binding tier is implicated, that is a legitimate and common outcome — the verdict is `불필요`.

### Step 3: The adjustment pass (single, non-recursive)

One pass. Read-only exploration subagents are allowed here and are not a round (CFI-2); **every such prompt carries CFI-5 verbatim**, and a spawned agent reports completion and blockage to its spawner by return value only, never by a banner and never by any notification route.

**Autonomous-adoption criteria — all four must hold, or the item is parked instead of adopted.** Existing recommendation criteria ask what *shape* the evidence has; unattended, the missing question is what happens when the answer is wrong.

- **S1 — Blast radius.** If the option touches a critical-path surface — authentication, payments, data integrity, a persisted schema, a public API contract — do **not** adopt it autonomously, whatever category it falls in. With a human present it was enough for one category to ask this; without one it is not.
- **S2 — Citations must actually resolve, and resolution is a record, not a claim.** A file citation resolves only if the path exists and names what it says it names; a document-section citation resolves only if its **verbatim heading is unique**. "I checked" is not resolution — this document rejects self-reported constraint compliance elsewhere and cannot rely on it here. Record the **actual command and its output** as the rationale. With no record, S2 is unmet.
- **S3 — Reversibility inside the segment.** Adopt only what the current segment can still undo. A decision that hardens across a segment boundary — one that makes already-merged work depend on it — is not an autonomous adoption.
- **S4 — A recommendation to convene a team is never auto-adopted.** Where the analysis concludes that a full discussion is warranted, that conclusion **promotes the item to the ladder's team-round rung**; it does not authorize a round here (CFI-2).

Then, through one working copy published under the document lock:

- **This pass edits the design document through a working copy, published once under the document lock.** Every write this pass makes to the document — the edits the scope reaches and the grade-line return of "Return the scoped item to its gate" alike — rides one copy and one publish; no response writes the document outside it. CFI-3's one edit of the document is that one publish. With nothing to write (verdict `불필요` and no edit), skip the procedure. `<run id>` is `CC_PIPELINE_RUN_ID` and `<stage id>` is `CC_PIPELINE_STAGE_ID` with `#` as `-` (`A#7` → `A-7`), the form the gate proves run-local; the copy lives in the one directory `mktemp -d "${TMPDIR:-/tmp}/cc-proto-<run id>-<stage id>.XXXXXX"` makes. The `mktemp`, both `cp`s (taking the copy and the publish) and the `rm -r` are declared `--surface 트리밖쓰기 --reach 런로컬`, and the `rm -r` adds `--destructive`. Never declare them `기기전역` or `미상`: the first parks on the pre-authorization judgment, the second parks as `도달미상` because the document path lies outside the namespace. `shasum` is a read. One response each:
    1. `mktemp -d "${TMPDIR:-/tmp}/cc-proto-<run id>-<stage id>.XXXXXX"`.
    2. `cp <document> <dir>/doc.md` and `shasum -a 256 <document>`. The expected hash is Step 1's `사전 sha256`; re-entered with a carried answer, it is the record's `지금 sha256`, else its `사전 sha256`. Another hash means another writer: halt with `분류: precondition-failed`.
    3. Read the copy with `limit: 1` — the Edit tool's precondition; the content is Step 1's read.
    4. Every write the scope reaches as several Edits on the copy, and `shasum -a 256 <document>` again; if it differs from 2, do not publish — halt with `분류: precondition-failed`.
    5. Publish with `/usr/bin/lockf -k -t 0 "${RUN_DIR}/designdoc.lock" cp <dir>/doc.md <document>` (absolute path; `-k` and `-t 0` both required), and record `shasum -a 256 <document>` as `사후 sha256`. `EX_TEMPFAIL` (75) means another writer holds the document — a planning violation rather than a queue. Do **not** wait and do **not** retry: halt with `분류: precondition-failed`, naming both writers.
    6. `rm -r <dir>`, then go on to Step 4's verdict and the carrier close.
    7. A halt at 2, 4 or 5 removes the directory first and lists 4's edits in the record's `관측 상세`. A compaction between 1 and 5 drops the copy: find it by the prefix `cc-proto-<run id>-<stage id>.`, remove it as in 6, and restart at 1.

    Never put the copy beside the document (a hidden file in the same directory included) or under the run directory, never copy inside `sh -c` or `bash -c`, never publish with `mv`, and never use a temporary name outside the namespace above: the publish is a `cp`. A halt after the publish carries 5's `사후 sha256` as its `지금 sha256`, as "A halt carries the scope and the Step 1 baselines" defines it. The carrier write (`docs/design-reconverge/{slug}.md`) is outside this procedure and keeps `_common/sidecar.md`'s own write form.
- **Return the scoped item to its gate.** When the scope is an `R<n>` whose grade line in the document carries `반증됨(실패)` or `검증불가(드리프트)` — a refutation during implementation flips it before halting, one before implementing does not — rewrite that whole line to `**검증 등급**: 구현 시 검증` and leave its `구현 시 검증 기록` line in place as history. Left terminal, the item is skipped by the next implement stage's discovery as already settled, and the segment would go to its pull request without the measurement that refuted it ever running again. This write is inside the scope, and the verdict's digest filters grade lines, so it alone never makes the verdict `재설계 필요`.
- **Edit only what the scope reaches** (CFI-6). Where a binding-tier decision changes, rewrite the decision sentence and record the superseded one in the same place, so a citation aimed at the old wording still lands — on every scope but `감사 골격급`, which records no superseded sentence (Step 2). Do not restate history as if it were current.
- **Every adopted decision gets a record**: the decision, the rejected alternative, the rationale, and — for S2 — the resolving command and its output. This skill writes those records into its own structured output; **the driver transcribes them into the run ledger.** This skill writes no pipeline sidecar.
- **Record `사후 sha256`** after the last edit: it is the hash step 5 of the working copy takes after the publish.

### Step 4: Verdict

Compute the two-value verdict (CFI-4):

- **`재설계 필요`** — the edit moved the document's **binding surface**: a `## 합의된 아키텍처` statement, a decision sentence, a resolved trade-off entry, or a verification item. The segment plan was derived from that surface, so it is now stale.
- **`불필요`** — nothing binding moved. The edit clarified rationale, corrected an example, or the scope turned out not to falsify anything.

The distinction is measurable rather than asserted: compute it over the **binding-surface digest** — the document with `검증 등급:` and `구현 시 검증 기록:` lines filtered out, section-scoped, tolerant on both diff sides — and compare before and after. Both sides come from the same command: the before side is Step 1's `사전 구속 표면 다이제스트` (or the carried record's, on re-entry), and the after side is what `<gate absolute path> binding-digest --manifest "$CC_PIPELINE_MANIFEST" -- <document path>` prints after the last edit. Never compute either side by hand — a hand-filtered hash that differs from the gate's by one blank line reads as a moved binding surface. That digest is invariant to the implementation arm's own two write forms by construction, so a verdict computed on it is not perturbed by them.

**Close the carrier block** where Step 2 took one, using `## 2`'s **close** write form and nothing else: flip `상태` to `처리됨` and insert **exactly one** `처리 기록` line at field position 2, immediately after that block's `상태` line, with every other block byte-unchanged. Its value grammar is fixed here:

```
**처리 기록**: 재수렴 sha256: <사후 sha256> · 판정: 재설계 필요|불필요 · <한 줄 사유>
```

A block that already carries a `처리 기록` is **not** a member of the close set — another reader closed it inside the window — and writing a second one into it is a construction fault. Evaluate the close form's diff constraint against the pre-write bytes before the `mv`; a violation means discard the temp, do not write, and report.

### Step 5: HARD STOP

Write the verdict, the residual out-of-scope defects CFI-1 declined, `사전 sha256`, `사후 sha256`, and the adopted-decision records into the structured output. Then, on the line immediately before the literal, emit the verdict as a line of its own — exactly one of these two, and nothing else on that line:

```
판정: 재설계 필요
판정: 불필요
```

and stop with the literal statement:

*"재수렴을 종료합니다. 판정은 여기까지이며 추가 패스는 없습니다."*

That literal is the driver's confirming terminal predicate and must be emitted byte for byte. The `판정:` line is what the gate records as the row's `재수렴 판정`: it reads only the terminal message, and only a whole line equal to one of the two forms — it forgives surrounding whitespace, one list marker (`- `, `* `, `1. `, `1) `), bold or backticks around the whole line or the value, a bold key, a full-width colon and one closing period, but write the plain form above — so a message with neither line, with both, or with the line only earlier in the transcript records `없음`, and a sibling segment's re-plan cannot cite it. **A terminal verdict returns the run to segment planning unconditionally** (CFI-4) — this skill does not decide that, and does not act on it. On the `상한 P0 잔여` shape the verdict returns the run to the driver's ordinary graph instead, because no segment plan exists yet when it runs. On the `감사 골격급` shape the verdict returns the run to a re-audit of the same audit key, for the same reason.

### (There is no Step 6.)

The absence is the contract. A further re-convergence is a new invocation driven by a new observation.

---

## Constraints

- **One scope per invocation** (CFI-1). Out-of-scope defects are recorded, never fixed.
- **No team round** (CFI-2). Read-only exploration subagents are not a round.
- **One adjustment pass, then stop** (CFI-3).
- **Edit only what the scope reaches** (CFI-6), under the document lock, bracketed by two digests.
- **The carrier's write form is `## 2`'s close, and nothing else.** This skill never uses the append form: that form belongs to the implementation arm, and its field set is shaped for an observation this skill did not make.
- **Never reach a notification surface.** No `PushNotification`, no `notify.sh`, no `terminal-notifier` — not from this file and not from any agent it spawns. Notifying a sleeping user is the driver's exclusive job.
- **Never write a pipeline sidecar.** This skill reads the grant to re-derive `RUN_DIR`; the driver is the sole writer of the run ledger and of the autonomous-decision rows this skill emits.
- **Read pipeline variables by name** — `printenv CC_PIPELINE_RUN_ID`, one name per call — and never bare `env` or bare `printenv`. This stage's own environment carries the pipeline token, so the whole-environment forms print a credential into the transcript and are parked as `비밀출력`.
- **No code modifications.** This skill changes the design, never the implementation.

Task: $ARGUMENTS
