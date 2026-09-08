.PHONY: test-darwin test-orchestrator

test-darwin: test-orchestrator
	bash scripts/test-lint-bash-portability.sh
	bash scripts/test-notify-title-oracle.sh

test-orchestrator:
	bash plugins/cc-cmds/orchestrator/test-run.sh
	bash scripts/test-gate.sh
