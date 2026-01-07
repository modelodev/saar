.PHONY: ci fmt test wrapper e2e-echo

fmt:
	gleam format --check src test

test:
	gleam test

ci:
	$(MAKE) fmt
	$(MAKE) test

wrapper:
	mkdir -p priv
	cc -O2 -Wall -Wextra -o priv/sad_wrapper native/wrapper/sad_wrapper.c

e2e-echo: wrapper
	gleam test
