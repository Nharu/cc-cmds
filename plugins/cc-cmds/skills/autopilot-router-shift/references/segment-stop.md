### Stopping one segment for a person

**A stop that belongs to one segment does not end the shift.** At each site the table below names, the segment needs a person and its siblings do not: instead of ending the shift with a `사유=중단` handoff, stop that one segment with a halt record the gate writes, and go on routing the others.

```
gate.sh act --manifest <매니페스트> --kind shift-halt --target <alias> --segment <id> \
  --cutpoint <token> --surface 읽기 --snapshot-digest <H> --site '<자리>' \
  -- '질문=<사람에게 물을 것, 한 줄>' '관측=<본 것 — 줄 번호, 종료 코드, 게이트 문면>' \
     ['추천=<재시도 | 세그먼트 park | 근거 제출>' '추천 근거=<종류>:<인용>[ / <종류>:<인용>]']
```

`근거 제출` is the recommendation of `종료 절 근거` alone; every other site whose recommendation reads `allowed` takes `재시도` or `세그먼트 park`.

**At `강제 표면 승인` the gate measures before it writes.** It runs the provenance check itself and writes the record only when the check refuses and every refused path is one an approval can let through; the record then carries one `**승인 대상**: <경로> | <분류> | <베이스 항목> | <승인 항목>` line per path. A path changed on both the base and the branch, a path name no approval row can carry, a check that cannot decide, or an unanswered `강제 표면 승인` record already on the segment is refused with exit 3 and nothing written — then take the refusal's own path (the block row it wrote, or `병합 거절` for a merge) and route the others. Only a person answers `승인`: the seat asks with the question line `surface-approval-preview` prints, the gate checks the shown paths against a fresh measurement and writes the approval rows with the answer.

| `자리` | where it arises | recommendation |
|---|---|---|
| `적용 전제 거부` | 「Merging and applying a segment」: an apply precondition refusal other than the stale remote ref | allowed |
| `병합 거절` | 「Merging and applying a segment」: any other cause of a refused merge; `다음` reads `CI 기존 실패` or `CI 수정 한도` | allowed |
| `push원격불일치` | exit 11 on a push of the segment's branch whose remote disagrees with the worktree | never |
| `도달 거부` | exit 11 on any other act of the segment the segment cannot do without; exit 11 on `act --kind ci-rerun` or `act --kind label-ack` — never a dispatch whose `11` left a `차단=파견 전` row | never |
| `베이스 해소 한도` | the segment's base cannot be resolved within its bound | never |
| `워크트리 기록 없음` | 「Merging a segment and recording it」: no recorded worktree, or one the segment did not work in | allowed |
| `종료 조건 11 판독 불가` | termination condition 11 with the merged tip unreadable | allowed |
| `대상 훅 거절` | 「Pushing and opening a pull request」: the target's own Bash hook refuses an act the segment cannot do without, and the refusal is not one a commit, a remote read or another spelling moves | never |
| `master 수리 불가` | `references/review-next-2.md`: `다음` reads `master 수리 불가` — the segment waits on a base-branch failure no repair run could be started for, and holds that event's representative marker | never |
| `적용 정산` | 「Merging and applying a segment」: `act --kind apply-settle` ended in `park … 정산 판정=필요` or `측정 실패` | never |
| `들여온 적용 정산` | 「Merging and applying a segment」: the segment is in the snapshot's `apply_imported` | never |
| `종료 절 근거` | 「Settling the termination clauses and proposing done」: a termination clause whose evidence neither a read nor a `clause-exec` of this run produced | `근거 제출` only; a person answers |
| `리뷰 게시 거절` | `act --kind review-post` exit 3: there is no dedicated write credential and this host's `gh` login could not be read either (not logged in, or expired), the posting account is not the frozen one, the review was already posted and matched, GitHub refused the post (a 4xx), or the post's outcome is unknown (no status line, a 5xx) and no post row was written — the gate's refusal line carried in `관측` says which | never |
| `게시 대조` | `act --kind review-post` exit 3: the review GitHub holds after the post does not match the rendered request, or cannot be read | never |
| `보류 리뷰 선점` | `act --kind review-post` exit 3: the posting account already holds a pending review on the pull request | never |
| `베이스 이동` | written by the gate's base move check alone, never by `act --kind shift-halt` (which refuses the site): the base of a target with no remote moved before or during an act of the segment, standard error holds a line containing `[run][warn] 베이스 이동 — `, and the exit is 11. A stop on the target key `베이스-<별칭>` — the segment record could not be written, or the act named no segment — offers `재시도` alone | never |
| `강제 표면 승인` | a review dispatch or the merge act exit 3 whose refusal names the enforcement-surface provenance check (`강제 표면이 좌석 적용 밖에서 바뀜`) — the segment branch changed a rule file, an instruction file, a hook or a project setting outside a seat apply, and no `강제 표면 승인` row lets it through. Use it instead of `병합 거절` for such a merge refusal | never; a person answers |

**The gate writes the record, and its options are the table's.** It writes `"$CC_PIPELINE_RUN_DIR/halt/shift/<id>#<n>.md"` with two options at every site, `재시도` and `세그먼트 park`, and at the two settlement sites the extra ones — `재실행` and `사람 확인 정산` at `적용 정산`, `사람 확인 정산` at `들여온 적용 정산` — and `승인` at `강제 표면 승인`, and a cone `blocked` row anchored on the segment that carries the record's path and digest and lists the segments that depend on it. The gate does not refuse acts on that cone — you hold it — except at site `베이스 이동`, where the gate holds a latch and refuses every act of that segment (every act on the target, when the stopped act named no segment) with exit 11 until the answer comes; its `재시도` answer releases the latch. Either way the snapshot tells every later shift what to hold: `shift_halts[]` has one element per shift stop no answer has reached yet, with its `세그먼트`, `자리`, `기록` and `보류` (the segments its cone holds now). Dispatch, merge or apply nothing on an element's `세그먼트` or on a segment in its `보류` until the answer comes back — the element then leaves `shift_halts[]` and the answer appears in `answered_halts[]` — and route every other segment as usual. Do not write a `park` row or a separate cone block for the same stop — the answer decides between those. A run-scope stop is not in the table: exit 7, a lane or limit wait, the design step's stop and a structural refusal still end the shift with `사유=중단`. The one exception is `종료 절 근거`, which stops no segment: it asks a person for one termination clause's evidence, and 「Settling the termination clauses and proposing done」 gives its form.

**Recommend only from what a file says.** Pass `추천` with `추천 근거` only when the interview record (`인터뷰 기록`), the manifest's authorization (`매니페스트 인가`) or the target's `CLAUDE.md` (`상시 지침`) settles the choice, each part quoting that file verbatim; the gate looks each quote up with a fixed-string search and refuses the act with exit 3 when one is not there, and it refuses `기기 사실` and any kind it does not know. On that exit 3 call again without the two fields. At a site whose recommendation reads `never`, the gate drops whatever you pass and the record reads `(없음)`. At `종료 절 근거` the gate takes `근거 제출` and nothing else, and it refuses every answer to that record whose answerer is not a person — the recommendation tells the person which way the evidence points, and never lets the seat answer. Without a recommendation the seat asks a person.

**When the gate cannot write the record** — exit 3 because `halt/shift` is not a real directory at its place, or because a file already sits at the name — write `act --kind blocked -- 스코프=cone 원인=막힘 '앵커 세그먼트=<id>' '사유=교대 정지 기록 불가 — <자리>' '근거=<게이트 문면>'` and go on: that row is in `shift_halts[]` with an empty `기록`, so it is held as above for the rest of the run, and the seat finds the stop in the ledger. Exit 2 is your argv (an unknown site, a missing `질문` or `관측`, a field the gate writes itself); fix it and call once more. Never pass `중단 기록`, `기록 다이제스트`, `자리` or `교대` on a `blocked` row — those are the gate's, and the row is refused with exit 2.

**End the shift only when nothing is left.** After the act, read the snapshot again and route every other segment as usual. When no act remains to dispatch, end with `사유=중단` and put each record's absolute path in `막힌 지점`. The answer comes back as an `answered_halts[]` element and 「Handing on a person's answer to a halt」 item 6 carries it out.

