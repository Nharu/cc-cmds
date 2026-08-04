# Deterministic Checks (run ONCE, outside the replication channel)

Consumed by Step 2, in the main session, before the readers spawn.

**Why once.** A check whose detection probability is essentially 1 is already saturated after a single run — replicating it `READER_COUNT` times adds nothing, because the coverage of an always-succeeding detector does not improve with more detectors. Replication buys value only where per-reader detection probability is below 1, which is the judgment classes the readers own. Running these once here is therefore not a cost saving at the expense of coverage; it is what frees the readers' entire budget for the semantic measurement only they can do. The output path is handed to every reader identically so none of them re-does the mechanical work.

**By reference, never by copy.** Read `${CLAUDE_SKILL_DIR}/../_common/verification.md` and apply its detection grammar and its well-formedness predicate **verbatim from that file**. Do NOT copy the matchers into this file — a copy is a parity obligation, and the point of citing the shared contract is that there is nothing to synchronize.

## Checks

1. **Anchor and link resolution.** Every `path`, `path:line`, `§anchor`, internal link, and fenced-command referent the document cites either resolves or does not. Report each non-resolving anchor with the cited form and the observed state (missing file, out-of-range line, renamed target).
2. **Section schema and canonical ordering.** The verification ledger section sits after the decisions section; the residual-items section sits after the unresolved-issues section and before the recommended-order section. A heading out of place, duplicated, or misspelled is a finding.
3. **Save-forbidden token absence proof.** Both literal forms of the never-saved verification grade must be document-wide zero: the full-line field form and the inline-tag form. This is the single document-wide exception in the shared detection grammar; use the grammar's own idiom for it.
4. **Required-field presence.** Every ledger entry and every residual item carries its required field set per the shared contract. A missing required field is a finding.
5. **Residual well-formedness.** Apply the shared well-formedness predicate: a required field missing, a `/tmp` literal, an unresolved failure-impact anchor, a token or enum value outside the frozen vocabulary, or a terminal token without its adjacent note line. **Line rendering is not a malformedness axis** — a leading bullet or missing bold is tolerated by the detection grammar and must not be reported here.
6. **Enum-value vocabulary.** Every enum-valued field carries a value inside its frozen set. An out-of-vocabulary value is a finding, never a silent default into another bucket.
7. **Dangling section references.** A `§` reference naming a section the document does not contain.

## Output

Write the result into the audit report as a `## 결정론적 검사` section. Each entry uses the same unique-defect shape the reconciliation pass consumes, so Step 5 can merge these with the reader findings without a translation step:

```
### D-<n>
- **Check**: <which of the seven above>
- **Location**: <section or anchor in the document>
- **Issue**: <what is wrong>
- **Evidence**: <the observed bytes, path, or count>
```

These entries count toward `원시 발견 수` and `고유 결함 수` in the disclosure block, and are **excluded from `미보강 잔여 수`**: reinforcement multiplicity is not a meaningful notion for a saturated channel, and counting a deterministic finding as unreinforced would corrupt the invariant that unreinforced residuals are the ones no second reader confirmed.
