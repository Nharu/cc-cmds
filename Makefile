.PHONY: lint readme check

lint:
	bash scripts/lint-skill-invariants.sh

readme:
	bash scripts/generate-readme.sh

check: lint readme
	@git diff --exit-code README.md || (echo "README.md is stale — run 'make readme' and commit" >&2; exit 1)
