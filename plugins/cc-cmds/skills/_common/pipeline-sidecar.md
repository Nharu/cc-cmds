# Pipeline Sidecar Contract (Shared SOT)

The payload schemas for the autonomous pipeline's durable state. Generic mechanics — path and slug derivation, the header grammar and `owner-doc=` provenance guard, the atomic compare-and-swap write, the never-delete lifetime, the version token — are **not restated here**: they live in `_common/sidecar.md` §1 and this file cites them read-only. What follows is only what §1 delegates to a payload schema: the kinds, their block grammars, their field sets, their mutability splits, and their write forms.

Five sidecar kinds and one non-sidecar record are defined:

| Artifact | Kind token | Writer | Location |
| --- | --- | --- | --- |
| Run manifest | `cc-run-manifest v1` | `autopilot` (kickoff) **only** | `<run 디렉터리>/plan.md` |
| Authorization record | `cc-pipeline-grant v1` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-grant/{slug}.md` |
| Interview record | `cc-run-interview v1` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-run/<run-id>.interview.md` |
| Run ledger | `cc-pipeline-run v1` | the driver **only** | `<base>/docs/pipeline-run/{slug}.md` |
| Approval sidecar | `cc-pipeline-approval v1` | the gate **only** | `<base>/docs/pipeline-approval/<run-id>.md` |
| Halt record | `cc-pipeline-halt v1` | the halting stage | volatile run directory (§4) — **not a sidecar** |

**Why the authorization is a separate file from the ledger.** Exposure: in two files the bytes carrying the permission grant pass through a writer's transform **once per run** rather than on every append. Progress cursor and resume state still live in **one** ledger; the grant is the run's input contract.

---

## 1. Writer partition — and why it is total

**The driver is read-only against the grant.** The only writer of `cc-pipeline-grant` is the kickoff skill `autopilot`; the driver reaches it by no path at all, so it cannot append a **well-formed new block that grants more**. The interview record (§2b.5) has the same single writer: it holds the person's own words, so it is written once, whole, while that person is present. **No gate refuses a write to it** the way one refuses a write to the manifest or the grant — what makes a later change visible is its hash row inside the frozen set, not a guard.

**The driver is the sole writer of the ledger, from the main worktree.** Stage processes emit structured output on stdout and **never write a sidecar** — not the ledger, not the grant — because `sidecar.md` §1.3's compare-and-swap only narrows the window N segment processes would contend in.

This partition is what lets the ledger's `stage-result` rows exist at all: the driver writes them **from the exit code and the artifacts it observed**, never from a stage's self-report, so the invariant is preserved verbatim rather than excepted.

---

## 2. `cc-pipeline-grant v1` — the authorization record

```
# 파이프라인 인가 기록 — {slug}
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=<document key>[; origin-worktree=<absolute worktree root>]; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 2.1 Blocks

One block per run: `## 인가 <run-id>`, where `<run-id>` is assigned at kickoff and is unique within the file. Blocks **accumulate** (§1.4 forbids deleting them) and each is **frozen from the instant it is appended** — there is no field with a mutable region, no disposition, and no close form. Re-authorizing means a **new run** with a new `<run-id>`, never an edit.

### 2.2 Field schema — 9 fields, fixed order

| # | Field | Required | Notes |
| --- | --- | --- | --- |
| 1 | `인가 일시` | always | ISO 8601; the reference point for every other field in the block |
| 2 | `종료 지점` | always | what the user declared "done" to mean for this run |
| 3 | `권한 절단점` | always | one value from the ordered vocabulary of §2.3 — at or below it is autonomous, above it is the blocked queue |
| 4 | `말단 행위 상한` | always | an integer, or `없음` (the default) |
| 5 | `직렬 웨이브 고지` | always | `수행` \| `해당 없음` — records that the user was told a wave carrying residual verification items runs serially |
| 6 | `시각 정합 마커` | always | `없음` \| `있음(인가)` \| `있음(park)` — the kickoff entry check of §2.4 |
| 7 | `사용자 확인 문면` | always | the user's own words authorizing this run, **verbatim** — the only field a human can audit a forged grant against |
| 8 | `설계 문서 전체 sha256` | always | the document's whole-file digest at kickoff |
| 9 | `보고서` | always | the run's morning-report path (§3.5) |

Field lines use the CANON rendering of `_common/verification.md`: bold key, no leading bullet, one ASCII space after the colon. A payload-bearing field is fenced per `sidecar.md` §2.5, whose fence and truncation rules apply here unchanged.

### 2.3 The permission cutpoint is ordered, not a set of toggles

```
커밋 → 브랜치 → push → PR → 머지 → 배포 → 머지 후 후속 착수
```

**Display form above, stored token in the field.** Field 3 carries the **token**, and for six of the seven rungs the two strings are identical — the exception is the last, which displays as `머지 후 후속 착수` and stores as `머지후착수`. Unrecognized tokens are a **hard stop** rather than a silent zero, and `scripts/lint-cutpoint-vocabulary.sh` derives this ladder from the driver's vocabulary so the rendering here cannot drift from the values it describes.

The interview takes **one** cutpoint. Everything at or below it is autonomous; the first act above it sends its segment to the blocked queue — it does **not** ask, because there is nobody to ask. Two consequences are part of this contract rather than implementation detail:

- **`머지` does not carry an `--admin` exception.** A run blocked by branch protection parks. A driver that granted itself the exception because it "was authorized to merge" would be widening the grant silently, which is exactly what §1 exists to prevent.
- **A failed non-required check parks.** The shipped policy enumerates failed non-required checks and asks whether to merge, and forbids merging without an answer. Unattended, the answer never comes, so that branch **is** the park branch.

`terraform plan` needs no grant entry — it is already classified as a read.

**`말단 행위 상한` defaults to `없음`.** The cutpoint authorizes a *class* of act, and the class is allowed for as many segments as the plan turns out to have. The accepted risk is explicit: at authorization time nobody knows how many merges the cutpoint permits, because segmentation happens later and a re-design can re-split it. Where the field carries an integer, the ledger latches the measured segment count at segment-planning time and routes the excess to the blocked queue → morning batch → a re-authorization command.

### 2.4 Foreign grants fail closed

Because `sidecar.md` §1.4 forbids deletion and `{slug}` folds every run of one document onto one path, **run N+1 finds a grant it did not write.** A run treats any existing grant whose `<run-id>` is not its own as **foreign**. A foreign grant is a **hard stop reported to the user**, never inherited authorization. Silently inheriting a previous run's merge permission is the one failure here that is both invisible and irreversible.

This is also the pipeline's only *immediate* notification trigger: the run is stopped until a human confirms, and a human confirming recovers the whole night. (Contrast the blocked queue, where waking someone recovers nothing.)

### 2.5 Write form and its diff gate

One write form: **append**. The writer emits a whole new `## 인가 <run-id>` block with all 9 fields through the compare-and-swap of `sidecar.md` §1.3. Its gate is the append gate: **0 removed lines**, every added line inside the new block. A write that edits a line of an existing block fails the gate — this schema has no rewrite form.

---

## 2b. `cc-run-manifest v1` — the run manifest

The manifest, not the design document, is what a run is *about*. A document is
one optional element inside it, so a run can start from a pull request or from
a bare intent.

**Three parts, split by writer and mutability** — `plan.md` (kickoff, **frozen
whole, creation-only, no append form**), `ledger.md` (driver, append-only),
`report.md`, for the same exposure reason as §1.

### 2b.1 Header and the seven sections

````
# 파이프라인 런 매니페스트 — <run-id>
<!-- cc-run-manifest v1; writer=autopilot; reader=orchestrator; run-id=<run-id>;
     anchor-kind=<doc|repo|pr|branch|intent>; anchor-key=<anchor key>;
     owner-doc=<document key> | (없음); origin-worktree=<abs worktree root>;
     NOT a design doc; mechanism-local, never staged by a skill -->

## 런 정체
**킥오프 일시**: <ISO8601>
**런 id**: <run-id>
**앵커 종류**: doc | repo | pr | branch | intent
**앵커 키**: <anchor key>
**사용자 확인 문면**: <축자>

## 의도
```text
<사용자의 자유 텍스트, 축자>
```

## 대상
**대상 맵 다이제스트**: <모든 대상 행의 정규 직렬화에 대한 sha256>
- `target` | 별칭=<alias> | 메인 워크트리=<abs> | 공통 git 디렉터리=<abs>
            | 베이스 브랜치=<name> | 홈=예|아니오
            | 원격 슬러그=<owner>/<name> | 절단점=<token> | 말단 행위 상한=없음|<int>
            [ | 실행 워크트리=<abs> ] [ | 리뷰 정책 상한=선리뷰후머지|선머지후리뷰|리뷰없음 ]
            [ | dev 식별자=<종류>:<값>[,<종류>:<값>…] ]
            [ | 배포트리거 식별자=<종류>:<값>[,<종류>:<값>…] ]

## 요소
**설계 문서**: <document key> | (없음)
**설계 문서 전체 sha256**: <hex> | (해당 없음)
**리뷰 대상**: <pr/branch 토큰> | (없음)
**적용 지점**: <설계 문서에서 축자 복사한 선언> | (없음)
**적용 프로브**: <apply가 필요한지 판정하는 읽기 전용 명령> | (없음)
**적용 주체**: 파이프라인 | 사람 | (해당 없음)

## 실행 계획
**승인 문면**: <단계 그래프를 승인한 발화, 축자>
```json
{ …승인된 entry-plan 객체… }
```

## 인가
**구속 다이제스트**: <아래 「얼리는 집합」에 대한 sha256>
**런 최대 절단점**: <token>
**종료 지점**: <자유 텍스트>
**벽시계 마감**: <ISO8601 절대>
**비용 천장**: <숫자만 — 통화 기호도 단위도 없이> | 없음
**무진전 상한**: <정수 — 진전 없는 라우터 판정 연속 횟수> | 없음
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사다리 가용 단 수**: 4 | 2
**미선언 상황 처분**: park | 선언된 기본값 진행
- `사전 인가` | 형태=<argv 접두 형태> | 사유=<왜 이 형태가 예측 가능한가>
- `자동 채택` | 판단 부류=<열 값 중 하나> | 상한=없음|<정수> | 심각도 상한=<critical|major|minor|trivial> | 사유=<왜 이 부류가 미리 안전한가>
- `사전 인가` | 인터뷰 기록=<base 기준 경로> | sha256=<전체 해시>     ← 설계 요구사항 인터뷰가 있었을 때만
- `설계 로스터` | 역할=<슬러그> | 범위=<한 줄, 탐색 범위> | 모델=<opus|sonnet|haiku>     ← 팀 티어 설계 스테이지가 있을 때만, 한 팀원 한 행

## 룰 설정        ← 선택. 절 전체를 생략할 수 있고, 생략이 기본이다.
**<룰 이름>**: 켬 | 끔
````

**`설계 문서` is the kickoff's to name, and on a design run `(없음)` is a refused
value.** That field is what the dispatch, its guards and the audit all resolve the
document through, so a run whose frozen plan requires a design must carry a real
path in it — the kickoff derives one from the intent when it reads the roster
back to the person, and writes it before the freeze. `(없음)` stays legitimate on
a run that requires no design. Two checks hold the line and **neither of them
invents a path**: the kickoff's own pre-freeze self-check refuses to write a
manifest pairing a design-requiring plan with `(없음)`, and the gate's
design-dispatch exemption refuses the act rather than reading that value as a
path.

**The manifest freezes the GOAL AND THE CONSTRAINTS, not the plan.** The step
graph is decided one act at a time by a router reading a snapshot, so a frozen
plan would be a value nothing compares against.

What IS frozen, and what `구속 다이제스트` covers: the goal, the termination
point together with its decomposition into checkable clauses, the targets and
their per-target cutpoints, the rule-catalog settings, the list of predicted
irreversible acts, **the `자동 채택` rows**, **the `설계 로스터` rows**, the cost
ceiling and the stagnation bound when declared, and the deadline. The gate
compares that digest at entry.

The `자동 채택` rows are in that list because they decide whether a judgment is
taken without a person. Serialization is over the whole file rather than over
`## 인가` alone, which is deliberately wider than the section the floor honours:
a row planted outside that section is not honoured **and** still moves the
digest. A manifest with no such row contributes nothing. `대상 맵 다이제스트` stays as well — it is the narrower check over the
target rows alone, and keeping both means a target-row edit is named as such
rather than reported as "something in the frozen set moved".

**The stage's authorization list is re-derived, and that is what keeps a run able to finish.** Kickoff happens **before** segmentation, so a segment's own worktree is never in the manifest — it reaches the list through the ledger's `segment` rows.

What keeps the comparison meaningful is not that the surface never moves. It is that it moves **only through the gate**, and leaves a field when it does. So the list is a pure function of the manifest's target rows and the set of worktrees the ledger's `segment` rows name — the last row per segment id, kept only when its `워크트리` is an absolute path to an existing directory sharing a declared target's common git directory — and **the moment that function can change is the moment a non-terminal `segment` row is written.** The re-derivation runs there, inside the `segment` arm of the row writer, with the row about to be written counted as that segment's last: when the render yields different bytes the gate rewrites, re-baselines, and puts `인가면=<before>→<after>` on **that row** — the two enforcement-surface digests, before and after. **A `segment` row without `인가면` reads as "this row widened nothing"**, and no more than that: a terminal row, a row whose inputs were the ones already settled so no render ran, a row whose render yielded the same bytes so nothing was rewritten, a row written before this field existed, and a row whose failure marker did not fit the row cap all look alike, and the row alone does not tell them apart. **A row on which the re-derivation did not land carries `인가면=실패(<사유>)` instead of nothing**, with the reason from a closed set — `런 디렉터리 없음`, `락 대기 초과`, `기준선 불일치`, `프로브 렌더`, `렌더` — and a `warn` on the writer's stderr; the worktree that row names is not on the list until the next non-terminal `segment` row from any segment re-derives it, and that next row does re-derive, because no failure arm records the settled key. The row itself is kept on every failure arm: it is a state transition, and refusing it over a lock a sibling holds or a render that failed would lose the transition to a condition the writer did not cause. The current surface is what `RUN_DIR/surface-digest` holds, never what the last row says. `인가면=생략(행 길이)` means the rewrite did happen and only the value was left off the row (§3.1a); a failure marker is never rewritten as `생략(행 길이)`, because that spelling asserts a rewrite that did not happen. Every path the list carries is emitted in both spellings, as the row wrote it and as `pwd -P` resolves it, because the harness compares directories as strings and a worktree reached through a link is touched by either.

> **Old wording** (for re-deriving citations): "and when that function yields different bytes the gate rewrites, re-baselines, and appends a `대상 추가` row naming what widened. That row is a record, not an input. The ledger's growth is not an input either: only a new worktree value moves the derivation, so the call after the one that wrote a segment row — normally that segment's dispatch — widens the list before the stage starts." — The trigger moved from the next call's prelude to the row itself, and the record moved from a `대상 추가` row to a field on the `segment` row, for two reasons that can each be checked in `gate.sh`. First, the prelude re-derivation ran after the caller's snapshot digest had been taken and before `gate_verb_act`'s staleness check read it, so the call that widened invalidated its own caller's digest. Second, the `대상 추가` series means "a repository joined the run" — `gate_undeclared_target` writes it with an actual alias and remote, and `feed.sh` renders it as such — and the rows the re-derivation appended there carried `별칭=-` and every target field as `-`: nothing refused them (the manifest census, `manifest_targets` in `run.sh`, reads the manifest alone and never saw them), but they put a non-target on the target-shaped series and every reader of that series had to know to skip them.

Nothing but a row written through the gate moves the list. A manifest edit, a row planted past the gate, or an act on a segment whose row already exists all leave it where it was until the next non-terminal `segment` row; a worktree that has been removed leaves the list at that same moment, because the derivation keeps only directories that exist. **Before the first `segment` row the surface is exactly the manifest's**: every declared target's main and execution worktree, the run directory, the document directories and the plugin directory — zero segment worktrees. Kickoff, a shift launch and a run that never segments all run on that set. **The re-derivation runs only from a baseline that still matches.** If the surface has already moved, the gate does not repair it: repairing would erase the evidence the surface check reads, and an edit by anything that is not the gate still lands as exit 7.

The widening is bounded by check, not by claim — a non-terminal `segment` row whose `워크트리` carries a double quote, a backslash, a pipe or a control byte, or is not an absolute path, not an existing directory, or not a worktree sharing some declared target's common git directory is **refused at write time** (exit 2), so the ledger never carries a live row naming a directory the settings could not admit. Every directory the list can add is therefore inside a worktree of a target the run already acts in — **inside**, because the check is on the common git directory and a subdirectory of an admitted worktree shares it. The byte condition exists because the row grammar maps a newline to a space and a pipe to a slash while the settings file is line-delimited JSON. The set is closed by an invariant rather than by a list: on every accepted non-terminal row, the `워크트리` the row carries and the entry the settings admit are the same bytes. The renderer escapes each entry as well, so neither half stands alone. Nothing there grants a cutpoint, and the cutpoint is what governs whatever leaves the machine. **Terminal rows — `완료`, `머지됨`, `park` — are exempt from all three**: the boundary check, the re-derivation and the field. A terminal row naming a directory that no longer exists is the ordinary shape and is recorded as written; the vanished path then leaves the list at the next non-terminal row.

**`실행 워크트리` is optional and exists because one field could not carry two duties.** `메인 워크트리` is pinned to the main worktree so that N linked worktrees of one repository converge on one sidecar location, but the act has to run where the branch actually **is**, and for a `pr` or `branch` anchor that is never the main worktree.

So the sidecar path reads `메인 워크트리` and the act's working directory reads `실행 워크트리`, falling back to the main worktree when the row declares none. A declared execution worktree is verified against the **same** common git directory: one in another repository would be a second target wearing the first one's cutpoint.

An act carrying `--segment` runs in **that segment row's `워크트리` first**, when it passes the same predicate (absolute, existing, same common git directory as the target); the target row's `실행 워크트리` and then `메인 워크트리` are the fallback. An approval's binding tuple is frozen and compared against that same directory. A `--kind skill` dispatch whose segment row names a worktree that fails the predicate is refused with exit 10 before the stage starts — falling back silently to the target's tree is the defect this replaces.

**The `사전 인가` rows are the list an irreversible act is checked against**, and
they are rows rather than a field because the set is open and each entry carries
its own reason. `형태` is an argv **prefix** — `gh pr`, `git push`, `terraform
apply` — matched against the first two words of the act, so a row grants a
family of acts rather than one spelling. An external-state act with no matching
row is **not refused**: it issues an approval and waits, because nobody being
awake to ask is not the same fact as the answer being no.

An act at or below `워크트리쓰기` needs no row at all — the list exists for the
acts whose effects outlive the run directory.

**The `자동 채택` rows are the other pre-declaration, and they name a JUDGMENT
CLASS rather than an argv shape.** A judgment carrying a class one of these rows
declares clears the auto-adoption floor's first arm and is taken without asking.
The safety argument is that **a run cannot write this input**, and it rests on
three things that are each true rather than on a list that reads well:

1. **`## 인가` is exactly one section, and the floor reads only that section.**
   Both consumers — the floor's first arm and the freeze-time class check —
   scan that one section, so the uniqueness guarantee protects the bytes that
   are actually honoured. A whole-file scan did not inherit it.
2. **The binding digest serializes these rows** (see above), so appending one
   moves the digest and the manifest check refuses at the next gate entry.
3. **The gate refuses an act that writes the manifest at all**, at any cutpoint,
   the same way it refuses a write to the authorization record. The manifest now
   carries the same kind of value the grant does, so it gets the same guard.

What is **not** claimed: "the manifest has no append form" describes the kickoff
writer, not the file. Nothing about the format prevents a line being appended —
what prevents it is (3), and what catches it if (3) is bypassed is (2). And both
sides of the digest comparison are read from the same file, so there is no
anchor outside it: a coordinated rewrite of the row and the digest field is
detected by nothing here. That residual is real and is stated rather than
covered by a fourth reason.

`판단 부류` is checked against the closed vocabulary at freeze time, and the ones
that hand risk to the user — `팀-구성`, `시각-면제` and `설계-골격` — are a **hard
stop** here. The count is deliberately not written down: `JUDGMENT_CLASSES` is
the single source, a lint compares every placeholder numeral in this tree against
it, and a number spelled here in prose is a number that lint cannot reach.
The check lives at freeze time because the manifest is written while a person is
present.

**The forbidden pair is refused at runtime as well**: the floor rejects both
forbidden classes before either arm, and the disposition is **escalation** rather than refusal — recording a judgment of that
class stays permitted, and only pre-adopting it is forbidden.

`심각도 상한` is a **convenience filter over a label the audit supplied, not a
floor.** The floor is the union; a document-producing stage has no unforgeable
severity predicate, and non-critical findings mostly pass because they are mostly
reversible rather than because of their grade.

**The `설계 로스터` rows are the design team a person approved at kickoff**, one
member per row, and a design stage dispatched by the run instantiates its team
from exactly these rows. They are written only when the graph carries a team-tier
design stage. **They do not reuse `사전 인가`.** That list is the one an act is
checked against, and a roster mixed into it is a row two readers read with two
meanings. **They are row-shaped because a new field would not freeze.** A `## 요소` field
enters neither digest, and a `**키**: 값` line inside `## 인가` enters one only
when the serializer names that field — the same ground `리뷰 정책 상한` records
below — while a row of this shape is
collected into `구속 다이제스트` over the whole file, like the `자동 채택` rows. A
manifest with no such row contributes zero bytes, so no run in flight moves, and
the design stage then instantiates the default roster frozen in its own skill
file. Nothing is chosen at runtime on either path, which is what keeps `팀-구성`
— a class the gate never adopts on its own — out of the stage's hands.

**The interview-record row is spelled as a `사전 인가` row, and it authorizes
nothing.** It carries no `형태=`, and the pre-authorization rule skips a row
without one, so no act matches it. What the spelling buys is that the row is
collected with the other `사전 인가` rows and the record's whole-file hash is
therefore inside `구속 다이제스트`. **What it does not buy is a comparison
against the file.** No gate re-hashes the record at runtime; the claim is that
the hash the person's kickoff took is frozen where editing it moves the digest,
and that anyone can compare the file against it with one `shasum`.

**The example above is fenced with FOUR backticks** because it contains
three-backtick fences of its own; the parser skips fenced spans and survives
nesting.

**`사용자 확인 문면` and `승인 문면` are different things.** The latter approves
the **step graph**; the former grants **authority**. With per-target cutpoints
the authorization is an N-row table, and that table's only human anchor is
`사용자 확인 문면`. Collapsing them promotes plan approval into permission
approval silently.

**`리뷰 정책 상한` is optional on the target row, and its absence reads as
`선리뷰후머지`.** It sits on the target row rather than in `## 인가` because that
is one of the few surfaces where a NEW key actually enters the frozen set: the
freeze covers the `target`, `종료 절`, `사전 인가`, `자동 채택` and `설계 로스터` rows and lines
whose value is literally `켬` or `끔`, and **an ordinary `**키**: 값` line inside
`## 인가` moves neither digest.** The next optional field takes the same care.

**The name deliberately does not share a spelling with the slice's `리뷰 정책`**,
so the comparison's two arguments cannot be silently swapped.

**`## 룰 설정` is the optional seventh section, and its absence is the norm.**
Four things about it, because each has its own way of being got wrong:

1. **No section means every rule is on, and a rule with no key inside the section
   is on as well.** The gate reads only `끔` as false, so a missing key, a missing
   section and any other value all leave the rule enforcing.
2. **The set of admissible keys is derived from the declarations, never fixed by a
   count.** It is exactly those rules whose `.rule` file says `끌 수 있는가: 예`.
   Neither the names nor the number are pinned here, because pinning them would
   create a second list to drift from the catalog.
3. **`켬` on a switchable rule is a positive statement; a key naming a rule that
   cannot be switched off is INERT AND YET HASHED.** The enable check returns for
   those names before it reads any setting, while the binding digest scans the
   whole file for `켬`/`끔` values — so such a key moves the digest and changes
   nothing else. That combination is why condition 13 warns about it rather than
   passing over it.
4. **A `켬`/`끔` line outside the section moves the digest and is not read by the
   gate**, and the same setting written twice inside the section is decided by
   **document order** — the reader stops at the first match.

**No interview question is written for this section.** The default is `켬` and
its absence is normal.

### 2b.2 `check_manifest()` — a conjunction, in order

Without this list the manifest becomes a fresh instance of the defect class
this whole change exists to remove: a field that is computed and recorded but
never compared.

1. **kind token** equals `cc-run-manifest v1` exactly.
2. **exactly one `## 인가` heading.** There is no append form, so a second block
   is unreachable on any normal path — its presence is tampering, not residue.
3. **`origin-worktree=`** matches the current worktree root, or is absent
   (absent is fail-open — it discriminates between files that have *already*
   proven ownership).
4. **Target preflight** — every target row's main worktree exists and its common
   git dir matches the declared value, and where the row declares an `실행
   워크트리` that directory exists and reports the **same** common git dir. A
   declared repo set with no verification leaves the silent-`.`-fallback alive.
   A mismatch is a **hard stop before the driver starts**, not a park.
5. **Target-map digest** matches the canonical serialization of the target rows.
6. **`구속 다이제스트`** matches the frozen set — goal, termination clauses,
   target rows, rule settings, pre-authorization rows, auto-adoption rows, design
   roster rows, the cost ceiling and stagnation bound when declared, deadline. The PLAN is not
   in it: the router decides the step graph one act at a time, so a frozen plan
   would be recorded and never compared.
7. **Every cutpoint token** is in `CUTPOINTS` — an unrecognized token is a hard
   error, never a silent zero.
8. **`벽시계 마감` parses as an absolute timestamp.** `없음` is refused: a field
   comment saying "required" means nothing if a validator accepts the absent
   value, so the outermost bound holds here or nowhere.
9. **`적용 주체: 파이프라인` requires `적용 지점` and `적용 프로브`.** An apply
   with no probe is refused at kickoff. (`적용 명령` is a *slice* field, not a
   manifest field, so it cannot be checked here.)
10. **`run-id=` and `anchor-key=` headers exist and match the body.** These are
    **fail-closed**: `origin-worktree=`'s fail-open tie-break is only sound
    *between* files that have already proven ownership, so removing the proof
    and keeping the tie-break inverts the order.
11. **Every `자동 채택` row's `판단 부류` is in the closed vocabulary**, and the
    ones that hand risk to the user are a hard stop (see §2b.1).
12. **`리뷰 정책 상한` on the target rows, in three branches.**
    (a) A token outside the review-policy vocabulary is a **hard stop**.
    **Absence is not a violation** — it reads as `선리뷰후머지`, which keeps every
    earlier manifest valid with no migration.
    (b) A target whose cutpoint is below `머지` and which declares a ceiling anyway
    gets a **warning** and the run continues: the value is inert there, and "not
    checked" and "checked and inert" must not read the same in the log.
    (c) If `## 요소` declares `적용 주체: 파이프라인` and **any** target's ceiling
    is `리뷰없음`, that is a **hard stop**: the apply would be held by a rule the
    manifest cannot turn off, so the run could not end. It is conservative
    **by necessity**, since which target receives the apply is not derivable here.
13. **`## 룰 설정` keys naming rules that cannot be turned off** get a **warning**
    rather than a hard stop, because such keys already sit in frozen manifests and
    a manifest has no amendment form.

14. **`dev 식별자` on the target rows** — every element is `<종류>:<값>`, the kind
    is one of `aws-profile` · `aws-account` · `kube-context` · `host` · `domain` ·
    `dir`, an `aws-account` is twelve digits and a `dir` is absolute. Each
    violation is a **hard stop**, and absence of the field is not a violation: it
    is the default, and it means the run believes a stage's `dev` claim. A typo
    would read at runtime as that absence, which is why this refuses rather than
    warns.
15. **`배포트리거 식별자` on the target rows** — same shape, kinds `branch` ·
    `workflow` · `jenkins-job` · `argv`, a kind outside that set is a **hard
    stop**. One arm is a **warning** instead: a `branch` trigger on a target whose
    cutpoint is below `push` is inert rather than wrong, and "not checked" must
    not read the same as "checked and inert".

**Both warnings fire at most once per run.** This whole conjunction re-runs on
every gate entry, so a per-entry warning buries the morning report under its own
repetitions. The suppression is a sentinel file per warning kind under the run
directory. This check runs **before** the run directory is initialized, so when
that directory cannot be created the suppression **fails open** and the warning is
emitted unsuppressed — a duplicate is cheaper than a loss.

4·5·6 are the **verification points**. Without them fields 3·5·6 ship computed,
recorded, and never compared.

### 2b.3 Identity — what used to come from the document

| Today (document-derived) | After (manifest-derived) |
| --- | --- |
| `SLUG` = document filename | **Deleted from the identity notion.** The one exception is the audit sidecar path the artifact predicate reads: the shared contract fixes that to the **document key**, so it does not move to the run id. That is the boundary between run-derived state and document-derived state |
| `BASE`·`GRANT`·`LEDGER` from `derive_paths()` | **Manifest-derived.** `BASE` is derived **from** `origin-worktree=` — it is not equal to it: the driver asks that directory for its common git directory and takes the **parent**, which is the repository's main worktree root. In an ordinary checkout the two are the same string; **in a linked worktree they are not.** `GRANT`·`LEDGER` from the run id, under that `BASE`. Without these three the path derivation cannot produce anything at all when there is no document |
| run key = document key | **`런 id`** = `<UTC date>-<8 hex>`. The primary key; ledger, report, worktree paths and branch names all derive from it |
| finding key = document path | **`앵커 키`**, with the domain fixed by `앵커 종류`: `doc` → document key, `repo` → `<owner>/<name>`, `pr` → `<owner>/<name>#<n>`, `branch` → `<owner>/<name>@<branch>`, `intent` → first 12 of the intent text's sha256 |
| `session_uuid` = `owner-doc\|구간\|단계\|시도` | **`런 id\|구간\|단계\|시도`.** Without a run term, two runs of one document aliased onto the same uuid — and therefore onto the same transcript |
| worktree·branch = slug-derived | run-id-derived, which is what finally makes the teardown guard's claimed depth hold |

**The kickoff must fold `BASE` the same way the driver does, and the row above is
the only place that is written down.** Read as an equality it says
`BASE = origin-worktree`, and a kickoff that follows it puts the authorization
record, the report stub and the watcher's `--ledger` argument in the document's
own worktree while the gate writes the ledger under the main one — a split
nothing reports. `§1.1` of `sidecar.md` explains **why** the fold exists.

**Per-target cutpoints and terminal-act caps live in the target rows.** A single
totally-ordered scalar cannot say "apply for infra, stop at PR for the
frontend" — not awkwardly, but at all. `런 최대 절단점` is a derived audit field
and `authorized()` does not read it; two gates that can disagree are not built.

**`벽시계 마감` is an absolute timestamp and a dispatch gate**, never an elapsed
accumulator: an accumulator that resets binds nothing, and only an absolute
stamp stays correct across a reboot.

**And it is now the FALLBACK bound rather than the primary one.** The clock
measures elapsed time, and the thing worth stopping is pointless spinning, so a
run that declares a progress-axis bound is judged on that bound and the clock
has no say over it. The clock still gates dispatch and merge for a manifest that
declares no such bound, so those runs are not left with nothing at all.

**`비용 천장` carries TWO thresholds.** At 80% it opens a boundary approval — a
person, if there is one, decides. At 100% it ENDS the run, because an approval
nobody answers is not a bound and the state this design targets is the one where
nobody is awake to be asked. **Digits only**: a value carrying a currency symbol
or a unit is not a figure the boundary's arithmetic can read, and the gate says
so and declines to enforce rather than silently treating the run as bounded.

**`무진전 상한` is the second progress axis, and it exists because the first
boundary on this axis can only ask.** B1's approval, while it waits, suppresses
B1 itself; the declared bound counts the same number outside that suppression
and ENDS the run when it is reached. An integer:
a value that will not read as one is warned about and not enforced, the same
disposition the ceiling takes.

**Both are optional, and a run that declares NEITHER keeps the wall clock** — see
the deadline note above for why that fallback exists and why it is narrow.

**`공통 git 디렉터리` is on every target row because of a hazard in this very
tree**: two working trees here share one `.git` and one `refs/stash`. Inferring
identity from a basename hands one namespace to two aliases silently, and the
consequence — stash attribution is per-REPOSITORY, not per-worktree — has to be
visible in the manifest rather than inferred.

### 2b.4 Compatibility is absorption, not a grace period

The manifest is the only schema. A call that supplies only a document is
absorbed as the **degenerate case**: one document, one target. No grace period,
no dead code.

**The population is not zero.** Re-count by listing `<base>/docs/pipeline-grant/`
and `<base>/docs/pipeline-run/` **on disk**, never from git (`docs/` is
git-ignored here).

What carries the compatibility argument is a property rather than a count: **an
absent optional field moves neither digest**, so every run in flight stays
conforming with no migration.

### 2b.5 The interview record — what the design stage cannot ask for

````
# 파이프라인 런 인터뷰 기록 — <run-id>
<!-- cc-run-interview v1; writer=autopilot; reader=design-discuss-unattended (driver dispatch) and the morning report; run-id=<run-id>;
     NOT a design doc; mechanism-local, never staged by a skill -->

## 과제
<과제 문면, 축자>

## 요구사항 문답
### 문 1
<질문, 축자>
### 답 1
<답, 축자>

## 배포 형상
**레포**: <답> | 없음
**슬라이스 수**: <답> | 없음
**적용 위치**: <답> | 없음
**적용 주체**: <답> | 없음
**실패 시 파킹**: <답> | 없음

## 재현 근거
<사람이 가리킨 재현 절차와 관측> | 없음

## 검증 선결
<설계 전에 참으로 확인돼야 하는 전제> | 없음

## 골격 사전 판정
<사람이 바꾸면 안 된다고 말한 것> | 없음

## 로스터
매니페스트 `## 인가` 의 `설계 로스터` 행을 따른다 | 없음(기본 로스터)
````

Written by the kickoff when the run's plan requires a design and the interview was
held — once, whole, **creation-only, with no append form**, the posture of the
manifest. Its whole-file `sha256` is taken immediately and enters the manifest as
the interview-record row of §2b.1. The question-and-answer pairs repeat as many
times as the interview had turns, numbered in order. **`없음` is a value**: a
section with no answer carries it, and an omitted section is a different fact.

**Every answer is verbatim.** The record is the disk anchor for the requirement's
own words, kept apart from the kickoff's reading of the person.

**It does not carry the roster.** The approved roster lives in the manifest's
`설계 로스터` rows and is frozen there; this record only refers to it.

**What reads it, and how it finds it.** A design stage dispatched by the run
opens this file and takes it as the requirement input for the discussion. It is
found by **path convention, not by argv**: the stage already holds
`CC_PIPELINE_RUN_ID` and the manifest's path, and this record sits beside the
manifest's own directory under that run id.

**The hash is re-taken and compared, and a disagreement is a halt.** The stage
takes the whole-file `sha256` and compares it against the interview-record row of
§2b.1. Three states stop it before the team spawns: the two values differ, the
row exists and the file does not, or the file exists and the row does not. When
**neither** the row nor the file is there the stage runs from the task sentence
and `## 의도` alone.

## 3. `cc-pipeline-run v1` — the run ledger

```
# 파이프라인 런 원장 — {slug}
<!-- cc-pipeline-run v1; writer=orchestrator; reader=orchestrator; owner-doc=<document key>[; origin-worktree=<absolute worktree root>]; NOT a design doc; mechanism-local, never staged by a skill -->
```

### 3.1 Blocks and rows

Block 0 is `## 계획 <run-id>` — the plan record written when the run starts. Every later block is `## 실행 <run-id>` and holds **rows**. A row is one line:

```
- `<계열>` | <필드>=<값> | <필드>=<값> | …
```

Values containing `|` or a newline are fenced per `sidecar.md` §2.5 and the row carries the fence's info string instead of the inline value.

**Every row carries `교대=<n>` as its first field after the series name.** `<n>` is the number of the routing shift that was current when the row was written, counted from `0` for the lead's own seat, so any row answers how many shifts had run. `0` stays the lead's own seat for as long as the run lasts, because the seat is read from the writer's own shift marker rather than derived from how many shifts the ledger has seen.

**An attempt that launched nothing consumes no ordinal.** The launcher writes its `교대 기동` row immediately before starting the successor, so a shift held behind a live stage and one stopped at the handoff floor both leave the scale where they found it.

### 3.1a Row length has a hard cap

**A row is at most 1024 bytes including its newline.** Above that, concurrent appends interleave field values undetectably, which is why the cap is a lint rather than a convention.

Two consequences the schema carries rather than leaving to callers. Long values — a declared file set, a question text, an answer text — are fenced per `sidecar.md` §2.5 or moved to a sidecar, never inlined. And the `prev=` chain field of §3.4a spends roughly 70 of those bytes, so the budget a writer actually has is smaller than the cap suggests.

**One field, and only one, is relaxed under the cap: `segment.인가면`.** It is 144 bytes on the row — separator, name, two sha256 hexes and the arrow — and the rows it lands on are the planning rows that already carry a long `선언 파일 집합`, so the worst row and the field meet. A `segment` row that would cross the cap with the field lands **without** it, carrying `인가면=생략(행 길이)` instead, and without even that when the marker does not fit; the settings are rewritten either way, and what degrades is the record, never the widening. A failure marker (`인가면=실패(<사유>)`) that would cross the cap is dropped outright rather than rewritten as `생략(행 길이)`; the `warn` the arm already emitted is the record then. This is not a general rule: every other series decides for itself what it may drop, which today is nothing.

### 3.2 The row series is closed at twenty-one

> **Former heading** (kept here so existing citations still land): `### 3.2 The row series is closed at fourteen`, then `### 3.2 The row series is closed at fifteen`, then `### 3.2 The row series is closed at sixteen`, then `### 3.2 The row series is closed at seventeen`, then `### 3.2 The row series is closed at eighteen`, `### 3.2 The row series is closed at nineteen` and `### 3.2 The row series is closed at twenty` — `handoff` arrived as the fifteenth kind, `의무 종결`·`의무 포기` as the sixteenth and seventeenth, `교대 기동` as the eighteenth, `경계 억제` as the nineteenth, `pace` as the twentieth and `계측 필링 건너뜀` as the twenty-first. A heading that states a count states a falsehood the moment the count moves, and it has moved seven times; every one of those spellings is kept here rather than replaced so a citation written against any of them still lands.

**A writer that needs a kind not on this list extends this definition; it does not improvise one.**

An approval and a deferred review obligation are **non-terminal states with their own lifecycle**, which is why they are series of their own rather than an overloaded `자율 승인` or `blocked`.

**`교대 기동` is the record of a successor's start itself**, written immediately before it, and it is what the shift ordinal is counted from; `handoff` and the authorisation row do not say a successor started. Its `서수` is the number of the shift being launched, which is deliberately not the same quantity as the `교대` seat every row carries: the seat says who did the launching.

**`경계 억제` records a suppression, which is frequent and otherwise silent.** It may not be written to `blocked`, because the obligation boundary reads `blocked` — **the load-bearing property is a property of the NAME**: no boundary reads it. `크레딧 잔량` is on the row because the suppression is bounded.

**`pace` records what the run saw of a pacing verdict that lives outside the run.** It is written by the gate on the record path of `act` and `exec` — immediately after the `자율 승인` row, and never by `snapshot`, which is a read and stays one — and only when the verdict differs from the last `pace` row of THIS run's ledger, or when the run has none yet; the basis is run-scoped so the 8-row ancestry window carries a `pace` row. An absent, unreadable, foreign-schema or stale state (older than three sensor periods, 180s) is written as `판정=(미상)` with `기준 틱=-` and `관측=-` rather than skipped — the row says the gate looked and found no verdict, which a reader has to tell apart from the gate never looking. **Two closed token sets, never mixed**: `판정` and `이전` take the sensor's verdict vocabulary (`가속` · `유지` · `제동` · `(미상)`), and `사유` takes the sensor's reason vocabulary (`brake` · `idle` · `lanes-below-target` · `default` · `tracker-skip` · `truncated` · `(미상)`); a dispatch refusal clause (`lane` · `window` · `burn` · `brake`) is a third vocabulary and belongs to `fleet.sh`'s own refusal log, not to this row. With `pace` the series counts twenty.

**`종료 절` and `문서 해시` are listed with the fields the gate actually writes**, because a table that under-reports its writer's series is not a closed definition.

**`의무 종결` and `의무 포기` are the exits of a `problem` obligation.** They are separate series rather than one with a state field because they differ in **tense**, and the tense decides when each is checked: `종결` cites a past act row and is never re-verified, `포기` cites a segment being terminal — a reversible, present-tense fact — and is re-verified every time the open set is computed.

Both carry a derived `의무 id` (`PO-<8 hex>` over the run id and the free-text identity) that the reader computes rather than the writer stores, so a `problem` row written before these series existed is closable with no migration. Neither carries the identity verbatim: §3.1a's 1024-byte cap makes unbounded free text unsafe on a row, so `표시 동일성` is a truncated label that **no predicate reads**. `세그먼트` is inherited from the row being closed and never accepted from argv, the same discipline `리뷰 의무` already applies to its carried fields.

| `계열` | Fields |
| --- | --- |
| `run` | `run-id` · `시작` · `설계 문서` · `전체 sha256` · `구속면 다이제스트` · `강제 코드` · `베이스 청결` · `판본` · `판본 트리` · `판본 다이제스트` · `RUN_DIR` · `보고서` |
| `generation` | `세대` · `전체 sha256` · `구속면 다이제스트` · `세그먼트 계획` · `segmentation`(`ok` \| `low-confidence`) |
| `segment` | `id` · `선행` · `선언 파일 집합` · `plan-binding-digest` · `상태` · `브랜치` · `PR` · `커밋` · `사전 HEAD` · `베이스 sha` · `워크트리` · `리뷰 정책`(optional) · `인가면`(optional, gate-written: `<sha256>→<sha256>` \| `생략(행 길이)` \| `실패(런 디렉터리 없음)` \| `실패(락 대기 초과)` \| `실패(기준선 불일치)` \| `실패(프로브 렌더)` \| `실패(렌더)`; absent means this row widened nothing, a `실패(…)` value means the re-derivation did not land and the next non-terminal row re-derives, and `RUN_DIR/surface-digest` is the current surface either way; never on a terminal row; a caller-supplied value is refused) |
| `stage-result` | `세그먼트` · `스테이지`(S-id) · `종류`(stage kind) · `종료 코드`(`-` on a settlement row) · `plan_sha256`(`implement` only) · `실행 버전` · `세션 id` · `부모`(`-` on a settlement row) · `압축 창`(effective compaction window and its source: `-` \| `(꺼짐)` \| `(미상)` \| `<정수>(argv\|런설정\|프로젝트\|레인)`) · `레인`(config home, tilde form) · `기록자`(`게이트` \| `드라이버`) · `종단 부류` · `관측`(settlement row only) |
| `cycle` | `세그먼트` · `사이클` · `리포트 경로` · `리뷰 HEAD` · `P0` · `P1` · `P2` · `P3` · `lane 결정` · `모드`(optional: `전체` \| `델타`; absent reads as `전체`) · `기준 사이클`(optional; required iff `모드=델타`, refused otherwise) |
| `problem` | `세그먼트` · `동일성`(`정규화 경로` + `카테고리 태그`) · `현재 단` · `단 이력` · `생성 등급`(축 2) · `payload`(근본 원인 문구) |
| `자율 승인` | `kind` · `판단 부류` · `결정` · `대상` · `세그먼트` · `절단점`(adjudicated rung) · `유도 절단점`(rung derived from argv \| `-`) · `축2` · `기각된 대안` · `근거` · `등급` · `기준` · `되돌리는 법` · `자격`(`분리` \| `주변`) · `행위자`(`리드` \| `교대` \| `스테이지`) · `해소 승인`(승인 id \| `-`) · `출처`(`스테이지 방출` when absorbed from a stage's terminal line) · `finding-id`(required iff `kind=severity`) · **exec only**: `등급 출처` · `선언` · `표지` · `파괴 출처` · `도달` · `유도 도달` · `식별자 대조` · `행위 다이제스트` · `argv`(excerpt, remainder-sized) |
| `cost` | `누적 usd` · `스테이지 수` · `관측 시각` |
| `blocked` | `대상` · `스코프`(act\|cone\|run) · `원인`(막힘\|무효화\|불명\|판정 불가\|해소) · `사유` · `근거` · `앵커 세그먼트`(scope `cone`) · `의존 세그먼트 수`(scope `cone`) · `의존 세그먼트`(scope `cone`, clipped) · `관측` · `재개 명령` · `도달 판정`(도달 park 행 전용) · `세그먼트`(같음) · `스테이지`(같음) · `축2`(같음) · `도달`(같음) · `행위 다이제스트`(같음) |
| `승인` | `승인 id` · `상태` · `대상` · `절단점`(adjudicated rung) · `유도 절단점`(rung derived from argv \| `-`) · `행위 다이제스트` · `구속 튜플` · `막는 세그먼트` · `질문 문면` · `답변 문면` · `사이드카 앵커` · `발행 시각` · `해소 시각` · `응답 토큰`(closing rows) · `답변 다이제스트`(closing rows) · `사유`(`철회` only — written by the boundary evaluation that withdraws) · `처분 사유`(a `대기` row appended after a free-input answer, which auto-resolution then leaves open; `자동 해소` on a closing row the gate wrote itself) · `관측 시각`(the free-input row) |
| `리뷰 의무` | `의무 id` · `상태` · `세그먼트` · `대상` · `머지 커밋` · `생성 등급`(축 2) · `이행 판정`(fulfilling row) · `근거`(fulfilling row) · `발행 시각` · `이행 시각` |
| `대상 추가` | `별칭` · `원격 슬러그` · `메인 워크트리` · `공통 git 디렉터리` · `베이스 브랜치` · `층`(0\|1) · `발견 경로` · `기록 시각` |
| `종료 절` | `id` · `상태`(충족\|불가능\|보류) · `근거` |
| `문서 해시` | `스테이지` · `sha256` · `동결값` · `관측` |
| `handoff` | `교대` · `대상` · `사유` · `버린 선택지` · `막힌 지점` · `다음 후보` · `기록 시각` |
| `의무 종결` | `의무 id`(`PO-<8 hex>`) · `표시 동일성`(잘린 라벨, 술어가 읽지 않음) · `처분`(`종결`) · `세그먼트`(닫히는 행에서 승계) · `근거` · `처분 시각` |
| `의무 포기` | `의무 id`(`PO-<8 hex>`) · `표시 동일성`(잘린 라벨, 술어가 읽지 않음) · `처분`(`포기`) · `세그먼트`(닫히는 행에서 승계) · `근거` · `처분 시각` |
| `교대 기동` | `서수` · `사유` · `대상` · `기록 시각` · `세션 id` · `레인` · `압축 창` |
| `경계 억제` | `경계` · `사유` · `크레딧 잔량` · `기록 시각` |
| `계측 필링 건너뜀` | `사유` · `세그먼트` · `트리거` · `기록 시각` |
| `pace` | `판정` · `이전` · `기준 틱` · `관측` · `사유` |

**The `run` row's three version fields say what code JUDGED the run, and the two beside them say what code was being judged.** `판본` is the pinned commit (`<40hex>` \| `(미상)` \| `(고정 안 함)`), `판본 트리` the pinned plugin subtree's git tree (`<40hex>` \| `(미커밋)` \| `(미상)` \| `(고정 안 함)`), and `판본 다이제스트` the content digest of the copy itself (`<sha256>` \| `(고정 안 함)`). `(고정 안 함)` is not a failure: a run opened before pinning existed, or one opened under the test seam, is deliberately left unpinned, and a reader has to be able to tell that apart from a pin whose value could not be determined. `(미커밋)` means the plugin subtree was dirty when the copy was taken, so no tree object names those bytes.

**`강제 코드` and `베이스 청결` are about the TARGET BASE, not about the judge** — the base's HEAD at run open and whether that worktree was clean.

**Restoring a pinned version.** When `판본 트리` is a hash, `git archive <tree> | tar -x` in the plugin repository reproduces the copy, and the result's content digest — computed by the same `pin_digest` the pin used — must equal `판본 다이제스트`. That works even when `판본` names a local commit that a later reset removed, because the subtree it points at is shared with its parent. When `판본 트리` is `(미커밋)` there is nothing to restore from: the copy under the run directory is the only one that ever existed, and once the reaper collects that directory the digest identifies the version without reproducing it. **That is a stated residual, not an oversight.**

**The copy's files are NOT part of the enforcement-surface digest.** The exclusion of plugin files from `gate_surface_digest_raw` stays exactly as it was: that digest's mismatch is exit 7, which is unrecoverable, so a false positive there is the incident that exclusion was introduced to prevent. Two write layers already cover the copy — the run hook's allow-list and the gate's own Bash path guard, both of which refuse every name under a run directory that is not a halt record, a segment plan or a witness product.

**This table is held equal to the gate's call sites by `scripts/lint-sidecar-field-table.sh`.** Per series, the union of literal `<키>=` names across every `gate_append '<계열>' …` call must be listed here; where no call site forwards `"$@"`, the listed set must also be written by some call site. `교대` and `prev` are outside the comparison — `gate_append` adds both to every row itself. `stage-result`'s predicate result is folded into `종단 부류`. **No cell carries the `writer pending` marker today, and the mechanism stays written down anyway**: a cell marked `writer pending` is the one shape the lint's reverse direction passes over, and it reports that field by name rather than skipping it silently.

**Every declared series has a writer, except one — and that exception is the rule holding rather than an omission.** A series that nothing writes turns the check reading it into a constant.

They are written from three different places, because the three have different knowledge. `run` is written once at run open, by the gate. `stage-result` and `cost` are written by the gate's detached stage supervisor when a stage terminates, from the stage's **own** terminal result line — its cost, its subtype, its session id — so nothing here depends on a stage reporting anything about itself. `problem` is an `act` kind like `segment` and `cycle`: recognising that a finding is the same finding as last cycle's is a judgment, and the router is where judgment lives.

**`stage-result` has two writers, and the row says which.** The gate's supervisor writes the rows of stages it dispatched (and its prelude the settlement rows), the driver writes the rows of stages it spawned itself and the stage-less apply rows; `기록자=게이트` or `기록자=드라이버` names the one that wrote this row. Both carry `압축 창` — the compaction window the launch read, with the layer it came from — and `레인`, the CLI config home the stage ran under, so a reader can tell a stage compacted under the lane's default from one the gate handed a window on its argv. The layers are read in one fixed order on both paths: the window the gate injects on the argv (`argv`; the driver injects none, so a driver row never says it), the run's per-kind settings file (`런설정`), the stage cwd's `.claude/settings.local.json` then `.claude/settings.json` (`프로젝트`), the lane's `settings.json` (`레인`). The two keys are merged per key across those layers, the way the CLI merges settings: `autoCompactEnabled` is taken from the highest layer that defines it and the window from the highest layer that holds an integer, each on its own. `(꺼짐)` is that highest `autoCompactEnabled` reading false — it wins over the argv value too, and then nothing is injected — `(미상)` a layer whose file exists but could not be read (every layer is read before anything is decided, so an argv value never stands in for a failed reading), `-` no layer at all. The launch leaves the two values in `<seg>.window` beside the pid record so a settlement that runs after the supervisor is gone can still put them on the row — **and that file is never a precondition of anything**: a settlement or a collection that finds it absent writes `압축 창=(미상)` and proceeds, and its presence is not a liveness input. A row with none of the three keys was written before they existed; that absence is a third state and is not read as `(미상)`. The gate injects a window for one stage kind (`review`) today, and `CC_ORCH_STAGE_AUTOCOMPACT=off` switches that injection off for every kind without touching the settings layers. `교대 기동` carries the same `레인` and `압축 창` for the successor routing session, with its `세션 id` to join on; a shift is not a stage kind, so it never gets an argv window.

**`generation` is deliberately still unwritten.** Nothing reads it, so the writer arrives with the reader or not at all.

**The terminal class the gate writes is a strict subset, and the omission is deliberate.** From outside a stage it can distinguish `크래시` (a non-zero status, or a subtype that is not success), `정상 완료` (the stage performed at least one gated act — a `자율 승인` row stamped `행위자=스테이지` for that segment, landing after that attempt's dispatch row; router rows written while the stage ran do not count), `산출물 없는 정지` and `공허한 성공` — the last two separated by whether the stage's own transcript carries a `permission_denials` entry, which is precisely the "trace of reaching a decision point" this contract asks for. `의도된 park` is read from the stage's halt record, which the halt contract owns. `적용 불명` alone is **not** written from here: it is a claim about an apply step's outcome, and its only writer is the driver's apply-outcome-unknown arm.

**`외부 종료` is written by a different path and is defined by an absence.** Every class above presumes the stage emitted a `type=result` envelope and reads that envelope's fields. `외부 종료` is written by the gate's prelude — on every verb but `plan` — when it settles a lost dispatch: a record the gate itself dispatched (`<seg>.kind` present, a non-empty fingerprint, `<seg>.attempt` present) whose CLI process and supervisor are both gone, with no `stage-result` row for that attempt. Its defining check is that no envelope exists, so it is disjoint from `공허한 성공`: a CLI that exits 0 having produced nothing is still reporting, while a process that simply vanished reports nothing. **It is the one class the gate writes about a stage it never classified**, and it does not name which outside force ended the stage. A settlement row carries `종료 코드=-` and `부모=-` (the settler is not the session that dispatched), a prose `관측`, and no accompanying `cost` row — there is no envelope to read a cost from. Exactly one `stage-result` row exists per `(세그먼트, 실행 버전)`: the settlement looks for an existing row before appending, and a driver-spawned record (no `.kind`) is never settled, because the driver collects it itself.

**`segment` and `cycle` have a writer on the router path, and both are `act` kinds rather than a seventh verb.** `act --kind segment` and `act --kind cycle` take **`키=값` fields after `--` instead of a command**, because what they perform *is* the row; they grade `읽기`, since a row reaches nothing a cutpoint or a credential could widen. A `segment` row is refused without a `상태` in the vocabulary below and without a `워크트리` — the merge rule enters that directory to read the branch's current HEAD, so a row missing it turns a review refusal into one that names a missing worktree. A row in a non-terminal state is further refused unless that `워크트리` is free of double quotes, backslashes, pipes and control bytes and is an absolute path inside an existing worktree of some declared target (§2b.1), and it is the row on which the gate re-derives the stage settings and writes `인가면`; a terminal row (`완료` · `머지됨` · `park`) is exempt from that check and carries no such field. A `cycle` row is refused without `사이클`, `P0`, `P1`, `리뷰 HEAD` and `리포트 경로`, which are exactly the five that rule reads — the last one because the rule opens that file and looks for a findings summary, so a row whose report is a stub is refused rather than believed.

**A `cycle` row may carry `모드` and `기준 사이클`, and a delta claim is refused at write time on eight checks.** `모드` is optional and **absence reads as `전체`** — in the gate's basis search, in the snapshot's `cycles[]` consumer, in the router and in check 8 alike. A delta review read only the files changed since this segment's last full cycle and re-adjudicated that cycle's P0/P1, while the merge rule reads `P0`/`P1` off the newest row without knowing the mode, so everything that makes the claim sound is refused before the row exists rather than believed after it. **Checks 1–7 run only on a `모드=델타` row** (check 1 whenever the field is present at all): (1) `모드` is `전체` or `델타`; (2) `기준 사이클` is present and a positive integer — digits only, compared everywhere below **by integer value**, so `04` and `4` name the same cycle — and the row's own `사이클` is an integer **greater than** it, so a delta cannot name itself or a later cycle as its basis; a `모드=전체` (or absent) row carrying a `기준 사이클` is refused, since a full review asserts no basis; (3) a `cycle` row of the **same segment** exists whose `사이클` **equals** `기준 사이클` as a field value — never a `grep -F` substring, since `사이클=1` is a substring of `사이클=10` — and when several rows share the number, the last `전체`/absent one among them is the basis, falling back to the last of them only when none is full, so a delta row cannot shadow the full row beside it; (4) that basis row's `모드` is `전체` or absent, so a delta never stacks on a delta; (5) the basis is the **largest** `전체`/absent `사이클` of this segment by integer value, and the refusal names the one that is; (6) inside the segment's last `segment` row's `워크트리`, `git merge-base --is-ancestor <기준 행 리뷰 HEAD> <이 행 리뷰 HEAD>` exits 0 — exit 1 (not an ancestor) and exit ≥2 or a missing worktree (undecidable) are refused **with different wording**, because folding 128 into "not an ancestor" would read a missing object as merely unrelated; (7) the basis row's `리포트 경로` resolves to a file that exists and matches `^[-*[:space:]]*\*\*발견 요약\*\*`. **Check 8 runs on every `cycle` row**: the row's own `리포트 경로` is opened, the one line matching `^[-*[:space:]]*\*\*리뷰 모드\*\*: (전체|델타)( |$)` is anchored first and the values are read off that line only; no such line reads as `전체`, no `모드` on the row reads as `전체`, and the two must agree; when both say `델타`, the line's `기준 사이클 <n>` must equal the row's `기준 사이클` by integer value, and the line's `` 기준 리뷰 HEAD `<sha>` `` and the basis row's `리뷰 HEAD` must resolve — `git rev-parse --verify <x>^{commit}` in the segment worktree — to the **same commit**, so a short and a long sha of one commit agree and an unresolvable one is refused as undecidable. A report that cannot be opened refuses a `델타` row and passes a `전체`/absent one: no new refusal is added to the existing path, and that absence is what the merge rule already catches at merge time. Check 8 runs on full rows because the dangerous direction is **under-claiming, not over-claiming** — a report that says `델타` under a row that stays silent reads as `전체`, is picked as the next cycle's full basis, and a delta then stacks on a review that read part of the tree. Both sides absent read as the same `전체`, so no row or report written before these fields existed is refused. Every refusal here is exit 2, and **the repair depends on which check refused**. A mode mismatch is repaired by rewriting the row to the mode the report says. Every other refusal of a delta row that still stands once the row's `사이클` is this cycle's number and its `기준 사이클` matches the report line is repaired by **no** row — rewritten as `델타` it meets the same check again, and rewritten as `전체` it meets the mode comparison, because the report still says `델타` — so that refusal's wording says so, and the router re-dispatches the segment's review as a full review without the three basis flags and writes no `cycle` row until a report the gate accepts exists. A relative `리포트 경로` is resolved the way the merge rule resolves it — two directory levels above the manifest — by one helper the gate uses for checks 7 and 8 alike.

**The shape table above carries the fields `gate_record_row` REQUIRES and the fields the rules READ, and it has to carry both.** It is the router's only instruction for what to put on a row: **a field some rule reads that is absent from this table is a rule that cannot fire, and that failure is indistinguishable from the check passing.**

**`segment.리뷰 정책` is optional, and omitting it on a later row is INHERITANCE rather than a reset.** The gate carries the previous row's value forward **at write time**, so every row states the policy in force at that moment and the last row alone answers the question. A value exceeding that target's `리뷰 정책 상한` is **refused with exit 2 and never clamped**: a quietly tightened row is indistinguishable from a conservative one. The carry is on this field alone and deliberately not on `워크트리`, which is required on every row and so cannot be erased in the first place.

**`절단점` and `유도 절단점` are two different claims and are carried as two fields.** `--cutpoint` is what the CALLER said, and the gate also derives a rung from the argv itself — `gh pr merge` and a non-GET `gh api …/pulls/<n>/merge` are `머지`, `gh pr create` is `PR`, `git commit` is `커밋`, `terraform apply`/`destroy` is `배포`, and wrappers (`lockf`, `command`, `find -exec`, `rg --pre`) are unwrapped to whatever they run. `절단점` on the row is the rung the act was **adjudicated** at and `유도 절단점` is what the argv said, `-` where the table has no row for that command. **Declaring below the derived rung is refused with exit 8**; declaring above it passes and the derived rung wins, because labelling every act with the target's cutpoint is the ordinary router path. **`git push`, `git merge` and `git branch` are deliberately not derived** — whether a push IS the merge depends on the refspec's destination, which only the manifest's target row can answer. **A residual, stated rather than hidden**: when the derived rung wins, both fields carry the same value, so an act declared honestly low and one declared high and pushed down read alike on the row — the difference survives only as a `과신고` line on stderr.

**`자격` records which credential each act actually ran under.** With neither pipeline credential provisioned the gate falls through to the ambient one — on a developer machine a full-scope login — and the fallback is kept, and `주변` on the row is how the morning tells a run that had the separation from one that only appeared to.

**`행위자` records which seat wrote the authorisation row — `리드`, `교대` or `스테이지`.** Nothing else on the row could: `교대=` is `0` for the lead and for a stage alike (it reads only the shift marker), and no guard stops a stage from calling `act --kind skill`. The progress vector's `dispatches=` component reads this field to decide whose dispatches count: it counts `stage-result` outcomes (`정상 완료` · `의도된 park` · `산출물 없는 정지`) only for a segment whose dispatch authorisation row carries this field with a value other than `스테이지`, which is what keeps the constrained side from writing its own progress — and the authorisation row alone, which lands before the launch, moves nothing. The act budget's spend count reads it the same way. A row written before the field existed carries none and contributes nothing — the safe direction. The field does not replace the runtime judgment (the gate reads the seat markers from the environment at judgment time).

**`승인` advances by appending, never by editing** — the same discipline `segment.상태` already takes (§3.4). A row carries the `승인 id` it advances; readers take the last row for an id as current. Everything needed to re-issue the question after a session cut is on the row.

**`절단점` on a `승인` row is not always a cutpoint token.** Three shapes share the series because they share the lifecycle: an **act** approval carries a `CUTPOINTS` token and a binding tuple of `(대상 별칭, 슬러그, 행위 토큰, argv 다이제스트, 브랜치, head_sha, base_sha, PR 번호, 리뷰 리포트 다이제스트, 열린 P0·P1)`; a **judgment** approval carries the literal `판단` and a tuple of `(스테이지 id, 질문 문면 다이제스트, 선택지판, 스냅숏 다이제스트 앞 12자)`; a **boundary** approval — issued by B1–B4, which have no act at all — carries the literal `경계` and a tuple of `(경계 이름, 그 경계 술어가 자기 안에서 계산한 결속값)`. Staleness is re-derived at execution against whichever tuple the row carries, so the three do not need three series.

**The judgment tuple is serialized into the one `구속 튜플` field as four `/`-separated components** — `<세그먼트>/<질문 전문의 sha256>/<선택지판>/<스냅숏 다이제스트 앞 12자>`, e.g. `S2-slice-A/3f1a…(64 hex)/v1/298c3e07b3c6` — the same shape the act tuple already takes, and no separate `질문 다이제스트` or `선택지판` field exists. The question digest is of the FULL question text, which the approval sidecar (§3b) holds under the block the row's `사이드카 앵커` names, so the row's digest has something to be compared against. `선택지판` is a version token (`v1`) rather than a digest, because the option set is a compile-time constant of the gate; it says which menu the row MEANT. It does not prove what a person saw; that comparison is made at close, by re-deriving the labels from the gate's table and matching them against the transcript's `options[].label`. Where the segment is unknown the first component is `-`.

**The boundary tuple's second component is the value the boundary's own predicate read** — B1 the progress digest, B2 the digest of the obligations its count is waiting on and that are not yet disposed (the ones open when the count last restarted, less every identity in the disposition latch — so a new identity opened and closed again, or a parked segment toggled, does not move it), B3 the act-budget window key (the progress vector with `acts=` removed; the vector carries no obligation component), B4 the progress digest until a bucket width is decided — and the approval id is `<경계 이름>-<sha256(RUN_ID + 경계 이름 + 결속값) 앞 8자>`. `RUN_ID` stays in the salt so the same condition in two runs does not share an id. There is no clock component: `발행 시각` is the only time on the row. Duplicate suppression is "the last row for that id is `대기`", not "any row exists" — a resolved id re-opens with a fresh `대기` row when the same binding value recurs, and the row sequence says what happened to it.

**A pending approval has two ends, not one.** `무효` is reachable through the same transcript binding as `승인`, so a person can answer *this should not have been asked* without also granting the act. Voiding **removes a blocker**, so it does not get a looser gate — it keeps the requirement that the answer be a real answer frame in the harness-written transcript.

**The transcript binding is by FRAME, not by text.** The line that closes an approval must be the `tool_result` of an `AskUserQuestion` call whose question carried the approval id (joined through `tool_use_id` to the `tool_use` block in the same transcript) and must hold the harness's `toolUseResult.answers` map, in which the question text is the key and the person's choice is the value. The id is looked for by containment anywhere in the question text. Nothing else qualifies: not the router's own Bash output echoing the ledger, not another tool's result, not an `is_error` frame (a dismissed dialog — the harness's text `The user doesn't want to proceed with this tool use` — or a collapsed call; the two get different warnings because they are opposite evidence about whether a person was present, and the first is called `다이얼로그 취소`, never `기각`, which is a state token). An ineligible frame, a torn last line, or a line that carries the id and is no frame at all leaves the approval `대기` and writes **no row**. Between two answer frames for one id the later one wins, and the search stops at the first lineage transcript holding one.

**For a `절단점=판단` approval the answer is read by label equality against the gate's own label set, never by scanning prose.** The gate owns the labels (`승인` · `거부` · `무효`) and the router renders them verbatim; the person's choice is compared whole-string, in **normal form** — the label with everything from its last ` ← ` onward removed, because the AUQ authoring rule marks the recommended option by appending ` ← 추천` to the label itself — and a menu whose normalized labels are not exactly the gate's set is refused before any answer is read. An answer equal to a label closes the approval with that state. **An answer equal to no label is FREE INPUT and is neither a grant nor a refusal**: the approval stays `대기`, the answer's full text goes to the approval sidecar only, and a further `대기` row is appended carrying `처분 사유=자유 입력` (or `슬롯 부재` when the frame's question slot has no entry in the answers map), `응답 토큰`, `사이드카 앵커` and `관측 시각` — and NO answer field, because `gate_approval_field` returns the last value a key ever had, so an answer on a `대기` row would read to every later reader as an answer with no mark of its status. `close` exits 5 on that path, not 0: 0 means resolved. `--void` and `--reject` may only agree with the label the person chose; a flag against it is refused. Act and boundary approvals have no menu and no label set, so for them the frame decides and the closer's flag is the disposition, as before.

**`질문 문면` and `답변 문면` are excerpts; the full texts live in the approval sidecar.** A row must stay inside the row-length cap of §3.1a, and a question with four option descriptions does not. `질문 문면` is clipped to 400 bytes on every row that carries it; `답변 문면` on a judgment approval's `승인`·`거부`·`무효` closing row is clipped to 160 bytes (the `무효` closing row is the thinnest and keeps roughly 61 bytes of headroom); `사유` on a `철회` row to 120. Both clips are normalized before they land — `|` and newlines would splice the row grammar — and cut with a visible marker rather than silently. Beside each excerpt the row carries the sha256 of the full text (`구속 튜플`'s second component for the question, `답변 다이제스트` for the answer), and `사이드카 앵커=<run-id>#<승인 id>` names the sidecar block those digests are of — without the anchor the digests would be values recorded and compared against nothing.

**For a `절단점=판단` approval, `답변 문면` carries the answer BYTES (as that excerpt); act approvals keep the fixed literal `트랜스크립트 판독`.** For an act approval the answer is binary, so the literal loses nothing; a question's answer is what the next step consumes. Closing rows of every shape also carry `응답 토큰` — the `tool_use_id` of the answer frame — and `답변 다이제스트`.

**Auto-resolution is the other closing path with no person behind it, and it says so on the row.** Unless `CC_CMDS_AUTOPILOT_AUTO_RESOLVE` is off, the gate closes the approvals that carry a recommendation the moment it issues them: a boundary approval as `승인` (continue), a judgment approval as the adoption of the router's own submitted judgment when its class may be adopted — inside the judgment vocabulary and not `팀-구성` or `시각-면제`, the two that hand risk to the user — and as `거부` otherwise, including a class outside the vocabulary and a judgment carrying no class. Act approvals are never auto-resolved. Nor are two kinds of `대기`: a B4 at or above the declared cost ceiling, which is left open because nothing else stops spending, and an approval whose last row carries `처분 사유` (`자유 입력`, `슬롯 부재`), which a person has already answered. **Every closing row — this path's and `close`'s — is appended under a transition guard**: inside the ledger lock the gate re-reads the id's last row and writes only if it is still `대기` (or `철회`, for `close`) and, for this path, carries no `처분 사유`. A refused auto-close writes nothing; a refused `close` fails rather than landing a second closing row whose last-row-wins reading would overwrite the first. The `대기` issue row is still written, and the closing row carries `답변 문면=자동 해소(추천: …)`, `응답 토큰=-`, `답변 다이제스트=-` and `처분 사유=자동 해소`, so a reader never mistakes it for a transcript answer. **Closing a boundary approval — by a person or by this path — restarts that boundary's count** in the run directory; without that the next evaluation re-issued the same question with the same count.

**`철회` is the one closing state with no answer behind it, and it has no clock.** A boundary approval whose raising condition has gone away is withdrawn by the gate's own boundary evaluation — never by the router, which has no verb for it — with `사유=` naming the condition that lapsed; the transition is refused while an answer frame for the id exists in this run's lineage, and while a `다이얼로그 취소` was observed in the same cycle. A later real answer may still close a `철회` approval: `close` admits `철회` as the one non-`대기` starting state. The entry point that writes `철회` lands with the boundary predicates; this vocabulary accepts the token ahead of it.

**`대상 추가` records a repository the run reached that the manifest did not name, and it is a RECORD rather than a grant.** A row that conferred a cutpoint would move the seat of authorization from the manifest to a file the run writes. A widening of the stage settings by a segment's own worktree is **not** this series — it is recorded as `인가면` on the `segment` row that caused it (§2b.1, the paragraph opening "The stage's authorization list is re-derived"), so every row here names an actual repository with an actual alias.

So the row's `층` is `0` or `1` and never higher. Layer 0 is read-only — clone, fetch, read, run that repository's tests — already reachable with arbitrary bash, so refusing it buys nothing and recording it buys the morning report. Layer 1 is local commits and branches, capped at `브랜치`, and the cap is **hardcoded rather than inherited or chosen**: nothing above `브랜치` leaves the machine, so no approval is needed and the split-writer rule is untouched. A layer-1 row is admissible only after the same preflight a manifest target gets — the main worktree exists and the common git directory matches — because stash attribution is per-REPOSITORY rather than per-worktree.

`push` and above take neither path. They park with the cause `대상 미선언`, and the resume command is the re-kickoff that writes a successor manifest.

**`리뷰 의무` exists because `선머지후리뷰` defers an obligation rather than removing one.**

**`생성 등급` on this series is read by nothing.** The excusal rule reads a field of the same name on `problem` rows; this one is kept because the morning wants to know what kind of act deferred the review.

**`머지 커밋` is the commit BEING merged and not a commit the merge creates** — the tip of the segment worktree at issue time, so it and a `cycle` row's `리뷰 HEAD` both name commits that exist before the merge does.

**`대상` and `이행 판정` are written by the gate in the carried position where the router's argv cannot overwrite them.** `대상` is the target alias the merge was authorized against, and the fulfilling side runs its landing test in **that** target's anchor repository rather than in the segment worktree. `이행 판정` is a **closed three-value field**: `착지·포함` (the merge landed on the base and a review covers that commit), `미착지` (it has not landed), `앵커 없음` (the row predates `머지 커밋` and cannot be measured). There is no fourth value and there is no `판정 불가` — an unanswerable probe refuses the fulfillment, so it leaves no row to carry a value on. `근거` is required on the fulfilling row on the same terms the `blocked` arm demands it.

**The row-length budget, restated as the number a writer can use.** The cap is 1024 bytes (§3.1a). The longest fulfilling row with `근거` empty measures 399 bytes, so what remains for `근거` is **625 bytes**.

**`실행 버전` belongs to `stage-result`, not to `segment`.** The session uuid is derived from `owner-doc|구간|단계|시도`, so `시도` must be durable — otherwise a reboot re-derives a uuid already bound to a different transcript. Attaching the field to the per-stage row is what makes that durable at the right granularity.

**`stage-result` is what removes the last edge into stage-owned ledger writes.** Its every field is observable by the driver from outside the stage: an exit code it waited on, artifacts it can stat, a digest it can compute. Nothing here requires the stage to report anything.

**`세션 id` and `부모` are the ancestry record, and without them the implementation-review separation rule is vacuous.** Recording the id the harness actually assigned, plus the id of the session that spawned it, makes the rule a real ancestry-closure check rather than a comparison of derived ids — and a fork inherits its parent, so a forked session cannot review its own work by taking a new id.

**`handoff` holds an abandoned alternative**: a successor shift starts from the snapshot alone, which carries progress, not *what was tried and dropped, and on seeing what*. The row takes `키=값` fields after `--` like `segment` and `cycle` do, grades `읽기`, and — like `blocked`, `종료 절` and a judgment `자율 승인` — does **not** require `--segment`: a shift is an event of the whole run rather than of one segment. Each of the three free-text fields is clipped to 300 characters, which is what keeps the row inside the cap of §3.1a.

**`계측 필링 건너뜀` is the twenty-first because a filing that did not happen has to be told apart from a round with nothing to file.** The gate runs the metrics collector from its prelude (§3.6) and turns what fired into at most one GitHub issue; when it cannot — no observation Project number configured, no write-scoped credential, a GitHub call that failed or an identity that is not the configured account, an instrument issue already open — the trigger would otherwise vanish, and silence reads in the morning as "nothing was wrong". The filings that DID happen go on `자율 승인` rows with `kind=metrics-filing` and `절단점=필링`, because they are decisions the run took. Both rows carry `세그먼트=-` and **no `행위자` field**: a metrics round is an event of the machine's runs rather than of any one segment, and the terminal classifier's fourth condition reads `행위자=스테이지` together with the segment, so a filing row spelled with a stage actor would be counted as a stage's own act on a segment that does not exist. `트리거` is the fired signatures (`<id>/<종류>`, comma separated), clipped like any free text — never the close list, which is what the collector judged gone rather than what fired. **A round that carries closes and nothing fired writes no skip row**, whatever prerequisite it then finds missing: there was nothing to file, so "could not file" is not true of it, and because the collector restates a close every round for as long as the condition stays gone, a skip row written there would recur six-hourly for ever and be byte-identical to the real signal.

### 3.3 Closed vocabularies

| Field | Values |
| --- | --- |
| `자율 승인.kind` | `lane` \| `citation` \| `severity` \| `visual-waiver` \| `verification-residual` \| `audit-composition` \| `unresolved-issue` \| `refinement` \| `roster-degradation` \| `stage-retry` \| `target-expansion` |
| `자율 승인.판단 부류` | `문서-신선도` \| `감사-발견` \| `심각도-조정` \| `잔여-항목` \| `인용-갱신` \| `스테이지-재시도` \| `팀-구성`(pre-adoption forbidden) \| `시각-면제`(pre-adoption forbidden) |
| `자율 승인.등급` | `0` \| `1` \| `2` |
| `승인.상태` | `대기` \| `승인` \| `거부` \| `무효` \| `기각` \| `철회` |
| `자율 승인.자격` | `분리` \| `주변` |
| `자율 승인.행위자` | `리드` \| `교대` \| `스테이지` |
| `승인.절단점` | a `CUTPOINTS` token \| `판단` \| `경계` |
| `계측 필링 건너뜀.사유` | `자격 없음` \| `상한 도달` \| `번호 없음` \| `조회 실패` |
| `자율 승인.절단점`(filing row) | `필링` — a marker outside the ladder, on the same layer as `판단` and `경계` of `승인.절단점` |
| `자율 승인.결정`(filing row) | `등록` \| `코멘트` \| `닫힘` |
| `리뷰 의무.상태` | `미이행` \| `이행` |
| `리뷰 의무.이행 판정` | `착지·포함` \| `미착지` \| `앵커 없음` |
| `segment.리뷰 정책` | `선리뷰후머지` \| `선머지후리뷰` \| `리뷰없음` (optional; omission on a later row inherits) |
| `target.리뷰 정책 상한` | `선리뷰후머지` \| `선머지후리뷰` \| `리뷰없음` (optional; absence reads `선리뷰후머지`) |
| `대상 추가.층` | `0` \| `1` |
| `blocked.사유` | `도달 park` \| `인가 한도` \| `사다리 R4` \| `사다리 단 부재` \| `사이클 예산 소진` \| `자동 채택 미달` \| `자동 채택 불성립` \| `예산·벽시계` \| `게이트 park` \| `시각 정합 park` \| `외부 상태 불확정` \| `대상 미선언` \| `강제 표면 이동` \| `라이브니스 침묵` |
| `blocked.스코프` | `act` \| `cone` \| `run` |
| `자율 승인.등급 출처` | `표` \| `불투명` \| `미상` (exec rows) |
| `자율 승인.선언` | `-` \| a `SURFACES` token — what `--surface` claimed, where it differs from the graded value or is the only grade there is |
| `자율 승인.표지` | `-` \| `비밀출력` \| `파괴` |
| `자율 승인.파괴 출처` | `-` \| `유도` \| `신고` \| `유도·신고` |
| `자율 승인.도달` | a `REACHES` token \| `-` |
| `자율 승인.유도 도달` | `-` \| `기기전역` \| `배포트리거` |
| `자율 승인.식별자 대조` | `-` \| `미선언` \| `일치` \| `대조불가` (`불일치`·`부재` park rather than land on a row) |
| `blocked.도달 판정` | `비밀출력` \| `신고등급한도` \| `도달미상` \| `기기전역` \| `push원격불일치` \| `도달모순` \| `dev파괴` \| `dev식별자불일치` \| `dev식별자부재` \| `dev대조불가` \| `파괴형태미명시` \| `prod인가없음` \| `배포트리거인가없음` |
| `target.dev 식별자` | optional; `<종류>:<값>` elements separated by `,` — `aws-profile` \| `aws-account`(12 digits) \| `kube-context` \| `host` \| `domain` \| `dir`(absolute) |
| `target.배포트리거 식별자` | optional; same shape — `branch` \| `workflow` \| `jenkins-job` \| `argv` |
| `handoff.사유` | `상한` \| `승인` \| `종단` \| `중단` |
| `blocked.원인` | `막힘` \| `무효화` \| `불명` \| `판정 불가` |
| `종료 절.상태` | `충족` \| `불가능` \| `보류` |
| `stage-result.종단 부류` | `정상 완료` \| `의도된 park` \| `공허한 성공` \| `크래시` \| `적용 불명` \| `산출물 없는 정지` \| `외부 종료` \| `한도-형상 회수` |
| `stage-result.기록자` | `게이트` \| `드라이버` |
| `압축 창.출처` | `argv` \| `런설정` \| `프로젝트` \| `레인` \| `꺼짐` \| `미상` (the parenthesised token of `압축 창` on `stage-result` and `교대 기동`; `-` carries no source) |
| `segment.상태` | `계획됨` \| `실행중` \| `리뷰중` \| `머지됨` \| `완료` \| `적용 준비` \| `park` |
| `generation.segmentation` | `ok` \| `low-confidence` |

**`승인.상태` has six values and the gate's `APPROVAL_STATES` constant is their single source of truth; `scripts/lint-approval-state-vocabulary.sh` holds the two equal.** `기각` is written by nothing today and stays in the set — the table is the authority and does not drop a value for being unobserved (the paragraph below says why). `철회` is written by the boundary evaluation that withdraws an approval whose raising condition went away — there is no clock and no router verb reaching it. The dismissed-dialog transcript event is called `다이얼로그 취소` precisely so it is never confused with `기각`.

`blocked.사유=강제 표면 이동` and `=라이브니스 침묵` are written by the gate's surface check and by the watcher's stall transcription, and `segment.상태=완료` is accepted by the gate as a terminal state. **Nothing is REMOVED from the table for being unobserved**, and that asymmetry is deliberate: a declared value that no artifact carries means "not seen yet", not "does not exist", and deleting it would make the next writer improvise a synonym.

**`자율 승인.kind` does not carry a classification.** On the gate path the field holds the **act kind** the decision was attached to, and on an `exec` call it is empty; the table's eleven tokens are what the legacy fixed-graph writer declared, kept for reading old rows.

**`자율 승인.판단 부류` is where a classification actually lives.** On a field that also carries the act kind, one manifest line reading `종류=skill` would pre-adopt every stage dispatch there is; a new field has zero legacy rows, which is what lets the lint assert the closed set with no exception.

**The three forbidden values are IN the vocabulary and forbidden there, rather than left out**, so the leak arrives as a refusal instead of a borrowed permitted token. The refusal is at **freeze time**: `check_manifest` compares every `자동 채택` row's class against the ten and hard-stops on any of the three. Recording a judgment OF that class is still permitted — what is forbidden is pre-adopting it.

**`segment.선행` and `segment.선언 파일 집합` are carried by the router and consumed by the gate; neither is authored by either.** The authority is the design document's slice declaration. `선행` is the cone's declared axis — the only axis that sees a dependency before the predecessor merges — and `선언 파일 집합` is the sole input to "did this segment reach outside what it declared", a question git cannot answer at all.

Two floors sit on `선행`, enforced at write time because `선행` is an *input* to the derivation the cone's superset check compares against. **It is monotone per segment id** — a later row may add and may not remove. And **absence is not `없음`** — in a repository carrying two or more segments a `segment` row with no `선행` is refused, while `없음` is accepted as a positive statement of independence.

**`blocked.스코프=cone` is the one scope the router may CREATE, and the polarity is the opposite of run scope's.** A run-scope block is raised by the gate and only resolved by the router; a cone holds what stands on a refuted premise and lets the siblings keep going. The gate does not take the router's `의존 세그먼트` on trust — it derives the cone itself and refuses a declaration that is a proper subset. Widening passes; narrowing does not.

**`blocked.원인=판정 불가` records an ancestry probe that could not be answered, and its disposition is fail-closed.** `git merge-base --is-ancestor` distinguishes three outcomes, and only exit 1 means "not an ancestor"; 128 means an object is not there, and reading it as "not an ancestor" would fail open. So the segment **stays in the cone** and the row says what could not be measured.

**`종료 절.상태=보류` is not `불가능` with a softer name.** Impossible ends the clause forever; on hold says a person's answer is outstanding and a successor run picks it up. Its `근거` must therefore name an **open** approval whose cutpoint is the literal `판단`, and the gate confirms that id exists in the ledger with `상태=대기` — evidence rather than wording, on the same terms every other clause settlement takes.

**`승인.절단점=판단` is written by the gate.** The router never chooses to ask: it submits its own recommendation through `act --kind judgment`, and whether that becomes a question is decided here. A grade-2 judgment is raised to one, and so is a grade-1 judgment that does not clear the auto-adoption floor. The approval's id is derived from the judgment rather than from an argv, so the same judgment submitted twice yields one approval instead of a queue, and its **binding tuple binds the question and the menu rather than a tree**, because a question's answer is an input to work that has not started and has no tree to measure (the four-component serialization stated under §3.2).

**The resubmission is the consumption of the answer.** The gate reads the approval's state before issuing anything: `승인` adopts the judgment and writes `자율 승인` carrying `해소 승인=<id>`; `거부` and `무효` refuse and do not re-ask; `대기` returns quietly. **A closed approval is never re-opened by a resubmission** — the id derivation guarantees only a genuinely different question reaches a new id — and **one answer opens one judgment**, enforced by refusing any id a `자율 승인` row already names.

**That durability is also why termination condition 2 excludes it.** An act approval's window closes with the night, so a run may not end while one is open; a question's answer survives into a successor run. What records the residual instead is a third class in the `done` file, `종단 — 질의 잔여 N건 · 승인 <id>…`, sitting beside `무효화` for the same structural reason. **No eleventh termination condition is created**: a condition exists to *refuse* a proposal, and an open question must not refuse one.

**`산출물 없는 정지` is the sixth terminal class, so a stage that correctly refused to decide for the user is not punished like one that produced nothing.**

Its definition is the four-part conjunction: **exit code 0, artifact predicate false, no halt record, and a trace in that stage's ndjson of reaching a decision point the skill directed it to.** The last clause is what separates it from `공허한 성공` — not "attempted nothing" but "arrived and did not decide". Its disposition is not a retry: the point is promoted to a pending approval, and that promotion is the recorded skip the unattended `design` step-6 default calls for.

**The other branch is invisible.** A stage that improvises and produces output lands as `정상 완료`, since the audit and review predicates are forgeable, so the morning report's heading is `기록된 자율 결정` rather than "every autonomous decision".

**One control partially recovers it.** In Mode A the router owns the stage's ndjson, so a `ToolSearch` naming `AskUserQuestion` with no halt record is a high-precision signal that the stage improvised.

**Every park names a scope and a cause, and one that cannot is a bug rather than
a decision.** `act` means a terminal act is blocked and NOTHING else stops — the
segment's artifacts survive and it is reported as 완성-미착지. `cone` means a
premise downstream work stands on has been refuted, so what depends on it stops
and its siblings do not. `run` means the run cannot judge the state a later
irreversible act would transform, or its own anchor is invalid; it stops the
declared blast radius. The anti-rule these exist to enforce: **a blocked act
never escalates to a cone or a run stop, and the absence of an answer is not a
cause**, so one cutpoint typo does not park every segment.

**`사이클 예산 소진` is separate from `사다리 R4` because they are different
events**; filing the first under the second makes the ledger say the ladder ran
out when it never started. `사다리 단 부재` is a third thing again — a transition
into a rung this run's authorization does not make available. It is a park and
not a clamp: clamping the rung would disarm the ladder's only end.

**`적용 불명` is its own termination class and not a kind of crash.** A crash is
an execution that did not complete; this one completed and left a state nobody
can describe. `적용 준비` is likewise separate from `실행중`: it names a worktree
pinned to a merge commit, which is the artifact a person needs when an apply's
outcome is unknown.

**Severity adjudication and parking are not new kinds.** A severity tie-break is a `자율 승인` row with `kind=severity`; a park is a `blocked` row with a `사유`.

**An approval and a review obligation are new kinds, because their rows advance through states** — issued, waiting, resolved or stale — and the reader of an existing kind takes every row as terminal.

**`되돌리는 법` is the field that makes the report readable rather than merely complete**: the unimportant decisions are bearable only when they are cheap to undo in the morning. So the field carries a concrete command or edit, not a claim, and failing to produce one is itself the escalation trigger.

**`등급` and `기준` come from the judgment-grade contract** (`_common/judgment-grade.md`). `기준` names the authored standard that chose the option, one a later reader can check. Grade 0 writes no row at all: a rule that fully determines the answer produced no decision to record.

**`kind=severity` requires `finding-id`.** The review rule defaults to the higher severity *unless the lead resolved the dispute*, so the exception counts as fired **only** where a `자율 승인` row records the decision, the rejected alternative, both rationales, and the finding it applies to; with no such row the rule's default branch applies. The interactive path is unchanged.

### 3.4 Write form and its diff gate

One write form: **append** — a new row, or a new `## 실행 <run-id>` block. Gate: **0 removed lines**. `segment.상태` advancing is expressed as a **new `segment` row** for the same `id`, not as an edit; readers take the last row for an `id` as current. This keeps a single append gate for the whole schema and leaves the run's history intact for the morning audit.

### 3.4a The chain, and why it is not only about forgery

Every row carries `prev=<64 hex>` — the sha256 of the preceding row's bytes. The first row of a block chains to the block heading.

It makes a rewrite visible, and it also catches §3.1a's interleaving, which **no row-grammar check can see** — the line count stays right and the field values splice — so one mechanism detects both, and deletion and reordering with them. A spliced row can satisfy a termination condition that the true rows do not, so corruption here **manufactures a false completion**; the advisory lock keeps interleaving rare and the chain makes the rare case detectable.

**Single writer is a property of components, not of processes.** Each gate invocation is a separate shell, so two acts in flight are two writers against one file; the lock is mandatory rather than defensive.

### 3.5 The morning report is a ledger-referenced companion

The report lives at `<base>/docs/pipeline-run/{runId}.md` — the same `<kind>` directory and the same kind token, so **no new kind is created** and the §1.2 guards apply to it unchanged. It is named by `<run-id>` rather than by `{slug}`, which means it is **not independently re-derivable** from the design document the way §1.1 sidecars are; it is found through the `보고서` field of the `run` row. Run-id naming is admissible here and not for the ledger because only the ledger must be findable with nothing but the document in hand.

- **Writer**: the driver. **Created as a stub by `autopilot` at kickoff**, so the file exists even if the run dies mid-way.
- **It must be durable independently of any banner**, because the notification seat's contract does not include delivery confirmation. The report is the source of truth; the banner is a courtesy. Every event writes the report **first** and attempts the banner second — the immediate-notification events included.
- **Two seats raise banners and neither is an agent — the liveness watcher and the adjudication gate.** The prohibition is on a *spawned stage* deciding whether a banner reaches the user, and neither seat is spawned. What is still not promised is **delivery**: this notifier cannot override a focus mode, so **the run may not reach a sleeping user at all**, and the morning report is the whole of the guarantee.
- **It enumerates every autonomous decision the run RECORDED** — the heading is `기록된 자율 결정`, because a stage that improvises and produces output writes no row — all `자율 승인` rows grouped by `kind` with decision, rejected alternative and rationale carried verbatim; every fix the ladder auto-adopted; every parked item with its `사유`; and each stage's `종단 부류`.
- **It also enumerates every `계측 필링 건너뜀` row** with its `사유` and `트리거`, beside the `자율 승인` rows with `절단점=필링` — the ninth item of the rendering enumeration in `autopilot`'s morning report. Where there is none, the report says so: an absent row is "nothing was due or everything was filed", never "the collector found nothing", and the report has to keep those apart.

**The limit is stated with the control.** The report is itself authored by the run, so it is powerless against a run that improvises a decision **and also** omits it from its own report. It is not a gate, and **the real protection against an irreversible autonomous act remains the permission cutpoint of §2.3.**

### 3.6 The metrics summary beside the ledger

The run metrics collector (`orchestrator/collect-run-metrics.sh`) is run by the gate from its prelude — every verb but `plan`, never from a stage seat, at most once per six hours per state root (stamp `<state root>/metrics.stamp`, one-attempt lock `<state root>/.metrics.lock` with a fifteen-minute expiry). It is the only writer of the five files below; the gate reads its stdout and nothing else.

| File | Where | What |
| --- | --- | --- |
| summary | `<base>/docs/pipeline-run/metrics.json` | the aggregate over every collected run, keys sorted, **no timestamps** |
| start marker | `<base>/docs/pipeline-run/metrics.json.pending` | created empty when a round starts, removed after the summary is renamed into place; one left behind is a round that died |
| per-run record | `<base>/docs/pipeline-run/metrics/<run-id>.json` | one per collected run, written once and not rewritten |
| unfiled | `<base>/docs/pipeline-run/metrics.unfiled/<issue number>.md` | an issue that was created but could not be added to the Project, with the command that adds it |
| round journal | `<state root>/metrics/<repo-key>/rounds.jsonl` | append-only, one line per round; `repo-key` is the repo base's absolute path with `/` turned into `-` |

**The summary carries no timestamps so that the same input gives the same bytes.** Two rounds over the same runs then leave the file byte-identical, and a changed summary always means changed input. **Round numbers, consecutive counts and times live only in the journal**, and the journal is the only source the trend trigger reads for its baseline and its run of bad or good rounds — a counter kept anywhere else could disagree with the lines it summarises. The stamp, the lock and the journal sit beside the reaper's root but are not reaped: the reaper walks `run/` only.

The population is every ledger in the directory whose run is `종단` or `버려짐` by the same state function the snapshot uses; a round with a run in that population that could not be collected judges nothing.

**The filing settings file is `~/.config/cc-cmds/metrics-filing`** (`${XDG_CONFIG_HOME:-$HOME/.config}/cc-cmds/metrics-filing`). Lines are `key<TAB>value`, read with `awk` and never sourced, and two keys are recognised:

- `project` — the number of the observation-only GitHub Project that instrument issues are added to. Anything but digits reads as absent. **While it is absent no issue is created at all** and the round writes `계측 필링 건너뜀 | 사유=번호 없음` instead.
- `account` — the GitHub login the write-scoped credential must resolve to. A credential that resolves to anything else is `사유=조회 실패`, not a filing under the wrong name.

The file holds no credential; the token comes from `credentials.sh` as it does for every other write.

**Instrument issues are an exception to the repository's autopilot tracking rule, and the exception is deliberate.** Issues labelled `cc-metrics` are added to the observation-only Project named by `project` and **not** to the autopilot Project the repository instructions say every autopilot defect goes to. They are measurements of the compaction window and of the collector itself, filed by a machine at most once per round; putting them on the work queue would bury the human-filed items that queue exists for. A later session must not "fix" this by moving them onto the autopilot Project.

---

## 3b. `cc-pipeline-approval v1` — the approval sidecar

```
# 파이프라인 승인 기록 — <run-id>
<!-- cc-pipeline-approval v1; writer=gate; reader=gate; owner-run=<run-id>; owner-doc=<document key> | (없음); NOT a design doc; mechanism-local, never staged by a skill -->
```

**Path**: `<base>/docs/pipeline-approval/<run-id>.md`. Keyed on the RUN rather than derived from the design document by `sidecar.md` §1.1's slug rule, because a run may start from a pull request or a bare intent and have no document to derive from at all. This is therefore a kind under §1.2's exception clause, and this section states everything that clause requires of such a kind.

**Header and proof pair.** Where a document-keyed kind carries `owner-doc=`, this one carries `owner-run=<run-id>` and, beside it, `owner-doc=` for the record (`(없음)` when the run names no document). Its proof pair is `owner-run=<run-id>` **together with the existence of that run's authorization record** `<base>/docs/pipeline-grant/<run-id>.md`. A reader takes the file as this run's only when both halves hold, and a writer refuses to create or extend it otherwise — fail-closed in both directions.

**Writer and directory.** The gate is the only writer, and — §1.1 makes directory creation the writer's duty — **the gate creates `<base>/docs/pipeline-approval/` immediately before its first write**, so the first approval of a fresh checkout does not swallow a free-input answer.

**Blocks.** One block per approval, `## 승인 <승인 id>`, holding two fenced regions:

````
## 승인 J-867db2b3
**질문 sha256**: <64 hex>
```text
<the full question text>
```
**답변 sha256**: <64 hex>
```text
<the full answer text>
```
````

The **immutable region** — `질문 sha256` and its fence — is written when the approval is issued and never rewritten. The **mutable region** — `답변 sha256` and its fence — is filled when the approval closes, and re-filled if a later answer supersedes an earlier one; a free-input answer (ledger `처분 사유=자유 입력`) is written here and nowhere else. Fences are one backtick longer than the longest backtick run in the payload, never shorter than three, so a payload cannot close its own fence; the tokenizer matches a closing fence by the exact backtick string that opened it and treats a `## 승인` line inside an open fence as payload. Act and boundary approvals get a block too — their question is a fixed literal, but the row's anchor has to name something and their closing rows carry the answer digest.

**Write form.** §1.3 of `sidecar.md` unchanged: a temp file in the same directory, a compare-and-swap against the bytes the build read, a plain `mv`, a read-back that the block heading is present, a bounded retry. Nothing here deletes or truncates.

**What the ledger carries about it.** Every `승인` row that this kind backs carries `사이드카 앵커=<run-id>#<승인 id>`, and the row's digests — the question digest inside `구속 튜플`, `답변 다이제스트` on a closing row — are digests OF the fenced texts in that block. `응답 토큰` names the transcript frame, not the sidecar, and does not stand in for the anchor.

---

## 4. `cc-pipeline-halt v1` — the halt record (not a sidecar)

When an unattended arm reaches a point that needs a human, it writes a halt record and stops. This is the **durable form of the plain-text failure report that `implement`'s fail-loud rule already prescribes** — a proper subset of it — so no shipped fail-loud paragraph changes.

```
${RUN_DIR}/halt/<stage-id>.md
RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>
```

```
<!-- cc-pipeline-halt v1; writer=<skill>; reader=orchestrator; stage=<stage-id>; run=<run-id> -->
**중단 시각**: <ISO8601>
**스킬**: <skill name>
**스텝**: <step identifier>
**분류**: tool-unavailable | gate-unanswerable | freeze-mismatch | precondition-failed
**질문 문면**: <the Korean question that would have been asked, verbatim, never summarized>
**선택지**:
- `<label>` — <description, verbatim>
**하네스 오류**: <the original harness error string, verbatim> | (없음)
**관측 상세**: <the measurement values this 분류 owes, parts joined with ` / `> | (없음)
**재호출 명령**: <the command line the skill would have emitted, verbatim> | (없음)
**후속**: 보류 큐
<!-- /cc-pipeline-halt v1 -->
```

- **Written with the atomic form of `sidecar.md` §1.3** (temp file in the same directory, then rename), so a partial record is never observed. The closing fence is the terminator: a record whose last non-empty line is not `<!-- /cc-pipeline-halt v1 -->` is **a crash mid-write, not a halt**.
- **`관측 상세` is where measurement values go, and `질문 문면` is not.** A `freeze-mismatch` halt owes which assertion diverged, the baseline value, the observed value, `FROZEN_SHA256`, and — on an assertion 1 mismatch — the intersecting paths, which `verification.md` §6.0 calls the only thing telling a later reader what ended the window. **On a 2b mismatch it owes three more**, because that assertion compares a subset of the own-entry: the diverging **component** as one of the closed three `worktree` | `branch` | `HEAD-tree`; on a `HEAD-tree` divergence the two **tree** shas as the compared pair plus the changed path count and up to five names from a tree-to-tree `git diff --name-only`; and the two `HEAD` commit shas as **reported-never-compared diagnostics**, which keep the forensic trail of an empty commit. `질문 문면` is the verbatim question a human uses to audit a forged halt, so these values never go there. It is **one line like every other field line in this block**, parts joined with ` / `, and every field line sits above the closing fence because that fence is the terminator. A class with no measurement values of its own writes `(없음)`.
- **An exit 11 from the gate is a halt input, not a retry input.** 도달 park says
  the act was not performed and will not be: the verdict is keyed on the act
  digest, so the same argv re-declared takes the recorded answer. A stage whose
  parked act was not essential continues without it and writes no halt record at
  all; one whose act was essential writes this record with `분류:
  gate-unanswerable` and the `도달 판정` value in `관측 상세`.
- **`재호출 명령` is inert.** The driver records it and **never executes it**. Auto-running it retries a condition whose cause is still present, turning a single pass into a loop bounded only by budget.
- **Termination discipline**: write the record atomically → take **no further step** (no cleanup beyond what the halting step already committed, no partial progress, no fallback act) → end the turn normally.
- **The discriminator is the artifact, not the exit code.** A halt is a *clean* stop, so its terminal envelope looks like a normal completion, and a model-driven skill cannot set an exit code to mean otherwise. **Exit says the stage ended; the halt record says why.** Both are machine-read; neither is prose.
- **The volatile run directory is deliberately not durable.** Process handles — `stage-pid`, process-group id, transcript paths — live here and nowhere else, so a stale record and a stale process die together and pid reuse cannot make the driver kill an unrelated live process. It is under `XDG_STATE_HOME` rather than `${TMPDIR}` because `/var/folders` is swept without a reboot.

---

## 5. Termination recognition — the driver never parses prose

> **The driver's input from a stage is exactly two things — that the process ended, and what it left on disk. Prose output is never parsed for control flow: not the report body, not the Korean summary, not the next-step line.**

Skills do emit next-step command strings; the rule binds the **reader**, not the writer, which is why no skill text needs editing. Such a line is disqualified as a control signal anyway: it is emitted on the success path (so it cannot separate a finished audit from an aborted one) and it is cwd-relative (so it resolves against the wrong tree in a segment worktree). It is copied **verbatim as an opaque string** into the morning report, for the human who may run it.

### 5.1 Artifact predicates

| Stage | Predicate |
| --- | --- |
| `design` | the freeze literal *"설계 문서를 동결했습니다. 이후 이 세션에서는 문서를 수정하지 않습니다."* |
| `design-audit` | the terminal literal *"이 명령은 여기서 종료합니다. 추가 리뷰 라운드는 없습니다."* + the `docs/design-audit/{slug}.reader-<k>.md` reader copies |
| `review` | the summary line `- **발견 요약**: 🔴 P0 N건 \| 🟠 P1 N건 \| 🟡 P2 N건 \| 🟢 P3 N건` in the report; the filename glob must accept the `review-pr{N}_{YYYY-MM-DD}[_v{N}].md` variants |
| `implement` | a git-state ladder — commit → branch ref → PR number, in the order the permission cutpoint authorizes. Evaluated by the driver **in the main tree** |
| `design-reconverge` | `docs/design-reconverge/{slug}.md` carrying `재수렴 sha256` and a two-value verdict (`재설계 필요` \| `불필요`), plus its confirming fixed literal. A terminal verdict returns to segment planning **unconditionally**, inside the same run — a moved document digest is recorded as a `문서 해시` row and needs no new run. Dispatched from the driver's ladder on a review finding, and by the routing shift on an implement stage's Step 1.5d halt; either way the document argument is the **main-worktree absolute path**, because `docs/` is absent from every linked worktree |
| `design-discuss-unattended` (dispatched by the run) | the fixed literal *"설계 문서를 동결했습니다."* in the stage's own stream **and** a line reading exactly `**상태**: 동결됨` in the document it wrote. A halt record at `${RUN_DIR}/halt/<stage id>.md` makes it an intentional park. **One destination**: the stage emits the freeze literal, the document path and its whole-file `sha256`, then stops, naming no next step — the next step is the driver's or the router's graph, and a document that is not frozen goes to neither the audit nor segment planning |

**The predicates are not equally strong, and pretending otherwise makes the table read stronger than it is.**

> **A predicate over state the stage cannot fabricate — a git ref, a remote ref, a PR number — is immune to a hollow success. A predicate over an artifact the stage authors is not.**

`implement` meets that bar: a run that answered in prose and moved on produces no commit, so the ladder is false and the driver never consults the stage's self-report. `design-audit`, `review` and the dispatched design stage do **not** meet it — the last crosses two authored facts, which catches a stage that said it froze without writing so, and no more — a model that improvised past a question still reaches the skill's normal exit, emits the terminal literal, writes the reader copies, and writes a well-formed summary line. **For a stage whose only output is a document, no un-fabricable predicate exists.** That is recorded rather than papered over.

### 5.2 The four termination classes

Exit status and the artifact predicate are **independent axes**, and the halt record is the third. Crossing all three is what separates "it died" from "it believed it was finished".

| exit | predicate | halt record | class | driver action |
| --- | --- | --- | --- | --- |
| success | true | — | `정상 완료` | next stage |
| success | false | present | `의도된 park` | blocked queue, no retry |
| success | false | absent | `공허한 성공` | retry **once**, then blocked queue under a distinct reason |
| non-zero | false | — | `크래시` | retry at the boundary, `시도+1` |
| (none) | — | absent | `한도-형상 회수` | one re-dispatch under its own name (implement), the recovery dispatch (review), or blocked queue |

Priority on read: **a halt record present ⇒ halt.** Then a reap mark present ⇒ `한도-형상 회수`. Absent and terminated ⇒ judge by the predicate.

The fifth row has no exit status because the driver itself ended the stage: the limit-shape arm of its wait loop signalled a boundary-idempotent stage whose transcript had been silent through at least one backoff rung, and it wrote a reap mark (`<stage>.reap-cause`, carrying `여유 계정` or `백오프 상한`) before the signal went out. Nothing collects such a stage, so it has no `.rc`; without the mark the consumer's default of 1 would read as `크래시` and the stage would be re-bought under the wrong name and out of the crash retry. The mark is what keeps the two countable apart. The sensor's headroom verdict can shorten that arm's ladder; it cannot make it zero — the first limit-shape observation always waits one rung, because transcript silence alone cannot tell a stage at a limit from a stage inside one long tool call. **"First" is scoped to the dispatch, and the scope is enforced at the spawn rather than at the teardown**: `stage_spawn` clears the accumulator alongside the reap mark, so a re-dispatch under the same stage id starts the ladder from zero however its predecessor ended. Leaving it to each exit path to reset was the same sentence resting on every future exit remembering, and the non-idempotent branch — which parks the stage and signals nothing — already did not.

The third row is a measured failure mode, and its retry count is argued in both directions: not zero, because one observation cannot rule out a transient cause; not the full retry budget, because a clean exit with no artifact is itself evidence that the next attempt does the same. Improvisation is deterministic, so a blind retry loop would reproduce it identically and burn the whole budget before reaching the ladder. **This does not restore the stop that the unattended arm removed** — nothing on the skill side can. It converts an unobservable failure into an observable one, which is the most the driver can do from outside.

---

## 6. The volatile run directory — the file list and who writes each

```
RUN_DIR = ${XDG_STATE_HOME:-$HOME/.local/state}/cc-cmds/run/<run-id>
```

**This directory is not a sidecar, and nothing here is durable state.** §4 already says so of the halt record, and why it sits here; it is true of every entry below.

**The list is written down because the directory has four writers and no schema**: nothing rejects an unknown name, and a scheduler that mistakes an unrecognized file for an absent one reads a live run as idle.

**Run directories are never cleaned up.** Any reader that enumerates this root has to be bounded and has to treat an unrecognized record shape as *undecidable* rather than as *idle*.

### 6.1 The file table

| Path | Writer | What it is |
| --- | --- | --- |
| `plan.md` | `autopilot` (kickoff) | the run manifest of §2b — frozen whole, creation-only |
| `started-at` | driver (`run.sh`) | run open time, epoch seconds |
| `config-dir` | driver (`run.sh`) | the **lane** this run opened in — tier 2 of the account resolver, written once at run open so every later stage dispatch resolves to the same lane |
| `orchestrator-dir` | driver (`run.sh`) | the absolute path of the orchestrator directory this run actually loaded — in a pinned run that is the copy's `orchestrator/`, not the installed checkout's |
| `generation` | driver (`run.sh`) | segment-plan generation counter |
| `plan.tsv` · `done.txt` | driver (`run.sh`) | the segment rows, and the segments already merged |
| `<stage>.pid` | driver (`run.sh`) | the spawned stage's pid |
| `<stage>.pgid` | driver (`run.sh`) | its process-group id — the **fallback** identity handle |
| `<stage>.start` | driver (`run.sh`) | its start-time fingerprint; `(pid, start time)` is the identity and the pid alone is not |
| `<stage>.rc` | driver (`run.sh`) | the collected exit status |
| `<stage>.window` | driver (`run.sh`) · gate (`gate.sh`) | two lines — the effective compaction window in the `압축 창` grammar and the lane in tilde form — written at launch and copied onto the `stage-result` row; **a record, never a liveness input or a settlement precondition** (absent → `(미상)`) |
| `<stage>.backoff` | driver (`run.sh`) | the limit ladder's accumulator for a stage in the limit shape — `elapsed sleep_s`, written after each rung, removed on the next sign of progress, and cleared again by `stage_spawn` so the ladder is per dispatch rather than per stage id; its presence is what admits the sensor's headroom verdict to the reap decision |
| `<stage>.reap-cause` | driver (`run.sh`) | written before the limit-shape arm signals a stage (`여유 계정` or `백오프 상한`); the classifier reads it as `한도-형상 회수` so the reaped stage does not land as `크래시` |
| `<stage>.reaped` | driver (`run.sh`) | `<pid> alive` or `<pid> dead` — the `kill -0` verdict stamped by `reap_orphan` before it removes the pid file |
| `<stage>.transcript` | driver (`run.sh`) | cached path of the stage's session transcript |
| `log/driver.log` · `log/<stage>.json` | driver (`run.sh`) | driver log, and each stage's result envelope |
| `gh.err` | driver (`run.sh`) | captured stderr of the last `gh` call |
| `halt/<stage-id>.md` | **the halting stage** | the halt record of §4 — the one file a stage writes here |
| `<segment>.plan.md` | the `implement` stage | the plan emitted by that segment's first process, and the admission token its second one is checked against |
| `designdoc.lock` | driver (`run.sh`) · **a stage that edits the design document** | the empty `lockf -k -t 0` target every design-document writer wraps its write in — the implementation arm's token writes, the audit's reconciliation pass, the re-convergence pass. It detects a second writer and queues nobody; absent when the run opens and read by no baseline |
| `cc-team-witness-<slug>[.<stage-id>].XXXXXX/` | **a team member (stage)** | the witness scratch directory — where a member publishes its round product, minted by `orchestrator/cc-team-witness-init.sh` and recorded verbatim as that member's `scratchDir`. The row is here because the Writer column is an enforcement rule: without it a member's publish is denied, and a lead that cannot read its team's witness either parks forever or synthesizes a round product it never observed |
| `shared/<gen>/` | **the lead seat** (the directory itself: driver, `run.sh`, created empty at run open) | a generation of the shared snapshot the seats read instead of each collecting its own — `manifest.tsv`, `blob/<id>`, `diff/<target>.patch`. Built in a sibling temp directory and renamed in, so a generation is either whole or absent, and never edited once published: an invalidation is a new generation. The row is here because the Writer column is an enforcement rule — the run hook and the gate's Bash-path guard both except exactly one level below `shared/` (`shared/<gen>/…`), and a file directly under `shared/` is refused by both, with `..` folded before either list is consulted. The routing seat is refused any argv element naming a path under here by a separate gate arm that stands on both argv-running verbs (`exec`, and `act` of every kind but the two dispatch kinds); its settings variant carries no directory grant, so that arm is what keeps the Bash path as narrow as the tool path |
| `plugin/cc-cmds/` | gate (`gate.sh`) | this run's own copy of the plugin root, taken once at run open. Every later gate call, watcher and feed `exec`s into it, so it is the code that actually enforces this run. **Stages read it and never write it** — the run-directory allow-list refuses every name under here, on the hook path and on the Bash path alike |
| `plugin-pin` | gate (`gate.sh`) | written once and never overwritten; `키<TAB>값` lines: `schema` · `plugin-dir` · `source` · `method`(`archive` \| `copy`) · `commit` · `tree` · `dirty` · `digest` · `version` · `pinned-at`, plus the optional diagnostic `commit-on-origin`. Published by a single `link(2)`, so simultaneous run-open entries yield exactly one pin and one copy |
| `settings/` | gate (`gate.sh`) | the per-run settings the stage wrapper launches with, hook included |
| `settings.lock` | gate (`gate.sh`) | `mkdir` mutex over the settings directory, held by readers and writer alike; the `segment` row writer holds it from before its re-derivation until after the row's append, so a sibling's render cannot read the ledger without this row. A holder that dies leaves the directory behind, and every later re-derivation then lands as `인가면=실패(락 대기 초과)` until it is removed |
| `ledger.lock` | gate (`gate.sh`) | the ledger's advisory lock |
| `ledger-path` | gate (`gate.sh`) | where this run's ledger is, for readers that have only the run directory |
| `session-lineage` | gate (`gate.sh`) | session id → run id, the ancestry index |
| `surface-digest` | gate (`gate.sh`) | the enforcement-surface baseline compared at each act |
| `progress-digest` · `progress-repeat` | gate (`gate.sh`) | the stagnation boundary's previous value and its repeat count |
| `obligation-window` · `obligation-window-done` · `obligation-repeat` | gate (`gate.sh`) | the obligation boundary's state — the obligations its count is waiting on, and which of them have been seen disposed since that count started — and its repeat count |
| `act-budget-base` · `act-budget-digest` | gate (`gate.sh`) | the terminal-act budget's baseline and its input digest |
| `cost-resolved-pct` | gate (`gate.sh`) | the cost share a B4 approval was closed at; B4 stays quiet until spending climbs ten points past it |
| `done` | gate (`gate.sh`) | written when the run proposes termination; **its absence is not evidence of activity** |
| `notify/park-<segment>` | gate (`gate.sh`) | per-segment park markers |
| `notify.state` | notifier (`notify-run.sh`), drained by the gate | pending notification events |
| `notify.stack` | notifier (`notify-run.sh`) | the notification stack's admitted slots |
| `notify.reported` · `notify.announced-void` | gate (`gate.sh`) | which events already reached the report |
| `watch.pid` | watcher (`watch.sh`) | the watcher's own pid — **not a stage**, and a census that counts it answers a different question than its name |
| `watch.state` · `watch.heartbeat` | watcher (`watch.sh`) | last observed ledger size and time; the published heartbeat |
| `watch.announced-*` | watcher (`watch.sh`), one written by the gate | once-only announcement markers |
| `stall` | watcher (`watch.sh`) | appended stall observations |
| `watch.log` | the kickoff's detach redirection | the watcher's stdout and stderr; **no script writes this path** — it is the shell redirection on the line that orphans the watcher |

**A pid file is a stage only if a sibling handle sits beside it.** Both spawners write `<name>.start` and the driver writes `<name>.pgid` on top of that, so a `*.pid` glob alone over this directory counts the watcher as a stage — and the run's termination condition, which has no resolving verb, then never comes true while a watcher runs.

**The two spawners write those files in OPPOSITE orders, so a sibling-less stage pid is a real on-disk state.** The driver writes `<stage>.start` and then `<stage>.pid`; the gate writes `<stage>.pid` and then `<stage>.start`, and it writes no `<stage>.pgid` at all. A stage the gate spawned therefore has a single identity handle with no fallback, and between those two writes its pid file sits here alone. A reader that meets that shape has **not** observed an idle run — it has observed a record it cannot judge, and it must publish "cannot judge" rather than a count, because the count `0` authorizes a swap. The exemption runs the other way for `watch.pid`, which is exempt **by name**, because the watcher never leaves a sibling and demanding one would make every watcher-only directory permanently undecidable.

**What that asymmetry demands of a reader is the sibling's CONTENT, not its presence.** The gate's `<stage>.start` is the output redirection target of a `ps | sed` pipeline, so an EMPTY sibling is on disk until `ps` emits a byte, and for the stage's whole lifetime if `ps` prints nothing. The test has to be that one of the two handles is **non-empty**, and it has to be the UNION of them rather than `<stage>.start` alone: a driver-spawned directory can carry an empty `<stage>.start` beside a valid `<stage>.pgid`, and the census calls that alive.

**The Writer column also decides who may WRITE here with an editing tool, not merely who does.** The run hook the gate installs treats this directory as an allow-list for `Write`/`Edit`: `halt/<stage-id>.md`, `<segment>.plan.md`, `designdoc.lock`, anything under a `cc-team-witness-*/` directory, anything one generation down under `shared/<gen>/`, and the unattended design stage's `design/` and `preimage/` are permitted, and every other path **this arm judges** is denied. **The gate's `Bash` path carries the same list**, so a write is not refused through one tool and allowed through the other; the two lists are stated once each and `scripts/test-gate.sh` pins that they agree. **It does not judge every path under `RUN_DIR`**: the arm is entered by walking the edit target's own spelling upward until an ancestor's inode matches the run directory, so a spelling whose ancestors never meet it is never judged here — whatever the bytes finally land on. Those rows are exactly the ones naming a stage, or a member of one, as the writer. It matters most for the gate-owned rows re-read as the baseline of each act (`surface-digest`, `act-budget-*`, `progress-*`, `obligation-*`, `ledger-path`, `session-lineage`, `done`): a stage able to write one would re-baseline the enforcement check against itself and leave no row.

**Both permitted names are narrower than they read, and the hook enforces the narrower reading.** `halt/<stage-id>.md` is a **direct child and one level only** — a path burrowing below it, `halt/<anything>/<anything>.md`, is denied, because the halt record is one file per stage. And what the list permits is **the file sitting at that name, not the name itself**: a leaf that is a symlink is denied even where its name matches — whether or not the link resolves. **That sentence is narrower than it reads. The gaps below are the ones known today, and this is not a claim that the list is complete.**

- **A hard link at a permitted name is not denied.** It has no link to follow and shares the target's device and inode outright, so no symlink test can separate the two names — the split between a name and a file has to come from the inode side there. **A hard link outside the run directory is not denied either, and it falls under no clause above**: it is not a resolution, so the leaf test never fires, and its ancestors are all outside, so the ancestor walk never reaches this arm at all.
- **A path sitting outside the run directory whose leaf resolves inside it** shares no ancestor with the run directory, so it is never judged here.
- **An intermediate component that resolves to a gate-owned directory** is closed for `settings/` by a directory-level inode anchor, so a `halt` that is a symlink to `settings/` no longer folds to an allowed name. **The anchor needs the directory to exist**: before `settings/` is created the anchor cannot fire, so that window stays open. A live run directory always has it, because the gate creates it at run open.

The symlink-leaf sentence closes none of these.

**`config-dir`, `orchestrator-dir`, `plugin-pin` and `plugin/` are written once and never overwritten.** A driver restarting against a live run directory must not move the lane a stage is already spending. A pin that exists is never replaced, because a second copy would mean two versions enforcing one run, and a pin naming a copy that is gone is a hard stop for the gate rather than an invitation to take a new one. A run directory laid down before these existed simply has none of them; a reader reports that as "unrecorded" rather than as an error.
