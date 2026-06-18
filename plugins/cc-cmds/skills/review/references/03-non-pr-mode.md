# Non-PR Mode Adaptation

When reviewing non-PR targets (local diff, file paths), adapt the context package and document header as below.

**Paste-ready comments are still generated** in non-PR mode — the self-contained 정중체 blockquotes (see `02-review-report-template.md` "Paste-Ready Comment Blockquote") are portable to a future PR, a commit message, or an issue. The confirms-existing dedup exception does not apply here, since a fully independent review has no existing PR comments to defer to.

## Local diff mode

| Element | PR Mode | Non-PR Mode (local diff) |
|---------|---------|--------------------------|
| PR comment collection | `gh api` | Skip |
| CI status check | `gh pr checks` | Skip |
| Document header PR fields | Included | Replace with branch name + commit range |
| Dedup instruction | Reference existing PR comments | N/A ("fully independent review") |
| Finding PR comment field | Reference related comments | `N/A (로컬 diff 모드)` |
| Reviewer checklist | Includes PR comment items | Focus on code-only analysis |

## File path mode

File path-based review (reviewing specific files/directories without a diff):

| Element | PR Mode | File Path Mode |
|---------|---------|----------------|
| Review target | PR diff | Full code of specified files/directories |
| PR comments/CI | `gh` used | N/A |
| Diff-based analysis | Focus on changed lines | Full code analysis (augment context with `grep`/`Read`) |
| Document header | PR info included | Show target file/directory paths |

File path mode context package adaptations (ref. `01-reviewer-context-package.md` 15-item list):
- Item 2 "Review scope diff" → replace with "Full source code of target files". For large target files, send only core modules and guide reviewers to explore the rest via `grep`/`Read` (same principle as item 9 context size management).
- Item 5 "Existing PR comments" → replace with "N/A".
