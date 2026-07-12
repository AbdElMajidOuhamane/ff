.PHONY: build install uninstall

build:
	zig build -Doptimize=ReleaseFast

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
