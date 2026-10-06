# syntax=docker/dockerfile:1
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils unzip && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"
COPY . .
# Vendors are gitignored/dockerignored — fetch pinned sources (see
# scripts/fetch-vendors.sh for versions and hashes).
RUN sh scripts/fetch-vendors.sh
# Published image stays epoll: io_uring needs a permissive seccomp profile
# and this image must boot under Docker defaults. For io_uring, build with
# -Dio_uring=true and run with --security-opt seccomp=unconfined.
RUN case "${TARGETARCH}" in \
      arm64) ZT=aarch64-linux-musl ;; \
      *)     ZT=x86_64-linux-musl ;; \
    esac && zig build -Doptimize=ReleaseFast -Dtarget=${ZT} -Dffi=false -Dio_uring=true
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
RUN adduser -D -u 1000 app
WORKDIR /app
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
USER app
