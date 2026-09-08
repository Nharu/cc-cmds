.PHONY: lint test-darwin prep

lint:
	bash scripts/lint-ci-scope-binding.sh

test-darwin: prep
	bash scripts/suite-a.sh

prep:
	@echo preparing
	bash scripts/suite-b.sh
