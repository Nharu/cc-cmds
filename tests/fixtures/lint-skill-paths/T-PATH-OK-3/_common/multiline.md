# Multi-line cleanup procedure

If `TeamDelete` fails, compute paths first:

```bash
echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"
echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/{team-name}"
```

Then surface the resolved strings in the AskUserQuestion body.
