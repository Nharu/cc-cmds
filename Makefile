.PHONY: lint readme check test

lint:
	bash scripts/lint-skill-invariants.sh
	bash scripts/lint-skill-options.sh
	bash scripts/lint-skill-paths.sh

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
