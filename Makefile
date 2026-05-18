# linux-toolkit-installer — developer tasks
.POSIX:
.PHONY: help lint test check install uninstall

PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin/linux-toolkit-installer
SELF   := $(abspath install.sh)

help:
	@echo "Targets:"
	@echo "  make lint       shellcheck (skips cleanly if not installed)"
	@echo "  make test       run tests/run.sh (bash -n + shellcheck + bats)"
	@echo "  make check      lint + test + dry-run --all on all 4 families"
	@echo "  make install    symlink install.sh -> $(BIN)"
	@echo "  make uninstall  remove that symlink"

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x install.sh lib/*.sh tests/run.sh && echo "shellcheck clean"; \
	else \
		echo "SKIPPED — shellcheck not installed (apt-get install shellcheck)"; \
	fi

test:
	@bash tests/run.sh

check: test
	@echo "== dry-run --all --with-optional across all families =="
	@for fam in debian fedora arch suse; do \
		echo "---- $$fam ----"; \
		./install.sh --force-family $$fam --dry-run --all --with-optional --yes \
			>/dev/null 2>&1 && echo "  $$fam OK" || { echo "  $$fam FAILED"; exit 1; }; \
	done
	@echo "check: OK"

install:
	@mkdir -p "$(PREFIX)/bin"
	@ln -sfn "$(SELF)" "$(BIN)"
	@echo "linked $(BIN) -> $(SELF)"

uninstall:
	@rm -f "$(BIN)"
	@echo "removed $(BIN)"
