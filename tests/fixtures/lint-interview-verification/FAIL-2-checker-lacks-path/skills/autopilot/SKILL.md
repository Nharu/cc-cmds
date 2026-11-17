# autopilot (fixture copy — only the lines the lint reads)

**At every Act 1 boundary the order is: append the trace line, then the text, then the call.** The token is the boundary's own: `요구사항 인터뷰` as 5j begins, `규약 읽기` right after 5j reads `verification.md`, `요구 확인` as the read-back is shown.

**5j — The requirements interview, when `design_required` is true.** Follow the shared convention.

- **The verification convention leaves a read trace.** Append `- <ISO8601> | 단계=규약 읽기 | 파일=_common/verification.md | sha256=<hex>` to the kickoff trace.
- **Exploration findings and verification preconditions** go in the record's `## 검증 선결`.

**5a — Termination point.** Free-form.
