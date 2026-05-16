.PHONY: lint readme check test

lint:
	bash scripts/lint-skill-invariants.sh
	bash scripts/lint-skill-options.sh
	bash scripts/lint-skill-paths.sh
	@jq empty plugins/cc-cmds/hooks/hooks.json
	@test -x plugins/cc-cmds/hooks/active-notify-pretool.sh
	@test -x plugins/cc-cmds/hooks/active-notify-stop.sh
	@grep -qE "terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]" plugins/cc-cmds/skills/active-notify/SKILL.md || (echo "lint: SKILL.md §7 bypass single-line contract violated (terminal-notifier + -group [quoted]cc-cmds-active-notify[quoted] must be on the same line for bypass_re to match)" >&2; exit 1)

readme:
	bash scripts/generate-readme.sh

check: lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)

test:
	bash scripts/test-lint-skill-options.sh
	bash scripts/test-lint-skill-invariants.sh
	bash scripts/test-lint-skill-paths.sh
	bash scripts/test-generate-readme.sh
	bash scripts/test-readme-gen-parity.sh
	bash scripts/test-active-notify-lifecycle.sh
	bash scripts/test-active-notify-stop-hook.sh
	bash scripts/test-active-notify-pretool-hook.sh
