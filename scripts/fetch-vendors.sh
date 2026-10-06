#!/bin/sh
# fetch-vendors.sh — download pinned C vendors into vendor/.
#
# Single source of truth for vendor versions/pins. Used by:
#   - .github/workflows (CI + release builds)
#   - the Dockerfile (RUN sh scripts/fetch-vendors.sh)
#   - README "Option B" local builds
#
# Idempotent: a vendor already present on disk is skipped, so CI can
# safely cache vendor/ between runs.
set -eu

QJS_REPO="quickjs-ng/quickjs"
QJS_TAG="v0.16.2"
QJS_SHA256=""

BEARSSL_VERSION="0.6"
BEARSSL_SHA256="6705bba1714961b41a728dfc5debbe348d2966c117649392f8c8139efc83ff14"

SQLITE_VERSION="3.53.4"
SQLITE_YEAR="2026"

NGHTTP2_VERSION="1.70.0"
NGHTTP2_SHA256=""

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "fetch-vendors: missing tool: $1" >&2; exit 1; }
}
need curl
need tar

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

verify() { # verify <file> <expected-sha256-or-empty>
    if [ -n "$2" ]; then
        got="$(sha256 "$1")"
        if [ "$got" != "$2" ]; then
            echo "fetch-vendors: SHA256 mismatch for $1 (got $got, want $2)" >&2
            exit 1
        fi
    fi
}

# --- quickjs-ng -------------------------------------------------------
if [ -f "$VENDOR/quickjs/quickjs.c" ]; then
    echo "quickjs $QJS_TAG: present, skipping"
else
    echo "quickjs: fetching $QJS_TAG"
    curl -fL "https://github.com/${QJS_REPO}/archive/refs/tags/${QJS_TAG}.tar.gz" -o "$tmp/qjs.tar.gz"
    verify "$tmp/qjs.tar.gz" "$QJS_SHA256"
    rm -rf "$tmp/qjs" "$VENDOR/quickjs"
    mkdir -p "$tmp/qjs" "$VENDOR/quickjs"
    tar -xzf "$tmp/qjs.tar.gz" -C "$tmp/qjs" --strip-components=1
    cp "$tmp/qjs/"*.h "$tmp/qjs/quickjs.c" "$tmp/qjs/libregexp.c" \
       "$tmp/qjs/libunicode.c" "$tmp/qjs/dtoa.c" "$VENDOR/quickjs/"
fi

# --- BearSSL ----------------------------------------------------------
if [ -f "$VENDOR/bearssl/zig_bridge.h" ] && [ -f "$VENDOR/bearssl/inc/bearssl.h" ]; then
    echo "bearssl $BEARSSL_VERSION: present, skipping"
else
    echo "bearssl: fetching $BEARSSL_VERSION"
    curl -fSL -o "$tmp/bearssl.tar.gz" "https://www.bearssl.org/bearssl-${BEARSSL_VERSION}.tar.gz"
    verify "$tmp/bearssl.tar.gz" "$BEARSSL_SHA256"
    rm -rf "$tmp/bearssl" "$VENDOR/bearssl"
    mkdir -p "$tmp/bearssl" "$VENDOR/bearssl"
    tar -xzf "$tmp/bearssl.tar.gz" -C "$tmp/bearssl" --strip-components=1
    cp -r "$tmp/bearssl/src" "$tmp/bearssl/inc" "$VENDOR/bearssl/"
    printf '#ifndef FF_BEARSSL_BRIDGE_H\n#define FF_BEARSSL_BRIDGE_H\n\n#include "bearssl.h"\n\n#endif\n' \
        > "$VENDOR/bearssl/zig_bridge.h"
fi

# --- SQLite -----------------------------------------------------------
if [ -f "$VENDOR/sqlite/sqlite3.c" ]; then
    echo "sqlite $SQLITE_VERSION: present, skipping"
else
    need unzip
    echo "sqlite: fetching $SQLITE_VERSION"
    SQLITE_ENC="$(echo "$SQLITE_VERSION" | awk -F. '{if (NF==4) printf "%d%02d%02d",$1,$2,$3,$4; else printf "%d%02d%02d00",$1,$2,$3}')"
    curl -fSL -o "$tmp/sqlite.zip" "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_ENC}.zip"
    rm -rf "$tmp/sqlite" "$VENDOR/sqlite"
    mkdir -p "$tmp/sqlite" "$VENDOR/sqlite"
    unzip -q -o "$tmp/sqlite.zip" -d "$tmp/sqlite"
    cp "$tmp"/sqlite/sqlite-amalgamation-*/sqlite3.c \
       "$tmp"/sqlite/sqlite-amalgamation-*/sqlite3.h "$VENDOR/sqlite/"
    printf '#ifndef FF_SQLITE_BRIDGE_H\n#define FF_SQLITE_BRIDGE_H\n\n#include "sqlite3.h"\n\n#endif\n' \
        > "$VENDOR/sqlite/zig_bridge.h"
fi

# --- nghttp2 ----------------------------------------------------------
if [ -f "$VENDOR/nghttp2/lib/nghttp2_session.c" ]; then
    echo "nghttp2 $NGHTTP2_VERSION: present, skipping"
else
    echo "nghttp2: fetching $NGHTTP2_VERSION"
    curl -fSL -o "$tmp/nghttp2.tar.gz" \
        "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.gz"
    verify "$tmp/nghttp2.tar.gz" "$NGHTTP2_SHA256"
    rm -rf "$tmp/nghttp2" "$VENDOR/nghttp2"
    mkdir -p "$tmp/nghttp2" "$VENDOR/nghttp2/lib" "$VENDOR/nghttp2/includes"
    tar -xzf "$tmp/nghttp2.tar.gz" -C "$tmp/nghttp2" --strip-components=1
    cp "$tmp"/nghttp2/lib/*.c "$tmp"/nghttp2/lib/*.h "$VENDOR/nghttp2/lib/"
    cp -r "$tmp/nghttp2/lib/includes/nghttp2" "$VENDOR/nghttp2/includes/"
fi

echo "fetch-vendors: all vendors ready"
