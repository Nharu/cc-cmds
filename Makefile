.PHONY: lint readme check check-gate-suite policy-drift test test-rest gate-shard print-gate-shards test-active-notify test-orchestrator test-darwin test-darwin-narrow census run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest

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
	bash scripts/lint-team-model-tier-pins.sh
	bash scripts/lint-unattended-surfaces.sh
	bash scripts/lint-cutpoint-vocabulary.sh
	bash scripts/lint-autoadopt-vocabulary.sh
	bash scripts/lint-ledger-row-length.sh
	bash scripts/lint-judgment-grade.sh
	bash scripts/lint-notify-env-name.sh
	bash scripts/lint-notify-title-render.sh
	bash scripts/lint-notify-fire-sites.sh
	bash scripts/lint-watch-threshold-pins.sh
	bash scripts/lint-pace-threshold-pins.sh
	bash scripts/lint-fleet-agent-pins.sh
	bash scripts/lint-statusline-token-arms.sh
	bash scripts/lint-approval-state-vocabulary.sh
	bash scripts/lint-sidecar-field-table.sh
	bash scripts/lint-approval-answer-provenance.sh
	bash scripts/lint-reap-retention.sh
	bash scripts/lint-macos-keepset-paths.sh
	bash scripts/lint-recovery-interlock-pins.sh
	bash scripts/lint-checkpoint-round-scope.sh
	bash scripts/lint-harness-global-collisions.sh
	bash scripts/lint-prompt-schemas.sh
	bash scripts/lint-triage-pins.sh
	bash scripts/lint-gate-banner-fields.sh
	bash scripts/lint-stage-policy-sources.sh
	bash scripts/lint-terminal-literals.sh
	bash scripts/lint-interview-record-sections.sh
	bash scripts/lint-interview-convention-refs.sh
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
	@grep -qE '선리뷰후머지.*선머지후리뷰.*리뷰없음' plugins/cc-cmds/skills/_common/pipeline-sidecar.md || (echo "lint: the review-policy axis must be written strict-to-loose in the contract (선리뷰후머지 -> 선머지후리뷰 -> 리뷰없음); a reader who takes the axis backwards picks the opposite end, which is the human form of the defect this axis exists to remove. No lint script is added for this: the token vocabulary has exactly one enumeration in the tree so there is no second copy to drift, and a bad token fails hard on its first call at runtime -- document ORDER is the one thing no runtime detector sees" >&2; exit 1)

readme:
	bash scripts/generate-readme.sh

check: lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)
	@$(MAKE) --no-print-directory check-gate-suite

# `check` runs the gate suite, but only when the change touches gate.sh.
# scripts/test-gate.sh is the one suite that catches a broken grading table —
# `make lint` passes a gate.sh that no longer grades `gh pr merge` — and the
# procedure every commit goes through was `lint readme` alone, so a change to
# gate.sh that followed the procedure to the letter had no local step that ever
# ran it. Running it unconditionally would be worse than not running it: the
# suite alone takes some forty minutes, and a procedure that costs that on
# every commit is one people skip, which puts back the very state this closes.
# PR CI already runs the suite on the merge ref, so this adds no new duty; it
# runs the same suite earlier, on the machine that made the change.
#
# The comparison is against the merge-base with the base branch and the diff is
# taken against the working tree, so committed, staged and unstaged edits all
# count. A tree with no base to compare against runs the suite rather than
# skipping it — skipping there in silence is the gap this target exists to
# close — and a `git diff` that fails is a failure, never an empty change list.
# The suite path stays a literal default so `make -n check` still shows it.
GATE_SUITE_TRIGGER := plugins/cc-cmds/orchestrator/gate.sh
GATE_SUITE_CMD ?= bash scripts/test-gate.sh
GATE_SUITE_BASE ?=

check-gate-suite:
	@base='$(GATE_SUITE_BASE)'; \
	if [ -z "$$base" ]; then \
	  for ref in origin/HEAD origin/master master; do \
	    if git rev-parse --verify --quiet "$$ref^{commit}" >/dev/null; then base=$$ref; break; fi; \
	  done; \
	fi; \
	mb=; \
	if [ -n "$$base" ]; then mb=$$(git merge-base "$$base" HEAD 2>/dev/null) || mb=; fi; \
	if [ -z "$$mb" ]; then \
	  echo "check-gate-suite: 비교할 베이스를 해소하지 못해 게이트 스위트를 돌린다 (base='$$base')"; \
	  $(GATE_SUITE_CMD); exit $$?; \
	fi; \
	changed=$$(git diff --name-only "$$mb" -- '$(GATE_SUITE_TRIGGER)') \
	  || { echo "check-gate-suite: git diff 가 실패해 $(GATE_SUITE_TRIGGER) 의 변경 여부를 판정할 수 없다" >&2; exit 1; }; \
	if [ -z "$$changed" ]; then \
	  echo "check-gate-suite: $(GATE_SUITE_TRIGGER) 가 $$base 대비 바뀌지 않아 게이트 스위트를 건너뛴다"; \
	  exit 0; \
	fi; \
	echo "check-gate-suite: $(GATE_SUITE_TRIGGER) 가 $$base 대비 바뀌어 게이트 스위트를 돌린다"; \
	$(GATE_SUITE_CMD)

# Whether check-gate-suite decides anything. `make -n check | grep test-gate`
# passes just as well for a condition that is always false, so this runs the
# target in a scratch repository and watches whether the suite command actually
# ran: not when only another file changed, yes when gate.sh changed on the
# branch, yes when it changed only in the working tree, and a failing suite
# fails make. The first two are each other's control — either one alone passes
# an implementation that always runs the suite or one that never does. The base
# is left to the default resolution so the `master` fallback is what runs.
# The make binary is taken through a second variable on purpose: a recipe line
# that names $(MAKE) directly is executed even under `make -n`.
CHECK_GATE_SELFTEST_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
CHECK_GATE_SELFTEST_MAKE := $(MAKE)

run-check-gate-selftest:
	@unset MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GATE_SUITE_BASE; \
	t=$$(mktemp -d) || exit 1; trap 'rm -rf "$$t"' EXIT; \
	r=$$t/repo; mk='$(CHECK_GATE_SELFTEST_MAKEFILE)'; trig='$(GATE_SUITE_TRIGGER)'; \
	fail() { echo "run-check-gate-selftest: $$*" >&2; exit 1; }; \
	gc() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$$@"; }; \
	suite() { rm -f "$$t/ran"; '$(CHECK_GATE_SELFTEST_MAKE)' --no-print-directory -f "$$mk" check-gate-suite GATE_SUITE_CMD="$$1" >"$$t/out" 2>&1; }; \
	mkdir -p "$$r/$${trig%/*}" && cd "$$r" && gc init -q -b master . \
	  && echo a > "$$trig" && echo a > other && gc add -A && gc commit -qm base \
	  && gc checkout -q -b only-other || fail "임시 저장소를 만들지 못했다"; \
	echo b > other && gc commit -qam other || fail "경우 A 를 준비하지 못했다"; \
	suite "touch $$t/ran" || fail "경우 A: make 가 실패했다: $$(cat "$$t/out")"; \
	[ ! -e "$$t/ran" ] || fail "경우 A: gate.sh 를 건드리지 않은 변경에서 스위트가 돌았다"; \
	echo b > "$$trig" && gc commit -qam gate || fail "경우 B 를 준비하지 못했다"; \
	suite "touch $$t/ran" || fail "경우 B: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 B: 브랜치에서 커밋한 gate.sh 변경에 스위트가 돌지 않았다"; \
	gc checkout -q master && gc checkout -q -b worktree-only && echo c > "$$trig" || fail "경우 C 를 준비하지 못했다"; \
	suite "touch $$t/ran" || fail "경우 C: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 C: 작업 트리에만 있는 gate.sh 변경에 스위트가 돌지 않았다"; \
	if suite false; then fail "경우 D: 스위트가 실패했는데 make 가 성공했다"; fi; \
	echo "run-check-gate-selftest: 네 경우 통과"

# The source half of the stage-policy drift check: does the policy the gate
# injects into unattended stages still say what the user-scope CLAUDE.md and
# the workspace instruction file say? Deliberately NOT part of `lint` — those
# sources are a person's global files, and editing them must not turn an
# unrelated unattended stage's `make check` red. Run by hand, at autopilot
# kickoff, and logged at run open. `--explain` puts the diff of each changed
# item under its finding, which is what a person needs to judge an `--ack`.
policy-drift:
	bash plugins/cc-cmds/orchestrator/stage-policy-drift.sh --explain

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
	scripts/test-lint-team-model-tier-pins.sh \
	scripts/test-lint-unattended-surfaces.sh \
	scripts/test-lint-cutpoint-vocabulary.sh \
	scripts/test-lint-autoadopt-vocabulary.sh \
	scripts/test-lint-ledger-row-length.sh \
	scripts/test-lint-judgment-grade.sh \
	scripts/test-lint-notify-env-name.sh \
	scripts/test-lint-notify-title-render.sh \
	scripts/test-lint-notify-fire-sites.sh \
	scripts/test-lint-watch-threshold-pins.sh \
	scripts/test-lint-pace-threshold-pins.sh \
	scripts/test-lint-statusline-token-arms.sh \
	scripts/test-lint-approval-state-vocabulary.sh \
	scripts/test-lint-sidecar-field-table.sh \
	scripts/test-lint-approval-answer-provenance.sh \
	scripts/test-lint-reap-retention.sh \
	scripts/test-lint-recovery-interlock-pins.sh \
	scripts/test-lint-ci-scope-binding.sh \
	scripts/test-lint-macos-keepset-paths.sh \
	scripts/test-lint-harness-global-collisions.sh \
	tests/fixtures/lint-gate-banner-fields/run.sh \
	scripts/test-gate-oracle.sh \
	scripts/test-measure-team-cost.sh \
	scripts/test-generate-readme.sh \
	scripts/test-readme-gen-parity.sh \
	scripts/test-lint-stage-policy-sources.sh \
	scripts/test-lint-terminal-literals.sh \
	scripts/test-lint-interview-record-sections.sh \
	scripts/test-lint-interview-convention-refs.sh

ORCH_TESTS := \
	plugins/cc-cmds/orchestrator/test-run.sh \
	scripts/test-gate.sh \
	scripts/test-team-witness-init.sh \
	scripts/test-similar-items.sh \
	scripts/test-gate-chain-equiv.sh \
	scripts/test-measure-gate-cost.sh \
	scripts/test-snapshot.sh \
	scripts/test-orchestrator-pretool-hook.sh \
	scripts/test-session-notify-hook.sh \
	scripts/test-stage-policy-edit-hook.sh \
	scripts/test-watch.sh \
	scripts/test-fleet.sh \
	scripts/test-statusline.sh \
	scripts/test-liveness-agreement.sh \
	scripts/test-lost-dispatch.sh \
	scripts/test-stage-supervisor.sh \
	scripts/test-design-brief.sh \
	scripts/test-route.sh \
	scripts/test-collect-run-metrics.sh \
	scripts/test-run-issue-filing.sh

DARWIN_TESTS := \
	scripts/test-notify-title-oracle.sh

ALL_TESTS := $(NOTIFY_TESTS) $(LINT_TESTS) $(ORCH_TESTS) $(DARWIN_TESTS)
TEST_GOALS := $(ALL_TESTS:%=run/%)

.PHONY: $(TEST_GOALS)

$(TEST_GOALS): run/%:
	bash $*

test: $(NOTIFY_TESTS:%=run/%) $(LINT_TESTS:%=run/%) $(ORCH_TESTS:%=run/%) \
	run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest

# How many shards the gate suite is cut into. CI reads it so the matrix, the
# per-shard dispatch and the union check all take their N from one place; a
# workflow that spelled the number itself would let the matrix and the check
# disagree, and the sections in the gap would belong to nobody.
GATE_SHARDS ?= 13

# So CI can read the number instead of spelling it a second time.
print-gate-shards:
	@echo $(GATE_SHARDS)

# `test` minus the gate suite. CI runs this in the always-on leg because the
# gate suite runs sharded in its own workflow, and running it in both places
# would put the forty minutes back that the sharding removes. Locally `test`
# is still the whole thing.
ORCH_TESTS_REST := $(filter-out scripts/test-gate.sh,$(ORCH_TESTS))

test-rest: $(NOTIFY_TESTS:%=run/%) $(LINT_TESTS:%=run/%) $(ORCH_TESTS_REST:%=run/%) \
	run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest

# One shard of the gate suite. SHARD is 1-based. An empty assignment is a
# success and not a failure — the partitioner exits 4 when the requested shard
# drew nothing, which happens whenever the components outnumber no shard.
gate-shard:
	@ids=$$(bash scripts/gate-shard.sh --shards $(GATE_SHARDS) --shard $(SHARD)); rc=$$?; \
	if [ "$$rc" = "4" ]; then echo "shard $(SHARD)/$(GATE_SHARDS): 배정된 절이 없습니다"; exit 0; fi; \
	[ "$$rc" = "0" ] || exit "$$rc"; \
	bash scripts/test-gate.sh --sections "$$ids"

# The partitioner and the census are driven by flags, so they cannot sit in the
# argument-less `bash <script>` lists above; their self-tests run no suite and
# take seconds.
run-gate-shard-selftest:
	bash scripts/gate-shard.sh --self-test

run-gate-census-selftest:
	bash scripts/gate-census.sh --self-test

# Regenerate scripts/gate-census.tsv. Run by hand, never from `test`: it runs
# every section alone, the whole suite once and every shard once — about an hour
# on an idle machine — and what it writes is a file to review and commit.
census:
	bash scripts/gate-census.sh --shards $(GATE_SHARDS) --out scripts/gate-census.tsv

test-active-notify: $(NOTIFY_TESTS:%=run/%)

test-orchestrator: $(ORCH_TESTS:%=run/%)

# The darwin leg. Both suites are host-OS-seamed: the ubuntu leg drives their
# Darwin branches by injection and covers all the selection logic, so what this
# target adds is only the handful of claims that need a real darwin kernel —
# process-group reparenting, advisory-lock contention, the boot clock across a
# sleep, and terminal-notifier delivery. Naming it for the platform rather than
# for one skill is what keeps a future darwin-dependent suite from having to
# re-wire the workflow to be seen.
#
# CI's macOS leg does not run this target; it runs `test-darwin-narrow` below.
test-darwin: test-active-notify test-orchestrator \
	run/scripts/test-lint-bash-portability.sh \
	$(DARWIN_TESTS:%=run/%)

# The darwin leg in CI. `test-darwin` above stays the whole darwin run for a
# local machine; this is the short list the macOS runner actually needs. A
# suite is on it only because the ubuntu leg cannot check what it checks — and
# the same assertion NAMES on both legs is not enough to say so, because a
# suite that silently tests nothing on one host prints the same names there.
# What each entry covers that no ubuntu run does:
#
#   test-run.sh                   the bash 3.2 floor actually exercised, the
#                                 boot clock, and the data-volume spelling of
#                                 a path, which ubuntu skips with a note.
#   test-gate-chain-equiv.sh      the enumerated divergences of the frozen
#                                 reference, which classify differently here.
#   test-lint-bash-portability.sh the multibyte-space case.
#   test-liveness-agreement.sh    the Hangul-date fingerprint assertions; the
#                                 ubuntu runner has no ko_KR.UTF-8 locale, so
#                                 there they pass without testing anything.
#   test-notify-title-oracle.sh   the real terminal-notifier's swallowing set.
#   test-gate.sh, section 18      the advisory-lock arm, which is darwin-only
#                                 for real.
#   test-gate.sh, section 31ai    the transition guard INSIDE that lock. The
#                                 lock tool is yielded on darwin alone, so the
#                                 ubuntu leg takes the unlocked fallback and
#                                 never runs the guard body; section 18 drives
#                                 the lock but passes no transition argument, so
#                                 it skips that body too. 31ai runs a real
#                                 `close`, which is how the guard gets reached.
#
# The two active-notify suites print the same assertions on both legs and are
# kept anyway: taking them off does not move the PR's critical path, which the
# ubuntu leg sets.
#
# Anything added here must also be matched by that workflow's `paths` filter,
# together with every file it sources, and nothing may stay in the filter that
# this list does not run, source or refer to. scripts/lint-macos-keepset-paths.sh
# checks both directions.
DARWIN_GATE_SECTIONS := 18,31ai

.PHONY: run-gate-darwin-sections

run-gate-darwin-sections:
	bash scripts/test-gate.sh --sections $(DARWIN_GATE_SECTIONS)

test-darwin-narrow: test-active-notify \
	run/plugins/cc-cmds/orchestrator/test-run.sh \
	run/scripts/test-gate-chain-equiv.sh \
	run/scripts/test-lint-bash-portability.sh \
	run/scripts/test-liveness-agreement.sh \
	$(DARWIN_TESTS:%=run/%) \
	run-gate-darwin-sections
