#### Dispatching the visual stage

When `steps[]` carries exactly one step whose `skill` is `visual`, and every step its `depends_on` names — the audit, or the design when the plan has no audit — ended `정상 완료`, dispatch it — `--segment -`, stage kind `visual`:

```
gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
  --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest <H> --emit-digest \
  -- visual -p "/cc-cmds:visual-unattended <스냅숏 design_doc>"
```

Wait on it as *Waiting on a stage* describes. The stage is complete when its artifact predicate holds: the literal `시각 디자인을 검토 통과로 확정했습니다.` in its stream, and the document's visual sidecar reading `**상태**: 검토 통과`. Either alone is a `공허한 성공`, which 「Continuing a stage that ended its turn in prose」 takes. The visual step is not a segment and its rows carry `세그먼트=-`. **A visual step that did not end `정상 완료` — a halt included — holds only the screen slices**: plan and dispatch every slice whose `**화면**` field reads `없음` as if the step had not been there.

**The publish step.** When `steps[]` carries exactly one step whose `skill` is `visual-publish` (`S2P`), and the step its `depends_on` names (`S2V`) ended `정상 완료`, dispatch it — `--segment -`, stage kind `visual-publish`:

```
gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
  --cutpoint 커밋 --surface 워크트리쓰기 --snapshot-digest <H> --emit-digest \
  -- visual-publish -p "/cc-cmds:visual-publish-unattended <스냅숏 design_doc>"
```

It is complete when the literal `시각 발행 단계를 마쳤습니다.` is in its stream and either the document's visual sidecar reads `**상태**: 발행됨` or a person's `거부` or `발행하지 않음` answer to its record stands; either half alone is a `공허한 성공`. **An `S2P` that did not end `정상 완료` — a halt included — holds only the screen slices**, as the visual step's does, and no implement step waits on `S2P`. Its `시각-판정`, `금지-후보` and `발행-실패` records take a person's answer only; the carry act hands it on like any answered halt.

**Which slices wait.** A slice of `## 구현 슬라이싱` is a screen slice when its `**화면**` field lists screen ids, or when it carries no `**화면**` field and the plan has a visual step or the document has a visual sidecar — a slice that does not say waits for every screen. A slice whose `**화면**` reads `없음` never waits. **The predicate** is `visual-check.sh approval <설계 문서>`, read through the gate as `gate.sh exec … --surface 읽기 -- <plugin root>/orchestrator/visual-check.sh approval <스냅숏 design_doc>` — the helper's absolute path is argv0 and nothing stands before it, because the gate grades its own helper by subcommand only when called that way, and behind `bash` the read is refused whenever the auto-resolve switch is off; exit 0 is a predicate that holds, anything else one that does not. When a screen slice's turn comes and the predicate already holds, plan and dispatch it as any slice, with no judgment — unless a person closed its `시각-승인` as `거부` or `무효` in this run, which item 5 settles.

**The fixed judgment.** The judgment that waits is one per screen segment, always in the same words, because its id is a hash of the run, the segment and the question:

```
gate.sh act --manifest <매니페스트> --kind judgment --target <home alias> --segment <화면 세그먼트> \
  --cutpoint 커밋 --surface 읽기 --snapshot-digest <H> --emit-digest \
  -- 등급=2 '판단 부류=시각-승인' '기준=시각 승인 대기' '근거=<화면 세그먼트> 의 화면이 고정 좌석에서 구현 승인되었는가'
```

Its `막는 세그먼트` is the screen segment, never the visual step id. Resubmitting it never reaches the two-questions-per-segment cap, which counts distinct ids. Once a `자율 승인` row carries its id in `해소 승인`, do not submit it again: a resubmission after the adoption is refused as spent. **Exit 0 on a resubmission is not an adoption by itself**: the approval is adopted only when that row carries `결정=채택`. A row carrying `결정=거절 소비` is a person's `거부` or `무효` spent, and it leads to item 5, never to item 3.

1. **A screen slice's turn with no predicate.** For that slice and for every planned slice whose `선행` reaches it, write a `segment` `park` row with the plan row's `선행` and a `스코프=cone` `blocked` row anchored on it with `원인=막힘` and `'사유=시각 승인 대기'` — the pair this section calls a visual-wait park — before any branch or worktree is cut for them, and then submit the fixed judgment on the screen segment — one per screen segment when several are waiting. A slice not planned yet gets no row: the planning rule keeps it back while its `선행` is parked. When the predicate already holds, the gate closes the approval as `승인` inside that act and adopts it, so go to item 3. When it does not, the act ends on exit 5; under the **CFI-S4 exception** that holds the screen segment and its `선행` followers and you keep dispatching the work outside them, naming the waiting slices in `막힌 지점`.
2. **Nothing left outside the held set.** End with `사유=승인`. The seat asks the person, naming `/cc-cmds:visual <설계 문서>` to run on the pinned seat and telling them to answer with the label `승인` once they have approved there; an answer in free words does not close the question, so the seat asks again for the label. On each turn read `answered_judgments[]` and the predicate: when `answered_judgments[]` carries that segment's `시각-승인` as `거부` or `무효`, go to item 5 whatever the predicate says; otherwise, when the person's `승인` stands or the predicate holds, submit the same fixed judgment again — it closes and adopts the approval. While a screen slice waits, do not propose done: the open `시각-승인` counts against termination condition 2. **In a run whose plan carries `S2P`**, the seat asks the `S2P` stage's latest `시각-판정` halt record instead of naming `/cc-cmds:visual`: a person's `승인` re-attaches the stage, which writes the approval line with the ` — 사람 답 <record>` tail, and then the same fixed judgment submitted again closes and adopts the approval.
3. **Adopted and the predicate holds.** Adopted means a `자율 승인` row with `결정=채택` carries the id in `해소 승인`. On a segment this run's shift left in a visual-wait park, write `상태=실행중` with the plan row's `선행` and dispatch its implementation as any planned slice. A `park` the fixed-graph driver wrote is not taken over: that run has its end row, the gate refuses its dispatches, and a new run plans the screen slices afresh.
4. **Adopted and the predicate is gone.** A sync or a re-publish removed the `**구현 승인**` line after the adoption. Do not submit the judgment again; leave the slice at `park` and write in `막힌 지점` — and the morning report — 「고정 좌석에서 `구현 승인` 을 다시 쓸 것」 — in a run whose plan carries `S2P`, 「`수정 요청` 뒤 다시 쓰인 `시각-판정` 에 `승인` 으로 답할 것」 instead. When the predicate holds again, item 3 dispatches it under the approval already closed.
5. **Refused.** A person closed the `시각-승인` as `거부` or `무효`: the screens are not to be built. The segment is already `park`, so submit the same fixed judgment again to consume the refusal (`결정=거절 소비`), and settle the clauses that need those screens as `불가능` citing that answer. A person's `거부` to an `S2P` `시각-판정` record, or `발행하지 않음` to its `발행-실패` record, is such a closing: the gate writes it inside the `중단 답` act (`처분 사유=중단 답 연동`), and the same resubmission consumes it. Until it is consumed the segment stays held. **A consumed refusal does not make the segment `실행중` again**: its exit 0 is not an adoption, the segment stays `park` for the rest of the run even when the predicate holds, and the gate refuses an implementation dispatch to it.

The same three walls stand around these items: the open `시각-승인` that refuses a dispatch to its segment, the `park` row, and the gate's own refusal of an implementation dispatch carrying a screen slice while the predicate does not hold or after a person closed its `시각-승인` as `거부` or `무효` — which is what stops item 4's or item 5's slice if it were dispatched anyway.
