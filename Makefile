.PHONY: ci fmt test

fmt:
	gleam format --check src test

test:
	gleam test

ci:
	$(MAKE) fmt
	$(MAKE) test
