# Team Cleanup (Shared Procedure)

After all team discussion/review is complete and results are synthesized, you MUST gracefully shut down the team. Follow these steps IN ORDER — do NOT skip ahead:

1. Send `shutdown_request` to each teammate via `SendMessage` (type: `"shutdown_request"`).

2. **WAIT for ALL teammates to confirm shutdown** (they respond with `shutdown_response` approve: true). Do NOT proceed to step 3 until every teammate has responded. If a teammate does not respond, retry the `shutdown_request` — **repeat up to 10 times** with a brief pause between attempts. **NEVER forcefully kill (`kill`) agent processes.**

3. **If a teammate still has not responded after 10 retries**, use `AskUserQuestion` to inform the user which teammate(s) failed to shut down and ask them to handle it manually. Do NOT proceed to `TeamDelete` until resolved.

4. Call `TeamDelete` to remove the team files and clean up resources. Only call this AFTER all teammates have confirmed shutdown or the user has handled unresponsive teammates.

5. **Verify process cleanup**: Run `ps aux | grep "team-name" | grep -v grep` to check for orphan agent processes. If any remain, **do NOT kill them** — use `AskUserQuestion` to inform the user of the remaining PIDs and ask them to terminate the processes.

## Shutdown failure fallback

If `TeamDelete` fails due to active teammates, **do NOT use `rm -rf` or `kill`**. Instead, use `AskUserQuestion` to inform the user of the failure and ask them to manually clean up (`~/.claude/teams/{team-name}` and `~/.claude/tasks/{team-name}`).

## Multiple teams

If multiple teams are created during the workflow (e.g., follow-up or refinement rounds), always clean up the previous team before creating the next one.
