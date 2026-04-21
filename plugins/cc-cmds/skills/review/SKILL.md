---
name: review
description: 에이전트 팀을 활용한 다관점 코드 리뷰
when_to_use: 사용자가 PR/로컬 diff/파일 경로에 대한 다관점 코드 리뷰(보안/성능/품질 등)를 요청할 때
disable-model-invocation: true
---

Conduct a multi-perspective code review using an agent team for the given task.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication and saved documentation should be in Korean.

## Input

`$ARGUMENTS` can be: a PR URL (`https://github.com/.../pull/N`), a PR number, a branch name, a file/directory path, a mixed input (target + directive, e.g., "PR #42 보안 중심으로"), or empty (auto-detect from current branch). See Step 1a for detailed parsing logic.

## Workflow

### Step 0: Tool Loading

Load deferred tools via ToolSearch before any other step:
- `ToolSearch("select:AskUserQuestion")` — MUST load before Step 1
- `ToolSearch("select:TeamCreate")`
- `ToolSearch("select:SendMessage")`
- `ToolSearch("select:TeamDelete")`

---

### Step 1: PR Detection & Scope Confirmation (Korean)

#### Pre-validation: gh CLI status check

When `$ARGUMENTS` is not a file path, verify gh CLI before auto-detect:
1. `command -v gh` — if not installed, install gh and ask user to run `gh auth login`
2. `gh auth status` — if not authenticated, ask user to run `gh auth login`
3. `gh api repos/{owner}/{repo}` — if no access, ask user to switch to the correct account

Proceed to 1a after pre-validation passes.

#### 1a: Input parsing & target detection

Parse `$ARGUMENTS`:

- **PR URL** (`https://github.com/.../pull/N`) → extract PR number → `gh pr view {number}`
- **Number** → treat as PR number → `gh pr view {number}`
- **Branch name pattern** → `gh pr list --head {branch} --json number,title --jq '.[0]'`
- **File path** → scoped file review (inform user: "파일 경로 기반 리뷰입니다. PR 기반 리뷰 시 추가 컨텍스트(PR 댓글, CI 상태 등)를 활용할 수 있습니다.")
- **Mixed input** (target + directive, e.g., "PR #42 보안 중심으로") → extract target + propagate directive to:
    - Step 3: prioritize directive in team composition (e.g., "보안 중심" → elevate security reviewer model or add extra security focus)
    - Step 4: add "User directive: [directive]" to reviewer context package. Directive influences review depth and coverage; severity is assessed independently on technical criteria.
    - Step 5: add "Review focus: [directive]" field to report overview
- **Ambiguous input** → clarify with AskUserQuestion

When `$ARGUMENTS` is empty, run auto-detect chain:

1. `gh pr view --json number,title,url,state,isDraft,baseRefName,additions,deletions,changedFiles` → success: PR review
2. Failure: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` → `git diff {DEFAULT_BRANCH}...HEAD --stat` → if diff exists: local diff review
3. No diff: AskUserQuestion to request review target

**If target is a non-PR (local diff or file path)**, Read `${CLAUDE_SKILL_DIR}/references/03-non-pr-mode.md` to apply adaptations to Steps 2-5 (context package items 2/5, document header, checklist focus).

#### 1b: Context collection

**For PR targets:**

```bash
# Repository slug (used in subsequent gh api calls)
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# PR metadata
gh pr view $PR_NUMBER --json number,title,body,state,isDraft,labels,milestone,\
  assignees,reviewers,headRefName,baseRefName,url,createdAt,\
  additions,deletions,changedFiles

# Changed file list
gh pr view $PR_NUMBER --json files --jq '[.files[].path]'

# Change statistics (fetch first to determine large PR gate)
gh pr diff $PR_NUMBER --stat

# Full diff (after large PR gate passes)
gh pr diff $PR_NUMBER
# For scope narrowing (gh pr diff does not support path filters):
# Extract baseRefName, headRefName from PR metadata, then:
# git fetch origin {baseRefName} {headRefName}
# git diff origin/{baseRefName}...origin/{headRefName} -- path/to/dir/
# For fork PRs where headRefName is not on origin:
# gh pr checkout {PR_NUMBER} then git diff origin/{baseRefName}...HEAD -- path/to/dir/
# Or fall back to filtering gh pr diff full output

# Existing inline review comments (--paginate for full collection, jq post-processing)
gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/comments" | \
  jq '[.[] | {author: .user.login, file: .path, line: .line, body: .body, \
  created_at: .created_at, resolved: (.resolved // false)}]' | \
  jq -s 'add'

# Review decisions (--paginate for full collection, jq post-processing)
gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews" | \
  jq '[.[] | {author: .user.login, state: .state, body: .body, \
  submitted_at: .submitted_at}]' | \
  jq -s 'add'

# General PR comments
gh pr view $PR_NUMBER --json comments \
  --jq '[.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]'

# CI check status
gh pr checks $PR_NUMBER --json name,status,conclusion 2>/dev/null || echo "[]"
```

**For local diff targets:**

```bash
git diff {DEFAULT_BRANCH}...HEAD        # full diff
git log {DEFAULT_BRANCH}..HEAD --oneline  # commit history
```

#### 1c: Scope confirmation (with large PR gate)

Present to user (in Korean):
- Review target type (PR / local diff / user-specified)
- PR title/number/URL (if PR)
- Change statistics (file count, additions, deletions)
- Key changed files/modules
- Existing PR review comment summary (if any)
- CI status (highlight failed checks if any)

**Large PR gate** (>50 changed files):
- Determine file count from PR metadata `changedFiles` field or `--stat` output
- Inform user of the scale
- Offer options: (a) proceed with full review, (b) focus on specific directory/module, (c) split review
- Adjust team composition if scope is narrowed

Proceed after user confirmation.

#### 1d: Edge case handling

| Case | Handling |
|------|----------|
| Draft PR | Proceed with review, mark draft status in report header |
| Closed/Merged PR | AskUserQuestion to confirm whether to continue |
| Multiple PRs on same branch | List all, let user choose |
| Fork PR | `gh pr view` handles normally |
| No GitHub remote | Skip all gh commands, switch to local diff mode |
| gh CLI not installed | Install gh, then ask user to run `gh auth login`. gh is required |
| gh auth failure | Ask user to run `gh auth login`. Retry after authentication |

---

### Step 2: Codebase Indexing & Exploration

#### 2a: Claude Context MCP indexing

1. Check existing index via `get_indexing_status`
2. If index missing or outdated:
   a. Identify exclusion targets:
      - Run `ls` at project root to survey structure
      - Read CLAUDE.md and .gitignore for project-specific exclusions
      - Common exclusions: `node_modules, .next, build, dist, __pycache__, .git, coverage, .turbo, .cache, out, .vercel, .output, vendor, target`
   b. Call `index_codebase` with exclusion list
   c. Poll `get_indexing_status` until status = "completed" — **never proceed before indexing completes**
3. If index is current, proceed immediately

#### 2b: Codebase context exploration

Explore based on changed file list:
- Related modules and dependencies (callers, importers)
- Related test files
- Existing patterns and conventions in the affected area
- Architectural context (overall structure understanding)

This exploration output is the key input for Step 3 team composition.

---

### Step 3: Team Composition Proposal (Korean)

Propose team composition based on PR characteristics and codebase exploration results.

#### PR characteristic analysis → risk indicators

- Auth/authorization logic changes → security reviewer needed
- DB schema/query changes → performance/DB reviewer needed
- Public API surface changes → API contract reviewer needed
- External service integration → security + integration review needed
- Async/concurrency code changes → concurrency reviewer needed

#### PR type-based default compositions

| PR Type | Team Composition (Roles) |
|---------|--------------------------|
| **Security-sensitive** (auth, sessions, payments, permissions) | Security reviewer + Logic reviewer + Code quality reviewer |
| **Data-centric** (migrations, schema, ORM) | DB/query expert + Security reviewer + Code quality reviewer |
| **API contract changes** (endpoints, response formats) | API contract reviewer + Security reviewer + Code quality reviewer |
| **General feature** (business logic, UI) | Security reviewer + Performance reviewer + Code quality reviewer |
| **Small patch** (<30 lines, single concern) | Logic reviewer + Code quality reviewer |
| **Large refactoring** (many files, no new features) | Code quality reviewer + Performance reviewer + Security reviewer |

Each reviewer's model (`opus`/`sonnet`/`haiku`) is dynamically proposed based on PR size, complexity, and the depth of analysis required for that role. Do not fix defaults — justify model choices with rationale in the Step 3 proposal.

The table above is the **default composition**. Roles can be added/changed based on PR characteristics. For example, a "data-centric" PR with concurrency issues should add a concurrency reviewer. Team composition is dynamically adjusted based on risk indicator analysis, with rationale presented during user approval.

#### Large PR additional strategy

When >50 files are in review scope (after Step 1c narrowing), consider adding a **Scope Coordinator** role. The coordinator operates as a persistent participant:

- **Round 0 (pre-analysis)**: Classify changed files by risk level and assign focus areas to each reviewer
- **Per-round coverage audit**: After each round's results, identify high-risk areas not yet reviewed and request additional review from relevant reviewers
- **Cross-cutting issue identification during cross-validation**: Synthesize findings from multiple reviewers to discover inter-module interaction issues individual reviewers might miss

#### Team proposal format

Present to user in Korean:

```
**PR 특성 분석:**
- 변경 규모: 파일 X개, +Y줄 / -Z줄
- 영향 영역: [identified domains]
- 위험 신호: [detected risk indicators]

**제안 팀 구성:**
| 역할 | 모델 | 담당 범위 |
|------|------|-----------|
| ... | ... | ... |

**팀 구성 근거:**
[1-2 sentences on why this composition fits this PR's characteristics]

이 팀 구성으로 진행할까요?
```

Branch on user response:
- **Approve** → create team, proceed to Step 4
- **Modification request** → reflect feedback, re-propose (repeat)
- **Reject/abort** → end review

---

### Step 4: Parallel Review (English, team internal)

**Before assigning reviewers, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the completion-signal contract and shared facilitator rules.

**Before building each reviewer's context package, Read `${CLAUDE_SKILL_DIR}/references/01-reviewer-context-package.md`** for the 15-item package contents, role-specific checklists, review protocol rounds, and review-specific facilitator additions.

- Create team with approved composition. Team naming conventions:
  - PR review: `review-pr{NUMBER}` (e.g., `review-pr42`)
  - Local diff: `review-{branch-name}` (e.g., `review-feat-auth`)
  - File path: `review-{short-slug}` (e.g., `review-auth-module`)
  - Step 6 re-creation: original team name + `-followup` (e.g., `review-pr42-followup`)
- All team-internal discussion in English
- NO code modifications allowed. Review only
- **The lead acts as a facilitator**, actively driving multi-round review

---

### Step 5: Result Synthesis & Documentation (Korean)

**Before synthesizing review results, Read `${CLAUDE_SKILL_DIR}/references/02-review-report-template.md`** for the severity system (P0~P3), merge rules, document structure template, and file naming/version conventions.

The lead synthesizes all review results into a Korean document under `docs/reviews/` following the template.

---

### Step 6: Review Discussion & Follow-up (Korean)

After presenting the review report, discuss with the user.

#### Lead direct handling (no team needed)

- Detailed explanation of specific findings
- Code section re-check (using Claude Context MCP)
- Severity re-assessment when user provides new context (e.g., "이 코드 경로는 내부 전용입니다")
- Explanation of why a specific finding was not included

#### Team re-creation proposal

Propose team re-creation when:
- User requests comprehensive analysis of areas not covered in the review
- Severity dispute requires independent re-evaluation
- Findings connect to broader architectural issues requiring multi-perspective analysis
- User discovers blind spots that need the same depth as the original review

Team re-creation proposal format builds on Step 3's format with additional fields:
- **Re-creation reason**: blind spot, additional analysis needed, severity dispute, etc.
- **Previous review coverage**: areas covered vs. uncovered in previous review
- **Additional analysis scope**: specific targets and expected outcomes
- Include previous review findings in the new team's context package
- Requires user approval

**Always clean up the previous team before creating a new one.**

#### Document update rules

Refer to `${CLAUDE_SKILL_DIR}/references/02-review-report-template.md` "Document Update Rules (Step 6)" section for the 개정 이력 / 철회된 항목 update conventions.

Repeat until user is satisfied.

**Before Step 6 begins (after Step 5 documentation is complete), Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure. If additional reviewer clarification is needed during Step 5 document writing, do so before cleanup. When Step 6 triggers team re-creation, always clean up the previous team before creating the next one.

---

## Constraints

- **No code modifications.** Review only.
- **Inter-agent communication must be in English.** User-facing communication and saved documents in Korean.
- **Agent Team required**: Steps involving team creation and inter-agent discussion MUST use TeamCreate and SendMessage tools. Do NOT substitute with Agent tool sub-agents. Real-time inter-agent discussion (debate, challenge, cross-validation) is only possible through Agent Teams, not isolated sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. Run `ToolSearch` with query "select:AskUserQuestion", "select:TeamCreate", "select:SendMessage", and "select:TeamDelete" to load each tool. These are deferred tools and will NOT work unless loaded first. AskUserQuestion MUST be loaded before Step 1 (scope confirmation with user).
- **Claude Context MCP required**: Actively use for codebase indexing and code search. Complete index creation/verification in Step 2 before team creation. Teammates have direct access to Claude Context MCP tools (`search_code`, etc.) and should search independently — the lead does not need to proxy searches.
- **PR comment dedup required**: When existing PR comments/reviews exist, always provide them as context to reviewers. Filter or flag findings that duplicate existing comments.
- **Fix suggestion inclusion**: Include fix direction when clear. This is judgment-based, not mandatory for all issues — decide based on issue type and complexity.
- **Sequential Thinking MCP**: The lead should use this when:
    - Synthesizing conflicting findings from multiple reviewers (Step 5)
    - Handling complex multi-step follow-up requests (Step 6)
    - Making team composition decisions for atypical or multi-domain PRs (Step 3)
    - Do NOT use for routine tasks (scope confirmation, simple follow-ups).
- **CI failure routing**: When CI has failed checks, mention in Step 1c. Analyze failure type (test/lint/build/type check) and add "CI failure priority check area: [failed check name and related files]" as a separate item in the relevant reviewer's context package.

Task: $ARGUMENTS
