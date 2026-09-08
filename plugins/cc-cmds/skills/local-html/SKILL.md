---
name: local-html
description: HTML 문서 발행 규약 — Artifact 가 아니라 이미지까지 인라인한 자기완결 로컬 HTML 파일로 저장하고, playwright 로 실제 렌더를 열어 폭·테마·줄바꿈을 시각 검증하고 고칠 것까지 없어질 때까지 고친다
when_to_use: HTML 문서·리포트를 새로 발행하거나 기존 것을 고칠 때
disable-model-invocation: false
usage: "(자동 호출 — 슬래시 커맨드 없음. HTML 문서를 만들기 직전과 만든 직후에 모델이 열어 그대로 따른다.)"
options: []
notes: |
    슬래시 커맨드 surface 가 없는 model-invoked 정책 스킬이다. 두 절은 한 쌍이다 — 파일을
    만드는 절만 지키고 시각 검증 절을 건너뛰면 이 규약을 지킨 것이 아니다. 브라우저 세션명과
    headless 규약은 `browser-policy` 를 따른다.
---

# local-html

## 1. Publish as a local file, never as an Artifact

- Publish an HTML document as a **local HTML file**, not as an Artifact. **Do NOT publish it as an Artifact** — the only exception is when the user explicitly asks for one.
- Save it in the directory where the project's existing HTML documents live (usually `docs/`), following the same naming convention as those.
- Inline images as data URIs so the document is **self-contained and opens from that single file alone**.
- Include `<!doctype html>`, `<meta charset="utf-8">`, and a viewport meta tag.

## 2. Visual verification is mandatory, and so is fixing what it finds

**After making the file, open the actual render with playwright, verify it
visually, and fix every problem you find.** Do NOT finish by saving the file
and reporting its path: HTML can be correct at the source and still wrong on
screen, and that difference does not surface unless you open it.

Verification covers at minimum:

- Open at **desktop, tablet, and mobile widths** and check that nothing breaks the layout or fails to fill the width.
- Every image loads and none is cropped.
- **Both light and dark themes** are readable.
- Korean line breaking does not split mid-word (`word-break: keep-all`).
- No horizontal scrollbar appears.

When you find a problem, fix it and open it again to confirm. **Repeat until
there is nothing left to fix.**
