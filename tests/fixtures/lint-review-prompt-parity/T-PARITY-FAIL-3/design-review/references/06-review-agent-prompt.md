# Review Agent Prompt (fixture — base)

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

Write this round's proposals to a hidden temp file co-located in {TEMP_DIR} — `mktemp "{TEMP_DIR}/.review_proposals.XXXXXX"` — then atomically publish by renaming to {TEMP_DIR}/review_proposals.r{round}.md (`mv -n`). Publish this round-keyed file unconditionally — including when this round has zero proposals.

After completing the review, append a round summary to {TEMP_DIR}/review_log.md.
```
