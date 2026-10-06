#!/bin/sh
# Builds the struct-by-value fixture for test/ffi.test.js §8.
# Pure C, no Zig. Output name must match ffi.test.js FIXTURES:
#   libaddon_probe.dylib (macOS) / libaddon_probe.so (Linux)
#
# Skips the rebuild when the output is newer than the sources, so a broken
# system compiler can never clobber a good committed artifact.
set -e
cd "$(dirname "$0")"
case "$(uname -s)" in
  Darwin) out=libaddon_probe.dylib ;;
  *)      out=libaddon_probe.so ;;
esac
if [ -f "$out" ] && [ "$out" -nt addon_probe.c ] && [ "$out" -nt build.sh ]; then
    echo "fixture up to date: $out"
    exit 0
fi
case "$(uname -s)" in
  Darwin) cc -dynamiclib -fPIC -O2 -o libaddon_probe.dylib addon_probe.c ;;
  *)      cc -shared -fPIC -O2 -o libaddon_probe.so addon_probe.c ;;
esac
echo "built: $(ls libaddon_probe.*)"
