# The gate's run-open branch starts the run dashboard, and a server it starts
# outlives the suite that opened the run. Every suite already turns the switch
# off for itself; this default covers one that forgets.
export CC_CMDS_DASHBOARD := off

# A new run's pin fetches the plugin checkout's `origin` and may pin the remote
# tip tree instead of the checkout. A harness that opens runs with pinning left
# on would then test remote code rather than the tree under test, and such
# harnesses cannot be listed by name, so every harness make starts inherits the
# switch that turns the fetch and fast-forward off (the pin itself stays on).
# Calling a harness other than test-gate.sh directly outside make, put
# `CC_GATE_PIN_SYNC_DISABLE=1` in front of it.
export CC_GATE_PIN_SYNC_DISABLE := 1

# Every check and suite runs in one time zone, whatever the caller's TZ says:
# the local host and CI's runners otherwise disagree, and a suite that mistakes
# local time for UTC passes on a UTC runner and fails here, or the other way
# round. A variable defined in the makefile beats the same name in the
# environment, so `TZ=UTC0 make test` still runs under this value. It is not
# UTC on purpose: under an offset of zero that mistake passes everywhere and
# hides. Calling a suite directly outside make inherits the host's zone instead;
# put `TZ=Asia/Seoul` in front of it on a host that is not KST. A child a suite
# starts with `env -i` does not receive the exported TZ either, so a new suite
# that does so passes `TZ` to that child explicitly.
TEST_TZ := Asia/Seoul
export TZ := $(TEST_TZ)

.PHONY: lint readme check check-unattended-refusal check-gate-suite policy-drift rule-enforcement testtest-rest gate-shard print-gate-shards print-gate-lanes print-gate-slots print-gate-sections print-gate-digests rest-shard print-rest-shards print-rest-goals test-active-notify test-orchestrator test-darwin test-darwin-narrow census run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest run-rest-shard-selftest print-test-tz tz-probe check-cheap check-push check-push-verify run-check-push-selftest run-test-tree-selftest run-gate-timing-selftest run-ci-duration-selftest print-gate-iso-extra run-gate-isolation-selftest isolation-check isolation-sweep isolation-capacity

lint:
	bash scripts/lint-skill-invariants.sh
	bash scripts/lint-skill-options.sh
	bash scripts/lint-skill-paths.sh
	bash scripts/lint-skill-description-budget.sh
	bash scripts/lint-bash-portability.sh
	bash scripts/lint-test-clock.sh
	bash scripts/lint-skill-auq-spec.sh
	bash scripts/lint-verification-literals.sh
	bash scripts/lint-design-audit-pins.sh
	bash scripts/lint-team-budget-pins.sh
	bash scripts/lint-team-model-tier-pins.sh
	bash scripts/lint-unattended-surfaces.sh
	bash scripts/lint-attention-schema.sh
	bash scripts/lint-lead-read-set.sh
	bash scripts/lint-cutpoint-vocabulary.sh
	bash scripts/lint-autoadopt-vocabulary.sh
	bash scripts/lint-ledger-row-length.sh
	bash scripts/lint-ledger-provenance.sh
	bash scripts/lint-judgment-grade.sh
	bash scripts/lint-notify-env-name.sh
	bash scripts/lint-notify-title-render.sh
	bash scripts/lint-notify-fire-sites.sh
	bash scripts/lint-watch-threshold-pins.sh
	bash scripts/lint-pace-threshold-pins.sh
	bash scripts/lint-fleet-agent-pins.sh
	bash scripts/lint-statusline-token-arms.sh
	bash scripts/lint-statusline-wrapper-pins.sh
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
	bash scripts/lint-kickoff-defaults.sh
	@jq empty plugins/cc-cmds/hooks/hooks.json
# Every command path in hooks.json must exist and be executable. This REPLACES a
# hard-coded assertion that named one hook, which had already stopped covering a
# sibling that was added beside it; a second assertion in a new place would have
# split the same check in two and let the next hook fall through the same gap.
# A hook whose path is wrong is silent — the harness runs nothing and says
# nothing — so this is the only place the typo becomes visible.
#
# Coverage is checked first, PER COMMAND rather than by a total count. `grep -o`
# would drop a command that is not written against the plugin root, and a dropped
# command is one this walk never checked while reporting success over the rest.
# The earlier form compared the number of commands against the number of root
# references and demanded they be equal, which silently required EXACTLY ONE
# reference per command. A command may legitimately name the root twice — once as
# the script it runs and once as an argument that hands the same directory to
# that script — and under the old form such a command made the totals differ and
# failed the check while every command was in fact covered.
#
# The coverage test asks for a root reference WITH A PATH under it. A bare
# `${CLAUDE_PLUGIN_ROOT}` is a directory handed to a script, not something the
# walk can open, so counting it as coverage would let a command pass the first
# test and contribute nothing to the second.
	@bad=$$(jq -r '.hooks[][].hooks[].command' plugins/cc-cmds/hooks/hooks.json | grep -cvF '$${CLAUDE_PLUGIN_ROOT}/' || true); \
	 test "$$bad" = "0" || { echo "lint: hooks.json 의 command 중 $$bad 개가 플러그인 루트 아래 경로를 갖지 않아 아래 검사가 건너뛴다" >&2; exit 1; }; \
	 jq -r '.hooks[][].hooks[].command' plugins/cc-cmds/hooks/hooks.json \
	   | grep -oE '[$$][{]CLAUDE_PLUGIN_ROOT[}]/[^" ]+' \
	   | sed -e 's|[$$][{]CLAUDE_PLUGIN_ROOT[}]|plugins/cc-cmds|' \
	   | while IFS= read -r p; do \
	       test -f "$$p" || { echo "lint: hooks.json 이 가리키는 파일이 없다: $$p" >&2; exit 1; }; \
	       test -x "$$p" || { echo "lint: hooks.json 이 가리키는 파일이 실행 가능하지 않다: $$p" >&2; exit 1; }; \
	     done
# Every module path in hooks.json, and the plugin's type contract when it names
# one, must exist. A module the engine cannot find is skipped as silently as a
# missing command hook, and nothing else in this tree reads either path. The
# execute bit is not asked for: the engine reads these files, it does not run
# them.
	@jq -r '.modules[]?' plugins/cc-cmds/hooks/hooks.json \
	   | while IFS= read -r p; do \
	       test -f "plugins/cc-cmds/hooks/$$p" || { echo "lint: hooks.json 의 modules 가 가리키는 파일이 없다: $$p" >&2; exit 1; }; \
	     done
	@t=$$(jq -r '.types // empty' plugins/cc-cmds/.claude-plugin/plugin.json); \
	 test -z "$$t" || test -f "plugins/cc-cmds/$$t" || { echo "lint: plugin.json 의 types 가 가리키는 파일이 없다: $$t" >&2; exit 1; }
	@grep -qE "terminal-notifier[[:space:]].*-group[[:space:]]['\"]cc-cmds-active-notify['\"]" plugins/cc-cmds/skills/active-notify/SKILL.md || (echo "lint: SKILL.md §7 bypass single-line contract violated (terminal-notifier + -group [quoted]cc-cmds-active-notify[quoted] must be on the same line for bypass_re to match)" >&2; exit 1)
	@jq -e 'has("version")' plugins/cc-cmds/.claude-plugin/plugin.json >/dev/null || (echo "lint: plugin.json must have a .version field (it is the single version SOT)" >&2; exit 1)
	@jq -e '[.plugins[] | has("version")] | any | not' .claude-plugin/marketplace.json >/dev/null || (echo "lint: marketplace.json plugin entries must NOT declare .version (plugin.json is the version SOT)" >&2; exit 1)
	@grep -qE '선리뷰후머지.*선머지후리뷰.*리뷰없음' plugins/cc-cmds/skills/_common/pipeline-sidecar.md || (echo "lint: the review-policy axis must be written strict-to-loose in the contract (선리뷰후머지 -> 선머지후리뷰 -> 리뷰없음); a reader who takes the axis backwards picks the opposite end, which is the human form of the defect this axis exists to remove. No lint script is added for this: the token vocabulary has exactly one enumeration in the tree so there is no second copy to drift, and a bad token fails hard on its first call at runtime -- document ORDER is the one thing no runtime detector sees" >&2; exit 1)
# Every scripts/lint-*.sh and scripts/test-*.sh must be registered here. An
# unregistered script never runs, so no test of its own can report its absence;
# this guard is the only place that does. Registration takes two shapes and both
# count: a recipe line `bash scripts/<name>` and a list item `scripts/<name> \`
# that `run/%` runs. A name counts as registered when it stands as a whole word
# on a line that is not a comment — after the line start or whitespace, and
# before whitespace, a backslash or the line end. Comment lines are left out
# because comments here name scripts too, and a name that appears only in a
# comment belongs to a script that never runs. The contract is a glob, not an
# enumeration, so a new script needs no list edit to be covered.
#
# The exception list is closed and holds one name. lint-ci-scope-binding.sh
# fails on today's tree (the workflow's make call sits inside a multi-line
# `run: |` block it cannot read), so registering it would turn lint red. The
# exception is checked both ways: a listed name that leaves the tree, or that
# reads as registered, is reported, so the commit that fixes and registers that
# lint must drop it here too.
	@reg=$$(grep -vE '^[[:space:]]*#' Makefile | tr -s ' \t' '\n\n' | sed -e 's/\\.*//' | grep -E '^scripts/' || true); \
	 skip='scripts/lint-ci-scope-binding.sh'; \
	 bad=0; \
	 for s in $$skip; do \
	   test -f "$$s" || { echo "lint: Makefile 등록 가드의 예외 $$s 가 트리에 없다 — 예외 목록에서 지운다" >&2; bad=1; }; \
	   if printf '%s\n' "$$reg" | grep -qFx "$$s"; then echo "lint: Makefile 등록 가드의 예외 $$s 가 등록되어 있다 — 예외 목록에서 지운다" >&2; bad=1; fi; \
	 done; \
	 for f in scripts/lint-*.sh scripts/test-*.sh; do \
	   case " $$skip " in *" $$f "*) continue ;; esac; \
	   printf '%s\n' "$$reg" | grep -qFx "$$f" || { echo "lint: $$f 가 Makefile 의 주석 아닌 줄에 등록되어 있지 않다 — 등록되지 않은 스크립트는 한 번도 돌지 않는다" >&2; bad=1; }; \
	 done; \
	 test "$$bad" = 0

readme:
	bash scripts/generate-readme.sh

# The unattended refusal of check-gate-suite is decided before lint and readme,
# so a run that would be refused does not spend them first. A prerequisite
# alone would not order it: this Makefile is run with -jN, and prerequisites of
# one target have no order between them. So `check` has the refusal as its one
# prerequisite and calls lint and readme from its recipe. The recursive calls
# name this file, so `make -f <path> check` from another directory finds it.
CHECK_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))

check: check-unattended-refusal
	@$(MAKE) --no-print-directory -f '$(CHECK_MAKEFILE)' lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)
	@$(MAKE) --no-print-directory -f '$(CHECK_MAKEFILE)' check-gate-suite

# The repository-wide checks that read files and paths and nothing else, bundled
# so a stage that ran only the axis it changed can still run them: the gate
# suite's four static sections, the static invariants moved out of four large
# suites, and the darwin leg's keepset lint. Each line is a component that must
# fail the target on its own defect, so no line carries a prefix or a `|| true`
# that would swallow it — scripts/test-local-bundle.sh asserts both. Not part of
# `check`: `check-push` runs it once on the committed tree before push.
check-cheap:
	bash scripts/test-gate.sh --sections 0a,0b,0c,0d
	bash scripts/test-meta-invariants.sh
	bash scripts/lint-macos-keepset-paths.sh

# Check the committed HEAD once in a clean clone before push, and stamp its tree
# on a pass; `check-push-verify` answers whether HEAD's tree carries a stamp. In
# an unattended run the clone tests the merge CI tests, with the base taken from
# this worktree's fresh FETCH_HEAD. Variables, all optional:
#   CHECK_PUSH_BASE         base commit to merge with (interactive use)
#   CHECK_PUSH_BASE_BRANCH  branch whose FETCH_HEAD line is the base (master)
#   CHECK_PUSH_SECTIONS     test-gate section ids, comma-separated
#   CHECK_PUSH_GOALS        REST goals (`make -s print-rest-goals`), comma-separated
#   CHECK_PUSH_JOBS         section lanes and goal jobs run at once (default 4;
#                           1 runs them in turn, as before)
# CHECK_PUSH_JOBS reaches check-push.sh the way CHECK_PUSH_SECTIONS does, as a
# command-line variable or from the environment; the recipe stays as it is.
# An unattended run whose head changed plugins/cc-cmds/orchestrator/gate.sh
# against its merge-base with the base is refused with exit 2 before the clone
# when CHECK_PUSH_SECTIONS is empty — goals alone do not cover gate.sh — so the
# tree gets no stamp and check-push-verify stays non-zero; name the sections of
# the axis that changed and run it again. This carries over the refusal `check`
# makes through check-gate-suite.
check-push:
	bash scripts/check-push.sh run

check-push-verify:
	bash scripts/check-push.sh verify

# `check` runs the gate suite, but only when the change touches gate.sh.
# scripts/test-gate.sh is the one suite that catches a broken grading table —
# `make lint` passes a gate.sh that no longer grades `gh pr merge` — and the
# procedure every commit goes through was `lint readme` alone, so a change to
# gate.sh that followed the procedure to the letter had no local step that ever
# ran it. Running it unconditionally would be worse than not running it: the
# full suite takes about three hours serially, and a procedure that costs that
# on every commit is one people skip, which puts back the very state this closes.
# PR CI already runs the suite on the merge ref, so this adds no new duty; it
# runs the same suite earlier, on the machine that made the change.
#
# The comparison is against the merge-base with the base branch and the diff is
# taken against the working tree, so committed, staged and unstaged edits all
# count. A tree with no base to compare against runs the suite rather than
# skipping it — skipping there in silence is the gap this target exists to
# close — and a `git diff` that fails is a failure, never an empty change list.
# The suite path stays a literal default so `make -n check` still shows it.
#
# Without GATE_SUITE_BASE every candidate base that resolves is tried and the
# merge-base closest to HEAD wins. Taking the first candidate that resolves
# picked a stale origin/HEAD over a local master that is ahead of it, so a
# gate.sh change already on local master counted as this branch's change and
# the suite ran for a branch that never touched gate.sh. The branch that is
# checked out is never its own base: on local master, master's merge-base with
# HEAD is HEAD itself, which would hide every gate.sh change committed there
# and skip the suite. An explicit GATE_SUITE_BASE that does not resolve, or no
# candidate left at all, is the no-base case and runs the suite.
#
# The full suite takes about three hours serially — the twenty-six CI shards
# add up to about 280 minutes, more than that because every shard pays its own
# prelude — so it ends within neither the foreground tool limit nor the
# two-hour background one, and the full regression is PR CI's job (twenty-six
# shards, about 11 minutes each on average and the slowest about 16). A change
# whose gate.sh edit crosses only some sections narrows the run with
# GATE_SUITE_CMD='bash scripts/test-gate.sh --sections <id,...>' — the same
# section choice the repository's test rules ask for. Interactively the default
# stays the full suite, and the message before the run says what it costs and
# how to narrow it. An unattended run (CC_PIPELINE_RUN_ID set) refuses the
# default rather than starting it: `check` fails and names the narrowing, and a
# run with no PR leaves the full regression unjudged and says so in the stage
# report. The refusal reads where GATE_SUITE_CMD came from, not what it says, so
# a command passed on the command line runs as given; that is how a person runs
# the whole suite on purpose, not a way out for a stage.
# The refusal is not a skip: nothing passes until a suite command has run.
GATE_SUITE_TRIGGER := plugins/cc-cmds/orchestrator/gate.sh
GATE_SUITE_CMD ?= bash scripts/test-gate.sh
GATE_SUITE_BASE ?=

# The one place that finds the base and decides whether gate.sh changed, shared
# by check-gate-suite and check-unattended-refusal. It runs inside a recipe's
# single shell, so every line ends in `\` and every shell `$` is doubled. It
# leaves `base`, `mb` and `gs_state`: nobase (no base resolved), difffail
# (`git diff` failed), unchanged, or changed.
define GATE_SUITE_PROBE
base='$(GATE_SUITE_BASE)'; mb=; \
if [ -n "$$base" ]; then \
  mb=$$(git merge-base "$$base" HEAD 2>/dev/null) || mb=; \
else \
  cur=$$(git symbolic-ref -q --short HEAD) || cur=; \
  for ref in origin/HEAD origin/master master; do \
    [ "$$ref" != "$$cur" ] || continue; \
    git rev-parse --verify --quiet "$$ref^{commit}" >/dev/null || continue; \
    m=$$(git merge-base "$$ref" HEAD 2>/dev/null) || continue; \
    if [ -z "$$mb" ] || git merge-base --is-ancestor "$$mb" "$$m"; then base=$$ref; mb=$$m; fi; \
  done; \
fi; \
if [ -z "$$mb" ]; then \
  gs_state=nobase; \
elif changed=$$(git diff --name-only "$$mb" -- '$(GATE_SUITE_TRIGGER)'); then \
  if [ -z "$$changed" ]; then gs_state=unchanged; else gs_state=changed; fi; \
else \
  gs_state=difffail; \
fi
endef

GATE_SUITE_REFUSAL := check-gate-suite: 무인 런에서는 기본값 전량을 시작하지 않는다 — 전량은 직렬 약 3시간(CI 26샤드 소요 합 약 280분)이라 백그라운드 도구 상한 2시간 안에도 끝나지 않는다. GATE_SUITE_CMD 를 지명해 바꾼 축의 절만 돌린다: GATE_SUITE_CMD='bash scripts/test-gate.sh --sections <id,...>'. 전량 회귀는 PR CI(26샤드, 샤드당 평균 약 11분, 가장 긴 샤드 약 16분)가 진다 — PR 이 없는 런에서는 미판정으로 남기고 스테이지 보고에 적는다

# The same refusal check-gate-suite makes, decided up front for `check`: an
# unattended run whose GATE_SUITE_CMD came from this file, on a tree where the
# suite would run (no base, or gate.sh changed). A failing `git diff` passes
# here and is left to check-gate-suite, which ends on it with 1 as before.
check-unattended-refusal:
	@if [ -n "$${CC_PIPELINE_RUN_ID:-}" ] && [ '$(origin GATE_SUITE_CMD)' = file ]; then \
	  $(GATE_SUITE_PROBE); \
	  case "$$gs_state" in \
	    nobase|changed) echo "$(GATE_SUITE_REFUSAL)" >&2; exit 1 ;; \
	  esac; \
	fi

check-gate-suite:
	@run_suite() { \
	  if [ -n "$${CC_PIPELINE_RUN_ID:-}" ] && [ '$(origin GATE_SUITE_CMD)' = file ]; then \
	    echo "$(GATE_SUITE_REFUSAL)" >&2; \
	    return 1; \
	  fi; \
	  $(GATE_SUITE_CMD); \
	}; \
	$(GATE_SUITE_PROBE); \
	if [ "$$gs_state" = nobase ]; then \
	  echo "check-gate-suite: 비교할 베이스를 해소하지 못해 게이트 스위트를 돌린다 (base='$$base')"; \
	  run_suite; exit $$?; \
	fi; \
	if [ "$$gs_state" = difffail ]; then \
	  echo "check-gate-suite: git diff 가 실패해 $(GATE_SUITE_TRIGGER) 의 변경 여부를 판정할 수 없다" >&2; exit 1; \
	fi; \
	if [ "$$gs_state" = unchanged ]; then \
	  echo "check-gate-suite: $(GATE_SUITE_TRIGGER) 가 $$base 대비 바뀌지 않아 게이트 스위트를 건너뛴다"; \
	  exit 0; \
	fi; \
	echo "check-gate-suite: $(GATE_SUITE_TRIGGER) 가 $$base 대비 바뀌어 게이트 스위트를 돌린다"; \
	echo "check-gate-suite: 전량은 직렬 약 3시간(CI 26샤드 소요 합 약 280분)이라 포그라운드 도구 상한도, 백그라운드 도구 상한 2시간도 넘는다 — 바꾼 축의 절만 돌리려면 GATE_SUITE_CMD='bash scripts/test-gate.sh --sections <id,...>' 로 좁힌다 (전량 회귀는 PR CI 가 26샤드로 진다)"; \
	run_suite

# Whether check-gate-suite decides anything. `make -n check | grep test-gate`
# passes just as well for a condition that is always false, so this runs the
# target in a scratch repository and watches whether the suite command actually
# ran: not when only another file changed, yes when gate.sh changed on the
# branch, yes when it changed only in the working tree, and a failing suite
# fails make. The first two are each other's control — either one alone passes
# an implementation that always runs the suite or one that never does. The base
# is left to the default resolution so the `master` fallback is what runs. The
# fifth case checks the no-base path: an unchanged tree skips with the default
# base and runs once GATE_SUITE_BASE names a ref that does not resolve. The
# sixth keeps origin/master behind a local master that already carries a
# gate.sh change: the closer base must win and the suite must not run. The
# seventh is the same commit with local master checked out: master is not its
# own base, so the committed change counts and the suite runs — F and G are each
# other's control. The eighth is a pair under CC_PIPELINE_RUN_ID: the default
# command is refused with a message naming GATE_SUITE_CMD and the --sections
# narrowing, offering no full command beside it and no forty-minute figure, and
# a named command runs. The ninth is a pair on `check` itself under the same
# variable: with the default command `check` fails on the refusal before lint
# prints a line, and with a named command it goes on to lint. The scratch
# repository has none of the files lint reads, so lint fails there and the exit
# code alone cannot tell the early refusal from a lint failure — what tells
# them apart is whether lint's first recipe line is in the output.
# The make binary is taken through a second variable on purpose: a recipe line
# that names $(MAKE) directly is executed even under `make -n`.
CHECK_GATE_SELFTEST_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
CHECK_GATE_SELFTEST_MAKE := $(MAKE)

run-check-gate-selftest:
	@unset MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GATE_SUITE_BASE GATE_SUITE_CMD CC_PIPELINE_RUN_ID; \
	t=$$(mktemp -d) || exit 1; trap 'rm -rf "$$t"' EXIT; \
	r=$$t/repo; mk='$(CHECK_GATE_SELFTEST_MAKEFILE)'; trig='$(GATE_SUITE_TRIGGER)'; \
	fail() { echo "run-check-gate-selftest: $$*" >&2; exit 1; }; \
	gc() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$$@"; }; \
	suite() { rm -f "$$t/ran"; c=$$1; shift; '$(CHECK_GATE_SELFTEST_MAKE)' --no-print-directory -f "$$mk" check-gate-suite GATE_SUITE_CMD="$$c" "$$@" >"$$t/out" 2>&1; }; \
	mkdir -p "$$r/$${trig%/*}" && cd "$$r" && gc init -q -b master . \
	  && echo a > "$$trig" && echo a > other && gc add -A && gc commit -qm base \
	  && gc checkout -q -b only-other || fail "임시 저장소를 만들지 못했다"; \
	echo b > other && gc commit -qam other || fail "경우 A 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 A: make 가 실패했다: $$(cat "$$t/out")"; \
	[ ! -e "$$t/ran" ] || fail "경우 A: gate.sh 를 건드리지 않은 변경에서 스위트가 돌았다"; \
	echo b > "$$trig" && gc commit -qam gate || fail "경우 B 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 B: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 B: 브랜치에서 커밋한 gate.sh 변경에 스위트가 돌지 않았다"; \
	gc checkout -q master && gc checkout -q -b worktree-only && echo c > "$$trig" || fail "경우 C 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 C: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 C: 작업 트리에만 있는 gate.sh 변경에 스위트가 돌지 않았다"; \
	if suite false; then fail "경우 D: 스위트가 실패했는데 make 가 성공했다"; fi; \
	gc checkout -q -f master && gc checkout -q -b no-base || fail "경우 E 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 E: make 가 실패했다: $$(cat "$$t/out")"; \
	[ ! -e "$$t/ran" ] || fail "경우 E: 바뀌지 않은 트리에서 기본 베이스로 스위트가 돌았다"; \
	suite "touch '$$t/ran'" GATE_SUITE_BASE=no-such-ref || fail "경우 E: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 E: 베이스를 해소하지 못했는데 스위트가 돌지 않았다"; \
	gc checkout -q master && echo d > "$$trig" && gc commit -qam master-gate \
	  && gc update-ref refs/remotes/origin/master HEAD~1 && gc checkout -q -b after-master || fail "경우 F 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 F: make 가 실패했다: $$(cat "$$t/out")"; \
	[ ! -e "$$t/ran" ] || fail "경우 F: 로컬 master 에 이미 있는 gate.sh 변경을 낡은 origin/master 대비로 세어 스위트가 돌았다"; \
	gc checkout -q master || fail "경우 G 를 준비하지 못했다"; \
	suite "touch '$$t/ran'" || fail "경우 G: make 가 실패했다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 G: 로컬 master 에서 커밋된 gate.sh 변경에 스위트가 돌지 않았다"; \
	( export CC_PIPELINE_RUN_ID=selftest; rm -f "$$t/ran"; \
	  '$(CHECK_GATE_SELFTEST_MAKE)' --no-print-directory -f "$$mk" check-gate-suite >"$$t/out" 2>&1 ) \
	  && fail "경우 H: 무인 런이 기본 전량 스위트를 거절하지 않았다: $$(cat "$$t/out")"; \
	grep -q 'GATE_SUITE_CMD 를 지명' "$$t/out" || fail "경우 H: 거절이 아닌 이유로 실패했다: $$(cat "$$t/out")"; \
	grep -qF -- '--sections' "$$t/out" || fail "경우 H: 거절이 --sections 로 좁히는 법을 적지 않는다: $$(cat "$$t/out")"; \
	if grep -qF "GATE_SUITE_CMD='bash scripts/test-gate.sh'" "$$t/out"; then fail "경우 H: 거절이 절 인자 없는 전량 명령을 선택지로 내민다: $$(cat "$$t/out")"; fi; \
	if grep -qF '40분' "$$t/out"; then fail "경우 H: 거절이 전량 소요를 40분으로 적는다: $$(cat "$$t/out")"; fi; \
	( export CC_PIPELINE_RUN_ID=selftest; suite "touch '$$t/ran'" ) || fail "경우 H: 지명한 스위트 명령이 무인 런에서 거절됐다: $$(cat "$$t/out")"; \
	[ -e "$$t/ran" ] || fail "경우 H: 무인 런에서 지명한 스위트 명령이 돌지 않았다"; \
	( export CC_PIPELINE_RUN_ID=selftest; \
	  '$(CHECK_GATE_SELFTEST_MAKE)' --no-print-directory -f "$$mk" check >"$$t/out" 2>&1 ) \
	  && fail "경우 I: 무인 런의 check 가 기본 전량을 거절하지 않았다: $$(cat "$$t/out")"; \
	grep -q 'GATE_SUITE_CMD 를 지명' "$$t/out" || fail "경우 I: check 가 거절 문면 없이 끝났다: $$(cat "$$t/out")"; \
	if grep -qF 'lint-skill-invariants' "$$t/out"; then fail "경우 I: 거절보다 lint 가 먼저 돌았다: $$(cat "$$t/out")"; fi; \
	( export CC_PIPELINE_RUN_ID=selftest; \
	  '$(CHECK_GATE_SELFTEST_MAKE)' --no-print-directory -f "$$mk" check GATE_SUITE_CMD="touch '$$t/ran'" >"$$t/out" 2>&1 ); \
	grep -qF 'lint-skill-invariants' "$$t/out" || fail "경우 I: 스위트 명령을 지명한 check 가 lint 까지 가지 않았다: $$(cat "$$t/out")"; \
	if grep -q 'GATE_SUITE_CMD 를 지명' "$$t/out"; then fail "경우 I: 스위트 명령을 지명했는데 거절했다: $$(cat "$$t/out")"; fi; \
	echo "run-check-gate-selftest: 아홉 경우 통과"

# What the next run's stages will read as `# Personal rules`: the counts and
# bytes per tag of the user-scope CLAUDE.md, its untagged and malformed bullets,
# the host map and the next steps. Deliberately NOT part of `lint` — the source
# is a person's global file, and editing it must not turn an unrelated
# unattended stage's `make check` red. Run by hand and at autopilot kickoff.
policy-drift:
	@bash plugins/cc-cmds/orchestrator/stage-rules.sh status

# Which rules of the user-scope CLAUDE.md a means enforces, by its enforcement
# markers: one row per rule with its verdict, then the prose-only rules, the
# partial gaps and the dead means. Deliberately NOT part of `lint` or `check`
# for the same reason as `policy-drift` — the source is a person's global file.
# Run by hand.
rule-enforcement:
	@bash plugins/cc-cmds/orchestrator/stage-rules.sh enforcement

# Each suite is a LIST of scripts rather than a block of recipe lines, so that
# the scripts become prerequisites and `make -j` can run them at once. As recipe
# lines they were strictly serial no matter what -j said, and that is the whole
# of the suite's wall clock: measured on this repository, the twenty-three
# smallest scripts together account for thirty-five seconds of a run whose
# length the large ones set, the gate suite alone taking about three hours.
# Serially every one of them waits behind the two large ones for nothing.
#
# Concurrency is safe without further isolation and the tests already say so:
# every one of them builds its own workspace with `mktemp -d`, the single
# script that runs `git worktree add` does it inside that workspace, and the
# notification lifecycle test overrides TMPDIR so its flag cannot collide with
# a real one. Nothing here writes into the checkout.
NOTIFY_TESTS := \
	scripts/test-active-notify-lifecycle.sh \
	scripts/test-active-notify-pretool-hook.sh \
	scripts/test-active-notify-dismiss.sh

LINT_TESTS := \
	scripts/test-lint-skill-options.sh \
	scripts/test-lint-skill-invariants.sh \
	scripts/test-lint-skill-paths.sh \
	scripts/test-lint-bash-portability.sh \
	scripts/test-lint-test-clock.sh \
	scripts/test-tz-pin.sh \
	scripts/test-lint-skill-auq-spec.sh \
	scripts/test-lint-verification-literals.sh \
	scripts/test-lint-design-audit-pins.sh \
	scripts/test-lint-team-budget-pins.sh \
	scripts/test-lint-team-model-tier-pins.sh \
	scripts/test-lint-unattended-surfaces.sh \
	scripts/test-lint-lead-read-set.sh \
	scripts/test-lint-cutpoint-vocabulary.sh \
	scripts/test-lint-autoadopt-vocabulary.sh \
	scripts/test-lint-ledger-row-length.sh \
	scripts/test-lint-ledger-provenance.sh \
	scripts/test-lint-judgment-grade.sh \
	scripts/test-lint-notify-env-name.sh \
	scripts/test-lint-notify-title-render.sh \
	scripts/test-lint-notify-fire-sites.sh \
	scripts/test-lint-watch-threshold-pins.sh \
	scripts/test-lint-pace-threshold-pins.sh \
	scripts/test-lint-statusline-token-arms.sh \
	scripts/test-lint-statusline-wrapper-pins.sh \
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
	scripts/test-measure-lead-context.sh \
	scripts/test-measure-test-share.sh \
	scripts/test-measure-discussion-passes.sh \
	scripts/test-solo-audit-experiment.sh \
	scripts/test-reader-model-compare.sh \
	scripts/test-reader-model-pair-audit.sh \
	scripts/test-measure-audit-findings.sh \
	scripts/test-generate-readme.sh \
	scripts/test-readme-gen-parity.sh \
	scripts/test-lint-stage-policy-sources.sh \
	scripts/test-lint-terminal-literals.sh \
	scripts/test-lint-interview-record-sections.sh \
	scripts/test-lint-interview-convention-refs.sh \
	scripts/test-lint-kickoff-defaults.sh

ORCH_TESTS := \
	plugins/cc-cmds/orchestrator/test-run.sh \
	scripts/test-gate.sh \
	scripts/test-suite-isolation.sh \
	scripts/test-kickoff-defaults.sh \
	scripts/test-kickoff-hook-probe.sh \
	scripts/test-rekick.sh \
	scripts/test-team-witness-init.sh \
	scripts/test-similar-items.sh \
	scripts/test-base-split.sh \
	scripts/test-gate-chain-equiv.sh \
	scripts/test-measure-gate-cost.sh \
	scripts/test-snapshot.sh \
	scripts/test-orchestrator-pretool-hook.sh \
	scripts/test-session-notify-hook.sh \
	scripts/test-session-permission-notify.sh \
	scripts/test-session-title-hook.sh \
	scripts/test-notify-focus.sh \
	scripts/test-attention.sh \
	scripts/test-stage-rules-edit-hook.sh \
	scripts/test-stage-rules.sh \
	scripts/test-watch.sh \
	scripts/test-fleet.sh \
	scripts/test-statusline.sh \
	scripts/test-statusline-hook.sh \
	scripts/test-liveness-agreement.sh \
	scripts/test-dashboard.sh \
	scripts/test-run-pane.sh \
	scripts/test-display-tz.sh \
	scripts/test-run-stops.sh \
	scripts/test-lost-dispatch.sh \
	scripts/test-stage-supervisor.sh \
	scripts/test-design-brief.sh \
	scripts/test-route.sh \
	scripts/test-collect-run-metrics.sh \
	scripts/test-design-path-report.sh \
	scripts/test-measure-cycle-causes.sh \
	scripts/test-run-issue-filing.sh \
	scripts/test-visual-config.sh \
	scripts/test-visual-check.sh \
	scripts/test-visual-capture.sh \
	scripts/test-meta-invariants.sh \
	scripts/test-local-bundle.sh \
	scripts/test-ci-signature.sh

DARWIN_TESTS := \
	scripts/test-notify-title-oracle.sh \
	scripts/test-suite-guard.sh \
	scripts/test-notify-focus-ax.sh

ALL_TESTS := $(NOTIFY_TESTS) $(LINT_TESTS) $(ORCH_TESTS) $(DARWIN_TESTS)
TEST_GOALS := $(ALL_TESTS:%=run/%)

.PHONY: $(TEST_GOALS)

# Every suite runs under scripts/suite-guard.sh, which reaps what the suite
# leaves behind once it ends. Under `make -jN` a leftover descendant keeps
# make's jobserver pipe open and make does not return while it lives; the
# wrapper's header says how it decides what is the suite's.
$(TEST_GOALS): run/%:
	bash scripts/suite-guard.sh $*

test: $(NOTIFY_TESTS:%=run/%) $(LINT_TESTS:%=run/%) $(ORCH_TESTS:%=run/%) \
	run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest \
	run-rest-shard-selftest run-check-push-selftest run-test-tree-selftest \
	run-gate-timing-selftest run-ci-duration-selftest run-gate-isolation-selftest

# How many runners the gate suite runs on (N), and how many rows each runner
# runs at once (L, its lanes). The partition is cut into S = N × L rows; runner
# k runs rows k, k + N, … at once. CI reads all three so the matrix, the
# per-runner dispatch and the union check take their numbers from one place; a
# workflow that spelled a number itself would let the matrix and the check
# disagree, and the sections in the gap would belong to nobody.
#
# S IS THE NUMBER OF ROWS AND N THE NUMBER OF JOBS. S goes to the partition
# table (CI's plan job), the union check and the row ids `gate-shard` asks the
# partitioner for, and to the census. N goes to the matrix and its number check
# and is the SHARD a `gate-shard` call takes.
GATE_SHARDS ?= 26
GATE_LANES ?= 1
GATE_SLOTS := $(shell echo $$(( $(GATE_SHARDS) * $(GATE_LANES) )))

# The isolation check of the sections a pull request changed rides on the rows
# above and, when their room runs out, on extra rows S+1..S+E, one runner each.
# GATE_ISO_EXTRA is the most CI's plan job may open; GATE_EXTRA is how many the
# table a runner was handed actually has, which only the plan job knows.
GATE_ISO_EXTRA ?= 8
GATE_EXTRA ?= 0

# So CI can read the numbers instead of spelling them a second time.
print-gate-iso-extra:
	@echo $(GATE_ISO_EXTRA)

print-gate-shards:
	@echo $(GATE_SHARDS)

print-gate-lanes:
	@echo $(GATE_LANES)

print-gate-slots:
	@echo $(GATE_SLOTS)

# The gate suite's section list, for CI's timing merge. It goes through make so
# that make stays the one entry point to the suites and its pinned zone applies.
print-gate-sections:
	@bash scripts/test-gate.sh --list < /dev/null

# The section digests, for CI's changed-section plan, through make for the same
# reason. GATE_DIGESTS_FROM names another copy of the suite (the base's) to read
# with this one's selector; empty reads this suite.
GATE_DIGESTS_FROM ?=
print-gate-digests:
	@bash scripts/test-gate.sh --digests $(if $(GATE_DIGESTS_FROM),--from '$(GATE_DIGESTS_FROM)') < /dev/null

# The zone a recipe actually receives, and the offset it resolves to. The
# offset is printed beside the name because glibc falls back to UTC in silence
# when it cannot find the zone data, and the name alone would still read right.
print-test-tz:
	@echo "$$TZ $$(date +%z)"

# Runs one script under the pinned zone. scripts/test-tz-pin.sh uses it to show
# that a fixture which mistakes local time for UTC fails through make.
TZ_PROBE ?=

tz-probe:
	bash $(TZ_PROBE)

# `test` minus the gate suite. CI runs this in the always-on leg because the
# gate suite runs sharded in its own workflow, and running it in both places
# would put back the three serial hours that the sharding removes. Locally `test`
# is still the whole thing.
ORCH_TESTS_REST := $(filter-out scripts/test-gate.sh,$(ORCH_TESTS))

REST_GOALS := $(NOTIFY_TESTS:%=run/%) $(LINT_TESTS:%=run/%) $(ORCH_TESTS_REST:%=run/%) \
	run-gate-shard-selftest run-gate-census-selftest run-check-gate-selftest \
	run-rest-shard-selftest run-check-push-selftest run-test-tree-selftest \
	run-gate-timing-selftest run-ci-duration-selftest run-gate-isolation-selftest

test-rest: $(REST_GOALS)

# How many runners `test-rest` is cut into in CI. The lint workflow's matrix and
# its union check both take N from here, as the gate shards take GATE_SHARDS.
REST_SHARDS ?= 3

print-rest-shards:
	@echo $(REST_SHARDS)

# The goal list the partitioner cuts, one per line. It is REST_GOALS itself, so
# a suite added to `test-rest` is in some shard without anyone naming it.
print-rest-goals:
	@printf '%s\n' $(REST_GOALS)

# One shard of `test-rest`. SHARD is 1-based. The goals come from the
# partitioner heaviest first and go to a sub-make on its command line, which
# starts them in that order, as many at once as the outer -j allows: `$(MAKE)`
# on the same recipe line is what hands the sub-make the outer jobserver. An
# empty assignment is a success, as it is for gate-shard.
#
# EACH SUITE'S OUTPUT REACHES THE LOG WHOLE. The sub-make holds every goal's
# output, make's echo of the command and the goal's stderr included, and writes
# it out in one piece when the goal ends, so no line of one suite falls between
# the start and end lines of another. ci-signature.sh pins a FAIL line on a
# suite only while that suite alone is open, and without this every failed
# rest-tests job read at step precision. `2>&1` puts the suite's stderr, where
# suite-guard prints its end line, in the same held output as its stdout. A make
# older than 4.0 has no output sync and runs the goals as before; their lines
# then interleave and the adapter reads the job at step precision. An unwrapped
# self-test goal's lines come out held the same way but outside every suite,
# so a FAIL line of one, or its failure, leaves the job at step precision. The
# adapter sees such a goal start by make's echo of `bash scripts/<x>.sh
# --self-test`, or, for `run-check-gate-selftest`, whose recipe make does not
# echo, by its own `run-check-gate-selftest: ` line.
#
# EVERY GOAL OF THE SHARD STARTS. The sub-make runs with `-k`, so a suite that
# fails does not stop it from starting the goals still waiting. Without it make
# starts nothing after the first failure, the goals listed on the `rest shard`
# line that never started leave no line, and the adapter reads the job at step
# precision, which was the case for a failure that ended before the shard's last
# goal started. The job still fails, and its wall clock is still set by the
# heaviest goal.
REST_OUTPUT_SYNC := $(if $(filter output-sync,$(.FEATURES)),--output-sync=target)

rest-shard:
	@goals=$$(bash scripts/rest-shard.sh --shards $(REST_SHARDS) --shard $(SHARD)); rc=$$?; \
	if [ "$$rc" = "4" ]; then echo "rest shard $(SHARD)/$(REST_SHARDS): 배정된 목표가 없습니다"; exit 0; fi; \
	[ "$$rc" = "0" ] || exit "$$rc"; \
	echo "rest shard $(SHARD)/$(REST_SHARDS): $$goals"; \
	$(MAKE) -k --no-print-directory $(REST_OUTPUT_SYNC) $$goals 2>&1

# One runner of the gate suite. SHARD is the runner, 1-based (1..N); lane j
# (0..L−1) runs row K = SHARD + j × N of the S-row partition, and the lanes run
# at once. An empty row is a success and not a failure — the partitioner exits
# 4 when the requested row drew nothing — and ends that lane alone.
#
# CI hands every runner the one table its plan job made (GATE_TABLE), so no
# runner partitions on its own. Without a table each lane partitions here,
# weighed with the measured times in GATE_TIMING when that file exists and with
# the census model when it does not.
#
# A LANE IS ISOLATED AND JUDGED ON ITS OWN. GATE_OUT_DIR, an absolute path,
# receives per row K: `timing-<K>.tsv` (the section markers: `@start` and
# `@end` around the row from here, and the selector's own line in front of each
# section, prelude and the epilogue), `lane-<K>.out` (the suite's output) and
# `result-<K>.tsv` (`<K><TAB><exit code><TAB><summary>`, the summary being the
# suite's total line, `빈 행` for an empty row, `격리 전용 행` for a row that
# carries isolation work only, or `-`). Each lane's TMPDIR is
# its own `lane-<K>` directory there. A lane fails on a non-zero exit code and
# on a missing total line alike — a suite that died before its total never ran
# its tail — and the runner fails when any lane did. The outputs reach the log
# whole and in row order once every lane has ended, so no line of one lane is
# cut by a line of the other. Without GATE_OUT_DIR the lanes write to a
# temporary directory removed afterwards.
#
# ONE LANE WITHOUT AN OUTPUT DIRECTORY IS THE PLAIN SHARD. With GATE_LANES=1
# and no GATE_OUT_DIR the suite runs in the foreground with its own output, and
# GATE_TIMING_OUT, an absolute path, asks for the same markers as above.
#
# A ROW OF A TABLE WITH ISOLATION WORK runs it in the same lane. The sections
# laid over the row join its cut, traced, with their markers under `@iso:`, and
# the row's own changed sections are traced too; that cut's record goes to
# `iso-<K>/row`. After `@end` the row's solos run, each a process of its own
# (`scripts/gate-isolation.sh solos`), into `iso-<K>/solo<n>-<id>`. A solo's
# exit code is the comparison's to judge, not the row's. An extra row (SHARD
# S+1..S+E, one runner, no lanes) has no third column: it runs its solos only
# and its result is `격리 전용 행`.
GATE_TIMING ?= scripts/gate-timing.tsv
GATE_TABLE ?=
GATE_TIMING_OUT ?=
GATE_OUT_DIR ?=

gate-shard:
	@pick() { \
	  if [ -n '$(GATE_TABLE)' ]; then \
	    bash scripts/gate-shard.sh --shards $(GATE_SLOTS) --extra $(GATE_EXTRA) --shard "$$@" --from-table '$(GATE_TABLE)'; \
	  else \
	    bash scripts/gate-shard.sh --shards $(GATE_SLOTS) --timing '$(GATE_TIMING)' --shard "$$1"; \
	  fi; }; \
	case '$(SHARD)' in ''|*[!0-9]*|0) echo "gate-shard: SHARD 는 1..$(GATE_SHARDS) 의 러너 번호입니다: '$(SHARD)'" >&2; exit 2 ;; esac; \
	extra=0; \
	if [ '$(SHARD)' -gt '$(GATE_SHARDS)' ]; then \
	  if [ '$(SHARD)' -le '$(GATE_SLOTS)' ] || [ '$(SHARD)' -gt "$$(( $(GATE_SLOTS) + $(GATE_EXTRA) ))" ]; then \
	    echo "gate-shard: SHARD $(SHARD) 가 러너 수 $(GATE_SHARDS) 를 넘고 추가 행 $$(( $(GATE_SLOTS) + 1 ))..$$(( $(GATE_SLOTS) + $(GATE_EXTRA) )) 도 아닙니다" >&2; exit 2; \
	  fi; \
	  [ -n '$(GATE_TABLE)' ] && [ -n '$(GATE_OUT_DIR)' ] || { echo "gate-shard: 추가 행 $(SHARD) 는 GATE_TABLE 과 GATE_OUT_DIR 로만 돕니다" >&2; exit 2; }; \
	  extra=1; \
	fi; \
	if [ '$(GATE_LANES)' = 1 ] && [ -z '$(GATE_OUT_DIR)' ]; then \
	  out='$(GATE_TIMING_OUT)'; \
	  mark() { [ -z "$$out" ] || printf '%s\t%s\n' "$$1" "$$(date +%s)" >> "$$out"; }; \
	  mark @start; \
	  ids=$$(pick '$(SHARD)'); rc=$$?; \
	  if [ "$$rc" = "4" ]; then echo "shard $(SHARD)/$(GATE_SLOTS): 배정된 절이 없습니다"; mark @end; exit 0; fi; \
	  [ "$$rc" = "0" ] || exit "$$rc"; \
	  if [ -z "$$ids" ]; then echo "shard $(SHARD)/$(GATE_SLOTS): 격리 작업만 실린 행입니다 — GATE_OUT_DIR 없이는 돌리지 않습니다"; mark @end; exit 0; fi; \
	  rc=0; CC_GATE_TIMING_OUT="$$out" bash scripts/test-gate.sh --sections "$$ids" || rc=$$?; \
	  mark @end; exit "$$rc"; \
	fi; \
	od='$(GATE_OUT_DIR)'; tmpod=; \
	if [ -z "$$od" ]; then od=$$(mktemp -d "$${TMPDIR:-/tmp}/gate-lanes.XXXXXX") || exit 1; tmpod=$$od; fi; \
	mkdir -p "$$od" || exit 1; \
	lane() { \
	  k=$$1; tm="$$od/timing-$$k.tsv"; lo="$$od/lane-$$k.out"; res="$$od/result-$$k.tsv"; \
	  printf '@start\t%s\n' "$$(date +%s)" >> "$$tm"; \
	  ids=$$(pick "$$k" 2>"$$lo"); rc=$$?; \
	  if [ "$$rc" = "4" ]; then \
	    echo "row $$k/$(GATE_SLOTS): 배정된 절이 없습니다" >> "$$lo"; \
	    printf '@end\t%s\n' "$$(date +%s)" >> "$$tm"; printf '%s\t0\t빈 행\n' "$$k" > "$$res"; return 0; \
	  fi; \
	  if [ "$$rc" != "0" ]; then printf '%s\t%s\t-\n' "$$k" "$$rc" > "$$res"; return "$$rc"; fi; \
	  ov=; so=; own=; \
	  if [ -n '$(GATE_TABLE)' ]; then \
	    ov=$$(pick "$$k" --overlay 2>>"$$lo") && so=$$(pick "$$k" --solo 2>>"$$lo") && own=$$(pick "$$k" --own 2>>"$$lo") \
	      || { printf '%s\t2\t-\n' "$$k" > "$$res"; return 2; }; \
	  fi; \
	  mkdir -p "$$od/lane-$$k"; \
	  rc=0; \
	  if [ -z "$$ids" ]; then \
	    echo "row $$k/$(GATE_SLOTS): 격리 작업만 실린 행입니다" >> "$$lo"; \
	    printf '@end\t%s\n' "$$(date +%s)" >> "$$tm"; tot='격리 전용 행'; \
	  elif [ -n "$$ov$$own" ]; then \
	    TMPDIR="$$od/lane-$$k" CC_GATE_TIMING_OUT="$$tm" CC_GATE_ISO_OUT="$$od/iso-$$k/row" \
	      CC_GATE_ISO_TRACE="$$ov$${ov:+$${own:+,}}$$own" CC_GATE_ISO_OVERLAY="$$ov" \
	      bash scripts/test-gate.sh --sections "$$ids$${ov:+,$$ov}" >> "$$lo" 2>&1 || rc=$$?; \
	    printf '@end\t%s\n' "$$(date +%s)" >> "$$tm"; \
	    tot=$$(grep -E '^test-gate: [0-9]+ passed, [0-9]+ failed$$' "$$lo" | tail -n 1); \
	  else \
	    TMPDIR="$$od/lane-$$k" CC_GATE_TIMING_OUT="$$tm" bash scripts/test-gate.sh --sections "$$ids" >> "$$lo" 2>&1 || rc=$$?; \
	    printf '@end\t%s\n' "$$(date +%s)" >> "$$tm"; \
	    tot=$$(grep -E '^test-gate: [0-9]+ passed, [0-9]+ failed$$' "$$lo" | tail -n 1); \
	  fi; \
	  printf '%s\t%s\t%s\n' "$$k" "$$rc" "$${tot:--}" > "$$res"; \
	  if [ -n "$$so" ]; then \
	    echo "row $$k/$(GATE_SLOTS): 단독 $$(printf '%s' "$$so" | tr ';' '\n' | grep -c .)개 — 기록은 iso-$$k" >> "$$lo"; \
	    bash scripts/gate-isolation.sh solos --out "$$od/iso-$$k" --spec "$$so" --timing-out "$$tm" --tmp "$$od/lane-$$k" >> "$$lo" 2>&1 \
	      || echo "row $$k/$(GATE_SLOTS): 단독을 돌리지 못했습니다 — 비교에서 맥락 없음으로 드러납니다" >> "$$lo"; \
	  fi; \
	  return "$$rc"; }; \
	rows=; pids=; j=0; \
	if [ "$$extra" = 1 ]; then \
	  rows=' $(SHARD)'; lane '$(SHARD)' & pids=" $$!"; \
	else \
	  while [ "$$j" -lt '$(GATE_LANES)' ]; do \
	    k=$$(( $(SHARD) + j * $(GATE_SHARDS) )); rows="$$rows $$k"; \
	    lane "$$k" & pids="$$pids $$!"; j=$$((j + 1)); \
	  done; \
	fi; \
	set -- $$pids; rcs=; \
	for k in $$rows; do rc=0; wait "$$1" || rc=$$?; shift; rcs="$$rcs $$k:$$rc"; done; \
	bad=0; \
	for k in $$rows; do \
	  echo "=== gate row $$k/$(GATE_SLOTS) (runner $(SHARD), lanes $(GATE_LANES)) ==="; \
	  cat "$$od/lane-$$k.out" 2>/dev/null; \
	done; \
	for kr in $$rcs; do \
	  k=$${kr%%:*}; rc=$${kr#*:}; \
	  sum=$$(cut -f3 "$$od/result-$$k.tsv" 2>/dev/null); \
	  if [ "$$rc" != "0" ]; then echo "gate-shard: 행 $$k 의 레인이 종료 코드 $$rc 로 끝났습니다" >&2; bad=1; fi; \
	  case "$$sum" in \
	    '빈 행'|'격리 전용 행') ;; \
	    'test-gate: '*) ;; \
	    *) echo "gate-shard: 행 $$k 의 레인 출력에 합계 줄(test-gate: <n> passed, <n> failed)이 없습니다" >&2; bad=1 ;; \
	  esac; \
	done; \
	[ -z "$$tmpod" ] || rm -rf "$$tmpod"; \
	exit "$$bad"

# The partitioner, the census and the timing and duration scripts are driven by
# flags, so they cannot sit in the argument-less `bash <script>` lists above;
# their self-tests run no suite and take seconds.
run-gate-shard-selftest:
	bash scripts/gate-shard.sh --self-test

run-gate-timing-selftest:
	bash scripts/gate-timing.sh --self-test

run-ci-duration-selftest:
	bash scripts/ci-duration.sh --self-test

run-gate-census-selftest:
	bash scripts/gate-census.sh --self-test

run-check-push-selftest:
	bash scripts/check-push.sh --self-test

run-test-tree-selftest:
	bash scripts/test-tree.sh --self-test

run-rest-shard-selftest:
	bash scripts/rest-shard.sh --self-test

# The comparator's cases run on made-up records; the reduced-suite cases cut a
# few made-up sections with the real selector and need a bash that can trace
# (4.1 or newer), and are skipped with a line saying so under an older one.
run-gate-isolation-selftest:
	ISO_BASH='$(ISO_BASH)' bash scripts/gate-isolation.sh --self-test

# The isolation check run by hand, on this machine. Each needs a bash of 4.1 or
# newer in ISO_BASH; sweep and capacity weigh with ISO_TIMING, or with the
# median of the latest master artifacts when it is not given.
#   isolation-check     the solos of each id of ISO_SECTIONS and one cut of
#                       them with ISO_WITH
#   isolation-sweep     every section, resumable in ISO_OUT; runs of
#                       consecutive sections of at most ISO_CHUNK_S seconds
#   isolation-capacity  whether the solos of what changed since BASE fit the
#                       rows CI would have
ISO_BASH ?= bash
ISO_SECTIONS ?=
ISO_WITH ?=
ISO_TIMING ?=
ISO_OUT ?=
ISO_CHUNK_S ?= 5400

isolation-check:
	ISO_BASH='$(ISO_BASH)' bash scripts/gate-isolation.sh check --sections '$(ISO_SECTIONS)' --with '$(ISO_WITH)' $(if $(ISO_OUT),--out '$(ISO_OUT)')

isolation-sweep:
	ISO_BASH='$(ISO_BASH)' ISO_TIMING='$(ISO_TIMING)' ISO_OUT='$(ISO_OUT)' ISO_CHUNK_S='$(ISO_CHUNK_S)' bash scripts/gate-isolation.sh sweep

isolation-capacity:
	ISO_TIMING='$(ISO_TIMING)' bash scripts/gate-isolation.sh capacity --base '$(BASE)' --shards $(GATE_SLOTS) --iso-extra $(GATE_ISO_EXTRA)

# Regenerate scripts/gate-census.tsv. Run by hand, never from `test`: it runs
# every section alone, the whole suite once and every shard once — about an hour
# on an idle machine — and what it writes is a file to review and commit. It is
# given S, the row count of the partition, as its shard count.
census:
	bash scripts/gate-census.sh --shards $(GATE_SLOTS) --out scripts/gate-census.tsv

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
#                                 a path, which ubuntu skips with a note. It
#                                 runs here as its two parts (`--part 1`,
#                                 `--part 2`) side by side: whole, it was one
#                                 suite running alone on the runner's three
#                                 cores for most of the job's wall clock. The
#                                 two parts together run every assertion of the
#                                 whole suite exactly once, so nothing is left
#                                 out of the bash 3.2 run.
#   test-gate-chain-equiv.sh      the enumerated divergences of the frozen
#                                 reference, which classify differently here.
#   test-lint-bash-portability.sh the multibyte-space case.
#   test-liveness-agreement.sh    the Hangul-date fingerprint assertions; the
#                                 ubuntu runner has no ko_KR.UTF-8 locale, so
#                                 there they pass without testing anything.
#   test-notify-title-oracle.sh   the real terminal-notifier's swallowing set.
#   test-suite-guard.sh           Apple make 3.81 waiting for a process that
#                                 holds its jobserver pipe, the CI arming line
#                                 under the real bash 3.2, and macOS `lsof`
#                                 listing the holders of a marker file.
#   test-notify-focus-ax.sh       the click handler's helper, compiled by the
#                                 handler's own build recipe and held to its
#                                 exit-code contract: a real Swift compile and
#                                 a real binding of the AX and CGS symbols,
#                                 neither of which ubuntu has.
#   test-gate.sh, section 18      the advisory-lock arm, which is darwin-only
#                                 for real.
#   test-gate.sh, section 31ai    the transition guard INSIDE that lock. The
#                                 lock tool is yielded on darwin alone, so the
#                                 ubuntu leg takes the unlocked fallback and
#                                 never runs the guard body; section 18 drives
#                                 the lock but passes no transition argument, so
#                                 it skips that body too. 31ai runs a real
#                                 `close`, which is how the guard gets reached.
#   test-gate.sh, section 84      gate_metrics_timed in a detached child under
#                                 Apple make 3.81, which waits for anything
#                                 the call leaves holding its jobserver pipe.
#
# The three active-notify suites print the same assertions on both legs and are
# kept anyway: taking them off does not move the PR's critical path, which the
# ubuntu leg sets. The return-hook suite runs its notifier as a stub, so it
# checks nothing more here than there, and it is the cheapest of the three to
# keep.
#
# Anything added here must also be matched by that workflow's `paths` filter,
# together with every file it sources, and nothing may stay in the filter that
# this list does not run, source or refer to. scripts/lint-macos-keepset-paths.sh
# checks both directions.
DARWIN_GATE_SECTIONS := 18,31ai,84

.PHONY: run-gate-darwin-sections run-test-run-part1 run-test-run-part2

run-gate-darwin-sections:
	bash scripts/suite-guard.sh scripts/test-gate.sh --sections $(DARWIN_GATE_SECTIONS)

run-test-run-part1:
	bash scripts/suite-guard.sh plugins/cc-cmds/orchestrator/test-run.sh --part 1

run-test-run-part2:
	bash scripts/suite-guard.sh plugins/cc-cmds/orchestrator/test-run.sh --part 2

# The heaviest go first, so `make -j` starts them before the short ones; the two
# test-run.sh parts are by far the longest. `$(DARWIN_TESTS)` stays at the end so
# a suite added to it is still run here — make runs a prerequisite named twice
# once.
test-darwin-narrow: run-test-run-part1 run-test-run-part2 \
	test-active-notify \
	run-gate-darwin-sections \
	run/scripts/test-notify-focus-ax.sh \
	run/scripts/test-liveness-agreement.sh \
	run/scripts/test-gate-chain-equiv.sh \
	run/scripts/test-suite-guard.sh \
	run/scripts/test-lint-bash-portability.sh \
	$(DARWIN_TESTS:%=run/%)
