# Unresolved closure — the `**구현 처분**` contract

The one source for how an open entry of a design document's
`## 미해결 이슈 / 트레이드오프` says whether an implementation may decide it.
Writer skills and the readers point here by path and section heading; they do
not copy its text.

## 대상 항목

Every entry of `## 미해결 이슈 / 트레이드오프` whose `상태` is not `해결`, the
value read as `## 판독 문법` reads it. An
entry whose `상태` is `해결` is already binding tier and carries none of the
fields below. The residual items of `## 구현 시 검증 항목` are not entries of
this contract: they are facts with a recipe, checked by the implement stage's
pre-implementation gate.

The one exception: an entry closed by `## 사유 거둠` keeps its `**사유**`,
`**구현 처분**` and `**닿는 슬라이스**` lines byte for byte, as history of
why it was forced. They are no longer read — the entry's `상태` is `해결`.

## 필드

Each target entry carries one line `**구현 처분**: <값>`, the value one of the
closed set:

- `구현 재량` — the implementation may choose. It is followed by
  `**재량 기준**: <한 줄>`, the written standard the implementation chooses by.
- `구현 전 결정` — a person (or an audit, or a re-convergence) closes it before
  any implementation plans over it. It is followed by
  `**닿는 슬라이스**: <id>, <id> | 전체` — the slices of `## 구현 슬라이싱` whose
  work the decision changes, or `전체` — and then by two more lines,
  `**추천 답**: <한 줄>`, the answer the writer recommends, and
  `**추천 근거**: <한 줄>`, why. The run collects every such entry before
  implementation and shows a person each one with its recommendation, so the
  person can confirm them all at once.
- `구현 무관` — the entry decides nothing the code writes: a later measurement,
  another ticket, an operational judgment outside the repository. The
  implementation does not read it.

## 값 고르는 기준

An entry is `구현 재량` only when all four hold:

1. Its `골격급` is not `예`.
2. Its `사유` does not start with `감사 합성 요구` or `베이스 계약 변경 필요`.
3. Its effect stays inside one slice's declared files and changes no contract
   another side reads — an interface, a file or row format, a flag, a ledger
   or halt record field, an exit code.
4. The standard that chooses the answer fits on one line (`**재량 기준**`), and
   the chosen answer can be undone by one edit — the shape of judgment grade 1.

An entry that decides nothing the code writes is `구현 무관`. Everything else is
`구현 전 결정`.

Two cases are always `구현 전 결정`, whatever else holds:

- an entry whose `골격급` is `예` — a skeleton-grade item left after the audit's
  re-convergence cap is one;
- an entry whose `사유` starts with `감사 합성 요구` or `베이스 계약 변경 필요`.

An entry whose `사유` starts with `베이스 계약 변경 필요` ends only by
`## 사유 거둠`: no other writer rewrites it to `해결`. An entry of the same case
whose `사유` starts with `감사 합성 요구` is closed as before, by the
re-convergence's `감사 골격급` scope.

**A writer closes on its own what a record already answers.** An entry whose
answer one of the repository's facts, the interview record or a written rule
decides is closed by the writer: written `해결`, or `구현 재량` when the four
conditions above hold. This does not narrow the rules above — the two
always-`구현 전 결정` cases stay, and so does condition 3 of `구현 재량` — so an
entry a fact answers but whose answer changes a contract another side reads is
closed as `해결` or left `구현 전 결정`, never written `구현 재량`. Outside those
two cases a writer leaves `구현 전 결정` only for four kinds of entry:

- a value judgment no written standard decides;
- a risk acceptance;
- a requirement beyond the record;
- an external resource a person has to prepare.

## 작성자 꼴

- A writer writes every entry that carries these fields as a `### ` sub-heading
  block, one field per line. An audit or a re-convergence that adds an entry to
  a section written as a table adds it below the table, in the sub-heading
  form; the interactive `design` skill's rule against mixing the two forms
  applies only when that skill writes the section anew.
- A writer that closes an entry writes the bare value, `**상태**: 해결`, and
  puts any note about how it was settled on a line of its own inside the
  entry. The reader also takes a note after `—`, `·` or `(` (`## 판독 문법`),
  but a bare value is the one every reader agrees on.
- An interactive audit writes `사유: 감사 합성 요구 — 사람 판단` on a synthesis
  item the person asked to record as open, as the unattended audit does.
- The answer an implementation chooses for a `구현 재량` entry is recorded in
  the reference-tier drift sidecar (`docs/design-drift/{slug}.md`), not in the
  design document.
- The two marker lines a closing re-convergence writes into an entry whose
  `사유` starts with `베이스 계약 변경 필요` — `**사유 거둠**` and
  `**대조 기록**` — take the form `## 사유 거둠` fixes.

## 사유 거둠

How an entry whose `사유` starts with `베이스 계약 변경 필요` is closed inside
the run, when the person keeps the base as it is. The base design document,
its ticket and the document's own `## 베이스 제약` section stay byte for byte;
the closing is recorded in this document only.

- **The one writer.** The base contract check of the `구속 티어 이탈 <halt
  record>` scope of `/cc-cmds:design-reconverge`, in its two sub-cases whose
  record's `**스텝**` is exactly `Step 1 CFI-U3 BT-STOP — 미결 결정` (an
  implement stage's open-decision stop) or exactly `결정 수거 — 구현 전 결정`
  (the gate's decision collection), and each sub-case's re-entry on a person's
  answer to its own base contract check stop. The two sub-cases run one check
  and write one form; they differ only in where the decision comes from. A
  design stage, an
  audit, a walkthrough and every other re-convergence scope — `감사 골격급`
  among them — neither closes such an entry nor writes it `해결`.
- **When it closes.** The re-convergence checks the person's decision against
  the ticket and contract blocks of the document's `## 베이스 제약` section.
  The result `무충돌` closes the entry in the same pass. The results `충돌`,
  `대조 문면 없음` and `지명할 줄 없음` stop and ask the person; the answer
  `베이스 개정 없이 계속` closes the entry. The result `선언 파일 밖` never
  closes in the run.
- **Write form.** The decision is written as a decision sentence of
  `## 합의된 아키텍처` or `## 주요 결정사항과 근거`. The entry's `상태` line
  becomes the bare `**상태**: 해결`. `**사유**` and every other field stay byte
  for byte. Right after the `**상태**` line come two lines, in this order:

  ```text
  **사유 거둠**: 베이스 개정 없이 — <대조 무충돌 | 사람 수용(충돌) | 사람 수용(대조 문면 없음) | 사람 수용(지명할 줄 없음)> · 런 <run id> · <stage id 축자> · 중단 기록 <기록 파일 이름>
  **대조 기록**: 「<블록 제목>」 무충돌; 「<블록 제목>」 충돌: 「<어긋난 줄 축자>」
  ```

  - The four marker values are `대조 무충돌` (the check found no conflict),
    `사람 수용(충돌)`, `사람 수용(대조 문면 없음)` and
    `사람 수용(지명할 줄 없음)` (the person answered `베이스 개정 없이 계속` to
    a stop of that result).
  - `<run id>` is `CC_PIPELINE_RUN_ID`. `<stage id 축자>` is the closing
    session's `CC_PIPELINE_STAGE_ID` as it is, `#` kept — not the `#`→`-` form
    the re-convergence uses in a temporary directory name.
  - `중단 기록` names the file of the halt record: for `대조 무충돌`, the
    record the re-convergence's scope names — the implement stage's
    open-decision stop that carried the attachment, or the gate's
    decision-collection record; for a `사람 수용(…)` value, the base contract
    check stop the person answered.
  - `**대조 기록**` gives one part per block. When several lines of one block
    conflict, `「<블록 제목>」 충돌: 「<어긋난 줄 축자>」` repeats once per line,
    so each part names one line. Its value is the single word
    `대조 문면 없음` for that result and `지명할 줄 없음` for that one.
  - Neither key matches any form of a key the reader reads (`상태`,
    `구현 처분`, `재량 기준`, `닿는 슬라이스`, `골격급`, `사유`).
- **Quotation bounds.** A block title or a line inside 「」 in
  `**대조 기록**` or in the precedence phrase below equals, byte for byte, a
  block title or a block line of the document's `## 베이스 제약` section, so a
  「」 or `; ` inside it is written as is and not escaped. A reader does not
  take the first `」` as the end: after the opening `「`, the end is the `」`
  at which the bytes between equal that section's block title (a title quote)
  or one line of the named block (a line quote). When more than one `」`
  qualifies, the end is the one followed by the bytes the form expects —
  ` 무충돌`, ` 충돌: 「`, `; 「` or the line end in `**대조 기록**`,
  ` 보다 앞선다 (` in the precedence phrase.
- **Precedence of a conflict the person accepted.** An entry whose `상태` is
  `해결` and whose `**사유 거둠**` is `사람 수용(충돌)`: its decision sentence
  takes precedence over the lines of `## 베이스 제약` its `**대조 기록**` names
  as `충돌`, and over those lines only. The implementation follows the
  decision instead of such a line; doing so is not a departure from the
  binding tier and is no cause for a CFI-U3 BT-STOP. A line not named, the
  other lines of the same block and the decisions of other entries bind as
  before, and the `## 베이스 제약` section, the base document and the base
  ticket stay byte for byte. The re-convergence ends the decision sentence
  with one line per named line, starting on the line after the decision's
  last line:

  ```text
  이 결정은 `## 베이스 제약` 의 「<어긋난 줄 축자>」 보다 앞선다 (사유 거둠 — 사람 수용(충돌))
  ```

  `대조 무충돌`, `사람 수용(대조 문면 없음)` and `사람 수용(지명할 줄 없음)`
  have no line to take precedence over: an implementation of such a decision
  keeps every line of `## 베이스 제약` as before, and stops with a CFI-U3
  BT-STOP as before when it cannot.

## 판독 문법

`unresolved_closure_pending <doc> <seg>` in `orchestrator/run.sh` reads this
contract for the driver and the gate (`gate.sh unclosed-decisions`). It prints
the headings of the `구현 전 결정` entries that reach `<seg>`, one per line in
document order, and nothing when none does. It reads **fail closed**:

- An empty document argument (a run with no document) prints nothing. A named
  document that is missing, unreadable or carries an unclosed code fence prints
  one line `문서 판독 불가 — <reason>`, which reaches every segment.
- The section is the last `## ` heading matching `미해결\s+이슈`, up to the next
  `## `. No section, a body of one `없음` line, or guidance lines only: no
  entry.
- Entries are `### ` blocks and table rows. A table row whose `상태` column
  reads `해결` is skipped; every other row reads `구현 전 결정 · 전체`, and its
  heading is its first cell. A section mixing both forms reads each by its own
  rule.
- A `상태` value — a field or a table cell — reads `해결` when, trimmed, it is
  `해결` or `해결됨` alone, or followed by `—`, `·` or `(` after optional
  blanks (`해결 — <메모>`, `해결 (…)`). Any other value, `해결 대기` among them,
  leaves the entry open.
- `**상태**:`, `상태:` and a key bolded with its value (`**상태: 해결** — …`)
  read alike, as do the same forms of `구현 처분`.
  A value is trimmed and must equal one of the closed set; an empty or
  out-of-vocabulary value reads `구현 전 결정 · 전체`, and so does a missing
  `**구현 처분**`.
- `구현 재량` without `**재량 기준**`, and `구현 전 결정` without
  `**닿는 슬라이스**`, read `구현 전 결정 · 전체`.
- The reader applies the two always-`구현 전 결정` cases again, whatever
  `**구현 처분**` says, with `전체` when `**닿는 슬라이스**` is absent.
- `<seg>` is a slice id. `**닿는 슬라이스**` filters by the ids it names when
  each is a `### 슬라이스 <id>` of the document, whatever that slice's
  `**스킬**`; an id the document does not have reads `전체`. A document with no
  `## 구현 슬라이싱` reaches every segment with every entry.
- `**추천 답**` and `**추천 근거**` are read from the entry's block, in the
  same key forms as `**구현 처분**`; an entry without them reads both as
  `(없음)`, as an entry of an older document and an entry forced to
  `구현 전 결정` (`골격급: 예`, or a `사유` starting with `감사 합성 요구` or
  `베이스 계약 변경 필요`) usually do, and every table row does. The headings the reader prints
  do not change: `unresolved_closure_fields <doc> <heading>` in
  `orchestrator/run.sh` reads the two values and `**닿는 슬라이스**` of one
  printed heading, for the gate's `decision-collect`.
- An entry closed by `## 사유 거둠` reads `해결` by its `상태` and drops out.
  A `**사유 거둠**` line on an entry whose `상태` is not `해결` changes nothing,
  wherever in the entry it stands: the reader's code does not read that key.

## 읽는 쪽

- The gate's `decision-collect` collects every entry of a document before any
  process A implement dispatch of it, writes one halt record that lists each
  with its recommendation, and holds the segments the entries reach until a
  re-convergence closes them (`_common/pipeline-sidecar.md` §4). While the
  re-convergence an answered record opened has not ended `정상 완료` — it
  stopped at its base contract check and waits for the person, among others —
  the hold stays under that record whatever the document's digest now is.
- The unattended implement stage asks `gate.sh unclosed-decisions` before it
  plans (process A) and halts on a non-empty answer with the
  `Step 1 CFI-U3 BT-STOP — 미결 결정` record of `_common/pipeline-sidecar.md`
  §4. The driver and the gate admit no plan of a process A attempt the reader
  is not empty for.
- The interactive `implement` asks the person about each `구현 전 결정` entry
  its plan reaches before it implements.
- A `구현 재량` entry is chosen by its `**재량 기준**`.
