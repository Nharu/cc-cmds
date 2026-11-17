#### Reviewing pull requests on a reviewer run

A reviewer run reviews pull requests other people wrote and posts one review on each. It never writes the author's branch: the gate refuses (exit 3) a `git push` or `git commit` on a review-only segment, an `implement` dispatch, a lead fix or `--lead-fix` review, a merge and `gh pr create`. Do not re-dispatch anything to fix a finding — the review's findings go to the author through the posted review and nowhere else.

The snapshot's `리뷰 세그먼트[]` is the read: one element per `리뷰 PR` row, in row order, with `id` (`P<k>`), `대상`, `PR`, `슬러그`, `베이스`, `워크트리` and `상태` (`미계획` before its planning act). **Plan every `미계획` element in this shift, in order, with three calls**, and dispatch its review at once — reviews of different pull requests run side by side within the lane bound:

1. `gate.sh exec … --target <대상> --surface 워크트리쓰기 --reach 협업 -- git fetch origin +refs/pull/<PR>/head:refs/cc-review/<run id>/<id> +refs/heads/<베이스>:refs/cc-review/<run id>/<id>-base`.
2. `gate.sh exec … --target <대상> --surface 워크트리쓰기 -- git worktree add --detach <워크트리> refs/cc-review/<run id>/<id>`.
3. The plan row, which pins the pull request's head:

   ```
   gate.sh act --manifest <매니페스트> --kind segment --target <대상> --segment <id> \
     --cutpoint 커밋 --surface 읽기 --snapshot-digest <H> --review-pr \
     -- 상태=계획됨 워크트리=<워크트리>
   ```

   The gate reads the pull request's current head from the remote and writes `종류=리뷰전용 고정 헤드=<sha> 베이스 sha=<sha>` only when it equals the worktree's HEAD. **On exit 3 saying the head moved, take calls 1, the removal, 2 and 3 again once, in that order**: call 1, then `gate.sh exec … --target <대상> --surface 워크트리쓰기 --destructive -- git worktree remove --force <워크트리>`, then call 2, then call 3. The fetch moves `refs/cc-review/<run id>/<id>`, and the worktree is made again at it rather than moved: until the plan row is written the segment has no row, so the gate runs every call in the target's main worktree, a `--segment` call included, and a checkout issued there moves the person's main checkout instead of the review worktree. Nothing is lost by the removal — no review has started in that worktree yet. **A segment that cannot be planned is parked, not halted** — a second head-moved refusal, any other exit 3 of call 3, or a call 1 or 2 that fails (a pull request closed overnight leaves `refs/pull/<PR>/head` unfetchable): write `act --kind segment --target <대상> --segment <id> -- 상태=park 워크트리=<워크트리> 선행=없음` and a `blocked` row saying why. The gate takes a `park` as the first row of a `리뷰 PR` segment that has no planning row, and `shift-halt` cannot stop a segment that has no row at all.

**Dispatch the review from `gate.sh review-line` unchanged** (「Spelling a review dispatch」), with `--trigger '첫 리뷰'`. For a review-only segment the line names the pull request's URL instead of a branch and carries `--base-sha <베이스 sha> --pr-head <고정 헤드> --depth <깊이> --post-ready`; the stage's session starts in the target's main worktree, and it reads the detached worktree through acts carrying `--segment`, which run there. Record its `cycle` row as for any review.

**When `다음` reads `게시`, post the review** — the one value `review_next[]` has for a review-only segment whose review ended `정상 완료`:

```
gate.sh act --manifest <매니페스트> --kind review-post --target <대상> --segment <id> \
  --cutpoint 커밋 --surface 외부상태변경 --snapshot-digest <H> -- 게시
```

The gate renders the review from the report's `## 게시 항목` and the run's wording file, posts it once as the frozen `리뷰 게시` row says (`보류` leaves it pending for a person to submit; `직접` submits it), reads it back and writes the `리뷰 게시` row. **After `대조=일치`, write `act --kind segment --segment <id> -- 상태=완료 워크트리=<워크트리> 선행=없음`.** With no dedicated write credential the gate posts under this host's `gh` login, still checks it against the frozen account, and records `게시 자격=주변` on its rows. On exit 3 the refusal names one of three sites — `리뷰 게시 거절` (no write credential and no readable `gh` login, a login other than the frozen account, a 4xx, or an unknown outcome; the refusal line says which), `게시 대조`, `보류 리뷰 선점` — so stop the segment there with `shift-halt` (「Stopping one segment for a person」) and go on with the others; never post the review another way, and never edit or delete a posted one.

**Clean up once the segment is `완료` or `park`**: `gate.sh exec … --target <대상> --surface 워크트리쓰기 --destructive -- git worktree remove --force <워크트리>`, then `git update-ref -d refs/cc-review/<run id>/<id>` and `git update-ref -d refs/cc-review/<run id>/<id>-base` the same way (`워크트리쓰기`). A segment whose call 2 never made the worktree (a call 1 or 2 that failed before the `park`) skips the `git worktree remove` — there is no worktree to remove, and the call fails on the missing path — and still takes both `git update-ref -d` calls, which pass on a ref that is not there. The gate takes `propose-done` on a reviewer run only when every `P<k>` segment's last row is `완료` or `park`; settle the clauses as 「Settling the termination clauses and proposing done」 says, citing each segment's `리뷰 게시` row as `리뷰 id=<id>`.

