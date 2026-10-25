.PHONY: build install uninstall fixtures fmt test ci fuzz fuzz-one fuzz-canary cov doctor

# Extra flags forwarded to `zig build`, e.g.:
#   make ci ZIGFLAGS="-Dtarget=x86_64-linux-musl -Dffi=false"
# CI Linux jobs are musl static; see .github/workflows/ci.yml.
ZIGFLAGS ?=

# Defaults for `make fuzz-one` (overridable: make fuzz-one FUZZ=ws_frame SEED=7 EVENTS=50000)
FUZZ ?= ws_frame
SEED ?= 123
EVENTS ?= 1000000

# ── macOS toolchain guard ──────────────────────────────────────────────────
# Zig 0.16.0 compiles its bundled libc++ from source. That copy does not
# build against the macOS 26/27 SDK shipped with standalone CommandLineTools:
#   error: sub-compilation of libcxx failed
#   clamp_to_integral.h: use of undeclared identifier 'INFINITY'
# If xcode-select points at CommandLineTools but Xcode is installed, hand
# Zig Xcode's Developer dir instead. `?=` keeps a DEVELOPER_DIR that the
# caller/CI already exported (GitHub macOS runners always set it).
ifeq ($(shell uname -s),Darwin)
  ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
    DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
    ifneq ($(wildcard $(DEVELOPER_DIR)/Platforms/MacOSX.platform),)
      export DEVELOPER_DIR
    endif
  endif
endif

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

# Matches the CI "tidy" job. Keep this path list in sync with ci.yml.
fmt:
	zig fmt --check build.zig src/

# Rebuilds the C fixture for test/ffi.test.js (zig cc, see build.sh).
fixtures:
	sh test/fixtures/build.sh

test: build fixtures
	zig build test $(ZIGFLAGS)
	sh test/run.sh

# CI entrypoint: same steps the GitHub Actions CI jobs run.
ci: fmt build fixtures
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

# Coverage via kcov (TigerBeetle-style): DWARF machine-code line coverage,
# no compiler flags. Requires `kcov` (brew install kcov / apt install kcov).
KCOV ?= kcov

cov:
	rm -rf kcov-output
	zig build test:build -Doptimize=ReleaseSafe $(ZIGFLAGS)
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/ff-test
	zig build fuzz:build -Doptimize=ReleaseSafe $(ZIGFLAGS)
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz smoke
	@for s in 123 124 125 126 127; do \
		for t in ws_frame http_request semver tls_pem utf8 http2_stream; do \
			$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz $$t $$s --events-max=200000 || exit 1; \
		done; \
	done
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz ws_frame 0123456789abcdef0123456789abcdef01234567 --events-max=1000 || exit 1
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz || true
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz bogus || true
	$(KCOV) --include-path=./src kcov-output ./zig-out/bin/fuzz canary 1 || true
	@echo "coverage: open kcov-output/index.html and follow the [merged] link"

# Diagnoses both toolchain traps:
#   1. cc + macOS 26/27 CLT SDK  -> "unknown architecture arm64e.x1"
#   2. zig + macOS 26/27 SDK     -> libcxx "INFINITY" sub-compilation failure
doctor:
	@echo "os:            $$(uname -sm)"
	@echo "xcode-select:  $$(xcode-select -p 2>/dev/null || echo none)"
	@echo "sdk:           $$(xcrun --show-sdk-path 2>/dev/null || echo none)"
	@echo "DEVELOPER_DIR: $${DEVELOPER_DIR:-<unset>}"
	@echo "zig:           $$(zig version)"
	@tmp=$$(mktemp -d); \
	printf 'pub fn main() void {}\n' > "$$tmp/t.zig"; \
	if out=$$(zig build-exe "$$tmp/t.zig" -lc++ --cache-dir "$$tmp/cache" -femit-bin="$$tmp/t" 2>&1); then \
		echo "zig -lc++:     ok"; \
	else \
		echo "zig -lc++:     FAILED — bundled libc++ cannot build against this SDK"; \
		echo "$$out" | head -3 | sed 's/^/               /'; \
		echo "               fix: sudo xcode-select -s /Applications/Xcode.app"; \
	fi; \
	rm -rf "$$tmp"
