.PHONY: ci fmt test coverage wrapper e2e-echo e2e-transient docs-limits

fmt:
	gleam format --check src test

test:
	gleam test

coverage:
	@if gleam test --help | rg -q -- "--coverage"; then \
		gleam test --coverage; \
	else \
		echo "coverage not supported by gleam test; skipping"; \
	fi

ci:
	$(MAKE) fmt
	$(MAKE) test
	$(MAKE) coverage

wrapper:
	mkdir -p priv
	cc -O2 -Wall -Wextra -o priv/sad_wrapper native/wrapper/sad_wrapper.c

e2e-transient: wrapper
	gleam test

e2e-echo: e2e-transient

docs-limits:
	gleam run -m sad/docs/limits_md
