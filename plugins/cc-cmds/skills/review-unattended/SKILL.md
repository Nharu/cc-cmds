---
name: review-unattended
description: 에이전트 팀을 활용한 다관점 코드 리뷰 (무인 — 사람 확인 없이 리포트까지 완주)
when_to_use: 자율 파이프라인 드라이버가 리뷰 스테이지를 헤드리스로 디스패치할 때. 사람이 직접 부르는 경우에는 `/cc-cmds:review`를 쓸 것
disable-model-invocation: true
usage: "/cc-cmds:review-unattended <target> [--report-path <abs-path>] [--base-sha <sha>] [--declared-files <csv>] [--basis-cycle <n>] [--basis-review-head <sha>] [--basis-report-path <abs-path>] [<directive>]"
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
    - name: "--base-sha <sha>"
      kind: flag
      default: "off (`gh pr view … baseRefName` 또는 기본 브랜치에서 base 를 스스로 유도)"
      summary: "diff 의 base 를 드라이버가 지정. 드라이버는 세그먼트가 갈라져 나온 base 를 이미 알고 있으므로, 이 값이 있으면 리뷰가 그것을 다시 유도하지 않는다. 넘겨받은 값은 신뢰하지 않고 `git merge-base --is-ancestor` 로 검증하며, 실패하면 기존 유도로 폴백하고 그 사실을 리포트 개요에 남긴다."
      parse_note: "`--base-sha` 다음 토큰을 값으로 취한다. 값이 없으면 플래그를 무시하고 기존 유도를 쓴다 — 정지하지 않는다."
    - name: "--declared-files <csv>"
      kind: flag
      default: "off (변경 파일 집합을 diff 에서만 유도)"
      summary: "이 세그먼트가 건드리기로 **선언된** 파일 집합(쉼표 구분). diff 는 무엇이 바뀌었는지만 말하고 무엇이 바뀌기로 되어 있었는지는 말하지 않으므로, 선언 밖 파일이 리뷰 범위 안에 있을 때 그것을 지목할 수 있게 한다."
      parse_note: "`--declared-files` 다음 토큰을 값으로 취한다. 쉼표·공백을 포함할 수 있어 드라이버가 인용 부호로 감싸 넘긴다. 값이 없으면 플래그를 무시한다 — 정지하지 않는다."
    - name: "--basis-cycle <n>"
      kind: flag
      default: "off (delta mode is not attempted; review runs full)"
      summary: "The 사이클 number of this segment's most recent FULL review cycle. Required together with --basis-review-head and --basis-report-path to attempt delta mode — all three or none. Any one missing or malformed drops the whole attempt to a full review, never a halt."
      parse_note: "`--basis-cycle` takes the next token as its value. Missing, or not a positive integer, or either companion flag itself missing or malformed → all three are treated as absent for this call; full review, no halt. One overview line records the attempt only when at least one of the three was actually supplied on argv."
    - name: "--basis-review-head <sha>"
      kind: flag
      default: "off (delta mode is not attempted; review runs full)"
      summary: "The 리뷰 HEAD of the cycle named by --basis-cycle. Verified with git merge-base --is-ancestor against the target head named explicitly, never the caller's ambient HEAD. On failure, or when the three-flag set is incomplete or malformed, the arm falls back to a full review and records why in the report overview."
      parse_note: "`--basis-review-head` takes the next token as its value. Value missing → treated as absent; see --basis-cycle's parse_note for the joint-absence rule."
    - name: "--basis-report-path <abs-path>"
      kind: flag
      default: "off (delta mode is not attempted; review runs full)"
      summary: "Main-worktree absolute path to the --basis-cycle report — the source of the prior findings this cycle re-adjudicates. Read-only; never written by this arm. Must be absolute or it is treated as malformed."
      parse_note: "`--basis-report-path` takes the next token as its value. Value missing or not an absolute path → treated as absent; see --basis-cycle's parse_note for the joint-absence rule."
    - name: "<directive>"
      kind: positional
      required: false
      summary: '리뷰 관점 지시문. severity 기준은 바꾸지 않고 팀 구성과 컨텍스트 가중치에만 영향.'
      parse_note: "타겟과 인식된 플래그(`--report-path`·`--base-sha`·`--declared-files`·`--basis-cycle`·`--basis-review-head`·`--basis-report-path`)의 값을 뺀 나머지. 인식되지 않는 `--` 토큰은 지시문으로 흡수하지 않고 폐기하며, 폐기 사실을 리포트에 한 줄 남긴다."
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

Read `${CLAUDE_SKILL_DIR}/../_common/pipeline-sidecar.md` §4 for the schema. Path: `${RUN_DIR}/halt/<stage-id>.md`, `RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`. `<run-id>` is re-derived from `<base>/docs/pipeline-grant/{slug}.md`. **Prefer the driver-exported `CC_PIPELINE_RUN_ID`** (with `RUN_DIR` from `CC_PIPELINE_RUN_DIR`); the re-derivation below is the fallback for a driver older than those variables, and it resolves only for a run started from a document — a manifest run keys its grant on the run id instead. `<stage-id>` comes from the driver-exported `CC_PIPELINE_STAGE_ID`, defaulting to this skill's name. Write it atomically (`sidecar.md` §1.3), record the question and every option **verbatim**, then take no further step and end the turn. **Never write a pipeline sidecar** — the driver is their sole writer.

### Per-grade disposition

The base skill marks each of its ask points with a judgment grade
(`${CLAUDE_SKILL_DIR}/../_common/judgment-grade.md`). This arm's disposition is
per grade, not one blanket rule — a blanket rule is what made the inversion
undecidable, because "it would have asked" says nothing about whether an answer
was choosable.

- **`등급 0`** — no disposition is needed. An already-written rule fully
  determines the answer, so there was never a question at this point.
- **`등급 1`** — adopt the recommended option, write a `자율 승인` row carrying
  `등급`, `기준` (the authored standard that chose it) and `되돌리는 법` (the
  concrete command or edit that undoes it), and continue. A choice for which no
  `되돌리는 법` can be produced is **not** grade 1 whatever its mark says: the
  field is a condition, not documentation of one. **A stage holds no gate verb,
  so it does not write that row itself** — it emits the five markers of
  `judgment-grade.md` §`Emission form` in its terminal message, and the gate
  absorbs them through the same auto-adoption floor an `act --kind judgment`
  meets. Emitting is not adopting: a judgment that does not clear the floor
  becomes an approval instead of a row.
- **`등급 2`** — write the halt record above and stop. This is the branch that
  keeps "leave most of it to the orchestrator" from becoming "the orchestrator
  waived the check you asked for".

The grades are a marking, not a proof. Nothing here checks that a point marked
`등급 1` deserved it; `scripts/lint-judgment-grade.sh` counts marks and matches
dispositions, and says so.

## Control-Flow Invariants

**CFI-U0 — There is no human-question surface.** `AskUserQuestion` is absent from the Step 0 roster and from every step below. Reaching a point that would have asked is a **halt**, never an improvised answer and never a silent default. This substitution is total and covers the shared team protocol: wherever `_common/agent-team-protocol.md`'s reconcile ladder or its escalation cases terminate in `AskUserQuestion`, **this arm resolves that terminus to `park`**. The protocol file is neither forked nor edited; this sentence is the substitution rule.

**CFI-U1 — Scope is never narrowed autonomously.** The large-PR gate's narrowing options are a *user's* trade, not this arm's. `P0 + P1 == 0` is the pipeline's **only** termination predicate, so thinning the review thins the very signal that decides whether the loop stops — and unlike a token saving elsewhere, that failure is silent and self-congratulating. Review the whole confirmed scope. Where the change is genuinely large, say so in the report's overview and compose for it (a Scope Coordinator is outside the team-size ceiling), but do not drop files.

**Amendment — a driver-declared delta is not an autonomous narrowing.** When `--basis-cycle`, `--basis-review-head` and `--basis-report-path` are all supplied and clear every check in Step 1b′, "the whole confirmed scope" for this cycle *is* the delta file set **for new findings** — the driver, not the model, made the trade that a file untouched since the last full review does not need a fresh read to discover new issues, and it made that trade on a git-verifiable basis rather than a judgment call. This is the same category of decision `--declared-files` already lets the driver make without violating this invariant. What CFI-U1 continues to forbid, unconditionally, is the arm narrowing **within** whatever scope it was handed on its own initiative, and the arm shrinking the *set of prior findings it accounts for*. That second door is closed structurally: every basis P0/P1, whether or not its cited file lies inside the delta file set, gets a fresh evidence-backed verdict every cycle (context-package item 18), never inferred from a git fact alone. So "did not re-read a file for a new issue" and "silently dropped a known one" can never be the same event.

**CFI-U2 — There is no follow-up discussion step.** The base skill's Step 6 exists to talk to a user. This arm ends at Step 5 with the report written and the team cleaned up. Routing the findings is the orchestrator's triage stage, not this stage's job, and re-spawning a team to re-argue a severity here would duplicate that stage with worse information.

**CFI-U3 — Severity ties default to the higher grade, and the exception needs a record.** The shipped rule takes the higher severity *unless the lead resolved the dispute*, and unattended there is no observable event that makes "the lead resolved it" true. So the exception counts as fired **only** where this arm records the decision, the rejected alternative, both rationales, and the `finding-id` in the report's `## 자율 승인 기록` section (Step 5). With no record, the default branch applies. This enforces the rule's own "document both rationales" sentence rather than overriding it.

**CFI-U4 — The report is written where the driver can still read it.** With `--report-path`, write there. Without it, the default path is cwd-relative — and a segment worktree is torn down after its segment terminates, taking the report with it. The driver always passes the flag; a missing one is worth a line in the report's overview so the loss is visible if it happens.

**CFI-U5 — No code modifications.** Review only. Unchanged from the base skill and not weakened by unattended operation.

**CFI-U6 — A source file is read once per stage, and a turn yield is not an invalidation point.** This is a control-flow invariant rather than a constraint because the load-bearing half of it is about control flow: the model stopping and resuming changes nothing about a file's bytes, so a yield that triggers a re-read is spending context to learn what it already knows. Common to all three review arms; CFI-U5's `Unchanged from the base skill` is the precedent for stating a shared rule here. Exactly **three** invalidation points exist — this session wrote to that path with `Edit`/`Write`; a git operation moved `HEAD` or the working tree (`checkout`, `rebase`, `merge`, `stash`, `pull`); or a new stage was entered. **Four things the cache never covers, each for a different reason:**

- the **run ledger** — its contract deliberately produces an under-claim, and a stale read flips that into an over-claim, which is the one direction this pipeline cannot tolerate;
- **witness files** — there is no invalidation event the lead can observe at all, so the cache has nothing to key on;
- a reviewer's **`output_file`** — a cached read reports it byte-stable, which is exactly the WEDGED verdict, on a file that is being written normally;
- the **gate snapshot** — being re-derived is its entire purpose.

Those four are re-read every time they are consulted.

---

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step (`Agent` is built-in — do not load it):

- `ToolSearch("select:SendMessage")`
- `ToolSearch("select:TaskStop")`

**`AskUserQuestion` is deliberately NOT loaded.** It is absent from every headless process anyway, so enumerating it would make this skill fail-loud at Step 0 forever; removing it narrows the fail-loud trigger without carving an exception into the rule, which is scoped to the tools this step enumerates.

**Fail-loud, durably.** If a `ToolSearch` for a Step-0-enumerated tool returns no result, or a later call to one fails because its schema was never loaded, **halt** with `분류: tool-unavailable`, carrying the harness error string verbatim.

**Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md` here, not at Step 4.** It carries the spawn / ledger / resume+convergence / escalation contract, the task-assignment header, and the `### Team size budget` ceiling that Step 3 reads — so the shipped placement had Step 3 depending on a file Step 4 was told to open. Reading the dispatch contract in the same place as the tools it governs removes that inversion, and CFI-U0's substitution of `park` for every `AskUserQuestion` terminus in that file is unchanged by where it is read. **This Read is not covered by the fail-loud rule above**, which is scoped to the tools this step enumerates: a contract document is a file and not a tool, so a failure to read it produces no `tool-unavailable` halt and no new halt class is created here.

---

### Step 1: Target resolution and context collection

#### Pre-validation: gh CLI status check

When the target is not a file path, verify gh CLI first: `command -v gh`, then `gh auth status`, then `gh api repos/{owner}/{repo}`. **Any of the three failing is a halt** with `분류: precondition-failed` — installing a package or re-authenticating is a human act, and guessing past it produces a review of nothing.

#### 1a: Input parsing

- **PR URL** → extract PR number → `gh pr view {number}`
- **Number** → PR number → `gh pr view {number}`
- **Branch name pattern** → `gh pr list --head {branch} --json number,title --jq '.[0]'`
- **File path** → scoped file review, no `gh` commands
- **`--base-sha <sha>` and `--declared-files <csv>`** → scope the driver already resolved. Each takes the **next token** as its value, and both the flag and its value are removed from the argument string **before** the directive is extracted. `--base-sha` names the commit this segment branched from — verified in 1b, never trusted. `--declared-files` is the comma-separated set the segment declared it would touch, quoted by the driver because it contains commas. A flag whose value is missing is dropped along with the flag: consuming the next token would swallow the following flag or the directive.
- **`--basis-cycle <n>`, `--basis-review-head <sha>` and `--basis-report-path <abs-path>`** → the delta basis the driver selected. Each takes the **next token** as its value, and each flag is removed together with its value **before** the directive is extracted, exactly as the two flags above are. A flag whose value is missing is dropped along with the flag. Whether the three values qualify is decided in 1b′, not here — parsing only strips them.
- **Any other token beginning with `--`** → not a directive, and **not a halt**. Discard it and record one line in the report overview naming the token. Halting here would park a segment over a mistyped or newly-added flag, and the loss — a whole segment's review, and the run's only termination signal for it — is far larger than the loss from proceeding without a hint whose meaning this arm does not know. Silently absorbing it into the directive is the other wrong answer: the directive reaches the reviewers as a weighting instruction, so an unknown flag would arrive as a review perspective nobody wrote, and nothing would report that it had.
- **Directive** → propagate to Step 3 (composition weighting) and Step 4 (`User directive: …` in the context package) and Step 5 (`Review focus:` in the overview). The directive influences depth and coverage; **severity is assessed independently on technical criteria.**
- **Anything that resolves to no target, or to more than one** — an unparseable argument, a branch carrying multiple open PRs, an empty argument — is a **halt** with `분류: precondition-failed`, listing the candidates it found.

**If the target is a non-PR** (local diff or file path), Read `${CLAUDE_SKILL_DIR}/../review/references/03-non-pr-mode.md` and apply its adaptations to Steps 2–5.

#### 1b: Context collection

Collect exactly what the base skill collects — repository slug, PR metadata, per-file `{path,additions,deletions}`, the full diff, existing inline review comments and review decisions (`--paginate`), general PR comments, and CI check status. For a local diff target use `git diff {DEFAULT_BRANCH}...HEAD` and `git log {DEFAULT_BRANCH}..HEAD --oneline`.

**A supplied `--base-sha` is verified before it is used, and its failure is a fallback rather than a halt.** Run `git merge-base --is-ancestor <supplied base> <target head>`, where `<target head>` is this review's target named explicitly — the branch, or the PR's head — and never the bare `HEAD` of whatever directory the command happens to run in. On success, take the diff against that value — `git diff <supplied base>...<target head>`, `git log <supplied base>..<target head> --oneline` — **in place of the base derivation only**; a PR target still collects its metadata and comments the way it already does, and what is replaced is which two commits the diff spans. Binding to the ambient `HEAD` would make the guard depend on the caller's working directory, which is the same class of failure the flag exists to close: an interactive caller sitting in another checkout would verify a base against a tree the review is not about. that substitution is the whole reason the flag exists, since the driver resolved this base when it created the segment and re-deriving it here only re-answers a settled question. **On failure, fall back to the derivation this step already describes and record one line in the report overview naming the rejected value and the base actually used.** The failure mode being bought off is silent: a base that is not an ancestor of `<target head>` yields a diff of a tree nobody wrote, so the reviewers produce real findings about the wrong change and the report reads exactly as it would have. Halting instead would be the wrong trade for the same reason the unknown-flag bullet gives — the segment's review is the run's only `P0 + P1` signal, and a base the driver got wrong is recoverable by deriving one, while a parked segment is not recoverable by anything this arm can do.

#### 1b′: Delta eligibility — every failure degrades to a full review, none halts

A delta review reads only the files changed since this segment's last full cycle for new findings and re-adjudicates that cycle's P0/P1. It is attempted only when the driver supplied all three basis flags, and it holds only when every check below passes. **Every failure is a degradation to a full review, never a halt** — the same reasoning as the `--base-sha` fallback: the segment's review is the run's only `P0 + P1` signal, a wrong basis is recovered by reading everything, and a parked segment is not recoverable by anything this arm can do.

| # | Check | On failure |
| --- | --- | --- |
| 0 | All three flags are present | None of the three: full review, silently, no overview line — that is the default. One or two: degrade, and one overview line names which arrived |
| 0.5 | `--basis-cycle` is a positive integer and `--basis-report-path` is an absolute path | Degrade, and one overview line names which is malformed |
| 1 | `git rev-parse --verify <basis-review-head>^{commit}` resolves | Degrade |
| 2 | `git merge-base --is-ancestor <basis-review-head> <target head>` — `<target head>` is the branch or the PR head named explicitly, never the bare `HEAD`; exit 1 (not an ancestor) and exit ≥2 (undecidable) get different wording | Degrade |
| 3 | The basis report exists, is not empty, and matches the `발견 요약` anchor `^[-*[:space:]]*\*\*발견 요약\*\*` | Degrade |
| 4 | The basis report's `리뷰 모드` line says `전체` or is absent | Degrade — `기준 사이클이 델타 사이클입니다 — 델타는 연쇄되지 않습니다` |

"Is the basis this segment's **latest** full cycle" is not checked here. This arm has no view of the ledger; it takes the router's selection the way it takes `--base-sha`, and the gate refuses a stale basis at write time. That is a division of labour, not a gap.

Degradation overview line, for example: `델타 조건이 성립하지 않아 전체 리뷰로 진행합니다 (사유: 기준 리뷰 HEAD 가 대상 head 의 조상이 아닙니다).`

#### Delta file set

The set is "files changed on the segment's side since the basis review HEAD, conflict resolutions included, intersected with the segment's own diff". Two tree diffs intersected naively do not remove files that arrived only from master — the segment's three-dot diff contains merged-in files too — and `--first-parent --no-merges` alone misses the conflict-resolution edits inside a merge commit. The two are combined:

```sh
# BASIS = --basis-review-head, TARGET = 대상 head(명시), BASE = 1b 에서 확정한 diff 베이스
SET_A=$( { git log --first-parent --no-merges -M --name-only --format= "$BASIS..$TARGET"
           for m in $(git log --first-parent --merges --format=%H "$BASIS..$TARGET"); do
             git diff-tree --cc --name-only --no-commit-id "$m"
           done; } | grep . | sort -u )
SET_B=$(git diff -M --name-only "$BASE...$TARGET" | sort -u)
DELTA=$(comm -12 <(printf '%s\n' "$SET_A") <(printf '%s\n' "$SET_B"))
```

- `--cc` emits only the paths whose merge result differs from both parents, so a conflict a person resolved by hand is included and a clean merge that took one side as-is is not.
- A **rename inside a merge commit** is not paired by `--cc`: the old path comes out as `DD` and the new one as `AA`, separately. `SET_B` is taken with `-M`, so only the new path survives the intersection. A basis finding that cites the old path is followed by the reviewer in the re-adjudication below regardless.
- An empty `DELTA` (nothing on the segment side since the basis but clean merges) is still a delta review: there is no new-finding scope, and the basis P0/P1 re-adjudication is all that remains.
- 1c's `--declared-files` comparison is **still against the whole segment diff**. The scope record is independent of the reading mode. A path outside the declaration that is also outside `DELTA` has that overlap noted under `## 미검토 영역`.

**What is read.** Each file in `DELTA` is read as **that file's whole diff against the base**, not as the hunks since the basis. The saving comes from which files are opened, not from slicing the ones that are — a slice loses the surrounding function, and the loss is largest in exactly the files both sides touched.

#### 1c: Scope record (no confirmation, no narrowing)

**A supplied `--declared-files` is compared against what actually changed.** List the changed paths for the diff just resolved and set them against the declared set. Name in the report's overview any changed path that is **outside** the declaration, and any declared path with **no** change. Neither is an error and neither narrows the review — the whole diff is reviewed either way — but the two lists are the only place the run says whether the change that landed is the change that was declared. Git can say which files moved; only the declaration says which ones were meant to. With no flag, skip this and say nothing.

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
- **Delta mode** (every 1b′ check passed) — size and the risk indicators below are evaluated over the delta file set: sum `git diff --numstat "$BASE...$TARGET" -- <DELTA files>`. The new-finding search scope is `DELTA`, so the team is sized to it. The floor still holds, so an empty `DELTA` does not yield an empty roster. The basis P0/P1 re-adjudication (context-package item 18) is **not** counted here: its cost is bounded by the number of basis findings and it asks for no additional reviewer.

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

The spawn / ledger / resume+convergence / escalation contract and the task-assignment header come from `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`, **read in Step 0**. Reviewers are **nameless background tasks** (`Agent` with `subagent_type:"claude"`, `run_in_background:true`, **no `name`**), resumed across rounds by `agentId`, self-terminating on return; each result is delivered by its **witness file** and the return text is only an early-wake hint.

**Before building each reviewer's context package, Read `${CLAUDE_SKILL_DIR}/../review/references/01-reviewer-context-package.md`** for the context package — items 1–17, and item 18 which exists only in delta mode — role checklists, protocol rounds, and facilitator additions.

- **In delta mode, item 18 carries the full text of every basis P0/P1 finding** — not filtered to the reviewer's file scope and not filtered to the delta file set — and each one is assigned to the composed reviewer whose role/category tag is the closest match (the smallest-scoped reviewer takes the remainder). Item 2's review-scope diff is the whole-file diff of each `DELTA` file against the base, per 1b′.

- **Derive the review slug** from the target: PR → `review-pr{NUMBER}`; local diff → `review-{branch-name}`; file path → `review-{short-slug}`.
- **Resolve the report path** per CFI-U4: `--report-path` when given, else `docs/reviews/{slug}.md`. Everything below writes to the resolved path.
- **Early-stub the report doc** at spawn time so the ledger has a home (no TMPDIR fallback): an H1 title, then a `<!-- cc-design-ledger v3 … -->` HTML-comment block after the H1 and before the first `##`. Entry schema is the protocol's ledger v3.
- **Spawn each reviewer** as a nameless background task, with the protocol's **task-assignment header** verbatim atop each prompt followed by the self-contained context package. Record each returned `agentId` immediately (`state=running`, round 1), stamping `epoch` (`max(disk epoch, 0)+1`, re-derived from the on-disk ledger — never an in-context counter) and the round-1 `witnessNonce` on every row in the same at-spawn window.
- **Witness scratch dir**: before the first spawn, run the protocol's `## Spawn` command — `<plugin root>/orchestrator/cc-team-witness-init.sh <this review's slug>` (no `bash` in front — see the protocol's note) — and record the **printed path, literally** (not `$WITNESS_DIR`) as each reviewer's `scratchDir`. Out-of-tree under either root, leaving the boundary gate untouched.
- **Progress checkpoint — this skill opts in.** Append the protocol's checkpoint clause verbatim after the task-assignment header in every reviewer spawn and resume prompt (`## Per-skill parameter seam` → **Parameter — progress checkpoint**), alongside the CFI injections below and substituting the same four tokens the header already substitutes. Reviewers publish to `${scratchDir}/partial/`; the lead reads no checkpoint in a live run.
- **Every reviewer prompt additionally carries CFI-U0 and CFI-U5 verbatim.** A spawned reviewer has no question surface and no notification surface, modifies no code, and reports completion and blockage to its spawner by witness file and return value only — never a banner, by any route: not the notification tools, not a script, not by asking someone else to emit one on its behalf.
- All inter-reviewer discussion in English. **NO code modifications.**
- **The lead facilitates** the multi-round resume loop (produce → cross-review → convergence). Round count follows the protocol's `### Round budget`.
- **Convergence**: after cross-review, resume each reviewer once with a convergence prompt re-injecting the current consensus and open conflicts verbatim; a round is converged-and-collected only when its witness is `witness_present` and the body says "no further input".
- **Escalation** (the protocol's reconcile ladder + failure phenotypes), with CFI-U0 applied to every terminus: **Case 1 — thin/empty witness** → re-scope + resume once; a second consecutive occurrence **halts** rather than asking, and the halt record names the reviewer, both witness bodies, and the three options the interactive arm would have offered. **Case 2 — never-returns** → the death verdict fires → `TaskStop` + same-round respawn (new `agentId`, ledger row's `agentId`/`outputFile` updated, `stallMark` reset); a respawn that also dies **halts**. **Case 3 — non-conforming witness** → re-assign once; a recurrence feeds the Case 1 counter.

---

### Step 5: Result Synthesis & Documentation (Korean) — the terminal step

**Before synthesizing, Read `${CLAUDE_SKILL_DIR}/../review/references/02-review-report-template.md`** for the severity system (P0~P3), merge rules, document structure, naming/version conventions, and the paste-ready comment section.

Synthesize into the resolved report path, following the template. Leave the `<!-- cc-design-ledger v3 … -->` block in place. **The `- **발견 요약**: 🔴 P0 N건 | 🟠 P1 N건 | 🟡 P2 N건 | 🟢 P3 N건` summary line is the driver's terminal predicate** — emit it byte for byte in the template's position.

The two elements below are this arm's overlay on the shared template, in the same way `## 자율 승인 기록` is: `02-review-report-template.md` is unchanged, because the interactive `review` reads it unconditionally.

#### `리뷰 모드` line — always

Directly after the overview's `리뷰 대상` line, in every report, full or delta:

```
- **리뷰 모드**: 전체
- **리뷰 모드**: 델타 (기준 사이클 <n>, 기준 리뷰 HEAD `<sha>`)
```

The line states **what actually happened**. Whatever the flags requested, if any 1b′ check failed the line says `전체`. The router copies this line onto the ledger's `cycle` row and the gate compares the two on every write, so the format is load-bearing.

#### `## 기준 사이클 재판정` — delta mode only

After `핵심 요약` and before the P0 section, one entry per basis P0/P1, none omitted:

```
## 기준 사이클 재판정

- **[category]** `파일:라인` (사이클 N 발견) — 원 서술 한 문장
    - **판정**: 해결됨 | 미해결
    - **근거**: <수정 위치와 내용, 또는 결함이 남아 있음을 확인한 근거>
```

A finding judged `해결됨` leaves this cycle's severity sections, and this entry is its only audit record. A finding judged `미해결` re-enters this cycle's section at the same severity (or at the reviewer's explicit re-grade, under the CFI-U3 rule) carrying `(사이클 N에서 상속, 미해결)`. Basis P2/P3 findings are carried into this cycle's P2/P3 sections without re-adjudication, marked `(사이클 N에서 상속)`. The basis report's `## 미검토 영역` entries are carried into this cycle's `## 미검토 영역`, marked `(사이클 N에서 상속)`.

**Counting rule** — the `발견 요약` line's **form is byte for byte unchanged**; only what it counts is defined here:

```
P0 = 미해결 기준 P0 + 델타 신규 P0
P1 = 미해결 기준 P1 + 델타 신규 P1
P2 = 상속 기준 P2   + 델타 신규 P2
P3 = 상속 기준 P3   + 델타 신규 P3
```

#### `## 자율 승인 기록` — the section CFI-U3 requires

Where two reviewers graded the same finding differently and this arm resolved it, append a row here carrying `finding-id`, the decision, the rejected alternative, and **both** rationales. Absent a row, the default branch (higher severity) applies and no exception was taken. **This arm writes the section; it does not write the run ledger** — the driver transcribes these rows into `자율 승인` (`kind=severity`) entries, which is what keeps the single-writer invariant intact.

#### Paste-ready comments (lead-authored)

Below each P0~P2 finding's analysis, write a self-contained, paste-ready GitHub comment as a `💬 붙여넣기용 코멘트` blockquote, per the template's "Paste-Ready Comment Blockquote" section. The label sits outside the blockquote.

- **Tone duality**: the analysis body is assertive (단정체); the comment is polite (정중체) — facts as `~됩니다 / ~입니다`, requests as `~하시면 될 것 같습니다 / ~해주시면 좋겠습니다` (`~해야 합니다` only for P0 merge-block intent; never `~하세요`). The comment reads standalone.
- **P3 = the item line is the comment**: write each P3 line itself in polite, self-contained form; the trailing `— {리뷰어명}` attribution is excluded when copied.
- **dedup exception**: a finding that only confirms an existing PR comment (carries `📎 관련 PR 코멘트`) gets a plain-text note instead of a blockquote. The absence of a blockquote signals "nothing new to post".
- **The comments are written, never posted.** Posting to GitHub is an outward-facing act and belongs to the permission cutpoint, not to a review stage.

**Then clean up and stop.** Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md` and apply it: returned tasks already self-terminated, so normal completion is a no-op plus ledger hygiene (no `state=running` row survives); `TaskStop` any genuinely-running leftover before marking it `aborted`. Removing the witness directory is part of what that file already mandates, path-guarded to the recorded `scratchDir`; do not restate it here. The restatement that used to sit here spelled it `rm -rf "$WITNESS_DIR"`, and that variable is unset in the shell the cleanup runs in — the expansion was empty, the command removed nothing, and the ledger recorded a cleanup that had not happened.

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
