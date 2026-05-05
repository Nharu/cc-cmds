# Team Cleanup (Shared Procedure)

After all team discussion/review is complete and results are synthesized, you MUST gracefully shut down the team. Follow these steps IN ORDER — do NOT skip ahead:

1. Send `shutdown_request` to each teammate via `SendMessage` (type: `"shutdown_request"`).

2. **WAIT for ALL teammates to confirm shutdown** (they respond with a `shutdown_response` DM via `SendMessage`, `approve: true`). Do NOT proceed to step 3 until every teammate has responded **as a DM** — a teammate whose session text says "shutting down" but who never invoked `SendMessage` has NOT confirmed. If a teammate does not respond, retry the `shutdown_request` — **repeat up to 10 times** with a brief pause between attempts. On retries after the 2nd, include an explicit channel reminder: *"Respond via `SendMessage` with a `shutdown_response` payload (type, request_id, approve). Plain-text acknowledgements are invisible to me."* **NEVER forcefully kill (`kill`) agent processes.**

3. **If a teammate still has not responded after 10 retries**, use `AskUserQuestion` to inform the user which teammate(s) failed to shut down and ask them to handle it manually. Do NOT proceed to `TeamDelete` until resolved.

4. Call `TeamDelete` to remove the team files and clean up resources. Only call this AFTER all teammates have confirmed shutdown or the user has handled unresponsive teammates.

5. **Verify process cleanup**: Run `ps aux | grep "team-name" | grep -v grep` to check for orphan agent processes. If any remain, **do NOT kill them** — use `AskUserQuestion` to inform the user of the remaining PIDs and ask them to terminate the processes.

## Idempotency guards

The 5-step procedure above MUST be idempotent so the facilitator-level `Cleanup-anchor recovery` rule (`_common/agent-team-protocol.md`) can invoke it at phase boundaries without regard to whether cleanup already ran.

Step inventory (referenced below): **step 1** = send `shutdown_request`, **step 2** = wait for `shutdown_response` + retry, **step 3** = after 10 retries surface via `AskUserQuestion`, **step 4** = `TeamDelete`, **step 5** = `ps aux` verification.

- **Pre-flight partial-state detection**: Before executing step 1, evaluate two signals via Bash and in-session state:
    - **S1 — Directory presence**: `test -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"` (same shell used by step 5's `ps aux` check).
    - **S2 — Session context activity**: the team was created via `TeamCreate` in this invocation AND at least one member has not yet received a `teammate_terminated` system notification.

    Branching based on the two signals:
    - **Directory absent (S1=false)** → full no-op. Team is already fully cleaned up. Return success without executing any subsequent step. This is the primary path Edit 6's "Cleanup-anchor recovery" relies on.
    - **Directory present but S2=false** → ambiguous case (all members terminated in this session, OR directory belongs to a different session, OR stale from prior crashed session). Apply **process-based disambiguation** before TeamDelete:
        1. Run process detection: `ps aux | grep -E "(<team-member-name-patterns>|tmux.*<team-name>)" | grep -v grep`. **Heuristic note**: CC's agent-team process naming scheme is not officially documented, so this pattern is best-effort. Refine it based on empirical dogfood observation (detectable via the "cleanup success rate" metric referenced in the design doc's Rollback section). Both false-positives (unrelated processes matching similar names) and false-negatives (CC runtime naming processes differently) are possible — mitigated below by cross-checking against the session's `TeamCreate` history in sub-cases 3/4.
        2. **No live processes found** → treat as stale (no recovery mechanism exists for CC agent teams across session death — if parent CC session ended, tmux panes for teammates also died; directory is file-system residue). Skip steps 1-3, proceed directly to step 4 (TeamDelete) + step 5 (ps aux re-verification).
        3. **Live processes found + this session has TeamCreate history for this team name** → current session's own team whose members happened to all receive `teammate_terminated` (rare edge case). Skip steps 1-3, proceed to step 4 + step 5.
        4. **Live processes found + this session does NOT have TeamCreate history for this team name** → concurrent-session conflict possible. Do NOT TeamDelete. Surface via `AskUserQuestion`:

           > "`{team-name}` directory exists and has live associated processes, but this session did not create it. It may belong to a concurrent session. Options: (a) skip this team (leave untouched), (b) force TeamDelete despite conflict risk, (c) abort workflow."

        Under normal flow (lead's own team just finished + all members terminated), **sub-case 3 above** (live processes + this session has TeamCreate history) applies and cleanup proceeds as expected. This branching preserves safety against concurrent-session collision while allowing stale-dir cleanup. Note: "sub-case N" here refers to the numbered list within the S1=true/S2=false branch, distinct from the main 5-step procedure's "step N" labels (step 1–5).
    - **Directory present AND S2=true (live team)** → execute the full 5-step flow normally.
- **Step 1 per-teammate tolerance**: If a teammate was already terminated (e.g., prior `teammate_terminated` system notification received, or `SendMessage` returns a not-found / dead-channel error for this teammate), skip `shutdown_request` for that teammate and count them as shutdown-confirmed for the purposes of step 2.
- **Step 4 not-found tolerance**: If `TeamDelete` returns an error indicating the team does not exist ("team not found", "no such team", or equivalent), treat as success. The desired post-condition (team resources cleaned up) is already satisfied.
- **Step 5 no-op on empty**: If no `shutdown_request` was sent (pre-flight no-op) or no teammates were spawned, the `ps aux` check is expected to return empty and is not a failure.

These guards do NOT weaken the cleanup contract — every failure mode that indicates an actual problem (unresponsive live teammate, TeamDelete failing with a different error type, orphan processes after a real shutdown) still follows the original error paths. The guards only short-circuit paths where the desired post-condition is already met.

## Shutdown failure fallback

If `TeamDelete` fails due to active teammates, **do NOT use `rm -rf` or `kill`**. Instead, before issuing `AskUserQuestion`, compute the actual cleanup paths by running the following Bash commands (substituting the real team name for `{team-name}`; if the team name contains spaces or special characters, assign it to a shell variable first):

```bash
echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"
echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/{team-name}"
```

Capture each output line as the resolved path. Then use `AskUserQuestion` to inform the user of the failure and ask them to manually remove those directories — embedding the computed path strings verbatim in the message body.

## Multiple teams

If multiple teams are created during the workflow (e.g., follow-up or refinement rounds), always clean up the previous team before creating the next one.
