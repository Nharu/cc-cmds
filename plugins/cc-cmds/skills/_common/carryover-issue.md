# Carrying review findings over to issues

A segment whose snapshot `review_next[]` element reads `다음` `이월` has a last
review cycle with no P0 and one to three P1 findings, every one of which its
review classified `이월 가능` and wrote up as a follow-up. This file is the one
procedure the routing shifts and the driver follow to carry those findings
over: one issue per finding, then the `리뷰 이월` row, then the merge. The row's
contract is `pipeline-sidecar.md` §3.2; the report grammar it reads is the
review report template's `### P1 분류 기준` and its P1 item shape.

**The order is fixed: issues, then the row, then the merge.** There is no state
with a row and no issues, because the row names the issues. There is a state
with issues and no row — a shift that died between them, or a row the gate
refused — and the reuse search in step 3 is what keeps the next attempt from
opening the same issues twice.

## 1. Read `다음` and the cycle

Take the element of `review_next[]` whose `세그먼트` is this segment. Go on only
while its `다음` is `이월`; `이월 머지` means the row already landed — go
straight to the merge — and any other value is that value's own disposition.
Keep the element's `사이클`, `리뷰 HEAD` and `리포트 경로` (absolute). The
cycle carried over is that one and no other: the gate refuses a row that names
any cycle but the segment's last.

## 2. Read the carry-over items from the report

Every read is a gate call (`gate.sh exec … --surface 읽기`), one command per
call with no pipe after it. The items are in the report's P1 section — from the
line that begins `## 🟠 P1` to the next line that begins `## `:

- an item's tag line is the line carrying `**[이월 가능]**`; items come in the
  order their tag lines do;
- its title is the text after `    - **이월 제목**: ` (four spaces) within the
  item;
- its body is the lines after `    - **이월 본문**:` that begin with exactly six
  spaces, up to the first line that does not; strip those six spaces.

The number of items is the cycle's `P1`. The gate checked the shape when the
cycle row was written and checks the count again when the row is written, so
an item that does not read this way is a report the gate would not have called
eligible: stop, and treat it as the failure in step 6.

## 3. One issue per item

For the k-th item:

- **Title**: `[이월] <run-id> <세그먼트> 사이클 <사이클> — <이월 제목>`. The run
  id is part of it because segment ids (`1`, `S2`) repeat from run to run.
- **Body**: the body lines from step 2, then one more line,
  `PR #<n> 의 리뷰 사이클 <사이클> 에서 넘어온 항목입니다.`, where `<n>` is the
  segment's pull request. Nothing else is added — the review wrote the body once,
  so every path files the same bytes. Write it to
  `$CC_PIPELINE_RUN_DIR/carry/<세그먼트>-<사이클>-<k>.md` with the file-edit tool.

**Reuse before creating.** Search the target repository's open issues for the
title prefix:

```
gate.sh exec … --cutpoint 커밋 --surface 읽기 --reach 협업 \
  -- gh issue list --repo <slug> --state open --search '"[이월] <run-id> <세그먼트> " in:title' --json number,title,url --limit 100
```

An open issue whose title ends, byte for byte, with ` — <이월 제목>` and starts
with `[이월] <run-id> <세그먼트> ` is this item's issue: take its URL and create
nothing. That covers a shift that opened the issue and died before the row, and
a merge refused after the row so the same carry-over comes round again.
Otherwise create it:

```
gate.sh exec … --cutpoint 커밋 --surface 외부상태변경 --reach 협업 \
  --rationale '리뷰 이월 — <세그먼트> 사이클 <사이클> 항목 <k>' \
  -- gh issue create --repo <slug> --title '<제목>' --body-file <본문 파일>
```

The URL is the command's last output line. A failed create is tried once more;
a second failure is step 6. **Do not add `--assignee`.**

**The project is best effort.** When the manifest preauthorizes
`gh project item-add` for the target, put each issue on the project the
manifest names, declared the same way as the create. A refusal or a failure
here is noted in `--rationale` of the next act and does not stop the carry-over.

## 4. The row

```
gate.sh act --manifest <매니페스트> --kind review-carry --target <alias> --segment <id> \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest <H> \
  -- '사이클=<사이클>' '리뷰 HEAD=<리뷰 HEAD>' '건수=<P1>' '이슈=<url>,<url>,…'
```

`이슈` lists the URLs in item order, comma-separated with no spaces. The gate
stamps `세그먼트`, `레인` and `기록 시각`; passing any of them is exit 2. Exit 2
means the call is wrong — the cycle, the count or the URLs; fix the argv once
from the gate's wording. Exit 3 means the run's state refuses it: either the row
already exists for this cycle (read `다음` again — it is `이월 머지`) or the cycle
is not eligible (it is `수정`).

## 5. Read `다음` again, then merge

Take a fresh snapshot. Merge only when this segment's `다음` now reads `이월
머지`, exactly as a passed review is merged — pinned to the cycle's `리뷰 HEAD`.
The merge rule reads the same row, so a merge issued on anything else is
refused.

## 6. When the carry-over fails

When an issue cannot be created after the retry, or the row is refused for a
reason step 4 does not repair, write no row and send the segment to the fix
cycle: dispatch the implementation with the cycle's report as its fix target,
as a `수정` disposition is dispatched. `다음` still reads `이월` after a failed
carry-over — nothing in the ledger changed — so this step is the one place a
shift dispatches a fix on `이월`; do it once per cycle, and name the failure in
the dispatch's `--rationale`. Issues already created stay open; name their URLs
in that `--rationale` too, so the morning report can close them with the fix.
