#!/bin/sh
# Builds the struct-by-value fixture for test/ffi.test.js §8.
# Pure C. Output name must match ffi.test.js FIXTURES:
#   libaddon_probe.dylib (macOS) / libaddon_probe.so (Linux)
#
# Always rebuilds, and always uses `zig cc`:
#   - a stale or previously committed binary must never mask a compile failure;
#   - system `cc` on macOS breaks whenever the selected Xcode and the installed
#     CommandLineTools SDK disagree (e.g. "unknown architecture arm64e.x1").
# Zig's bundled clang is hermetic and already required by this repo.
set -e
cd "$(dirname "$0")"

command -v zig >/dev/null 2>&1 || {
    echo "build.sh: zig not found in PATH (needed to build the C fixture)" >&2
    exit 1
}

case "$(uname -s)" in
  Darwin) out=libaddon_probe.dylib
          zig cc -dynamiclib -fPIC -O2 -o "$out" addon_probe.c ;;
  *)      out=libaddon_probe.so
          zig cc -shared    -fPIC -O2 -o "$out" addon_probe.c ;;
esac

echo "built: $out"
