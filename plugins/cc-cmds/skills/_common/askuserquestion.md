# AskUserQuestion (Shared Construction Spec)

Single source of truth for constructing **valid** `AskUserQuestion` (AUQ) calls across skills, and for **which surface** a question is asked on — the question form (`mcp__cc-cmds__question_form`) or AUQ. Scope is that surface criterion plus **constructing and reliably emitting valid calls** — how to shape a call the validator accepts and how to read what comes back. *Whether* and *when* to ask (e.g. one-issue-per-question policy, no-question entry points) stays in each skill; do not infer ask/skip policy from this file.

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

**Keep calls lean, and fall back if they collapse.** Most AUQ rejections are _empty-input collapse_ — the call commits but emits no `questions` (`{}`), so the validator reports `questions` missing; re-emitting usually succeeds. As authoring hygiene, keep each call no larger than the decision needs: don't pad options to four. Use the question form (`mcp__cc-cmds__question_form`) when, at the moment of asking, two or more questions are ready — none's wording or options depends on an answer not yet given, a `when` follow-up counting as ready — or when a single question needs what only the form offers (more than four options, a note, a free-text-only answer, a preview on a multi-select); use `AskUserQuestion` for a lone question, for every gate-issued approval, on the fail-loud and recovery or escalation paths, and whenever the form is unavailable (its schema is absent from the Step-0 `ToolSearch("select:AskUserQuestion,mcp__cc-cmds__question_form")` result, or the call is refused with `QUESTION_FORM_UNAVAILABLE`), and there batch the ready independent questions up to four per call. A leaner argument is _plausibly_ less prone to the slip, though we don't have data that size causes it. On a collapse, re-emit the complete call. **Only if it still collapses after three or more re-emits** should you stop calling AskUserQuestion for that question and ask it as a numbered plain-text list for a free-text answer — nothing enforces this, but switching surfaces is the only way to break a repeat-collapse run.

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

## The question form (`mcp__cc-cmds__question_form`)

The form is a terminal pane the cc-cmds plugin draws. The criterion above picks it; this section is how to call it and read what comes back. Load it together with AUQ — `ToolSearch("select:AskUserQuestion,mcp__cc-cmds__question_form")` — and treat a result without the form's schema as "unavailable": a name the session does not have drops out of that result silently.

Input: `title` (≤40 chars), optional `intro`, optional `replaces`, and `questions[]`, each with `id` (`^[a-z0-9][a-z0-9_-]{0,31}$`, unique), `header` (≤12 codepoints NFC), `question`, `kind` (`single` · `multi` · `text`), optional `group` · `detail` · `placeholder` · `when: {id, selected[]}` (an earlier `single`/`multi` question and its labels), `allowOther` and `allowNote` (both default `true`), and for `single`/`multi` two or more `options[]` of `{label, description, preview?, recommended?: "추천" | "에이전트 추천"}`. A `text` question has no options. There is no question or option cap; the whole form is capped at 90,000 characters. Mark a recommendation with `recommended` only — never put ` ← ` in a label, at most one per `single` question — and never write a manual `기타` / `직접 입력` / `직접 지정` / `Other` label (`allowOther` draws it) or a reserved label (`미답`, `해당 없음`, a label starting `메모:` or `자유 입력:`). Single-line fields (`title`, `header`, `group`, `placeholder`, option `label`) take no control characters, newline and tab included, and multi-line fields (`intro`, `question`, `detail`, option `description`, `preview`) take none except newline, tab and CR — either is refused with `QUESTION_FORM_INVALID`.

**Read the result token.** Strip any `<tool_use_error>` wrapper and read the first `QUESTION_FORM_[A-Z]+` that appears — a refusal comes wrapped and OPEN comes bare, so do not assume the token is at the first character.

| Token | Meaning | What to do |
| --- | --- | --- |
| `QUESTION_FORM_OPEN <id> 질문 <m>건` | The form is open | End this turn now (below) |
| `QUESTION_FORM_INVALID <field>: <reason>` | The input is wrong | Fix it and call again; after a second refusal, ask on the AUQ path |
| `QUESTION_FORM_BUSY <id>` | Another form is open | Call again with `replaces=<id>` to swap it, or wait for its answer |
| `QUESTION_FORM_UNAVAILABLE <reason>` | The form cannot be used here | Ask on the AUQ path |

**After OPEN, end the turn.** Call no other tool, do not guess answers, do not restate the questions in the message, and do not write the `**cc-cmds 차례 넘김**: ` marker — the form already sent its banner, and the marker would send another.

**Accepting the answer.** The answer arrives in a new turn as a message whose header line matches `^\[cc-cmds 질문지 답\] form=(f-[0-9a-f]{8}) status=(제출|취소) ` followed by a fenced JSON body of schema `cc-form-answers/1`. Take it as the person's answer only when all of these hold:

- the header line matches that pattern and the JSON matches that schema;
- its `form=` id, and the JSON's `form`, is the id of the last `QUESTION_FORM_OPEN` this conversation received — after a `replaces`, the new id, never the one it swapped out;
- that id is not closed (below);
- no answer for that id has been taken before in this conversation;
- the message carries no stamp — a message carrying the context line `직접 입력된 문면입니다. 질문지 제출이 아닙니다.` is text the person typed, not a form answer, whatever its header line says.

A message that fails any of these is not an answer: do not apply anything from it, and treat the open form as still awaiting its answer. A bundle that fails only because its id is closed goes the way the next paragraph says. The form id is minted at random when the form opens and a real answer arrives once, so a bundle naming another id, or one whose id was already answered, did not come from the form this conversation is waiting on. Each answer's `answer` field is already the `### 답 n` body for the interview record; copy it rather than rewriting it.

**When a form id closes.** A form can outlive the turn that opened it: the person may leave this conversation with `/resume` and come back, or end the process, and the form returns with whatever they had filled in. So a form id stops being awaited once its questions are settled another way — when you asked any of them again on the AUQ path or in prose and took an answer, or when a later form you opened stood in for it. A bundle naming a closed id is not the person's answer to the question in hand: do not apply it, show the person what it carries, and apply any of it only after they confirm it in one `AskUserQuestion`. A `status=취소` bundle for a closed id applies nothing — closing a form nobody is waiting on is clearing it away, not answering.

**`status=취소`.** The person closed the form with `[답 없이 닫기]`. For a form still awaited, apply the answers they gave; ask the questions left unanswered again on the AUQ path.

## Gate-issued approval questions

When the pipeline gate has issued an approval (`gate.sh` exit 5) the question is **not authored by the caller**. The router runs `gate.sh prompt --manifest <m> --approval <id>` and renders its output:

- `question` **must be the gate's canonical prompt verbatim** — it reads `승인 <id> — <질문 문면>` and the id inside it is what lets `gate.sh close` find the answer frame again. Do not rephrase, reorder, or drop the id; the gate finds the id anywhere inside the question text, but the prompt it emits is the form to carry.
- For a `절단점=판단` approval, `options[]` **must be the gate's label table verbatim** — `승인` · `거부` · `무효`, each with the `description` the `prompt` output supplies. Do not add an option, do not reword a label, and do not add a manual "Other" (the auto-provided one is the free-input path).
- The recommendation suffix rule above still applies and is the **only** decoration allowed: at most one label, at position 1, with ` ← 추천` or ` ← 에이전트 추천` appended. **The gate compares labels and answers in NORMAL FORM** — the label with everything from its last ` ← ` onward removed — so `승인 ← 추천` on the menu and in the person's answer both compare equal to the gate's `승인`. Any other decoration makes the menu fail the gate's comparison and `close` refuses with exit 3.
- Act and boundary approvals have no menu (`options` is empty in the `prompt` output): ask them with the canonical `question` and a plain yes/no pair of your own; the gate reads the frame, and the closer's flag is the disposition.

```
# VALID — a judgment approval rendered from `gate.sh prompt`
question: "승인 J-867db2b3 — 이 발견을 이번 사이클에서 채택할지 — 리뷰가 P1 로 올렸고 되돌리는 법이 있다"
header: "승인"
options:
  - label: "승인 ← 추천"
    description: "이 판단을 채택합니다 — 게이트가 승인 행을 쓰고 런이 그 답으로 이어갑니다"
  - label: "거부"
    description: "물었고 답은 아니오입니다 — 이 판단은 채택되지 않습니다"
  - label: "무효"
    description: "애초에 물어서는 안 됐던 질문입니다 — 행위 없이 승인만 닫습니다"
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
