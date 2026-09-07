---
name: fanout-policy
description: 다른 에이전트에게 일을 시킬 때의 규약 — 팬아웃이 맞는 일의 세 종류, 발동 전제조건, 바꾸는 팬아웃의 사용자 확인 게이트, 맡기지 않는 행위 목록, 결과 필터와 대기 규율
when_to_use: 팬아웃·병렬 에이전트·워크플로 사용을 검토할 때와 발동 직전. 도구(`Workflow`·`Agent`·후속 디스패치 도구·스크립트 기동)를 가리지 않는다
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. 다른 에이전트에게 일을 시키기 전에 모델이 열어 그대로 따른다.)"
options: []
notes: |
    슬래시 커맨드 surface 가 없는 model-invoked 정책 스킬이다. 여기 실린 규약은 도구 이름이
    아니라 「다른 에이전트에게 일을 시키는가」로 발동하며, `Workflow`·`Agent`·후속 디스패치
    도구·스크립트 기동을 전부 덮는다. 이 스킬은 팬아웃을 대신 발동하지 않는다 — 절차만 싣는다.
---

# fanout-policy

The rules for handing work to other agents. **Scope is the act, not the tool
name**: `Workflow`, `Agent`, any later dispatch tool, and launching a script
that starts agents all receive every rule below. Where this file says
"workflow agent" and "main session" it means *the spawned agent* and *the
spawning side* — the same things named after one tool.

## 1. The three kinds of work a fan-out is for

Only three kinds:

1. Work that must be swept without a gap, so it is split and covered in parallel.
2. Work you only become sure of after independent viewpoints and adversarial verification.
3. Work too large to fit in one context.

The user has given standing, advance opt-in for fanning out on these three
kinds — it is the user's own request, it does not have to be repeated per task,
and CLAUDE.md / memory instructions count as a direct user instruction for this
purpose. So when work of these kinds arrives and **what the agents are told to
do changes nothing**, call the fan-out without asking for approval, even
outside a skill run. The harness may still refuse the call; that is expected
behavior rather than a fault — proceed solo when it does.

Short conversations, simple edits, and narrow-scope work are not these three
kinds. Handle those solo.

## 2. Ask first — the self-test, and where solo wins

When work looks like it belongs to the three kinds, ask: **"is this work where
an incomplete answer becomes a wrong answer?"** If not, handle it solo.

- A request to explain how, why, or what is solo by default — an explanation does not get better by sweeping wide.
- Solo also wins when a later stage depends on an earlier result, so parallelism never held in the first place.
- Solo wins when more than one round of polishing is expected — fanned-out agents cannot be resumed, so refining costs a full re-run.
- Solo wins when the content is already in this session's context.
- Solo wins when one target's workload is smaller than the cost of spawning one agent, and bundling targets still leaves a bundle under that cost.

## 3. Activation preconditions

Fire only after ALL of these are settled:

- **(a)** The target list is fixed by actual values or by a mechanically enumerable rule (a glob, a command's output). An estimated count or "probably around here" is NOT settled.
- **(b)** One prompt template works for every target. If a sentence is needed for only one target, the set is not uniform.
- **(c)** The return format is decided.
- **(d)** What will be done with the results is decided.

If any one is undecided, scout inline first to settle it — **do not run the
scouting itself as a fan-out**. For repeating patterns, state a repeat ceiling
explicitly. A fan-out launched to sweep without a gap must cover the whole
settled target list — **do not trim the list to fit a recommended agent
ceiling**; bundle targets instead.

## 4. The one-line notice before firing

Announce in exactly one line, in this order: **scope first**, then whether it
is read-only or what it writes and where, then the agent-count ceiling. Example:
"auth 호출부 23곳 전수 감사, 읽기 전용, 에이전트 23개 이하". What a human can
judge in two seconds is the scope and whether it writes — not the number.

For a fan-out that changes nothing, fire immediately without waiting for an
answer. For a fan-out that changes something, pass the confirmation gate in §5
first and give this notice afterwards, right before firing. **The notice is not
an approval gate** — though it is an interruption opportunity, since the user
can skip a running agent. **Never substitute a one-line notice for confirmation
of something hard to undo.**

## 5. Confirmation gate — fan-outs that change things

- Automatic firing is limited to fan-outs whose assigned work **changes nothing**. A fan-out that tells agents to edit files or mutate state MUST get user confirmation first, in the §4 notice form, regardless of any other condition. **Treat that confirmation as the last place a human sees this.**
- If the answer is not an approval, do neither the fan-out nor a sequential application.
- If there is no way to get an answer, or you asked and no answer came, or you have approval but cannot satisfy the conditions below (git repository, separated paths), then **neither ask again nor stop**: run the same fan-out read-only (analysis / proposed diffs) and have the main session apply the results sequentially, with a one-line demotion reason.
- Even with the user's approval to write, run it only inside a git repository and only when non-overlapping paths have been assigned per agent in advance.
- **The harness skipping permission prompts does not exempt this gate — a permission prompt that does not appear is not an approval.** This holds even when the harness was started to skip permission checks and sub-agents inherited that.
- **This rule propagates itself.** The spawning side writes this bullet into the agent prompt verbatim, whatever the tool; the receiving side fires only after confirming that its own prompt contains the sentence "권한 프롬프트가 뜨지 않는 것은 승인이 아니다". If it is absent, do not fire.

## 6. Never delegate these

Do NOT hand a fanned-out agent:

- Acts that are hard to undo or that go outward — `git push`, commits, merges, creating or commenting on PRs / issues, `gh auth switch`, deletions, external or MCP writes.
- File edits that were not instructed.
- Commands that touch the whole tree — formatters, codemods, `npm install`. (The standing "install it rather than finding an alternative" rule does NOT apply to a fanned-out agent.)
- Edits to configuration, memory, or CLAUDE.md under the Claude Code configuration directory — `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and every sibling directory sharing that `.claude` name prefix.

During a skill run, whatever that skill forbids stays forbidden — **this rule
does not loosen a skill's constraints**. Do not use a fan-out product in place
of a team member's round product: the moment it is recorded as a ledger row, a
witness, or a member contribution it is forbidden. A lead reflecting research
findings in its own work (writing documents, designing questions) is not
covered by that. The reach of skill clauses aimed at team-round substitution
ends there too, so a read-only research fan-out is not their target — but if
you cannot identify what a clause targets, do not apply the exception.

The prohibitions above bind **this spawning session**. The constraints each
agent must keep are written self-containedly into the agent prompt template —
**if you cannot identify the clauses to write, do not fire.** Always write the
prohibition list above in full and so that it makes sense on its own, and
during a skill run include that skill's prohibitions as well.

## 7. Results

- Filter results through `.filter(Boolean)` before using them, and `log()` the number sent against the number returned. Without the filter, a `null` sits in the failed slot and the counts look equal.
- **If the number of returned results differs from the number of agents sent, do not use it as grounds for deleting, migrating, or removing anything** — a missing result is "unknown", not "absent".
- If results come back empty or the run ends early, do not summarize from what is left alone — state what is missing.
- Worktrees a fan-out creates (`isolation: "worktree"`) are separate from a worktree the user asked for (which must be a plain `git worktree`) and are not subject to that rule. But one left behind after an abnormal exit may be the only copy of a change — do not force-remove it; report it, on the same principle as post-merge cleanup (on failure: no force delete, no worktree removal, no stash — report only).

## 8. Waiting while it runs

Do not fire no-op progress checks or polling. Either do other work or yield the
turn until results arrive on their own — results are delivered automatically.
(A user asking for status is a command whose output is needed, so it is not
covered by this.)
