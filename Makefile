include bats.lock
BATS_DIR     := .bats/bats-core-$(BATS_VERSION)
BATS         := $(BATS_DIR)/bin/bats
BATS_URL     := https://github.com/bats-core/bats-core/archive/refs/tags/v$(BATS_VERSION).tar.gz

.DEFAULT_GOAL := help
.PHONY: help test clean

help:
	@echo "Available targets:"
	@echo "  test        Run tests/check-and-push-config.bats (downloads BATS on first run)"
	@echo "  clean       Remove any generated/downloaded files"

$(BATS):
	mkdir -p .bats
	curl -fsSL $(BATS_URL) -o .bats/bats-$(BATS_VERSION).tar.gz
	echo "$(BATS_SHA256)  .bats/bats-$(BATS_VERSION).tar.gz" | sha256sum -c
	tar -xzf .bats/bats-$(BATS_VERSION).tar.gz -C .bats/
	rm .bats/bats-$(BATS_VERSION).tar.gz

test: bats.lock $(BATS)
	$(BATS) tests/

clean:
	rm -rf .bats/
