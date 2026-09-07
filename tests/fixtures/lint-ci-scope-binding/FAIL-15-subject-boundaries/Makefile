.PHONY: lint test-darwin

lint:
	bash scripts/lint-ci-scope-binding.sh

# Three suites rather than one: B1's two branches and B2 report the same rule id,
# so putting them on one target would collapse them into a single expected key
# and either branch would then cover for the other.
test-darwin:
	bash scripts/suite-a.sh
	bash scripts/suite-b.sh
	bash scripts/suite-c.sh
