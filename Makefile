.PHONY: ci fmt test coverage

fmt:
	gleam format --check src test

test:
	gleam test

coverage:
	gleam test --coverage

ci:
	$(MAKE) fmt
	$(MAKE) test
	$(MAKE) coverage
