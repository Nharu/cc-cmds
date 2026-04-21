# Review Report Template

The lead synthesizes all review results into a Korean document using this template (Step 5).

## Severity System (P0~P3)

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

## Merge Recommendation Rules

- **P0 ≥ 1** → "머지 불가 (즉시 수정 필요)"
- **P1 ≥ 1, P0 = 0** → "머지 전 수정 권장"
- **P0 + P1 = 0** → "머지 가능"

## Category Tags

Findings use `[category]` tags from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`.

When CI has detected failures that a reviewer confirms, add `[CI-CONFIRMED]` tag to distinguish from independent findings.

## Finding Merge Rules

When multiple reviewers raise issues at the same location:
- **Same file/line issue**: Merge into one item, preserve each reviewer's perspective as sub-items.
- **Severity conflict**: Default to higher severity, unless the lead resolved the dispute in Step 4 — in that case, follow the resolution. Document both rationales.
- **Independent perspective issues**: If same location but different nature (e.g., security vs performance), keep as separate items.
- **False positives**: Items agreed as false positive during cross-validation are excluded from the final document. Briefly mention in "리뷰어 간 이견 사항" section if needed.
- **Positive findings**: Synthesize reviewers' `[POSITIVE]` items into the "긍정적 사항" section.

## Fix Suggestion Inclusion Rules

| Severity | Fix Suggestion |
|----------|---------------|
| P0 | Mandatory |
| P1 | Mandatory |
| P2 | Include when non-obvious |
| P3 | Omit when obvious. Include for non-obvious tech debt (from `low` source) |

"Non-obvious" criteria: 3+ equally valid approaches exist, fix impacts other modules, or domain knowledge is required.

## Document Structure

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

## File Saving

Location: `docs/reviews/` (create with `mkdir -p docs/reviews/` if it does not exist).

Naming conventions:
- PR review: `review-pr{NUMBER}_{YYYY-MM-DD}.md` (e.g., `review-pr42_2026-03-26.md`)
- Local diff: `review-{branch-name}_{YYYY-MM-DD}.md` (e.g., `review-feat-auth_2026-03-26.md`)
- Re-review: `review-pr{NUMBER}_{YYYY-MM-DD}_v{N}.md` (e.g., `review-pr42_2026-03-26_v2.md`)
    - If a previous review exists for the same PR, always increment `_v{N}`. Previous documents are preserved for review history tracking.
    - Step 6 in-place edits apply only within the same review session. A separate session re-review creates a new version document.

**Previous review detection**: On re-review, search `docs/reviews/` for `review-pr{NUMBER}_*.md` pattern, find the highest version number, and assign the next version. If no previous file exists, create without version suffix.

**Re-review dedup**: For re-reviews (v2+), include previous review document findings as reference material in reviewer context. Mark unresolved issues as `persists from v{N-1}`. Resolved issues need no separate reporting.

## Document Update Rules (Step 6)

- Update `docs/reviews/` document immediately whenever findings change.
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
