---
name: github-ops
description: GitHub 이슈·PR 작업 절차 — 이슈 본문 작성 원칙, Assignee 지정 시점, PR 발행·이슈 연결, 머지 절차와 CI 대기 분기, 인라인 리뷰 코멘트 묶음 제출
when_to_use: 이슈를 생성·수정하거나, PR을 발행·머지하거나, PR에 인라인 리뷰 코멘트를 남기기 직전
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. GitHub 이슈·PR 작업 직전에 모델이 열어 그대로 따른다.)"
options: []
notes: |
    슬래시 커맨드 surface 가 없는 model-invoked 정책 스킬이다. 모델은 frontmatter
    `description` + `when_to_use` 로 호출을 결정하고, body 의 다섯 절을 해당 행위 직전에
    그대로 적용한다. 이 스킬은 어떤 명령도 대신 실행하지 않는다 — 절차만 싣는다.
---

# github-ops

Procedures for GitHub issue and pull-request work. Apply before creating or
editing an issue, before opening or merging a PR, and before leaving more than
one inline review comment.

## 1. Issue body — describe the problem, not the fix

- Do NOT put a detailed solution or a concrete implementation proposal in the issue body. Concentrate on describing the problem situation itself in detail.
- Carry enough fact to let a reader pin the problem down exactly: reproduction steps, the gap between expected and actual behavior, the environment and conditions it occurs under, relevant logs and error messages, and the blast radius.
- Sketching a rough direction is allowed — "several instances must be coordinated into one cycle" is the right altitude. Concrete design and implementation method belong to a later, separate step, not to the issue: a detailed fix fixed before investigation narrows both root-cause analysis and the search for alternatives.
- The high-level direction is optional, not an obligation. A problem description alone can be the whole body (when the cause is clear the direction is usually self-evident), and if you do include one, keep it to the core in a sentence or two.
- **Exception**: include a detailed solution only when the user explicitly asks for one.
- **NEVER write a meta sentence saying this rule is being followed** — e.g. "구체 설계는 별도 단계에서 다룬다", "상세 방안은 이후 논의에서 정한다". Such a sentence is meaningless to an outside reader. The rule is a behavioral instruction to the author, not body content — and this holds for PR bodies as well as issue bodies.

## 2. Assignee on issues

- Do NOT pass `--assignee` to `gh issue create`. Creating an issue is backlog registration only; an assignee stamped at creation makes an untouched issue look owned regardless of whether anyone started it, which destroys the ability to identify what is actually in progress.
- Assign at the moment the issue is actually picked up, to the user: `gh issue edit <N> --add-assignee @me`.
- The PR assignee rule (§3) is a separate rule and stays as it is — this one does not override it.

## 3. Opening a PR

Always apply both:

- Set the assignee to the user — `gh pr create --assignee @me`.
- If a related issue exists, link it in the PR body as `Closes #N` / `Refs #N`. Before opening, run `gh issue list --state all` and check whether a matching candidate exists.

## 4. Merging a PR

Merge only on an explicit request. A `branch → commit → pr → merge` chain
request counts as explicit through the final merge; unless the request
explicitly skips it, waiting for CI is included.

- **CI wait**: run `gh pr checks --watch` in the background, continue with other work, and resume from it. A new session MUST re-query `gh pr checks` — never rely on a remembered result. If no check is registered yet, keep re-querying for about 90 seconds; if it is still 0 after that window expires, report "no checks" and proceed.
- **Reading the result**: all green → merge. On failure, note first that `exit 1` with 0 checks is *not registered* rather than failed — the ~90s re-query above preempts that case. Otherwise branch on the **number of check rows** printed by `gh pr checks --required` (the row count, NOT the exit code):
    - **0 rows** (no required checks designated) → the failures from the run *without* `--required` are the subject.
    - **all required checks passing** → enumerate the failing non-required checks, report them, and ask whether to merge. **No answer means do not merge.**
    - **required pending (`exit 8`)** → return to waiting.
    - **anything else** (a required check failed, or an error) → analyze the cause and propose a fix. On approval, merge automatically once CI passes again — no second confirmation.
- **Executing the merge**: record the head SHA when the CI wait starts (or immediately before merging when the wait was skipped), then run `gh pr merge <method flag> --match-head-commit <SHA> --delete-branch`. If the SHA no longer matches, start over. **`--admin` is forbidden** except on explicit instruction. On a merge-queue repository, do the follow-up handling after the PR reaches MERGED.
- **Choosing the merge method**: a method named in the request wins outright (if that method is disabled, report it). Otherwise take the convention from repository documentation (`CONTRIBUTING.md`, the project's `CLAUDE.md`, `README`, `.github/`) and from GitHub settings (allowed merge methods, branch protection rules). **Past merge history does not count as a convention.** With no convention, fall back in the order merge commit → squash → rebase, skipping disabled methods. Report to the user only when documentation and settings conflict with each other.
- **After merging**: clean up locally. If cleanup fails (the branch is checked out in a worktree, there are uncommitted changes, …) do NOT force-delete, do NOT remove the worktree, and do NOT stash — report only.

## 5. Inline review comments

- When leaving several inline review comments on a PR, do NOT post them one at a time (`POST .../pulls/{n}/comments`). **Submit them bundled as a single review**: `POST .../pulls/{n}/reviews` with every inline comment in the `comments[]` array under one event (`event=COMMENT`, etc.) — the API equivalent of the GitHub UI's "Start a review → Finish your review". The author then receives one notification and the review reads as one unit.
- A single comment may be posted on its own.
- An intermittent 404 is a transient network/SSO error — retry.
