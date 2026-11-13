# Approval reflection — bringing an approved screen into the design document

The one source for how a person's approval of screens whose wording or structure
differs from the frozen design document moves the document toward those screens.
Two writers read it: the unattended re-convergence `design-reconverge` on the
scope `승인 화면 반영 <시각-판정 중단 기록 절대 경로>`, and the interactive
`/cc-cmds:visual <문서> 구현 승인` phase in the same call that approves. They
point here by path and section heading; they do not copy its text.

After a reflection ends `완료`, the design document is again the one binding
source: the implementation follows the document, and nothing compares the build
with the approved screens as a second truth.

## 입력

- **The drift block.** The sidecar `<base>/docs/visual/{slug}.md` carries one
  `### 설계 문서 어긋남` block, after the `### 화면 <id>` blocks and before
  `### 금지 후보` (`plugins/cc-cmds/skills/visual/references/sidecar.md` §2).
  One line is one difference:
  - `- <화면 id> · <문서 절 제목 축자> · 「<문서 문면 축자>」 → 「<화면 문면>」`
  - a wording the screen removed: `… · 「<문서 문면 축자>」 → (삭제)`
  - a wording the screen added that the document lacks: `… · 「(없음)」 → 「<화면 문면>」`
  - no difference: the body is the one line `없음`.

  Sample data (fake names, numbers, dates) is not wording and is never a line.
- **The measure.** `visual-check.sh drift <설계 문서>` prints
  `어긋남 <n>건 · sha256 <hex>` and exits 0 when the block exists, exits 1 when
  it does not, and exits 2 — printing each such line — when a line's section
  heading is not exactly one heading of the document or its document wording is
  not verbatim inside that section (`「(없음)」` excepted). The helper is called
  by its absolute path as the first word of a `gate.sh exec`, declared
  `--surface 읽기`.
- **The binding between the two.** The unattended path starts only when the
  `**관측 상세**` of the `시각-판정` record the scope names carries
  `설계 문서 어긋남=<n>건 · sha256 <hex>` and `drift` prints the same count and
  the same sha256 now. A difference is a halt with `분류: precondition-failed`
  naming both values: the list the person approved is not the list on disk, and
  a reflection that read it would edit outside what the person approved. An
  exit 2 prints no count line, so it is read against the block: when the
  block's lines are, in number and verbatim, the lines the record quotes, and
  every printed line is one of them, it is not that halt — the block is the
  approved one, and the lines `drift` prints are lines that cannot be applied
  (`## 실패로 보는 경우`), which stop on the reflection's own record. The
  interactive path computes the block, shows it and asks in the same call, so
  the list shown is the list written.
- **The scope is the block's lines and nothing wider.** A difference the block
  does not list is not reflected; the unattended implementation's binding-tier
  stop catches what is left. That the list is complete rests on the publishing
  stage's judgment and on the person who read it at `시각-판정` — a known limit,
  since nothing extracts the differences between a screen and the document
  mechanically.

## 고칠 수 있는 절

A line is reflected by rewriting its document wording to the screen wording, and
only inside these sections:

- `## 합의된 아키텍처`;
- the decision sentences of `## 주요 결정사항과 근거`;
- the entries of `## 미해결 이슈 / 트레이드오프` whose `상태` is `해결`.

A decision sentence that changes keeps the superseded sentence in the same
place, as the re-convergence's Step 3 does on every scope that records one, so a
citation aimed at the old wording still lands. A `→ (삭제)` line removes the
wording from its sentence; a `「(없음)」` line adds the screen wording to the
section the line names. Never touch `## 팀이 정한 요구 결정`, `## 시각 정합 기준`,
`## 검증 기록` or any section outside the three.

## 실패로 보는 경우

Every one of these is judged on the working copy, before anything is published.
A failed reflection changes no byte of the document. The next attempt still does
not start from the stop record's `사전 sha256`: before a person answers, a
screen-less slice's implementation stage may write the same document, so a
carried answer measures its baselines again (`## 운반 답 재진입`, step 2).

1. **S1–S4 unmet** — the adoption criteria of `design-reconverge` Step 3.
2. **A collision with another binding decision** — the screen wording would make
   another binding sentence of the same document read otherwise.
3. **A forbidden section** — the line can be reflected only by changing
   `## 구현 슬라이싱`, `## 구현 시 검증 항목` or `## 베이스 제약`.
4. **Wording a screen-less slice planned or merged** — the line's document
   wording is quoted verbatim in the slice body (that slice's section of
   `## 구현 슬라이싱`) of a segment with no screens that holds a `plan_sha256`
   row or a merge row in the run ledger. The ledger row says which segment
   planned or merged; the verbatim quote in the plan's input says which wording
   is that segment's.

**A line that cannot be applied** fails too: before editing a line, check that
its document wording stands verbatim inside one of the sections it may change.
It does not when the wording sits in a section that cannot be changed (such as
`## 팀이 정한 요구 결정` or `## 시각 정합 기준`), or when another write removed it
from the document after the approval. Write that line into the failure's reason.

Never drop a line of the approved list silently, and never edit a section the
list may not change to make a line fit.

## 첨부 결정

A failed reflection stops on a record only a person answers, with the one option
`결정 첨부 후 다시 반영`. The answer's attachment chooses, per drift line, quoting
the line verbatim:

- `문서대로 둠` — the line leaves the reflection; the remaining difference is
  what the unattended implementation's binding-tier stop handles.
- `화면대로 고침` — the line is reflected, inside the sections it may change.

A line of failure 3 or 4, and a line that cannot be applied, takes `문서대로 둠`
only: the forbidden sections and the planned or merged wording are not lifted by
an answer, so the only answer that ends the stop is to take the line out. A line
the attachment does not name is reflected as before; a line it names with
`화면대로 고침` that still fails stops again in the same form.

**The attachment's form.** The answer carries the decisions the way a
`구속 티어 이탈` stop's answer does, as `첨부=<기록>.answer.md` — the answered
record's path with `.md` replaced by `.answer.md`. The file holds the block's
lines, each copied verbatim on a line of its own, and under each one
`문서대로 둠` or `화면대로 고침`. The gate does not require the attachment: an
answer with none, or one that leaves a line out, is let in all the same. A line
the attachment does not name reads `화면대로 고침`, and when that line fails
again the reflection stops in the same form — a line of the approved list is
never dropped silently. The attachment is read at step 4 of
`## 운반 답 재진입`.

## 쓰기 순서

1. **Working copy.** Every edit rides one working copy of the document.
2. **Publish.**
   - Unattended: the re-convergence's working copy and its `lockf` publish
     (`design-reconverge` Step 3), its hash checks included.
   - Interactive: compare the document's `shasum -a 256` before taking the copy
     and again right before publishing; a difference stops the reflection
     without writing `실패` — only a collision (step 4) writes it — and leaves
     the sidecar as it is. While an unattended run on the same document is
     alive, do not reflect interactively at all — the run's re-convergence is
     that document's reflection: show the run id and stop before step 3. Alive
     is one signal: among the authorization records under
     `<base>/docs/pipeline-grant/` whose header `owner-doc=` is this document's
     key, take the latest `## 인가 <run-id>` block; its run is alive while its
     run directory `${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>`
     holds no `done` file yet. Never read it from the sidecar's
     ` — 사람 답` tail, which an ended run leaves behind. An abandoned run with
     no `done` reads as alive too; whether to end it is a person's call. The
     interactive publish takes no `lockf` of the unattended side — a known
     limit. The comparison is the one the unattended path makes, so it adds
     no new rule and keeps one writer from overwriting another.
3. **Sidecar, once.** Rewrite `**문서 반영**` to
   `완료 — 문서 sha256 <사후 64 hex>` — unattended with the tail
   ` — 사람 답 <기록 파일 이름>` of the `시각-판정` record the scope names,
   interactive with no tail — and `**설계 문서 구속 다이제스트**` to the value
   `visual-check.sh binding <설계 문서>` measures over the published document.
   The old digest would read the approved screens as stale. Write the sidecar in
   its atomic form: a temporary file in the same directory, then one whole-file
   replace. No other byte of the sidecar changes.
4. **Failure.** Before writing the stop record, rewrite `**문서 반영**` to
   `실패 — <사유 한 줄>` with the same tail rule. The reason never contains
   ` — 사람 답 `, because readers read the tail from the line's last
   ` — 사람 답 `.

**A cut after the publish is not a failure.** When the session ends after the
document was published and before the sidecar was written, or the sidecar write
fails, every session that comes back on this scope — a re-attached one, one
started on a re-entry card, a new session the gate let in again under its entry
predicate's condition 4, and one carrying an answer — compares the reflection
record's `사후 sha256` with the document now before it reflects anything. Equal → write only step 3 to the sidecar. Different → it is not this
reflection's document any more; follow the re-convergence's ordinary re-entry
rules. This comparison comes before the re-convergence's re-entry rule that stops
when the document moved after the attempt began.

## 반영 기록

One record per reflection, one line per drift line:

```text
- <고친 절 제목 축자> · 「<이전 문면>」 → 「<새 문면>」
```

with a line `문서대로 둠` in place of the arrow for a line the attachment took out,
and two lines at the end, `사전 sha256: <64 hex>` and `사후 sha256: <64 hex>`.

The record is written once the working copy's checks have passed, right before
the publish, and its `사후 sha256` is the working copy's: the publish copies the
working copy as it is, so that value is the published document's hash. An
attempt that stops before the publish leaves its record behind, but the hash
does not match the document, so the recovery comparison does not hold and the
next attempt reflects from the start and overwrites the record.

- Unattended: `${CC_PIPELINE_RUN_DIR}/design/{slug}/approval-reflection-<기록 파일 이름>.md`,
  `<기록 파일 이름>` the `시각-판정` record's file name. The morning report reads
  this file.
- Interactive: `<base>/docs/visual/reflection/{slug}.md`. It sits in a
  subdirectory because every `*.md` directly under `docs/visual/` is enumerated
  as a sidecar, and a document whose key ends in `.reflection` would collide
  with that name.

Writes of the record and of the sidecar are declared like the document publish,
`--surface 트리밖쓰기 --reach 런로컬`.

## 운반 답 재진입

A reflection that comes back to the re-convergence on a carried
`결정 첨부 후 다시 반영` follows this one procedure, in order. It takes the place
of the re-convergence's 「Re-entered with a carried answer」 items, of the
expected hash of its working-copy response 2 and of the before side of its
Step 4 digest comparison, on this scope only. An answer the gate lets in again
under its entry predicate's condition 4 follows it too.

1. **Card check.** Compare the card's `**기록 다이제스트**` with the sha256 of its
   `**중단 기록**`; a difference is a halt with `분류: precondition-failed`
   naming both values.
2. **Baselines.** Run the recovery comparison of `## 쓰기 순서` first (the
   reflection record's `사후 sha256` against the document now). When it does
   not hold, measure the document's `shasum -a 256` and the gate's
   `binding-digest` now and take them as this attempt's `사전 sha256` and
   `사전 구속 표면 다이제스트`. Never take the stop record's baselines, and never
   refuse the answer because the document moved after the stop: a screen-less
   slice writing the same document meanwhile is the ordinary flow. The hash the
   working-copy response 2 expects, the digest Step 4 compares and the
   baselines a stop record of this attempt carries are all these values. What
   keeps another write from overwriting a line the person saw is not the whole
   document's hash but the per-line verbatim check (`## 실패로 보는 경우`, a line
   that cannot be applied) and the working copy's hash checks and `lockf`
   publish.
3. **Question comparison.** The question is the same when the `시각-판정` record
   that the stop record's `범위=승인 화면 반영 <기록>` names is still the latest
   `시각-판정 기록` that `visual-check.sh run-state` prints, and the
   `sha256 <hex>` that `visual-check.sh drift <설계 문서>` prints for the sidecar
   block now equals the one in that `시각-판정` record's
   `설계 문서 어긋남=<n>건 · sha256 <hex>` piece. Then apply the answer, even when
   a recomputed reason or line list reads otherwise than the stop record's
   `**질문 문면**`. Otherwise do not apply it: write a new reflection stop with
   the card's path in its `관측 상세`.
4. **Attachment.** Read `첨부=<기록>.answer.md` and take each line's
   `문서대로 둠` or `화면대로 고침` (`## 첨부 결정`). With no attachment, every
   line is `화면대로 고침`.
5. **Reflection.** At the step the record names (`Step 3 승인 화면 반영`), run
   working copy → publish → sidecar in the order of `## 쓰기 순서`. Never rewrite
   the carried record.

## 종단

How a reflection attempt ends, and what each end leaves, is a closed table: the
sidecar value, the stop record and its option, who writes them, the way the
attempt is let in again and who dispatches that attempt, the document hash the
next attempt starts from, and the morning report line. The writers, the gate,
the routers and the morning report follow it; an end the table does not hold is
not made. A value that is not empty or 「없음」 always names its writer.

「지금 문서로 다시 잰 값」 is the baseline of `## 운반 답 재진입` step 2: the
recovery comparison first, then the document's sha256 and the gate's
`binding-digest` measured now. 「대화형 기준」 is the document sha256 the
interactive reflection measures before it takes its working copy.

| 종단 | `**문서 반영**` | 정지 기록 | 쓰는 쪽 | 다시 들이는 길 | 다시 파견하는 쪽 | 다음 시도의 기준 해시 | 아침 보고 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 정상 완료 | `완료 — 문서 sha256 <사후>` | 없음 | 반영 재수렴 세션(사이드카 두 줄) | 들이지 않는다 — 술어가 `승인 유효` 로 돌아와 화면 슬라이스가 계획·파견된다 | 없음 | 해당 없음 | `완료`, 어긋남 건수, 반영 기록 경로 |
| 실패 넷, 적용할 수 없는 줄 | `실패 — <사유>` | `Step 3 승인 화면 반영 — 충돌`, 선택지 `결정 첨부 후 다시 반영` | 반영 재수렴 세션(사이드카 `실패` 줄을 쓴 뒤 정지 기록) | 사람 답 — 같은 런은 `재부착` 라우트의 운반, 앞선 런은 진입 술어의 운반 답 갈래 | 라우터 교대 — 사람 답의 운반(`--carry-answer`) | 지금 문서로 다시 잰 값 | `실패 — <사유>`, 정지 기록, 선택지 `결정 첨부 후 다시 반영`, 답이 없으면 화면 슬라이스가 보류로 서 있음 |
| 게시 전 `precondition-failed`(원인과 관계없이 분류만 본다 — 문서 해시 다름, `lockf` 75, 카드 다이제스트 다름 등), 첫 번째 | `대기` 그대로(운반 답의 시도면 `실패` 그대로) | 재수렴의 `precondition-failed` 정지(선택지 없음). 사람에게 묻는 기록으로 보고하지 않는다 — 라우터 교대의 반영 분기가 이 기록을 재파견으로 처리한다 | 반영 재수렴 세션(정지 기록만, 사이드카 줄은 쓰지 않음) | 진입 술어 조건 4 를 이 종단에서만 풀어 같은 답으로 한 번 더 | 라우터 교대 — 반영 분기. 운반 답의 시도였으면 같은 답의 운반 | 지금 문서로 다시 잰 값 | `대기`, 다시 들임 |
| 정지 기록 없는 비정상 종료(시간 초과·예산 소진 등), 첫 번째 | `대기` 그대로(운반 답의 시도면 `실패` 그대로) | 없음 | 없음 — 쓰는 세션이 없다 | 위와 같음 | 위와 같음 | 위와 같음 | `대기`, 다시 들임 |
| 위 두 종단의 두 번째 | `대기` 그대로 | 게시 전 `precondition-failed` 이면 재수렴의 그 정지(선택지 없음), 비정상 종료면 없음. 사이드카 줄과 사람 전용 정지를 새로 쓰는 쪽은 없다 | 게시 전 `precondition-failed` 이면 반영 재수렴 세션(정지 기록만), 비정상 종료면 없음 | 들이지 않는다 — 진입 술어가 세 번째 시도를 거절한다. 런이 끝난 뒤 `/cc-cmds:visual <문서> 구현 승인` 을 다시 실행하면 대화형 반영이 문서 고침부터 이어진다 | 없음 — 사람의 대화형 다시 실행 | 대화형 기준 | `대기 — 반영 재시도 소진`, 다시 실행 안내 |
| 다른 분류의 정지 기록(반영 정지·`precondition-failed` 밖, 예: `tool-unavailable`) | 직전 값(`대기` 또는 `실패`) 그대로 | 반영 재수렴 세션이 남긴 그 기록 | 반영 재수렴 세션(정지 기록만, 사이드카 줄은 쓰지 않음) | 들이지 않는다 — 진입 술어의 재시도 판정이 분류가 `precondition-failed` 가 아닌 기록에 열리지 않는다. 런이 끝난 뒤 대화형 다시 실행 | 없음 — 사람의 대화형 다시 실행 | 대화형 기준 | `대기 — 반영 중단(<분류>)`, 정지 기록 경로, 다시 실행 안내 |
| 정상 완료인데 사이드카가 `완료` 가 아님 | 직전 값 그대로 | 없음 | 없음 — 세션은 끝났고 게이트는 거절만 한다 | 들이지 않는다 — 진입 술어의 재시도 판정은 정상 종료에 열리지 않는다. 런이 끝난 뒤 대화형 다시 실행 | 없음 — 사람의 대화형 다시 실행 | 대화형 기준 | `대기 — 반영 완료 미기록`, 반영 기록 경로와 그 `사후 sha256`, 지금 문서 sha256, 다시 실행 안내. 두 해시가 같으면 반영은 이미 게시되었으므로 대화형 다시 실행의 `drift` 가 그 줄을 적용할 수 없는 줄로 읽을 수 있다는 것도 적는다 |
| 대화형 반영이 2 와 4 사이에서 멈춤 | `대기 — 어긋남 <n>건`(꼬리 없음) | 없음 | 대화형 세션이 2 에서 쓴 `대기` 뿐이고, 그 뒤 쓰는 쪽은 없다 | 무인 쪽은 들이지 않는다 — 진입 술어 조건 1 과 라우터 반영 분기의 꼬리 조건이 꼬리 없는 `대기` 를 거른다. `/cc-cmds:visual <문서> 구현 승인` 을 다시 실행하면 대화형 반영이 문서 고침부터 이어진다 | 없음 — 사람의 대화형 다시 실행 | 대화형 기준 | 라우터 교대가 있는 런은 `대기 — 대화형 반영 중단`, 라우터 교대가 없거나 계획에 시각 발행 스텝이 없는 런은 `대기 — 반영 미파견`. 어느 쪽이든 다시 실행 안내 |
| 반영을 파견할 자리가 없는 런(라우터 교대가 없는 런, 계획에 시각 발행 스텝이 없는 런) | `대기` 그대로 | 없음 | 없음 | `/cc-cmds:visual <문서> 구현 승인` 을 다시 실행하면 대화형 반영이 문서 고침부터 이어진다 | 없음 — 사람의 대화형 다시 실행 | 대화형 기준 | `대기 — 반영 미파견`, 다시 실행 안내 |
| 앞선 런에서 가져온 답 | 앞선 런이 남긴 값(`대기` 또는 `실패`) | 게이트가 이 런 `halt/` 로 복사한 앞선 런의 기록 | 게이트(기록 복사와 이 런의 `중단 답` 행). 사이드카는 쓰지 않는다 | 진입 술어의 운반 답 갈래 | 라우터 교대 — 거절된 첫 런 범위 파견이 내준 `--carry-answer <line>` 으로 운반 | 지금 문서로 다시 잰 값 | 그 시도의 종단에 맞는 위 행 |
| 앞선 런에서 가져온 답, 운반 거절(종료 코드 18) | 앞선 런이 남긴 값 그대로 | 게이트가 복사한 앞선 런의 기록(답한 채 남음) | 게이트(`blocked` 행). 사이드카와 새 정지 기록은 없다 | 들이지 않는다 — 이 런에서는 시도가 없고, 교대는 `handoff 사유=중단` 으로 끝난다. 화면 슬라이스는 서 있다 | 없음 | 해당 없음 | `blocked` 행의 사유와 그 기록, 화면 슬라이스가 서 있음 |

A second end of the same kind is not a failure of `## 실패로 보는 경우` and is
not asked of a person: the sidecar stays `대기`, nobody writes a `실패` line or a
person-only stop for it, and the morning report shows the spent retry.

The stop record of a reflection never offers a `보류` option: a record left
unanswered is the hold — the screen slices stand in this run, and the record
waits for a person in the morning report.
