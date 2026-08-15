# syntax=docker/dockerfile:1
FROM debian:bookworm AS build
ARG ZIG_VERSION=0.16.0
ARG V8_ZIG_VERSION=v0.5.2
ARG V8_VERSION=14.9.207.35
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:$PATH"
COPY . .
RUN mkdir -p vendor/v8/linux && curl -fL -o vendor/v8/linux/libc_v8.a "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${V8_ZIG_VERSION}/libc_v8_${V8_VERSION}_linux_x86_64.a"
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dv8-linux

# Final Stage: The Anzar MicroVM Base
FROM alpine:3.20
# Install the GNU compatibility layer for the V8/Zig binary
RUN apk add --no-cache gcompat libstdc++ ca-certificates
RUN adduser -D -u 1000 app
WORKDIR /app
# Copy the compiled binary globally
COPY --from=build /app/zig-out/bin/ff /usr/local/bin/ff
