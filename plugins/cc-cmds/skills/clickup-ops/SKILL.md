---
name: clickup-ops
description: ClickUp 티켓 작업 절차 — 티켓 생성 전 유사 티켓 조회, 생성 시 담당자·상태 미지정, 티켓에서 출발한 작업 착수 시 유사 티켓 조회
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

## 2. Assignee and status on creation

- Do NOT set an assignee or a status when creating a ticket. Creating a ticket is backlog registration only; an assignee or an in-progress status stamped at creation makes an untouched ticket look owned or started.
- Assignment and the status change happen when work on the ticket actually starts. Those writes belong to the user's global instructions and are not repeated here.

## 3. Before creating a ticket — similar-ticket lookup

`<plugin root>` below is the directory holding `orchestrator/` and `skills/` — the parent of this skill directory's parent. Substitute it yourself before the command reaches a shell: it is not a shell variable, and `${CLAUDE_SKILL_DIR}` written into a command expands to an empty prefix.

- The list id is a required input. Take it from the user's request; when the work started from a ClickUp ticket, take that ticket's list; with neither, ask the user. Do NOT guess one and do NOT store a default.
- Immediately before creating the ticket, write the draft description to a file and run `<plugin root>/orchestrator/similar-items.py clickup --list <ID> --title "<draft title>" --body-file <file>` — directly, with no `python3` or other interpreter in front.
- Then create the ticket from the same file with `<plugin root>/orchestrator/clickup-create.py --list <ID> --name "<title>" --description-file <file>`, again with no interpreter in front. It prints `<id>` and `<url>` of the new ticket on one line. It refuses with exit code 5 inside an unattended pipeline run, which files no ticket.
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
