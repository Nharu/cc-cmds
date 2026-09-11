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
	bash scripts/lint-approval-state-vocabulary.sh
	bash scripts/lint-sidecar-field-table.sh
	bash scripts/lint-approval-answer-provenance.sh
	@jq empty plugins/cc-cmds/hooks/hooks.json
# Every command path in hooks.json must exist and be executable. This REPLACES a
# hard-coded assertion that named one hook, which had already stopped covering a
# sibling that was added beside it; a second assertion in a new place would have
# split the same check in two and let the next hook fall through the same gap.
# A hook whose path is wrong is silent — the harness runs nothing and says
# nothing — so this is the only place the typo becomes visible.
#
# The resolution count is compared first. `grep -o` would drop a command that is
# not written against the plugin root, and a dropped command is one this walk
# never checked while reporting success over the rest.
	@n_cmd=$$(jq -r '.hooks[][].hooks[].command' plugins/cc-cmds/hooks/hooks.json | grep -c .); \
	 n_path=$$(jq -r '.hooks[][].hooks[].command' plugins/cc-cmds/hooks/hooks.json | grep -oE '[$$][{]CLAUDE_PLUGIN_ROOT[}][^" ]*' | grep -c .); \
	 test "$$n_cmd" = "$$n_path" || { echo "lint: hooks.json 의 command $$n_cmd 개 중 $$n_path 개만 플러그인 상대 경로로 해소된다" >&2; exit 1; }; \
	 jq -r '.hooks[][].hooks[].command' plugins/cc-cmds/hooks/hooks.json \
	   | grep -oE '[$$][{]CLAUDE_PLUGIN_ROOT[}][^" ]*' \
	   | sed -e 's|[$$][{]CLAUDE_PLUGIN_ROOT[}]|plugins/cc-cmds|' \
	   | while IFS= read -r p; do \
	       test -f "$$p" || { echo "lint: hooks.json 이 가리키는 파일이 없다: $$p" >&2; exit 1; }; \
	       test -x "$$p" || { echo "lint: hooks.json 이 가리키는 파일이 실행 가능하지 않다: $$p" >&2; exit 1; }; \
	     done
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
	scripts/test-lint-approval-state-vocabulary.sh \
	scripts/test-lint-sidecar-field-table.sh \
	scripts/test-lint-approval-answer-provenance.sh \
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
	scripts/test-session-notify-hook.sh \
	scripts/test-watch.sh \
	scripts/test-statusline.sh \
	scripts/test-liveness-agreement.sh \
	scripts/test-lost-dispatch.sh

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
