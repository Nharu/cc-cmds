---
name: design-discuss-unattended
description: 설계 세션의 Step 3 토론과 Step 4 종합·저장을 좌석 없이 돌리는 다리 (무인 — 질문은 park 기록으로)
when_to_use: autopilot 드라이버가 아니라 `design` 리드 좌석이 Step 2 승인 뒤 `claude -p` 로 파견할 때. 사람이 직접 부르지 않는다
disable-model-invocation: true
usage: "/cc-cmds:design-discuss-unattended <brief-path>"
options:
    - name: "<brief-path>"
      kind: positional
      required: true
      summary: "`docs/design-brief/{slug}.md` — 좌석이 쓴 인터뷰 브리프. 메인 워크트리 기준 경로."
notes: "halt 기록을 쓰지 않는다 — 이 다리는 런 디렉터리를 갖지 않으며 park 는 상태 루트의 `park.md` 로 돌아간다."
---

Run Step 3 (design discussion) and Step 4 (synthesis through the save) of `/cc-cmds:design` in a headless session, from an interview brief, **without ever asking a human**.
Team communication is English. Everything written for the user — the saved document, the presentation blocks, a park record — is Korean.

## What this sibling is, and what it is not

This is the **leg** of `/cc-cmds:design`: the seat (the conversation with the human) runs Step 1 and Step 2, dispatches this skill with `claude -p`, and takes back over at Step 5. The boundary is Step 3 + Step 4 through the save, and it is forced rather than chosen — the Step 4 fidelity pass resumes the Step 3 team by `agentId`, and an agent id is addressable only from the session that spawned it, so Step 3 and the pass cannot straddle a session. The exit is the synthesis-terminal line: after the save no teammate message is permitted, so the team has no further use here.

It follows the landed `design-audit` / `design-audit-unattended` pair: a separate file so that "this arm has no human-question surface" is a whole-file predicate `scripts/lint-unattended-surfaces.sh` can check. It differs from its siblings in one thing its `when_to_use` states: **the `design` seat dispatches it, not the autopilot driver**, so it owns no run directory and writes no halt record there.

`references/` — none. This arm Reads Step 3 and Step 4 out of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` (see *Interim body* below). Rules 1 and 2 of the surface lint prove the file carries no instruction to ask and no reachable notification call; they do not prove the model never asks in prose and answers itself. That residual is not closed here.

**The leg is not a clean room.** It loads the plugin and therefore the plugin's hooks, and it inherits the global and repository instruction layers and **follows** them. What the split buys is a clean *conversation*, not a blank instruction layer — a brief that carries repository conventions is redundant, and a brief that assumes the seat's context is missing. The notification-class hooks load too and are all closed in a headless leg; this arm's "no notification" property rests on those gates as well as on this text.

**Its permission posture is `bypassPermissions`, and the blast radius is written down here so that "a human decision already taken" is a checkable fact rather than an assertion.** Without any confirmation, the leg and every member it spawns can write any path the user account can write — not only `docs/{topic-slug}.md`, the state root and the witness scratch directories this workflow names — run any Bash command, including dependency installs, `git worktree add` / `git worktree remove --force` and the verification carve-out's `git checkout -- . && git clean -fd` reset, fetch from the web, and spawn further agents. No pipeline gate engages: the seat's launch line sets no `CC_PIPELINE_*` variable, so the gate hook that fences autopilot stages does not apply, and "NO code modifications" and the carve-out bind by instruction alone. The seat disclosed exactly this, as one line of the Step 2 proposal the user approved, and recorded it in `leg.json` as `permission_posture` and `posture_approved_at`; this arm never touches those two fields.

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

The first ten fields are the field set of the pipeline halt record (`cc-pipeline-halt v1` in `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4), verbatim; the last three are this arm's. Write it with the atomic form of `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` §1.3 (same-directory temp, then rename); the closing fence is the terminator. Record the question, every option label and every description **verbatim** — the seat holds none of the discussion and renders the record without composing anything, so a summary here is a question the user never actually gets. One record carries at most **four** questions. `재호출 명령` is recorded and **never executed** by this arm or by anything downstream. **No halt record** under any run directory: this leg does not own a run.

**`자리 id` is a closed set of nine.** `ledger-missing` (the ledger stub is missing or unparseable before spawn — parked immediately) · `case2-respawn-dead` (a Case-2 same-round respawn also died — stop point) · `unavail-streak` (`unavailStreak ≥ 2`, a witness `output_file` that vanished — stop point) · `empty-streak` (`emptyStreak ≥ M` — stop point) · `growth-streak` (`growthStreak ≥ G`, a member alive and babbling but publishing no witness — stop point) · `case1-thin-witness` (protocol Case-1, two consecutive thin witnesses — bundled) · `fidelity-case1` (fidelity-pass Case-1, twice — bundled) · `fidelity-decision-reopen` (a decision-reopen's second re-convergence failure — bundled) · `sweep-claim-2nd-fail` (the pre-save sweep's same claim failing a second time — bundled). The interrupted-save slug ambiguity has no site: the slug is a field of the brief. Eight of the nine are second-failure or debounce-threshold escalations and one is a pre-spawn check, so a **normal run parks zero times** — and that claim now carries load: it is what removes the park term from the cost model, so **if a park is ever observed on a normal run the cost model is void.** Maintenance duty: adding a site requires justifying it against the price of one park, and **a first-failure site is never added** — one such addition turns "zero on the normal path" into "once per run" without anyone deciding it.

### Per-grade disposition

The base skill marks its ask points with a judgment grade (`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`). This arm's disposition is per grade:

- **`등급 0`** — no disposition is needed; an already-written rule determines the answer.
- **`등급 1`** — none of this arm's nine sites is reachable at this grade: every one is a second-failure or debounce escalation with no authored standard that picks an option. Adding a site marked `등급 1` takes on the closed-set maintenance duty above, and a choice with no `되돌리는 법` is not `등급 1` whatever its mark says.
- **`등급 2`** — write the park record and leave at the stop point (CFI-L1).

## Control-Flow Invariants

These rules govern how this leg stops and what it hands back, and MUST stay near the top of this file: post-compaction reattaches only the first ~5K tokens with priority, and a summarized-away rule here makes the leg either ask in prose or exit mid-round.

### CFI-U0 — There is no human-question surface

`AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its escalation cases terminate in `AskUserQuestion`, **this arm resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule. Here a halt is the park record above, and its `자리 id` is one of the closed nine.

### CFI-L1 — Park at a stop point, never mid-round

Detect immediately; emit after the current round's wait has ended — every live member has published its witness, or the reconcile ladder has returned a death verdict. Only the pre-spawn site `ledger-missing` parks at once, because there is no team to wait for yet. The reason is runtime, not caution: print-mode wind-down waits for background members up to the ceiling and then kills them, so a leg that tries to exit mid-round is blocked for up to an hour and kills its members at the end of that wait. A ceiling kill is not destructive — a killed member resolves to a resumable state with its partial work — so what this rule buys is wall-clock and determinism, and it is not relaxed on recoverability grounds. **`TaskStop` followed by a park is a dead end**: a stopped agent resolves as `success:false` and is lost for good. The four bundled sites are emitted once, immediately before the save.

### CFI-L2 — The exit is the synthesis-terminal line, and a resumed turn writes no prose

Normal termination is: save → durable witness corpus (inside the `done`-flip window) → `presentation.md` → end of turn. The leg never emits the seat's user-facing tail (the two Korean notices, the aggregate line, the presentation) — it composes them into `presentation.md` for the seat to render. On a resumed coherence turn the leg writes the ledger block only and returns its findings in `coherence.md`; it never edits the document's prose.

### CFI-L3 — No notification, no halt record, no sidecar

This arm never reaches `PushNotification`, `notify.sh` or `terminal-notifier` — nor does any member it spawns. It writes no halt record under any run directory, and it never writes `pipeline-grant` or `pipeline-run`. Its only channels toward a human are `park.md` and `presentation.md`.

CFI-2 and CFI-3 of the base skill (Step 5 → 6 → 7 and the freeze) are the seat's and do not exist in this arm.

## Workflow

### Step 0: Tool loading

`ToolSearch("select:SendMessage,TaskStop")`. `Agent` is built-in. **`AskUserQuestion` is deliberately absent**: it is absent from every headless process anyway, and enumerating it would make this skill fail-loud at Step 0 forever.

**Fail-loud, durably — through one site.** If a Step-0 tool cannot be loaded, if the brief fails a guard below, or if the ledger stub cannot be created, park **before spawning** with `자리 id: ledger-missing`; `분류` (`tool-unavailable` / `precondition-failed`) and `관측 상세` carry the specifics. No tenth site is minted for a pre-spawn failure.

### Step 1: Read the brief and guard it

`$ARGUMENTS` is the brief path, as given. Read it whole and Read `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` `## 1`. Guards, every one a pre-spawn park on failure: the header's version token is exactly `cc-design-brief v1` (§1.5 strict equality); the `## 대상` block's `**문서 키**` equals the header's `owner-doc=` (§1.2 — the document may not exist yet, the key is derived from the path); all eight blocks are present in order — `## 요구사항`, `## 제약`, `## 배포 형상`, `## 탐색 결과`, `## 재현`, `## 팀 구성`, `## 기준선`, `## 대상`; `## 배포 형상` carries all five field lines — `**레포**`, `**슬라이스 수**`, `**적용 위치**`, `**적용 주체**`, `**실패 시 파킹**` — where `없음` is a value and an omitted line is not; the last non-empty line is `<!-- cc-design-brief: end -->`. The brief is never edited and never staged.

### Step 2: State root and baseline

`STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/{slug}"` with `{slug}` from `## 대상`'s `**접힌 슬러그**`. The two-command boundary gate's assertion 1 uses the brief's `## 기준선` as its baseline — never re-derive it; the tree has already moved. The exempt paths are `docs/{topic-slug}.md` and `docs/design-brief/{slug}.md`. Declare `-run-` as assertion 2a's exception pattern.

### Step 3 · Step 4: Interim body

**Read `${CLAUDE_SKILL_DIR}/../design/SKILL.md` from `### Step 3: Design Discussion (English, internal only)` through Step 4's `Save the design document …` bullet** and follow it, with five substitutions:

1. every `AskUserQuestion` terminus → a park at one of the nine sites (CFI-U0);
2. interview product, exploration findings, reproduction data and the approved roster come from the brief's blocks, not from any conversation;
3. the boundary-gate baseline is the brief's `## 기준선`;
4. the post-save Korean notices, the aggregate line and the presentation are **not** emitted — they become the three blocks of `presentation.md` (Step 5 below);
5. before `team-cleanup.md` is applied, and inside the window in which each ledger row is flipped to `done`, the witness corpus is made durable (below).

When that body is relocated into this file, this section is replaced by it.

**Durable witness corpus.** Copy every `{role-slug}.{round/phase}.md` — phase witnesses included, not only rounds — into `$STATE/witness/`, together with each member's rendered dispatch prompt as `witness/{role-slug}.prompt.md` (the prompt is the whole definition of a role; the ledger carries a one-line label) and `witness/INDEX.md` with one row per `(role-slug, round/phase)` giving byte count and `sha256`, so a complete corpus is distinguishable from one with holes. The copy happens inside the `done`-flip window of the row it belongs to. **The runtime's own subagent transcript store is never used as the corpus**: synthesizing from raw transcripts instead of published witnesses is the manipulation the protocol names and forbids; the lawful route to the same information is `SendMessage` to that member for a fresh witness.

**`leg.json` updates.** On every ledger flip rewrite `heartbeat_at` to now (atomic form; diagnostic only — no step compares it, the seat's progress reading uses the file's mtime). Write `state: parked` after `park.md`. **Never write `state: done`**: it is the seat's consumption mark, and the base skill's pull-check is active only while `state` is `pending` or `parked`, so a leg-written `done` would switch that check off before the seat ever saw `presentation.md` or `coherence.md` — after writing either artifact, leave `state` as it is. Every other field — `session_id`, `redispatch_count`, `brief_sha256`, `leg_out`, `leg_err`, `prior_session_ids` — is the seat's and is never touched here.

### Step 5: `presentation.md`

Written last, because it is part of the seat's artifact predicate. Header `<!-- cc-design-presentation v1; writer=design-discuss-unattended; reader=design; slug=<slug> -->`, then `## 고지` (the two Korean notices — save complete, cleanup done), `## 검증 집계` (*"구현 시 검증 항목 N건이 기록되었습니다 — /implement 시작 시 우선 검증됩니다."* when the section is non-empty, otherwise `없음`), `## 결과` (the presentation text). Atomic form. Then end the turn (CFI-L2).

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

Task: $ARGUMENTS
