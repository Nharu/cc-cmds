---
name: design-base
description: 여러 티켓으로 나눌 큰 작업의 베이스 설계 — 티켓 간 계약과 병렬화 최대의 티켓 분할을 설계하고, 감사 뒤 트래커 발행까지
when_to_use: 요청이 각자 독자적 설계 판단이 필요한 조각들로 나뉘는 큰 작업이라, 단일 설계 문서 하나로 구현 슬라이스를 나누기보다 먼저 조각 간 계약과 티켓 분할을 정하고 조각마다 따로 설계하려 할 때
disable-model-invocation: true
usage: "/cc-cmds:design-base <task> | --split <문서>"
options:
    - name: "<task>"
      kind: positional
      required: true
      summary: "베이스 설계를 진행할 작업 주제 (자유형 한국어/영문 텍스트). `--split` 모드에서는 쓰지 않는다."
      parse_note: "`$ARGUMENTS` 에 `--split` 토큰이 없으면 전체가 작업 주제다."
    - name: "--split <문서>"
      kind: flag
      default: "off"
      summary: "분할 모드 — 동결·감사를 마친 베이스 설계 문서를 다시 점검하고, 고른 트래커에 베이스 티켓과 각 티켓을 발행하거나 문서만으로 분할을 기록한다."
      parse_note: "`--split` 다음의 첫 `.md` 토큰이 베이스 문서 경로다. 있으면 설계 흐름(Step 1–7)은 돌지 않는다."
---

Conduct a **base design** for the given task: the upper design of a piece of work that will be cut into several tickets, each of which gets its own `/cc-cmds:design` later. A base design fixes the contracts between the tickets and the ticket split itself, and leaves every implementation below the contract level to the tickets.
All team discussions and inter-agent communication are English. User-facing communication and the saved document are Korean.

This skill is `/cc-cmds:design` with substitutions, not a copy of it. Every step below that says *read* names the section of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` to read and follow; what this file states is only what differs. The document grammar, the check predicates, the issue-body rules and the split registry are defined once in `${CLAUDE_SKILL_DIR}/../_common/base-design.md` — read it before Step 1.

## Control-Flow Invariants

These rules MUST stay near the top of this file: post-compaction reattaches only the first ~5K tokens with priority.

**Read the `## Control-Flow Invariants` section of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` (CFI-1a through CFI-4) and follow it as written**, with the discussion leg being `design-base-unattended` wherever it names `design-discuss-unattended` **as the skill the seat dispatches or waits on** — and nowhere else. A file header the seat matches in what the leg writes (`park.md`, `presentation.md`, `coherence.md` and their `writer=design-discuss-unattended` token) is read byte for byte as written: `design-base-unattended` follows that skill's steps and writes those headers unchanged, so rewriting the token in a predicate would make every completed leg look incomplete. Three invariants are added:

- **CFI-B1 — No `## 구현 슬라이싱`.** A base document never carries that section; the ticket split (`## 티켓 분할`) takes its place. Writing it makes the document fail its own discriminator, and the driver would cut implementation segments out of a document that has none.
- **CFI-B2 — `base-split.py check` passes before the freeze.** Step 7 runs `${CLAUDE_SKILL_DIR}/../../orchestrator/base-split.py check <문서>` where the base skill runs its slicing self-check, and the document is not frozen until it prints nothing and exits 0. The script alone judges the predicates; the lead does not argue a violation away.
- **CFI-B3 — Tracker writes happen only in `--split` mode, after the audit.** The design flow writes no tracker item, and `--split` publishes only the bytes the audit read: the issue bodies are the document's `**발행 본문**` fields copied byte for byte by the plan script, never recomposed.

## Input Parsing

- `$ARGUMENTS` carries `--split` → **split mode** (`## Split mode` below). The first `.md` token after it is the base document path. The design flow does not run.
- Otherwise `$ARGUMENTS` is the task, as `/cc-cmds:design` takes it.

## Workflow

### Step 1: Requirements Interview & Codebase Exploration (Korean)

**Read Step 1 of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` and follow it**, with these differences:

- **Delivery shape without the slice count.** Ask the delivery-shape questions except **how many slices** — a base document is cut into tickets, not slices. The brief's `**슬라이스 수**` line is written `없음`. Skip the base-design suggestion bullet of that step; this skill is where it points.
- **The base criterion.** Confirm with the user that each piece left after the cut still needs its own design judgment. When the pieces are small enough to need none, propose `/cc-cmds:design` instead: `AskUserQuestion` with `베이스 설계로 계속` ← 추천 · `중단 — /cc-cmds:design 으로 다시 시작` (등급 2 — the scope of the work is the person's to decide). No automatic switch.
- **The publish question.** Ask where the tickets go once the document is audited: `AskUserQuestion` with `발행 안 함 (문서만)` ← 추천 · `GitHub 이슈` · `ClickUp` (등급 2 — publishing to a shared tracker is the person's decision). For GitHub take the repository slug (`owner/name`); for ClickUp take the list id. Write the answer into the brief's `## 요구사항` as one line, `발행: 없음 | github <owner/name> | clickup <목록 id>`. One target only, at most 100 tickets, always under a new base ticket (`base-design.md` §4).
- **Where a piece lands.** Each ticket's `**레포**` is the repository its implementation lands in, which is separate from where it is tracked; the delivery-shape answer about repositories feeds those fields.

### Step 2: Team Composition Proposal (Korean)

**Read Step 2 of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` and follow it, including its `Leg dispatch (after approval — the seat launches the discussion leg)` block, its leg pull-check and its recovery ladder**, with these differences — and no other, so the team-size budget and the launch line stay the base skill's and are not restated here:

- Propose a **split seat** among the domain seats: its scope is the ticket graph — contracts, dependency edges, owned files, the critical path and the parallel width — read against `base-design.md` §2.
- The dispatched skill is `design-base-unattended` (`/cc-cmds:design-base-unattended <brief path>`), and the state root is `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/design/{slug}` exactly as the base skill derives it.
- The brief's machine header is `<!-- cc-design-brief v1; writer=design-base; reader=design-base-unattended; owner-doc=<document key>; NOT a design doc; mechanism-local, never staged by a skill -->`; its eight blocks, their order and the terminator `<!-- cc-design-brief: end -->` are the base skill's.

### Steps 3–4: The discussion leg

Run by `design-base-unattended` in its own session (CFI-1a). It saves the document in the grammar of `base-design.md` §1.

### Steps 5–6

**Read Step 5 and Step 6 of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` and follow them as written.** A walkthrough disposition that would change a contract block or the ticket split is a design change and is asked like any other; it is never folded into a body reflection silently.

### Step 7: Coherence pass & freeze

**Read Step 7 of `${CLAUDE_SKILL_DIR}/../design/SKILL.md` and follow it**, except its slicing self-check: in that position run

```bash
"${CLAUDE_SKILL_DIR}/../../orchestrator/base-split.py" check <문서>
```

by path, with no interpreter in front. Each output line is one violation (`D0`, `P1`–`P4`, `B1`). Repair the document in place and run it again until it exits 0 — this is a check, not a review round, so CFI-3(b) is not touched. A repair that needs a decision the user has not made (moving a file between tickets, dropping an edge someone asked for, accepting a depth above two) is asked: `AskUserQuestion` with the repair the check points to ← 추천 · `중단` (등급 2 — the split is the person's design). The freeze waits for exit 0 (CFI-B2).

After the freeze notice, name the next two commands, in Korean:

- `/cc-cmds:design-audit <문서> --base` — the audit, in base mode.
- `/cc-cmds:design-base --split <문서>` — the split, after the audit.

## Split mode

`/cc-cmds:design-base --split <문서>`. Attended, in this order:

1. **Check.** Run `base-split.py check <문서>` (path as in Step 7). Any violation → report the lines and stop; the audited document is not edited here.
2. **Open items.** An entry of `## 미해결 이슈 / 트레이드오프` at `상태: 대기` (an audit hand-off) → report it and stop. It is resolved by a design pass, never in place.
3. **Publish decision.** Read the brief's `발행:` line when it is at hand and offer it as the recommendation: `AskUserQuestion` with the recorded choice ← 추천 · the other two of `발행 안 함 (문서만)` / `GitHub 이슈` / `ClickUp` (등급 2 — publishing is the person's decision). Build the row `` - `베이스 발행` | 트래커=<github|clickup|없음> | 대상=<owner/name|목록 id|-> ``.
4. **No tracker.** `트래커=없음` → `base-split.py record <문서> --row '<행>' --doc-only`, report the registry path, and end.
5. **Plan.** `base-split.py plan <문서> --row '<행>' --out "$(mktemp -d)"`. A refusal (exit 3) is reported verbatim and ends the mode — this includes `ClickUp 도구 미비`, which the script returns before writing anything when a ClickUp tool it would call is missing or does not take an option the plan passes; nothing is created, so no base ticket is left without its children.
6. **Similar items.** For the base ticket and every ticket, follow the similar-item procedure of `github-ops` (GitHub) or `clickup-ops` (ClickUp) with the title and the plan's body file, leaving out this split's own items as `base-design.md` §5 says (a registry row at `발행됨`/`발행중` is not queried, and an item whose reference the registry records is not a candidate). A candidate whose normalized title (NFC, whitespace folded, trimmed) equals an open item stops the mode without a question — report both titles and the item's reference; `base-design.md` §5 already decides it, so there is no question here. Otherwise show every candidate and confirm: `AskUserQuestion` with `이대로 발행` ← 추천 · `중단` (등급 2 — whether a candidate whose title is not equal is the same work is the person's judgment; the rule settles only equality). Record the confirmed candidates with `record … --entry <id> --plan <plan> --similar '<참조 목록>'` after the row exists.
7. **Publish.** Run the plan's argvs **as given**, in order — the script, not this skill, builds them, and this includes the ClickUp argvs, whose argv0 is the tool's absolute path. Before each `create`, `record --state 발행중`; right after it, `record --state 발행됨 --ref <URL>` (`--node-id <id>` for ClickUp). A `resolve` entry is settled by an exact-title read: one match is adopted (`발행됨`), none is `record --state 없음` and the next plan creates it again, several stop the mode. Run `plan` again until no `wait` entry is left. The ClickUp credential is the one `clickup-ops` names; nothing else of that skill changes an argv.
8. **Report.** The registry path (`docs/design-base/<slug>.tickets.md`, never committed), each ticket's reference, and any tracker error verbatim with how far the registry got — it is the idempotent ledger, so a re-run of `--split` resumes from it.

## Constraints

- NO code modifications, as in `/cc-cmds:design`.
- The base document's tracker bodies carry no document path, no label (`T<n>`, `C<n>`, `§`) and no heading line (`base-design.md` §3); `B1` enforces it.
- The registry is written only by `base-split.py record`. This skill never edits it by hand and never stages it.

Task: $ARGUMENTS
