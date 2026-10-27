# Unresolved closure — the `**구현 처분**` contract

The one source for how an open entry of a design document's
`## 미해결 이슈 / 트레이드오프` says whether an implementation may decide it.
Writer skills and the readers point here by path and section heading; they do
not copy its text.

## 대상 항목

Every entry of `## 미해결 이슈 / 트레이드오프` whose `상태` is not `해결`. An
entry whose `상태` is `해결` is already binding tier and carries none of the
fields below. The residual items of `## 구현 시 검증 항목` are not entries of
this contract: they are facts with a recipe, checked by the implement stage's
pre-implementation gate.

## 필드

Each target entry carries one line `**구현 처분**: <값>`, the value one of the
closed set:

- `구현 재량` — the implementation may choose. It is followed by
  `**재량 기준**: <한 줄>`, the written standard the implementation chooses by.
- `구현 전 결정` — a person (or an audit, or a re-convergence) closes it before
  any implementation plans over it. It is followed by
  `**닿는 슬라이스**: <id>, <id> | 전체` — the slices of `## 구현 슬라이싱` whose
  work the decision changes, or `전체`.
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

## 작성자 꼴

- A writer writes every entry that carries these fields as a `### ` sub-heading
  block, one field per line. An audit or a re-convergence that adds an entry to
  a section written as a table adds it below the table, in the sub-heading
  form; the interactive `design` skill's rule against mixing the two forms
  applies only when that skill writes the section anew.
- An interactive audit writes `사유: 감사 합성 요구 — 사람 판단` on a synthesis
  item the person asked to record as open, as the unattended audit does.
- The answer an implementation chooses for a `구현 재량` entry is recorded in
  the reference-tier drift sidecar (`docs/design-drift/{slug}.md`), not in the
  design document.

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
- `**상태**:` and `상태:` read alike, as do `**구현 처분**:` and `구현 처분:`.
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

## 읽는 쪽

- The unattended implement stage asks `gate.sh unclosed-decisions` before it
  plans (process A) and halts on a non-empty answer with the
  `Step 1 CFI-U3 BT-STOP — 미결 결정` record of `_common/pipeline-sidecar.md`
  §4. The driver and the gate admit no plan of a process A attempt the reader
  is not empty for.
- The interactive `implement` asks the person about each `구현 전 결정` entry
  its plan reaches before it implements.
- A `구현 재량` entry is chosen by its `**재량 기준**`.
