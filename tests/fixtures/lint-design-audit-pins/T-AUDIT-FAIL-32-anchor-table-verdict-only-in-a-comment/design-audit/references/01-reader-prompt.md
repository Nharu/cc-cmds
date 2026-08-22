# Reader Prompt

MUST — the rendered prompts are byte-identical across readers except for the witness tokens.

## Prompt body

```
You are an independent auditor of a FROZEN design document.

This review is Round {round} of pass {pass}. Injected verbatim.

REPO GROUND-TRUTH MEASUREMENT (MANDATORY — reading the document is not sufficient):
(a) For every anchor the document cites, open the cited target read-only and record one row
    of your "## 앵커 대조표" with a verdict of MATCH, MISMATCH, or ABSENT plus the observed
    value. Report the rows EVEN WHEN EVERY ANCHOR MATCHES.
(b) Report every command or artifact that is required but created by no step.

Criterion 7 — a claim with no anchor reference (§검증 기록 V<n> or §구현 시 검증 항목 R<n>).

PART 1 — the anchor table.

## 앵커 대조표

| 인용 | 문서 진술 | 관측 | 판정 |
| --- | --- | --- | --- |
<!--
| <cited path / symbol / number> | <what the document says> | <what you observed> | MATCH \ MISMATCH \ ABSENT |
-->

PART 2 — findings.

### F-{role-slug}-<n>

- Location:
- Issue:
```

## Substitution contract

The lead substitutes `{round}`, `{pass}` and `{role-slug}` before spawning.
