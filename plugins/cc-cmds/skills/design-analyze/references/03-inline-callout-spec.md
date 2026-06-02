# Inline Annotated Copy — Render Spec

Renders `docs/analysis/<slug>.annotated.md`: a **byte-for-byte copy** of the source document with analysis callouts inserted. The source document and its repo are NEVER touched (CFI-1) — callouts live only on this copy under cwd `docs/analysis/`.

## Procedure

1. **Byte-copy the source** into `docs/analysis/<slug>.annotated.md`:
   ```bash
   mkdir -p docs/analysis
   cp "<design-doc-path>" "docs/analysis/<slug>.annotated.md"
   ```
   (The original byte content is preserved exactly; only the copy is edited afterward.)
2. **Prepend a top banner** recording provenance and mode:
   ```markdown
   > 📋 **분석 주석 사본** — 원본: `<design-doc-path>`
   > 분석 모드: 코드 grounding (CODE_ROOT: `<abs path>`) / 문서 단독
   > 본 파일은 원본의 사본입니다. 콜아웃은 사본에만 추가되며 원본은 수정되지 않았습니다.
   > 전체 발견·근거는 보고서(`<slug>.md`) 참조.

   ---
   ```
3. **Insert a blockquote callout immediately after the relevant block** (the heading/paragraph the finding's `doc_location` points to), for each `confirmed` / `amended` finding:
   ```markdown
   > 🟠 **[A-03 · major · 문서-코드 불일치]** <짧은 요지> → 보고서 §발견사항 A-03
   ```
   - Icon matches severity: 🔴 critical / 🟠 major / 🟡 minor.
   - The bracket carries `[A-NN · <severity> · <한글 카테고리 라벨>]`.
   - Append `[foundational]` inside the bracket when set.
   - The trailing `→ 보고서 §발견사항 A-NN` keeps the copy aligned to the report's single source-of-truth (A-NN is attribute-stable).
   - For `amended` findings, append ` (사용자 수정)`.

## Render rule

- Only `confirmed` / `amended` findings get callouts.
- `excluded` findings are NOT annotated here (they appear only in the report's "철회된 항목").
- `미검토` (abort) findings: include the callout with a `미검토` marker, e.g. `> ⏸️ **[A-07 · 미검토 · …]** …(사용자 조기 종료로 미검토) → 보고서 …`.
- In doc-only mode, callouts carry no `path:line`; doc-code-gap callouts are absent (suppressed).
- Multiple findings on the same block stack as consecutive blockquote lines in A-NN order.
