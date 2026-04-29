---
name: review-lite
description: 2인 팀을 활용한 경량 코드 리뷰
when_to_use: 빠른 코드 리뷰가 목적이고 다관점 심층 분석이 불필요할 때 (큰 PR coverage gap, 미묘한 race condition·authn bypass 검출률 약화 가능)
disable-model-invocation: true
usage: "/cc-cmds:review-lite [<target>]"
options:
    - name: "<target>"
      kind: positional
      required: false
      summary: "리뷰 대상 (PR 번호/URL, 브랜치, 파일/디렉토리, 또는 생략 시 현재 브랜치 자동 감지). PR 크기 무관 — 큰 PR 은 report 의 *리뷰 범위* 섹션에 미커버 영역 명시."
---

Conduct a lightweight code review using a fixed 2-member sonnet agent team for the given task.
All team discussions and inter-agent communication should be in English to optimize token usage.
User-facing communication and saved documentation should be in Korean.

This skill is the lightweight sibling of `review`. It trades depth for predictable token cost: a fixed 2-member sonnet team (Security reviewer + Code-quality/Logic reviewer) replaces the dynamic risk-indicator-driven composition, the discussion runs a single round + one cross-validation round (no follow-ups), Claude Context MCP and the Explore subagent are skipped, and the second-positional `<directive>` argument is dropped. Use `review` when subtle invariants — concurrency, authn bypass — or large-PR depth-driven scope splitting matter more than speed.

## Input

> _Consistency Note: README의 user-facing 요약은 frontmatter `options[]`에서 자동 생성됨. 본 섹션은 runtime-agent 작동 규약이며, 변경 시 frontmatter도 함께 갱신._

`$ARGUMENTS` can be: a PR URL (`https://github.com/.../pull/N`), a PR number, a branch name, a file/directory path, or empty (auto-detect from current branch). The base `review` skill's second positional `<directive>` is **not supported** in lite — see Step 1a for the dropped-token warning.

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
- **Mixed input with extra tokens after the target** (e.g., "PR #42 보안 중심으로"): extract the target only. Emit one Korean warning and discard the remainder: *"리뷰 지시문은 review-lite에서 지원하지 않아 무시합니다. 가중치 분석이 필요하면 /cc-cmds:review 를 사용하세요."* Do NOT propagate the directive to team composition, context package, or the report.
- **Ambiguous input** → clarify with AskUserQuestion

When `$ARGUMENTS` is empty, run auto-detect chain:

1. `gh pr view --json number,title,url,state,isDraft,baseRefName,additions,deletions,changedFiles` → success: PR review
2. Failure: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` → `git diff {DEFAULT_BRANCH}...HEAD --stat` → if diff exists: local diff review
3. No diff: AskUserQuestion to request review target

**If target is a non-PR (local diff or file path)**, Read `${CLAUDE_SKILL_DIR}/../review/references/03-non-pr-mode.md` to apply adaptations to Steps 2-5 (context package items 2/5, document header, checklist focus).

#### 1b: Context collection

**For PR targets:**

```bash
# Repository slug (used in subsequent gh api calls)
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# PR metadata (latestReviews = current state snapshot per reviewer; full history via gh api .../reviews below)
gh pr view $PR_NUMBER --json number,title,body,state,isDraft,labels,milestone,\
  assignees,reviewRequests,latestReviews,headRefName,baseRefName,url,createdAt,\
  additions,deletions,changedFiles

# Changed files with per-file statistics (path, additions, deletions; '.[] | .path' for path-only)
gh pr view $PR_NUMBER --json files --jq '[.files[] | {path,additions,deletions}]'

# Full diff
gh pr diff $PR_NUMBER

# Existing inline review comments
gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/comments" | \
  jq '[.[] | {author: .user.login, file: .path, line: .line, body: .body, \
  created_at: .created_at, resolved: (.resolved // false)}]' | \
  jq -s 'add'

# Review decisions
gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews" | \
  jq '[.[] | {author: .user.login, state: .state, body: .body, \
  submitted_at: .submitted_at}]' | \
  jq -s 'add'

# General PR comments
gh pr view $PR_NUMBER --json comments \
  --jq '[.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]'

# CI check status
gh pr checks $PR_NUMBER --json name,state,bucket 2>/dev/null || echo "[]"
```

**For local diff targets:**

```bash
git diff {DEFAULT_BRANCH}...HEAD        # full diff
git log {DEFAULT_BRANCH}..HEAD --oneline  # commit history
```

#### 1c: Scope confirmation

Present to user (in Korean):
- Review target type (PR / local diff / user-specified)
- PR title/number/URL (if PR)
- Change statistics (file count, additions, deletions)
- Key changed files/modules
- Existing PR review comment summary (if any)
- CI status (highlight failed checks if any)

**No large-PR gate**: PR size is not a lite-savings axis. Proceed regardless of size; the Step 5 *리뷰 범위* section will explicitly disclose any context-window-driven coverage gap. Proceed after user confirmation.

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

### Step 2: Codebase Exploration (lead-direct)

**Claude Context MCP is not used in lite.** Do NOT call `index_codebase`, `get_indexing_status`, or `search_code`. The `Explore` subagent is also not used — the lead explores directly with `grep` + `Read`.

Explore based on the changed file list:
- Related modules and dependencies (callers, importers) — `grep -r` from project root, scoped to changed files' siblings.
- Related test files — `grep -r` for the changed module names + project test directory conventions.
- Existing patterns and conventions in the affected area — `Read` representative neighbours.
- Architectural context — `Read` top-level structure files (e.g., index/router/manifest).

This exploration output is the key input for Step 3 reviewer context packages.

---

### Step 3: Team Composition Announcement (Korean)

**No proposal cycle.** The team composition is fixed and announced to the user with a single Y/N gate.

Announcement template (Korean):

```
**리뷰 팀 구성** (review-lite 고정 2인):
| 역할 | 모델 | 담당 범위 |
|------|------|-----------|
| 보안 전담 리뷰어 | sonnet | 위협 모델, 인증·인가, 입력 검증, 시크릿/크레덴셜, 암호 사용, 세션·토큰 처리, 의존성 취약점 |
| 코드 품질·로직 리뷰어 | sonnet | 로직 정확성, API 계약, 가독성·유지보수성, 테스트, 성능 |

이 구성으로 진행할까요?
```

Branch on user response:
- **Approve** → create team, proceed to Step 4
- **Reject/abort** → end review

The split is structural (path-agnostic): the security reviewer covers any security-sensitive change regardless of file path or keyword pattern. There is no path-regex gate — `crypto/`, `signing/`, `jwt-validator.ts`, `csrf.ts`, `rate-limit/` etc. are all caught structurally by the dedicated security reviewer. There is also no `Scope Coordinator` role; the 2-member team self-divides scope, and any uncovered area is explicitly disclosed in the Step 5 report.

Team naming conventions:
- PR review: `review-lite-pr{NUMBER}` (e.g., `review-lite-pr42`)
- Local diff: `review-lite-{branch-name}` (e.g., `review-lite-feat-auth`)
- File path: `review-lite-{short-slug}` (e.g., `review-lite-auth-module`)

---

### Step 4: Parallel Review (English, team internal)

**Before assigning reviewers, Read `${CLAUDE_SKILL_DIR}/../_common/agent-team-protocol.md`** for the completion-signal contract and shared facilitator rules.

**Before building each reviewer's context package, Read `${CLAUDE_SKILL_DIR}/../review/references/01-reviewer-context-package.md`** for the 15-item package contents, role-specific checklists, review protocol rounds, and review-specific facilitator additions.

- Create team with the announced 2-member composition.
- All team-internal discussion in English.
- NO code modifications allowed. Review only.
- **The lead acts as a facilitator** within the lite round cap.

#### Round structure (fixed)

1. **Round 1 — Initial Review**: each reviewer independently produces findings within their scope (per the role-specific checklist from `01-reviewer-context-package.md`). Wait for `[COMPLETE]` from BOTH reviewers.
2. **Round 2 — Cross-Validation**: forward each reviewer's findings to the other reviewer for one cross-check pass (severity disagreements, missed cross-domain issues such as a security finding that also has performance implications, blind-spot disclosure). Wait for `[COMPLETE]` from BOTH reviewers.

**No further rounds.** No follow-up or refinement team cycle. Total team-internal rounds = 2.

---

### Step 5: Result Synthesis & Documentation (Korean)

**Before synthesizing review results, Read `${CLAUDE_SKILL_DIR}/../review/references/02-review-report-template.md`** for the severity system (P0~P3), merge rules, document structure template, and file naming/version conventions.

The lead synthesizes all review results into a Korean document under `docs/reviews/` following the template. Report length is unconstrained (length is not a lite-savings axis); structure is the floor — P0~P3 severity tags and the structured finding list MUST be preserved.

**Mandatory section — `## 리뷰 범위`** (coverage-gap explicit disclosure):

Every review-lite report MUST include this section so the user is never silently misled about uncovered files when a PR exceeds context-window throughput.

```markdown
## 리뷰 범위

- 보안 전담 리뷰어 분담: <files>
- 코드 품질·로직 리뷰어 분담: <files>
- 미커버 영역: <context window 한계로 분담 못 된 files; 없으면 "없음">
```

For small PRs the *미커버 영역* line is typically *"없음"*. For large PRs that exceeded coverage during Round 1, list the uncovered files explicitly so the user can decide whether to re-run with `/cc-cmds:review` for full coverage.

After saving the report:

- Notify the user in Korean: *"리뷰 보고서 저장을 완료했습니다. 팀을 정리한 뒤 결과를 공유드리겠습니다."*
- **Read `${CLAUDE_SKILL_DIR}/../_common/team-cleanup.md`** and follow the 5-step shutdown procedure.
- Present the report summary to the user in Korean.
- Emit the lite-redirect footer (single line, every invocation):

```
ℹ️ 보안 민감 PR, deep audit, 큰 PR 의 정밀 분담, 또는 미묘한 동시성 검증이 필요한 경우 /cc-cmds:review 권장.
```

---

### Step 6: Review Discussion & Follow-up (Korean, lead-only)

After presenting the review report, discuss with the user.

#### Lead direct handling (no team needed)

- Detailed explanation of specific findings
- Code section re-check (using `grep` + `Read` directly — Claude Context MCP is not used)
- Severity re-assessment when user provides new context (e.g., "이 코드 경로는 내부 전용입니다")
- Explanation of why a specific finding was not included

#### No team re-creation

Follow-up team spawning is **disabled in lite**. If the user requests comprehensive analysis of areas not covered, severity-dispute independent re-evaluation, multi-perspective architectural follow-up, or blind-spot deep-dive, do NOT spawn a new team. Instead emit in Korean: *"더 깊은 분석이 필요하면 `/cc-cmds:review` 를 사용해주세요."* and continue lead-only refinement of the existing report.

#### Document update rules

Refer to `${CLAUDE_SKILL_DIR}/../review/references/02-review-report-template.md` "Document Update Rules (Step 6)" section for the 개정 이력 / 철회된 항목 update conventions.

Repeat until user is satisfied.

---

## Constraints

- **No code modifications.** Review only.
- **Inter-agent communication must be in English.** User-facing communication and saved documents in Korean.
- **Sonnet pin**: every reviewer uses model `"sonnet"`. Haiku is forbidden; opus is out of scope (use `/cc-cmds:review` if opus depth is required).
- **Agent Team required**: TeamCreate + SendMessage only. Do NOT substitute with isolated Agent sub-agents.
- **Deferred tool loading**: Before using AskUserQuestion, TeamCreate, SendMessage, or TeamDelete, you MUST first load them via ToolSearch. AskUserQuestion MUST be loaded before Step 1.
- **No Claude Context MCP**: do NOT call `index_codebase`, `get_indexing_status`, or `search_code`. Use `grep` + `Read` only.
- **No Sequential Thinking MCP**: lite contract — predictable token cost.
- **PR comment dedup required**: when existing PR comments/reviews exist, always provide them as context to reviewers. Filter or flag findings that duplicate existing comments.
- **Fix suggestion inclusion**: include fix direction when clear. Judgment-based — decide based on issue type and complexity.
- **CI failure routing**: when CI has failed checks, mention them in Step 1c. Add "CI failure priority check area: [failed check name and related files]" to the relevant reviewer's context package — security-sensitive failures (auth, secrets) route to the security reviewer; logic/build/test failures route to the code-quality/logic reviewer.

Task: $ARGUMENTS
