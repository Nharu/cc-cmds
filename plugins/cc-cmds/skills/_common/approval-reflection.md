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
A failed reflection changes no byte of the document, so the next attempt starts
from the same `사전 sha256`.

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

## 쓰기 순서

1. **Working copy.** Every edit rides one working copy of the document.
2. **Publish.**
   - Unattended: the re-convergence's working copy and its `lockf` publish
     (`design-reconverge` Step 3), its hash checks included.
   - Interactive: compare the document's `shasum -a 256` before taking the copy
     and again right before publishing; a difference stops the reflection.
     While an unattended run on the same document is alive, do not reflect
     interactively at all — the run's re-convergence is that document's
     reflection. Alive is read from the run's own record — a manifest naming
     the document, whose plan carries a visual publish step and whose ledger
     exists and carries no end token yet — never from the sidecar's
     ` — 사람 답` tail, which an ended run leaves behind. A run with no visual
     publish step dispatches no reflection, so it does not hold this one back. The comparison is the one the unattended path makes, so it adds
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
fails, the session that comes back — a re-attached one or one started on a
re-entry card — compares the reflection record's `사후 sha256` with the document
now. Equal → write only step 3 to the sidecar. Different → it is not this
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

- Unattended: `${CC_PIPELINE_RUN_DIR}/design/{slug}/approval-reflection-<기록 파일 이름>.md`,
  `<기록 파일 이름>` the `시각-판정` record's file name. The morning report reads
  this file.
- Interactive: `<base>/docs/visual/reflection/{slug}.md`. It sits in a
  subdirectory because every `*.md` directly under `docs/visual/` is enumerated
  as a sidecar, and a document whose key ends in `.reflection` would collide
  with that name.

Writes of the record and of the sidecar are declared like the document publish,
`--surface 트리밖쓰기 --reach 런로컬`.

## 종단

How a reflection attempt ends, and what each end leaves, is a closed table: the
sidecar value, the stop record and its option, the way the attempt is let in
again, and the morning report line. The writers, the gate, the routers and the
morning report follow it; an end the table does not hold is not made.

| 종단 | `**문서 반영**` | 정지 기록 | 다시 들이는 길 | 아침 보고 |
| --- | --- | --- | --- | --- |
| 정상 완료 | `완료 — 문서 sha256 <사후>` | 없음 | 들이지 않는다 — 술어가 `승인 유효` 로 돌아와 화면 슬라이스가 계획·파견된다 | `완료`, 어긋남 건수, 반영 기록 경로 |
| 실패 넷, 적용할 수 없는 줄 | `실패 — <사유>` | `Step 3 승인 화면 반영 — 충돌`, 선택지 `결정 첨부 후 다시 반영` | 사람 답 — 같은 런은 `재부착` 라우트의 운반, 앞선 런은 진입 술어의 운반 답 갈래 | `실패 — <사유>`, 정지 기록, 선택지, 답이 없으면 화면 슬라이스가 보류로 서 있음 |
| 게시 전 `precondition-failed`(문서 해시 다름·`lockf` 75), 첫 번째 | `대기` 그대로 | 재수렴의 `precondition-failed` 정지(선택지 없음) | 같은 답으로 한 번 더 | `대기`, 다시 들임 |
| 정지 기록 없는 비정상 종료, 첫 번째 | `대기` 그대로 | 없음 | 같은 답으로 한 번 더 | `대기`, 다시 들임 |
| 위 두 종단의 두 번째 | `실패 — <종단>` | 실패 정지와 같은 사람 전용 정지 | 사람 답 | `실패 — <종단>`, 정지 기록, 선택지 |
| 반영을 파견할 자리가 없는 런 | `대기` 그대로 | 없음 | `/cc-cmds:visual <문서> 구현 승인` 을 다시 실행하면 대화형 반영이 문서 고침부터 이어진다 | `대기 — 반영 미파견`, 다시 실행 안내 |
| 앞선 런에서 가져온 답 | 앞선 런이 남긴 값 | 게이트가 이 런 `halt/` 로 복사한 기록 | 진입 술어의 운반 답 갈래 | 그 시도의 종단에 맞는 위 행 |

The stop record of a reflection never offers a `보류` option: a record left
unanswered is the hold — the screen slices stand in this run, and the record
waits for a person in the morning report.
