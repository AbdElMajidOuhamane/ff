#!/bin/sh
# Builds the struct-by-value fixture for test/ffi.test.js §8.
# Pure C, no Zig. Output name must match ffi.test.js FIXTURES:
#   libaddon_probe.dylib (macOS) / libaddon_probe.so (Linux)
set -e
cd "$(dirname "$0")"
case "$(uname -s)" in
  Darwin) cc -dynamiclib -fPIC -O2 -o libaddon_probe.dylib addon_probe.c ;;
  *)      cc -shared -fPIC -O2 -o libaddon_probe.so addon_probe.c ;;
esac
echo "built: $(ls libaddon_probe.*)"
