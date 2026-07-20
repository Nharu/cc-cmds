# AskUserQuestion (Shared Construction Spec)

Single source of truth for constructing **valid** `AskUserQuestion` (AUQ) calls across skills. Scope is **constructing and reliably emitting valid calls** — how to shape a call the validator accepts. *Whether* and *when* to ask (e.g. one-issue-per-call policy, no-question entry points) stays in each skill; do not infer ask/skip policy from this file.

## Hard Schema Constraints

Violating any of these yields `InputValidationError`:

- `questions`: 1–4 entries. Each needs `question` (string), `header` (string, **≤12 codepoints**), `options` (2–4 entries), `multiSelect` (boolean) — all four required.
- Each option needs `label` (string) **and** `description` (string). `preview` is optional and **single-select only** (never on a `multiSelect: true` question).
- The tool auto-appends an "Other" free-text choice. Do NOT add a manual one.

## Two Axes: Questions vs Options

These are independent limits — do not conflate them:

- **Axis A — questions per call**: 1–4 questions in one `AskUserQuestion` call.
- **Axis B — options per question**: each question carries 2–4 options.

A call with one question of three options is valid; so is four questions each with two options. "Too many choices" almost always means Axis B (>4 options on one question), not Axis A.

**Keep calls lean, and fall back if they collapse.** Most AUQ rejections are _empty-input collapse_ — the call commits but emits no `questions` (`{}`), so the validator reports `questions` missing; re-emitting usually succeeds. As authoring hygiene, keep each call no larger than the decision needs: don't pad options to four, and don't batch independent questions into one call just to save a turn (≤4 genuinely interdependent is fine). A leaner argument is _plausibly_ less prone to the slip, though we don't have data that size causes it. On a collapse, re-emit the complete call. **Only if it still collapses after three or more re-emits** should you stop calling AskUserQuestion for that question and ask it as a numbered plain-text list for a free-text answer — nothing enforces this, but switching surfaces is the only way to break a repeat-collapse run.

## The Auto-Provided "Other"

The tool always renders an "Other" choice that lets the user type free text. Therefore **never** add a manual catch-all option such as `직접 지정`, `기타`, `직접 입력`, or `Other` — it duplicates the built-in channel and, when your real options already number four, pushes the question to 5 (Axis B violation). If you need a free-text escape hatch, it already exists; just omit the manual one.

## Header Sizing (incl. Korean)

The limit is **≤12 codepoints** (≈12 UTF-16 code units), not display columns. An NFC-composed Korean syllable is 1 codepoint, so `팀 토론 진행` = 7 (the spaces count). **Spaces and decorations like `← 추천` count too.** NFD/decomposed jamo render identically but count per-jamo (`한` = 3 in NFD) — a silent-overflow trap where a header looks ≤12 yet is rejected. So: author headers in NFC and stay conservatively ≤12 codepoints. Keep the header a **short category tag** (e.g. `UD`, `처리 방식`, `안전 한계`), not the full topic sentence — put the full meaning in `question`.

## preview, multiSelect & Recommendation Rules

- `preview` is single-select only. Use it for side-by-side artifacts (mockups, code snippets); omit it otherwise.
- `multiSelect: true` only when choices are genuinely non-exclusive.
- **Recommendation is a documented convention, not a schema field.** To mark a recommended option: place it at **position 1** and append a suffix to its `label`; put the rationale in that option's `description`, never in the label. Standardize the visual form as `← [에이전트 ]추천` while preserving provenance — lead/skill-originated recommendations use `← 추천`, agent-originated ones use `← 에이전트 추천`.

## Worked Examples

**Example #1 — options must be `{label, description}`, not bare strings.**

```
# INVALID — do not copy
options: ["승인", "거부 (현재 유지)"]          # bare strings: missing description
```

```
# VALID
options:
  - label: "승인"
    description: "에이전트 제안을 현재 스코프에 적용합니다."
  - label: "거부 (현재 유지)"
    description: "변경하지 않으며 이 항목은 다시 보고되지 않습니다."
```

**Example #2 — header overflow.**

```
# INVALID — do not copy
header: "외부 이터레이션 안전 한계 도달"        # 17 codepoints > 12
```

```
# VALID
header: "안전 한계"                            # 5 codepoints; full meaning lives in `question`
question: "외부 이터레이션 안전 한계(5회)에 도달했습니다. 계속 진행하시겠습니까?"
```

## Pre-call Checklist

Before every AUQ call, confirm:

1. 1–4 questions; each has `question`, `header`, `options`, `multiSelect`.
2. Every `header` ≤12 codepoints (NFC), spaces and `← 추천` included.
3. Every question has 2–4 options; each option has both `label` and `description`.
4. No manual `직접 지정`/`기타`/`직접 입력`/`Other` option.
5. `preview` (if any) only on single-select questions.
6. Recommended option (if any) at position 1 with the `← [에이전트 ]추천` suffix and rationale in `description`.

**Authoring rule**: every AUQ option menu written into skill or reference prose MUST present each option as a `label`+`description` object (no bare-label strings) and MUST NOT include a manual Other/기타/직접 지정 option — prose templates get copied verbatim into live calls, so a malformed template breeds a malformed call.
