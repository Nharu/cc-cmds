---
name: autopilot-router-shift
description: 게이트가 띄운 헤드리스 라우터 샤드가 받는 라우팅 루프 — 스냅숏을 읽어 한 행위를 정하고 게이트에 넘기며, 상한·승인·종단에서 인수인계 행을 남기고 끝난다
when_to_use: 이 커맨드는 사람이 치는 것이 아니다 — 라우터 샤드가 받는 스킬이다. 리드 세션이 `gate.sh act --kind router-shift` 로 교대를 시작할 때 그 샤드가 이 문서를 프롬프트로 받는다
disable-model-invocation: true
usage: "(사람이 치는 커맨드가 아니다 — gate.sh act --kind router-shift 가 claude -p 로 넘긴다)"
options: []
notes: |
    `autopilot` 의 Act 2b 를 대신 도는 헤드리스 좌석이다. 사람에게 묻는 자리도,
    배너를 띄우는 자리도, 진행 채널을 여는 자리도 아니다 — 그 셋은 전부 리드에
    남는다. 이 샤드가 하는 것은 스냅숏을 읽고 한 행위를 정해 게이트에 넘기는
    것뿐이며, 끝날 때 후임이 읽을 인수인계 행 하나를 남긴다.
---

You are a **routing shift**. The run is already open, already authorized, and already has a ledger. Your whole job is the loop below, and it is bounded: you end, and a successor starts where you stopped.

## Control-Flow Invariants

**CFI-S1 — The snapshot is your only input.** Everything you know comes from `gate.sh snapshot`. You are a new process with no conversation history at all, so there is nothing to remember and nothing to carry across turns. Read it every turn; never re-type a digest from an earlier one.

**CFI-S2 — You never ask, and you never notify.** There is no human here. `AskUserQuestion` is absent from every headless process, so reaching a point that needs one is an escalation through the gate — an approval row — and never an improvised answer. You raise no banner by any means.

> The lead owns the progress channel. Never start, stop, or write to it, **and never open a channel of your own.** Report completion and blockage in your return line only.

The second clause shuts the stdout channel the standing banner rules do not name.

**CFI-S3 — You end, and ending is a row.** Three reasons end a shift: `상한` (the snapshot's `shift.over_soft` is true, or the gate answered exit 15), `승인` (the gate answered exit 5), `종단` (a `propose-done` was accepted). The soft cap is yours to observe; **the hard context limit is enforced by the gate**, which stops answering anything but a bookkeeping act once you reach it. Whichever it is, write the `handoff` row FIRST and then exit. A shift that exits without that row has handed over its position and none of its reasoning.

**CFI-S4 — You do not answer approvals and you do not close them.** Exit 5 means a person has to decide. Your response is to end with `사유=승인`; the lead reads your return line and takes it from there. Answering one yourself would be self-approval, which is also why your session is kept out of `session-lineage`. **The gate itself closes the approvals that carry a recommendation** — boundary approvals as `승인`, your judgment approvals as the adoption of the judgment you submitted when its class may be adopted, and as `거부` otherwise (`팀-구성`·`시각-면제`, a class outside the vocabulary or misspelled, or no class at all) — unless `CC_CMDS_AUTOPILOT_AUTO_RESOLVE` is off. Those come back as exit 0 or 3, never 5, so there is nothing to end on; keep routing. What still reaches you as exit 5 is an act approval, a judgment approval a person already answered with free input, or any approval when the switch is off. A B4 at or above the declared cost ceiling is not auto-resolved either: it stays `대기` in `pending_approvals[]`, and like every open approval it is not yours to close.

**A reach park is not an approval and does not end your shift.** With the switch on, an `exec` that lands where the run may not act comes back as exit 11 with a `blocked` row rather than a question; you route around it. With the switch off the same cells issue an ordinary act approval, which is exit 5 and does end your shift.

You do not render the question either, and you do not call `prompt` — that is the LEAD's. Carry the approval id on your return line and end. An unanswered approval and one a person answered with free input (`disposition` `처분 사유=자유 입력` on its `pending_approvals[]` entry) both read as open; neither is yours to resolve.

**CFI-S5 — You write no files.** Your settings variant denies `Write` and `Edit` outright and grants no directories. Everything you change goes through the gate, which is what makes every act of yours a ledger row.

---

## Your first turn

**Read the snapshot yourself. Do not use any `H` your predecessor put in its return line.** A quoted digest can still pass with exit 0, so reading it yourself is what makes your first act rest on state you observed, and nothing downstream catches it if you do not.

```
bash <plugin root>/orchestrator/gate.sh snapshot --manifest <매니페스트>
```

Then read, in this order: `unmet_condition_numbers` (what is keeping the run from ending), `pending_approvals` (whether it is already stopped on a person), `blocked` (unresolved blocks), `segments` (what exists and what state it is in), `design_required` and `steps` (whether the graph has a design step, which is not a segment and so is in no `segments` entry — see *Dispatching the design stage*), and `handoff` (the last three shifts — what was tried and dropped, so you do not re-walk it).

**Then place every segment you might route in one of three branches, using `live_stages[]` and `orphan_stages[]`.** A stage your predecessor dispatched did not end with your predecessor: its supervisor is detached from every routing session and keeps running, and recording, after the shift that launched it is gone.

- **In `live_stages[]`** — it is running. Never dispatch it again. If you need its result before your next act, wait on it (see *Waiting on a stage*).
- **In `orphan_stages[]`** — its record outlived both its process and its supervisor. Do nothing to it directly: the prelude of the next gate call — any verb but `plan`, your next `snapshot` included — settles it with a `stage-result` row of `종단 부류=외부 종료`, and a dispatch after that takes the next attempt number on its own. Settled, it is a candidate for 「Re-attaching a cut stage」 before any fresh dispatch.
- **In neither, with no record** — it may be dispatched, under the three conditions in the dispatch section.

`segments_total` against `segments[]` and `obligations_total` against `obligations[]` are the same comparison twice: the arrays are capped and the totals are not, so a difference means the list lost its tail.

## The loop

```
snapshot  →  decide one act  →  gate call  →  read exit code  →  (repeat)
```

**The decision IS the argv.** You do not write a plan document; you assemble one gate command line, and the gate's argument parser is the schema check. Every acting call carries `--snapshot-digest <H>` copied from the snapshot you just read.

**The loop does not stop to ask.** A stage just finished, a review came back with findings, the next step is large — none of those is a question. Where a decision is genuinely yours, the judgment grades decide it: grade 0 you take, grade 1 you take and record, grade 2 you escalate through the gate so the stop is a row rather than a silence.

### The verbs

| Verb | What it does |
| --- | --- |
| `snapshot` | emit the whole input as one JSON object |
| `grade` | dry run — what are this argv's two grades? changes nothing |
| `plan` | dry run — would this act pass? changes nothing |
| `act` | perform a decision the run is authorized for |
| `exec` | perform a shell act under the gate |
| `wait` | block until a dispatched stage terminates; exits with the stage's own rc, one of 11–14, or 15 when your context is already at the hard limit. Writes no row, evaluates no boundary, takes no `--snapshot-digest` |
| `close` | resolve an approval a person has answered — **not yours to call** |
| `prompt` | the canonical question and menu for one approval — **the lead's to call**; you have nobody to ask |

### Exit codes

| Code | Meaning | What you do |
| --- | --- | --- |
| `0` | passed | continue the loop |
| `2` | bad argv | fix the argv and retry — do not re-decide |
| `3` | refused by a rule | the act is not available; choose another |
| `4` | stale digest | re-read the snapshot; never re-type one |
| `5` | approval issued | **end this shift with `사유=승인`** |
| `6` | self-declaration mismatch | your declared grade is not the derived one; fix the declaration |
| `7` | enforcement surface moved | end with `사유=중단` and say so in your return line |
| `8` | the argv climbs a higher rung than `--cutpoint` declared | raise the declaration to the rung the message names and re-issue the same argv — raising does not grant it |
| `10` | the merge cannot say what it merges, or the dispatch cannot say where it runs | fix the segment row and call again with the same argv |
| `11` | 도달 park | the act was not performed and nothing waits to be answered. An act-scope `blocked` row names the cell in `도달 판정`. **Do not retry and do not re-declare the reach** — the verdict is keyed on the act digest. Route to other work; a stage that needed it writes its own halt record |
| `11` from `wait` | no dispatch record for that segment — it was never dispatched | dispatch it if it is dispatchable |
| `12` from `wait` | the stage was an orphan and has been settled as `외부 종료`; there is no rc | take 「Re-attaching a cut stage」 first; when it declines, treat it as a stage that produced nothing observable and re-dispatch if the segment still needs the work |
| `13` from `wait` | `--timeout` elapsed with the stage still alive | the stage is still running — wait again or route other work; never re-dispatch a live stage |
| `14` from `wait` | launch failure — an attempt was pinned but no supervisor ever wrote its row; `wait` removed the leftover `.sup`, `.sup.start` and `.launch` | re-dispatch; the dispatch takes a fresh attempt number |
| `15` | your context is at or past the hard limit (`shift.over_hard`) | **write `handoff` with `사유=상한` and end this shift.** That act is not capped — bookkeeping kinds pass — so write it first and then exit. Do not choose another act: every other one comes back 15 too |

**`15` is a routing instruction and not a refusal, and what comes with it is how you know it is the gate's.** The act you issued may exit 15 on its own account, so read the two together: a cap carries a `gate:` line on stderr and no output from the act. `wait` reports it the same way, with no `[wait]` final line. Ambiguity remains where an act both prints nothing and exits 15; the gate's line is the only discriminator, and there is no second one.

**`11` means two things, and the verb you issued tells them apart.** From `act` or `exec` it is 도달 park; from `wait` it is "never dispatched".

### Dispatching a stage

```
gate.sh act --manifest <매니페스트> --kind skill --target <alias> --segment <id> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> \
  -- <스테이지 종류> -p "/cc-cmds:<스킬>-unattended <인자…>"
```

**The first token after `--` is the STAGE KIND** and is consumed before the CLI sees the rest, so a form starting with `-p` hands `-p` over as the kind and the stage runs under settings that are not its own. The kind is one of `audit`·`design`·`implement`·`review`·`reconverge`·`generic`. `-p` is required — without it the stage gets an empty prompt and ends as a success having produced nothing. The prompt is a slash command with its leading `/`, and it must be the `-unattended` variant: the plain skills carry `disable-model-invocation: true` and a headless stage naming one resolves nothing. The one exception is `/cc-cmds:design-reconverge`, which is itself the unattended skill and has no `-unattended` pair (see 「Routing a pre-implementation refutation to re-convergence」).

**An act carrying `--segment` runs in that segment row's worktree** — the value the row's `워크트리` names, when it is an absolute existing directory sharing the target's common git directory; otherwise the target row's execution worktree, then its main worktree. The stage's settings list that worktree too, from the call after the segment row is written. An act that must run in the main worktree (updating the base branch, for instance) does not carry `--segment`. A `--kind skill` dispatch whose segment row names a worktree that fails that predicate is refused with exit `10` before the stage starts.

**Issue that call in the foreground. It returns within seconds.** The gate starts the stage under a supervisor whose process lineage is cut from yours before the call returns, and that supervisor — not your session — waits on the stage and writes its `stage-result` row. So the dispatch's exit status says whether the LAUNCH succeeded, never how the stage ended, and nothing you do afterwards can kill the stage: ending your turn, reaching the cap, taking exit 5 or crashing all leave it running and recording.

No instruction governs a stage's survival, and therefore no instruction can end it.

### Waiting on a stage

When the snapshot's `live_stages[]` holds a segment whose result you need before your next act, issue

```
gate.sh wait --manifest <매니페스트> --segment <id> --timeout 540
```

**in the FOREGROUND, and never as a background job of any kind.** You are a `claude -p` process: a background `wait` is reaped when you end, so **no shift ever observes a stage terminate**, and each successor dies at the same place.

**`--timeout` must stay under the harness's own foreground ceiling of 600 seconds.** Use `540`. The timeout ends the WAIT and never the stage (exit `13`), so on a 13 you take a fresh `snapshot`, confirm the segment is still in `live_stages[]`, and issue the same `wait` again. Any other exit is the stage's own rc, one of 11–14 from the table above, or `15` — the gate evaluates the hard limit when a shift enters `wait`, so a `wait` issued past it returns at once instead of blocking. Tell that 15 from a stage's own by the `gate:` line on stderr and the absence of the final `[wait]` line.

`wait` prints one heartbeat line every 300 seconds (`--interval` changes that) and one final line; in the foreground you read them in the call's own output, and no `Monitor` is involved.

**Do not end your turn while a stage you are waiting on is live.** Ending there burns a successor on the same live stage. Wait in the foreground until the stage ends or until your own cap ends you; a cap that lands mid-wait is a shift that did its job, and its successor picks the wait up.

Three conditions must **all** hold before a segment is dispatchable: **dependency** (no predecessor unfinished), **capacity** (concurrent streams within the cap), and **exclusion** (no live stage already holding an exclusive resource).

#### Re-attaching a cut stage

**A stage cut mid-turn is continued, not bought again.** A fresh dispatch starts a new session: a design or review team is spawned from nothing and re-runs every round it had already published, an audit re-reads everything, and an implement stage re-derives its whole context. `--resume <세션 id>` on `act --kind skill` instead continues the cut session's own transcript — its team members are resumed by `agentId`, witnesses already published are collected where they lie, and the turn goes on from the step it was on. Measured: a design stage that crashed mid-discussion was re-attached and finished `정상 완료`, and implement stages cut by the account's session limit were re-attached and finished after fresh re-dispatches had each thrown away some ninety turns — every one of those re-attachments improvised by a shift that read the gate's source, because no router text offered it. Where nothing offered it, one design was re-kicked as a new run five times running, each run paying again for the discussion round its predecessor had already published.

**Take this before every other arm that reads a stage's last `stage-result` row** — item 1 of 「Dispatching the design stage」, 「Recovering a review stage that crashed」, and any fresh re-dispatch of a segment — and for every stage kind. Each read is a gate call on the terms 「Recovering a review stage that crashed」 states (`gate.sh exec --manifest <매니페스트> --target <alias> --segment <id | -> --cutpoint <token> --surface 읽기 --snapshot-digest <H> -- <command>`, one command per call, answered only by output carrying `게이트 통과`, exit 4 retried at most three times, a refusal never read as a file fact). `<key>` below is the segment id, or the step id for the design step. Re-attach only when all four hold:

1. **Nothing is running on it.** `<key>` is in neither `live_stages[]` nor `orphan_stages[]` — an orphan is settled as `외부 종료` by your next gate call, and is read here after that.
2. **The last row was cut, not finished.** Read the stage's rows — `grep -nF '| 세그먼트=<id> | 스테이지=<id> | 종류=' "$CC_PIPELINE_LEDGER"` for a segment, `grep -nF '| 세그먼트=- | 스테이지=<step id> | 종류=design |' "$CC_PIPELINE_LEDGER"` for the design step — and take the last line. It qualifies when it reads **`종단 부류=크래시` and that attempt's stream carries the usage-limit envelope** (`grep -cF '"api_error_status":429' "$CC_PIPELINE_RUN_DIR/log/<key>#<실행 버전>.json"` answers 1 or more), or when it reads **`종단 부류=외부 종료`** — the process and its supervisor vanished mid-turn: a machine asleep, a reboot, a process group ended. Every other class, and a `크래시` whose stream holds no 429, is not this subsection's: route it as before.
3. **There is a session to continue.** The row's `세션 id` is not `미상`, and the attempt's stream shows that session actually started: `grep -cF '"session_id":"<세션 id>"' "$CC_PIPELINE_RUN_DIR/log/<key>#<실행 버전>.json"` answers 1 or more. A stage that died before its first request has no transcript to resume, and a fresh dispatch loses nothing.
4. **It has not already been re-attached three times.** Count this stage's `stage-result` rows carrying `세션 id=<세션 id> ` — every re-attachment keeps the session id and adds a row. Four or more means the original and three re-attachments all ended cut; route as before.

**A limit must have cleared first.** The 429 envelope's `result` text names the reset (`resets 1:50pm (Asia/Tokyo)`). When that time has not passed yet (`date`), do not re-attach — the first request dies on the same limit and spends an attempt. Route other work; when nothing else is dispatchable, end the shift with `사유=중단` and the reset time in `막힌 지점`.

**The dispatch keeps the stage kind, the target and the `--segment` of the attempt it continues** (`-` for the design step) and adds `--resume`:

```
gate.sh act --manifest <매니페스트> --kind skill --target <alias> --segment <id | -> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> --resume <세션 id> \
  -- <스테이지 종류> -p "계정 사용량 한도나 프로세스 종료로 앞 턴이 끊겼고, 이제 이어서 진행할 수 있습니다. 중단된 지점부터 하던 절차를 그대로 이어 가세요 — 처음부터 다시 하지 말고, 이미 끝난 라운드와 이미 쓴 절·커밋은 다시 하지 마세요."
```

**The prompt is that sentence, verbatim, and never the slash command again.** The resumed session is already inside its `-unattended` skill: the `-unattended` rule of 「Dispatching a stage」 is about which skill a NEW session loads, and re-sending the command re-enters the skill at its first step, which is the restart this subsection exists to avoid. The gate accepts only a session id that appears on this stage's own `stage-result` rows and refuses any other with exit `2`. It pins a new attempt number, so the continued turn gets its own stream and its own row under the same `세션 id`; wait on it as *Waiting on a stage* describes, and route the row it lands as usual — a cut row comes back here under item 4's count.

#### Dispatching the design stage

When the snapshot's `design_required` is `true` and a step in `steps[]` has `skill` `design`, you are the only thing that dispatches it — the fixed-graph driver's design arm is not on the router's path, and the lead does not route. Both keys are in the snapshot for exactly this, so CFI-S1 holds: `design_required` is the frozen plan's own value (`true`, `false` or `null`, never folded), and `steps[]` carries each step's `id`, `skill` and `depends_on`. The step id below is `.steps[]? | select(type == "object" and .skill == "design") | .id // empty`. **Both guards carry load and neither is decoration** — an object step written without an `id` yields nothing here rather than `null`, and an older string step yields nothing rather than a jq error. An empty result means the plan named no design step, which is the same conclusion the gate reaches before it refuses the dispatch with exit 3. **The selector is the front half of the gate's decision, and the back half is shell rather than jq.** The gate strips blank lines from that output and then requires exactly one line to remain, so three results read the same way here — no line at all, one blank line (a step whose `id` is the empty string), and two or more lines (a plan carrying more than one `design` step). All three mean `no single design step`, and all three take whatever disposition an empty result takes here. **An empty-string `id` is not a design step with a blank name.** Nothing on this path keys on that value: a run-directory file named with it and a `| 스테이지= |` grep both land on real things that are not this stage. **A design step is not a segment.** It has no `segment` row, so `segments[]` never names it, and it is dispatched with `--segment -`; every ledger row about it — the dispatch, the stage's own acts, its `stage-result` — carries `세그먼트=-`, while its run-directory files (attempt pin, stream, pid record, halt record) are named by the step id. That is the row the fixed-graph arm writes too, so both paths leave one row shape. **Three guards, and the document's freeze line is none of them.**

**Every read here is a gate call**, one command per call with no pipe after it: `gate.sh exec --manifest <매니페스트> --target <alias> --segment - --cutpoint <token> --surface 읽기 --snapshot-digest <H> -- <command>`. A probe answers only when its output carries `게이트 통과`, on the same terms as 「Recovering a review stage that crashed」 states them — exit 4 is re-read and retried at most three times, every other refusal does what 「Exit codes」 says, and a refusal is never read as a file fact.

1. **Resume is decided by the ledger.** Read this run's rows for the step: `grep -nF '| 세그먼트=- | 스테이지=<step id> | 종류=design |' "$CC_PIPELINE_LEDGER"`. If a row exists the stage was dispatched already, and **the last such row decides** — a step dispatched again carries one row per attempt. **Take 「Re-attaching a cut stage」 first**: a row it re-attaches is continued in its own session and goes nowhere else in this list. `종단 부류=정상 완료` goes to item 5's freeze check. **`외부 종료`, `크래시` and `공허한 성공` may be dispatched afresh, and only onto an absent document** — the gate's termination condition 1 and the fixed-graph driver read these three the same way. Each says the stage is over and nothing proves it carried anything off: `외부 종료` is written by the gate's prelude about a dispatch whose process and supervisor both vanished, without looking at the document; `크래시` is every non-zero exit, a usage limit that resets by itself included; `공허한 성공` is a stage that returned zero without a frozen document. **One `공허한 성공` is not this case**: a stage that emitted a judgment and opened an approval on this step lands on the same class, stopped on purpose, and a person owes it an answer — an entry in `pending_approvals[]` whose `blocks` is the step id means stop the design as below, holding its clauses `보류` on that approval. For the three, go on to item 2, whose first bullet holds the stage dispatched again while it runs, and then item 3 in full: nothing at the path, or the stage's own spawn-time stub → item 4 dispatches again, on the next attempt number; anything else at the path → stop the design as below, because a stage that ended after saving left the document partway. **Two of the three buy one fresh dispatch and no more: a `크래시` whose stream holds no 429 envelope, and a `공허한 성공`.** Neither clears by itself, so the next attempt meets the same cause — a design cut by the background-wait cap returns zero at the same place again, and a stage a person stopped by ending its `pid` is a `크래시` with no limit behind it, which this depth undoes at most once rather than every time. The gate leaves a retry's depth to the router and no gate boundary counts these attempts, so the depth is this item's. Count the step's fresh attempts on the rows already read: a row is a re-attachment when its `세션 id` is not `미상` and stands on an earlier row of the step, and every other row is a fresh attempt. **When the last row is one of these two and two or more fresh attempts already stand, stop the design as below** instead of going on to item 2; condition 1 then stays on its plain line, because the gate's window counts no attempts, and that is no reason to hold the proposal. Whether the stream holds the envelope is the read 「Re-attaching a cut stage」 item 2 makes (`grep -cF '"api_error_status":429' "$CC_PIPELINE_RUN_DIR/log/<step id>#<실행 버전>.json"`, through the gate like every read here). `외부 종료` and a `크래시` carrying the envelope keep the window as stated above. Every other class stops the design there. A stage that halted left a document partway through its walkthrough or a question for a person, and neither a second design nor the audit may take it.

   **Stopping the design is not a `blocked` row.** A design step has no `segment` row, and a cone is refused without one; run scope is only ever resolved by the routing loop. What stops is everything that depends on the step: dispatch none of it, and once nothing else in the graph is dispatchable, propose done with each clause that needs the document marked `불가능` and the `stage-result` row — plus the halt record's path when one exists — as its evidence. A clause held by an approval the stage's emitted judgment opened is `보류` naming that approval id instead. **The gate records that proposal as `무효화`, never as satisfied.** With no `segment` row, condition 1 names the design step instead of saying the run has not begun once the step's last `stage-result` row is not one item 1 dispatches again, a saved document already sits at the path, or the manifest names no document — item 1's window (`외부 종료`, `크래시`, or `공허한 성공` with no open approval on the step, over nothing at the path or the spawn-time stub) is where the plain line stands; when every clause is settled that line is the only one left, and `propose-done` closes the run as `무효화`. That verdict is the gate's, not this loop's — a `1` still in `unmet_condition_numbers` is no reason to hold the proposal once the clauses are settled as above. **One approval may hold several clauses `보류` only when it was opened by the design step** (its `막는 세그먼트` is the step id): the step emits one judgment for the whole document, and every clause that needs the document waits on that one answer. Any other approval id named on a second clause is still refused.
2. **A stage still running holds everything — a spent dispatch pin does not.** Item 1's row is written only when the stage ends, and the stage puts a file at the document path when it spawns its team, hours before its last edit freezes it — so while it runs, item 1 finds no row and item 3 finds a document. Before item 3, look for the step itself. **Three signals, and they do not share one disposition.**

   - **Its id as `세그먼트` in the snapshot's `live_stages[]`, or its id in `orphan_stages[]`** → **wait and advance nothing**: dispatch no step that depends on the design, and wait on it with `gate.sh wait --manifest <매니페스트> --segment <step id>` (the step id, never `-`) as *Waiting on a stage* describes; when the wait ends, start again from item 1.
   - **A dispatch record with no row** — `ls "$CC_PIPELINE_RUN_DIR/<step id>.attempt"` answering present while item 1 found none — → wait on it the same way, **once**. That pin is the state `wait` answers **14** for: the attempt number was stamped and no row ever followed. `wait` does not remove the pin on that path, so a 14 means the pin is **spent**, not that the stage is still coming — do not wait on it a second time and do not start again from item 1. Go on to items 3 and 4 and dispatch; that takes the next attempt number. Reading 14 as "still running" is what turns 「wait → 14 → start over」 into a circuit with no exit, because nothing in it ever clears the pin.

   You are exactly the seat this guard is for: a shift that took over mid-stage never saw the dispatch, and a shift change during a design stage of several hours is the ordinary case, not the exotic one.
3. **It fires only on an absent document, and the design stage's own spawn-time stub counts as absent.** `ls <설계 문서 메인 워크트리 절대 경로>`. A document that exists is not this run's to design, whatever else it contains — a person's unfrozen document lacks the freeze line too, and a dispatch keyed on that line would write over it. Do not dispatch.

   **The one file that is not somebody's work is the stub the design stage writes when it spawns its team** — an H1 and the team's ledger comment block, with no `##` section yet. Ask the file rather than the path: `grep -qF '<!-- cc-design-ledger' <문서>` true **and** `grep -qE '^## ' <문서>` false. Both → the previous attempt carried nothing off, there is nothing to write over, and the path counts as absent: go on to item 4 and dispatch. A person's document fails the first test and a saved one fails the second, so neither is mistaken for a stub. Measured: a design stage crashed on a session limit and left 2841 bytes with no `##` heading at the path; every later run stopped here on that file until a person renamed it by hand, which no procedure asks for and an unattended run has nobody to do.

   **This leans harder on item 2, which is why item 2 comes first.** The stub is at the path while the stage is still running, so the only thing standing between a live stage and a second dispatch is item 2's live-stage check — never reach item 3 before item 2 has answered.

   **Whether the graph goes on is the freeze line's to say:** a document carrying a line reading exactly `**상태**: 동결됨` (`grep -qxF '**상태**: 동결됨' <문서>`) → the graph goes on to its next step with that document as it stands; a document without that line — a person's hand-written draft included — → stop the design as item 1 says, naming the missing freeze line in the evidence, because an unfrozen document never goes on to the audit or to segment planning (item 5). **Record no judgment row for either**: the judgment vocabulary has no class for this decision, and borrowing a class meant for something else would put a mislabelled row where the morning audit reads classes.
4. **The dispatch.** Stage kind `design`, home alias, `--segment -`, document path first and task sentence second — the fixed-graph arm's shape:

   ```
   gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
     --cutpoint <token> --surface 워크트리쓰기 --snapshot-digest <H> --emit-digest \
     -- design -p "/cc-cmds:design-discuss-unattended <설계 문서 메인 워크트리 절대 경로> \"<## 의도 의 첫 비어 있지 않은 줄>\""
   ```

   The gate exempts exactly this form — `--kind skill`, `--segment -`, stage kind `design` — from the `segment` row and predecessor checks, and only when the frozen plan requires a design and names exactly one `design` step; it keys the stage on that step's id and refuses with exit 3 otherwise. Exit 3 means the act is not available, as the table says: do not write a `segment` row for the step to get past it — that row is what termination condition 1 counts, and a design step is not a segment. The path is the one the manifest's `## 요소` names, made absolute against the home target's main worktree; the task sentence is the first non-empty line inside `## 의도`'s fence, copied verbatim. Neither value is in the snapshot, so read each from the manifest with a gate read (`grep -nF '**설계 문서**:' <매니페스트>`, `grep -n -A3 -xF '## 의도' <매니페스트>`). CFI-S1 still holds on the same terms as the crash subsection's reads: whether to dispatch was decided from the snapshot, and these reads only fetch the argv's values from the artifact that holds them — they are not a second input for deciding, and `## 실행 계획` is not read at all. Issue it in the foreground like any dispatch, and wait on it with `gate.sh wait --manifest <매니페스트> --segment <step id>`.

   **The name belongs to the kickoff, and no shift supplies one.** `## 요소`'s `설계 문서` is chosen in Act 1 and frozen with the manifest; on a `design_required` run `(없음)` is a refused value there, rejected by the kickoff's own pre-freeze self-check and again by the gate's exemption. So when that read comes back empty or `(없음)`, do **not** compose a path for the argv. A path invented here names a document no other guard, no audit and no segment plan is looking for, and the run would go on around it. Let the gate refuse with exit 3 and stop the design as item 1 says.
5. **`정상 완료` on the row is not the freeze.** On this path the gate classifies a stage by its exit, its halt record and whether it wrote a gate row, and none of those says the document was frozen. So check both authored facts before anything reads the document: the freeze literal `설계 문서를 동결했습니다.` in the stage's stream (`grep -rlF --include='<step id>#*.json' '설계 문서를 동결했습니다.' "$CC_PIPELINE_RUN_DIR/log"`) **and** a line reading exactly `**상태**: 동결됨` in the document (`grep -qxF '**상태**: 동결됨' <문서>`). Both → the next step of the graph; the stage names no next step, by contract. Either missing → stop the design as item 1 says, naming which of the two is absent in the evidence. **An unfrozen document never goes on to the audit or to segment planning.**

#### Routing a pre-implementation refutation to re-convergence

When an implement stage refutes a residual verification item before implementing (its Step 1.5d), it leaves the design document untouched, appends a `## 회차 <N>` block with `**상태**: 대기` to the re-convergence carrier, writes a halt record, and stops. **That halt is not a park for a person — it is this loop's to route**, to `/cc-cmds:design-reconverge`, whose terminal verdict returns the segment to planning inside this same run. No new run id, manifest or authorization record is needed, whatever the halt record's option text says: the gate records a moved document digest as a `문서 해시` row and refuses nothing on it. Nothing else dispatches this — the fixed-graph driver's re-convergence sits on its escalation ladder, which only a review finding reaches, and a pre-implementation refutation happens before any review.

**Every read here is a gate call**, one command per call with no pipe after it, under `--surface 읽기` with the segment's `--segment`, and it answers only when its output carries `게이트 통과` — on exactly the terms 「Recovering a review stage that crashed」 states, including the three-retry limit on exit 4 and its `blocked` disposition for a probe that stays unanswered (`사유=재수렴 라우팅 — 판정 읽기가 답하지 않는다 (<exit code>)`). The `blocked` form in this subsection is that subsection's item 3 form, with `사유` changed.

1. **The segment stopped in an implement stage, and nothing is running on it.** Read its last `stage-result` row as the crash arm does (`grep -nF '| 세그먼트=<id> | 스테이지=<id> | 종류=' "$CC_PIPELINE_LEDGER"`, last line). It must read `종류=implement` with `종단 부류=의도된 park` **or `정상 완료`**, and the segment must be in neither `live_stages[]` nor `orphan_stages[]`. `정상 완료` is admitted because the classifier finds a halt record by one name only — `halt/<segment>#<attempt>.md` — and a stage that named its record differently was measured landing on `정상 완료` with the record on disk. `크래시`, `공허한 성공` and `외부 종료` are not this case: a Step 1.5d halt is a clean stop by contract.
2. **A Step 1.5d halt record binds to it.** Scan the halt directory by content, not by file name, in one read with no shell glob: `grep -rn -e '^<!-- cc-pipeline-halt v1;' -e '^\*\*스킬\*\*: ' -e '^\*\*스텝\*\*: ' -e '^\*\*분류\*\*: ' -e '^<!-- /cc-pipeline-halt v1 -->' "$CC_PIPELINE_RUN_DIR/halt"`. On a call that carries `게이트 통과`, exit 1 or a missing directory means no record. A record qualifies when its lines read `**스킬**: implement-unattended`, `**분류**: precondition-failed`, a `**스텝**:` value beginning with `Step 1.5d`, and it carries the closing fence. **It binds by its header's `stage=` field**: equal to `<segment>#<실행 버전>` of item 1's row, or to `<segment>`. A header whose `stage=` is the skill's own name binds only when **exactly one** segment satisfies item 1 in this snapshot and no `blocked` row already names that record as `근거`; with zero or several candidates write the `blocked` form with `사유=재수렴 라우팅 — 중단 기록 <path> 를 세그먼트에 묶을 수 없다 (<k>개 후보)` and dispatch nothing. **When the record and the row disagree, the record wins** — the contract's read priority is "a halt record present ⇒ halt" — and the dispatch's `--rationale` says so: `row 종단 부류=<class>; halt record <path> bound by <stage=… | single candidate>`.
3. **An open carrier block names the item, and the item is not spent.** The carrier is `<home main worktree>/docs/design-reconverge/<slug>.md`, where `<slug>` is the design document's repo-relative path with `.md` stripped and every `/` replaced by `-` (the manifest's `## 요소` names the document; `_common/sidecar.md` §1.1 is the rule). Read it with `grep -n -e '^## 회차 ' -e '^\*\*상태\*\*: ' -e '^\*\*대상 항목\*\*: ' -e '^\*\*처리 기록\*\*: ' -e '^<!-- cc-design-reconverge: end -->' <carrier>`. Take the first block whose `상태` is `대기` and whose `대상 항목` names an `R<n>`. **That `R<n>` must have no block reading `**상태**: 처리됨`** — one item is re-converged at most once per run, and an item refuted again after its re-convergence goes to a person as `blocked` with `사유=재수렴 라우팅 — R<n> 이 재수렴 뒤 다시 반증됐다`. A carrier whose last marker is not the end marker is truncated: `blocked`, `사유=재수렴 라우팅 — 캐리어 잘림`. No such block at all → `blocked`, `사유=재수렴 라우팅 — 1.5d 중단 기록에 대응하는 대기 블록이 캐리어에 없다`.
4. **Exclusion.** Dispatch no re-convergence while another `reconverge` stage is live, and dispatch no `implement` stage while one is — the document lock detects a second writer, it does not keep one out.
5. **The dispatch reuses the halted segment's row.** Stage kind `reconverge`, the segment's own `--segment`, and the document as its **main-worktree absolute path** — the same value the design arm builds from `## 요소`:

   ```
   gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment <id> \
     --cutpoint <token> --surface 워크트리쓰기 --snapshot-digest <H> \
     --rationale '<R<n>, carrier 회차 <N>, and item 2's binding>' \
     -- reconverge -p "/cc-cmds:design-reconverge <설계 문서 메인 워크트리 절대 경로> R<n>"
   ```

   **The stage runs in the segment's linked worktree, and `docs/` is not there** — it is gitignored, so no linked worktree carries the document or its carrier. That is why the document argument is always the main-worktree absolute path and never a relative one or one resolved against the segment worktree: the skill uses the path as given and derives the carrier from the document's own directory, and the stage's settings already list the main worktree. Write no `segment` row for the re-convergence — a new row owes a terminal state nothing here would drive it to. `/cc-cmds:design-reconverge` has no `-unattended` pair because it is itself the unattended skill; it is the one name this rule admits beside the `-unattended` ones, and the driver dispatches the same name.
6. **After it ends, the segment goes back to planning — or to a person.** Read the re-convergence's `stage-result` row, then two authored facts: its terminal literal in its own stream (`grep -cF '재수렴을 종료합니다. 판정은 여기까지이며 추가 패스는 없습니다.' "$CC_PIPELINE_RUN_DIR/log/<id>#<실행 버전>.json"`), and item 3's block for that `R<n>` now reading `**상태**: 처리됨` with a `**처리 기록**:` line carrying `판정: 재설계 필요` or `판정: 불필요`.
   - **Both present** → dispatch the segment's `implement` stage again with the prompt it had. The segment holds no `plan_sha256` row, so the stage starts from its first process on the edited document. A further `대기` block for the same document comes first, through item 3 again.
   - **`판정: 재설계 필요`** additionally parks every unmerged segment whose `implement` rows carry a `plan_sha256`: its plan was derived from the binding surface that just moved, and this loop has no way to make a segment that already holds a plan compose a new one. `blocked` with `사유=재수렴 라우팅 — 구속면 이동(재설계 필요)으로 계획이 낡았다`, one row per segment.
   - **Either missing** — a halt, a crash, no literal, no closed block → `blocked` for the segment with `사유=재수렴 라우팅 — 재수렴 종단 술어 거짓 (<which is absent>)`, and no second re-convergence for the same item.

#### Dispatching a review cycle in delta mode

The `cycle` row you write after a review stage takes two optional fields beyond the five required ones:

```
act --kind cycle -- 사이클=<n> P0=<n> P1=<n> '리뷰 HEAD=<sha>' '리포트 경로=<path>' ['모드=전체|델타'] ['기준 사이클=<n>']
```

`cycles[]` entries in the snapshot carry `세그먼트`·`사이클`·`P0`·`P1`·`모드`·`리뷰 HEAD`·`리포트 경로`; an empty `모드` reads as `전체`.

A segment's second and later review cycles re-read almost everything the first one read. A **delta** cycle reads only the files changed since the segment's last full cycle for new findings and re-adjudicates every P0/P1 that cycle raised; the review skill and the gate decide whether it holds, and this loop only offers it. **If the segment's last `stage-result` row reads `종류=review` with `종단 부류=크래시` or `외부 종료`, go to 「Re-attaching a cut stage」 and then, for a `크래시` it declines, 「Recovering a review stage that crashed」 before dispatching anything from here** — a fresh dispatch early-stubs the report path that subsection reads its roster from. Five things, in order:

1. **Basis selection.** Filter `cycles[]` to this segment and take, among the rows whose `모드` is `전체` or empty, the one with the numerically largest `사이클`. **`사이클` is a JSON string in the snapshot**, so a string maximum picks `"9"` over `"10"` and offers a basis the gate then refuses as stale, on every re-dispatch alike; compare it as an integer, which is what this expression does — `[.cycles[] | select(.["세그먼트"]=="<세그먼트>" and (.["모드"]=="" or .["모드"]=="전체"))] | max_by((.["사이클"] | tonumber?) // -1)` — and a `null` result means there is no basis. None → dispatch a full review exactly as before. One → carry that row's `사이클`, `리뷰 HEAD` and `리포트 경로` into the `/cc-cmds:review-unattended` prompt as `--basis-cycle <n> --basis-review-head <sha> --basis-report-path <abs>`, alongside the `--report-path`, `--base-sha` and `--declared-files` you already pass. All three or none: the skill treats a partial set as absent.
2. **Path resolution.** The basis row's `리포트 경로` may be relative to the target's base. You hold the manifest path, so build `dirname(<매니페스트>)/../../<경로>` and pass the absolute result; an absolute value goes through as-is. No new snapshot key exists for this.
3. **The row's mode is copied from the report, never from the dispatch.** After the stage ends, read the report overview's `- **리뷰 모드**: …` line and write `모드` and `기준 사이클` on the `cycle` row from that line: `- **리뷰 모드**: 전체` → `모드=전체` (or omit both fields); `- **리뷰 모드**: 델타 (기준 사이클 <n>, 기준 리뷰 HEAD `<sha>`)` → `모드=델타 '기준 사이클=<n>'`. The skill degrades to a full review when any eligibility check fails, and only the report says whether it did. The gate compares the row against the report on every `cycle` write and refuses with exit 2. **There are two repairs, and the refusal's wording says which one applies.** A mode mismatch — the row says one mode and the report the other — is repaired by rewriting the row to what the report says. Every other refusal of a delta claim (the basis number or head on the report line, the basis row, its report, the ancestry, a `사이클` not above its basis) that still stands once the row's `사이클` is this cycle's number and its `모드`·`기준 사이클` match the report line is repaired by **no** row: rewritten as `모드=델타` it meets the same check again, and rewritten as `모드=전체` it meets the mode comparison, because the report still says `델타`. Re-dispatch this segment's review as a full review **without the three basis flags**, and write no `cycle` row until a report the gate accepts exists.
4. **No new question point.** When a basis exists, attempting delta is the default. Whether it holds is decided by the skill's eligibility checks and the gate's write-time checks, not by asking.
5. **The snapshot window is a limit, stated rather than hidden.** `cycles[]` is the ledger's last twenty `cycle` rows, so a segment whose basis row has been pushed out of the window by other segments' cycles gets a full review. That errs toward reading more, never toward a false delta.

#### Recovering a review stage that crashed

A review stage that dies usually leaves its team's work on disk: every seat publishes into a witness scratch directory under the run directory, and `/cc-cmds:review-unattended --recover` synthesizes the report from that directory without spawning anyone. The fixed-graph driver dispatches that recovery on its own; this loop has to dispatch it too, or a crashed review's witness is never read and the next dispatch buys the whole review again. **Evaluate this before re-dispatching a crashed review** — a fresh review early-stubs the same report path, and that stub replaces the ledger block the recovery reads its roster from. **Every review dispatch you issue carries an absolute `--report-path`**, the ordinary ones included: without it the report lands relative to a segment worktree that is torn down, no seat holds its path, and item 2 blocks every crash, so this subsection never fires.

**Every read in this subsection is a gate call.** You write no files (CFI-S5) and every Bash line you issue goes through the gate, so the ledger rows, the report existence check, the termination-predicate and partial-recovery tests, the `.recover.md` existence check, the `리뷰 HEAD` read, and the witness enumeration with its stamps are each one `gate.sh exec --manifest <매니페스트> --target <alias> --segment <id> --cutpoint <token> --surface 읽기 --snapshot-digest <H> -- <command>` call — one command per call, with no pipe after it. None of them needs `--reach`.

**A probe answers only when its output carries `게이트 통과`.** A gate refusal exits non-zero with nothing on stdout — the same observation as `grep` finding no line or `ls` finding no file. The refusal these reads meet most is exit 4, a stale snapshot digest, and it is routine exactly where they sit: right after a stage's row lands and right after the recovery ends. So a call whose output lacks that line is a refusal whatever its exit code, and never branch on the refused call. **Only exit 4 is retried here**: re-read the snapshot and issue the same probe again with the new digest, **at most three times in a row for one probe**. Every other refusal code does what 「Exit codes」 says for it — 5 ends the shift with `사유=승인`, 7 ends it with `사유=중단`, 11 is not retried — and a code of 1 with no gate line means the shell rejected the line before the gate ran. On a call that carries the line, the command's own exit code is the answer: for `grep` and `ls`, 0 is a match or a present file and 1 is none; any other code means the probe did not run as written (an unresolved path, a bad argument), which is not an answer either — fix the probe when the fault is in its own argv. **A probe that stays unanswered ends the subsection**: when the retries reach three, when the table forbids retrying its code, or when the fault is not one you can fix in the argv, write item 3's `blocked` form with `사유=리뷰 크래시 — 복구 판정 읽기가 답하지 않는다 (<exit code>)` and dispatch nothing. Reading a refusal as a file fact is not harmless: at item 3 it parks the segment while the witness is still on disk, and no second recovery is allowed for the same crash. Five things, in order:

1. **One terminal class triggers it.** None of the values below is in the snapshot — `segments[].마지막 스테이지` carries only the segment id on this path — so read the segment's `stage-result` rows from the ledger through the gate: `grep -nF '| 세그먼트=<id> | 스테이지=<id> | 종류=' "$CC_PIPELINE_LEDGER"`, and take the last line. The row the gate writes carries `종류=<stage kind>`, `실행 버전=<attempt>` and `종단 부류=<class>`. Only `종류=review` with `종단 부류=크래시` belongs to this arm, and only once 「Re-attaching a cut stage」 has declined it — continuing the review's own session finishes the round and the synthesis that this recovery can only rebuild from what was published; every other class is routed as before and is not a recovery target. A crashed `--recover` dispatch is not recovered again — record it under item 3's `blocked` form as `리뷰 복구 종단 부류 크래시`. CFI-S1 still holds: the snapshot remains the only input for deciding what to do next, and these reads fetch the values a row needs from an artifact the stage just produced, as the delta section's read of the report does.
2. **A report that already carries the termination predicate is not recovered, and a report path you do not hold is not rebuilt.** The report path is the `--report-path` you passed on that review dispatch — the same value the ordinary `cycle` row's `리포트 경로` comes from. No ledger row and no snapshot key carries it (the `skill` act row records the rationale, not the argv), so a shift that did not issue the review dispatch itself — for example one that took the seat after it — does not hold the path and must not reconstruct it by listing `docs/reviews/`: record item 3's `blocked` row with `사유=리뷰 크래시 — 원래 리포트 경로를 원장에서 얻을 수 없어 복구를 파견하지 않는다` and dispatch nothing. With the path in hand, **first check that the file exists** with `ls <report path>` through the gate. On a call that carries `게이트 통과`, a non-zero exit means no file: the stage died before its early stub, so there is no completed report — skip the predicate test and go straight to the basis-flag check below and then item 3, whose Zero branch is where such a crash lands. Grepping an absent file exits 2, which is not an answer, so the existence check comes first. With the file present, test it through the gate: `grep -qE '^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건' <report path>`. A match means the file already holds a completed report — dispatch nothing and record `사유=리뷰 크래시 — 리포트에 종료 술어 줄이 이미 있어 복구를 파견하지 않는다`. With no match or no file, **a review dispatched with the three basis flags is not recovered.** The recovery arm does not carry the delta mode into its report — its `리뷰 모드` line is absent or reads `전체` — so a report built from a delta corpus would reach the `cycle` row as a full review, and the delta section's basis selection would take that row as the next full basis with nothing refusing it. Re-dispatch the segment's review as a full review without the three basis flags, as the delta section's item 3 repair does, and write no `cycle` row for the crash.
3. **Name exactly one witness directory, or dispatch nothing.** Each directory is `"$CC_PIPELINE_RUN_DIR"/cc-team-witness-<slug>.<tag>.XXXXXX`, and its `.attempt` stamp holds the stage id the gate handed the stage, verbatim — on this path `<segment>#<attempt>`, with `<attempt>` the row's `실행 버전`. Enumerate and compare in one gate read, with no shell glob: `grep -rlxF --include=.attempt '<segment>#<실행 버전>' "$CC_PIPELINE_RUN_DIR"`; each printed file whose parent directory is named `cc-team-witness-*` is a candidate. A glob that matches no directory fails in the shell before the gate runs, which looks like an empty answer and is not one. `-x` makes the comparison whole-line, so `S1#2` does not take `S1#21`. **Match on the stamp, never on the directory name** — the name carries a sanitized tag — **and never choose by mtime**: attempts of one segment interleave, and mtime order lies.

   Every `blocked` row in this subsection takes this one form, and only `사유` changes:

   ```
   gate.sh act --manifest <매니페스트> --kind blocked --target <alias> \
     --cutpoint <token> --surface 읽기 --snapshot-digest <H> \
     --rationale '<why>' \
     -- 스코프=cone 원인=막힘 '사유=<사유>' '근거=<the stage-result row>' '앵커 세그먼트=<id>'
   ```

   - **Exactly one** → item 4.
   - **Zero** (the call carries `게이트 통과`, `grep` exits 1 and prints nothing) → the stage died before its first spawn and nothing is on disk to recover. Write the `blocked` form above with `사유=리뷰 크래시 — 시도 <n> 의 위트니스 디렉터리가 없어 Step 4 미도달, 복구를 파견하지 않는다`.
   - **Two or more** → the `blocked` form above with `사유=리뷰 크래시 — 시도 <n> 에 위트니스 디렉터리 <k>개, 지명 불가: <every candidate path>`. Dispatching without a name buys a stage that is certain to fail: with no `--scratch-dir` the recovery arm lists the candidates and recovers nothing.
4. **The dispatch.** Stage kind `review`, the same target as the review it recovers, both paths absolute:

   ```
   gate.sh act --manifest <매니페스트> --kind skill --target <alias> --segment <id> \
     --cutpoint <token> --surface <token> --snapshot-digest <H> \
     -- review -p "/cc-cmds:review-unattended <target> --recover --scratch-dir <abs witness dir> --report-path <abs original report path>"
   ```

   Carry no `--base-sha`, `--declared-files` or basis flags; the recovery reads only the directory and the report's ledger block. Issue it in the foreground exactly as the dispatch section requires — it is an ordinary dispatch and returns within seconds — and wait on it as *Waiting on a stage* describes. It pins a new attempt of its own, so its `stage-result` row is not the crash it recovers.
5. **The `cycle` row comes from the recovered report, and only from a clean one.** The report is clean when all four hold: the recovery's `stage-result` row reads `종단 부류=정상 완료`; the report path now matches item 2's termination predicate; the file carries no `- **발견 요약(부분 복구)**:` line (test it with `grep -qF -e '- **발견 요약(부분 복구)**:' <report path>` — the `-e` keeps the leading `-` from being read as a flag); and no `<report path>.recover.md` exists beside it (`ls <report path>.recover.md` through the gate — a non-zero exit means absent only on a call that carries `게이트 통과`). Otherwise write no `cycle` row — a partial-recovery line is deliberately not the predicate, and a diversion to `.recover.md` means the report path holds a report this recovery did not write — and record item 3's `blocked` form naming which: `리뷰 복구 종단 부류 <class>`, `부분 복구`, or `.recover.md 로 우회`. Do not dispatch a second recovery for the same crash.

   From a clean report, read the `리뷰 HEAD` line with a probe anchored at the line head that also requires the value: ``grep -E '^[-*[:space:]]*\*\*리뷰 HEAD\*\*: `?[0-9a-f]{40}`?$' <report path>``. Exactly one printed line is the value; no line, or more than one, is absent. An unanchored probe is not enough — a finding that quotes the label matches it, and a label with no 40-character sha behind it is no source for the field. **No `리뷰 모드` line is required.** Item 2 already refused to recover a review dispatched with the basis flags, so the recovered report is a full review, and a report with no mode line is read by the gate as `전체`, which is the truth here.
   - **`리뷰 HEAD` present** → write the `cycle` row: `P0` and `P1` from the `발견 요약` line, `리뷰 HEAD` from that line's sha, the report path as `리포트 경로`, the crashed review's cycle number as `사이클`, and no `모드`·`기준 사이클` fields.
   - **`리뷰 HEAD` absent** → the recovery arm is not bound to emit that line and nothing may stand in for it, so a required field of the row has no source. Do not park the segment for that: write no `cycle` row and re-dispatch the segment's review as a full review **without the three basis flags**, carrying an absolute `--report-path` like every review dispatch. That is what a crashed review got before this subsection existed, so a clean recovery never leaves the night worse off than no recovery would. This re-dispatch is a review, not a second recovery.

## Ending your shift

Check `shift.over_soft` on every snapshot. When it is true — or when the gate answered `15`, or you took exit 5, or a `propose-done` was accepted — write this and then exit:

```
gate.sh act --manifest <매니페스트> --kind handoff --target <alias> \
  --cutpoint <token> --surface <token> --snapshot-digest <H> \
  -- 교대=<n> 사유=<상한|승인|종단|중단> \
     '버린 선택지=<시도했고 버린 것 · 무엇을 보고 버렸는가>' \
     '막힌 지점=<지금 벽이 있는 자리>' \
     '다음 후보=<후임이 먼저 볼 것>'
```

`교대=<n>` is the snapshot's `shift.n`, and that is YOUR OWN launch number — the gate hands it down in `CC_PIPELINE_SHIFT_ID` and stamps the same value on every row you write. `0` is reserved for the lead's seat and means routing never left it, so it is never a number you write. The three free-text fields are clipped by the gate; write them anyway.

**`버린 선택지` is the field nothing else in the ledger can hold.** The snapshot records what LANDED — never what was considered and dropped. Leave it empty and your successor pays again for every dead end you already walked.

**A live stage holds back none of the three.** Its supervisor is detached from your session, so ending on `상한`, `승인` or `종단` while it runs costs the stage nothing: your successor finds it in `live_stages[]` or in the ledger.

## Your return line

One line to the lead. It says: the reason you ended, the shift number, and — if you ended on `승인` — the approval id and what it blocks. Nothing else. Blockage goes here too; there is no other channel you are permitted to use.
