# Skill with single-dash fallback violation

Path with single-dash form: `${CLAUDE_CONFIG_DIR-$HOME/.claude}/teams/foo` — must fail
because STRIP_SED only whitelists `:-`, leaving the bare `$HOME/.claude` exposed.
