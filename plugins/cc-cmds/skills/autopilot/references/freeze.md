# autopilot seat — the manifest and the authorization record (Step 6)

**The manifest** at `<base>/docs/pipeline-run/<run-id>.plan.md`, written **whole, once** (creation-only; there is no append form). Its shape is `## 2b.1` of `pipeline-sidecar.md` — follow that section byte-for-byte rather than the sketch of it you remember.

**It freezes the goal and the constraints, not the plan.** There is no plan digest, and the absence is deliberate: the router decides the step graph one act at a time from a snapshot, so a frozen plan would be a value that is recorded and never compared — the exact defect this contract exists to remove, arriving as a leftover.

Two digests are computed here and **compared at entry**, so they are not decoration:

- `대상 맵 다이제스트` — sha256 over the canonical serialization of every `target` row (whitespace runs collapsed to one space, then sorted).
- `구속 다이제스트` — sha256 over the whole frozen set: the goal, the termination point decomposed into checkable `종료 절` rows, the target rows, the rule-catalog settings, the `사전 인가` rows, the `자동 채택` rows, the `설계 로스터` rows, the `베이스 발행` and `베이스 설계` rows, the `세그먼트 입양` rows, the `선행 착지` rows, the `플러그인 허용` rows, the `적용 프로브 코드` row when written, the `라벨 인정` rows, the `재킥오프` row, the cost ceiling and the stagnation bound when declared, and the deadline. Both are kept rather than merged, so that a target-row edit is reported as a target-row edit instead of as "something in the frozen set moved".

**Eleven row kinds exist only when Act 1 took their input**, and all eleven go under `## 인가`:

- when 5m ran, one `- \`사전 인가\` | 인터뷰 기록=<base 기준 경로> | sha256=<전체 해시>` row. It carries no `형태=`, so it authorizes no act — the pre-authorization rule skips a row without one — and what it buys is that the record's hash is inside the frozen set;
- when 5k ran, the approved `설계 로스터` rows, one per member, in the order the person approved them;
- when 5p took rows, one `- \`사전 인가\` | <값>` row each, the value being the `형태=` and `사유=` tail exactly as confirmed;
- when 5q took rows, one `- \`자동 채택\` | <값>` row each, the value being the four-field tail exactly as confirmed;
- when 5r ran, exactly one `- \`베이스 발행\` | 트래커=<github|clickup|없음> | 대상=<값>[ | 원 티켓=<task id>]` row (the bracketed field only on a `clickup` row, and only when 5r took an origin ticket), and its `사전 인가` form rows when the tracker is not `없음`;
- when Step 4 resolved a base ticket for a child run, exactly one `- \`베이스 설계\` | 문서=docs/<slug>.md | sha256=<hex> | 티켓=T<n>` row. The gate checks its form and count only and never re-hashes the file — the design stage does that before it spawns anyone;
- when Step 2 settled an adoption, one `- \`세그먼트 입양\` | 세그먼트=<id> | 브랜치=<브랜치> | 워크트리=<절대 경로> | 출처 런=<런 id> | PR=<번호>` row per adopted segment, with the values Step 2 verified (`출처 런=-` for a branch a person made outside any run). A re-kickoff's row carries values `rekick.sh` derived again from the source run's ledger, the worktree and the remote, not values a person read back, and names the source run. The manifest check holds the row to its form only; the gate checks the worktree, the branch and the earlier run when the segment is planned;
- when 5s took rows, one `- \`선행 착지\` | 슬라이스=<id> | 원격 슬러그=<owner>/<name> | 머지 커밋=<40자리 hex>` row per confirmed predecessor, exactly as read back. The manifest check refuses a malformed row and a second row for one slice; the planning act checks the slug against the slice's `레포` and the commit against that repository's base branch;
- when 5t took plugins, one `- \`플러그인 허용\` | 플러그인=<이름@마켓> | 사유=<한 줄>` row per plugin the person picked, the `사유` being the evidence 5t named; and one such row per `plugin-allow` key 5o confirmed, and per released default the person picked at 5t, with the fixed `사유=킥오프 기본값`. The gate reads the rows when it renders the run's settings and turns those plugins on for every stage, never for the shift; the manifest check refuses a malformed row, an `@inline` or `@builtin` key and a second row for one key. A re-kickoff carries the rows byte for byte, except a row whose key is now a seed key or one no account of the kickoff has; a row whose key cannot be judged because an account file did not read is carried as it was;
- when 5u took rows, one `- \`라벨 인정\` | 대상=<별칭> | 체크=<체크 이름> | 라벨=<라벨> | 사유=<한 줄>` row per pair the person answered 「인정함」, with the check name as `gh pr checks` shows it and the label string the job compares against, both byte for byte as read back. A pair answered 「행을 두지 않음」 writes nothing. The manifest check refuses a row whose `대상` is not a target alias, whose `체크`, `라벨` or `사유` is empty or carries a `|` or surrounding whitespace, whose `체크` holds a comma, and a second row for one (target, check) pair;
- when 5c took a mapping other than the default `0/2`, exactly one `- \`적용 프로브 코드\` | 불필요=<n> | 필요=<n> | 프로브 sha256=<hex>` row, with `<hex>` measured by 5c's rule — the `**적용 프로브**` value with its backticks removed and no trailing newline, taken from the draft file by `kickoff-defaults.sh --apply-probe-sha`, never from a probe retyped into a shell command. Keeping `0/2` writes no row. **Just before freezing, run `bash <plugin root>/orchestrator/kickoff-defaults.sh --apply-probe-sha <초안 경로>` on a full draft of the manifest that already carries the row** — written with the file tool under `${TMPDIR:-/tmp}`, not at the manifest's own path — and read its `행` line, which is the driver's own manifest check on that row and does not rest on how the hash was first measured: `맞음` freezes the draft's bytes; `거부` carries the check's text — when that text says the row's hash does not match the probe, take the `프로브` line's hash into the row, say so, and run it again until it reads `맞음`; any other `거부` (two rows, a broken row) is not repaired by a hash, so rewrite the row as 5c's answer gives it and run it again. `없음` on a draft that carries the row means the driver does not read the row as written — an indented row or one under a `*` bullet reads as no row, and the run would take `0/2` — so it is not `맞음` either: rewrite the row to start at the line's first column with `- ` and run it again. A call refused by the user's permission settings or ending non-zero is not `맞음`, and the row is not frozen on it: ask 5c's mapping again, where keeping `0/2` writes no row. The manifest check stops the run on a hash that does not match, so this is the last moment a person is present to see it.

**One more row kind goes under `## 인가`, and it is not asked**, so twelve kinds in all can stand there:

- on every kickoff, exactly one `- \`재킥오프\` | 연쇄 상한=3 | 길이=<ISO 8601 기간> | 사유=<한 줄>` row, written without a toggle. `길이` is the length 5e captured, `사유` says in one line why the run may be continued by a successor. It is the person's consent that the seat may open a successor run without a person: when this run ends on its deadline, its cost ceiling or its stagnation bound, the seat's re-kickoff (`act2-seat.md` 「Seat re-kickoff」) reads the row — no row, no successor — counts the chain against `연쇄 상한`, and falls back to `길이` when the previous deadline interval cannot be carried. It is frozen into the binding set like every other row, and the seat's successor copies it byte for byte; the manifest check refuses a second row, a `연쇄 상한` that is not a positive integer and a `길이` that is not an ISO 8601 duration.

**The `재킥오프` row and Step 1.0's re-kickoff are two things that share a word.** Step 1.0 is a person calling this skill again, so that a stopped run's answers are carried into a new run through the restart helper `orchestrator/rekick.sh` and `kickoff-defaults.sh --carry` (CFI-11). The `재킥오프` row is a frozen consent that the seat may run that same path on its own, with `--auto`, after this run ends.

**A value confirmed at 5o lands where the answer to its question would have landed, in the same spelling** — the manifest and the authorization record have no field that says a value came from a default. The one trace of a default in the manifest is the fixed text `사유=킥오프 기본값` of a `플러그인 허용` row, which is the row's existing `사유` field and not a new one; the trace lines `기본값 고지` and `기본값 확정` are where that is recorded. **Re-check a deadline confirmed at 5o — or computed by a re-kickoff's `--carry`, where the re-check runs before the draft is rendered (Step 1.0 item 7) — just before writing**: run `bash <plugin root>/orchestrator/kickoff-defaults.sh --check-deadline <절대값>`. On `지남`, do not write that value — ask 5e as before and freeze the new answer; it is never resolved again. A call refused by the user's permission settings or ending non-zero counts as `지남`: a deadline nobody could check is not frozen.

**Write `리뷰 정책 상한` on every target row whose cutpoint is `머지` or above, even when the value is the strictest one.** Its absence reads as the strictest value, but on a row without the field a differently spelled ceiling that found its way into the row becomes the only ceiling there is; with the field written, the duplicate stops the manifest check instead.

**When the graph carries a design stage, the document does not exist yet, and the manifest says so rather than inventing a value.** `## 요소` → `설계 문서` is the path the stage will write — the one named in 5k, which is where the router dispatches the stage and what the audit later reads — and `설계 문서 전체 sha256` — here and in the authorization record — is `(해당 없음)`. The document's hash at each stage's end is recorded by the gate as it lands, not frozen here.

**Check the manifest against the tier before writing it, because after this nobody is here to ask.** Six refusals, each sending you back rather than freezing a plan that cannot run, and then the entry checker:

- `design_required` is true and `설계 문서` is empty or `(없음)` → back to 5k, name the document. The gate refuses that dispatch too — but it refuses it at three in the morning, with the graph already stalled behind it.
- `design_required` is true (tier `solo` or `team-4`) and `## 실행 계획` carries no step that is an object with `skill` `design` **and a non-empty `id`** → back to Step 4, insert or complete the step and add its id to every other step's `depends_on`. **Existence is not the predicate, because the shape that gets through today is a step that is present and carries no `id`** — the gate keys the stage on that field, so a step missing it resolves downstream to no design step at all, and "insert the step" on its own says nothing about one already sitting there.
- `design_scope` is `base` and the plan is not the base run's shape — `design_required` true, `design_tier` `team-4`, `steps[]` exactly `design` (no dependency), `design-audit` (depending on the design step alone) and `split` (depending on both) in that array order with three distinct ids, exactly one `베이스 발행` row in its frozen spelling (an `원 티켓` field only after the target of a `clickup` row, its value letters, digits, `_` and `-`), and a `github` tracker target equal to the `원격 슬러그` of a declared target → back to Step 4 for the graph or to 5r for the row. A `single` plan that carries a `split` step or a `베이스 발행` row is refused the same way. These are the driver's own manifest checks, so a plan that fails here fails the run's first gate call too — at a moment nobody is present to fix it.
- `design_tier` is `solo`, `design_required` is true and `## 실행 계획` carries a `design-audit` step → back to Step 4: a `solo` design is not audited, so either the step goes or the tier is raised to `team-4`.
- the plan carries no `design_path` key → back to Step 4 and write it by the entry judgment's deterministic default, then the `설계 경로` answer on a `team-4` single design. The schema requires the key and the checker reads a missing one as a plan frozen before it existed, so only this check stops a new plan from being frozen as an old one.
- `design_path` is `solo-audit` and the manifest carries a `설계 로스터` row → back to 5k: a roster is approved on the discussion path only, and the driver's manifest check refuses the pair.

Then run the entry checker on the plan as it will be frozen — `jq -f <plugin root>/orchestrator/prompts/entry-plan.check.jq <plan file>` — and treat any line it prints as a refusal of the same kind: back to Step 4. It is the file `check_manifest` runs on the run's first gate call, so a plan it refuses here would be refused there, with nobody present.

The gate already refuses the exemption unless the frozen plan requires a design and names **exactly one** `design` step, so a graph that disagrees with its tier does fail loudly overnight. What checking here buys is not detection, it is **who is present**: the person who chose the tier can settle it in one turn.

**The example in that contract is fenced with four backticks because it contains three-backtick fences of its own.** Any document that explains this grammar has the same shape, which is why the parser reading it skips fenced spans and survives nesting — and why you must not "simplify" the nesting when you copy it.

**The authorization record** at `<base>/docs/pipeline-grant/<run-id>.md` — appended through the compare-and-swap of `sidecar.md` §1.3 with the **append** form's diff gate (0 removed lines; every added line inside the new block).

```
# 파이프라인 인가 기록 — <run-id>
<!-- cc-pipeline-grant v1; writer=autopilot; reader=orchestrator; owner-doc=<document key> | (없음); origin-worktree=<홈 워크트리 루트>; NOT a design doc; mechanism-local, never staged by a skill -->

## 인가 <run-id>
**인가 일시**: <ISO8601>
**종료 지점**: <5a 답변>
**권한 절단점**: <이 런의 최대 절단점 토큰 — 대상별 값은 매니페스트가 소유한다>
**말단 행위 상한**: 없음 | <정수>
**직렬 웨이브 고지**: 수행 | 해당 없음
**시각 정합 마커**: 없음 | 있음(인가) | 있음(park)
**사용자 확인 문면**: <사용자 발화 축자>
**설계 문서 전체 sha256**: <hex> | (해당 없음)
**보고서**: <base>/docs/pipeline-run/<run-id>.md
```

**Nine fields, in that order, and the gate refuses a block that is missing any of them.** The contract fixes the count and gives this block no rewrite form — it is frozen at append, and re-authorizing is a new run rather than an edit — so a field omitted here is omitted for the life of the run. `직렬 웨이브 고지` records that the user was told the residual-item wave runs serially; write `해당 없음` when there was no such wave.

**`사용자 확인 문면` is verbatim, and it is the only field a human can audit a forged grant against.** Do not paraphrase it, do not tidy it, do not translate it. It is **not** the same field as the manifest's `승인 문면`: that one approved the step graph, this one grants authority.

**`권한 절단점` in the grant is the run's maximum**, a derived audit value. The value that authorizes an act is the one in that target's row, and the driver reads it there.

Once the manifest and the authorization record are both written, append `단계=매니페스트 기록` to the kickoff trace.

