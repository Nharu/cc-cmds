# Some skill

Detect active teams by enumerating `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/` via Bash:
`ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/" 2>/dev/null | grep -E "^design-foo$"`.

S1 directory presence: `test -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{team-name}"`.
