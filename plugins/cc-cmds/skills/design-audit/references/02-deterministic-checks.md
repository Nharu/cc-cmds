# Deterministic Checks (run ONCE, outside the replication channel)

Consumed by Step 2, in the main session, before the readers spawn.

**Why once.** A check whose detection probability is essentially 1 is already saturated after a single run — replicating it `READER_COUNT` times adds nothing, because the coverage of an always-succeeding detector does not improve with more detectors. Replication buys value only where per-reader detection probability is below 1, which is the judgment classes the readers own. Running these once here is therefore not a cost saving at the expense of coverage; it is what frees the readers' entire budget for the semantic measurement only they can do. The output path is handed to every reader identically so none of them re-does the mechanical work.

**By reference, never by copy.** Read `${CLAUDE_SKILL_DIR}/../_common/verification.md` and apply its detection grammar and its well-formedness predicate **verbatim from that file**. Do NOT copy the matchers into this file — a copy is a parity obligation, and the point of citing the shared contract is that there is nothing to synchronize.

## Checks

1. **Anchor and link resolution.** Every `path`, `path:line`, `§anchor`, internal link, and fenced-command referent the document cites either resolves or does not. Report each non-resolving anchor with the cited form and the observed state (missing file, out-of-range line, renamed target).
2. **Section schema and canonical ordering.** The verification ledger section sits after the decisions section; the residual-items section sits after the unresolved-issues section and before the recommended-order section. A heading out of place, duplicated, or misspelled is a finding.
3. **Save-forbidden token absence proof.** Both literal forms of the never-saved verification grade must be document-wide zero: the full-line field form and the inline-tag form. This is the single document-wide exception in the shared detection grammar; use the grammar's own idiom for it.
4. **Required-field presence.** Every ledger entry and every residual item carries its required field set per the shared contract. A missing required field is a finding.
5. **Residual well-formedness.** Apply the shared well-formedness predicate **as it stands in the shared contract**, by reference. Its disjuncts are deliberately not restated here: this file's own opening rule is that a copy is a parity obligation, and an inline list of the disjuncts is exactly such a copy — it goes stale the first time the contract gains a disjunct, and a check running the stale list reports green on the axis that was just added. Read the predicate there and apply it verbatim, including its rule that **line rendering is not a malformedness axis**.
6. **Enum-value vocabulary.** Every enum-valued field carries a value inside its frozen set. An out-of-vocabulary value is a finding, never a silent default into another bucket.
7. **Dangling section references.** A `§` reference naming a section the document does not contain.

8. **Coherence-pass stamp.** Read the `<!-- cc-design-frozen … -->` stamp beside the document's ledger block, once. **The arms are keyed on what the stamp SAYS, never on which skill produced the document:**
    - **present, reading `coherence-pass=done`** — satisfied.
    - **present, reading anything else, or malformed** — a finding. A stamp that exists and does not say `done` is the pipeline reporting its own skip.
    - **absent** — a finding, worded as *"no coherence-pass stamp"* and never as *"the pass was skipped"*. Those are two different claims and the bytes do not separate them: a pipeline that has no coherence pass and a pipeline that has one and skipped it leave an identical document. Report the absence, say that the cause is not decidable from the document, and let the reconciliation pass route it. Do not resolve it by inferring a producer.

    **Keying on the producer is not merely under-specified — it is unreachable.** No byte of a produced document records which skill produced it: the stamp itself carries no producer field, and the caller identity exists only in the session that is gone by audit time. An arm selected by producer identity can therefore never be selected, so the previous form of this check **could not fail on any input** — every document passed it vacuously, including the ones it was written to catch.

    **One of those arms was also simply wrong.** It granted `design-prompt` a *해당 없음* on the ground that the skill has no coherence pass. That skill produces no document of its own — it writes a section INTO `design`'s document, and its path rule hard-gates it against creating a separate artifact. The document a `--base` audit reads is therefore the one `design` produced and was required to stamp, and the arm instructed the check to ignore a mandatory stamp on exactly that document.

    **The residual is stated rather than papered over.** Keying on the value makes the check reachable and correct about what it can see, and it does not recover the one thing the bytes never carried: a document from a pipeline that legitimately has no coherence pass still draws the absent-arm finding. That finding is honest — it says the stamp is missing and that the reason is undecidable here — but it is a finding, and a caller with such a pipeline will see it on every run.

    **Route it to `## 미해결 이슈`, never to `기각`, and the reason is arithmetic rather than taste.** A known residual that recurs on every run of a documented call shape is exactly what that owner is for. Sending it to `기각` instead would put a **permanent floor of one** under the rejection count — and the reconciliation pass leans on a zero rejection count beside a large applied count as its triage-collapse signal, so a floor of one is a detector that can no longer reach its own alarm state. The routing lines are fixed-arity precisely so that collapse shows up without extra instrumentation; a finding that fills one of them unconditionally spends that instrumentation on itself.

## Output

Write the result into the audit report as a `## 결정론적 검사` section. **This is a write to the report, so it carries the report's terminator duty** — stated here by reference rather than restated, because this file's own opening rule is that a copy is a parity obligation: SKILL.md fixes the sentinel and requires every write to the report to re-emit it as the last non-empty line, and a second spelling of that sentinel here would be one more place to forget when it changes. Each entry uses the same unique-defect shape the reconciliation pass consumes, so Step 5 can merge these with the reader findings without a translation step:

```
### D-<n>
- **Check**: <which of the eight above>
- **Location**: <section or anchor in the document>
- **Issue**: <what is wrong>
- **Evidence**: <the observed bytes, path, or count>
```

These entries count toward `원시 발견 수` and `고유 결함 수` in the disclosure block, and are **excluded from `미보강 잔여 수`**: reinforcement multiplicity is not a meaningful notion for a saturated channel, and counting a deterministic finding as unreinforced would corrupt the invariant that unreinforced residuals are the ones no second reader confirmed.
