---
name: autopilot
description: 목표 하나를 받아 이 세션이 라우터가 되어 스킬 호출을 스스로 정하며 완주시키는 파이프라인의 킥오프와 아침 보고
when_to_use: 사용자가 설계 문서·레포·PR·브랜치, 또는 아직 산출물이 없는 목표를 던져 두고 설계·감사·구현·리뷰·머지·적용까지 알아서 이어지게 하고 싶을 때 — 진행은 이 터미널로 중계되고 중요한 결정만 물어 온다. 또는 그렇게 돌린 런의 아침 보고를 받을 때
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

**Act 1 — a person is here.** Intent, entry judgment, target declaration and verification, the plan, the boundaries (cutpoints, deadline, ladder, banners), and — if the plan needs a design document that does not exist — the requirements interview and the design team's roster, then the plan's approval and the frozen interview record.

**Act 2 — the person may leave.** Freeze the manifest, start the watcher, and enter the router loop. Nobody has to stay, but the terminal keeps showing what happens, and an approval waits for them rather than guessing.

**What a design needs from a person is taken in Act 1 because of a tool, not because of taste.** `design` interviews through `AskUserQuestion`, and that tool is **absent from every headless process**. A design stage dispatched into the night cannot ask at all, so the two things only a person can give it — the answers to the requirements interview and the approval of the team that will discuss — are taken here and frozen before the person leaves. The design itself is then the run's first stage (`design-discuss-unattended`), and this conversation neither writes it nor waits for it. Anyone who reads this as a preference will eventually try to "just let it run" without the interview, so it is written here as what it is: a constraint on the design's inputs, not on where the document is written.

## Control-Flow Invariants

**CFI-1 — This skill is the only writer of the authorization record and the manifest.** The driver reads both and never writes either, by construction rather than by discipline. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Removing the write path removes the residual instead of mitigating it, and what remains is misbehaviour by this skill, which happens with a human watching. Never hand the driver a path, a helper, or a prompt that would let it write there.

**CFI-2 — One block per run, frozen at append.** Re-authorizing is a **new run with a new `<run-id>`**, never an edit to an existing block. There is no field with a mutable region and no close form. The manifest's `plan.md` is **creation-only**: it is frozen whole and has no append form at all.

**CFI-3 — The routing loop runs as a headless SHIFT, and this session is the run's SEAT.** Cost grows with the square of a session's length — every turn re-reads the whole history before it — so a routing loop that never restarts pays for the night twice over. The loop is therefore capped and handed to a successor `claude -p` shift instead of being run to exhaustion here. An interactive session cannot end itself and start a successor: the harness has no affordance for it, and the watcher refuses to on charter. Moving the loop out is the only shape available. What stays here is the seat where a person is — where a question is asked, where a banner belongs, and where a shift is started.

**Exception, in place — a DEFERRED run ends Act 2 without starting a shift.** The closing clause above says what stays here, and for a deferred run one of the three is not exercised: Act 2 freezes the manifest and the authorization record, writes their paths into the fleet backlog, and ends. Nothing is started here, and the first shift is started later by `fleet.sh dispatch` on the lane's own launchd job (Step 7, 「The deferred variant」). The exception is written **inside this invariant** rather than beside it because a reader who reaches "where a shift is started" and stops has already concluded the wrong thing; a deferred kickoff that starts no shift is conforming, not a leak. Everything else CFI-3 says holds unchanged — the loop is still a headless shift, this session is still the seat, and the seat still does not route.

**The number is kept deliberately even though the content changed**, on CFI-4's precedent: citations to it live outside this file, in pull request comments, issues and other agents' reports, and a renumbering would leave every one of them pointing at a real but unrelated invariant, which is indistinguishable from a correct citation.

**What is not lost is after-the-fact reconstruction.** Every routing act is a ledger row, and the morning report already reads from disk rather than from a scrollback.

**What IS lost is watching it happen** — the shift's turns no longer flow through this terminal. The progress channel buys part of that back: it projects the ledger's boundary events and state transitions into this session as messages, measured at roughly five an hour. And that observability was already incomplete before this shape, so the channel covers more than the hole it was cut for: a run with any live stage reports as running, and every arm that would report a stopped router requires zero live ones — so a stage that is itself wedged is visible on no channel at all today.

**Interruption is partly lost.** Ctrl+C no longer cuts the shift's current turn; the lead cancels the background task instead. Cancelling the shift does NOT take the channel down with it — a task stop reaches one task id and nothing else. But if you stopped the FEED yourself, re-arm it: that is the one death nothing reports.

What the router may NOT do is decide from memory. Its input is the snapshot and nothing else, save the digest value the gate emits from that same state — see Act 2b. A shift is a NEW process with no conversation history at all, so leaning on one would be leaning on something it does not have; and this seat is compacted repeatedly over a long run, so the same reliance here would have its input silently rewritten.

The morning report stays a **separate invocation** (`--report`), because a run that spans days is read from disk rather than from a scrollback.

**CFI-4 — Only a seat that was not spawned raises a banner.** The predicate is fixed; what shows that a seat was not spawned — its witness — differs by the kind of seat, and a new seat is admitted by naming its witness together with the fact that the witness is a value the model cannot write, never by adding to a count. This run's banners come from two seats: the liveness watcher, which outlives the session and is orphaned to init (witness: process lineage), and the adjudication gate, a shell script the router calls (witness: `cc_caller_is_router`, which tells the router from a stage). An ordinary session's hook seats raise banners too, outside any run; their witness is the absence of `agent_id` in the hook payload, which tells the main thread from a subagent, and they take the gate's witness as well, so a stage session raises none. The three witnesses answer different questions, so none of them substitutes for another. The shared operating rules bar a *spawned agent* from deciding whether a banner reaches the user, and nothing that raises one here is spawned — that is the whole of why this run may raise banners at all. **The number is kept deliberately even though the content changed**: citations to it live outside this file, in pull request comments, issues and other agents' reports, and a renumbering would leave every one of them pointing at a real but unrelated invariant, which is indistinguishable from a correct citation. This skill arms nothing and cancels nothing.

**The count stays TWO under CFI-3's deferred exception, and that is a decision rather than an oversight.** A deferred run's first shift is started by `fleet.sh dispatch` from a launchd job, which is a third non-agent process and would look like a candidate for a third seat. It is not given one here. The two seats above both raise a banner into a terminal a person chose to leave open; a lane dispatcher wakes on a timer with nobody in front of it, so "raise a banner" there means something this invariant has never had to define. Whether a host-resident sensor may raise one at all is an **open residual**, and leaving it open costs a deferred run nothing: everything it needs to report, it reports through the ledger, the run report and the progress channel the seat re-arms. Do not read the deferred variant as widening this invariant.

**CFI-5 — The interview takes ONE cutpoint per target, not seven toggles.** See Act 1 Step 5. A per-act toggle matrix invites a grant that is incoherent under composition (push without commit), and it does not match how the user's own standing rules describe delegation. Per-target rather than per-run because a run may span repositories with different appetites — "infrastructure applies, the front end stops at a pull request" is not expressible as one scalar.

**CFI-6 — Act 2 starts only when Act 1 has nothing left to ask.** Every entry in the judgment's `unresolved` is answered, every target is confirmed by the user, and the plan is approved, before a single byte of the manifest is written. A question carried across the seam is a question nobody will answer.

**The seam is a boundary in the other direction too: when Act 1 has nothing left to ask, it does not stop.** There is no waiting for a document to be written somewhere else. Once the plan is approved and the interview record is frozen, Act 2 starts in the same turn. A kickoff that halts with no question pending is the same leak seen from the other side — the person leaves believing the run started, and nothing on disk says it did not.

**CFI-7 — A channel event is not a turn to route in.** Under CFI-3's shape the run is routed by a `claude -p` shift that holds the run's only routing seat; what remains here is the seat where a person is. The progress channel wakes this session even when its turn has ended — measured: an idle lead with no user input took a turn 94 seconds after arming, on the event alone, with the emitting process still running — and it wakes it roughly once every ten minutes all night. **On a wake caused by a channel event, relay the line and stop.** Do not call the gate, do not read the snapshot, do not dispatch a stage, do not launch or close a shift, do not answer an approval, do not decide anything.

**Read the envelope before acting. Every arrival carries a `<task-id>`, so the task id alone settles nothing — and which id is which is recall, which a compaction erases.** What separates them is whether `<summary>` carries the channel's own `description` (`autopilot <run-id>`), whether `<status>` is present, and what the body says. With **no `<status>`** and a body the feed could have written: **relay it, and that is the whole of the turn.** With no `<status>` and a body of `[Monitor timed out — re-arm if needed.]`: the channel is dead — **re-arm it, relay nothing.** With no `<status>` and a body of `[N events suppressed]`: lines were lost and the channel is alive — relay nothing, re-arm nothing. **With a `<status>`** the task has ended: if `<summary>` is the channel's, the channel is dead — **re-arm it, relay nothing, and do not route**, because a dead channel is not progress; if `<summary>` is not the channel's, the shift has ended and **routing resumes** — this is the only notification that resumes it. The last thing that resumes routing is a message the human actually typed, and it is the only arrival you did not launch yourself.

A lead that routes on a channel event is a second router, and two routers disagree in the dark. That is why `watch.sh` resumes nothing, retries nothing and decides nothing, and why the shift is kept out of `session-lineage`.

**CFI-8 — The design is a stage of the run, and what only a person can give it is taken here.** The kickoff never hands a person a design command to run and never waits for one to come back. What an unattended design stage cannot ask for — the requirements interview and the team composition — is taken in Act 1 and frozen: the interview, verbatim, into the interview record (Step 5m), whose digest enters `구속 다이제스트` through a `사전 인가` row; the approved roster into the manifest's `설계 로스터` rows (Step 5k), which enter it directly. **Taking the roster here is a constraint, not a convenience.** `팀-구성` is a class the gate never adopts on its own, so a stage that composed its own team would stop on a person every time; a roster approved here is read by the stage, never chosen by it.

**And there is a receiving side.** The interview record is not written only to be archived: the design stage derives its path from the run id it already holds, opens it, takes the requirement from it, and re-takes its `sha256` to check against the `사전 인가` row before it spawns anyone. A handoff with a writer and no reader would halve this invariant — the person would answer the interview and the stage would still design from the task sentence alone.

**Numbered 8 because 7 is taken.** CFI-7 belongs to the progress channel, and on the precedent CFI-3 and CFI-4 state, an existing number is never moved to make room — citations to it live outside this file.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:

- `ToolSearch("select:AskUserQuestion")` — MUST load before Act 1
- `ToolSearch("select:Monitor")` — MUST load before Step 7. The progress channel is
  armed with it, and under CFI-3's shape that channel is the only thing a person sees
  while the night runs. Loaded here rather than at the call site because Step 7 is
  reached after the human has left.

**Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`** and apply its hard construction constraints to every call in this skill.

---

## Act 1 — with a person here

### Step 1: Read the contracts, then judge the entry

1. Parse `$ARGUMENTS`. `--report` selects the reporting mode — **if present, jump to Act 3.** Everything else is the intent, read whole.

    **The argument is an INTENT, never a question to answer.** A kickoff phrased as a question — "이거 개선이 가능할까?" — is still a kickoff, and there is no branch in this skill that reads it as conversation and ends there. Measured: one arrived that way and the lead investigated the code, interviewed with the question tool, wrote a design document alone, and stopped — no entry judgment, no target verification, no plan approval, no interview, no manifest, no grant, no watcher, no router loop. **The run did not exist**, and the deviation surfaced only because the user asked why the procedure had not run. If the intent is a question, answer it *by performing Act 1* — the interview is where the question gets asked back properly.
2. **Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1` and `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` from its first line up to, not including, the numbered heading `## 3. `** (the preamble, `## 1.`, `## 2.` and the whole of `## 2b.` — `## 2b` is the manifest contract this skill authors: the template, `check_manifest`, identity, compatibility and the interview record). The boundary is the numbered heading because the templates in `## 2b.1` and `## 2b.5` carry unnumbered H2 lines such as `## 인가` inside their fences, so "up to the next `## `" stops in the middle of a template. The rest of that file, from `## 3. ` on, is read at Step 7.
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

**Visual-fidelity marker.** If there is a design document, search it for a `## 시각 정합 기준` section. A document the design stage has yet to write has nothing to search, so a `design_required` run skips this check; if the frozen document turns out to carry the section, the implementing stage halts on it rather than implementing that segment.

If it is present, tell the user plainly and get a decision. The reason this belongs *here* rather than at runtime is that it is the only moment a human can answer it: that gate's cap clause forbids both auto-abandon and auto-advance, and those are the only two moves an unattended executor has, so the gate is unattended-ineligible by construction. **Ignoring the marker is explicitly rejected** — the gate writes zero bytes, so skipping it leaves no trace at all and work the user asked to be visually verified merges without it.

Ask with `AskUserQuestion` (header chip `시각 정합`):

- label `"그 세그먼트만 park (권장)"` — description: 마커가 걸린 화면을 구현하는 세그먼트는 보류 큐로 보내고 나머지는 계속 돕니다. 아침에 그 세그먼트만 직접 확인하시면 됩니다.
- label `"이 런에서 제외"` — description: 마커가 가리키는 작업을 이번 자율 실행의 범위에서 아예 뺍니다.
- label `"자율 실행 취소"` — description: 시각 검증이 이 작업의 핵심이라면 무인 실행 자체가 맞지 않습니다.

Record the answer in the manifest's `시각 정합 마커` field.

**Residual verification items — and the access they need, TAKEN not just announced.** **This applies only when the design document already exists.** When `design_required` is true there is no document at this point, so there are no items to count and no recipe to read a requirement from. Say so in one line — 「이 런에서는 무엇이 런을 멈출지 떠나시기 전에 알려 드릴 수 없습니다 — 설계 스테이지가 동결 직전에 잔여 항목마다 사다리를 스스로 내려가고, 거기서 풀리지 않은 것만 승인으로 올라옵니다.」 — and move on; the stage walks that ladder when the items first exist, which is at its own freeze. With a document in hand, count the `### R<n>` entries under `## 구현 시 검증 항목` whose grade is the save-time residual token. Tell the user how many there are and which will run unattended: an external probe, a worktree recipe, or an execution-caution item **cannot** get consent overnight, so a pre-implementation one of those will stop the run.

Then — for each item that would stop it — **read what that item's own recipe says it needs, and ask the user for it here.** Every residual item already writes down its requirement; nothing in Act 1 used to collect it, so the person was told "this will stop the run" and then allowed to leave without being asked the one thing that would prevent it. Take the credential, the profile name, the tunnel, the endpoint — whatever the recipe names — verbatim, and record it against that `R<n>`. Where the answer is "that item does not need to run", record that too: it is the cheapest possible resolution and it is invisible to every later stage.

This is the difference the measurement showed. A run stopped at 04:32 on three pre-implementation items. In the morning: one needed a secret this machine's profiles already reached, one needed a database this machine already had a key for — both settled in minutes, both passing — and the third turned out not to be exercisable at all, its premise already refuted elsewhere in the same document. Two answers and one deletion, none of them longer than a sentence, and a whole night spent to discover that a stage had to succeed and be billed first.

**Announce the residual items even when none of them blocks** — that part is a notice and goes into the report either way. The questions above are only for the ones that would stop the run.

**Stage policy drift.** Every unattended stage and every router shift is launched with automatic CLAUDE.md discovery switched off and a file the gate synthesizes in its place: the English stage policy (`<plugin root>/orchestrator/stage-policy.md`) followed by the target repository's instruction chain. The policy was distilled from the user-scope `CLAUDE.md` and the workspace instruction file, which a person edits by hand, so run `bash <plugin root>/orchestrator/stage-policy-drift.sh` here and show the user its last line — `match`, `mismatch <n>` (with the `added`/`removed`/`changed`/`non-unique` lines above it), or `skipped` — together with whether the host map `~/.config/cc-cmds/stage-policy-sources` exists (without it nothing is excluded from the chain and the `workspace` rows cannot be compared). This is a notice, not a stop: a drifted source means the policy is due for an update in this repository, and tonight's stages still run on the policy as shipped.

**Cross-repository stacking.** If more than one target was confirmed, say this out loud: **segments in different repositories cannot stack on each other's commits.** A dependency between them buys ordering and nothing more, because there is no commit in repository B that contains repository A's merge. It is the most likely place a first multi-repo run diverges from what the user pictured, and it costs one sentence here.

### Step 4: The plan, and what a design stage needs from a person

Present the judgment's step graph as the plan, in Korean. Read out every `unresolved` entry and settle each one — CFI-6. **Do not take the approval here** — it is Step 5l, after the cutpoints, because the check the approval rests on reads them.

**If `design_required` is true, this conversation does not hand the person a design command and does not wait for one.** The document is written by the run's first stage, `design-discuss-unattended`, which the router dispatches onto the absent document (Act 2b, 「Dispatching the design stage」) and which freezes it before anything reads it. What this kickoff owes that stage are the two inputs it cannot ask for — Step 5j's requirements interview and, for a team tier, Step 5k's roster — and CFI-8 is why they are taken here.

**`design` still carries `disable-model-invocation`, and this skill still does not invoke it or reproduce its workflow by other means** — no roles stood up out of `Task` calls, no round structure re-derived from its reference files, no discussion run under another name. The one document this conversation writes is a `lead-solo` one, straight out of the interview it has just held, with the user in front of it and no team at all. That is the input the refusal exists to protect, not to withhold.

**The judgment's `design_tier` decides who writes the document.**

| `design_tier` | who writes the document | Korean line |
| --- | --- | --- |
| `lead-solo` | this conversation, after Step 5m — the graph carries no design stage | *"설계 문서는 이 대화에서 바로 쓰겠습니다 — 표면이 하나이고 계약 변경이 없어 팀을 띄우지 않습니다."* |
| `team-2` | the design stage, with the roster approved in Step 5k | *"설계는 런의 첫 스테이지가 무인 토론 팀으로 씁니다 — 팀 구성은 잠시 뒤에 확인받겠습니다."* |
| `team-4` | the design stage, with the roster approved in Step 5k | *"설계는 런의 첫 스테이지가 무인 토론 팀으로 씁니다 — 계약·스키마 변경이 걸려 있어 팀 구성을 잠시 뒤에 함께 살펴 주세요."* |

**A team tier's graph starts at the design stage.** The document is nobody's input until it is frozen, so the stage comes first and every later step, the audit included, depends on it. A `lead-solo` graph starts at the step after the design, because the document exists before Act 2 does — and neither dispatcher designs over a document that exists.

**What a `lead-solo` document owes, stated here because no skill is present to shape it.** The other two tiers inherit a document contract from the skill that wrote them; this one inherits nothing, so the contract is written out rather than assumed. (a) **Section floor** — `## 합의된 아키텍처`, `## 주요 결정사항과 근거`, `## 미해결 이슈 / 트레이드오프`, `## 권장 구현 순서`, in that order; length is unconstrained. (b) **Verification sections** — `## 검증 기록` and `## 구현 시 검증 항목` carry the **same schema as the team tiers** (`_common/verification.md`, the V-ledger and residual-item contracts, including the field-line rendering), each included only when it has content and each placed where that contract places it. A `lead-solo` document that settles claims inline still owes the V-ledger rows, because `implement` cannot tell which skill emitted a marker and reads them identically. (c) **Freeze and `sha256`** — no skill emits a freeze notice on this path, so the freeze *is* the moment this kickoff, having written the document after Step 5m, takes the saved path and records its whole-file `sha256`; nothing else marks it, and the document must not be edited after that record without a new one. (d) **`## 구현 슬라이싱`** — present only when Step 5j's delivery-shape answers exist. The tier is chosen for single-surface, single-repository work, so its usual absence is the same meaningful omission the section's own rule describes, and downstream grouping falls back to one segment, which is the answer the declaration would have given. (e) **No ledger block** — a `lead-solo` document has no roster, so it carries no `<!-- cc-design-ledger v3 … -->` block, and **that absence is the tier's definition rather than a defect.** Downstream must not read it as one: the fail-closed reads of a missing ledger belong to a team skill re-reading **its own** document mid-run, and none of them is a reader of a finished `lead-solo` document. (f) **Runtime classification default** — if a runtime point in the product being designed maps unstructured input to a closed set of outcomes, Read `${CLAUDE_SKILL_DIR}/../_common/runtime-classification.md` and apply it the same way `design` does. The `Category: UR` entry this default adds is one of the entries (g) resolves. (g) **Unresolved-issue resolution** — this tier has no `design`-style unresolved-issue walkthrough, so before (c)'s `sha256` record, put each `Category: UR` entry still at `상태: 대기` to the user in this same conversation, whether or not (f) fired: on acceptance write `상태: 해결` with a `사용자 acknowledged tradeoff: <framing>` body note, as `design` does; otherwise revise the decision, then record. Never carry one at `상태: 대기` into Act 2.

**The tier is a default the user may raise, never one this skill lowers.** When `design_required` is true and the judged tier is not `team-4`, ask once with `AskUserQuestion` (header chip `설계 티어`), offering the judged tier as the recommended option and only the tiers **above** it — never a lower one. The asymmetry is `prompts/triage.md`'s own: over-staffing spends tokens, under-staffing ships a contract change nobody modelled. Labels are `"lead-solo — 이 대화에서 직접 작성"`, `"team-2 — 무인 설계 스테이지(로스터 승인)"`, `"team-4 — 무인 설계 스테이지(로스터 승인)"`, whichever apply, each with a one-line description of what that tier buys. When the judged tier is `team-4` there is no higher tier and a single option is not a question, so do not ask — write the judged value and its rationale into the tier's Korean line. When `design_required` is false the judgment still carries a tier, and there is no question either.

**Changing the tier rewrites the step graph, and the rewrite happens before `## 실행 계획` is frozen.** Here the tier is not a command string — it decides the graph's **shape**, so a tier that moves while the graph stays put freezes a manifest that contradicts itself. Raising `lead-solo` to a team tier: insert a first step with `skill` `design` and add that step's id to the `depends_on` of every other step. **The inserted step is a full `steps[]` entry, not a marker** — an object carrying `id`, `skill`, `summary` and an empty `depends_on`, which is exactly the four fields `prompts/entry-plan.schema.json` requires of a step and the only four it allows. **The `id` is not a label on a design step, it is what makes the step findable at all:** the gate keys the stage's run-directory files on that field and both routers grep the ledger for its value, so a step written without one does not read downstream as a design step with a blank name — it reads as no design step, and every step depending on it waits overnight on a dispatch that never comes. Lowering a team tier to `lead-solo`: remove that step and strike its id from every `depends_on`. `team-2` ↔ `team-4` changes who staffs the discussion, not the shape, and leaves the graph alone. Raising is the only direction this conversation offers, so it is the branch usually taken; the lowering rule is here because a judged tier may still be corrected before the freeze, and a graph left carrying a design step nobody will dispatch stalls at its first dependency.

**Present what each step will actually DO, not just its name.** A one-line-per-step graph reads far shallower than the work is: a `design` step is an unattended discussion team followed by a walkthrough whose dispositions the stage takes and records, a coherence pass, the residual-item ladder and the freeze; a `review` step is a multi-round agent team with a reconciliation pass, an `implement` step is two processes split across a plan-emission gate. Approving "S1 review" is not the same as approving that. One clause per step is enough — the point is that the person refusing has seen the shape.

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

**Then, for each target whose cutpoint is `머지` or above, take that target's `리뷰 정책 상한`.** This is the tail of 5b and not a new step — it is asked about the same target, immediately after that target's cutpoint, and only when the answer put the target at `머지` or higher. A target that cannot merge has nothing for this value to bound.

**Do not take the default silently.** Present it as a choice being confirmed rather than a question being skipped, because this is the last moment it can be set at all. Three things the wording must say:

- **It is a CEILING and not a default.** Each slice declares its own review policy at or below this value; raising the ceiling does not mean any slice will use it, and lowering it refuses slices that declare looser.
- **What `선머지후리뷰` actually buys and costs.** The first merge of a segment passes and leaves one obligation behind; while that obligation is unfulfilled the **second** merge of that segment is refused, and the run cannot terminate.
- **It can only be set here.** Once the manifest is frozen, editing this field moves both digests and the next gate entry is a hard stop — there is no amendment form.

**When this run declares `적용 주체=파이프라인`, drop `리뷰없음` from the offered options** and say why in one clause: the apply would then be held by a rule the manifest cannot turn off, so it could never be performed and the run could not end. **Removing it here is shaping the question, not enforcing the answer** — the enforcement is the manifest check, which hard-stops on that combination however the manifest came to carry it.

**5b (second tail) — the two identifier questions, asked per target and asked unconditionally.** A run with a low cutpoint can still run `terraform` against dev, so there is no cutpoint below which these stop mattering.

**Say this once, before asking** — it is the whole of what the reach axis does, and it is the only moment a person hears it:

- Local reads have nothing to declare; a read through a remote-capable tool must declare where it lands, and prod personal data, heavy queries and billed queries are **recorded rather than refused**.
- Local execution and collaboration — issues, comments, labels, projects, and a push that is not a deploy branch — proceed on their own. **Destructive dev acts, prod writes and deploy triggers park unless a `사전 인가` row names them**, and only that act parks: the run keeps going.
- A write run through a shell, an interpreter or a build tool is capped at read and run-local. To let one reach dev or prod, the manifest must name that form **down to the script operand** — `npm run` and `make` alone open nothing.
- Declare `dev 식별자` and a `dev` claim is checked against argv; a mismatch or nothing to compare against parks. Declare none and the claim is believed and recorded.
- A destructive prod act needs the authorization row to carry the destructive word itself — `aws rds` authorizes the queries, not `aws rds delete-db-instance`. A destructive word that sits AFTER the operands (`aws s3 sync ./d s3://b --delete`, a `+main` refspec) can only be authorized by spelling the whole argv in `형태`.
- A spelling whose global flag comes first — `aws --profile x ssm …` — does not match an authorization row and parks.
- A push needs the target's cutpoint at `push` or above, and a push to the base branch is judged as a merge.
- A CLAUDE.md slot apply proceeds only when a review record covers it; every other slot write parks.
- **Once frozen none of this can be edited**, and the switch that decides park-versus-approval cannot be changed mid-run.

**Then ask, per target, in ONE `AskUserQuestion` call with two questions** (headers `dev 식별자` and `배포 트리거`): whether this target has dev identifiers, and whether it has deploy triggers. On a yes, take the `<종류>:<값>` elements as free text — kinds `aws-profile` · `aws-account` · `kube-context` · `host` · `domain` · `dir` for the first, `branch` · `workflow` · `jenkins-job` · `argv` for the second — and **read them back before freezing**. The manifest check hard-stops on a malformed element at the next gate entry, which is after the person has gone; the read-back here is the only correction opportunity there is.

**5c — Apply, if any target's cutpoint is `배포`.** Take the apply command verbatim, the read-only probe that decides whether an apply is needed, the actor (`파이프라인` or `사람`), and — when the actor is the pipeline — the blast radius that parks if the apply's outcome cannot be judged. The default radius is the repository and it may only be **narrowed**. State plainly that the driver executes an apply itself, with zero retries, and that an outcome it cannot judge stops the declared radius and preserves the worktree for the morning.

**5d — Terminal-act cap, per target.** Default is `없음`, and say why the question is being asked at all: at this moment nobody knows how many merges the cutpoint authorizes, because segmentation happens later and a re-design can re-split it. Offer `없음` (recommended) or an integer. A number latches against the measured segment count and routes the excess to the blocked queue.

**5e — Wall-clock deadline.** An absolute ISO8601 timestamp, and it is **required** — `없음` is refused by the driver's own manifest check. It is a dispatch gate and never a kill signal: a stage in flight runs to completion and is classified normally, and no merge happens after it. Offer a default of the next morning and let the user move it.

The deadline rests on the same assumption 5a just qualified: the user picks a time believing the implementation happens overnight. If an audit stands first in the graph, what exists at that hour may be the audit's output and nothing else. Say so while they choose the time, not afterwards.

**Say which bound will actually end this run, because it may not be this one.** The clock measures elapsed time and the thing worth stopping is pointless spinning; measured, it has ended runs through no fault of theirs — a machine asleep for 35 hours, an external queue holding one for most of 262 minutes, and one that died having performed zero acts. So the clock is now the bound for a run that declares no cost ceiling, and **5f below is where a run gets one**. A user who answers both should hear, in one line, that the ceiling is what will stop the night and the timestamp is the outer edge.

**5f — Cost ceiling.** A plain number in USD — **no currency symbol and no unit**, because the boundary's arithmetic reads digits and a value it cannot read is not a ceiling. `없음` is allowed and means this axis is unbounded.

Say both thresholds out loud, because they do different things and only one of them involves the user: at **80%** the run opens a boundary approval and waits for a person; at **100%** it **ends the run** without asking. The second one is not a harsher version of the first — an approval nobody answers is not a bound at all, and the state this whole design targets is the one where nobody is awake to be asked.

Offer a number the user can reason about. The runs this pipeline has actually billed sit in the tens of dollars per review cycle, so a ceiling is a decision about how many cycles a night may spend, not a round number picked for comfort.

**5g — Stagnation bound.** An integer, or `없음`. It counts consecutive router judgments over an unmoved progress digest, and when the count reaches it the run **ends**.

Say why the question is separate from the boundary that already watches this. A boundary at this axis fires at a fixed threshold and **asks**, and the approval it opens suppresses that boundary while it waits — so unattended, the counter freezes at the value that opened the question and the run spins against a bound that can no longer advance. This one is the disposition nobody has to be awake for, and it is why the axis gets a number the user chooses rather than one the code fixes.

Offer `없음` only alongside the ceiling: a run that declares neither progress-axis bound falls back to the wall clock, which is what 5e just said is the weaker yardstick.

**5h — Ladder rungs.** `4` (the full ladder: local fix, scoped re-convergence, root re-design, human) or `2` (stop after the scoped re-convergence). Say what `2` buys — a run that never re-designs on its own — and what it costs: more parks in the morning.

**5i — The banner kill switch, announced rather than asked.** There is no question here any more: the run's seats named in CFI-4 raise a banner whenever the run cannot pass a point without a person, and that is on by default. What this step owes the user is the **resolved state, said out loud** — because the value can only be chosen before the run starts, and this is the last moment anyone can notice that what they meant to set and what is actually in force are different things.

Say all three of these:

- 「이 런의 배너를 전부 끄시려면 런을 시작하기 전에 `CC_CMDS_AUTOPILOT_NOTIFY=0` 을 걸어 주세요 — `off`·`false`·`no` 도 대소문자 구분 없이 같게 읽습니다.」
- 「런 도중에는 끌 수 없습니다. 감시자는 기동할 때 환경을 물려받고 다시 읽지 않고, 게이트는 호출마다 별개의 프로세스라 앞 호출에서 건 값이 다음 호출에 남지 않습니다 — 지금이 정하는 자리입니다.」
- 「이 배너들은 서로를 밀어내지 않고 쌓입니다. 런이 도는 동안 통틀어 여덟 건까지 하나씩 따로 남고, 그 뒤로는 나머지가 한 자리에 모여 개수로만 표시됩니다 — 여덟은 한 화면에 동시에 뜨는 수가 아니라 이 런 전체가 쓸 수 있는 자리 수이고, 한 번 그 자리를 넘어간 항목은 앞의 배너에 답해 자리가 비어도 다시 개별 배너로 올라오지 않습니다. 빠짐없는 목록은 아침 보고서에 있습니다.」

**Say what cannot be promised.** Before writing anything, state the two limits in one line each. First: 「이 채널이 파는 것은 「깨우기」가 아니라 「처음 보는 화면」입니다 — 돌아와서 보실 때 답을 기다리는 멈춤이 한눈에 들어오는 것. 개별 배너 자리는 런 전체에 걸쳐 여덟이고 그 뒤는 묶여서 보이며, 넘어간 항목은 자리가 비어도 되돌아오지 않습니다. 전수를 보장하는 것은 배너가 아니라 디스크의 보고서입니다.」 **Say the two halves of that separately**, because they are a measurement and an ordinary fact rather than one observation: this notifier has no permission to override a focus mode, and a focus or sleep schedule suppresses banners and sounds together. "No banner wakes a sleeping person" is the *sum* of those two, and someone who reads only the first will over- or under-trust the channel. Second: **a stage that improvises past a decision point is not detectable**, which is why the report enumerates every autonomous decision the run recorded, for you to audit in the morning.

**5j — The requirements interview, when `design_required` is true.** This is the interview `design` would have held, taken here because the stage that writes the document cannot hold one (CFI-8). Ask with `AskUserQuestion` until the requirement is settled — what the work must do, what it must leave unchanged, and what would count as done. **Keep every question and every answer verbatim.** The interview record's whole value is that it is not a summary: a paraphrase is this conversation's reading of the person, and the record exists so that their own words survive on disk after this session has been compacted. Take, alongside:

- **the five delivery-shape answers**, under the five field names the `design` brief uses — `**레포**`, `**슬라이스 수**`, `**적용 위치**`, `**적용 주체**`, `**실패 시 파킹**` — writing `없음` where one does not apply, because an omitted answer and a negative one are different facts;
- **the reproduction evidence** the person can point at — the steps and what was observed — or `없음`;
- **the verification preconditions** — what must be confirmed true before a design is worth writing — or `없음`;
- and, **only when the person offers one, a skeleton pre-judgment** — something they say the design must not change. Do not prompt a list out of them; an invented constraint binds the design as hard as a real one.

**5k — The design team's roster, when the tier is `team-2` or `team-4`.** Propose the rows of `### Default roster (driver dispatch)` in `design-discuss-unattended/SKILL.md`, **read from that file and quoted verbatim** — never retyped from memory — and let the person remove a row, add one, or change a row's scope or model. Read the approved rows back in their frozen spelling, one member per row,

```
- `설계 로스터` | 역할=<슬러그> | 범위=<한 줄, 탐색 범위> | 모델=<opus|sonnet|haiku>
```

and take the confirmation with `AskUserQuestion` (header chip `설계 팀`). Say in one line what a malformed row costs: the stage halts before it spawns anyone when a row lacks a field, names a model outside the three aliases, or repeats a `역할` — and that halt happens after the person has left. **Write the approved rows even when they equal the default.** A manifest with no row falls back to the same default, but only a row is inside `구속 다이제스트`, and only what the person approved here is authority for a class the gate never adopts on its own.

**5k also names the document, because nothing else in Act 1 does.** `## 요소`'s `설계 문서` is what the dispatch, all three of its guards and the audit resolve the document through, and the entry judgment is forbidden to supply it — a judgment that pre-empted the path would name a file nothing creates. So derive it here: fold the intent into a short kebab-case topic slug and take `docs/{topic-slug}.md`, relative to the home target's repository root, keeping the slug plain enough that the sidecar slug later folded out of it stays readable. Read the path back to the person in the same breath as the roster — one line, exactly as it will be written — and Step 6 writes it into `## 요소`. **On a `design_required` run this field may not be `(없음)`**: Step 6's self-check refuses such a manifest and the gate refuses the dispatch, so a design with no name stops the run here, in front of the person, rather than at three in the morning.

**5l — The plan's approval.** Taken here rather than in Step 4, because the first check below reads 5b's cutpoints.

**Before asking, check the graph against the cutpoints — the gate will.** Where any target's cutpoint reaches `머지`, two rules fire at the merge that the graph must already satisfy: a review record covering the branch's current HEAD with P0·P1 at zero, and a review session whose ancestry is disjoint from the implementation's. A graph that runs `implement` and then merges is **not executable**, and the schema accepts it, so nothing else catches this — the user approves a plan that cannot run and the mismatch surfaces at the merge, in the middle of the night. Add the review step, and say out loud that it is a separate stage rather than a phase of the implement one.

**When the graph carries a design stage, say in one clause what it does before asking** — the discussion team from 5k, a walkthrough whose dispositions the stage takes and records, a coherence pass, the residual-item ladder, and the freeze — and that nothing downstream reads the document until it is frozen.

**The approval utterance is captured verbatim.** It approves the STEP GRAPH, which is not the same thing as granting authority — that is what the rest of Step 5 took. Collapsing the two promotes plan approval into permission approval silently, so the manifest carries them as two separate fields.

**5m — Freeze the interview record, when 5j ran.** Assign `<run-id>` here rather than in Step 6 — the record's path carries it — and resolve `<base>` the way Step 6 does. Write `<base>/docs/pipeline-run/<run-id>.interview.md` **whole, once** — creation-only, no append form — in the shape of `pipeline-sidecar.md` `### 2b.5`, byte for byte. Then take its whole-file `sha256` (`shasum -a 256`); Step 6 writes the path and that value into the manifest. The record does not carry the roster — it refers to the manifest's `설계 로스터` rows. **Do not edit it after the hash is taken.** Nothing re-hashes the file at runtime, so an edit after that point is seen by no gate, and the manifest goes on vouching for bytes that are gone.

**A `lead-solo` document is written after 5m**, in this conversation, out of the interview it has just held, under the contract in Step 4 (「What a `lead-solo` document owes」). Take its path and whole-file `sha256`; that record is its freeze.

**5n — Immediate or deferred kickoff. This step is the criterion, and there is no other.** Ask with `AskUserQuestion` (header chip `기동 시점`) whether the run starts in this session or is frozen into the pace backlog for a lane's `fleet.sh dispatch` job to start later. Offer `즉시` (recommended) and `연기`, and say in one clause what `연기` costs: nothing is relayed into this terminal, and the authorization sitting in the backlog is spent by a job that runs while nobody is here.

**Nothing else in this pipeline carries this branch, so an answer taken anywhere else is invented.** The frontmatter has no deferral option, no environment variable selects it, the entry judgment does not produce it, and the manifest contract has no field for it — Step 7 reads this step's answer and only this step's answer. A deferred record's own fields say *when* the work was authorized and by when it must start; they do not say that deferral was chosen, because by then it already had been.

**A run that reaches Step 7 with no answer here is immediate — and that is a fallback, not a default this step may take instead of asking.** The rule at the head of Step 5 stands: ask. What this sentence covers is the run that skipped a mandatory step, and the disposition is asymmetric on purpose — `연기` freezes a grant that a job spends hours later with nobody present, so it is the branch that has to be chosen out loud, while `즉시` keeps the person who is sitting here in the loop. Read the answer back before Step 6: a run deferred by mistake does not start tonight, and a run started by mistake cannot be put back into the backlog.

**This step sits after 5m because it enters nothing 5m freezes.** The interview record, the manifest and the authorization record are byte-identical on both branches — which is exactly what lets the deferred path perform Step 6 unchanged and diverge only at Step 7.

---

## Act 2 — freeze, then start routing

### Step 6: Write the manifest and the authorization record

Assign `<run-id>` — or keep the one Step 5m assigned: a short, collision-free identifier for this run. It, not the document, is what every path below is derived from — which is what stops two runs of one document from aliasing onto one ledger, one report, one worktree path and one session id.

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
- `구속 다이제스트` — sha256 over the whole frozen set: the goal, the termination point decomposed into checkable `종료 절` rows, the target rows, the rule-catalog settings, the `사전 인가` rows, the `자동 채택` rows, the `설계 로스터` rows, the cost ceiling and the stagnation bound when declared, and the deadline. Both are kept rather than merged, so that a target-row edit is reported as a target-row edit instead of as "something in the frozen set moved".

**Two row kinds exist only when Step 5 took their input**, and both go under `## 인가`:

- when 5m ran, one `- \`사전 인가\` | 인터뷰 기록=<base 기준 경로> | sha256=<전체 해시>` row. It carries no `형태=`, so it authorizes no act — the pre-authorization rule skips a row without one — and what it buys is that the record's hash is inside the frozen set;
- when 5k ran, the approved `설계 로스터` rows, one per member, in the order the person approved them.

**When the graph carries a design stage, the document does not exist yet, and the manifest says so rather than inventing a value.** `## 요소` → `설계 문서` is the path the stage will write — the one named in 5k, which is where the router dispatches the stage and what the audit later reads — and `설계 문서 전체 sha256` — here and in the authorization record — is `(해당 없음)`. The document's hash at each stage's end is recorded by the gate as it lands, not frozen here.

**Check the manifest against the tier before writing it, because after this nobody is here to ask.** Three refusals, each sending you back rather than freezing a plan that cannot run:

- `design_required` is true and `설계 문서` is empty or `(없음)` → back to 5k, name the document. The gate refuses that dispatch too — but it refuses it at three in the morning, with the graph already stalled behind it.
- `design_required` is true, the tier is `team-2` or `team-4`, and `## 실행 계획` carries no step that is an object with `skill` `design` **and a non-empty `id`** → back to Step 4, insert or complete the step and add its id to every other step's `depends_on`. **Existence is not the predicate, because the shape that gets through today is a step that is present and carries no `id`** — the gate keys the stage on that field, so a step missing it resolves downstream to no design step at all, and "insert the step" on its own says nothing about one already sitting there.
- the tier is `lead-solo` and `## 실행 계획` carries such a step → back to Step 4, remove it and strike its id from every `depends_on`.

The gate already refuses the exemption unless the frozen plan requires a design and names **exactly one** `design` step, so a graph that disagrees with its tier does fail loudly overnight. What checking here buys is not detection, it is **who is present**: the person who chose the tier can settle it in one turn.

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

**Decide first whether this kickoff is deferred, and decide it from Step 5n's answer alone.** 5n is where that branch is chosen and the only place it is chosen — there is no flag, no environment variable and no manifest field carrying it — so a decision made here on any other ground is made on nothing. A run that reached Step 7 without a 5n answer is immediate, which is 5n's own fallback and not a guess improvised at this line. A deferred kickoff goes straight to item 7 and performs none of items 1 through 6 below — in particular it arms no progress channel (item 4) and starts no shift (item 6). The list is read in order, and item 6 ends in "do not stop here", so the branch is taken here, before item 1, rather than discovered after the shift has already started.

**On the immediate path, read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` from `## 3. ` to the end before item 1.** Step 1 stopped short of that heading on purpose: from here on the ledger path, the watcher, the progress channel, the shift and the approval answers all use the contracts in that part — the ledger, the approval sidecar, the halt record, termination recognition and the volatile run directory — and nothing before this step does. The deferred path (item 7) does not read it. That path freezes the manifest and the authorization record, appends one backlog line and ends, so nothing on it uses those contracts, and reading them there would bring back the cost Step 1 removed.

1. **Create the morning-report stub** at `<base>/docs/pipeline-run/<run-id>.md` — an H1 and the run's identifying line. The stub exists so that a run which dies halfway still leaves a file where the user looks.
2. **Take the first snapshot, THEN start the watcher.** The run directory is created by the router's first gate call, and the watcher treats a missing directory as "the run went away" and exits — silently, with status 0. Started in the order this list used to give, it was gone before the run began: measured, watcher up at 03:18:0x and the directory created at 03:18:36, with the launching call reporting success. One `gate.sh snapshot --manifest <매니페스트>` first makes the directory exist; the watcher also waits out a short startup window now, but the ordering is what makes that window unnecessary.

   **That first `snapshot` also PINS the run to a version.** The gate copies its own plugin root to `<RUN_DIR>/plugin/cc-cmds`, records what it copied in `<RUN_DIR>/plugin-pin`, and from then on every gate call, watcher and feed for this run `exec`s into that copy — so a deploy, a `git pull` or a sibling run's apply cannot change the code enforcing a run that is already open. Write the watcher and feed launch lines with the installed path exactly as below: they hop by themselves, and the launch line here must stay **exactly one** occurrence for `scripts/lint-watch-threshold-pins.sh` to pass.
3. **Start the liveness watcher in the background**:
   ```
   bash <plugin root>/orchestrator/watch.sh --run-dir <RUN_DIR> --ledger <원장 경로> --stall 1200 --interval 60 --after-stage 120 --run-open 300 --stage-age 7200 > <RUN_DIR>/watch.log 2>&1 < /dev/null &
   ```
   It resumes nothing and decides nothing. Its whole job is to make one failure visible — **the router quietly stopping** — which is otherwise indistinguishable from a quiet terminal. It also emits a positive heartbeat, because a watcher that only speaks on failure cannot be told apart from a watcher that died.

   **It stops itself.** The gate writes a `done` file into the run directory when the run terminates, and the watcher exits on seeing it — or on the run directory going away. Nothing else reaps it: the gate ends a run without touching it and Act 3 is forbidden from starting or writing anything, so before this the loop outlived every run it watched. Measured on one machine: seven watchers from seven runs, the oldest a day and four hours.

   **There is no `--notify` flag any more, and passing one is now an invalid invocation.** Banners are governed by `CC_CMDS_AUTOPILOT_NOTIFY` and by nothing else. A second parsing site is what made the flag worth removing rather than defaulting: with it in place, a user who set the variable went on receiving every banner this process raises while believing they had switched them off. This is still one of the seats where raising a banner is allowed at all — a spawned agent may not, and a shell script that outlives the session is not an agent (CFI-4).

   **The heartbeat goes to a file, not only to stdout.** This is launched in the background with its **stdin closed and its stdout redirected** to a log file in the run directory — read the invocation above: `> <RUN_DIR>/watch.log 2>&1 < /dev/null`. Nothing is closed on the output side, and the reason the file is still needed is that nobody opens that log overnight, so a heartbeat printed there reaches nobody just the same. `watch.heartbeat` in the run directory is rewritten every pass, and its mtime is what makes the watcher's own liveness measurable.

   **`--stage-age 7200` measures a DIFFERENT SUBJECT from the other four, and that is why it is so much larger.** They time the router's silence; this one times how long a single stage has been alive, against the mtime of its start fingerprint. The pathology it names — a stage wedged while the router keeps working normally — is invisible to every other arm here and to every boundary in the gate, because a hung stage produces no acts and those boundaries count acts. Two hours comes from 27 real runs whose longest stage ran 70.6 minutes; a wider sample's duration distribution puts 12.9% of intervals over two hours, so this arm is **not** guaranteed to be quiet. That is accepted because of what it costs: this is the one arm that notifies and writes **no block row**, so a false positive is a line in the morning rather than a run that cannot end until a person writes a resolving row. The sibling arms measure the router's silence, which needs a person to break; this one measures a stage's, which resolves by itself when the stage ends.

   **All five thresholds are the script's own defaults and none of them is an attempt to change anything.** They are pinned here because the status line has to decide whether a heartbeat is fresh, and a threshold it cannot read from a contract is a threshold it invents. `--stall 1200` and `--interval 60` were spelled out for that reason and the two newer arms then went unwritten, which left the only configuration this run actually uses readable nowhere. `--after-stage 120` is how long a stage's terminal row may sit as the last row before the router is named, and it is also the idleness the run-open arm requires. `--run-open 300` is how long the run may be open with no segment. They are all deliberately NOT matched to the status line's own 180-second staleness mark: that mark is a render that clears itself on the next tick, while these arms write a ledger row that only a person's resolving row takes back. Two different costs deserve two different thresholds.

   **The redirection is new, and discoverability is its whole justification.** The harness keys a background task's output on an internal task id, which cannot be walked back to a run directory — so the watcher's loud line landed somewhere nobody could find from the one place a person actually looks in the morning, which is the run directory. `< /dev/null` goes with it so the process cannot be stopped waiting on a terminal that is no longer there.
4. **Arm the progress channel.** Under CFI-3's shape the routing turns do not flow through this terminal, so this is what a person sees while the night runs:
   ```
   Monitor(command: "bash <plugin root>/orchestrator/feed.sh --run-dir <RUN_DIR> --ledger <원장 경로>",
           persistent: true,
           description: "autopilot <run-id>")
   ```
   **`persistent: true` is not optional.** Without it the monitor carries a default timeout and dies partway through the night, and the death arrives as a bracketed harness marker rather than as a status — which is the shape CFI-7's envelope test exists to catch.

   **The `description` must be exactly `autopilot <run-id>`.** That string rides in the `<summary>` of every event this channel produces, and it is the ONLY thing that separates two runs emitting at once — a task id cannot do it, because every arrival carries one. CFI-7 keys on this string, so a different spelling makes the invariant undecidable rather than merely untidy.

   The channel emits nothing when nothing happens, so a quiet hour costs no notification and no model turn. It does not replace the morning report: it is a pure projection of the ledger and can say nothing the ledger does not, and if it is removed with a task stop it leaves no trace of having gone.
5. **Tell the user, in Korean, what is about to happen**: the run id, each target and its cutpoint, the termination point, and that the run's boundary events will be relayed into this terminal.
6. **Start the first shift. This seat does not route.** Act 2b is the shift's loop and never this session's: the routing seat leaves the lead at kickoff and comes back only as a return line, which is what CFI-3 and CFI-7 both say and what the shift numbering is built on — `교대=0` means routing never left this seat, and shift `n` stamps `n`. Issue the `act --kind router-shift` call of 「Shifting the loop」 with `사유=상한`, then wait for its return. Do not stop here, and do not route while it runs.
7. **The deferred variant — freeze here, dispatch later.** A kickoff may end Act 2 **without starting a shift**: freeze the manifest and the authorization record exactly as Step 6 does, append one backlog record naming their paths, and stop. The lane's own `fleet.sh dispatch` job starts the run later. This is the exception written into CFI-3, and it exists because what kept the fleet idle was never the scheduler — it was that there was no way to put work in.

   **None of Step 7's items 1 through 6 is performed on this path** — no report stub, no first `snapshot`, no liveness watcher, no progress channel and no shift. The run id already exists: Step 6 assigned it and the manifest carries it. What does not exist at freeze time is the **run directory** — the first gate call on the run creates it, and nothing on this path makes one — so there is nothing for the watcher or for the progress channel's `--run-dir` to point at. `fleet.sh dispatch` performs the three preparations in item 2's order — the stub, one `snapshot`, then the watcher — immediately before `run.sh --manifest`, and for the same measured reason; **but it does not perform them at the paths items 1 and 3 name.** It derives the report stub and the watcher's `--ledger` from the manifest's `origin-worktree` (`<origin-worktree>/docs/pipeline-run/<run-id>.md`), while `run.sh` derives the same ledger from that worktree's **git common dir** — the `<base>` rule of Step 6. When `origin-worktree` is the main worktree the two strings are one path and the deferred kickoff is equivalent to items 1 through 3. When it is a **linked worktree** they are not, and the split is the one Step 6 describes at `origin-worktree=`, arriving from the other side: the watcher measures a stub `run.sh` never writes, its stall arm has no gate-idle condition to hold it back, and after twenty minutes of an unchanging file it writes a run-scoped `blocked` row into the ledger the gate actually uses — a row that blocks the run's termination condition and repeats a "resume the router" banner, which the fixed graph `run.sh` drives has no session to resume. Until `fleet.sh` derives that path the way `run.sh` does, a deferred run is equivalent to the interactive one only from the main worktree. It arms no progress channel, so a deferred run relays nothing into this terminal. In place of item 5, tell the user, in Korean, that the run was deferred: the run id, the backlog record's `id`, and that nothing starts in this session and its boundary events will not be relayed here.

   **The backlog** is `<pace dir>/backlog.jsonl`, where `<pace dir>` is `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/pace`, and **this skill only ever APPENDS to it, holding the dispatcher's own lock.** The enqueuer — this path — adds records and never edits one; the dispatcher (`…fleet.dispatch.<lane>`) edits an existing record's state and never adds one. Those operations do not overlap, and that is **not** what makes them safe: the dispatcher edits by writing the whole file anew and renaming it over the old one, so a line appended after it read the file and before the rename is not in the new file and disappears with no trace. So the append takes `backlog.lock` in the same place and the same way the dispatcher does:

   1. `mkdir -p <pace dir>`, then `mkdir <pace dir>/backlog.lock` — **without `-p`**; the `mkdir` succeeding is taking the lock, and it failing means another writer holds it. On a failure, wait one second and try again, up to ten tries (the dispatcher's own wait). A lock directory whose mtime is more than sixty seconds old is a dead holder's: remove it and try again, as the dispatcher does. Still held after the ten tries → do not append without it; tell the user and try again, since a person is here.
   2. Write this process's pid into `<pace dir>/backlog.lock/pid`.
   3. Append the record as one line with `>>`.
   4. `rm -rf <pace dir>/backlog.lock` at once — only a lock this process took, and never held across anything but the append, because a dispatcher lane waits only ten seconds for it before ending its tick with nothing started.

   Do not go back and fix up a record you wrote earlier. A record whose premise has moved is **parked by the dispatcher**, which is the only writer entitled to say so.

   The record is one JSON object on one line and carries `schema: "cc-pace-backlog v1"`, `id`, `enqueued_at`, `authorized_at`, `deadline`, `base_commit`, `doc_sha256`, `manifest_path`, `lane` and `status: pending`; `park_reason` stays empty until a dispatcher parks it. **`schema` is required, with exactly that value** (`FLEET_BACKLOG_SCHEMA` in `fleet.sh`): the dispatcher picks its head only among records whose `schema` equals it and skips every other one — not parked, not modified, no ledger row — so a record without it waits as pending forever and no report ever counts it. **`deadline` is written, and it is not a priority.** Order is `enqueued_at` FIFO and a near deadline never overtakes — there is no preemption here, so allowing one to overtake starves the head. What a deadline does is park the record once it passes.

   **The three time fields have exactly one spelling, and the dispatcher accepts no other.** Write `enqueued_at`, `authorized_at` and `deadline` as `YYYY-MM-DDTHH:MM:SS` followed by `Z` or a `±HH:MM` offset (`±HHMM` is read too). The `T` separator and the zone are both **required**; fractional seconds are the only optional part and are dropped. `fleet_iso_epoch` in `fleet.sh` is the parser, and what it refuses is not exotic — a space separator (`2026-09-22 09:00:00`) and a zone-less local timestamp are both valid ISO 8601 and both rejected here. Take the value from `fleet.sh`'s own `fleet_iso` rather than composing one by hand where anything already holds an epoch.

   **A misspelled field costs the whole record, permanently.** An unparseable time is not a warning and not a retry: the dispatcher parks the record as `clock-incoherent`, and by the rule below a parked record is never re-planned — that night's work is gone and recovering it needs the user's authorization all over again. It also spends the same park token a genuinely skewed host clock spends, so the morning report cannot tell "this host's clock is wrong" from "this skill left the zone off", and the two are fixed in entirely different places. That indistinguishability is the second reason the spelling is written here instead of trusted.

   **Over 4 KiB, refuse at enqueue rather than park at dispatch.** The two failures are not equivalent even though both stop the record: a refusal lands here, where a person is sitting and can shorten it, and a park lands at three in the morning where nobody is.

   **A parked record is never re-planned.** Re-planning would need the user's authorization again and there is nobody to give it. The five park causes are a closed vocabulary the dispatcher writes — `base-moved`, `doc-changed`, `deadline-passed`, `clock-incoherent`, `manifest-missing` — so the morning report counts causes instead of reading prose.

   **Depth, as guidance and not as a gate:** a backlog shallower than about **8** does not carry the fleet through a night. Of the idle time that could be judged at all, **84%** had budget available and only 16% was a spent window — the fleet was idle for want of work, not for want of capacity, which is the whole reason this path exists.

---

## Act 2b — the router loop

The router decides **what happens next**. The gate decides **whether it may**. Those two jobs used to live in the same `case` arms of a shell driver, so neither could move without the other; splitting them is the point of this design, and this act is the half that judges.

### The loop, and its only input

```
snapshot  →  decide  →  gate call  →  (repeat)
```

1. **Read the snapshot.** `bash <plugin root>/orchestrator/gate.sh snapshot --manifest <매니페스트>` — one JSON object. Add `--render` for the human table when reporting to the terminal; that table carries the run's liveness — live stages, how long ago the ledger grew, the watcher's last heartbeat, and whether the run has terminated — so "is this still going?" is one command rather than a pid comparison. It also carries what is HOLDING the run: a `대기 승인` count that stays on the table at zero rather than vanishing, so "no approvals" and "no line" remain different readings, and a `미충족 조건` line naming the termination conditions by number and saying so when the only thing left is an invalidation. **This is the router's entire declared input, with one derived exception.** The emitted digest file is a value the gate wrote from the state this same snapshot describes — it carries no decision and no obligation, only the `H` a caller would otherwise re-read, so taking it is a shortcut through the round trip rather than a second source of truth. Everything that is not that number comes from the snapshot. Do not carry a decision across turns, do not remember an obligation the snapshot does not show, and do not treat a previous turn's plan as binding.
2. **Decide one next act.**
3. **Call the gate with that decision as argv.** The decision is not a document the router writes; **it is the argv**, and the gate's argument parser is the schema check. That is also what makes the router testable without a model in the loop: drive the verbs with bad argv against a fixture ledger and assert the exit code.
4. **Read the exit code and go back to 1.**

**The keys of that object are the contract, and the render table is not a substitute for them.** The router is told to read the JSON every turn and is judged on doing so, so a key that exists in the output and nowhere in this document is a key the router has no reason to trust or even to look for. Everything the object carries:

| Key | What it carries |
| --- | --- |
| `run_id`, `goal`, `goal_digest` | the run's identity and the frozen termination point |
| `targets[]` | `alias`, `slug`, `cutpoint`, `home` — one object per target |
| `obligations[]`, `obligations_total` | open obligations; the array is capped and the total is not, so compare them before concluding the list is whole |
| `pending_approvals[]`, `pending_approvals_total` | `id`, `blocks`, `cutpoint`, `disposition`, `question` — what the run is stopped on and what answering it releases. `disposition` is `-` until a person answers with free input, then `자유 입력` (or `슬롯 부재`): the approval is still open but has been answered and no disposition could be derived, which is not the same state as unanswered. Unlike `obligations[]` the array is not capped, so the total is the same count as a bare number; it is carried because the emitted digest file below carries it too, and one derivation is what keeps the two surfaces from disagreeing |
| `unmet_conditions[]` | the numbered termination conditions that do NOT hold, as rendered lines. **Capped**, and the lines that grow with the night take the front of it |
| `unmet_conditions_total` | how many there actually are. Greater than the array's length means the array lost its tail |
| `unmet_condition_numbers[]` | the same causes as condition numbers — deduplicated, ascending, at most ten, and never truncated. This is the one to read when the two above disagree |
| `disposition` | `충족`, `무효화` or `미충족` — what a `propose-done` would be recorded as right now. `무효화` means the run may record its end but only as invalid |
| `design_required` | `true`, `false` or `null` — the frozen plan's own value, never folded (`null` when the plan does not declare it). With `steps[]` it is how a shift learns the run has a design step to dispatch, which no `segments[]` entry can say |
| `steps[]` | `id`, `skill`, `depends_on` — the frozen plan's step graph, one object per step, without the prose summary. The design step is the one whose `skill` is `design`; a step the plan wrote as a bare skill string has a `null` id |
| `segments[]`, `segments_total` | `id`, `상태`, `워크트리`, `선행`, `커밋`, `마지막 스테이지` — one object per segment. A shift starts with no history, so this is where it learns the run has segments at all |
| `blocked[]` | `스코프`, `사유`, `앵커` — unresolved blocks only; a row whose cause is `해소` closes an earlier one and is not carried |
| `cycles[]` | `세그먼트`, `사이클`, `P0`, `P1`, `모드`, `리뷰 HEAD`, `리포트 경로` — the review results, capped. An empty `모드` reads as `전체` |
| `shift` | `n`, `context`, `soft`, `hard`, `over_soft`, `floor` — the session cap's state. `over_soft` true is the signal to end this shift |
| `handoff[]` | `교대`, `버린 선택지`, `막힌 지점`, `다음 후보` — the last three handoffs and no more. This is where a successor learns what its predecessor already tried and dropped |
| `orphan_stages[]` | segment ids whose dispatch record outlived both its process and its supervisor — a lost dispatch. Do nothing to them directly: the prelude of the next gate call on any verb but `plan` settles each one with a `stage-result` row of `종단 부류=외부 종료`, and a dispatch after that takes the next attempt number |
| `live_stages[]` | `세그먼트`, `스테이지`, `pid`, `감독`, `시작` — one object per stage that is actually running (pid alive and its start-time fingerprint matching). `마지막 스테이지` on `segments[]` names a stage that has ENDED, so this is the key that answers "is one running now": a segment here is waited on with `gate.sh wait`, never dispatched again. `pid` is the CLI — the process to stop if a person wants the stage stopped — and `감독` is its supervisor |
| `ledger_damage`, `chain_intact` | the ledger's integrity, as a count and as a boolean |
| `H` | the snapshot digest to copy into the next acting call's `--snapshot-digest`. An acting call that carried `--emit-digest` has already written this same value to that file, so reading the file is the ordinary way to obtain it and calling `snapshot` again is the fallback |

**THE LOOP DOES NOT STOP TO ASK.** The person was present exactly once, in Act 1, and everything the run may do without them was frozen there. Inside this loop there is **one** place a question belongs — exit 5, where the gate has issued an approval and the run genuinely cannot answer itself. Everywhere else the router decides, records the decision, and continues.

That includes the moments that feel like natural checkpoints: a stage just finished, a review came back with findings, the next step is large or expensive, the previous act failed. None of those is a question. **A router that asks at one of them stops the run**, and the stop is invisible — the ledger is well-formed, the last row is a normal one, nothing refused anything. It is not even distinguishable from a run waiting on an approval, because *that* state leaves a `승인` row and this one leaves nothing at all. Unattended, nobody answers and the night is spent.

Measured: a review stage completed and produced its report; the router recorded the cycle row and then asked the user whether to continue. No rule had refused, no approval was pending, no vocabulary error had occurred, and every value the next decision needed was in the snapshot it had just read.

**Where a decision is genuinely yours to make rather than to act on, the answer is the judgment grades below — not a question.** Grade 0 you take, grade 1 you take and record, grade 2 you escalate, and escalation means issuing an approval through the gate so the stop is a row rather than a silence.

**Every acting call carries `--snapshot-digest <H>`, and every acting call carries `--emit-digest` so the next one does not have to go looking for it.** The gate writes that file after its own last ledger row, so its `H` is the value the *next* acting call needs; read the file rather than calling `snapshot` again. Measured: without it every act cost two gate invocations, and the first of the two existed only to read back a number the previous invocation had already decided. **Fall back to `snapshot` wherever the emitted value is not yours to use** — the file is absent (the first acting call of a run, or an emission that failed), its `actor` is not you, it is stale by construction (anything happened after it was written, a dry run included), or the gate refused the flag with exit 2 as an unknown argument (the hook receives the gate as a runtime parameter, so the two copies can be different deployments). In that last case drop the flag and keep using `snapshot`. The list is open on purpose: a closed count went stale the first time a new case appeared, and the rule it was standing in for is one sentence. What does **not** change is the binding: the digest is still compared against live state, and it is still the one just observed rather than one held across a turn. This is the mechanical enforcement of conversational statelessness, and its scope is bounded rather than total: a remembered digest is refused with exit 4 **when the run has since made progress, or when the ledger has grown past the bounded ancestry window** — not merely because rows landed after it. A value a few rows old belongs to a concurrent writer and is admitted on purpose, because refusing it meant one actor's successful act invalidated every other actor's digest the instant it landed. A digest carried across a compaction is far outside that window in practice, so the enforcement still stands where it was aimed; it is no longer a guarantee about *any* remembered value. Re-read; never re-type from memory.

### Turn economy — what a routing turn costs, and the four rules that cut it

A shift's cost grows with the square of its length, so the cheapest thing a router can do is finish the same work in fewer responses. The waste is measured and it is not in what the calls do: across 504,653 responses **82.8%** carried exactly one tool call — **88.0%** at a lead seat and **83.2%** headless. The four rules below are the whole of the intervention; they are stated identically in `_common/agent-team-protocol.md` because a team seat spends turns the same way.

- **Issue independent calls in one response.** Two calls are independent when neither's arguments depend on the other's result. Split a response at a real dependency and nowhere else — not at a topic change, not to narrate between them, and not because a snapshot "feels stale" when nothing has happened since it was read.
- **Reuse one `--snapshot-digest` across up to three READ `exec` calls in the same response.** Of the 49,224 sequential `exec` pairs in the ledger history 73.6% are mediated by the digest alone and 84.8% have a snapshot immediately before them, so most of those round trips re-read a number that has not moved. **Three** is the bound because the ancestry window is eight rows (`GATE_ANCESTRY_WINDOW=8`) and the shared value has to stay inside it. The cap is on **reads only** — an acting call carries `--emit-digest` and the next one reads the emitted file, as the paragraph above requires. A digest that went stale is refused with exit 4 and costs one extra ledger row; that is the designed failure, not a reason to re-snapshot before every read.
- **Pass absolute paths; never prefix a command with `cd`.** `grep`, `sed`, `ls` and `python3` all take a path argument, so `cd X && …` buys nothing and costs a shell. It costs more than a shell here: the working directory is not part of the act's record, so the morning report holds a command a reader cannot re-run.
- **Never wrap a command in `bash -c` to batch it.** The gate grades an act by the basename of its argv0, so the wrapper launders the grade — a network act is recorded as a worktree write, and the 도달 audit of Act 3 reads a run that never left the machine. Batching means several calls in one response and never several commands inside one call.

**Narrow the snapshot with `--fields` rather than by reading less of it.** `snapshot --fields <selector>` is schema-driven and the selector owns the comma; the steady-state list is `H,disposition,unmet_conditions_total,pending_approvals_total,live_stages,shift,pace`. Use the full object whenever a decision needs a key outside that list — the point is to stop paying for the whole object on turns that only need the digest and the liveness, not to route on a narrower input than the decision requires.

### The verbs

| Verb | What it does |
| --- | --- |
| `snapshot` | emit the whole input as one JSON object |
| `grade` | dry run — what are this argv's two grades? changes nothing |
| `plan` | dry run — would this act pass, and if not which rule refuses it. Every read-only axis the same argv would meet as an `act` is evaluated, including the enforcement surface, the termination conditions, the segment-row existence check and the predecessor-landing check; the axes a dry run cannot reach are named on stderr rather than passed over silently |
| `act` | check, record, perform a pipeline act |
| `exec` | check, record, perform one bash line |
| `wait` | block until a dispatched stage terminates; writes no row, evaluates no boundary and takes no `--snapshot-digest`. Its exit status is the stage's own rc, or 11–14 below |
| `close` | resolve a pending approval from the harness-written transcript (`--void` records that it should not have been asked, `--reject` that it was asked and the answer is no — on a judgment approval a flag may only agree with the label the person chose) |
| `prompt` | the canonical question and the gate's menu for one pending approval, as JSON — what you carry verbatim into `AskUserQuestion`; changes nothing |

**Several `act` kinds take FIELDS after `--` rather than a command**, because what they perform is the ledger row itself. **Write them; they are not bookkeeping.** The merge rule reads a `cycle` row, and termination condition 1 counts `segment` rows — a run that never writes either cannot merge anything and cannot propose that it is done, and both failures look exactly like the mechanism working.

```
act --kind segment    -- 상태=<…> 워크트리=<path> 선행=<세그먼트 id CSV>|없음 '선언 파일 집합=<CSV>' ['리뷰 정책=<선리뷰후머지|선머지후리뷰|리뷰없음>']
act --kind cycle      -- 사이클=<n> P0=<n> P1=<n> '리뷰 HEAD=<sha>' '리포트 경로=<path>' ['모드=전체|델타'] ['기준 사이클=<n>']
act --kind problem    -- 동일성=<…> '현재 단=<n>' '생성 등급=<축2 토큰>'
act --kind judgment   -- 등급=1 '판단 부류=<열 값>' 기준=<…> '되돌리는 법=<명령>' 근거=<…>
act --kind clause     -- id=<절 id> 상태=<충족|불가능|보류> 근거=<…>
act --kind blocked    -- 스코프=run  원인=해소 사유=<선행 막힘의 사유> 근거=<…>
act --kind blocked    -- 스코프=cone 원인=막힘 사유=<…> 근거=<…> '앵커 세그먼트=<id>' ['의존 세그먼트=<CSV>']
act --kind obligation -- '의무 id=<RO-…>' 근거=<…>
act --kind obligation-done -- 동일성=<problem 행의 동일성> 근거=<원장에서 찾을 수 있는 객체를 지목>
act --kind obligation-drop -- 동일성=<problem 행의 동일성> 근거=<원장에서 찾을 수 있는 객체를 지목>
```

**`obligation` and the two `obligation-*` kinds are different series and are not interchangeable.** `obligation` fulfils a deferred REVIEW obligation and takes an `RO-` id. The other two dispose of an obligation a `problem` row opened, and they are what makes condition 3 satisfiable — before them the open set only grew.

**`종결` says the work was done; `포기` says this run will not do it.** They are checked at different times because they make claims in different tenses. `종결` cites a past act, and the past cannot be rewritten, so it is never revisited. `포기` requires the segment to be terminal, and segment state is reversible — so it is **re-verified every time the open set is computed**, and moving that segment back out of a terminal state re-opens the obligation. Do not use `포기` to make a number go down; it will come back.

**The rationale must name an object the gate can find in this ledger, and prose alone is refused (exit 2).** The recognised forms are a row anchor `A-<8 hex>` — the leading eight of the `prev=` every row already carries, so any row is addressable — an approval id `J-<8 hex>`, a review-obligation id `RO-<8 hex>`, or a segment id. Each resolves to the row that **declares** the object — the row whose own trailing `prev=` begins with the anchor, the approval's first `승인 id=` row, the review obligation's first `의무 id=` row, the segment's `segment` row — never to a later row that merely mentions it, so quoting an old id in a `근거` does not make it new. Two further floors: the object must sit **after** the problem row in the ledger (exit 3), which blocks closing a fresh obligation with something that predates it; and **one object closes one obligation** (exit 3), compared by the row the anchor resolves to rather than by its spelling. A closing act's own rows are rows like any other, so one close can supply the anchor for the next; that chain is not refused, and it is visible in `done-obligations`, where each closing row's anchor sits beside it.

**What the gate does NOT check is whether that act actually discharged the obligation.** It cannot, and it does not pretend to. That residual is carried to the morning by `<RUN_DIR>/done-obligations`, which names every disposed obligation with its disposition and its anchor — including the ones disposed by **exemption**, which write no row at all.

**Write `선행` on the `segment` row at PLANNING time, not later.** It is the cone's declared axis, and it is the only axis that sees a dependency *before* the predecessor merges — segments branch from the resolved base rather than from each other, so ancestry only says "that one already landed", and the moment a cone typically stands up is before that. Two floors follow from that and both are refusals at write time: the field is **monotone** (a later row may add and may not remove), and **absence is not `없음`** (in a repository with two or more segments, a row without the field is refused; `없음` is accepted as a positive statement of independence). `선언 파일 집합` is likewise carried at planning time — it is the sole input to "did this segment touch a file outside its declaration", which git cannot answer at all.

**Put `리뷰 정책` on the segment's FIRST row when the slice declared one.** The gate carries the value forward from row to row, and carrying forward can only propagate a value some first row actually wrote — a template that never writes one leaves every later resolution falling to the strict default, and the policy the slice declared reaches nothing. Omitting the field on a **later** row is inheritance and not a reset. A value exceeding that target's `리뷰 정책 상한` is refused with **exit 2** and is never quietly tightened to fit.

**`act --kind obligation` now has its `--target` compared against the obligation row's `대상`.** A mismatch is exit 2. The landing test runs in that target's anchor repository, so fulfilling against a different target would measure the right commit in the wrong repository and report a confident wrong answer; the repair is to call again naming the target the row points at.

**A cone is the one `blocked` scope you may create; run scope you may only resolve.** A cone holds what stands on a refuted premise and lets its siblings keep running, which is what an open question needs. Declare `의존 세그먼트` or leave it out — the gate derives the cone either way and refuses a declaration that is a **proper subset** (exit 6). Widening passes.

**Use `grade` and `plan` rather than finding out by doing.** Without them the router has to learn by attempting, and that turns the progress-relative act budget into something that fires on grammar instead of on stagnation. Neither verb performs the act, neither takes act budget, and neither writes the row the act would have written.

**They are NOT free of ledger writes, and the sentence that said so was wrong.** A common prelude runs ahead of the verb dispatch on every invocation regardless of which verb was asked for: the first call of a run appends a `run` row unconditionally, and later calls re-derive the authorization directory, overwrite the enforcement-surface baseline and append a `대상 추가` row. That re-derivation is not occasional — measured on one run's ledger it was 170 rows out of 804, 21 percent, alternating between exactly two values with a period of two. So a dry run does move the snapshot digest — but only its tip half, because the `run` and `대상 추가` rows are not components of the progress vector. The tip axis admits an ancestor inside a bounded window, so a router that reads a digest, asks `plan`, and then acts on the digest it read first is **not** refused, and **the forced re-read after a dry run is no longer needed** — that is the 21 percent, measured above, that stops costing a round trip. Re-read when the dry run sat among many other writers' rows, since the window is a few rows wide rather than a session long. Making the re-derivation conditional on the verb would still not change any of this: the `run` row is written from the other arm of the same branch and stays unconditional either way.

**And where that re-read is wanted it is a real `snapshot` call, not a file read.** `grade` and `plan` perform nothing and reach no acting path, so neither emits a digest however the flag is spelled — which is deliberate rather than an omission: emitting from a verb that answers a question would put a value in the file that no act of this run stands behind. So after a dry run there is no fresh emission to read, and the next acting call either calls `snapshot` or carries the value it held before the dry run, which the bounded ancestry admits.

### Reading the exit codes

| Code | Meaning | What the router does |
| --- | --- | --- |
| 0 | performed | continue |
| 1 | the gate itself failed | not a refusal — the gate did not reach a verdict. Read the message; a malformed argv reaches the shell before any check runs |
| 2 | vocabulary error, or an argv this gate does not accept | fix the argv — a token was outside a closed set, or a flag was spelled the way an older gate took it (`--emit-digest` takes no path) or used on a verb that performs nothing |
| 3 | a rule refused | read which one; the refusal names the repair |
| 4 | stale snapshot digest | **re-read the snapshot** and reconsider; do not retry with the old one. A bare append by another actor is not staleness and does not produce a 4 — what does is the run making progress, or the ledger growing past the bounded ancestry window, between the emission and the call. A 4 here is not evidence against the emission, it is the emission's designed failure mode |
| 5 | approval issued | the act is outside pre-authorization — see below |
| 6 | declared grade ≠ graded | the self-declaration was wrong; do not re-declare to match |
| 7 | enforcement surface moved | stop and tell the user; a file the boundary rests on was edited |
| 8 | the argv climbs a HIGHER rung than `--cutpoint` declared | **raise the declaration to the rung the message names and re-issue the same argv.** But raising it does not grant it: if the raised rung passes the target's own cutpoint the act is not authorized at all, and the prescription there is **park**, not another raise — that refusal comes back as 3 from `절단점-준수`, never as another 8 |
| 9 | *(empty slot)* | — |
| 10 | the merge cannot say what it merges, or the dispatch cannot say where it runs | **fix the segment row and call again with the same argv** — do not raise anything. If the same 10 comes back on the repair itself, or the row already says what the message asks for, the row is not the thing that can be repaired: **park the segment** and say which sentence refused. Do not retry a third time and do not lower `--cutpoint` to get past it |
| 11 | 도달 park — the act was not performed and nothing is waiting to be answered | an act-scope `blocked` row already names the cell in `도달 판정`. **Do not retry the same argv and do not re-declare its reach**; the verdict is keyed on the act digest and a second declaration takes the recorded one. Go to other work the run can still do; if that act was essential, the stage writes a halt record and ends |
| 127 | a launch precondition failed — the stage wrapper is missing, or the stage-instruction synthesis refused: a `.claude/rules/` directory or a fenced-outside `@import` line in the target's instruction chain, a missing `stage-policy.md`, a target row whose main worktree is empty or not a directory, or a malformed host-map line | deterministic — do not retry the same argv. The `warn` line names the host or repository state a person has to change; park the segment (the run, when the launch was a shift) |
| 11 from `wait` | no dispatch record for that segment — it was never dispatched | dispatch it if it is dispatchable |
| 12 from `wait` | the stage was an orphan and the prelude settled it as `외부 종료` — there is no rc to pass through | treat it as a stage that produced nothing observable; re-dispatch if the segment still needs the work |
| 13 from `wait` | `--timeout` elapsed with the stage still alive | the stage is still running; wait again or route other work, and never re-dispatch a live stage |
| 14 from `wait` | launch failure — `<seg>.attempt` was pinned but no supervisor ever wrote a `stage-result` row (the launch token was refused, or the dispatch died between the pin and the detach); `wait` removed the leftover `.sup`, `.sup.start` and `.launch` | re-dispatch; the next dispatch takes a fresh attempt number. 14 is kept apart from 11 because "never dispatched" and "dispatched and then died before a row" prescribe different next looks |

**11 is shared, and the verb tells the two apart.** The `wait` codes were chosen while the table ended at 10; 도달 park took 11 in the meantime, and 11 was kept as `wait`'s "never dispatched" when 14 was settled. The two cannot meet on one call: `wait` performs no act and so cannot park, and `act`/`exec` never report a missing dispatch. Read the code beside the verb you issued.

**9 is empty on purpose, and saying so is what keeps it empty.** A hole with no stated reason reads as a mistake and gets filled by the next person to add a code. 9 is held by an internal signal the gate uses to mean "this question already has an answer"; assigning it here would make one number both a sentinel and a contract code, falsifying the comments that defend the sentinel.

**Why 8 is neither 3 nor 6, and why the opposite mistake is free.** The gate derives a rung from the argv itself — `gh pr merge` is a merge, `terraform apply` is a deploy, `git commit` is a commit — and compares it against `--cutpoint`. A declaration BELOW the derived rung is refused, because that one word is read as a threshold by five separate consumers (the rule catalog, the target's ceiling, the wall-clock deadline, the undeclared-target layers, and the review-obligation issuer) and every one of them opens on the low side. It is not 3 because a rule refusal is switchable through `## 룰 설정` and this one stands above the catalog and survives every setting; it is not 6 because that code already carries two meanings whose repairs point in opposite directions. **Declaring HIGHER than the derived rung is never refused** — you label acts with the target's cutpoint, so `--cutpoint 배포 -- git commit` is the ordinary path. The gate simply judges it at the derived rung, says so on stderr, and the ledger row carries both `절단점` (what it was adjudicated as) and `유도 절단점` (what the argv said, `-` when the table has no row for it). Where the table has no row nothing is derived and the declared value stands, which is the old behaviour unchanged.

**Why 10 is neither 2 nor 3.** 2 tells the router to fix its argv — but here the argv is correct and the **ledger's segment row** is what is wrong, so a router obeying 2 retries the identical argv into the identical refusal forever. 3 says a rule refused — but this refusal is not in the catalog and it survives `**리뷰-후-머지**: 끔`, so reporting it as 3 would cancel, on the very surface the router reads, the property that turning the rule off does not turn this off. The same holds for a `--kind skill` dispatch whose segment row names a worktree that is not the target's — not absolute, not an existing directory, or in another repository: the stage would otherwise run in the target's own tree, so the gate refuses it with the same code. The prescription is to record or repair the segment row that names the worktree, then re-issue the same call.

**The row write itself is exempt from the ownership sentence, which is what makes that prescription reachable.** Every sentence of the anchor check reads the segment row as it stands, and `act --kind segment` is the act that replaces it — so on a `머지` target, where the row write is labelled `--cutpoint 머지` like any other act, the check refused the repair on the strength of the row being repaired and prescribed the repair again. The ownership question is not dropped: the row writer asks it of the row being written, refusing a non-terminal row whose worktree is in another repository with exit 2. The remaining sentences still read the existing row, so a `segment` act can still come back 10 — that is the case the park disposition above is for.

**Exit 7 is the router's alone, and a stage that receives it can only stop.** The condition is outside a stage by definition — the surfaces are the run's settings, the rule catalog, the hook and the project settings — and it cannot even look at them, because looking needs the Bash that was just refused. It has no re-baseline available either: that would be the bound moving its own boundary. So the gate now tells a stage in as many words to stop rather than retry, and records a run-scope `blocked` row so the condition is visible as run state instead of as a stage's wasted turns. Measured before that: five stages, four of which retried into the same refusal 3, 9, 12 and 15 times and produced nothing. **The run does not recover — re-baselining is not offered.** Start a new run.

**On `plan`, 7 is a forecast and not an event.** The comparison that produces it is a pure read, so the dry run makes it exactly as an act does — but it appends no run-scope `blocked` row, raises no banner, and does not end the run. A 7 from `plan` says the next `act` carrying this argv will take the paragraph above; a 7 from `act` says it just did. Only the second is the run's ending. Before this the dry run answered 0 here, having skipped the axis altogether — which is the shape of defect this verb exists to remove: an axis that is cheap to check, writes nothing when checked, and was reported as passing without being looked at.

Past the checks, the act's own exit status passes through. A refusal always arrives with a `gate:` line and no output from the act — that, not the number, is what separates them.

### When an approval is pending

**Approvals that carry a recommendation no longer wait.** With `CC_CMDS_AUTOPILOT_AUTO_RESOLVE` unset (the default), the gate closes a boundary approval (B1–B3, `SHIFT-FLOOR`, and B4 below the declared cost ceiling) as `승인` — its recommendation is to continue — and closes a judgment approval by adopting the router's own recommendation, the judgment it submitted, **only when its class may be adopted**: inside the judgment vocabulary and not one of the two classes that hand risk to the user. Everything else is closed as `거부` — `팀-구성` and `시각-면제`, a class outside the vocabulary (a misspelling of a vocabulary class, or a value carrying a space), and a judgment with no class at all: the run still does not wait, and it does not take that risk on anyone's behalf. Three approvals are **not** auto-resolved and stay `대기` like any open approval: a B4 at or above the declared ceiling (nothing else stops spending, so the open approval is the signal that the run is past what was authorized), an approval a person already answered with free input or through a frame with no slot for it (its last row carries `처분 사유`, and closing it would replace the person's words with the router's), and act approvals (below). The closing row is written only if the approval is still an unanswered `대기` under the ledger lock, so an auto-close and a person's `close` cannot overwrite each other — the loser writes nothing, and a person's `close` that loses fails saying so. Each close is a ledger row carrying `처분 사유=자동 해소` and `응답 토큰=-`, so the morning report can tell it from a person's answer. What you see is an ordinary exit code — `0` for an adopted judgment, `3` for a refused one — and no exit 5. **Act approvals are not auto-resolved**: an external-state act outside the pre-authorization has no recommendation, so exit 5 below still applies to them, and to every approval when the switch is `0`/`off`/`false`/`no`.

**A reach park never reaches exit 5 while the switch is on, and it becomes an ordinary act approval when the switch is off.** An `exec` whose declared reach the run may not act in exits 11 with a `blocked` row rather than issuing a question — there is no recommendation to auto-resolve and nobody to ask, so the act is dropped and the run continues. Turn the switch off and the same table's park cells issue the act approval this gate has always issued, which is exit 5 below. **The rule-loop fix is what makes either safe**: the catalog now runs to the end instead of returning at the first approval request, so an act that both needs a pre-authorization and lacks a review record can no longer be let through by answering only the first of the two.

Exit 5 means the run has asked and cannot answer itself. **Ask the user in this terminal** — this session has `AskUserQuestion` and a headless stage does not, which is the whole reason the router lives here. Then call `gate.sh close --approval <id>`.

**The question you ask is the gate's, verbatim — you do not write it.** Before asking, call `bash <plugin root>/orchestrator/gate.sh prompt --manifest <매니페스트> --approval <id>`. It prints one JSON object: `question` is the canonical prompt `승인 <id> — <질문>`, and `options[]` are `{label, description}` pairs from the gate's own label table. **(가) Put `question` into the `AskUserQuestion` `question` field byte-for-byte** — do not rephrase, shorten or move the id: the id riding inside the question text is how `close` finds the answer frame again, and a question that does not carry it is a question that can never be closed. **(나) For a `절단점=판단` approval, render `options[]` verbatim as the option list**, label and description both, in that order, and add nothing of your own — no extra option, no hand-written free-input entry (the tool provides one), no reworded label. The one decoration the AUQ authoring rule allows is the recommendation suffix (` ← 추천` / ` ← 에이전트 추천`) on the label at position 1; the gate strips it at comparison time. Act and boundary approvals come back with an empty `options[]`: they have no menu, so ask them as a plain yes/no question with the canonical `question` and close with the flag that matches the answer.

`close` reads the **harness-written transcript**, not the router's prose, and it reads it **by frame**: the line must be the `tool_result` of the `AskUserQuestion` whose question carried the id, and it must hold the harness's `toolUseResult.answers` map. A router that could type its own answer would be issuing approvals to itself; a router's own Bash output that happens to echo the ledger is not a frame and never closes anything. If the transcript cannot be read, `close` refuses; that refusal is the mechanism working.

**For a judgment approval the answer is read by label equality, never by scanning prose.** The person's choice is compared, whole-string and with the recommendation suffix removed, against the gate's three labels: `승인` closes as granted, `거부` as refused, `무효` as should-not-have-been-asked. **An answer equal to none of them is free input, and free input is not a refusal**: the approval stays `대기`, `close` exits 5, the answer bytes are kept in the run's approval sidecar (`docs/pipeline-approval/<run-id>.md`), and the approval's last row gains `처분 사유=자유 입력` — which the snapshot surfaces as `disposition` on that pending approval, so the morning can tell "answered, nothing derived" from "nobody answered". Re-ask if the person's free text needs to become a choice; do not try to close it with a flag. A frame whose question slot has no entry in the answers map is the sibling case, `처분 사유=슬롯 부재`.

**`close --void` and `close --reject` may only AGREE with the answer.** On a judgment approval a flag that contradicts the person's choice is refused (exit 3) — `--void` over an answer of `승인` is the router proposing a disposition against the person's words. On act and boundary approvals, which have no menu, the flag is still the disposition: bare `close` records `승인`, `--void` records `무효` — the question should not have been asked — and `--reject` records `거부` — it was asked, and the answer is no. `--void` and `--reject` together are refused everywhere, because they are different claims about the same approval rather than two strengths of one claim. `거부` is terminal the way `무효` is — resubmitting the same act against a rejected approval is refused rather than re-asked.

**A menu that is not the gate's is refused before the answer is read.** If the transcript's `options[].label` (suffix removed) is not exactly the gate's label set, `close` exits 3 naming both sets — that is (나) above being enforced, and the repair is to ask again with the `prompt` output rendered verbatim.

**What holds and what does not.** A torn transcript line, a dismissed dialog (the harness's `is_error` frame saying the person closed the question without choosing), a collapsed call, another tool's result, or a line carrying the id that is no answer frame at all — each leaves the approval `대기` with exit 5, a warning naming which, and **no ledger row**. Only a real answer frame writes anything.

**While an approval is open, the stagnation boundaries are suspended.** A run waiting for a person is not a run that stopped moving, and without the suspension the boundary's own remedy would reset the counter that fired it.

**Closing a boundary approval restarts that boundary's count**, whatever the disposition and whoever closed it. Before this the count stayed where it was, the suspension lifted, and the very next act took it past the threshold again — the same question with the same number, seconds after a grant. B1's repeat count and B2's obligation count go back to zero, B3's window restarts from the exec total at the close, and B4 does not ask again until spending climbs another ten points past the share it was answered at. At or above the declared ceiling a B4 is left open for a person rather than auto-resolved, so there is no answered share to count from until someone closes it.

### Judgment, not just acts

Not every decision is an act. For those, the question is **"may I choose this without asking?"** — the three grades of `_common/judgment-grade.md`. Grade 0 needs no record, grade 1 is adopted with a row carrying `등급`·`기준`·`되돌리는 법`·`판단 부류`, and grade 2 is escalated. **`팀 토론 진행` and `재설계` are never adopted as recommendations** — they are routing output, and whether to convene a team is the router's call rather than a stage's.

**You never choose to ask.** Submit your own recommendation with `act --kind judgment`; whether it becomes a question is the gate's decision. A grade-2 judgment is raised to a `절단점=판단` approval, and so is a grade-1 judgment that does not clear the auto-adoption floor. Both come back as exit 5, and the approval's id is derived from the judgment, so resubmitting the same one finds the open approval instead of opening a second. **With auto-resolution on (the default) neither waits**: the gate issues the approval, closes it at once as the adoption of your recommendation, and the act exits 0 with the `자율 승인` row naming the approval in `해소 승인` — see 「When an approval is pending」. A judgment approval left open from before is closed the same way on its resubmission — unless a person already answered it with free input, in which case it stays open.

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
  --emit-digest \
  -- <스테이지 종류> -p "/cc-cmds:<스킬>-unattended <인자…>"
```

`<H>` comes from `<run-dir>/digest/gate-digest-router.json`, written by the previous acting call's own `--emit-digest`; where that file is absent take it from `snapshot` instead, and where the gate refuses the flag as an unknown argument drop the flag and keep taking it from `snapshot`. **Check its `actor` field before using `H`** — it carries the emitting stage id verbatim, `router` when the router wrote it, and a value that is not yours means the file is somebody else's emission rather than a stale one of your own; fall back to the round trip in that case.

**The first token after `--` is the STAGE KIND, and it is consumed before the CLI ever sees the rest.** `act --kind skill` calls the launcher as `<alias> <segment> <stage-kind> <cli args…>`, so a form that starts with `-p` hands `-p` over as the kind. The vocabulary check then falls back to `generic`, meaning the stage runs under settings that are not its own, and `-p` is gone from what reaches the wrapper. The kind is one of `audit`·`design`·`implement`·`review`·`reconverge`·`generic`, and it selects the settings variant rather than the skill.

An earlier version of this section omitted that token — so the text written to prevent a silent-green dispatch was itself instructing one.

Four parts, and each one has a measured failure:

- **`-p` is required.** The wrapper passes everything after `--` to the CLI, so without `-p` the prompt is never delivered. Omitting it while passing a bare skill name produced `산출물 없는 정지 rc=0 · 0.809852 USD` — the model woke with an **empty first user message**, read a file, asked "what should I do?", and terminated as a success. Omitting it while passing a quoted slash command instead fails loudly (`stage-wrapper: CLI arguments are required after --`, `크래시 rc=2`), which is the better of the two.
- **The prompt is a slash command**, leading `/` included.
- **It must be the `-unattended` variant** — and the reason is not that the plain name fails. The plain `design-audit`, `implement` and `review` skills carry `disable-model-invocation: true`, which closes the **Skill tool** path and nothing else; a headless stage that names one still reaches the same instructions by reading the file, and measured, one did — a complete report, 129 USD, produced end to end from a plain skill name. So the failure mode is not an error, it is a stage running the interactive-shaped workflow with nobody to interview, and it is green. Nothing in this loop detects it, because there is nothing to detect: the dispatch is well formed and the stage produces output. Only the spelling in the prompt separates the two.

  This paragraph used to say the plain name "resolves nothing at all". That was false, and its falseness is why no check was ever built here — a form believed to fail loudly needs no guard.

The first form is the dangerous one precisely because it is green: exit 0, cost charged, no output. Neither the gate nor the wrapper can catch it — a prompt is a string, and any string is a valid one.

**Issue the dispatch in the foreground; it returns within seconds.** The gate pins the attempt, writes a one-shot launch token, and starts `gate.sh supervise-stage` — a re-entry of the gate itself, not a second script — through a double fork that leaves it adopted by init before the call returns. That supervisor consumes the token (a caller without it is refused with exit 3 and starts nothing), runs the stage, writes `stage-result` and `cost`, and removes the per-segment files. The act's exit status is therefore LAUNCH success; how the stage ended is what `wait` reports.

**To wait for it, issue `gate.sh wait --manifest <매니페스트> --segment <id>` as a harness-tracked background command and put `Monitor` on its output.** It prints a heartbeat line every 300 seconds (`--interval`) and a final line, and its exit status is the stage's own rc or one of 11–14. `--timeout` defaults to 21600 seconds and ends the wait with 13, never the stage. Tracked is right for `wait` because it must die with the seat that issued it; it was wrong for the dispatch, and that is why the dispatch no longer blocks.

This replaced an instruction measured to cause the loss it was written against. The dispatch used to block on the stage, the harness reaps a tracked job by walking its process tree, and the stage died with the session that dispatched it — with no row, because the row was written after the block. No instruction governs a stage's survival now, so none can end it.

**The stage's stream is at `<run-dir>/log/<segment>.json`**, and its stderr beside it. That is where a stage's own account of itself lives when you need it.

Three conditions must **all** hold before a segment is dispatchable, and reading only the first is how a router concludes it may go: **dependency** (no predecessor unfinished), **capacity** (concurrent model streams within the cap, taken from each skill's declared value rather than estimated), and **exclusion** (no live stage already holding an exclusive resource — the experiment-worktree prefix, which counts repo-wide, and one live stage per output document path).

#### Dispatching the design stage

When the snapshot's `design_required` is `true` and a step in `steps[]` has `skill` `design`, this loop is the only thing that dispatches it — the fixed-graph driver's design arm is not on the router's path. The step id below is that step's `id` (`.steps[]? | select(type == "object" and .skill == "design") | .id // empty`), read from the snapshot like everything else this loop decides on. **Both guards carry load and neither is decoration** — an object step written without an `id` yields nothing here rather than `null`, and an older string step yields nothing rather than a jq error. An empty result means the plan named no design step, which is the same conclusion the gate reaches before it refuses the dispatch with exit 3. **The selector is the front half of the gate's decision, and the back half is shell rather than jq.** The gate strips blank lines from that output and then requires exactly one line to remain, so three results read the same way here — no line at all, one blank line (a step whose `id` is the empty string), and two or more lines (a plan carrying more than one `design` step). All three mean `no single design step`, and all three take whatever disposition an empty result takes here. **An empty-string `id` is not a design step with a blank name.** Nothing on this path keys on that value: a run-directory file named with it and a `| 스테이지= |` grep both land on real things that are not this stage. **A design step is not a segment.** It has no `segment` row and is dispatched with `--segment -`; every ledger row about it — the dispatch, the stage's own acts, its `stage-result` — carries `세그먼트=-`, while its run-directory files (attempt pin, stream, pid record, halt record) are named by the step id. That is the row the fixed-graph arm writes too, so both paths leave one row shape. **Three guards, and the document's freeze line is none of them.** Every read below goes through the gate and is answered only by a call whose output carries `게이트 통과`, on the same terms as 「Recovering a review stage that crashed」.

1. **Resume is decided by the ledger.** Read this run's rows for the step: `gate.sh exec … --surface 읽기 -- grep -nF '| 세그먼트=- | 스테이지=<step id> | 종류=design |' <원장 경로>`. If a row exists the stage was dispatched already, and **the last such row decides** — a step dispatched again carries one row per attempt. `종단 부류=정상 완료` goes to item 5's freeze check. **`종단 부류=외부 종료` is the one class that may be dispatched again, and only onto an absent document.** The gate's prelude writes that class about a dispatch whose process and supervisor both vanished, without looking at the document, so a stage ended before its team placed a file at the path — a machine asleep, a process group ended — lands here having written nothing. Go on to item 2, whose first bullet holds the stage dispatched again while it runs, and then take item 3's `ls` alone: no file at the path → item 4 dispatches again, on the next attempt number; a file at the path → stop the design as below, whatever its freeze line says, because a stage that ended unobserved after placing the document left it partway. Anything else stops the design there. A stage that halted or crashed left a document partway through its walkthrough, and neither a second design nor the audit may take that document.

   **Stopping the design is not a `blocked` row.** A design step has no `segment` row, and a cone is refused without one; run scope is only ever resolved by this loop. What stops is everything that depends on the step: dispatch none of it, and once nothing else in the graph is dispatchable, propose done with each clause that needs the document marked `불가능` and the `stage-result` row — plus the halt record's path when one exists — as its evidence. A clause held by an approval the stage's emitted judgment opened is `보류` naming that approval id instead. **The gate records that proposal as `무효화`, never as satisfied.** With no `segment` row, condition 1 names the design step instead of saying the run has not begun once the step's last `stage-result` row is anything but `외부 종료`, a document already sits at the path, or the manifest names no document — an `외부 종료` last row with no document is the window item 1 dispatches again, and there the plain line stands; when every clause is settled that line is the only one left, and `propose-done` closes the run as `무효화`. That verdict is the gate's, not this loop's — a `1` still in `unmet_condition_numbers` is no reason to hold the proposal once the clauses are settled as above. **One approval may hold several clauses `보류` only when it was opened by the design step** (its `막는 세그먼트` is the step id): the step emits one judgment for the whole document, and every clause that needs the document waits on that one answer. Any other approval id named on a second clause is still refused.
2. **A stage still running holds everything — a spent dispatch pin does not.** Item 1's row is written only when the stage ends, and the stage puts a file at the document path when it spawns its team, hours before its last edit freezes it — so while it runs, item 1 finds no row and item 3 finds a document. Before item 3, look for the step itself. **Three signals, and they do not share one disposition.**

   - **Its id as `세그먼트` in the snapshot's `live_stages[]`, or its id in `orphan_stages[]`** → **wait and advance nothing**: dispatch no step that depends on the design, and wait on it with `gate.sh wait --manifest <매니페스트> --segment <step id>` (the step id, never `-`); when the wait ends, start again from item 1.
   - **A dispatch record with no row** — `gate.sh exec … --surface 읽기 -- ls <절대 run-dir>/<step id>.attempt` answering present while item 1 found none — → wait on it the same way, **once**. That pin is the state `wait` answers **14** for: the attempt number was stamped and no row ever followed. `wait` does not remove the pin on that path, so a 14 means the pin is **spent**, not that the stage is still coming — do not wait on it a second time and do not start again from item 1. Go on to items 3 and 4 and dispatch; that takes the next attempt number. Reading 14 as "still running" is what turns 「wait → 14 → start over」 into a circuit with no exit, because nothing in it ever clears the pin.

   This guard is not about remembering a dispatch — the session that meets it is the one that took the seat mid-stage and never saw the dispatch at all.
3. **It fires only on an absent document, and the design stage's own spawn-time stub counts as absent.** `ls <설계 문서 메인 워크트리 절대 경로>` through the gate. A document that exists is not this run's to design, whatever else it contains — a person's unfrozen document lacks the freeze line too, and a dispatch keyed on that line would write over it. Do not dispatch.

   **The one file that is not somebody's work is the stub the design stage writes when it spawns its team** — an H1 and the team's ledger comment block, with no `##` section yet. Ask the file rather than the path, through the gate: `grep -qF '<!-- cc-design-ledger' <문서>` true **and** `grep -qE '^## ' <문서>` false. Both → the previous attempt carried nothing off, there is nothing to write over, and the path counts as absent: go on to item 4 and dispatch. A person's document fails the first test and a saved one fails the second, so neither is mistaken for a stub. Measured: a design stage crashed on a session limit and left 2841 bytes with no `##` heading at the path; every later run stopped here on that file until a person renamed it by hand, which no procedure asks for and an unattended run has nobody to do.

   **This leans harder on item 2, which is why item 2 comes first.** The stub is at the path while the stage is still running, so the only thing standing between a live stage and a second dispatch is item 2's live-stage check — never reach item 3 before item 2 has answered.

   **Whether the graph goes on is the freeze line's to say:** a document carrying a line reading exactly `**상태**: 동결됨` (`grep -qxF '**상태**: 동결됨' <문서>` through the gate) → the graph goes on to its next step with that document as it stands; a document without that line — a person's hand-written draft included — → stop the design as item 1 says, naming the missing freeze line in the evidence, because an unfrozen document never goes on to the audit or to segment planning (item 5). **Record no judgment row for either**: the judgment vocabulary has no class for this decision, and borrowing a class meant for something else would put a mislabelled row where the morning audit reads classes.
4. **The dispatch.** Stage kind `design`, home alias, `--segment -`, document path first and task sentence second — the fixed-graph arm's shape:

   ```
   gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
     --cutpoint <token> --surface 워크트리쓰기 --snapshot-digest <H> --emit-digest \
     -- design -p "/cc-cmds:design-discuss-unattended <설계 문서 메인 워크트리 절대 경로> \"<## 의도 의 첫 비어 있지 않은 줄>\""
   ```

   The gate exempts exactly this form — `--kind skill`, `--segment -`, stage kind `design` — from the `segment` row and predecessor checks, and only when the frozen plan requires a design and names exactly one `design` step; it keys the stage on that step's id and refuses with exit 3 otherwise. Do not write a `segment` row for the step to get past a refusal: that row is what termination condition 1 counts, and a design step is not a segment. The path is the one `## 요소` names, made absolute against the home target's main worktree. The task sentence is the first non-empty line inside `## 의도`'s fence, copied verbatim. Wait on it with `gate.sh wait --manifest <매니페스트> --segment <step id>`.

   **The name belongs to the kickoff, and this loop never supplies one.** `## 요소`'s `설계 문서` is chosen in Act 1 (Step 5k) and frozen with the manifest; on a `design_required` run `(없음)` is a refused value there, rejected by the kickoff's own pre-freeze self-check and again by the gate's exemption. So when the field is empty or `(없음)`, do **not** compose a path for the argv. A path invented here names a document no other guard, no audit and no segment plan is looking for, and the run would go on around it. Let the gate refuse with exit 3 and stop the design as item 1 says.
5. **`정상 완료` on the row is not the freeze.** On this path the gate classifies a stage by its exit, its halt record and whether it wrote a gate row, and none of those says the document was frozen. So check both authored facts before anything reads the document: the freeze literal `설계 문서를 동결했습니다.` in the stage's stream (`gate.sh exec … --surface 읽기 -- grep -rlF --include='<step id>#*.json' '설계 문서를 동결했습니다.' <절대 run-dir>/log`) **and** a line reading exactly `**상태**: 동결됨` in the document (`grep -qxF '**상태**: 동결됨' <문서>`). Both → the next step of the graph; the stage names no next step, by contract. Either missing → stop the design as item 1 says, naming which of the two is absent in the evidence. **An unfrozen document never goes on to the audit or to segment planning.**

#### Dispatching a review cycle in delta mode

A segment's second and later review cycles re-read almost everything the first one read. A **delta** cycle reads only the files changed since the segment's last full cycle for new findings and re-adjudicates every P0/P1 that cycle raised; the review skill and the gate decide whether it holds, and this loop only offers it. **If the segment's last `stage-result` row reads `종류=review` with `종단 부류=크래시`, go to 「Recovering a review stage that crashed」 before dispatching anything from here** — a fresh dispatch early-stubs the report path that subsection reads its roster from. Five things, in order:

1. **Basis selection.** Filter `cycles[]` to this segment and take, among the rows whose `모드` is `전체` or empty, the one with the numerically largest `사이클`. **`사이클` is a JSON string in the snapshot**, so a string maximum picks `"9"` over `"10"` and offers a basis the gate then refuses as stale, on every re-dispatch alike; compare it as an integer, which is what this expression does — `[.cycles[] | select(.["세그먼트"]=="<세그먼트>" and (.["모드"]=="" or .["모드"]=="전체"))] | max_by((.["사이클"] | tonumber?) // -1)` — and a `null` result means there is no basis. None → dispatch a full review exactly as before. One → carry that row's `사이클`, `리뷰 HEAD` and `리포트 경로` into the `/cc-cmds:review-unattended` prompt as `--basis-cycle <n> --basis-review-head <sha> --basis-report-path <abs>`, alongside the `--report-path`, `--base-sha` and `--declared-files` you already pass. All three or none: the skill treats a partial set as absent.
2. **Path resolution.** The basis row's `리포트 경로` may be relative to the target's base. You hold the manifest path, so build `dirname(<매니페스트>)/../../<경로>` and pass the absolute result; an absolute value goes through as-is. No new snapshot key exists for this.
3. **The row's mode is copied from the report, never from the dispatch.** After the stage ends, read the report overview's `- **리뷰 모드**: …` line and write `모드` and `기준 사이클` on the `cycle` row from that line: `- **리뷰 모드**: 전체` → `모드=전체` (or omit both fields); `- **리뷰 모드**: 델타 (기준 사이클 <n>, 기준 리뷰 HEAD `<sha>`)` → `모드=델타 '기준 사이클=<n>'`. The skill degrades to a full review when any eligibility check fails, and only the report says whether it did. The gate compares the row against the report on every `cycle` write and refuses with exit 2. **There are two repairs, and the refusal's wording says which one applies.** A mode mismatch — the row says one mode and the report the other — is repaired by rewriting the row to what the report says. Every other refusal of a delta claim (the basis number or head on the report line, the basis row, its report, the ancestry, a `사이클` not above its basis) that still stands once the row's `사이클` is this cycle's number and its `모드`·`기준 사이클` match the report line is repaired by **no** row: rewritten as `모드=델타` it meets the same check again, and rewritten as `모드=전체` it meets the mode comparison, because the report still says `델타`. Re-dispatch this segment's review as a full review **without the three basis flags**, and write no `cycle` row until a report the gate accepts exists.
4. **No new question point.** When a basis exists, attempting delta is the default. Whether it holds is decided by the skill's eligibility checks and the gate's write-time checks, not by asking.
5. **The snapshot window is a limit, stated rather than hidden.** `cycles[]` is the ledger's last twenty `cycle` rows, so a segment whose basis row has been pushed out of the window by other segments' cycles gets a full review. That errs toward reading more, never toward a false delta.

#### Recovering a review stage that crashed

A review stage that dies usually leaves its team's work on disk: every seat publishes into a witness scratch directory under the run directory, and `/cc-cmds:review-unattended --recover` synthesizes the report from that directory without spawning anyone. The fixed-graph driver dispatches that recovery on its own; this loop has to dispatch it too, or a crashed review's witness is never read and the next dispatch buys the whole review again. **Evaluate this before re-dispatching a crashed review** — a fresh review early-stubs the same report path, and that stub replaces the ledger block the recovery reads its roster from. **Every review dispatch this loop issues carries an absolute `--report-path`**, the ordinary ones included: without it the report lands relative to a segment worktree that is torn down, no session holds its path, and item 2 blocks every crash, so this subsection never fires.

**A probe answers only when its output carries `게이트 통과`.** Every read below goes through the gate, and a gate refusal exits non-zero with nothing on stdout — the same observation as `grep` finding no line or `ls` finding no file. The refusal these reads meet most is exit 4, a stale snapshot digest, and it is routine exactly where they sit: right after a stage's row lands and right after the recovery ends. So a call whose output lacks that line is a refusal whatever its exit code, and never branch on the refused call. **Only exit 4 is retried here**: re-read `H` and issue the same probe again, **at most three times in a row for one probe**. Every other refusal code does what 「Reading the exit codes」 says for it — 6 is not re-declared to match, 7 stops, 11 is not retried — and a code of 1 with no gate line means the shell rejected the line before the gate ran. On a call that carries the line, the command's own exit code is the answer: for `grep` and `ls`, 0 is a match or a present file and 1 is none; any other code means the probe did not run as written (an unresolved path, a bad argument), which is not an answer either — fix the probe when the fault is in its own argv. **A probe that stays unanswered ends the subsection**: when the retries reach three, when the table forbids retrying its code, or when the fault is not one the router can fix in the argv, write item 3's `blocked` form with `사유=리뷰 크래시 — 복구 판정 읽기가 답하지 않는다 (<exit code>)` and dispatch nothing. Reading a refusal as a file fact is not harmless: at item 3 it parks the segment while the witness is still on disk, and no second recovery is allowed for the same crash. Five things, in order:

1. **One terminal class triggers it.** None of the values below is in the snapshot — `segments[].마지막 스테이지` carries only the segment id on this path — so read the segment's `stage-result` rows from the ledger with a read through the gate: `gate.sh exec … --surface 읽기 -- grep -nF '| 세그먼트=<id> | 스테이지=<id> | 종류=' <원장 경로>`, and take the last line. The row the gate writes carries `종류=<stage kind>`, `실행 버전=<attempt>` and `종단 부류=<class>`. Only `종류=review` with `종단 부류=크래시` belongs to this arm; every other class is routed as before and is not a recovery target. A crashed `--recover` dispatch is not recovered again — record it under item 3's `blocked` form as `리뷰 복구 종단 부류 크래시`. Reading the ledger here has the standing the delta section's read of the report has: an artifact the stage just produced, read to write a row, not a decision carried across turns.
2. **A report that already carries the termination predicate is not recovered, and a report path you do not hold is not rebuilt.** The report path is the `--report-path` this session passed on that review dispatch — the same value the ordinary `cycle` row's `리포트 경로` comes from. No ledger row and no snapshot key carries it (the `skill` act row records the rationale, not the argv), so a session that did not issue that dispatch must not reconstruct it by listing `docs/reviews/`: record item 3's `blocked` row with `사유=리뷰 크래시 — 원래 리포트 경로를 원장에서 얻을 수 없어 복구를 파견하지 않는다` and dispatch nothing. With the path in hand, **first check that the file exists** with `ls <report path>` through the gate. On a call that carries `게이트 통과`, a non-zero exit means no file: the stage died before its early stub, so there is no completed report — skip the predicate test and go straight to the basis-flag check below and then item 3, whose Zero branch is where such a crash lands. Grepping an absent file exits 2, which is not an answer, so the existence check comes first. With the file present, test it through the gate: `grep -qE '^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건' <report path>`. A match means the file already holds a completed report — dispatch nothing and record `사유=리뷰 크래시 — 리포트에 종료 술어 줄이 이미 있어 복구를 파견하지 않는다`. With no match or no file, **a review dispatched with the three basis flags is not recovered.** The recovery arm does not carry the delta mode into its report — its `리뷰 모드` line is absent or reads `전체` — so a report built from a delta corpus would reach the `cycle` row as a full review, and the delta section's basis selection would take that row as the next full basis with nothing refusing it. Re-dispatch the segment's review as a full review without the three basis flags, as the delta section's item 3 repair does, and write no `cycle` row for the crash.
3. **Name exactly one witness directory, or dispatch nothing.** Each directory is `<run-dir>/cc-team-witness-<slug>.<tag>.XXXXXX`, and its `.attempt` stamp holds the stage id the gate handed the stage, verbatim — on this path `<segment>#<attempt>`, with `<attempt>` the row's `실행 버전`. Enumerate and compare in one read, with no shell glob: `gate.sh exec … --surface 읽기 -- grep -rlxF --include=.attempt '<segment>#<실행 버전>' <absolute run-dir>`; each printed file whose parent directory is named `cc-team-witness-*` is a candidate. A glob that matches no directory fails in the shell before the gate runs, which looks like an empty answer and is not one. `-x` makes the comparison whole-line, so `S1#2` does not take `S1#21`. **Match on the stamp, never on the directory name** — the name carries a sanitized tag — **and never choose by mtime**: attempts of one segment interleave, and mtime order lies.

   Every `blocked` row in this subsection takes this one form, and only `사유` changes:

   ```
   gate.sh act --manifest <매니페스트> --kind blocked --target <alias> \
     --cutpoint <token> --surface 읽기 --snapshot-digest <H> --emit-digest \
     --rationale '<why>' \
     -- 스코프=cone 원인=막힘 '사유=<사유>' '근거=<the stage-result row>' '앵커 세그먼트=<id>'
   ```

   - **Exactly one** → item 4.
   - **Zero** (the call carries `게이트 통과`, `grep` exits 1 and prints nothing) → the stage died before its first spawn and nothing is on disk to recover. Write the `blocked` form above with `사유=리뷰 크래시 — 시도 <n> 의 위트니스 디렉터리가 없어 Step 4 미도달, 복구를 파견하지 않는다`.
   - **Two or more** → the `blocked` form above with `사유=리뷰 크래시 — 시도 <n> 에 위트니스 디렉터리 <k>개, 지명 불가: <every candidate path>`. Dispatching without a name buys a stage that is certain to fail: with no `--scratch-dir` the recovery arm lists the candidates and recovers nothing.
4. **The dispatch.** Stage kind `review`, the same target as the review it recovers, both paths absolute:

   ```
   gate.sh act --manifest <매니페스트> --kind skill --target <alias> --segment <id> \
     --cutpoint <token> --surface <token> --snapshot-digest <H> --emit-digest \
     -- review -p "/cc-cmds:review-unattended <target> --recover --scratch-dir <abs witness dir> --report-path <abs original report path>"
   ```

   Carry no `--base-sha`, `--declared-files` or basis flags; the recovery reads only the directory and the report's ledger block. Issue it as a harness-tracked background command like every stage. It pins a new attempt of its own, so its `stage-result` row is not the crash it recovers.
5. **The `cycle` row comes from the recovered report, and only from a clean one.** The report is clean when all four hold: the recovery's `stage-result` row reads `종단 부류=정상 완료`; the report path now matches item 2's termination predicate; the file carries no `- **발견 요약(부분 복구)**:` line (test it with `grep -qF -e '- **발견 요약(부분 복구)**:' <report path>` — the `-e` keeps the leading `-` from being read as a flag); and no `<report path>.recover.md` exists beside it (`ls <report path>.recover.md` through the gate — a non-zero exit means absent only on a call that carries `게이트 통과`). Otherwise write no `cycle` row — a partial-recovery line is deliberately not the predicate, and a diversion to `.recover.md` means the report path holds a report this recovery did not write — and record item 3's `blocked` form naming which: `리뷰 복구 종단 부류 <class>`, `부분 복구`, or `.recover.md 로 우회`. Do not dispatch a second recovery for the same crash.

   From a clean report, read the `리뷰 HEAD` line with a probe anchored at the line head that also requires the value: ``grep -E '^[-*[:space:]]*\*\*리뷰 HEAD\*\*: `?[0-9a-f]{40}`?$' <report path>``. Exactly one printed line is the value; no line, or more than one, is absent. An unanchored probe is not enough — a finding that quotes the label matches it, and a label with no 40-character sha behind it is no source for the field. **No `리뷰 모드` line is required.** Item 2 already refused to recover a review dispatched with the basis flags, so the recovered report is a full review, and a report with no mode line is read by the gate as `전체`, which is the truth here.
   - **`리뷰 HEAD` present** → write the `cycle` row: `P0` and `P1` from the `발견 요약` line, `리뷰 HEAD` from that line's sha, the report path as `리포트 경로`, the crashed review's cycle number as `사이클`, and no `모드`·`기준 사이클` fields.
   - **`리뷰 HEAD` absent** → the recovery arm is not bound to emit that line and nothing may stand in for it, so a required field of the row has no source. Do not park the segment for that: write no `cycle` row and re-dispatch the segment's review as a full review **without the three basis flags**, carrying an absolute `--report-path` like every review dispatch. That is what a crashed review got before this subsection existed, so a clean recovery never leaves the night worse off than no recovery would. This re-dispatch is a review, not a second recovery.

### Resuming after a break

Five ways a run is cut, and all five resume: the terminal closes, Ctrl+C, the token limit, the network drops, a reboot. **Resume by resuming this session and saying so.** The router then does what it always does — read the snapshot and continue. There is no separate resume protocol, because the router holds no state that a snapshot does not.

**The first three do not cut a stage.** The terminal closing, Ctrl+C and a dropped network act on this session, and a dispatched stage's supervisor is detached from it — nothing was cut, so there is nothing to re-attach: read the snapshot, find the segment in `live_stages[]`, and `gate.sh wait` on it. A stage whose supervisor did die with it shows in `orphan_stages[]` until the next gate call settles it as `외부 종료`.

**`--resume` is for the three cases that do end a stage.** A reboot (the run directory survives and the processes do not), the stage's own death (an account limit, a token limit, a CLI crash — the supervisor survives those and records them, so the run knows), and a stage that ended its turn to ask (the wrapper's documented use). A resumed stage continues its turn rather than restarting it. It is not this shell's child either, so liveness is `kill -0` on the recorded pid together with its start-time fingerprint, never the shell's own `wait` builtin.

### Shifting the loop, and re-arming the channel on every return

The loop is capped rather than run to exhaustion, and the cap is read from the snapshot's `shift` block — never estimated. A session cannot measure its own context, and a number a router recalls is memory wearing a number.

**Three reasons end a shift, and a live stage holds back none of them.** `상한` — `shift.over_soft` is true. `승인` — the gate answered exit 5, so the shift ends without answering and the seat does. `종단` — a `propose-done` was accepted. A live stage used to hold back the first, on the premise that it was the routing session's child and would die with it; the supervisor is detached now, so ending a shift under a live stage costs the stage nothing, and holding the cap for it would keep exactly the context the cap exists to end.

Ending a shift is two calls, in this order:

```
gate.sh act --manifest <매니페스트> --kind handoff --target <alias> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> \
  -- 교대=<n> 사유=<상한|승인|종단|중단> \
     '버린 선택지=<시도했고 버린 것 · 무엇을 보고 버렸는가>' \
     '막힌 지점=<지금 벽이 있는 자리>' \
     '다음 후보=<후임이 먼저 볼 것>'
```

**`버린 선택지` is the field nothing else in the ledger can hold.** The snapshot records what LANDED; without this the successor re-walks every dead end its predecessor already paid for, and the morning report's request for the rejected alternative has no source at all. A shift that ends with all three fields empty has handed over its position and none of its reasoning.

Then the seat starts the successor:

```
gate.sh act --manifest <매니페스트> --kind router-shift --target <alias> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> \
  -- <사유> -p "/cc-cmds:autopilot-router-shift <매니페스트>"
```

**The first token after `--` is the HANDOFF REASON**, the way it is the stage kind for `act --kind skill`. `--kind router-shift` is the LEDGER ROW KIND and `shift` is the SETTINGS VARIANT the wrapper receives; they are different layers with different names, and swapping them runs the shift under settings that are not its own.

**That call has TWO outcomes and they are told apart by exit status, not by prose.** `0` — the successor ran and came back, so route again on its return line. `5` — an approval was issued instead of a launch: the handoff floor is past its cap, nothing was started, and this is a question for a person, so answer it here before trying again. Both used to report `0`, which is why 「 the successor is running」 had to be inferred rather than read. A third outcome, `10` for a cap shift held behind a live stage, left with the hold.

**The successor reads the snapshot itself and never the `H` its predecessor handed back.** The gate no longer refuses that value on the strength of the `handoff` row alone: `handoff` moves the chain tip and no component of the progress vector, and the ledger's row count left the digest formula entirely, so a quoted digest can sit inside the bounded ancestry window and pass. Reading it yourself is what makes the successor's first act rest on state it observed — and nothing downstream catches it if it does not.

**The seat delegates its `exec` READS to the shift, and consumes what comes back.** A read this seat runs to reconstruct the run's state is paid for twice — once here, in a context that is compacted repeatedly across a long run, and again in the shift, which reads the snapshot fresh regardless. So the seat does not go looking: it issues the shift, and when the shift returns it reads the `handoff` row and the chain tip that row left behind. Measured, the saving is small — bounded at ≤1.4pp of the seat's cost — and the reason to take it is the ordering rather than the number. A seat that reads run state itself is a **second reader of one state**, and two readers disagree in the dark exactly as two routers do; delegating leaves one reader and one record of what it read.

**Three things do NOT move with it, and each for its own reason.** The **snapshot stays at the seat** — `H` is needed by every acting call, so delegating it would mean delegating the act; what narrows it is `--fields`, not a change of reader. **Rendering an approval stays at the seat**, because an approval exists precisely to reach the person sitting in it, and a rendering that arrives in a headless process reaches nobody. And a read the seat performs to answer a question a person has just asked is not a delegated read at all — it is the seat doing the one job CFI-3 leaves it.

**RE-ARM THE PROGRESS CHANNEL ON EVERY SHIFT RETURN.** Whether a `persistent` monitor survives a compaction or a resume is unmeasured, and this binds the risk without waiting for the answer: at most three times a night, at moments the seat is awake anyway. Both branches hold — alive, the feed's lock finds the running instance, prints one line and exits 0 so a healthy night files no false failure; dead, the cursor picks up exactly where the last line stopped. Re-arm with the same command and the same `description` as Step 7.

---

## Act 3 — the morning report (`--report`)

Read the manifest, the run ledger and the report for the named run, then render in Korean. **Render only — this mode starts nothing and writes nothing.**

Cover, in this order:

- **결과 요약** — segments planned, merged, **완성-미착지**, parked; where the run stopped against its `종료 지점`. Keep 완성-미착지 separate from parked: those segments produced everything they were asked to and had exactly one terminal act blocked, and folding them into "parked" hides the difference between a night that worked and a night that did not.
- **자율 결정 전부** — every `자율 승인` row, grouped by `kind`, carrying the decision, the rejected alternative, and the rationale as recorded. **This is the whole point of the report.** The residual it compensates for — a stage that asked in prose, answered itself, and produced output anyway — is byte-indistinguishable from a correct run through every channel the design permits, so after-the-fact auditability is the only control left. Do not summarize these rows away.
- **도달 감사** — the acts that PASSED and touched something outside this machine, which no other section reports: every exec row whose `도달` is `dev`, `prod`, `배포트리거` or `협업`, every row whose `등급 출처` is `불투명` or `미상`, every row carrying a `표지`, every `dev` row whose `식별자 대조` is `미선언` or `대조불가`, and every read whose `도달` is `prod`. List them prod first. `런로컬` and `-` are reported as a COUNT and not enumerated — they are the bulk and reading them teaches the eye to skip.
- **보류 큐** — every `blocked` row with its `스코프`, `원인`, `사유`, and the re-invocation command line where one was recorded. Group the `act` parks by `도달 판정`: a `dev식별자부재` and a `prod인가없음` are one manifest line apart from being finished, while a `비밀출력` is a form that must be rewritten. Group by scope: an `act` park is one command away from finished, a `cone` park needs its premise repaired first, and a `run` park means the run could not judge a state. **Those command lines are inert**: the driver recorded them and never ran them, and neither does this step. They are for the user's hands.
- **사람 대조 필요** — every report line so marked. These are the ones where the run could not tell "still working" from "stuck", or where an apply's outcome is unknown. Name the preserved worktree path for each apply of unknown outcome; it is the only reproduction of that state.
- **스테이지 종단 부류** — per stage: 정상 완료 / 의도된 park / 산출물 없는 정지 / 공허한 성공 / 크래시 / 적용 불명 / 외부 종료. Call out every `공허한 성공` **and every `외부 종료`** explicitly; the first is a measured failure mode that used to be invisible, and the point of naming it is that it can now be counted. `외부 종료` is the one class the gate writes about a stage it never classified: the prelude settled a dispatch whose record outlived both its process and its supervisor, with no result envelope to read, so the row says a stage ended unobserved and not how. `산출물 없는 정지` was missing from this enumeration while the schema has carried it all along, and it is the value a stage lands on when it *correctly refused to decide for the user* — reporting it as one of the others is the same conflation the class was created to end.
- **판본** — the `run` row's `판본`, `판본 트리` and `판본 다이제스트`: the commit, the plugin subtree's git tree and the content digest of the copy that actually enforced this run. `(고정 안 함)` means the run was never pinned — it opened before pinning existed, or under the test seam — and is a statement about the run, not a missing value. `(미커밋)` means the subtree was dirty when the copy was taken. To reproduce a pinned version, `git archive <판본 트리> | tar -x` in the plugin repository and check that the result's content digest equals `판본 다이제스트`; a `(미커밋)` version cannot be reproduced once the reaper has collected the run directory.
- **비용** — the accumulated `cost` rows, and the cycle count against the run's cycle budget. Put **`정산됨(비용 불명) N건`** — the count of `외부 종료` rows — beside the total: a settled stage has no envelope and therefore no `cost` row, so a total shown alone reads lower than what was spent. Where this run has no `cost` row at all, report `비용 불명`, never `0`.

**State the report's own limit at the end.** It is authored by the run it describes, so it is powerless against a run that improvises **and also** omits that from its own report. The conjunction being rarer than either part is why this control is worth having — it is not a gate, and the real protection against an irreversible autonomous act remains the permission cutpoints the user set in 5b.

---

## Constraints

- **Never write the run ledger.** The driver is its sole writer. This skill writes the manifest, the grant, the interview record and the report stub, and nothing else under `docs/pipeline-run/` after that stub.
- **Never edit a design document from this skill.** The one document this skill writes is a new `lead-solo` one, after Step 5m, with a human in front of it; editing an existing one from here is a different act. There is no handoff that asks a person to run a design skill in this skill's place — a team tier's design is the run's first stage.
- **Never `arm` or `cancel` the notification helper from this skill** (CFI-4). The run's banners come from the two seats named there, and that helper stays an independent skill for use in conversation — what was removed is autopilot's dependency on it, not the helper. This is stated as a prohibition rather than as "do not infer the arming" on purpose: the older wording implied that a user utterance would make arming correct, and after this change there is no path here that arms it at all.
- **Never run a `재호출 명령`** recorded by a halted stage. It is recorded precisely because re-running it would retry a condition whose cause is still present.
- **The router's input is the snapshot** (CFI-3). Never act on a remembered decision, a remembered obligation, or a previous turn's plan.
- **Never assemble a stage command line in the router.** A stage is `act --kind skill`; the gate calls the wrapper.
- **Never stop the loop to ask.** Exit 5 is the only question in Act 2b; a stage finishing, a review returning findings, or an act failing are not questions. The stop leaves no row, so it cannot be told apart from a healthy run — see Act 2b.
- **Never answer a pending approval on the user's behalf.** `close` reads the transcript, and typing the answer defeats the only thing that makes the record auditable.
- **`--admin` is never authorized here**, whatever cutpoint the user picks.

Task: $ARGUMENTS
