# Carrying review findings over to issues

A segment whose snapshot `review_next[]` element reads `다음` `이월` has a last
review cycle that is the re-check after the lead fix, with no P0 and at least
one P1 finding, every one of which its review classified `이월 가능` and wrote
up as a follow-up. There is no upper bound on the count: every P1 is carried or
none is, and a cycle before the lead fix is never carried. This file is the one
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

## 2. Have the gate write the bodies

Do not read the items out of the report, and do not write a body file yourself.
The gate parses the report with the same parser that judged the cycle eligible
and writes one body file per item under the run directory — a directory a
session's own file-edit tool is refused, which is why the gate is the writer:

```
gate.sh carry-body --manifest <매니페스트> --segment <id>
```

It prints two lines per item, in the order the report's tag lines come:

```
이월 <k> 제목=[이월] <run-id> <세그먼트> 사이클 <사이클> — <이월 제목>
이월 <k> 본문 파일=<run-dir>/carry/<세그먼트>-<사이클>-<k>.md
```

The title carries the run id because segment ids (`1`, `S2`) repeat from run
to run. The body file holds the item's `이월 본문` lines with their six-space
indent removed, then one line naming where the item came from. When a segment
row names the segment's pull request, the line is `PR #<n> 의 리뷰 사이클
<사이클> 에서 넘어온 항목입니다.`; a segment reviewed before its pull request
opens has none, and the line is `브랜치 <branch> 의 리뷰 사이클 <사이클>(리뷰
HEAD <sha>) 에서 넘어온 항목입니다.`, with the branch from the segment rows and
the reviewed HEAD from the cycle's row. Nothing else is added — the review
wrote the body once, and every path files the bytes the gate wrote. The number
of items is the cycle's `P1`. Exit 3 means the segment's `다음` is not `이월`
or its segment rows name neither a pull request nor a branch: read `다음`
again, and treat anything else as the failure in step 6.

## 3. One issue per item

For the k-th item, take the title and the body file from step 2 as printed.

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

`<본문 파일>` is the path step 2 printed, as printed; the gate lets an act name
a file under `carry/` and no other new path under the run directory. The URL is
the command's last output line. A failed create is tried once more;
a second failure is step 6. **Do not add `--assignee`.**

The create needs no `사전 인가` row: eligibility no longer asks the manifest
for one, and the act is opened by the reach it declares.

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
stamps `세그먼트`, `레인` and `기록 시각`; passing any of them is exit 2. It
also asks the repository about every URL: the k-th must be an open issue, not a
pull request, whose title starts `[이월] <run-id> <세그먼트> 사이클 ` and ends
` — <the k-th 이월 제목>` — so a URL copied wrong names no carried finding and is
refused. Exit 2 means the call is wrong — the cycle, the count or a URL; fix the
argv once from the gate's wording. Exit 3 means the run's state refuses it: the
row already exists for this cycle (read `다음` again — it is `이월 머지`), the
cycle is not eligible (it is `잔여 보류`), or the repository could not be asked
about an issue.

## 5. Read `다음` again, then merge

Take a fresh snapshot. Merge only when this segment's `다음` now reads `이월
머지`, exactly as a passed review is merged — pinned to the cycle's `리뷰 HEAD`.
The merge rule reads the same row, so a merge issued on anything else is
refused.

## 6. When the carry-over fails

When an issue cannot be created after the retry, or the row is refused for a
reason step 4 does not repair, write no row and park the segment as a residual
(`이월 실패`). The carry-over comes only after the re-check, where no
implementation is dispatched again, so there is no fix cycle to fall back to.
`다음` still reads `이월` after a failed carry-over — nothing in the ledger
changed — and that is what the gate reads to write the residual body:

```
gate.sh residual-body --manifest <매니페스트> --segment <id>
```

It prints `잔여 제목=`, `잔여 본문 파일=` and `잔여 부류=이월 실패`; the body
lists every carry-over item. Create the one issue with the same form as step 3,
`--surface 외부상태변경 --reach 협업`, with that title and `--body-file`, then
park the segment: a `스코프=cone` `blocked` row with `원인=막힘`,
`사유=리뷰 잔여`, `이슈=<url>` and a `근거` that starts `이월 실패` and names
the failure and the URLs of the carry-over issues already opened — they stay
open. When `residual-body` exits 3 or the create fails, park with the same
`사유` and no `이슈=`, and put that failure in `근거`.
