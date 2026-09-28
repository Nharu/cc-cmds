---
name: design-discuss-unattended
description: 설계 세션의 무인 팔 — 좌석이 파견하면 Step 3 토론과 Step 4 종합·저장을 도는 다리, autopilot 드라이버가 파견하면 Step 7U 동결까지 도는 스테이지 (질문은 park·정지 기록으로)
when_to_use: 사람이 직접 부르지 않는다. `design` 리드 좌석이 Step 2 승인 뒤 `claude -p` 로 파견하거나(다리), autopilot 드라이버가 `design_required` 인 런의 첫 스테이지로 파견한다(스테이지)
disable-model-invocation: true
usage: "/cc-cmds:design-discuss-unattended <brief-or-doc-path> [<task-sentence>]"
options:
    - name: "<brief-or-doc-path>"
      kind: positional
      required: true
      summary: "좌석 파견: `docs/design-brief/{slug}.md` — 좌석이 쓴 인터뷰 브리프. 드라이버 파견: 설계 문서 경로(메인 워크트리 절대 경로, 드라이버가 준다 — 아직 없을 수 있다)."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰. 어느 파견인지는 이 인자가 아니라 `CC_PIPELINE_RUN_ID` 의 유무로 가른다."
    - name: "<task-sentence>"
      kind: positional
      required: false
      summary: "드라이버 파견에서만 — 매니페스트 `## 의도` 의 첫 줄. 인터뷰 브리프가 없을 때 과제 문면이 되는 한 문장."
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 좌석 파견에서는 무시한다."
notes: "좌석 파견은 halt 기록을 쓰지 않는다 — 런 디렉터리가 없고 park 는 상태 루트의 `park.md` 로 돌아간다. 드라이버 파견은 `${CC_PIPELINE_RUN_DIR}/halt/` 에 정지 기록을 쓰고, 동결 문면을 내고 멈춘다."
---

Run the unattended part of `/cc-cmds:design` in a headless session, **without ever asking a human**. Dispatched by the `design` seat it runs Step 3 (design discussion) and Step 4 (synthesis through the save) from an interview brief; dispatched by the autopilot driver it runs the same two steps from a task sentence and continues through the unattended walkthrough, pass-through refinement, coherence pass, residual ladder and freeze (Step 5U → 6U → 7U).
Team communication is English. Everything written for the user — the saved document, the presentation blocks, a park or halt record — is Korean.

## What this sibling is, and what it is not

This is the **one unattended arm** of `/cc-cmds:design`, and it has **two dispatchers**. As the seat's **leg**, the seat (the conversation with the human) runs Step 1 and Step 2, dispatches this skill with `claude -p`, and takes back over at Step 5; the boundary is Step 3 + Step 4 through the save, and it is forced rather than chosen — the Step 4 fidelity pass resumes the Step 3 team by `agentId`, and an agent id is addressable only from the session that spawned it, so Step 3 and the pass cannot straddle a session. As the driver's **stage**, nobody takes back over: the human's part was taken at kickoff (intent, cutpoints, roster), so the arm continues past the save to the freeze and hands the frozen document to the driver.

It is a separate file so that "this arm has no human-question surface" is a whole-file predicate `scripts/lint-unattended-surfaces.sh` can check. **One file still carries one arm**; what varies is who dispatched it.

## Two dispatchers, one arm

**The discriminator is `CC_PIPELINE_RUN_ID`.** Only the driver sets it: non-empty → **driver dispatch** (stage); unset or empty → **seat dispatch** (leg). Evaluate it once at Step 0 and never re-evaluate. The driver-dispatch rules live in this section, in `## Halt record (driver dispatch)`, in CFI-L4 and in Steps 5U–7U, and nowhere else.

| | seat dispatch (leg) | driver dispatch (stage) |
| --- | --- | --- |
| input | interview brief (`docs/design-brief/{slug}.md`) | design-document path (may not exist yet) + task sentence + the interview record, when the run has one (Step 1) |
| state root | `$STATE` (Step 2) | `${CC_PIPELINE_RUN_DIR}/design/{slug}/` |
| a question | park record (`park.md`) | halt record (`${CC_PIPELINE_RUN_DIR}/halt/${CC_PIPELINE_STAGE_ID}.md`) |
| terminal | `presentation.md`, end of turn | freeze literal + path + whole-file `sha256`, end of turn |
| Step 3 roster | approved by the seat, in the brief | the `설계 로스터` rows in the manifest's `## 인가`, else `### Default roster (driver dispatch)` below |
| Bash | no gate — `bypassPermissions`, blast radius disclosed in the brief | every command through `gate.sh exec` (below) |
| ends at | the save (Step 4) | the freeze (Step 7U) |

`references/` — none. This arm Reads Step 3 and Step 4 out of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` (see *Interim body* below). The surface lint does not prove the model never asks in prose and answers itself; that residual is not closed here.

**The leg is not a clean room.** It loads the plugin's hooks and inherits the global and repository instruction layers and **follows** them; the split buys a clean *conversation*, not a blank instruction layer. The notification-class hooks load too and are all closed in a headless leg.

**Its permission posture is `bypassPermissions`, and the blast radius is written down here so that "a human decision already taken" is a checkable fact.** Without any confirmation, the leg and every member it spawns can write any path the user account can write, run any Bash command (including dependency installs, `git worktree add` / `git worktree remove --force` and the verification carve-out's `git checkout -- . && git clean -fd` reset), fetch from the web, and spawn further agents. No pipeline gate engages under seat dispatch, so "NO code modifications" and the carve-out bind by instruction alone. The seat disclosed exactly this in the Step 2 proposal the user approved and recorded it in `leg.json` as `permission_posture` and `posture_approved_at`; this arm never touches those two fields.

## Park record — the disposition for every point that would have asked

Where `/cc-cmds:design` would call `AskUserQuestion`, this arm writes a **park record** and stops at the next stop point. Path: `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/{slug}/park.md`, where `{slug}` is the folded slug from the brief's `## 대상` block. Header and fields:

```
<!-- cc-design-park v1; writer=design-discuss-unattended; reader=design; slug=<slug> -->
**중단 시각**: <ISO8601>
**스킬**: design-discuss-unattended
**스텝**: <step identifier>
**분류**: tool-unavailable | gate-unanswerable | precondition-failed
**질문 문면**: <the Korean question that would have been asked, verbatim, never summarized>
**선택지**:
- `<label>` — <description, verbatim>
**하네스 오류**: <verbatim> | (없음)
**관측 상세**: <measurement values, parts joined with ` / `> | (없음)
**재호출 명령**: <the resume command line, verbatim> | (없음)
**후속**: 보류 큐
**자리 id**: <one of the nine below>
**묶인 대상**: <role / claim / reopened decision the question is bound to>
**원장 상태**: <the ledger's roster state at park time>
<!-- /cc-design-park v1 -->
```

The first ten fields are the field set of the pipeline halt record (`cc-pipeline-halt v1` in `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4), verbatim; the last three are this arm's. Write it with the atomic form of `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` §1.3 (same-directory temp, then rename); the closing fence is the terminator. Record the question, every option label and every description **verbatim** — the seat renders the record without composing anything. One record carries at most **four** questions. `재호출 명령` is recorded and **never executed** by this arm or by anything downstream. **No halt record** under any run directory: this leg does not own a run.

**`자리 id` is a closed set of nine.** `ledger-missing` (the ledger stub is missing or unparseable before spawn — parked immediately) · `case2-respawn-dead` (a Case-2 same-round respawn also died — stop point) · `unavail-streak` (`unavailStreak ≥ 2`, a witness `output_file` that vanished — stop point) · `empty-streak` (`emptyStreak ≥ M` — stop point) · `growth-streak` (`growthStreak ≥ G`, a member alive and babbling but publishing no witness — stop point) · `case1-thin-witness` (protocol Case-1, two consecutive thin witnesses — bundled) · `fidelity-case1` (fidelity-pass Case-1, twice — bundled) · `fidelity-decision-reopen` (a decision-reopen's second re-convergence failure — bundled) · `sweep-claim-2nd-fail` (the pre-save sweep's same claim failing a second time — bundled). Eight of the nine are second-failure or debounce-threshold escalations and one is a pre-spawn check, so a **normal seat-dispatched run parks zero times**, and **if a park is ever observed on a normal seat-dispatched run the cost model is void.** The driver-dispatch sites below are first-failure sites by design, so a stage that halts is not a counter-example. Maintenance duty: adding a site requires justifying it against the price of one park, and **a first-failure site is never added to the nine**.

## Halt record (driver dispatch)

Under driver dispatch the same nine sites and every site in Steps 5U–7U resolve to a **halt record**, not a park record: the stage owns a run directory, and the driver reads halts there. Schema is `cc-pipeline-halt v1` in `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4, verbatim — path `${CC_PIPELINE_RUN_DIR}/halt/${CC_PIPELINE_STAGE_ID}.md`, the ten fields, atomic form, closing fence as terminator, question and every option label and description **verbatim**, `재호출 명령` recorded and never executed. Put the site's id in `스텝` after the step identifier (`Step 5U / skeleton`). Then take no further step and end the turn. **A halt does not come back within a run** — a halted stage's row is `의도된 park`, which the driver does not re-dispatch.

**Driver-dispatch sites are a second closed set, of seven.** `document-present` (a saved document already exists at the document path — Step 0, before spawn) · `roster-missing` (the manifest's `## 인가` carries `설계 로스터` rows that cannot be instantiated mechanically — Step 0, before spawn) · `skeleton` (a walkthrough disposition that would change the skeleton — Step 5U) · `step5-zero-section` (the saved document has no `## 미해결 이슈 / 트레이드오프` heading — Step 5U) · `step7-coherence-conflict` (a coherence finding contradicts a converged decision — Step 7U) · `slicing-unknown` (the slicing self-check cannot be repaired without a decision the authors did not make — Step 7U) · `ladder-unsettled` (a residual item that no rung of the ladder settles is escalated as a `설계-골격` judgment, and the stage halts with its rung-1 and rung-3 evidence attached — Step 7U). The first two are pre-spawn refusals of an input this stage must not work from; each of the other five is the point where the attended skill asks a `등급 2` question that only a person can answer. All seven are **first-failure sites, deliberately**.

### Per-grade disposition

The base skill marks its ask points with a judgment grade (`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`). This arm's disposition is per grade:

- **`등급 0`** — no disposition is needed; an already-written rule determines the answer.
- **`등급 1`** — under seat dispatch none of this arm's nine sites is reachable at this grade: every one is a second-failure or debounce escalation with no authored standard that picks an option. Under driver dispatch exactly one class reaches it: a Step 5U walkthrough disposition that **does not change the skeleton** (`## Skeleton predicate` below). It is adopted as a `설계-쟁점` judgment — the five markers of `judgment-grade.md` §Emission form (`**판단 부류**`·`**판단 등급**`·`**판단 기준**`·`**판단 되돌리는 법**`·`**판단 근거**`), one per line, in the terminal message; the driver hands that message to the gate's absorber right after it records this stage's `stage-result` row. Adding any other site marked `등급 1` takes on the closed-set maintenance duty above, and a choice with no `되돌리는 법` is not `등급 1` whatever its mark says.

    **One terminal message carries at most one judgment**, because the absorber reads the first value of each marker and nothing after it. Every Step 5U `해결` of this dispatch is therefore **bundled into one judgment**: `**판단 부류**: 설계-쟁점`, `**판단 등급**: 1`, `**판단 기준**` stating the standard the whole bundle shares — every disposition passed `## Skeleton predicate` below; each entry's own standard is already in the document, in that entry's `**자율 처분**` field — `**판단 근거**` listing each settled entry by its heading number (short — the ledger keeps about 150 characters), and `**판단 되돌리는 법**` the one-line restore of the **first** transition's pre-image, `cp "${CC_PIPELINE_RUN_DIR}/preimage/<slug>.<seq>.md" <doc>`, which Step 5U writes before every transition so that the line is true. That restore undoes the whole bundle together with everything written after it; say so in `**판단 근거**` rather than implying a per-entry undo. **A judgment that cannot join the bundle is not emitted beside it**: anything other than `설계-쟁점` at `등급 1` has no second slot, so it is a halt at `skeleton` with the judgment in `질문 문면`, never a second set of markers. The bundle is emitted on every terminal message after the first `해결` was applied — a freeze and a halt alike — because the transitions are in the document either way. A `설계-골격` escalation (Step 7U's ladder) is carried by the halt record, never by markers, so it does not compete with the bundle for the one slot.
- **`등급 2`** — write the park record and leave at the stop point (CFI-L1); under driver dispatch, write the halt record and stop.

## Control-Flow Invariants

These rules govern how this leg stops and what it hands back, and MUST stay near the top of this file: post-compaction reattaches only the first ~5K tokens with priority.

### CFI-U0 — There is no human-question surface

`AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its escalation cases terminate in `AskUserQuestion`, **this arm resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule. Here a halt is the park record above, and its `자리 id` is one of the closed nine. Under driver dispatch `park` is realized as the halt record of `## Halt record (driver dispatch)`, and the site is one of the nine or one of the seven.

### CFI-L1 — Park at a stop point, never mid-round

Detect immediately; emit after the current round's wait has ended — every live member has published its witness, or the reconcile ladder has returned a death verdict. Only the pre-spawn site `ledger-missing` parks at once, because there is no team to wait for yet. Print-mode wind-down waits for background members up to the ceiling and then kills them, so a mid-round exit costs up to an hour; this rule buys wall-clock and determinism and is not relaxed on recoverability grounds. **`TaskStop` followed by a park is a dead end**: a stopped agent resolves as `success:false` and is lost for good. The four bundled sites are emitted once, immediately before the save.

**Wind-down waits only for tasks the harness still holds, and a member that has RETURNED is not one of them.** When every live task has ended, a turn that ends is the process ending with rc 0. The protocol's **Returned-without-witness** arm is what closes this: a member's completion notification with no witness on disk is resolved **in that same turn** — resumed with `SendMessage` (at most twice) or respawned into the same round — so that no turn ends with a `running` row the harness no longer holds.

### CFI-L2 — The exit is the synthesis-terminal line, and a resumed turn writes no prose

Normal termination is: save → durable witness corpus (inside the `done`-flip window) → `presentation.md` → end of turn. The leg never emits the seat's user-facing tail (the two Korean notices, the aggregate line, the presentation) — it composes them into `presentation.md` for the seat to render. On a resumed coherence turn the leg writes the ledger block only and returns its findings in `coherence.md`; it never edits the document's prose.

### CFI-L3 — No notification, no sidecar; a halt record only under driver dispatch

This arm never reaches `PushNotification`, `notify.sh` or `terminal-notifier` — nor does any member it spawns. It never writes `pipeline-grant` or `pipeline-run`, under either dispatcher: the driver is their only writer, and a stage that reads them still does not write them. Under seat dispatch it writes no halt record under any run directory (it owns none) and its only channels toward a human are `park.md` and `presentation.md`; under driver dispatch its only channels are the halt record and its terminal message.

### CFI-L4 — Driver dispatch: atomic transitions, no team, no drop, one destination

Applies only when `CC_PIPELINE_RUN_ID` is set. **(a) A walkthrough transition is one Edit, and the pre-image comes first.** Before any Step 5U item transition, copy the document to `${CC_PIPELINE_RUN_DIR}/preimage/<slug>.<seq>.md` (atomic form). Then apply the item's terminal transition — `상태`, `자율 처분`, the body reflection and every depth-2 child surfaced while processing it — in **one** Edit. Only then may a halt record be written, so the document and the halt record never describe a half-applied transition differently. **(b) No team is composed.** `팀-구성` is a permanently forbidden auto-adoption class; the roster for Step 3 is the manifest's `설계 로스터` rows when it carries any, and otherwise `### Default roster (driver dispatch)` frozen in this file — in both cases read, never chosen. Step 5U offers no `팀 토론 진행`; Step 6U spawns nothing. **(c) Nothing is dropped.** A drop's undo evidence lives outside the document; the substitute is `상태: 보류` + `사유`, which re-surfaces on the attended walkthrough's next pass. **(d) One destination.** The stage ends by emitting the freeze literal, the document path and its whole-file `sha256`, then stops — it names neither the audit nor the kickoff, because the driver's step graph already holds the next stage.

CFI-2 and CFI-3 of the base skill (Step 5 → 6 → 7 and the freeze) are the seat's under seat dispatch; under driver dispatch their unattended forms are Steps 5U–7U below, and CFI-3c's terminality holds — after Step 7U's freeze no document edit follows.

## Workflow

### Step 0: Tool loading

`ToolSearch("select:SendMessage,TaskStop")`. `Agent` is built-in. **`AskUserQuestion` is deliberately absent**: it is absent from every headless process anyway.

**Fail-loud, durably — through one site.** If a Step-0 tool cannot be loaded, if the brief fails a guard below, if the target-document guard below parks, or if the ledger stub cannot be created, park **before spawning** with `자리 id: ledger-missing`; `분류` (`tool-unavailable` / `precondition-failed`) and `관측 상세` carry the specifics. No tenth site is minted for a pre-spawn failure.

**Dispatcher resolution (once).** Read `CC_PIPELINE_RUN_ID` by name (`printenv CC_PIPELINE_RUN_ID`, never bare `env`). Non-empty → driver dispatch for the rest of this process; take `CC_PIPELINE_RUN_DIR` and `CC_PIPELINE_STAGE_ID` the same way. Under driver dispatch two more pre-spawn checks run here, and both halt with `분류: precondition-failed`:

- **Document-present guard → `document-present`.** If a *saved* document exists at the given document path, halt — Step 4's save would overwrite it, and whatever it holds is not this dispatch's. **Judge by content on the same axis as the target-document guard below** — does the ledger block parse, and does the body carry at least one `##` section? An early ledger stub is passed; a saved document is parked. Existence is not the test, because a crashed attempt leaves its own spawn-time stub at the path and the driver re-dispatches over it.
- **Roster check → `roster-missing`.** Read the manifest named by `CC_PIPELINE_MANIFEST`. If its `## 인가` section carries one or more rows of the form

    ```
    - `설계 로스터` | 역할=<slug> | 범위=<one line, exploration scope> | 모델=<opus|sonnet|haiku>
    ```

    instantiate the Step 3 roster from exactly those rows, one member per row, in order. If it carries none, instantiate `### Default roster (driver dispatch)` below, verbatim. Either way nothing is chosen by this stage. **Halt** when rows are present but one cannot be instantiated mechanically — a missing `역할`, `범위` or `모델` field, a model outside the three aliases, or two rows with the same `역할` — because a slot filled by judgment delegates `팀-구성`, a forbidden class. Rows outside `## 인가` are not read. Deviation is not tolerated and recorded; it is a stop.

### Default roster (driver dispatch)

The roster this stage instantiates when the manifest carries no `설계 로스터` row. It is frozen here so that it is read, not chosen. It follows the base skill's Step 2 shape: domain seats plus the verification seat, counted like any other row. Changing it is an edit to this file, reviewed like one, never a runtime choice.

```
- `설계 로스터` | 역할=architecture | 범위=the requirement's structure, contracts and interfaces across the affected surfaces, and the alternatives to them | 모델=opus
- `설계 로스터` | 역할=codebase-impact | 범위=the files, call sites, tests and conventions the design touches, read from the tree | 모델=opus
- `설계 로스터` | 역할=verification | 범위=settle the discussion's verifiable claims against the tree per _common/verification.md, pre-registering claim and expected result | 모델=sonnet
```

### Step 1: Read the brief and guard it

Under **driver dispatch there is no brief**: `$ARGUMENTS` is the design-document path followed by the task sentence, and the interview product is the interview record when this run has one and otherwise the task sentence plus the manifest's `## 의도` block; exploration findings and reproduction data start from the record's `## 탐색 결과` and `## 재현 근거` when it carries them, and the Step 3 team re-checks every one the design rests on and reads the tree for everything else (the base skill's Step 3 already has them do this against the codebase); the roster is the one instantiated at Step 0; the baseline is `git status --porcelain` + `git worktree list --porcelain` taken **now**, before any spawn. Skip the brief guards below and the target-document guard — the document-present guard at Step 0 is its driver-dispatch form — and proceed to Step 2.

**The interview record, when this run has one.** The kickoff freezes the person's interview answers verbatim; this stage is its reader. Resolve it by **path convention** — `$(dirname "$CC_PIPELINE_MANIFEST")/${CC_PIPELINE_RUN_ID}.interview.md`, the same `<base>/docs/pipeline-run/` directory the manifest sits in — and not from the row, so that the resolution does not depend on the very row it is about to be checked against. Then:

- **File present** — read the version token on its header comment and read it whole, and take the content sections its version lists below as the requirement input in place of the task sentence. `없음` is a value in each of them and an omitted section is not. `## 로스터` is **not** read here — the roster was instantiated at Step 0 from the manifest, and reading a second source for it is how a stage starts composing a team. Measure the file with `shasum -a 256` and compare it against the manifest `## 인가` row `- \`사전 인가\` | 인터뷰 기록=<base 기준 경로> | sha256=<전체 해시>`.
    - Version 2 (`cc-run-interview v2`): `## 과제`, `## 요구사항 문답`, `## 확인된 요구`, `## 배포 형상`, `## 탐색 결과`, `## 재현 근거`, `## 검증 선결`, `## 골격 사전 판정`.
    - Version 1 (`cc-run-interview v1`): `## 과제`, `## 요구사항 문답`, `## 배포 형상`, `## 재현 근거`, `## 검증 선결`, `## 골격 사전 판정`.
- **Any other version token, or none** → **halt before spawning**, `자리 id: ledger-missing`, `분류: precondition-failed`, with the resolved path and the token observed in `관측 상세`. A format this stage does not know is not read as "no record": filling it from the task sentence would bring back the silent shallowness the record exists to prevent.
- **The hash disagrees, or the row exists with no file, or the file exists with no row** → **halt before spawning**, `자리 id: ledger-missing`, `분류: precondition-failed`, with the resolved path, the expected hash and the observed hash in `관측 상세`, because the record's hash sits inside the frozen set.
- **Neither row nor file** → this run held no design interview. Proceed on the task sentence and `## 의도`, exactly as before.

**Reading the record.**

- An answer is read against its question's `**선택지**`. An answer equal in normal form to an offered label means that label and its description.
- `## 확인된 요구` is the requirement baseline. Where its `완료 기준` differs from the manifest's `종료 절`, the `종료 절` wins the baseline — it is what the person answered last, in the kickoff's boundary questions — and the matching line of `### 확인된 요구와의 대응` reads `해석 — 매니페스트 종료 절`.
- `없음` is a value.
- A section that is missing, or a value that does not fit its section, becomes a requirement-decision list entry `기록 형식 — <빠진 절 또는 어긋난 값>`, not a halt.
- `## 탐색 결과` and `## 재현 근거` are claims observed at the record's commit. The Step 3 team re-checks against the current tree every one the design rests on, and reads the tree for the rest, so that a kickoff's exploration never becomes design input unchecked.

The manifest's `## 의도` block stays in force either way. It is the run's intent, decided by the entry judgment; the record is the person's answers. They are not the same sentence and neither replaces the other.

Under seat dispatch `$ARGUMENTS` is the brief path, as given. Read it whole and Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1`. Guards, every one a pre-spawn park on failure: the header's version token is exactly `cc-design-brief v1` (§1.5 strict equality); the `## 대상` block's `**문서 키**` equals the header's `owner-doc=` (§1.2 — the document may not exist yet, the key is derived from the path); all eight blocks are present in order — `## 요구사항`, `## 제약`, `## 배포 형상`, `## 탐색 결과`, `## 재현`, `## 팀 구성`, `## 기준선`, `## 대상`; `## 배포 형상` carries all five field lines — `**레포**`, `**슬라이스 수**`, `**적용 위치**`, `**적용 주체**`, `**실패 시 파킹**` — where `없음` is a value and an omitted line is not; the last non-empty line is `<!-- cc-design-brief: end -->`. The brief is never edited and never staged.

**Target-document guard.** Resolve `docs/{topic-slug}.md` from `## 대상`. No file at that path is an ordinary first dispatch: proceed. Otherwise read it: a file that already exists is an earlier run's, and one reachable state is where a lawful recovery lands. **Judge by content, never by existence.** The axis is the seat's own artifact predicate: does the ledger block parse, and does the body carry at least one `##` section? **An early ledger stub is passed; a saved document is parked.**

- **A saved document** — the ledger block parses *and* at least one `##` section is present. Park before spawning: Step 4's save would overwrite it, carrying off whatever Step 5 walkthrough decisions and Step 6 refinements it already holds. Two causes reach this branch and both are faults — a first dispatch whose leg died *after* the save, and a re-dispatch that should never have been issued.
- **An early stub only** — the ledger block parses and there is *no* `##` section: the H1 and the ledger comment that the borrowed Step 3 body writes at spawn time, before any discussion has happened. Nothing has been saved over, so proceed; the spawn step adopts the stub in place. Two causes reach this branch and **neither is a fault** — a leg that died *after the spawn and before the save*, and the base skill's rung-1r re-dispatch, which is authorized on `phase: discuss` precisely to recover from that death.
- **Neither** — the file exists but its ledger block is missing or unparseable. Park, fail-closed: the guard cannot tell what it is looking at, and every other reader of this ledger takes the same posture on a block it cannot parse.

Park with `자리 id: ledger-missing`, `분류: precondition-failed`, and put the path, its byte count, its mtime and **which branch above fired** into `관측 상세`. The boundary gate is no backstop for the saved-document branch: Step 2 below exempts that exact path, so the overwrite would satisfy every assertion it makes.

### Step 2: State root and baseline

`STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/{slug}"` with `{slug}` from `## 대상`'s `**접힌 슬러그**`. The two-command boundary gate's assertion 1 uses the brief's `## 기준선` as its baseline — never re-derive it; the tree has already moved. The exempt paths are `docs/{topic-slug}.md` and `docs/design-brief/{slug}.md`. Declare `-run-` as assertion 2a's exception pattern.

Under driver dispatch `STATE="${CC_PIPELINE_RUN_DIR}/design/{slug}"` with `{slug}` derived from the document path per `sidecar.md` §1.1 (`mkdir -p` it — the run directory exists, this subtree does not), the baseline is the one taken at Step 1, and the only exempt path is the document itself. The `-run-` exception pattern is what keeps a sibling segment's worktree from failing this stage's gate.

### Step 3 · Step 4: Interim body

**Read `${CLAUDE_SKILL_DIR}/../design/SKILL.md` from `### Step 3: Design Discussion (English, internal only)` through Step 4's `Save the design document …` bullet** and follow it, with these substitutions:

1. every `AskUserQuestion` terminus → a park at one of the nine sites (CFI-U0);
2. interview product, exploration findings, reproduction data and the approved roster come from the brief's blocks, not from any conversation;
3. the boundary-gate baseline is the brief's `## 기준선`;
4. the post-save Korean notices, the aggregate line and the presentation are **not** emitted — they become the three blocks of `presentation.md` (Step 5 below);
5. before `team-cleanup.md` is applied, and inside the window in which each ledger row is flipped to `done`, the witness corpus is made durable (below);
6. (driver dispatch only) the interview record governs, and what the team decides in its place is listed:
    - every member prompt carries the record's absolute path and the sentence "Read it whole; any summary in this prompt is a convenience and the record governs.", and tells the member to write a `## 요구 결정` section in its witness — the requirement-level decisions it would take that the record does not answer;
    - synthesis writes `## 팀이 정한 요구 결정` immediately after `## 재현·근본원인` (first, when the document has none) and before `## 합의된 아키텍처`, in the form of `### The requirement-decision list (driver dispatch)` below;
    - a requirement-level choice the record left open is decided and listed, and is never written as an unresolved entry;
    - a record hypothesis (`가설(추측)`) the team could not reproduce is listed as `재현 가설` and creates no Tier-2 unresolved pointer.

Under driver dispatch substitutions 2 and 3 read their inputs from Step 0 and Step 1 above instead of a brief — substitution 2's interview product is the interview record's sections Step 1 took when Step 1 resolved one, and the task sentence plus `## 의도` when it did not — and substitution 4 does not apply: after the save the stage writes no `presentation.md` and continues into Step 5U. Substitution 6 applies under driver dispatch only.

When that body is relocated into this file, this section is replaced by it.

**Durable witness corpus.** Copy every `{role-slug}.{round/phase}.md` — phase witnesses included, not only rounds — into `$STATE/witness/`, together with each member's rendered dispatch prompt as `witness/{role-slug}.prompt.md` (the prompt is the whole definition of a role; the ledger carries a one-line label) and `witness/INDEX.md` with one row per `(role-slug, round/phase)` giving byte count and `sha256`, so a complete corpus is distinguishable from one with holes. The copy happens inside the `done`-flip window of the row it belongs to. **The runtime's own subagent transcript store is never used as the corpus**: synthesizing from raw transcripts instead of published witnesses is the manipulation the protocol names and forbids; the lawful route to the same information is `SendMessage` to that member for a fresh witness.

**`leg.json` updates.** On every ledger flip rewrite `heartbeat_at` to now (atomic form; diagnostic only). Write `state: parked` after `park.md`. **Never write `state: done`**: it is the seat's consumption mark, and a leg-written `done` would switch the seat's pull-check off before it saw `presentation.md` or `coherence.md` — after writing either artifact, leave `state` as it is. Every other field — `session_id`, `redispatch_count`, `brief_sha256`, `leg_out`, `leg_err`, `prior_session_ids` — is the seat's and is never touched here.

### Step 5: `presentation.md` (seat dispatch only)

Written last, because it is part of the seat's artifact predicate. Header `<!-- cc-design-presentation v1; writer=design-discuss-unattended; reader=design; slug=<slug> -->`, then `## 고지` (the two Korean notices — save complete, cleanup done), `## 검증 집계` (*"구현 시 검증 항목 N건이 기록되었습니다 — /implement 시작 시 우선 검증됩니다."* when the section is non-empty, otherwise `없음`), `## 결과` (the presentation text). Atomic form. Then end the turn (CFI-L2). Under driver dispatch this step does not run; the stage enters Step 5U in the same turn.

## Skeleton predicate (driver dispatch)

The attended walkthrough asks a person about every unresolved item. The unattended one may settle an item itself only when settling it **does not change the skeleton**, and "skeleton" is not a new concept:

> **Skeleton = the document's binding tier + `## 구현 슬라이싱` + the run's frozen set.** An item's disposition leaves the skeleton unchanged when the write that applies it **fits one enumerated write form mechanically**. If it does not fit, it is skeleton.

The binding tier is the `Binding` list of `${CLAUDE_SKILL_DIR}/../implement-unattended/SKILL.md` → `## Constraints`, keyed on section identity and not on content (`## 구현 슬라이싱` is on that list). The frozen set is what the manifest's `구속 다이제스트` serializes — goals, termination clauses, targets, rule settings, pre-authorizations, auto-adoptions, deadline. The enumerated write forms are: **W1 · W2 · W3** of that same file (grade flip, verification note, store-existence note inside a `### R<n>`), and the **walkthrough transition** — inside one entry of `## 미해결 이슈 / 트레이드오프`: the `상태` line, a `**자율 처분**: <one line>` field, one paragraph of body reflection appended to that entry, and depth-2 child entries in the base skill's encoding. Three checks, in this order, on every disposition before it is written:

1. **Form** — does the write fit one enumerated form, byte-checkably (the snapshot-diff gate of the implement arm, applied to this document)? Rewriting a heading, an architecture sentence, a decision sentence, a slice declaration, or retiring or re-grading an `### R<n>` fits none.
2. **Frozen set** — does the write intersect anything the manifest froze (a target, a cutpoint, a termination clause, a declared file set)? A `해결` whose body reflection would move a slice's declared files does.
3. **Inherited grade** — does the attended skill mark this exact point `등급 2` for a reason other than "a person must confirm" (a value judgment with no authored standard, a risk acceptance)? Then the standard that would let a stage choose does not exist.

Any check ambiguous → **fail-closed**: the item is skeleton, and the disposition is the `skeleton` halt with the item, the proposed write and which check was ambiguous in `관측 상세`. A disposition that passes all three is a `설계-쟁점` judgment at `등급 1`, emitted per `### Per-grade disposition`. **Do not classify by `Category` (UD/UC/UA/UR)**: that field carries out-of-vocabulary values, and the form test has no such input.

### Step 5U: Unattended walkthrough (driver dispatch)

The base skill's Step 5 without a person. Read `### Step 5: Unresolved Issue Walkthrough` of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` for the queue contract, the encodings, the `상태` vocabulary and depth management; they apply as written. What differs:

- **Queue init.** Same heading regex, same LAST-match rule, same depth-2 and drop-uncertain promotions. **0-match → halt `step5-zero-section`**: the attended menu there (add the section / skip / abort) is a person's choice and none of its three options has an authored standard. 0 entries under a present heading → proceed to Step 6U.
- **Per item.** (1) Auto-investigation, read-only, as the base skill defines it per category, hard limits included. (2) **Skeleton predicate** above on the disposition the investigation supports. (3) If skeleton → halt `skeleton` (CFI-L4(a): pre-image first, and the halt is written only after any transition already begun has been completed in its single Edit). If not skeleton → write the pre-image `${CC_PIPELINE_RUN_DIR}/preimage/<slug>.<seq>.md` (`seq` = the item's position in the queue, zero-padded to three digits), then apply the transition in **one Edit**: `상태: 해결` with the body reflection and `**자율 처분**: <the standard applied>`, or `상태: 보류` with `사유: 무인 워크스루 — 사용자 확인 필요 (<YYYY-MM-DD>)` when the investigation is inconclusive; every depth-2 child surfaced while processing this item is recorded in the same Edit as `(깊이: 2)` + `상태: 보류` + `사유: depth-2 follow-up (parent …)`. Record each `해결` for the single bundled judgment of `### Per-grade disposition` — its markers are emitted once, in the terminal message, never once per item.
- **No menu.** There is no `팀 토론 진행` (CFI-L4(b)), no `더 논의`, no dropped-confirm prompt: a UC false positive is `상태: 보류` + `사유: 무인 워크스루 — false positive 후보, 사용자 확인 필요` (CFI-L4(c)). A UR whose investigation supports `재설계` is `상태: 보류` + `사유: 재설계 필요 — 라우터 라우팅` and is Step 6U's input.
- **Pre-image retention.** `preimage/` must survive until the run's **last stage** has terminated — every `**판단 되돌리는 법**` this stage emitted points at it. The shared contract's "the run directory is deliberately not durable" is about **process handles** (`*.pid`, `*.pgid`, `*.rc`, `*.start`, transcript pointers), not `preimage/`. Bound: one file per transition, at most **64** per document slug; past 64 the oldest is removed and the removal is stated in the terminal message.

### Step 6U: Pass-through refinement (driver dispatch)

Step 6U is a **destination** — Step 5U's `재설계` items and Step 4's two escalation options route here — and it redesigns nothing: it leaves every such item at `상태: 보류` + `사유: 재설계 필요 — 라우터 라우팅`, so the router's redesign rung (`/cc-cmds:design-reconverge`) or the morning's person picks it up. No team is spawned (CFI-L4(b)), nothing is asked, and the step ends in the same turn into Step 7U.

### Step 7U: Coherence, slicing self-check, residual ladder, freeze (driver dispatch)

The jobs below run in this order, then the freeze; the ladder needs final R-items and writes, and nothing follows the freeze (CFI-3c of the base skill).

1. **Coherence pass.** Resume this session's Step 3 team by `agentId` (the base skill's permitted resume #3 — this is the one session that can address them), phase token `coherence`, `epoch` re-stamp and `witnessNonce` per the base skill's Step 7 and the protocol, one round, collect by witness under CFI-U0. Apply each finding directly to the document. **A finding that contradicts a converged decision → halt `step7-coherence-conflict`**, naming the finding and the decision. A finding that the document departs from a recorded interview answer is not such a contradiction: it is listed by the requirement-decision job below as `벗어남 — 문 <n>`. Clear each consumed `[Step 7 정합 점검 대상]` note. Then apply `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`.
2. **Slicing self-check** (only when `## 구현 슬라이싱` is present): the base skill's two rules — declared ⊇ actual, and `SKILL.md` implies `README.md`. Repair the declaration in place; a repair that needs a decision the authors did not make → halt `slicing-unknown`.
3. **Requirement-decision list.** Re-read the whole document against the interview record and its `## 확인된 요구`, and fill `### 확인된 요구와의 대응`. A requirement-level decision not yet in `## 팀이 정한 요구 결정` is added, whether it came from synthesis, a Step 5U `해결`, a coherence correction or a slicing repair. A requirement-level entry of `## 미해결 이슈 / 트레이드오프` left at `상태: 보류` is listed as `미결 — 보류로 동결`. A decision that departs from a recorded answer is listed as `벗어남 — 문 <n>` and never goes to `step7-coherence-conflict`; the run does not stop for it. This job follows the coherence pass and the slicing repair because it collects what they decided, and precedes the ladder because the ladder follows the last write.
4. **Residual ladder.** For every `### R<n>` still at `**검증 등급**: 구현 시 검증`, descend until one rung settles it:
    - **Rung 1 — self-document check** (read-only, no external contact): is the item's premise still true against the rest of the frozen-to-be document? A refuted premise is **evidence only** — retiring the item fits no write form, so the item is escalated as a `설계-골격` judgment (`등급 2`) with the evidence, and nothing is written.
    - **Rung 2 — declared-store lookup**: if the recipe names a credential, `credentials.sh store-has <name>` (`${CLAUDE_SKILL_DIR}/../../orchestrator/credentials.sh`, through the gate; the manifest's `사전 인가` targets this spelling because `test -f` has no grade row). 있음 → write **W3** (form and diff gate in `implement-unattended/SKILL.md`), which records existence and moves no value anywhere; 없음 → the item stays blocked, evidence only.
    - **Rung 3 — reachability**: **off by default**, because every probing client is graded `외부상태변경` and the `design` settings variant denies `WebFetch`, so this rung costs the very cutpoint it would verify. It runs only when the manifest opens it for that item by a `사전 인가` row naming the item; then the result is evidence only.
    - An item no rung settles → halt `ladder-unsettled` **as a `설계-골격` judgment**: the halt record's `질문 문면` is the item and its blocker, `관측 상세` carries the rung-1 and rung-3 evidence. Halt after all items have been walked, not at the first, so the record lists every unsettled item at once.
5. **Freeze.** Write `**상태**: 동결됨` on the document's status line (this is the last document edit). Then emit, in the terminal message: the freeze literal *"설계 문서를 동결했습니다."* on its own line — byte-identical to the first sentence of the attended skill's freeze notice, and the driver's artifact predicate reads exactly it — followed by the document path and its whole-file `sha256`, then the one bundled judgment of Step 5U when any `해결` was applied. Name no next step (CFI-L4(d)). End the turn.

### The requirement-decision list (driver dispatch)

`## 팀이 정한 요구 결정` lists the requirement-level decisions the team took because the interview record did not answer them, so that the person reads what was decided in their place before reading how it is built. Only a driver-dispatched stage writes it.

- **Entry.** One heading `### 요구 결정 <n>. <제목>` and, under it, four bold-key fields: `**정한 것**` · `**기록과의 관계**` · `**근거**` · `**버린 대안**`. The `### 확인된 요구와의 대응` block in the same section is not an entry.
- **`**기록과의 관계**` is a closed vocabulary**: `미답 — <기록의 절 | 문답 밖>` · `위임 — 문 <n>` · `위임 — 문 <n> (선택지 설명)` · `해석 — 문 <n>` · `벗어남 — 문 <n>` · `재현 가설` · `킥오프 탐색 확정 — 확인된 요구에 없음` · `미결 — 보류로 동결` · `기록 v1` · `기록 없음` · `기록 형식 — <…>`.
- **`### 확인된 요구와의 대응`** carries one line per line the kickoff read back: `- <읽어 준 줄, 축자> → 그대로 | 해석 — … | 벗어남 — …`.
- **First line.** An empty list is `없음`. Under a v1 record the section opens with 「인터뷰 기록이 v1 이라 확인된 요구·탐색 결과·제시한 선택지 칸이 없습니다.」; with no record, 「이 런에는 인터뷰 기록이 없습니다 — 과제 문장과 의도로 설계했습니다.」.
- **Tier.** The section is reference tier and carries no `상태`, `검증 등급` or `근거 등급` key. Its heading holds neither `미해결` nor `이슈`, so Step 5U's section regex does not reach it.

### Resumed turns

- **Park answer.** A message of the form *"park 질문 `<자리 id>` 에 대한 사용자의 답은 다음과 같다: …"* resumes the workflow at that site with the answer applied. The neutral wording is the seat's; treat the turn as an artifact turn.
- **Coherence pass.** A message carrying the final document's path and the `[Step 7 정합 점검 대상]` notes: re-read the ledger from disk → re-stamp `epoch` on every Step-3 row (`max(disk epoch, 0) + 1`, one Edit per row, one contiguous window), writing each row's `coherence` `witnessNonce` **before** the resume and flipping `round/phase` **after** it → resume this session's Step 3 team by `agentId` (the base skill's permitted resume #3, one round) → collect by witness with Case-1 / Case-2 handling under CFI-U0 → write `$STATE/coherence.md` (header `<!-- cc-design-coherence v1; writer=design-discuss-unattended; reader=design; slug=<slug> -->`, one finding block per item) and end the turn **without editing the document's prose**. **Memoryless-resume watch**: if a resume's tool result carries `(no prior transcript)`, that member was not resumed — treat it as Case-2 and do not count it toward `resumedMessageCount`.

## Constraints

- NO code modifications. The observation & verification carve-out of the base skill's `## Constraints` applies verbatim.
- Inter-agent communication is English.
- Team members are nameless `Agent` sub-agents (`subagent_type: "claude"`, `run_in_background: true`, no `name`), resumed by `agentId`, self-terminating on return.
- **Every member prompt carries CFI-U0 verbatim** plus this sentence: a member never emits a banner by any route — not a notification tool, not a script, not by asking someone else to emit one on its behalf — and reports completion and blockage to its spawner by witness file and return value only.
- Call external commands directly, never inside `bash -c`.
- **Never reach a notification surface** and **never write a pipeline sidecar** (CFI-L3).
- **Under driver dispatch every Bash command goes through `gate.sh exec`**, with the `--reach` discipline of `implement-unattended`'s CFI-U7 — declare where an act lands (`런로컬`·`기기전역`·`dev`·`prod`·`협업`·`배포트리거`·`미상`), prefer `미상` to a guess, read pipeline variables by name and never with bare `env`, and on exit 11 neither retry nor re-declare. This includes every member the Step 3 team spawns: the gate hook is inherited by the stage's children, so a member's plain Bash is refused rather than silently unrecorded. Under seat dispatch no gate engages, as stated in the blast-radius paragraph above.
- **The design document's only writes under driver dispatch** are: the Step 4 save; Step 5U transitions and their pre-images; Step 7U's coherence corrections, slicing repair, the `## 팀이 정한 요구 결정` entries and its `### 확인된 요구와의 대응` block, W3 lines and the freeze line. `preimage/`, `halt/` and `design/{slug}/` under `CC_PIPELINE_RUN_DIR` are the only other writes.

Task: $ARGUMENTS
