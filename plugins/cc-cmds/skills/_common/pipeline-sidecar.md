# Pipeline Sidecar Contract (Shared SOT)

The payload schemas for the autonomous pipeline's durable state. Generic mechanics — path and slug derivation, the header grammar and `owner-doc=` provenance guard, the atomic compare-and-swap write, the never-delete lifetime, the version token — are **not restated here**: they live in `_common/sidecar.md` §1 and this file cites them read-only. What follows is only what §1 delegates to a payload schema: the kinds, their block grammars, their field sets, their mutability splits, and their write forms.

Two sidecar kinds and one non-sidecar record are defined:

| Artifact | Kind token | Writer | Location |
| --- | --- | --- | --- |
| Run manifest | `cc-run-manifest v1` | `autopilot` (kickoff) **only** | `<run 디렉터리>/plan.md` |
| Authorization record | `cc-pipeline-grant v1` | `autopilot` (kickoff) **only** | `<base>/docs/pipeline-grant/{slug}.md` |
| Run ledger | `cc-pipeline-run v1` | the driver **only** | `<base>/docs/pipeline-run/{slug}.md` |
| Halt record | `cc-pipeline-halt v1` | the halting stage | volatile run directory (§4) — **not a sidecar** |

**Why the authorization is a separate file from the ledger.** The decision is about **exposure**, not about structure or convention. In a single file the bytes carrying the permission grant pass through the writer's transform on **every append**, all night; in two files they pass through it **once per run**. That asymmetry holds under both fault models — a bug in the transform and a bug in the append gate — and it matters here specifically because **no lint validates a sidecar**, so a protection that does not rest on gate correctness is the one that actually pays. Progress cursor and resume state still live in **one** ledger; the grant is not progress state, it is the run's input contract.

---

## 1. Writer partition — and why it is total

**The driver is read-only against the grant.** The only writer of `cc-pipeline-grant` is the kickoff skill `autopilot`; the driver reaches it by no path at all. An append gate can refuse edits to a frozen block but cannot refuse a **well-formed new block that grants more** — that is an ordinary append. Giving the all-night process no write access does not mitigate that residual, it **deletes** it: a process with no write path cannot widen its own authorization no matter how it fails. What remains is misbehaviour by the kickoff skill itself, which happens with a human watching.

**The driver is the sole writer of the ledger, from the main worktree.** Stage processes emit structured output on stdout and **never write a sidecar** — not the ledger, not the grant. `sidecar.md` §1.3 states plainly that its compare-and-swap narrows the check-then-act window to a single process spawn rather than eliminating it, so N segment processes resolving to one `<base>` would contend in that residual window and destroy the loser's block. A single writer does not arbitrate that contention; it removes it by construction.

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

**Display form above, stored token in the field.** Field 3 carries the **token**, and for six of the seven rungs the two strings are identical — the exception is the last, which displays as `머지 후 후속 착수` and stores as `머지후착수`. A grant written from the display text matches no token, and the consequence is not a parse warning: the index lookup reports "unknown", `authorized()` denies every act, and the run produces a night of blocked terminal acts with nothing naming the cause. Unrecognized tokens are therefore a **hard stop** rather than a silent zero, and `scripts/lint-cutpoint-vocabulary.sh` derives this ladder from the driver's vocabulary so the rendering here cannot drift from the values it describes.

The interview takes **one** cutpoint. Everything at or below it is autonomous; the first act above it sends its segment to the blocked queue — it does **not** ask, because there is nobody to ask. Two consequences are part of this contract rather than implementation detail:

- **`머지` does not carry an `--admin` exception.** A run blocked by branch protection parks. A driver that granted itself the exception because it "was authorized to merge" would be widening the grant silently, which is exactly what §1 exists to prevent.
- **A failed non-required check parks.** The shipped policy enumerates failed non-required checks and asks whether to merge, and forbids merging without an answer. Unattended, the answer never comes, so that branch **is** the park branch. It is stated here because a clause that fires rarely with a human present becomes a default path without one.

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
one optional element inside it. That inversion is the whole of the generality:
today the run identifier, the authorization, the ledger path, the report path
and every remediation target are derived from a document, so a run that starts
from a pull request or from a bare intent has nothing to derive them from.

**Three parts, split by writer and mutability** — `plan.md` (kickoff, **frozen
whole, creation-only, no append form**), `ledger.md` (driver, append-only),
`report.md`. The split is the same one §1 already draws and for the same
reason: the bytes that carry authorization pass through a writer's transform
once per run rather than on every append.

### 2b.1 Header and the six sections

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
            [ | 실행 워크트리=<abs> ]

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
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사다리 가용 단 수**: 4 | 2
**미선언 상황 처분**: park | 선언된 기본값 진행
- `사전 인가` | 형태=<argv 접두 형태> | 사유=<왜 이 형태가 예측 가능한가>
- `자동 채택` | 판단 부류=<여덟 값 중 하나> | 상한=없음|<정수> | 심각도 상한=<critical|major|minor|trivial> | 사유=<왜 이 부류가 미리 안전한가>
````

**The manifest freezes the GOAL AND THE CONSTRAINTS, not the plan.** The plan
digest is gone, and its absence is the point rather than an omission: the step
graph is now decided one act at a time by a router reading a snapshot, so a
frozen plan would be a value nothing compares against — the defect class this
whole contract exists to remove, arriving as a leftover.

What IS frozen, and what `구속 다이제스트` covers: the goal, the termination
point together with its decomposition into checkable clauses, the targets and
their per-target cutpoints, the rule-catalog settings, the list of predicted
irreversible acts, and the optional deadline. The gate compares that digest at
entry. `대상 맵 다이제스트` stays as well — it is the narrower check over the
target rows alone, and keeping both means a target-row edit is named as such
rather than reported as "something in the frozen set moved".

**The stage's authorization list is re-derived, and that is what keeps a run able to finish.** It used to be written once at run open and never again, on the ground that a surface which changes because the gate touched it is a surface whose comparison means nothing. The ground is real; the remedy was too wide. Kickoff happens **before** segmentation, so a segment's own worktree is by construction a directory the list cannot contain — and a run that meets one has no way to get it. Measured: a run produced its review and then could not remediate at all, ending with its goal marked unreachable for want of a directory rather than for want of work.

What keeps the comparison meaningful is not that the surface never moves. It is that it moves **only through the gate**, and leaves a row when it does. So the list is a pure function of the manifest and the ledger's `대상 추가` rows — both themselves recorded — and when that function yields different bytes the gate rewrites, re-baselines, and appends a row naming what widened. **The re-derivation runs only from a baseline that still matches.** If the surface has already moved, the gate does not repair it: repairing would erase the evidence the surface check reads, and an edit by anything that is not the gate still lands as exit 7.

The widening is bounded by construction — every directory it can add is a worktree of a target the run already acts in. Nothing there grants a cutpoint, and the cutpoint is what governs whatever leaves the machine.

**`실행 워크트리` is optional and exists because one field could not carry two duties.** `메인 워크트리` is pinned to the main worktree so that N linked worktrees of one repository converge on one sidecar location — that is what keeps the state a single writer owns from splitting N ways. But the act has to run where the branch actually **is**, and for a `pr` or `branch` anchor that is never the main worktree, because git refuses to check one branch out twice. With only the first field, a stage woke on the main worktree's branch every time: it started normally, the files were readable, and what it read was a different version. Nothing mechanical noticed — the one observation that caught it was a stage comparing its own HEAD against the branch name in its instructions, which is goodwill rather than a check.

So the sidecar path reads `메인 워크트리` and the act's working directory reads `실행 워크트리`, falling back to the main worktree when the row declares none. A declared execution worktree is verified against the **same** common git directory: one in another repository would be a second target wearing the first one's cutpoint.

**The `사전 인가` rows are the list an irreversible act is checked against**, and
they are rows rather than a field because the set is open and each entry carries
its own reason. `형태` is an argv **prefix** — `gh pr`, `git push`, `terraform
apply` — matched against the first two words of the act, so a row grants a
family of acts rather than one spelling. An external-state act with no matching
row is **not refused**: it issues an approval and waits. The distinction is the
point. Nobody being awake to ask is not the same fact as the answer being no,
and a run that conflates them either stops all night or acts on a grant nobody
gave.

An act at or below `워크트리쓰기` needs no row at all — the list exists for the
acts whose effects outlive the run directory.

**The `자동 채택` rows are the other pre-declaration, and they name a JUDGMENT
CLASS rather than an argv shape.** A judgment carrying a class one of these rows
declares clears the auto-adoption floor's first arm and is taken without asking.
The safety argument is entirely that **a run cannot write this input**: the
manifest has no append form, `## 인가` must be exactly one section, the binding
digest covers these rows, and `인가-자기확장-금지` cannot be switched off. So the
declaration happens once, in front of a person.

`판단 부류` is checked against the closed eight at freeze time, and the two that
hand risk to the user — `팀-구성` and `시각-면제` — are a **hard stop** here.
Deciding mechanically at the moment a judgment is made whether it hands risk to
the user is impossible, because the only inputs available (the option labels and
the question text) are authored by the party the check would bind. At freeze time
it is entirely mechanical. That asymmetry is why the check lives here and rests
on nothing the run declares about itself at runtime.

`심각도 상한` is a **convenience filter over a label the audit supplied, not a
floor.** The floor is the union; a document-producing stage has no unforgeable
severity predicate, and non-critical findings mostly pass because they are mostly
reversible rather than because of their grade.

**The example above is fenced with FOUR backticks** because it contains
three-backtick fences of its own. Any document that explains this grammar has
the same shape, which is why the parser that reads it has to skip fenced spans
and survive nesting.

**`사용자 확인 문면` and `승인 문면` are different things.** The latter approves
the **step graph**; the former grants **authority**. With per-target cutpoints
the authorization is an N-row table, and that table's only human anchor is
`사용자 확인 문면`. Collapsing them promotes plan approval into permission
approval silently.

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
   target rows, rule settings, pre-authorization rows, deadline. The PLAN is not
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

4·5·6 are the **verification points**. Without them fields 3·5·6 ship computed,
recorded, and never compared — exactly the state the binding-surface digest was
in.

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
own worktree while the gate writes the ledger under the main one. Measured: a
stage ran forty minutes and added 41 rows to the gate's ledger while all three
kickoff artifacts sat in another worktree, empty or untouched. Both sets exist
and both are well-formed, so nothing reports the split — and it only appears
when the document lives in a linked worktree, so a test on an ordinary checkout
cannot reproduce it. `§1.1` of `sidecar.md` explains **why** the fold exists
(N linked worktrees must converge on one location so single-writer state does
not fan out); this row is where it must not be lost.

**Per-target cutpoints and terminal-act caps live in the target rows.** A single
totally-ordered scalar cannot say "apply for infra, stop at PR for the
frontend" — not awkwardly, but at all. `런 최대 절단점` is a derived audit field
and `authorized()` does not read it; two gates that can disagree are not built.

**`벽시계 마감` is an absolute timestamp and a dispatch gate**, never an elapsed
accumulator. An accumulator that resets binds nothing — which is precisely the
defect this contract watched a backoff helper ship — and only an absolute stamp
stays correct across a reboot.

**`공통 git 디렉터리` is on every target row because of a hazard in this very
tree**: two working trees here share one `.git` and one `refs/stash`. Inferring
identity from a basename hands one namespace to two aliases silently, and the
consequence — stash attribution is per-REPOSITORY, not per-worktree — has to be
visible in the manifest rather than inferred.

### 2b.4 Compatibility is absorption, not a grace period

The manifest is the only schema. A call that supplies only a document is
absorbed as the **degenerate case**: one document, one target. No grace period,
no dead code. The ground for that is measured — this pipeline has never run
(zero grants, zero ledgers, zero run directories, zero segment branches), so
there is no population for backward compatibility to protect, and keeping two
sidecar schemas would put two code paths under the mechanisms where single
writer and fail-closed carry the weight.

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

### 3.1a Row length has a hard cap

**A row is at most 1024 bytes including its newline.** Above that, concurrent appends interleave: two independent measurements put the last clean size at exactly 1024, with corruption beginning at 1025 and line counts staying correct while field values splice. That is the shape no row-grammar regex and no `wc -l` can detect, which is why the cap is a lint rather than a convention.

Two consequences the schema carries rather than leaving to callers. Long values — a declared file set, a question text, an answer text — are fenced per `sidecar.md` §2.5 or moved to a sidecar, never inlined. And the `prev=` chain field of §3.4a spends roughly 70 of those bytes, so the budget a writer actually has is smaller than the cap suggests.

### 3.2 The row series is closed at fourteen

**A writer that needs a kind not on this list extends this definition; it does not improvise one.** The absence of that rule is what produced a ledger whose own sections disagreed about who wrote what.

The count moved from nine to eleven when the gate acquired two records the existing series could not carry: an approval is not a decision the run made (`자율 승인`) and not a stop (`blocked`), and a deferred review obligation is neither. Both are **non-terminal states with their own lifecycle**, which is precisely what no existing kind models — every one of the nine is either a fact about something that already happened or a stop. Extending the definition rather than overloading a kind is what this section's own rule requires, and the two additions are stated here rather than improvised at the call site.

**The last two are a reconciliation rather than an extension, and the difference matters.** `종료 절` and `문서 해시` were already being written by the gate while this table did not list them — so the table was not a closed definition at all, it was a partial inventory that read like one. A contract that under-reports what its writer emits is worse than one that over-reports: a reader checking whether a series exists gets "no" for something the ledger is full of. They are listed now with the fields the gate actually writes.

| `계열` | Fields |
| --- | --- |
| `run` | `run-id` · `시작` · `설계 문서` · `전체 sha256` · `구속면 다이제스트` · `RUN_DIR` · `보고서` |
| `generation` | `세대` · `전체 sha256` · `구속면 다이제스트` · `세그먼트 계획` · `segmentation`(`ok` \| `low-confidence`) |
| `segment` | `id` · `선행` · `선언 파일 집합` · `plan-binding-digest` · `상태` · `브랜치` · `PR` · `커밋` · `사전 HEAD` · `베이스 sha` · `워크트리` |
| `stage-result` | `세그먼트` · `스테이지`(S-id) · `종류`(stage kind) · `종료 코드` · `아티팩트 술어 결과` · `plan_sha256`(`implement` only) · `실행 버전` · `세션 id` · `부모` · `종단 부류` |
| `cycle` | `세그먼트` · `사이클` · `리포트 경로` · `P0` · `P1` · `P2` · `P3` · `lane 결정` |
| `problem` | `동일성`(`정규화 경로` + `카테고리 태그`) · `현재 단` · `단 이력` · `payload`(근본 원인 문구) |
| `자율 승인` | `kind` · `판단 부류` · `결정` · `기각된 대안` · `근거` · `등급` · `기준` · `되돌리는 법` · `자격`(`분리` \| `주변`) · `finding-id`(required iff `kind=severity`) |
| `cost` | `누적 usd` · `스테이지 수` · `관측 시각` |
| `blocked` | `대상` · `스코프`(act\|cone\|run) · `원인`(막힘\|무효화\|불명\|판정 불가) · `사유` · `근거` · `앵커 세그먼트`(scope `cone`) · `의존 세그먼트`(scope `cone`) · `관측` · `재개 명령` |
| `승인` | `승인 id` · `상태` · `대상` · `절단점` · `행위 다이제스트` · `구속 튜플` · `막는 세그먼트` · `질문 문면` · `답변 문면` · `발행 시각` · `해소 시각` |
| `리뷰 의무` | `의무 id` · `상태` · `세그먼트` · `머지 커밋` · `생성 등급`(축 2) · `발행 시각` · `이행 시각` |
| `대상 추가` | `별칭` · `원격 슬러그` · `메인 워크트리` · `공통 git 디렉터리` · `베이스 브랜치` · `층`(0\|1) · `발견 경로` · `기록 시각` |
| `종료 절` | `id` · `상태`(충족\|불가능\|보류) · `근거` |
| `문서 해시` | `스테이지` · `sha256` · `동결값` · `관측` |

**Every declared series has a writer, except one — and that exception is the rule holding rather than an omission.** Five of the twelve were written by nothing, and the cost of that was not untidy bookkeeping: each series that nothing writes turns the check reading it into a constant. `cost` is the only input the cost boundary has, so it read an empty set, took its fail-open guard — a guard whose whole shape assumes a missing value is temporary — and could never fire however low the declared ceiling was. `problem` is what every open obligation is derived from, so obligations were always zero and the termination condition asking whether they are empty held vacuously; the narrow excuse rule beside it could not be reached at all. `stage-result` is where the terminal classes are counted and where the implementation-review separation rule reads ancestry, so that rule returned early and passed on every run it exists to catch.

They are written from three different places, because the three have different knowledge. `run` is written once at run open, by the gate. `stage-result` and `cost` are written by the gate when a stage terminates, from the stage's **own** terminal result line — its cost, its subtype, its session id — so nothing here depends on a stage reporting anything about itself. `problem` is an `act` kind like `segment` and `cycle`: recognising that a finding is the same finding as last cycle's is a judgment, and the router is where judgment lives.

**`generation` is deliberately still unwritten.** Nothing reads it. A writer for it would put a value in the ledger that is recorded and never compared, which is the exact defect class this contract exists to remove — so the writer arrives with the reader or not at all.

**The terminal class the gate writes is a strict subset, and the omission is deliberate.** From outside a stage it can distinguish `크래시` (a non-zero status, or a subtype that is not success), `정상 완료` (the stage performed at least one gated act), `산출물 없는 정지` and `공허한 성공` — the last two separated by whether the stage's own transcript carries a `permission_denials` entry, which is precisely the "trace of reaching a decision point" this contract asks for. `의도된 park` and `적용 불명` are **not** written from here: both are claims about the stage's intent, they are read from its halt record, and guessing them from outside would put an unverified value in the ledger.

**`segment` and `cycle` have a writer on the router path, and both are `act` kinds rather than a seventh verb.** The fixed-graph loop used to be their only writer, which the router never enters — and the absence was not a gap in bookkeeping. The merge rule reads a `cycle` row, so with no writer it refused **every** merge for want of a row no path could produce; termination condition 1 counts `segment` rows, so a run could never propose that it was done. Both read as the mechanism working. `act --kind segment` and `act --kind cycle` take **`키=값` fields after `--` instead of a command**, because what they perform *is* the row; they grade `읽기`, since a row reaches nothing a cutpoint or a credential could widen. A `segment` row is refused without a `상태` in the vocabulary below and without a `워크트리` — the merge rule enters that directory to read the branch's current HEAD, so a row missing it turns a review refusal into one that names a missing worktree. A `cycle` row is refused without `사이클`, `P0`, `P1` and `리뷰 HEAD`, which are exactly the four that rule reads.

**`자격` records which credential each act actually ran under.** With neither pipeline credential provisioned the gate falls through to the ambient one — on a developer machine a full-scope login — and the fallback is kept, because refusing would stop every host that has not provisioned one. What is not kept is the silence: `주변` on the row is how the morning tells a run that had the separation from one that only appeared to.

**`승인` advances by appending, never by editing** — the same discipline `segment.상태` already takes (§3.4). A row carries the `승인 id` it advances; readers take the last row for an id as current. Everything needed to re-issue the question after a session cut is on the row, which is what makes the resume path have a source rather than a memory.

**`절단점` on a `승인` row is not always a cutpoint token.** Three shapes share the series because they share the lifecycle: an **act** approval carries a `CUTPOINTS` token and a binding tuple of `(대상 별칭, 슬러그, 행위 토큰, argv 다이제스트, 브랜치, head_sha, base_sha, PR 번호, 리뷰 리포트 다이제스트, 열린 P0·P1)`; a **judgment** approval carries the literal `판단` and a tuple of `(스테이지 id, 질문 문면 다이제스트, 선택지 집합 다이제스트, 스냅숏 다이제스트)`; a **boundary** approval — issued by B1–B4, which have no act at all — carries the literal `경계` and a tuple of `(경계 이름, 발동 시점 H, 관련 세그먼트 집합)`. Staleness is re-derived at execution against whichever tuple the row carries, so the three do not need three series.

**A pending approval has two ends, not one.** `무효` is reachable through the same transcript binding as `승인`, and it exists because the alternative to granting was pending forever: a pending row counts against termination condition 2 and suspends the stagnation boundaries, so one approval nobody wants to grant stalls the rest of the run. Voiding **removes a blocker**, so it is not the conservative direction and does not get a looser gate — it keeps the requirement that a human line naming both the id and the question text appear in the harness-written transcript. What it buys is the ability to answer *this should not have been asked* without also granting the act.

**`질문 문면` and `답변 문면` are fenced or sidecar'd, not inlined.** A row must stay inside the row-length cap of §3.1a, and a question with four option descriptions does not.

**For a `절단점=판단` approval, `답변 문면` carries the answer BYTES.** For an act approval the answer is binary — the act happens or it does not — so the fixed literal `트랜스크립트 판독` lost nothing, and act approvals keep it. A question's answer is what the next step consumes, and this row is the run's only durable copy of it: recording only that a person answered means the run kept the fact and threw away the content. The excerpt is normalized before it lands — `|` and newlines would splice the row grammar — and clipped with a visible marker rather than silently, because a silent truncation reads in the morning as the whole answer.

**`대상 추가` records a repository the run reached that the manifest did not name, and it is a RECORD rather than a grant.** The distinction is the whole of it. A declared target already has a cutpoint the manifest gave it, and an approval there opens one act inside that grant; an undeclared repository has no cutpoint to open, so a row that conferred one would move the seat of authorization from the manifest to a file the run writes. That is the property the split-writer rule exists to hold, and it does not depend on whether the row could be forged.

So the row's `층` is `0` or `1` and never higher. Layer 0 is read-only — clone, fetch, read, run that repository's tests — already reachable with arbitrary bash, so refusing it buys nothing and recording it buys the morning report. Layer 1 is local commits and branches, capped at `브랜치`, and the cap is **hardcoded rather than inherited or chosen**: nothing above `브랜치` leaves the machine, so no approval is needed and the split-writer rule is untouched. A layer-1 row is admissible only after the same preflight a manifest target gets — the main worktree exists and the common git directory matches — because stash attribution is per-REPOSITORY rather than per-worktree, and this very tree already has two working trees sharing one `.git` and one `refs/stash`.

`push` and above take neither path. They park with the cause `대상 미선언`, and the resume command is the re-kickoff that writes a successor manifest.

**`리뷰 의무` exists because `선머지후리뷰` defers an obligation rather than removing one.** Its `생성 등급` is the axis-2 grade of the act that created it, which is the field the run's termination conditions read — an obligation created by an act graded at or below `워크트리 쓰기` is excusable when its segment parks, and one created above that is not.

**`실행 버전` belongs to `stage-result`, not to `segment`.** The session uuid is derived from `owner-doc|구간|단계|시도`, so `시도` must be durable — otherwise a reboot re-derives a uuid already bound to a different transcript. Attaching the field to the per-stage row is what makes that durable at the right granularity.

**`stage-result` is what removes the last edge into stage-owned ledger writes.** Its every field is observable by the driver from outside the stage: an exit code it waited on, artifacts it can stat, a digest it can compute. Nothing here requires the stage to report anything.

**`세션 id` and `부모` are the ancestry record, and without them the implementation-review separation rule is vacuous.** That rule asks whether a review stage's session is disjoint from the implementation's. While session ids are *derived* from `owner-doc|구간|단계|시도` they differ by construction, so the comparison is a tautology and passes on every run including the ones it exists to catch. Recording the id the harness actually assigned, plus the id of the session that spawned it, turns the rule into a real ancestry-closure check — and a fork inherits its parent, so a forked session cannot review its own work by taking a new id.

### 3.3 Closed vocabularies

| Field | Values |
| --- | --- |
| `자율 승인.kind` | `lane` \| `citation` \| `severity` \| `visual-waiver` \| `verification-residual` \| `audit-composition` \| `unresolved-issue` \| `refinement` \| `roster-degradation` \| `stage-retry` \| `target-expansion` |
| `자율 승인.판단 부류` | `문서-신선도` \| `감사-발견` \| `심각도-조정` \| `잔여-항목` \| `인용-갱신` \| `스테이지-재시도` \| `팀-구성`(pre-adoption forbidden) \| `시각-면제`(pre-adoption forbidden) |
| `자율 승인.등급` | `0` \| `1` \| `2` |
| `승인.상태` | `대기` \| `승인` \| `거부` \| `무효` \| `기각` |
| `자율 승인.자격` | `분리` \| `주변` |
| `승인.절단점` | a `CUTPOINTS` token \| `판단` \| `경계` |
| `리뷰 의무.상태` | `미이행` \| `이행` |
| `대상 추가.층` | `0` \| `1` |
| `blocked.사유` | `인가 한도` \| `사다리 R4` \| `사다리 단 부재` \| `사이클 예산 소진` \| `자동 채택 미달` \| `자동 채택 불성립` \| `예산·벽시계` \| `게이트 park` \| `시각 정합 park` \| `외부 상태 불확정` \| `대상 미선언` \| `강제 표면 이동` \| `라이브니스 침묵` |
| `blocked.스코프` | `act` \| `cone` \| `run` |
| `blocked.원인` | `막힘` \| `무효화` \| `불명` \| `판정 불가` |
| `종료 절.상태` | `충족` \| `불가능` \| `보류` |
| `stage-result.종단 부류` | `정상 완료` \| `의도된 park` \| `공허한 성공` \| `크래시` \| `적용 불명` \| `산출물 없는 정지` |
| `segment.상태` | `계획됨` \| `실행중` \| `리뷰중` \| `머지됨` \| `완료` \| `적용 준비` \| `park` |
| `generation.segmentation` | `ok` \| `low-confidence` |

**Three of the values above are a reconciliation with the artifacts, not a widening.** `blocked.사유=강제 표면 이동` and `=라이브니스 침묵` are written by the gate's surface check and by the watcher's stall transcription, and `segment.상태=완료` is accepted by the gate as a terminal state — all three were in the ledger while this table said they were outside the vocabulary. **Nothing is REMOVED from the table for being unobserved**, and that asymmetry is deliberate: a declared value that no artifact carries means "not seen yet", not "does not exist", and deleting it would make the next writer improvise a synonym.

**`자율 승인.kind` does not carry a classification, and this line states what it does carry rather than repairing the table above.** On the gate path the field holds the **act kind** the decision was attached to, and on an `exec` call it is empty; only the legacy fixed-graph path ever put a classification there, and that writer leaves with the fixed graph. The table's eleven tokens are what that legacy writer declared, kept for reading old rows.

**`자율 승인.판단 부류` is where a classification actually lives, and it is a new field for a reason that is not tidiness.** The auto-adoption floor's first arm asks whether the manifest declared this class in advance; on a field that also carries the act kind, one manifest line reading `종류=skill` would pre-adopt every stage dispatch there is. Moving values onto a polluted field inherits the pollution. And the ledger is append-only with deletion forbidden, so the rows already written can never be repaired — a new field has zero legacy rows, which is what lets the lint assert the closed set with no exception.

**The two forbidden values are IN the vocabulary and forbidden there, rather than left out.** A class with no token does not stop being decided; it forces whoever records the decision to borrow a permitted token, and the borrowing is the leak. Named and forbidden, the leak arrives as a refusal. The refusal is at **freeze time**: `check_manifest` compares every `자동 채택` row's class against the eight and hard-stops on either of the two, which is a check that runs while a person is present and rests on nothing the run says about itself at runtime. Recording a judgment OF that class is still permitted — what is forbidden is pre-adopting it.

**`segment.선행` and `segment.선언 파일 집합` are carried by the router and consumed by the gate; neither is authored by either.** The authority is the design document's slice declaration. `선행` is the cone's declared axis — the only axis that sees a dependency before the predecessor merges — and `선언 파일 집합` is the sole input to "did this segment reach outside what it declared", a question git cannot answer at all.

Two floors sit on `선행`, and the cone's superset check cannot supply them, because `선행` is an *input* to the derivation the superset check compares against: declaring narrowly shrinks both sides together. So they are enforced at write time. **It is monotone per segment id** — a later row may add and may not remove, since rows are append-only and the last one wins, which makes the lie that pays a retroactive one. And **absence is not `없음`** — in a repository carrying two or more segments a `segment` row with no `선행` is refused, while `없음` is accepted as a positive statement of independence. Read later the two are the same empty set; write time is the only moment the difference exists.

**`blocked.스코프=cone` is the one scope the router may CREATE, and the polarity is the opposite of run scope's.** A run-scope block is raised by the gate and only resolved by the router, because a router that could invent one would be inventing the state that governs whether the run may end. A cone is not a run stop: it holds what stands on a refuted premise and lets the siblings keep going, which is exactly the disposition an open question needs. The gate does not take the router's `의존 세그먼트` on trust — it derives the cone itself and refuses a declaration that is a proper subset. Widening passes; narrowing does not.

**`blocked.원인=판정 불가` records an ancestry probe that could not be answered, and its disposition is fail-closed.** `git merge-base --is-ancestor` distinguishes three outcomes, and only exit 1 means "not an ancestor"; 128 means an object is not there — a vanished worktree, a damaged object database, a permission failure. Reading that as "not an ancestor" would turn every fault into "not in the cone, so nothing is held", which is an unconditional fail-open. So the segment **stays in the cone** and the row says what could not be measured. What the morning reads is *this could not be judged*, not *this was judged and stood up*.

**`종료 절.상태=보류` is not `불가능` with a softer name.** Impossible ends the clause forever; on hold says a person's answer is outstanding and a successor run picks it up. Its `근거` must therefore name an **open** approval whose cutpoint is the literal `판단`, and the gate confirms that id exists in the ledger with `상태=대기` — evidence rather than wording, on the same terms every other clause settlement takes.

**`승인.절단점=판단` finally has a writer, and the writer is the gate.** The router never chooses to ask: it submits its own recommendation through `act --kind judgment`, and whether that becomes a question is decided here. A grade-2 judgment is raised to one — the old refusal said so in as many words while refusing, and no such path existed anywhere — and so is a grade-1 judgment that does not clear the auto-adoption floor. The approval's id is derived from the judgment rather than from an argv, so the same judgment submitted twice yields one approval instead of a queue, and its **binding tuple is `-`**: an act approval carries head and base shas because its answer is valid only against the tree it named, while a question's answer is an input to work that has not started and has no tree to measure.

**That durability is also why termination condition 2 excludes it.** An act approval's window closes with the night, so a run may not end while one is open; a question's answer survives into a successor run. Counting questions there made one open question a run that could never say it was done — the exact failure this design removes. What records the residual instead is a third class in the `done` file, `종단 — 질의 잔여 N건 · 승인 <id>…`, sitting beside `무효화` for the same structural reason. **No eleventh termination condition is created**: a condition exists to *refuse* a proposal, and an open question must not refuse one.

**`산출물 없는 정지` is the sixth terminal class, and it exists because a stage that correctly refused to decide for the user was punished exactly like one that produced nothing.** Measured: a headless stage reaching a point where it must ask has no `AskUserQuestion` — it read the document, failed a `ToolSearch`, chose none of the options, and left the file byte-identical. It did not improvise. But the driver saw exit 0, no artifact and no halt record, called it `공허한 성공`, retried once and parked for "no artifact".

Its definition is the four-part conjunction: **exit code 0, artifact predicate false, no halt record, and a trace in that stage's ndjson of reaching a decision point the skill directed it to.** The last clause is what separates it from `공허한 성공` — not "attempted nothing" but "arrived and did not decide". Its disposition is not a retry: the point is promoted to a pending approval, and that promotion is the recorded skip the unattended `design` step-6 default calls for.

**The scope of that measurement is n=1, one point, one model — no general law is claimed.** And the limit carries weight in the unreassuring direction: the inverted unattended default rests on stages being conservative, and the one point actually tested was the case where a refusal was *most* likely.

**The other branch is worse because it is invisible.** A stage that improvises and produces output lands as `정상 완료`, since the audit and review predicates are forgeable — this contract says so itself. So the morning report's heading is `기록된 자율 결정` rather than "every autonomous decision": measured, the latter is false. One branch is mispunished and the other is not observed at all.

**One control partially recovers the second branch.** In Mode A the router owns the stage's ndjson, so a `ToolSearch` naming `AskUserQuestion` with no halt record is a high-precision signal that the stage improvised. It does not fix anything; it turns an unobservable failure into an observable one.

**Every park names a scope and a cause, and one that cannot is a bug rather than
a decision.** `act` means a terminal act is blocked and NOTHING else stops — the
segment's artifacts survive and it is reported as 완성-미착지. `cone` means a
premise downstream work stands on has been refuted, so what depends on it stops
and its siblings do not. `run` means the run cannot judge the state a later
irreversible act would transform, or its own anchor is invalid; it stops the
declared blast radius. The anti-rule these exist to enforce: **a blocked act
never escalates to a cone or a run stop, and the absence of an answer is not a
cause.** Without it one cutpoint typo parks every segment and the night produces
nothing; with it every segment reaches its pull request and the blocked terminal
acts pile up in the morning report next to the commands that finish them.

**`사이클 예산 소진` is separate from `사다리 R4` because they are different
events.** The cycle cap is the most common park a long run produces and the
ladder's terminal rung is among the rarest; filing the first under the second
makes the ledger say the ladder ran out when it never started. `사다리 단 부재`
is a third thing again — a transition into a rung this run's authorization does
not make available. It is a park and not a clamp: clamping the rung would make
the terminal-rung branch unreachable and disarm the ladder's only end.

**`적용 불명` is its own termination class and not a kind of crash.** A crash is
an execution that did not complete; this one completed and left a state nobody
can describe. Folding it into `크래시` would say the wrong thing to the person
reading the morning report, and folding it into `게이트 park` would file the
heaviest outcome a run can produce under its most common token — the same defect
this contract already indicts elsewhere. `적용 준비` is likewise separate from
`실행중`: it names a worktree pinned to a merge commit, which is the artifact a
person needs when an apply's outcome is unknown, and a state that says only
"running" does not tell them it exists.

**Severity adjudication and parking are not new kinds.** A severity tie-break is a `자율 승인` row with `kind=severity`; a park is a `blocked` row with a `사유`. Reusing the two existing series with a required discriminator is what keeps those two cases out of the count while still making each findable.

**An approval and a review obligation are new kinds, and the test that separates them from the paragraph above is lifecycle.** A severity tie-break and a park are each *finished* the moment they are written — the row records a thing that happened. An approval is issued, waits an unbounded time, and then resolves or goes stale; a deferred review obligation is created at a merge and discharged much later or not at all. A kind whose rows advance through states cannot be a discriminator on a kind whose rows do not, because the reader of the existing kind takes every row as terminal. That is why these two extend the definition and the earlier two did not.

**`되돌리는 법` is the field that makes the report readable rather than merely complete.** A report enumerating fifty autonomous decisions a person cannot act on is a log, not a report. "Only the important ones reach me" is bearable exactly when the unimportant ones are **cheap to undo in the morning** — and that is a property of the record, not of the decision. So the field carries a concrete command or edit, not a claim.

It also replaces an unfalsifiable judgment with a producible artifact. The router does not assert that an act is reversible; it produces the thing that reverses it, and failing to produce one is itself the escalation trigger. A false undo command is a lie a person catches in the morning; a false reversibility judgment leaves no trace at all.

**`등급` and `기준` come from the judgment-grade contract** (`_common/judgment-grade.md`). `기준` names the authored standard that chose the option — "the model was confident" is not one, because the point of the field is that a later reader can check it. Grade 0 writes no row at all: a rule that fully determines the answer produced no decision to record.

**`kind=severity` requires `finding-id` for a reason that is not bookkeeping.** The shipped review rule defaults to the higher severity *unless the lead resolved the dispute*, and unattended there is no observable event that makes "the lead resolved it" true or false. So the exception counts as fired **only** where a `자율 승인` row records the decision, the rejected alternative, both rationales, and the finding it applies to; with no such row the rule's default branch applies. This enforces the rule's own third sentence rather than overriding it, and the interactive path is unchanged.

### 3.4 Write form and its diff gate

One write form: **append** — a new row, or a new `## 실행 <run-id>` block. Gate: **0 removed lines**. `segment.상태` advancing is expressed as a **new `segment` row** for the same `id`, not as an edit; readers take the last row for an `id` as current. This keeps a single append gate for the whole schema and leaves the run's history intact for the morning audit.

### 3.4a The chain, and why it is not only about forgery

Every row carries `prev=<64 hex>` — the sha256 of the preceding row's bytes. The first row of a block chains to the block heading.

It was proposed as anti-forgery: a run that writes its own ledger can otherwise rewrite what it recorded, and a chain makes that visible. But the same field settles a defect nobody expected it to. §3.1a's interleaving corrupts rows in a way that **no row-grammar check can see** — the line count stays right and the field values splice — and a splice is, to the chain, indistinguishable from a rewrite. So one mechanism detects both, and deletion and reordering with them.

**Why that matters more than tidiness.** A spliced row can satisfy a termination condition that the true rows do not, and the run then stops reporting success on a state that never existed. Corruption here does not merely lose information; it **manufactures a false completion**. Serializing writes with an advisory lock keeps interleaving rare; the chain is what makes the rare case detectable rather than silent.

**Single writer is a property of components, not of processes.** The driver's comment says the ledger has one writer, and that is true of the *component*: one function appends. It is not true of the *processes* — each gate invocation is a separate shell, so two acts in flight are two writers against one file. The lock is therefore mandatory rather than defensive, and the chain is what catches the window the lock does not cover.

### 3.5 The morning report is a ledger-referenced companion

The report lives at `<base>/docs/pipeline-run/{runId}.md` — the same `<kind>` directory and the same kind token, so **no new kind is created** and the §1.2 guards apply to it unchanged. It is named by `<run-id>` rather than by `{slug}`, which means it is **not independently re-derivable** from the design document the way §1.1 sidecars are; it is found through the `보고서` field of the `run` row. That is the whole of the difference, and it is why run-id naming is admissible here and was rejected for the ledger: the ledger must be findable with nothing but the document in hand, the report must not.

- **Writer**: the driver. **Created as a stub by `autopilot` at kickoff**, so the file exists even if the run dies mid-way.
- **It must be durable independently of any banner**, because the notification seat's contract does not include delivery confirmation. The report is the source of truth; the banner is a courtesy. Every event writes the report **first** and attempts the banner second — the immediate-notification events included — since a seat with no delivery confirmation can otherwise leave a banner as the only record of something nobody saw.
- **No push adapter is seated today, and that is a stated limitation rather than a pending task.** The driver has no tool inventory, so a push surface would have to be reached by dispatching a stage — and a spawned stage is barred from deciding whether a banner reaches the user. The seat's three operations stay defined so an in-process implementation can drop in, but until one does, **the run may not reach a sleeping user at all**. Nothing downstream may assume it does; the morning report is the whole of the guarantee.
- **It enumerates every autonomous decision the run RECORDED** — the heading is `기록된 자율 결정`, and the qualifier is measured rather than modest: a stage that improvises and produces output lands as `정상 완료` and writes no row, so a heading promising "every" decision would be false — all `자율 승인` rows grouped by `kind` with decision, rejected alternative and rationale carried verbatim; every fix the ladder auto-adopted; every parked item with its `사유`; and each stage's `종단 부류`.

**The limit is stated with the control.** The report is itself authored by the run, so it is powerless against a run that improvises a decision **and also** omits it from its own report. The conjunction being rarer than either part is the whole of this control's value — it is not a gate, and **the real protection against an irreversible autonomous act remains the permission cutpoint of §2.3.**

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
**재호출 명령**: <the command line the skill would have emitted, verbatim> | (없음)
**후속**: 보류 큐
<!-- /cc-pipeline-halt v1 -->
```

- **Written with the atomic form of `sidecar.md` §1.3** (temp file in the same directory, then rename), so a partial record is never observed. The closing fence is the terminator: a record whose last non-empty line is not `<!-- /cc-pipeline-halt v1 -->` is **a crash mid-write, not a halt**.
- **`재호출 명령` is inert.** The driver records it and **never executes it**. Auto-running it retries a condition whose cause is still present, which makes a single pass into a bounded-only-by-budget loop — and does so precisely when the tree has been *proven* to be in motion. The field is named for its inertness because attributing that in prose is not enough: the predictable failure is a future implementer wiring it to a dispatcher.
- **Termination discipline**: write the record atomically → take **no further step** (no cleanup beyond what the halting step already committed, no partial progress, no fallback act) → end the turn normally.
- **The discriminator is the artifact, not the exit code.** A halt is a *clean* stop, so its terminal envelope looks like a normal completion, and a model-driven skill cannot set an exit code to mean otherwise. **Exit says the stage ended; the halt record says why.** Both are machine-read; neither is prose.
- **The volatile run directory is deliberately not durable.** Process handles — `stage-pid`, process-group id, transcript paths — live here and nowhere else, so a stale record and a stale process die together and pid reuse cannot make the driver kill an unrelated live process. It is under `XDG_STATE_HOME` rather than `${TMPDIR}` because `/var/folders` is swept without a reboot, and "no record ⇒ no process" must not be falsified by a sweep.

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
| `design-reconverge` | `docs/design-reconverge/{slug}.md` carrying `재수렴 sha256` and a two-value verdict (`재설계 필요` \| `불필요`), plus its confirming fixed literal. A terminal verdict returns to segment planning **unconditionally** |

**The predicates are not equally strong, and pretending otherwise makes the table read stronger than it is.**

> **A predicate over state the stage cannot fabricate — a git ref, a remote ref, a PR number — is immune to a hollow success. A predicate over an artifact the stage authors is not.**

`implement` meets that bar: a run that answered in prose and moved on produces no commit, so the ladder is false and the driver never consults the stage's self-report. `design-audit` and `review` do **not** meet it — a model that improvised past a question still reaches the skill's normal exit, emits the terminal literal, writes the reader copies, and writes a well-formed summary line. **For a stage whose only output is a document, no un-fabricable predicate exists.** That is recorded rather than papered over.

### 5.2 The four termination classes

Exit status and the artifact predicate are **independent axes**, and the halt record is the third. Crossing all three is what separates "it died" from "it believed it was finished".

| exit | predicate | halt record | class | driver action |
| --- | --- | --- | --- | --- |
| success | true | — | `정상 완료` | next stage |
| success | false | present | `의도된 park` | blocked queue, no retry |
| success | false | absent | `공허한 성공` | retry **once**, then blocked queue under a distinct reason |
| non-zero | false | — | `크래시` | retry at the boundary, `시도+1` |

Priority on read: **a halt record present ⇒ halt.** Absent and terminated ⇒ judge by the predicate.

The third row is a measured failure mode, and its retry count is argued in both directions: not zero, because one observation cannot rule out a transient cause; not the full retry budget, because a clean exit with no artifact is itself evidence that the next attempt does the same. Improvisation is deterministic, so a blind retry loop would reproduce it identically and burn the whole budget before reaching the ladder. **This does not restore the stop that the unattended arm removed** — nothing on the skill side can. It converts an unobservable failure into an observable one, which is the most the driver can do from outside.
