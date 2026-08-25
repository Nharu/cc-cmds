---
name: autopilot
description: 의도나 대상 하나를 받아 밤사이 무인으로 완주시키는 자율 파이프라인의 킥오프와 아침 보고
when_to_use: 사용자가 설계 문서·레포·PR·브랜치, 또는 아직 산출물이 없는 의도를 자리를 비운 동안 설계·감사·구현·리뷰·머지·적용까지 자동으로 진행시키고 싶을 때, 또는 그렇게 돌린 런의 아침 보고를 받을 때
disable-model-invocation: true
usage: "/cc-cmds:autopilot <의도 또는 대상> [--report]"
options:
    - name: "<의도 또는 대상>"
      kind: positional
      required: true
      summary: "이 런이 무엇에 관한 것인지 — 설계 문서 경로(`.md`), 레포 슬러그, PR·브랜치 참조, 또는 아직 산출물이 없는 자유 텍스트 의도. 앵커 종류는 1막의 진입 판정이 정한다."
      parse_note: "`$ARGUMENTS` 전체를 의도로 읽는다. `.md` 토큰이 있으면 문서 앵커 후보로 우선 해석하되, 최종 앵커 종류는 진입 판정과 사용자 확인이 정한다."
    - name: "--report"
      kind: flag
      default: "off (킥오프 모드 — 1막 인터뷰 후 드라이버 기동)"
      summary: "아침 보고 모드. 그 런의 매니페스트·원장·보고서를 읽어 한국어로 렌더링만 하고, 새 런을 시작하지 않는다."
notes: "인가 기록과 런 매니페스트를 쓸 수 있는 유일한 주체다. 드라이버는 두 파일에 어떤 경로로도 쓰지 않는다 — 밤새 도는 프로세스에 쓰기 권한이 없으면 그 프로세스의 어떤 버그도 자기 권한을 넓힐 수 없다."
---

Kick off an unattended pipeline run over an intent or a target, or render the morning report of one that already ran.

The user is present exactly once — here. Everything the run is allowed to do without them is decided in this conversation and frozen into a manifest and an authorization record.

## The kickoff is two acts, and the seam between them is where the human leaves

**Act 1 — a person is here.** Intent, entry judgment, target declaration and verification, the plan, its approval, and — if the plan needs a design document that does not exist — writing it, inline, right now.

**Act 2 — nobody is here.** Freeze the manifest, detach, run to completion.

**The design step is in Act 1 because of a tool, not because of taste.** `design` interviews through `AskUserQuestion`, and that tool is **absent from every headless process**. A design stage dispatched into the night does not degrade into a worse design — it cannot ask at all, and whatever it emits is anchored to nothing. Anyone who reads this as a preference will eventually try to "just let it run", so it is written here as what it is: a constraint.

## Control-Flow Invariants

**CFI-1 — This skill is the only writer of the authorization record and the manifest.** The driver reads both and never writes either, by construction rather than by discipline. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Removing the write path removes the residual instead of mitigating it, and what remains is misbehaviour by this skill, which happens with a human watching. Never hand the driver a path, a helper, or a prompt that would let it write there.

**CFI-2 — One block per run, frozen at append.** Re-authorizing is a **new run with a new `<run-id>`**, never an edit to an existing block. There is no field with a mutable region and no close form. The manifest's `plan.md` is **creation-only**: it is frozen whole and has no append form at all.

**CFI-3 — The kickoff ends when the driver is launched.** This skill does not supervise the run, does not poll it, and does not stay resident. The morning report is a **separate invocation** (`--report`). A kickoff that waits around is a model-owned loop wearing a shell driver's clothes, and it fails in exactly the way the driver exists to prevent.

**CFI-4 — `arm` here, `cancel` there.** The notification lifecycle is split across two owners because a single owner would have to break one rule or the other. `arm` may not be started on a model's own judgment — it needs a user utterance, and this is the only place one exists. `cancel` is named in the spawned-agent prohibition, so no stage may do it; **the driver executes it.** Ask for the arming; never infer it.

**CFI-5 — The interview takes ONE cutpoint per target, not seven toggles.** See Act 1 Step 5. A per-act toggle matrix invites a grant that is incoherent under composition (push without commit), and it does not match how the user's own standing rules describe delegation. Per-target rather than per-run because a run may span repositories with different appetites — "infrastructure applies, the front end stops at a pull request" is not expressible as one scalar.

**CFI-6 — Act 2 starts only when Act 1 has nothing left to ask.** Every entry in the judgment's `unresolved` is answered, every target is confirmed by the user, and the plan is approved, before a single byte of the manifest is written. A question carried across the seam is a question nobody will answer.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:

- `ToolSearch("select:AskUserQuestion")` — MUST load before Act 1

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`** and apply its hard construction constraints to every call in this skill.

---

## Act 1 — with a person here

### Step 1: Read the contracts, then judge the entry

1. Parse `$ARGUMENTS`. `--report` selects the reporting mode — **if present, jump to Act 3.** Everything else is the intent, read whole.
2. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md`** (the whole of it — `## 2b` is the manifest contract this skill authors).
3. **Read `<plugin root>/orchestrator/prompts/entry-plan.md`** and produce the judgment it describes, satisfying `entry-plan.schema.json`. Check your own output against that schema before using it — required keys present, every enum value in range — with `jq`, not by eye.
4. If the judgment names a `doc` anchor, read that document and record its whole-file `sha256` (`shasum -a 256`).

### Step 2: Declare and verify the targets

The judgment **proposed** repositories; it did not decide them. Present the list and take a confirmation. For each confirmed target, resolve and verify on disk:

- the main worktree root, and its common git directory (`git rev-parse --path-format=absolute --git-common-dir`),
- the base branch,
- the remote slug (`<owner>/<name>`).

**A target that does not verify is a hard stop, not a warning.** The driver preflights the same values and refuses to start; discovering that here, with the user present, costs a sentence, and discovering it at 3am costs the night.

Exactly one target is `홈=예`. If the judgment could not tell which, ask.

### Step 3: Entry checks that must happen while a human is present

**Visual-fidelity marker.** If there is a design document, search it for a `## 시각 정합 기준` section.

If it is present, tell the user plainly and get a decision. The reason this belongs *here* rather than at runtime is that it is the only moment a human can answer it: that gate's cap clause forbids both auto-abandon and auto-advance, and those are the only two moves an unattended executor has, so the gate is unattended-ineligible by construction. **Ignoring the marker is explicitly rejected** — the gate writes zero bytes, so skipping it leaves no trace at all and work the user asked to be visually verified merges without it.

Ask with `AskUserQuestion` (header chip `시각 정합`):

- label `"그 세그먼트만 park (권장)"` — description: 마커가 걸린 화면을 구현하는 세그먼트는 보류 큐로 보내고 나머지는 계속 돕니다. 아침에 그 세그먼트만 직접 확인하시면 됩니다.
- label `"이 런에서 제외"` — description: 마커가 가리키는 작업을 이번 자율 실행의 범위에서 아예 뺍니다.
- label `"자율 실행 취소"` — description: 시각 검증이 이 작업의 핵심이라면 무인 실행 자체가 맞지 않습니다.

Record the answer in the manifest's `시각 정합 마커` field.

**Residual verification items.** Count the `### R<n>` entries under `## 구현 시 검증 항목` whose grade is the save-time residual token. Tell the user how many there are and which will run unattended — an external probe, a worktree recipe, or an execution-caution item **cannot** get consent overnight, so a pre-implementation one of those will stop the run. This is a notice, not a question; it goes into the report either way.

**Cross-repository stacking.** If more than one target was confirmed, say this out loud: **segments in different repositories cannot stack on each other's commits.** A dependency between them buys ordering and nothing more, because there is no commit in repository B that contains repository A's merge. It is the most likely place a first multi-repo run diverges from what the user pictured, and it costs one sentence here.

### Step 4: The plan, and the design if one is needed

Present the judgment's step graph as the plan, in Korean, and take an approval. Read out every `unresolved` entry and settle each one — CFI-6.

**If `design_required` is true, write the design now, inline, in this conversation.** Invoke the `design` skill on the confirmed anchor and let it interview the user; when it freezes a document, that document becomes the run's `doc` element and its `sha256` is recorded. Do not plan to "let the run design it" — see the two-acts note above. If the user does not want to do that now, the honest move is to stop: a run whose first stage cannot ask questions and has no document to implement produces nothing but a park.

**The approval utterance is captured verbatim.** It approves the STEP GRAPH, which is not the same thing as granting authority — that is Step 5. Collapsing the two promotes plan approval into permission approval silently, so the manifest carries them as two separate fields.

### Step 5: The interview

None of these has a safe default this skill may pick for the user.

**5a — Termination point.** What does "done" mean for this run? Free-form; it goes into the manifest verbatim and into the morning report. This is what the run is measured against.

**5b — The permission cutpoint, one per target (ordered, exactly one each).** Present the ladder and take one value for each confirmed target:

```
커밋 → 브랜치 → push → PR → 머지 → 배포 → 머지 후 후속 착수
```

**The ladder above is the DISPLAY form; the manifest stores the TOKEN.** Six of the seven are the same string in both forms, and the seventh is not — the last rung displays as `머지 후 후속 착수` and stores as `머지후착수`. Write the **token** into each target row's `절단점`, never the spaced display text. This is not a style note: a grant carrying the display form matched no token, the index lookup answered "unknown", and every act was denied while nothing reported why — the most permissive grant authorized nothing. `scripts/lint-cutpoint-vocabulary.sh` derives this ladder from the driver's own vocabulary, so the two forms cannot drift apart again.

At or below the chosen point the run acts on its own; the first act above it sends that segment to the blocked queue **without asking**, because there is nobody to ask. Two consequences must be stated out loud when the user picks `머지` or above:

- **`머지` does not carry an `--admin` exception.** A run blocked by branch protection parks. A driver that granted itself that exception because it "was authorized to merge" would be widening the grant silently.
- **A failed non-required check parks.** The shipped policy enumerates such failures and asks whether to merge, and forbids merging without an answer — so unattended, that branch *is* the park branch. It fires rarely with a human present and becomes a default path without one.

**5c — Apply, if any target's cutpoint is `배포`.** Take the apply command verbatim, the read-only probe that decides whether an apply is needed, the actor (`파이프라인` or `사람`), and — when the actor is the pipeline — the blast radius that parks if the apply's outcome cannot be judged. The default radius is the repository and it may only be **narrowed**. State plainly that the driver executes an apply itself, with zero retries, and that an outcome it cannot judge stops the declared radius and preserves the worktree for the morning.

**5d — Terminal-act cap, per target.** Default is `없음`, and say why the question is being asked at all: at this moment nobody knows how many merges the cutpoint authorizes, because segmentation happens later and a re-design can re-split it. Offer `없음` (recommended) or an integer. A number latches against the measured segment count and routes the excess to the blocked queue.

**5e — Wall-clock deadline.** An absolute ISO8601 timestamp, and it is **required** — `없음` is refused by the driver's own manifest check. It is a dispatch gate and never a kill signal: a stage in flight runs to completion and is classified normally, and no merge happens after it. Offer a default of the next morning and let the user move it.

**5f — Ladder rungs.** `4` (the full ladder: local fix, scoped re-convergence, root re-design, human) or `2` (stop after the scoped re-convergence). Say what `2` buys — a run that never re-designs on its own — and what it costs: more parks in the morning.

**5g — Morning notification.** Ask whether to arm a morning banner. **Ask — never infer** (CFI-4). On an affirmative, invoke the `active-notify` skill and `arm` it; on anything else, arm nothing and say that the report on disk is the only channel.

**Say what cannot be promised.** Before writing anything, state the two limits in one line each: **the run may not be able to reach you while you are asleep** — the notification seat provides no delivery confirmation and no push adapter is seated, so the report on disk is the source of truth — and **a stage that improvises past a decision point is not detectable**, which is why the report enumerates every autonomous decision for you to audit in the morning.

---

## Act 2 — freeze, launch, and leave

### Step 6: Write the manifest and the authorization record

Assign `<run-id>`: a short, collision-free identifier for this run. It, not the document, is what every path below is derived from — which is what stops two runs of one document from aliasing onto one ledger, one report, one worktree path and one session id.

**The manifest** at `<base>/docs/pipeline-run/<run-id>.plan.md`, written **whole, once** (creation-only; there is no append form). Its shape is `## 2b.1` of `pipeline-sidecar.md` — follow that section byte-for-byte rather than the sketch of it you remember. Two digests are computed here and **compared by the driver at entry**, so they are not decoration:

- `대상 맵 다이제스트` — sha256 over the canonical serialization of every `target` row (whitespace runs collapsed to one space, then sorted).
- `계획 다이제스트` — sha256 over the bytes inside the `## 실행 계획` fence.

**The example in that contract is fenced with four backticks because it contains three-backtick fences of its own.** Any document that explains this grammar has the same shape, which is why the parser reading it skips fenced spans and survives nesting — and why you must not "simplify" the nesting when you copy it.

**The authorization record** at `<base>/docs/pipeline-grant/<run-id>.md` — appended through the compare-and-swap of `sidecar.md` §1.3 with the **append** form's diff gate (0 removed lines; every added line inside the new block).

```
# 파이프라인 인가 기록 — <run-id>
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=<document key> | (없음); origin-worktree=<홈 워크트리 루트>; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 <run-id>
**인가 일시**: <ISO8601>
**종료 지점**: <5a 답변>
**권한 절단점**: <이 런의 최대 절단점 토큰 — 대상별 값은 매니페스트가 소유한다>
**말단 행위 상한**: 없음 | <정수>
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사용자 확인 문면**: <사용자 발화 축자>
**설계 문서 전체 sha256**: <hex> | (해당 없음)
**보고서**: <base>/docs/pipeline-run/<run-id>.md
```

**`사용자 확인 문면` is verbatim, and it is the only field a human can audit a forged grant against.** Do not paraphrase it, do not tidy it, do not translate it. It is **not** the same field as the manifest's `승인 문면`: that one approved the step graph, this one grants authority.

**`권한 절단점` in the grant is the run's maximum**, a derived audit value. The value that authorizes an act is the one in that target's row, and the driver reads it there.

### Step 7: Stub the report, launch, and stop

1. **Create the morning-report stub** at `<base>/docs/pipeline-run/<run-id>.md` — an H1 and the run's identifying line. The stub exists so that a run which dies halfway still leaves a file where the user looks.
2. **Launch the driver, detached**:
   ```
   bash <plugin root>/orchestrator/run.sh --manifest <매니페스트 절대경로> --detach
   ```
   The driver detaches exactly once — itself — and runs its stages in the foreground so it owns their process groups and can reclaim the whole tree on restart. Do not background the stages, and do not wrap this in a supervisor of your own.
3. **Report to the user in Korean and stop** (CFI-3): the run id, each target and its cutpoint, the deadline, where the report will be, and how to read it (`/cc-cmds:autopilot <run-id> --report`).

---

## Act 3 — the morning report (`--report`)

Read the manifest, the run ledger and the report for the named run, then render in Korean. **Render only — this mode starts nothing and writes nothing.**

Cover, in this order:

- **결과 요약** — segments planned, merged, **완성-미착지**, parked; where the run stopped against its `종료 지점`. Keep 완성-미착지 separate from parked: those segments produced everything they were asked to and had exactly one terminal act blocked, and folding them into "parked" hides the difference between a night that worked and a night that did not.
- **자율 결정 전부** — every `자율 승인` row, grouped by `kind`, carrying the decision, the rejected alternative, and the rationale as recorded. **This is the whole point of the report.** The residual it compensates for — a stage that asked in prose, answered itself, and produced output anyway — is byte-indistinguishable from a correct run through every channel the design permits, so after-the-fact auditability is the only control left. Do not summarize these rows away.
- **보류 큐** — every `blocked` row with its `스코프`, `원인`, `사유`, and the re-invocation command line where one was recorded. Group by scope: an `act` park is one command away from finished, a `cone` park needs its premise repaired first, and a `run` park means the run could not judge a state. **Those command lines are inert**: the driver recorded them and never ran them, and neither does this step. They are for the user's hands.
- **사람 대조 필요** — every report line so marked. These are the ones where the run could not tell "still working" from "stuck", or where an apply's outcome is unknown. Name the preserved worktree path for each apply of unknown outcome; it is the only reproduction of that state.
- **스테이지 종단 부류** — per stage: 정상 완료 / 의도된 park / 공허한 성공 / 크래시 / 적용 불명. Call out every `공허한 성공` explicitly; it is a measured failure mode that used to be invisible, and the point of naming it is that it can now be counted.
- **비용** — the accumulated `cost` rows, and the cycle count against the run's cycle budget.

**State the report's own limit at the end.** It is authored by the run it describes, so it is powerless against a run that improvises **and also** omits that from its own report. The conjunction being rarer than either part is why this control is worth having — it is not a gate, and the real protection against an irreversible autonomous act remains the permission cutpoints the user set in 5b.

---

## Constraints

- **Never write the run ledger.** The driver is its sole writer. This skill writes the manifest, the grant and the report stub, and nothing else under `docs/pipeline-run/` after that stub.
- **Never edit a design document from this skill.** Writing one through `design` in Act 1 is a different act with a human in it; editing an existing one from here is not.
- **Never infer the arming** (CFI-4). No user utterance, no `arm`.
- **Never run a `재호출 명령`** recorded by a halted stage. It is recorded precisely because re-running it would retry a condition whose cause is still present.
- **Do not supervise the run** (CFI-3). Launch and stop.
- **`--admin` is never authorized here**, whatever cutpoint the user picks.

Task: $ARGUMENTS
