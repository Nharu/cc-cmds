---
name: design-reconverge
description: 반증된 검증 항목이나 설계 결함 발견 하나에 스코프된 재수렴 — 설계를 고치고 두 값 판정 후 정지 (무인)
when_to_use: 자율 파이프라인 드라이버가 사다리 R2(재설계) 레인에 진입할 때. 사람이 참여하는 재설계는 `/cc-cmds:design`으로 처음부터 다시 수렴할 것
disable-model-invocation: true
usage: "/cc-cmds:design-reconverge <design-doc-path> <scope>"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "재수렴 대상 설계 문서 경로 (`.md`). 드라이버가 메인 워크트리 절대 경로로 넘긴다."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석."
    - name: "<scope>"
      kind: positional
      required: true
      summary: "재수렴 스코프. `R<n>` 형태의 잔여 검증 항목 식별자이거나, `(정규화 파일 경로, 카테고리 태그)` 형태의 문제 동일성."
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 비어 있으면 중단 기록을 남기고 정지 — 스코프 없는 재설계는 이 스킬이 하는 일이 아니다."
notes: "전면 재수렴이 아니다. 넘겨받은 스코프 하나만 고치고, 두 값 판정과 고정 리터럴을 남기고 정지한다. 팀 라운드는 사다리 R3에서만 열린다."
---

Re-converge a design document against **one** scoped defect, then stop — **without ever asking a human**.
Internal agent communication is in English to optimize token usage. Saved documentation is in Korean.

This is a **scoped repair, not a re-run of design.** It is entered from the escalation ladder's redesign rung, it touches only what the scope names, and its terminal verdict routes the run back to segment planning.

## What this skill is, and what it is not

The pipeline's slow lane needs a redesign that runs unattended. Putting a mode branch inside `/cc-cmds:design` would fork exactly the region its own control-flow invariants protect, so this is a **separate command** — the same shape this repo already used when a command with a different termination contract replaced its predecessor rather than growing a flag.

It also gives the re-convergence carrier a reader. `_common/sidecar.md` `## 2` has defined `docs/design-reconverge/{slug}.md` — nineteen fields, two write forms, a frozen tail, a terminator — with **nobody referencing it**. This skill is its reader.

**What this skill never does**: propose a design of its own beyond the scope it was handed, run a full team discussion (that budget belongs to the ladder's next rung), or ask a human anything.

## Halt record — the disposition for every point that would have asked

Read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4 for the schema. Path: `${RUN_DIR}/halt/<stage-id>.md`, `RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`. `<run-id>` is re-derived from `<base>/docs/pipeline-grant/{slug}.md`. **Prefer the driver-exported `CC_PIPELINE_RUN_ID`** (with `RUN_DIR` from `CC_PIPELINE_RUN_DIR`); the re-derivation below is the fallback for a driver older than those variables, and it resolves only for a run started from a document — a manifest run keys its grant on the run id instead. `<stage-id>` comes from the driver-exported `CC_PIPELINE_STAGE_ID`, defaulting to this skill's name. Write it atomically (`sidecar.md` §1.3), record the question and every option **verbatim**, then take no further step and end the turn. **Never write a pipeline sidecar** — the driver is their sole writer.

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

`재설계 필요` or `불필요`. There is no third value and no "partially". The verdict answers one question — *does the segment plan have to be rebuilt?* — and the driver's only use for it is unconditional: **a terminal verdict returns the run to segment planning either way.** The value tells the planner whether the binding surface moved, not whether to re-plan.

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

1. **Parse** `$ARGUMENTS`: the first `.md` token is the document path (used as given — the driver passes a main-worktree absolute path because `docs/` may be untracked and absent from a segment worktree); the remainder is the scope. A missing document, a non-`.md` target, an unreadable or empty document, or an empty scope is a **halt** with `분류: precondition-failed`.
2. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `## 2`** — `## 1` for path/slug derivation, the provenance guard, and the atomic compare-and-swap; `## 2` for the carrier's block grammar, its nineteen fields, its frozen tail, its two write forms and their diff gates, and its file terminator. Derive `{slug}` and the document key **from the document's own directory**, never the cwd.
3. **Read the whole design document** and record `사전 sha256` (`shasum -a 256`).
4. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** for the binding-tier partition and the frozen verification vocabulary — this skill rewrites binding-tier material, so it must know exactly which sections that is.

### Step 2: Locate the scope, and take the carrier's request block if there is one

Two entry shapes, and the difference decides whether the carrier has a block to close:

- **`R<n>` — a refuted or drift-graded verification item.** Read `docs/design-reconverge/{slug}.md` after the `sidecar.md` §1.2 read guard passes. Apply §2.5's **truncation check** first: a file whose last non-empty line outside an open fence is not `<!-- cc-design-reconverge: end -->` is truncated — fail closed, surface it, **do not write to it**, and halt. Then find the `## 회차 <N>` block whose `대상 항목` names this `R<n>` and whose `상태` is `대기`. Its frozen tail (fields 3–19) is the evidence: `주장`, `기대 결과`, `관측 요지`, `관측 결과`, `실행된 레시피`, `치환 맵`, `실패 시 영향`. **Use those bytes rather than re-running anything** — the block exists precisely so the observation survives the process that made it.
- **A problem identity `(정규화 파일 경로, 카테고리 태그)` — a review finding routed to the redesign rung.** There is no carrier block, because the carrier's append form belongs to the implementation arm and its field set is shaped for a refuted verification item. Work from the review report the driver names in the scope. **The carrier is not written on this path**, and the terminal predicate rests on the fixed literal of Step 5 plus this skill's structured verdict.

Either way, **read the design document sections the scope reaches** and identify which binding-tier material the defect actually falsifies. If nothing in the binding tier is implicated, that is a legitimate and common outcome — the verdict is `불필요`.

### Step 3: The adjustment pass (single, non-recursive)

One pass. Read-only exploration subagents are allowed here and are not a round (CFI-2); **every such prompt carries CFI-5 verbatim**, and a spawned agent reports completion and blockage to its spawner by return value only, never by a banner and never by any notification route.

**Autonomous-adoption criteria — all four must hold, or the item is parked instead of adopted.** Existing recommendation criteria ask what *shape* the evidence has; unattended, the missing question is what happens when the answer is wrong.

- **S1 — Blast radius.** If the option touches a critical-path surface — authentication, payments, data integrity, a persisted schema, a public API contract — do **not** adopt it autonomously, whatever category it falls in. With a human present it was enough for one category to ask this; without one it is not.
- **S2 — Citations must actually resolve, and resolution is a record, not a claim.** A file citation resolves only if the path exists and names what it says it names; a document-section citation resolves only if its **verbatim heading is unique**. "I checked" is not resolution — this document rejects self-reported constraint compliance elsewhere and cannot rely on it here. Record the **actual command and its output** as the rationale. With no record, S2 is unmet.
- **S3 — Reversibility inside the segment.** Adopt only what the current segment can still undo. A decision that hardens across a segment boundary — one that makes already-merged work depend on it — is not an autonomous adoption.
- **S4 — A recommendation to convene a team is never auto-adopted.** Where the analysis concludes that a full discussion is warranted, that conclusion **promotes the item to the ladder's team-round rung**; it does not authorize a round here (CFI-2).

Then, holding the lock:

- **Take the document lock** for every write: `/usr/bin/lockf -k -t 0 "${RUN_DIR}/designdoc.lock" <command>` (absolute path; `-k` and `-t 0` both required). `EX_TEMPFAIL` (75) means another writer holds the document — a planning violation rather than a queue. Do **not** wait and do **not** retry: halt with `분류: precondition-failed`, naming both writers.
- **Edit only what the scope reaches** (CFI-6). Where a binding-tier decision changes, rewrite the decision sentence and record the superseded one in the same place, so a citation aimed at the old wording still lands. Do not restate history as if it were current.
- **Every adopted decision gets a record**: the decision, the rejected alternative, the rationale, and — for S2 — the resolving command and its output. This skill writes those records into its own structured output; **the driver transcribes them into the run ledger.** This skill writes no pipeline sidecar.
- **Record `사후 sha256`** after the last edit.

### Step 4: Verdict

Compute the two-value verdict (CFI-4):

- **`재설계 필요`** — the edit moved the document's **binding surface**: a `## 합의된 아키텍처` statement, a decision sentence, a resolved trade-off entry, or a verification item. The segment plan was derived from that surface, so it is now stale.
- **`불필요`** — nothing binding moved. The edit clarified rationale, corrected an example, or the scope turned out not to falsify anything.

The distinction is measurable rather than asserted: compute it over the **binding-surface digest** — the document with `검증 등급:` and `구현 시 검증 기록:` lines filtered out, section-scoped, tolerant on both diff sides — and compare before and after. That digest is invariant to the implementation arm's own two write forms by construction, so a verdict computed on it is not perturbed by them.

**Close the carrier block** where Step 2 took one, using `## 2`'s **close** write form and nothing else: flip `상태` to `처리됨` and insert **exactly one** `처리 기록` line at field position 2, immediately after that block's `상태` line, with every other block byte-unchanged. Its value grammar is fixed here:

```
**처리 기록**: 재수렴 sha256: <사후 sha256> · 판정: 재설계 필요|불필요 · <한 줄 사유>
```

A block that already carries a `처리 기록` is **not** a member of the close set — another reader closed it inside the window — and writing a second one into it is a construction fault. Evaluate the close form's diff constraint against the pre-write bytes before the `mv`; a violation means discard the temp, do not write, and report.

### Step 5: HARD STOP

Write the verdict, the residual out-of-scope defects CFI-1 declined, `사전 sha256`, `사후 sha256`, and the adopted-decision records into the structured output. Then stop with the literal statement:

*"재수렴을 종료합니다. 판정은 여기까지이며 추가 패스는 없습니다."*

That literal is the driver's confirming terminal predicate and must be emitted byte for byte. **A terminal verdict returns the run to segment planning unconditionally** (CFI-4) — this skill does not decide that, and does not act on it.

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
- **No code modifications.** This skill changes the design, never the implementation.

Task: $ARGUMENTS
