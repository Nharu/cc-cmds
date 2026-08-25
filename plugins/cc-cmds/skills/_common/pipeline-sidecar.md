# Pipeline Sidecar Contract (Shared SOT)

The payload schemas for the autonomous pipeline's durable state. Generic mechanics — path and slug derivation, the header grammar and `owner-doc=` provenance guard, the atomic compare-and-swap write, the never-delete lifetime, the version token — are **not restated here**: they live in `_common/sidecar.md` §1 and this file cites them read-only. What follows is only what §1 delegates to a payload schema: the kinds, their block grammars, their field sets, their mutability splits, and their write forms.

Two sidecar kinds and one non-sidecar record are defined:

| Artifact | Kind token | Writer | Location |
| --- | --- | --- | --- |
| Authorization record | `cc-pipeline-grant v1` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-grant/{slug}.md` |
| Run ledger | `cc-pipeline-run v1` | the driver **only** | `<base>/docs/pipeline-run/{slug}.md` |
| Halt record | `cc-pipeline-halt v1` | the halting stage | volatile run directory (§4) — **not a sidecar** |

**Why the authorization is a separate file from the ledger.** The decision is about **exposure**, not about structure or convention. In a single file the bytes carrying the permission grant pass through the writer's transform on **every append**, all night; in two files they pass through it **once per run**. That asymmetry holds under both fault models — a bug in the transform and a bug in the append gate — and it matters here specifically because **no lint validates a sidecar**, so a protection that does not rest on gate correctness is the one that actually pays. Progress cursor and resume state still live in **one** ledger; the grant is not progress state, it is the run's input contract.

---

## 1. Writer partition — and why it is total

**The driver is read-only against the grant.** The only writer of `cc-pipeline-grant` is the kickoff skill `autopilot`; the driver reaches it by no path at all. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Giving the all-night process no write access does not mitigate that residual, it **deletes** it: a process with no write path cannot widen its own authorization no matter how it fails. What remains is misbehaviour by the kickoff skill itself, which happens with a human watching.

**The driver is the sole writer of the ledger, from the main worktree.** Stage processes emit structured output on stdout and **never write a sidecar** — not the ledger, not the grant. `sidecar.md` §1.3 states plainly that its compare-and-swap narrows the check-then-act window to a single process spawn rather than eliminating it, so N segment processes resolving to one `<base>` would contend in that residual window and destroy the loser's block. A single writer does not arbitrate that contention; it removes it by construction.

This partition is what lets the ledger's `stage-result` rows exist at all: the driver writes them **from the exit code and the artifacts it observed**, never from a stage's self-report, so the invariant is preserved verbatim rather than excepted.

---

## 2. `cc-pipeline-grant v1` — the authorization record

```
# 파이프라인 인가 기록 — {slug}
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=<document key>[; origin-worktree=<absolute worktree root>]; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 2.1 Blocks

One block per run: `## 인가 <run-id>`, where `<run-id>` is assigned at kickoff and is unique within the file. Blocks **accumulate** (§1.4 forbids deleting them) and each is **frozen from the instant it is appended** — there is no field with a mutable region, no disposition, and no close form. Re-authorizing means a **new run** with a new `<run-id>`, never an edit.

### 2.2 Field schema — 9 fields, fixed order

| # | Field | Required | Notes |
| --- | --- | --- | --- |
| 1 | `인가 일시` | always | ISO 8601; the reference point for every other field in the block |
| 2 | `종료 지점` | always | what the user declared "done" to mean for this run |
| 3 | `권한 절단점` | always | one value from the ordered vocabulary of §2.3 — at or below it is autonomous, above it is the blocked queue |
| 4 | `말단 행위 상한` | always | an integer, or `없음` (the default) |
| 5 | `직렬 웨이브 고지` | always | `수행` \| `해당 없음` — records that the user was told a wave carrying residual verification items runs serially |
| 6 | `시각 정합 마커` | always | `없음` \| `있음(인가)` \| `있음(park)` — the kickoff entry check of §2.4 |
| 7 | `사용자 확인 문면` | always | the user's own words authorizing this run, **verbatim** — the only field a human can audit a forged grant against |
| 8 | `설계 문서 전체 sha256` | always | the document's whole-file digest at kickoff |
| 9 | `보고서` | always | the run's morning-report path (§3.5) |

Field lines use the CANON rendering of `_common/verification.md`: bold key, no leading bullet, one ASCII space after the colon. A payload-bearing field is fenced per `sidecar.md` §2.5, whose fence and truncation rules apply here unchanged.

### 2.3 The permission cutpoint is ordered, not a set of toggles

```
커밋 → 브랜치 → push → PR → 머지 → 배포 → 머지 후 후속 착수
```

**Display form above, stored token in the field.** Field 3 carries the **token**, and for six of the seven rungs the two strings are identical — the exception is the last, which displays as `머지 후 후속 착수` and stores as `머지후착수`. A grant written from the display text matches no token, and the consequence is not a parse warning: the index lookup reports "unknown", `authorized()` denies every act, and the run produces a night of blocked terminal acts with nothing naming the cause. Unrecognized tokens are therefore a **hard stop** rather than a silent zero, and `scripts/lint-cutpoint-vocabulary.sh` derives this ladder from the driver's vocabulary so the rendering here cannot drift from the values it describes.

The interview takes **one** cutpoint. Everything at or below it is autonomous; the first act above it sends its segment to the blocked queue — it does **not** ask, because there is nobody to ask. Two consequences are part of this contract rather than implementation detail:

- **`머지` does not carry an `--admin` exception.** A run blocked by branch protection parks. A driver that granted itself the exception because it "was authorized to merge" would be widening the grant silently, which is exactly what §1 exists to prevent.
- **A failed non-required check parks.** The shipped policy enumerates failed non-required checks and asks whether to merge, and forbids merging without an answer. Unattended, the answer never comes, so that branch **is** the park branch. It is stated here because a clause that fires rarely with a human present becomes a default path without one.

`terraform plan` needs no grant entry — it is already classified as a read.

**`말단 행위 상한` defaults to `없음`.** The cutpoint authorizes a *class* of act, and the class is allowed for as many segments as the plan turns out to have. The accepted risk is explicit: at authorization time nobody knows how many merges the cutpoint permits, because segmentation happens later and a re-design can re-split it. Where the field carries an integer, the ledger latches the measured segment count at segment-planning time and routes the excess to the blocked queue → morning batch → a re-authorization command.

### 2.4 Foreign grants fail closed

Because `sidecar.md` §1.4 forbids deletion and `{slug}` folds every run of one document onto one path, **run N+1 finds a grant it did not write.** A run treats any existing grant whose `<run-id>` is not its own as **foreign**. A foreign grant is a **hard stop reported to the user**, never inherited authorization. Silently inheriting a previous run's merge permission is the one failure here that is both invisible and irreversible.

This is also the pipeline's only *immediate* notification trigger: the run is stopped until a human confirms, and a human confirming recovers the whole night. (Contrast the blocked queue, where waking someone recovers nothing.)

### 2.5 Write form and its diff gate

One write form: **append**. The writer emits a whole new `## 인가 <run-id>` block with all 9 fields through the compare-and-swap of `sidecar.md` §1.3. Its gate is the append gate: **0 removed lines**, every added line inside the new block. A write that edits a line of an existing block fails the gate — this schema has no rewrite form.

---

## 3. `cc-pipeline-run v1` — the run ledger

```
# 파이프라인 런 원장 — {slug}
<!-- cc-pipeline-run v1; writer=orchestrator; reader=orchestrator; owner-doc=<document key>[; origin-worktree=<absolute worktree root>]; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.1 Blocks and rows

Block 0 is `## 계획 <run-id>` — the plan record written when the run starts. Every later block is `## 실행 <run-id>` and holds **rows**. A row is one line:

```
- `<계열>` | <필드>=<값> | <필드>=<값> | …
```

Values containing `|` or a newline are fenced per `sidecar.md` §2.5 and the row carries the fence's info string instead of the inline value.

### 3.2 The row series is closed at nine

**A writer that needs a kind not on this list extends this definition; it does not improvise one.** The absence of that rule is what produced a ledger whose own sections disagreed about who wrote what.

| `계열` | Fields |
| --- | --- |
| `run` | `run-id` · `시작` · `설계 문서` · `전체 sha256` · `구속면 다이제스트` · `RUN_DIR` · `보고서` |
| `generation` | `세대` · `전체 sha256` · `구속면 다이제스트` · `세그먼트 계획` · `segmentation`(`ok` \| `low-confidence`) |
| `segment` | `id` · `선언 파일 집합` · `plan-binding-digest` · `상태` · `브랜치` · `PR` · `커밋` · `사전 HEAD` · `베이스 sha` · `워크트리` |
| `stage-result` | `세그먼트` · `스테이지`(S-id) · `종료 코드` · `아티팩트 술어 결과` · `plan_sha256`(`implement` only) · `실행 버전` · `종단 부류` |
| `cycle` | `세그먼트` · `사이클` · `리포트 경로` · `P0` · `P1` · `P2` · `P3` · `lane 결정` |
| `problem` | `동일성`(`정규화 경로` + `카테고리 태그`) · `현재 단` · `단 이력` · `payload`(근본 원인 문구) |
| `자율 승인` | `kind` · `결정` · `기각된 대안` · `근거` · `finding-id`(required iff `kind=severity`) |
| `cost` | `누적 usd` · `스테이지 수` · `관측 시각` |
| `blocked` | `대상` · `사유` · `관측` · `재개 명령` |

**`실행 버전` belongs to `stage-result`, not to `segment`.** The session uuid is derived from `owner-doc|구간|단계|시도`, so `시도` must be durable — otherwise a reboot re-derives a uuid already bound to a different transcript. Attaching the field to the per-stage row is what makes that durable at the right granularity.

**`stage-result` is what removes the last edge into stage-owned ledger writes.** Its every field is observable by the driver from outside the stage: an exit code it waited on, artifacts it can stat, a digest it can compute. Nothing here requires the stage to report anything.

### 3.3 Closed vocabularies

| Field | Values |
| --- | --- |
| `자율 승인.kind` | `lane` \| `citation` \| `severity` \| `visual-waiver` |
| `blocked.사유` | `인가 한도` \| `사다리 R4` \| `자동 채택 미달` \| `예산·벽시계` \| `게이트 park` \| `시각 정합 park` |
| `stage-result.종단 부류` | `정상 완료` \| `의도된 park` \| `공허한 성공` \| `크래시` |
| `segment.상태` | `계획됨` \| `실행중` \| `리뷰중` \| `머지됨` \| `park` |
| `generation.segmentation` | `ok` \| `low-confidence` |

**Severity adjudication and parking are not new kinds.** A severity tie-break is a `자율 승인` row with `kind=severity`; a park is a `blocked` row with a `사유`. Reusing the two existing series with a required discriminator is what keeps the count at nine while still making each case findable.

**`kind=severity` requires `finding-id` for a reason that is not bookkeeping.** The shipped review rule defaults to the higher severity *unless the lead resolved the dispute*, and unattended there is no observable event that makes "the lead resolved it" true or false. So the exception counts as fired **only** where a `자율 승인` row records the decision, the rejected alternative, both rationales, and the finding it applies to; with no such row the rule's default branch applies. This enforces the rule's own third sentence rather than overriding it, and the interactive path is unchanged.

### 3.4 Write form and its diff gate

One write form: **append** — a new row, or a new `## 실행 <run-id>` block. Gate: **0 removed lines**. `segment.상태` advancing is expressed as a **new `segment` row** for the same `id`, not as an edit; readers take the last row for an `id` as current. This keeps a single append gate for the whole schema and leaves the run's history intact for the morning audit.

### 3.5 The morning report is a ledger-referenced companion

The report lives at `<base>/docs/pipeline-run/{runId}.md` — the same `<kind>` directory and the same kind token, so **no new kind is created** and the §1.2 guards apply to it unchanged. It is named by `<run-id>` rather than by `{slug}`, which means it is **not independently re-derivable** from the design document the way §1.1 sidecars are; it is found through the `보고서` field of the `run` row. That is the whole of the difference, and it is why run-id naming is admissible here and was rejected for the ledger: the ledger must be findable with nothing but the document in hand, the report must not.

- **Writer**: the driver. **Created as a stub by `autopilot` at kickoff**, so the file exists even if the run dies mid-way.
- **It must be durable independently of any banner**, because the notification seat's contract does not include delivery confirmation. The report is the source of truth; the banner is a courtesy. Every event writes the report **first** and attempts the banner second — the immediate-notification events included — since a seat with no delivery confirmation can otherwise leave a banner as the only record of something nobody saw.
- **No push adapter is seated today, and that is a stated limitation rather than a pending task.** The driver has no tool inventory, so a push surface would have to be reached by dispatching a stage — and a spawned stage is barred from deciding whether a banner reaches the user. The seat's three operations stay defined so an in-process implementation can drop in, but until one does, **the run may not reach a sleeping user at all**. Nothing downstream may assume it does; the morning report is the whole of the guarantee.
- **It enumerates every decision the run made autonomously** — all `자율 승인` rows grouped by `kind` with decision, rejected alternative and rationale carried verbatim; every fix the ladder auto-adopted; every parked item with its `사유`; and each stage's `종단 부류`.

**The limit is stated with the control.** The report is itself authored by the run, so it is powerless against a run that improvises a decision **and also** omits it from its own report. The conjunction being rarer than either part is the whole of this control's value — it is not a gate, and **the real protection against an irreversible autonomous act remains the permission cutpoint of §2.3.**

---

## 4. `cc-pipeline-halt v1` — the halt record (not a sidecar)

When an unattended arm reaches a point that needs a human, it writes a halt record and stops. This is the **durable form of the plain-text failure report that `implement`'s fail-loud rule already prescribes** — a proper subset of it — so no shipped fail-loud paragraph changes.

```
${RUN_DIR}/halt/<stage-id>.md
RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>
```

```
<!-- cc-pipeline-halt v1; writer=<skill>; reader=orchestrator; stage=<stage-id>; run=<run-id> -->
**중단 시각**: <ISO8601>
**스킬**: <skill name>
**스텝**: <step identifier>
**분류**: tool-unavailable | gate-unanswerable | freeze-mismatch | precondition-failed
**질문 문면**: <the Korean question that would have been asked, verbatim, never summarized>
**선택지**:
- `<label>` — <description, verbatim>
**하네스 오류**: <the original harness error string, verbatim> | (없음)
**재호출 명령**: <the command line the skill would have emitted, verbatim> | (없음)
**후속**: 보류 큐
<!-- /cc-pipeline-halt v1 -->
```

- **Written with the atomic form of `sidecar.md` §1.3** (temp file in the same directory, then rename), so a partial record is never observed. The closing fence is the terminator: a record whose last non-empty line is not `<!-- /cc-pipeline-halt v1 -->` is **a crash mid-write, not a halt**.
- **`재호출 명령` is inert.** The driver records it and **never executes it**. Auto-running it retries a condition whose cause is still present, which makes a single pass into a bounded-only-by-budget loop — and does so precisely when the tree has been *proven* to be in motion. The field is named for its inertness because attributing that in prose is not enough: the predictable failure is a future implementer wiring it to a dispatcher.
- **Termination discipline**: write the record atomically → take **no further step** (no cleanup beyond what the halting step already committed, no partial progress, no fallback act) → end the turn normally.
- **The discriminator is the artifact, not the exit code.** A halt is a *clean* stop, so its terminal envelope looks like a normal completion, and a model-driven skill cannot set an exit code to mean otherwise. **Exit says the stage ended; the halt record says why.** Both are machine-read; neither is prose.
- **The volatile run directory is deliberately not durable.** Process handles — `stage-pid`, process-group id, transcript paths — live here and nowhere else, so a stale record and a stale process die together and pid reuse cannot make the driver kill an unrelated live process. It is under `XDG_STATE_HOME` rather than `${TMPDIR}` because `/var/folders` is swept without a reboot, and "no record ⇒ no process" must not be falsified by a sweep.

---

## 5. Termination recognition — the driver never parses prose

> **The driver's input from a stage is exactly two things — that the process ended, and what it left on disk. Prose output is never parsed for control flow: not the report body, not the Korean summary, not the next-step line.**

Skills do emit next-step command strings; the rule binds the **reader**, not the writer, which is why no skill text needs editing. Such a line is disqualified as a control signal anyway: it is emitted on the success path (so it cannot separate a finished audit from an aborted one) and it is cwd-relative (so it resolves against the wrong tree in a segment worktree). It is copied **verbatim as an opaque string** into the morning report, for the human who may run it.

### 5.1 Artifact predicates

| Stage | Predicate |
| --- | --- |
| `design` | the freeze literal *"설계 문서를 동결했습니다. 이후 이 세션에서는 문서를 수정하지 않습니다."* |
| `design-audit` | the terminal literal *"이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다."* + the `docs/design-audit/{slug}.reader-<k>.md` reader copies |
| `review` | the summary line `- **발견 요약**: 🔴 P0 N건 \| 🟠 P1 N건 \| 🟡 P2 N건 \| 🟢 P3 N건` in the report; the filename glob must accept the `review-pr{N}_{YYYY-MM-DD}[_v{N}].md` variants |
| `implement` | a git-state ladder — commit → branch ref → PR number, in the order the permission cutpoint authorizes. Evaluated by the driver **in the main tree** |
| `design-reconverge` | `docs/design-reconverge/{slug}.md` carrying `재수렴 sha256` and a two-value verdict (`재설계 필요` \| `불필요`), plus its confirming fixed literal. A terminal verdict returns to segment planning **unconditionally** |

**The predicates are not equally strong, and pretending otherwise makes the table read stronger than it is.**

> **A predicate over state the stage cannot fabricate — a git ref, a remote ref, a PR number — is immune to a hollow success. A predicate over an artifact the stage authors is not.**

`implement` meets that bar: a run that answered in prose and moved on produces no commit, so the ladder is false and the driver never consults the stage's self-report. `design-audit` and `review` do **not** meet it — a model that improvised past a question still reaches the skill's normal exit, emits the terminal literal, writes the reader copies, and writes a well-formed summary line. **For a stage whose only output is a document, no un-fabricable predicate exists.** That is recorded rather than papered over.

### 5.2 The four termination classes

Exit status and the artifact predicate are **independent axes**, and the halt record is the third. Crossing all three is what separates "it died" from "it believed it was finished".

| exit | predicate | halt record | class | driver action |
| --- | --- | --- | --- | --- |
| success | true | — | `정상 완료` | next stage |
| success | false | present | `의도된 park` | blocked queue, no retry |
| success | false | absent | `공허한 성공` | retry **once**, then blocked queue under a distinct reason |
| non-zero | false | — | `크래시` | retry at the boundary, `시도+1` |

Priority on read: **a halt record present ⇒ halt.** Absent and terminated ⇒ judge by the predicate.

The third row is a measured failure mode, and its retry count is argued in both directions: not zero, because one observation cannot rule out a transient cause; not the full retry budget, because a clean exit with no artifact is itself evidence that the next attempt does the same. Improvisation is deterministic, so a blind retry loop would reproduce it identically and burn the whole budget before reaching the ladder. **This does not restore the stop that the unattended arm removed** — nothing on the skill side can. It converts an unobservable failure into an observable one, which is the most the driver can do from outside.
