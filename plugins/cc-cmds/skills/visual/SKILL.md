---
name: visual
description: 설계 문서의 화면을 로컬에서 생성·검토하고, Claude Design 에 발행·동기하며, 구현 승인을 사이드카에 쓴다 (대화형, 고정 계정 좌석)
when_to_use: 무인 런이 `검토 통과` 로 남긴 화면을 아침에 발행·캔버스 편집·동기한 뒤 구현을 승인할 때, 또는 사이드카 없는 설계 문서의 화면을 대화형으로 처음 만들 때. 무인 파이프라인 스테이지는 `/cc-cmds:visual-unattended` 를 쓴다
disable-model-invocation: true
usage: "/cc-cmds:visual <design-doc-path>"
options:
    - name: "<design-doc-path>"
      kind: positional
      required: true
      summary: "대상 설계 문서 경로 (`.md`). 사이드카 `<base>/docs/visual/<slug>.md` 의 상태가 이번 국면을 정한다."
notes: "국면은 사이드카 상태로 정해진다 — 없음은 생성, `로컬 초안` 은 생성 이어 하기, `검토 통과` 는 발행, `발행됨` 은 동기·발행 묶음 다시 생성·구현 승인·금지 후보 승인. Claude Design 에 닿는 모든 국면은 고정 계정 판독이 `일치` 여야 진행한다."
---

Generate, review, publish and approve the screens of a design document, in an attended session on the pinned Claude Design account. User-facing text is Korean; this control prose is English.

**The Design and Design System artifacts are the user's explicit request.** Invoking `/cc-cmds:visual` on a document whose sidecar is `검토 통과` or `발행됨` is the person asking for those artifacts to be created, read and re-versioned. That is the explicit-request exception the Artifact tools require, and it covers only the artifacts this skill's phases name — nothing else is published from here.

The shared contract lives in `${CLAUDE_SKILL_DIR}/references/`: `contract.md` (generation rules, review rubric, models and author envelopes, polish downgrade) and `sidecar.md` (the two link files, the binding digest, the input bundle and the approval predicate). `visual-unattended` reads the same two files. Helpers are `${CLAUDE_SKILL_DIR}/../../orchestrator/visual-config.sh`, `visual-check.sh` and `visual-capture.sh`.

## Control-Flow Invariants

These rules decide what a phase may do and where it stops. They stay near the top of this file so that compaction cannot drop them.

**CFI-1 — The sidecar's state is the phase.** No sidecar → 생성. `로컬 초안` → 생성 이어 하기. `검토 통과` → 발행. `발행됨` → one of 동기 / 발행 묶음 다시 생성 / 구현 승인 / 금지 후보 승인. The person confirms the phase once; the confirmation is `등급 0` because the state already decided it. No phase reads or writes run state — not the run ledger, not a manifest, not a halt record, not a pipeline sidecar. This seat holds no run id.

**CFI-2 — Account pinning stops, it never routes around.** Every phase that reaches Claude Design reads the account with `visual-config.sh account` at four points: K0 at phase start (the `구현 승인` phase included), K1 immediately before every `Artifact`, `ArtifactComments` or `ArtifactData` call, K2 immediately after a publish (the account again, plus reading the returned URL back as its author), K3 every time a URL pinned in a link file is read (it must read as this account's artifact). A verdict other than `일치`, or a K2/K3 author read that fails, stops the phase where it stands and tells the person the verdict, the log path the helper printed and the fix — run the same phase again in the pinned seat. Never publish again under a new URL, never move to another seat, never write a field that records the attempt. The model the person uses on the canvas is not chosen, suggested or recorded here.

**CFI-3 — Only publish and sync move the comparison baseline.** The screen files, `support.js` and their pinned `**sha256**`·`**버전**`·`**동기 시각**`·`**런타임**` change only in 발행, 동기 and the publish step of 발행 묶음 다시 생성. Before overwriting, compare the current files against the pinned values and show any unrecorded move to the person. Sync and republish delete the `**구현 승인**` line in the same write.

**CFI-4 — `**구현 승인**` is written by the 구현 승인 phase and nothing else.** It is written only after K0 and K1 + K3 for every pinned URL succeeded in the same invocation, only on `발행됨`, never when `**스냅숏 형태**` is `초안`, never while an `external-ref` finding stands, and its input bundle is measured by `visual-check.sh bundle` — never computed here.

**CFI-5 — The review loop is capped at three rounds with a fresh reviewer each.** A round that yields no verdict counts as a failed round. After the third failed round the phase stops and asks (`contract.md` §3 and Step 3 below). Authors and reviewers are read-only subagents; the parent writes every file, and rejects an edit pair whose id is not on that round's fix list.

**CFI-6 — Host files are written by `seed` and `append` only.** The ban list grows only by a candidate the person approved item by item, passed verbatim to `visual-config.sh append`. Nothing in this skill edits a host file with the file-edit tools.

## Step 0: Tool loading

- `ToolSearch("select:AskUserQuestion,mcp__cc-cmds__question_form")` — before Step 1. **Before calling AskUserQuestion, Read `${CLAUDE_SKILL_DIR}/../_common/askuserquestion.md`** and apply its hard constraints to every question this skill asks.
- `ToolSearch("select:Artifact,ArtifactComments,ArtifactData")` — at the start of 발행, 동기, 발행 묶음 다시 생성 and 구현 승인. A missing schema is the publish contract's preflight failure (Step 4).
- `Agent` is built-in. Authors and reviewers are spawned with it, read-only, with the `model` from Step 1's model table.

The question points below carry their judgment grade (`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`).

## Step 1: Resolve

1. The first `.md` token of `$ARGUMENTS` is the design document. Derive the document key, `{slug}` and `<base>` per `${CLAUDE_SKILL_DIR}/references/sidecar.md` §1, from the document's own directory.
2. Read the sidecar `<base>/docs/visual/{slug}.md` if it exists. Its machine header must be `cc-visual v1` and its `owner-doc=` must equal the document key; otherwise stop and say which — it belongs to another document whose slug folds to the same name, and this skill does not write over it.
3. Read `<base>/docs/visual-system/system.md` if it exists and check `owner-repo=` per `sidecar.md` §3. A mismatch or an absent field means the repository has no design system this skill may use; say so.
4. Run `visual-config.sh models` and keep the table it prints (`contract.md` §6). Report any line it wrote to stderr.
5. If the host ban list `${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds/visual-bans` does not exist, run `visual-config.sh seed` once and report it — this is the first use. Then run `visual-config.sh bans` into a temporary file outside the tree; that file is this invocation's ban list.

## Step 2: Choose and announce the phase

- `등급 0` Confirm the phase CFI-1 picked with one AskUserQuestion, 옵션 `<국면> 진행 ← 추천` / `중단`. When the sidecar is `발행됨`, this is instead the choice below.
- `등급 2` On `발행됨`, AskUserQuestion with 옵션 `동기` / `발행 묶음 다시 생성` / `구현 승인` / `금지 후보 승인` (the last only when the sidecar has a `### 금지 후보` line) / `중단`. Each option's description says what it moves: sync and republish move the baseline and delete `**구현 승인**`; 구현 승인 writes that line; candidate approval writes the host ban list.

At the start of every phase that generates or polishes locally, tell the person that the local authors run on this seat's account and use its usage.

## Step 3: 생성 / 생성 이어 하기

**Direction.**

- 생성 (no sidecar): there is no run to inherit, so no record is looked up. `등급 2` Ask the direction with AskUserQuestion — 옵션 `방향을 적는다` / `레포 디자인 시스템만 따른다` / `중단` — and ask for the screen list when the document does not enumerate its screens. The answers are this invocation's direction.
- 이어 하기 (`로컬 초안`): read the record the sidecar's `**기록**` names. Use its `## 시각 방향` only when the file's sha256 equals the field and its version token is `cc-run-interview v3`; otherwise do not use it and ask the direction as above. Carry over the earlier rounds' screens and the `**검토**` count.

**Design system.** With a usable `system.md` (Step 1.3) read `tokens.css`·`tokens.md` and its `**금지 해제**` lines. Without one, generate it: spawn a `ds-generate` author (`contract.md` §6, file-block envelope) for `tokens.css`, `tokens.md` and `system.html`, and write `system.md` with `**출처**: 신규` and `**아티팩트**: (미발행)`.

**Screens.** Spawn a `screen-generate` author per screen with the document, the direction, the tokens and `contract.md` §2; write each returned file block to `docs/visual/{slug}.<id>.html` atomically. Write the sidecar as `로컬 초안` with the fields of `sidecar.md` §2.

**Review loop** (CFI-5), per round:

1. Render each screen with `visual-capture.sh ref <screen> --out <mktemp -d outside the tree>`. Where it reports `비교 안 함`, review from the HTML and set `**검토 렌더**: 불가(환경)`.
2. Run `visual-check.sh scan <screens> --bans <Step 1.5 list> [--lifts <system.md>]`.
3. Spawn a fresh reviewer with `contract.md` §3, the screens, the renders, the scan output and the ban list's `판단` items. The verdict is the structural rule of §3, never the reviewer's opinion.
4. Record each reviewer candidate under `### 금지 후보`.
5. `ACCEPT` → set `**상태**: 검토 통과`, update `**검토**`, remove the render directory and go to Step 4 only if the person asks; otherwise end with the next-step line `/cc-cmds:visual <문서>` (발행).
6. `REJECT` → build the fix list and polish it per `contract.md` §7, write the `**다듬기**` line, next round.

- `등급 2` After the third failed round, AskUserQuestion with 옵션 `방향을 바꿔 다시 생성` / `로컬 초안으로 둔다` / `중단`, showing the last round's findings. The sidecar stays `로컬 초안` unless the person chooses otherwise.

## Step 4: 발행 (`검토 통과`)

The publish contract has five parts.

- **(a) Preflight.** The Artifact tools loaded (Step 0) and a claude.ai login present. Either missing → stop with an explicit message naming which. Then K0.
- **(b) Success is a returned URL.** K1, then create the Design artifact from the screen files (one artboard per screen, each file as written). A call that returns no URL is a failure; say so and stop. K2 on the returned URL. If K2 fails, the publish has already happened: write nothing locally, leave the sidecar `검토 통과`, and show the orphan URL with the two local parts the helper printed. Do not delete the orphan and do not reuse it — the next run in the pinned seat is a new first publish.
- **(c) Pull back and pin.** K1, then read each screen back through its URL and overwrite the local screen file with that source; pin `**아티팩트**`·`**버전**`·`**sha256**`·`**동기 시각**` and `**스냅숏 형태**`. In the same read take the canvas type file `artifact-type/dc-runtime.js` and place it as `docs/visual/support.js`, pinning `**런타임**`.
    - `등급 2` If the received bytes differ from an existing `support.js`, AskUserQuestion before overwriting — 옵션 `덮고 재고정` / `덮지 않는다` / `중단` — showing every other sidecar that pins `**런타임**` and the two type releases. This moves other documents' baselines, so it is a risk acceptance. `덮고 재고정` re-pins those sidecars' `**런타임**` in the same write and reports the list. `덮지 않는다` leaves this document's `**스냅숏 형태**` at `초안` and emits no paste block.
- **(d) Baseline.** Only publish and sync move it (CFI-3) — including a shared-runtime change another document's publish makes, which that seat re-pins under (c).
- **(e) No unattended twin.** Publishing and syncing are never done by a stage.

When `system.md` is `**출처**: 신규` and `**아티팩트**: (미발행)`, the publish phase also creates the Design System artifact from the token list of `contract.md` §1 (`project/tokens.json`) and pins its URL in `system.md`; the canvas carries the same list as `project/ds/<folder>/tokens.json`. DesignSync is not driven from here — its tool limits it to a user-started `/design-sync`; for a React design system, suggest `/design-sync` and stop there.

Set `**상태**: 발행됨` and emit the paste block (Step 6).

## Step 5: `발행됨`

**동기.** K0, then for each pinned URL K1 + K3. Read the artifact's open comments with `ArtifactComments` and show them, then pull each screen back as in Step 4 (c), comparing first against the pinned values (CFI-3). Delete `**구현 승인**` in the same write and say so.

**발행 묶음 다시 생성.** Run Step 3's generation and review in a temporary directory outside the tree; the screen files are not touched. On `ACCEPT`, publish as a new version of the same artifact (K1, K2 on the same URL) and pull back as in Step 4 (c); the sidecar stays `발행됨` and `**구현 승인**` is deleted. On failure the screen files and the sidecar stay as they were.

**구현 승인.** In this order, in one invocation:

1. K0.
2. K1 + K3 for every pinned URL. If the bytes read differ from the screen file, show the move as sync does and pull it back first.
3. `**스냅숏 형태**` is `초안` → refuse, and say that the runtime question of Step 4 (c) left it there.
4. `visual-check.sh scan <screens> --bans <Step 1.5 list> --lifts <system.md>`. Any `external-ref` finding → refuse. Show the remaining findings grouped by rule id.
    - `등급 2` AskUserQuestion for the acceptance set — 옵션 one per rule id found (multi-select) / `수용하지 않는다` / `중단` — saying that an accepted id lets the implementation take those findings as they are. With findings left that the person does not accept, do not write the line; say what to fix and that this phase can be run again.
5. Measure `visual-check.sh bundle <document>` and the sha256 of the host ban list file, then write `**구현 승인**: <now, ISO8601 UTC> — 입력 묶음 <bundle> — 금지 목록 <sha256> — 기계 검사 수용 <ids | 없음>` (`sidecar.md` §2). Confirm with `visual-check.sh approval <document>` and report its line.

After writing, tell the person: if an autopilot run is waiting on these screens, answer its seat question with `승인` (or tell it to continue).

**금지 후보 승인.** For each line under `### 금지 후보`, show the id, kind, description, pattern and source screen.

- `등급 2` AskUserQuestion per candidate — 옵션 `승인` / `거절` / `나중에` — and for `승인` pass the line verbatim to `visual-config.sh append` and report its output. Remove approved and rejected lines from the sidecar; keep `나중에`.

## Step 6: The paste block

Only on `발행됨`, and never when `**스냅숏 형태**` is `초안`, emit a `## 시각 정합 기준` block for the person to paste into the design document — this skill never writes it there:

```
## 시각 정합 기준

- 프로토타입 SOT: docs/visual/{slug}.<id>.html (support.js 와 함께 렌더)
- 렌더 힌트: <선언된 뷰포트, 테마>
- 대상 화면:
  - <화면 id> → docs/visual/{slug}.<id>.html
```

**Warn with the block.** Once pasted, an unattended implementation of this document stops at the marker. If the sidecar's `**기록**` names a run, tell the person to paste the block only after that run's unattended screen slices are done, and name the run id from the record path.

## Constraints

- Writes are limited to `<base>/docs/visual/` (this document's sidecar, its screen files, `support.js` and the other sidecars Step 4 (c) re-pins), `<base>/docs/visual-system/`, temporary directories outside the tree, and the host ban list through `visual-config.sh`. Every link-file and extract write is the same-directory temp file → rename of `../_common/sidecar.md`. Nothing here is staged or committed.
- Token values are never normalized; theme wrappers are kept verbatim (`contract.md` §1).
- Never write the design document. The paste block is emitted, not written.
- Never reach a notification surface: no `PushNotification`, no `notify.sh`, no `terminal-notifier`.
- **Deferred tool loading**: AskUserQuestion and the Artifact tools are deferred and must be loaded by Step 0 before use.

Document: $ARGUMENTS
