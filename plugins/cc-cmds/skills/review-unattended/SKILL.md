---
name: review-unattended
description: 에이전트 팀을 활용한 다관점 코드 리뷰 (무인 — 사람 확인 없이 리포트까지 완주)
when_to_use: 자율 파이프라인 드라이버가 리뷰 스테이지를 헤드리스로 디스패치할 때. 사람이 직접 부르는 경우에는 `/cc-cmds:review`를 쓸 것
disable-model-invocation: true
usage: "/cc-cmds:review-unattended <target> [--report-path <abs-path>] [<directive>]"
options:
    - name: "<target>"
      kind: positional
      required: true
      summary: "리뷰 대상. 드라이버가 방금 만든 PR 번호나 브랜치를 넘긴다."
      parse_note: "숫자만 포함된 토큰은 PR 번호, 하이픈·영문 포함 토큰은 브랜치로 해석. 어느 형태에도 해당되지 않으면 중단 기록을 남기고 정지."
    - name: "--report-path <abs-path>"
      kind: flag
      default: "off (리포트를 cwd 상대 `docs/reviews/{slug}.md`에 기록)"
      summary: "뒤에 오는 **메인 워크트리 절대 경로**에 리포트를 기록한다. 세그먼트 워크트리에서 실행될 때 리포트가 그 트리에 떨어져 철거와 함께 파괴되는 것을 막는 유일한 수단."
      parse_note: "`--report-path` 다음 토큰을 값으로 취한다. 값이 없거나 절대 경로가 아니면 중단 기록을 남기고 정지."
    - name: "<directive>"
      kind: positional
      required: false
      summary: '리뷰 관점 지시문. severity 기준은 바꾸지 않고 팀 구성과 컨텍스트 가중치에만 영향.'
      parse_note: "타겟과 `--report-path` 값을 뺀 나머지."
notes: "사람에게 묻는 표면이 없다. 범위를 스스로 좁히지 않으며(정지 술어를 얇게 만들기 때문), 리포트를 쓰고 종료한다 — 후속 논의 단계가 없다."
---

Conduct a multi-perspective code review using an agent team, **without ever asking a human**.
All team discussions and inter-agent communication are in English to optimize token usage.
Saved documentation is in Korean.

## What this sibling is, and what it is not

This is the unattended arm of `/cc-cmds:review`. It is a **separate file** rather than a flag, because one arm per file makes "this arm contains no human-question surface" a whole-file predicate and therefore checkable (`scripts/lint-unattended-surfaces.sh`). `/cc-cmds:review` is unchanged byte for byte.

**What the split does not buy.** It removes the *instruction* to ask; it does not remove the model's ability to ask in prose and answer itself. That residual is not closed here.

`references/` is **shared with the base skill, not copied** — every reference path below points into `../review/references/`, which carries no human-question surface.

## Input

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

`$ARGUMENTS` is a PR number, a PR URL, or a branch name, optionally followed by `--report-path <abs>` and a directive. **The target is required** — this arm has no auto-detect chain, because auto-detect ends in a question when it fails and because the driver always knows what it just pushed.

**Design document (optional, directive-supplied).** A directive may name the design document the change was built from. When one is given it becomes context-package item 17 and unlocks the `design-conformance` tag. The driver supplies it as a **main-worktree absolute path**.

## Halt record — the disposition for every point that would have asked

Read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4 for the schema. Path: `${RUN_DIR}/halt/<stage-id>.md`, `RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`. `<run-id>` is re-derived from `<base>/docs/pipeline-grant/{slug}.md`; `<stage-id>` comes from the driver-exported `CC_PIPELINE_STAGE_ID`, defaulting to this skill's name. Write it atomically (`sidecar.md` §1.3), record the question and every option **verbatim**, then take no further step and end the turn. **Never write a pipeline sidecar** — the driver is their sole writer.

## Control-Flow Invariants

**CFI-U0 — There is no human-question surface.** `AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its escalation cases terminate in `AskUserQuestion`, **this arm resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule.

**CFI-U1 — Scope is never narrowed autonomously.** The large-PR gate's narrowing options are a *user's* trade, not this arm's. `P0 + P1 == 0` is the pipeline's **only** termination predicate, so thinning the review thins the very signal that decides whether the loop stops — and unlike a token saving elsewhere, that failure is silent and self-congratulating. Review the whole confirmed scope. Where the change is genuinely large, say so in the report's overview and compose for it (a Scope Coordinator is outside the team-size ceiling), but do not drop files.

**CFI-U2 — There is no follow-up discussion step.** The base skill's Step 6 exists to talk to a user. This arm ends at Step 5 with the report written and the team cleaned up. Routing the findings is the orchestrator's triage stage, not this stage's job, and re-spawning a team to re-argue a severity here would duplicate that stage with worse information.

**CFI-U3 — Severity ties default to the higher grade, and the exception needs a record.** The shipped rule takes the higher severity *unless the lead resolved the dispute*, and unattended there is no observable event that makes "the lead resolved it" true. So the exception counts as fired **only** where this arm records the decision, the rejected alternative, both rationales, and the `finding-id` in the report's `## 자율 승인 기록` section (Step 5). With no record, the default branch applies. This enforces the rule's own "document both rationales" sentence rather than overriding it.

**CFI-U4 — The report is written where the driver can still read it.** With `--report-path`, write there. Without it, the default path is cwd-relative — and a segment worktree is torn down after its segment terminates, taking the report with it. The driver always passes the flag; a missing one is worth a line in the report's overview so the loss is visible if it happens.

**CFI-U5 — No code modifications.** Review only. Unchanged from the base skill and not weakened by unattended operation.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step (`Agent` is built-in — do not load it):

- `ToolSearch("select:SendMessage")`
- `ToolSearch("select:TaskStop")`

**`AskUserQuestion` is deliberately NOT loaded.** It is absent from every headless process anyway, so enumerating it would make this skill fail-loud at Step 0 forever; removing it narrows the fail-loud trigger without carving an exception into the rule, which is scoped to the tools this step enumerates.

**Fail-loud, durably.** If a `ToolSearch` for a Step-0-enumerated tool returns no result, or a later call to one fails because its schema was never loaded, **halt** with `분류: tool-unavailable`, carrying the harness error string verbatim.

---

### Step 1: Target resolution and context collection

#### Pre-validation: gh CLI status check

When the target is not a file path, verify gh CLI first: `command -v gh`, then `gh auth status`, then `gh api repos/{owner}/{repo}`. **Any of the three failing is a halt** with `분류: precondition-failed` — installing a package or re-authenticating is a human act, and guessing past it produces a review of nothing.

#### 1a: Input parsing

- **PR URL** → extract PR number → `gh pr view {number}`
- **Number** → PR number → `gh pr view {number}`
- **Branch name pattern** → `gh pr list --head {branch} --json number,title --jq '.[0]'`
- **File path** → scoped file review, no `gh` commands
- **Directive** → propagate to Step 3 (composition weighting) and Step 4 (`User directive: …` in the context package) and Step 5 (`Review focus:` in the overview). The directive influences depth and coverage; **severity is assessed independently on technical criteria.**
- **Anything that resolves to no target, or to more than one** — an unparseable argument, a branch carrying multiple open PRs, an empty argument — is a **halt** with `분류: precondition-failed`, listing the candidates it found.

**If the target is a non-PR** (local diff or file path), Read `${CLAUDE_SKILL_DIR}/../review/references/03-non-pr-mode.md` and apply its adaptations to Steps 2–5.

#### 1b: Context collection

Collect exactly what the base skill collects — repository slug, PR metadata, per-file `{path,additions,deletions}`, the full diff, existing inline review comments and review decisions (`--paginate`), general PR comments, and CI check status. For a local diff target use `git diff {DEFAULT_BRANCH}...HEAD` and `git log {DEFAULT_BRANCH}..HEAD --oneline`.

#### 1c: Scope record (no confirmation, no narrowing)

There is no user to confirm with, and CFI-U1 forbids narrowing. **Record** the scope instead of confirming it — target type, PR title/number/URL, change statistics, key changed files, existing-comment summary, CI status with failed checks highlighted. This record becomes the report's overview.

Where the change exceeds 50 files, note the scale and add a **Scope Coordinator** in Step 3 rather than reducing coverage.

#### 1d: Edge cases

| Case | Handling |
| --- | --- |
| Draft PR | proceed; mark draft status in the report header |
| Closed / merged PR | **halt** (`precondition-failed`) — in a pipeline run the PR was created moments ago, so this state means something else moved it |
| Multiple PRs on one branch | **halt**, listing them |
| Fork PR | `gh pr view` handles it normally |
| No GitHub remote | switch to local diff mode |
| gh missing or unauthenticated | **halt** (`precondition-failed`) |

---

### Step 2: Codebase Survey & Exploration

Identical to the base skill. Survey the tree (`ls` at root), read `CLAUDE.md` and `.gitignore` for conventions and skip targets, skip the usual build/vendor directories, and orient on the changed files' neighbourhood with `Glob`/`Read`. Then explore related modules and dependencies, related tests, existing patterns in the affected area, and the architectural context. This output is the key input for Step 3.

---

### Step 3: Team Composition (no proposal, no approval)

Compose from PR characteristics and the Step 2 exploration, then **proceed** — there is no approval round. Write the composition and its rationale into the report so the morning reader sees what ran and why.

**How many reviewers**: bounded by `_common/agent-team-protocol.md`'s `### Team size budget`. Read the ceiling **and its coordinator-class carve-out** there; this step states no number of its own.

#### Small-work gate (evaluated once on entering this step)

A small, single-concern change does not need a full team. Evaluate against the scope recorded in 1c — which, per CFI-U1, is the whole target.

- **PR mode** — sum `additions + deletions` over the per-file array from 1b; the file count is that array's length.
- **Local diff mode** — aggregate `git diff {DEFAULT_BRANCH}...HEAD --numstat` and sum the added and deleted columns.
- **File path mode** — there is no diff input, so **the gate does not apply**; compose normally and do not substitute an estimate.

**Risk indicators outrank the size row.** If any of auth/authorization, DB schema or query, public API surface, external service integration, or async/concurrency fires, compose for that risk no matter how small the diff is. A security-relevant change is very often a small patch.

**Floor.** Every composed row below carries at least two reviewers, so this gate cannot yield an empty roster.

#### Risk indicators → roles

- Auth/authorization changes → security reviewer
- DB schema/query changes → performance/DB reviewer
- Public API surface changes → API contract reviewer
- External service integration → security + integration review
- Async/concurrency changes → concurrency reviewer

#### Type-based default compositions

| PR Type | Team Composition (Roles) |
| --- | --- |
| **Security-sensitive** (auth, sessions, payments, permissions) | Security reviewer + Logic reviewer + Code quality reviewer |
| **Data-centric** (migrations, schema, ORM) | DB/query expert + Security reviewer + Code quality reviewer |
| **API contract changes** (endpoints, response formats) | API contract reviewer + Security reviewer + Code quality reviewer |
| **General feature** (business logic, UI) | Security reviewer + Performance reviewer + Code quality reviewer |
| **Small patch** (<30 lines, single concern) | Logic reviewer + Code quality reviewer |
| **Large refactoring** (many files, no new features) | Code quality reviewer + Performance reviewer + Security reviewer |

Each reviewer's model is chosen from size, complexity, and the depth the role needs; record the rationale in the report rather than fixing defaults.

#### Large-scope additional strategy

Above 50 files in scope, add a **Scope Coordinator**. It is meta/orchestration rather than a domain perspective, so it is **not counted** against the ceiling. It classifies changed files by risk in round 0, audits coverage after each round and requests more review where high-risk areas are untouched, and synthesizes cross-module findings during cross-validation. **This is the unattended answer to a large PR — coverage bought with a coordinator, never with a narrower scope** (CFI-U1).

---

### Step 4: Parallel Review (English, team internal)

**Before assigning reviewers, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the spawn / ledger / resume+convergence / escalation contract and the task-assignment header. Reviewers are **nameless background tasks** (`Agent` with `subagent_type:"claude"`, `run_in_background:true`, **no `name`**), resumed across rounds by `agentId`, self-terminating on return; each result is delivered by its **witness file** and the return text is only an early-wake hint.

**Before building each reviewer's context package, Read `${CLAUDE_SKILL_DIR}/../review/references/01-reviewer-context-package.md`** for the 17-item package, role checklists, protocol rounds, and facilitator additions.

- **Derive the review slug** from the target: PR → `review-pr{NUMBER}`; local diff → `review-{branch-name}`; file path → `review-{short-slug}`.
- **Resolve the report path** per CFI-U4: `--report-path` when given, else `docs/reviews/{slug}.md`. Everything below writes to the resolved path.
- **Early-stub the report doc** at spawn time so the ledger has a home (no TMPDIR fallback): an H1 title, then a `<!-- cc-design-ledger v3 … -->` HTML-comment block after the H1 and before the first `##`. Entry schema is the protocol's ledger v3.
- **Spawn each reviewer** as a nameless background task, with the protocol's **task-assignment header** verbatim atop each prompt followed by the self-contained context package. Record each returned `agentId` immediately (`state=running`, round 1), stamping `epoch` (`max(disk epoch, 0)+1`, re-derived from the on-disk ledger — never an in-context counter) and the round-1 `witnessNonce` on every row in the same at-spawn window.
- **Witness scratch dir**: before the first spawn, `WITNESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-team-witness-{slug}.XXXXXX")`, recorded as each reviewer's `scratchDir`. Out-of-tree, leaving the boundary gate untouched.
- **Every reviewer prompt additionally carries CFI-U0 and CFI-U5 verbatim.** A spawned reviewer has no question surface and no notification surface, modifies no code, and reports completion and blockage to its spawner by witness file and return value only — never a banner, by any route: not the notification tools, not a script, not by asking someone else to emit one on its behalf.
- All inter-reviewer discussion in English. **NO code modifications.**
- **The lead facilitates** the multi-round resume loop (produce → cross-review → convergence). Round count follows the protocol's `### Round budget`.
- **Convergence**: after cross-review, resume each reviewer once with a convergence prompt re-injecting the current consensus and open conflicts verbatim; a round is converged-and-collected only when its witness is `witness_present` and the body says "no further input".
- **Escalation** (the protocol's reconcile ladder + failure phenotypes), with CFI-U0 applied to every terminus: **Case 1 — thin/empty witness** → re-scope + resume once; a second consecutive occurrence **halts** rather than asking, and the halt record names the reviewer, both witness bodies, and the three options the interactive arm would have offered. **Case 2 — never-returns** → the death verdict fires → `TaskStop` + same-round respawn (new `agentId`, ledger row's `agentId`/`outputFile` updated, `stallMark` reset); a respawn that also dies **halts**. **Case 3 — non-conforming witness** → re-assign once; a recurrence feeds the Case 1 counter.

---

### Step 5: Result Synthesis & Documentation (Korean) — the terminal step

**Before synthesizing, Read `${CLAUDE_SKILL_DIR}/../review/references/02-review-report-template.md`** for the severity system (P0~P3), merge rules, document structure, naming/version conventions, and the paste-ready comment section.

Synthesize into the resolved report path, following the template. Leave the `<!-- cc-design-ledger v3 … -->` block in place. **The `- **발견 요약**: 🔴 P0 N건 | 🟠 P1 N건 | 🟡 P2 N건 | 🟢 P3 N건` summary line is the driver's terminal predicate** — emit it byte for byte in the template's position.

#### `## 자율 승인 기록` — the section CFI-U3 requires

Where two reviewers graded the same finding differently and this arm resolved it, append a row here carrying `finding-id`, the decision, the rejected alternative, and **both** rationales. Absent a row, the default branch (higher severity) applies and no exception was taken. **This arm writes the section; it does not write the run ledger** — the driver transcribes these rows into `자율 승인` (`kind=severity`) entries, which is what keeps the single-writer invariant intact.

#### Paste-ready comments (lead-authored)

Below each P0~P2 finding's analysis, write a self-contained, paste-ready GitHub comment as a `💬 붙여넣기용 코멘트` blockquote, per the template's "Paste-Ready Comment Blockquote" section. The label sits outside the blockquote.

- **Tone duality**: the analysis body is assertive (단정체); the comment is polite (정중체) — facts as `~됩니다 / ~입니다`, requests as `~하시면 될 것 같습니다 / ~해주시면 좋겠습니다` (`~해야 합니다` only for P0 merge-block intent; never `~하세요`). The comment reads standalone.
- **P3 = the item line is the comment**: write each P3 line itself in polite, self-contained form; the trailing `— {리뷰어명}` attribution is excluded when copied.
- **dedup exception**: a finding that only confirms an existing PR comment (carries `📎 관련 PR 코멘트`) gets a plain-text note instead of a blockquote. The absence of a blockquote signals "nothing new to post".
- **The comments are written, never posted.** Posting to GitHub is an outward-facing act and belongs to the permission cutpoint, not to a review stage.

**Then clean up and stop.** Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and apply it: returned tasks already self-terminated, so normal completion is a no-op plus ledger hygiene (no `state=running` row survives); `TaskStop` any genuinely-running leftover before marking it `aborted`. Then `rm -rf "$WITNESS_DIR"` and end.

**There is no Step 6** (CFI-U2). The findings are routed by the orchestrator's triage stage.

---

## Constraints

- **No code modifications.** Review only.
- **Inter-agent communication in English.** Saved documents in Korean.
- **Nameless background sub-agents required**: reviewers MUST be spawned as nameless `Agent` background tasks and driven through a retained-context, lead-mediated resume loop. Do NOT collapse a round into an isolated one-shot `Agent()` — that throws away retained context and breaks cross-review.
- **Codebase grounding required**: reviewers ground findings in the source with their own `grep`/`Glob`/`Read`; the lead does not proxy searches. The one second grounding surface is a `design-conformance` finding, which grounds in the supplied design document *and* in the source, because its claim is a mismatch between the two. No finding is ever grounded in the design document alone.
- **PR comment dedup required**: existing PR comments and reviews are always provided to reviewers; findings duplicating them are filtered or flagged.
- **CI failure routing**: failed checks are recorded in 1c, and "CI failure priority check area: [check name and related files]" is added as its own item to the relevant reviewer's context package.
- **Never reach a notification surface.** No `PushNotification`, no `notify.sh`, no `terminal-notifier` — not from this file and not from any agent it spawns.
- **Never write a pipeline sidecar.** This arm reads the grant to re-derive `RUN_DIR`; the driver is the sole writer of both pipeline sidecars.

Task: $ARGUMENTS
