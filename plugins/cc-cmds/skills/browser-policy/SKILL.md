---
name: browser-policy
description: playwright(-cli) 사용 규약 — `-s=` 로 세션을 격리하는 세션명 작명 규칙과 팬아웃 시 인덱스 배분, headless 기본 원칙과 `--headed` 승격이 허용되는 조건·승격 주체
when_to_use: 브라우저 자동화를 시작하거나 세션명을 정할 때, 그리고 사람 개입 게이트에 막혔을 때
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. 브라우저 자동화 직전에 모델이 열어 그대로 따른다.)"
options: []
notes: |
    슬래시 커맨드 surface 가 없는 model-invoked 정책 스킬이다. `playwright-cli` 스킬을
    대체하지 않는다 — 그 스킬을 쓸 때 지켜야 할 세션 격리와 headless 규약만 싣는다.
---

# browser-policy

Rules for driving a browser with the `playwright(-cli)` skill.

## 1. Session naming — always isolate with `-s=`

- **Always pass an explicit session name** with `-s=<session>` so the session is isolated. Omitting it shares the `default` session with other Claude Code sessions, and tabs and login state collide.
- The name is always `<task/project identifier>-<session discriminator>`, whether the session is standalone or part of a fan-out — e.g. `-s=<repo>-7f3a`. **An identifier alone is not enough**: another session working in the same repository will pick the same name and collide.
- The discriminator is a short random value, and it must come from **an actually invoked random generator** (e.g. `openssl rand -hex 2`) — never chosen by eye. A deterministic value like a branch name or a date, or a value that merely "looks random", makes two concurrently running sessions pick the same base, which also repeats agent indices across sessions.
- **When spawning several agents at once**, whatever the tool (`Workflow`, `Agent`), **the lead** appends a distinct index per agent to that base (e.g. `-s=<repo>-7f3a-a3`) and **writes that session name into each agent's prompt**.
- **An agent that receives a session name from its lead uses it verbatim and does NOT invent its own.** Reading that sentence as not applying to itself and re-deriving a name from the repository name merges back the sessions the lead just split apart.

## 2. headless is the default

`open` runs **headless** and quietly by default. `--headed` is permitted in
exactly two cases:

1. **Real-time human operation that automation cannot substitute for** — entering a 2FA code, a CAPTCHA, clicking through OAuth consent, device approval: moments a human hand must be in. A login that can be automated from stored credentials (`env.md` and the like) does NOT qualify, so stay headless for it. What needs headed is not the login itself, only the authentication step that only a human can pass.
2. **The user explicitly asked to watch the screen.** A confirmation right before an irreversible action (submit, payment, delete) or an eyeball check of the result is headed **only when the user asked for it**.

Everything else — pure automation such as scraping and verification, and any
automatable login — is headless.

## 3. Promotion to `--headed`, and who may do it

When a headless run hits an unexpected human-intervention gate (a sudden login
wall, CAPTCHA, 2FA):

- Reopen the session with `--headed` to promote it, and tell the user what needs to be operated. Preserve progress with a persistent profile where possible.
- **Only an agent that was not spawned by another agent may promote.** An agent spawned from above must NOT reopen with `--headed` on its own when it meets that gate — it reports only, to the side that spawned it, saying which session is blocked on what. If each agent promotes on its own, several windows open in front of the user at once with no attribution to the work that opened them.
- **The reporting agent ends its turn and closes that session's browser, handing it to the lead** (do NOT delete the profile). Holding it keeps the report from going out and makes the lead's `--headed` reopen collide with that session.
- **Even when not spawned by another agent, do not promote if the run is one the user is not watching.** Instead, leave the blocking point in the return statement and end the turn — the same prescription as any wait on human operation. Do not poll: human operation does not arrive on its own.
