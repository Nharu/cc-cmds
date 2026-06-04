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

## Paste-Ready Comment Blockquote

Each P0~P2 finding carries a self-contained, paste-ready GitHub comment directly below its analysis (근거 / 💡 수정 제안). The lead authors these during Step 5 synthesis — reviewers (Step 4) never pre-write them, since P-levels are only fixed after the internal 5-level → 4-level mapping. The user copies the blockquote and pastes it straight into a GitHub inline comment with no rewriting.

**Skeleton** (list sub-bullet, 4-space indent; the label is plain text *outside* the blockquote, and the blockquote `>` holds *only the comment body*):

```
    💬 **붙여넣기용 코멘트**

    > **P{N}: [자기완결적 한 문장 재진술, 마침표로 끝].**
    >
    > **[근거]**
    > [정중체 근거 — 이슈 위치를 첫 언급에서 `파일:라인`으로 명시]
    >
    > **[제안]**
    > [💡 수정 제안을 정중체로 재진술]
```

- **Label outside the blockquote**: the `💬 붙여넣기용 코멘트` label is a plain paragraph; the blockquote carries only the comment body. Copying just the blockquote pastes cleanly with no meta-label contamination (works for both raw-markdown copy and rendered-selection copy).
- **Title = prose only** (no `파일:라인`); **location (`파일:라인`) goes in the first mention inside `[근거]`** → self-contained for both inline comments (line implicit) and general PR comments (path needed).
- **Container = blockquote** (never a code fence — monospace rendering would destroy bold / inline-code formatting).
- **Standalone reading**: the comment must read on its own, with no cross-reference such as "위 분석 참조".

### Tone duality (분석 = 단정체 / 코멘트 = 정중체)

The analysis body states facts assertively; the paste-ready comment is polite. Do not hedge a confirmed bug in the comment.

- **Fact statements**: `~됩니다 / ~있습니다 / ~없습니다 / ~입니다` (no hedging — never `~인 것 같습니다` / `~일 수도 있습니다` for a confirmed bug).
- **Requests / suggestions**: `~하시면 될 것 같습니다 / ~해주시면 좋겠습니다 / ~좋을 듯합니다` (`~해야 합니다` only when the P0 intent is to block merge; never `~하세요` / `~해라`).

### Severity rules

| Severity | Paste-ready comment | `[근거]` | `[제안]` |
|----------|---------------------|---------|---------|
| P0 | Blockquote | Required | Required |
| P1 | Blockquote | Required | Required |
| P2 | Blockquote | Required | Only when the analysis carries a `💡 수정 제안` |
| P3 | Item line *is* the comment (no blockquote) | — | — |

- P2 `[제안]` is gated on the presence of `💡 수정 제안` in the analysis (itself "non-obvious only" per Fix Suggestion Inclusion Rules) → the comment never invents a suggestion the analysis lacks.
- **P3**: write the single item line itself in polite, self-contained form from the start (no separate blockquote / `[근거]` / `[제안]`). When copying a P3 line, **exclude the trailing `— {리뷰어명}` attribution** (it stays in the document for tracking but is not part of the comment). For P0~P2 the attribution lives on the header line outside the blockquote, so it is already excluded.

### confirms-existing exception (dedup)

When a finding only **confirms an existing PR comment** (it carries `📎 관련 PR 코멘트`), do NOT produce a duplicate paste-ready comment. Instead place a single plain-text note below the analysis — no blockquote, no `💬` label:

> 이미 PR 코멘트 #N에서 제기된 사항입니다 — 해당 스레드에 동의하시거나 resolve 처리해주시면 될 것 같습니다.

(If the thread reference is a URL, substitute `이미 [이 PR 코멘트](URL)에서 제기된 사항입니다`.) The absence of a blockquote on a confirms-existing finding is the signal for "nothing new to post" (P3 excepted — a P3 line is itself the comment). In the rare case a P3 line is itself confirms-existing, the dedup rule wins: do not post that line as a comment, leave only the confirms-existing plain note.

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

각 P0·P1·P2 항목은 분석(근거/제안) 아래에 `💬 붙여넣기용 코멘트` 블록을 두어 GitHub 인라인 코멘트로 그대로 복사할 수 있게 했다(톤: 분석은 단정, 코멘트는 정중). P3는 항목 한 줄이 곧 코멘트다.

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

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (📎로 confirms-existing이면 블록쿼트 대신 평문 노트)

## 🟠 P1 (머지 전 수정 권장)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction]
    - 📎 관련 PR 코멘트: [if applicable]

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (📎로 confirms-existing이면 블록쿼트 대신 평문 노트)

## 🟡 P2 (차후 이슈 등록 권장)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [when non-obvious only]

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (`[제안]`은 💡 수정 제안이 있을 때만; 📎로 confirms-existing이면 평문 노트)

## 🟢 P3 (개선 제안)

- **[category]** `파일:라인` [정중체·자기완결 한 줄 — 그대로 붙여넣을 수 있는 개선 제안] — 리뷰어
- **[category]** `파일:라인` [정중체·자기완결 한 줄 — 줄 끝 `— 리뷰어명`은 복사 시 제외] — 리뷰어

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
