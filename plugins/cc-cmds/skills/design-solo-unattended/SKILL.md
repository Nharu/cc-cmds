---
name: design-solo-unattended
description: 리드 단독 설계의 무인 팔 — autopilot 이 `solo` 티어 런과 `team-4` 단일 설계의 `solo-audit` 경로 런의 설계 단계로 파견하면 리드 혼자 요약을 쓰고 동결한다 (팀 없음, 질문은 정지 기록으로)
when_to_use: 사람이 직접 부르지 않는다. autopilot 드라이버·게이트가 선택 함수가 이 스킬을 고른 런 — `solo` 티어이거나 `team-4` 이고 `design_path` 가 `solo-audit` 이며 `design_required` 인 런 — 의 설계 스테이지로 파견한다
disable-model-invocation: true
usage: "/cc-cmds:design-solo-unattended <doc-path> [<task-sentence>]"
options:
    - name: "<doc-path>"
      kind: positional
      required: true
      summary: "설계 문서 경로(메인 워크트리 절대 경로, 드라이버가 준다 — 아직 없을 수 있다)."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰. 드라이버 파견 전용이라 `CC_PIPELINE_RUN_ID` 가 비어 있으면 아무것도 쓰지 않고 끝난다."
    - name: "<task-sentence>"
      kind: positional
      required: false
      summary: "매니페스트 `## 의도` 의 첫 줄. 인터뷰 기록이 없을 때 과제 문면이 되는 한 문장."
      parse_note: "첫 `.md` 토큰 이후의 모든 내용."
notes: "팀을 띄우지 않고 5U·6U 를 돌지 않는다. 멈춤 자리는 닫힌 넷(`document-present`·`ledger-missing`·`slicing-unknown`·`ladder-unsettled`)이고, 종단은 동결 문면·문서 경로·sha256 이다."
---

Run the light design stage of an autopilot run in a headless session, **without ever asking a human and without a team**. The lead alone reads the interview record and the tree, writes a design summary under the headings implementation already reads, and freezes it; on a `solo` plan the run then goes to implementation without a design audit, and on a `team-4` plan whose `design_path` is `solo-audit` the run's design audit reads it next.
Everything written for a person — the saved document and a halt record — is Korean.

This file is a separate arm so that "it has no human-question surface" is a whole-file predicate `scripts/lint-unattended-surfaces.sh` can check. It is **dispatched by the driver or the gate only**, for a run whose plan reads `design_required` true and for which the selection function `manifest_design_skill` gives `design-solo-unattended` — `design_tier: solo`, or `design_tier: team-4` with `design_path: solo-audit`; there is no seat-dispatch branch. **Before Step 0, Read only the parts of `${CLAUDE_SKILL_DIR}/../design-discuss-unattended/SKILL.md` listed below** and follow their driver-dispatch path, with only the steps below replaced. A part named by a heading runs from that heading to the next heading of the same or a higher level; a part named by a list item's text is that item with its indented lines. The rest of that file is the team's and the seat's, and this arm does not Read it: every other mention of the discuss arm below restates what this arm needs from it.

Discuss-arm parts this arm reads:

- `## Halt record (driver dispatch)`
- `### Step 1: Read the brief and guard it`
- `6. (driver dispatch only) the interview record governs, and what the team decides in its place is listed:`
- `### Step 7U: Coherence, slicing self-check, residual ladder, freeze (driver dispatch)`
- `### The requirement-decision list (driver dispatch)`
- `- **Research.** Research is open:`

## Control-Flow Invariants

These rules MUST stay near the top of this file: post-compaction reattaches only the first ~5K tokens with priority.

### CFI-U0 — There is no human-question surface

The question tool is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers every shared file this arm Reads: wherever `design-discuss-unattended/SKILL.md`, `design/SKILL.md` or `_common/agent-team-protocol.md` terminate in a question to the user, **this arm resolves that terminus to `park`**. None of those files is forked or edited; this sentence is the substitution rule. Here `park` is always the halt record of `## Halt record` below, at one of its four sites.

### CFI-L1 — There is no round to wait for

The discuss arm's CFI-L1 times a halt to the end of a team round. This arm spawns no team and runs no round, so that rule has no place to apply: a halt is written as soon as its site is reached, and the stage stops there.

### CFI-L2 — The exit is the freeze literal

The discuss arm's CFI-L2 governs the seat's leg (`presentation.md`, a resumed coherence turn), and this arm has no seat dispatch, so it does not apply. The terminal is Step 7U's freeze output below, and nothing else ends a normal run.

### CFI-L3 — No notification, no sidecar, a halt record only

Unchanged from the discuss arm. This arm never reaches a notification tool or script, never writes `pipeline-grant` or `pipeline-run`, and its only channels toward a person are the halt record and its terminal message.

### CFI-L4 — No team, no drop, one destination

From the discuss arm's CFI-L4: **(b)** no team is composed and nothing is spawned; **(c)** nothing is dropped — an item that cannot be settled is written at `상태: 보류` with its reason; **(d)** the stage ends by emitting the freeze literal, the document path and its whole-file `sha256`, and names no next stage. **(a)** (the walkthrough transition and its pre-image) has no place here, because Step 5U does not run.

## Dispatcher

Read `CC_PIPELINE_RUN_ID` by name (`printenv CC_PIPELINE_RUN_ID`, never bare `env`). Empty or unset → this arm has no seat-dispatch branch: write nothing, print one line saying that `design-solo-unattended` is dispatched by the autopilot driver only, and end the turn. Non-empty → take `CC_PIPELINE_RUN_DIR`, `CC_PIPELINE_STAGE_ID` and `CC_PIPELINE_MANIFEST` the same way and continue.

## Halt record

Follow `## Halt record (driver dispatch)` of the discuss arm as written: schema `cc-pipeline-halt v1` of `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4, path `${CC_PIPELINE_RUN_DIR}/halt/${CC_PIPELINE_STAGE_ID}.md`, the ten fields, the atomic form, the closing fence as terminator, the question and every option label and description verbatim, `재호출 명령` recorded and never executed, and the site's id in `스텝` after the step identifier (`Step 7U / ladder-unsettled`). **Every halt writes `문서 사전 sha256=<값>` in its `관측 상세`** — the `shasum -a 256` of the document at the document path as it stands when the record is written, `없음` when no file is there — so a fresh session handed the answer can tell the saved document is this attempt's own (Step 0's document-present guard). Then take no further step and end the turn.

**The sites are a closed set of four**, all first-failure sites:

- `document-present` — a saved document already exists at the document path (Step 0);
- `ledger-missing` — the interview record or the base-design row fails its check, or a file the redesign input names does not exist (Step 1);
- `slicing-unknown` — the slicing self-check cannot be repaired without a decision nobody made (Step 7U);
- `ladder-unsettled` — residual items no rung of the ladder settles (Step 7U); a `설계-골격` judgment only when its `**추천**` is `(없음)`, and a `등급 0` halt the seat answers when the ladder's writing rules let it carry a recommendation.

The discuss arm's other sites are never reached here: the nine park sites other than `ledger-missing` all wait on a team, `roster-missing` reads a roster this arm never instantiates, and `skeleton`, `step5-zero-section` and `step7-coherence-conflict` belong to Step 5U and to the team coherence pass, neither of which runs. Adding a site takes on the discuss arm's closed-set duty.

**`**추천**` and `**추천 근거**`**, after the option lines and before `**하네스 오류**`: at `ladder-unsettled` the discuss arm's ladder writing rules in its Step 7U job 4 decide the line, the `**잔여 판정**` line and the fixed step, classification and option labels with it. At the other three sites the discuss arm's general rules decide.

### Per-grade disposition

The attended skill marks its ask points with a judgment grade (`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`); this arm's disposition is per grade:

- **`등급 0`** — no disposition is needed; an already-written rule determines the answer.
- **`등급 1`** — no site of this arm reaches it. The discuss arm's only `등급 1` class is a Step 5U disposition, and Step 5U does not run here, so this arm emits no judgment markers.
- **`등급 2`** — write the halt record and stop.

## Workflow

### Step 0: Tools and the document-present guard

Load no deferred tool: this arm uses neither `Agent` nor `SendMessage`, and the question tool is absent as in every headless process. There is no roster check and no ledger stub.

**Document-present guard → `document-present`.** If a file exists at the document path and its body carries at least one line beginning with `## `, it is a saved document: halt with `분류: precondition-failed`, putting the path, its byte count, its mtime and the first such line in `관측 상세`. Whether the file carries a design-ledger comment block is not part of the test — a light document has none, and asking for one would read a saved light document as neither saved nor a stub. A file with no `## ` line holds nothing saved, and Step 3's Write replaces it. **A re-entry is exempt**: when `CC_PIPELINE_HALT_ANSWER` names a card and the `문서 사전 sha256` in the `관측 상세` of the record the card names equals the `shasum -a 256` of the document now, the saved document is the halted attempt's own — do not halt; enter the halted step as **Re-entered with a carried answer** below says. A card whose record carries no `문서 사전 sha256`, or one that differs, gets the guard as written.

**Re-entered with a carried answer.** A fresh session can be handed a person's answer to an earlier attempt's halt: the routing shift's carry act writes an answer card and starts this stage with `CC_PIPELINE_HALT_ANSWER` set to its path and the ordinary design dispatch prompt. When it is set, after the guard above:

1. **Read the card and check the digest.** Its `**중단 기록**` is the earlier attempt's halt record and `**기록 다이제스트**` that record's sha256. Compute `shasum -a 256` of the record and compare; a difference is a halt with `분류: precondition-failed` naming both values — the answer was given to other bytes.
2. **Enter at the step the record names**, from what is on disk — the document at the document path and the record — and apply the card's option there as the answer to the record's `**질문 문면**`, as **Resumed turns** below says for that option. Do not ask that question again.
3. **If the question computed there is not the record's**, do not apply the answer: write a new halt record for the question computed now, with the card's path in its `관측 상세`.
4. **Never rewrite the carried record** — the card's `**중단 기록**` belongs to the earlier attempt, and the answer is bound to its digest.

### Step 1: Inputs and baseline

Follow the discuss arm's Step 1 under driver dispatch as written: the interview record by path convention with its version token and its hash against the manifest's `사전 인가` row, the rules of `Reading the record.`, and the base-design row when the manifest carries one. Every failure there is `ledger-missing` with `분류: precondition-failed`, exactly as in that arm. Its branch for a ledger stub that cannot be created does not apply. Take the baseline (`git status --porcelain` + `git worktree list --porcelain`) now, before any write.

### Step 2: State root

Unchanged: `STATE="${CC_PIPELINE_RUN_DIR}/design/{slug}"`, with `{slug}` from the document path per `${CLAUDE_SKILL_DIR}/../_common/sidecar.md` §1.1, and the document itself as the only exempt path of the boundary gate, with `-run-` as assertion 2a's exception pattern.

### Step 3 · Step 4 (replaced): The lead writes the summary

The lead alone reads the interview record (or, without one, the task sentence and the manifest's `## 의도`) and the tree, and writes the summary. Every claim of the record's `## 탐색 결과` and `## 재현 근거` that the design rests on is checked again against the current tree; the rest of the tree is read as the design needs it.

- **Verification.** `${CLAUDE_SKILL_DIR}/../_common/verification.md` applies as written: a claim settled against the tree goes to `## 검증 기록`, a claim that cannot be settled now goes to `## 구현 시 검증 항목` as an `### R<n>` with its required fields, and the pre-save sweep's four conditions hold before the Write.
- **Substitution 6** of the discuss arm's `### Step 3 · Step 4: Interim body` (the listed item, not the rest of that section) applies as written: the record governs, a requirement-level choice the record left open is decided and listed in `## 팀이 정한 요구 결정` in the form of `### The requirement-decision list (driver dispatch)`, and a verified base-design row brings `## 베이스 제약` with its fixed first sentence in `## 합의된 아키텍처`.
- **Headings, in this order:** the H1; the document status line; `## 팀이 정한 요구 결정`; `## 베이스 제약` (only with a base-design row); `## 합의된 아키텍처`; `## 주요 결정사항과 근거`; `## 검증 기록` (when a claim was settled); `## 미해결 이슈 / 트레이드오프` (its entries at `상태: 보류`, or the single line `없음`); `## 구현 시 검증 항목` (when an item exists); `## 구현 슬라이싱` (always, in the declaration form `design/SKILL.md` defines). Implementation binds by section identity, so no other heading is invented to carry a decision.
- **Every `상태: 보류` entry carries `**구현 처분**`** and its companion field, chosen and written by `${CLAUDE_SKILL_DIR}/../_common/unresolved-closure.md` (`## 값 고르는 기준`, `## 작성자 꼴`). An entry whose `사유` is `베이스 계약 변경 필요` is `구현 전 결정`.
- **A hotfix run's slices merge first.** When the plan in the manifest's `## 실행 계획` carries `run_profile` `hotfix`, every implementation slice of `## 구현 슬라이싱` declares `**리뷰 정책**: 선머지후리뷰`, which is the run's frozen review policy ceiling. The number of slices follows the slicing rules as written.
- **The document status line before the freeze is `**상태**: 초안`**, on its own line below the H1. That value is this arm's own: no other skill defines a pre-freeze document status, and it overlaps none of the item status values (`대기`·`조사중`·`결정대기`·`해결`·`보류`), so the freeze Edit matches exactly one line.
- **Save** the complete document with **one Write**. No design-ledger comment block, no hidden temporary file, no `mv`, no spawn-time stub. "One page" is the target length, not a check.

### Steps 5U · 6U: not run

There is no walkthrough and no pass-through refinement. An entry that cannot be decided is written at save time as `상태: 보류` with its `사유`, and goes to the router's redesign rung or to the morning. **The stage does not move itself to the heavy path** when the work looks heavier than expected: it writes the summary and freezes it.

### Step 7U: Re-read, slicing self-check, requirement list, residual ladder, freeze

Read the discuss arm's Step 7U and follow its five jobs in order, with the first replaced:

1. **Re-read against the requirements.** The lead re-reads the whole document against the record's `## 확인된 요구` and fixes it in place. A finding that departs from a recorded answer does not halt: it is listed by job 3 as `벗어남 — 문 <n>`. There is no team to resume and no team cleanup.
2. **Slicing self-check** — unchanged; a repair that needs a decision nobody made → halt `slicing-unknown`. Read item `8. **Slicing self-check` of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` with its indented lines: rules (f) and (g), their baseline and their counting are defined there and nowhere in this arm. Neither split rule ever reaches `slicing-unknown`: a split nobody decided is not made, and the reason field is written instead.
3. **Requirement-decision list** — unchanged.
4. **Residual ladder** — unchanged, W3 included; an item no rung settles → halt `ladder-unsettled`, after every item has been walked.
5. **Freeze.** When this freeze follows an answer to this stage's `ladder-unsettled` halt, first write the `**잔여 동결**` line directly below the status line, in the discuss arm's Step 7U job 5 form. Then one Edit that replaces the single line `**상태**: 초안` with `**상태**: 동결됨`; this is the last document edit. Then emit, in the terminal message, the freeze literal *"설계 문서를 동결했습니다."* on its own line, followed by the document path and its whole-file `sha256`, then the discuss arm's `강제 표면:` line from job 2's screen when the document has `## 구현 슬라이싱`. No judgment markers follow. Name no next step. End the turn.

## Constraints

- NO code modifications. The observation and verification carve-out of the base skill's `## Constraints` applies verbatim.
- Every Bash command goes through `gate.sh exec`, with the `--reach` discipline of `implement-unattended`'s CFI-U7. Call external commands directly, never inside `bash -c`; read pipeline variables by name, never with bare `env`.
- **Never reach a notification surface** and **never write a pipeline sidecar** (CFI-L3).
- **Research** follows the research paragraph of the discuss arm's `## Constraints` as written.
- **The design document's only writes** are: the Step 3 Write, Step 7U's in-place fixes, slicing repair, requirement-decision entries and `### 확인된 요구와의 대응` block, W3 lines (with the `**검증 시점**` revert W3 entails), the `**잔여 동결**` line, and the freeze Edit.

## Resumed turns

This arm resumes only on an answer to its own `/ ladder-unsettled` halt:

- **`잔여로 두고 동결`** — continue after the ladder: write the `**잔여 동결**` line, then freeze (Step 7U job 5).
- **`골격 재검토`** — do not redesign in this session: write the `**잔여 동결**` line with the label `골격 재검토`, then freeze. The redesign is design re-convergence's, which the routing shift dispatches after this freeze.

In both branches the terminal message is the freeze literal, the path and the `sha256`, unchanged.

Task: $ARGUMENTS
