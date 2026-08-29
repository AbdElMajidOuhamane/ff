# syntax=docker/dockerfile:1

# ── Build stage ──────────────────────────────────────────────
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
# amd64 -> x86_64, arm64 -> aarch64 (buildx TARGETARCH; defaults to host arch)
ARG TARGETARCH
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"
COPY . .

# Map buildx TARGETARCH to the Zig target triple
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
