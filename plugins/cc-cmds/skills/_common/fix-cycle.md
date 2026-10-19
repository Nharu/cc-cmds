# Fix cycle

**What binds.** This file binds the two unattended stages that fix a review's findings: an `implement-unattended` turn dispatched to fix a review report, and a `review-unattended` lead fix (`--lead-fix`). Each host skill points here and keeps only what is its own — where its invariants sit, where the steps below fall inside its workflow, and the lines it alone writes. Nothing here asks a person and nothing here notifies anyone: a point this file cannot settle is the host skill's halt, under the host skill's rules.

## Start condition

An unattended implementation stage runs a fix cycle when either holds:

1. the stage prompt's scope directive carries `수정 대상: <report absolute path> 의 P0·P1`;
2. the directive does not, and all three hold: the admitted plan's `Scope:` line carries the same shape, the run ledger holds at least one `cycle` row of this segment, and that plan's row stands later in the ledger than this segment's last `cycle` row.

When (1) and (2) name different reports, (1) wins. A turn dispatched with `베이스 해소:` is not a fix cycle. An unattended review stage runs a fix cycle when it is called with `--lead-fix <report>`.

Recognise the shape by its two fixed pieces alone — `수정 대상: ` and ` 의 P0·P1` — and never by the path between them or by a `(사이클 n)` or `(사이클 n 재시도)` part around them.

A fix cycle that runs as process A — its plan was voided by a re-convergence or a `재계획` row — edits nothing, as every process A. The fix check and the end-of-turn lines below belong to the process B that follows it, which is a fix cycle by condition (2).

## Fix brief

Before the first edit, read four things.

- **(가) Every P0 and P1 item of the target report.** Number them in report order as `P0-<k>` and `P1-<k>`, and check the count against the report's `발견 요약`. Items under `## 다른 슬라이스 몫 (집계 제외)` are not part of (가) and get no number. A count that does not match is a halt with `분류: precondition-failed` naming both counts: an item dropped here is a known finding nobody fixes and nobody records.
- **(나) Items of another severity in the same report that point at the same file or the same function.** They are not targets. Read them as facts the fix rests on.
- **(다) Items of this segment's earlier reports that point at the same file, with their `기준 사이클 재판정` verdicts.** The earlier reports are the `리포트 경로` values of this segment's `cycle` rows in the run ledger. A host that has no view of the ledger does not read (다); its own section says so.
- **(라) A `💡 수정 제안` is a hypothesis.** Write down every fact the suggestion rests on — a rule of another section or another file, the behaviour of an external tool — and confirm each before applying it. A premise that cannot be confirmed is not applied, and the item is recorded as `수정 불가 — <reason>`.

(나) and (다) never add targets.

## Fix check

Run after the last fix commit and before the turn ends. It has two branches.

**Branch choice.** A diff that changes any shell script (`*.sh`) takes branch 1; any other diff takes branch 2.

**Branch 1 — one fresh checker, once.** Spawn one new read-only subagent, in the foreground, once. No team, no rounds. Pass `model: "opus"` explicitly — the model a seat that fits no class of the team model tier receives. Its prompt carries, verbatim, the host skill's invariant that there is no human-question surface and the host skill's research paragraph: in `implement-unattended`, `CFI-U1` and the standalone paragraph that begins `Research is open:`; in `review-unattended`, `CFI-U0` and the whole `CFI-U8` paragraph, from its `--reach` declaration rule to its end, because that skill's research sentences sit inside `CFI-U8` rather than in a paragraph of their own. This file names the passages and holds no copy of either.

**Branch 2 — the fixer checks directly.** The fixer answers the same five questions from the same inputs itself. No subagent is spawned.

**Inputs, both branches.**

1. `git log --first-parent --no-merges -p <리뷰 HEAD>..HEAD`, with `<리뷰 HEAD>` the target report's own `리뷰 HEAD` line.
2. The brief's item text, the `💡` and the (나) items included.
3. For every changed literal, identifier, predicate name and rule wording, one repository-wide `grep`, listed as `path:line` with the diff's own hunks left out. Thirty entries in total at most; whatever is past thirty is named only, under `grep 초과`.
4. The names of the external tools the changed lines drive.

**The five questions.**

1) Is each item's defect closed in every spelling and every copy?
2) Did every other copy of a changed rule, predicate, reader or literal, and every reader of its value, change with it — and where one did not, is there a reason it need not? For every changed value set (a list of runners, spellings or states), compare it with the other lists of the same concept and name each element that is in another list and not in this one.
3) What does each external tool actually do with this spelling? For every normalisation, exclusion or literal a `💡` fixed, state what the tool accepts in the part removed or excluded. Where macOS and Linux differ, state both. Open a tool's documentation at most once.
4) Does each new regression test feed the input that triggers the defect, and does it avoid asserting the defect as the correct result?
5) Does any changed hunk carry a defect of P0 or P1 grade, by the review report template's severity system?

**What the check finds.** The same for both branches.

- On a changed hunk, or on another copy of a changed rule: fix it in this turn, whatever grade the check gave it, once, as one commit.
- On untouched existing code: record it on the `**자체 점검**` line only.
- Where the fix would land outside the declared files: do not fix it; record it on the `**자체 점검**` line as `선언 밖`.
- Do not check again after that fix.
- The check writes no report, no `cycle` row and no count. It dismisses no review finding and changes no severity.
- Nothing the check finds is a reason to halt.

**A turn that made no commit** — every item fixed outside the tree (a pull request body, say) or recorded `수정 불가` — runs neither the fix check nor the pre-push check below. Its `**자체 점검**` line reads `점검 없음 — 수정 커밋 없음`, and an item fixed outside the tree reads `P?-<k> 수정됨 — <the artefact fixed>` on the `**수정 항목**` line.

**Bounds.** The bound is kept by count: one check, one commit for what it found, thirty `grep` entries, one documentation read per external tool. The minutes these counts aim at are +12 for branch 1 and +5 for branch 2 on an implementation fix cycle, and +8 for branch 1 and +5 for branch 2 on a lead fix. The stage keeps no clock.

## Tests of a fix cycle

Run the repository's pre-push check, as its own instructions name it, once after the last commit (`make check-push` in cc-cmds). Beyond that, run the test sections the diff reaches, chosen the way the repository's instructions choose sections, on this host. A section that runs a path differently on macOS runs whole all the same. Do not run a full test-gate pass.

The `**시험 범위**` line names the sections run and the regression tests question 4 answered for. When the repository's instructions name no pre-push check, run none and write `push 전 검사 없음 — 레포 지침에 없음` on that line. When they carry no section-selection rule, choose the suites that test the files the diff changed, and say on the same line why.

**When the pre-push check or a chosen section fails, do not push.**

- If the failure narrows to one item's fix commit, undo that commit with one `git revert` commit, record the item as `수정 불가 — push 전 검사 실패: <check name>`, and run the failed check once more. This revert commit is not the one commit the fix check allows. Do not fix the failure and run again.
- If the failure does not narrow to one item, or the second run fails too, do not push: halt with `분류: precondition-failed`, and put the failed check's name and the tail of its output in `**질문 문면**`.

The commits stay, so no uncommitted path is left behind. This branch creates no new halt class. The `**시험 범위**` line names the failed check and the reverted commit.

## Rule D — a root cause outside the declared files

When an item's root cause lies outside the declared files, do not fix around it inside them. An implementation stage first fixes and commits the other items and finishes the fix check and the tests, then stops on that item with a CFI-U3 BT-STOP, naming the file and the evidence in `**질문 문면**`. A lead fix records the item as `수정 불가 — 근본 원인이 선언 파일 밖 <file>`.

## End-of-turn lines

Every terminal message of a fix cycle — a normal end and a halt alike — carries two lines of their own beside `**시험 범위**`.

- `**수정 항목**` — per item, one of `P?-<k> 수정됨`, `P?-<k> 수정됨 — <the out-of-tree artefact fixed>` or `P?-<k> 수정 불가 — <reason>`; and, per hunk that touches no item, `범위 밖: <file:range> — <why>`. A hunk that makes the same fix on another copy of a changed rule counts as touching that item.
- `**자체 점검**` — the branch run, what was fixed, what was not (`선언 밖` included) and `grep 초과`.

The three marks are different things: `범위 밖:` is a fix hunk that touches no item, `선언 밖` is a check finding not fixed because it lies outside the declared files, and `grep 초과` is a place past the thirty-entry list. The driver and the gate read no value from either line. The lead fix's `.lead-fix.md` record keeps its shape.
