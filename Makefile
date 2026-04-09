HELP_DESCRIPTION = "Various utilities for the current project."
JULIA_BIN ?= julia
JULIA_ARGS ?= --threads=6,2 --optimize=0
CLEAN_DIRS ?= tmp/ test/tmp/
JULIA_TEST_FAILFAST ?= true
JULIA_TEST_VERBOSE ?= true

.PHONY: all
all: help

-include Makefile.local

.PHONY: repl
repl: # Start Julia REPL in the current project
	JULIA_PKG_PRECOMPILE_AUTO=0 $(JULIA_BIN) $(JULIA_ARGS) --project=.

.PHONY: test
test: # Run tests
	@echo "Testing..."
	JULIA_TEST_FAILFAST=$(JULIA_TEST_FAILFAST) \
		JULIA_TEST_VERBOSE=$(JULIA_TEST_VERBOSE) \
		$(JULIA_BIN) $(JULIA_ARGS) --compile=min --startup-file=no --project=. \
		-e 'import Pkg; Pkg.test()'

.PHONY: clean
clean: # Clean project artifacts
	$(foreach path,$(CLEAN_DIRS), \
		rm -rf $(path); \
	)

.PHONY: format
format: # Format all Julia files in the current directory
	$(JULIA_BIN) $(JULIA_ARGS) --project=dev -e 'using JuliaFormatter; format(".")'

.PHONY: pre-commit-install
pre-commit-install: # Install pre-commit hooks
	cp dev/scripts/pre-commit-hook.jl .git/hooks/pre-commit

.PHONY: pre-commit-uninstall
pre-commit-uninstall: # Uninstall pre-commit hooks
	rm .git/hooks/pre-commit

.PHONY: bump-major
bump-major: # Increment project MAJOR version
	$(JULIA_BIN) $(JULIA_ARGS) dev/scripts/bumpversion.jl Project.toml --major

.PHONY: bump-minor
bump-minor: # Increment project MINOR version
	$(JULIA_BIN) $(JULIA_ARGS) dev/scripts/bumpversion.jl Project.toml --minor

.PHONY: bump-patch
bump-patch: # Increment project PATCH version
	$(JULIA_BIN) $(JULIA_ARGS) dev/scripts/bumpversion.jl Project.toml --patch

.PHONY: bump-prerelease
bump-prerelease: # Increment project PRERELEASE version
	$(JULIA_BIN) $(JULIA_ARGS) dev/scripts/bumpversion.jl Project.toml --prerelease

.PHONY: init-dev
init-dev: # Initialize dev environment
	$(JULIA_BIN) $(JULIA_ARGS) --project=dev -e 'import Pkg; Pkg.instantiate()'

.PHONY: reset-dev
reset-dev: # Reset dev environment
	$(JULIA_BIN) $(JULIA_ARGS) --project=dev \
	-e 'rm("dev/Manifest.toml"; force=true); import Pkg; Pkg.instantiate()'

.PHONY: help
help:
ifdef HELP_DESCRIPTION
	@printf "%s\n\n" $(HELP_DESCRIPTION) | fmt
endif
	@echo "Available commands:"
	@grep -vE '^[[:space:]]' $(MAKEFILE_LIST) | \
		grep -E '^.*:.* #' | \
		sed -E 's/(.*):(.*):.*#(.*)/  \2###\3/' | \
		column -t -s '###'
