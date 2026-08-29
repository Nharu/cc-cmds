---
name: design-audit-unattended
description: 동결된 설계 문서를 독립 리더 팬아웃으로 1회 감사하고 정합 조정 1회 후 정지 (무인 — 사람 확인 없이 park)
when_to_use: 자율 파이프라인 드라이버가 감사 스테이지를 헤드리스로 디스패치할 때. 사람이 직접 부르는 경우에는 `/cc-cmds:design-audit`를 쓸 것
disable-model-invocation: true
usage: "/cc-cmds:design-audit-unattended <design-doc-path> [<note>] [--base]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "감사 대상 설계 문서 경로 (`.md`). 드라이버가 메인 워크트리 절대 경로로 넘긴다. 첫 리더 spawn 직전의 sha256으로 동결된다."
    - name: "<note>"
      kind: positional
      required: false
      summary: "문서 경로 뒤 자유 텍스트. 전 리더에게 **축어로 동일하게** 주입되는 초점 메모."
    - name: "--base"
      kind: flag
      default: "off"
      summary: "base 설계 문서 모드 — 기존 내용의 정합·완결만 감사하고 신규 구현 세부 제안을 금지한다."
notes: "반복 라운드가 없다. 사람에게 묻는 표면도 없다 — 동결 불일치는 중단 기록을 남기고 park하며 자동 재감사는 0회다."
---

Audit a FROZEN design document with an independent reader fan-out, reconcile once, then stop — **without ever asking a human**.
All reader prompts and internal team communication are in English to optimize token usage.
User-facing communication is Korean.

This is a **single pass over a frozen document** — NOT a convergence loop, and it must never become one.

## What this sibling is, and what it is not

This is the unattended arm of `/cc-cmds:design-audit`. It is a **separate file** rather than a flag, because one arm per file makes "this arm contains no human-question surface" a whole-file predicate and therefore checkable (`scripts/lint-unattended-surfaces.sh`). `/cc-cmds:design-audit` is unchanged byte for byte.

**What the split does not buy.** It removes the *instruction* to ask; it does not remove the model's ability to ask in prose and answer itself. That residual is not closed here.

`references/` is **shared with the base skill, not copied** — every reference path below points into `../design-audit/references/`, which carries no human-question surface.

## Input

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

`$ARGUMENTS` is the path to a design document (`.md`), optionally followed by a free-text note and/or the flag `--base`. The **first `.md` token** is the document path; `--base` is extracted wherever it appears; everything else, joined, is the note. **The path is used as given** — the driver passes a main-worktree absolute path because `docs/` may be untracked and absent from a segment worktree.

## Halt record — the disposition for every point that would have asked

Read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4 for the schema. Path: `${RUN_DIR}/halt/<stage-id>.md`, `RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`. `<run-id>` is re-derived from `<base>/docs/pipeline-grant/{slug}.md`. **Prefer the driver-exported `CC_PIPELINE_RUN_ID`** (with `RUN_DIR` from `CC_PIPELINE_RUN_DIR`); the re-derivation below is the fallback for a driver older than those variables, and it resolves only for a run started from a document — a manifest run keys its grant on the run id instead. `<stage-id>` comes from the driver-exported `CC_PIPELINE_STAGE_ID`, defaulting to this skill's name. Write it atomically (`sidecar.md` §1.3), record the question and every option **verbatim**, then take no further step and end the turn. **Never write a sidecar** — the driver is the sole writer of the run ledger.

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

## Control-Flow Invariants

These rules govern termination and the freeze contract, and MUST stay near the top of this file. Post-compaction reattaches only the first ~5K tokens with priority. A summarized-away rule here does not merely degrade quality — the model's default behavior when handed a pile of findings is to keep reviewing, so losing CFI-2 or CFI-3 **resurrects, inside this command, the unbounded loop this command exists to delete.**

### CFI-0 — Fixed constants (single source of truth)

```
READER_COUNT = 3
ROUNDS_PER_READER = 1
OUTER_ITERATIONS = 0
ADJUSTMENT_PASSES = 1
ROUND_TOKEN = 1
PASS_TOKEN = fanout
```

These six lines are the **only** place any of these values appears in this skill. Every other mention refers to them **by name**. They are byte-identical to the base skill's block by contract, and `lint-unattended-surfaces.sh` asserts that parity — the one drift risk a forked spine actually carries is a divergent budget, so it is pinned rather than trusted.

`READER_COUNT` is a **budget, not a target.** It is fixed by the single-pass reconciliation limit. Do NOT justify it with a coverage formula of the `1 − (1 − c)^N` family — that model is statistically rejected for this population.

### CFI-U0 — There is no human-question surface

`AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its durable escalation counters terminate in `AskUserQuestion`, **this arm resolves that terminus to `park`** — write the halt record and stop. The protocol file is neither forked nor edited; this sentence is the substitution rule.

### CFI-1 — Freeze (the mechanism, not hygiene)

The freeze window opens at the last pre-spawn write of Step 1 and closes when the last reader witness is collected. Inside it, no `Edit`/`Write` may target the document and nothing may change in the tree. Three artifacts are recorded at the open — `FROZEN_SHA256`, the `git status --porcelain` baseline, and the worktree baseline (the two-command boundary gate of `${CLAUDE_SKILL_DIR}/../_common/verification.md`) — and all three are re-checked at the close.

**The worktree half is the gate's three scoped assertions, not a whole-output equality** — 2a (path set), 2b (this audit's own entry), 2c (`cc-design-exp-` count is 0), exactly as `${CLAUDE_SKILL_DIR}/../_common/verification.md` §6 defines them, and identically to the interactive arm's CFI-1. Do not re-derive them here.

**This arm is where the false positive costs the most.** The window spans the whole fan-out, and a mismatch here is a **halt with an automatic re-audit count of zero** — so a sibling worktree's commit, which changes no byte of the reviewed text (`FROZEN_SHA256` covers that directly) and no byte of `CODE_ROOT`, would end an unattended audit for the night over a tree no reader measured. It is deliberately not a mismatch.

**Declare `-run-` as assertion 2a's exception pattern before the window opens.** The pipeline's segment worktrees carry that reserved infix, so without the declaration a sibling segment's worktree *creation* fails 2a for something this audit did not do and cannot see. The declaration excuses a *worktree path-set* entry only — the `git status --porcelain` baseline, 2b, and the `cc-design-exp-` zero-count are untouched by it.

This is load-bearing, not tidiness. The audit's reproduction rate stays below 1 only while the induced-defect rate is zero, and that rate becomes positive the instant any byte of the reviewed text changes between reviews.

### CFI-2 — Fan-out shape (there is no round 2, ever)

Exactly `READER_COUNT` readers, each spawned exactly once, each performing `ROUNDS_PER_READER` round.

**Declared carve-out**: the shared team protocol's multi-round rule — its `### Round budget` together with the ban on a one-shot isolated `Agent()` per round — is **inapplicable here, and this sentence is the explicit exception.** Cross-review IS the reproduction channel this command removes. **No reader is ever resumed**; `SendMessage` is deliberately not loaded in Step 0, so a resume is tool-unavailable rather than merely forbidden. The protocol's same-round respawn on a death verdict is the only re-spawn permitted; it reuses `ROUND_TOKEN`/`PASS_TOKEN` unchanged and is bounded by the protocol's durable escalation counters, whose termini CFI-U0 resolves to `park`.

### CFI-3 — One reconciliation pass, then HARD STOP

The reconciliation pass consumes the collected report set exactly once. It **MUST NOT** call `Agent()`, **MUST NOT** re-open a dispositioned finding, and **MUST NOT** treat its own edits as new input. The invocation's only exit is Step 7. There is no Step 8, no outer iteration, and no "one more round".

The hard stop forbids **re-review**, not editing. Once the stop is reached the document is an ordinary edit target again; each post-stop edit carries the marker `**미리뷰(스톱 이후 추가)**`.

**CFI-3b — Synthesis question (mandatory terminal act).** The pass may not close by dispositioning items one at a time. Its last act is to ask, once, in writing: *"이 발견들이 **함께** 함의하는 요구사항이 있는가?"* Items that are locally small in separate readers' reports compose into requirements that appear in no single report, and only the reconciling side can see that composition.

**CFI-3c — Not a round cap.** This invariant fixes the freeze and the non-recursion discipline. It carries no numeric round budget; do not add one here.

### CFI-4 — Observed-result precondition (anti-fabrication)

No finding, anchor verdict, count, or slot value may be recorded unless it came from a collected witness. The lead never authors a reader's witness and never infers one from a return text. Uncertain means fail closed.

### CFI-5 — Disclosure is a precondition of stopping

Step 7 cannot complete without a disclosure block that passes all four anti-vacuity checks. Boundedness is enforced by this gate, not by prose: the stop is the only exit and the gate is the only way through it.

### CFI-6 — Forbidden imports (loop-resurrection denylist)

None of the following may appear anywhere under this skill: `consecutive_no_major`, `COUNT_APPLIED`, `escalate_applied`, `INNER_EXIT_REASON`, `inner_round`, `outer_iter`, `outer_log.md`, `ack_items.md`, `pending_applies.md`, `INNER_TEMP_DIR`, a severity max-aggregation ratchet, and any auto-approve or auto-reject predicate used as a **termination input**. This command still triages, but no counter anywhere depends on the triage outcome.

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:

- `ToolSearch("select:TaskStop")`

`Agent` is built-in. **`SendMessage` is deliberately NOT loaded** — no member is ever resumed (CFI-2). **`AskUserQuestion` is deliberately NOT loaded** — it is absent from every headless process anyway, so enumerating it here would make this skill fail-loud at Step 0 forever; removing it narrows the fail-loud trigger without carving an exception into the rule, which is scoped to the tools this step enumerates.

**Fail-loud, durably.** If a `ToolSearch` for a Step-0-enumerated tool returns no result, or a later call to one fails because its schema was never loaded, **halt** with `분류: tool-unavailable`, carrying the harness error string verbatim.

### Step 1: Resolve, validate, FREEZE

1. **Parse** `$ARGUMENTS` per `## Input`. A missing or non-`.md` target is a **halt** with `분류: precondition-failed`.
2. **Read the whole document.** An unparseable or empty document is a **halt** (nothing to freeze).
3. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1`** and derive, from the **document's own directory** and never the cwd: `CODE_ROOT` (`git rev-parse --show-toplevel`, falling back to the document's directory), the **document key**, and `{slug}`.
4. **FREEZE.** Record `FROZEN_SHA256` (`shasum -a 256`) plus both git baselines, having first declared the `-run-` exception pattern (CFI-1). Create `<base>/docs/design-audit/` and early-stub the report at `<base>/docs/design-audit/{slug}.md`: an H1 title, the machine header `<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->`, the `<!-- cc-design-ledger v3 … -->` block, and a `## 감사 개시` block carrying `frozen-sha256`, `frozen-at`, `reader-count`, `round-token`, `pass-token`. **The `writer=`/`reader=` fields keep the base skill's name** — the carrier is the same mechanism whichever arm produced it, and a reader downstream must not have to know which arm ran.
5. **Write the opening notice into the report rather than emitting it as a user-facing line.** There is no human watching, and the report is where the morning reader looks: the target, the hash prefix, *"리더 팬아웃 1라운드 후 정지 — 추가 라운드 없음"*, and the post-stop `**미리뷰(스톱 이후 추가)**` convention.

### Step 2: Deterministic checks (ONCE, outside the replication channel)

**Read `${CLAUDE_SKILL_DIR}/../design-audit/references/02-deterministic-checks.md`** and run it once.

A check whose detection probability is essentially 1 gains nothing from N-fold replication. Running these once, in the main session, frees the readers' whole budget for the semantic measurement only they can do.

Write the output into the report as `## 결정론적 검사` and hand its path to **all** readers identically. Capture the boundary baselines **after** this write; the freeze window opens here.

### Step 3: Fan-out spawn

**Before spawning, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the spawn / witness / ledger v3 / reconcile-ladder contract and the task-assignment header, and **Read `${CLAUDE_SKILL_DIR}/../design-audit/references/01-reader-prompt.md`** for the reader prompt.

Readers are **nameless background tasks** (`Agent` with `subagent_type:"claude"`, `run_in_background:true`, **no `name`**), self-terminating on return; each reader's result is delivered by its **witness file**. The `Agent()` call **omits `model`** so readers inherit the session model.

- **Witness scratch dir**: before the first spawn, `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{slug}.XXXXXX")`, recorded as each reader's `scratchDir`. The witnessed phase is `PASS_TOKEN` and the witness path is `${WITNESS_DIR}/reader-<k>.fanout.md`. Out-of-tree, leaving the boundary gate untouched.
- **Ledger**: record each returned `agentId` immediately (`state=running`, phase `fanout`), stamping `epoch` and the phase `witnessNonce` on every row in the same at-spawn recording window.
- **MUST — byte-identical prompts.** The `READER_COUNT` rendered prompts differ **only** in `{WITNESS_PATH}`, `{WITNESS_NONCE}`, and `{role-slug}`. Differentiating readers by lens destroys the reinforcement statistic the `미보강 잔여 수` slot reports.
- **Every reader prompt additionally carries CFI-U0 verbatim.** A spawned reader has no question surface and no notification surface either; it reports completion and blockage to its spawner by witness file and return value only, and never emits a banner by any route — not the notification tools, not a script, not by asking someone else to emit one on its behalf.

### Step 4: Witness collection (no resume)

Apply the protocol's `witness_present` completion predicate, its reconcile ladder, and its Case 1 / Case 2 / Case 3 escalations verbatim, with CFI-U0's substitution applied to every terminus. Flip each row to `done` with a last-return derived **from the witness content**. No reader is resumed for any reason (CFI-2).

### Step 5: Freeze verification, dedup, evidence

1. **Re-hash and re-compare both baselines** — the worktree half as the gate's **2a/2b/2c**, with 2a taken modulo the declared `-run-` exception. A sibling worktree's `HEAD` move is not a mismatch. **A mismatch is a halt, and the automatic re-audit count is zero.** Write the halt record with `분류: freeze-mismatch`, naming **which** assertion diverged, the baseline value, the observed value, `FROZEN_SHA256`, and — in `재호출 명령` — the exact re-invocation command line. Then stop.

   **Why no automatic re-audit.** What the freeze contract calls for after a mismatch is a fresh invocation against a *new* freeze, and that requires a judgment that the tree has settled. The only evidence for that judgment is the baseline, which has just been proven broken. A driver that re-invokes anyway turns a single pass into a bounded-only-by-budget loop, and does so exactly when the tree is *demonstrably* in motion. The judgment is a human's; the command line is recorded so they can make it in the morning. There is deliberately no "continue anyway" path — that is the seam through which a positive induced-defect rate re-enters.

2. **Dedup into unique defects** (identity = same anchor or section AND same root cause) and record each defect's **reinforcement multiplicity**. Merge the Step-2 deterministic findings in: they count toward `원시` and `고유` and are **excluded from `미보강`** by definition, which is what keeps the `원시 ≥ 고유 ≥ 미보강` invariant sound.
3. **Copy each collected reader report in-tree** to `<base>/docs/design-audit/{slug}.reader-<k>.md`, each carrying the same `owner-doc=` machine header, **after** the freeze verdict.

### Step 6: Reconciliation pass (single, non-recursive)

**Read `${CLAUDE_SKILL_DIR}/../design-audit/references/03-adjustment-pass.md`.**

Record the `조정 시작` timestamp as the **first** act of this step. In one non-recursive pass: re-assign severity as a single labeller; route every unique defect to exactly one named owner; apply the accepted set; write the routed items into their carriers; ask the synthesis question of CFI-3b and answer it in writing; record `조정 종료`.

Severity is re-assigned here, by one labeller, in one pass. It is **never** aggregated across readers by taking a maximum — per-reader severity labels are not comparable, so a maximum is a ratchet rather than a measurement.

**This pass edits the design document, so it takes the document lock.** Wrap each write in `/usr/bin/lockf -k -t 0 "${RUN_DIR}/designdoc.lock" <command>` (absolute path; `-k` and `-t 0` both required). `EX_TEMPFAIL` (75) means another writer holds the document, which is a planning violation rather than a queue: do not wait, do not retry — halt with `분류: precondition-failed` naming both writers.

### Step 7: Residual disclosure + HARD STOP

**Read `${CLAUDE_SKILL_DIR}/../design-audit/references/04-disclosure-block.md`.**

Compose the disclosure block, run the four anti-vacuity self-checks, write the report, write the block into the report in Korean, then **Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and apply the terminal strip plus `rm -rf "$WITNESS_DIR"`. Emit the next-step line, then stop with the literal statement *"이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다."*

That literal is the driver's terminal predicate, so it must be emitted byte for byte. **The next-step line is inert** — it is a cwd-relative string for a human to run in the morning, and nothing downstream executes it.

### (There is no Step 8.)

The absence is the contract, not an oversight. A further audit is a new invocation against a new hash.

## Options

> _Consistency Note: README의 user-facing 옵션 표는 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent가 읽는 작동 규약(`{BASE_MODE_CONSTRAINT}` 치환 블록)이며, frontmatter 변경 시 함께 갱신._

### --base

Base design audit mode. When `$ARGUMENTS` contains `--base`, substitute the following block for `{BASE_MODE_CONSTRAINT}` in the reader prompt:

```
BASE MODE CONSTRAINT:
Verify consistency and completeness of the existing design content. Do NOT propose adding new implementation details.
- DO report: inconsistencies, contradictions, or missing interface definitions between existing sections.
- DO report: essential supplements to existing content that are clearly needed for consistency.
- DON'T report: adding new implementation details that don't currently exist (these belong to task-level design).
- DON'T report: removing or reducing existing detailed design content.
```

**Repo-measurement carve-out (BASE MODE)**: the repo ground-truth measurement of the reader contract is in-scope even under `--base` — an artifact the document's architecture requires but no step creates is an internal incompleteness of the existing design, not a new implementation detail.

When `--base` is absent, substitute a single empty line so the prompt structure stays stable.

## Constraints

- **Do NOT modify the design document during the freeze window** (CFI-1). The reconciliation pass of Step 6 edits it; readers never do.
- **Never fabricate** a finding, an anchor verdict, a `path:line` citation, or a slot integer (CFI-4).
- **No reader is resumed** and no second round is spawned, for any reason (CFI-2).
- **Never reach a notification surface.** No `PushNotification`, no `notify.sh`, no `terminal-notifier` — not from this file and not from any agent it spawns. Notifying a sleeping user is the driver's exclusive job, and a working stage that also notifies is forbidden without exception.
- **Never write a pipeline sidecar.** This arm reads the grant to re-derive `RUN_DIR`; the driver is the sole writer of both pipeline sidecars.
- **The disclosure block's four checks are structural only.** The *truth* of the recorded integers cannot be checked. This is the deliberate split: garbage output is fenced structurally, interpretable misjudgment is left to prose.

Task: $ARGUMENTS
