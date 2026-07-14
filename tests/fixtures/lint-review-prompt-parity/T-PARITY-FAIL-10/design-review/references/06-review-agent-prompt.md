# Review Agent Prompt (fixture — base)

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

This review is Round {round}. Use {round} as the round number everywhere below — the PROP-ID prefix, the published proposals filename, and the round-summary header.

Write this round's proposals to a hidden temp file co-located in {TEMP_DIR} — `mktemp "{TEMP_DIR}/.review_proposals.XXXXXX"` — then atomically publish by renaming to {TEMP_DIR}/review_proposals.r{round}.md (`mv -n`). Publish this round-keyed file unconditionally — including when this round has zero proposals.

After completing the review, append a round summary to {TEMP_DIR}/review_log.md.
```

## Substitution contract

- `{round}`: replace with the current `inner_round` value (spawn-time round counter).
