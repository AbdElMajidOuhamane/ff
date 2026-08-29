# syntax=docker/dockerfile:1

# ── Build stage ──────────────────────────────────────────────
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
# Pinned bellard/quickjs master snapshot — hash-verified identical to the
# locally validated build (dtoa-split lineage, NOT the 2024-01-13 release).
ARG QJS_COMMIT=04be246001599f5995fa2f2d8c91a0f198d3f34c
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

# Map buildx TARGETARCH to the Zig target triple.
# Static musl binary — no gcompat / libstdc++ needed at runtime.
RUN case "${TARGETARCH}" in \
      arm64) ZT=aarch64-linux-musl ;; \
      *)     ZT=x86_64-linux-musl ;; \
    esac && zig build -Doptimize=ReleaseFast -Dtarget=${ZT}

# ── Runtime stage ────────────────────────────────────────────
# QuickJS build is a static musl binary: no gcompat, no libstdc++ needed.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
RUN adduser -D -u 1000 app
WORKDIR /app
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
USER app
