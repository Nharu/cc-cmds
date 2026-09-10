.PHONY: lint test-darwin

lint:
	bash scripts/lint-ci-scope-binding.sh

# Every recipe line here fails I3, so the execution set derives EMPTY and the run
# aborts. The exit code is the point of this fixture: two I3 violations were
# already printed, so "the comparison could not be carried out" is false of this
# run and exit 2 would throw both of them away.
test-darwin:
	@echo one
	bash scripts/suite-a.sh \
		scripts/suite-b.sh
