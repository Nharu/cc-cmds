# Skill whose banned path sits inside an HTML comment

The file the model reads includes its comments, so this is a real violation and
must stay caught. This fixture is what turns red if this lint is ever handed a
comment-blanked copy "for consistency" with the presence-asserting lints.

<!--
Manual cleanup target: `~/.claude/teams/{team-name}` — must fail lint.
-->
