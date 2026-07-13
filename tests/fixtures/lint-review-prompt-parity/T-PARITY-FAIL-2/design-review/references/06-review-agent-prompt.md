# Review Agent Prompt (fixture — base)

## Prompt body

```
You are a design document reviewer. Perform ONE independent round of review.

Write all proposals to {TEMP_DIR}/review_proposals.md (overwrite the file at the start of the round).

After completing the review, append a round summary to {TEMP_DIR}/review_log.md.
```
