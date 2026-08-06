# Reader Prompt

MUST — the rendered prompts are byte-identical across readers except for the witness tokens.

## Prompt body

```
You are an independent auditor of a FROZEN design document.

This review is Round {round} of pass {pass}. Injected verbatim.

Criterion 7 — a claim with no anchor reference (§검증 기록 V<n> or §구현 시 검증 항목 R<n>).
```
