---
name: autopilot
description: 설계 문서 하나를 밤사이 무인으로 완주시키는 자율 파이프라인의 킥오프와 아침 보고
when_to_use: 사용자가 작성이 끝난 설계 문서를 자리를 비운 동안 감사·구현·리뷰·머지까지 자동으로 진행시키고 싶을 때, 또는 그렇게 돌린 런의 아침 보고를 받을 때
disable-model-invocation: true
usage: "/cc-cmds:autopilot <design-doc-path> [--report]"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "자율 실행 대상 설계 문서 경로 (`.md`). 킥오프와 아침 보고 양쪽에서 런을 식별하는 키다."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰을 경로로 해석. 경로는 문서 자신의 위치에서 절대 경로로 정규화해 드라이버에 넘긴다."
    - name: "--report"
      kind: flag
      default: "off (킥오프 모드 — 인터뷰 후 드라이버 기동)"
      summary: "아침 보고 모드. 그 문서의 가장 최근 런 원장과 보고서를 읽어 한국어로 렌더링만 하고, 새 런을 시작하지 않는다."
notes: "인가 기록을 쓸 수 있는 유일한 주체다. 드라이버는 그 파일에 어떤 경로로도 쓰지 않는다 — 밤새 도는 프로세스에 쓰기 권한이 없으면 그 프로세스의 어떤 버그도 자기 권한을 넓힐 수 없다."
---

Kick off an unattended pipeline run over one design document, or render the morning report of one that already ran.

The user is present exactly once — here. Everything the run is allowed to do without them is decided in this conversation and frozen into an authorization record.

## Control-Flow Invariants

**CFI-1 — This skill is the only writer of the authorization record.** The driver reads it and never writes it, by construction rather than by discipline. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Removing the write path removes the residual instead of mitigating it, and what remains is misbehaviour by this skill, which happens with a human watching. Never hand the driver a path, a helper, or a prompt that would let it write there.

**CFI-2 — One block per run, frozen at append.** Re-authorizing is a **new run with a new `<run-id>`**, never an edit to an existing block. There is no field with a mutable region and no close form.

**CFI-3 — The kickoff ends when the driver is launched.** This skill does not supervise the run, does not poll it, and does not stay resident. The morning report is a **separate invocation** (`--report`). A kickoff that waits around is a model-owned loop wearing a shell driver's clothes, and it fails in exactly the way the driver exists to prevent.

**CFI-4 — `arm` here, `cancel` there.** The notification lifecycle is split across two owners because a single owner would have to break one rule or the other. `arm` may not be started on a model's own judgment — it needs a user utterance, and this is the only place one exists. `cancel` is named in the spawned-agent prohibition, so no stage may do it; **the driver executes it.** Ask for the arming; never infer it.

**CFI-5 — The interview takes ONE cutpoint, not seven toggles.** See below. A per-act toggle matrix invites a grant that is incoherent under composition (push without commit), and it does not match how the user's own standing rules describe delegation.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:

- `ToolSearch("select:AskUserQuestion")` — MUST load before Step 1

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`** and apply its hard construction constraints to every call in this skill.

### Step 1: Resolve and read

1. Parse `$ARGUMENTS`. The first `.md` token is the document; `--report` selects the reporting mode. A missing or non-`.md` target is a hard stop with a Korean one-liner.
2. **If `--report`, jump to Step 6.**
3. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md`.** Derive, from the **document's own directory** and never the cwd: the document key, `{slug}`, and `<base>` (the repository's main worktree root).
4. Read the design document. Record its whole-file `sha256` (`shasum -a 256`).
5. **Check for an existing authorization record** at `<base>/docs/pipeline-grant/{slug}.md`. Because that file is never deleted and `{slug}` folds every run of one document onto one path, a previous run's block will be there. That is normal — a new run appends a new block. What is **not** normal is a block from a run that is still live; say so and stop if one is found.

### Step 2: Entry checks that must happen while a human is present

**Visual-fidelity marker.** Search the document for a `## 시각 정합 기준` section.

If it is present, tell the user plainly and get a decision. The reason this belongs *here* rather than at runtime is that it is the only moment a human can answer it: that gate's cap clause forbids both auto-abandon and auto-advance, and those are the only two moves an unattended executor has, so the gate is unattended-ineligible by construction. **Ignoring the marker is explicitly rejected** — the gate writes zero bytes, so skipping it leaves no trace at all and work the user asked to be visually verified merges without it.

Ask with `AskUserQuestion` (header chip `시각 정합`):

- label `"그 세그먼트만 park (권장)"` — description: 마커가 걸린 화면을 구현하는 세그먼트는 보류 큐로 보내고 나머지는 계속 돕니다. 아침에 그 세그먼트만 직접 확인하시면 됩니다.
- label `"이 런에서 제외"` — description: 마커가 가리키는 작업을 이번 자율 실행의 범위에서 아예 뺍니다.
- label `"자율 실행 취소"` — description: 시각 검증이 이 작업의 핵심이라면 무인 실행 자체가 맞지 않습니다.

Record the answer in the grant's `시각 정합 마커` field.

**Residual verification items.** Count the `### R<n>` entries under `## 구현 시 검증 항목` whose grade is the save-time residual token. Tell the user how many there are and which will run unattended — an external probe, a worktree recipe, or an execution-caution item **cannot** get consent overnight, so a pre-implementation one of those will stop the run. This is a notice, not a question; it goes into the report either way.

### Step 3: The interview

Four questions, and none of them has a safe default this skill may pick for the user.

**3a — Termination point.** What does "done" mean for this run? Free-form; it goes into the grant verbatim and into the morning report. This is what the run is measured against.

**3b — The permission cutpoint (ordered, exactly one).** Present the ladder and take one value:

```
커밋 → 브랜치 → push → PR → 머지 → 배포 → 머지 후 후속 착수
```

At or below the chosen point the run acts on its own; the first act above it sends that segment to the blocked queue **without asking**, because there is nobody to ask. Two consequences must be stated out loud when the user picks `머지` or above:

- **`머지` does not carry an `--admin` exception.** A run blocked by branch protection parks. A driver that granted itself that exception because it "was authorized to merge" would be widening the grant silently.
- **A failed non-required check parks.** The shipped policy enumerates such failures and asks whether to merge, and forbids merging without an answer — so unattended, that branch *is* the park branch. It fires rarely with a human present and becomes a default path without one.

**3c — Terminal-act cap.** Default is `없음`, and say why the question is being asked at all: at this moment nobody knows how many merges the cutpoint authorizes, because segmentation happens later and a re-design can re-split it. Offer `없음` (recommended) or an integer. A number latches against the measured segment count and routes the excess to the blocked queue.

**3d — Morning notification.** Ask whether to arm a morning banner. **Ask — never infer** (CFI-4). On an affirmative, invoke the `active-notify` skill and `arm` it; on anything else, arm nothing and say that the report on disk is the only channel.

**Serial-wave notice (not a question).** Tell the user: *"병렬 완주는 사용 가능하며, 잔여 검증 항목을 실은 웨이브 하나는 직렬로 돕니다."* Name it, measure it, and move on — it is a real constraint that mostly does not apply, and stating it up front is what keeps it from reading later as a silent collapse of parallelism.

**Say what cannot be promised.** Before writing the grant, state the two limits in one line each: **the run may not be able to reach you while you are asleep** — the notification seat provides no delivery confirmation and no push adapter is seated, so the report on disk is the source of truth — and **a stage that improvises past a decision point is not detectable**, which is why the report enumerates every autonomous decision for you to audit in the morning.

### Step 4: Write the authorization record

Assign `<run-id>`: a short, collision-free identifier for this run. Then append one block through the compare-and-swap of `sidecar.md` §1.3, with the **append** form's diff gate (0 removed lines; every added line inside the new block).

```
# 파이프라인 인가 기록 — {slug}
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=<document key>; origin-worktree=<문서 워크트리 루트>; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 <run-id>
**인가 일시**: <ISO8601>
**종료 지점**: <3a 답변>
**권한 절단점**: <3b 값 하나>
**말단 행위 상한**: 없음 | <정수>
**직렬 웨이브 고지**: 수행
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사용자 확인 문면**: <사용자 발화 축자>
**설계 문서 전체 sha256**: <hex>
**보고서**: <base>/docs/pipeline-run/<run-id>.md
```

**`사용자 확인 문면` is verbatim, and it is the only field a human can audit a forged grant against.** Do not paraphrase it, do not tidy it, do not translate it.

### Step 5: Stub the report, launch, and stop

1. **Create the morning-report stub** at `<base>/docs/pipeline-run/<run-id>.md` — an H1 and the run's identifying line. The stub exists so that a run which dies halfway still leaves a file where the user looks.
2. **Launch the driver, detached**:
   ```
   bash <plugin root>/orchestrator/run.sh --doc <설계문서 절대경로> --run-id <run-id> --detach
   ```
   The driver detaches exactly once — itself — and runs its stages in the foreground so it owns their process groups and can reclaim the whole tree on restart. Do not background the stages, and do not wrap this in a supervisor of your own.
3. **Report to the user in Korean and stop** (CFI-3): the run id, the cutpoint, where the report will be, and how to read it (`/cc-cmds:autopilot <문서> --report`).

### Step 6: Morning report rendering (`--report`)

Read the run ledger `<base>/docs/pipeline-run/{slug}.md` and the report `<base>/docs/pipeline-run/<run-id>.md` for the most recent run of this document, then render in Korean. **Render only — this mode starts nothing and writes nothing.**

Cover, in this order:

- **결과 요약** — segments planned, merged, parked; where the run stopped against its `종료 지점`.
- **자율 결정 전부** — every `자율 승인` row, grouped by `kind`, carrying the decision, the rejected alternative, and the rationale as recorded. **This is the whole point of the report.** The residual it compensates for — a stage that asked in prose, answered itself, and produced output anyway — is byte-indistinguishable from a correct run through every channel the design permits, so after-the-fact auditability is the only control left. Do not summarize these rows away.
- **보류 큐** — every `blocked` row with its `사유`, and the re-invocation command line where one was recorded. **Those command lines are inert**: the driver recorded them and never ran them, and neither does this step. They are for the user's hands.
- **스테이지 종단 부류** — per stage: 정상 완료 / 의도된 park / 공허한 성공 / 크래시. Call out every `공허한 성공` explicitly; it is a measured failure mode that used to be invisible, and the point of naming it is that it can now be counted.
- **비용** — the accumulated `cost` rows.

**State the report's own limit at the end.** It is authored by the run it describes, so it is powerless against a run that improvises **and also** omits that from its own report. The conjunction being rarer than either part is why this control is worth having — it is not a gate, and the real protection against an irreversible autonomous act remains the permission cutpoint the user set in 3b.

---

## Constraints

- **Never write the run ledger.** The driver is its sole writer. This skill writes the grant and the report stub, and nothing else under `docs/pipeline-run/` after that stub.
- **Never edit the design document.** Not one byte, in either mode.
- **Never infer the arming** (CFI-4). No user utterance, no `arm`.
- **Never run a `재호출 명령`** recorded by a halted stage. It is recorded precisely because re-running it would retry a condition whose cause is still present.
- **Do not supervise the run** (CFI-3). Launch and stop.
- **`--admin` is never authorized here**, whatever cutpoint the user picks.

Task: $ARGUMENTS
