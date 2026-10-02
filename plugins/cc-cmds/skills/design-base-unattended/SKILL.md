---
name: design-base-unattended
description: 베이스 설계의 무인 팔 — 좌석·드라이버가 파견하면 베이스 문서의 토론·저장(드라이버면 동결까지)을, `--split` 이면 감사 뒤 분할 점검과 트래커 발행을 돈다 (질문은 park·정지 기록으로)
when_to_use: 사람이 직접 부르지 않는다. `design-base` 리드 좌석이 Step 2 승인 뒤 `claude -p` 로 파견하거나(다리), autopilot 이 베이스 런의 설계 단계와 분할 단계로 파견한다(스테이지)
disable-model-invocation: true
usage: "/cc-cmds:design-base-unattended <brief-or-doc-path> [<task-sentence>] | --split <문서>"
options:
    - name: "<brief-or-doc-path>"
      kind: positional
      required: true
      summary: "좌석 파견: `docs/design-brief/{slug}.md` — `design-base` 좌석이 쓴 인터뷰 브리프. 드라이버 파견: 베이스 설계 문서 경로(메인 워크트리 절대 경로 — 아직 없을 수 있다)."
      parse_note: "`$ARGUMENTS`의 첫 `.md` 토큰. 어느 파견인지는 `CC_PIPELINE_RUN_ID` 의 유무로 가른다."
    - name: "<task-sentence>"
      kind: positional
      required: false
      summary: "드라이버 파견에서만 — 매니페스트 `## 의도` 의 첫 줄."
      parse_note: "첫 `.md` 토큰 이후의 모든 내용. 좌석 파견과 `--split` 에서는 무시한다."
    - name: "--split <문서>"
      kind: flag
      default: "off"
      summary: "분할 단계 — 감사를 마친 베이스 문서를 다시 점검하고 매니페스트 `베이스 발행` 행대로 트래커에 발행하거나 문서만으로 기록한다. 드라이버 파견에서만 쓴다."
      parse_note: "`--split` 다음의 첫 `.md` 토큰이 베이스 문서 경로(메인 워크트리 절대 경로)다."
notes: "설계 흐름은 `design-discuss-unattended` 를 치환과 함께 읽어 돈다. 분할 단계의 멈춤 자리는 닫힌 다섯 개이고, 마지막 줄은 「베이스 분할을 마쳤습니다.」다."
---

Run the unattended part of `/cc-cmds:design-base` in a headless session, **without ever asking a human**. In the design flow it is `design-discuss-unattended` with substitutions, saving (and, under driver dispatch, freezing) a base design document. In split mode it checks the audited document again and publishes its tickets as the run's frozen `베이스 발행` row says.
Team communication is English. Everything written for a person — the saved document, `presentation.md`, a park or halt record — is Korean.

This file is a separate arm so that "it has no human-question surface" is a whole-file predicate `scripts/lint-unattended-surfaces.sh` can check. The document grammar, the predicates, the issue-body rules and the registry are defined in `${CLAUDE_SKILL_DIR}/../_common/base-design.md`; read it before Step 0.

## Control-Flow Invariants

These rules MUST stay near the top of this file: post-compaction reattaches only the first ~5K tokens with priority.

### CFI-U0 — There is no human-question surface

The question tool is absent from the Step 0 roster and from every step below, in both modes. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its escalation cases terminate in a question to the user, **this arm resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule. Under seat dispatch `park` is the park record; under driver dispatch and in split mode it is the halt record.

**The remaining invariants are those of `${CLAUDE_SKILL_DIR}/../design-discuss-unattended/SKILL.md`** — CFI-L1 through CFI-L4 — read and followed as written, with this arm in place of that one. In split mode CFI-L3 holds unchanged: no notification surface, no pipeline sidecar, a halt record only.

## What is read from `design-discuss-unattended`

Read `${CLAUDE_SKILL_DIR}/../design-discuss-unattended/SKILL.md` and take from it, unchanged: the discriminator `CC_PIPELINE_RUN_ID` and the two dispatchers; the park record and the halt record (driver dispatch) and their mechanics; the **nine park sites** and the **seven driver-dispatch sites**. One driver site is renamed here: **`slicing-unknown` reads `split-unrepairable`** — a base document has no slicing section, and the repair that can fail is the one of `base-split.py check` (Step 7U below).

### Per-grade disposition

The attended skill marks its ask points with a judgment grade (`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`); this arm's disposition is per grade, as in `design-discuss-unattended`:

- **`등급 0`** — no disposition is needed; an already-written rule determines the answer. The split mode's duplicate rule is one: a normalized-title equality with an open item stops the stage, and any other candidate is recorded and passed.
- **`등급 1`** — reachable only under driver dispatch, only as a Step 5U walkthrough disposition that does not change the skeleton, emitted as one bundled `설계-쟁점` judgment exactly as `design-discuss-unattended` describes. A disposition that touches `## 티켓 간 계약` or `## 티켓 분할` is skeleton (below) and never reaches this grade.
- **`등급 2`** — the park record under seat dispatch, the halt record under driver dispatch and in split mode, then stop.

## Workflow — design flow

### Steps 0–2

**Read Step 0, Step 1 and Step 2 of `design-discuss-unattended` and follow them**, with one difference: the default roster under driver dispatch is this one, frozen here and read, never chosen.

```
- `설계 로스터` | 역할=architecture | 범위=the requirement's structure, contracts and interfaces across the affected surfaces, and the alternatives to them | 모델=opus
- `설계 로스터` | 역할=codebase-impact | 범위=the files, call sites, tests and conventions the design touches, read from the tree | 모델=opus
- `설계 로스터` | 역할=split | 범위=the ticket graph: contracts between tickets, dependency edges, owned and shared files per repository, critical path and parallel width, checked against _common/base-design.md predicates | 모델=opus
- `설계 로스터` | 역할=verification | 범위=settle the discussion's verifiable claims against the tree per _common/verification.md, pre-registering claim and expected result | 모델=sonnet
```

Under seat dispatch the brief's header names `writer=design-base; reader=design-base-unattended`; the version token `cc-design-brief v1`, `owner-doc=`, the eight blocks and the terminator are guarded exactly as `design-discuss-unattended` guards them. `**슬라이스 수**` reads `없음`, and `## 요구사항` carries the publish line `발행: …` as information for the document, never as an instruction to publish.

### Steps 3–4: Interim body

**Read `### Step 3 · Step 4: Interim body` of `design-discuss-unattended`** — which reads the base skill's Step 3 and Step 4 with its substitutions 1–6 — and add three:

7. **The document is a base document.** Step 4's section list is replaced by the template of `base-design.md` §1: the discriminator line, `## 티켓 간 계약` with one `### 계약 C<n> — ` block per contract, and `## 티켓 분할` with its header fields, the base ticket and one `### 티켓 T<n> — ` block per ticket. `## 구현 슬라이싱` and `## 테스트 설계` are not written.
8. **Every member prompt carries the constraint** "Decide nothing below the contract level: a ticket's implementation is its own later design." The split seat drafts the graph; the synthesis runs `base-split.py check` once on the saved document and fixes what it reports before the save completes.
9. **The skeleton grows.** For Step 5U's skeleton predicate, `## 티켓 간 계약` and `## 티켓 분할` are part of the skeleton beside the binding tier, read by section identity — a disposition that writes inside either fits no enumerated write form.

### Step 5 (seat dispatch) · Steps 5U–6U (driver dispatch)

Read and follow `design-discuss-unattended`'s Step 5, Step 5U and Step 6U as written.

### Step 7U: Coherence, split check, residual ladder, freeze (driver dispatch)

Read `design-discuss-unattended`'s Step 7U and follow its five jobs in order, with the second replaced:

2. **Split check.** Run `"${CLAUDE_SKILL_DIR}/../../orchestrator/base-split.py" check <문서>` through `gate.sh exec --surface 읽기`, by path. Repair each reported violation in place and run it again until it exits 0. A repair that needs a decision the authors did not make — moving an owned file between tickets, removing an edge, accepting a depth above two without a reason the document already states — → halt `split-unrepairable`, with the check's output lines in `관측 상세`.

The freeze is unchanged and byte-identical: `**상태**: 동결됨` on the status line, then the literal 「설계 문서를 동결했습니다.」 on its own line, the document path and its whole-file `sha256`.

## Workflow — split mode (`--split <문서>`)

Driver dispatch only: `CC_PIPELINE_RUN_ID`, `CC_PIPELINE_RUN_DIR`, `CC_PIPELINE_STAGE_ID` and `CC_PIPELINE_MANIFEST` are read by name. Every Bash command goes through `gate.sh exec`; plugin scripts are called by path as argv0, never behind an interpreter. `BS` below is `${CLAUDE_SKILL_DIR}/../../orchestrator/base-split.py`, `OUT` is `${CC_PIPELINE_RUN_DIR}/split/${CC_PIPELINE_STAGE_ID}/`. In this order:

1. **Check.** `BS check <문서>` (`--surface 읽기`). Any violation → halt `split-check-failed`, the output lines in `관측 상세`.
2. **Open audit items.** An entry of `## 미해결 이슈 / 트레이드오프` at `상태: 대기` → halt `audit-open-items`, naming each entry.
3. **Publish row.** Read the manifest's `## 인가` for exactly one row `` - `베이스 발행` | 트래커=<github|clickup|없음> | 대상=<owner/name|목록 id|-> `` in the form of `base-design.md` §6. None, several, or one that does not fit that form → halt `publish-not-authorized`. The row is the whole of the decision; the brief and the document's publish line are not read for it. **It is an authorization only because it is frozen**, and the freeze is the driver's: the row counts only when the manifest's binding digest serializes it, which the installed driver does when `${CLAUDE_SKILL_DIR}/../../orchestrator/run.sh` names the row literal in its binding set. Confirm that before reading the row as an authorization — `grep -n -F '베이스 발행' <run.sh>` through `gate.sh exec --surface 읽기` — and when it finds nothing, halt `publish-not-authorized` stating that the installed driver does not freeze the row. A row the digest does not cover can be written after kickoff without moving the digest, so reading it would let an unfrozen line authorize tracker writes.
4. **Registry.** When `docs/design-base/<slug>.tickets.md` exists beside the document, its header `doc-sha256` must equal the document's current whole-file `sha256` → otherwise halt `split-check-failed`.
5. **Duplicates** (`트래커` other than `없음`). Before any tracker write, for the base ticket and then every ticket, run `similar-items.py <github|clickup> --title '<발행 제목>' --body-file /dev/null --lexical-only --format json` (by path from `${CLAUDE_SKILL_DIR}/../../orchestrator/`; GitHub with `--repo <대상>`, ClickUp with `--list <대상>`), declared `--surface 읽기 --reach 협업`. The body is empty on purpose: the plan's body files do not exist yet, and the duplicate rule is a title rule. A returned open item whose normalized title (NFC, whitespace folded, trimmed) equals the query title → halt `duplicate-ticket` with both titles and the item's reference; nothing has been written. **This split's own items are not duplicates**: on a resume the registry already holds rows for what an earlier attempt made, so skip the query for a base or ticket whose registry row is `발행됨` or `발행중` (step 7 settles a `발행중` row by `resolve`), and drop from the results any item whose reference equals a `참조` the registry records. Without this, every resume would stop on the tickets it made itself. Keep every other candidate for step 7 (등급 0, `base-design.md` §5).
6. **Plan** (`트래커` other than `없음`). `BS plan <문서> --row '<행>' --out "$OUT"` — it writes the body files and `plan.jsonl` under the run directory and nothing on a tracker. Exit 3 → halt `split-check-failed` with its reason line.
7. **Publish** (`트래커` other than `없음`). Take the entries of `plan.jsonl` in order and run each `argv` **as given** — this stage never builds or edits an argv — through `gate.sh exec --surface 외부상태변경 --reach 협업`. A step-5 candidate is recorded with `BS record … --entry <id> --plan "$OUT/plan.jsonl" --similar '<참조 목록>'` once its row exists.
    - `create`: `BS record … --entry <id> --state 발행중` first, then the argv, then `BS record … --entry <id> --state 발행됨 --ref <URL>` from its output (`--node-id <id>` besides for ClickUp), before the next entry.
    - `edit` · `relate`: the argv, then `BS record … --entry <id> --state 발행됨 --ref -`.
    - `resolve`: a row left `발행중` by an earlier attempt. Read the target with the step-5 command — `similar-items.py <github|clickup> --title '<entry title>' --body-file /dev/null --lexical-only --format json` with the same target flag, declared `--surface 읽기 --reach 협업` — and keep the open items whose normalized title equals the entry's `title`: one → `--state 발행됨` with its reference (`--node-id` besides for ClickUp); none → `--state 없음`, and the next plan creates it again; several → halt `tracker-error`.
    - `wait`: run `BS plan` again after the entries before it are recorded, and continue with the new plan until it holds no `wait`.

    Any tracker error, any non-zero exit of an argv, or a `record` refusal → halt `tracker-error`, the failing argv and its error verbatim in `하네스 오류`, and the registry path in `관측 상세` — the registry shows exactly how far the split got and is the idempotent ledger of the next attempt.
8. **No tracker.** `트래커=없음` → in place of steps 5–7, `BS record <문서> --row '<행>' --doc-only`. No `plan` runs and no tracker command is issued.
9. **Terminal.** End with the line 「베이스 분할을 마쳤습니다.」 as the last line of the terminal message, preceded by the registry path. Name no next step.

**Split-mode sites are a closed set of five**, all first-failure sites: `split-check-failed` · `audit-open-items` · `publish-not-authorized` · `duplicate-ticket` · `tracker-error`. The record is `cc-pipeline-halt v1` of `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4, at `${CC_PIPELINE_RUN_DIR}/halt/${CC_PIPELINE_STAGE_ID}.md`, with the site after the step identifier in `스텝` (`Split 7 / tracker-error`); stop at the **first** site reached. Each site has one `분류`: `split-check-failed` · `publish-not-authorized` · `tracker-error` → `precondition-failed`; `audit-open-items` · `duplicate-ticket` → `gate-unanswerable` (a person decides the open entry, or whether the candidate is the same work). One exception: an act the gate parked (exit 11) is `gate-unanswerable` at whichever site it stopped, with the gate's `도달 판정` in `관측 상세`, so a refusal by the gate is never filed as a tracker error. Adding a site takes on the closed-set duty of `design-discuss-unattended`.

## Constraints

- NO code modifications. The registry is written only by `BS record`; the base document is never edited in split mode.
- Every member prompt carries CFI-U0 verbatim, the no-banner sentence of `design-discuss-unattended`'s Constraints and its research paragraph verbatim.
- Under driver dispatch and in split mode every Bash command goes through `gate.sh exec` with the `--reach` discipline of `implement-unattended`'s CFI-U7; call external commands directly, never inside `bash -c`; read pipeline variables by name, never with bare `env`.
- Never reach a notification surface; never write `pipeline-grant` or `pipeline-run`.

Task: $ARGUMENTS
