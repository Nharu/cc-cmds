# Carryover issues — how open work leaves an unattended run

Two routes take open work out of a run and put it in an issue, and this file is
the one place their registration is defined. **P** carries the `P1` findings
of a segment whose review cycle has reached the P1 blocking ceiling, so that the
segment can merge. **N** records a no-progress boundary question that
auto-resolution closed as "continue", so that its cause outlives the run. Both
end in an `이월` row, which the gate writes and checks; this file covers what
comes before that row. The routing seat follows it from the two router
skills (`autopilot` and `autopilot-router-shift`).

Procedure detail for `gh` itself lives in the `github-ops` skill. **Its
pre-registration duplicate lookup is not called from here**: it calls an outside
API and reads a credential on a path the unattended router has not declared,
and the duplicate rules below do that job on this route.

## Titles

- P: `[이월] <세그먼트> 사이클 <n>` — the segment id and the cycle of the review
  being carried.
- N: `[무진전] <run-id>` — one per run, whatever the number of approvals.

## Bodies

`docs/` is not tracked, so a report path is not something a reader of the issue
can open. **The body carries the findings themselves.**

- **P** transcribes every `P1` item of the review report, `(미매핑)` items
  included, each with its location, its evidence and its fix suggestion as the
  report states them, and names the pull request number. The number of findings
  the issues carry — new ones and reused ones together — has to equal the
  review's `P1`; when it does not, write no `이월` row and send a fix stage
  instead, because the gate refuses a row whose `건수` is not that `P1` and the
  merge rule refuses a merge without the row.
- **N** carries, for each approval in `carryover_due[]`, its question text; the
  progress digest; every open segment with its last `stage-result`; and the
  handoff's `막힌 지점`.
- Neither body names a design document path or quotes its section labels. The
  issue has to stand on its own after the run directory is gone.

**The body goes on the argv.** The routing seat writes no files (its CFI-S5), so
it passes the body as `gh issue create --repo <owner>/<repo> --title <제목> --body <본문>`.
A seat that can write files puts a body file under `$RUN_DIR` and passes
`--body-file`; a path under `~/.config` is graded `기기전역` and is not used.

## Duplicates

- **P** opens one issue per carried cycle, for the findings no earlier issue
  carries. A finding an earlier `이월` row of the same segment already carried
  reuses that row's URL: read the issues it names with `gh issue view` (a read)
  and match the finding by location and root cause. A finding carried again in
  a later delta review therefore keeps its first URL. The row's `이슈=` lists
  every URL the cycle's findings live in, new and reused, joined by `,`.
- **N** opens one issue per run. When `carryover_due[]` grows again later in
  the run, the new approvals get their own `이월` rows naming the same URL —
  the issue is found by its `[무진전] <run-id>` title with `gh issue list
  --search` (a read). The body was written for the first approvals only, so
  before those rows add each new approval's question text and the progress
  digest to the issue with `gh issue comment <URL> --body <본문>`; a reused
  URL without it leaves the later causes in the run directory alone.

**Accepted residual.** Nothing records which finding went to which URL before
the `이월` row lands. A shift that dies between `gh issue create` and the row
leaves the next shift no trace of that issue, and it opens the same title a
second time. The duplicate is visible by title in the morning; it never merges
anything, since the merge rule reads only the row.

## Failure

- **P**: a registration that fails — a non-zero exit, or no issue URL on
  standard output — means no `이월` row and no merge. Send a fix stage.
- **N**: a registration that fails leaves the approvals due. Try again on the
  next shift, and say in the handoff report that it failed and why.
- **The issue exists but the gate refuses the `이월` row.** A `cycle` row that
  arrived in between, the row cap, or a cycle below `cycle_carry_from` each
  refuse the row after `gh issue create` has already succeeded. Do not retry
  the row with other numbers. On P send a fix stage; on N the approvals stay
  due. Either way, name every URL the attempt created in the handoff report,
  and the next attempt reuses those URLs instead of opening the same title
  again. A row over the cap names fewer URLs only by carrying fewer findings,
  which the `건수` check refuses, so on P it is a fix stage as well.
- Neither route parks a segment or asks a person.

**When auto-resolution is off** (`auto_resolve` false in the snapshot), `gh
issue create` outside pre-authorization becomes an approval, which is a
question for a person. P does not attempt the carryover and sends a fix stage,
which is how the run behaved before the ceiling existed; N has nothing due,
because only an auto-resolved approval enters `carryover_due[]`.

## Repository and project

- P registers in the segment's target repository, N in the run's home target.
- Only when that repository is `Nharu/cc-cmds`, follow the issue with
  `gh project item-add 1 --owner Nharu --url <URL>`. A failure there — a
  credential without the `project` scope, for one — is reported and does not
  stop the carryover.

## Gate declaration

`gh issue create`, `gh issue comment` and `gh project item-add` go through
`gate.sh exec` with `--surface 외부상태변경 --reach 협업`, the command called
directly and not inside `bash -c`. An exit 11 is not retried: on P it means a
fix stage, on N the approvals stay due.

**The cutpoint.** Label these acts with the target's cutpoint as you label
every other act. The gate derives the bottom rung, `커밋`, from these three
verbs — an issue moves no code — and judges them there, so the merge rule
does not ask them for the `이월` row they exist to produce, and N needs no
segment. Declaring `머지` is therefore not a refusal; an exit 3 naming
`리뷰-후-머지` on one of these acts means the argv was not one of the three
verbs, so check the spelling rather than writing the row first.

Then write the row:

- P: `act --kind 이월 --segment <seg> -- 출처=리뷰 사이클=<n> '리뷰 HEAD=<sha>' '승인 id=-' '이슈=<url>[,<url>…]' 건수=<P1>`
- N: `act --kind 이월 -- 출처=경계 사이클=- '리뷰 HEAD=-' '승인 id=<B1-…>' '이슈=<url>' 건수=1`, once per due approval.
