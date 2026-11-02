9. **A residual-ladder halt answered `골격 재검토` goes to re-convergence, then to a fresh audit.** `design-discuss-unattended`, `design-solo-unattended` and `design-base-unattended` halt at `/ ladder-unsettled` when their residual ladder leaves items open, and a person who answers `골격 재검토` asks for the skeleton to be reviewed against those items. A frozen design stage cannot do that, so the frozen document is re-converged in this run, scoped to the residual items the record froze, and then audited again. This is the one person's answer to a design stage that comes back as a pass rather than as a re-attachment.
   - **The record** is the element's `record` when item 2 sent you here by its `설계-재수렴` route. From item 5 of 「Dispatching the design stage」 there is no element, because the re-attached design's `정상 완료` row took the answer up: read the step's answers (`gate.sh exec … --surface 읽기 -- grep -nF '| 세그먼트=<step id> | 중단 기록=' <원장 경로>`) and take the `중단 기록` of the last line carrying `| 선택지=골격 재검토 |`, and that line as `<line>`.
   - **The gate decides whether it may run.** It admits the dispatch only when the step's last `중단 답` is a person's `골격 재검토` on a `/ ladder-unsettled` record, either taken up by a design row that ended `정상 완료` or — after the freeze — answered after a `잔여로 두고 동결` on the same record with a design row ended `정상 완료` between the two; it refuses a second re-convergence on the same record, and refuses outright when the audit's own continuation (item 4) fits as well. On exit 3 dispatch nothing on the step: when item 2 sent you here, go to item 8; from item 5 of 「Dispatching the design stage」, with no element, end the shift with `사유=중단`, naming the record in `막힌 지점`.
   - **Exclusion** as item 4 of 「Routing a pre-implementation refutation to re-convergence」; the gate does not wait for the design or the audit step to have nothing live — it refuses the dispatch while either has a live attempt, and that refusal goes to item 8 like any other. The answer item 8 returns does not count against the person's next one: their new `골격 재검토` on the same record opens this item as the first would have.
   - **The dispatch** carries `--segment -` and stage kind `reconverge`, and the scope `잔여 동결 재검토` with the record's absolute path — the scope string `_common/pipeline-sidecar.md` §3.2 defines, which the gate holds the prompt to. Its row reads `세그먼트=- | 스테이지=<step id> | 종류=reconverge`, it runs where the design ran, and the document goes as its main-worktree absolute path:

     ```
     gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
       --cutpoint <token> --surface 워크트리쓰기 --snapshot-digest <H> \
       --rationale '중단 답 줄 <line>; 잔여 동결 재검토' \
       -- reconverge -p "/cc-cmds:design-reconverge <스냅숏 design_doc> 잔여 동결 재검토 <record>"
     ```

   - **After it ends**, a design step whose last `stage-result` row reads `종류=reconverge` is this item's second half. Read the terminal literal in its stream with the read item 6 of 「Routing a pre-implementation refutation to re-convergence」 makes. Present → dispatch the audit afresh on the audit step, exactly as item 4's second half does; the gate refuses segment planning until an audit after the re-convergence ends `정상 완료`, and a row reading `재수렴 판정=재설계 필요` re-plans through `replan_due[]` as item 4 says. **A plan with no audit step** — a `solo` plan's graph has none — has no audit to dispatch, and the gate refuses one with exit 3 there; with the literal present, go straight on to segment planning, the step the graph names after a frozen design, as when item 5 of 「Dispatching the design stage」 finds both freeze facts. The gate does not wait on an audit that the plan does not name. Absent — a halt, a crash, no literal — → stop the design as 「Dispatching the design stage」 says, with the re-convergence row as its evidence, and no second re-convergence.
10. **A re-audit that still found skeleton-grade items, answered `재수렴`, goes to re-convergence, then to a fresh audit.** Only an earlier version's re-audit parked at `Step 7 / 골격급 재발`; a person who answers `재수렴` asks for one more re-convergence.
   - **The dispatch** carries `--segment -` and stage kind `reconverge`. The key's last row is the re-audit's `의도된 park`, so the gate keys this `- reconverge` on the audit step the way it keys item 4's:

     ```
     gate.sh act --manifest <매니페스트> --kind skill --target <home alias> --segment - \
       --cutpoint <token> --surface 워크트리쓰기 --snapshot-digest <H> \
       --rationale '중단 답 줄 <line>; 골격급 재발 재수렴' \
       -- reconverge -p "/cc-cmds:design-reconverge <스냅숏 design_doc> 감사 골격급 <record>"
     ```

   - **After it ends**, take the audit afresh as 「Routing a skeleton-grade audit to re-convergence」 says, with `blocked` and `사유=중단 답 라우팅 — 재수렴 종단 술어 거짓` when the literal is absent.
   - **No new record follows.** The fresh audit asks again under the key's cap, which this answer's re-convergence counts toward. On exit 3 go to item 8.

