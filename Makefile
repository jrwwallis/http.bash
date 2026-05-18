SHELL   := bash
SCRIPT  := http.bash
PYTEST  := python3 -m pytest
TESTS   := tests/test_get.py tests/test_errors.py tests/test_cli.py \
           tests/test_redirects.py tests/test_https.py

.PHONY: all test test-zsh test-deps lint check clean

all: check

# Run shellcheck then all pytest suites.
check: lint test

lint:
	shellcheck $(SCRIPT)

test:
	$(PYTEST) $(TESTS) -v

test-zsh:
	$(PYTEST) tests/test_zsh_compat.py -v

test-deps:
	$(PYTEST) tests/test_deps.py -v

# Run a single test file: make test-get, make test-cli, etc.
test-%:
	$(PYTEST) tests/test_$*.py -v

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.pyc' -delete 2>/dev/null || true
