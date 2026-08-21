---
name: design-audit
description: 동결된 설계 문서를 독립 리더 팬아웃으로 1회 감사하고 정합 조정 1회 후 정지 (반복 루프 없음)
when_to_use: 설계 문서 작성이 끝나 더 이상 수정하지 않을 시점에, 문서를 동결한 뒤 레포 실측 기반 독립 감사로 잔여 결함을 드러내고 이름 붙은 하류 소유자에게 인계하고자 할 때 (design 종단 이후 · design-apply의 impl-design.md · implement 직전)
disable-model-invocation: true
usage: "/cc-cmds:design-audit <design-doc-path> [<note>] [--base]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "감사 대상 설계 문서 경로 (`.md`). 첫 리더 spawn 직전의 sha256으로 동결되며, 감사가 끝날 때까지 어떤 바이트도 수정되지 않는다."
    - name: "<note>"
      kind: positional
      required: false
      summary: "문서 경로 뒤 자유 텍스트. 전 리더에게 **축어로 동일하게** 주입되는 초점 메모 (리더별로 다르게 주면 보강 통계가 무의미해지므로 금지)."
    - name: "--base"
      kind: flag
      default: "off"
      summary: "base 설계 문서 모드 — 기존 내용의 정합·완결만 감사하고 신규 구현 세부 제안을 금지한다. FE 파이프라인이 확장한 base 문서의 호출 형태."
notes: "반복 라운드가 없다. 외부 이터 0회 · 리더당 1라운드 · 조정 1회 후 하드 스톱이며, 재감사는 새 sha256에 대한 새 호출이다."
---

Audit a FROZEN design document with an independent reader fan-out, reconcile once, then stop.
All reader prompts and internal team communication are in English to optimize token usage.
User-facing communication is Korean.

This is a **single pass over a frozen document** — NOT a convergence loop, and it must never become one. The document is hashed before the first reader spawns and is not edited again until every reader has returned; that freeze is what makes the audit's reproduction rate provably sub-critical, and it is the whole reason this command replaced the loop that preceded it.

## Input

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

`$ARGUMENTS` is the path to a design document (`.md`), optionally followed by a free-text note and/or the flag `--base`. The **first `.md` token** is the document path; `--base` is extracted wherever it appears; everything else, joined, is the note. See Step 1 for parsing.

## Control-Flow Invariants

These rules govern termination and the freeze contract, and MUST stay near the top of this file. Post-compaction reattaches only the first ~5K tokens with priority. A summarized-away rule here does not merely degrade quality — the model's default behavior when handed a pile of findings is to keep reviewing, so losing CFI-2 or CFI-3 **resurrects, inside this command, the unbounded loop this command exists to delete.** That is why this skill takes the invariant heading rather than an exemption: its termination state is not recoverable from the ledger. A ledger whose rows all read `done@fanout` looks byte-identical whether the correct next act is "reconcile and stop" or "spawn round 2".

### CFI-0 — Fixed constants (single source of truth)

```
READER_COUNT = 3
ROUNDS_PER_READER = 1
OUTER_ITERATIONS = 0
ADJUSTMENT_PASSES = 1
ROUND_TOKEN = 1
PASS_TOKEN = fanout
```

These six lines are the **only** place any of these values appears in this skill. Every other mention — prose here, `references/*.md`, the spawn prompt, the disclosure block — refers to them **by name**. A hook reads `READER_COUNT` from this block directly and never from a spawn prompt, because a copy drifts.

`READER_COUNT` is a **budget, not a target.** It is fixed by the single-pass reconciliation limit: one more reader adds roughly a third again as many raw findings and pushes that limit, while the residual-disclosure block adds **zero** raw items. Do NOT justify it with a coverage formula of the `1 − (1 − c)^N` family — that model is statistically rejected for this population (heterogeneous detection; the defect-pool profile likelihood is unbounded above, so any coverage figure derived from it is an upper bound that cannot be audited even with unbounded budget). `READER_COUNT` is the designated adjustment handle; changing any other line here is a redesign, not a tuning.

### CFI-1 — Freeze (the mechanism, not hygiene)

The freeze window opens at the last pre-spawn write of Step 1 and closes when the last reader witness is collected. Inside it, no `Edit`/`Write` may target the document and nothing may change in the tree. Three artifacts are recorded at the open — `FROZEN_SHA256`, the `git status --porcelain` baseline, and the `git worktree list --porcelain` baseline (the two-command boundary gate of `${CLAUDE_SKILL_DIR}/../_common/verification.md`) — and all three are re-checked at the close.

This is load-bearing, not tidiness. The audit's reproduction rate stays below 1 only while the induced-defect rate is zero, and that rate becomes positive the instant any byte of the reviewed text changes between reviews. Reader witnesses are written out-of-tree precisely so the boundary baselines stay untouched; the in-tree reader-report copies are written **after** the window closes.

### CFI-2 — Fan-out shape (there is no round 2, ever)

Exactly `READER_COUNT` readers, each spawned exactly once, each performing `ROUNDS_PER_READER` round.

**Declared carve-out**: the shared team protocol's multi-round rule — its `### Round budget` together with the ban on a one-shot isolated `Agent()` per round — is **inapplicable here, and this sentence is the explicit exception.** The rule is referenced rather than quoted so this carve-out cannot drift away from the value it exempts. Cross-review IS the reproduction channel this command removes — a reader that has seen a peer's finding is no longer an independent replicate. **No reader is ever resumed**; `SendMessage` is deliberately not loaded in Step 0, so a resume is not merely forbidden but tool-unavailable. The protocol's same-round respawn on a death verdict is the only re-spawn permitted; it reuses `ROUND_TOKEN`/`PASS_TOKEN` unchanged and is bounded by the protocol's durable escalation counters, every one of which terminates in an `AskUserQuestion` rather than in another autonomous spawn.

### CFI-3 — One reconciliation pass, then HARD STOP

The reconciliation pass consumes the collected report set exactly once. It **MUST NOT** call `Agent()`, **MUST NOT** re-open a dispositioned finding, and **MUST NOT** treat its own edits as new input. The invocation's only exit is Step 7. There is no Step 8, no outer iteration, and no "one more round" — a further audit is a **new invocation against a new sha256**, which is why the freeze-violation branch emits a re-invocation command line and stops instead of looping internally.

The hard stop forbids **re-review**, not editing. Once the stop is reached the document is an ordinary edit target again; each post-stop edit carries the marker `**미리뷰(스톱 이후 추가)**` so the next cycle can find it.

**CFI-3b — Synthesis question (mandatory terminal act).** The pass may not close by dispositioning items one at a time. Its last act is to ask, once, in writing: *"이 발견들이 **함께** 함의하는 요구사항이 있는가?"* Items that are locally small in separate readers' reports compose into requirements that appear in no single report, and only the reconciling side can see that composition. Without this step that class of finding arrives **after** the stop.

**CFI-3c — Not a round cap.** This invariant fixes the freeze and the non-recursion discipline. It carries no numeric round budget; do not add one here.

### CFI-4 — Observed-result precondition (anti-fabrication)

No finding, anchor verdict, count, or slot value may be recorded unless it came from a collected witness. The lead never authors a reader's witness and never infers one from a return text. Uncertain means fail closed.

### CFI-5 — Disclosure is a precondition of stopping

Step 7 cannot complete without a disclosure block that passes all four anti-vacuity checks. Boundedness is enforced by this gate, not by prose: the stop is the only exit and the gate is the only way through it.

### CFI-6 — Forbidden imports (loop-resurrection denylist)

None of the following may appear anywhere under this skill: `consecutive_no_major`, `COUNT_APPLIED`, `escalate_applied`, `INNER_EXIT_REASON`, `inner_round`, `outer_iter`, `outer_log.md`, `ack_items.md`, `pending_applies.md`, `INNER_TEMP_DIR`, a severity max-aggregation ratchet, and any auto-approve or auto-reject predicate used as a **termination input**. This command still triages, but no counter anywhere depends on the triage outcome, so the incentive gradient that collapsed the predecessor's filter does not exist.

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:

- `ToolSearch("select:AskUserQuestion")` — MUST load before Step 1
- `ToolSearch("select:TaskStop")`

`Agent` is built-in. **`SendMessage` is deliberately NOT loaded** — no member is ever resumed (CFI-2), and its absence is a structural guard rather than an omission.

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`** and apply its hard construction constraints to every AskUserQuestion call in this skill.

### Step 1: Resolve, validate, FREEZE

1. **Parse** `$ARGUMENTS` per `## Input`. A missing or non-`.md` target is a hard stop with a Korean one-liner.
2. **Read the whole document.** An unparseable or empty document is a hard stop (nothing to freeze).
3. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1`** and derive, from the **document's own directory** and never the cwd: `CODE_ROOT` (`git rev-parse --show-toplevel`, falling back to the document's directory), the **document key**, and `{slug}`.
4. **FREEZE.** Record `FROZEN_SHA256` (`shasum -a 256`) plus both git baselines. Create `<base>/docs/design-audit/` and early-stub the report at `<base>/docs/design-audit/{slug}.md`: an H1 title, the machine header `<!-- cc-design-audit v1; writer=design-audit; reader=design-audit; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->`, the `<!-- cc-design-ledger v3 … -->` block (this stub is the ledger's home, so no fallback location is ever needed), and a `## 감사 개시` block carrying `frozen-sha256`, `frozen-at`, `reader-count`, `round-token`, `pass-token`. The `frozen-sha256` recorded here is never rewritten — it is the second hash that anti-vacuity check (i) compares against.
5. **Notify once, in Korean** (a one-way notice, not a question): the target, the hash prefix, *"리더 팬아웃 1라운드 후 정지 — 추가 라운드 없음"*, and the post-stop `**미리뷰(스톱 이후 추가)**` convention.

### Step 2: Deterministic checks (ONCE, outside the replication channel)

**Read `${CLAUDE_SKILL_DIR}/references/02-deterministic-checks.md`** and run it once.

A check whose detection probability is essentially 1 gains nothing from N-fold replication — its coverage is already saturated at one run. Replication buys value only for judgment classes whose per-reader detection probability is below 1. Running these once, in the main session, is therefore not a shortcut: it is what frees the readers' whole budget for the semantic measurement only they can do.

Write the output into the report as `## 결정론적 검사` and hand its path to **all** readers identically so no reader re-does mechanical work. Capture the boundary baselines **after** this write; the freeze window opens here.

### Step 3: Fan-out spawn

**Before spawning, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the spawn / witness / ledger v3 / reconcile-ladder contract and the task-assignment header, and **Read `${CLAUDE_SKILL_DIR}/references/01-reader-prompt.md`** for the reader prompt.

Readers are **nameless background tasks** (`Agent` with `subagent_type:"claude"`, `run_in_background:true`, **no `name`**), self-terminating on return; each reader's result is delivered by its **witness file** and the return text is only an early-wake hint. The `Agent()` call **omits `model`** so readers inherit the session model.

- **Witness scratch dir (parameters for the protocol)**: before the first spawn, `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{slug}.XXXXXX")`, recorded as each reader's `scratchDir`. The witnessed phase is `PASS_TOKEN` (colon-free, as the protocol requires) and the witness path is `${WITNESS_DIR}/reader-<k>.fanout.md`. The witness dir is out-of-tree, leaving the boundary gate untouched.
- **Ledger**: record each returned `agentId` immediately (`state=running`, phase `fanout`), stamping `epoch` and the phase `witnessNonce` on every row in the same at-spawn recording window, per the protocol.
- **MUST — byte-identical prompts.** The `READER_COUNT` rendered prompts differ **only** in `{WITNESS_PATH}`, `{WITNESS_NONCE}`, and `{role-slug}`. Differentiating readers by lens silently destroys the reinforcement statistic the `미보강 잔여 수` slot reports: with disjoint lenses every finding is trivially unreinforced and the slot becomes noise.

### Step 4: Witness collection (no resume)

Apply the protocol's `witness_present` completion predicate, its reconcile ladder, and its Case 1 / Case 2 / Case 3 escalations verbatim — do not restate them here. Flip each row to `done` with a last-return derived **from the witness content**. No reader is resumed for any reason (CFI-2).

### Step 5: Freeze verification, dedup, evidence

1. **Re-hash and re-compare both baselines.** A mismatch is fail-closed: report in Korean what changed, then `AskUserQuestion` with `재감사(새 동결로 재실행) ← 추천` — which emits the exact re-invocation command line and **stops** — or `중단`. There is deliberately no "continue anyway" option: that is the seam through which a positive induced-defect rate re-enters.
2. **Dedup into unique defects** (identity = same anchor or section AND same root cause) and record each defect's **reinforcement multiplicity** — how many readers independently raised it. Merge the Step-2 deterministic findings in: they count toward `원시` and `고유` and are **excluded from `미보강`** by definition, since reinforcement is not a meaningful notion for a saturated channel. That exclusion is what keeps the `원시 ≥ 고유 ≥ 미보강` invariant sound.
3. **Copy each collected reader report in-tree** to `<base>/docs/design-audit/{slug}.reader-<k>.md`, each carrying the same `owner-doc=` machine header, **after** the freeze verdict. These are the durable artifacts anti-vacuity check (ii) counts; the out-of-tree witness stays where the protocol put it.

### Step 6: Reconciliation pass (single, non-recursive)

**Read `${CLAUDE_SKILL_DIR}/references/03-adjustment-pass.md`.**

Record the `조정 시작` timestamp as the **first** act of this step. In one non-recursive pass: re-assign severity as a single labeller; route every unique defect to exactly one named owner; apply the accepted set; write the routed items into their carriers; ask the synthesis question of CFI-3b and answer it in writing; record `조정 종료`.

Severity is re-assigned here, by one labeller, in one pass. It is **never** aggregated across readers by taking a maximum — per-reader severity labels are not comparable (measured spread across readers on one document was better than twofold), so a maximum is a ratchet rather than a measurement. Readers do not emit severity tiers at all, so there is nothing to aggregate even if someone tried.

### Step 7: Residual disclosure + HARD STOP

**Read `${CLAUDE_SKILL_DIR}/references/04-disclosure-block.md`.**

Compose the disclosure block, run the four anti-vacuity self-checks, write the report, echo the block in Korean, then **Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and apply the terminal strip plus `rm -rf "$WITNESS_DIR"`. Emit the next-step line, then stop with the literal statement *"이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다."*

### (There is no Step 8.)

The absence is the contract, not an oversight. A further audit is a new invocation against a new hash, bounded by the same argument as this one.

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

**Repo-measurement carve-out (BASE MODE)**: the repo ground-truth measurement of the reader contract is in-scope even under `--base` — an artifact the document's architecture requires but no step creates is an internal incompleteness of the existing design, not a new implementation detail. Using a measurement *result* as a vector for a new task-level design-substance proposal within the same finding remains forbidden.

When `--base` is absent, substitute a single empty line so the prompt structure stays stable.

`--base` is not decoration. A base design document is deliberately intent-level, and an unconstrained reader against an intent-level document emits a flood of "missing implementation detail" findings. That inflates the raw finding count, which pushes the single-pass reconciliation limit, which is the one structural selector fixing `READER_COUNT` (CFI-0). The flag is therefore a control on the exact constraint that fixes the budget.

## Constraints

- **Do NOT modify the design document during the freeze window** (CFI-1). The reconciliation pass of Step 6 edits it; readers never do.
- **Never fabricate** a finding, an anchor verdict, a `path:line` citation, or a slot integer (CFI-4).
- **No reader is resumed** and no second round is spawned, for any reason (CFI-2).
- **The disclosure block's four checks are structural only.** The *truth* of the recorded integers cannot be checked — a lead that runs the readers and then writes plausible-but-wrong numbers passes all four. This is the deliberate split: garbage output is fenced structurally, interpretable misjudgment is left to prose.

Task: $ARGUMENTS
