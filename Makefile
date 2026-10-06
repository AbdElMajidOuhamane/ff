.PHONY: build install uninstall fixtures test ci

# Extra flags forwarded to `zig build`, e.g.:
#   make ci ZIGFLAGS="-Dtarget=x86_64-linux-musl -Dffi=false"
# CI Linux jobs are musl static; see .github/workflows/ci.yml.
ZIGFLAGS ?=

build:
	zig build -Doptimize=ReleaseFast $(ZIGFLAGS)

install: build
	mkdir -p $(HOME)/.local/bin
	cp zig-out/bin/ff $(HOME)/.local/bin/ff
	@echo "Installed to ~/.local/bin/ff"
	@if ! echo "$$PATH" | grep -q "$(HOME)/.local/bin"; then \
		echo "Add to your ~/.zshrc:"; \
		echo '  export PATH="$$HOME/.local/bin:$$PATH"'; \
	fi

uninstall:
	rm -f $(HOME)/.local/bin/ff

# Builds the C fixture for test/ffi.test.js
# (libaddon_probe.dylib on macOS, .so on Linux).
fixtures:
	sh test/fixtures/build.sh

test: build fixtures
	zig build test $(ZIGFLAGS)
	sh test/run.sh

# CI entrypoint: same steps the GitHub Actions CI jobs run.
ci: build fixtures
	zig build test $(ZIGFLAGS)
	sh test/run.sh
