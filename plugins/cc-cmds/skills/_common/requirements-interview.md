# Requirements interview (shared convention)

How a requirements interview is conducted, for every skill that runs one before a design exists. The discipline below was moved here verbatim from the interactive `design` skill's requirements interview, so that the unattended kickoff asks with the same depth; each consumer reads this file once and keeps its own wiring (what the answers feed, where they are recorded, when the interview ends) in its own text.

## Consumers

- `design/SKILL.md` — `### Step 1: Requirements Interview & Codebase Exploration (Korean)`
- `autopilot/SKILL.md` — `**5j — `

## One rule: the code answers what it can, the person answers the rest

Facts are settled by exploration, reproduction and measurement, and recorded with where they were observed. Intent, priority and trade-offs are asked of the person. Do not ask the person what the tree already answers, and do not settle from the tree what only the person can decide. A finding never stands in for an intent.

## How deep — the lead decides

This is a naive guide, not a rule set: there is no mode, no floor and no quota. The lead judges how deep a given task needs to go. For example, the person who asked for this file put it as 「픽스나 개선류는 탐색으로 가능하겠지만, 신규 기능 개발같은건 제대로 인터뷰가 필요할테니」 — an illustration of the judgment, not a classification to apply.

Three signs that the interview is still shallow:

- the completion criterion cannot be written in the person's own words;
- a line of the closing read-back is the lead's guess rather than something the person said or confirmed;
- a recommended option leans on nothing that was observed.

One stopping criterion: stop when the closing read-back can be written without a line the lead made up. A read-back confirms what was asked; it does not stand in for what was not.

## The discipline

- Ask deep, non-obvious questions covering all aspects of the task, including but not limited to: technical implementation, UI/UX, concerns, tradeoffs, scale, constraints, and integration points.
- Avoid generic or superficial questions. Dig into specifics.
- Explore the existing codebase as needed during the interview to inform better questions and identify related patterns, modules, and conventions.
- **Issue-originated design** — applies whenever the task references a GitHub issue number or URL or a ClickUp ticket id or URL, or exists to resolve a specific issue or ticket.
    - **Do NOT let the solution proposed in the issue body constrain the design.** Investigate the codebase directly and find the fix that is actually right. Treat the issue's proposal as one reference opinion: check whether a better alternative exists and whether the proposal's premises even hold.
    - **Scan the other open issues in the same breath.** During the requirements interview / codebase exploration, run `<plugin root>/orchestrator/similar-items.py github --issue <N>` for the originating issue (directly, with no interpreter in front). `<plugin root>` is the directory holding `orchestrator/` and `skills/` — the parent of the consuming skill's directory's parent; substitute it yourself before the command reaches a shell, since it is not a shell variable and `${CLAUDE_SKILL_DIR}` written into a command expands to an empty prefix. For a ClickUp ticket, run `<plugin root>/orchestrator/similar-items.py clickup --task <ID|URL>` instead, and link an accepted ClickUp ticket in the PR body by its URL rather than as `Closes #N`. It compares the issue against every open issue in the repository — a lexical shortlist re-ranked by a type-decision classification model — and prints the closest candidates; a `notice:` line saying the candidates were picked without semantic judgment means the re-rank did not run, and `status=unavailable` means no comparison ran at all. Treat the list as the starting set, not the verdict, and look for issues worth handling together — normally the ones that would land in the same PR. Detection is the lead's judgment and is deliberately broad: not only title/body duplication and explicit duplicate / cross-references, but also issues touching the same component, module, or area, or whose labels and keywords overlap enough that one PR is the reasonable shape. Ground the candidate set in the codebase exploration, not in title-matching alone — add what exploration surfaces and drop listed candidates it shows to be unrelated.
    - **If candidates exist, propose them via `AskUserQuestion`.** If the user accepts, merge the selected issues into ONE design document and ONE PR scope, and link every one of them in the PR body as `Closes #N`. The proposal is an option, never a mandate — if the user chooses to proceed with the single original issue, continue with the original scope unchanged.
- **Reproduction-first (execution by reproduction)** — a third mode of the interview↔exploration loop, for issue/bug tasks. Reproducing the actual symptom *before* the team is composed keeps the interview questions sharp and anchors the team on the real root cause instead of a code-reading guess.
    - **Single filter test**: *"Does the task claim that existing code currently misbehaves, and is that misbehavior observable by running the existing app or test suite?"* NO (new feature / greenfield / pure architecture choice — nothing to misbehave yet) → skip reproduction. YES → attempt reproduction before the team is composed. Whether to reproduce, and whether the lead does it directly or hands it to the team, is the lead's delegated judgment; the consuming skill says how a hand-off is made.
    - Reproduction runs only the unmodified app/tests and routes all artifacts/logging out of tree — see `_common/verification.md` `## 6. Observation & verification carve-out` (do not restate it here).
    - **On a reproduction attempt, emit four data points**: `재현 절차` / `관측된 증상` ("미관측" if only hypothesized) / `근본 원인` / (only on failure) `재현 차단요인`. The confirmed-vs-hypothesis distinction is carried solely by `근거 등급` (token `확인됨(재현·관측)` when the recipe was actually run and the symptom observed; otherwise `가설(추측)`), not by the field names.
    - **Two-tier fallback when reproduction fails**: Tier-1 — ask the user for the gap (env / exact steps / logs) during the interview, then retry. Tier-2 — if it still fails, or the lead judges user help futile (inaccessible failure env/data, non-determinism with no capture, an external dependency the user can't exercise), proceed with the root cause marked `가설(추측)` and `재현 차단요인` filled. The user-can't-help call is the lead's delegated judgment. What a Tier-2 outcome feeds is the consuming skill's to say.
- **Verification-first (settling claims in-session)** — a companion to reproduction-first, generalized from bug symptoms to any load-bearing assumption the design will rest on. **Read `${CLAUDE_SKILL_DIR}/../_common/verification.md`** (the in-session verification SOT: claim taxonomy, severity→filter tests, carve-out surfaces) and apply it as assumptions surface. Settle the cheap (a)/(b) claims inline (a `grep`, a `--version`, a single unmodified tool run) so the team composes on observed facts; note any verifiable claim that cannot be settled now, so it is carried forward rather than dropped.
- Iterate between interviewing and codebase exploration until all critical aspects are sufficiently covered, then confirm with the user before proceeding.

## Closing read-back

The interview ends by reading back what was settled, under three labels in this order: `해야 할 것` · `바꾸지 않는 것` · `완료 기준`. Each may be `없음`; none may be left out. The lead may read back more than these three (the delivery shape, what is left to the design), and when a choice is being left to the design — including one that sits inside the description of the option the person picked — says so plainly. The person's confirmation of this read-back is the interview's last question.

The three labels are the **shape** of that confirmation, not a list of topics to ask about. They do not mean one question per label, and they are not a floor on depth.

## What this file does not decide

How the question tool is called, how the interview is recorded, which turn a question is asked in, and where the interview sits in the consuming skill's order are all outside this file; each consumer owns them.
