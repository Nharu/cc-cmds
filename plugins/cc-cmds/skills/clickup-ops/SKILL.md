---
name: clickup-ops
description: ClickUp 티켓 작업 절차 — 티켓 생성 전 유사 티켓 조회, 생성 시 리스트가 쓰는 필드만 참조 티켓 값으로 채우고 상태는 미지정, 발행 뒤 재조회 확인, 티켓에서 출발한 작업 착수 시 유사 티켓 조회
when_to_use: ClickUp 티켓을 만들기 직전, 또는 ClickUp 티켓에서 출발한 작업을 착수할 때
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. ClickUp 티켓 작업 직전에 모델이 열어 그대로 따른다.)"
options: []
notes: |
    슬래시 커맨드 surface 가 없는 model-invoked 정책 스킬이다. 모델은 frontmatter
    `description` + `when_to_use` 로 호출을 결정하고, body 의 네 절을 해당 행위 직전에
    그대로 적용한다. 이 스킬은 어떤 명령도 대신 실행하지 않는다 — 절차만 싣는다 — 유사 티켓 조회 도구와 티켓 생성 도구 둘을 가리킨다.
---

# clickup-ops

Procedures for ClickUp ticket work. Apply before creating a ticket and when
starting work that originates from a ticket.

## 1. Ticket description — describe the problem, not the fix

Write the ticket description by the same rule as a GitHub issue body: `github-ops` `## 1. Issue body — describe the problem, not the fix`. It is not repeated here.

## 2. Fields and status on creation

- Do NOT set a status or a tag when creating a ticket. An in-progress status stamped at creation makes an untouched ticket look started; the status change happens when work on the ticket actually starts, and that write belongs to the user's global instructions.
- Fill the assignee, start date, due date and priority only where the list uses that field. Read the list first (`<plugin root>` as defined in `## 3.`) with `<plugin root>/orchestrator/similar-items.py clickup --lexical-only --list-fields <ID> [--task-fields <reference id>] --log <file>` (no interpreter in front; GETs only, no judgment call, one JSON document written to `--log`). A field is in use when more than half of the list's open top-level tickets set it — exactly half, or no such ticket, leaves it empty. Do not count the ticket the new one splits off, nor tickets created in the same pass.
- A field in use takes its value from a reference ticket, never from a guess: the assignee and priority of the ticket the new one splits off (with no assignee there, the assignees every in-use ticket sharing a tag with it has in common; with no priority there, the most common priority in the list, and a tie gives no value); the start date from the latest due date of the existing tickets the new one waits on, the due date from the earliest start date of those that wait on it, and with neither, that ticket's own dates. Copy the `*_date_time` flag only when the reference response carries the key. A field in use with no value is left empty — say so in the report.
- A document that came back with `"partial": true` is not a basis for any field: report its `reason` and create the ticket without the fields.

## 3. Before creating a ticket — similar-ticket lookup

`<plugin root>` below is the directory holding `orchestrator/` and `skills/` — the parent of this skill directory's parent. Substitute it yourself before the command reaches a shell: it is not a shell variable, and `${CLAUDE_SKILL_DIR}` written into a command expands to an empty prefix.

- The list id is a required input. Take it from the user's request; when the work started from a ClickUp ticket, take that ticket's list; with neither, ask the user. Do NOT guess one and do NOT store a default.
- Immediately before creating the ticket, write the draft description to a file and run `<plugin root>/orchestrator/similar-items.py clickup --list <ID> --title "<draft title>" --body-file <file>` — directly, with no `python3` or other interpreter in front.
- Then create the ticket from the same file with `<plugin root>/orchestrator/clickup-create.py --list <ID> --name "<title>" --description-file <file>`, again with no interpreter in front. It prints `<id>` and `<url>` of the new ticket on one line. Add `--parent <task id>` to make the ticket a subtask of a task in the same list, and the fields `## 2.` decided with `--assignee <user id>` (repeatable), `--priority <1-4>`, `--start-date <ms>` / `--due-date <ms>` and, only when the flag was copied, `--start-date-time` / `--due-date-time`. It has no status or tag option. Inside an unattended pipeline run it refuses with exit code 5 unless the run's frozen `베이스 발행` row names `clickup` and this same list — that row is the only thing that lets an unattended run file a ticket.
- To make one ticket wait on another, run `<plugin root>/orchestrator/clickup-relate.py --task <waiting id> --depends-on <blocking id>`, with no interpreter in front. For a ticket that must wait on the new one, swap the arguments: `--task <existing id> --depends-on <new id>`. It reads both tickets first; when the edge is already there it sends nothing, prints `이미 있음` after the pair and exits 0. Inside an unattended pipeline run it refuses with exit code 5 unless the frozen `베이스 발행` row names `clickup` and both tickets sit in that row's list.
- After creating and relating, read the new tickets back (`--list-fields <ID> --task-fields <new id>…`) and check that the assignee, priority, dates, parent and dependencies are the ones you sent. Report any difference; do not paper over it with a second write.
- The lookup output is candidates only. Do NOT withhold, postpone, merge or rewrite the creation because of it, and do NOT close, comment on, reassign or link any candidate. Report the candidates next to the new ticket's id and URL in the same message.
- If the output carries a `notice:` line, relay it verbatim. `status=unavailable` means the lookup did not run: say so in one line and create the ticket anyway.
- Creating several tickets in one pass: run the lookup for each ticket only after the previous one has been created, so that a ticket created earlier in the pass is in the next one's corpus.

## 4. Starting work from a ticket outside design

`<plugin root>` below is the directory holding `orchestrator/` and `skills/` — the parent of this skill directory's parent. Substitute it yourself before the command reaches a shell: it is not a shell variable, and `${CLAUDE_SKILL_DIR}` written into a command expands to an empty prefix.

- When work that starts from a ClickUp ticket does not go through `design` (whose Step 1 runs the same lookup), run `<plugin root>/orchestrator/similar-items.py clickup --task <ID|URL>` with no interpreter in front. It compares the ticket against every open ticket in its space and marks candidates in the same list.
- Treat the list as the starting set, not the verdict. If candidates worth handling together exist, propose them via `AskUserQuestion`.
- Link an accepted ticket in the PR body by its URL. Do NOT write it as `Closes #N` — that form closes GitHub issues only.
- The writes that follow acceptance (assigning the ticket, moving it to IN PROGRESS, re-reading it) belong to the user's global instructions and are not repeated here.

When you are running as an unattended pipeline stage (`CC_PIPELINE_RUN_ID` is set), add `--lexical-only`, do not propose the candidates or ask about them, and copy the output lines — the `similar-items:` line, any `notice:` line and the candidate lines — verbatim into the report the stage writes when it finishes. Proceed with the original ticket's scope.
