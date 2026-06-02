# Author Feedback Document — Template

Renders `docs/analysis/<slug>.feedback.md`: a concise, author-facing list of the analysis findings. Written for the document's author — terse, actionable, grouped by severity. The full rationale lives in the report; this is the hand-off summary.

## Render rule

- Only `confirmed` / `amended` findings.
- `excluded` findings are omitted.
- `미검토` (abort) findings are listed under a "미검토 (사용자 조기 종료)" group with their flag.
- Each item: 이슈 → 근거 → 제안, kept to 1–3 lines. A-NN ties each item back to the report.
- In doc-only mode, omit code citations and add the doc-only scope note in the header.

## Structure

```markdown
# 설계 문서 피드백

> 대상: `<design-doc-path>` ([문서 제목])
> 분석 모드: 코드 grounding / 문서 단독
> 종합 권고: [verdict]
> 전체 근거·맥락은 분석 보고서(`<slug>.md`) 참조.

---

## 🔴 우선 해결 (critical) ← skip if none

### [A-NN] <title> `[foundational]`(해당 시)
- **이슈**: <한 줄 요지> (§doc-anchor)
- **근거**: <evidence 요약> (grounded: `path:line`)
- **제안**: <suggested_direction>

## 🟠 채택 전 검토 (major) ← skip if none

### [A-NN] <title>
- **이슈**: … (§anchor)
- **근거**: …
- **제안**: …

## 🟡 개선 제안 (minor) ← skip if none

- **[A-NN]** <title> — <한 줄 이슈+제안> (§anchor)

---

## 미검토 (사용자 조기 종료) ← 워크스루 중단 시에만

- **[A-NN]** <title> — 미검토 상태로 남음 (§anchor)
```
