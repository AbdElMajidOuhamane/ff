# syntax=docker/dockerfile:1

# ── Build stage ──────────────────────────────────────────────
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
# Pinned bellard/quickjs master snapshot — hash-verified identical to the
# locally validated build (dtoa-split lineage, NOT the 2024-01-13 release).
ARG QJS_COMMIT=04be246001599f5995fa2f2d8c91a0f198d3f34c
# Pinned BearSSL release tarball — sha256-verified (https://www.bearssl.org).
ARG BEARSSL_VERSION=0.6
ARG BEARSSL_SHA256=6705bba1714961b41a728dfc5debbe348d2966c117649392f8c8139efc83ff14
# amd64 -> x86_64, arm64 -> aarch64 (buildx TARGETARCH; defaults to x86_64)
ARG TARGETARCH
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"
COPY . .

# Fetch QuickJS (pinned commit, immutable GitHub archive) — V8-style:
# vendor/quickjs is untracked, fetched at container build time.
RUN curl -fL "https://github.com/bellard/quickjs/archive/${QJS_COMMIT}.tar.gz" -o /tmp/qjs.tar.gz \
 && mkdir -p /tmp/qjs-src \
 && tar -xzf /tmp/qjs.tar.gz -C /tmp/qjs-src --strip-components=1 \
 && mkdir -p vendor/quickjs \
 && cp /tmp/qjs-src/*.c /tmp/qjs-src/*.h vendor/quickjs/

# Fetch BearSSL (pinned release, sha256-verified) — vendor/bearssl is
# untracked, fetched at container build time (same pattern as QuickJS).
# Only src/ + inc/ are used; the local zig_bridge.h bridge is generated here.
# rm -rf first: the fetched tree must start clean (defense in depth against
# any leaked local copy mixing master-only sources with 0.6 headers).
RUN curl -fsSL -o /tmp/bearssl.tar.gz "https://www.bearssl.org/bearssl-${BEARSSL_VERSION}.tar.gz" \
 && echo "${BEARSSL_SHA256}  /tmp/bearssl.tar.gz" | sha256sum -c - \
 && rm -rf vendor/bearssl \
 && mkdir -p /tmp/bearssl-src \
 && tar -xzf /tmp/bearssl.tar.gz -C /tmp/bearssl-src --strip-components=1 \
 && mkdir -p vendor/bearssl \
 && cp -r /tmp/bearssl-src/src /tmp/bearssl-src/inc vendor/bearssl/ \
 && printf '#ifndef FF_BEARSSL_BRIDGE_H\n#define FF_BEARSSL_BRIDGE_H\n\n#include "bearssl.h"\n\n#endif\n' > vendor/bearssl/zig_bridge.h \
 && rm -rf /tmp/bearssl-src /tmp/bearssl.tar.gz

# Map buildx TARGETARCH to the Zig target triple.
# Static musl binary — no gcompat / libstdc++ needed at runtime.
RUN case "${TARGETARCH}" in \
      arm64) ZT=aarch64-linux-musl ;; \
      *)     ZT=x86_64-linux-musl ;; \
    esac && zig build -Doptimize=ReleaseFast -Dtarget=${ZT}

# ── Runtime stage ────────────────────────────────────────────
# QuickJS build is a static musl binary: no gcompat, no libstdc++ needed.
FROM alpine:3.20
# ca-certificates: needed by the runtime's own fetch/wss TLS client.
RUN apk add --no-cache ca-certificates
# Serving certs are runtime input, e.g.:
#   docker run -v ./certs:/app/certs ff start --cert /app/certs/cert.pem --key /app/certs/key.pem
RUN adduser -D -u 1000 app
WORKDIR /app
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
USER app
