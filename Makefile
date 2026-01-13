.PHONY: ci fmt test coverage wrapper e2e-echo e2e-transient e2e-continuous docs-limits

fmt:
	gleam format --check src test tools/docs_limits/src tools/docs_limits/test

test:
	gleam test
	(cd tools/docs_limits && gleam test)

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

e2e-continuous: wrapper
	SAD_WRAPPER_FORCE_FALLBACK=1 gleam test

docs-limits:
	(cd tools/docs_limits && gleam run -m sad/docs/limits_md)
