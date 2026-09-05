---
name: autopilot
description: 목표 하나를 받아 이 세션이 라우터가 되어 스킬 호출을 스스로 정하며 완주시키는 파이프라인의 킥오프와 아침 보고
when_to_use: 사용자가 설계 문서·레포·PR·브랜치, 또는 아직 산출물이 없는 목표를 던져 두고 설계·감사·구현·리뷰·머지·적용까지 알아서 이어지게 하고 싶을 때 — 진행은 이 터미널에서 보이고 중요한 결정만 물어 온다. 또는 그렇게 돌린 런의 아침 보고를 받을 때
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
notes: "인가 기록과 런 매니페스트를 쓸 수 있는 유일한 주체다. 게이트도 스테이지도 두 파일에 어떤 경로로도 쓰지 않는다 — 밤새 도는 것에 쓰기 권한이 없으면 그것의 어떤 버그도 자기 권한을 넓힐 수 없다. 순서는 이 세션의 모델이 매 원장 쓰기마다 정하고, 그 결정이 무엇을 해도 되는지는 게이트가 판정한다."
---

Kick off an unattended pipeline run over an intent or a target, or render the morning report of one that already ran.

The user is present exactly once — here. Everything the run is allowed to do without them is decided in this conversation and frozen into a manifest and an authorization record.

## The kickoff is two acts, and the seam between them is where the human leaves

**Act 1 — a person is here.** Intent, entry judgment, target declaration and verification, the plan, its approval, and — if the plan needs a design document that does not exist — writing it, inline, right now.

**Act 2 — the person may leave.** Freeze the manifest, start the watcher, and enter the router loop. Nobody has to stay, but the terminal keeps showing what happens, and an approval waits for them rather than guessing.

**The design step is in Act 1 because of a tool, not because of taste.** `design` interviews through `AskUserQuestion`, and that tool is **absent from every headless process**. A design stage dispatched into the night does not degrade into a worse design — it cannot ask at all, and whatever it emits is anchored to nothing. Anyone who reads this as a preference will eventually try to "just let it run", so it is written here as what it is: a constraint.

## Control-Flow Invariants

**CFI-1 — This skill is the only writer of the authorization record and the manifest.** The driver reads both and never writes either, by construction rather than by discipline. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Removing the write path removes the residual instead of mitigating it, and what remains is misbehaviour by this skill, which happens with a human watching. Never hand the driver a path, a helper, or a prompt that would let it write there.

**CFI-2 — One block per run, frozen at append.** Re-authorizing is a **new run with a new `<run-id>`**, never an edit to an existing block. There is no field with a mutable region and no close form. The manifest's `plan.md` is **creation-only**: it is frozen whole and has no append form at all.

**CFI-3 — This session IS the router, and it does not detach.** The run is not handed to a background driver that decides things out of sight; the model reading these words takes the turns, and the terminal shows the run happening. What that buys is the whole reason for the shape: progress is visible while it happens, and the person can interrupt.

What the router may NOT do is decide from memory. Its input is the snapshot and nothing else — see Act 2b. The session is compacted repeatedly over a long run, so a router that leaned on conversation history would have its input silently rewritten, and every claim about reproducibility would go with it.

The morning report stays a **separate invocation** (`--report`), because a run that spans days is read from disk rather than from a scrollback.

**CFI-4 — Two seats raise banners, and neither of them is an agent.** The liveness watcher outlives the session and is orphaned to init; the adjudication gate is a shell script the router calls. The shared operating rules bar a *spawned agent* from deciding whether a banner reaches the user, and nothing that raises one here is spawned — that is the whole of why this run may raise banners at all. **The number is kept deliberately even though the content changed**: citations to it live outside this file, in pull request comments, issues and other agents' reports, and a renumbering would leave every one of them pointing at a real but unrelated invariant, which is indistinguishable from a correct citation. This skill arms nothing and cancels nothing.

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

    **The argument is an INTENT, never a question to answer.** A kickoff phrased as a question — "이거 개선이 가능할까?" — is still a kickoff, and there is no branch in this skill that reads it as conversation and ends there. Measured: one arrived that way and the lead investigated the code, interviewed with the question tool, wrote a design document alone, and stopped — no entry judgment, no target verification, no plan approval, no interview, no manifest, no grant, no watcher, no router loop. **The run did not exist**, and the deviation surfaced only because the user asked why the procedure had not run. If the intent is a question, answer it *by performing Act 1* — the interview is where the question gets asked back properly.
2. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md`** (the whole of it — `## 2b` is the manifest contract this skill authors).
3. **Read `<plugin root>/orchestrator/prompts/entry-plan.md`** and produce the judgment it describes, satisfying `entry-plan.schema.json`. Check your own output against that schema before using it — required keys present, every enum value in range — with `jq`, not by eye.
4. If the judgment names a `doc` anchor, read that document and record its whole-file `sha256` (`shasum -a 256`).

### Step 2: Declare and verify the targets

The judgment **proposed** repositories; it did not decide them. Present the list and take a confirmation. For each confirmed target, resolve and verify on disk:

- the main worktree root, and its common git directory (`git rev-parse --path-format=absolute --git-common-dir`),
- the base branch,
- the remote slug (`<owner>/<name>`),
- and, **when the work belongs to a branch that is checked out in a linked worktree, that worktree** — recorded as `실행 워크트리` on the target row.

**That last one is not a convenience.** The main worktree is where the sidecar goes, so that N linked worktrees of one repository converge on one location; but the act has to run where the branch actually is, and for a `pr` or `branch` anchor those are never the same directory, because git refuses to check one branch out twice. Find it with `git worktree list` and record it. Omit the field when the repository has only one worktree — the driver falls back to the main one. Get this wrong and nothing announces it: the stage starts, the files are readable, and it reads a different version of them.

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

**Residual verification items — and the access they need, TAKEN not just announced.** Count the `### R<n>` entries under `## 구현 시 검증 항목` whose grade is the save-time residual token. Tell the user how many there are and which will run unattended: an external probe, a worktree recipe, or an execution-caution item **cannot** get consent overnight, so a pre-implementation one of those will stop the run.

Then — for each item that would stop it — **read what that item's own recipe says it needs, and ask the user for it here.** Every residual item already writes down its requirement; nothing in Act 1 used to collect it, so the person was told "this will stop the run" and then allowed to leave without being asked the one thing that would prevent it. Take the credential, the profile name, the tunnel, the endpoint — whatever the recipe names — verbatim, and record it against that `R<n>`. Where the answer is "that item does not need to run", record that too: it is the cheapest possible resolution and it is invisible to every later stage.

This is the difference the measurement showed. A run stopped at 04:32 on three pre-implementation items. In the morning: one needed a secret this machine's profiles already reached, one needed a database this machine already had a key for — both settled in minutes, both passing — and the third turned out not to be exercisable at all, its premise already refuted elsewhere in the same document. Two answers and one deletion, none of them longer than a sentence, and a whole night spent to discover that a stage had to succeed and be billed first.

**Announce the residual items even when none of them blocks** — that part is a notice and goes into the report either way. The questions above are only for the ones that would stop the run.

**Cross-repository stacking.** If more than one target was confirmed, say this out loud: **segments in different repositories cannot stack on each other's commits.** A dependency between them buys ordering and nothing more, because there is no commit in repository B that contains repository A's merge. It is the most likely place a first multi-repo run diverges from what the user pictured, and it costs one sentence here.

### Step 4: The plan, and the design if one is needed

Present the judgment's step graph as the plan, in Korean, and take an approval. Read out every `unresolved` entry and settle each one — CFI-6.

**If `design_required` is true, the design is written now, in this conversation — and YOU CANNOT INVOKE IT.** `design` carries `disable-model-invocation`, so the Skill tool refuses it and the refusal forbids reproducing the workflow by other means. That is deliberate: `design` is reserved for explicit user invocation. So the handoff is explicit rather than implied.

**Tell them, in the same breath, that `design` will end by pointing at `/cc-cmds:design-audit` — and that they should not follow it.** That skill's handoff does not know it was called from here, and the audit is already a stage in the graph they just approved. Following it runs the audit twice, once by hand and once as the stage; *not* returning here is worse — the manifest, the grant and the ledger are all still unwritten, so a kickoff abandoned at that line leaves nothing on disk and cannot be told apart from one that never started.

Ask the user to run `/cc-cmds:design <anchor>` themselves, and say why in one line — the design step interviews, and the tool that interviews is absent from every headless process, so it belongs to the act with a human in it. **Then wait.** When they come back, resume this kickoff, take the path of the document `design` froze, record its whole-file `sha256`, and continue from Step 5 with that document as the run's `doc` element. Do not re-run Act 1 from the top; the targets and the entry judgment already hold.

Do not plan to "let the run design it" — see the two-acts note above. If the user does not want to run it now, the honest move is to stop: a run whose first stage cannot ask questions and has no document to implement produces nothing but a park.

**Before presenting, check the graph against the cutpoints — the gate will.** Where any target's cutpoint reaches `머지`, two rules fire at the merge that the graph must already satisfy: a review record covering the branch's current HEAD with P0·P1 at zero, and a review session whose ancestry is disjoint from the implementation's. A graph that runs `implement` and then merges is **not executable**, and the schema accepts it, so nothing else catches this — the user approves a plan that cannot run and the mismatch surfaces at the merge, in the middle of the night. Add the review step, and say out loud that it is a separate stage rather than a phase of the implement one.

**Present what each step will actually DO, not just its name.** A one-line-per-step graph reads far shallower than the work is: a `review` step is a multi-round agent team with a reconciliation pass, an `implement` step is two processes split across a plan-emission gate. Approving "S1 review" is not the same as approving that. One clause per step is enough — the point is that the person refusing has seen the shape.

**The approval utterance is captured verbatim.** It approves the STEP GRAPH, which is not the same thing as granting authority — that is Step 5. Collapsing the two promotes plan approval into permission approval silently, so the manifest carries them as two separate fields.

### Step 5: The interview

None of these has a safe default this skill may pick for the user.

**5a — Termination point.** What does "done" mean for this run? Free-form; it goes into the manifest verbatim and into the morning report. This is what the run is measured against.

**When the graph puts an audit before the work, say that the audit can move this out of reach — before taking the answer.** An audit routes its findings to owners, and one of those owners is the design document's `## 미해결 이슈` bucket, which means *a person has to answer this*. Unattended there is nobody, so a single audit can make the termination point being frozen right now unreachable, and it is the **second** step that does it. Measured: a termination point of "all three slices landed" was frozen with a 09:00 deadline; the audit ran first, completed normally, produced 29 unique defects, and routed 15 of them into that bucket — taking the document from 5 open items to 20. From that moment the run could not proceed, and it stopped and waited, which is correct behaviour. What was wrong is that this was foreseeable at kickoff and nobody said it.

An audited-first graph is the *normal* path for a run that starts from a design document, so this is not an edge case. Offer the user the choice explicitly: freeze a termination point that stops at the audit's output, or keep the further one and accept that the morning may show it unmet for a reason that is the mechanism working.

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

The deadline rests on the same assumption 5a just qualified: the user picks a time believing the implementation happens overnight. If an audit stands first in the graph, what exists at that hour may be the audit's output and nothing else. Say so while they choose the time, not afterwards.

**5f — Ladder rungs.** `4` (the full ladder: local fix, scoped re-convergence, root re-design, human) or `2` (stop after the scoped re-convergence). Say what `2` buys — a run that never re-designs on its own — and what it costs: more parks in the morning.

**5g — The banner kill switch, announced rather than asked.** There is no question here any more: the two seats of CFI-4 raise a banner whenever the run cannot pass a point without a person, and that is on by default. What this step owes the user is the **resolved state, said out loud** — because the value can only be chosen before the run starts, and this is the last moment anyone can notice that what they meant to set and what is actually in force are different things.

Say all three of these:

- 「이 런의 배너를 전부 끄시려면 런을 시작하기 전에 `CC_CMDS_AUTOPILOT_NOTIFY=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」
- 「런 도중에는 끌 수 없습니다. 감시자는 기동할 때 환경을 물려받고 다시 읽지 않고, 게이트는 호출마다 별개의 프로세스라 앞 호출에서 건 값이 다음 호출에 남지 않습니다 — 지금이 정하는 자리입니다.」
- 「이 배너들은 서로를 밀어내지 않고 쌓입니다. 여덟 건까지는 하나씩 따로 남고, 그보다 많아지면 나머지는 한 자리에 모여 개수로만 표시됩니다 — 화면에 보이는 배너 수가 실제로 답을 기다리는 건수보다 적을 수 있다는 뜻이고, 빠짐없는 목록은 아침 보고서에 있습니다.」

**Say what cannot be promised.** Before writing anything, state the two limits in one line each. First: 「이 채널이 파는 것은 「깨우기」가 아니라 「처음 보는 화면」입니다 — 돌아와서 보실 때 답을 기다리는 멈춤이 한눈에 들어오는 것. 여덟 건까지는 개별로, 그 이상은 묶여서 보입니다. 전수를 보장하는 것은 배너가 아니라 디스크의 보고서입니다.」 **Say the two halves of that separately**, because they are a measurement and an ordinary fact rather than one observation: this notifier has no permission to override a focus mode, and a focus or sleep schedule suppresses banners and sounds together. "No banner wakes a sleeping person" is the *sum* of those two, and someone who reads only the first will over- or under-trust the channel. Second: **a stage that improvises past a decision point is not detectable**, which is why the report enumerates every autonomous decision the run recorded, for you to audit in the morning.

---

## Act 2 — freeze, then start routing

### Step 6: Write the manifest and the authorization record

Assign `<run-id>`: a short, collision-free identifier for this run. It, not the document, is what every path below is derived from — which is what stops two runs of one document from aliasing onto one ledger, one report, one worktree path and one session id.

**Resolve `<base>` first, the way the driver does, and never assume it equals the worktree you are standing in.** From the home target's worktree, take the **parent of the common git directory**:

```
BASE=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
```

In an ordinary checkout that is the same string as `git rev-parse --show-toplevel`. **In a linked worktree it is not** — it is the repository's main worktree root, which is the whole point: N linked worktrees of one repository must converge on one location, or state that has a single writer fans out with the worktrees while every copy carries identical headers.

`origin-worktree=` in the manifest header is a *different* value — the document's own worktree root, which the manifest check compares against the current one. Do not reuse it as `<base>`. Writing all four paths below under `origin-worktree` puts the authorization record, the report stub and the watcher's `--ledger` argument in one worktree while the gate writes the ledger in another; both sets are well-formed, so nothing reports it. Measured: a stage ran 40 minutes and grew the gate's ledger by 41 rows while the watcher was measuring a stub that never changed and the authorization record sat where the gate never looks. It reproduces only when the document is in a linked worktree, so an ordinary checkout will not show it.

**The manifest** at `<base>/docs/pipeline-run/<run-id>.plan.md`, written **whole, once** (creation-only; there is no append form). Its shape is `## 2b.1` of `pipeline-sidecar.md` — follow that section byte-for-byte rather than the sketch of it you remember.

**It freezes the goal and the constraints, not the plan.** There is no plan digest, and the absence is deliberate: the router decides the step graph one act at a time from a snapshot, so a frozen plan would be a value that is recorded and never compared — the exact defect this contract exists to remove, arriving as a leftover.

Two digests are computed here and **compared at entry**, so they are not decoration:

- `대상 맵 다이제스트` — sha256 over the canonical serialization of every `target` row (whitespace runs collapsed to one space, then sorted).
- `구속 다이제스트` — sha256 over the whole frozen set: the goal, the termination point decomposed into checkable `종료 절` rows, the target rows, the rule-catalog settings, the `사전 인가` rows, the `자동 채택` rows, and the deadline. Both are kept rather than merged, so that a target-row edit is reported as a target-row edit instead of as "something in the frozen set moved".

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
**직렬 웨이브 고지**: 수행 | 해당 없음
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사용자 확인 문면**: <사용자 발화 축자>
**설계 문서 전체 sha256**: <hex> | (해당 없음)
**보고서**: <base>/docs/pipeline-run/<run-id>.md
```

**Nine fields, in that order, and the gate now refuses a block that is missing any of them.** The contract fixes the count and gives this block no rewrite form — it is frozen at append, and re-authorizing is a new run rather than an edit — so a field omitted here is omitted for the life of the run. This template carried eight for a while, dropping `직렬 웨이브 고지`, and nothing on the reading side compared the set. `직렬 웨이브 고지` records that the user was told the residual-item wave runs serially; write `해당 없음` when there was no such wave.

**`사용자 확인 문면` is verbatim, and it is the only field a human can audit a forged grant against.** Do not paraphrase it, do not tidy it, do not translate it. It is **not** the same field as the manifest's `승인 문면`: that one approved the step graph, this one grants authority.

**`권한 절단점` in the grant is the run's maximum**, a derived audit value. The value that authorizes an act is the one in that target's row, and the driver reads it there.

### Step 7: Stub the report, start the watcher, enter the loop

1. **Create the morning-report stub** at `<base>/docs/pipeline-run/<run-id>.md` — an H1 and the run's identifying line. The stub exists so that a run which dies halfway still leaves a file where the user looks.
2. **Take the first snapshot, THEN start the watcher.** The run directory is created by the router's first gate call, and the watcher treats a missing directory as "the run went away" and exits — silently, with status 0. Started in the order this list used to give, it was gone before the run began: measured, watcher up at 03:18:0x and the directory created at 03:18:36, with the launching call reporting success. One `gate.sh snapshot --manifest <매니페스트>` first makes the directory exist; the watcher also waits out a short startup window now, but the ordering is what makes that window unnecessary.
3. **Start the liveness watcher in the background**:
   ```
   bash <plugin root>/orchestrator/watch.sh --run-dir <RUN_DIR> --ledger <원장 경로> --stall 1200 --interval 60 --after-stage 120 --run-open 300 > <RUN_DIR>/watch.log 2>&1 < /dev/null &
   ```
   It resumes nothing and decides nothing. Its whole job is to make one failure visible — **the router quietly stopping** — which is otherwise indistinguishable from a quiet terminal. It also emits a positive heartbeat, because a watcher that only speaks on failure cannot be told apart from a watcher that died.

   **It stops itself.** The gate writes a `done` file into the run directory when the run terminates, and the watcher exits on seeing it — or on the run directory going away. Nothing else reaps it: the gate ends a run without touching it and Act 3 is forbidden from starting or writing anything, so before this the loop outlived every run it watched. Measured on one machine: seven watchers from seven runs, the oldest a day and four hours.

   **There is no `--notify` flag any more, and passing one is now an invalid invocation.** Banners are governed by `CC_CMDS_AUTOPILOT_NOTIFY` and by nothing else. A second parsing site is what made the flag worth removing rather than defaulting: with it in place, a user who set the variable went on receiving every banner this process raises while believing they had switched them off. This is still one of the two seats where raising a banner is allowed at all — a spawned agent may not, and a shell script that outlives the session is not an agent (CFI-4).

   **The heartbeat goes to a file, not only to stdout.** This is launched in the background by a tool call that then returns, so its stdout is closed and anything printed there reaches nobody. `watch.heartbeat` in the run directory is rewritten every pass, and its mtime is what makes the watcher's own liveness measurable.

   **All four thresholds are the script's own defaults and none of them is an attempt to change anything.** They are pinned here because the status line has to decide whether a heartbeat is fresh, and a threshold it cannot read from a contract is a threshold it invents. `--stall 1200` and `--interval 60` were spelled out for that reason and the two newer arms then went unwritten, which left the only configuration this run actually uses readable nowhere. `--after-stage 120` is how long a stage's terminal row may sit as the last row before the router is named, and it is also the idleness the run-open arm requires. `--run-open 300` is how long the run may be open with no segment. They are all deliberately NOT matched to the status line's own 180-second staleness mark: that mark is a render that clears itself on the next tick, while these arms write a ledger row that only a person's resolving row takes back. Two different costs deserve two different thresholds.

   **The redirection is new, and discoverability is its whole justification.** The harness keys a background task's output on an internal task id, which cannot be walked back to a run directory — so the watcher's loud line landed somewhere nobody could find from the one place a person actually looks in the morning, which is the run directory. `< /dev/null` goes with it so the process cannot be stopped waiting on a terminal that is no longer there.
4. **Tell the user, in Korean, what is about to happen**: the run id, each target and its cutpoint, the termination point, and that the run is now visible in this terminal rather than detached.
5. **Enter the router loop of Act 2b.** Do not stop here.

---

## Act 2b — the router loop

The router decides **what happens next**. The gate decides **whether it may**. Those two jobs used to live in the same `case` arms of a shell driver, so neither could move without the other; splitting them is the point of this design, and this act is the half that judges.

### The loop, and its only input

```
snapshot  →  decide  →  gate call  →  (repeat)
```

1. **Read the snapshot.** `bash <plugin root>/orchestrator/gate.sh snapshot --manifest <매니페스트>` — one JSON object. Add `--render` for the human table when reporting to the terminal; that table carries the run's liveness — live stages, how long ago the ledger grew, the watcher's last heartbeat, and whether the run has terminated — so "is this still going?" is one command rather than a pid comparison. **This is the router's entire declared input.** Do not carry a decision across turns, do not remember an obligation the snapshot does not show, and do not treat a previous turn's plan as binding.
2. **Decide one next act.**
3. **Call the gate with that decision as argv.** The decision is not a document the router writes; **it is the argv**, and the gate's argument parser is the schema check. That is also what makes the router testable without a model in the loop: drive the verbs with bad argv against a fixture ledger and assert the exit code.
4. **Read the exit code and go back to 1.**

**THE LOOP DOES NOT STOP TO ASK.** The person was present exactly once, in Act 1, and everything the run may do without them was frozen there. Inside this loop there is **one** place a question belongs — exit 5, where the gate has issued an approval and the run genuinely cannot answer itself. Everywhere else the router decides, records the decision, and continues.

That includes the moments that feel like natural checkpoints: a stage just finished, a review came back with findings, the next step is large or expensive, the previous act failed. None of those is a question. **A router that asks at one of them stops the run**, and the stop is invisible — the ledger is well-formed, the last row is a normal one, nothing refused anything. It is not even distinguishable from a run waiting on an approval, because *that* state leaves a `승인` row and this one leaves nothing at all. Unattended, nobody answers and the night is spent.

Measured: a review stage completed and produced its report; the router recorded the cycle row and then asked the user whether to continue. No rule had refused, no approval was pending, no vocabulary error had occurred, and every value the next decision needed was in the snapshot it had just read.

**Where a decision is genuinely yours to make rather than to act on, the answer is the judgment grades below — not a question.** Grade 0 you take, grade 1 you take and record, grade 2 you escalate, and escalation means issuing an approval through the gate so the stop is a row rather than a silence.

**Every acting call carries `--snapshot-digest <H>`, copied from the snapshot just read.** This is the mechanical enforcement of conversational statelessness: a compacted router carrying a remembered digest is refused with exit 4 rather than acting on state that has moved. Re-read; never re-type from memory.

### The verbs

| Verb | What it does |
| --- | --- |
| `snapshot` | emit the whole input as one JSON object |
| `grade` | dry run — what are this argv's two grades? changes nothing |
| `plan` | dry run — would this act pass, and if not which rule refuses it |
| `act` | check, record, perform a pipeline act |
| `exec` | check, record, perform one bash line |
| `close` | resolve a pending approval from the harness-written transcript (`--void` records that it should not have been asked, `--reject` that it was asked and the answer is no) |

**Several `act` kinds take FIELDS after `--` rather than a command**, because what they perform is the ledger row itself. **Write them; they are not bookkeeping.** The merge rule reads a `cycle` row, and termination condition 1 counts `segment` rows — a run that never writes either cannot merge anything and cannot propose that it is done, and both failures look exactly like the mechanism working.

```
act --kind segment    -- 상태=<…> 워크트리=<path> 선행=<세그먼트 id CSV>|없음 '선언 파일 집합=<CSV>'
act --kind cycle      -- 사이클=<n> P0=<n> P1=<n> '리뷰 HEAD=<sha>'
act --kind problem    -- 동일성=<…> '현재 단=<n>' '생성 등급=<축2 토큰>'
act --kind judgment   -- 등급=1 '판단 부류=<열 값>' 기준=<…> '되돌리는 법=<명령>' 근거=<…>
act --kind clause     -- id=<절 id> 상태=<충족|불가능|보류> 근거=<…>
act --kind blocked    -- 스코프=run  원인=해소 사유=<선행 막힘의 사유> 근거=<…>
act --kind blocked    -- 스코프=cone 원인=막힘 사유=<…> 근거=<…> '앵커 세그먼트=<id>' ['의존 세그먼트=<CSV>']
act --kind obligation -- '의무 id=<RO-…>' 근거=<…>
```

**Write `선행` on the `segment` row at PLANNING time, not later.** It is the cone's declared axis, and it is the only axis that sees a dependency *before* the predecessor merges — segments branch from the resolved base rather than from each other, so ancestry only says "that one already landed", and the moment a cone typically stands up is before that. Two floors follow from that and both are refusals at write time: the field is **monotone** (a later row may add and may not remove), and **absence is not `없음`** (in a repository with two or more segments, a row without the field is refused; `없음` is accepted as a positive statement of independence). `선언 파일 집합` is likewise carried at planning time — it is the sole input to "did this segment touch a file outside its declaration", which git cannot answer at all.

**A cone is the one `blocked` scope you may create; run scope you may only resolve.** A cone holds what stands on a refuted premise and lets its siblings keep running, which is what an open question needs. Declare `의존 세그먼트` or leave it out — the gate derives the cone either way and refuses a declaration that is a **proper subset** (exit 6). Widening passes.

**Use `grade` and `plan` rather than finding out by doing.** They write no row and cost no budget. Without them the router has to learn by attempting, and that turns the progress-relative act budget into something that fires on grammar instead of on stagnation.

### Reading the exit codes

| Code | Meaning | What the router does |
| --- | --- | --- |
| 0 | performed | continue |
| 2 | vocabulary error | fix the argv — a token was outside a closed set |
| 3 | a rule refused | read which one; the refusal names the repair |
| 4 | stale snapshot digest | **re-read the snapshot** and reconsider; do not retry with the old one |
| 5 | approval issued | the act is outside pre-authorization — see below |
| 6 | declared grade ≠ graded | the self-declaration was wrong; do not re-declare to match |
| 7 | enforcement surface moved | stop and tell the user; a file the boundary rests on was edited |

**Exit 7 is the router's alone, and a stage that receives it can only stop.** The condition is outside a stage by definition — the surfaces are the run's settings, the rule catalog, the hook and the project settings — and it cannot even look at them, because looking needs the Bash that was just refused. It has no re-baseline available either: that would be the bound moving its own boundary. So the gate now tells a stage in as many words to stop rather than retry, and records a run-scope `blocked` row so the condition is visible as run state instead of as a stage's wasted turns. Measured before that: five stages, four of which retried into the same refusal 3, 9, 12 and 15 times and produced nothing. **The run does not recover — re-baselining is not offered.** Start a new run.

Past the checks, the act's own exit status passes through. A refusal always arrives with a `gate:` line and no output from the act — that, not the number, is what separates them.

### When an approval is pending

Exit 5 means the run has asked and cannot answer itself. **Ask the user in this terminal** — this session has `AskUserQuestion` and a headless stage does not, which is the whole reason the router lives here. Then call `gate.sh close --approval <id>`.

`close` reads the **harness-written transcript**, not the router's prose. A router that could type its own answer would be issuing approvals to itself and the record would be indistinguishable from one a person gave. If the transcript cannot be read, `close` refuses; that refusal is the mechanism working.

**`close` has three dispositions and they are not interchangeable.** Bare `close` records `승인` — asked and granted. `close --void` records `무효` — the question should not have been asked. `close --reject` records `거부` — it was asked, and the answer is no. All three need the same transcript line, and `--void` and `--reject` together are refused, because they are different claims about the same approval rather than two strengths of one claim.

**An approval the run should never have asked for is voided, not granted.** `gate.sh close --approval <id> --void` records `무효` and the act does not happen. It needs the same transcript line as an approval — voiding removes a blocker rather than adding one, so it gets no looser gate — and what it buys the person is a way to say *this should not have been asked* without granting the act to get the run moving again.

**A `절단점=판단` approval whose answer reads as "no" cannot be closed as `승인`.** The gate scans the extracted answer bytes for a negative — `아니오`, `아니요`, `거부`, `거절`, `하지 마`, `하지마`, `no`, `nope`, `reject`, `don't` — and refuses the grant, naming what matched and asking for `--reject` or `--void` instead. The scan does not run on act approvals: their `답변 문면` is a fixed literal, so there is nothing extracted to read, and their refusal is the closer naming a flag. `거부` is terminal the way `무효` is — resubmitting the same act against a rejected approval is refused rather than re-asked.

**While an approval is open, the stagnation boundaries are suspended.** A run waiting for a person is not a run that stopped moving, and without the suspension the boundary's own remedy would reset the counter that fired it.

### Judgment, not just acts

Not every decision is an act. For those, the question is **"may I choose this without asking?"** — the three grades of `_common/judgment-grade.md`. Grade 0 needs no record, grade 1 is adopted with a row carrying `등급`·`기준`·`되돌리는 법`·`판단 부류`, and grade 2 is escalated. **`팀 토론 진행` and `재설계` are never adopted as recommendations** — they are routing output, and whether to convene a team is the router's call rather than a stage's.

**You never choose to ask.** Submit your own recommendation with `act --kind judgment`; whether it becomes a question is the gate's decision. A grade-2 judgment is raised to a `절단점=판단` approval, and so is a grade-1 judgment that does not clear the auto-adoption floor. Both come back as exit 5, and the approval's id is derived from the judgment, so resubmitting the same one finds the open approval instead of opening a second.

**Once the answer arrives, resubmit the same judgment — that is the whole of the follow-up.** The approval's id is derived from the judgment, so the resubmission finds the closed approval rather than opening a new one, and the gate routes on its state: `승인` adopts the judgment and writes the row with `해소 승인=<id>`; `거부` and `무효` refuse the act and do **not** re-ask; `대기` is still waiting, so leave it and come back. **One answer opens one judgment** — an id already named by a `자율 승인` row is spent, and a second judgment leaning on it is refused with a request for a new question. Nothing here re-opens a closed approval: only a question whose `기준` and `근거` differ hashes to a new id.

**The floor is a union.** Either arm admits: the manifest declared this `판단 부류` in a `자동 채택` row, **or** `되돌리는 법` is a runnable command whose argv0 grades at or below `워크트리쓰기`. Prose fails the second arm — it grades `등급 미상` — and that is the point of the field: produce the thing that reverses the decision rather than assert that one exists.

**Two classes are outside the union entirely.** `팀-구성` and `시각-면제` hand risk to the user, so neither arm admits them: the floor rejects them before it looks at the manifest or at the undo command. What follows is an **approval**, not a refusal — recording a judgment of that class is permitted and only adopting it unattended is not. Declaring either in a `자동 채택` row is a hard stop when the manifest is frozen, and the runtime rejection is what makes the two agree instead of contradicting.

**What makes arm (a)'s input unforgeable** is three things, and it is worth knowing which: `## 인가` is exactly one section and the floor reads only that section; the `자동 채택` rows are inside `구속 다이제스트`, so appending one moves the digest and the next gate entry refuses; and the gate refuses any act that writes the manifest, at any cutpoint. The residual is that both sides of the digest comparison live in the same file, so a rewrite that moves the row **and** the digest field together is detected by nothing — which is why the write guard, not the digest, is the load-bearing half.

**A run may END with questions still open.** They do not count against termination condition 2, because a question's answer is an input to work that has not started and a successor run can consume it. What records them is the `done` file's third class, `종단 — 질의 잔여 N건 · 승인 <id>…`. A clause blocked on one is settled with `상태=보류` whose `근거` names that open approval id — which is a different disposition from `불가능`: impossible ends the clause, on hold hands it to the next run.

### Proposing that the run is done

`act --kind propose-done` carries the goal digest, the termination point decomposed into checkable clauses each with **evidence**, and the residual. **Evidence is a ledger reference or an observable artifact, never prose** — a proposal citing prose is the exact shape of "the check passes and the property fails", while one citing a merge commit is confirmed in the morning with one command.

The disagreement runs both ways, and only one direction is obvious:

- The gate can **refuse** a proposal, naming the unmet conditions. A re-proposal against the same unmet set is rejected at the parser.
- The gate can also **end** the run. When every condition holds and the router reaches for something else, it must name a specific admissible next obligation — an open obligation's identity, a non-terminal segment, or a clause marked unmet. Failing to name one, the run terminates as satisfied. Without this the gate could only block termination, never cause it, and the router alone would decide when the night ends.
- **A goal can be unreachable.** The router may propose done with a clause marked impossible and its evidence; the gate accepts that on a reduced condition set.

**A run the PERSON decided to end is that same path, and it is the only way to record their decision.** When the user says to stop short of the termination point, propose done with the unmet clauses marked impossible and the user's own utterance as the evidence for each. Do not reach for `problem` to record the stopping: that row **creates an open obligation**, which is condition 3's input, so writing it makes the run harder to end — the act of recording the stop would worsen the thing being recorded.

This matters because of what `done` is for. `런 상태` in the snapshot is derived from the run directory's `done` file and from nothing else, so a run nobody proposed done for renders `진행 중` forever — indistinguishable from one that died quietly, and the watcher never self-stops either, so it becomes a zombie of its own. Measured: a run whose stages had all terminated, with zero pending approvals, zero open obligations, an intact hash chain and one terminal segment — quiet and whole in every respect except that a person had decided to end it — went on rendering as in-flight because there was no row saying so. The decision existed only in a conversation, and a conversation is not on disk.

### Dispatching a stage

A stage is `act --kind skill`, and the gate launches it through the wrapper. Never assemble a CLI command line in the router: `"$CLI_BIN" "$@"` is an argv laundering tool for anyone holding an allow-list entry, and the wrapper's only legitimate caller is the gate.

**What goes after `--` is exactly this, and getting it wrong costs money without saying so:**

```
gate.sh act --manifest <매니페스트> --kind skill --target <alias> --segment <id> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> \
  -- <스테이지 종류> -p "/cc-cmds:<스킬>-unattended <인자…>"
```

**The first token after `--` is the STAGE KIND, and it is consumed before the CLI ever sees the rest.** `act --kind skill` calls the launcher as `<alias> <segment> <stage-kind> <cli args…>`, so a form that starts with `-p` hands `-p` over as the kind. The vocabulary check then falls back to `generic`, meaning the stage runs under settings that are not its own, and `-p` is gone from what reaches the wrapper. The kind is one of `audit`·`design`·`implement`·`review`·`reconverge`·`generic`, and it selects the settings variant rather than the skill.

An earlier version of this section omitted that token — so the text written to prevent a silent-green dispatch was itself instructing one.

Four parts, and each one has a measured failure:

- **`-p` is required.** The wrapper passes everything after `--` to the CLI, so without `-p` the prompt is never delivered. Omitting it while passing a bare skill name produced `산출물 없는 정지 rc=0 · 0.809852 USD` — the model woke with an **empty first user message**, read a file, asked "what should I do?", and terminated as a success. Omitting it while passing a quoted slash command instead fails loudly (`stage-wrapper: -- 뒤에 CLI 인자가 필요합니다`, `크래시 rc=2`), which is the better of the two.
- **The prompt is a slash command**, leading `/` included.
- **It must be the `-unattended` variant.** The plain `design-audit`, `implement` and `review` skills carry `disable-model-invocation: true`, so a headless stage naming them resolves nothing at all.

The first form is the dangerous one precisely because it is green: exit 0, cost charged, no output. Neither the gate nor the wrapper can catch it — a prompt is a string, and any string is a valid one.

**Dispatch it as a HARNESS-TRACKED background command, never with a bare `&`.** A stage call blocks for as long as the stage runs — the background ceiling alone allows an hour — and no foreground tool timeout reaches that. Detaching it with `&` and ending the turn produces a process nothing is waiting on: the stage finishes, writes its rows, and **nobody is told**. Measured: a stage completed normally at 08:58 with `종단 부류=정상 완료` in the ledger, and the run sat untouched until a person resumed the session ten hours later. Use the mechanism that re-invokes you on completion; that notification is the only thing that makes the next turn happen.

**This one cannot be checked for you, and that was measured rather than assumed.** The environment a harness-tracked background command sees and the environment a foreground one sees are byte-identical — zero differing lines — so the gate has nothing to test at dispatch time, and no exit code can be reserved for getting it wrong. It is the one requirement in this loop that is prose because it can only be prose; `--snapshot-digest` gets an exit code precisely because it is visible in the argv.

What catches the mistake is the watcher, on a **two-minute** clock rather than the twenty-minute stall clock: a stage's terminal row sitting as the last row in the ledger means the router has not acted since it finished. A router that was woken clears that in seconds. If you see that alarm in a report, this is what it is telling you.

**The stage's stream is at `<run-dir>/log/<segment>.json`**, and its stderr beside it. That is where a stage's own account of itself lives when you need it.

Three conditions must **all** hold before a segment is dispatchable, and reading only the first is how a router concludes it may go: **dependency** (no predecessor unfinished), **capacity** (concurrent model streams within the cap, taken from each skill's declared value rather than estimated), and **exclusion** (no live stage already holding an exclusive resource — the experiment-worktree prefix, which counts repo-wide, and one live stage per output document path).

### Resuming after a break

Five ways a run is cut, and all five resume: the terminal closes, Ctrl+C, the token limit, the network drops, a reboot. **Resume by resuming this session and saying so.** The router then does what it always does — read the snapshot and continue. There is no separate resume protocol, because the router holds no state that a snapshot does not.

A stage that was mid-flight when the session died is **re-attached, not re-run**: `--resume` continues its turn rather than restarting it. And a re-attached stage is not this shell's child, so `wait` would report a clean exit for a process it never reaped — liveness is `kill -0` on the recorded pid together with its start-time fingerprint, never `wait`.

---

## Act 3 — the morning report (`--report`)

Read the manifest, the run ledger and the report for the named run, then render in Korean. **Render only — this mode starts nothing and writes nothing.**

Cover, in this order:

- **결과 요약** — segments planned, merged, **완성-미착지**, parked; where the run stopped against its `종료 지점`. Keep 완성-미착지 separate from parked: those segments produced everything they were asked to and had exactly one terminal act blocked, and folding them into "parked" hides the difference between a night that worked and a night that did not.
- **자율 결정 전부** — every `자율 승인` row, grouped by `kind`, carrying the decision, the rejected alternative, and the rationale as recorded. **This is the whole point of the report.** The residual it compensates for — a stage that asked in prose, answered itself, and produced output anyway — is byte-indistinguishable from a correct run through every channel the design permits, so after-the-fact auditability is the only control left. Do not summarize these rows away.
- **보류 큐** — every `blocked` row with its `스코프`, `원인`, `사유`, and the re-invocation command line where one was recorded. Group by scope: an `act` park is one command away from finished, a `cone` park needs its premise repaired first, and a `run` park means the run could not judge a state. **Those command lines are inert**: the driver recorded them and never ran them, and neither does this step. They are for the user's hands.
- **사람 대조 필요** — every report line so marked. These are the ones where the run could not tell "still working" from "stuck", or where an apply's outcome is unknown. Name the preserved worktree path for each apply of unknown outcome; it is the only reproduction of that state.
- **스테이지 종단 부류** — per stage: 정상 완료 / 의도된 park / 산출물 없는 정지 / 공허한 성공 / 크래시 / 적용 불명. Call out every `공허한 성공` explicitly; it is a measured failure mode that used to be invisible, and the point of naming it is that it can now be counted. `산출물 없는 정지` was missing from this enumeration while the schema has carried it all along, and it is the value a stage lands on when it *correctly refused to decide for the user* — reporting it as one of the others is the same conflation the class was created to end. **A warning, because reading the gate's own source will contradict this line**: a comment there still says that value is not written on that path while the code beneath it writes it. The comment is wrong and is not repaired here.
- **비용** — the accumulated `cost` rows, and the cycle count against the run's cycle budget.

**State the report's own limit at the end.** It is authored by the run it describes, so it is powerless against a run that improvises **and also** omits that from its own report. The conjunction being rarer than either part is why this control is worth having — it is not a gate, and the real protection against an irreversible autonomous act remains the permission cutpoints the user set in 5b.

---

## Constraints

- **Never write the run ledger.** The driver is its sole writer. This skill writes the manifest, the grant and the report stub, and nothing else under `docs/pipeline-run/` after that stub.
- **Never edit a design document from this skill.** Writing one through `design` in Act 1 is a different act with a human in it; editing an existing one from here is not.
- **Never `arm` or `cancel` the notification helper from this skill** (CFI-4). The run's banners come from the two seats named there, and that helper stays an independent skill for use in conversation — what was removed is autopilot's dependency on it, not the helper. This is stated as a prohibition rather than as "do not infer the arming" on purpose: the older wording implied that a user utterance would make arming correct, and after this change there is no path here that arms it at all.
- **Never run a `재호출 명령`** recorded by a halted stage. It is recorded precisely because re-running it would retry a condition whose cause is still present.
- **The router's input is the snapshot** (CFI-3). Never act on a remembered decision, a remembered obligation, or a previous turn's plan.
- **Never assemble a stage command line in the router.** A stage is `act --kind skill`; the gate calls the wrapper.
- **Never stop the loop to ask.** Exit 5 is the only question in Act 2b; a stage finishing, a review returning findings, or an act failing are not questions. The stop leaves no row, so it cannot be told apart from a healthy run — see Act 2b.
- **Never answer a pending approval on the user's behalf.** `close` reads the transcript, and typing the answer defeats the only thing that makes the record auditable.
- **`--admin` is never authorized here**, whatever cutpoint the user picks.

Task: $ARGUMENTS
