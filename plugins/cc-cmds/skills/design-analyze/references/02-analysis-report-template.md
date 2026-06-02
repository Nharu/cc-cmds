# Analysis Report Template

The lead synthesizes all analysis results into a Korean report using this template (Step 5 → rendered in Step 7). The report is the **required base artifact** — always generated, the single source-of-truth for all findings (inline copy and feedback artifacts reference `→ 보고서 §발견사항 A-NN`).

## Finding canonical schema (single handoff contract)

Analysts produce the UPSTREAM block; the lead appends DOWNSTREAM fields in Steps 5–6. All 3 artifacts render from this object.

```
Finding {
  # ── UPSTREAM (analyst-produced) ──
  id:                 "A-NN"          # monotonic, attribute-independent (stable across severity re-eval)
  title:              string          # short headline
  severity:           critical | major | minor
  category:           <taxonomy tag>  # includes doc-code-gap
  doc_location:       "§x.y \"heading\""
  code_citations:     [ "path:line", ... ]   # array; [] when grounding OFF / no code ref
  evidence:           string          # why it matters / why this severity
  suggested_direction:string          # proposed direction (NOT a forced fix)
  analyst_role:       string

  # ── DOWNSTREAM (lead-set ONLY; analysts never set these) ──
  foundational:       bool            # Step 5 synthesis — on critical only; 보류 vs 재설계
  walkthrough_status: confirmed | excluded | amended | 미검토   # Step 6 (미검토 = abort)
  amendment_note?:    string          # Step 6 — only when status == amended
}
```

`id = A-NN` is monotonic and **attribute-independent** — it stays stable even if severity is re-evaluated, so every artifact's §ref / callout / feedback item stays aligned.

## Severity system (3 levels)

| Level | Icon | Meaning |
|-------|------|---------|
| critical | 🔴 | As written, causes system failure / unsafety / unmaintainability, OR invalidates a core premise |
| major | 🟠 | Serious gap/risk/cost recommended to resolve before adoption |
| minor | 🟡 | Improvement, clarification, small gap |

**`[foundational]` flag**: on a `critical` finding when it topples the document's *core approach* (no local fix). Assigned by the lead in Step 5 synthesis. The single axis that splits 보류 vs 재설계.

**premise-contradiction severity floor** (doc-code-gap, monotone 3-step):
- 주변부 모순 → impact-based (minor allowed)
- 리팩토링 *전제* 접촉 → **major floor** (minor forbidden)
- 핵심 전제·접근 *무효화* → **critical + `[foundational]`** → 재설계

Floor and flag are two thresholds on the same axis (premise proximity); both applied in Step 5 ("higher severity wins").

## Category tags

`architecture` · `feasibility` · `impl-cost` · `migration-safety` · `completeness` · `consistency` · `alternatives` · `doc-code-gap` · `scalability` · `security-design` · `data-integrity` · `api-contract`.

**`doc-code-gap`** (한글 라벨 "문서-코드 불일치") = document-vs-code mismatch. 3 sub-modes:
- **직접 모순**: doc claims X, code shows not-X.
- **오독**: doc misreads the existing code/behavior.
- **stale 가정**: doc's premise was true once but the code has since changed.

doc-code-gap findings cite **both sides**: the doc claim (`§anchor`) + the actual code (`path:line`); multiple code locations go in `code_citations[]`.

## Verdict ladder (replaces merge recommendation)

| Condition | Verdict |
|-----------|---------|
| critical == 0 ∧ major == 0 | **채택 권고** |
| critical == 0 ∧ major ≥ 1 | **조건부 채택** (나열된 major 선해소) |
| critical ≥ 1 ∧ no foundational | **보류** (해당 부분 재작업 후 재평가) |
| foundational critical ≥ 1 | **재설계 권고** (핵심 전제 불건전) |

Flag-based, not count-threshold: for a third-party design, count thresholds are arbitrary; the real question is whether a critical is locally fixable (보류) or premise-breaking (재설계), which `foundational` captures and audits.

## Render rule

Render only `confirmed` / `amended` findings into the finding sections. `excluded` appears ONLY in "철회된 항목" (transparent). `amended` shows its `amendment_note` with a `사용자 수정` flag. `미검토` (abort) is included with its flag. Empty severity sections are skipped.

## Document structure

File: `docs/analysis/<slug>.md` (create `docs/analysis/` with `mkdir -p` if absent).

```markdown
# 설계 문서 분석 보고서

## 개요

- **분석 대상**: `<design-doc-path>` — [문서 제목]
- **분석 날짜**: YYYY-MM-DD
- **분석 모드**: 코드 grounding (CODE_ROOT: `<absolute path>`) / 문서 단독
- **분석 범위/커버리지**: [전체 / 섹션 범위; 미분석 영역 요약]
- **분석 팀 구성**: [역할(렌즈) (모델): 담당 범위 …]
- **종합 권고 (verdict)**: 채택 권고 / 조건부 채택 / 보류 / 재설계 권고
- **발견 요약**: 🔴 critical N건 (foundational M건) | 🟠 major N건 | 🟡 minor N건

---

## 종합 권고

[verdict + 1-paragraph rationale. foundational critical이 있으면 재설계 사유를 명시.]

## 핵심 요약

[3-5 문장: 설계의 전반적 건전성, 가장 중요한 발견, 채택 가능성.]

## 방법론

[단일 패스 다관점 팀 분석; 분석 모드; 렌즈별 커버리지.]

---

## 발견 사항

### 🔴 critical ← skip section if none

- **[A-NN · category]** <title> — analyst_role  `[foundational]`(해당 시)
    - **문서 위치**: §x.y "heading"
    - **코드 인용**: `path:line` (grounded; doc-code-gap은 문서 주장 §anchor + 실제 코드 path:line 양측)
    - **근거**: evidence
    - 💡 제안 방향: suggested_direction
    - (amended 시) ✏️ **사용자 수정**: amendment_note

### 🟠 major ← skip if none
…(동일 블록 구조)

### 🟡 minor ← skip if none
…

---

## 문서-코드 불일치 ← grounding 전용; doc-only 모드에서는 섹션 자체 생략

[doc-code-gap 발견을 sub-mode(직접 모순/오독/stale 가정)별로 묶어 양측 인용과 함께.]

## 대안 평가 요약

[문서가 검토한/누락한 대안, 선택 근거 평가.]

## 긍정적 평가

[설계의 건전한 선택 — analyst `[POSITIVE]` 종합.]

## 미분석 영역

[의도적으로 분석하지 않은 섹션/관점 — blind spot 투명 고지. 워크스루 중단 시 `미검토` 발견도 여기 또는 해당 severity 섹션에 플래그와 함께.]

## 분석가 간 이견

[severity 이견, 양측 근거, 최종 판정.]

---

## 개정 이력

[Step 8 후속에서 변경 발생 시. 초기 생성 시 비움.]

## 철회된 항목

[워크스루에서 `무효(제외)` 처분된 발견 — 투명 기록. 초기엔 비움.]
- ~~[A-NN 원 발견]~~ — 제외 사유: [사용자 제공 맥락]
```

## File naming

- Report: `docs/analysis/<slug>.md`
- Inline copy: `docs/analysis/<slug>.annotated.md` (see `03-inline-callout-spec.md`)
- Feedback: `docs/analysis/<slug>.feedback.md` (see `04-feedback-template.md`)

`<slug>` derives from the source document filename (e.g. `refactoring.md` → `refactoring`).
