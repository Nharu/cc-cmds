---
name: review
description: 에이전트 팀을 활용한 다관점 코드 리뷰
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

- Create team with approved composition. Team naming conventions:
  - PR review: `review-pr{NUMBER}` (e.g., `review-pr42`)
  - Local diff: `review-{branch-name}` (e.g., `review-feat-auth`)
  - File path: `review-{short-slug}` (e.g., `review-auth-module`)
  - Step 6 re-creation: original team name + `-followup` (e.g., `review-pr42-followup`)
- All team-internal discussion in English
- NO code modifications allowed. Review only.
- **The lead acts as a facilitator**, actively driving multi-round review

#### Reviewer Context Package

When assigning each reviewer, include the following in the initial message:

1. **Completion signal instruction**: "When you send your result, start the message with `[COMPLETE]` if your review is finished, or `[IN PROGRESS]` if you need more time to analyze. If `[IN PROGRESS]`, briefly state what remains."
2. **Review scope diff**: Full diff or role-filtered diff
3. **Role-relevant changed file list**: Filtered by the lead based on Step 3 assigned scope + Round 0 results (if Scope Coordinator exists)
4. **Role-specific review checklist** (with MCP search query guidance — see below)
5. **Existing PR comments/review summary** + dedup instruction: "Do not report already-raised issues as new findings. If you confirm an existing issue, reference it as 'confirms existing review by @author' and add only additional analysis."
6. **PR metadata** (CI status, draft status, linked issues) — omit for non-PR reviews
7. **Fix suggestion rules**: critical/high = mandatory, medium = include when non-obvious, low = include only for non-obvious tech debt, nitpick = omit
8. **Claude Context MCP usage guide**: Reference role-specific checklist MCP items
9. **Context size management**: For large diffs, filter to role-relevant file diffs only. Include change stats summary + high-risk file diffs in initial message; point reviewers to MCP `search_code` for the rest. For many existing PR comments, send summary only.
10. **Severity system definition**: Reviewers use 5 levels:
    - `critical`: Immediately exploitable security vulnerability in production, data loss/leakage, complete core functionality block
    - `high`: High probability of production incident or security issue, merge block recommended
    - `medium`: Quality/performance degradation under real load, fix recommended before or after merge
    - `low`: Minor code smell, future tech debt, style inconsistency
    - `nitpick`: Pure cosmetic or marginal optimization
11. **(Large PR, with Scope Coordinator)** **Round 0 analysis results**: This reviewer's focus areas, high-risk file list, priority check areas
12. **Positive findings**: "If you find well-implemented patterns or noteworthy positive aspects, include them with a `[POSITIVE]` tag briefly."
13. **(Optional) Lead's codebase exploration summary** from Step 2b — key dependencies, related test files, existing pattern summary. Include within context size limits.
14. **Category tag list**: Choose from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`
15. **Reporting format**: Findings must follow this structure:
    ```
    [severity] [category] file:line (or module/pattern) — issue description
      Rationale: severity justification
      Fix suggestion: fix direction (when applicable)
    [POSITIVE] file:line — positive aspect (when applicable)
    ```

#### Role-specific review checklists

**Security reviewer:**
- Authentication/authorization: JWT validation, per-route auth guards, privilege escalation, IDOR
- Input validation: SQL/NoSQL injection, XSS, path traversal, SSRF, command injection
- Sensitive data: hardcoded secrets, PII logging, excessive API response fields
- Cryptography: weak hashing, hardcoded IV/salt, insecure random
- MCP usage: search with role-relevant keywords focused on changed files and related modules. Narrow scope by changed file paths if results are too broad.

**Performance reviewer:**
- DB/ORM: N+1 queries, unused eager loading, missing pagination, full table scans, missing transactions
- Memory/resources: event listener leaks, unreleased timers, unclosed streams/connections, unbounded caches
- Computation: O(n^2)+, unnecessary computation in hot paths, missing memoization
- Concurrency/IO: sequential await (where Promise.all is possible), main thread blocking, missing connection pooling
- MCP usage: search for DB call patterns, query builders, pagination keywords focused on changed areas. Narrow by file paths if too broad.

**Code quality reviewer:**
- Design: SRP, DRY violations, inappropriate coupling, over/under-abstraction
- Error handling: swallowed exceptions, generic catch, unhandled async errors, inconsistent error formats
- Readability: magic numbers/strings, complex conditionals, misleading names, long functions
- Type safety (TypeScript): `any` types, unsafe type assertions, missing return types, unhandled nullable
- Testing: missing test coverage for new logic, implementation-coupled tests, missing edge cases
- MCP usage: search for usages of changed functions/classes, similar patterns, error formats focused on changed areas. Narrow if too broad.

**Dynamic roles (applied as needed):**
- DB/query expert: migration rollback safety, index impact, query plans
- API contract reviewer: backward compatibility, breaking changes, versioning
- Concurrency reviewer: race conditions, lock usage, idempotency
- Logic reviewer: business logic correctness, branch condition completeness, edge case coverage, requirements-implementation alignment

#### Review Protocol (minimum 2 rounds)

1. **Round 1 — Independent Review**: Each reviewer reviews independently from their own perspective. Wait for ALL reviewers to submit `[COMPLETE]` findings. If a reviewer sends `[IN PROGRESS]`, reply with "Take your time and send your complete findings when ready" — do NOT move on.

2. **Quality Gate**: Before cross-validation, verify each review meets minimum quality:
    - Specific location references: `file:line` or `module/pattern` for architecture/pattern-level issues (no vague descriptions)
    - Severity rationale included for each finding
    - No duplication with existing PR comments
    - Fix suggestions included where appropriate
    - **Checklist coverage check**: Judge by whether the reviewer actually checked checklist items, not by finding count. "Checked but no issues found" is normal (clean code). If findings are listed without any mention of checklist items, judge as insufficient and request re-check. Re-request until QG passes (within total round safety limit).

3. **Cross-validation**: Send each reviewer's findings to other reviewers. Explicitly request: validate severity assessments, identify missed issues in overlapping areas, flag false positives, and note findings that interact with their own.

4. **Round 2+ — Refinement**: Forward cross-validation feedback to original authors. Request severity revision, missed issue additions, and challenge responses. Repeat until convergence.

5. **Convergence Check**: After each round, ask ALL reviewers: "Do you have any remaining findings to add or severity assessments to dispute? Reply with `[COMPLETE] No further input` or `[IN PROGRESS]` with your remaining concerns." Only proceed to Step 5 when ALL reviewers confirm `[COMPLETE]`.

**When Scope Coordinator exists (large PR):**
- **Round 0 (pre-analysis)**: Scope Coordinator classifies changed files by risk and assigns reviewer focus areas. Results included in reviewer context packages alongside Round 1 assignment.
- **After Quality Gate**: Scope Coordinator performs coverage audit — identifies high-risk areas not yet reviewed and requests additional review from relevant reviewers.
- **During cross-validation**: Scope Coordinator synthesizes findings from multiple reviewers to identify cross-cutting issues (inter-module interaction problems).
- Scope Coordinator uses the same `[COMPLETE]`/`[IN PROGRESS]` signals and is included in Convergence Checks.

#### Facilitator Rules

- **Distinguish idle notifications from DMs**: Messages marked with `(idle)` are **system-generated summaries**, NOT teammate DMs. Even if an idle notification contains words like "completed" or "finished", it is NOT a `[COMPLETE]` signal. ONLY count a response as received when the teammate sends an actual DM via SendMessage that starts with `[COMPLETE]` or `[IN PROGRESS]`.
- **Idle ≠ Done**: A teammate going idle is normal — it does NOT mean they are done. Teammates may go idle while still processing (e.g., during sequential-thinking). If a teammate goes idle without sending a DM, send them a follow-up asking for their status.
- **Do NOT end review after the first response.** Even if all reviewers send `[COMPLETE]` in Round 1, you MUST proceed to cross-validation (Round 2) at minimum.
- **Cross-pollinate findings**: When one reviewer finds an issue that impacts another reviewer's scope, forward it and ask for their assessment.
- **Resolve severity disputes**: If reviewers disagree on severity, ask both to justify their rating before the lead makes a final call.
- **Ensure completeness**: If a reviewer's findings seem unusually sparse for their scope, ask them to double-check specific areas before accepting.
- **PR comment dedup (2-layer check)**: Reviewers receive existing PR comments as context for 1st-layer filtering. The lead performs 2nd-layer verification during cross-validation to catch missed duplicates. Both reviewers and lead share responsibility to minimize duplication.
- **Round safety limit**: Step 4 review protocol is capped at **10 rounds maximum**. Upon reaching the limit, report current state to the user and ask whether to extend by 10 more rounds. Extensions can repeat indefinitely.

---

### Step 5: Result Synthesis & Documentation (Korean)

The lead synthesizes all review results into a Korean document.

#### Severity system (P0~P3)

| Level | Icon | Meaning | Merge Impact |
|-------|------|---------|--------------|
| P0 | 🔴 | Immediate fix (security vulnerability, data corruption, complete feature block) | Merge blocked |
| P1 | 🟠 | Fix recommended before merge | Merge block recommended |
| P2 | 🟡 | Register as follow-up issue recommended | Mergeable |
| P3 | 🟢 | Improvement suggestion (includes nitpick) | Optional |

Internal 5-level → document 4-level mapping:
- critical → P0
- high → P1
- medium → P2
- low + nitpick → P3

**Skip P0 section if empty** (applies to most PRs). Only show when applicable.
**Skip "리뷰어 간 이견 사항" and "미검토 영역" sections if not applicable.**

#### Merge recommendation rules

- **P0 ≥ 1** → "머지 불가 (즉시 수정 필요)"
- **P1 ≥ 1, P0 = 0** → "머지 전 수정 권장"
- **P0 + P1 = 0** → "머지 가능"

#### Category tags

Findings use `[category]` tags from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`

When CI has detected failures that a reviewer confirms, add `[CI-CONFIRMED]` tag to distinguish from independent findings.

#### Finding merge rules

When multiple reviewers raise issues at the same location:
- **Same file/line issue**: Merge into one item, preserve each reviewer's perspective as sub-items
- **Severity conflict**: Default to higher severity, unless the lead resolved the dispute in Step 4 — in that case, follow the resolution. Document both rationales.
- **Independent perspective issues**: If same location but different nature (e.g., security vs performance), keep as separate items
- **False positives**: Items agreed as false positive during cross-validation are excluded from the final document. Briefly mention in "리뷰어 간 이견 사항" section if needed.
- **Positive findings**: Synthesize reviewers' `[POSITIVE]` items into the "긍정적 사항" section.

#### Fix suggestion inclusion rules

| Severity | Fix Suggestion |
|----------|---------------|
| P0 | Mandatory |
| P1 | Mandatory |
| P2 | Include when non-obvious |
| P3 | Omit when obvious. Include for non-obvious tech debt (from `low` source) |

"Non-obvious" criteria: 3+ equally valid approaches exist, fix impacts other modules, or domain knowledge is required.

#### Document structure

```markdown
# 코드 리뷰 리포트

## 개요

- **PR**: #[number] — [title]
- **URL**: [PR URL]
- **리뷰 날짜**: YYYY-MM-DD
- **PR 상태**: Open / Draft / Merged
- **CI 상태**: ✅ 통과 / ⚠️ [failed check list] / ❌ 빌드 실패
- **리뷰 대상**: [files/directories/commit range]
- **변경 규모**: 파일 X개, +Y줄 / -Z줄
- **리뷰 팀 구성**:
    - [role] ([model]): [scope]
    - ...
- **발견 요약**: 🔴 P0 N건 | 🟠 P1 N건 | 🟡 P2 N건 | 🟢 P3 N건

---

## 핵심 요약

[3-5 sentences: overall code quality assessment, most important findings, merge recommendation.
Mention CI failure items if applicable.]

---

## 🔴 P0 (즉시 수정 필수) ← skip section if none

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction or example code]
    - 📎 관련 PR 코멘트: [@author의 기존 코멘트 참조] (if applicable)

## 🟠 P1 (머지 전 수정 권장)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction]
    - 📎 관련 PR 코멘트: [if applicable]

## 🟡 P2 (차후 이슈 등록 권장)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [when non-obvious only]

## 🟢 P3 (개선 제안)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
- **[category]** `파일:라인` 이슈 설명 — 리뷰어

---

## 리뷰어 간 이견 사항

[severity disagreements, both rationales, final resolution]

---

## 긍정적 사항

- [well-implemented patterns, best practices, improvements over existing code]

---

## 미검토 영역

[intentionally excluded files or perspectives — transparently disclose blind spots]

---

## 개정 이력

[Updated when changes occur during Step 6 follow-up. Leave empty on initial creation.]

---

## 철회된 항목

[Findings invalidated by user context. Leave empty on initial creation.]
```

#### File saving

Location: `docs/reviews/` (create with `mkdir -p docs/reviews/` if it does not exist)

Naming conventions:
- PR review: `review-pr{NUMBER}_{YYYY-MM-DD}.md` (e.g., `review-pr42_2026-03-26.md`)
- Local diff: `review-{branch-name}_{YYYY-MM-DD}.md` (e.g., `review-feat-auth_2026-03-26.md`)
- Re-review: `review-pr{NUMBER}_{YYYY-MM-DD}_v{N}.md` (e.g., `review-pr42_2026-03-26_v2.md`)
    - If a previous review exists for the same PR, always increment `_v{N}`. Previous documents are preserved for review history tracking.
    - Step 6 in-place edits apply only within the same review session. A separate session re-review creates a new version document.

**Previous review detection**: On re-review, search `docs/reviews/` for `review-pr{NUMBER}_*.md` pattern, find the highest version number, and assign the next version. If no previous file exists, create without version suffix.

**Re-review dedup**: For re-reviews (v2+), include previous review document findings as reference material in reviewer context. Mark unresolved issues as `persists from v{N-1}`. Resolved issues need no separate reporting.

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

- Update `docs/reviews/` document immediately whenever findings change
- Add entries to `## 개정 이력` section:
    ```
    ## 개정 이력
    - YYYY-MM-DD: [change summary]
    ```
- Move findings invalidated by user context to `## 철회된 항목` section:
    ```
    ## 철회된 항목
    - ~~[original finding]~~ — 철회 사유: [user-provided context]
    ```

Repeat until user is satisfied.

---

## Non-PR Mode Adaptation

When reviewing non-PR targets (local diff, file paths):

| Element | PR Mode | Non-PR Mode (local diff) |
|---------|---------|--------------------------|
| PR comment collection | `gh api` | Skip |
| CI status check | `gh pr checks` | Skip |
| Document header PR fields | Included | Replace with branch name + commit range |
| Dedup instruction | Reference existing PR comments | N/A ("fully independent review") |
| Finding PR comment field | Reference related comments | `N/A (로컬 diff 모드)` |
| Reviewer checklist | Includes PR comment items | Focus on code-only analysis |

**File path-based review** (reviewing specific files/directories without a diff):

| Element | PR Mode | File Path Mode |
|---------|---------|----------------|
| Review target | PR diff | Full code of specified files/directories |
| PR comments/CI | `gh` used | N/A |
| Diff-based analysis | Focus on changed lines | Full code analysis (augment context with MCP `search_code`) |
| Document header | PR info included | Show target file/directory paths |

File path mode context package adaptations:
- Item 2 "Review scope diff" → replace with "Full source code of target files". For large target files, send only core modules and guide reviewers to explore the rest via MCP `search_code` (same principle as item 9 context size management).
- Item 5 "Existing PR comments" → replace with "N/A".

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
- **Team cleanup required**: After Step 5 documentation is complete, before Step 6 begins, clean up the team. (If additional reviewer clarification is needed during Step 5 document writing, do so before cleanup.) Follow these steps IN ORDER — do NOT skip ahead:
  1. Send `shutdown_request` to each teammate via `SendMessage` (type: "shutdown_request").
  2. **WAIT for ALL teammates to confirm shutdown** (they respond with `shutdown_response` approve: true). Do NOT proceed to step 3 until every teammate has responded. If a teammate does not respond, retry the `shutdown_request` — **repeat up to 10 times**. **NEVER forcefully kill (`kill`) agent processes.**
  3. **If a teammate still has not responded after 10 retries**, use `AskUserQuestion` to inform the user which teammate(s) failed to shut down and ask them to handle it manually. Do NOT proceed to TeamDelete until resolved.
  4. Call `TeamDelete` to remove the team files and clean up resources. Only call this AFTER all teammates have confirmed shutdown or the user has handled unresponsive teammates.
  5. **Verify process cleanup**: Run `ps aux | grep "team-name" | grep -v grep` to check for orphan agent processes. If any remain, **do NOT kill them** — use `AskUserQuestion` to inform the user of the remaining PIDs and ask them to terminate the processes.
  - **Shutdown failure fallback**: If `TeamDelete` fails due to active teammates, **do NOT use `rm -rf` or `kill`**. Instead, use `AskUserQuestion` to inform the user of the failure and ask them to manually clean up (`~/.claude/teams/{team-name}` and `~/.claude/tasks/{team-name}`).
  - When multiple teams are created during workflow (e.g., Step 6 follow-up), always clean up the previous team before creating the next one.

Task: $ARGUMENTS
