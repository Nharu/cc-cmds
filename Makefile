.PHONY: lint readme check test test-active-notify test-orchestrator test-darwin

lint:
	bash scripts/lint-skill-invariants.sh
	bash scripts/lint-skill-options.sh
	bash scripts/lint-skill-paths.sh
	bash scripts/lint-skill-description-budget.sh
	bash scripts/lint-bash-portability.sh
	bash scripts/lint-skill-auq-spec.sh
	bash scripts/lint-verification-literals.sh
	bash scripts/lint-design-audit-pins.sh
	bash scripts/lint-team-budget-pins.sh
	bash scripts/lint-unattended-surfaces.sh
	bash scripts/lint-cutpoint-vocabulary.sh
	bash scripts/lint-ledger-row-length.sh
	bash scripts/lint-judgment-grade.sh
	bash scripts/lint-notify-env-name.sh
	@jq empty plugins/cc-cmds/hooks/hooks.json
	@test -x plugins/cc-cmds/hooks/active-notify-pretool.sh
	@grep -qE "terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]" plugins/cc-cmds/skills/active-notify/SKILL.md || (echo "lint: SKILL.md §7 bypass single-line contract violated (terminal-notifier + -group [quoted]cc-cmds-active-notify[quoted] must be on the same line for bypass_re to match)" >&2; exit 1)
	@jq -e 'has("version")' plugins/cc-cmds/.claude-plugin/plugin.json >/dev/null || (echo "lint: plugin.json must have a .version field (it is the single version SOT)" >&2; exit 1)
	@jq -e '[.plugins[] | has("version")] | any | not' .claude-plugin/marketplace.json >/dev/null || (echo "lint: marketplace.json plugin entries must NOT declare .version (plugin.json is the version SOT)" >&2; exit 1)

readme:
	bash scripts/generate-readme.sh

check: lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)

test: test-active-notify
	bash scripts/test-lint-skill-options.sh
	bash scripts/test-lint-skill-invariants.sh
	bash scripts/test-lint-skill-paths.sh
	bash scripts/test-lint-bash-portability.sh
	bash scripts/test-lint-skill-auq-spec.sh
	bash scripts/test-lint-verification-literals.sh
	bash scripts/test-lint-design-audit-pins.sh
	bash scripts/test-lint-team-budget-pins.sh
	bash scripts/test-lint-unattended-surfaces.sh
	bash scripts/test-lint-cutpoint-vocabulary.sh
	bash scripts/test-lint-ledger-row-length.sh
	bash scripts/test-lint-judgment-grade.sh
	bash scripts/test-lint-notify-env-name.sh
	bash scripts/test-measure-team-cost.sh
	bash scripts/test-generate-readme.sh
	bash scripts/test-readme-gen-parity.sh
	bash plugins/cc-cmds/orchestrator/test-run.sh
	bash scripts/test-gate.sh
	bash scripts/test-snapshot.sh
	bash scripts/test-orchestrator-pretool-hook.sh
	bash scripts/test-watch.sh
	bash scripts/test-statusline.sh
	bash scripts/test-liveness-agreement.sh

test-active-notify:
	bash scripts/test-active-notify-lifecycle.sh
	bash scripts/test-active-notify-pretool-hook.sh

test-orchestrator:
	bash plugins/cc-cmds/orchestrator/test-run.sh
	bash scripts/test-gate.sh
	bash scripts/test-snapshot.sh
	bash scripts/test-orchestrator-pretool-hook.sh
	bash scripts/test-watch.sh
	bash scripts/test-statusline.sh
	bash scripts/test-liveness-agreement.sh

# The darwin leg. Both suites are host-OS-seamed: the ubuntu leg drives their
# Darwin branches by injection and covers all the selection logic, so what this
# target adds is only the handful of claims that need a real darwin kernel —
# process-group reparenting, advisory-lock contention, the boot clock across a
# sleep, and terminal-notifier delivery. Naming it for the platform rather than
# for one skill is what keeps a future darwin-dependent suite from having to
# re-wire the workflow to be seen.
test-darwin: test-active-notify test-orchestrator
	bash scripts/test-lint-bash-portability.sh
