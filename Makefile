.PHONY: build install uninstall fixtures test ci fuzz fuzz-one fuzz-canary cov

# Extra flags forwarded to `zig build`, e.g.:
#   make ci ZIGFLAGS="-Dtarget=x86_64-linux-musl -Dffi=false"
# CI Linux jobs are musl static; see .github/workflows/ci.yml.
ZIGFLAGS ?=

# Defaults for `make fuzz-one` (overridable: make fuzz-one FUZZ=ws_frame SEED=7 EVENTS=50000)
FUZZ ?= ws_frame
SEED ?= 123
EVENTS ?= 1000000

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
	zig build fuzz -Doptimize=ReleaseSafe $(ZIGFLAGS) -- smoke

# Deterministic parser fuzzers (TigerBeetle-style). Always ReleaseSafe so
# OOB/overflow checks fire; the seed fully determines the run.
fuzz:
	zig build fuzz -Doptimize=ReleaseSafe $(ZIGFLAGS) -- smoke

# Single target: make fuzz-one FUZZ=ws_frame SEED=123 EVENTS=1000000
fuzz-one:
	zig build fuzz -Doptimize=ReleaseSafe $(ZIGFLAGS) -- $(FUZZ) $(SEED) --events-max=$(EVENTS)

# Canary must FAIL (proves fuzzer failures propagate); `!` inverts the exit.
fuzz-canary:
	! zig build fuzz -Doptimize=ReleaseSafe $(ZIGFLAGS) -- canary 1

# Coverage via zig-cov (https://github.com/ericsssan/zcov): build it once,
# then make cov ZIGCOV_RT=/path/to/zig-cov-rt.o ZIGCOV_BIN=/path/to/zig-cov
cov:
	@test -n "$(ZIGCOV_RT)" || { echo "set ZIGCOV_RT=/path/to/zig-cov-rt.o"; exit 2; }
	zig build test -Doptimize=ReleaseSafe -Dcoverage -Dcoverage-rt=$(ZIGCOV_RT) $(ZIGFLAGS)
	$(ZIGCOV_BIN) report *.zcov --format=html --output=zig-out/coverage.html
