# Review Report Template

The lead synthesizes all review results into a Korean document using this template (Step 5).

## Severity System (P0~P3)

| Level | Icon | Meaning | Merge Impact |
|-------|------|---------|--------------|
| P0 | 🔴 | Real harm in normal use, and one of (a)–(e) below | Merge blocked |
| P1 | 🟠 | Partial harm that surfaces on its own and can be undone | Merge block recommended |
| P2 | 🟡 | No real harm in normal use, or a finding the lowering table below moves here — follow-up issue recommended | Mergeable |
| P3 | 🟢 | Improvement suggestion (includes nitpick) | Optional |

**Judgment criterion.** This is the only place the criterion is written. The unattended review and the interactive `/review` grade against the same text, and item 10 of `01-reviewer-context-package.md` maps the reviewers' five internal levels onto it without restating it. The question it asks of every finding is: **if this merges, does normal use suffer real harm?**

**P0 — merging causes real harm in normal use, and the defect is one of the following.**

- (a) Data loss or corruption, monetary loss, or leakage of a secret or credential.
- (b) A permission or security defect that a realistic actor can use, or that holds under a standard, a regulation, or an observed spelling. A bypass of review-before-merge (`선리뷰후머지`), a bypass of pre-authorization (`사전 인가`), and a defect that overturns a person's answer all belong here.
- (c) A silently wrong result, or a safety check that is silently switched off.
- (d) On the delivery path, a normal input halts every run, stage, or dispatch of one kind. The delivery path is CI and deployment in a product repository, and the autopilot pipeline in cc-cmds.
- (e) A test or script that actually performs a destructive, external, or credential-bearing act.

**P1 — the harm is partial, surfaces on its own, and can be undone.**

**Remainder — real harm in normal use that is not P0 and that the lowering table below does not move is P1.** Failing one of the three P1 conditions above does not drop it to P2. A change that fails on every invocation of an interactive-only skill, and a silent cost or throughput regression, belong here.

**Lowered to P2 — the finding stays in the report; lowering is never dropping.** Each row's exclusion takes precedence over the lowering: when the exclusion applies, the finding keeps its level.

| Lowering reason | Exclusion — when it applies, do not lower |
|---|---|
| A gate bypass that holds only with an argv a cooperating model would never type | It holds under a standard, a regulation, or an observed spelling. A bypass of review-before-merge, of pre-authorization, or of the park on a destructive act is never lowered, whatever the spelling |
| A test gap (a mutation survives, but there is no behaviour defect) | A behaviour defect comes with it. The test actually performs an external, destructive, or credential-bearing act |
| A wording mismatch in a document or comment. Polishing a sentence whose facts are right is not this row: it is the `문서표현` field (item 14 of `01-reviewer-context-package.md`), and by default it is not a finding at all | Applies only to text people read (`docs/`, README, CHANGELOG, comments). SKILL.md, `_common`, prompts, and schemas are instructions a model executes, so a mismatch there is judged as a behaviour defect |
| An extreme condition with no path to occur in practice | Lower only when the report states why it is unreachable. If an unrefuted argument that it is reachable stands, the level is kept |
| A pre-existing defect this PR did not create (`(기존 결함)`, judged against the base sha) | This diff makes that code reachable or makes it bear load. A defect inherited from an earlier cycle. A regression introduced by a fix commit is not pre-existing |

**Out-of-scope observations take no level.** An observation of a field not open for the review (item 14's Field scope of `01-reviewer-context-package.md`) goes to `## 범위 밖 관찰` and enters neither the `발견 요약` line, nor the merge recommendation, nor any `💬` paste-ready comment.

The internal-level mapping below is subordinate to this criterion: a reviewer assigns the internal level that corresponds to the P level the criterion gives, never the other way round.

Internal 5-level → document 4-level mapping:
- critical → P0
- high → P1
- medium → P2
- low + nitpick → P3

**Skip P0 section if empty** (applies to most PRs). Only show when applicable.
**Skip "리뷰어 간 이견 사항" and "미검토 영역" sections if not applicable.**

## Merge Recommendation Rules

- **P0 ≥ 1** → "머지 불가 (즉시 수정 필요)"
- **P0 = 0, 차단 P1 = 0, 이월 가능 P1 ≥ 1** → "이월 후 머지 가능 (이월 가능 항목을 후속 이슈로 넘긴 뒤 머지)"
- **P1 ≥ 1, P0 = 0** (위 줄에 해당하지 않을 때) → "머지 전 수정 권장"
- **P0 + P1 = 0** → "머지 가능"

무인 파이프라인은 「이월 후 머지 가능」 줄을 리드 수정 뒤의 확인 리뷰에서만 적용하고, 이슈 등록과 머지 판정은 게이트가 한다. 대화형 리뷰에서는 사람이 정한다.

The interactive `/review` and `/review-lite` take no `--slice` and register no issue: they write the classification below, and the person decides whether the carryable items go to follow-up issues before merging.

### P1 분류 기준

P1 은 아래 세 기준을 모두 만족할 때만 `이월 가능`이고, 하나라도 어긋나거나 리뷰어 사이 판정이 갈리면 `차단`이다. 갈린 경우는 `## 리뷰어 간 이견 사항`에 두 근거를 남긴다. 이 기준은 P0·P1 을 가르는 심각도 기준을 바꾸지 않으며, 이미 P1 으로 판정된 항목을 나눌 뿐이다.

1. 이 변경을 되돌리거나 다시 설계하지 않고, 뒤따르는 별도 PR 하나로 고칠 수 있다.
2. 이 슬라이스가 맡은 요구를 거짓으로 만들지 않는다. 설계 문서가 있으면 그 문서가 이 슬라이스에 배정한 항목이 기준이다.
3. 머지된 채 고쳐지지 않은 동안 영속 상태·원장 행·외부 상태를 틀리게 남기지 않고, 게이트·룰·시험의 검사를 약하게 만들지 않는다.

## P1 Classification Grammar

All three review skills write this grammar. The gate parses it in the unattended pipeline, so the spellings below are byte-fixed. `N` is a decimal number with no leading zero.

### Summary lines

Directly after the `발견 요약` line of the overview block, in this order:

```
- **발견 요약**: 🔴 P0 N건 | 🟠 P1 N건 | 🟡 P2 N건 | 🟢 P3 N건
- **P1 분류**: 차단 N건 | 이월 가능 N건
- **다른 슬라이스 몫**: N건 (집계 제외)
```

- The `발견 요약` line is byte-for-byte unchanged. Its P1, P2 and P3 counts exclude other-slice items; its P0 count includes them.
- `P1 분류` is always present, in every skill. 차단 + 이월 가능 equals the `발견 요약` P1. With no P1 the line reads `- **P1 분류**: 차단 0건 | 이월 가능 0건`.
- A recovery report whose summary key is `발견 요약(부분 복구)` writes exactly `- **P1 분류**: 차단 미상 | 이월 가능 미상`.
- The gate parses the line with the regex below. A line that does not match, or no line, reads as `분류 미상`, and the report is ineligible for carryover.

```
^- \*\*P1 분류\*\*: 차단 (0|[1-9][0-9]*)건 \| 이월 가능 (0|[1-9][0-9]*)건$
```

- The `다른 슬라이스 몫` line is present only when the review applied a slice scope (`review-unattended --slice <id>`). Its absence reads as 0.
- The slice overview line sits in the overview block directly above `발견 요약`, in exactly one of these two shapes:

```
- **슬라이스 범위**: 슬라이스 <id> (다른 슬라이스 <k>개)
- **슬라이스 범위**: 적용 안 됨 — <인자 없음|설계 문서 없음|슬라이싱 절 없음|슬라이스 <id> 블록 없음>
```

### P1 disposition tag and sub-bullets — inside `## 🟠 P1 (머지 전 수정 권장)` only

The first line of an item carries the tag one space after the category tag, without backticks:

```
- **[category]** **[차단]** `파일:라인` 이슈 설명 — 리뷰어
- **[category]** **[이월 가능]** `파일:라인` 이슈 설명 — 리뷰어
```

**A new report writes every P0 and P1 item in this one form**: a column-0 bullet starting `- **[category]**`, never a `### ` head. A P0 item is the same line without a disposition tag: ``- **[category]** `파일:라인` 이슈 설명 — 리뷰어``. The head form is a rule for reading reports written before this one; the gate's `report-check` flags a `### ` line inside the P0 or P1 section as `비불릿`. In such an older report, an item written with a `### P1-n …` head carries exactly one of the same two tokens on that head line, without backticks, and that head line is the item's first line.

**Anchor.** The first backtick token of every P0 and P1 item line is `파일:라인` — a path with no space or backtick, a colon, and a line number or range (``^[^ `]+:[0-9]+(-[0-9]+)?$``); a `[CI-CONFIRMED]` token before it is skipped. A finding about something that is missing anchors at the line its fix would touch. The finding fingerprint and the readers that tell one finding from another read this token, and `report-check` flags an item line without it as `앵커 없음`.

The sub-bullets come after the existing `근거` / `💡 수정 제안` / `📎` lines and before the blank line that precedes `💬`. The one exception is the `**좌석**` line, which is the item's first sub-bullet, above `근거` (its rule sits beside the `모델 티어` block description below). Every P1 item has:

```
    - **분류 근거**: <한 줄 — 이월 가능이면 세 기준을 모두 만족하는 이유, 차단이면 어긋난 기준 번호와 이유>
```

A `**[이월 가능]**` item then has, in this order:

```
    - **이월 제목**: <한 줄 — 이슈 제목 끝에 그대로 쓰인다>
    - **이월 본문**:
      <문제 상황 한 줄>
      <위치: 저장소 경로:줄>
      <근거와 영향>
```

The rules the gate relies on:

- **Section.** The P1 section runs from the line starting `## 🟠 P1` to the next line starting `## ` (two hashes, a space). Neither a `### ` line nor any line inside a head-form item ends the section.
- **Tag line.** A line inside the P1 section that contains `**[차단]**` or `**[이월 가능]**`. Every P1 item has exactly one tag line and it is its first line. A new report's tag line starts with `- `; a reader also takes a line starting `### `, the head form of older reports. Every tag line contains one token exactly once and never contains both tokens. The tokens appear nowhere else in the section (`근거`, `💬`). Tags outside the P1 section are ignored.
- **What is counted.** The number of tag lines containing `**[차단]**` and the number containing `**[이월 가능]**`, counted the same way in both item forms. If any tag line breaks a rule above, the report is `분류 미상` and ineligible for carryover. A parser that counts every line carrying a token and one that counts only `- ` / `### ` tag lines therefore reach the same verdict on every report.
- **Item extent.** An item runs from its tag line to the line before the next tag line, or to the end of the section. `분류 근거`, `이월 제목` and `이월 본문` belong to the item whose extent contains them. A column-0 `- ` line and a `### ` line without a token do not end the extent.
- **Same indentation in both forms.** `분류 근거`, `이월 제목` and `이월 본문` are written exactly as fenced above, with four spaces before `- `. Every `이월 본문` body line starts with exactly six spaces. This holds when the item is a head and its other lines are column-0 bullets. The gate matches `    - **이월 제목**: ` and `    - **이월 본문**:` at that indentation; a line written otherwise is not one.
- **No backticks.** The finding fingerprint takes the first backtick token as the finding identifier, so a backticked tag would change every fingerprint.
- **`이월 본문` boundary.** Body lines all start with exactly six spaces. The body ends at the first line that does not and holds no blank line. Neither body lines nor disposition sub-bullets start at column 0, so the fingerprint's `- ` line matcher reads none of them in either item form.
- **`이월 본문` content.** The problem, its location, the evidence and the impact. Forbidden: a fix suggestion; a design-document path, heading, section number or document-local label; a report path; the substring `docs/`; a credential value.
- **Gate check on the body.** Each `**[이월 가능]**` item extent has exactly one non-empty `이월 제목` line, exactly one `이월 본문` line followed by at least one body line, and no `docs/` in the body. The `이월 제목` of the `**[이월 가능]**` items of one report differ byte-for-byte from each other — issue reuse looks an issue up by its title, so two items with one title would fold into one issue URL and the carryover record would refuse the duplicate. The rest is the reviewer contract.
- **Who takes a tag.** P0, P2 and P3 items carry no disposition tag.

### Other-slice section

Placed after the `## 🟢 P3 (개선 제안)` section and before the `---` that precedes `## 리뷰어 간 이견 사항`, and present only when it has at least one item:

```
## 다른 슬라이스 몫 (집계 제외)

- **[category]** **[P2]** `파일:라인` 이슈 설명 — 리뷰어
    - **배정**: 슬라이스 <id> — 「<설계 문서의 그 슬라이스 블록에서 이 발견이 속하는 줄의 축자 문면>」
    - **근거**: <왜 이 슬라이스가 아니라 그 슬라이스의 몫인가>
```

- The severity token is exactly one of `**[P1]**`, `**[P2]**`, `**[P3]**` — never P0.
- An other-slice P0 stays in `## 🔴 P0 (즉시 수정 필수)` and is counted. It carries the same `    - **배정**: 슬라이스 <id> — 「…」` sub-bullet as information only.
- **A finding is another slice's share only when all three hold:** its remedy is work the design assigns to a declared slice other than the current one; that slice has not merged; and it is not a defect in a line this slice changed — a defect in a line this slice changed is never another slice's share.
- The head starts `## 다`, not `## 🔴 P0` or `## 🟠 P1`, so the fingerprint and every P0/P1 section reader skip this section unchanged.
- When the pipeline records the cycle, the gate checks that every `**배정**: 슬라이스 <id>` names a segment of this run other than the current one that has not merged, and that this section's item count equals the `다른 슬라이스 몫` line. This is the one place a review drops a P1 from the count, which is why it is checked at record time. A run without slicing has no such section.

### Out-of-scope observations section

Placed after the `## 🟢 P3 (개선 제안)` section and the `## 다른 슬라이스 몫 (집계 제외)` section, and before the `---` that precedes `## 리뷰어 간 이견 사항`. Present only when there is at least one observation:

```
## 범위 밖 관찰

- [요구] `파일:라인` <관찰 한 줄> — <리뷰어>
- [문서표현] `파일:라인` <관찰 한 줄> — <리뷰어>
```

- Each line is a reviewer's `[범위 밖:<분야>]` line (item 15 of `01-reviewer-context-package.md`) carried over; the same observation at the same `파일:라인` from several reviewers is one line with the reviewers side by side (`— 리뷰어 A, 리뷰어 B`).
- The marker is the plain `[요구]` or `[문서표현]`, never a bold category tag. The section holds no line shaped like `발견 요약`, no line starting `- **[`, and no bold marker such as `**결함 수준**:`: the gate's report readers count only `- **[` lines inside the P0 and P1 sections as items, but read a bold marker line as the first match in the whole file whatever section it sits in, so a bold marker here would be read as the report's own.
- The lines carry no level, no rationale and no fix suggestion, and no `💬` block follows them.

## Category Tags

Findings use `[category]` tags from: `security`, `performance`, `code-quality`, `logic`, `error-handling`, `type-safety`, `testing`, `api-contract`, `concurrency`, `data-integrity`, `design-conformance`.

`design-conformance` is available **only** when a design document was supplied to the review (context-package item 17). Without that document there is no baseline to compare against, so the tag is unusable rather than merely unused.

Opening a field adds no tag. A finding of an open `요구` field takes `logic`, or `design-conformance` when a spec document was supplied; a finding of an open `문서표현` field takes `code-quality`. An out-of-scope observation takes no category tag at all, only its `[요구]` or `[문서표현]` marker (`### Out-of-scope observations section`).

When CI has detected failures that a reviewer confirms, add `[CI-CONFIRMED]` tag to distinguish from independent findings. The unattended review leaves out of this instruction every check that the manifest's `라벨 인정` row names.

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
- **Title = prose only** (no `파일:라인`); **location (`파일:라인`) goes in the first mention inside `[근거]`** → self-contained for both inline comments (line implicit) and general PR comments (path needed). A `design-conformance` finding additionally names the **design-document section** it diverges from, in that same `[근거]` block and alongside the source location — its claim is a mismatch between two places, so one anchor cannot state it. Cite the section by heading and identifier, never by line number: the design document is user-local and its line numbers do not survive to the reader.
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

## Fix Record

Written only by `review-unattended --lead-fix`, at the path that skill's `## The fix record and its path` defines, never inside a report. One line per P0 and P1 item of the cap report, every item, nothing else on the line:

```
- P0-1: 수정됨
- P1-2: 수정 불가 — <사유 한 문장>
```

`P0-<k>` / `P1-<k>` numbers the cap report's items from 1 down each severity section, inherited items included, in report order. The value is exactly `수정됨` or `수정 불가 — ` followed by a non-empty reason; the driver counts lines of this shape against the cap report's P0 + P1. `수정됨` is a claim the re-check judges, never a verdict.

## Cap Cycle Re-check

Written only by `review-unattended --recheck`. After `핵심 요약` and before the P0 section — and before `## 기준 사이클 재판정` when that section is present too — one entry per P0 and P1 item of the cap report, none omitted:

```
## 상한 사이클 재확인

- **[category]** `파일:라인` (상한 사이클 N, P1-2) — 원 서술 한 문장
    - **수정 기록**: 수정됨 | 수정 불가 — <사유> | 재구현 | 없음
    - **판정**: 해결됨 | 미해결
    - **근거**: <수정 위치와 내용, 또는 결함이 남아 있음을 확인한 근거>
```

`수정 기록` copies the item's fix record value, or `없음` when the record or its line is missing — an item with no line is judged from the code like any other. A re-check after a re-implementation has no fix record — the implementation stage writes none — and every entry there reads `재구현`; the items are judged from the code the same way. The entries number exactly the cap report's P0 + P1. A verdict left unsettled after reassignment, or contested with no `## 자율 승인 기록` row settling it, is `미해결` with `**근거**: 이번 사이클에서 판정이 확정되지 않았습니다 (누락)` or `(충돌)`.

**One finding, one entry.** When the delta basis report is the cap report itself, an item here has no `## 기준 사이클 재판정` entry of its own; that section then holds only basis items that are not cap items, or its single `없음` line. A new finding that is the same defect as an unresolved cap item is folded into that item.

**Counting** — the `발견 요약` line's form is unchanged. An item judged `미해결` re-enters its severity section at its cap severity (or at an explicit re-grade under the higher-grade rule) carrying `(상한 사이클 N에서 상속, 재확인 미해결)`, and a P1 one carries its own `**[차단]**` or `**[이월 가능]**` tag like any P1. An item judged `해결됨` leaves the severity sections. Then:

```
P0 = 미해결 상한 P0 + 그 밖의 P0(기준 재판정·신규, 중복 제거 뒤)
P1 = 미해결 상한 P1 + 그 밖의 P1(기준 재판정·신규, 중복 제거 뒤)
```

### Defect level — `--recheck` reports only

A re-check classes every finding it leaves standing — every P0, and every `**[차단]**` P1 (every P1 when the `P1 분류` line reads `미상`) — by where its fix lies, because the gate sends a design-level remainder to a re-convergence instead of another lead fix. One summary line directly after the `P1 분류` line, and one sub-bullet under each such item:

```
- **결함 수준**: 설계 N건 | 구현 N건
```

```
    - **결함 수준**: 설계 — <구속 문면 중 바꿔야 하는 곳 한 문장>
    - **결함 수준**: 구현 — <코드만 고치면 되는 이유 한 문장>
```

`설계` means the fix needs the design document's binding text to change; `구현` means the code can be fixed within it. 설계 + 구현 equals the number of items classed, and the sub-bullets number the same. The gate parses the summary line exactly:

```
^- \*\*결함 수준\*\*: 설계 (0|[1-9][0-9]*)건 \| 구현 (0|[1-9][0-9]*)건$
```

A missing line, a line off this form, a sum that differs from the items classed, or sub-bullets that do not match is read as `미상` — no design-level item — so the segment goes round the cheaper lead fix and the `cycle` row is never refused for it. A review that is not a re-check writes neither line.

## Recovery report — the termination-predicate interlock

A recovery report is written by the recovery arm from a crashed stage's on-disk
leftovers, and it is **thin by construction** — unconverged, uncross-reviewed,
and cut off at the moment of death. Without this interlock the mechanism is
worse than not having it: a review that died at twenty minutes yields a
plausible-looking "clean review" and the run terminates on it.

**What the driver matches is the SHAPE of the findings-summary line.** Verbatim:

```text
^- \*\*발견 요약\*\*: 🔴 P0 [0-9]+건 \| 🟠 P1 [0-9]+건 \| 🟡 P2 [0-9]+건 \| 🟢 P3 [0-9]+건
```

The **values of the counts are never read**, and there is **no position
condition** — the driver greps the whole report file and the line matches
wherever it sits.

**The `P0 + P1 = 0` line of the Merge Recommendation Rules above is NOT the
suppression target.** The two lines are easy to conflate and conflating them
puts the suppression in the wrong place: an implementation that deletes only the
rubric line leaves the predicate passing, so a thin recovery report reads as
P0 and P1 zero and the run terminates on it — precisely the scenario this
interlock exists to prevent.

**The suppression target is the shape, not the position.** A recovery report in
which **any** role resolved to the `checkpoint` or `absent` tier — **or in which
every role resolved to `witness` but any of them did so at a round below the last
round the ledger block records** — **or in which the roster could not be obtained
at all** — **or in which any role's resolution round is
below the highest round at which that role left anything at all** — puts a line
of the shape above
**nowhere in the file**. Moving such a
line elsewhere does not suppress it; it still matches. In its place, emit a line
that names the tier and is deliberately built not to match:

```
- **발견 요약(부분 복구)**: 🔴 P0 미상 | 🟠 P1 미상 | 🟡 P2 미상 | 🟢 P3 미상 — 최저 계층 {checkpoint|absent|로스터 불가|라운드 미달}, 최저 라운드 {N|미상}
```

It breaks at two independent junctions — the key is `발견 요약(부분 복구)`, so
`^- \*\*발견 요약\*\*: 🔴` does not match it, and the count positions read `미상`,
so `[0-9]+건` does not match either. Either junction alone would do; both are
present so that a later edit to one of them cannot silently re-arm the line. The
trailing tier-and-round clause touches neither junction, so extending it is free.

**The third condition exists because the roster is what "every role" ranges
over.** A recovery that cannot read the roster cannot know which roles are
missing, so "every role resolved to `witness`" is vacuously satisfiable over
whatever set it happened to see — including the empty one. Suppressing on an
unobtainable roster is what keeps the interlock from passing on a set it never
established.

**The fourth condition catches a seat the ladder demoted.** A role that reached
a round, left there only a candidate the witness predicate refuses, and had
nothing else at that round descends to a lower round and resolves at it. Its
resolution round then sits below the round it actually reached, and that gap is
the evidence of non-convergence — the ledger's column cannot show it, because a
crash before the flip leaves that column low as well. The comparand for this
condition is per role and comes off the disk, not out of the ledger.

**The real consequence of the predicate failing is a park.** The driver folds
that result into its terminal classification, the class is not "정상 완료", and
the segment parks. A thin recovery report therefore leaves a place for a person
to arrive at instead of quietly ending the run.

**A recovery in which every role resolved to `witness`, no role's resolution
round is below the last round the ledger block records, and no role's resolution
round is below the highest round at which that role left anything at all emits
the line normally.** Uniform `witness` is not sufficient on its own — no role may
sit below either round. A role sitting **above** the ledger's round is on the
emitting side: that column is a conservative under-claim that can lag a live
round, so a role ahead of it left a witness at a round the column had not caught
up to. No role can sit above its own reached round, because the ladder starts
there and only descends. Rounds after the first exist
to cross-review and converge, and a round-1 witness is by definition upstream of
both, so a recovery built entirely from round-1 witnesses is a real finding set
that has not yet had its self-refutations taken out of it, and it is not the
finding set the original stage would have published. **That case takes the
partial-recovery line with `최저 계층 라운드 미달` where the ledger block records
a round of 2 or higher, and also where any seat resolved at a round below the one
it reached**, and the places to read the shortfall from are
`## 복구 프로버넌스`'s 해소 라운드 and 도달 라운드 columns and the `최저 라운드`
field of that line — a reached-round shortfall does not show in the 해소 라운드
column on its own, because it is the gap between the two columns.

**Where the ledger block records only round 1, neither condition fires on any
corpus in which every seat resolved to `witness` at the highest round it reached,
and that is a hole rather than a design.** The ledger-round comparand is the
ledger's own round column, and a crash landing before the round-2 flip is written
lowers it along with the work — every row still reads `round-1`, so a
round-1-only recovery sits at the comparand rather than below it. The
reached-round comparand does not help **on such a corpus**, because a seat that
resolved at the highest round it reached is not below it. **Only a seat whose
resolution round fell below the round it reached is outside the antecedent, and
the fourth condition catches that one — a seat that reached a higher round and
resolved there leaves the corpus inside the hole, which is why the comparison
that decides this is the per-role one the arm states as "closes per role, so no
`max` across the roster is taken".** Nothing on disk separates that crash from a
team that legitimately finished in one round **where every seat reached only
round 1**, so the paragraph above says what such a corpus is worth while the
conditions as written let it emit the ordinary line.

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
- **리뷰 분야**: 기술(기본)
- **기획서**: 없음
- **리뷰 팀 구성**:
    - [role] ([opus|sonnet|haiku]): [scope]
    - ...
- **모델 티어**:
    - <role-slug> | 부류=<class id> | 모델=<opus|sonnet|haiku> | 출처=<표|승격|사용자> | 지표=<trigger id[,trigger id]|-> | 재기동=<-|sonnet (한도 오류)>
    - ...
- **슬라이스 범위**: 슬라이스 <id> (다른 슬라이스 <k>개)
- **발견 요약**: 🔴 P0 N건 | 🟠 P1 N건 | 🟡 P2 N건 | 🟢 P3 N건
- **P1 분류**: 차단 N건 | 이월 가능 N건
- **다른 슬라이스 몫**: N건 (집계 제외)

`슬라이스 범위` 줄은 두 모양 중 정확히 하나로 쓰며, 슬라이스 범위를 적용하지 않았으면 `적용 안 됨 — <사유>` 모양이다. `다른 슬라이스 몫` 줄은 슬라이스 범위를 적용했을 때만 둔다. 세 줄의 문법은 "P1 Classification Grammar" 섹션이 소유한다.

`리뷰 분야` 줄은 열린 분야가 없으면 `기술(기본)`, 있으면 `기술 + 요구`·`기술 + 문서표현`·`기술 + 요구, 문서표현` 처럼 열린 분야만 「요구, 문서표현」 순서로 쓴다. `기획서` 줄은 컨텍스트 패키지 17번 항목으로 쓴 문서의 경로, 없으면 `없음`, 무인 리뷰가 앵커 브리프(첫 줄 `# 앵커 브리프 — 설계 문서 없는 런`)를 받았으면 `없음 — 앵커 브리프` 다. 분야 규칙은 `01-reviewer-context-package.md` 14번 항목의 Field scope 가 소유한다.

`모델 티어` 블록은 `_common/team-model-tier.md` 에 구속되는 스킬(`review`·`review-unattended`)만 채운다. 모델을 리터럴로 쓰는 `review-lite` 는 고르는 것이 없으므로 이 블록을 생략한다. 행 문법은 그 티어 파일이 소유하며 여기서 다시 적지 않는다.

`**좌석**` 줄은 그 블록을 채우는 보고서의 모든 P0·P1 항목이 항목 줄 바로 아래 첫 하위 불릿으로 갖는다: `    - **좌석**: 낸=<role-slug>[,<role-slug>…] | 동의=<role-slug>[,<role-slug>…]`, 동의 좌석이 없으면 `동의=-`. 슬러그는 같은 보고서 `모델 티어` 행의 첫 칸과 바이트가 같다. `낸` 은 자기 증인에서 그 결함을 낸 좌석 전부이고, Finding Merge Rules 로 합친 항목이면 합쳐진 모든 좌석을 적는다. `동의` 는 낸 좌석이 아닌 좌석 가운데 교차 검증에서 그 항목을 최종 심각도 이상으로 확인한 좌석이며, 낮은 심각도로 본 좌석·반박한 좌석·다루지 않은 좌석은 적지 않는다. 상속되어 다시 들어온 항목(`(상한 사이클 N에서 상속, …)`, 델타 모드의 `(사이클 N에서 상속, 미해결)`·`(사이클 N에서 상속)`)은 원 보고서의 이 줄을 그대로 옮기고, 원 보고서에 줄이 없으면 쓰지 않는다. `## 상한 사이클 재확인` 항목과 P2·P3 항목은 이 줄을 갖지 않는다. 팀 없이 증인 잔재로 합성하는 복구 보고서(`--recover`, `발견 요약(부분 복구)`)는 `모델 티어` 블록과 이 줄을 갖지 않고, `--lead-fix` 는 새 보고서를 쓰지 않으므로 해당하지 않는다. 이 줄은 `**[차단]**`·`**[이월 가능]**` 태그 토큰을 담지 않는다 — 게이트가 P1 절의 모든 줄에서 그 토큰을 센다. `review-lite` 는 `모델 티어` 블록과 함께 이 줄을 생략한다. 항목 줄 끝의 `— 리뷰어` 는 사람이 읽는 꼬리로 그대로 남는다.

각 P0·P1·P2 항목은 분석(근거/제안) 아래에 `💬 붙여넣기용 코멘트` 블록을 두어 GitHub 인라인 코멘트로 그대로 복사할 수 있게 했다(톤: 분석은 단정, 코멘트는 정중). P3는 항목 한 줄이 곧 코멘트다.

---

## 핵심 요약

[3-5 sentences: overall code quality assessment, most important findings, merge recommendation.
Mention CI failure items if applicable.]

---

## 🔴 P0 (즉시 수정 필수) ← skip section if none

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **좌석**: 낸=<role-slug>[,<role-slug>] | 동의=<role-slug>[,<role-slug>]|-
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction or example code]
    - 📎 관련 PR 코멘트: [@author의 기존 코멘트 참조] (if applicable)

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (📎로 confirms-existing이면 블록쿼트 대신 평문 노트)

## 🟠 P1 (머지 전 수정 권장)

- **[category]** **[차단]** `파일:라인` 이슈 설명 — 리뷰어
    - **좌석**: 낸=<role-slug>[,<role-slug>] | 동의=<role-slug>[,<role-slug>]|-
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction]
    - 📎 관련 PR 코멘트: [if applicable]
    - **분류 근거**: <한 줄 — 이월 가능이면 세 기준을 모두 만족하는 이유, 차단이면 어긋난 기준 번호와 이유>

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (📎로 confirms-existing이면 블록쿼트 대신 평문 노트)

- **[category]** **[이월 가능]** `파일:라인` 이슈 설명 — 리뷰어
    - **좌석**: 낸=<role-slug>[,<role-slug>] | 동의=<role-slug>[,<role-slug>]|-
    - **근거**: [severity justification]
    - 💡 수정 제안: [specific fix direction]
    - **분류 근거**: <한 줄 — 이월 가능이면 세 기준을 모두 만족하는 이유, 차단이면 어긋난 기준 번호와 이유>
    - **이월 제목**: <한 줄 — 이슈 제목 끝에 그대로 쓰인다>
    - **이월 본문**:
      <문제 상황 한 줄>
      <위치: 저장소 경로:줄>
      <근거와 영향>

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (📎로 confirms-existing이면 블록쿼트 대신 평문 노트)

## 🟡 P2 (차후 이슈 등록 권장)

- **[category]** `파일:라인` 이슈 설명 — 리뷰어
    - **근거**: [severity justification]
    - 💡 수정 제안: [when non-obvious only]

    💬 붙여넣기용 코멘트 ← "Paste-Ready Comment Blockquote" 섹션 참조 (`[제안]`은 💡 수정 제안이 있을 때만; 📎로 confirms-existing이면 평문 노트)

## 🟢 P3 (개선 제안)

- **[category]** `파일:라인` [정중체·자기완결 한 줄 — 그대로 붙여넣을 수 있는 개선 제안] — 리뷰어
- **[category]** `파일:라인` [정중체·자기완결 한 줄 — 줄 끝 `— 리뷰어명`은 복사 시 제외] — 리뷰어

## 다른 슬라이스 몫 (집계 제외) ← only when a slice scope was applied and it has at least one item

- **[category]** **[P2]** `파일:라인` 이슈 설명 — 리뷰어
    - **배정**: 슬라이스 <id> — 「<설계 문서의 그 슬라이스 블록에서 이 발견이 속하는 줄의 축자 문면>」
    - **근거**: <왜 이 슬라이스가 아니라 그 슬라이스의 몫인가>

## 범위 밖 관찰 ← only when there is at least one observation; "Out-of-scope observations section" 참조

- [요구] `파일:라인` <관찰 한 줄> — 리뷰어
- [문서표현] `파일:라인` <관찰 한 줄> — 리뷰어

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

### Recovery-report variant

A recovery report follows the same skeleton with two changes. The `발견 요약`
line follows the interlock above — the ordinary line when every role resolved to
`witness`, no role's resolution round is below the last round the ledger
block records, and no role's resolution round is below the highest round at
which that role left anything at all, the partial-recovery line otherwise; with
the partial-recovery line the `P1 분류` line reads exactly
`- **P1 분류**: 차단 미상 | 이월 가능 미상` — and
one extra section is
added
directly after `## 개요`:

```markdown
## 복구 프로버넌스

| 역할 | 계층 | 해소 라운드 | 도달 라운드 | 파일 | seq | nonce 미검증 |
| --- | --- | --- | --- | --- | --- | --- |
| [role] | witness / checkpoint / absent | [N] | [N] | [path read, or — for absent] | [N, or — outside the checkpoint tier] | 예 / 아니오 |
```

`seq` is recorded as read and adjudicates nothing. `nonce 미검증` is `예` only
where the ledger block was gone and the witness was accepted on a
self-consistency check instead of a nonce comparison.

`해소 라운드` is the round the ladder resolved the role at; `도달 라운드` is the
highest round at which that role left anything at all, which is where the ladder
started. The two differ exactly where the ladder descended, and that is the seat
the second suppression condition catches — a row carrying `2` and `1` says the
seat got to round 2 and could not finish there, which the `최저 계층 라운드 미달`
value on the summary line does not say on its own.

A 계층 cell reading `absent (조인 미해소: {파일명})` means the row was left with
no file while that file stayed assigned to no row — an absence the join
produced rather than one the disk shows, written so a reader can tell the two
apart afterwards. It does not say which row that file belonged to.

The partial-recovery line's `최저 라운드` is the **minimum** of this table's
`해소 라운드` column, so the two are read together: the table says which role
stopped where, the line says how far the weakest one got.

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
