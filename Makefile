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
	bash scripts/lint-autoadopt-vocabulary.sh
	bash scripts/lint-ledger-row-length.sh
	bash scripts/lint-judgment-grade.sh
	bash scripts/lint-notify-env-name.sh
	bash scripts/lint-notify-title-render.sh
	bash scripts/lint-notify-fire-sites.sh
	bash scripts/lint-watch-threshold-pins.sh
	bash scripts/lint-statusline-token-arms.sh
	bash scripts/lint-recovery-interlock-pins.sh
	@jq empty plugins/cc-cmds/hooks/hooks.json
	@test -x plugins/cc-cmds/hooks/active-notify-pretool.sh
	@grep -qE "terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]" plugins/cc-cmds/skills/active-notify/SKILL.md || (echo "lint: SKILL.md §7 bypass single-line contract violated (terminal-notifier + -group [quoted]cc-cmds-active-notify[quoted] must be on the same line for bypass_re to match)" >&2; exit 1)
	@jq -e 'has("version")' plugins/cc-cmds/.claude-plugin/plugin.json >/dev/null || (echo "lint: plugin.json must have a .version field (it is the single version SOT)" >&2; exit 1)
	@jq -e '[.plugins[] | has("version")] | any | not' .claude-plugin/marketplace.json >/dev/null || (echo "lint: marketplace.json plugin entries must NOT declare .version (plugin.json is the version SOT)" >&2; exit 1)

readme:
	bash scripts/generate-readme.sh

check: lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)

# Each suite is a LIST of scripts rather than a block of recipe lines, so that
# the scripts become prerequisites and `make -j` can run them at once. As recipe
# lines they were strictly serial no matter what -j said, and that is the whole
# of the suite's wall clock: measured on this repository, the run takes about
# half an hour while the twenty-three smallest scripts together account for
# thirty-five seconds of it. Serially every one of them waits behind the two
# large ones for nothing.
#
# Concurrency is safe without further isolation and the tests already say so:
# every one of them builds its own workspace with `mktemp -d`, the single
# script that runs `git worktree add` does it inside that workspace, and the
# notification lifecycle test overrides TMPDIR so its flag cannot collide with
# a real one. Nothing here writes into the checkout.
NOTIFY_TESTS := \
	scripts/test-active-notify-lifecycle.sh \
	scripts/test-active-notify-pretool-hook.sh

LINT_TESTS := \
	scripts/test-lint-skill-options.sh \
	scripts/test-lint-skill-invariants.sh \
	scripts/test-lint-skill-paths.sh \
	scripts/test-lint-bash-portability.sh \
	scripts/test-lint-skill-auq-spec.sh \
	scripts/test-lint-verification-literals.sh \
	scripts/test-lint-design-audit-pins.sh \
	scripts/test-lint-team-budget-pins.sh \
	scripts/test-lint-unattended-surfaces.sh \
	scripts/test-lint-cutpoint-vocabulary.sh \
	scripts/test-lint-autoadopt-vocabulary.sh \
	scripts/test-lint-ledger-row-length.sh \
	scripts/test-lint-judgment-grade.sh \
	scripts/test-lint-notify-env-name.sh \
	scripts/test-lint-notify-title-render.sh \
	scripts/test-lint-notify-fire-sites.sh \
	scripts/test-lint-watch-threshold-pins.sh \
	scripts/test-lint-statusline-token-arms.sh \
	scripts/test-lint-recovery-interlock-pins.sh \
	scripts/test-lint-ci-scope-binding.sh \
	scripts/test-measure-team-cost.sh \
	scripts/test-generate-readme.sh \
	scripts/test-readme-gen-parity.sh

ORCH_TESTS := \
	plugins/cc-cmds/orchestrator/test-run.sh \
	scripts/test-gate.sh \
	scripts/test-team-witness-init.sh \
	scripts/test-gate-chain-equiv.sh \
	scripts/test-measure-gate-cost.sh \
	scripts/test-snapshot.sh \
	scripts/test-orchestrator-pretool-hook.sh \
	scripts/test-watch.sh \
	scripts/test-statusline.sh \
	scripts/test-liveness-agreement.sh

DARWIN_TESTS := \
	scripts/test-notify-title-oracle.sh

ALL_TESTS := $(NOTIFY_TESTS) $(LINT_TESTS) $(ORCH_TESTS) $(DARWIN_TESTS)
TEST_GOALS := $(ALL_TESTS:%=run/%)

.PHONY: $(TEST_GOALS)

$(TEST_GOALS): run/%:
	bash $*

test: $(NOTIFY_TESTS:%=run/%) $(LINT_TESTS:%=run/%) $(ORCH_TESTS:%=run/%)

test-active-notify: $(NOTIFY_TESTS:%=run/%)

test-orchestrator: $(ORCH_TESTS:%=run/%)

# The darwin leg. Both suites are host-OS-seamed: the ubuntu leg drives their
# Darwin branches by injection and covers all the selection logic, so what this
# target adds is only the handful of claims that need a real darwin kernel —
# process-group reparenting, advisory-lock contention, the boot clock across a
# sleep, and terminal-notifier delivery. Naming it for the platform rather than
# for one skill is what keeps a future darwin-dependent suite from having to
# re-wire the workflow to be seen.
test-darwin: test-active-notify test-orchestrator \
	run/scripts/test-lint-bash-portability.sh \
	$(DARWIN_TESTS:%=run/%)
